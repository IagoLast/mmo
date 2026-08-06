-- Challenge and battle negotiation over an already-connected MMO world.
-- The world client/router owns authentication, presence and reconnects.

local BattleNet = require("src.mmo.BattleNet")
local ChallengePrompt = require("src.mmo.ChallengePrompt")
local Handshake = require("src.link.Handshake")
local LinkBattle = require("src.link.LinkBattle")
local Protocol = require("src.link.Protocol")

local BattleFlow = {}
BattleFlow.__index = BattleFlow

local function playerName(player)
  if type(player) == "table" then return player.name or player.nickname end
  if type(player) == "string" then return player end
  return nil
end

function BattleFlow.new(game, worldClient, opts)
  opts = opts or {}
  return setmetatable({
    game = game,
    worldClient = worldClient,
    linkBattle = opts.linkBattle or LinkBattle,
    promptFactory = opts.promptFactory or ChallengePrompt,
    autoPrompt = opts.autoPrompt ~= false,
    autoPushBattle = opts.autoPushBattle ~= false,
    onError = opts.onError,
    onChallenge = opts.onChallenge,
    onBattleReady = opts.onBattleReady,
    onBattleEnded = opts.onBattleEnded,
    stage = "idle",
  }, BattleFlow)
end

function BattleFlow:challenge(targetId)
  assert(targetId ~= nil, "challenge needs a target id")
  self.worldClient:send({ type = "challenge", targetId = targetId })
  self.stage = "challengeSent"
end

function BattleFlow:reply(challengeId, accepted)
  self.worldClient:send({
    type = "challenge_reply",
    challengeId = challengeId,
    accept = accepted == true,
  })
  self.stage = accepted and "challengeAccepted" or "idle"
end

function BattleFlow:fail(reason)
  self.stage = "idle"
  self.error = reason
  if self.battleNet then self.battleNet:markEnded(reason) end
  if self.onError then self.onError(reason) end
end

function BattleFlow:receiveChallenge(message)
  self.incomingChallenge = message
  self.stage = "challengeReceived"
  if self.onChallenge then self.onChallenge(message) end
  if self.autoPrompt and self.game.stack then
    local prompt = self.promptFactory.new(self.game, message, function(accepted)
      self:reply(message.challengeId, accepted)
      self.incomingChallenge = nil
    end)
    self.game.stack:push(prompt)
  end
end

function BattleFlow:startNegotiation(message)
  if self.battleNet and not self.battleNet.closed then
    self:fail("another battle is already active")
    return
  end
  self.battleId = message.battleId
  self.role = message.role == "host" and "host" or "guest"
  self.opponent = message.opponent or {}
  self.seed = tonumber(message.seed)
  if not self.seed then
    self:fail("battle_start did not include a seed")
    return
  end
  self.battleNet = BattleNet.new(self.worldClient, self.battleId)
  self.myHello = Handshake.hello(self.game, self.role == "host" and "battle" or nil)
  self.peerHello = nil
  self.theirParty = nil
  self.partySent = false
  self.stage = "battleHello"
  self.battleNet:send(self.myHello)
end

function BattleFlow:sendParty()
  if self.partySent then return end
  self.partySent = true
  self.battleNet:send({
    type = "party",
    mons = Protocol.packParty(self.game.save.party),
  })
end

function BattleFlow:tryStartBattle()
  if not self.peerHello or not self.theirParty or self.activeBattle then return end
  local verdict = Handshake.checkCompat(self.myHello, self.peerHello)
  if not Handshake.battleAllowed(verdict) then
    self:fail("link version or mods do not match")
    return
  end
  local opts = {
    myParty = Protocol.packParty(self.game.save.party),
    theirParty = self.theirParty,
    theirName = playerName(self.opponent) or "FOE",
    role = self.role,
    seed = self.seed,
    verdict = verdict,
    strict = Handshake.strict(verdict),
    keepNetOpen = true,
  }
  local battle, why
  if self.role == "host" then
    battle, why = self.linkBattle.newHost(self.game, self.battleNet, opts)
  else
    battle, why = self.linkBattle.newGuest(self.game, self.battleNet, opts)
  end
  if not battle then self:fail(why or "battle could not start") return end
  self.activeBattle = battle
  self.stage = "battleRunning"
  battle.onFinish = function(result)
    self.worldClient:send({
      type = "battle_end",
      battleId = self.battleId,
    })
    self.stage = "idle"
    self.activeBattle = nil
    self.battleNet = nil
    if self.onBattleEnded then self.onBattleEnded(result) end
  end
  if self.onBattleReady then self.onBattleReady(battle, opts) end
  if self.autoPushBattle and self.game.stack then self.game.stack:push(battle) end
end

function BattleFlow:handleBattlePayload(payload)
  if self.stage == "battleRunning" then return false end
  if payload.type == "hello" and not self.peerHello then
    self.peerHello = payload
    local verdict = Handshake.checkCompat(self.myHello, self.peerHello)
    if not Handshake.battleAllowed(verdict) then
      self:fail("link version or mods do not match")
      return true
    end
    self:sendParty()
    self.stage = "battleParty"
  elseif payload.type == "party" then
    self.theirParty = payload.mons or {}
  else
    return false
  end
  self:tryStartBattle()
  return true
end

-- Application-message entry point used by WorldClient's router.
function BattleFlow:handleMessage(message)
  if not message then return false end
  if message.type == "challenge_received" then
    self:receiveChallenge(message)
    return true
  elseif message.type == "battle_start" then
    self:startNegotiation(message)
    return true
  elseif message.type == "battle_message" then
    if not self.battleNet or not self.battleNet:ingest(message) then return false end
    if self.stage ~= "battleRunning" then
      for _, payload in ipairs(self.battleNet:poll()) do
        if not self:handleBattlePayload(payload) then
          -- Preserve early action/hash packets for LinkBattle after party.
          self.battleNet.inbox[#self.battleNet.inbox + 1] = payload
        end
      end
    end
    return true
  elseif message.type == "battle_ended" and message.battleId == self.battleId then
    if self.battleNet then self.battleNet:markEnded(message.reason) end
    if self.stage ~= "battleRunning" then self.stage = "idle" end
    return true
  end
  return false
end

-- Sole consumer of WorldClient's application inbox. Game calls this after
-- WorldClient:update, independently of whichever state is on top.
function BattleFlow:update()
  for _, message in ipairs(self.worldClient:pollEvents()) do
    self:handleMessage(message)
  end
end

return BattleFlow
