-- Headless MMO presence contract. Run with:
--   luajit tests/mmo_world_client_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq
local WorldClient = require("src.mmo.WorldClient")
local Transport = require("src.mmo.Transport")

-- Transport framing remains independently testable without an OS socket.
do
  local wire = { written = "", read = '{"type":"one"}\n{"type":"two","n":2}\n' }
  function wire:send(bytes) self.written = self.written .. bytes return #bytes end
  function wire:receive()
    if self.read == "" then return nil, "timeout", "" end
    local chunk = self.read
    self.read = ""
    return nil, "timeout", chunk
  end
  function wire:close() self.didClose = true end
  local framed = Transport.new()
  framed.socket, framed.connected = wire, true
  check(framed:send({ type = "hello", name = "RED" }), "transport queues JSON")
  framed:update()
  check(wire.written:sub(-1) == "\n", "transport writes newline-delimited JSON")
  local messages = framed:poll()
  eq(#messages, 2, "transport decodes every complete line")
  eq(messages[2].n, 2, "transport preserves JSON payload")
  framed:close()
  check(wire.didClose, "transport closes its socket")
end

local FakeTransport = {}
FakeTransport.__index = FakeTransport

function FakeTransport.new()
  return setmetatable({ connected = false, sent = {}, inbox = {} }, FakeTransport)
end
function FakeTransport:connect(address) self.address = address self.connected = true return true end
function FakeTransport:send(message) self.sent[#self.sent + 1] = message return true end
function FakeTransport:update() end
function FakeTransport:poll() local out = self.inbox self.inbox = {} return out end
function FakeTransport:push(message) self.inbox[#self.inbox + 1] = message end
function FakeTransport:close() self.connected = false self.closed = true end

local transport = FakeTransport.new()
local ow = {
  isOverworld = true,
  map = { id = "PALLET_TOWN" },
  player = { cellX = 5, cellY = 6, px = 80, py = 96,
             facing = "down", moving = false },
  npcPool = {}, added = {}, removed = {},
}
function ow:addRuntimeObject(mapId, def, owner)
  local id = mapId .. "_mmo_" .. tostring(#self.added + 1)
  self.added[#self.added + 1] = { id = id, mapId = mapId, def = def, owner = owner }
  self.npcPool[id] = { id = id, def = def, progress = 0 }
  return id
end
function ow:removeRuntimeObject(id, owner)
  self.removed[#self.removed + 1] = { id = id, owner = owner }
  self.npcPool[id] = nil
  return true
end

local game = {
  stack = { states = { ow } }, overworld = ow,
  save = { player = { name = "RED" } },
  data = {
    maps = { PALLET_TOWN = {}, VIRIDIAN_CITY = {} },
    field = { playerSprites = { walk = "SPRITE_RED" } },
  },
}

local client = WorldClient.new(game, {
  address = "127.0.0.1:4000", transport = transport,
})
check(client:connect(), "fake MMO transport connects")
client:update()
local join = transport.sent[1]
eq(join.type, "join_world", "first world tick joins")
eq(join.name, "RED", "join uses local save name")
eq(join.mapId, "PALLET_TOWN", "join includes map")
eq(join.px, 80, "join includes pixel position")

transport:push({ type = "world_snapshot", selfId = "me", players = {
  { playerId = "me", name = "RED", mapId = "PALLET_TOWN", x = 5, y = 6 },
  { playerId = "blue", name = "BLUE", mapId = "PALLET_TOWN", x = 7, y = 8,
    px = 113, py = 128, facing = "left", moving = true },
} })
client:update()
eq(client.selfId, "me", "world snapshot establishes local id")
check(client:player("me") == nil, "snapshot never mirrors the local player")
local blue = client:player("blue")
check(blue ~= nil, "snapshot stores a remote player")
eq(#ow.added, 1, "remote player spawns one runtime NPC")
local entity = client:remoteEntity("blue")
check(entity and entity.remoteControlled, "remote NPC is network controlled")
check(entity.passable, "remote NPC is visible but never collision-blocks")
eq(entity.remotePlayerName, "BLUE", "remote NPC exposes trainer name")
eq(entity.px, 113, "remote NPC uses authoritative pixel position")

ow.player.facing, ow.player.moving, ow.player.px = "right", true, 81
client:update()
local move = transport.sent[#transport.sent]
eq(move.type, "move", "changed local pose emits move")
eq(move.seq, 1, "moves carry increasing sequence")
eq(move.facing, "right", "move carries facing")

ow.map.id = "VIRIDIAN_CITY"
ow.player.cellX, ow.player.cellY = 2, 3
ow.player.px, ow.player.py, ow.player.moving = 32, 48, false
client:update()
local mapMove = transport.sent[#transport.sent]
eq(mapMove.type, "move", "local map change is a move, never a second join")
eq(mapMove.mapId, "VIRIDIAN_CITY", "map move carries the new map")
eq(mapMove.seq, 2, "map move advances the sequence")

transport:push({ type = "player_moved", playerId = "blue",
  mapId = "PALLET_TOWN", x = 8, y = 8, px = 128, py = 128,
  facing = "right", moving = false, seq = 2 })
client:update()
eq(client:player("blue").name, "BLUE",
   "movement deltas do not erase the remote trainer name")

transport:push({ type = "challenge_received", challengeId = "c1",
                 fromPlayerId = "blue" })
client:update()
local app = client:pollEvents()
eq(#app, 1, "non-presence messages remain in application inbox")
eq(app[1].type, "challenge_received", "challenge is not consumed by presence")

transport:push({ type = "player_moved", player = {
  playerId = "blue", name = "BLUE", mapId = "VIRIDIAN_CITY",
  x = 2, y = 3, facing = "up", moving = false,
} })
client:update()
eq(#ow.removed, 1, "changing maps removes the old runtime NPC")
eq(#ow.added, 2, "changing maps respawns the NPC on its new map")
eq(ow.added[2].mapId, "VIRIDIAN_CITY", "new runtime NPC belongs to new map")

transport:push({ type = "player_left", playerId = "blue" })
client:update()
check(client:player("blue") == nil, "leave removes remote player state")
eq(#ow.removed, 2, "leave removes runtime NPC")

local presence = client:pollPresenceEvents()
check(#presence >= 3, "presence events are separately observable")
client:close()
check(transport.closed, "closing world client closes persistent transport")

T.finish()
