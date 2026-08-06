-- Contract for the argv -> os.getenv bridge the browser build needs, since
-- Emscripten has no process environment to export POKEPORT_* into.
-- Needs no ROM and no love:  luajit tests/core_webenv_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
local WebEnv = require("src.core.WebEnv")

-- The pristine os.getenv, captured before anything can wrap it, so the
-- _resetForTests cases can assert restoration by identity rather than by
-- behaviour.
local pristine = os.getenv

local function reset()
  WebEnv._resetForTests()
end

-- --------------------------------------------------------------- parse only
-- parse() is pure, so the spellings can be pinned without touching os.getenv.
do
  local found = WebEnv.parse({ "--env", "POKEPORT_MMO_ADDR=127.0.0.1:4000" })
  eq(found.POKEPORT_MMO_ADDR, "127.0.0.1:4000",
     "`--env NAME=VALUE` spelling (two argv slots)")

  found = WebEnv.parse({ "--env=POKEPORT_IDENTITY=red" })
  eq(found.POKEPORT_IDENTITY, "red", "`--env=NAME=VALUE` spelling (one argv slot)")

  -- A ws:// endpoint with a query string is the case that actually shows up
  -- in the browser launcher, and it has three '=' in it.
  local url = "ws://play.example.com:8080/socket?token=abc&mode=world"
  found = WebEnv.parse({ "--env", "POKEPORT_MMO_ADDR=" .. url })
  eq(found.POKEPORT_MMO_ADDR, url, "only the first '=' after the name splits the pair")
  found = WebEnv.parse({ "--env=POKEPORT_MMO_ADDR=" .. url })
  eq(found.POKEPORT_MMO_ADDR, url, "the `--env=` spelling keeps '=' in the value too")

  -- LOVE hands over the whole argv, game path and flags included.
  found = WebEnv.parse({
    "love", "game.love", "--console",
    "--env", "POKEPORT_MMO_ADDR=1.2.3.4:9",
    "--fused",
    "--env=POKEPORT_IDENTITY=blue",
    "--env", "POKEPORT_MMO_DEFAULTS=web",
    "trailing",
  })
  eq(found.POKEPORT_MMO_ADDR, "1.2.3.4:9", "pairs survive unrelated argv before them")
  eq(found.POKEPORT_IDENTITY, "blue", "both spellings can be interleaved")
  eq(found.POKEPORT_MMO_DEFAULTS, "web", "pairs survive unrelated argv between them")

  -- The value of a two-slot pair must not be re-read as a flag of its own.
  found = WebEnv.parse({ "--env", "A=1", "--env", "B=2" })
  eq(found.A, "1", "consecutive two-slot pairs both land")
  eq(found.B, "2", "the consumed value slot is skipped, not re-scanned")

  found = WebEnv.parse({ "--env", "POKEPORT_EMPTY=" })
  eq(found.POKEPORT_EMPTY, "", "an empty value is a value, not a missing pair")

  found = WebEnv.parse({ "--env", "not-a-pair", "--env", "9BAD=x", "--env" })
  check(next(found) == nil, "malformed pairs and a trailing bare --env are ignored")

  check(next(WebEnv.parse(nil)) == nil, "parse(nil) yields nothing rather than raising")
  check(next(WebEnv.parse("--env A=1")) == nil, "parse of a non-table yields nothing")
end

-- ------------------------------------------------------------- install/getenv
reset()
do
  local count = WebEnv.install({ "--env", "POKEPORT_MMO_ADDR=10.0.0.1:4000",
                                 "--env=POKEPORT_IDENTITY=red" })
  eq(count, 2, "install reports how many pairs it folded in")
  eq(os.getenv("POKEPORT_MMO_ADDR"), "10.0.0.1:4000",
     "an injected name is readable through the ordinary os.getenv")
  eq(os.getenv("POKEPORT_IDENTITY"), "red", "every injected name is readable")
  eq(WebEnv.get("POKEPORT_IDENTITY"), "red", "WebEnv.get exposes the injected value")
  check(WebEnv.get("POKEPORT_NOT_INJECTED") == nil,
        "WebEnv.get is nil for a name that was never injected")

  -- Fall-through: anything not injected must still reach the real environment,
  -- so a desktop run with no --env flags behaves exactly as before.
  eq(os.getenv("PATH"), pristine("PATH"),
     "a non-injected name falls through to the real os.getenv")
  check(os.getenv("POKEPORT_DEFINITELY_UNSET_XYZ") == nil,
        "a name that is neither injected nor in the environment is nil")
end

-- ----------------------------------------------------------- idempotent install
do
  local wrapper = os.getenv
  local count = WebEnv.install({ "--env", "POKEPORT_MMO_DEFAULTS=web" })
  eq(count, 1, "a second install reports only its own pairs")
  check(os.getenv == wrapper,
        "a second install merges rather than stacking another os.getenv wrapper")
  eq(os.getenv("POKEPORT_MMO_DEFAULTS"), "web", "the second install's pairs are live")
  eq(os.getenv("POKEPORT_MMO_ADDR"), "10.0.0.1:4000",
     "the first install's pairs survive the second")
  eq(os.getenv("PATH"), pristine("PATH"),
     "fall-through still reaches the real environment after a double install")

  -- conf.lua and main.lua both call install; the later one must win on a
  -- name they disagree about rather than being ignored.
  WebEnv.install({ "--env", "POKEPORT_MMO_ADDR=127.0.0.1:9999" })
  eq(os.getenv("POKEPORT_MMO_ADDR"), "127.0.0.1:9999",
     "a later install overrides an earlier value for the same name")

  -- Installing nothing must not wrap os.getenv a second time either.
  WebEnv.install({ "love", "game.love" })
  check(os.getenv == wrapper, "installing an argv with no pairs leaves the wrapper alone")
end

-- --------------------------------------------------------------- reset
do
  WebEnv._resetForTests()
  check(os.getenv == pristine, "_resetForTests restores the pristine os.getenv")
  check(os.getenv("POKEPORT_MMO_ADDR") == nil,
        "_resetForTests drops the injected values")
  check(WebEnv.get("POKEPORT_MMO_ADDR") == nil, "_resetForTests clears WebEnv.get too")
  eq(os.getenv("PATH"), pristine("PATH"), "the real environment is untouched by a reset")

  -- Reset must be safe when nothing was installed, and re-installable after.
  WebEnv._resetForTests()
  check(os.getenv == pristine, "a second _resetForTests is a no-op, not a crash")
  WebEnv.install({ "--env", "POKEPORT_IDENTITY=green" })
  eq(os.getenv("POKEPORT_IDENTITY"), "green", "install works again after a reset")
  check(os.getenv ~= pristine, "install re-wraps os.getenv after a reset")
  WebEnv._resetForTests()
  check(os.getenv == pristine, "the suite leaves os.getenv as it found it")
end

T.finish("WebEnv")
