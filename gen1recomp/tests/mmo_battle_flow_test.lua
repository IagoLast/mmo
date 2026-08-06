-- Headless contract tests for the MMO challenge/handshake adapter.
-- Runs without ROM data: luajit tests/mmo_battle_flow_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(value, message)
  if value then print("ok   " .. message) else
    failures = failures + 1
    print("FAIL " .. message)
  end
end

local fakeHandshake = {}
function fakeHandshake.hello(game, mode)
  return { type = "hello", protocol = 2, name = game.save.player.name,
           mode = mode, fingerprint = "same" }
end
function fakeHandshake.checkCompat(a, b)
  return a.fingerprint == b.fingerprint and "full" or "subset"
end
function fakeHandshake.battleAllowed(verdict) return verdict == "full" end
function fakeHandshake.strict(verdict) return verdict == "full" end

local fakeProtocol = {}
function fakeProtocol.packParty(party)
  local out = {}
  for i, mon in ipairs(party) do out[i] = { species = mon.species } end
  return out
end

local starts = {}
local fakeLinkBattle = {}
local function start(role, game, net, opts)
  local battle = { role = role, opts = opts, net = net }
  starts[#starts + 1] = battle
  return battle
end
function fakeLinkBattle.newHost(game, net, opts) return start("host", game, net, opts) end
function fakeLinkBattle.newGuest(game, net, opts) return start("guest", game, net, opts) end

package.loaded["src.link.Handshake"] = fakeHandshake
package.loaded["src.link.Protocol"] = fakeProtocol
package.loaded["src.link.LinkBattle"] = fakeLinkBattle
package.loaded["src.mmo.ChallengePrompt"] = { new = function() return {} end }

local BattleNet = require("src.mmo.BattleNet")
local BattleFlow = require("src.mmo.BattleFlow")

local function worldPair()
  local a, b = { inbox = {}, sent = {} }, { inbox = {}, sent = {} }
  function a:send(message)
    self.sent[#self.sent + 1] = message
    b.inbox[#b.inbox + 1] = message
  end
  function b:send(message)
    self.sent[#self.sent + 1] = message
    a.inbox[#a.inbox + 1] = message
  end
  function a:update() self.updates = (self.updates or 0) + 1 end
  function b:update() self.updates = (self.updates or 0) + 1 end
  function a:pollEvents() local value = self.inbox self.inbox = {} return value end
  function b:pollEvents() local value = self.inbox self.inbox = {} return value end
  return a, b
end

local worldA, worldB = worldPair()
local netA = BattleNet.new(worldA, "battle-1")
netA:send({ type = "action", kind = "move", slot = 1 })
local envelope = worldB.inbox[1]
check(envelope.type == "battle_message" and envelope.battleId == "battle-1",
      "BattleNet wraps link traffic with its battle id")
check(envelope.payload.type == "action", "BattleNet preserves the link payload")
check(not netA:ingest({ type = "battle_message", battleId = "other", payload = {} }),
      "BattleNet rejects traffic for another battle")
check(netA:ingest({ type = "battle_message", battleId = "battle-1",
                    payload = { type = "hash", turn = 1 } }),
      "BattleNet accepts traffic for its battle")
check(netA:poll()[1].type == "hash", "BattleNet exposes inner messages to LinkBattle")
netA:close()
check(not worldA.closed, "closing a virtual battle leaves the world connection open")

worldA, worldB = worldPair()
local function game(name, species)
  local stack = { states = {} }
  function stack:push(state) self.states[#self.states + 1] = state end
  return { save = { player = { name = name }, party = { { species = species } } },
           stack = stack }
end
local gameA, gameB = game("RED", "CHARIZARD"), game("BLUE", "BLASTOISE")
local flowA = BattleFlow.new(gameA, worldA, {
  linkBattle = fakeLinkBattle, autoPrompt = false, autoPushBattle = true,
})
local flowB = BattleFlow.new(gameB, worldB, {
  linkBattle = fakeLinkBattle, autoPrompt = false, autoPushBattle = true,
})

flowA:challenge("player-blue")
check(worldA.sent[1].type == "challenge" and worldA.sent[1].targetId == "player-blue",
      "challenge sends the minimal target-id request")
flowB:handleMessage({ type = "challenge_received", challengeId = "challenge-1",
                      from = { id = "player-red", name = "RED" } })
flowB:reply("challenge-1", true)
check(worldB.sent[#worldB.sent].type == "challenge_reply"
      and worldB.sent[#worldB.sent].accept == true,
      "incoming challenge can be accepted")

-- The server starts both peers with one authoritative seed. Hello and party
-- then travel as inner link messages through the persistent connection.
flowA:handleMessage({ type = "battle_start", battleId = "battle-2", role = "host",
                      opponent = { id = "player-blue", name = "BLUE" }, seed = 4242 })
flowB:handleMessage({ type = "battle_start", battleId = "battle-2", role = "guest",
                      opponent = { id = "player-red", name = "RED" }, seed = 4242 })

for _ = 1, 3 do flowA:update(); flowB:update() end

check(flowA.stage == "battleRunning" and flowB.stage == "battleRunning",
      "matching handshakes and parties start both battles")
check(#starts == 2 and starts[1].opts.seed == 4242 and starts[2].opts.seed == 4242,
      "both LinkBattle instances use the server seed")
local byRole = {}
for _, battle in ipairs(starts) do byRole[battle.role] = battle end
check(byRole.host.opts.theirParty[1].species == "BLASTOISE"
      and byRole.guest.opts.theirParty[1].species == "CHARIZARD",
      "party exchange reaches the opposite LinkBattle perspective")
check(gameA.stack.states[1] == flowA.activeBattle
      and gameB.stack.states[1] == flowB.activeBattle,
      "negotiated LinkBattle is pushed on each game stack")

local battleId = flowA.battleId
flowA.activeBattle.onFinish("win")
local ended = worldA.sent[#worldA.sent]
check(ended.type == "battle_end" and ended.battleId == battleId
      and ended.result == nil, "battle completion returns to the MMO server")
check(flowA.stage == "idle", "finished battle returns the flow to idle")

if failures > 0 then os.exit(1) end
print("all MMO battle flow tests passed")
