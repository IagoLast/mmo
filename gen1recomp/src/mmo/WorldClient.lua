-- MMO world presence client.  Owns only login-free presence and leaves every
-- challenge/battle message untouched in applicationInbox for the next layer.

local FieldDefaults = require("src.world.FieldDefaults")
local Logger = require("src.core.Logger")
local Transport = require("src.mmo.Transport")

local WorldClient = {}
WorldClient.__index = WorldClient

local PRESENCE = {
  welcome = true, snapshot = true, world_snapshot = true,
  player_joined = true, player_moved = true, player_left = true,
}

local function validFacing(facing)
  return facing == "up" or facing == "down" or facing == "left" or facing == "right"
end

local function overworld(game)
  local states = game.stack and game.stack.states or {}
  for i = #states, 1, -1 do
    if states[i] and states[i].isOverworld then return states[i] end
  end
  local ow = game.overworld
  if ow and ow.isOverworld and ow.map and ow.player then return ow end
end

local function playerId(player)
  return player and (player.playerId or player.id)
end

local function copyPlayer(player)
  local id = playerId(player)
  if not id then return nil end
  return {
    playerId = tostring(id),
    name = player.name and tostring(player.name) or nil,
    mapId = player.mapId, x = tonumber(player.x) or 0, y = tonumber(player.y) or 0,
    px = tonumber(player.px), py = tonumber(player.py),
    facing = validFacing(player.facing) and player.facing or "down",
    moving = player.moving == true,
  }
end

function WorldClient.new(game, opts)
  opts = opts or {}
  return setmetatable({
    game = game, address = opts.address,
    transport = opts.transport or Transport.new(opts.transportOptions),
    players = {}, applicationInbox = {}, presenceInbox = {}, listeners = {},
    selfId = nil, joined = false, joinedName = nil, joinedMap = nil,
    sequence = 0, lastSent = nil, closed = false,
  }, WorldClient)
end

function WorldClient:connect()
  if not self.address or self.address == "" then return false end
  local ok = self.transport:connect(self.address)
  if not ok then
    Logger.warn("MMO: unable to connect to %s (%s)", self.address,
                tostring(self.transport.error))
  end
  return ok
end

-- Public application channel used by challenge/battle modules.
function WorldClient:send(message)
  return self.transport:send(message)
end

function WorldClient:pollEvents()
  local events = self.applicationInbox
  self.applicationInbox = {}
  return events
end

function WorldClient:pollPresenceEvents()
  local events = self.presenceInbox
  self.presenceInbox = {}
  return events
end

function WorldClient:on(eventType, callback)
  self.listeners[eventType] = self.listeners[eventType] or {}
  self.listeners[eventType][#self.listeners[eventType] + 1] = callback
  return callback
end

function WorldClient:_emit(message)
  self.presenceInbox[#self.presenceInbox + 1] = message
  for _, callback in ipairs(self.listeners[message.type] or {}) do
    pcall(callback, message)
  end
end

function WorldClient:_dropEntity(remote)
  if remote and remote.npcId then
    local ow = overworld(self.game)
    if ow and ow.removeRuntimeObject then
      ow:removeRuntimeObject(remote.npcId, "mmo")
    end
    remote.npcId, remote.entity = nil, nil
  end
end

function WorldClient:_dropPlayer(id)
  id = id and tostring(id)
  local remote = id and self.players[id]
  if remote then self:_dropEntity(remote) self.players[id] = nil end
end

function WorldClient:_upsert(raw)
  local incoming = copyPlayer(raw)
  if not incoming or incoming.playerId == self.selfId then return end
  local old = self.players[incoming.playerId]
  if old and old.mapId ~= incoming.mapId then self:_dropEntity(old) end
  if old then
    for key, value in pairs(incoming) do old[key] = value end
    return old
  end
  incoming.name = incoming.name or "TRAINER"
  self.players[incoming.playerId] = incoming
  return incoming
end

function WorldClient:_snapshot(players)
  local seen = {}
  for _, raw in ipairs(players or {}) do
    local remote = self:_upsert(raw)
    if remote then seen[remote.playerId] = true end
  end
  for id in pairs(self.players) do
    if not seen[id] then self:_dropPlayer(id) end
  end
end

function WorldClient:_handle(message)
  local kind = message.type
  if kind == "welcome" then
    self.selfId = message.playerId and tostring(message.playerId) or self.selfId
  elseif kind == "world_snapshot" then
    self.selfId = message.selfId and tostring(message.selfId) or self.selfId
    self:_snapshot(message.players)
  elseif kind == "snapshot" then
    self:_snapshot(message.players)
  elseif kind == "player_joined" or kind == "player_moved" then
    self:_upsert(message.player or message)
  elseif kind == "player_left" then
    self:_dropPlayer(message.playerId or message.id)
  else
    -- Deliberately do not consume challenge/battle/error messages here.
    self.applicationInbox[#self.applicationInbox + 1] = message
    return
  end
  self:_emit(message)
end

local function localState(ow)
  local p = ow.player
  return {
    mapId = ow.map.id, x = p.cellX, y = p.cellY,
    px = math.floor((p.px or p.cellX * 16) + 0.5),
    py = math.floor((p.py or p.cellY * 16) + 0.5),
    facing = validFacing(p.facing) and p.facing or "down",
    moving = p.moving == true,
  }
end

local function signature(state)
  return table.concat({ state.mapId, state.x, state.y, state.px, state.py,
                        state.facing, state.moving and "1" or "0" }, "|")
end

function WorldClient:_publishLocal(ow)
  local state = localState(ow)
  local save = self.game.save
  local name = tostring(save and save.player and save.player.name or "RED")
  if not self.joined then
    local join = { type = "join_world", name = name }
    for key, value in pairs(state) do join[key] = value end
    self:send(join)
    self.joined, self.joinedName, self.joinedMap = true, name, state.mapId
    self.lastSent = signature(state)
    return
  end
  local current = signature(state)
  if current ~= self.lastSent then
    self.sequence = self.sequence + 1
    local move = { type = "move", seq = self.sequence }
    for key, value in pairs(state) do move[key] = value end
    self:send(move)
    self.lastSent = current
    self.joinedMap = state.mapId
  end
end

function WorldClient:_spawn(remote, ow)
  if not remote.mapId or not self.game.data.maps[remote.mapId] then return end
  local walk = FieldDefaults.fieldValue(self.game.data, "playerSprites", "walk")
  local npcId = ow:addRuntimeObject(remote.mapId, {
    x = remote.x, y = remote.y, sprite = walk,
    movement = "STAY", range = string.upper(remote.facing),
    mmoPlayerId = remote.playerId, mmoPlayerName = remote.name,
  }, "mmo")
  remote.npcId = npcId
end

function WorldClient:_syncEntities(ow)
  for id, remote in pairs(self.players) do
    if id == self.selfId then
      self:_dropPlayer(id)
    else
      if not remote.npcId then self:_spawn(remote, ow) end
      local entity = remote.npcId and ow.npcPool and ow.npcPool[remote.npcId]
      remote.entity = entity
      if entity then
        entity.remoteControlled = true
        entity.passable = true
        entity.remotePlayerId = id
        entity.remotePlayerName = remote.name
        entity.cellX, entity.cellY = remote.x, remote.y
        entity.px = remote.px or remote.x * 16
        entity.py = remote.py or remote.y * 16
        entity.facing = remote.facing
        entity.moving = remote.moving
        entity.progress = remote.moving and ((entity.progress or 0) + 1) % 16 or 0
        entity.targetX, entity.targetY = nil, nil
      end
    end
  end
end

function WorldClient:player(id)
  return id and self.players[tostring(id)] or nil
end

function WorldClient:remoteEntity(id)
  local remote = self:player(id)
  return remote and remote.entity or nil
end

function WorldClient:update()
  if self.closed then return end
  self.transport:update()
  if self.transport.closed then
    self.closed = true
    return
  end
  for _, message in ipairs(self.transport:poll()) do
    if type(message) == "table" and PRESENCE[message.type] then
      self:_handle(message)
    else
      self.applicationInbox[#self.applicationInbox + 1] = message
    end
  end
  local ow = overworld(self.game)
  if ow and ow.map and ow.player and self.transport.connected then
    -- NEW GAME creates the overworld underneath Oak's naming screen.  Wait
    -- until it is actually topmost before the one allowed join_world, so the
    -- chosen save name (rather than the temporary RED default) is published.
    local states = self.game.stack and self.game.stack.states or {}
    if self.joined or states[#states] == ow then self:_publishLocal(ow) end
    self:_syncEntities(ow)
  end
end

function WorldClient:close()
  for id in pairs(self.players) do self:_dropPlayer(id) end
  self.transport:close()
  self.closed = true
end

return WorldClient
