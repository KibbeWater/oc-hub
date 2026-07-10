-- nbs.lua: Note Block Studio (.nbs) toolkit for OpenComputers.
-- Parses every NBS version (classic v0 through OpenNBS v5), converts songs
-- to an absolute-time event list (handling OpenNBS "Tempo Changer" custom
-- instruments), schedules notes across player computers, and extracts
-- .nbs files from stored (uncompressed) zips as served by noteblock.world.
-- Install to /usr/lib/nbs.lua. Pure Lua: also runs on desktop Lua 5.2+.
--
-- Memory design: notes are kept as packed byte strings at every stage
-- (5 bytes per note while parsing, 6 bytes per scheduled action), never
-- as per-note tables, so even 100KB+ songs fit small OC machines. Long
-- loops call nbs.onYield periodically (set it to os.sleep(0) in OpenOS
-- programs) so big songs don't trip the "too long without yielding"
-- watchdog.

local nbs = {}

-- Called every few hundred notes inside heavy loops; assign a function
-- that yields (e.g. function() os.sleep(0) end) when running in OpenOS.
nbs.onYield = nil

local opsCount = 0
local function breathe()
  opsCount = opsCount + 1
  if opsCount % 1000 == 0 and nbs.onYield then nbs.onYield() end
end

nbs.INSTRUMENTS = {
  [0] = "Piano", "Double Bass", "Bass Drum", "Snare Drum", "Click",
  "Guitar", "Flute", "Bell", "Chime", "Xylophone", "Iron Xylophone",
  "Cow Bell", "Didgeridoo", "Bit", "Banjo", "Pling",
}

nbs.INSTRUMENT_BLOCKS = {
  [0] = "Air/other", "Wood", "Stone", "Sand", "Glass",
  "Wool", "Clay", "Block of Gold", "Packed Ice", "Bone Block",
  "Iron Block", "Soul Sand", "Pumpkin", "Block of Emerald", "Hay Bale",
  "Glowstone",
}

--------------------------------------------------------------- reader ----

local Reader = {}
Reader.__index = Reader

local function newReader(data, pos)
  return setmetatable({ data = data, pos = pos or 1 }, Reader)
end

function Reader:u8()
  local b = self.data:byte(self.pos)
  self.pos = self.pos + 1
  return b or 0
end

function Reader:u16()
  local a, b = self.data:byte(self.pos, self.pos + 1)
  self.pos = self.pos + 2
  return (a or 0) + (b or 0) * 256
end

function Reader:i16()
  local v = self:u16()
  if v >= 32768 then v = v - 65536 end
  return v
end

function Reader:i32()
  local a, b, c, d = self.data:byte(self.pos, self.pos + 3)
  self.pos = self.pos + 4
  local v = (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end

function Reader:str()
  local len = self:i32()
  if len <= 0 then return "" end
  local s = self.data:sub(self.pos, self.pos + len - 1)
  self.pos = self.pos + len
  return s
end

function Reader:skip(n)
  self.pos = self.pos + n
end

function Reader:eof()
  return self.pos > #self.data
end

--------------------------------------------------------------- parser ----

-- Packed note record inside a tick bucket: 5 bytes.
-- instrument, key, velocity (layer volume already applied), pitch+32768 LE.
local function packNote(inst, key, vel, pitch)
  local p = pitch + 32768
  return string.char(inst % 256, key % 256, vel % 256,
    p % 256, math.floor(p / 256) % 256)
end

-- Iterates the packed notes of a tick bucket (or any 5-byte note string).
-- Yields instrument, key, velocity, pitch(detune in cents).
function nbs.eachNote(data)
  local i = -5
  return function()
    i = i + 5
    local inst, key, vel, p1, p2 = data:byte(i + 1, i + 5)
    if not p2 then return nil end
    return inst, key, vel, (p1 + p2 * 256) - 32768
  end
end

-- Parses .nbs file contents (a string). Returns a song table:
--   version, vanillaCount, lengthTicks, name, author, originalAuthor,
--   description, tempo (ticks/second), timeSignature, loop{...},
--   noteCount, customInstruments[0..n] = {name, file, pitch},
--   ticks = { {t=<tick>, n=<packed notes>}, ... }   (see nbs.eachNote)
function nbs.parse(data)
  if type(data) ~= "string" or #data < 8 then
    return nil, "not a valid NBS file"
  end
  local r = newReader(data)
  local song = { customInstruments = {} }

  local first = r:u16()
  if first == 0 then
    song.version = r:u8()
    if song.version < 1 or song.version > 5 then
      return nil, "unsupported NBS version " .. song.version
    end
    song.vanillaCount = r:u8()
    if song.version >= 3 then song.lengthTicks = r:u16() end
  else
    song.version = 0
    song.vanillaCount = 10
    song.lengthTicks = first
  end

  song.layerCount = r:u16()
  song.name = r:str()
  song.author = r:str()
  song.originalAuthor = r:str()
  song.description = r:str()
  song.tempo = r:u16() / 100
  if song.tempo <= 0 then song.tempo = 10 end
  r:skip(2) -- auto-save enabled + duration
  song.timeSignature = r:u8()
  r:skip(20) -- minutes spent, left/right clicks, blocks added/removed
  r:str() -- MIDI/schematic import name
  if song.version >= 4 then
    song.loop = {
      enabled = r:u8() ~= 0,
      maxCount = r:u8(),
      startTick = r:u16(),
    }
  end

  -- pass 1: skim the note section (layer volumes live after it, but we
  -- need them to bake velocities, so notes are decoded in pass 2)
  local noteStart = r.pos
  local noteSize = song.version >= 4 and 6 or 2
  while true do
    local jump = r:u16()
    if jump == 0 or r:eof() then break end
    while true do
      local layerJump = r:u16()
      if layerJump == 0 then break end
      r:skip(noteSize)
      breathe()
    end
  end
  local noteEnd = r.pos

  -- layer section
  local layerVolume = {}
  for i = 0, song.layerCount - 1 do
    if r:eof() then break end
    r:str() -- layer name
    if song.version >= 4 then r:skip(1) end -- lock
    layerVolume[i] = r:u8()
    if song.version >= 2 then r:skip(1) end -- stereo
  end

  -- custom instruments
  if not r:eof() then
    local count = r:u8()
    for i = 0, count - 1 do
      if r:eof() then break end
      song.customInstruments[i] = {
        name = r:str(),
        file = r:str(),
        pitch = r:u8(),
      }
      r:skip(1) -- press key
    end
  end

  -- pass 2: decode notes into one packed string per tick
  local n = newReader(data, noteStart)
  local ticks = {}
  local tick = -1
  local total = 0
  while n.pos < noteEnd do
    local jump = n:u16()
    if jump == 0 then break end
    tick = tick + jump
    local layer = -1
    local parts = {}
    while true do
      local layerJump = n:u16()
      if layerJump == 0 then break end
      layer = layer + layerJump
      local inst = n:u8()
      local key = n:u8()
      local vel, pitch = 100, 0
      if song.version >= 4 then
        vel = n:u8()
        n:skip(1) -- panning
        pitch = n:i16()
      end
      local volume = layerVolume[layer]
      if volume and volume < 100 then
        vel = math.floor(vel * volume / 100 + 0.5)
      end
      parts[#parts + 1] = packNote(inst, key, vel, pitch)
      total = total + 1
      breathe()
    end
    if #parts > 0 then
      ticks[#ticks + 1] = { t = tick, n = table.concat(parts) }
    end
  end
  song.ticks = ticks
  song.noteCount = total
  if not song.lengthTicks or song.lengthTicks == 0 then
    song.lengthTicks = #ticks > 0 and (ticks[#ticks].t + 1) or 0
  end
  return song
end

-------------------------------------------------------------- timeline ---

-- Converts the tick-based song into events with absolute times (seconds),
-- applying OpenNBS "Tempo Changer" notes (pitch field = tempo t/s * 15).
-- Returns events = { {time=<s>, n=<packed notes>}, ... }, duration.
function nbs.timeline(song)
  local tempoChanger = {}
  local hasChangers = false
  for idx, ci in pairs(song.customInstruments) do
    if ci.name == "Tempo Changer" then
      tempoChanger[song.vanillaCount + idx] = true
      hasChangers = true
    end
  end

  local events = {}
  local tempo = song.tempo
  local lastTick, lastTime = 0, 0
  for _, bucket in ipairs(song.ticks) do
    local time = lastTime + (bucket.t - lastTick) / tempo
    lastTick, lastTime = bucket.t, time
    local payload = bucket.n
    if hasChangers then
      -- strip tempo changer notes, applying their tempo
      local needsFilter = false
      for inst in nbs.eachNote(payload) do
        if tempoChanger[inst] then
          needsFilter = true
          break
        end
      end
      if needsFilter then
        local kept = {}
        for inst, key, vel, pitch in nbs.eachNote(payload) do
          if tempoChanger[inst] then
            local newTempo = math.abs(pitch) / 15
            if newTempo > 0.1 then tempo = newTempo end
          else
            kept[#kept + 1] = packNote(inst, key, vel, pitch)
          end
        end
        payload = table.concat(kept)
      end
    end
    if #payload > 0 then
      events[#events + 1] = { time = time, n = payload }
    end
    breathe()
  end

  local duration = lastTime + (song.lengthTicks - lastTick) / tempo
  if #events > 0 then
    duration = math.max(duration, events[#events].time)
  end
  return events, duration
end

----------------------------------------------------------------- pitch ---

-- Maps an NBS key (0-87, with optional detune in cents) to a note block
-- pitch (1-25, key 33 = F#3 = pitch 1). Out-of-range keys are folded by
-- whole octaves into the playable range instead of clamping, so melodies
-- stay recognizable.
function nbs.blockPitch(key, detune)
  local k = key + math.floor((detune or 0) / 100 + 0.5)
  local p = k - 32
  while p < 1 do p = p + 12 end
  while p > 25 do p = p - 12 end
  return p
end

-------------------------------------------------------------- encoding ---

-- Wire format for a scheduled action: 6 bytes.
-- time in 10ms units (3 bytes little-endian), kind, a, b.
-- kind 0-249  = instrument id: trigger note, a = pitch
-- kind 250    = redstone volley: a = device index (0-based), b = side mask
nbs.RECORD_SIZE = 6
nbs.KIND_VOLLEY = 250

local function packRecord(fire, kind, a, b)
  local cs = math.floor(fire * 100 + 0.5)
  return string.char(
    cs % 256,
    math.floor(cs / 256) % 256,
    math.floor(cs / 65536) % 256,
    kind % 256,
    a % 256,
    b % 256)
end

-- Encodes a list of {t=, inst=, p=} / {t=, volley=true, dev=, mask=}.
function nbs.encodeRecords(records)
  local out = {}
  for _, rec in ipairs(records) do
    if rec.volley then
      out[#out + 1] = packRecord(rec.t, nbs.KIND_VOLLEY, rec.dev - 1, rec.mask)
    else
      out[#out + 1] = packRecord(rec.t, rec.inst, rec.p, 0)
    end
  end
  return table.concat(out)
end

-- Reads record #i (1-based) from an encoded blob.
-- Returns time (seconds), kind, a, b (see above).
function nbs.readRecord(blob, i)
  local base = (i - 1) * nbs.RECORD_SIZE
  local t1, t2, t3, kind, a, b = blob:byte(base + 1, base + 6)
  if not b then return nil end
  return (t1 + t2 * 256 + t3 * 65536) / 100, kind, a, b
end

------------------------------------------------------------- scheduler ---

-- Distributes events across players honoring instruments and capacity.
--
-- Two ways to make a sound, with different costs (from the OC source):
--  * note_block.trigger(pitch) - synchronized call, parks the machine for
--    ~1 game tick. Flexible pitch, but max ~20 notes/s per computer.
--  * redstone.setOutput{...} - synchronized call + a machine pause of
--    misc.redstoneDelay (default 0.1s), BUT one call sets all 6 sides at
--    once: six pre-tuned note blocks fire perfectly simultaneously.
--
-- players: { {
--     inst  = {[instrumentId] = blockCount},        -- adapter blocks
--     banks = { {inst = {[side 0-5] = instrumentId}}, ... }  -- optional
--   }, ... }
-- opts.perTick:  max trigger notes per player per game tick (default 1)
-- opts.fallback: substitute an available instrument when no player has
--                the required one (default true)
-- opts.rsDelay:  the server's misc.redstoneDelay in seconds (default 0.1)
-- opts.slack:    ticks a note may fire LATE before it is dropped
--                (default 2); 0 = strict on-time or drop
--
-- Returns:
--   assignments[playerIndex] = encoded action blob (see nbs.readRecord),
--     sorted by time and streamed during scheduling - per-note tables are
--     never materialized, so large songs fit in memory
--   stats   = { total, played, dropped, merged, substituted, bank, late }
--   tunings[playerIndex] = { {dev=<n>, side=<0-5>, pitch=<1-25>}, ... }
function nbs.schedule(events, players, opts)
  opts = opts or {}
  local perTick = opts.perTick or 1
  local fallback = opts.fallback ~= false
  local rsDelay = opts.rsDelay or 0.1
  local TICK = 0.05
  local dynCost = TICK / perTick
  local volleyCost = TICK + rsDelay
  local slack = (opts.slack or 2) * TICK

  local stats = { total = 0, played = 0, dropped = 0, merged = 0,
    substituted = 0, bank = 0, late = 0 }

  -- streaming output: a small pending buffer per player keeps records
  -- ordered (a record can precede at most slack seconds of later ones)
  local outs = {}
  local busyUntil = {}
  local anyPlayers = {}
  local currentVolley = {} -- [player][dev] = pending volley entry
  local lastVolleyFire = {} -- [player][dev] = last volley time
  for i, player in ipairs(players) do
    outs[i] = { parts = {}, pending = {} }
    busyUntil[i] = 0
    currentVolley[i] = {}
    lastVolleyFire[i] = {}
    if next(player.inst) then anyPlayers[#anyPlayers + 1] = i end
  end

  local function flush(out, upto)
    local pending = out.pending
    while pending[1] and pending[1].fire < upto - 1e-9 do
      local entry = table.remove(pending, 1)
      if entry.volley then
        local mask = 0
        for side in pairs(entry.volley) do mask = mask + 2 ^ side end
        out.parts[#out.parts + 1] =
          packRecord(entry.fire, nbs.KIND_VOLLEY, entry.dev - 1, mask)
      else
        out.parts[#out.parts + 1] =
          packRecord(entry.fire, entry.inst, entry.p, 0)
      end
    end
  end

  local function enqueue(out, entry)
    local pending = out.pending
    local i = #pending
    while i > 0 and pending[i].fire > entry.fire do i = i - 1 end
    table.insert(pending, i + 1, entry)
  end

  -- pass A: how often each distinct (instrument, pitch) occurs
  local freq = {}
  for _, event in ipairs(events) do
    for inst, key, _, pitch in nbs.eachNote(event.n) do
      local pairKey = inst * 32 + nbs.blockPitch(key, pitch)
      freq[pairKey] = (freq[pairKey] or 0) + 1
      breathe()
    end
  end

  -- collect bank channels and tune them: the hottest (inst, pitch) pairs
  -- get channels first; surplus channels duplicate the hottest pairs
  local channels = {}
  local byInst = {}
  for pi, player in ipairs(players) do
    for di, dev in ipairs(player.banks or {}) do
      for side = 0, 5 do
        local instId = dev.inst and dev.inst[side]
        if instId then
          local chan = { player = pi, dev = di, side = side, inst = instId }
          channels[#channels + 1] = chan
          byInst[instId] = byInst[instId] or {}
          table.insert(byInst[instId], chan)
        end
      end
    end
  end

  local tunings = {}
  for i = 1, #players do tunings[i] = {} end
  local bankFor = {} -- [inst*32+pitch] = {channel, ...}
  for instId, list in pairs(byInst) do
    local pairsOf = {}
    for key, count in pairs(freq) do
      if math.floor(key / 32) == instId then
        pairsOf[#pairsOf + 1] = { key = key, count = count }
      end
    end
    table.sort(pairsOf, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return a.key < b.key
    end)
    if #pairsOf > 0 then
      for i, chan in ipairs(list) do
        local pair = pairsOf[((i - 1) % #pairsOf) + 1]
        chan.pitch = pair.key % 32
        chan.state = "off"
        bankFor[pair.key] = bankFor[pair.key] or {}
        table.insert(bankFor[pair.key], chan)
        table.insert(tunings[chan.player],
          { dev = chan.dev, side = chan.side, pitch = chan.pitch })
      end
    end
  end

  local capable = {}
  local function playersFor(inst)
    local list = capable[inst]
    if not list then
      list = {}
      for i, player in ipairs(players) do
        if (player.inst[inst] or 0) > 0 then list[#list + 1] = i end
      end
      capable[inst] = list
    end
    return list
  end

  -- an instrument the player can actually play, piano preferred
  local function substituteFor(playerIndex)
    local inst = players[playerIndex].inst
    if (inst[0] or 0) > 0 then return 0 end
    local best
    for id in pairs(inst) do
      if not best or id < best then best = id end
    end
    return best
  end

  -- a new volley powers exactly its own sides, so every channel the
  -- device previously held high gets its rising edge back
  local function resetDevice(pi, di)
    for _, chan in ipairs(channels) do
      if chan.player == pi and chan.dev == di and chan.state == "on" then
        chan.state = "off"
      end
    end
  end

  for _, event in ipairs(events) do
    local t = event.time
    for i = 1, #players do flush(outs[i], t) end

    -- dedupe identical (instrument, pitch) notes; they sound the same
    local seen, list = {}, {}
    for inst, key, vel, pitch in nbs.eachNote(event.n) do
      stats.total = stats.total + 1
      local p = nbs.blockPitch(key, pitch)
      local dupKey = inst * 32 + p
      if seen[dupKey] then
        stats.merged = stats.merged + 1
      else
        seen[dupKey] = true
        list[#list + 1] = { inst = inst, p = p, vel = vel }
      end
      breathe()
    end
    -- loudest notes get first pick of the available capacity
    table.sort(list, function(a, b) return a.vel > b.vel end)

    for _, note in ipairs(list) do
      local placed = false

      -- 1) a pre-tuned redstone channel, if one is free: perfectly
      --    simultaneous and it can join a volley that is already firing
      for _, chan in ipairs(bankFor[note.inst * 32 + note.p] or {}) do
        if chan.state == "off" then
          local cur = currentVolley[chan.player][chan.dev]
          if cur and math.abs(cur.fire - t) < 0.001 then
            if not cur.volley[chan.side] then
              cur.volley[chan.side] = true
              chan.state = "on"
              placed = true
            end
          elseif (not cur or t - cur.fire >= volleyCost - 1e-9)
            and busyUntil[chan.player] <= t + 1e-9 then
            resetDevice(chan.player, chan.dev)
            local entry = { fire = t, dev = chan.dev,
              volley = { [chan.side] = true } }
            enqueue(outs[chan.player], entry)
            currentVolley[chan.player][chan.dev] = entry
            lastVolleyFire[chan.player][chan.dev] = t
            chan.state = "on"
            busyUntil[chan.player] = t + volleyCost
            placed = true
          end
        end
        if placed then break end
      end
      if placed then
        stats.bank = stats.bank + 1
        stats.played = stats.played + 1
      else
        -- 2) a dynamic note block via adapter trigger
        local candidates = playersFor(note.inst)
        local substituted = false
        if #candidates == 0 and fallback then
          candidates = playersFor(0)
          if #candidates == 0 then candidates = anyPlayers end
          substituted = true
        end

        -- earliest machine wins; a busy machine is still eligible if the
        -- note would fire at most `slack` late
        local best, bestBusy
        for _, pi in ipairs(candidates) do
          local b = busyUntil[pi]
          if b <= t + slack + 1e-9 and (not best or b < bestBusy) then
            best, bestBusy = pi, b
          end
        end

        if best then
          local fireAt = math.max(t, busyUntil[best])
          busyUntil[best] = fireAt + dynCost
          local inst = note.inst
          if substituted then
            inst = substituteFor(best)
            stats.substituted = stats.substituted + 1
          end
          enqueue(outs[best], { fire = fireAt, inst = inst, p = note.p })
          stats.played = stats.played + 1
          if fireAt > t + 0.001 then stats.late = stats.late + 1 end
        else
          stats.dropped = stats.dropped + 1
        end
      end
    end
  end

  -- drain the reorder buffers and release every powered bank channel
  local assignments = {}
  for pi = 1, #players do
    flush(outs[pi], math.huge)
    local offs = {}
    for di, fire in pairs(lastVolleyFire[pi]) do
      offs[#offs + 1] = { fire = fire + volleyCost, dev = di }
    end
    table.sort(offs, function(a, b) return a.fire < b.fire end)
    for _, off in ipairs(offs) do
      outs[pi].parts[#outs[pi].parts + 1] =
        packRecord(off.fire, nbs.KIND_VOLLEY, off.dev - 1, 0)
    end
    assignments[pi] = table.concat(outs[pi].parts)
    outs[pi] = nil
  end

  return assignments, stats, tunings
end

--------------------------------------------------------------- utility ---

-- Splits a noteplayer calibration between m machines that share one
-- component network (e.g. server blades in a rack, which all see the same
-- note_block addresses). Machine n (1-based) takes every m-th block of
-- each instrument and every m-th redstone bank, so no two machines ever
-- fight over the same block in the same game tick (the block event would
-- dedupe and the pitches would race).
function nbs.partitionCalibration(config, n, m)
  local bankOwned = {}
  for _, bank in ipairs(config.banks or {}) do
    for _, address in pairs(bank.sides or {}) do
      bankOwned[address] = true
    end
  end

  -- deterministic split of the dynamic blocks, per instrument
  local byInst = {}
  for address, inst in pairs(config.blocks or {}) do
    if not bankOwned[address] then
      byInst[inst] = byInst[inst] or {}
      table.insert(byInst[inst], address)
    end
  end
  local blocks = {}
  for inst, list in pairs(byInst) do
    table.sort(list)
    for i, address in ipairs(list) do
      if (i - 1) % m == n - 1 then blocks[address] = inst end
    end
  end

  -- whole bank devices round-robin; their blocks follow their device
  local banks = {}
  for i, bank in ipairs(config.banks or {}) do
    if (i - 1) % m == n - 1 then
      banks[#banks + 1] = bank
      for _, address in pairs(bank.sides or {}) do
        blocks[address] = (config.blocks or {})[address]
      end
    end
  end

  return { blocks = blocks, banks = banks }
end

-- Expands a volley side mask into a setOutput() table for sides 0-5.
function nbs.maskToSides(mask)
  local values = {}
  for side = 0, 5 do
    values[side] = mask % 2 == 1 and 15 or 0
    mask = math.floor(mask / 2)
  end
  return values
end

------------------------------------------------------------------- zip ---

-- Extracts the first file matching `pattern` from a ZIP archive that
-- stores entries uncompressed (as noteblock.world packed songs do).
-- Returns contents, entryName or nil, error.
function nbs.unzipStored(zipData, pattern)
  local function u16(pos)
    local a, b = zipData:byte(pos, pos + 1)
    return (a or 0) + (b or 0) * 256
  end
  local function u32(pos)
    local a, b, c, d = zipData:byte(pos, pos + 3)
    return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
  end

  -- find the end-of-central-directory record (may be followed by a comment)
  local eocd
  for i = #zipData - 21, math.max(1, #zipData - 65557), -1 do
    if zipData:sub(i, i + 3) == "PK\5\6" then
      eocd = i
      break
    end
  end
  if not eocd then return nil, "not a zip archive" end

  local count = u16(eocd + 10)
  local pos = u32(eocd + 16) + 1
  for _ = 1, count do
    if zipData:sub(pos, pos + 3) ~= "PK\1\2" then
      return nil, "corrupt zip central directory"
    end
    local method = u16(pos + 10)
    local compSize = u32(pos + 20)
    local nameLen = u16(pos + 28)
    local extraLen = u16(pos + 30)
    local commentLen = u16(pos + 32)
    local localOffset = u32(pos + 42)
    local name = zipData:sub(pos + 46, pos + 45 + nameLen)
    if name:match(pattern) then
      if method ~= 0 then
        return nil, "zip entry '" .. name .. "' is compressed"
      end
      local lp = localOffset + 1
      if zipData:sub(lp, lp + 3) ~= "PK\3\4" then
        return nil, "corrupt zip local header"
      end
      local dataStart = lp + 30 + u16(lp + 26) + u16(lp + 28)
      return zipData:sub(dataStart, dataStart + compSize - 1), name
    end
    pos = pos + 46 + nameLen + extraLen + commentLen
  end
  return nil, "no entry matching '" .. pattern .. "' in archive"
end

return nbs
