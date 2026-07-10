-- noteblock: modern note block music player for OpenComputers.
-- Plays .nbs songs (all NBS versions) on vanilla note blocks, with built-in
-- noteblock.world browsing, search and download. Notes are scheduled across
-- every available player: this computer's own calibrated note blocks plus
-- any number of remote "noteplayer" nodes -- because each note block
-- trigger costs ~1 game tick, more players means denser songs play clean.
--
-- Usage:
--   noteblock                       touch GUI browser (or text UI with --cli)
--   noteblock play <target> [...]   play files/URLs/noteblock.world ids
--   noteblock search <words...>     quick search
--   noteblock players               list available player nodes
--   noteblock update                push this computer's noteplayer files
--                                   to every listening node (they install
--                                   and reboot; only the master needs
--                                   internet access)
--   noteblock stop                  stop all nodes
--
-- Targets: /path/song.nbs | https://noteblock.world/song/<id> | <id> | any URL
-- Options:
--   --port=3001      protocol port
--   --slack=2        ticks a note may fire late before being dropped;
--                    spilling quiet chord notes 1-2 ticks recovers most
--                    of what a single computer would otherwise drop
--   --pertick=1      max notes per player per game tick
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

local haveUI, ocui = pcall(require, "ocui")
if not haveUI then ocui = nil end

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

-- OpenOS caches required libraries until reboot, so after an update the
-- old nbs module can linger in package.loaded even though the file on
-- disk is new; drop the cache and reload before giving up
if nbs.VERSION ~= 3 then
  package.loaded.nbs = nil
  nbs = require("nbs")
end
if nbs.VERSION ~= 3 then
  local where = package.searchpath
    and package.searchpath("nbs", package.path) or "an unknown path"
  fail("outdated nbs library loaded from " .. tostring(where)
    .. "; delete that stale copy (the current one installs to"
    .. " /usr/lib/nbs.lua via 'ocgit install'), or reboot")
end

-- let the nbs library yield inside its heavy loops so large songs don't
-- trip the "too long without yielding" watchdog
nbs.onYield = function() os.sleep(0) end

local function fmtTime(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

------------------------------------------------------------------- http --

-- onProgress(bytesReceived, totalOrNil) is called per chunk; the total
-- comes from the Content-Length response header when the server sends it.
local function fetch(url, headers, onProgress)
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
  local code, message, respHeaders = req.response()
  local total
  if type(respHeaders) == "table" then
    for name, value in pairs(respHeaders) do
      if tostring(name):lower() == "content-length" then
        total = tonumber(type(value) == "table" and value[1] or value)
      end
    end
  end
  local chunks = {}
  local received = 0
  local readOk, readErr = pcall(function()
    for chunk in req do
      chunks[#chunks + 1] = chunk
      received = received + #chunk
      if onProgress then onProgress(received, total) end
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

-- Some packed songs on noteblock.world have a deflated (not stored)
-- song.nbs. The Data Card's inflate expects a zlib stream; zip entries
-- are raw deflate, so prepend the zlib header. The missing adler32
-- trailer is tolerated by Java's InflaterOutputStream.
local function zipInflater()
  if not component.isAvailable("data") then return nil end
  local dataCard = component.data
  if not dataCard.inflate then return nil end
  return function(raw)
    local ok, out = pcall(dataCard.inflate, "\120\156" .. raw)
    if ok then return out end
    return nil, out
  end
end

-- Downloads a song by public id. Songs are cached in /home/music keyed
-- by id, so repeat plays skip the network entirely.
-- hooks = { status = fn(text), progress = fn(bytes, total) } (optional).
-- Returns path, meta or nil, error.
local function downloadSong(id, hooks)
  local function report(text)
    if hooks and hooks.status then hooks.status(text) else print(text) end
  end

  if fs.isDirectory(MUSIC_DIR) then
    local pattern = "%." .. id:gsub("(%W)", "%%%1") .. "%.nbs$"
    for entry in fs.list(MUSIC_DIR) do
      if entry:match(pattern) then
        report("using cached copy")
        return fs.concat(MUSIC_DIR, entry), nil
      end
    end
  end

  ensureInternet()
  local meta = apiJson(API .. "/song/" .. id) or {}
  report("fetching download link...")
  local url, err = fetch(API .. "/song/" .. id .. "/open",
    { ["User-Agent"] = UA["User-Agent"], src = "downloadButton" })
  if not url then
    return nil, "cannot get song from noteblock.world: " .. tostring(err)
  end
  url = url:gsub("^%s*\"?", ""):gsub("\"?%s*$", "")
  report("downloading song...")
  local zip, zerr = fetch(url, nil, hooks and hooks.progress)
  if not zip then
    return nil, "download failed: " .. tostring(zerr)
  end
  local data, uerr = nbs.unzip(zip, "%.nbs$", zipInflater())
  if not data then
    return nil, tostring(uerr)
  end
  report(string.format("downloaded %d KB", math.floor(#data / 1024)))

  fs.makeDirectory(MUSIC_DIR)
  local base = sanitizeName(meta.title)
  if base == "" then base = id end
  local path = fs.concat(MUSIC_DIR, base .. "." .. id .. ".nbs")
  local f, ferr = io.open(path, "wb")
  if not f then return nil, "cannot save song: " .. tostring(ferr) end
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
  if id then
    local path2, derr = downloadSong(id)
    if not path2 then fail(derr) end
    return path2
  end
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
      local unzipped, uerr = nbs.unzip(data, "%.nbs$", zipInflater())
      if not unzipped then fail(uerr) end
      data = unzipped
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

-- Reads this computer's own noteplayer calibration (v1 flat map or v2
-- {blocks, banks} schema) so the master can play locally too.
local function loadLocalSetup()
  local blocks, counts, banks = {}, {}, {}
  local f = io.open(PLAYER_CONFIG, "r")
  if not f then return blocks, counts, banks end
  local data = serialization.unserialize(f:read("*a") or "") or {}
  f:close()
  if not data.blocks then data = { blocks = data, banks = {} } end
  data.banks = data.banks or {}
  local bankBlocks = {}
  for _, bank in ipairs(data.banks) do
    for _, address in pairs(bank.sides) do bankBlocks[address] = true end
  end
  for address, inst in pairs(data.blocks) do
    if not bankBlocks[address] and component.type(address) == "note_block" then
      local proxy = component.proxy(address)
      if proxy then
        blocks[inst] = blocks[inst] or {}
        table.insert(blocks[inst], proxy)
        counts[inst] = (counts[inst] or 0) + 1
      end
    end
  end
  for _, bank in ipairs(data.banks) do
    if component.type(bank.addr) == "redstone" then
      local proxy = component.proxy(bank.addr)
      if proxy then
        local instBySide = {}
        for side, address in pairs(bank.sides) do
          instBySide[side] = data.blocks[address]
        end
        banks[#banks + 1] = { rs = proxy, sides = bank.sides, inst = instBySide }
      end
    end
  end
  return blocks, counts, banks
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
      local payload = tostring(sig[8])
      local instPart, bankPart = payload:match("^([^|]*)|?(.*)$")
      local inst = {}
      for id, count in (instPart or ""):gmatch("(%d+):(%d+)") do
        inst[tonumber(id)] = tonumber(count)
      end
      local banks = {}
      for devPart in (bankPart or ""):gmatch("[^;]+") do
        local sides, side = {}, 0
        for token in devPart:gmatch("[^,]+") do
          if token ~= "-" then sides[side] = tonumber(token) end
          side = side + 1
        end
        banks[#banks + 1] = { inst = sides }
      end
      found[sig[3]] = { inst = inst, banks = banks }
    end
  end
  local list = {}
  for addr, node in pairs(found) do
    list[#list + 1] = { addr = addr, inst = node.inst, banks = node.banks }
  end
  table.sort(list, function(a, b) return a.addr < b.addr end)
  return list
end

-- Sends a player's schedule in chunks; retries missing chunks.
local CHUNK = 3996 -- multiple of nbs.RECORD_SIZE

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

  local function execute(kind, a, b)
    if kind == nbs.KIND_VOLLEY then
      local bank = session.localBanks and session.localBanks[a + 1]
      if bank then pcall(bank.rs.setOutput, nbs.maskToSides(b)) end
    else
      trigger(kind, a)
    end
  end

  local width = 80
  pcall(function() width = term.getViewport() end)

  local function elapsed()
    if paused then return pausedAt - start end
    return computer.uptime() - start
  end

  local function drawProgress()
    local e = math.max(0, math.min(elapsed(), session.duration))
    if session.gui then
      session.gui.bar:setValue(e / math.max(1, session.duration))
      session.gui.timeLabel:setText(string.format("%s / %s%s",
        fmtTime(e), fmtTime(session.duration), paused and "  paused" or ""))
      return
    end
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

      local action
      if session.gui then
        local kind, char = session.gui.ui:pump(timeout)
        if kind == "quit" then action = "stop" end
        if kind == "key" then
          if char == 32 then action = "toggle"
          elseif char == 113 or char == 81 then action = "stop" end
        end
        if session.gui.control.action then
          action = session.gui.control.action
          session.gui.control.action = nil
        end
      else
        local sig = table.pack(event.pull(timeout))
        if sig[1] == "interrupted" then action = "stop" end
        if sig[1] == "key_down" then
          if sig[3] == 32 then action = "toggle"
          elseif sig[3] == 113 or sig[3] == 81 then action = "stop" end
        end
      end
      if action == "stop" then -- [q], Ctrl+C, or the stop button
        stopped = true
        return
      elseif action == "toggle" then
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
        if session.gui then
          session.gui.pauseButton:setText(paused and " > Resume " or " || Pause ")
        end
      end

      if not paused and session.localBlob then
        while true do
          local t, kind, a, b = nbs.readRecord(session.localBlob, nextLocal)
          if not t or start + t > computer.uptime() then break end
          execute(kind, a, b)
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
  for _, bank in ipairs(session.localBanks or {}) do
    pcall(bank.rs.setOutput, nbs.maskToSides(0))
  end
  drawProgress()
  if not session.gui then print("") end
  if not ok and err ~= nil and not tostring(err):match("interrupted") then
    error(err, 0)
  end
  return not stopped and ok
end

local function playFile(path, gui)
  -- status routing: CLI prints, GUI updates its status label; errors
  -- return to the GUI instead of exiting the program
  local function say(fmt, ...)
    local text = string.format(fmt, ...)
    if gui then gui.log(text) else printf("%s", text) end
  end
  local function abort(msg)
    if gui then
      gui.log("error: " .. tostring(msg))
      return false
    end
    fail(msg)
  end

  local f, err = io.open(path, "rb")
  if not f then return abort("cannot open " .. path .. ": " .. tostring(err)) end
  local data = f:read("*a")
  f:close()

  say("parsing song...")
  local song, perr = nbs.parse(data)
  if not song then return abort(perr) end
  local events, duration = nbs.timeline(song)

  -- assemble players: this computer's blocks + discovered remote nodes
  local players, remote = {}, {}
  local localBlocks, localCounts, localBanks = loadLocalSetup()
  local localIndex
  if next(localCounts) or #localBanks > 0 then
    local bankSpec = {}
    for i, bank in ipairs(localBanks) do
      bankSpec[i] = { inst = bank.inst }
    end
    players[#players + 1] = { inst = localCounts, banks = bankSpec }
    localIndex = #players
  end
  local modem = openModem()
  if modem then
    say("discovering players...")
    local nodes = discoverPlayers(modem)
    say("%d player node(s) found", #nodes)
    for _, node in ipairs(nodes) do
      players[#players + 1] = { inst = node.inst, banks = node.banks }
      remote[#players] = node.addr
    end
  end
  if #players == 0 then
    return abort("no note blocks available: calibrate this computer with"
      .. " 'noteplayer calibrate' or start remote 'noteplayer' nodes")
  end

  say("scheduling...")
  local assignments, stats, tunings = nbs.schedule(events, players, {
    perTick = tonumber(opts.pertick) or 1,
    fallback = not opts.nofallback,
    rsDelay = tonumber(opts.rsdelay) or 0.1,
    slack = tonumber(opts.slack),
  })

  local totalBlocks = 0
  for _, player in ipairs(players) do
    for _, count in pairs(player.inst) do totalBlocks = totalBlocks + count end
  end

  local title = song.name ~= "" and song.name or fs.name(path)
  local author = song.author ~= "" and song.author or song.originalAuthor
  if gui then
    if gui.setTitle then gui.setTitle(title, author) end
    if gui.setInfo then
      gui.setInfo(string.format("%s | %d notes | %d players | %d dropped%s",
        fmtTime(duration), song.noteCount, #players, stats.dropped,
        stats.bank > 0 and (" | " .. stats.bank .. " banked") or ""))
    end
  else
    print("")
    printf("Song:     %s%s", title, author ~= "" and (" - " .. author) or "")
    printf("Length:   %s   %d notes   %.4g t/s   NBS v%d",
      fmtTime(duration), song.noteCount, song.tempo, song.version)
    printf("Players:  %d (%d note blocks)%s", #players, totalBlocks,
      localIndex and ", including this computer" or "")
    local lost = stats.dropped
    printf("Schedule: %d play (%d banked, %d slightly late), %d merged,"
      .. " %d dropped (%.1f%%), %d substituted",
      stats.played, stats.bank, stats.late, stats.merged, lost,
      stats.total > 0 and (100 * lost / stats.total) or 0, stats.substituted)
    if lost > stats.total * 0.1 then
      print("          (add more players, note blocks, redstone banks,"
        .. " or raise --slack)")
    end
  end

  -- deliver schedules to remote nodes
  local songId = string.format("%d-%s", math.floor(computer.uptime() * 100),
    tostring(title):sub(1, 8))
  for index, addr in pairs(remote) do
    if #assignments[index] > 0 then
      say("sending %d action(s) to %s...",
        #assignments[index] / nbs.RECORD_SIZE, addr:sub(1, 8))
      if transmit(modem, addr, songId, title, assignments[index]) then
        -- per-song bank tuning; the node confirms once its blocks are set
        if #tunings[index] > 0 then
          local parts = {}
          for _, tune in ipairs(tunings[index]) do
            parts[#parts + 1] = tune.dev .. ":" .. tune.side .. ":" .. tune.pitch
          end
          modem.send(addr, port, PROTOCOL, "tune", songId, table.concat(parts, ","))
          local deadline = computer.uptime() + 8
          local tuned = false
          while computer.uptime() < deadline and not tuned do
            local sig = table.pack(event.pull(
              math.max(0.05, deadline - computer.uptime()), "modem_message"))
            if sig[1] == "modem_message" and sig[3] == addr and sig[4] == port
              and sig[6] == PROTOCOL and sig[7] == "tuned" and sig[8] == songId then
              tuned = true
            end
          end
          if not tuned then
            say("node %s tuning TIMED OUT", addr:sub(1, 8))
          end
        end
      else
        say("node %s FAILED (skipped)", addr:sub(1, 8))
      end
    end
  end

  -- tune this computer's own banks (setPitch is ~1 tick per block)
  if localIndex and #tunings[localIndex] > 0 then
    say("tuning %d local bank block(s)...", #tunings[localIndex])
    for _, tune in ipairs(tunings[localIndex]) do
      local bank = localBanks[tune.dev]
      local address = bank and bank.sides[tune.side]
      if address then
        local proxy = component.proxy(address)
        if proxy then pcall(proxy.setPitch, tune.pitch) end
      end
    end
  end

  if gui then
    gui.log("playing")
  else
    print("[space] pause  [q] stop")
  end
  local delay = 1.5
  if modem then
    modem.broadcast(port, PROTOCOL, "play", songId, delay)
  end
  return runPlayback({
    duration = duration,
    delay = delay,
    modem = modem,
    gui = gui,
    localBlob = localIndex and #assignments[localIndex] > 0
      and assignments[localIndex] or nil,
    localBlocks = localBlocks,
    localBanks = localBanks,
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
        local path, derr = downloadSong(pick.publicId)
        if path then
          playFile(path)
        else
          printf("error: %s", tostring(derr))
        end
        io.write("press Enter to go back... ")
        io.read()
      end
    end
  end
end

-------------------------------------------------------------------- gui --

-- Touch-first interface built on /usr/lib/ocui.lua. Tier 2+ screens get
-- taps/drag-scrolling; keyboards keep working everywhere. `noteblock
-- --cli` forces the classic text browser.

local function wantGui()
  if opts.cli or not ocui then return false end
  if not (component.isAvailable("gpu") and component.isAvailable("screen")) then
    return false
  end
  local w, h = component.gpu.getResolution()
  return w >= 40 and h >= 14
end

-- Full-screen playback view; returns when the song ends or is stopped.
local function guiPlaySong(ui, item)
  local theme = ocui.theme
  ui:clear()
  ui:add(ocui.label{ x = 1, y = 1, w = ui.w, text = "", bg = theme.accent })
  ui:add(ocui.label{ x = 2, y = 1, w = ui.w - 2, text = "Now Playing",
    fg = theme.accentText, bg = theme.accent })
  local titleLabel = ui:add(ocui.label{ x = 3, y = 3, w = ui.w - 4,
    text = tostring(item.title or "?") })
  local authorLabel = ui:add(ocui.label{ x = 3, y = 4, w = ui.w - 4,
    text = tostring(item.originalAuthor or ""), fg = theme.dim })
  local infoLabel = ui:add(ocui.label{ x = 3, y = 6, w = ui.w - 4,
    text = "", fg = theme.dim })
  local statusLabel = ui:add(ocui.label{ x = 3, y = 7, w = ui.w - 4,
    text = "starting..." })
  local bar = ui:add(ocui.progress{ x = 3, y = 9, w = ui.w - 4 })
  local timeLabel = ui:add(ocui.label{ x = 3, y = 10, w = ui.w - 4,
    text = "", fg = theme.dim })
  local control = {}
  local pauseButton = ui:add(ocui.button{ x = 3, y = 12, w = 12,
    text = " || Pause ",
    onTap = function() control.action = "toggle" end })
  ui:add(ocui.button{ x = 17, y = 12, w = 12, text = " [] Stop ",
    onTap = function() control.action = "stop" end })
  ui:draw()

  local gui = {
    ui = ui,
    control = control,
    bar = bar,
    timeLabel = timeLabel,
    pauseButton = pauseButton,
    log = function(text) statusLabel:setText(tostring(text)) end,
    setInfo = function(text) infoLabel:setText(text) end,
    setTitle = function(title, author)
      titleLabel:setText(tostring(title))
      authorLabel:setText(tostring(author or ""))
    end,
  }

  local path = item.path
  if not path then
    local derr
    path, derr = downloadSong(item.publicId, {
      status = function(text) statusLabel:setText(text) end,
      progress = function(done, total)
        if total and total > 0 then
          bar:setValue(done / total)
          timeLabel:setText(string.format("%d / %d KB",
            math.floor(done / 1024), math.floor(total / 1024)))
        else
          timeLabel:setText(string.format("%d KB", math.floor(done / 1024)))
        end
      end,
    })
    if path then
      bar:setValue(0)
      timeLabel:setText("")
    else
      statusLabel:setText("error: " .. tostring(derr))
    end
  end
  if path then
    playFile(path, gui)
    statusLabel:setText("finished - tap anywhere to go back")
  end

  -- wait for user input (not network noise) before returning
  while true do
    local kind, extra = ui:pump(math.huge)
    if kind == "quit" or kind == "key" or kind == "tap" or kind == "drop" then
      return
    end
    if kind == "other" and type(extra) == "table"
      and (extra[1] == "touch" or extra[1] == "drop") then
      return
    end
  end
end

local function guiBrowse()
  ensureInternet()
  local ui = ocui.new(component.gpu)
  local theme = ocui.theme
  local state = { kind = "recent", page = 1, query = nil }
  local pageCache = {}
  local quit = false
  local pageSize = math.min(100, ui.h - 6)
  local songList, statusLabel, pageLabel, tabs

  -- background prefetch: neighboring pages load while the user reads the
  -- current one. One request runs at a time; a queue holds the rest and
  -- refills as the user navigates, so Next/Prev are usually instant.
  local prefetch = { key = nil, req = nil, chunks = nil,
    connected = false, queue = {} }
  local prefetchKick
  local function prefetchCancel(clearQueue)
    if prefetch.req then pcall(prefetch.req.close) end
    prefetch.key, prefetch.req, prefetch.chunks = nil, nil, nil
    prefetch.connected = false
    if clearQueue then prefetch.queue = {} end
  end
  prefetchKick = function()
    if prefetch.req then return end
    local job = table.remove(prefetch.queue, 1)
    while job and pageCache[job.key] do
      job = table.remove(prefetch.queue, 1)
    end
    if not job then return end
    local ok, req = pcall(internet.request, job.url, nil, UA)
    if ok then
      prefetch.req, prefetch.key, prefetch.chunks = req, job.key, {}
      prefetch.connected = false
    end
  end
  local function prefetchQueue(key, url)
    if pageCache[key] or prefetch.key == key then return end
    for _, job in ipairs(prefetch.queue) do
      if job.key == key then return end
    end
    prefetch.queue[#prefetch.queue + 1] = { key = key, url = url }
    prefetchKick()
  end
  local function prefetchPump()
    if not prefetch.req then return prefetchKick() end
    if not prefetch.connected then
      local ok, connected = pcall(prefetch.req.finishConnect)
      if not ok or connected == nil then
        prefetchCancel()
        return prefetchKick()
      end
      if connected ~= true then return end
      prefetch.connected = true
    end
    for _ = 1, 8 do
      local ok, chunk = pcall(prefetch.req.read)
      if not ok then
        prefetchCancel()
        return prefetchKick()
      end
      if chunk == nil then
        local okJson, data = pcall(json.decode, table.concat(prefetch.chunks))
        if okJson and type(data) == "table" and data.content then
          pageCache[prefetch.key] = data
        end
        prefetchCancel()
        return prefetchKick()
      elseif chunk == "" then
        return
      end
      prefetch.chunks[#prefetch.chunks + 1] = chunk
    end
  end

  local function cacheKey(kind, query, page)
    return kind .. ":" .. (query or "") .. ":" .. page
  end
  local function listUrl(page)
    if state.kind == "search" then
      return API .. "/song/search?q=" .. urlencode(state.query)
        .. "&page=" .. page .. "&limit=" .. pageSize
    elseif state.kind == "featured" then
      return API .. "/song/featured"
    end
    return API .. "/song?page=" .. page .. "&limit=" .. pageSize
  end

  local function loadLocalList()
    local items = {}
    if fs.isDirectory(MUSIC_DIR) then
      for entry in fs.list(MUSIC_DIR) do
        if entry:match("%.nbs$") then
          items[#items + 1] = {
            title = entry:gsub("%.nbs$", ""),
            path = fs.concat(MUSIC_DIR, entry),
          }
        end
      end
    end
    table.sort(items, function(a, b) return a.title < b.title end)
    return { content = items }
  end

  local buildLayout, loadPage, setTabs

  setTabs = function()
    for _, tab in ipairs(tabs) do
      tab.primary = tab.tabKind == state.kind
      tab:draw()
    end
  end

  loadPage = function()
    local key = cacheKey(state.kind, state.query, state.page)
    local data
    if state.kind == "local" then
      data = loadLocalList()
    else
      data = pageCache[key]
      if not data then
        statusLabel:setText("loading...")
        local err
        data, err = apiJson(listUrl(state.page))
        if data and not data.content then data = { content = data } end
        if not data or not data.content then
          statusLabel:setText("error: " .. tostring(err or "no results"))
          return
        end
        pageCache[key] = data
      end
    end
    local items = data.content or {}
    songList:setItems(items)
    local total = tonumber(data.total)
    local pages = total and math.max(1, math.ceil(total / pageSize))
    pageLabel:setText(string.format("  page %d%s  ", state.page,
      pages and ("/" .. pages) or ""))
    statusLabel:setText(#items == 0 and "nothing here"
      or (#items .. " song(s) - tap one to play"))
    if state.kind == "recent" or state.kind == "search" then
      prefetchQueue(cacheKey(state.kind, state.query, state.page + 1),
        listUrl(state.page + 1))
      if state.page > 1 then
        prefetchQueue(cacheKey(state.kind, state.query, state.page - 1),
          listUrl(state.page - 1))
      end
    end
  end

  local function switchTo(kind, query)
    prefetchCancel(true)
    state = { kind = kind, page = 1, query = query }
    setTabs()
    loadPage()
  end

  buildLayout = function()
    ui:clear()
    ui:add(ocui.label{ x = 1, y = 1, w = ui.w, text = "", bg = theme.accent })
    ui:add(ocui.label{ x = 2, y = 1, w = ui.w - 10,
      text = "NOTE BLOCK WORLD", fg = theme.accentText, bg = theme.accent })
    ui:add(ocui.button{ x = ui.w - 7, y = 1, w = 8, text = " Quit ",
      onTap = function() quit = true end })
    tabs = {}
    local x = 2
    for _, def in ipairs({ { "Recent", "recent" }, { "Featured", "featured" },
      { "Search", "search" }, { "Local", "local" } }) do
      local tab = ocui.button{ x = x, y = 2, text = " " .. def[1] .. " ",
        onTap = function()
          if def[2] == "search" then
            local query = ocui.prompt(ui, "Search")
            ui:draw()
            if query then switchTo("search", query) end
          else
            switchTo(def[2])
          end
        end }
      tab.tabKind = def[2]
      ui:add(tab)
      tabs[#tabs + 1] = tab
      x = x + tab.w + 1
    end
    songList = ui:add(ocui.list{ x = 1, y = 4, w = ui.w, h = ui.h - 6,
      items = {},
      render = function(item)
        if item.path then return item.title end
        return tostring(item.title or "?"),
          fmtTime(tonumber(item.duration) or 0) .. " "
          .. tostring(tonumber(item.noteCount) or 0) .. "n"
      end,
      onSelect = function(_, item)
        prefetchCancel(true)
        guiPlaySong(ui, item)
        buildLayout()
        setTabs()
        loadPage()
        ui:draw()
      end })
    ui:add(ocui.button{ x = 2, y = ui.h - 1, w = 10, text = " < Prev ",
      onTap = function()
        if state.page > 1 then
          state.page = state.page - 1
          loadPage()
        end
      end })
    pageLabel = ui:add(ocui.label{ x = 13, y = ui.h - 1, w = 14,
      text = "", fg = theme.dim })
    ui:add(ocui.button{ x = 28, y = ui.h - 1, w = 10, text = " Next > ",
      onTap = function()
        state.page = state.page + 1
        loadPage()
      end })
    statusLabel = ui:add(ocui.label{ x = 1, y = ui.h, w = ui.w,
      text = "", fg = theme.dim })
    ui:draw()
  end

  buildLayout()
  setTabs()
  loadPage()
  ui:draw()

  while not quit do
    prefetchPump()
    local kind, a = ui:pump(0.25)
    if kind == "quit" then break end
    if kind == "key" then
      if a == 113 then break -- q
      elseif a == 110 then -- n
        state.page = state.page + 1
        loadPage()
      elseif a == 112 and state.page > 1 then -- p
        state.page = state.page - 1
        loadPage()
      elseif a == 115 then -- s
        local query = ocui.prompt(ui, "Search")
        ui:draw()
        if query then switchTo("search", query) end
      end
    end
  end
  prefetchCancel(true)

  -- restore a sane terminal
  component.gpu.setBackground(0x000000)
  component.gpu.setForeground(0xFFFFFF)
  term.clear()
end

----------------------------------------------------------------- update --

-- Broadcasts this computer's own noteplayer files to every listening
-- node, which verifies, installs and reboots. So only the master ever
-- needs internet access: 'ocgit pull && ocgit install' here, then
-- 'noteblock update' ships it to the whole fleet.

-- Locate this computer's installed copies wherever they actually live:
-- the nbs library through package.path (however require() found it), the
-- noteplayer program through the shell search path. Nodes always install
-- to the canonical destinations.
local function updateSources()
  local sources = {
    {
      src = package.searchpath and package.searchpath("nbs", package.path),
      dst = "/usr/lib/nbs.lua",
      name = "nbs.lua",
    },
    {
      src = shell.resolve("noteplayer", "lua"),
      dst = "/usr/bin/noteplayer.lua",
      name = "noteplayer.lua",
    },
  }
  for _, entry in ipairs(sources) do
    if not entry.src or not fs.exists(entry.src) then
      fail("cannot find " .. entry.name .. " on this computer;"
        .. " run 'ocgit install' first")
    end
  end
  return sources
end

local function commandUpdate()
  local modem = openModem()
  if not modem then fail("a network card is required") end

  local sources = updateSources()
  local bodies = {}
  for i, entry in ipairs(sources) do
    local f, err = io.open(entry.src, "rb")
    if not f then fail("cannot read " .. entry.src .. ": " .. tostring(err)) end
    bodies[i] = f:read("*a")
    f:close()
    printf("shipping %s (%d bytes, from %s)", entry.name, #bodies[i], entry.src)
  end

  local id = tostring(math.floor(computer.uptime() * 100))
  modem.broadcast(port, PROTOCOL, "upd-begin", id, #sources)
  local chunkCounts = {}
  for i, body in ipairs(bodies) do
    chunkCounts[i] = math.ceil(#body / CHUNK)
    modem.broadcast(port, PROTOCOL, "upd-file", id, i, sources[i].dst, chunkCounts[i])
  end

  local function sendChunk(index, seq)
    modem.broadcast(port, PROTOCOL, "upd-chunk", id, index, seq,
      bodies[index]:sub((seq - 1) * CHUNK + 1, seq * CHUNK))
  end

  for i = 1, #bodies do
    for seq = 1, chunkCounts[i] do
      sendChunk(i, seq)
      if seq % 8 == 0 then os.sleep(0.05) end
    end
  end

  local confirmed = {}
  for _ = 1, 3 do
    modem.broadcast(port, PROTOCOL, "upd-eof", id)
    local resend = {}
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
      local sig = table.pack(event.pull(
        math.max(0.05, deadline - computer.uptime()), "modem_message"))
      if sig[1] == "modem_message" and sig[4] == port and sig[6] == PROTOCOL then
        if sig[7] == "upd-ok" and sig[8] == id then
          confirmed[sig[3]] = true
        elseif sig[7] == "upd-miss" and sig[8] == id then
          confirmed[sig[3]] = nil
          for index, seq in tostring(sig[9]):gmatch("(%d+):(%d+)") do
            resend[index .. ":" .. seq] = true
          end
        end
      end
    end
    if not next(resend) then break end
    io.write("resending lost chunks... ")
    for key in pairs(resend) do
      local index, seq = key:match("(%d+):(%d+)")
      index, seq = tonumber(index), tonumber(seq)
      if seq == 0 then
        -- node missed the file header entirely
        modem.broadcast(port, PROTOCOL, "upd-file", id, index,
          sources[index].dst, chunkCounts[index])
        for s = 1, chunkCounts[index] do sendChunk(index, s) end
      else
        sendChunk(index, seq)
      end
      os.sleep(0.05)
    end
    print("done")
  end

  modem.broadcast(port, PROTOCOL, "upd-commit", id)
  local count = 0
  for _ in pairs(confirmed) do count = count + 1 end
  printf("%d node(s) confirmed the update and are rebooting.", count)
  if count == 0 then
    print("(no daemons answered; are the nodes running 'noteplayer'?)")
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
elseif command == "update" then
  commandUpdate()
elseif command == nil then
  if wantGui() then
    guiBrowse()
  else
    browse()
  end
else
  print("usage: noteblock [play <target>...|search <words>|players|update|stop]"
    .. " [--cli]")
  os.exit(1)
end
