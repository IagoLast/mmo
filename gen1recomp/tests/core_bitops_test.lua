-- Parity contract for the pure-Lua `bit` stand-in the browser build needs.
-- Runs under luajit, where the genuine bit library is present, so every
-- assertion is BitOps.f(...) == bit.f(...) rather than a hand-written table
-- of expected values -- LuaJIT is the specification.  Run with:
--   luajit tests/core_bitops_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- Capture the real library before any install() case can shadow it.
local ref = rawget(_G, "bit")
check(type(ref) == "table" and type(ref.band) == "function",
      "reference bit library is available (these tests need luajit)")

local BitOps = require("src.core.BitOps")

-- A spread that exercises every interesting bit position: zero, small values,
-- the byte/halfword/word masks the ROM and save code uses, values above 2^31
-- (where signedness starts to matter), and negatives on the way in.
local VALUES = {
  0, 1, 2, 3, 7, 8, 15, 16, 127, 128,
  0xFF, 0x100, 0xFFFF, 0x10000, 0xFFFFFF, 0xFFFFFFFF,
  0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFE,
  0x12345678, 0xDEADBEEF, 0xABCDEF01, 0x0000FF00, 0xF0F0F0F0, 0x0F0F0F0F,
  2147483647, 2147483648, 3000000000, 4294967295,
  -1, -2, -128, -255, -65536, -2147483648, -2147483647,
}

-- 0 and 32/33 prove the 5-bit mask (32 must be a no-op, 33 must equal 1);
-- 31 is the boundary where a naive float implementation loses precision.
local SHIFTS = { 0, 1, 7, 8, 16, 24, 31, 32, 33, 63, -1 }

local function argstr(args, n)
  local parts = {}
  for i = 1, n do parts[i] = tostring(args[i]) end
  return table.concat(parts, ", ")
end

-- One check per operator rather than one per case: a 1000-case sweep that
-- printed a line each would bury the interesting line.  The message names
-- the first divergence with its exact input and both values.
local function sweep(label, arity, cases)
  local mine, real = BitOps[label], ref[label]
  if type(mine) ~= "function" then
    return check(false, "BitOps." .. label .. " is missing")
  end
  local bad, first = 0, nil
  for _, args in ipairs(cases) do
    local got = mine(unpack(args, 1, args.n or arity))
    local want = real(unpack(args, 1, args.n or arity))
    if got ~= want then
      bad = bad + 1
      if not first then
        first = ("%s(%s) -> got %s, want %s")
          :format(label, argstr(args, args.n or arity), tostring(got), tostring(want))
      end
    end
  end
  return check(bad == 0, ("BitOps.%s matches bit.%s (%d-operand) over %d cases%s")
    :format(label, label, arity, #cases,
      bad > 0 and (" -- " .. bad .. " mismatch(es), first: " .. first) or ""))
end

local function unaryCases()
  local cases = {}
  for _, x in ipairs(VALUES) do cases[#cases + 1] = { x, n = 1 } end
  return cases
end

local function shiftCases()
  local cases = {}
  for _, x in ipairs(VALUES) do
    for _, n in ipairs(SHIFTS) do cases[#cases + 1] = { x, n, n = 2 } end
  end
  return cases
end

local function pairCases()
  local cases = {}
  for _, x in ipairs(VALUES) do
    for _, y in ipairs(VALUES) do cases[#cases + 1] = { x, y, n = 2 } end
  end
  return cases
end

-- ---------------------------------------------------------------- unary ops
sweep("tobit", 1, unaryCases())
sweep("bnot", 1, unaryCases())
sweep("bswap", 1, unaryCases())

-- ---------------------------------------------------------------- shifts
sweep("lshift", 2, shiftCases())
sweep("rshift", 2, shiftCases())
sweep("arshift", 2, shiftCases())
sweep("rol", 2, shiftCases())
sweep("ror", 2, shiftCases())

-- ---------------------------------------------------------------- logic ops
sweep("band", 2, pairCases())
sweep("bor", 2, pairCases())
sweep("bxor", 2, pairCases())

-- band/bor/bxor are variadic in LuaJIT and GenSave leans on that (a four-way
-- bor when it packs a word), so the fold has to agree too.
do
  local three, four = {}, {}
  for _, x in ipairs(VALUES) do
    for _, y in ipairs(VALUES) do
      three[#three + 1] = { x, y, 0xFF0F, n = 3 }
      four[#four + 1] = { x, y, 0x10, 0x2000, n = 4 }
    end
  end
  sweep("band", 3, three)
  sweep("bor", 3, three)
  sweep("bxor", 3, three)
  sweep("band", 4, four)
  sweep("bor", 4, four)
  sweep("bxor", 4, four)
end

-- ---------------------------------------------------------------- tohex
do
  local cases = {}
  for _, x in ipairs(VALUES) do
    cases[#cases + 1] = { x, n = 1 }                    -- default width
    for _, n in ipairs({ 1, 2, 4, 8, -1, -2, -4, -8 }) do
      cases[#cases + 1] = { x, n, n = 2 }
    end
  end
  sweep("tohex", 1, cases)
end

-- ------------------------------------------------------- documented semantics
-- Spot checks that state the contract the module's header promises, so a
-- future rewrite that drifts from LuaJIT fails with a readable message and
-- not just "5000 cases diverge".
eq(BitOps.bnot(0), -1, "bnot(0) is -1: results are SIGNED 32-bit")
eq(BitOps.tobit(0xFFFFFFFF), -1, "tobit wraps above 2^31 into the negative half")
eq(BitOps.tobit(-1), -1, "tobit takes negatives modulo 2^32")
eq(BitOps.band(0x1234, 0xFF), 0x34, "masked call sites keep unsigned results")
eq(BitOps.lshift(1, 32), 1, "shift counts are masked to 5 bits (32 == 0)")
eq(BitOps.lshift(1, 33), 2, "shift counts are masked to 5 bits (33 == 1)")
eq(BitOps.rshift(-1, 1), 0x7FFFFFFF, "rshift is logical: it shifts in zeros")
eq(BitOps.arshift(-1, 1), -1, "arshift replicates the sign bit")
eq(BitOps.bor(1, 2, 4, 8), 15, "bor folds four operands")
eq(BitOps.bxor(0xFF, 0x0F, 0xF0), 0, "bxor folds three operands")
eq(BitOps.tohex(0xDEADBEEF), "deadbeef", "tohex defaults to 8 lowercase digits")
eq(BitOps.tohex(0xDEADBEEF, -8), "DEADBEEF", "a negative width means uppercase")
eq(BitOps.tohex(0x12345678, 4), "5678", "a narrow width keeps the low digits")

-- ------------------------------------------------------------------- install
-- On every native target LuaJIT already owns `bit`; install() must leave it
-- alone or the JIT-compiled fast path would be replaced by the slow table.
do
  local returned = BitOps.install()
  check(rawget(_G, "bit") == ref, "install() does not clobber an existing bit")
  check(returned == ref, "install() hands back the host's bit when there is one")

  -- ...and the browser case: no host bit, so the polyfill is published.
  rawset(_G, "bit", nil)
  local published = BitOps.install()
  check(rawget(_G, "bit") == BitOps, "install() publishes BitOps when bit is absent")
  check(published == BitOps, "install() returns the table call sites will see")
  rawset(_G, "bit", ref)
  check(rawget(_G, "bit") == ref, "reference bit restored for the rest of the run")
end

T.finish("BitOps parity")
