-- Contract for Transport's non-blocking dial, the shape the browser forces:
-- a WebSocket handshake only advances when the page's event loop turns, so
-- the first connect() can never succeed and the socket comes up several
-- frames later.  Everything here runs against an injected fake socketModule,
-- so it needs no OS socket and no ROM:
--   luajit tests/mmo_transport_async_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq
local Transport = require("src.mmo.Transport")
local Platform = require("src.core.Platform")

-- Transport dates its dial deadline off love.timer.getTime (os.clock measures
-- CPU time, which barely moves while a page waits on a handshake).  Drive it
-- by hand so the timeout case does not depend on wall clock.
local clock = 0
love.timer.getTime = function() return clock end

-- A scripted stand-in for a LuaSocket TCP object.  Each entry of `script` is
-- what the n-th connect() call reports: `true` for success, otherwise the
-- error string LuaSocket would hand back.  The last entry repeats, which is
-- what a real pending socket does.
local FakeTcp = {}
FakeTcp.__index = FakeTcp

function FakeTcp.new(script)
  return setmetatable({ script = script, dials = 0, timeouts = {},
                        wire = "", rx = "", closed = false }, FakeTcp)
end
function FakeTcp:settimeout(value) self.timeouts[#self.timeouts + 1] = value end
function FakeTcp:connect(host, port)
  self.dials = self.dials + 1
  self.host, self.port = host, port
  local step = self.script[math.min(self.dials, #self.script)]
  if step == true then return 1 end
  return nil, step
end
function FakeTcp:send(bytes) self.wire = self.wire .. bytes return #bytes end
function FakeTcp:receive()
  if self.rx == "" then return nil, "timeout", "" end
  local chunk = self.rx
  self.rx = ""
  return nil, "timeout", chunk
end
function FakeTcp:close() self.closed = true end

local function fakeModule(script, select)
  local mod = { tcps = {} }
  function mod.tcp()
    local tcp = FakeTcp.new(script)
    mod.tcps[#mod.tcps + 1] = tcp
    mod.last = tcp
    return tcp
  end
  mod.select = select
  return mod
end

-- ------------------------------------------------- the browser dial, happy path
do
  -- Emscripten's SOCKFS reports "timeout" until the WebSocket handshake has
  -- had a few frames, then "already connected" once it is up.
  local mod = fakeModule({ "timeout", "timeout", "timeout", "already connected" })
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })

  check(t:connect("play.example.com:4000"), "async connect() returns true for 'dialling'")
  local sock = mod.last
  check(t.connecting, "a pending dial is flagged connecting")
  check(not t.connected, "connect() returning true does NOT mean connected yet")
  check(not t.closed, "a pending dial is not closed")
  eq(sock.timeouts[1], 0, "the async dial sets a zero timeout so it never blocks")
  eq(sock.host, "play.example.com", "the dial splits host from the address")
  eq(sock.port, 4000, "the dial splits port from the address, as a number")
  eq(t.deadline, 3, "a pending dial arms a deadline from love.timer.getTime")

  -- join_world wants to go out on the first world tick, which is exactly when
  -- the browser is still shaking hands -- so it must buffer, not be dropped.
  check(t:send({ type = "join_world", name = "RED" }),
        "send() during the handshake is accepted")
  check(#t.txBuf > 0, "send() during the handshake buffers the message")
  eq(sock.wire, "", "nothing reaches the wire before the socket is up")

  t:update()
  check(t.connecting and not t.connected, "one tick later the dial is still pending")
  t:update()
  check(t.connecting and not t.connected, "and still pending on the tick after that")
  eq(sock.wire, "", "a pending dial never flushes the buffer")
  eq(sock.dials, 3, "each tick retries the connect once")

  -- Second retry reports "already connected": the socket is really up now.
  t:update()
  check(t.connected, "the retry that reports 'already connected' completes the dial")
  check(not t.connecting, "completing the dial clears the connecting flag")
  check(not t.closed, "a completed dial is not closed")
  check(sock.wire:find("join_world", 1, true) ~= nil,
        "the buffered message goes out on the first tick after connecting")
  eq(sock.wire:sub(-1), "\n", "the buffered message keeps its newline framing")
  eq(t.txBuf, "", "a flushed buffer is drained")

  -- ...and the connection behaves like the old one from here on.
  sock.rx = '{"type":"world_snapshot","selfId":"me"}\n'
  t:update()
  local messages = t:poll()
  eq(#messages, 1, "a connected async transport decodes inbound lines")
  eq(messages[1].selfId, "me", "the decoded payload survives the async path")

  t:close()
  check(sock.closed and t.closed, "close() shuts the socket down")
end

-- ---------------------------------------------------- refusal, resolved later
do
  -- The realistic browser refusal: the dial is accepted as pending and the
  -- failure only surfaces on a later tick.
  local mod = fakeModule({ "timeout", "connection refused" })
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })
  check(t:connect("127.0.0.1:4000"), "a dial that will be refused still starts pending")
  local sock = mod.last

  t:update()
  check(not t.connected, "a refused dial never connects")
  check(not t.connecting, "a refused dial stops dialling")
  check(t.closed, "a refused dial closes the transport")
  check(t.error and tostring(t.error):find("connection refused", 1, true) ~= nil,
        "a refused dial records the socket's reason (got: " .. tostring(t.error) .. ")")
  check(sock.closed, "a refused dial releases the socket")
  check(not t:send({ type = "join_world" }), "send() on a refused transport is refused")
  t:update()
  eq(sock.dials, 2, "a closed transport stops retrying")
end

-- ------------------------------------------------- refusal on the first dial
do
  -- The other shape: the stack answers immediately.  connect() reports the
  -- failure through its return value and self.error.
  local mod = fakeModule({ "connection refused" })
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })
  check(not t:connect("127.0.0.1:4000"), "an immediately refused dial returns false")
  check(t.error and tostring(t.error):find("connection refused", 1, true) ~= nil,
        "an immediately refused dial records the reason")
  check(not t.connected and not t.connecting,
        "an immediately refused dial is neither connected nor dialling")
  check(mod.last.closed, "an immediately refused dial releases the socket")
  check(not t:send({ type = "join_world" }),
        "send() after a refused connect() is refused")
  -- NOTE: unlike the later-tick refusal above, this path leaves `closed`
  -- false -- it matches the pre-existing desktop path, which also only
  -- returns false.  Pinned so a change to either is deliberate.
  check(not t.closed, "an immediately refused dial leaves `closed` false (see NOTE)")
end

-- ------------------------------------------------------------------ deadline
do
  local mod = fakeModule({ "timeout" })  -- never resolves
  clock = 100
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })
  check(t:connect("10.0.0.1:4000"), "a dead address still starts pending")
  eq(t.deadline, 103, "the deadline is now + connectTimeout")
  local sock = mod.last

  clock = 102.9
  t:update()
  check(t.connecting, "before the deadline the dial keeps retrying")
  clock = 103.1
  t:update()
  check(not t.connecting and t.closed, "past the deadline the dial is abandoned")
  check(t.error and tostring(t.error):find("timed out", 1, true) ~= nil,
        "the abandoned dial says it timed out (got: " .. tostring(t.error) .. ")")
  check(t.error and tostring(t.error):find("3", 1, true) ~= nil,
        "the timeout message names the configured timeout")
  check(sock.closed, "the abandoned dial releases the socket")
  clock = 0
end

-- -------------------------------------------------------- select() gating
do
  -- Some LuaSocket builds expose select; when it says the socket is not yet
  -- writable, Transport must not burn a connect() retry on it.
  -- The opening connect() happens before any select, so the script has to
  -- start pending for the gating to be observable at all.
  local writable = {}
  local mod = fakeModule({ "timeout", "already connected" },
    function(_, _, _) return {}, writable end)
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })
  check(t:connect("127.0.0.1:4000"), "select-aware dial starts pending")
  local sock = mod.last
  eq(sock.dials, 1, "the opening connect() is the only dial so far")

  t:update()
  eq(sock.dials, 1, "an unwritable socket does not consume a connect() retry")
  check(t.connecting, "an unwritable socket stays pending")

  writable[1] = sock
  t:update()
  eq(sock.dials, 2, "a writable socket is retried")
  check(t.connected, "a writable socket completes the dial")
end

-- --------------------------------------------------------- guards and reentry
do
  local mod = fakeModule({ "timeout" })
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })
  check(not t:send({ type = "join_world" }),
        "send() before any connect() is refused")
  t:connect("127.0.0.1:4000")
  check(t:connect("127.0.0.1:4000"), "connect() while dialling reports true")
  eq(#mod.tcps, 1, "connect() while dialling does not open a second socket")

  t:close()
  check(t.closed and not t.connecting, "close() during a dial stops the dial")
  t:update()
  check(not t.connected, "update() on a closed transport does nothing")

  local bad = Transport.new({ async = true, socketModule = fakeModule({ true }) })
  check(not bad:connect("no-port-here"), "a malformed address is rejected")
  check(bad.error and tostring(bad.error):find("host:port", 1, true) ~= nil,
        "the malformed address says what it expected")

  local none = Transport.new({ async = true, socketModule = false })
  check(not none:connect("127.0.0.1:4000"), "no LuaSocket means no connect")
  check(none.error and tostring(none.error):find("LuaSocket", 1, true) ~= nil,
        "the missing-LuaSocket reason names LuaSocket")
end

-- ------------------------------------------------------------ desktop path
do
  -- async = false must behave exactly as it did before the browser work:
  -- one blocking connect, connected on return, no connecting state.
  local mod = fakeModule({ true })
  local t = Transport.new({ async = false, socketModule = mod, connectTimeout = 5 })
  check(not t:send({ type = "join_world" }), "desktop send() before connect is refused")
  check(t:connect("127.0.0.1:4000"), "desktop connect() succeeds on the first call")
  local sock = mod.last
  check(t.connected, "desktop connect() returning true means connected")
  check(not t.connecting, "the desktop path never enters the connecting state")
  check(not t.closed, "a connected desktop transport is not closed")
  check(t.deadline == nil, "the desktop path arms no dial deadline")
  eq(sock.timeouts[1], 5, "the desktop dial blocks for connectTimeout")
  eq(sock.timeouts[2], 0, "the desktop socket is non-blocking once connected")
  eq(sock.dials, 1, "the desktop path dials exactly once")

  check(t:send({ type = "join_world", name = "RED" }), "desktop send() queues")
  t:update()
  check(sock.wire:find("join_world", 1, true) ~= nil, "desktop update() flushes the queue")
  eq(sock.dials, 1, "desktop update() never re-dials")

  sock.rx = '{"type":"world_snapshot"}\n{"type":"player_left"}\n'
  t:update()
  eq(#t:poll(), 2, "desktop receive still decodes every complete line")
end

do
  -- A desktop refusal is a plain false from connect(), as before.
  local mod = fakeModule({ "connection refused" })
  local t = Transport.new({ async = false, socketModule = mod, connectTimeout = 5 })
  check(not t:connect("127.0.0.1:4000"), "desktop connect() returns false when refused")
  check(t.error and tostring(t.error):find("connection refused", 1, true) ~= nil,
        "desktop refusal records the reason")
  check(not t.connected and not t.connecting, "desktop refusal leaves nothing dialling")
  check(mod.last.closed, "desktop refusal releases the socket")
end

-- ------------------------------------------------- async defaults off platform
do
  local realSystem = love.system
  Platform._resetForTests()
  love.system = { getOS = function() return "Web" end }
  check(Platform.isWeb(), "Platform.isWeb() is true when love reports OS 'Web'")
  eq(Platform.detect().romImportMode, "browser", "the web build imports ROMs via the browser")
  check(not Platform.detect().canSpawnProcess, "a browser build cannot spawn a process")
  local web = Transport.new({ socketModule = fakeModule({ "timeout" }) })
  check(web.async, "Transport defaults to the async dial on the web")

  Platform._resetForTests()
  love.system = { getOS = function() return "OS X" end }
  check(not Platform.isWeb(), "Platform.isWeb() is false on a desktop OS")
  local desktop = Transport.new({ socketModule = fakeModule({ true }) })
  check(not desktop.async, "Transport defaults to the blocking dial off the web")

  Platform._resetForTests()
  love.system = realSystem
end

-- ------------------------------------------------- clock fallback without love
do
  -- love.timer is gone in the plain-Lua harness the primitive tiers use, so
  -- now() has to fall back to os.clock rather than index a nil global.
  local realLove = love
  love = nil
  local mod = fakeModule({ "timeout" })
  local t = Transport.new({ async = true, socketModule = mod, connectTimeout = 3 })
  local ok, err = pcall(function() return t:connect("127.0.0.1:4000") end)
  love = realLove
  check(ok, "an async dial with no love global does not raise (" .. tostring(err) .. ")")
  check(type(t.deadline) == "number", "the deadline falls back to a real number")
end

T.finish("Transport async dial")
