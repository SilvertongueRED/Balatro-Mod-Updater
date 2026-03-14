return {
  auto_run = true,

  update_git = true,
  update_updatejson = true,

  -- UI
  show_loading_overlay = true,
  prompt_restart = true,
  prompt_on_errors = true,

  -- How long (seconds) the in-game UI waits for autoupdate.ps1 before showing a timeout warning
  -- Increase this if you have lots of repos or a slow network.
  ui_timeout_seconds = 300,

  -- Restart helper
  auto_relaunch_via_steam = true,
  steam_appid = "2379780",

  -- Ignore these folders when scanning mods (base list, merged with in-game toggles)
  -- NOTE: "smods" is skipped for MOD-level updates only. Steamodded framework updates
  -- use their own separate path and are NOT affected by this list.
  skip_folders = { "smods", "_Balatro-Automatic-Mod-Updater_Backups" },

  make_backups = true,

  -- Loading indicator placement (Balatro UI units)
  loading_align = "bm",
  loading_offset = { x = 0, y = 0 },

  -- Framework staging/apply
  framework_pending_file = "pending_apply.json",
  framework_apply_script = "apply_pending.ps1",
  framework_apply_on_launch = true,

  -- In-game config: per-mod update toggles
  -- Keys are folder names, values are booleans (true = update enabled)
  mod_update_enabled = {},

  -- Per-mod version pinning: when a mod is reverted to a backup it is frozen here.
  -- Keys are folder names; values are { pinned=true, backup_file="name.zip", pinned_at="ISO" }.
  mod_pinned = {},

  -- General settings (mirrored to autoupdater_config.json for the PS1 script)
  cfg_update_git = true,
  cfg_update_updatejson = true,
  cfg_make_backups = true,
  cfg_update_frameworks = true,
  cfg_update_steamodded = true,
  cfg_update_lovely = true,

  -- Nexus API key (stored here so SMODS persists it; written to autoupdater_config.json)
  nexus_api_key = "",
}
