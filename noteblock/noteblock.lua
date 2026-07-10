-- noteblock: modern note block music player for OpenComputers.
-- Plays .nbs songs (all NBS versions) on vanilla note blocks, with built-in
-- noteblock.world browsing, search and download. Notes are scheduled across
-- every available player: this computer's own calibrated note blocks plus
-- any number of remote "noteplayer" nodes -- because each note block
-- trigger costs ~1 game tick, more players means denser songs play clean.
--
-- Usage:
--   noteblock                       browse noteblock.world interactively
--   noteblock play <target> [...]   play files/URLs/noteblock.world ids
--   noteblock search <words...>     quick search
--   noteblock players               list available player nodes
--   noteblock stop                  stop all nodes
--
-- Targets: /path/song.nbs | https://noteblock.world/song/<id> | <id> | any URL
-- Options:
--   --port=3001      protocol port
--   --pertick=1      max notes per player per game tick (raise if you don't
--                    mind notes slipping a tick on dense chords)
--   --wait=2         seconds to wait for player discovery
--   --nofallback     drop notes for missing instruments instead of
--                    substituting an available one
--
-- Playback keys: [space] pause/resume, [q] stop.
-- Requires: /usr/lib/nbs.lua, /usr/lib/json.lua; an internet card for
-- noteblock.world; a wireless card for remote players. Local playback needs
-- note blocks calibrated with 'noteplayer calibrate'.

local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local internet = require("internet")
local json = require("json")
local nbs = require("nbs")
local serialization = require("serialization")
local shell = require("shell")
local term = require("term")

local API = "https://api.noteblock.world/v1"
local MUSIC_DIR = "/home/music"
local PROTOCOL = "NBP2"
local PLAYER_CONFIG = "/etc/noteplayer.cfg"
local PAGE_SIZE = 8

local args, opts = shell.parse(...)
local port = tonumber(opts.port) or 3001

local function printf(fmt, ...) io.write(string.format(fmt, ...), "\n") end

local function fail(msg)
  io.stderr:write("noteblock: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local function fmtTime(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

------------------------------------------------------------------- http --

local function fetch(url, headers)
  local ok, req = pcall(internet.request, url, nil, headers)
  if not ok then return nil, tostring(req) end
  local deadline = computer.uptime() + 30
  while true do
    local connOk, connected, reason = pcall(req.finishConnect)
    if not connOk then return nil, tostring(connected) end
    if connected then break end
    if connected == nil then return nil, tostring(reason or "connection failed") end
    if computer.uptime() > deadline then return nil, "connection timed out" end
    os.sleep(0.05)
  end
  local code, message = req.response()
  local chunks = {}
  local readOk, readErr = pcall(function()
    for chunk in req do
      chunks[#chunks + 1] = chunk
    end
  end)
  if code and (code < 200 or code >= 300) then
    return nil, string.format("HTTP %d %s", code, tostring(message or ""))
  end
  if not readOk then return nil, tostring(readErr) end
  return table.concat(chunks)
end

local UA = { ["User-Agent"] = "OC-Noteblock/2.0 (OpenComputers)" }

local function ensureInternet()
  if not component.isAvailable("internet") then
    fail("an internet card is required for noteblock.world features")
  end
end

local function apiJson(url)
  local body, err = fetch(url, UA)
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok then return nil, "bad response from noteblock.world" end
  return data
end

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

------------------------------------------------------- noteblock.world ---

local function sanitizeName(name)
  name = (name or ""):gsub("[^%w %-%._]", ""):gsub("%s+", " ")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if #name > 40 then name = name:sub(1, 40) end
  return name
end

-- Downloads a song by public id. Returns path, meta.
local function downloadSong(id)
  ensureInternet()
  local meta = apiJson(API .. "/song/" .. id) or {}
  io.write("fetching download link... ")
  local url, err = fetch(API .. "/song/" .. id .. "/open",
    { ["User-Agent"] = UA["User-Agent"], src = "downloadButton" })
  if not url then
    print("")
    fail("cannot get song from noteblock.world: " .. tostring(err))
  end
  url = url:gsub("^%s*\"?", ""):gsub("\"?%s*$", "")
  print("ok")
  io.write("downloading song... ")
  local zip, zerr = fetch(url)
  if not zip then
    print("")
    fail("download failed: " .. tostring(zerr))
  end
  local data, uerr = nbs.unzipStored(zip, "%.nbs$")
  if not data then
    print("")
    fail(tostring(uerr))
  end
  printf("ok (%d bytes)", #data)

  fs.makeDirectory(MUSIC_DIR)
  local base = sanitizeName(meta.title)
  if base == "" then base = id end
  local path = fs.concat(MUSIC_DIR, base .. "." .. id .. ".nbs")
  local f, ferr = io.open(path, "wb")
  if not f then fail("cannot save song: " .. tostring(ferr)) end
  f:write(data)
  f:close()
  return path, meta
end

-- Turns a play target (path, URL, id) into a local .nbs path.
local function resolveTarget(target)
  local path = shell.resolve(target)
  if fs.exists(path) and not fs.isDirectory(path) then return path end
  local id = target:match("^https?://noteblock%.world/song/([%w_%-]+)")
    or target:match("^nbw:([%w_%-]+)$")
  if not id and target:match("^[%w_%-]+$") and #target >= 8 and #target <= 12
    and not fs.exists(path) then
    id = target
  end
  if id then return (downloadSong(id)) end
  if target:match("^https?://") then
    ensureInternet()
    io.write("downloading " .. target .. " ... ")
    local data, err = fetch(target, UA)
    if not data then
      print("")
      fail("download failed: " .. tostring(err))
    end
    print("ok")
    if data:sub(1, 2) == "PK" then
      data = assert(nbs.unzipStored(data, "%.nbs$"))
    end
    fs.makeDirectory(MUSIC_DIR)
    local dest = fs.concat(MUSIC_DIR, "download.nbs")
    local f = io.open(dest, "wb")
    f:write(data)
    f:close()
    return dest
  end
  fail("no such file or song: " .. target)
end

---------------------------------------------------------------- players --

local function loadLocalBlocks()
  local blocks, counts = {}, {}
  local f = io.open(PLAYER_CONFIG, "r")
  if not f then return blocks, counts end
  local mapping = serialization.unserialize(f:read("*a") or "") or {}
  f:close()
  for address, inst in pairs(mapping) do
    if component.type(address) == "note_block" then
      local proxy = component.proxy(address)
      if proxy then
        blocks[inst] = blocks[inst] or {}
        table.insert(blocks[inst], proxy)
        counts[inst] = (counts[inst] or 0) + 1
      end
    end
  end
  return blocks, counts
end

local function openModem()
  if not component.isAvailable("modem") then return nil end
  local modem = component.modem
  modem.open(port)
  if modem.isWireless() then pcall(modem.setStrength, 400) end
  return modem
end

local function discoverPlayers(modem)
  local found = {}
  modem.broadcast(port, PROTOCOL, "discover")
  local deadline = computer.uptime() + (tonumber(opts.wait) or 2)
  while computer.uptime() < deadline do
    local sig = table.pack(event.pull(
      math.max(0.05, deadline - computer.uptime()), "modem_message"))
    if sig[1] == "modem_message" and sig[4] == port
      and sig[6] == PROTOCOL and sig[7] == "hello" then
      local inst = {}
      for id, count in tostring(sig[8]):gmatch("(%d+):(%d+)") do
        inst[tonumber(id)] = tonumber(count)
      end
      found[sig[3]] = inst
    end
  end
  local list = {}
  for addr, inst in pairs(found) do
    list[#list + 1] = { addr = addr, inst = inst }
  end
  table.sort(list, function(a, b) return a.addr < b.addr end)
  return list
end

-- Sends a player's schedule in chunks; retries missing chunks.
local CHUNK = 4000 -- multiple of nbs.RECORD_SIZE

local function transmit(modem, addr, songId, songName, blob)
  local last = math.ceil(#blob / CHUNK)
  modem.send(addr, port, PROTOCOL, "song", songId, songName)
  local want = {}
  for seq = 1, last do want[seq] = true end

  for _ = 1, 4 do
    local sent = 0
    for seq = 1, last do
      if want[seq] then
        modem.send(addr, port, PROTOCOL, "notes", songId, seq,
          blob:sub((seq - 1) * CHUNK + 1, seq * CHUNK))
        sent = sent + 1
        if sent % 16 == 0 then os.sleep(0.05) end
      end
    end
    modem.send(addr, port, PROTOCOL, "eof", songId, last)
    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
      local sig = table.pack(event.pull(
        math.max(0.05, deadline - computer.uptime()), "modem_message"))
      if sig[1] == "modem_message" and sig[3] == addr and sig[4] == port
        and sig[6] == PROTOCOL and sig[7] == "ready" and sig[8] == songId then
        local missing = tostring(sig[9] or "")
        if missing == "" then return true end
        want = {}
        for seq in missing:gmatch("%d+") do want[tonumber(seq)] = true end
        break
      end
    end
  end
  return false
end

--------------------------------------------------------------- playback --

local function runPlayback(session)
  local start = computer.uptime() + session.delay
  local paused, pausedAt = false, 0
  local nextLocal = 1
  local localTotal = session.localBlob
    and math.floor(#session.localBlob / nbs.RECORD_SIZE) or 0
  local ring = {}

  local function trigger(inst, pitch)
    local list = session.localBlocks[inst]
    if not list then
      local _, fallbackList = next(session.localBlocks)
      list = fallbackList
    end
    if not list or #list == 0 then return end
    ring[inst] = ((ring[inst] or 0) % #list) + 1
    pcall(list[ring[inst]].trigger, pitch)
  end

  local width = 80
  pcall(function() width = term.getViewport() end)

  local function elapsed()
    if paused then return pausedAt - start end
    return computer.uptime() - start
  end

  local function drawProgress()
    local e = math.max(0, math.min(elapsed(), session.duration))
    local label = string.format(" %s/%s %s", fmtTime(e),
      fmtTime(session.duration), paused and "|| paused" or "")
    local barWidth = math.max(10, width - #label - 3)
    local filled = math.floor(barWidth * e / math.max(1, session.duration))
    local _, y = term.getCursor()
    term.setCursor(1, y)
    term.clearLine()
    io.write("[" .. string.rep("=", filled)
      .. string.rep(" ", barWidth - filled) .. "]" .. label)
  end

  local stopped = false
  local lastDraw = 0
  local ok, err = pcall(function()
    while true do
      local now = computer.uptime()
      local timeout = math.max(0.05, lastDraw + 0.25 - now)
      if not paused and session.localBlob then
        local t = nbs.readRecord(session.localBlob, nextLocal)
        if t then
          timeout = math.min(timeout, math.max(0, start + t - now))
        end
      end

      local sig = table.pack(event.pull(timeout))
      if sig[1] == "key_down" then
        local char = sig[3]
        if char == 32 then -- space
          if paused then
            if session.modem then
              session.modem.broadcast(port, PROTOCOL, "resume")
            end
            start = start + (computer.uptime() - pausedAt)
            paused = false
          else
            if session.modem then
              session.modem.broadcast(port, PROTOCOL, "pause")
            end
            pausedAt = computer.uptime()
            paused = true
          end
        elseif char == 113 or char == 81 then -- q/Q
          stopped = true
          return
        end
      end

      if not paused and session.localBlob then
        while true do
          local t, inst, pitch = nbs.readRecord(session.localBlob, nextLocal)
          if not t or start + t > computer.uptime() then break end
          trigger(inst, pitch)
          nextLocal = nextLocal + 1
        end
      end

      if computer.uptime() - lastDraw >= 0.2 then
        drawProgress()
        lastDraw = computer.uptime()
      end

      if not paused and elapsed() >= session.duration + 0.5
        and nextLocal > localTotal then
        return
      end
    end
  end)

  if (stopped or not ok) and session.modem then
    session.modem.broadcast(port, PROTOCOL, "stop")
  end
  drawProgress()
  print("")
  if not ok and err ~= nil and not tostring(err):match("interrupted") then
    error(err, 0)
  end
  return not stopped and ok
end

local function playFile(path)
  local f, err = io.open(path, "rb")
  if not f then fail("cannot open " .. path .. ": " .. tostring(err)) end
  local data = f:read("*a")
  f:close()

  local song, perr = nbs.parse(data)
  if not song then fail(perr) end
  local events, duration = nbs.timeline(song)

  -- assemble players: this computer's blocks + discovered remote nodes
  local players, remote = {}, {}
  local localBlocks, localCounts = loadLocalBlocks()
  local localIndex
  if next(localCounts) then
    players[#players + 1] = { inst = localCounts }
    localIndex = #players
  end
  local modem = openModem()
  if modem then
    io.write("discovering players... ")
    local nodes = discoverPlayers(modem)
    printf("%d found", #nodes)
    for _, node in ipairs(nodes) do
      players[#players + 1] = { inst = node.inst }
      remote[#players] = node.addr
    end
  end
  if #players == 0 then
    fail("no note blocks available: calibrate this computer with"
      .. " 'noteplayer calibrate' or start remote 'noteplayer' nodes")
  end

  local assignments, stats = nbs.schedule(events, players, {
    perTick = tonumber(opts.pertick) or 1,
    fallback = not opts.nofallback,
  })

  local totalBlocks = 0
  for _, player in ipairs(players) do
    for _, count in pairs(player.inst) do totalBlocks = totalBlocks + count end
  end

  local title = song.name ~= "" and song.name or fs.name(path)
  local author = song.author ~= "" and song.author or song.originalAuthor
  print("")
  printf("Song:     %s%s", title, author ~= "" and (" - " .. author) or "")
  printf("Length:   %s   %d notes   %.4g t/s   NBS v%d",
    fmtTime(duration), song.noteCount, song.tempo, song.version)
  printf("Players:  %d (%d note blocks)%s", #players, totalBlocks,
    localIndex and ", including this computer" or "")
  local lost = stats.dropped
  printf("Schedule: %d play, %d merged, %d dropped (%.1f%%), %d substituted",
    stats.played, stats.merged, lost,
    stats.total > 0 and (100 * lost / stats.total) or 0, stats.substituted)
  if lost > stats.total * 0.1 then
    print("          (add more players/note blocks or raise --pertick)")
  end

  -- deliver schedules to remote nodes
  local songId = string.format("%d-%s", math.floor(computer.uptime() * 100),
    tostring(title):sub(1, 8))
  for index, addr in pairs(remote) do
    if #assignments[index] > 0 then
      io.write(string.format("sending %d notes to %s... ",
        #assignments[index], addr:sub(1, 8)))
      if transmit(modem, addr, songId, title, nbs.encodeRecords(assignments[index])) then
        print("ok")
      else
        print("FAILED (node skipped)")
      end
    end
  end

  print("[space] pause  [q] stop")
  local delay = 1.5
  if modem then
    modem.broadcast(port, PROTOCOL, "play", songId, delay)
  end
  return runPlayback({
    duration = duration,
    delay = delay,
    modem = modem,
    localBlob = localIndex and nbs.encodeRecords(assignments[localIndex]) or nil,
    localBlocks = localBlocks,
  })
end

----------------------------------------------------------------- browse --

local function listSongs(mode)
  if mode.kind == "search" then
    return apiJson(API .. "/song/search?q=" .. urlencode(mode.query)
      .. "&page=" .. mode.page .. "&limit=" .. PAGE_SIZE)
  elseif mode.kind == "featured" then
    local data, err = apiJson(API .. "/song/featured")
    if data and not data.content then data = { content = data } end
    return data, err
  end
  return apiJson(API .. "/song?page=" .. mode.page .. "&limit=" .. PAGE_SIZE)
end

local function browse()
  ensureInternet()
  local mode = { kind = "recent", page = 1 }
  while true do
    term.clear()
    local heading = mode.kind == "search"
      and ("Search: " .. mode.query) or mode.kind
    printf("Note Block World - %s (page %d)", heading, mode.page)
    print(string.rep("-", 50))

    local data, err = listSongs(mode)
    local items = data and data.content or nil
    if not items then
      printf("error: %s", tostring(err or "no results"))
      items = {}
    end
    for i, songInfo in ipairs(items) do
      printf("%2d. %-34s %5s %6d notes", i,
        tostring(songInfo.title or "?"):sub(1, 34),
        fmtTime(tonumber(songInfo.duration) or 0),
        tonumber(songInfo.noteCount) or 0)
    end
    if #items == 0 then print("(nothing here)") end
    print(string.rep("-", 50))
    io.write("# to play | [n]ext [p]rev [s]earch [f]eatured [r]ecent [q]uit: ")
    local input = (io.read() or "q"):gsub("%s+", "")

    if input == "q" or input == "Q" then
      return
    elseif input == "n" then
      mode.page = mode.page + 1
    elseif input == "p" then
      mode.page = math.max(1, mode.page - 1)
    elseif input == "f" then
      mode = { kind = "featured", page = 1 }
    elseif input == "r" then
      mode = { kind = "recent", page = 1 }
    elseif input == "s" then
      io.write("search: ")
      local query = (io.read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if query ~= "" then mode = { kind = "search", query = query, page = 1 } end
    else
      local pick = items[tonumber(input) or -1]
      if pick and pick.publicId then
        term.clear()
        local path = downloadSong(pick.publicId)
        playFile(path)
        io.write("press Enter to go back... ")
        io.read()
      end
    end
  end
end

------------------------------------------------------------------- main --

local command = args[1]
if command == "play" then
  if not args[2] then fail("usage: noteblock play <file|url|id> [...]") end
  for i = 2, #args do
    if not playFile(resolveTarget(args[i])) then break end
  end
elseif command == "search" then
  ensureInternet()
  local query = table.concat(args, " ", 2)
  if query == "" then fail("usage: noteblock search <words...>") end
  local data, err = apiJson(API .. "/song/search?q=" .. urlencode(query)
    .. "&page=1&limit=10")
  if not data or not data.content then fail(err or "search failed") end
  printf("%d result(s):", tonumber(data.total) or #data.content)
  for _, songInfo in ipairs(data.content) do
    printf("  %-12s %-36s %5s %6d notes", songInfo.publicId,
      tostring(songInfo.title or "?"):sub(1, 36),
      fmtTime(tonumber(songInfo.duration) or 0),
      tonumber(songInfo.noteCount) or 0)
  end
  print("play one with: noteblock play <id>")
elseif command == "players" then
  local modem = openModem()
  if not modem then fail("a network card is required") end
  local nodes = discoverPlayers(modem)
  printf("%d player node(s):", #nodes)
  for _, node in ipairs(nodes) do
    local parts = {}
    for inst, count in pairs(node.inst) do
      parts[#parts + 1] = string.format("%s x%d",
        nbs.INSTRUMENTS[inst] or ("#" .. inst), count)
    end
    table.sort(parts)
    printf("  %s  %s", node.addr:sub(1, 8), table.concat(parts, ", "))
  end
  local _, localCounts = loadLocalBlocks()
  if next(localCounts) then
    print("plus this computer's own calibrated note blocks.")
  end
elseif command == "stop" then
  local modem = openModem()
  if not modem then fail("a network card is required") end
  modem.broadcast(port, PROTOCOL, "stop")
  print("stop broadcast sent")
elseif command == nil then
  browse()
else
  print("usage: noteblock [play <target>...|search <words>|players|stop]")
  os.exit(1)
end
