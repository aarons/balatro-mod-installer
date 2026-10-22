# Balatro mod installer

A single command that installs and updates a curated set of Balatro mods.
Re-running it checks each component's installed version against the list and
only downloads what's missing or out of date. Mod folders that aren't in the
list are kept in the Mods directory by default, so hand-installed or
experiments mods won't be deleted — pass `--remove-extra` to remove them
instead.

## Architecture

The repo is one data file and two programs:

| File | Role |
|---|---|
| `mods.csv` | **The mod list** — one hand-edited line per mod: `name,type,url,ref,folder`. No pinned versions; `ref` says *what to track* (`@release`, a branch, or an explicit tag/SHA pin). |
| `install.sh` | **The installer** — everything else. Detects the platform (macOS native / Steam Deck Proton), resolves each mod's `ref` to a concrete version at run time, downloads, installs. On the Deck (no local `mods.csv`) it fetches the list from GitHub and keeps *itself* up to date from the repo before running. |
| `share.sh` | **First-time Deck transfer** — serves the repo over the LAN so a new Steam Deck can curl `install.sh` once without typing a GitHub URL. Never needed again after that. |

Typical use — the same zero-flag command everywhere:

```bash
# macOS (repo checkout — uses the mods.csv next to the script):
./install.sh              # resolve latest versions, install / update everything

# Steam Deck (a lone copy of install.sh — fetches mods.csv from GitHub,
# self-updates from the repo first):
./install.sh

# common flags:
#   --status        report installed vs latest, change nothing
#   --force         reinstall everything from scratch
#   --remove-extra  remove unlisted mod folders (default: keep them)
#   --remote        fetch mods.csv from GitHub even in a checkout
#   --mods-file F   use a specific mod list
#   --no-self-update
#   --help
```

There is no separate "update" step: versions are resolved fresh on every run,
so re-running `./install.sh` *is* the update. Nothing machine-generated is
committed to the repo — `mods.csv` only changes when you add, remove, or pin
a mod.

### Version pinning

Each mod's `ref` in `mods.csv` is one of:

| `ref` | Meaning |
|---|---|
| `@release` | track the latest GitHub release (most mods; best compatibility) |
| a branch name | track that branch's latest commit (repos without releases) |
| a tag name | **pin** to that exact release |
| a 40-char commit SHA | **pin** to that exact commit |

If a mod update breaks something, look up the last-good version in
`Mods/.balatro-mod-installer.state` on the affected machine, put that tag/SHA
in the mod's `ref`, and re-run.

Mod repo `url`s are full URLs (currently all GitHub). `git ls-remote`
resolution already works against any git host; to *download* from another
host, add its archive-URL patterns to `source_tarball_url()` /
`release_asset_url()` in `install.sh`.

## What it installs

| Component | Where | Source |
|---|---|---|
| **Lovely injector** | game directory (next to `Balatro.app` / `Balatro.exe`) | latest **release** (platform-matched asset) |
| **Steamodded** (`smods`) | `Mods/smods/` | latest **release** |
| Amulet, JokerDisplay, Cartomancer, Handy, Cryptid, UNIK, Bunco, All In Jest, Typist, BUMod, Blueprint, Malverk, Saturn, Pokermon | `Mods/<folder>/` | latest **release** |
| BetterStakes, NeowBlessings, WhatsInMyFool, ExtraCredit | `Mods/<folder>/` | latest `main` (no releases shipped) |

- **Lovely** is a compiled binary distributed only via GitHub Releases. On
  **macOS** that's `lovely-aarch64-apple-darwin.tar.gz` (Apple Silicon) or
  `lovely-x86_64-apple-darwin.tar.gz` (Intel), and its two files
  (`liblovely.dylib`, `run_lovely_macos.sh`) go in the **game** directory.
  On **Steam Deck / Linux** it's the Windows build
  (`lovely-x86_64-pc-windows-msvc.zip`), and its single file (`version.dll`)
  goes in the game directory. Either way, Lovely goes next to the game
  executable, *not* in the Mods folder.
- **Steamodded** tracks its latest **release** rather than `main`: the `main`
  branch carries an in-progress blind/scoring refactor that content mods
  haven't adopted yet (it caused a load-time crash with Paperback), and the
  Steamodded team recommends the latest release for mod compatibility.
- **NeowBlessings** is installed from a [maintained fork](https://github.com/aarons/Balatro-NeowBlessings)
  rather than the upstream `kjossul/NeowBlessings`. Upstream is unmaintained
  (open issues/PRs ignored) and ships a global `create_joker` function that
  collides with other mods (e.g. All-In-Jest), crashing when a joker blessing
  is picked. The fork renames it to `neow_create_joker` to avoid the collision.
- Each mod is placed in its own folder, with its `lovely/` patch files
  contained inside that folder (as Lovely requires).

## Install locations

Default paths (override with `BALATRO_GAME_DIR` / `BALATRO_MODS_DIR` or the
`--game-dir` / `--mods-dir` flags):

| | macOS | Steam Deck / Linux (Proton) |
|---|---|---|
| **Game dir** (`Balatro.app` / `Balatro.exe` + Lovely) | `~/Library/Application Support/Steam/steamapps/common/Balatro` | `~/.local/share/Steam/steamapps/common/Balatro` |
| **Mods dir** (the `Mods/` folder, each mod in its own subfolder) | `~/Library/Application Support/Balatro/Mods` | `…/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods` |

- On **macOS** the Mods folder is under `Application Support/Balatro/`, **not**
  next to the game — the two `Application Support` paths above are different
  directories.
- On **Steam Deck** the Mods folder is inside Balatro's Proton prefix (the
  Windows `%AppData%` mapped into `compatdata/2379780/`). The script
  auto-locates the game across all Steam libraries (including an SD card
  listed in `libraryfolders.vdf`) and derives the Mods path from that same
  library.
- The installed-version record for every component lives at
  `Mods/.balatro-mod-installer.state` (see [How updates / status are
  tracked](#how-updates--status-are-tracked)).

## Requirements

- **macOS**: `curl`, `tar` (stock). `git` is preferred for resolving branch
  versions (`git ls-remote` — not rate-limited); without it the script falls
  back to the GitHub REST API (anonymous: 60 requests/hour — fine for one
  run; set `GITHUB_TOKEN` to raise it).
- **Steam Deck / Linux**: the above plus one of `unzip` / `bsdtar` / `python3`
  to unpack Lovely's Windows `.zip` (all stock on SteamOS).

## How updates / status are tracked

The installed version of each component (a commit SHA, or a release tag) is
recorded in `Mods/.balatro-mod-installer.state`. On each run the installer
resolves every `ref` to the current version and compares:

- folder missing → **install**
- recorded version ≠ resolved version → **update** (folder is replaced atomically)
- recorded version == resolved version and folder present → **up to date**, skipped

If a mod's version can't be resolved (offline, rate limit), the installer
reports it and leaves whatever is installed untouched.

> Updating replaces a mod's folder with the latest version. If you've
> hand-edited a mod's in-folder config, it will be reset to that mod's default.

## Custom Balatro location (macOS)

If Balatro isn't at the default Steam path, point the script at it:

```bash
BALATRO_GAME_DIR="/path/to/Balatro" ./install.sh
# or:  ./install.sh --game-dir "/path/to/Balatro"
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

One-time setup — in **Desktop Mode** on the Deck, open Konsole and run:

```bash
curl -fO https://raw.githubusercontent.com/aarons/balatro-mod-installer/main/install.sh
chmod +x install.sh
```

(Or run `./share.sh` on the Mac and use the shorter LAN one-liner it prints —
same result, less typing on the Deck.)

From then on, everything is one command — no Mac, no LAN server:

```bash
./install.sh             # self-update + latest mod list from GitHub + install
./install.sh --status    # report only
./install.sh --force     # reinstall everything
```

Since there's no `mods.csv` next to the lone script, it fetches the list from
this repo on every run — and first refreshes *itself* from the repo, so the
copy on the Deck never goes stale.

On Linux there is **no native Balatro build** — Steam runs the *Windows* game
through Proton. The script accounts for this:

- **Lovely is the Windows `version.dll`** (`lovely-x86_64-pc-windows-msvc.zip`),
  placed next to `Balatro.exe` in the game directory — not the Linux `.so`.
- **Mods live inside Balatro's Proton prefix**, not a native folder:
  `…/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods`.
- **You must launch Balatro through Steam once first.** The Proton prefix
  (where mods live) doesn't exist until the game's first run. If the script
  reports the prefix is missing, launch Balatro once, quit, and re-run.
- **Extraction needs a zip tool.** The Windows Lovely build is a `.zip`, so
  the script uses `unzip`, `bsdtar`, or `python3` (whichever is present — all
  stock on SteamOS).

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
`BALATRO_GAME_DIR=… BALATRO_MODS_DIR=… ./install.sh` (or the `--game-dir` /
`--mods-dir` flags).

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
