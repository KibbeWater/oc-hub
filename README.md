# OC-LUA — develop OpenComputers scripts on your PC

Write Lua on your local machine, sync and deploy it into Minecraft
(OpenComputers, MC 1.12.2) over the Internet Card.

Repository: `github.com/KibbeWater/oc-hub`

| Tool | Runs | Purpose |
|------|------|---------|
| `ocgit` | in-game | Pull-only git client: `clone` / `pull` / `status` / `install` from GitHub |
| `ocdev` | in-game | Live sync from your PC — edits appear in-game within seconds |
| `ocrun` | in-game | Runs a dev script and **hot-restarts it** when the code updates |
| `ocpush` | in-game | Broadcasts a script wirelessly to a **fleet of ocnet listener nodes** |
| `mkinstaller` | in-game | Config window that flashes **auto-installer** or **ocnet listener** EEPROMs |
| `noteblock` | in-game | Note block music player with **noteblock.world** browsing/downloads |
| `noteplayer` | in-game | Player node: calibrated note blocks the master schedules across |
| `tools/serve.py` | on PC | Dev server that `ocdev`/`ocrun` sync from |

`oc-manifest.cfg` in the git root declares where every file gets installed
(programs to `/usr/bin`, libraries to `/usr/lib`, ...). It is read by the
EEPROM auto-installer and by `ocgit install`.

## Repository layout

```
setup.lua              interactive setup wizard (run once per computer)
oc-manifest.cfg        install manifest (what goes where in-game)
ocgit/ocgit.lua        pull-only git client (GitHub API)
ocgit/ocdev.lua        live-sync watcher
ocgit/ocrun.lua        live-sync + managed process with hot restart
ocgit/ocpush.lua       wireless fleet broadcaster (pairs with netboot)
ocgit/json.lua         JSON decoder library      -> /usr/lib/json.lua
ocgit/optimize.lua     Lua source optimizer      -> /usr/lib/optimize.lua
installer/flash.lua    mkinstaller (EEPROM config window)
installer/boot.lua     auto-installer bootstrap BIOS (<4KB)
installer/netboot.lua  ocnet listener BIOS (<4KB)
installer/stage2.lua   full installer, downloaded by boot.lua at boot
installer/luabios.lua  standard Lua BIOS restored after installation
examples/blink.lua     example worker script for ocnet nodes
tools/serve.py         dev server for live sync
```

## Setup: one command in-game

On an OpenOS computer with an internet card:

```
wget -f https://raw.githubusercontent.com/KibbeWater/oc-hub/main/setup.lua /tmp/setup.lua
/tmp/setup.lua
```

The setup wizard (windowed if a GPU + screen are present, plain text prompts
otherwise) lets you configure the repo/branch, checkout directory, token and
optimization, toggle the steps to run, then bootstraps `ocgit`, clones the
repository, applies `oc-manifest.cfg` — putting the whole toolkit on the
PATH — and can launch `mkinstaller` at the end to flash an EEPROM. Re-running
it later is safe: it pulls instead of cloning and overwrites the tools with
the current versions.

<details>
<summary>Manual bootstrap (what setup.lua automates)</summary>

```
mkdir /usr/lib
mkdir /usr/bin
wget https://raw.githubusercontent.com/KibbeWater/oc-hub/main/ocgit/json.lua /usr/lib/json.lua
wget https://raw.githubusercontent.com/KibbeWater/oc-hub/main/ocgit/ocgit.lua /usr/bin/ocgit.lua
ocgit clone KibbeWater/oc-hub /home/work
ocgit install /home/work
```
</details>

Every other computer can be set up automatically with an installer EEPROM
(below) — or by running `setup.lua` on it, too.

## ocgit — git-based deployment

```
ocgit clone KibbeWater/oc-hub /home/work   # first time
ocgit pull /home/work                      # after every git push
ocgit status /home/work                    # dry run: what would change
ocgit install /home/work                   # apply oc-manifest.cfg locally
```

Options:

- `--branch=<name>` — track a branch other than the repo default.
- `--path=<subdir>` — sync only a subdirectory of the repository.
- `--token=<pat>` — GitHub personal access token; required for private
  repositories and raises the API limit from 60 to 5000 requests/hour.
  Stored in the `.ocgit` manifest, so don't use a valuable token.
- `--force` (pull) — re-download everything.
- `--optimize` — run the optimizer on `.lua` files before writing (see below).

How it works: `ocgit` fetches the repo file tree from the GitHub API, compares
blob SHAs against the `.ocgit` manifest it keeps in the checkout, and only
downloads changed files from `raw.githubusercontent.com`. Files deleted from
the repo are deleted in-game too (only files ocgit itself created).

The daily loop: edit on PC, `git commit && git push`, then in-game
`ocgit pull && ocgit install`.

## Live development: serve.py + ocdev + ocrun

On your PC, from this folder:

```
python tools/serve.py . 8064
```

In-game, plain file sync:

```
ocdev 192.168.x.x:8064 /home/work
```

Or sync **and run** a script, restarting it on every change — run one of
these per computer that should execute dev code:

```
ocrun 192.168.x.x:8064 myscript.lua /home/work --args="reactor1"
```

`ocrun` polls the server; when any file changes it kills the running script
(OpenOS `thread` API) and starts the new version. If the script crashes or
exits it is *not* restarted until the next change, so a broken build won't
spin. Shared options: `--interval=<seconds>` (default 2), `--optimize`,
`--token=<secret>`; `ocdev` also takes `--once` and `--run=<command>`.

### Using ngrok (works on servers you don't control)

Instead of a LAN address you can tunnel the dev server through ngrok — then
the in-game computer talks to a public HTTPS URL, so **no mod config changes
are needed** and it works on multiplayer servers too:

```
python tools/serve.py . 8064 --token=mysecret
ngrok http 8064
```

In-game, pass the tunnel URL instead of a host:

```
ocdev https://<id>.ngrok-free.app /home/work --token=mysecret
ocrun https://<id>.ngrok-free.app myscript.lua /home/work --token=mysecret
```

Notes:
- The tools automatically send the `ngrok-skip-browser-warning` header, so
  ngrok's free-tier interstitial page never gets in the way.
- An ngrok tunnel is reachable by anyone who knows the URL — that's why
  `--token` exists. Start `serve.py` with `--token=<secret>` and pass the
  same `--token` in-game; everything else gets a 403.
- Free-tier URLs change on every ngrok restart; a (free) static domain from
  the ngrok dashboard (`ngrok http --url=<yours>.ngrok-free.app 8064`)
  avoids retyping.

To autostart on boot, add to `/etc/rc.d/` or `/home/.shrc`, e.g.:

```
echo 'ocrun 192.168.x.x:8064 myscript.lua /home/work' >> /home/.shrc
```

### Allowing LAN addresses (required for direct LAN sync only)

OpenComputers **blocks private/LAN addresses by default**. In
`config/opencomputers.cfg` (of the server, or your client instance in
single-player), find the `internet { ... }` block and change
`"deny private"` to `"allow private"` in `filteringRules` (older configs:
remove `"private"` from `blacklist`). Restart Minecraft. Not needed for
GitHub-based workflows or when tunneling through ngrok.

## mkinstaller — the auto-installer EEPROM

Turns any EEPROM into a self-configuring installer: put it in a computer
(fresh or existing) with an internet card, power on, and it will

1. install OpenOS onto the largest writable drive if no drive has it
   (from an OpenOS floppy if one is inserted, otherwise downloaded from the
   OpenComputers GitHub repository),
2. install everything declared in `oc-manifest.cfg`,
3. flash itself back to a **standard Lua BIOS** pointed at the boot drive,
   and reboot into OpenOS.

So one EEPROM bootstraps a machine end-to-end and then keeps serving as its
normal boot EEPROM.

On the master computer:

```
mkinstaller
```

A configuration window lets you load a saved profile, the default (last
used — prefilled from the surrounding ocgit checkout on first run), or enter
a new configuration (GitHub user, repo, branch, stage-2 path). You can save
it as a named profile (stored in `/etc/ocinstaller/`), then type `FLASH` to
write the currently inserted EEPROM. The previous EEPROM code is validated
(warns if it isn't a standard Lua BIOS) and backed up to
`/home/eeprom-backup.lua`.

To prepare several EEPROMs, hot-swap blank ones into the master computer and
re-run `mkinstaller` — pick the saved profile each time.

Technical shape: an EEPROM holds only 4KB and boots without OpenOS, so the
flashed code (`installer/boot.lua`) is a minimal bootstrap that reads
`owner/repo|branch|path` from the EEPROM data area, downloads
`installer/stage2.lua` from your repo and runs it. Stage 2 has no size limit
and is fetched fresh at every boot, so installer improvements ship without
reflashing existing EEPROMs.

Target computers need: internet card, a hard drive, and ideally tier 2+ RAM
(the OpenOS-from-GitHub download builds file lists in memory).

## ocnet — a wireless fleet of script runners

For running dev scripts on many computers at once (20+), flash cheap nodes
with the **ocnet listener** EEPROM (`mkinstaller`, option 2). A node needs
only a CPU, RAM, a **wireless network card**, and the EEPROM — no hard
drive, no OpenOS. On boot it immediately listens on the configured port
(default 2412) and asks for the current script.

From the master computer (which needs a wireless card too):

```
ocpush examples/blink.lua --watch     # push + keep watching for changes
ocpush --ping                         # list nodes and what they run
ocpush --stop                         # stop the script on all nodes
```

- Every push broadcasts the script in chunks; nodes verify completeness,
  then **kill the running script and start the new version**.
- `--watch` also answers the "hello" a node sends on boot, so nodes that
  join or reboot later get the current script automatically (debounced, so
  20 nodes booting at once trigger one push).
- `--force` restarts nodes even if the content is unchanged;
  `--optimize` shrinks the script before sending; `--port=` separates
  independent fleets.
- Chain it with live sync for PC-to-fleet updates: `ocdev` (or `ocgit pull`)
  keeps the file fresh on the master, and `ocpush --watch` notices the
  changed file and re-broadcasts it.

Worker scripts run in a bare environment (no OpenOS): use
`component`/`computer` directly and sleep via `computer.pullSignal(seconds)`
— the listener transparently intercepts it so updates can always interrupt
the script. See `examples/blink.lua`. If a script crashes, the node shows
the error and waits for the next push.

## noteblock — note block music player + noteblock.world

Plays `.nbs` (Note Block Studio) songs on vanilla note blocks, with built-in
[noteblock.world](https://noteblock.world) browsing, search and downloads.
A modern rewrite of the classic NoteblockPlayer.

### Setup

1. Place note blocks next to **Adapters** connected to a computer. The block
   *under* each note block picks the instrument (gold = bell, wood = bass...).
2. On each computer with note blocks: `noteplayer calibrate` — every block
   plays, you type its instrument number. Verify with `noteplayer test`.
3. Single computer? You're done: `noteblock` needs nothing else.
   More computers = denser songs: run the `noteplayer` daemon on each extra
   node (wireless card required); the master finds them automatically.

### Usage

```
noteblock                            browse/search noteblock.world (needs internet card)
noteblock play <file|url|id> [...]   play local .nbs files or nbw songs
noteblock search tetris              quick search with ids
noteblock players                    list discovered player nodes
noteblock stop                       stop all nodes
```

Playback keys: `[space]` pause/resume, `[q]` stop. Downloads are cached in
`/home/music/`. All NBS versions parse (classic v0 through OpenNBS v5),
including tempo changers, per-note velocity and detune.

### Getting the most out of ONE computer

Each note block `trigger()` is a *synchronized* OpenComputers call — it
parks the machine until the next server tick — so one computer plays at
most ~20 notes/second, hard cap, no software can raise it. What software
*can* do is never waste a slot. The scheduler merges duplicate notes,
sorts chords by velocity, and — the big one — uses **slack scheduling**:
when a tick is full, overflow notes fire up to `--slack=2` ticks late
(quietest last) instead of being dropped. A 100ms spill is barely audible;
a missing note is not. On the test song this takes a single 4-block
computer from **39% of notes dropped to 0.1%** — nothing else required.
`--slack=0` restores strict on-time-or-drop.

The schedule report before playback shows played/late/dropped counts, so
you always know how a song fits your hardware. When a song is denser than
~20 notes/s *sustained*, more machines or redstone banks (below) are the
only ways up — chords also only become truly simultaneous with more
machines, since one machine serializes them a tick apart.

### Server racks: more speed with ZERO extra setup

The cheapest multiplier reuses the note blocks you already calibrated.
Every server blade in a Server Rack is a **full, independent OC machine**
with its own one-synchronized-call-per-tick slot — and through the rack's
side buses they all see the *same* component network, i.e. the same
note_block addresses your first computer uses. Since calibration is keyed
by those network-global addresses, it copies over as-is:

1. Place a rack next to your existing setup, wire its bus to the adapter
   network, insert server blades (each needs CPU/RAM/wireless card).
2. On each blade: `noteplayer import 2/4` (= "I am machine 2 of 4"), then
   run `noteplayer`. The blade fetches the calibration from the running
   daemon over the network and keeps every 4th block. On the original
   computer, re-run `noteplayer import 1/4` (it re-splits from its saved
   full copy in `/etc/noteplayer.full.cfg`).
3. Play. Four blades = 4x the notes/second on the same physical blocks.

The n/m split matters: two machines triggering the *same* block in the
same tick race on its pitch (Minecraft dedupes the block event), so each
machine must own a disjoint subset. `import` guarantees that.

### Redstone banks: more parallel chords per machine

Straight from the OC source: `redstone.setOutput{...}` is also a
synchronized call (plus a `misc.redstoneDelay` machine pause, 0.1s by
default), **but one call sets all 6 sides of a device at once** — and a
note block fires on a redstone rising edge with whatever pitch it already
has. So: wire note blocks to the sides of Redstone I/O blocks (or the
computer's redstone card), keep them *also* touching an Adapter, and you
get a **pre-tuned organ**: up to 6 perfectly simultaneous notes per call,
~40 notes/s per device-owning machine — 120/s if the server sets
`misc.redstoneDelay: 0` in `opencomputers.cfg`.

`noteplayer calibrate` maps the banks (it pulses each side and asks which
block rang). Per song, the master picks the hottest (instrument, pitch)
pairs, re-tunes the bank blocks through the Adapter, schedules what fits
onto banks (chords love this) and routes the rest through normal triggers.
On the test song, adding one 12-channel piano organ to a single computer
cut drops from 39% to 19%.

Cheap scaling tip: a microcontroller with a wireless card + redstone card
is a full OC machine with its own call budget — a dirt-cheap bank driver.

Options: `--pertick=N` (trigger notes per node per game tick, default 1),
`--rsdelay=S` (match the server's `misc.redstoneDelay`, default 0.1),
`--wait=S` (discovery window), `--nofallback` (drop notes for missing
instruments instead of substituting), `--port=3001`.

Upgrading from the old NoteblockPlayer: nodes migrate `calibration.dat`
to `/etc/noteplayer.cfg` automatically the first time `noteplayer` runs.

Test the toolkit on your PC: `lua tools/test_nbs.lua <song.nbs> [packed.zip]`.

## oc-manifest.cfg reference

```
file <repo path> <target path>          install a single file
dir <repo dir> <target dir>             install a whole directory tree
label <name>                            drive label (EEPROM installer only)
bios <repo path>                        Lua BIOS restored after install
openos <owner>/<repo> <branch> <path>   override the OpenOS download source
```

`#` starts a comment. Both the EEPROM installer and `ocgit install` apply the
`file`/`dir` directives; the rest only concern the installer.

## optimize — Lua source optimizer

`/usr/lib/optimize.lua` strips comments, indentation, blank lines and
redundant whitespace from Lua source without touching string literals, and
verifies the result still compiles (falling back to the original if not).

- `ocgit pull --optimize`, `ocdev --optimize`, `ocrun --optimize` shrink
  `.lua` files before writing — useful on small OC drives.
- `mkinstaller` uses it automatically to fit `boot.lua` into the 4KB EEPROM.
- In your own code: `local optimize = require("optimize")`,
  `local smaller, stats = optimize.safeStrip(source)`.

Note: an optimized checkout no longer matches the repo byte-for-byte; that's
fine for deployment targets, but keep your master checkout unoptimized.

## Troubleshooting

- **"an internet card is required"** — put an Internet Card in the computer.
- **HTTP 403 / rate limit** — unauthenticated GitHub API allows 60
  requests/hour per IP; use `--token=`. (The EEPROM installer uses at most
  3 API calls per run; file downloads via raw.githubusercontent don't count.)
- **GitHub rejects requests** — mod config `enableHttpHeaders` must be `true`
  (default); GitHub requires a `User-Agent` header.
- **"GitHub truncated the file list"** — very large repo; use `--path=`.
- **SSL/handshake errors (GitHub or ngrok)** — the Java 8 runtime running the
  game is too old to trust modern certificates. ngrok uses Let's Encrypt,
  which needs Java 8u141 or newer (the old default 8u51 fails). Update the
  JRE the game runs on.
- **ngrok returns an HTML page instead of files** — shouldn't happen (the
  tools send `ngrok-skip-browser-warning`), but if you test in a browser
  that page is expected on the free tier.
- **Installer EEPROM shows an error and halts** — the message stays on
  screen; most causes are no internet card, no hard drive, or a typo in the
  flashed repo config (re-run `mkinstaller`).

## Limitations (by design)

`ocgit` is pull-only. A real git client (packfiles, SHA-1 hashing, merges) is
impractical in OC's sandboxed Lua, and unnecessary: code is authored on the
PC where real git lives. If you ever need to push a file *from* in-game
(e.g. captured data), that's feasible via the GitHub Contents API with a
token and a Data Card for base64 — ask for it if you want it.
