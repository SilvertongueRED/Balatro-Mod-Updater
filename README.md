# Balatro-Automatic-Mod-Updater
Automatically updates (and makes backups of) any balatro mod and frameworks (Steamodded and Lovely Injector) at game startup. 
It does this directly from noticing any changes to a mod you've downloaded from its Git page, its Git Release version, or its Nexus Mods page. Also creates backups of any mod/framework that's updated, gives an option to restart now or later after those updates, in-game configs for pasting your Nexus mods API key, and in-game configs for checking for updates after startup and individually toggling off mods for update checking. 

## Troubleshooting

### "Your local changes would be overwritten by merge" error

If you see this error when running `git pull` to update this mod:

```
error: Your local changes to the following files would be overwritten by merge:
        autoupdater_config.json
```

Run these commands in the mod folder to resolve it:

```
git stash
git pull
git stash pop
```

This is a one-time issue that occurs because `autoupdater_config.json` was previously tracked by git but has since been moved to `.gitignore`. Your local config will be preserved.
