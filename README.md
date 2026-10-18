# Balatro-Mod-Updater
Updates (and makes backups of) any Balatro mod and the frameworks (Steamodded and Lovely Injector).

It notices changes to a mod you installed from its Git page, its GitHub Releases, or its Nexus Mods page. It also:
- backs up every mod and framework before updating it
- lets you restart now or later after updates
- has in-game settings for your Nexus API key, auto-checking at startup, and turning update checks off for single mods
- has per-mod "Check" buttons in the Mod Toggles tab

Auto-checking at startup is off by default. Turn it on in the mod's config tab.

## What's new in 0.8.3
- **Bigger Config page.** The settings now fill the whole window: two panels with larger toggles, text and buttons, and room for the controller button hints.
- **Easier Nexus key.** The Config page has a **How do I get a key?** button. It shows the steps and opens your Nexus account's API tab in the browser, and **Paste key** saves it. (Nexus only offers one-click sign-in to apps it has registered itself, so the key is still copied by hand.)
- **Config page controller fix.** Up and Down on the right-hand buttons no longer jump to a toggle on the left.
- **Close All Menus on the title line.** On every tab the red button now sits next to the page title with its "Hold B or press Esc" hint beside it, instead of in the corner.
- **Bigger page selector** on every list tab, matching the size of the search box and Clear button.
- **Bigger No Source tab**, sized like the other tabs.
- **Updated mod description.** The Mod Updater page in Steamodded now shows four short cards (updates, search and sort, Fork Finder, crash protection) instead of a block of text.

## What's new in 0.8.2
- **Search on the Mod Toggles, Backups and Fork Finder tabs**, like in Balatro Mod Search and Sort. Type in the box next to the page selector and the list narrows while you type. Every word has to match the mod's name or folder name, in any order. **Clear** empties the box, and **Found x of y** shows how many match.
  - Keyboard: press **S** to jump into the box and hold **S** to clear it. Controller: press **R3** (click the right stick), hold it to clear.
  - On Mod Toggles, **All on / All off** change only the mods your search found while a search is active.
  - The search is kept while you move between tabs and sub-screens. It empties when you leave the Mods menu.
  - **Clear** empties the search right where you are: only the list changes, the menu does not reload.
- **Bigger, roomier Mod Toggles, Backups and Fork Finder tabs**: larger text and buttons that use the whole window, with room for the controller button hints.
- **Fork Finder can be sorted** like the other tabs: **A-Z**, or **Recent** (the mods whose newest fork was updated most recently first). Its search also matches the GitHub repository name.
- **Crash recovery screen for crashes before the main menu.** If Balatro crashes while it is still starting, right after the updater updated some mods, you get a recovery screen instead of only the crash report. It offers **Put them all back and restart**, **Choose which mods to put back...**, and **Show the crash report** (nothing changes). It works with mouse, keyboard (arrows, Enter, Esc) and controller (D-pad or stick, A, B). Crashes after the main menu still get the normal crash report.
- **Crash Detected question fixes:**
  - On a controller, the cursor now starts on the question instead of the main menu behind it.
  - The question always waits for the main menu. It no longer gets lost when the update check finishes while the game is still loading.
  - After **Not now**, you are reliably asked again the next time the game starts.

## What's new in 0.8.1
- **A startup crash now asks you what to do instead of changing things by itself.** If Balatro did not reach the main menu right after the updater changed some mods, the next time the game gets to the main menu you see **Crash Detected** with the list of mods that were updated (version and time). Pick one:
  - **Yes, put them all back**: every one of those mods goes back to the version you had before and is pinned. A window then lists what was put back, with **Restart now**.
  - **Choose mods...**: one check box per mod, with **Revert selected**, **Revert all** and **Keep all** (plus **Tick all** / **Untick all**). Handy for finding the one that breaks the game: put half back, restart, see.
  - **Not now**: nothing changes. You are asked again the next time you start the game, or press **Startup crash: review N mod(s)** in the Mod Updater settings.
- Mods you keep stay suspects until the game has started fine once: if it crashes again, you are asked again, and `Undo last update.bat` can still undo them.
- Works with mouse, keyboard (**Esc** = Not now) and controller (D-pad and A, **B** = Not now / Back, LB / RB turn the picker's pages).
- **Works with "Auto-check at startup" off, too.** The crash is noticed by the game itself when it starts, not by the update check.
- **`Undo last update.bat` lets you choose too.** Press Enter to put everything back, type numbers (for example `1,3`) for only some, or `K` to keep everything.
- **Fixed:** pins made by `Undo last update.bat` were lost the next time the game started, so the mods could update to the broken version again. They are kept now, and the main menu tells you what was put back.
- While you have not answered, those mods are not updated again.

## What's new in 0.8.0
- **Switching goes back to the Fork Finder.** After you press **Switch to Fork** (or **Switch to Original / Parent**) you land on the Fork Finder list again instead of the main menu.
- **Fork Finder finds the whole family now.** For a mod that is itself a fork it checks (1) the **Original** project, (2) the **Parent** it was forked from (when that is a different repo), (3) other forks of the parent/original (**Parent fork**) and (4) forks of *your own copy* (**Fork-fork**). Everything is compared against the copy you have installed, so "+N commits" means "N commits you don't have". Example: Redux Arcanum now finds `RakibRyan/Redux-Arcanum`, a fork of the fork you have installed.
- **Newest first, clearly labelled.** Each mod's list is sorted by last update with the newest on top, and every card says what it is: ORIGINAL, PARENT, PARENT FORK, FORK-FORK or FORK. The mod list shows the counts (for example "Original + 2 parent forks + 1 fork-fork").
- **Hide translations.** New **Translations: Hidden / Shown** button. Forks that are only or mostly translations (Espanol / ESP / language files / "translation" commits) are left out while it is on (on by default; the status line says how many are hidden). Scan again to improve detection on old scan data.
- **Open the page of what you have now.** Every mod row has a **Page** button, and the fork screen has **Open GitHub page** (and **Open Nexus page** when the mod has one) for your current copy, so you can read about it before switching.
- **Lovely requirement fixer.** Some forks ask for a Lovely version that doesn't exist (Balatro-History's fork wants `Lovely (>=0.15)` while the newest Lovely is 0.10.0), so Steamodded refuses to load them ("Missing Dependencies") and blacklists them. For mods switched to a fork, the updater now lowers a requirement that is higher than any real Lovely to the Lovely you have, after a switch and after every update run. Restart the game to apply.

## What's new in 0.7.9
- **Hold B now works.** A quick tap of B is still "Back" (it happens when you let go); holding B for about 0.7 seconds closes all menus. Regular B presses keep working afterwards. The hold is timed every frame straight from the gamepad, so it works even when another mod (like Better Mouse and Gamepad) handles the controller, and it no longer fails when a menu is rebuilding. Tapping B on a mod's Backups or Fork list screen now goes Back (it did nothing before).
- **Your settings survive updates.** When the updater updates itself (release or git), your Nexus API key, GitHub token, `config.lua` settings, saved lists and changelogs are kept instead of being replaced by the repo's blank defaults.
- **Mod Toggles:** the mod name is on the left, the on/off box and **Check** are together on the far right, and the status text sits in the gap between. Rows no longer overlap the buttons above or the "Saved on/off list" line below; the page selector sits a little lower.
- **Backups:** the list is lowered away from the Sort button, and the space above and below the page selector is equal.
- **Controller:** LB / RB no longer switch tabs on screens without pages (Config); only LT / RT switch tabs. D-pad / left-stick left and right now move to the next button in the same row (e.g. Paste from clipboard -> Clear).

## What's new in 0.7.8
- **Menus always fit.** Every list is a fixed size, so nothing runs out of its box, overlaps the tab buttons, or jumps around when you change page.
- **Close All Menus** (red button on every screen). On a controller **hold B** for about a second; on a keyboard press **Esc**. Hold-B works in every menu in the game, not only this mod's.
- **Controller:** LT / RT switch tabs, LB / RB switch pages, and D-pad / left-stick up and down walk through every row in order.
- **Mod Toggles:** **Save list** keeps the current on/off list, **Restore list** puts it back. The first time you press **All on** / **All off** the list is saved automatically (unless you saved one yourself).
- **Backups:** wider rows with bigger version / date text. Hover a row (or focus its **Backups** button) to see a short summary of the newest changes. The notes live in `changelogs.json` and are rewritten after every update and every restore.
- **Fork Finder:** shows only forks newer than your installed copy by default (button switches to all forks). Each fork has an **Open fork page** button (opens GitHub in your browser) and a hover summary of what changed.
- Fixed a crash on the "Check for updates now" result screen (`on_full_update_done` was used before it was defined).


## How each mod is updated
1. **The mod folder has an `update.json` with `"provider": "github"` or `"nexus"`.** That source is used, even if the folder is also a git clone.
2. **The mod folder is a git clone.** It gets `git pull`. An `update.json` with `"branch": "stable"` makes it switch to and follow that branch.
3. **Neither.** The mod is never checked. It's listed under `untracked_mods` in `last_run.json` so you know.

### GitHub (`update.json`)
```json
{ "provider": "github", "repo": "Owner/Repo", "track": "auto" }
```
- `track`:
  - `auto` (default): use releases if the repo has any. Otherwise follow the newest commit on the default branch.
  - `release`: releases only.
  - `branch`: always follow the newest commit. Add `"branch": "name"` to pick the branch.
- `include_prereleases`: `true` also accepts pre-releases.
- `asset_regex`: picks the release file. If no file matches, the release's source-code zip is used.
- `strip_single_top_folder`: `true` (default) unpacks a zip that has a single top folder straight into the mod folder.

### Nexus (`update.json`)
```json
{ "provider": "nexus", "mod_id": 12345 }
```
- Only MAIN files are used, and the newest upload wins. Optional and old files are ignored. Use `file_name_regex` to pick one file when a mod has several.
- Nexus only allows API downloads for **Premium** accounts. On a free account, the updater shows "update available" with a link instead.

### Git
- Leftover merge conflicts (`<<<<<<<` markers) are repaired automatically.
- If your local edits clash with an update, the update still goes in. Your edits are saved in `git stash list`.
- `git_reset_on_diverge: true` in `autoupdater_config.json` resets mods whose author rewrote history (a backup is made first).

## Steamodded & Lovely
- Steamodded is checked by reading its `version.lua`.
- Lovely is checked by comparing `version.dll` with the latest release.
- Updates are staged and applied by `apply_pending.ps1` after Balatro closes. Click **Restart now** to apply them.
- Applying never replaces Steamodded with the same or an older version.
- Old staged updates are removed automatically once you're current.

## If the game won't start after an update
- **The game crashes while starting (before the main menu):** the Mod Updater's crash recovery screen appears instead of the crash report. It lists the mods it just updated. Choose **Put them all back and restart**, or **Choose which mods to put back...**, or **Show the crash report** to change nothing.
- **The game reaches the main menu (after one failed start):** you get the **Crash Detected** question described in "What's new in 0.8.1". Nothing is changed until you answer.
- **Neither screen shows up:** close Balatro and double-click **`Undo last update.bat`** in this folder. It lists the mods from the last update. Press **Enter** to put all of them back, type numbers like **1,3** for only some, or **K** to keep everything.
- Put-back mods are **pinned**: they are not updated again until you unpin them in the **Backups** tab.

## Optional settings (`autoupdater_config.json`)
- `github_token`: raises GitHub's limit from 60 to 5000 checks per hour. You don't need to edit this file: in the **Fork Finder** tab click **GitHub token** and follow the steps (free, read-only, takes about a minute).
- `report_untracked`: `false` stops listing untracked mods.

## Fork Finder and the GitHub token
Fork Finder looks for forks of your mods that have newer work. Each scan makes many GitHub requests, and GitHub only allows 60 per hour without a token, so a scan of a big mod list will stop early.

Fix (one time, about a minute):
1. Open the **Fork Finder** tab and click **GitHub token**, then **Open GitHub page**.
2. Name: `Balatro Mod Updater`. Expiration: `90 days`. Repository access: **Public repositories (read-only)**. Leave all permissions untouched.
3. Click **Generate token** and copy it (starts with `github_pat_`).
4. Back in the game click **Paste token**.

The token only reads public data. When it expires (after 90 days) the next scan shows a prompt: click **Yes, replace it** and you are taken straight to the token screen. After pasting, click **Scan Now** to scan right away.

## In-game settings tabs
- **Mod Toggles**: **All on / All off** buttons, a **Now / Next** sort pair (*Now: A-Z* shows the current sort, and the *Next: Recent* button switches to it), larger names and checkboxes, and a per-mod **Check** button. Rows line up in fixed columns so the controller d-pad / stick moves straight up and down.
- **Backups**: the same **Now / Next** sort pair (A-Z or Recent). Each mod shows the version in use and when it was last updated (pinned mods show "Pinned to backup <date>"). **Back** in a mod's backup list returns to this page.
- **No Source**: lists mods with no git clone or `update.json`. Copy the mod's GitHub or Nexus page link and click **Paste link** to create its `update.json`. This tab also has the switch for the "N mod(s) have no git/update.json" note on the results screen (on by default).
- **Close all** appears on every screen and leaves the mods menu completely.
