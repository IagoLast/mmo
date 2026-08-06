-- Platform capability detection for NX / mobile / desktop / web.

local Platform = {}

local cached

local function compute()
  local osName = (love and love.system and love.system.getOS and love.system.getOS())
    or "Unknown"
  local nx = osName == "NX"
  local mobile = osName == "Android" or osName == "iOS"
  -- love.js (Emscripten) reports "Web" from both love.system.getOS() and
  -- love._os, so conf.lua can branch on the same signal before love.system
  -- is loaded.  A browser build has no process to spawn, no LuaJIT and no
  -- FFI, and receives its ROM as a file the page wrote into the save
  -- directory before boot -- hence its own romImportMode.
  local web = osName == "Web"
  local nativePicker = love and love.system
    and type(love.system.pickFile) == "function"
  return {
    os = osName,
    nx = nx,
    mobile = mobile,
    web = web,
    console = nx,
    hasNativePicker = nativePicker,
    canSpawnProcess = (not web)
      and (osName == "OS X" or osName == "Windows" or osName == "Linux"),
    romImportMode = nx and "save-directory"
      or (web and "browser")
      or (nativePicker and "native-picker")
      or "desktop",
    networkValidated = not nx,
  }
end

function Platform.detect()
  if not cached then cached = compute() end
  return cached
end

function Platform.isNX()
  return Platform.detect().nx
end

function Platform.isWeb()
  return Platform.detect().web
end

function Platform.romImportMode()
  return Platform.detect().romImportMode
end

function Platform.canSpawnProcess()
  return Platform.detect().canSpawnProcess
end

function Platform.networkValidated()
  return Platform.detect().networkValidated
end

-- Tests may swap love.system between cases.
function Platform._resetForTests()
  cached = nil
end

return Platform
