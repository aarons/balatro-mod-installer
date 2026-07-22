# Balatro mod installer

A single command that installs and updates a curated set of Balatro mods.
Re-running it checks each component's installed version against the list and
only downloads what's missing or out of date. Mod folders that aren't in the
list are removed from the Mods directory, so mods dropped from `mods.csv`
(or installed by hand) don't linger — pass `--keep-extra` to keep them.

## Architecture

The repo has one data file and three kinds of programs, each with a single job:

| File | Role |
|---|---|
| `mods.csv` | **The mod list** — one line per mod with its GitHub repo, tracked ref, resolved version, and download URL. The single source of truth for both installers. |
| `update-mods.sh` | **Version discovery** — resolves the latest version of every entry (branch HEAD or latest release) and rewrites the `version`/`url` columns of `mods.csv`. The only program that talks to the GitHub API. |
| `install-balatro-mods.sh` | **macOS installer** (native build, Lovely `dylib`). Reads `mods.csv`, downloads, installs. No version discovery. |
| `install-balatro-mods-steamdeck.sh` | **Steam Deck / Linux installer** (Proton, Lovely `version.dll`). Same, for the Proton setup. |
| `share.sh` | **Transfer** — serves the repo over the LAN; the Steam Deck curls the installer once, and the installer fetches `mods.csv` from this server on every run. |

Typical maintenance flow:

```bash
./update-mods.sh                     # resolve latest versions into mods.csv
git diff mods.csv                    # review what moved
git commit -am "chore: bump mod versions"

./install-balatro-mods.sh            # macOS:      install / update everything
./install-balatro-mods-steamdeck.sh  # Steam Deck:  install / update everything

# both installers take the same flags:
#   --status      report installed vs mods.csv (no changes)
#   --force       reinstall everything from scratch
#   --mods-file   use a different mod list (default: mods.csv next to the script)
#   --help
# update-mods.sh takes --check (report what would change, write nothing).
```

The two installers install the **same set of mods** (the mods are
platform-agnostic Lua). They differ only in how/where Lovely and the Mods
folder go — see [Steam Deck / Linux](#steam-deck--linux-proton) below for the
Proton specifics.

## What it installs

| Component | Where | Source |
|---|---|---|
| **Lovely injector** | game directory (next to `Balatro.app` / `Balatro.exe`) | latest GitHub **release** (platform-matched asset) |
| **Steamodded** (`smods`) | `Mods/smods/` | latest **release** |
| Amulet | `Mods/Amulet/` | latest `main` |
| JokerDisplay | `Mods/JokerDisplay/` | latest `main` |
| Cartomancer | `Mods/Cartomancer/` | latest `main` |
| Handy | `Mods/HandyBalatro/` | latest `main` |
| Cryptid | `Mods/Cryptid/` | latest `main` |
| UNIK | `Mods/UNIKs-mod/` | latest `main` |
| Bunco | `Mods/Bunco/` | latest `main` |
| All In Jest | `Mods/All-In-Jest/` | latest `main` |
| BetterStakes | `Mods/BetterStakes/` | latest `main` |
| NeowBlessings | `Mods/NeowBlessings/` | latest `main` (maintained [fork](https://github.com/aarons/Balatro-NeowBlessings)) |
| Typist | `Mods/balatro-typist-mod/` | latest `main` |

- **Lovely** is a compiled binary distributed only via GitHub Releases, so it's
  pinned to the latest release. On **macOS** that's `lovely-aarch64-apple-darwin.tar.gz`
  (Apple Silicon) or `lovely-x86_64-apple-darwin.tar.gz` (Intel), and its two
  files (`liblovely.dylib`, `run_lovely_macos.sh`) go in the **game** directory.
  On **Steam Deck / Linux** it's the Windows build (`lovely-x86_64-pc-windows-msvc.zip`),
  and its single file (`version.dll`) goes in the game directory. Either way,
  Lovely goes next to the game executable, *not* in the Mods folder.
- **Steamodded** is pinned to its latest **release** rather than `main`: the
  `main` branch carries an in-progress blind/scoring refactor that content mods
  haven't adopted yet (it caused a load-time crash with Paperback), and the
  Steamodded team recommends the latest release for mod compatibility.
- **Other mods** are installed from the HEAD of their default branch. Most of
  these repos either ship no installable release asset or tag releases well
  behind their default branch, so "latest commit" is the most reliable "latest
  version". Each mod is placed in its own folder, with its `lovely/` patch
  files contained inside that folder (as Lovely requires).
- **NeowBlessings** is installed from a [maintained fork](https://github.com/aarons/Balatro-NeowBlessings)
  rather than the upstream `kjossul/NeowBlessings`. Upstream is unmaintained
  (open issues/PRs ignored) and ships a global `create_joker` function that
  collides with other mods (e.g. All-In-Jest), crashing when a joker blessing
  is picked. The fork renames it to `neow_create_joker` to avoid the collision.

> In `mods.csv` each mod's `ref` field is either a branch name (track that
> branch's latest commit) or the literal `@release` (track the latest GitHub
> release). Flip any mod between the two by editing that field, then run
> `./update-mods.sh` to re-resolve. To add a mod, add a line with its
> `name,type,repo,ref,folder` and blank `version,url` — the updater fills them.

## Install locations

Where each script puts things by default (these are the paths to inspect to find
the locally-installed mods). Override with `BALATRO_GAME_DIR` / `BALATRO_MODS_DIR`
or the `--game-dir` / `--mods-dir` flags.

| | macOS | Steam Deck / Linux (Proton) |
|---|---|---|
| **Game dir** (`Balatro.app` / `Balatro.exe` + Lovely) | `~/Library/Application Support/Steam/steamapps/common/Balatro` | `~/.local/share/Steam/steamapps/common/Balatro` |
| **Mods dir** (the `Mods/` folder, each mod in its own subfolder) | `~/Library/Application Support/Balatro/Mods` | `…/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods` |

- On **macOS** the Mods folder is under `Application Support/Balatro/`, **not**
  next to the game — the two `Application Support` paths above are different
  directories. So an installed mod lives at e.g.
  `~/Library/Application Support/Balatro/Mods/Cryptid/`.
- On **Steam Deck** the Mods folder is inside Balatro's Proton prefix (the
  Windows `%AppData%` mapped into `compatdata/2379780/`). The script
  auto-locates the game across all Steam libraries (including an SD card listed
  in `libraryfolders.vdf`) and derives the Mods path from that same library, so
  the root may differ if Balatro is installed on a secondary library.
- The installed-version record for every component lives at
  `Mods/.balatro-mod-installer.state` (see [How updates / status are
  tracked](#how-updates--status-are-tracked)).

## Requirements

- **Installers — macOS**: `curl`, `tar` (all stock), plus `mods.csv` next to
  the script. No `jq`/Python/`git` needed.
- **Installers — Steam Deck / Linux**: `curl`, `tar`, one of `unzip` /
  `bsdtar` / `python3` to unpack Lovely's Windows `.zip` (all stock on
  SteamOS). `mods.csv` is fetched from the share endpoint automatically.
- **`update-mods.sh`**: `curl`; prefers `git` (via `git ls-remote`) to resolve
  branch versions without hitting GitHub's REST API rate limit, falling back
  to the REST API (anonymous: 60 requests/hour — fine for a single run of ~12
  lookups; set `GITHUB_TOKEN` to raise it). The installers themselves never
  touch the GitHub API.

## How updates / status are tracked

The installed version of each component (a commit SHA, or a release tag)
is recorded in `Mods/.balatro-mod-installer.state`. On each run the installer
compares it against the version pinned in `mods.csv`:

- folder missing → **install**
- recorded version ≠ mods.csv → **update** (folder is replaced atomically)
- recorded version == mods.csv and folder present → **up to date**, skipped

"Latest" therefore means "latest as of the last `./update-mods.sh` run" — the
installers are fully deterministic given a `mods.csv`.

> Updating replaces a mod's folder with the latest version. If you've hand-edited
> a mod's in-folder config, it will be reset to that mod's default.

## Custom Balatro location (macOS)

If Balatro isn't at the default Steam path, point the script at it:

```bash
BALATRO_GAME_DIR="/path/to/Balatro" ./install-balatro-mods.sh
# or:  ./install-balatro-mods.sh --game-dir "/path/to/Balatro"
```

(The game directory is the folder containing `Balatro.app` — in Steam:
right-click Balatro → Manage → Browse local files.) The script patches the
bundled `run_lovely_macos.sh` to match a non-default location.

## Launching the game (macOS)

On macOS you **cannot launch through Steam** (a Steam client bug). Start the
game via Lovely instead:

```bash
sh "$HOME/Library/Application Support/Steam/steamapps/common/Balatro/run_lovely_macos.sh"
```

…or drag `run_lovely_macos.sh` from the game folder onto Terminal and press Enter.

## Steam Deck / Linux (Proton)

Use `install-balatro-mods-steamdeck.sh`. Run `./share.sh` on the Mac, then in
**Desktop Mode** on the Deck open Konsole and run the one-liner it prints:

```bash
curl -fO http://<mac-ip>:8000/install-balatro-mods-steamdeck.sh \
  && bash install-balatro-mods-steamdeck.sh
```

The installer fetches `mods.csv` from the share endpoint by itself (hardcoded
default `http://192.168.1.16:8000`; override with `--share-url` or
`BALATRO_SHARE_URL`) and caches it next to the script, so re-running works even
if the Mac is offline — it just uses the last-fetched list. Useful flags:

```bash
bash install-balatro-mods-steamdeck.sh --status   # report only
bash install-balatro-mods-steamdeck.sh --force    # reinstall everything
```

On Linux there is **no native Balatro build** — Steam runs the *Windows* game
through Proton. The script accounts for this; the differences from the macOS
version are:

- **Lovely is the Windows `version.dll`** (`lovely-x86_64-pc-windows-msvc.zip`),
  placed next to `Balatro.exe` in the game directory — not the Linux `.so`.
- **Mods live inside Balatro's Proton prefix**, not a native folder:
  `…/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods`.
  The script auto-locates the game across the usual Steam library roots **and**
  any extra libraries listed in `libraryfolders.vdf` (e.g. an SD card), then
  derives the Mods folder from that same library.
- **You must launch Balatro through Steam once first.** The Proton prefix (where
  mods live) doesn't exist until the game's first run. If the script reports the
  prefix is missing, launch Balatro once, quit, and re-run.
- **Extraction needs a zip tool.** The Windows Lovely build is a `.zip`, so the
  script uses `unzip`, `bsdtar`, or `python3` (whichever is present — all stock
  on SteamOS).

> ### Required one-time Steam setup
> For Lovely to load under Proton you **must** set a launch option. In Steam,
> right-click **Balatro → Properties → General → Launch Options** and paste
> exactly:
>
> ```
> WINEDLLOVERRIDES="version=n,b" %command%
> ```
>
> Without this, Proton loads its own built-in `version.dll` and **no mods will
> load.** You only set it once. After that, just launch Balatro normally from
> Steam (Game Mode or Desktop Mode) — Lovely injects automatically. The script
> reprints this reminder after a successful run.

If Balatro is on a custom path, override detection the same way as on macOS:
`BALATRO_GAME_DIR=… BALATRO_MODS_DIR=… ./install-balatro-mods-steamdeck.sh`
(or the `--game-dir` / `--mods-dir` flags).

## Notes on specific mods

- **Amulet** is a Talisman replacement/fork (big-number scaling). It declares
  `provides: ["Talisman"]` — don't also install Talisman alongside it.
- **Cryptid** requires Steamodded **and** Amulet — both are included above.
- **Bunco**, **All In Jest**, **UNIK** and others require Steamodded; it's
  installed first.
- **Cartomancer** is a performance/QoL mod for big runs: it can hide joker
  cards (a large win at 100+ jokers, e.g. on Steam Deck), fixes a vanilla UI
  memory leak, and adds joker stacking/scrolling. Configure it from its own
  in-game options page.
- **Handy** adds extra game-speed steps (adjustable in-run) and an
  animation-skip toggle for instant scoring. Every feature can be toggled
  individually in its in-game menu. Pairs well with the vanilla
  **Reduced Motion** setting, which stops the constant card/joker wiggle.
