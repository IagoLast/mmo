-- Persistent newline-delimited JSON transport for the MMO service.
-- Kept separate from src/link/Net: link play owns peer/room semantics, while
-- this connection is a long-lived application channel.
--
-- The browser is the WebSocket-backed implementation this module was left
-- room for, and it needs no second codepath: love.js links LuaSocket, and
-- Emscripten's SOCKFS maps a TCP socket onto a WebSocket, so `socket.tcp()`
-- and the newline-delimited JSON framing below travel unchanged.  What does
-- NOT survive the move is the *blocking* connect: the WebSocket handshake
-- only advances when the page's event loop turns, and the event loop cannot
-- turn while Lua is parked inside connect().  A blocking connect in a browser
-- therefore always burns its whole timeout and then fails.
--
-- So connect() is a state machine.  It opens the socket non-blocking, and
-- update() finishes the handshake over subsequent frames.  connect() returning
-- true means "dialling", not "connected"; `self.connected` still only flips
-- once the peer is actually there, which is the flag WorldClient gates
-- publishing on.  Desktop keeps the old blocking behaviour by default so
-- nothing about a native run changes (async = Platform.isWeb()).

local Json = require("src.link.Json")

local okSocket, socket = pcall(require, "socket")
if not okSocket then socket = nil end

local Transport = {}
Transport.__index = Transport

-- LuaSocket reports "an operation is already in progress" for a non-blocking
-- connect that has not resolved, and "already connected" once it has.  The
-- exact wording varies with the platform's strerror, so match on substrings
-- rather than on equality.
local function classifyConnect(err)
  if not err then return "connected" end
  local text = tostring(err):lower()
  if text:find("already connected", 1, true)
      or text:find("isconn", 1, true) then
    return "connected"
  end
  if text == "timeout"
      or text:find("in progress", 1, true)
      or text:find("would block", 1, true)
      or text:find("einprogress", 1, true)
      or text:find("ealready", 1, true) then
    return "pending"
  end
  return "failed"
end

local function splitAddress(address)
  local host, port = tostring(address or ""):match("^(.-):(%d+)$")
  if not host or host == "" then return nil, nil, "expected host:port" end
  return host, tonumber(port)
end

-- Wall clock for the dial deadline. os.clock() measures CPU time, which
-- barely advances while the page waits on a handshake, so it would let a
-- dead address hang effectively forever; love.timer.getTime() is real time
-- and is verified working under love.js.
local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

function Transport.new(opts)
  opts = opts or {}
  local async = opts.async
  if async == nil then
    local okPlatform, Platform = pcall(require, "src.core.Platform")
    async = okPlatform and Platform.isWeb() or false
  end
  return setmetatable({
    socketModule = opts.socketModule or socket,
    connectTimeout = opts.connectTimeout or 3,
    async = async and true or false,
    inbox = {}, rxBuf = "", txBuf = "",
    connected = false, connecting = false, closed = false, error = nil,
  }, Transport)
end

function Transport:connect(address)
  if self.connected or self.connecting then return true end
  if not self.socketModule then
    self.error = "MMO play needs LuaSocket"
    return false
  end
  local host, port, why = splitAddress(address)
  if not host then self.error = why return false end
  local tcp, err = self.socketModule.tcp()
  if not tcp then self.error = tostring(err or "can't create TCP socket") return false end

  self.host, self.port = host, port
  self.address = address

  if not self.async then
    tcp:settimeout(self.connectTimeout)
    local connected, connectErr = tcp:connect(host, port)
    if not connected then
      pcall(function() tcp:close() end)
      self.error = tostring(connectErr or "connection failed")
      return false
    end
    tcp:settimeout(0)
    self.socket = tcp
    self.connected = true
    self.closed = false
    return true
  end

  -- Async dial: never blocks, so a browser frame is never held hostage.
  tcp:settimeout(0)
  local connected, connectErr = tcp:connect(host, port)
  local state = connected and "connected" or classifyConnect(connectErr)
  if state == "failed" then
    pcall(function() tcp:close() end)
    self.error = tostring(connectErr or "connection failed")
    return false
  end
  self.socket = tcp
  self.closed = false
  if state == "connected" then
    self.connected = true
    self.connecting = false
  else
    self.connecting = true
    self.deadline = now() + self.connectTimeout
  end
  return true
end

-- Advance a pending async dial by one tick. Returns true once the socket is
-- usable; sets self.error and closes on refusal or deadline.
function Transport:_advanceConnect()
  local sock = self.socket
  if not sock then
    self.connecting = false
    return false
  end
  -- select() tells us the socket has resolved one way or the other; a second
  -- connect() then reports which. Not every LuaSocket build exposes select
  -- usefully here, so the connect() retry alone is also sufficient.
  local ready = true
  if self.socketModule and self.socketModule.select then
    local _, writable = self.socketModule.select(nil, { sock }, 0)
    ready = writable ~= nil and #writable > 0
  end
  if ready then
    local connected, connectErr = sock:connect(self.host, self.port)
    local state = connected and "connected" or classifyConnect(connectErr)
    if state == "connected" then
      self.connecting = false
      self.connected = true
      return true
    end
    if state == "failed" then
      self:_fail("MMO connect failed: " .. tostring(connectErr))
      return false
    end
  end
  if self.deadline and now() > self.deadline then
    self:_fail("MMO connect timed out after "
      .. tostring(self.connectTimeout) .. "s")
  end
  return false
end

function Transport:send(message)
  -- Buffer while the async dial is still in flight rather than dropping the
  -- message: the first frames after boot are exactly when join_world wants
  -- to go out, and the browser handshake takes a few of them.
  if self.closed or not (self.connected or self.connecting) then return false end
  self.txBuf = self.txBuf .. Json.encode(message) .. "\n"
  return true
end

function Transport:_fail(message)
  self.error = tostring(message)
  self.connected = false
  self.connecting = false
  self.closed = true
  if self.socket then pcall(function() self.socket:close() end) end
  self.socket = nil
end

function Transport:_flush()
  if #self.txBuf == 0 then return end
  local sent, err, last = self.socket:send(self.txBuf)
  if sent then
    self.txBuf = self.txBuf:sub(sent + 1)
  elseif err == "timeout" then
    self.txBuf = self.txBuf:sub((last or 0) + 1)
  else
    self:_fail("MMO send failed: " .. tostring(err))
  end
end

function Transport:_receive()
  while self.connected do
    local data, err, partial = self.socket:receive(8192)
    local chunk = data or partial or ""
    if #chunk > 0 then self.rxBuf = self.rxBuf .. chunk end
    if err == "closed" then self:_fail("MMO server closed the connection") break end
    if err and err ~= "timeout" then self:_fail("MMO receive failed: " .. tostring(err)) break end
    if not data then break end
  end
  while true do
    local newline = self.rxBuf:find("\n", 1, true)
    if not newline then break end
    local line = self.rxBuf:sub(1, newline - 1):gsub("\r$", "")
    self.rxBuf = self.rxBuf:sub(newline + 1)
    if line ~= "" then
      local message = Json.decode(line)
      if message then
        self.inbox[#self.inbox + 1] = message
      end
    end
  end
end

function Transport:update()
  if self.closed then return end
  -- A queued send() before the handshake lands is fine: it sits in txBuf and
  -- goes out on the first tick after the socket comes up.
  if self.connecting and not self:_advanceConnect() then return end
  if not self.connected then return end
  self:_flush()
  if self.connected then self:_receive() end
end

function Transport:poll()
  local messages = self.inbox
  self.inbox = {}
  return messages
end

function Transport:close()
  if self.socket then pcall(function() self.socket:close() end) end
  self.socket = nil
  self.connected = false
  self.connecting = false
  self.closed = true
end

return Transport
