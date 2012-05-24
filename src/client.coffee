EventEmitter = require('events').EventEmitter

tls = require 'tls'
net = require 'net'
_ = require 'underscore'

identifierlessOutgoingCommands = []

class PimSocket extends EventEmitter
  constructor: (options) ->
    super
    @bufferIncrement = 1024
    @buffer = new Buffer(@bufferIncrement)
    @endOfBuffer = 0
    @token = options.token
    host = options.host ? "p.im"
    port = options.port ? 443
    secure = options.secure ? ((port % 2) is 1)
    M = net
    if secure
      M = tls
    @_socket = M.connect port, host, () =>
      #TODO: Check the connection is secure
      @_socket.write "GET / HTTP/1.1\r\nHost: #{host}\r\nUpgrade: raw\r\n\r\n"
    @_socket.on 'data', @onData
    @_socket.on 'end', @destroy
    @_socket.on 'error', @destroy
    @_socket.on 'close', @destroy

  destroy: =>
    if !@destroyed
      @destroyed = true
      @emit 'destroy'
      if @_socket
        @_socket.removeAllListeners()
        @_socket.end()
        @_socket.destroy()
        delete @_socket
      delete @buffer
      @removeAllListeners()

  log: =>
    @emit 'log', arguments...

  onData: (data) =>
    if data.length is 0
      return
    smallestMultipleOfXLargerThanY = (x,y) ->
      m = Math.ceil(y/x)
      return x*m
    newSize = @endOfBuffer + data.length
    if newSize > @buffer.length
      oldBuffer = @buffer
      @buffer = new Buffer(smallestMultipleOfXLargerThanY(@bufferIncrement,newSize))
      oldBuffer.copy(@buffer)
    data.copy(@buffer,@endOfBuffer,0,data.length)
    @endOfBuffer = newSize
    start = 0
    for i in [0...@endOfBuffer]
      if @buffer[i] is 10 # \n
        payload = ""
        if i > start
          payload = @buffer.toString('utf8',start,i)
          @log '>> '+payload
          @emit 'message', payload
        start = i+1
    if start > 0
      if start < @endOfBuffer
        @buffer.copy @buffer, 0, start, @endOfBuffer
      @endOfBuffer -= start
    return

  send: (message) =>
    if !@destroyed
      @log '<< '+message
      @_socket.write message+"\n", 'utf8'
      return true
    else
      error = new Error "Destroyed socket cannot send data"
      error.code = 'DESTROYED'
      @emit 'error', error
      return false

class PimClient extends EventEmitter
  protocol: "1"
  encoding: "H"
  autoStatus: 'idle'

  constructor: (@delegate, options) ->
    super
    @callbacks = {}
    if options?.token
      @token = options.token
    @socket = new PimSocket options
    @socket.on 'log', @log
    @socket.on 'message', @onMessage
    @socket.on 'destroy', =>
      delete @socket
      @destroy()
    @on 'ready', @onReady

  destroy: ->
    if !@destroyed
      @destroyed = true
      @emit 'destroy'
      delete @delegate
      # TODO: Invalidate all callbacks with an error?
      delete @callbacks
      if @socket
        @socket.removeAllListeners()
        @socket.destroy()
        delete @socket
      if @keepaliveTimer
        clearTimeout @keepaliveTimer
        delete @keepaliveTimer
      @removeAllListeners()

  log: =>
    @emit 'log', arguments...

  sendResponse: (command, identifier, args) ->
    return @send {command, identifier, args}

  sendCommand: (command, args, callback) ->
    if typeof args is 'function'
      # User omitted args
      callback = args
      args = {}
    if callback
      identifier = null
      for i in [1..1000]
        if !@callbacks[""+i]?
          identifier = i
          break
      if !identifier?
        error = new Error "Callbacks exhausted"
        error.code = 'CALLBACKFAIL'
        @emit 'error', error
        return false
      @callbacks[""+identifier] = {callback:callback}
    else
      identifier = 0
    return @send {command, identifier, args}

  send: (details) ->
    {command, identifier, args} = details
    toSend = command
    if identifierlessOutgoingCommands.indexOf(command) is -1
      toSend += " #{identifier}"
    if args?
      try
        argsStr = JSON.stringify args
      catch e
        e.code = 'JSONFAIL'
        @emit 'error', e
        return false
      if argsStr.substr(0,1) isnt '{'
        error = new Error "Invalid args"
        error.code = "ARGSFAIL"
        @emit 'error', error
        return false
      argsStr = argsStr.substr(1,argsStr.length-2)
      if argsStr.length
        toSend += " #{argsStr}"
    return @socket.send toSend

  onMessage: (message) =>
    unless @announced
      @log "Server is: #{message}"
      # TODO: Check what protocol/encodings the server supports by parsing message
      @announced = true
      @socket.send "P #{@protocol} #{@encoding}"
    else unless @established
      if message is "P #{@protocol} #{@encoding}"
        @log "Protocol/encoding accepted. Connection established."
        @established = true
        @emit 'ready'
      else
        error = new Error "Handshake not understood by server: #{message}"
        error.code = 'HANDSHAKEFAIL'
        @emit 'error', error
        @destroy()
    else
      @processMessage message
    return

  error: (code, message) ->
    @log "ERROR{#{code}}: #{message}"
    return errorCode: code, errorMessage: message

  processMessage: (message) ->
    @resetKeepalive()
    matches = message.match /^([A-Z]+)( [0-9]+)?( \".*)?$/
    unless matches
      error = new Error "Invalid command received: #{message}"
      error.code = 'COMMANDFAIL'
      @emit 'error', error
      @destroy()
      return
    command = matches[1]
    identifier = parseInt matches[2]
    argsStr = matches[3]

    if isNaN(identifier) or identifier < 0
      identifier = 0
    unless argsStr
      args = {}
    else
      try
        args = JSON.parse "{#{argsStr}}"
      catch e
        e.code = 'JSONFAIL'
        @emit 'error', e
        @destroy()
        return

    if command is 'RESPONSE'
      if identifier > 0
        cb = @callbacks[""+identifier]
        if cb?
          delete @callbacks[""+identifier]
          cb.callback args
        else
          error = new Error "Tried to invoke a non-existant callback"
          error.code = "RESPONSEFAIL"
          @emit 'error', error
      else
        error = new Error "Server responded but no reponse requested"
        error.code = "RESPONSEFAIL"
        @emit 'error', error
    else
      if identifier > 0
        callback = (args) =>
          @sendResponse command, identifier, args
          return
      else
        callback = null
      @catchall command, args, callback
    return

  resetKeepalive: ->
    if @keepaliveTimer?
      clearTimeout @keepaliveTimer
    @keepaliveTimer = setTimeout @keepalive, 60000

  keepalive: =>
    delete @keepaliveTimer
    time = new Date().getTime()
    @sendCommand 'PING', (args) =>
      if args.success?
        @log "Lag: #{(new Date().getTime() - time)/1000}s"
        @resetKeepalive()
      else
        # TODO: Handle this, though it should never occur...
        console.error "PING FAILED, this is unhandled..."
        console.dir args

  onReady: =>
    @resetKeepalive()
    if @token?
      autoStatus = @autoStatus
      if @delegate?.autoStatus?
        if typeof @delegate.autoStatus is 'function'
          autoStatus = @delegate.autoStatus()
        else
          autoStatus = @delegate.autoStatus
      @sendCommand "AUTH", {token: @token, autoStatus:autoStatus}, (res) =>
        if res.errorCode
          @emit 'authenticationFailed'
        else
          @emit 'authenticated', res

  catchall: (command, args, callback) ->
    if @delegate?[command]
      @delegate[command] args, callback
    else
      if command is 'PING'
        callback success:true
      else
        @log "UNHANDLED COMMAND: '#{command}'"

module.exports = PimClient
