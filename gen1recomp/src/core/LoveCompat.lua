-- Keeps LOVE 11.4-under-Emscripten (love.js) away from a missing-file read,
-- where such a read is unrecoverable.
--
-- The engine targets LOVE 11.5, whose contract is that reading a file that is
-- not there returns `nil, message`. love.js is built on 11.4, and there is no
-- 11.5 build of it. On desktop 11.4 that call raises a catchable Lua error --
-- annoying but survivable. In the browser it is far worse. Measured, in
-- headless Chrome on the real build:
--
--   love.filesystem.getInfo("missing.txt")            --> nil          (safe)
--   pcall(love.filesystem.read, "missing.txt")        --> true, nil, true
--   ...while the page logs "Could not open file missing.txt. Does not exist.",
--      pops LOVE's fatal SDL message box, and the wasm then dies with
--      "RuntimeError: memory access out of bounds".
--
-- So the throw does not unwind into Lua at all: pcall reports success and
-- hands back garbage, LOVE's top-level error path fires anyway, and the wasm
-- stack is left corrupted. No amount of wrapping in pcall can catch that --
-- an earlier version of this module tried exactly that and did nothing.
--
-- The only fix is to never make the call. getInfo is safe on every version and
-- answers the only question these call sites are really asking, so the read
-- family gets an existence check in front of it and returns 11.5's `nil,
-- message` itself when the file is absent.
--
-- The concrete failure this prevents is a fatal error on first boot:
--
--   Could not open file rom-cache.complete. Does not exist.
--
-- which is RomImporter.isReady -> CacheFs.read asking "has a ROM been imported
-- yet?". On a fresh install the honest answer is "no", and that answer used to
-- kill the app before the launcher could offer to import one.
--
-- Doing this in one place beats auditing every love.filesystem.read in the
-- codebase: the call sites are already correct for the version the project
-- targets, and the hazard is the host's, not theirs. On 11.5+ this module
-- installs nothing at all.

local LoveCompat = {}

-- Reads whose first argument is a path that must already exist. The value is
-- the number of arguments for which argument 1 is really a path:
-- love.filesystem.newFileData doubles as newFileData(contents, name), which
-- takes two arguments and must NOT be existence-checked.
local READERS = {
  read = false,        -- read(name [, size]) -- arg 1 is always a path
  lines = false,       -- lines(name)
  newFileData = 1,     -- only the 1-argument form names a file
}

-- Writers cannot be pre-checked (the file is supposed to not exist yet), so
-- they keep the pcall, which at least normalises a raised failure on hosts
-- where raising does work.
local WRITERS = { "write", "append" }

local installed = false

local function missingMessage(path)
  return ("Could not open file %s. Does not exist."):format(tostring(path))
end

local function wrapReader(original, pathArgCount)
  return function(...)
    local path = ...
    local argc = select("#", ...)
    local checkable = type(path) == "string"
      and (pathArgCount == false or argc == pathArgCount)
    if checkable and love.filesystem.getInfo and not love.filesystem.getInfo(path) then
      return nil, missingMessage(path)
    end
    local ok, first, second = pcall(original, ...)
    if ok then return first, second end
    return nil, tostring(first)
  end
end

local function wrapWriter(original)
  return function(...)
    local ok, first, second = pcall(original, ...)
    if ok then return first, second end
    return nil, tostring(first)
  end
end

function LoveCompat.needsFilesystemShim(major, minor)
  major = tonumber(major) or 0
  minor = tonumber(minor) or 0
  if major < 11 then return true end
  return major == 11 and minor < 5
end

-- Idempotent, and a no-op on every host that already behaves like 11.5.
-- Returns the number of functions wrapped, so a caller can log or assert.
function LoveCompat.install()
  if installed then return 0 end
  if not (love and love.filesystem) then return 0 end
  if not LoveCompat.needsFilesystemShim(love._version_major, love._version_minor) then
    return 0
  end
  installed = true
  local count = 0
  for name, pathArgCount in pairs(READERS) do
    local original = love.filesystem[name]
    if type(original) == "function" then
      love.filesystem[name] = wrapReader(original, pathArgCount)
      count = count + 1
    end
  end
  for _, name in ipairs(WRITERS) do
    local original = love.filesystem[name]
    if type(original) == "function" then
      love.filesystem[name] = wrapWriter(original)
      count = count + 1
    end
  end
  return count
end

function LoveCompat._resetForTests()
  installed = false
end

return LoveCompat
