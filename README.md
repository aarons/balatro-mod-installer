# Balatro mod installer

A single command that installs and updates a curated set of Balatro mods.
Re-running it checks each component's installed version against the latest and
only downloads what's missing or out of date. There are two independent,
self-contained scripts — one per platform:

| Script | Platform |
|---|---|
| `install-balatro-mods.sh` | **macOS** (native build, Lovely `dylib`) |
| `install-balatro-mods-steamdeck.sh` | **Steam Deck / Linux** (Proton, Lovely `version.dll`) |

```bash
./install-balatro-mods.sh            # macOS:      install / update everything
./install-balatro-mods-steamdeck.sh  # Steam Deck:  install / update everything

# both scripts take the same flags:
#   --status   report what's installed vs available (no changes)
#   --force    reinstall everything from scratch
#   --help
```

The two scripts install the **same set of mods** (the mods are platform-agnostic
Lua). They differ only in how/where Lovely and the Mods folder go — see
[Steam Deck / Linux](#steam-deck--linux-proton) below for the Proton specifics.

## What it installs

| Component | Where | Source |
|---|---|---|
| **Lovely injector** | game directory (next to `Balatro.app` / `Balatro.exe`) | latest GitHub **release** (platform-matched asset) |
| **Steamodded** (`smods`) | `Mods/smods/` | latest **release** |
| Amulet | `Mods/Amulet/` | latest `main` |
| JokerDisplay | `Mods/JokerDisplay/` | latest `main` |
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

> In `MODS_TABLE` (in the script) each mod's 4th field is either a branch name
> (track that branch's latest commit) or the literal `@release` (track the
> latest GitHub release). Flip any mod between the two by editing that field.

## Requirements

- **macOS**: `curl`, `tar` (all stock). No `jq`/Python needed.
- **Steam Deck / Linux**: `curl`, `tar`, and one of `unzip` / `bsdtar` /
  `python3` to unpack Lovely's Windows `.zip` (all stock on SteamOS).
- `git` is used (via `git ls-remote`) to resolve the latest version without
  hitting GitHub's REST API rate limit. If `git` isn't installed (it's not in
  the SteamOS base image) it falls back to the REST API (anonymous: 60
  requests/hour — fine for a single run of ~12 lookups). Set `GITHUB_TOKEN` to
  raise that limit if needed.

## How updates / status are tracked

The installed version of each component (a commit SHA, or a release tag)
is recorded in `Mods/.balatro-mod-installer.state`. On each run the script
resolves the latest version and compares:

- folder missing → **install**
- recorded version ≠ latest → **update** (folder is replaced atomically)
- recorded version == latest and folder present → **up to date**, skipped

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

Use `install-balatro-mods-steamdeck.sh`. Copy it to the Deck (e.g. into your home
folder), then in **Desktop Mode** open Konsole and run:

```bash
chmod +x install-balatro-mods-steamdeck.sh
./install-balatro-mods-steamdeck.sh            # install / update everything
./install-balatro-mods-steamdeck.sh --status   # report only
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
