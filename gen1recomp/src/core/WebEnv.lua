-- Command-line environment injection, for hosts with no process environment.
--
-- The engine is configured throughout by environment variables read with
-- os.getenv: POKEPORT_MMO_ADDR picks the MMO service (src/core/Game.lua),
-- POKEPORT_IDENTITY picks the save folder (conf.lua), POKEPORT_MMO_DEFAULTS
-- selects the launcher presentation preset (src/core/SaveData.lua), and a
-- dozen more.  scripts/run-client.sh exports them before launching LOVE.
--
-- A browser has no process environment to export into: os.getenv always
-- returns nil under Emscripten.  What love.js *can* pass through is the
-- argument vector (Module.arguments -> LOVE's `arg`), which is verified to
-- arrive intact.  So the web launcher passes `--env NAME=VALUE` pairs and
-- this module folds them into os.getenv itself.
--
-- Doing it at the os.getenv layer rather than at each call site is deliberate:
-- every existing reader keeps working untouched, on every platform, and the
-- desktop scripts stay the source of truth for what the knobs are called.
-- Real process environment still wins nothing/loses nothing -- injected values
-- take precedence, and anything not injected falls through to the real
-- os.getenv, so a desktop run with no --env flags behaves exactly as before.

local WebEnv = {}

local overrides = {}
local realGetenv = nil

-- Accepts both `--env NAME=VALUE` (two argv slots) and `--env=NAME=VALUE`.
-- Values may contain '=' (a ws:// URL with a query string), so only the
-- first '=' after the name separates key from value.
function WebEnv.parse(argv)
  local found = {}
  if type(argv) ~= "table" then return found end
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local pair = nil
    if type(a) == "string" then
      pair = a:match("^%-%-env=(.+)$")
      if not pair and a == "--env" then
        pair = argv[i + 1]
        i = i + 1
      end
    end
    if type(pair) == "string" then
      local key, value = pair:match("^([%a_][%w_]*)=(.*)$")
      if key then found[key] = value end
    end
    i = i + 1
  end
  return found
end

-- Idempotent: safe to call from conf.lua and again from main.lua, and safe
-- to call repeatedly in tests.  Later calls merge additional pairs rather
-- than stacking another wrapper around os.getenv.
function WebEnv.install(argv)
  local found = WebEnv.parse(argv)
  local count = 0
  for key, value in pairs(found) do
    overrides[key] = value
    count = count + 1
  end
  if not realGetenv then
    realGetenv = os.getenv
    os.getenv = function(name)
      local injected = overrides[name]
      if injected ~= nil then return injected end
      return realGetenv(name)
    end
  end
  return count
end

function WebEnv.get(name)
  return overrides[name]
end

-- Tests restore the pristine os.getenv between cases.
function WebEnv._resetForTests()
  if realGetenv then os.getenv = realGetenv end
  realGetenv = nil
  overrides = {}
end

return WebEnv
