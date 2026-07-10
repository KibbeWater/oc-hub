-- noteplayer: note block player node for the noteblock music system.
-- Runs on a computer with vanilla note blocks attached through Adapters
-- and a (wireless) network card. The master ("noteblock") does all song
-- parsing and scheduling; this node just executes its schedule precisely.
--
-- Two kinds of hardware, because of how OpenComputers costs calls:
--  * adapter note blocks - trigger(pitch) is a synchronized call (~1 game
--    tick each): flexible pitch, ~20 notes/s per computer.
--  * redstone banks - note blocks fed by the sides of a Redstone I/O
--    block (or this computer's redstone card). One setOutput call fires
--    up to 6 pre-tuned blocks at exactly the same instant. The master
--    re-tunes them per song through the adapter.
--
-- Usage:
--   noteplayer                daemon: wait for a master (Ctrl+C stops)
--   noteplayer calibrate      assign instruments + map redstone banks
--   noteplayer test           play a quick scale on every block
--   noteplayer status         show the current calibration
-- Options: --port=3001
--
-- Calibration lives in /etc/noteplayer.cfg. A calibration.dat from the
-- old NoteblockPlayer is migrated automatically on first run.

local component = require("component")
local computer = require("computer")
local event = require("event")
local nbs = require("nbs")
local serialization = require("serialization")
local shell = require("shell")

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
-- Config schema: { blocks = {address -> instrument},
--                  banks  = { {addr = <redstone address>,
--                              sides = {[side 0-5] = noteBlockAddress}}, } }

-- The old NoteblockPlayer stored {instrument -> address} in calibration.dat.
local function migrateLegacy()
  for _, oldPath in ipairs({ "/home/calibration.dat",
    shell.resolve("calibration.dat") }) do
    local f = io.open(oldPath, "r")
    if f then
      local legacy = serialization.unserialize(f:read("*a") or "") or {}
      f:close()
      local blocks, found = {}, 0
      for inst, address in pairs(legacy) do
        if type(inst) == "number" and type(address) == "string"
          and component.type(address) == "note_block" then
          blocks[address] = inst
          found = found + 1
        end
      end
      if found > 0 then
        printf("migrated %d block(s) from legacy %s", found, oldPath)
        return { blocks = blocks, banks = {} }
      end
    end
  end
  return nil
end

local function loadConfig()
  local f = io.open(CONFIG, "r")
  if not f then
    local migrated = migrateLegacy()
    if migrated then
      local out = io.open(CONFIG, "w")
      if out then
        out:write(serialization.serialize(migrated))
        out:close()
        printf("saved migrated calibration to %s", CONFIG)
      end
      return migrated
    end
    return { blocks = {}, banks = {} }
  end
  local data = serialization.unserialize(f:read("*a") or "") or {}
  f:close()
  if not data.blocks then
    -- v1 schema was a flat {address -> instrument} map
    data = { blocks = data, banks = {} }
  end
  data.banks = data.banks or {}
  -- drop anything that is no longer connected
  local blocks = {}
  for address, inst in pairs(data.blocks) do
    if component.type(address) == "note_block" then
      blocks[address] = inst
    end
  end
  data.blocks = blocks
  local banks = {}
  for _, bank in ipairs(data.banks) do
    if component.type(bank.addr) == "redstone" then
      banks[#banks + 1] = bank
    end
  end
  data.banks = banks
  return data
end

local function saveConfig(config)
  local f, err = io.open(CONFIG, "w")
  if not f then fail("cannot save calibration: " .. tostring(err)) end
  f:write(serialization.serialize(config))
  f:close()
end

-- Splits calibrated blocks into dynamic (adapter-triggered) and bank
-- (redstone-fed, pitch managed per song) blocks.
local function buildSetup(config)
  local bankBlocks = {}
  for _, bank in ipairs(config.banks) do
    for _, address in pairs(bank.sides) do
      bankBlocks[address] = true
    end
  end
  local blocks, counts = {}, {}
  for address, inst in pairs(config.blocks) do
    if not bankBlocks[address] then
      local proxy = component.proxy(address)
      if proxy then
        blocks[inst] = blocks[inst] or {}
        table.insert(blocks[inst], proxy)
        counts[inst] = (counts[inst] or 0) + 1
      end
    end
  end
  local banks = {}
  for _, bank in ipairs(config.banks) do
    local proxy = component.proxy(bank.addr)
    if proxy then
      banks[#banks + 1] = { rs = proxy, sides = bank.sides }
    end
  end
  return blocks, counts, banks
end

local function commandCalibrate()
  local config = { blocks = {}, banks = {} }
  local ordered = {}
  for address in component.list("note_block") do
    ordered[#ordered + 1] = address
  end
  table.sort(ordered)
  if #ordered == 0 then
    fail("no note blocks found; attach them via Adapters")
  end

  print("Calibrating " .. #ordered .. " note block(s).")
  print("Each block plays 3 notes; enter its instrument number.")
  print("")
  for i = 0, 15 do
    printf("  %2d = %-14s (%s)", i, nbs.INSTRUMENTS[i], nbs.INSTRUMENT_BLOCKS[i])
  end
  print("")

  for index, address in ipairs(ordered) do
    local block = component.proxy(address)
    while true do
      io.write(string.format("[block %d/%d] listen... ", index, #ordered))
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
          config.blocks[address] = inst
          printf("  block %d -> %s", index, nbs.INSTRUMENTS[inst])
          break
        end
        print("  enter a number 0-15, r or s")
      end
    end
  end

  -- redstone banks: which calibrated block hangs on which redstone side
  local devices = {}
  for address in component.list("redstone") do
    devices[#devices + 1] = address
  end
  table.sort(devices)
  if #devices > 0 then
    print("")
    printf("%d redstone device(s) found (I/O blocks or redstone card).", #devices)
    print("Note blocks fed by their sides become fast pre-tuned 'banks':")
    print("one call fires up to 6 of them at exactly the same time.")
    io.write("Map redstone banks? (y/N): ")
    local answer = (io.read() or ""):lower()
    if answer:sub(1, 1) == "y" then
      for di, address in ipairs(devices) do
        local rs = component.proxy(address)
        local sides = {}
        printf("device %d/%d (%s):", di, #devices, address:sub(1, 8))
        for side = 0, 5 do
          io.write(string.format("  side %d: pulsing... ", side))
          pcall(rs.setOutput, side, 15)
          os.sleep(0.3)
          pcall(rs.setOutput, side, 0)
          os.sleep(0.2)
          io.write("which block # rang? (Enter = none): ")
          local input = tonumber((io.read() or ""):gsub("%s", ""))
          if input and ordered[input] and config.blocks[ordered[input]] then
            sides[side] = ordered[input]
            printf("    side %d -> block %d (%s)", side, input,
              nbs.INSTRUMENTS[config.blocks[ordered[input]]])
          end
        end
        if next(sides) then
          config.banks[#config.banks + 1] = { addr = address, sides = sides }
        end
      end
    end
  end

  saveConfig(config)
  print("")
  print("Saved to " .. CONFIG .. ":")
  local _, counts, banks = buildSetup(config)
  for inst, count in pairs(counts) do
    printf("  dynamic %-14s x%d", nbs.INSTRUMENTS[inst] or ("#" .. inst), count)
  end
  for i, bank in ipairs(banks) do
    local n = 0
    for _ in pairs(bank.sides) do n = n + 1 end
    printf("  bank %d: %d channel(s)", i, n)
  end
end

local function commandStatus()
  local config = loadConfig()
  local _, counts, banks = buildSetup(config)
  if not next(counts) and #banks == 0 then
    print("Not calibrated. Run: noteplayer calibrate")
    return
  end
  print("Dynamic note blocks (adapter trigger):")
  for inst, count in pairs(counts) do
    printf("  %2d %-14s x%d", inst, nbs.INSTRUMENTS[inst] or "?", count)
  end
  for i, bank in ipairs(banks) do
    printf("Redstone bank %d (%s):", i, bank.rs.address:sub(1, 8))
    for side = 0, 5 do
      local address = bank.sides[side]
      if address then
        local inst = config.blocks[address]
        printf("  side %d: %s", side, nbs.INSTRUMENTS[inst] or "?")
      end
    end
  end
end

local function commandTest()
  local config = loadConfig()
  local blocks, _, banks = buildSetup(config)
  if not next(blocks) and #banks == 0 then
    fail("not calibrated; run: noteplayer calibrate")
  end
  for inst, list in pairs(blocks) do
    printf("dynamic %s (x%d)", nbs.INSTRUMENTS[inst] or ("#" .. inst), #list)
    for _, block in ipairs(list) do
      for pitch = 1, 25, 6 do
        pcall(block.trigger, pitch)
        os.sleep(0.15)
      end
    end
  end
  for i, bank in ipairs(banks) do
    printf("bank %d volley", i)
    local mask = 0
    for side in pairs(bank.sides) do mask = mask + 2 ^ side end
    pcall(bank.rs.setOutput, nbs.maskToSides(mask))
    os.sleep(0.4)
    pcall(bank.rs.setOutput, nbs.maskToSides(0))
    os.sleep(0.4)
  end
end

----------------------------------------------------------------- daemon --

local function commandDaemon()
  if not component.isAvailable("modem") then
    fail("a network card is required")
  end
  local modem = component.modem
  local config = loadConfig()
  local blocks, counts, banks = buildSetup(config)
  if not next(blocks) and #banks == 0 then
    fail("not calibrated; run: noteplayer calibrate")
  end

  modem.open(port)
  if modem.isWireless() then pcall(modem.setStrength, 400) end

  -- hello payload: "inst:count,..." then "|" then per-device bank sides
  local instCSV = {}
  for inst, count in pairs(counts) do
    instCSV[#instCSV + 1] = inst .. ":" .. count
  end
  local bankParts = {}
  for _, bank in ipairs(banks) do
    local sides = {}
    for side = 0, 5 do
      local address = bank.sides[side]
      sides[side + 1] = address and tostring(config.blocks[address]) or "-"
    end
    bankParts[#bankParts + 1] = table.concat(sides, ",")
  end
  local helloPayload = table.concat(instCSV, ",")
    .. "|" .. table.concat(bankParts, ";")

  printf("noteplayer: listening on port %d (Ctrl+C to stop)", port)
  for inst, count in pairs(counts) do
    printf("  dynamic %-14s x%d", nbs.INSTRUMENTS[inst] or ("#" .. inst), count)
  end
  if #banks > 0 then printf("  %d redstone bank(s)", #banks) end

  -- state
  local master
  local songId, songName
  local chunks, blob
  local recordCount, nextIndex = 0, 1
  local state = "idle" -- idle | loaded | playing | paused
  local startTime, pausedAt = 0, 0
  local ring = {}

  local function reset()
    songId, songName, chunks, blob = nil, nil, nil, nil
    recordCount, nextIndex = 0, 1
    state = "idle"
    for _, bank in ipairs(banks) do
      pcall(bank.rs.setOutput, nbs.maskToSides(0))
    end
  end

  local function trigger(inst, pitch)
    local list = blocks[inst]
    if not list then
      local _, fallbackList = next(blocks)
      list = fallbackList
    end
    if not list or #list == 0 then return end
    ring[inst] = ((ring[inst] or 0) % #list) + 1
    pcall(list[ring[inst]].trigger, pitch)
  end

  local function execute(kind, a, b)
    if kind == nbs.KIND_VOLLEY then
      local bank = banks[a + 1]
      if bank then pcall(bank.rs.setOutput, nbs.maskToSides(b)) end
    else
      trigger(kind, a)
    end
  end

  -- per-song tuning: "dev:side:pitch,..." (setPitch is ~1 tick per block)
  local function applyTuning(csv)
    local applied = 0
    for dev, side, pitch in tostring(csv):gmatch("(%d+):(%d+):(%d+)") do
      local bank = banks[tonumber(dev)]
      local address = bank and bank.sides[tonumber(side)]
      if address then
        local proxy = component.proxy(address)
        if proxy and pcall(proxy.setPitch, tonumber(pitch)) then
          applied = applied + 1
        end
      end
    end
    return applied
  end

  local function handleMessage(from, kind, a, b, c)
    if kind == "discover" then
      modem.send(from, port, PROTOCOL, "hello", helloPayload)
    elseif kind == "song" then
      reset()
      master = from
      songId, songName = a, tostring(b or "?")
      chunks = {}
      printf("receiving '%s' from %s", songName, from:sub(1, 8))
    elseif kind == "notes" and from == master and a == songId then
      chunks[tonumber(b) or 0] = c
    elseif kind == "eof" and from == master and a == songId then
      local lastSeq = tonumber(b) or 0
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
        printf("song ready: %d action(s) for this node", recordCount)
      end
      modem.send(from, port, PROTOCOL, "ready", songId, table.concat(missing, ","))
    elseif kind == "tune" and from == master and a == songId then
      local applied = applyTuning(b)
      if applied > 0 then printf("tuned %d bank block(s)", applied) end
      modem.send(from, port, PROTOCOL, "tuned", songId)
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
        handleMessage(sig[3], sig[7], sig[8], sig[9], sig[10])
      end

      -- fire every action that is due
      while state == "playing" do
        local t, kind, a, b = nbs.readRecord(blob, nextIndex)
        if not t or startTime + t > computer.uptime() then break end
        execute(kind, a, b)
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
