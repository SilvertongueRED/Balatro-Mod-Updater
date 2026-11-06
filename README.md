# Balatro-Mod-Updater
Updates (and makes backups of) any Balatro mod and the frameworks (Steamodded and Lovely Injector).

It notices changes to a mod you installed from its Git page, its GitHub Releases, or its Nexus Mods page. It also:
- backs up every mod and framework before updating it
- lets you restart now or later after updates
- has in-game settings for your Nexus API key, auto-checking at startup, and turning update checks off for single mods
- has per-mod "Check" buttons in the Mod Toggles tab

Auto-checking at startup is off by default. Turn it on in the mod's config tab.

## What's new in 0.8.5
- **A pinned mod is tried again when its source has something newer.** If you put a mod back (Restore & Pin, or the crash screen), the Updater remembers which version you left. On every check it looks at the source: if there is a different, newer version it releases the pin and updates straight to the **latest** version, not just the next one. If the source still has nothing newer, the mod stays put. Steamodded and Lovely work the same way. Switch it off with **Retry pinned mods when newer** in Config (`pin_retry_newer` in `autoupdater_config.json`), and the pin then stays and the results just mention that a newer version exists.
- **Always the latest version.** Every mod type jumps straight to the newest version in one update, however many versions it is behind.
- **Saved copies of the game, and automatic protection from a Steam update.**
  - The first check saves a copy of the Balatro game files (about the size of the game) in `AMU_GameBackups`, next to your `Mods` folder. Every new Steam build is saved too. The newest 3 copies are kept (`game_backup_keep`).
  - When the Updater notices Steam updated the game, it saves the new version, stages a switch back to the saved copy of the version you were on, and **freezes mod and Steamodded/Lovely updates**, because a mod built for the new game could crash the old one. The results window offers **Restart now**; if you just quit, the switch happens when the game closes and the game is started through Steam. Turn the automatic switch off with **Auto-switch to saved game** in Config (`game_auto_switch`).
  - Updates stay frozen until you turn them on: **Mods > Mod Updater > Backups > Balatro game files > Use Steam's newest game + turn updates on**. That puts the newest saved game back, resumes updates, and the newest version stays saved so it is the one switched back to after the **next** Steam update.
  - **Allow mod updates on a saved copy** (same window) lets mods update even while an older game is installed. Use it only if you know what you are doing.
  - **`Use backed up game.bat`** does the same from outside the game: pick a saved copy by number, or **S** for Steam's version. Close Balatro first.
  - Turn the whole feature off with `"game_backup": false` in `autoupdater_config.json`.
- **Fork Finder: ignore a whole mod.** Every row starts with a small square: tick it and fork scans skip that mod completely (it leaves the list unless **Ignored: Shown** is on). Rows now use short text such as `Orig + 2 forks` with the full story on hover, and a mod you switched to a fork has both **Forks** and **Switch Back** buttons. The **Webpage** button on *Balatro game files* opens the Balatro update history on SteamDB.
- **Fork Finder: Ignore scans.** Each fork now has an **Ignore scans** checkbox next to **Open fork page**. Ignored forks are not checked by scans; they stay listed (shown as IGNORED) so you can un-ignore them, and the **Ignored: Hidden/Shown** button above the list hides or shows them. **Recent** sort orders mods by the newest listed fork's last push date, and shows that date on each row.
- **A restart window after every change that needs one.** Putting a mod back (Restore & Pin), switching a mod to a fork and switching back to the original now open the same **Restart now / Later** window the updates use (it only appears when the change worked). Steamodded, Lovely and the game files already did.
- **Unpin checks for a newer version at once.** Unpin on a mod (Backups tab) now checks that one mod straight away. If its source has a newer version it is updated and the results window opens with **Restart now / Later**. If it is already the newest, the status line says so and no restart is needed. While a saved game copy is installed the status line says updates are paused. Steamodded and Lovely still update on the next full check.
- **Pins and toggles are saved at once.** Steamodded only saved this mod's settings when you left the Mods menu, so a pin made right before **Restart now** could be lost (the mod then showed no PINNED badge after the restart). Every pin, unpin, toggle and fork switch now saves straight away, and **Restart now** saves first.
- **Remembered sorting.** The sort on Mod Toggles, Backups and Fork Finder (and the Fork Finder list filters) is saved in `ui_state.json` the moment you change it.
- **Show filters.** Mod Toggles has a **Show:** pill with a **Next:** button next to it, like the sort control (All, ON = mods with updates on, OFF = mods with updates off). Backups has the same for **All / Pinned**. They work together with the search box, and **All on / All off** only change the mods being shown. The chosen filter is remembered, also after a restart (the search box still starts empty).
- **First and last page.** Every list has a **<<** and a **>>** button next to the page selector. On a controller, **hold LB** for about half a second to jump to the first page and **hold RB** to jump to the last (on other pads the matching shoulder button); a quick tap of LB / RB still turns one page. With a controller in use the two buttons show a small "hold" label and the LB / RB glyph.
- **Green and red names on Backups.** Balatro game files, Lovely Injector and Steamodded are green while they are on the newest version and red while a saved older copy is in use.
- **The restart helper runs hidden.** It used to leave a PowerShell window open while the game restarted (Windows 11 ignores `-WindowStyle Hidden` for tasks). It now starts through a tiny script (`amu_restart_hidden.vbs` in the Balatro save folder) with no window.
- New test files: `Test pins and latest.bat`, `Test game backup.bat` and `Test fork ignore.bat` (both run in a throw-away folder in your temp folder and never touch your real Mods or game folders).

## What's new in 0.8.4
- **Hold S clears the search, even while you are typing.** On Mod Toggles, Backups and Fork Finder, holding **S** on the keyboard for about half a second now empties the search box. Before, it only worked when the cursor was outside the box. A quick tap of S still jumps into the box, and holding **R3** on a controller still clears it.
- **No more sideways jump after leaving the search box with a controller.** Pressing **B** (or Enter, or Esc) in the search box could push the whole tab to the right. The tab is now put back.
- **No more frozen keyboard and controller.** If the controller's on-screen keyboard was left behind after the search box closed, the keyboard and controller stopped responding while the mouse still worked. A leftover keyboard is now closed automatically.

## What's new in 0.8.3
- **Bigger Config page.** The settings now fill the whole window: two panels with larger toggles, text and buttons, and room for the controller button hints.
- **Easier Nexus key.** The Config page has a **How do I get a key?** button. It shows the steps and opens your Nexus account's API tab in the browser, and **Paste key** saves it. (Nexus only offers one-click sign-in to apps it has registered itself, so the key is still copied by hand.)
- **Config page controller fix.** Up and Down on the right-hand buttons no longer jump to a toggle on the left.
- **Clearer Nexus errors.** If Nexus rejects your API key (error 401), the results screen now says so and points to Config > How do I get a key?
- **A little more room under each tab title**, so it no longer touches the buttons below it.
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
- Put-back mods are **pinned**: they are not updated again until you unpin them in the **Backups** tab, or until their source has a different (newer) version and **Retry pinned mods when newer** is on.
- **A Steam update of Balatro broke your mods:** the Updater switches back to the saved copy of the old game by itself and freezes updates (see 0.8.5). If you need to do it by hand, close Balatro and double-click **`Use backed up game.bat`**.

## Optional settings (`autoupdater_config.json`)
- `github_token`: raises GitHub's limit from 60 to 5000 checks per hour. You don't need to edit this file: in the **Fork Finder** tab click **GitHub token** and follow the steps (free, read-only, takes about a minute).
- `report_untracked`: `false` stops listing untracked mods.
- `game_backup` (default `true`), `game_backup_keep` (default `3`), `game_auto_switch` (default `true`), `allow_updates_on_backup_game` (default `false`), `pin_retry_newer` (default `true`): see 0.8.5.

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
