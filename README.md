# Balatro-Mod-Updater
Updates (and makes backups of) any Balatro mod and the frameworks (Steamodded and Lovely Injector).

It notices changes to a mod you installed from its Git page, its GitHub Releases, or its Nexus Mods page. It also:
- backs up every mod and framework before updating it
- lets you restart now or later after updates
- has in-game settings for your Nexus API key, auto-checking at startup, and turning update checks off for single mods
- has per-mod "Check" buttons in the Mod Toggles tab

Auto-checking at startup is off by default. Turn it on in the mod's config tab.

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
- **Automatic:** the next time the game reaches the main menu and the updater runs, it rolls back and pins the mods it last updated.
- **By hand:** close Balatro and double-click **`Undo last update.bat`** in this folder.

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
- **Mod Toggles**: **All on / All off** buttons, a sort button (A-Z or Recently updated), larger names and checkboxes, and a per-mod **Check** button. Rows line up in fixed columns so the controller d-pad / stick moves straight up and down.
- **Backups**: sort button (A-Z or Recently updated). Each mod shows the version in use and when it was last updated (pinned mods show "Pinned to backup <date>"). **Back** in a mod's backup list returns to this page.
- **No Source**: lists mods with no git clone or `update.json`. Copy the mod's GitHub or Nexus page link and click **Paste link** to create its `update.json`. This tab also has the switch for the "N mod(s) have no git/update.json" note on the results screen (on by default).
- **Close all** appears on every screen and leaves the mods menu completely.
