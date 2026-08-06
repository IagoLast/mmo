-- Pure-Lua stand-in for LuaJIT's `bit` library.
--
-- Every desktop, mobile and console target runs LuaJIT, which ships `bit`
-- as a built-in.  The browser target does not: love.js is Emscripten-compiled
-- LÖVE on *plain Lua 5.1*, where `bit` simply does not exist (verified: the
-- love.js 11.4 build reports jit=nil, bit=nil, ffi=absent).  Four modules
-- would blow up on the first bitwise call there:
--
--   src/core/ChipSynth.lua      -- audio synthesis (per-sample, hot)
--   src/import/Rom.lua          -- ROM header/bank decoding
--   src/import/RomExtractor.lua -- the extraction pass over the cart
--   src/save_convert/GenSave.lua-- .sav packing/unpacking and checksums
--
-- Install() therefore publishes this table as the global `bit` when, and only
-- when, the host has none.  On LuaJIT it is a no-op, so nothing about the
-- native builds changes.
--
-- Semantics follow LuaJIT's bit.* exactly, because the call sites were written
-- against it:
--   * operands are taken modulo 2^32 (negatives wrap, like tobit)
--   * results are SIGNED 32-bit, so bnot(0) == -1, matching LuaJIT
--   * shift counts are masked to 5 bits (n % 32), again like LuaJIT
-- Masked call sites (`band(x, 0xFF)`) are unaffected by the signedness, but
-- GenSave's `band(bnot(sum), 0xFF)` checksum relies on negatives normalising
-- back correctly on the way into the next operation -- hence normalise-on-
-- input rather than assuming callers pass unsigned values.
--
-- Speed: the binary ops walk eight 4-bit nibbles through 16x16 lookup tables
-- rather than looping over 32 individual bits, which is ~4x less work per
-- call.  That is fast enough for ROM extraction and the audio synth in the
-- browser; native builds never reach this code.

local BitOps = {}

local TWO32 = 4294967296
local TWO31 = 2147483648

-- Nibble lookup tables: AND_T[a][b], OR_T[a][b], XOR_T[a][b] for a,b in 0..15.
local AND_T, OR_T, XOR_T = {}, {}, {}
for a = 0, 15 do
  AND_T[a], OR_T[a], XOR_T[a] = {}, {}, {}
  for b = 0, 15 do
    local andv, orv, xorv = 0, 0, 0
    local pa, pb, place = a, b, 1
    for _ = 1, 4 do
      local ba, bb = pa % 2, pb % 2
      if ba == 1 and bb == 1 then andv = andv + place end
      if ba == 1 or bb == 1 then orv = orv + place end
      if ba ~= bb then xorv = xorv + place end
      pa, pb, place = (pa - ba) / 2, (pb - bb) / 2, place * 2
    end
    AND_T[a][b], OR_T[a][b], XOR_T[a][b] = andv, orv, xorv
  end
end

-- Any Lua number -> unsigned 32-bit. Truncates toward zero first so that
-- fractional intermediates (LuaJIT's bit.* also coerces) behave predictably.
local function unsigned(x)
  x = tonumber(x) or 0
  if x >= 0 then x = math.floor(x) else x = math.ceil(x) end
  x = x % TWO32
  if x < 0 then x = x + TWO32 end
  return x
end

-- unsigned 32-bit -> signed 32-bit, which is what LuaJIT hands back.
local function signed(x)
  if x >= TWO31 then return x - TWO32 end
  return x
end

local function binop(tbl, a, b)
  a, b = unsigned(a), unsigned(b)
  local res, place = 0, 1
  for _ = 1, 8 do
    local na, nb = a % 16, b % 16
    res = res + tbl[na][nb] * place
    a = (a - na) / 16
    b = (b - nb) / 16
    place = place * 16
  end
  return res
end

-- band/bor/bxor are variadic in LuaJIT and GenSave calls bor with four
-- operands, so fold rather than assuming two.
local function fold(tbl, x, y, ...)
  local acc = binop(tbl, x, y)
  for i = 1, select("#", ...) do
    acc = binop(tbl, acc, (select(i, ...)))
  end
  return signed(acc)
end

function BitOps.tobit(x) return signed(unsigned(x)) end
function BitOps.band(x, y, ...) return fold(AND_T, x, y, ...) end
function BitOps.bor(x, y, ...) return fold(OR_T, x, y, ...) end
function BitOps.bxor(x, y, ...) return fold(XOR_T, x, y, ...) end
function BitOps.bnot(x) return signed(TWO32 - 1 - unsigned(x)) end

-- Shifts and rotations drop the bits that leave the word BEFORE multiplying,
-- never after. Lua numbers are doubles with a 53-bit mantissa, so the obvious
-- `(v * 2^n) % 2^32` silently loses precision as soon as v * 2^n exceeds 2^53
-- (v = 0xFFFFFF, n = 31 is already ~3.6e16) and returns a value that is off by
-- one in the low bits. Masking first keeps every intermediate under 2^32.
function BitOps.lshift(x, n)
  n = unsigned(n) % 32
  if n == 0 then return signed(unsigned(x)) end
  local keep = 2 ^ (32 - n)
  return signed((unsigned(x) % keep) * (2 ^ n))
end

function BitOps.rshift(x, n)
  n = unsigned(n) % 32
  return signed(math.floor(unsigned(x) / (2 ^ n)))
end

-- Arithmetic shift: replicate the sign bit instead of shifting in zeros.
function BitOps.arshift(x, n)
  n = unsigned(n) % 32
  local v = unsigned(x)
  local shifted = math.floor(v / (2 ^ n))
  if v >= TWO31 and n > 0 then
    -- fill the vacated high bits with ones
    shifted = shifted + (TWO32 - (2 ^ (32 - n)))
  end
  return signed(shifted % TWO32)
end

function BitOps.rol(x, n)
  n = unsigned(n) % 32
  local v = unsigned(x)
  if n == 0 then return signed(v) end
  local keep = 2 ^ (32 - n)
  -- low (32 - n) bits move up by n; the top n bits wrap round to the bottom.
  -- Both terms stay below 2^32, so their sum is exact.
  local low = v % keep
  return signed(low * (2 ^ n) + (v - low) / keep)
end

function BitOps.ror(x, n)
  n = unsigned(n) % 32
  if n == 0 then return signed(unsigned(x)) end
  return BitOps.rol(x, 32 - n)
end

function BitOps.bswap(x)
  local v = unsigned(x)
  local b0 = v % 256
  local b1 = math.floor(v / 256) % 256
  local b2 = math.floor(v / 65536) % 256
  local b3 = math.floor(v / 16777216) % 256
  return signed(b0 * 16777216 + b1 * 65536 + b2 * 256 + b3)
end

function BitOps.tohex(x, n)
  n = tonumber(n) or 8
  local digits = math.abs(n)
  if digits > 8 then digits = 8 end
  local fmt = (n < 0 and "%0" .. digits .. "X") or ("%0" .. digits .. "x")
  local v = unsigned(x)
  if digits < 8 then v = v % (2 ^ (digits * 4)) end
  return string.format(fmt, v)
end

-- Publish as the global `bit` unless the host already provides one (LuaJIT).
-- Returns the table that call sites will see, so a caller can assert on it.
function BitOps.install()
  local existing = rawget(_G, "bit")
  if type(existing) ~= "table" then
    rawset(_G, "bit", BitOps)
    existing = BitOps
  end
  -- The global is not enough: four modules pull the library in with
  -- `require("bit")` (RomExtractor, ChipSynth, GenSave, OverworldController).
  -- That is a LuaJIT extension -- LuaJIT preloads the module as well as the
  -- global -- and on plain Lua 5.1 it resolves to nothing, so the browser
  -- build failed at `src/import/RomExtractor.lua:1: module 'bit' not found`
  -- the moment a ROM import started.
  if package and type(package.loaded) == "table" and package.loaded.bit == nil then
    package.loaded.bit = existing
  end
  return existing
end

return BitOps
