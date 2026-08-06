-- Net-compatible view of one battle multiplexed over the persistent MMO
-- connection. LinkBattle sees ordinary link messages while the world server
-- sees { type="battle_message", battleId=..., payload=... } envelopes.

local BattleNet = {}
BattleNet.__index = BattleNet

function BattleNet.new(worldClient, battleId)
  assert(worldClient and worldClient.send, "BattleNet needs a world client")
  assert(battleId ~= nil, "BattleNet needs a battle id")
  return setmetatable({
    worldClient = worldClient,
    battleId = battleId,
    inbox = {},
    closed = false,
    error = nil,
    paired = true,
    mode = "mmoBattle",
  }, BattleNet)
end

function BattleNet:send(payload)
  if self.closed then return false end
  self.worldClient:send({
    type = "battle_message",
    battleId = self.battleId,
    payload = payload,
  })
  return true
end

-- Called by the persistent world's application-message router. Returns true
-- when the envelope belongs to this battle and was consumed.
function BattleNet:ingest(message)
  if self.closed or not message or message.type ~= "battle_message"
     or message.battleId ~= self.battleId then
    return false
  end
  if type(message.payload) == "table" then
    self.inbox[#self.inbox + 1] = message.payload
  end
  return true
end

function BattleNet:poll()
  local messages = self.inbox
  self.inbox = {}
  return messages
end

-- Game owns the persistent connection pump even while battle/party states
-- are on top. Do not poll it here: BattleFlow is the sole application-inbox
-- consumer and routes envelopes into this adapter on the next frame.
function BattleNet:update()
  if self.closed then return end
  if self.worldClient.error then
    self.error = self.worldClient.error
  elseif self.worldClient.transport and self.worldClient.transport.error then
    self.error = self.worldClient.transport.error
  end
  if self.worldClient.closed then self.closed = true end
end

-- Closing a virtual battle must never close the shared world socket.
function BattleNet:close()
  self.closed = true
  self.inbox = {}
end

function BattleNet:markEnded(reason)
  self.endReason = reason
  self.closed = true
end

return BattleNet
