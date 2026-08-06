-- Contract for the LOVE 11.4 -> 11.5 love.filesystem backport.
--
-- The bug this guards: love.js is built on LOVE 11.4, where a read of a
-- missing file RAISES, while the engine's call sites are written against
-- 11.5, where it returns `nil, message`.  RomImporter.isReady asking "has a
-- ROM been imported yet?" on a first boot is a legitimate miss, and under
-- 11.4 that killed the app before the launcher existed.
--
-- Every case builds its own throwaway `love` table, so a case that wraps a
-- filesystem cannot leak wrapped functions into the next one.  Runs with no
-- ROM and no real love:  luajit tests/core_lovecompat_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
local LoveCompat = require("src.core.LoveCompat")

local WRAPPED = { "read", "write", "append", "lines", "newFileData" }

-- A love.filesystem whose functions behave like 11.4: a miss raises rather
-- than returning nil.  Every function returns two values on success so the
-- "does the wrapper drop the second return?" question is answerable.
local function fakeFilesystem()
  local fs = {}

  fs.read = function(name)
    if name == "missing.txt" then
      error("Could not open file missing.txt. Does not exist.", 0)
    end
    return "CONTENTS/" .. tostring(name), 42
  end

  fs.write = function(name, data)
    if name == "readonly.txt" then error("Could not write to file readonly.txt.", 0) end
    -- 11.4 also has a non-raising failure mode, and `false` is a legitimate
    -- first return value the wrapper must not turn into nil.
    if name == "full.txt" then return false, "disk full" end
    return true, tostring(data)
  end

  fs.append = function(name)
    if name == "missing.txt" then error("Could not open file missing.txt.", 0) end
    return true, "appended"
  end

  fs.lines = function(name)
    if name == "missing.txt" then error("Could not open file missing.txt.", 0) end
    local i = 0
    return function() i = i + 1 return ({ "one", "two" })[i] end, "iterator-extra"
  end

  fs.newFileData = function(name)
    if name == "missing.txt" then error("Could not open file missing.txt.", 0) end
    -- A non-string error object exercises the wrapper's tostring().
    if name == "weird.txt" then error({ code = 7 }, 0) end
    return { _fileData = true, name = name }, "filedata-extra"
  end

  -- Not in WRAPPED: must survive install untouched.
  fs.getInfo = function(name) return name ~= "missing.txt" and {} or nil end

  return fs
end

local function fakeLove(major, minor)
  return { _version_major = major, _version_minor = minor,
           _version = major .. "." .. minor .. ".0",
           filesystem = fakeFilesystem() }
end

-- Each case gets a clean module state and its own global love.
local function fresh(major, minor)
  LoveCompat._resetForTests()
  love = fakeLove(major, minor)
  local originals = {}
  for _, name in ipairs(WRAPPED) do originals[name] = love.filesystem[name] end
  originals.getInfo = love.filesystem.getInfo
  return originals
end

-- ------------------------------------------------- needsFilesystemShim
do
  local needs = LoveCompat.needsFilesystemShim

  -- The version that actually matters: love.js.
  check(needs(11, 4), "11.4 (love.js) needs the shim")
  check(needs(11, 0), "11.0 needs the shim")
  check(needs(11, 1), "11.1 needs the shim")
  check(needs(10, 5), "10.5 needs the shim -- a lower major wins over the minor")
  check(needs(0, 0), "0.0 needs the shim")
  check(needs(9, 99), "9.99 needs the shim despite a high minor")

  check(not needs(11, 5), "11.5 is the target contract and needs nothing")
  check(not needs(11, 6), "11.6 needs nothing")
  check(not needs(11, 50), "11.50 needs nothing (minor compares numerically)")
  check(not needs(12, 0), "12.0 needs nothing -- a higher major short-circuits")
  check(not needs(12, 4), "12.4 needs nothing even though its minor is below 5")
  check(not needs(13, 0), "13.0 needs nothing")

  -- Numeric strings are what a version table could plausibly hold.
  check(needs("11", "4"), "string version components are coerced (11.4)")
  check(not needs("11", "5"), "string version components are coerced (11.5)")

  -- Unknown version => assume the old contract.  Wrapping a host that did not
  -- need it is harmless; not wrapping one that did is a fatal boot error.
  check(needs(nil, nil), "an unknown version is treated as needing the shim")
  check(needs(), "no arguments at all is treated as needing the shim")
  check(needs("garbage", "nonsense"), "unparseable version components need the shim")
  check(needs({}, {}), "table version components need the shim")
  check(needs(11, nil), "a known major with an unknown minor needs the shim")
  check(needs(11), "11 with no minor needs the shim")
  check(not needs(12, nil), "12 with an unknown minor still needs nothing")
end

-- ------------------------------------------------------------ 11.4: wrapping
do
  local originals = fresh(11, 4)
  local count = LoveCompat.install()
  eq(count, 5, "install wraps every affected function on 11.4")
  for _, name in ipairs(WRAPPED) do
    check(love.filesystem[name] ~= originals[name], "install wraps love.filesystem." .. name)
    eq(type(love.filesystem[name]), "function", "the wrapped " .. name .. " is still a function")
  end
  check(love.filesystem.getInfo == originals.getInfo,
        "install leaves functions outside its list alone")

  -- The regression itself: the missing marker file must be a nil return.
  local contents, message = love.filesystem.read("missing.txt")
  check(contents == nil, "a raised read becomes a nil first return, not an error")
  check(type(message) == "string"
        and message:find("Does not exist", 1, true) ~= nil,
        "the raised message is handed back as the second return (got: "
        .. tostring(message) .. ")")

  -- ...and success must keep BOTH values.  read returns contents AND size;
  -- a wrapper that forwarded only the first would silently break every
  -- caller that uses the size.
  local data, size = love.filesystem.read("rom.gb")
  eq(data, "CONTENTS/rom.gb", "a successful read passes the contents through")
  eq(size, 42, "a successful read passes the SIZE through as the second value")

  local okWrite, extra = love.filesystem.write("save.dat", "payload")
  eq(okWrite, true, "a successful write passes its first return through")
  eq(extra, "payload", "a successful write passes its second return through")

  local failed, why = love.filesystem.write("readonly.txt", "x")
  check(failed == nil, "a raised write becomes nil")
  check(type(why) == "string" and why:find("readonly.txt", 1, true) ~= nil,
        "a raised write reports its reason")

  -- `false` is a real success-path value for write; the wrapper checks
  -- pcall's ok flag, not the truthiness of the result, so it must survive.
  local falsy, reason = love.filesystem.write("full.txt", "x")
  eq(falsy, false, "a legitimate `false` return is NOT converted to nil")
  eq(reason, "disk full", "a legitimate false return keeps its message")

  local appended, note = love.filesystem.append("log.txt", "line")
  eq(appended, true, "a successful append passes its first return through")
  eq(note, "appended", "a successful append passes its second return through")
  check(love.filesystem.append("missing.txt") == nil, "a raised append becomes nil")

  local iter, iterExtra = love.filesystem.lines("data.txt")
  eq(type(iter), "function", "a successful lines still hands back an iterator")
  eq(iter(), "one", "the iterator from a wrapped lines still works")
  eq(iter(), "two", "the iterator keeps its own state across calls")
  eq(iterExtra, "iterator-extra", "lines passes its second return through")
  local noIter, linesWhy = love.filesystem.lines("missing.txt")
  check(noIter == nil, "a raised lines becomes nil")
  check(type(linesWhy) == "string", "a raised lines reports a string reason")

  local fileData, fdExtra = love.filesystem.newFileData("rom.gb")
  check(type(fileData) == "table" and fileData._fileData,
        "a successful newFileData passes the object through")
  eq(fdExtra, "filedata-extra", "newFileData passes its second return through")
  check(love.filesystem.newFileData("missing.txt") == nil,
        "a raised newFileData becomes nil")

  -- A non-string error object must not leak out as a table where callers
  -- expect a message.
  local none, weird = love.filesystem.newFileData("weird.txt")
  check(none == nil, "a non-string raise still becomes nil")
  eq(type(weird), "string", "a non-string raise is tostring'd into a message")
end

-- --------------------------------------------------------- 11.5+: no wrapping
for _, version in ipairs({ { 11, 5 }, { 11, 6 }, { 12, 0 } }) do
  local label = version[1] .. "." .. version[2]
  local originals = fresh(version[1], version[2])
  eq(LoveCompat.install(), 0, "install wraps nothing on " .. label)
  local untouched = true
  for _, name in ipairs(WRAPPED) do
    if love.filesystem[name] ~= originals[name] then untouched = false end
  end
  check(untouched, "every original function identity is preserved on " .. label)

  -- And the native contract is left to speak for itself: a raise stays a
  -- raise, because on these hosts LOVE itself returns nil instead.
  local ok = pcall(love.filesystem.read, "missing.txt")
  check(not ok, "on " .. label .. " the unwrapped function is called directly")
end

-- ----------------------------------------------------------------- idempotence
do
  fresh(11, 4)
  eq(LoveCompat.install(), 5, "the first install on 11.4 wraps five functions")
  local afterFirst = {}
  for _, name in ipairs(WRAPPED) do afterFirst[name] = love.filesystem[name] end

  eq(LoveCompat.install(), 0, "a second install reports nothing wrapped")
  local stable = true
  for _, name in ipairs(WRAPPED) do
    if love.filesystem[name] ~= afterFirst[name] then stable = false end
  end
  check(stable, "a second install does not re-wrap the already-wrapped functions")

  -- A double wrap would still behave correctly, so prove the guard by
  -- identity above and the behaviour here.
  local contents, message = love.filesystem.read("missing.txt")
  check(contents == nil and type(message) == "string",
        "the singly-wrapped read still converts a raise after a second install")
  eq(select(2, love.filesystem.read("rom.gb")), 42,
     "the second return survives a second install")
end

-- ------------------------------------------------------------------- no love
do
  LoveCompat._resetForTests()
  local realLove = love
  love = nil
  eq(LoveCompat.install(), 0, "install is a no-op with no love global")

  LoveCompat._resetForTests()
  love = { _version_major = 11, _version_minor = 4 }
  eq(LoveCompat.install(), 0, "install is a no-op with no love.filesystem")

  -- A host missing one of the five must not abort the other four.
  LoveCompat._resetForTests()
  love = fakeLove(11, 4)
  love.filesystem.append = nil
  love.filesystem.lines = "not a function"
  eq(LoveCompat.install(), 3, "install skips absent or non-function entries")
  check(love.filesystem.lines == "not a function",
        "a non-function entry is left exactly as it was")
  check(select(1, love.filesystem.read("missing.txt")) == nil,
        "the functions that were present are still wrapped")
  love = realLove
end

-- ---------------------------------------------------------------- reset
do
  -- _resetForTests clears the installed guard.  It does NOT unwrap, so a
  -- reset followed by an install on the SAME love table wraps a second time
  -- around the first wrapper.  Pinned because it is the behaviour the test
  -- suites have to work around (every case above builds a fresh love).
  fresh(11, 4)
  LoveCompat.install()
  local firstWrapper = love.filesystem.read
  LoveCompat._resetForTests()
  eq(LoveCompat.install(), 5, "install runs again after _resetForTests")
  check(love.filesystem.read ~= firstWrapper,
        "_resetForTests does NOT restore the originals, so install re-wraps (see NOTE)")

  -- The double wrap is at least behaviour-preserving.
  local contents, message = love.filesystem.read("missing.txt")
  check(contents == nil and type(message) == "string",
        "a double-wrapped read still converts a raise into nil + message")
  local data, size = love.filesystem.read("rom.gb")
  eq(data, "CONTENTS/rom.gb", "a double-wrapped read still passes contents through")
  eq(size, 42, "a double-wrapped read still passes the size through")
end

T.finish("LoveCompat")
