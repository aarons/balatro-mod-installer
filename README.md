# Balatro mod installer (macOS)

A single command that installs and updates a curated set of Balatro mods on
macOS. Re-running it checks each component's installed version against the
latest and only downloads what's missing or out of date.

```bash
./install-balatro-mods.sh            # install / update everything
./install-balatro-mods.sh --status   # report what's installed vs available (no changes)
./install-balatro-mods.sh --force     # reinstall everything from scratch
./install-balatro-mods.sh --help
```

## What it installs

| Component | Where | Source |
|---|---|---|
| **Lovely injector** | game directory (next to `Balatro.app`) | latest GitHub **release** (arch-matched `.tar.gz`) |
| **Steamodded** (`smods`) | `Mods/smods/` | latest `main` |
| Amulet | `Mods/Amulet/` | latest `main` |
| JokerDisplay | `Mods/JokerDisplay/` | latest `main` |
| Cryptid | `Mods/Cryptid/` | latest `main` |
| UNIK | `Mods/UNIKs-mod/` | latest `main` |
| Bunco | `Mods/Bunco/` | latest `main` |
| Aikoyori's Shenanigans | `Mods/Aikoyoris-Shenanigans/` | latest `main` |
| All In Jest | `Mods/All-In-Jest/` | latest `main` |
| BetterStakes | `Mods/BetterStakes/` | latest `main` |
| NeowBlessings | `Mods/NeowBlessings/` | latest `main` |
| Paperback | `Mods/paperback/` | latest `main` |
| Typist | `Mods/balatro-typist-mod/` | latest `main` |

- **Lovely** is a compiled binary distributed only via GitHub Releases, so it's
  pinned to the latest release (`lovely-aarch64-apple-darwin.tar.gz` on Apple
  Silicon, `lovely-x86_64-apple-darwin.tar.gz` on Intel). Its two files
  (`liblovely.dylib`, `run_lovely_macos.sh`) go in the **game** directory, *not*
  the Mods folder.
- **Mods** are installed from the HEAD of their default branch. Most of these
  repos either ship no installable release asset or tag releases well behind
  their default branch, so "latest commit" is the most reliable "latest
  version". Each mod is placed in its own folder, with its `lovely/` patch
  files contained inside that folder (as Lovely requires).

## Requirements

- macOS, `curl`, `tar` (all stock). No `jq`/Python needed.
- `git` is used (via `git ls-remote`) to resolve the latest version without
  hitting GitHub's REST API rate limit. If `git` isn't installed it falls back
  to the REST API (anonymous: 60 requests/hour). Set `GITHUB_TOKEN` to raise
  that limit if needed.

## How updates / status are tracked

The installed version of each component (a commit SHA, or Lovely's release tag)
is recorded in `Mods/.balatro-mod-installer.state`. On each run the script
resolves the latest version and compares:

- folder missing → **install**
- recorded version ≠ latest → **update** (folder is replaced atomically)
- recorded version == latest and folder present → **up to date**, skipped

> Updating replaces a mod's folder with the latest version. If you've hand-edited
> a mod's in-folder config, it will be reset to that mod's default.

## Custom Balatro location

If Balatro isn't at the default Steam path, point the script at it:

```bash
BALATRO_GAME_DIR="/path/to/Balatro" ./install-balatro-mods.sh
# or:  ./install-balatro-mods.sh --game-dir "/path/to/Balatro"
```

(The game directory is the folder containing `Balatro.app` — in Steam:
right-click Balatro → Manage → Browse local files.) The script patches the
bundled `run_lovely_macos.sh` to match a non-default location.

## Launching the game

On macOS you **cannot launch through Steam** (a Steam client bug). Start the
game via Lovely instead:

```bash
sh "$HOME/Library/Application Support/Steam/steamapps/common/Balatro/run_lovely_macos.sh"
```

…or drag `run_lovely_macos.sh` from the game folder onto Terminal and press Enter.

## Notes on specific mods

- **Amulet** is a Talisman replacement/fork (big-number scaling). It declares
  `provides: ["Talisman"]` — don't also install Talisman alongside it.
- **Cryptid** requires Steamodded **and** Amulet — both are included above.
- **Bunco**, **All In Jest**, **UNIK** and others require Steamodded; it's
  installed first.
