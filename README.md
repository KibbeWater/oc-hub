# OC-LUA — develop OpenComputers scripts on your PC

Write Lua on your local machine, sync and deploy it into Minecraft
(OpenComputers, MC 1.12.2) over the Internet Card.

Repository: `github.com/KibbeWater/oc-hub`

| Tool | Runs | Purpose |
|------|------|---------|
| `ocgit` | in-game | Pull-only git client: `clone` / `pull` / `status` / `install` from GitHub |
| `ocdev` | in-game | Live sync from your PC — edits appear in-game within seconds |
| `ocrun` | in-game | Runs a dev script and **hot-restarts it** when the code updates |
| `mkinstaller` | in-game | Config window that flashes an **auto-installer EEPROM** |
| `tools/serve.py` | on PC | Dev server that `ocdev`/`ocrun` sync from |

`oc-manifest.cfg` in the git root declares where every file gets installed
(programs to `/usr/bin`, libraries to `/usr/lib`, ...). It is read by the
EEPROM auto-installer and by `ocgit install`.

## Repository layout

```
oc-manifest.cfg        install manifest (what goes where in-game)
ocgit/ocgit.lua        pull-only git client (GitHub API)
ocgit/ocdev.lua        live-sync watcher
ocgit/ocrun.lua        live-sync + managed process with hot restart
ocgit/json.lua         JSON decoder library      -> /usr/lib/json.lua
ocgit/optimize.lua     Lua source optimizer      -> /usr/lib/optimize.lua
installer/flash.lua    mkinstaller (EEPROM config window)
installer/boot.lua     bootstrap BIOS flashed onto the EEPROM (<4KB)
installer/stage2.lua   full installer, downloaded by boot.lua at boot
installer/luabios.lua  standard Lua BIOS restored after installation
tools/serve.py         dev server for live sync
```

## Bootstrap a "master" computer in-game

On an OpenOS computer with an internet card:

```
mkdir /usr/lib
mkdir /usr/bin
wget https://raw.githubusercontent.com/KibbeWater/oc-hub/main/ocgit/json.lua /usr/lib/json.lua
wget https://raw.githubusercontent.com/KibbeWater/oc-hub/main/ocgit/ocgit.lua /usr/bin/ocgit.lua
ocgit clone KibbeWater/oc-hub /home/work
cd /home/work
ocgit install
```

`ocgit install` reads `oc-manifest.cfg` and copies everything to its declared
target, so after this the whole toolkit is on the PATH. Every other computer
can be set up automatically with an installer EEPROM (below).

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
