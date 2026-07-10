-- noteplayer: note block player node for the noteblock music system.
-- Runs on a computer with vanilla note blocks attached through Adapters
-- and a (wireless) network card. The master ("noteblock") does all song
-- parsing and scheduling; this node just plays (instrument, pitch) at the
-- exact times it is told to, so many nodes together can play dense songs
-- that a single computer never could (each trigger costs ~1 game tick).
--
-- Usage:
--   noteplayer                daemon: wait for a master (Ctrl+C stops)
--   noteplayer calibrate      assign an instrument to every note block
--   noteplayer test           play a quick scale on every block
--   noteplayer status         show the current calibration
-- Options: --port=3001
--
-- Calibration is stored in /etc/noteplayer.cfg. Instruments follow NBS ids
-- (the block placed UNDER the note block decides the sound):
-- 0 Piano, 1 Double Bass, 2 Bass Drum, 3 Snare, 4 Click, 5 Guitar,
-- 6 Flute, 7 Bell, 8 Chime, 9 Xylophone, 10 Iron Xylophone, 11 Cow Bell,
-- 12 Didgeridoo, 13 Bit, 14 Banjo, 15 Pling.

local component = require("component")
local computer = require("computer")
local event = require("event")
local nbs = require("nbs")
local serialization = require("serialization")
local shell = require("shell")
local term = require("term")

local CONFIG = "/etc/noteplayer.cfg"
local PROTOCOL = "NBP2"

local args, opts = shell.parse(...)
local port = tonumber(opts.port) or 3001

local function printf(fmt, ...) io.write(string.format(fmt, ...), "\n") end

local function fail(msg)
  io.stderr:write("noteplayer: " .. tostring(msg) .. "\n")
  os.exit(1)
end

------------------------------------------------------------ calibration --

local function loadCalibration()
  local f = io.open(CONFIG, "r")
  if not f then return {} end
  local data = serialization.unserialize(f:read("*a") or "") or {}
  f:close()
  -- keep only blocks that are still connected
  local mapping = {}
  for address, inst in pairs(data) do
    if component.type(address) == "note_block" then
      mapping[address] = inst
    end
  end
  return mapping
end

local function saveCalibration(mapping)
  local f, err = io.open(CONFIG, "w")
  if not f then fail("cannot save calibration: " .. tostring(err)) end
  f:write(serialization.serialize(mapping))
  f:close()
end

-- Builds blocks[instrument] = {proxy, ...} from the calibration.
local function buildBlocks(mapping)
  local blocks, counts = {}, {}
  for address, inst in pairs(mapping) do
    local proxy = component.proxy(address)
    if proxy then
      blocks[inst] = blocks[inst] or {}
      table.insert(blocks[inst], proxy)
      counts[inst] = (counts[inst] or 0) + 1
    end
  end
  return blocks, counts
end

local function commandCalibrate()
  local mapping = {}
  local total, index = 0, 0
  for _ in component.list("note_block") do total = total + 1 end
  if total == 0 then fail("no note blocks found; attach them via Adapters") end

  print("Calibrating " .. total .. " note block(s).")
  print("Each block plays 3 notes; enter its instrument number.")
  print("")
  for i = 0, 15 do
    printf("  %2d = %-14s (%s)", i, nbs.INSTRUMENTS[i], nbs.INSTRUMENT_BLOCKS[i])
  end
  print("")

  for address in component.list("note_block") do
    index = index + 1
    local block = component.proxy(address)
    while true do
      io.write(string.format("[%d/%d] listen... ", index, total))
      for _ = 1, 3 do
        pcall(block.trigger, 13)
        os.sleep(0.4)
      end
      io.write("instrument # (r = replay, s = skip): ")
      local input = (io.read() or ""):gsub("%s", "")
      if input == "r" or input == "R" then
        -- replay
      elseif input == "s" or input == "S" or input == "" then
        print("  skipped")
        break
      else
        local inst = tonumber(input)
        if inst and inst >= 0 and inst <= 15 then
          mapping[address] = inst
          printf("  -> %s", nbs.INSTRUMENTS[inst])
          break
        end
        print("  enter a number 0-15, r or s")
      end
    end
  end

  saveCalibration(mapping)
  local _, counts = buildBlocks(mapping)
  print("")
  print("Saved to " .. CONFIG .. ":")
  for inst, count in pairs(counts) do
    printf("  %-14s x%d", nbs.INSTRUMENTS[inst] or ("#" .. inst), count)
  end
end

local function commandStatus()
  local mapping = loadCalibration()
  local _, counts = buildBlocks(mapping)
  if not next(counts) then
    print("Not calibrated. Run: noteplayer calibrate")
    return
  end
  print("Calibrated note blocks:")
  for inst, count in pairs(counts) do
    printf("  %2d %-14s x%d", inst, nbs.INSTRUMENTS[inst] or "?", count)
  end
end

local function commandTest()
  local blocks = buildBlocks(loadCalibration())
  if not next(blocks) then fail("not calibrated; run: noteplayer calibrate") end
  for inst, list in pairs(blocks) do
    printf("testing %s (x%d)", nbs.INSTRUMENTS[inst] or ("#" .. inst), #list)
    for _, block in ipairs(list) do
      for pitch = 1, 25, 6 do
        pcall(block.trigger, pitch)
        os.sleep(0.15)
      end
    end
  end
end

----------------------------------------------------------------- daemon --

local function commandDaemon()
  if not component.isAvailable("modem") then
    fail("a network card is required")
  end
  local modem = component.modem
  local mapping = loadCalibration()
  local blocks, counts = buildBlocks(mapping)
  if not next(blocks) then
    fail("not calibrated; run: noteplayer calibrate")
  end

  modem.open(port)
  if modem.isWireless() then pcall(modem.setStrength, 400) end

  local instCSV = {}
  for inst, count in pairs(counts) do
    instCSV[#instCSV + 1] = inst .. ":" .. count
  end
  instCSV = table.concat(instCSV, ",")

  printf("noteplayer: listening on port %d (Ctrl+C to stop)", port)
  for inst, count in pairs(counts) do
    printf("  %-14s x%d", nbs.INSTRUMENTS[inst] or ("#" .. inst), count)
  end

  -- state
  local master
  local songId, songName
  local chunks, lastSeq
  local blob
  local recordCount, nextIndex = 0, 1
  local state = "idle" -- idle | loaded | playing | paused
  local startTime = 0
  local pausedAt = 0
  local ring = {}

  local function reset()
    songId, songName, chunks, lastSeq, blob = nil, nil, nil, nil, nil
    recordCount, nextIndex = 0, 1
    state = "idle"
  end

  local function trigger(inst, pitch)
    local list = blocks[inst]
    if not list then
      -- shouldn't happen (the master only assigns what we reported), but
      -- play on any block rather than staying silent
      local _, fallbackList = next(blocks)
      list = fallbackList
    end
    if not list or #list == 0 then return end
    ring[inst] = ((ring[inst] or 0) % #list) + 1
    pcall(list[ring[inst]].trigger, pitch)
  end

  local function handleMessage(from, kind, a, b, c, d)
    if kind == "discover" then
      modem.send(from, port, PROTOCOL, "hello", instCSV)
    elseif kind == "song" then
      reset()
      master = from
      songId, songName = a, tostring(b or "?")
      chunks = {}
      printf("receiving '%s' from %s", songName, from:sub(1, 8))
    elseif kind == "notes" and from == master and a == songId then
      chunks[tonumber(b) or 0] = c
    elseif kind == "eof" and from == master and a == songId then
      lastSeq = tonumber(b) or 0
      local missing = {}
      for seq = 1, lastSeq do
        if not chunks[seq] then missing[#missing + 1] = seq end
      end
      if #missing == 0 then
        blob = table.concat(chunks, "", 1, lastSeq)
        chunks = nil
        recordCount = math.floor(#blob / nbs.RECORD_SIZE)
        nextIndex = 1
        state = "loaded"
        printf("song ready: %d notes for this node", recordCount)
      end
      modem.send(from, port, PROTOCOL, "ready", songId, table.concat(missing, ","))
    elseif kind == "play" and from == master and a == songId and blob then
      startTime = computer.uptime() + (tonumber(b) or 1)
      nextIndex = 1
      state = "playing"
      printf("playing '%s'", songName)
    elseif kind == "pause" and from == master and state == "playing" then
      pausedAt = computer.uptime()
      state = "paused"
    elseif kind == "resume" and from == master and state == "paused" then
      startTime = startTime + (computer.uptime() - pausedAt)
      state = "playing"
    elseif kind == "stop" and from == master then
      if state ~= "idle" then print("stopped") end
      reset()
    elseif kind == "ping" then
      modem.send(from, port, PROTOCOL, "pong", state, songName or "")
    end
  end

  local ok, err = pcall(function()
    while true do
      local timeout = math.huge
      if state == "playing" then
        local t = nbs.readRecord(blob, nextIndex)
        if t then
          timeout = math.max(0, startTime + t - computer.uptime())
        else
          state = "idle"
          printf("finished '%s'", songName or "?")
          if master then modem.send(master, port, PROTOCOL, "done", songId) end
          timeout = math.huge
        end
      end

      local sig = table.pack(event.pull(timeout))
      if sig[1] == "modem_message" and sig[4] == port and sig[6] == PROTOCOL then
        handleMessage(sig[3], sig[7], sig[8], sig[9], sig[10], sig[11])
      end

      -- fire every note that is due
      while state == "playing" do
        local t, inst, pitch = nbs.readRecord(blob, nextIndex)
        if not t or startTime + t > computer.uptime() then break end
        trigger(inst, pitch)
        nextIndex = nextIndex + 1
      end
    end
  end)
  modem.close(port)
  if not ok and err ~= nil and not tostring(err):match("interrupted") then
    fail(err)
  end
  print("noteplayer stopped.")
end

------------------------------------------------------------------- main --

local command = args[1]
if command == "calibrate" then
  commandCalibrate()
elseif command == "test" then
  commandTest()
elseif command == "status" then
  commandStatus()
elseif command == nil then
  commandDaemon()
else
  print("usage: noteplayer [calibrate|test|status] [--port=3001]")
  os.exit(1)
end
