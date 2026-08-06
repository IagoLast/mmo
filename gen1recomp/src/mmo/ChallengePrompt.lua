-- Minimal incoming-challenge UI. Kept as a factory so the overworld router
-- does not need to know TextBox/ChoiceBox details.

local Strings = require("src.core.Strings")
local TextBox = require("src.render.TextBox")

local ChallengePrompt = {}

function ChallengePrompt.new(game, challenge, reply)
  local from = challenge.from
  local name = type(from) == "table" and (from.name or from.nickname)
    or type(from) == "string" and from
    or challenge.fromName or "TRAINER"
  return TextBox.new(game,
    Strings("%s challenges\nyou. Battle?", tostring(name):sub(1, 16)), nil, {
      defaultNo = true,
      choice = function(accepted)
        reply(accepted == true)
      end,
    })
end

return ChallengePrompt
