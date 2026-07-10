-- nbs.lua: Note Block Studio (.nbs) toolkit for OpenComputers.
-- Parses every NBS version (classic v0 through OpenNBS v5), converts songs
-- to an absolute-time event list (handling OpenNBS "Tempo Changer" custom
-- instruments), schedules notes across player computers with per-tick
-- capacity limits, and extracts .nbs files from stored (uncompressed) zips
-- as served by noteblock.world.
-- Install to /usr/lib/nbs.lua. Pure Lua: also runs on desktop Lua 5.2+.

local nbs = {}

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

local function newReader(data)
  return setmetatable({ data = data, pos = 1 }, Reader)
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

-- Parses .nbs file contents (a string). Returns a song table:
--   version, vanillaCount, lengthTicks, name, author, originalAuthor,
--   description, tempo (ticks/second), timeSignature, loop{...},
--   noteCount, customInstruments[0..n] = {name, file, pitch},
--   ticks = { {t=<tick>, notes={ {inst,key,vel,pitch}... }}, ... }
-- Note velocity already includes the layer volume (0-100).
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

  -- note section
  local ticks = {}
  local tick = -1
  while true do
    local jump = r:u16()
    if jump == 0 or r:eof() then break end
    tick = tick + jump
    local layer = -1
    local bucket = {}
    while true do
      local layerJump = r:u16()
      if layerJump == 0 then break end
      layer = layer + layerJump
      local note = {
        layer = layer,
        inst = r:u8(),
        key = r:u8(),
        vel = 100,
        pitch = 0,
      }
      if song.version >= 4 then
        note.vel = r:u8()
        r:skip(1) -- panning
        note.pitch = r:i16()
      end
      bucket[#bucket + 1] = note
    end
    if #bucket > 0 then
      ticks[#ticks + 1] = { t = tick, notes = bucket }
    end
  end
  song.ticks = ticks

  -- layer section (apply layer volume to note velocity)
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

  local total = 0
  for _, bucket in ipairs(ticks) do
    for _, note in ipairs(bucket.notes) do
      local volume = layerVolume[note.layer]
      if volume and volume < 100 then
        note.vel = math.floor(note.vel * volume / 100 + 0.5)
      end
      note.layer = nil
      total = total + 1
    end
  end
  song.noteCount = total
  if not song.lengthTicks or song.lengthTicks == 0 then
    song.lengthTicks = #ticks > 0 and (ticks[#ticks].t + 1) or 0
  end
  return song
end

-------------------------------------------------------------- timeline ---

-- Converts the tick-based song into events with absolute times (seconds),
-- applying OpenNBS "Tempo Changer" notes (pitch field = tempo t/s * 15).
-- Returns events = { {time=<s>, notes={ {inst,key,vel,pitch}... }}, ... }
-- and the total duration in seconds.
function nbs.timeline(song)
  local tempoChanger = {}
  for idx, ci in pairs(song.customInstruments) do
    if ci.name == "Tempo Changer" then
      tempoChanger[song.vanillaCount + idx] = true
    end
  end

  local events = {}
  local tempo = song.tempo
  local lastTick, lastTime = 0, 0
  for _, bucket in ipairs(song.ticks) do
    local time = lastTime + (bucket.t - lastTick) / tempo
    lastTick, lastTime = bucket.t, time
    local playable = {}
    for _, note in ipairs(bucket.notes) do
      if tempoChanger[note.inst] then
        local newTempo = math.abs(note.pitch) / 15
        if newTempo > 0.1 then tempo = newTempo end
      else
        playable[#playable + 1] = note
      end
    end
    if #playable > 0 then
      events[#events + 1] = { time = time, notes = playable }
    end
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

------------------------------------------------------------- scheduler ---

-- Distributes events across players honoring instruments and capacity.
--
-- Two ways to make a sound, with different costs (from the OC source):
--  * note_block.trigger(pitch) - synchronized call, parks the machine for
--    ~1 game tick. Flexible pitch, but max ~20 notes/s per computer and
--    chords smear across ticks.
--  * redstone.setOutput{...} - synchronized call + a machine pause of
--    misc.redstoneDelay (default 0.1s = 2 ticks), BUT one call sets all
--    6 sides at once, and a note block fires on a redstone rising edge
--    with whatever pitch was pre-set. Six pre-tuned note blocks per
--    redstone device = a perfectly simultaneous 6-note "volley".
--
-- players: { {
--     inst  = {[instrumentId] = blockCount},        -- adapter blocks
--     banks = { {inst = {[side 0-5] = instrumentId}}, ... }  -- optional
--   }, ... }
-- opts.perTick:  max trigger notes per player per game tick (default 1)
-- opts.fallback: substitute an available instrument when no player has
--                the required one (default true)
-- opts.rsDelay:  the server's misc.redstoneDelay in seconds (default 0.1)
--
-- Returns:
--   assignments[playerIndex] = sorted list of
--     {t=<seconds>, inst=<id>, p=<1-25>}           (trigger note)
--     {t=<seconds>, volley=true, dev=<n>, mask=<0-63>}  (redstone volley)
--   stats   = { total, played, dropped, merged, substituted, bank }
--   tunings[playerIndex] = { {dev=<n>, side=<0-5>, pitch=<1-25>}, ... }
--     (per-song pitches the player must set on its bank blocks first)
function nbs.schedule(events, players, opts)
  opts = opts or {}
  local perTick = opts.perTick or 1
  local fallback = opts.fallback ~= false
  local rsDelay = opts.rsDelay or 0.1
  local TICK = 0.05
  local dynCost = TICK / perTick
  local volleyCost = TICK + rsDelay

  local stats = { total = 0, played = 0, dropped = 0, merged = 0,
    substituted = 0, bank = 0 }
  local assignments = {}
  local busyUntil = {} -- per player machine: earliest time it is free again
  local anyPlayers = {}
  for i, player in ipairs(players) do
    assignments[i] = {}
    busyUntil[i] = 0
    if next(player.inst) then anyPlayers[#anyPlayers + 1] = i end
  end

  -- pass A: how often each distinct (instrument, pitch) occurs
  local freq = {}
  for _, event in ipairs(events) do
    for _, note in ipairs(event.notes) do
      local key = note.inst * 32 + nbs.blockPitch(note.key, note.pitch)
      freq[key] = (freq[key] or 0) + 1
    end
  end

  -- collect bank channels and tune them: the hottest (inst, pitch) pairs
  -- get channels first; surplus channels duplicate the hottest pairs so
  -- fast repeats can alternate between two devices
  local channels = {}
  local byInst = {}
  local volleys = {} -- volleys[player][dev] = { {t=, chans={side=true}}, ... }
  for pi, player in ipairs(players) do
    volleys[pi] = {}
    for di, dev in ipairs(player.banks or {}) do
      volleys[pi][di] = {}
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

    -- dedupe identical (instrument, pitch) notes; they sound the same
    local seen, list = {}, {}
    for _, note in ipairs(event.notes) do
      stats.total = stats.total + 1
      local p = nbs.blockPitch(note.key, note.pitch)
      local dupKey = note.inst * 32 + p
      if seen[dupKey] then
        stats.merged = stats.merged + 1
      else
        seen[dupKey] = true
        list[#list + 1] = { inst = note.inst, p = p, vel = note.vel }
      end
    end
    -- loudest notes get first pick of the available capacity
    table.sort(list, function(a, b) return a.vel > b.vel end)

    for _, note in ipairs(list) do
      local placed = false

      -- 1) a pre-tuned redstone channel, if one is free: perfectly
      --    simultaneous and it can join a volley that is already firing
      for _, chan in ipairs(bankFor[note.inst * 32 + note.p] or {}) do
        if chan.state == "off" then
          local devVolleys = volleys[chan.player][chan.dev]
          local last = devVolleys[#devVolleys]
          if last and math.abs(last.t - t) < 0.001 then
            if not last.chans[chan.side] then
              last.chans[chan.side] = true
              chan.state = "on"
              placed = true
            end
          elseif (not last or t - last.t >= volleyCost - 1e-9)
            and busyUntil[chan.player] <= t + 1e-9 then
            resetDevice(chan.player, chan.dev)
            devVolleys[#devVolleys + 1] = { t = t, chans = { [chan.side] = true } }
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

        local best, bestBusy
        for _, pi in ipairs(candidates) do
          local b = busyUntil[pi]
          if b <= t + TICK - dynCost + 1e-9 and (not best or b < bestBusy) then
            best, bestBusy = pi, b
          end
        end

        if best then
          busyUntil[best] = math.max(busyUntil[best], t) + dynCost
          local inst = note.inst
          if substituted then
            inst = substituteFor(best)
            stats.substituted = stats.substituted + 1
          end
          local a = assignments[best]
          a[#a + 1] = { t = t, inst = inst, p = note.p }
          stats.played = stats.played + 1
        else
          stats.dropped = stats.dropped + 1
        end
      end
    end
  end

  -- turn volleys into records; a trailing all-off volley releases every
  -- channel once the song is over
  for pi = 1, #players do
    for di, list in ipairs(volleys[pi]) do
      for _, volley in ipairs(list) do
        local mask = 0
        for side in pairs(volley.chans) do
          mask = mask + 2 ^ side
        end
        table.insert(assignments[pi],
          { t = volley.t, volley = true, dev = di, mask = mask })
      end
      if #list > 0 then
        table.insert(assignments[pi],
          { t = list[#list].t + volleyCost, volley = true, dev = di, mask = 0 })
      end
    end
    table.sort(assignments[pi], function(a, b) return a.t < b.t end)
  end

  return assignments, stats, tunings
end

-------------------------------------------------------------- encoding ---

-- Wire format for a scheduled action: 6 bytes.
-- time in 10ms units (3 bytes little-endian), kind, a, b.
-- kind 0-249  = instrument id: trigger note, a = pitch
-- kind 250    = redstone volley: a = device index (0-based), b = side mask
nbs.RECORD_SIZE = 6
nbs.KIND_VOLLEY = 250

function nbs.encodeRecords(records)
  local out = {}
  for _, rec in ipairs(records) do
    local cs = math.floor(rec.t * 100 + 0.5)
    local kind, a, b
    if rec.volley then
      kind, a, b = nbs.KIND_VOLLEY, rec.dev - 1, rec.mask
    else
      kind, a, b = rec.inst, rec.p, 0
    end
    out[#out + 1] = string.char(
      cs % 256,
      math.floor(cs / 256) % 256,
      math.floor(cs / 65536) % 256,
      kind % 256,
      a % 256,
      b % 256)
  end
  return table.concat(out)
end

-- Reads record #i (1-based) from an encoded blob.
-- Returns time (seconds), kind, a, b (see encodeRecords).
function nbs.readRecord(blob, i)
  local base = (i - 1) * nbs.RECORD_SIZE
  local t1, t2, t3, kind, a, b = blob:byte(base + 1, base + 6)
  if not b then return nil end
  return (t1 + t2 * 256 + t3 * 65536) / 100, kind, a, b
end

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
