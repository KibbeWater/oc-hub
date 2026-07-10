-- Desktop test harness for noteblock/nbs.lua (run with standard Lua 5.2+):
--   lua tools/test_nbs.lua <song.nbs> [packed.zip]
-- Validates parsing, timeline, pitch mapping, scheduling and zip extraction
-- against a real noteblock.world song.

package.path = "noteblock/?.lua;" .. package.path
local nbs = require("nbs")

local nbsPath, zipPath = arg[1], arg[2]
if not nbsPath then
  print("usage: lua tools/test_nbs.lua <song.nbs> [packed.zip]")
  os.exit(1)
end

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

local function readAll(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

-- decodes a scheduled action blob into {t, kind, a, b} records
local function decodeAll(blob)
  local records = {}
  local i = 1
  while true do
    local t, kind, a, b = nbs.readRecord(blob, i)
    if not t then break end
    records[#records + 1] = { t = t, kind = kind, a = a, b = b }
    i = i + 1
  end
  return records
end

-- zip extraction --------------------------------------------------------

local fileData = readAll(nbsPath)

if zipPath then
  local zipData = readAll(zipPath)
  local extracted, name = nbs.unzipStored(zipData, "%.nbs$")
  check("unzipStored finds song.nbs", name == "song.nbs", name)
  check("unzipStored bytes identical", extracted == fileData,
    extracted and #extracted .. " vs " .. #fileData)
end

-- parsing ----------------------------------------------------------------

local song, perr = nbs.parse(fileData)
check("parse succeeds", song ~= nil, perr)
if not song then os.exit(1) end

print(string.format("     '%s' by '%s', v%d, %.4g t/s, %d ticks, %d notes",
  song.name, song.author, song.version, song.tempo,
  song.lengthTicks, song.noteCount))

-- known values from the noteblock.world API for song ppOZ2D67LX
check("version 5", song.version == 5, song.version)
check("tempo 10 t/s", math.abs(song.tempo - 10) < 0.001, song.tempo)
check("note count 705", song.noteCount == 705, song.noteCount)
-- header stores the last tick index; the API's tickCount (887) is that +1
check("length 886 ticks", song.lengthTicks == 886, song.lengthTicks)

local instCounts = {}
for _, bucket in ipairs(song.ticks) do
  for inst in nbs.eachNote(bucket.n) do
    instCounts[inst] = (instCounts[inst] or 0) + 1
  end
end
-- API stats.instrumentNoteCounts: [264,84,0,0,0,0,0,33,324,0,...]
check("instrument 0 has 264 notes", instCounts[0] == 264, instCounts[0])
check("instrument 1 has 84 notes", instCounts[1] == 84, instCounts[1])
check("instrument 7 has 33 notes", instCounts[7] == 33, instCounts[7])
check("instrument 8 has 324 notes", instCounts[8] == 324, instCounts[8])

-- timeline ---------------------------------------------------------------

local events, duration = nbs.timeline(song)
check("timeline duration ~88.7s", math.abs(duration - 88.7) < 0.75, duration)
local ordered = true
for i = 2, #events do
  if events[i].time < events[i - 1].time then ordered = false end
end
check("timeline is ordered", ordered)

-- pitch mapping ----------------------------------------------------------

check("blockPitch: key 33 -> 1", nbs.blockPitch(33) == 1, nbs.blockPitch(33))
check("blockPitch: key 57 -> 25", nbs.blockPitch(57) == 25, nbs.blockPitch(57))
check("blockPitch: key 45 -> 13", nbs.blockPitch(45) == 13, nbs.blockPitch(45))
check("blockPitch: key 21 folds to 1", nbs.blockPitch(21) == 1, nbs.blockPitch(21))
check("blockPitch: key 69 folds to 25", nbs.blockPitch(69) == 25, nbs.blockPitch(69))
check("blockPitch: detune +100 = +1 key", nbs.blockPitch(40, 100) == 9,
  nbs.blockPitch(40, 100))

-- record encoding --------------------------------------------------------

local blob = nbs.encodeRecords({
  { t = 0, inst = 0, p = 1 },
  { t = 12.34, inst = 5, p = 25 },
  { t = 3600.5, volley = true, dev = 3, mask = 42 },
})
local t1, k1, a1r = nbs.readRecord(blob, 1)
local t2, k2, a2r = nbs.readRecord(blob, 2)
local t3, k3, a3r, b3 = nbs.readRecord(blob, 3)
check("record 1 roundtrip", t1 == 0 and k1 == 0 and a1r == 1)
check("record 2 roundtrip", math.abs(t2 - 12.34) < 0.011 and k2 == 5 and a2r == 25)
check("volley record roundtrip", math.abs(t3 - 3600.5) < 0.011
  and k3 == nbs.KIND_VOLLEY and a3r == 2 and b3 == 42)
check("readRecord past end returns nil", nbs.readRecord(blob, 4) == nil)

local sides = nbs.maskToSides(42) -- binary 101010: sides 1, 3, 5
check("maskToSides", sides[0] == 0 and sides[1] == 15 and sides[2] == 0
  and sides[3] == 15 and sides[4] == 0 and sides[5] == 15)

-- scheduling -------------------------------------------------------------

-- one player with every needed instrument and huge capacity: nothing dropped
local fullBand = { { inst = { [0] = 4, [1] = 4, [7] = 4, [8] = 4 } } }
local a1, s1 = nbs.schedule(events, fullBand, { perTick = 99 })
check("full band drops nothing", s1.dropped == 0, s1.dropped)
check("all notes accounted for",
  s1.played + s1.dropped + s1.merged == s1.total,
  s1.played .. "+" .. s1.dropped .. "+" .. s1.merged .. " vs " .. s1.total)
check("assignments match played", #decodeAll(a1[1]) == s1.played, #decodeAll(a1[1]))

-- single player at 1 note/tick: capacity must be respected
local function minSpacing(records)
  local minimum = math.huge
  for i = 2, #records do
    minimum = math.min(minimum, records[i].t - records[i - 1].t)
  end
  return minimum
end

local soloist = { { inst = { [0] = 1, [1] = 1, [7] = 1, [8] = 1 } } }
local a2, s2 = nbs.schedule(events, soloist, { perTick = 1, slack = 0 })
check("strict solo spacing >= 1 tick", minSpacing(decodeAll(a2[1])) >= 0.05 - 0.001,
  minSpacing(decodeAll(a2[1])))
check("solo drops the overflow", s2.played + s2.dropped + s2.merged == s2.total)
print(string.format("     strict solo: %d played, %d dropped (%.1f%%)",
  s2.played, s2.dropped, 100 * s2.dropped / s2.total))

-- default slack lets overflow notes fire a tick or two late instead of
-- being dropped; machine capacity must still hold
local a2s, s2s = nbs.schedule(events, soloist, { perTick = 1 })
check("slack solo spacing >= 1 tick", minSpacing(decodeAll(a2s[1])) >= 0.05 - 0.001,
  minSpacing(decodeAll(a2s[1])))
check("slack recovers drops", s2s.dropped < s2.dropped,
  s2s.dropped .. " vs " .. s2.dropped)
check("slack late notes counted", s2s.late > 0, s2s.late)
check("slack accounting", s2s.played + s2s.dropped + s2s.merged == s2s.total)
print(string.format("     slack solo: %d played (%d late), %d dropped (%.1f%%)",
  s2s.played, s2s.late, s2s.dropped, 100 * s2s.dropped / s2s.total))

-- four players: fewer drops than one player
local quartet = {}
for i = 1, 4 do quartet[i] = { inst = { [0] = 1, [1] = 1, [7] = 1, [8] = 1 } } end
local _, s3 = nbs.schedule(events, quartet, { perTick = 1 })
check("more players -> fewer drops", s3.dropped < s2.dropped,
  s3.dropped .. " vs " .. s2.dropped)
print(string.format("     quartet: %d played, %d dropped (%.1f%%)",
  s3.played, s3.dropped, 100 * s3.dropped / s3.total))

-- players without the instrument: substitution
local drummer = { { inst = { [2] = 2, [3] = 2 } } }
local a4, s4 = nbs.schedule(events, drummer, { perTick = 99 })
check("fallback substitutes", s4.substituted > 0 and s4.substituted == s4.played,
  s4.substituted)
local subInstOk = true
for _, rec in ipairs(a4[1]) do
  if rec.inst ~= 2 and rec.inst ~= 3 then subInstOk = false end
end
check("substituted notes use available instruments", subInstOk)
local _, s5 = nbs.schedule(events, drummer, { perTick = 99, fallback = false })
check("nofallback drops instead", s5.substituted == 0 and s5.played == 0,
  s5.played)

-- redstone bank scheduling -----------------------------------------------

-- a bank-only player: two redstone devices, all six sides wired to piano
-- blocks (instrument 0, the fixture's melody instrument, 264 notes)
local organ = { {
  inst = {},
  banks = {
    { inst = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 } },
    { inst = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 } },
  },
} }
local aB, sB, tB = nbs.schedule(events, organ, { rsDelay = 0.1 })
check("organ plays via banks only", sB.bank > 0 and sB.bank == sB.played, sB.bank)
check("organ tunings produced", #tB[1] == 12, #tB[1])
local tuningOk = true
for _, tune in ipairs(tB[1]) do
  if tune.pitch < 1 or tune.pitch > 25 or tune.dev < 1 or tune.dev > 2
    or tune.side < 0 or tune.side > 5 then
    tuningOk = false
  end
end
check("organ tunings valid", tuningOk)

-- volley physics: per device, calls must be >= 1 tick + rsDelay apart, and
-- a side may never be high in two consecutive volleys (no rising edge)
local volleyOk, edgeOk = true, true
local lastTime, lastMask = {}, {}
for _, rec in ipairs(decodeAll(aB[1])) do
  if rec.kind == nbs.KIND_VOLLEY then
    local dev, mask = rec.a, rec.b
    if lastTime[dev] and rec.t - lastTime[dev] < 0.15 - 0.001 then
      volleyOk = false
    end
    local overlap = 0
    local m1, m2 = lastMask[dev] or 0, mask
    for _ = 1, 6 do
      if m1 % 2 == 1 and m2 % 2 == 1 then overlap = overlap + 1 end
      m1 = math.floor(m1 / 2)
      m2 = math.floor(m2 / 2)
    end
    if overlap > 0 then edgeOk = false end
    lastTime[dev], lastMask[dev] = rec.t, mask
  end
end
check("volleys respect device cadence", volleyOk)
check("no side stays high across volleys", edgeOk)
print(string.format("     organ: %d bank notes of %d total (%.1f%%)",
  sB.bank, sB.total, 100 * sB.bank / sB.total))

-- hybrid: soloist + organ should beat the plain soloist
local hybrid = {
  { inst = { [0] = 1, [1] = 1, [7] = 1, [8] = 1 } },
  organ[1],
}
local _, sH = nbs.schedule(events, hybrid, { perTick = 1, rsDelay = 0.1 })
check("hybrid beats solo", sH.dropped < s2.dropped,
  sH.dropped .. " vs " .. s2.dropped)
print(string.format("     hybrid: %d played (%d bank), %d dropped (%.1f%%)",
  sH.played, sH.bank, sH.dropped, 100 * sH.dropped / sH.total))

-- calibration partitioning (server blades sharing one block network) -----

local shared = {
  blocks = {
    a = 0, b = 0, c = 0, d = 0, -- four pianos
    e = 5, f = 5,               -- two guitars
    x = 7, y = 7,               -- bells owned by the bank below
  },
  banks = { { addr = "rs1", sides = { [0] = "x", [2] = "y" } } },
}
local p1 = nbs.partitionCalibration(shared, 1, 2)
local p2 = nbs.partitionCalibration(shared, 2, 2)
local function countBlocks(cfg)
  local total = 0
  for _ in pairs(cfg.blocks) do total = total + 1 end
  return total
end
local disjoint = true
for address in pairs(p1.blocks) do
  if p2.blocks[address] then disjoint = false end
end
check("partitions are disjoint", disjoint)
check("partition sizes", countBlocks(p1) == 5 and countBlocks(p2) == 3,
  countBlocks(p1) .. "/" .. countBlocks(p2))
check("each partition gets pianos",
  (p1.blocks.a or p1.blocks.b or p1.blocks.c or p1.blocks.d) ~= nil
  and (p2.blocks.a or p2.blocks.b or p2.blocks.c or p2.blocks.d) ~= nil)
check("bank follows partition 1", #p1.banks == 1 and #p2.banks == 0)
check("bank blocks stay with their bank",
  p1.blocks.x == 7 and p1.blocks.y == 7
  and p2.blocks.x == nil and p2.blocks.y == nil)
local p11 = nbs.partitionCalibration(shared, 1, 1)
check("1/1 partition keeps everything", countBlocks(p11) == 8 and #p11.banks == 1)

-- classic v0 parsing -----------------------------------------------------

local function u16le(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function i32str(s) return string.char(#s % 256, math.floor(#s / 256) % 256, 0, 0) .. s end
local classic = table.concat({
  u16le(4),            -- song length (nonzero => classic)
  u16le(1),            -- layer count
  i32str("Classic"),   -- name
  i32str("Tester"),    -- author
  i32str(""),          -- original author
  i32str(""),          -- description
  u16le(1000),         -- tempo 10.00 t/s
  string.char(0, 0),   -- auto-save
  string.char(4),      -- time signature
  string.rep("\0", 20),-- stats
  i32str(""),          -- import name
  -- notes: tick 0 with two notes, tick 2 with one
  u16le(1), u16le(1), string.char(0, 45), u16le(1), string.char(5, 50), u16le(0),
  u16le(2), u16le(1), string.char(0, 40), u16le(0),
  u16le(0),
  -- layers
  i32str("melody"), string.char(50),
  -- custom instruments
  string.char(0),
})
local old, oerr = nbs.parse(classic)
check("classic v0 parses", old ~= nil, oerr)
if old then
  check("v0 version", old.version == 0, old.version)
  check("v0 name", old.name == "Classic", old.name)
  check("v0 tempo", math.abs(old.tempo - 10) < 0.001, old.tempo)
  check("v0 note count", old.noteCount == 3, old.noteCount)
  local _, _, vel0 = nbs.eachNote(old.ticks[1].n)()
  check("v0 layer volume applied", vel0 == 50, vel0)
  local ev0 = nbs.timeline(old)
  check("v0 timeline times", math.abs(ev0[2].time - 0.2) < 0.001,
    ev0[2] and ev0[2].time)
end

-- large song stress: ~100KB / 12000 notes must parse and schedule with
-- packed strings all the way through (this size OOM'd/timed out the old
-- table-per-note pipeline on real OC hardware)
local TICKS, PER = 600, 20
-- v6 file: vanilla count 20 (built-in copper trumpets at 16-19)
local header = table.concat({
  u16le(0), string.char(6), string.char(20),
  u16le(TICKS), u16le(PER),
  i32str("Big Song"), i32str(""), i32str(""), i32str(""),
  u16le(1000), string.char(0, 0), string.char(4),
  string.rep("\0", 20), i32str(""),
  string.char(0, 0), u16le(0), -- loop settings (v4+)
})
local parts = { header }
for _ = 1, TICKS do
  parts[#parts + 1] = u16le(1)
  for i = 1, PER do
    parts[#parts + 1] = u16le(1)
      .. string.char(i % 20, 33 + (i * 7) % 25, 100, 100) .. u16le(0)
  end
  parts[#parts + 1] = u16le(0)
end
parts[#parts + 1] = u16le(0)
for _ = 1, PER do -- layers
  parts[#parts + 1] = i32str("") .. string.char(0, 100, 100)
end
parts[#parts + 1] = string.char(0) -- no custom instruments
local bigData = table.concat(parts)

local yields = 0
nbs.onYield = function() yields = yields + 1 end
local bigSong, bigErr = nbs.parse(bigData)
check("big v6 song parses", bigSong ~= nil, bigErr)
if bigSong then
  check("big song is v6 with 20 builtins",
    bigSong.version == 6 and bigSong.vanillaCount == 20, bigSong.version)
  check("big song note count", bigSong.noteCount == TICKS * PER, bigSong.noteCount)
  local bigEvents = nbs.timeline(bigSong)
  local bigBand = { inst = {} }
  for i = 0, 15 do bigBand.inst[i] = 1 end
  local bigAsn, bigStats = nbs.schedule(bigEvents, { bigBand }, {})
  check("big song schedules everything",
    bigStats.played + bigStats.dropped + bigStats.merged == bigStats.total,
    bigStats.total)
  -- with ample capacity, the copper trumpet notes (inst 16-19) must land
  -- as substituted vanilla instruments rather than being dropped
  local _, richStats = nbs.schedule(bigEvents, { bigBand }, { perTick = 99 })
  check("v6 trumpets get substituted", richStats.substituted == TICKS * 4,
    richStats.substituted)
  check("heavy loops yield for the watchdog", yields > 10, yields)
  print(string.format(
    "     big song: %d KB file, %d notes, %d actions out, %d yields",
    math.floor(#bigData / 1024), TICKS * PER,
    math.floor(#bigAsn[1] / nbs.RECORD_SIZE), yields))
end
nbs.onYield = nil

print("")
if failures == 0 then
  print("all tests passed")
else
  print(failures .. " test(s) FAILED")
  os.exit(1)
end
