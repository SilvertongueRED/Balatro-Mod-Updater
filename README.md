# Balatro Mod Updater

Keeps your Balatro mods, **Steamodded** and **Lovely Injector** up to date, backs everything up before it changes anything, and rescues you when an update breaks the game.

> **Windows only.** Needs Windows PowerShell 5.1, [Steamodded](https://github.com/Steamopollys/Steamodded) 1.x and Lovely.

## Contents
- [Features](#features)
- [Installation](#installation)
- [How each mod is updated](#how-each-mod-is-updated)
- [In-game tabs](#in-game-tabs)
- [Fork Finder and the GitHub token](#fork-finder-and-the-github-token)
- [Saved copies of the game](#saved-copies-of-the-game)
- [If the game won't start after an update](#if-the-game-wont-start-after-an-update)
- [Settings](#settings-autoupdater_configjson)
- [Troubleshooting](#known-limits-and-troubleshooting)
- [Changelog](#changelog)

## Features

| | |
|---|---|
| **Updates from anywhere** | Mods installed from a **Git** page, **GitHub Releases** or **Nexus Mods**, plus Steamodded and Lovely. Always jumps straight to the newest version. |
| **Backups first** | Every mod and framework is backed up before it is updated. Restore or **pin** any backup from the Backups tab. |
| **Crash protection** | If an update crashes the game, a recovery screen offers to put the updated mods back. |
| **Fork Finder** | Finds forks of your mods that have newer work and lets you switch to one (and back). |
| **Saved game copies** | Saves Balatro's game files and switches back to the old version when a Steam update would break your mods. |
| **Search, sort, filter** | Every list tab has live search, sort, show filters and first/last page buttons, with full controller support. |
| **Restart now or later** | After updates you pick **Restart now** or **Later**. |

Auto-checking at startup is **off by default**. Turn it on in the mod's Config tab.

## Installation

1. Install Steamodded and Lovely.
2. Put the `Balatro-Mod-Updater` folder in your Balatro `Mods` folder.
3. Start Balatro and open **Mods > Mod Updater**.
4. Optional: add your Nexus API key (**Config > How do I get a key?**) and turn on **Auto-check at startup**.

## How each mod is updated

| Mod folder has... | What happens |
|---|---|
| `update.json` with `"provider": "github"` or `"nexus"` | That source is used, even if the folder is also a git clone. |
| A git clone | `git pull`. An `update.json` with `"branch": "stable"` switches to and follows that branch. |
| Neither | Never checked. Listed under `untracked_mods` in `last_run.json`. |

### GitHub (`update.json`)
```json
{ "provider": "github", "repo": "Owner/Repo", "track": "auto" }
```

| Option | Meaning |
|---|---|
| `track` | `auto` (default): releases if the repo has any, otherwise the newest commit on the default branch. `release`: releases only. `branch`: always the newest commit (add `"branch": "name"` to pick the branch). |
| `include_prereleases` | `true` also accepts pre-releases. |
| `asset_regex` | Picks the release file. If nothing matches, the source-code zip is used. |
| `strip_single_top_folder` | `true` (default) unpacks a zip with one top folder straight into the mod folder. |

### Nexus (`update.json`)
```json
{ "provider": "nexus", "mod_id": 12345 }
```
- Only **MAIN** files are used and the newest upload wins. Use `file_name_regex` to pick one file when a mod has several.
- Nexus only allows API downloads for **Premium** accounts. On a free account you get "update available" with a link.

### Git
- Leftover merge conflict markers (`<<<<<<<`) are repaired automatically.
- If your local edits clash with an update, the update still goes in and your edits are saved in `git stash list`.
- `git_reset_on_diverge: true` in `autoupdater_config.json` resets mods whose author rewrote history (a backup is made first).

### Steamodded and Lovely
- Steamodded is checked by reading its `version.lua`. Lovely is checked by comparing `version.dll` with the latest release.
- Updates are staged and applied by `apply_pending.ps1` after Balatro closes. Click **Restart now** to apply them.
- Applying never replaces Steamodded with the same or an older version, and old staged updates are removed once you are current.

## In-game tabs

| Tab | What it does |
|---|---|
| **Mod Toggles** | Turn update checks on or off per mod, **All on / All off**, **Save list / Restore list**, per-mod **Check** button, sort (A-Z / Recent) and **Show** filter (All / ON / OFF). |
| **Backups** | Version in use and last update for each mod, restore or pin a backup, **Unpin**, sort and **Show** filter (All / Pinned). Hover a row for a summary of the newest changes. |
| **Fork Finder** | Forks with newer work, **Switch to Fork / Switch Back**, **Scan Now**, GitHub token setup. |
| **No Source** | Mods with no git clone or `update.json`. Paste their GitHub or Nexus link to create one. |
| **Config** | Nexus key, GitHub token, auto-check, pin retry, game backup options. |

Every screen has a red **Close all** button (**hold B** on a controller or press **Esc**). Controller: **LT / RT** switch tabs, **LB / RB** turn pages (hold to jump to the first or last page), **R3** jumps to search (hold to clear).

## Fork Finder and the GitHub token

Fork Finder lists forks of your mods with newer work (**Show newer forks only**, the default) or every recently active fork (**Show all forks**). **Scan Now** scans for whichever is selected.

GitHub only allows 60 requests per hour without a token, so a scan of a big mod list stops early. **Fix it once, in about a minute:**

1. Open **Fork Finder**, click **GitHub token**, then **Open GitHub page**.
2. Name: `Balatro Mod Updater`. Expiration: `90 days`. Repository access: **Public repositories (read-only)**. Leave all permissions untouched.
3. Click **Generate token** and copy it (starts with `github_pat_`).
4. Back in the game click **Paste token**, then **Scan Now**.

The token only reads public data. When it expires the next scan offers **Yes, replace it**.

## Saved copies of the game

- The first check saves a copy of the Balatro game files in `AMU_GameBackups`, next to your `Mods` folder. Every new Steam build is saved too, and the newest 3 copies are kept (`game_backup_keep`).
- When Steam updates the game, the Updater saves the new version, stages a switch back to the saved copy you were on, and **freezes mod and Steamodded/Lovely updates**, because a mod built for the new game could crash the old one.
- Updates stay frozen until you turn them on: **Mods > Mod Updater > Backups > Balatro game files > Use Steam's newest game + turn updates on**.
- **Allow mod updates on a saved copy** (same window) lets mods update on an older game. Only use it if you know what you are doing.
- `Use backed up game.bat` does the same from outside the game: pick a saved copy by number, or **S** for Steam's version. Close Balatro first.
- Turn the feature off with `"game_backup": false`, or only the automatic switch with **Auto-switch to saved game** in Config.

## If the game won't start after an update

1. **Crash before the main menu:** a recovery screen lists the mods that were just updated. Choose **Put them all back and restart**, **Choose which mods to put back...**, or **Show the crash report** (changes nothing).
2. **The game reaches the main menu after a failed start:** the **Crash Detected** question appears. Nothing changes until you answer.
3. **Neither screen shows up:** close Balatro and double-click `Undo last update.bat`. Press **Enter** to put everything back, type numbers like `1,3` for only some, or `K` to keep everything.
4. **A Steam update broke your mods:** the Updater switches back to the saved game by itself. By hand, close Balatro and run `Use backed up game.bat`.

Put-back mods are **pinned**: they are not updated again until you unpin them in **Backups**, or until their source has a newer version and **Retry pinned mods when newer** is on.

## Settings (`autoupdater_config.json`)

| Setting | Default | Meaning |
|---|---|---|
| `github_token` | empty | Raises GitHub's limit from 60 to 5000 requests per hour. Easier to set from the **GitHub token** button. |
| `report_untracked` | `true` | `false` stops listing untracked mods. |
| `game_backup` | `true` | Save copies of the game files. |
| `game_backup_keep` | `3` | How many saved game copies to keep. |
| `game_auto_switch` | `true` | Switch back to the saved game after a Steam update. |
| `allow_updates_on_backup_game` | `false` | Let mods update while an older saved game is installed. |
| `pin_retry_newer` | `true` | Release a pin and update when the source has something newer. |

## Known limits and troubleshooting

**Install and environment**
- **Game does not relaunch after Restart now.** Task Scheduler may be blocked by antivirus or a work policy. The Updater falls back to the `steam://` link: start the game from Steam yourself.
- **Updates never run.** Check that Windows PowerShell 5.1 is installed and scripts are allowed to start.
- **Antivirus flags `autoupdate.ps1`.** A script that downloads files can look suspicious. The whole script is readable in this repository.

**Network limits (not a bug in the mod)**
- **GitHub 60 requests per hour without a token.** Fork scans fail first. Use the **GitHub token** button.
- **Nexus key rejected or rate limited.** Paste the key again, or wait an hour. Error 401 means the key was rejected.
- **Download cut off mid-update.** Can leave a half-extracted mod. Restore the newest backup from **Backups**.

**Steamodded and Lovely**
- **Update staged, not applied.** Click **Restart now**. If you just quit, it is applied when the game closes.
- **Restoring by hand.** Backups are zips in `_framework_backups`, plus `winmm.dll.bak_<date>` files next to Lovely.

**Folder names with a version in them**
- Updates change the files, not the folder name. Rename the folder by hand with the game closed. This resets that mod's toggle and pin, because they are saved by folder name.

**Conflicts with other mods**
- **Mods that replace `love.wheelmoved`** (Better Mouse and Gamepad is one): if wheel scrolling fails, check your other mods.
- **Controller mods that use R3 or S:** the search key may do nothing. Click the search box with the mouse.
- **Old copies of a mod inside `Mods`:** two mods with the same ID crash the game. Move backups and `.bak` copies out of `Mods`.

## Changelog

### 1.0.0
First 1.0 release: the 0.8.x series polished and bug-fixed.
- New: bottom-right pop-up when a check or scan ends (**All mods up to date!**, **N new forks found**). Click it to open Fork Finder.
- New: saved copies of the game, with automatic switch back and an update freeze after a Steam update.
- New: pinned mods are retried when their source has something newer (**Retry pinned mods when newer**).
- New: Fork Finder can **ignore a whole mod** (square on each row) and **ignore single forks** (**Ignore scans**), with an **Ignored: Hidden/Shown** button.
- New: **Show** filters on Mod Toggles (All / ON / OFF) and Backups (All / Pinned).
- New: **<<** and **>>** buttons on every list. Controller: hold LB / RB for first / last page.
- New: restart window after Restore & Pin, switching to a fork and switching back.
- New: Unpin checks that mod for a newer version at once.
- New: green / red names on Backups (newest version vs a saved older copy in use).
- New test files: `Test pins and latest.bat`, `Test game backup.bat`, `Test fork ignore.bat`, `Test startup crash.bat`.
- Changed: the fork scan follows the Fork Finder filter and remembers its mode (`scan_mode`). Show all forks uses more GitHub requests, so use a token.
- Changed: switching to a fork or back is faster, and `update_timing_history.txt` logs the time of each step.
- Changed: Checking... and Shuffling mods... start and stop together. Sort, filters and pins are saved immediately.
- Changed: the restart helper runs hidden (no PowerShell window).
- Fixed: Fork Finder stuck on "Scanning for forks...".
- Fixed: "No common ancestor" is skipped quietly instead of shown as a 404 error.
- Fixed: picking a mod's original repo in Fork Finder now does **Switch Back**.
- Fixed: a pin made right before **Restart now** could be lost.

### 0.8.4
- Fixed: holding **S** clears the search even while typing (Mod Toggles, Backups, Fork Finder).
- Fixed: leaving the search box with a controller no longer shifts the tab sideways.
- Fixed: a leftover on-screen keyboard no longer freezes keyboard and controller.

### 0.8.3
- New: bigger Config page (two panels, larger controls).
- New: **How do I get a key?** button for the Nexus key, and **Paste key**.
- New: clearer Nexus 401 error on the results screen.
- Changed: red **Close All Menus** button now sits on the title line with its hint.
- Changed: bigger page selector and No Source tab, new mod description cards.
- Fixed: Up / Down on the Config buttons no longer jumps to a toggle on the left.

### 0.8.2
- New: search on Mod Toggles, Backups and Fork Finder (keyboard **S**, controller **R3**, hold to clear).
- New: Fork Finder sort (**A-Z** / **Recent**).
- New: crash recovery screen for crashes before the main menu.
- Changed: bigger, roomier Mod Toggles, Backups and Fork Finder tabs.
- Fixed: Crash Detected question waits for the main menu, and re-asks after **Not now**.

### 0.8.1
- New: a startup crash now asks what to do (**put them all back**, **Choose mods...**, **Not now**) instead of changing things by itself.
- New: `Undo last update.bat` lets you choose which mods to put back.
- Fixed: pins made by `Undo last update.bat` were lost on the next start.
- Works with **Auto-check at startup** off.

### 0.8.0
- New: Fork Finder finds the whole family (Original, Parent, Parent fork, Fork-fork), newest first and clearly labelled.
- New: **Translations: Hidden / Shown** button.
- New: **Page** and **Open GitHub / Nexus page** buttons for your current copy.
- New: Lovely requirement fixer for forks that ask for a Lovely version that does not exist.
- Changed: switching returns you to the Fork Finder list.

### 0.7.9
- New: **Hold B** (about 0.7 s) closes all menus. A quick tap is Back.
- Fixed: your settings (Nexus key, GitHub token, `config.lua`, lists) survive updates of the updater itself.
- Changed: Mod Toggles and Backups layout cleanups, D-pad / stick moves along a row.

### 0.7.8
- New: **Close All Menus** on every screen, **Save list / Restore list** on Mod Toggles.
- New: Backups hover summary, Fork Finder **Open fork page** button.
- Changed: fixed-size lists so nothing overlaps or jumps.
- Fixed: crash on the "Check for updates now" result screen.
