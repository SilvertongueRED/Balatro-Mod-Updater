-- Mod Updater (Steamodded) v0.8.0
-- In-game config with two tabs: Settings (general + Nexus key + check now) and Mod Toggles (paginated).
-- Uses Steamodded's DynamicUIManager for proper pagination.
-- Git pull mode: rebase (default and recommended).

local mod = SMODS.current_mod
local config = mod and mod.config or {}

-- modicon info
SMODS.Atlas {
  key = 'modicon',
  path = 'modicon.png',
  px = 64,
  py = 64,
  inject = function(self)
    self.full_path = (self.mod and self.mod.path or SMODS.path) .. self.path
    local file_data = assert(SMODS.NFS.newFileData(self.full_path),
      ('Failed to collect file data for Atlas %s'):format(self.key))
    self.image_data = assert(love.image.newImageData(file_data),
      ('Failed to initialize image data for Atlas %s'):format(self.key))
    self.image = love.graphics.newImage(self.image_data,
      { mipmaps = true, dpiscale = 1 })
    G[self.atlas_table][self.key_noloc or self.key] = self
  end,
}

-- Derive the actual folder name of this mod dynamically so it works
-- regardless of what the user names the mod folder (e.g. after cloning the repo).
local mod_folder_name = "Balatro-Mod-Updater"
if mod and mod.path then
  local name = mod.path:match("([^/\\]+)[/\\]*$")
  if name and name ~= "" then
    mod_folder_name = name
  end
end

local function is_windows()
  return love and love.system and love.system.getOS and love.system.getOS() == "Windows"
end

local function winpath(p) return (p:gsub("/", "\\")) end
local function safe_quote(s) return '"' .. tostring(s):gsub('"', '""') .. '"' end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function strip_bom(s)
  if not s or #s < 3 then return s end
  local b1, b2, b3 = s:byte(1,3)
  if b1 == 0xEF and b2 == 0xBB and b3 == 0xBF then
    return s:sub(4)
  end
  return s
end

local function join_path(a, b)
  if not a or a == "" then return b end
  local last = a:sub(-1)
  if last == "/" or last == "\\" then return a .. b end
  return a .. "/" .. b
end

local function RGBA(r,g,b,a) return {r,g,b,a} end

-- SMODS.current_mod is only set while mods are LOADING. At runtime (button clicks) it is nil,
-- so always resolve the mod folder through this helper instead.
local function amu_mod_path()
  if mod and mod.path and mod.path ~= "" then return mod.path end
  if SMODS and SMODS.current_mod and SMODS.current_mod.path then return SMODS.current_mod.path end
  return join_path(join_path(love.filesystem.getSaveDirectory(), "Mods"), mod_folder_name)
end

-- Forward declaration; assigned after run_fork_scan is defined.
local amu_run_fork_scan

---------------------------------------------------------------------------
-- Launch tracking for crash rollback (fixed in 0.7.0)
-- _launch_attempt : written now, while the game is still loading mods
-- _launch_sentinel: written once the main menu is reached
-- If a previous attempt exists without a sentinel, that launch never reached the
-- menu (crash/freeze), so _crash_flag tells autoupdate.ps1 to roll back the
-- mods it updated last time.
---------------------------------------------------------------------------
do
  local mp = mod and mod.path
  if mp and mp ~= "" then
    local function touch(name)
      pcall(function()
        local f = io.open(join_path(mp, name), "wb")
        if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ")); f:close() end
      end)
    end
    if file_exists(join_path(mp, "_recently_updated.json"))
      and file_exists(join_path(mp, "_launch_attempt"))
      and not file_exists(join_path(mp, "_launch_sentinel")) then
      touch("_crash_flag")
    end
    touch("_launch_attempt")

    local wrote = false
    local orig_main_menu = Game and Game.main_menu
    if orig_main_menu then
      function Game:main_menu(...)
        if not wrote then wrote = true; touch("_launch_sentinel") end
        return orig_main_menu(self, ...)
      end
    end
  end
end

-- JSON decoder bundled with mod
local json = nil
do
  local ok, chunk = pcall(function()
    local p = (SMODS.current_mod and SMODS.current_mod.path) or ""
    return assert(loadfile(p .. "/json.lua"))
  end)
  if ok and chunk then
    local ok2, j = pcall(chunk)
    if ok2 then json = j end
  end
end

local function decode_json(str)
  str = strip_bom(str)
  if json and json.decode then
    local ok, out = pcall(json.decode, str)
    if ok then return out end
  end
  return nil
end

-- Minimal JSON encoder for writing config files the PS1 script can read
local function encode_json_value(v, indent, depth)
  indent = indent or ""
  depth = depth or 0
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then return tostring(v)
  elseif t == "string" then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
  elseif t == "table" then
    local is_array = true
    local max_i = 0
    for k, _ in pairs(v) do
      if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
        is_array = false
        break
      end
      if k > max_i then max_i = k end
    end
    if is_array and max_i == #v then
      if #v == 0 then return "[]" end
      local parts = {}
      local inner = indent .. "  "
      for i = 1, #v do
        parts[i] = inner .. encode_json_value(v[i], inner, depth + 1)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys+1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      if #keys == 0 then return "{}" end
      local parts = {}
      local inner = indent .. "  "
      for _, k in ipairs(keys) do
        parts[#parts+1] = inner .. encode_json_value(tostring(k), inner, depth+1) .. ": " .. encode_json_value(v[k], inner, depth+1)
      end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
  end
  return '"[unserializable]"'
end

local function encode_json(v)
  return encode_json_value(v, "", 0)
end

local function show_msg(title, msg, buttons, mtype)
  if love and love.window and love.window.showMessageBox then
    love.window.showMessageBox(title, msg, buttons or {"OK"}, mtype or "info")
  end
end

---------------------------------------------------------------------------
-- TEXT FITTING: measure text with the game's own font so nothing ever runs out of a box
---------------------------------------------------------------------------

local function amu_text_w(text, scale)
  text = tostring(text or "")
  local ok, w = pcall(function()
    local f = G.LANG.font
    return f.FONT:getWidth(text) * (f.squish or 1) * scale * G.TILESCALE * f.FONTSCALE / (G.TILESIZE * G.TILESCALE)
  end)
  if ok and type(w) == "number" then return w end
  return #text * scale * 0.5
end

-- Remove the last character (UTF-8 safe).
local function amu_cut_last_char(s)
  s = s:sub(1, -2)
  while #s > 0 do
    local b = s:byte(-1)
    if b >= 0x80 and b < 0xC0 then
      s = s:sub(1, -2)
    elseif b >= 0xC0 then
      s = s:sub(1, -2)
      break
    else
      break
    end
  end
  return s
end

-- Shorten `text` with ".." until it is no wider than `maxw` (in UI units) at `scale`.
local function amu_fit(text, scale, maxw)
  text = tostring(text or "")
  text = text:gsub("[\r\n\t]+", " ")
  if amu_text_w(text, scale) <= maxw then return text end
  local s = text
  while #s > 0 do
    s = amu_cut_last_char(s)
    local trimmed = s:gsub("%s+$", "")
    if amu_text_w(trimmed .. "..", scale) <= maxw then return trimmed .. ".." end
  end
  return ".."
end

-- A {text=...} table whose text is always clamped to fit a box of width `maxw`.
local function amu_status_tbl(scale, maxw, initial)
  local raw = { text = "" }
  local t = setmetatable({}, {
    __index = function(_, k) return raw[k] end,
    __newindex = function(_, k, v)
      if k == "text" then raw.text = amu_fit(v or "", scale, maxw) else raw[k] = v end
    end,
  })
  t.text = initial or ""
  return t
end

---------------------------------------------------------------------------
-- changelogs.json reader (cached; reloads itself when autoupdate.ps1 rewrites the file)
---------------------------------------------------------------------------
local amu_cl_cache = { stamp = nil, data = nil }

local function amu_changelogs()
  local rel = "Mods/" .. mod_folder_name .. "/changelogs.json"
  local info = love.filesystem.getInfo(rel)
  local stamp = info and ((info.modtime or 0) .. ":" .. (info.size or 0)) or "none"
  if amu_cl_cache.data and amu_cl_cache.stamp == stamp then return amu_cl_cache.data end
  local data
  local s = read_all(join_path(amu_mod_path(), "changelogs.json"))
  if s then data = decode_json(s) end
  amu_cl_cache.stamp = stamp
  amu_cl_cache.data = (type(data) == "table" and type(data.mods) == "table") and data.mods or {}
  return amu_cl_cache.data
end

G.UIDEF = G.UIDEF or {}
G.FUNCS = G.FUNCS or {}

---------------------------------------------------------------------------
-- SCAN MODS DIRECTORY
---------------------------------------------------------------------------

local always_skip = {
  ["smods"] = true,
  [mod_folder_name] = true,
  ["_Balatro-Mod-Updater_Backups"] = true,
}

-- Subset of always_skip that should appear in skip_folders in the generated config.
-- The updater's own folder is excluded so it can self-update via git/GitHub releases.
local config_always_skip = {
  ["smods"] = true,
  ["_Balatro-Mod-Updater_Backups"] = true,
}

-- Legacy folder names from older versions that should never appear in the
-- generated autoupdater_config.json skip_folders list.  They may still be
-- present in SMODS-persisted config.skip_folders from a previous release.
local legacy_skip_deny = {
  ["AutoModUpdater"] = true,
  ["_AutoModUpdater_Backups"] = true,
  ["_Balatro-Automatic-Mod-Updater_Backups"] = true,
}

local function scan_mods_and_init_config()
  if not config.mod_update_enabled then
    config.mod_update_enabled = {}
  end
  if not config.mod_pinned then
    config.mod_pinned = {}
  end
  if not config.mod_fork_source then
    config.mod_fork_source = {}
  end

  local items = love.filesystem.getDirectoryItems("Mods")
  if items then
    for _, name in ipairs(items) do
      local info = love.filesystem.getInfo("Mods/" .. name)
      if info and info.type == "directory" then
        if not always_skip[name] and name:sub(1,1) ~= "_" then
          if config.mod_update_enabled[name] == nil then
            config.mod_update_enabled[name] = true
          end
        end
      end
    end
  end

  for name, _ in pairs(config.mod_update_enabled) do
    local info = love.filesystem.getInfo("Mods/" .. name)
    if (not info or info.type ~= "directory") or always_skip[name] then
      config.mod_update_enabled[name] = nil
    end
  end

  -- Remove pin entries for mods that no longer exist
  for name, _ in pairs(config.mod_pinned) do
    local info = love.filesystem.getInfo("Mods/" .. name)
    if (not info or info.type ~= "directory") or always_skip[name] then
      config.mod_pinned[name] = nil
    end
  end

  -- Enforce consistency: pinned mods must have updates disabled
  for name, pin_info in pairs(config.mod_pinned) do
    if type(pin_info) == "table" and pin_info.pinned then
      config.mod_update_enabled[name] = false
    end
  end
end

pcall(scan_mods_and_init_config)

---------------------------------------------------------------------------
-- WRITE SKIP LIST + MERGED CONFIG for the PowerShell script
---------------------------------------------------------------------------

local amu_secrets_adopted = false   -- one-time (per game session): see below
local function write_ps1_config_overlay()
  local mod_path = amu_mod_path()
  if mod_path == "" then return end

  local skip = {}
  for name, _ in pairs(config_always_skip) do
    skip[#skip+1] = name
  end
  if config.mod_update_enabled then
    for name, enabled in pairs(config.mod_update_enabled) do
      if not enabled then
        skip[#skip+1] = name
      end
    end
  end
  if config.skip_folders then
    local set = {}
    for _, n in ipairs(skip) do set[n] = true end
    for _, n in ipairs(config.skip_folders) do
      if not set[n] and not legacy_skip_deny[n] and n ~= mod_folder_name then
        skip[#skip+1] = n
      end
    end
  end
  table.sort(skip)

  -- Always use rebase as the git pull mode
  local pinned_mods = {}
  if config.mod_pinned then
    for name, info in pairs(config.mod_pinned) do
      if type(info) == "table" and info.pinned then
        pinned_mods[name] = {
          pinned = true,
          backup_file = info.backup_file or "",
          pinned_at = info.pinned_at or "",
        }
      end
    end
  end

  local merged = {
    update_git = config.cfg_update_git ~= false,
    update_updatejson = config.cfg_update_updatejson ~= false,
    make_backups = config.cfg_make_backups ~= false,
    skip_folders = skip,
    nexus_api_key = config.nexus_api_key or "",
    nexus_game_domain = "balatro",
    git_pull_mode = "rebase",
    update_frameworks = (config.cfg_update_steamodded == true) or (config.cfg_update_lovely == true),
    update_steamodded = config.cfg_update_steamodded == true,
    update_lovely = config.cfg_update_lovely == true,
    pinned_mods = pinned_mods,
    balatro_game_dir = "",
    check_forks = config.check_forks == true,
    mod_fork_source = config.mod_fork_source or {},
    github_token = config.github_token or "",
  }

  -- Keep advanced settings that only exist in autoupdater_config.json (no in-game toggle),
  -- so hand-edited values like github_token aren't wiped every run.
  do
    local existing = decode_json(read_all(join_path(mod_path, "autoupdater_config.json")) or "")
    if type(existing) == "table" then
      for _, k in ipairs({ "git_reset_on_diverge", "report_untracked" }) do
        if existing[k] ~= nil then merged[k] = existing[k] end
      end
      -- GitHub token: the in-game setting wins. If it was never set in-game, adopt a token
      -- that was typed into autoupdater_config.json by hand (one-time migration).
      if config.github_token == nil and type(existing.github_token) == "string" and existing.github_token ~= "" then
        config.github_token = existing.github_token
        merged.github_token = existing.github_token
      end
      -- Same for the Nexus API key: if config.lua came back blank (e.g. it was replaced by the repo's default
      -- copy during an update) but the key is still saved in autoupdater_config.json, keep using it instead of
      -- overwriting it with a blank. Only done on the first run of a session, so clearing the key in-game still works.
      if not amu_secrets_adopted then
        amu_secrets_adopted = true
        if (config.nexus_api_key == nil or config.nexus_api_key == "")
           and type(existing.nexus_api_key) == "string" and existing.nexus_api_key ~= "" then
          config.nexus_api_key = existing.nexus_api_key
          merged.nexus_api_key = existing.nexus_api_key
        end
      end
    end
  end

  -- Auto-detect Balatro game directory from the running executable location
  if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
    local detected = love.filesystem.getSourceBaseDirectory()
    if detected and detected ~= "" then
      merged.balatro_game_dir = detected
    end
  end

  -- Preserve fields from the existing JSON that the user may have set manually
  local existing_path = join_path(mod_path, "autoupdater_config.json")
  local existing_data = read_all(existing_path)
  if existing_data then
    local existing = decode_json(existing_data)
    if existing then
      if existing.nexus_game_domain then merged.nexus_game_domain = existing.nexus_game_domain end
      if existing.balatro_game_dir and existing.balatro_game_dir ~= "" then merged.balatro_game_dir = existing.balatro_game_dir end
    end
  end

  pcall(function()
    local f = io.open(existing_path, "wb")
    if f then
      f:write(encode_json(merged))
      f:close()
    end
  end)
end

---------------------------------------------------------------------------
-- NEXUS API KEY helpers
---------------------------------------------------------------------------

local function mask_nexus_key(key)
  if not key or key == "" then return "(not set)" end
  if #key <= 6 then return string.rep("*", #key) end
  return key:sub(1, 4) .. string.rep("*", math.min(12, #key - 4))
end

local amu_nexus_display = { text = mask_nexus_key(config.nexus_api_key) }

---------------------------------------------------------------------------
-- GITHUB TOKEN helpers (used by Fork Finder; lifts GitHub's 60 requests/hour limit)
---------------------------------------------------------------------------

-- Opens GitHub's "new fine-grained token" page with the name and 90-day expiry filled in.
local AMU_GH_TOKEN_URL = "https://github.com/settings/personal-access-tokens/new"
  .. "?name=Balatro+Mod+Updater"
  .. "&description=Lets+Balatro+Mod+Updater+scan+mod+forks+%28read-only%2C+public+data%29"
  .. "&expires_in=90"

local function mask_gh_token(tok)
  if not tok or tok == "" then return "GitHub token: not set (limit 60 checks/hour)" end
  return "GitHub token: " .. tok:sub(1, 11) .. string.rep("*", 8) .. "  (set)"
end

local amu_gh_display = { text = mask_gh_token(config.github_token) }
local amu_gh_msg = { text = "" }

---------------------------------------------------------------------------
-- CHECK FOR UPDATES NOW (manual trigger)
---------------------------------------------------------------------------

local on_full_update_done  -- forward declaration (assigned further down)
local amu_check_status = amu_status_tbl(0.28, 4.6, "")
local amu_is_checking = false

local function run_manual_check()
  if amu_is_checking then return end
  if not is_windows() then
    amu_check_status.text = "Windows only"
    return
  end

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)

  pcall(write_ps1_config_overlay)

  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then
    amu_check_status.text = "Missing autoupdate.ps1!"
    return
  end

  if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
    amu_check_status.text = "No thread support"
    return
  end

  amu_is_checking = true
  amu_check_status.text = "Checking..."

  local channel = love.thread.getChannel("amu_manual_check")
  channel:clear()

  local cmd = table.concat({
    "powershell","-NoProfile","-ExecutionPolicy","Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
  }, " ")

  local thread_code = [[
    local cmd = ...
    local ok = pcall(function() os.execute(cmd) end)
    local ch = love.thread.getChannel("amu_manual_check")
    ch:push(ok and "done" or "error")
  ]]
  local t = love.thread.newThread(thread_code)
  t:start(cmd)

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    func = function()
      local msg = channel:pop()
      if msg then
        amu_is_checking = false
        local summary_path = join_path(mod_path, "last_run.json")
        local data = read_all(summary_path)
        local summary = data and decode_json(data) or nil
        if summary then
          local updated = summary.updated_mods or {}
          local errors = summary.errors or {}
          if #updated > 0 then
            amu_check_status.text = "Done! " .. #updated .. " mod(s) updated."
          elseif #errors > 0 then
            amu_check_status.text = "Done with " .. #errors .. " error(s)."
          else
            amu_check_status.text = "All mods up to date!"
          end
        else
          amu_check_status.text = msg == "done" and "Done!" or "Error running script."
        end
        on_full_update_done(mod_path)
        return true
      end
      return false
    end
  }))
end

-- Per-mod check status tracking
local amu_per_mod_status = {}
local amu_per_mod_checking = {}

local function run_single_mod_check(folder_name)
  if amu_per_mod_checking[folder_name] then return end
  if not is_windows() then
    amu_per_mod_status[folder_name] = "Windows only"
    return
  end

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)

  pcall(write_ps1_config_overlay)

  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then
    amu_per_mod_status[folder_name] = "Missing script!"
    return
  end

  if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
    amu_per_mod_status[folder_name] = "No thread support"
    return
  end

  amu_per_mod_checking[folder_name] = true
  amu_per_mod_status[folder_name] = "Checking..."

  local ch_name = "amu_single_check_" .. folder_name
  local channel = love.thread.getChannel(ch_name)
  channel:clear()

  local cmd = table.concat({
    "powershell","-NoProfile","-ExecutionPolicy","Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-TargetMod", safe_quote(folder_name),
  }, " ")

  local thread_code = string.format([[
    local cmd = ...
    local ok = pcall(function() os.execute(cmd) end)
    local ch = love.thread.getChannel(%q)
    ch:push(ok and "done" or "error")
  ]], ch_name)
  local t = love.thread.newThread(thread_code)
  t:start(cmd)

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    func = function()
      local msg = channel:pop()
      if msg then
        amu_per_mod_checking[folder_name] = nil
        local summary_path = join_path(mod_path, "last_run.json")
        local data = read_all(summary_path)
        local summary = data and decode_json(data) or nil
        if summary then
          local updated = summary.updated_mods or {}
          local errors = summary.errors or {}
          if #updated > 0 then
            amu_per_mod_status[folder_name] = "Updated!"
            show_prompt(summary)
          elseif #errors > 0 then
            amu_per_mod_status[folder_name] = "Error"
          else
            amu_per_mod_status[folder_name] = "Up to date"
          end
        else
          amu_per_mod_status[folder_name] = msg == "done" and "Done" or "Error"
        end
        return true
      end
      return false
    end
  }))
end

---------------------------------------------------------------------------
-- CONFIG TAB helpers
---------------------------------------------------------------------------

local MODS_PER_PAGE = 7
local AMU_CONFIG_PAGE = 1
-- Sort pill ("Now: ...") and button ("Next: ...") text, one pair per screen
local amu_sort_label = { toggles_now = "A-Z", toggles_next = "Next: Recent", backups_now = "A-Z", backups_next = "Next: Recent" }
local amu_nosrc_msg = amu_status_tbl(0.27, 9.4, "")
local AMU_NOSRC_PAGE = 1

-- Backup browser state (forward-declared; build_backup_mods_page defined after open_overlay)
local AMU_BACKUP_PAGE = 1
local amu_backup_status = amu_status_tbl(0.3, 11.6, "")
local amu_restore_in_progress = false
local build_backup_mods_page  -- forward declaration; assigned after close_overlay is defined

-- Fork Finder state (forward-declared; build_fork_mods_page defined after open_overlay)
local AMU_FORK_PAGE = 1
local amu_fork_status = amu_status_tbl(0.3, 9.8, "")
local amu_fork_scanning = false
local amu_fork_suggestions = nil
local load_fork_suggestions  -- forward declaration; assigned after open_overlay/close_overlay
local get_fork_mod_entries   -- forward declaration; assigned after open_overlay/close_overlay
local build_fork_mods_page   -- forward declaration; assigned after close_overlay is defined
-- Fixed list sizes: every page of a list is exactly this big, so tabs never grow, shrink or overflow.
local AMU_BK_PER, AMU_BK_ROW_H, AMU_BK_W, AMU_BK_H = 6, 0.72, 11.9, 4.32
local AMU_FORK_PER, AMU_FORK_ROW_H, AMU_FORK_W, AMU_FORK_H = 6, 0.5, 9.8, 3.24
local AMU_NS_PER, AMU_NS_W, AMU_NS_H = 7, 9.6, 3.9
local amu_fork_filter_label = { text = "" }
local amu_fork_filter_text    -- assigned with the Fork Finder code
local amu_fork_tr_label = { text = "" }
local amu_fork_tr_text        -- assigned with the Fork Finder code
local amu_fork_summary        -- assigned with the Fork Finder code
local amu_restore_folder = nil

---------------------------------------------------------------------------
-- Shared menu helpers: mod lookup, versions, update times, navigation buttons
---------------------------------------------------------------------------

local function find_smods_mod(folder_name)
  if SMODS and SMODS.Mods then
    local escaped = folder_name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    for _, m in pairs(SMODS.Mods) do
      if m.path and m.path:match("[/\\]" .. escaped .. "[/\\]?$") then return m end
    end
  end
  return nil
end

local function get_display_name(folder_name)
  local m = find_smods_mod(folder_name)
  local display = (m and (m.name or m.display_name)) or folder_name
  if #display > 32 then display = display:sub(1, 29) .. "..." end
  return display
end

-- Shorten a name so every row's columns line up (needed for controller up/down).
local function fit_name(s, max_chars)
  s = tostring(s or "")
  if #s <= max_chars then return s end
  return s:sub(1, max_chars - 2) .. ".."
end

local function parse_stamp(stamp)
  local y, mo, d, h, mi, sec = tostring(stamp):match("(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)(%d%d)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                   hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) })
end

local function fmt_date(t)
  if not t or t <= 0 then return nil end
  return os.date("%Y-%m-%d", t)
end

-- folder -> newest backup time (a backup is made right before every update)
local function build_last_update_map()
  local map = {}
  local items = love.filesystem.getDirectoryItems("Mods/_Balatro-Mod-Updater_Backups") or {}
  for _, name in ipairs(items) do
    local base, stamp = name:match("^(.+)%-(%d%d%d%d%d%d%d%d_%d%d%d%d%d%d)%.zip$")
    if base then
      local t = parse_stamp(stamp)
      if t and t > (map[base] or 0) then map[base] = t end
    end
  end
  return map
end

-- Last update time = newest of: latest backup, last time git moved HEAD (pull/checkout).
local function last_update_for(folder, map)
  local t = (map and map[folder]) or 0
  local gi = love.filesystem.getInfo("Mods/" .. folder .. "/.git/logs/HEAD")
  if gi and gi.modtime and gi.modtime > t then t = gi.modtime end
  return t
end

local function git_short_hash(folder)
  local base = "Mods/" .. folder .. "/.git/"
  local head = love.filesystem.read(base .. "HEAD")
  if not head then return nil end
  head = head:gsub("%s+$", "")
  local ref = head:match("^ref:%s*(.+)$")
  local hash
  if ref then
    local r = love.filesystem.read(base .. ref)
    if r then hash = r:match("^(%x+)") end
    if not hash then
      local packed = love.filesystem.read(base .. "packed-refs")
      if packed then
        for line in packed:gmatch("[^\r\n]+") do
          local h, name = line:match("^(%x+)%s+(.+)$")
          if h and name == ref then
            hash = h
            break
          end
        end
      end
    end
  else
    hash = head:match("^(%x+)")
  end
  return hash and hash:sub(1, 7) or nil
end

local function mod_version_line(folder)
  local m = find_smods_mod(folder)
  local parts = {}
  local ver = m and m.version and tostring(m.version) or ""
  if ver ~= "" and ver ~= "0.0.0" then
    parts[#parts + 1] = "v" .. (ver:gsub("^[vV]", ""))
  end
  local h = git_short_hash(folder)
  local pin = config.mod_pinned and config.mod_pinned[folder]
  if type(pin) == "table" and pin.pinned then
    local ci = amu_changelogs()[folder]
    if type(ci) == "table" and ci.restored and ci.head and ci.head ~= "" then h = tostring(ci.head):sub(1, 7) end
  end
  if h then parts[#parts + 1] = "#" .. h end
  if #parts == 0 then return "version unknown" end
  return table.concat(parts, " ")
end

-- mode: "az" (default) or "recent" (most recently updated first)
local function get_sorted_mod_entries(mode)
  local entries = {}
  local umap = (mode == "recent") and build_last_update_map() or nil
  if config.mod_update_enabled then
    for folder_name, _ in pairs(config.mod_update_enabled) do
      entries[#entries+1] = {
        folder = folder_name,
        display = get_display_name(folder_name),
        updated = umap and last_update_for(folder_name, umap) or 0,
      }
    end
  end
  table.sort(entries, function(a, b)
    if mode == "recent" and a.updated ~= b.updated then return a.updated > b.updated end
    local al, bl = a.display:lower(), b.display:lower()
    if al ~= bl then return al < bl end
    return a.folder < b.folder
  end)
  return entries
end

local function amu_sort_name(mode)
  return (mode == "recent") and "Recent" or "A-Z"
end

-- Fill in both labels for a screen ("toggles" / "backups"): what is active now, and what the button switches to.
local function amu_sort_set(which, mode)
  local nxt = (mode == "recent") and "az" or "recent"
  amu_sort_label[which .. "_now"] = amu_sort_name(mode)
  amu_sort_label[which .. "_next"] = "Next: " .. amu_sort_name(nxt)
end

---------------------------------------------------------------------------
-- NAVIGATION + CONTROLLER SUPPORT (shared by every Mod Updater screen)
--   * "Close All Menus": button, hold-B on a controller, Esc on a keyboard
--   * LT / RT (triggers) switch tabs, LB / RB (bumpers) switch pages
--   * D-pad / left-stick up & down walk through EVERY row, top to bottom
---------------------------------------------------------------------------

local AMU_HOLD_B_SECS = 0.7

-- Closes whatever menu is open (and saves mod settings first when we're in the Mods menu).
local function amu_close_everything()
  if G.ACTIVE_MOD_UI or (SMODS and SMODS.IN_MODS_TAB) then
    if G.FUNCS.exit_mods then pcall(G.FUNCS.exit_mods) end
  end
  if G.FUNCS.exit_overlay_menu then pcall(G.FUNCS.exit_overlay_menu) end
end

G.FUNCS.amu_close_all = function(e)
  amu_close_everything()
end

-- Re-open this mod's menu on the tab the player was last on (Backups, Fork Finder, ...).
G.FUNCS.amu_back_to_menu = function(e)
  local id = (mod and mod.id) or "modupdater"
  local f = G.FUNCS["openModUI_" .. id]
  local ok = false
  if f then ok = pcall(f, { config = {} }) end
  if not ok then amu_close_everything() end
end

-- Rebuild the whole tab (pager included) when it is on screen. Used when the NUMBER of rows changes.
local function amu_reopen_if_open(area_id)
  local om = G and G.OVERLAY_MENU
  if om and om.get_UIE_by_ID and om:get_UIE_by_ID(area_id) then G.FUNCS.amu_back_to_menu() end
end

-- Is one of OUR screens the open overlay? (cached for a moment: it walks the node tree)
local amu_open_cache = { om = nil, t = -10, v = false }
local function amu_screen_open()
  local om = G and G.OVERLAY_MENU
  if not om or not om.get_UIE_by_ID then return false end
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  if amu_open_cache.om == om and (now - amu_open_cache.t) < 0.25 then return amu_open_cache.v end
  local ok, found = pcall(function()
    return om:get_UIE_by_ID('amu_marker') or om:get_UIE_by_ID('tab_but_Mod Toggles')
  end)
  amu_open_cache.om, amu_open_cache.t, amu_open_cache.v = om, now, (ok and found) and true or false
  return amu_open_cache.v
end

-- Switch the tab strip by dir (+1 / -1), wrapping around. Same logic the game uses for LB/RB.
local function amu_cycle_tab(dir)
  local om = G and G.OVERLAY_MENU
  local strip = om and om.get_UIE_by_ID and om:get_UIE_by_ID('tab_shoulders')
  if not strip then return false end
  local ok, done = pcall(function()
    local proto = strip.UIBox:get_group(nil, strip.children[1].children[1].config.group)
    local choices = {}
    for _, v in ipairs(proto) do
      if v.config.choice and v.config.button then choices[#choices + 1] = v end
    end
    for k, v in ipairs(choices) do
      if v.config.chosen then
        local nxt = k + dir
        if nxt < 1 then nxt = #choices elseif nxt > #choices then nxt = 1 end
        choices[nxt]:click()
        G.CONTROLLER:snap_to({ node = choices[nxt] })
        G.CONTROLLER:update_cursor()
        return true
      end
    end
    return false
  end)
  return ok and done and true or false
end

-- Up / down on a controller: go row by row (so no button is ever skipped), picking the
-- button in the next row that is closest sideways to where you are now.
local function amu_row_nav(ctrl, dir)
  local cur = ctrl.focused.target
  if not cur or not cur.T then return false end
  local cur_g = cur
  local cfa = cur.config and cur.config.focus_args
  if cfa and type(cfa.funnel_to) == "table" then cur_g = cfa.funnel_to end
  local cx, cy = cur_g.T.x + cur_g.T.w / 2, cur_g.T.y + cur_g.T.h / 2

  local items = {}
  for _, v in pairs(G.MOVEABLES) do
    v.states.focus.can = false
    v.states.focus.is = false
    if ctrl:is_node_focusable(v) then
      v.states.focus.can = true
      local g = v
      local fa = v.config and v.config.focus_args
      if fa and type(fa.funnel_to) == "table" then g = fa.funnel_to end
      items[#items + 1] = { node = v, x = g.T.x + g.T.w / 2, y = g.T.y + g.T.h / 2 }
    end
  end
  if #items < 2 then
    cur.states.focus.is = true
    return true
  end
  table.sort(items, function(a, b) return a.y < b.y end)

  -- group into rows (buttons whose centres are within 0.22 of each other sit in one row)
  local rows = {}
  for _, it in ipairs(items) do
    local last = rows[#rows]
    if last and (it.y - last.y0) < 0.22 then
      last[#last + 1] = it
    else
      rows[#rows + 1] = { it, y0 = it.y }
    end
  end

  -- which row are we in now?
  local cur_row, best = 1, math.huge
  for i, r in ipairs(rows) do
    local d = math.abs(r.y0 - cy)
    if d < best then best, cur_row = d, i end
  end

  if dir == "L" or dir == "R" then
    -- sideways: only to the next button in the SAME row (e.g. Paste -> Clear); nothing there = let the game decide
    local pick_h, pick_hd = nil, math.huge
    for _, it in ipairs(rows[cur_row]) do
      local dx = it.x - cx
      if (dir == "R" and dx > 0.05) or (dir == "L" and dx < -0.05) then
        if math.abs(dx) < pick_hd then pick_h, pick_hd = it, math.abs(dx) end
      end
    end
    if not pick_h then return false end
    ctrl.focused.prev_target = cur
    ctrl.focused.target = pick_h.node
    pick_h.node.states.focus.is = true
    if G.VIBRATION then G.VIBRATION = G.VIBRATION + 0.7 end
    return true
  end

  local target_row = cur_row + (dir == "D" and 1 or -1)
  if target_row < 1 or target_row > #rows then
    cur.states.focus.is = true      -- already at the top / bottom
    return true
  end

  local pick, pick_d = nil, math.huge
  for _, it in ipairs(rows[target_row]) do
    local d = math.abs(it.x - cx)
    if d < pick_d then pick, pick_d = it, d end
  end
  if not pick then return false end

  ctrl.focused.prev_target = cur
  ctrl.focused.target = pick.node
  pick.node.states.focus.is = true
  if G.VIBRATION then G.VIBRATION = G.VIBRATION + 0.7 end
  return true
end

-- Hold-B state. t0 = when the current hold started (real clock), fired = the hold already closed everything,
-- pending = the press was swallowed and a quick tap still has to be turned into the normal Back on release.
local amu_holdb = { pending = false, fired = false, t0 = nil }
local function amu_now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
end

-- Is B physically down? Checks the game's held-button list AND the gamepad itself, so it still works when another
-- mod (e.g. Better Mouse and Gamepad) swallows the button event before the game sees it.
local function amu_b_down(ctl)
  if ctl and ctl.held_buttons and ctl.held_buttons["b"] then return true end
  if love and love.joystick and love.joystick.getJoysticks then
    local raw = "b"
    if G and G.button_mapping then
      for k, v in pairs(G.button_mapping) do if v == "b" then raw = k end end
    end
    local ok, down = pcall(function()
      for _, j in ipairs(love.joystick.getJoysticks()) do
        if j.isGamepad and j:isGamepad() and j:isGamepadDown(raw) then return true end
      end
      return false
    end)
    if ok and down then return true end
  end
  return false
end

-- Called once per frame (see the controller hook below).
local function amu_hold_tick(ctl)
  if amu_b_down(ctl) then
    if G.OVERLAY_MENU and not (ctl and ctl.text_input_hook) then
      if not amu_holdb.t0 then amu_holdb.t0 = amu_now() end
      if not amu_holdb.fired and (amu_now() - amu_holdb.t0) >= AMU_HOLD_B_SECS then
        amu_holdb.pending, amu_holdb.fired = false, true
        pcall(amu_close_everything)
      end
    end
  else
    -- Button is up: forget any stale hold (release events can be missed)
    amu_holdb.pending, amu_holdb.fired, amu_holdb.t0 = false, false, nil
  end
end

-- Find a node in the open overlay by a test on its config.
local function amu_find_node(pred)
  local om = G.OVERLAY_MENU
  if not (om and om.UIRoot) then return nil end
  local seen = {}
  local function walk(node)
    if type(node) ~= "table" or seen[node] then return nil end
    seen[node] = true
    local c = node.config
    if type(c) == "table" and pred(c) then return node end
    if type(node.children) == "table" then
      for _, ch in pairs(node.children) do
        local r = walk(ch)
        if r then return r end
      end
    end
    return nil
  end
  local ok, res = pcall(walk, om.UIRoot)
  return ok and res or nil
end

-- A tap of B on one of our screens: press that screen's Back button directly. (The game's own B -> Back link only
-- exists on the standard Back button; our sub-screens - a mod's backups, the fork list - use a custom Back button.)
local function amu_do_back()
  local node = amu_find_node(function(c) return c.id == "overlay_menu_back_button" end)
            or amu_find_node(function(c) return c.button == "amu_back_to_menu" end)
  if node and node.click then
    if pcall(node.click, node) then return end
  end
  amu_close_everything()
end

if Controller and not Controller._amu_hooked then
  Controller._amu_hooked = true

  local orig_press = Controller.button_press_update
  function Controller:button_press_update(button, dt)
    if (button == "triggerleft" or button == "triggerright") and not self.locks.frame and amu_screen_open() then
      if amu_cycle_tab(button == "triggerright" and 1 or -1) then
        self.held_button_times[button] = 0
        self.interrupt.focus = false
        return
      end
    end
    -- LB / RB only turn pages. On a screen without pages (Config) they do nothing - they must never switch tabs.
    if (button == "leftshoulder" or button == "rightshoulder") and not self.locks.frame and amu_screen_open() then
      local om = G.OVERLAY_MENU
      if om and om.get_UIE_by_ID and not om:get_UIE_by_ID('cycle_shoulders') then
        self.held_button_times[button] = 0
        return
      end
    end
    -- B: a quick tap is the normal Back button (done when you let go), holding it closes ALL menus.
    -- The hold itself is timed in Controller:update below, so it no longer depends on this press getting through.
    if button == "b" and not self.locks.frame and G.OVERLAY_MENU and not self.text_input_hook and amu_screen_open() then
      amu_holdb.pending, amu_holdb.fired = true, false
      amu_holdb.t0 = amu_now()
      self.held_button_times["b"] = 0
      self.interrupt.focus = false
      return
    end
    return orig_press(self, button, dt)
  end

  local orig_release = Controller.button_release_update
  function Controller:button_release_update(button, dt)
    if button == "b" and (amu_holdb.pending or amu_holdb.fired) then
      local was_tap = amu_holdb.pending and not amu_holdb.fired
      amu_holdb.pending, amu_holdb.fired, amu_holdb.t0 = false, false, nil
      if was_tap and G.OVERLAY_MENU then
        self.frame_buttonpress = false
        if amu_screen_open() then
          amu_do_back()
        else
          orig_press(self, "b", dt) -- the normal Back action
        end
      end
    end
    return orig_release(self, button, dt)
  end

  -- Time the hold from the controller INSTANCE's update. Other mods (Better Mouse and Gamepad) replace
  -- G.CONTROLLER.update on the instance, which would silently skip a hook placed only on the Controller class.
  local ctl = G and G.CONTROLLER
  if ctl then
    if not rawget(ctl, "_amu_upd_hooked") then
      ctl._amu_upd_hooked = true
      local prev = ctl.update
      ctl.update = function(self, dt)
        local r = prev(self, dt)
        amu_hold_tick(self)
        return r
      end
    end
  else
    local orig_update = Controller.update
    function Controller:update(dt)
      local r = orig_update(self, dt)
      amu_hold_tick(self)
      return r
    end
  end

  local orig_focus = Controller.update_focus
  function Controller:update_focus(dir)
    if (dir == "U" or dir == "D" or dir == "L" or dir == "R") and self.focused and self.focused.target
       and self.HID and self.HID.controller and not self.interrupt.focus
       and not (self.locked and not G.SETTINGS.paused) and amu_screen_open() then
      local ok, handled = pcall(amu_row_nav, self, dir)
      if ok and handled then return end
    end
    return orig_focus(self, dir)
  end
end

-- In the tab strip, show the trigger glyphs (LT / RT) instead of the bumper glyphs.
do
  local orig_pip = G.FUNCS.set_button_pip
  if orig_pip and not G.FUNCS._amu_pip_hooked then
    G.FUNCS._amu_pip_hooked = true
    G.FUNCS.set_button_pip = function(e)
      local fa = e and e.config and e.config.focus_args
      if fa and e.children and not e.children.button_pip
         and (fa.button == "leftshoulder" or fa.button == "rightshoulder")
         and G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller then
        local ok, swap = pcall(function()
          if not amu_screen_open() then return false end
          local par = e.parent
          if not par or not par.children then return false end
          for _, ch in pairs(par.children) do
            if type(ch) == "table" and ch.config and ch.config.id == "tab_shoulders" then return true end
          end
          return false
        end)
        if ok and swap then
          fa.button = (fa.button == "leftshoulder") and "triggerleft" or "triggerright"
        end
      end
      return orig_pip(e)
    end
  end
end

-- The red "Close All Menus" button, with the shortcut hint underneath it.
local function amu_close_all_node(minw)
  local dim = RGBA(0.78, 0.8, 0.88, 1)
  local using_pad = G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller
  local hint
  if using_pad then
    hint = {
      { n = G.UIT.T, config = { text = "Hold ", scale = 0.21, colour = dim } },
      { n = G.UIT.C, config = { minw = 0.34, minh = 0.3, align = "cm", func = "set_button_pip",
          focus_args = { button = "b", type = "none", orientation = "cm", scale = 0.32, offset = { x = 0, y = 0 } } }, nodes = {} },
      { n = G.UIT.T, config = { text = " or press Esc", scale = 0.21, colour = dim } },
    }
  else
    hint = { { n = G.UIT.T, config = { text = "Hold B or press Esc", scale = 0.21, colour = dim } } }
  end
  return { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
      { n = G.UIT.B, config = { id = "amu_marker", w = 0, h = 0 } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = minw or 2.6, minh = 0.42, r = 0.09,
          colour = G.C.RED, button = "amu_close_all", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Close All Menus", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
    }},
    { n = G.UIT.R, config = { align = "cm", padding = 0.01 }, nodes = hint },
  }}
end

local function amu_header_row(title, scale)
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  return { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
    { n = G.UIT.T, config = { text = title, scale = scale or 0.5, colour = purple, shadow = true } },
    { n = G.UIT.B, config = { w = 0.5, h = 0.1 } },
    amu_close_all_node(2.6),
  }}
end

local function amu_update_area(id, def)
  local om = G and G.OVERLAY_MENU
  if not om or not om.get_UIE_by_ID then return end
  local area = om:get_UIE_by_ID(id)
  if area and area.config.object then
    area.config.object:remove()
    area.config.object = UIBox {
      definition = def,
      config = { offset = { x = 0, y = 0 }, align = "cm", parent = area },
    }
  end
end

local function amu_update_areas(defs)
  for id, def in pairs(defs) do amu_update_area(id, def) end
end

-- Shared page geometry (kept in one place so every list is the same size on every page)
local AMU_ROW_H = 0.5

local function amu_list_root(rows, w, h)
  return {
    n = G.UIT.ROOT,
    config = { align = "tm", colour = G.C.CLEAR, padding = 0, minw = w, minh = h },
    nodes = { { n = G.UIT.C, config = { align = "tl", padding = 0 }, nodes = rows } },
  }
end

local function amu_blank_row(w, h)
  h = h or AMU_ROW_H
  return { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = h }, nodes = {
    { n = G.UIT.B, config = { h = h - 0.04, w = w or 5.5 } } } }
end

---------------------------------------------------------------------------
-- ON/OFF LIST SNAPSHOT (so you can go back after trying "All on" / "All off")
---------------------------------------------------------------------------

local AMU_SNAP_FILE = "toggle_snapshot.json"
local amu_snap_info = amu_status_tbl(0.27, 9.6, "")
local amu_snap_autosaved = false

local function amu_snap_path()
  return join_path(amu_mod_path(), AMU_SNAP_FILE)
end

local function amu_read_snapshot()
  local s = read_all(amu_snap_path())
  local d = s and decode_json(s) or nil
  if type(d) == "table" and type(d.enabled) == "table" then return d end
  return nil
end

local function amu_snap_label()
  local d = amu_read_snapshot()
  if not d then return "No saved on/off list yet. 'Save list' keeps one." end
  return "Saved on/off list: " .. tostring(d.saved_at or "?") .. "  -  'Restore list' puts it back"
end

local function amu_save_snapshot(source, keep)
  local enabled = {}
  for k, v in pairs(config.mod_update_enabled or {}) do enabled[k] = v and true or false end
  local data = {
    saved_at = os.date("%Y-%m-%d %H:%M"),
    source = source,
    keep = keep and true or false,
    enabled = enabled,
  }
  local f = io.open(amu_snap_path(), "wb")
  if not f then return false end
  f:write(encode_json(data))
  f:close()
  return true
end

local build_mod_toggles_page

local function amu_refresh_toggles()
  pcall(amu_update_areas, {
    ["amu_mod_toggle_list"] = build_mod_toggles_page(AMU_CONFIG_PAGE)
  })
end

G.FUNCS.amu_snap_save = function(e)
  if amu_save_snapshot("saved by you in the Mod Toggles tab", true) then
    amu_snap_info.text = "Saved. " .. amu_snap_label()
  else
    amu_snap_info.text = "Couldn't write toggle_snapshot.json"
  end
end

G.FUNCS.amu_snap_restore = function(e)
  local d = amu_read_snapshot()
  if not d then amu_snap_info.text = "Nothing saved yet - press 'Save list' first."; return end
  local n = 0
  for folder, val in pairs(d.enabled) do
    if config.mod_update_enabled and config.mod_update_enabled[folder] ~= nil then
      local pin = config.mod_pinned and config.mod_pinned[folder]
      if type(pin) == "table" and pin.pinned then
        config.mod_update_enabled[folder] = false
      else
        config.mod_update_enabled[folder] = val and true or false
      end
      n = n + 1
    end
  end
  pcall(write_ps1_config_overlay)
  amu_snap_info.text = "Restored " .. n .. " mods to the list saved " .. tostring(d.saved_at or "?")
  amu_refresh_toggles()
end

-- Builds the dynamic mod-toggle list content for a given page.
-- Every row uses the SAME fixed column widths so the toggles and Check buttons sit in
-- straight vertical lines (this is what makes controller up/down land on the next row).
-- NOTE: the game's real text is ~20% taller than the plain font metrics, so a row with a toggle is ~0.65 high.
-- Every row therefore gets a fixed, generous minimum height and the list area is exactly rows x that height.
-- A check box without the game's roomy padding / empty label, so a row stays slim.
local function amu_tight_toggle(args)
  args.label = ""
  args.label_scale = 0.1
  args.w = 0
  args.scale = 0.42
  local t = create_toggle(args)
  if type(t) == "table" and type(t.config) == "table" then t.config.padding = 0.03 end
  return t
end

local AMU_TOG_ROW_H = 0.60
local AMU_TOG_W, AMU_TOG_H = 10.1, 7 * 0.60

build_mod_toggles_page = function(page)
  local entries = get_sorted_mod_entries(config.sort_toggles)
  local total_pages = math.max(1, math.ceil(#entries / MODS_PER_PAGE))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_CONFIG_PAGE = page

  local rows = {}
  local start_i = (page - 1) * MODS_PER_PAGE + 1
  local end_i = math.min(#entries, page * MODS_PER_PAGE)

  for i = start_i, end_i do
    local entry = entries[i]
    if entry then
      if config.mod_update_enabled[entry.folder] == nil then
        config.mod_update_enabled[entry.folder] = true
      end

      local row_i = i - start_i + 1
      local folder = entry.folder

      G.FUNCS["amu_check_mod_" .. row_i] = function(e)
        run_single_mod_check(folder)
      end

      if not amu_per_mod_status[folder] then
        amu_per_mod_status[folder] = ""
      end

      local check_colour = amu_per_mod_checking[folder] and RGBA(0.5, 0.5, 0.5, 0.9) or G.C.BLUE

      -- name on the left, the update status in the middle, toggle + Check together on the far right
      local row_nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 4.3 }, nodes = {
          { n = G.UIT.T, config = { text = amu_fit(entry.display, 0.44, 4.2), scale = 0.44, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.C, config = { align = "cl", padding = 0.04, minw = 3.3 }, nodes = {
          { n = G.UIT.T, config = { ref_table = amu_per_mod_status, ref_value = folder, scale = 0.26, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.C, config = { align = "cm", padding = 0, minw = 0.9 }, nodes = {
          amu_tight_toggle {
            ref_table = config.mod_update_enabled,
            ref_value = entry.folder,
            callback = function()
              write_ps1_config_overlay()
            end
          },
        }},
        { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 1.5, minh = 0.44, r = 0.09,
          colour = check_colour, button = "amu_check_mod_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Check", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } }
        }},
      }
      rows[#rows+1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_TOG_ROW_H }, nodes = row_nodes }
    end
  end

  local shown = math.max(0, end_i - start_i + 1)
  for _ = shown + 1, MODS_PER_PAGE do rows[#rows+1] = amu_blank_row(AMU_TOG_W - 0.5, AMU_TOG_ROW_H) end

  return amu_list_root(rows, AMU_TOG_W, AMU_TOG_H)
end

-- Callback for the mod toggles page cycle
G.FUNCS.amu_mod_toggles_page = function(args)
  if not args or not args.cycle_config then return end
  local page = args.cycle_config.current_option or 1
  AMU_CONFIG_PAGE = page
  amu_refresh_toggles()
end

-- Sort button on the Mod Toggles screen (A-Z <-> Recently updated)
G.FUNCS.amu_sort_toggles = function(e)
  config.sort_toggles = (config.sort_toggles == "recent") and "az" or "recent"
  amu_sort_set("toggles", config.sort_toggles)
  amu_refresh_toggles()
end

-- Turn updates on/off for EVERY mod at once (pinned mods always stay off).
-- The first time, the current on/off list is saved automatically so it can be restored.
local function amu_set_all_updates(val)
  local on, off = 0, 0
  for folder, v in pairs(config.mod_update_enabled or {}) do
    local pin = config.mod_pinned and config.mod_pinned[folder]
    if not (type(pin) == "table" and pin.pinned) then
      if v then on = on + 1 else off = off + 1 end
    end
  end
  local existing = amu_read_snapshot()
  local mixed = on > 0 and off > 0
  if mixed and not amu_snap_autosaved and not (existing and existing.keep) then
    if amu_save_snapshot("saved automatically just before All on / All off", false) then
      amu_snap_autosaved = true
    end
  end

  for folder, _ in pairs(config.mod_update_enabled or {}) do
    local pin = config.mod_pinned and config.mod_pinned[folder]
    if type(pin) == "table" and pin.pinned then
      config.mod_update_enabled[folder] = false
    else
      config.mod_update_enabled[folder] = val
    end
  end
  pcall(write_ps1_config_overlay)
  amu_snap_info.text = amu_snap_label()
  amu_refresh_toggles()
end
G.FUNCS.amu_toggles_all_on  = function(e) amu_set_all_updates(true) end
G.FUNCS.amu_toggles_all_off = function(e) amu_set_all_updates(false) end

-- Paste Nexus API key from clipboard
G.FUNCS.amu_paste_nexus_key = function(e)
  local clip = ""
  pcall(function()
    clip = love.system.getClipboardText() or ""
  end)
  clip = clip:gsub("%s+", "")
  if clip == "" then
    amu_nexus_display.text = "(clipboard empty)"
    return
  end
  config.nexus_api_key = clip
  amu_nexus_display.text = mask_nexus_key(clip)
  write_ps1_config_overlay()
end

-- Clear Nexus API key
G.FUNCS.amu_clear_nexus_key = function(e)
  config.nexus_api_key = ""
  amu_nexus_display.text = mask_nexus_key("")
  write_ps1_config_overlay()
end

-- Check for updates now button
G.FUNCS.amu_check_updates_now = function(e)
  run_manual_check()
end

-- Backup browser page callback
G.FUNCS.amu_backup_mods_page = function(args)
  if not args or not args.cycle_config then return end
  local page = args.cycle_config.current_option or 1
  AMU_BACKUP_PAGE = page
  amu_update_areas({
    ["amu_backup_mod_list"] = build_backup_mods_page(page)
  })
end

-- Fork Finder page callback
G.FUNCS.amu_fork_mods_page = function(args)
  if not args or not args.cycle_config then return end
  local page = args.cycle_config.current_option or 1
  AMU_FORK_PAGE = page
  amu_update_areas({
    ["amu_fork_mod_list"] = build_fork_mods_page(page)
  })
end

---------------------------------------------------------------------------
-- BACKUP BROWSER: helper functions
---------------------------------------------------------------------------

-- Return a sorted list (newest first) of backup zip files for a given mod folder.
local function list_backups_for_mod(folder_name)
  local backups = {}
  local items = love.filesystem.getDirectoryItems("Mods/_Balatro-Mod-Updater_Backups")
  if not items then return backups end
  local prefix = folder_name .. "-"
  for _, name in ipairs(items) do
    if name:sub(1, #prefix) == prefix then
      local rest = name:sub(#prefix + 1)
      -- Only match files whose suffix is a yyyyMMdd_HHmmss timestamp + .zip
      if rest:sub(-4):lower() == ".zip" and rest:match("^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d") then
        backups[#backups + 1] = name
      end
    end
  end
  table.sort(backups, function(a, b) return a > b end)  -- newest first
  return backups
end

-- Format a backup zip filename into a human-readable date/time string.
local function format_backup_label(mod_folder, zip_name)
  local prefix = mod_folder .. "-"
  local s = zip_name
  if s:sub(1, #prefix) == prefix then s = s:sub(#prefix + 1) end
  if s:sub(-4):lower() == ".zip" then s = s:sub(1, -5) end
  local y, mo, d, h, mi, sec = s:match("^(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)(%d%d)$")
  if y then return y .. "-" .. mo .. "-" .. d .. "  " .. h .. ":" .. mi .. ":" .. sec end
  return s
end

-- Pin a mod at a specific backup and restore that backup via the PS1 script.
local function revert_and_pin_mod(folder_name, backup_file)
  if not is_windows() then
    amu_backup_status.text = "Windows only"
    return
  end

  -- Update config immediately so the UI reflects the pinned state right away
  if not config.mod_pinned then config.mod_pinned = {} end
  config.mod_pinned[folder_name] = {
    pinned = true,
    backup_file = backup_file,
    pinned_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  if config.mod_update_enabled then
    config.mod_update_enabled[folder_name] = false
  end
  pcall(write_ps1_config_overlay)

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
  local ps1 = join_path(mod_path, "autoupdate.ps1")

  if not file_exists(ps1) then
    amu_backup_status.text = folder_name .. " pinned. (autoupdate.ps1 missing – restore files manually)"
    return
  end

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-RestoreModName", safe_quote(folder_name),
    "-RestoreBackupFile", safe_quote(backup_file),
  }, " ")

  amu_restore_in_progress = true
  amu_restore_folder = folder_name
  amu_backup_status.text = "Restoring " .. folder_name .. "..."

  if love and love.thread and love.thread.newThread and love.thread.getChannel then
    local channel = love.thread.getChannel("amu_restore_status")
    channel:clear()
    local thread_code = [[
      local cmd = ...
      local ok = pcall(function() os.execute(cmd) end)
      local ch = love.thread.getChannel("amu_restore_status")
      ch:push(ok and "done" or "error")
    ]]
    local t = love.thread.newThread(thread_code)
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false,
      blocking = false,
      func = function()
        local msg = channel:pop()
        if msg then
          amu_restore_in_progress = false; amu_restore_folder = nil
          amu_backup_status.text = folder_name ..
            (msg == "done" and " restored. Restart to apply." or " restore error. See last_run.json.")
          return true
        end
        return false
      end
    }))
  else
    os.execute(cmd)
    amu_restore_in_progress = false; amu_restore_folder = nil
    amu_backup_status.text = folder_name .. " restored. Restart to apply."
  end
end

-- Unpin a mod so auto-updates resume on the next cycle.
local function unpin_mod(folder_name)
  if config.mod_pinned then config.mod_pinned[folder_name] = nil end
  if config.mod_update_enabled then config.mod_update_enabled[folder_name] = true end
  pcall(write_ps1_config_overlay)
  amu_backup_status.text = folder_name .. " unpinned. Updates will resume."
end

---------------------------------------------------------------------------
-- CONFIG TAB: Settings (general toggles + Nexus key + check now)
---------------------------------------------------------------------------

SMODS.current_mod.config_tab = function()
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  local panel = RGBA(0.15, 0.15, 0.15, 0.95)

  amu_nexus_display.text = mask_nexus_key(config.nexus_api_key)

  local function trow(label, key, with_cb)
    return { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      create_toggle { label = label, ref_table = config, ref_value = key, w = 0, scale = 0.4,
        callback = with_cb and function() write_ps1_config_overlay() end or nil },
    }}
  end

  -- LEFT: general settings
  local left = { n = G.UIT.C, config = { align = "tm", padding = 0.06, minw = 5.0 }, nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.T, config = { text = "General Settings", scale = 0.45, colour = purple, shadow = true } } } },
    trow("Auto-check at startup", "auto_run", false),
    trow("Update Git repos", "cfg_update_git", true),
    trow("Update via update.json", "cfg_update_updatejson", true),
    trow("Make backups", "cfg_make_backups", true),
    trow("Update Steamodded", "cfg_update_steamodded", true),
    trow("Update Lovely Injector", "cfg_update_lovely", true),
  }}

  -- RIGHT: Nexus key, then the "check now" button with clear space above it
  local right = { n = G.UIT.C, config = { align = "tm", padding = 0.06, minw = 5.0 }, nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.T, config = { text = "Nexus API Key", scale = 0.45, colour = purple, shadow = true } } } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 4.6, minh = 0.5, r = 0.1, colour = panel }, nodes = {
        { n = G.UIT.T, config = { ref_table = amu_nexus_display, ref_value = "text", scale = 0.35, colour = G.C.UI.TEXT_LIGHT } } } } } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 2.7, minh = 0.52, r = 0.1, colour = G.C.BLUE,
          button = "amu_paste_nexus_key", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Paste from clipboard", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
      { n = G.UIT.B, config = { h = 0.1, w = 0.12 } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 1.5, minh = 0.52, r = 0.1, colour = G.C.RED,
          button = "amu_clear_nexus_key", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Clear", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
    }},
    -- space below the Nexus section
    { n = G.UIT.B, config = { h = 0.45, w = 0.1 } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 4.4, minh = 0.7, r = 0.12, colour = G.C.GREEN,
          button = "amu_check_updates_now", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Check for updates now", scale = 0.4, colour = purple } } } },
    }},
    { n = G.UIT.R, config = { align = "cm", padding = 0.02, minh = 0.32 }, nodes = {
      { n = G.UIT.T, config = { ref_table = amu_check_status, ref_value = "text", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } },
  }}

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.08, colour = G.C.BLACK, r = 0.1, emboss = 0.05, minh = 5.6, minw = 10.6 },
    nodes = {
      amu_header_row("Mod Updater", 0.45),
      { n = G.UIT.R, config = { align = "tm", padding = 0.02 }, nodes = { left, right } },
    }
  }
end

---------------------------------------------------------------------------
-- EXTRA TAB: Mod Toggles (paginated, 8 per page)
-- Note: SMODS.GUI.DynamicUIManager.initTab wraps staticPageDefinition
-- inside a ROOT node with minh=6, minw=8, align="cm".
-- updateDynamicAreas creates UIBox with offset y=0.5, so we account for that.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- NO SOURCE tab: mods the updater can't check yet (no git clone, no update.json)
---------------------------------------------------------------------------

local function parse_source_link(text)
  text = tostring(text or ""):gsub("%s+", "")
  local owner, repo = text:match("github%.com/([%w%-_%.]+)/([%w%-_%.]+)")
  if owner and repo then
    repo = repo:gsub("%.git$", "")
    return "github", owner .. "/" .. repo
  end
  local id = text:match("nexusmods%.com/balatro/mods/(%d+)")
  if id then return "nexus", id end
  return nil
end

local function write_update_json(folder, kind, val)
  local dir = join_path(join_path(love.filesystem.getSaveDirectory(), "Mods"), folder)
  local body
  if kind == "github" then
    body = '{\n  "provider": "github",\n  "repo": "' .. val .. '",\n  "track": "auto"\n}\n'
  else
    body = '{\n  "provider": "nexus",\n  "mod_id": ' .. val .. ',\n  "game_domain": "balatro"\n}\n'
  end
  local f = io.open(join_path(dir, "update.json"), "wb")
  if not f then return false end
  f:write(body)
  f:close()
  return true
end

local function read_untracked_list()
  local out = {}
  local data = decode_json(read_all(join_path(amu_mod_path(), "last_run.json")) or "")
  local u = type(data) == "table" and data.untracked_mods or nil
  if type(u) == "string" then u = { u } end
  if type(u) == "table" then
    local mods_dir = join_path(love.filesystem.getSaveDirectory(), "Mods")
    for _, name in ipairs(u) do
      if type(name) == "string" and not file_exists(join_path(join_path(mods_dir, name), "update.json")) then
        out[#out + 1] = { folder = name, display = get_display_name(name) }
      end
    end
  end
  table.sort(out, function(a, b) return a.display:lower() < b.display:lower() end)
  return out
end

local function build_nosrc_page(page)
  local entries = read_untracked_list()
  local total_pages = math.max(1, math.ceil(#entries / AMU_NS_PER))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_NOSRC_PAGE = page
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)

  local rows = {}
  local start_i = (page - 1) * AMU_NS_PER + 1
  local end_i = math.min(#entries, page * AMU_NS_PER)

  if #entries == 0 then
    rows[1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_ROW_H }, nodes = {
      { n = G.UIT.T, config = { text = "Every checked mod has an update source.", scale = 0.36, colour = purple } } } }
    rows[2] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_ROW_H }, nodes = {
      { n = G.UIT.T, config = { text = "(Run 'Check for updates now' to refresh this list.)", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } }
  end

  for i = start_i, end_i do
    local entry = entries[i]
    if entry then
      local row_i = i - start_i + 1
      local folder = entry.folder
      local display = entry.display
      G.FUNCS["amu_nosrc_paste_" .. row_i] = function(e)
        local clip = ""
        pcall(function() clip = love.system.getClipboardText() or "" end)
        local kind, val = parse_source_link(clip)
        if not kind then
          amu_nosrc_msg.text = "Copy the mod's GitHub or Nexus page link first, then press again."
          return
        end
        if write_update_json(folder, kind, val) then
          amu_nosrc_msg.text = display .. ": saved (" .. kind .. " " .. tostring(val) .. "). Checked from the next update run."
        else
          amu_nosrc_msg.text = "Couldn't write update.json for " .. display
        end
        amu_update_area("amu_nosrc_list", build_nosrc_page(AMU_NOSRC_PAGE))
      end
      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_ROW_H }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 5.2 }, nodes = {
          { n = G.UIT.T, config = { text = amu_fit(display, 0.44, 5.1), scale = 0.44, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.8, minh = 0.44, r = 0.09,
          colour = G.C.BLUE, button = "amu_nosrc_paste_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Paste link", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } },
      }}
    end
  end

  local filled = (#entries == 0) and 2 or math.max(0, end_i - start_i + 1)
  for _ = filled + 1, AMU_NS_PER do
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_ROW_H }, nodes = {
      { n = G.UIT.B, config = { h = AMU_ROW_H - 0.04, w = AMU_NS_W - 0.5 } } } }
  end

  return amu_list_root(rows, AMU_NS_W, AMU_NS_H)
end

G.FUNCS.amu_nosrc_page = function(args)
  if not args or not args.cycle_config then return end
  AMU_NOSRC_PAGE = args.cycle_config.current_option or 1
  amu_update_areas({ ["amu_nosrc_list"] = build_nosrc_page(AMU_NOSRC_PAGE) })
end

---------------------------------------------------------------------------
-- Tab builder shared by Mod Toggles / Backups / Fork Finder / No Source
--   * the list area has a FIXED size, so the tab never grows or shrinks
--   * the list is drawn centred in that area (no offset hack) so it can't overlap anything
---------------------------------------------------------------------------

local function amu_make_tab(o)
  local per_page = o.per_page or MODS_PER_PAGE
  local total_pages = math.max(1, math.ceil(o.count / per_page))
  local page = math.max(1, math.min(o.get_page(), total_pages))
  o.set_page(page)
  local page_options = {}
  for p = 1, total_pages do page_options[p] = "Page " .. p .. "/" .. total_pages end

  local function spacer(h) return { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { { n = G.UIT.B, config = { w = 0.1, h = h } } } } end
  local gap_pager = 0.05
  -- the empty space ABOVE the page selector (below the last mod) and BELOW it (above the window edge) are kept equal
  local n_after = #(o.after or {})
  local above = 0.08 + n_after * 0.43 + gap_pager
  local bottom_gap = math.max(0.02, above - 0.23)

  local col = {}
  for _, n in ipairs(o.top) do col[#col + 1] = n end
  col[#col + 1] = spacer(o.gap_top or 0.1)
  col[#col + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
    { n = G.UIT.O, config = { id = o.id, w = o.list_w, h = o.list_h, object = Moveable() } } } }
  for _, n in ipairs(o.after or {}) do col[#col + 1] = n end
  col[#col + 1] = spacer(gap_pager)
  col[#col + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
    create_option_cycle {
      w = 3.8, scale = 0.55, options = page_options, current_option = page,
      opt_callback = o.cb, cycle_shoulders = true, no_pips = true,
    } } }
  col[#col + 1] = spacer(bottom_gap)

  local static_def = { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
    { n = G.UIT.C, config = { align = "tm", padding = 0.03, minw = o.panel_w - 0.3 }, nodes = col } } }

  -- fill the list on the next frame (the overlay has to exist first)
  G.E_MANAGER:add_event(Event({ func = function()
    amu_update_area(o.id, o.build(page))
    return true
  end }))

  return {
    n = G.UIT.ROOT,
    config = { emboss = 0.05, r = 0.1, minw = o.panel_w, minh = 0, align = "cm", colour = G.C.BLACK, padding = 0.04 },
    nodes = { static_def },
  }
end

local function amu_btn(label, func, colour, minw, scale)
  return { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = minw, minh = 0.44, r = 0.1,
    colour = colour, button = func, hover = true, shadow = true }, nodes = {
    { n = G.UIT.T, config = { text = label, scale = scale or 0.32, colour = G.C.UI.TEXT_LIGHT } } } }
end

local function amu_gap(w) return { n = G.UIT.B, config = { w = w or 0.2, h = 0.1 } } end

-- Two pieces for the sort control, like the Mod Sort mod:
--   [ Now: <current sort> ]  (info only)   [ Next: <next sort> ]  (the button - switches to that sort)
local function amu_sort_nodes(which, func, now_w, next_w)
  local pill = HEX and HEX("2B2B35") or { 0.17, 0.17, 0.21, 1 }
  local dim  = HEX and HEX("A9A9B8") or { 0.66, 0.66, 0.72, 1 }
  return {
    { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = now_w, minh = 0.44, r = 0.1, colour = pill }, nodes = {
      { n = G.UIT.T, config = { text = "Now: ", scale = 0.28, colour = dim } },
      { n = G.UIT.T, config = { ref_table = amu_sort_label, ref_value = which .. "_now", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } },
    amu_gap(0.08),
    { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = next_w, minh = 0.44, r = 0.1,
        colour = G.C.BLUE, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { ref_table = amu_sort_label, ref_value = which .. "_next", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } },
  }
end

SMODS.current_mod.extra_tabs = function()
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  return {
    {
      label = "Mod Toggles",
      tab_definition_function = function()
        amu_sort_set("toggles", config.sort_toggles)
        local sn = amu_sort_nodes("toggles", "amu_sort_toggles", 1.75, 1.95)
        amu_snap_info.text = amu_snap_label()
        return amu_make_tab({
          id = "amu_mod_toggle_list", cb = "amu_mod_toggles_page", build = build_mod_toggles_page,
          count = #get_sorted_mod_entries(config.sort_toggles), per_page = MODS_PER_PAGE,
          get_page = function() return AMU_CONFIG_PAGE end, set_page = function(p) AMU_CONFIG_PAGE = p end,
          panel_w = 10.6, list_w = AMU_TOG_W, list_h = AMU_TOG_H, gap_top = 0.15,
          top = {
            amu_header_row("Mod Update Toggles", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
              sn[1], sn[2], sn[3],
              amu_gap(0.12),
              amu_btn("All on", "amu_toggles_all_on", G.C.GREEN, 1.1),
              amu_gap(0.08),
              amu_btn("All off", "amu_toggles_all_off", G.C.RED, 1.1),
              amu_gap(0.15),
              amu_btn("Save list", "amu_snap_save", G.C.PURPLE or purple, 1.5),
              amu_gap(0.08),
              amu_btn("Restore list", "amu_snap_restore", G.C.ORANGE or RGBA(0.85, 0.5, 0.05, 1), 1.8),
            }},
          },
          after = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_snap_info, ref_value = "text", scale = 0.27, colour = G.C.UI.TEXT_LIGHT } } } },
          },
        })
      end
    },
    {
      label = "Backups",
      tab_definition_function = function()
        amu_sort_set("backups", config.sort_backups)
        local sn = amu_sort_nodes("backups", "amu_sort_backups", 1.9, 2.2)
        return amu_make_tab({
          id = "amu_backup_mod_list", cb = "amu_backup_mods_page", build = build_backup_mods_page,
          count = #get_sorted_mod_entries(config.sort_backups), per_page = AMU_BK_PER,
          get_page = function() return AMU_BACKUP_PAGE end, set_page = function(p) AMU_BACKUP_PAGE = p end,
          panel_w = 12.6, list_w = AMU_BK_W, list_h = AMU_BK_H, gap_top = 0.25,
          top = {
            amu_header_row("Mod Backups & Pinning", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
              sn[1], sn[2], sn[3],
            }},
          },
          after = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_backup_status, ref_value = "text", scale = 0.3, colour = purple } } } },
          },
        })
      end
    },
    {
      label = "Fork Finder",
      tab_definition_function = function()
        if not amu_fork_suggestions then amu_fork_suggestions = load_fork_suggestions() end
        amu_fork_filter_label.text = amu_fork_filter_text()
        amu_fork_tr_label.text = amu_fork_tr_text()
        return amu_make_tab({
          id = "amu_fork_mod_list", cb = "amu_fork_mods_page", build = build_fork_mods_page,
          count = #get_fork_mod_entries(), per_page = AMU_FORK_PER,
          get_page = function() return AMU_FORK_PAGE end, set_page = function(p) AMU_FORK_PAGE = p end,
          panel_w = 10.6, list_w = AMU_FORK_W, list_h = AMU_FORK_H,
          top = {
            amu_header_row("Fork Finder", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.7, minh = 0.46, r = 0.1,
                colour = amu_fork_scanning and RGBA(0.5, 0.5, 0.5, 0.9) or G.C.GREEN,
                button = "amu_scan_forks", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { text = "Scan Now", scale = 0.3, colour = purple } } } },
              amu_gap(0.1),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 3.0, minh = 0.46, r = 0.1,
                colour = G.C.BLUE, button = "amu_fork_filter", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { ref_table = amu_fork_filter_label, ref_value = "text", scale = 0.29, colour = G.C.UI.TEXT_LIGHT } } } },
              amu_gap(0.1),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.6, minh = 0.46, r = 0.1,
                colour = G.C.BLUE, button = "amu_fork_tr_filter", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { ref_table = amu_fork_tr_label, ref_value = "text", scale = 0.29, colour = G.C.UI.TEXT_LIGHT } } } },
              amu_gap(0.1),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.9, minh = 0.46, r = 0.1,
                colour = G.C.BLUE, button = "amu_gh_help_open", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { text = "GitHub token", scale = 0.29, colour = G.C.UI.TEXT_LIGHT } } } },
            }},
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.3 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_fork_status, ref_value = "text", scale = 0.3, colour = purple } } } },
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.28 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_gh_display, ref_value = "text", scale = 0.26, colour = G.C.UI.TEXT_LIGHT } } } },
          },
        })
      end
    },
    {
      label = "No Source",
      tab_definition_function = function()
        return amu_make_tab({
          id = "amu_nosrc_list", cb = "amu_nosrc_page", build = build_nosrc_page,
          count = #read_untracked_list(), per_page = AMU_NS_PER,
          get_page = function() return AMU_NOSRC_PAGE end, set_page = function(p) AMU_NOSRC_PAGE = p end,
          panel_w = 10.6, list_w = AMU_NS_W, list_h = AMU_NS_H,
          top = {
            amu_header_row("Mods With No Update Source", 0.46),
            { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
              { n = G.UIT.T, config = { text = "Copy a mod's GitHub or Nexus page link, then press 'Paste link'.", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } },
            { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
              create_toggle { label = "Show the 'no update source' note after update checks",
                ref_table = config, ref_value = "show_untracked_note", w = 0, scale = 0.34 },
            }},
          },
          after = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_nosrc_msg, ref_value = "text", scale = 0.27, colour = G.C.GREEN } } } },
          },
        })
      end
    },
  }
end

-- Write the config overlay once on startup
pcall(write_ps1_config_overlay)

---------------------------------------------------------------------------
-- Loading definition: transparent (no panel), purple text
---------------------------------------------------------------------------

G.UIDEF.amu_loading_box = function(ref)
  ref = ref or {}
  local purple = (G.C and (G.C.PURPLE or (G.C.UI and G.C.UI.PURPLE))) or RGBA(0.62, 0.33, 0.92, 1)
  local clear  = (G.C and (G.C.CLEAR or (G.C.UI and G.C.UI.TRANSPARENT_LIGHT))) or RGBA(0,0,0,0)

  -- One line of text where every letter (dots and suits too) rides a travelling wave.
  local label = ref.label or "Shuffling mods...   ♠  ♥  ♦  ♣"
  local text = DynaText({
    string = { label }, colours = { purple }, scale = 0.72, shadow = true, silent = true,
  })
  local orig_align = text.align_letters
  text.align_letters = function(self)
    orig_align(self)
    local amp = (G.SETTINGS and G.SETTINGS.reduced_motion) and 0
      or math.sqrt(self.scale) * (self.font.FONTSCALE / G.TILESIZE) * 3000
    local t = G.TIMERS.REAL
    local letters = self.strings[self.focused_string] and self.strings[self.focused_string].letters or {}
    -- dots count up 1 -> 2 -> 3 -> 1 ... (hidden dots keep their space so nothing shifts)
    local shown = 1 + math.floor(t * 2.5) % 3
    local dot_n = 0
    for k, letter in ipairs(letters) do
      letter.offset.y = amp * math.sin(4.2 * t - 0.42 * k)
      if letter.char == "." then
        dot_n = dot_n + 1
        letter.pop_in = (dot_n <= shown) and 1 or 0
      end
    end
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.0, r = 0, colour = clear },
    nodes = {
      { n = G.UIT.O, config = { object = text } },
    }
  }
end

local function open_overlay(def, cfg)
  if not (G and G.FUNCS and G.FUNCS.overlay_menu) then return false end
  return pcall(function()
    G.FUNCS.overlay_menu({ definition = def, config = cfg })
  end)
end

local function close_overlay()
  if G and G.FUNCS and G.FUNCS.exit_overlay_menu then
    pcall(G.FUNCS.exit_overlay_menu)
  end
end

---------------------------------------------------------------------------
-- GITHUB TOKEN help screen + buttons
---------------------------------------------------------------------------

G.FUNCS.amu_gh_open_page = function(e)
  local ok = pcall(function() love.system.openURL(AMU_GH_TOKEN_URL) end)
  amu_gh_msg.text = ok and "Opened GitHub in your browser. Follow the steps, then come back."
                        or "Couldn't open a browser. Go to github.com/settings/personal-access-tokens/new"
end

G.FUNCS.amu_gh_paste_token = function(e)
  local clip = ""
  pcall(function() clip = love.system.getClipboardText() or "" end)
  clip = clip:gsub("%s+", "")
  if clip == "" then
    amu_gh_msg.text = "Clipboard is empty. Copy the token on GitHub first."
    return
  end
  if not (clip:match("^github_pat_") or clip:match("^ghp_")) then
    amu_gh_msg.text = "That doesn't look like a GitHub token (should start with github_pat_)."
    return
  end
  config.github_token = clip
  amu_gh_display.text = mask_gh_token(clip)
  amu_gh_msg.text = "Token saved! Click Scan Now to look for forks."
  pcall(write_ps1_config_overlay)
end

G.FUNCS.amu_gh_clear_token = function(e)
  config.github_token = ""
  amu_gh_display.text = mask_gh_token("")
  amu_gh_msg.text = "Token removed."
  pcall(write_ps1_config_overlay)
end

G.UIDEF.amu_github_token_help = function()
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.15, 0.15, 0.15, 0.95)
  amu_gh_display.text = mask_gh_token(config.github_token)

  local function line(txt, colour)
    return { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = txt, scale = 0.33, colour = colour or G.C.UI.TEXT_LIGHT } }
    }}
  end
  local function button(label, func, colour, w)
    return { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = w or 2.8, minh = 0.6, r = 0.1,
      colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.34, colour = G.C.UI.TEXT_LIGHT } }
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = 9.5, padding = 0.22, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.T, config = { text = "Get a free GitHub token", scale = 0.5, colour = purple, shadow = true } }
      }},
      line("Without one, GitHub allows only 60 checks per hour, so Fork Finder stops early.", purple),
      line("A token makes it 5000 per hour. It is free, read-only and only sees public data."),
      { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
      line("1.  Click 'Open GitHub page' (log in if GitHub asks)."),
      line("2.  Name: Balatro Mod Updater      (should already be filled in)"),
      line("3.  Expiration: 90 days            (should already be filled in)"),
      line("4.  Repository access: Public repositories (read-only)"),
      line("5.  Permissions: leave EVERYTHING unchecked / untouched"),
      line("6.  Click 'Generate token', then copy it (starts with github_pat_)"),
      line("7.  Come back here and click 'Paste token'"),
      { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 7.5, minh = 0.45, r = 0.1, colour = panel }, nodes = {
          { n = G.UIT.T, config = { ref_table = amu_gh_display, ref_value = "text", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
        }},
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { ref_table = amu_gh_msg, ref_value = "text", scale = 0.28, colour = G.C.GREEN } }
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        button("Open GitHub page", "amu_gh_open_page", G.C.BLUE, 3.2),
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        button("Paste token", "amu_gh_paste_token", G.C.GREEN, 2.8),
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        button("Clear", "amu_gh_clear_token", G.C.RED, 1.5),
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        button("Scan Now", "amu_gh_scan_now", G.C.GREEN, 2.8),
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        button("Back", "amu_back_to_menu", panel, 2.0),
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        button("Close All Menus", "amu_close_all", G.C.RED, 3.2),
      }},
    }
  }
end

G.FUNCS.amu_gh_help_open = function(e)
  amu_gh_msg.text = ""
  open_overlay(G.UIDEF.amu_github_token_help())
end

-- "Scan Now" from the token screen: go back to Fork Finder and start the scan.
G.FUNCS.amu_gh_scan_now = function(e)
  if not (config.github_token and config.github_token ~= "") then
    amu_gh_msg.text = "Paste your token first (then scanning works properly)."
    return
  end
  G.FUNCS.amu_back_to_menu()
  if amu_run_fork_scan then amu_run_fork_scan() end
end

-- Shown after a fork scan when the token is bad/expired or GitHub's hourly limit was hit.
-- kind: "bad" | "limit" (no token yet) | "limit_token" (limit hit even with a token)
G.UIDEF.amu_token_problem = function(kind)
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.15, 0.15, 0.15, 0.95)
  local lines
  if kind == "bad" then
    lines = { "Your GitHub token has expired or was rejected.",
              "Fork scans can't run until you replace it.",
              "Replace it now? (about a minute)" }
  elseif kind == "limit" then
    lines = { "GitHub allows only 60 checks per hour without a token,",
              "so this scan stopped early and the list is partial.",
              "Get a free token now? (about a minute)" }
  else
    lines = { "GitHub's hourly limit was reached, even with your token.",
              "The list is partial. Try again in about an hour." }
  end
  local function line(t, c)
    return { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = t, scale = 0.36, colour = c or G.C.UI.TEXT_LIGHT } } } }
  end
  local nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
      { n = G.UIT.T, config = { text = "GitHub token", scale = 0.5, colour = purple, shadow = true } } } },
  }
  for i, t in ipairs(lines) do nodes[#nodes + 1] = line(t, (i == #lines) and purple or nil) end
  nodes[#nodes + 1] = { n = G.UIT.B, config = { h = 0.15, w = 0.1 } }
  local function b(label, func, colour, w)
    return { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = w, minh = 0.62, r = 0.1,
      colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } }
  end
  local gap = { n = G.UIT.B, config = { h = 0.1, w = 0.15 } }
  if kind == "limit_token" then
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      b("Back", "amu_back_to_menu", panel, 2.4), gap, b("Close All Menus", "amu_close_all", G.C.RED, 3.2) } }
  else
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      b("Yes, replace it", "amu_gh_help_open", G.C.GREEN, 3.2), gap,
      b("Not now", "amu_back_to_menu", panel, 2.2), gap,
      b("Close All Menus", "amu_close_all", G.C.RED, 3.2) } }
  end
  return { n = G.UIT.ROOT, config = { align = "cm", minw = 9.0, padding = 0.22, r = 0.2, colour = bg, shadow = true, hover = true }, nodes = nodes }
end

---------------------------------------------------------------------------
-- BACKUP BROWSER: build_backup_mods_page and amu_backup_picker overlay
-- (defined here, after open_overlay/close_overlay are in scope)
---------------------------------------------------------------------------

-- Overlay that lists available backups for a single mod and lets the user
-- revert to one (which also pins the mod so updates are frozen).
G.UIDEF.amu_backup_picker = function(ref)
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.12, 0.12, 0.12, 0.96)

  local folder   = ref.folder  or ""
  local display  = ref.display or folder
  local backups  = ref.backups or {}

  local pinned_info   = config.mod_pinned and config.mod_pinned[folder]
  local pinned_backup = pinned_info and pinned_info.backup_file or ""

  local max_show = 5
  local shown = math.min(#backups, max_show)

  -- Register one revert G.FUNC per visible backup entry
  for i = 1, shown do
    local bf = backups[i]
    G.FUNCS["amu_revert_" .. tostring(i)] = function(e)
      close_overlay()
      revert_and_pin_mod(folder, bf)
      G.FUNCS.amu_back_to_menu()   -- back to the Backups page, not the main menu
    end
  end

  local rows = {}
  for i = 1, shown do
    local bf    = backups[i]
    local label = format_backup_label(folder, bf)
    local is_cur_pin = (bf == pinned_backup)

    local btn_node
    if is_cur_pin then
      btn_node = {
        n = G.UIT.C, config = { align = "cm", padding = 0.05, minw = 1.9, minh = 0.45, r = 0.1, colour = panel }, nodes = {
          { n = G.UIT.T, config = { text = "\226\156\147 Pinned", scale = 0.32, colour = G.C.GREEN } }
        }
      }
    else
      btn_node = {
        n = G.UIT.C, config = { align = "cm", padding = 0.05, minw = 1.9, minh = 0.45, r = 0.1,
          colour = G.C.GREEN, button = "amu_revert_" .. tostring(i), hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Revert & Pin", scale = 0.32, colour = purple } }
        }
      }
    end

    rows[#rows + 1] = {
      n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.04, minw = 3.8 }, nodes = {
          { n = G.UIT.T, config = { text = label, scale = 0.34, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        btn_node,
      }
    }
  end

  if #backups == 0 then
    rows[1] = {
      n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.T, config = { text = "No backups found.", scale = 0.38, colour = purple } }
      }
    }
  elseif #backups > max_show then
    rows[#rows + 1] = {
      n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.T, config = { text = "(showing " .. max_show .. " most recent of " .. #backups .. ")", scale = 0.3, colour = purple } }
      }
    }
  end

  local minh = math.max(3.5, shown * 0.55 + 2.2)

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = 7.4, minh = minh, padding = 0.24, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.T, config = { text = "Backups: " .. display, scale = 0.52, colour = purple, shadow = true } }
      }},
      { n = G.UIT.B, config = { h = 0.12, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.12, minw = 6.6, r = 0.12, colour = panel }, nodes = rows }
      }},
      { n = G.UIT.B, config = { h = 0.14, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 2.8, minh = 0.7, r = 0.12,
          colour = panel, button = "amu_back_to_menu", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Back", scale = 0.42, colour = purple } }
        }},
        { n = G.UIT.B, config = { h = 0.1, w = 0.2 } },
        amu_close_all_node(2.8),
      }},
    }
  }
end

---------------------------------------------------------------------------
-- CHANGELOG HOVER (Backups tab): short summary of the newest changes of each mod.
-- Data comes from changelogs.json, which autoupdate.ps1 refreshes after every
-- update and every restore, so it always describes the version that is installed.
---------------------------------------------------------------------------

-- one short readable line from a commit message / release note line
local function amu_clean_note(s)
  s = tostring(s or "")
  s = s:gsub("[\r\n]+", " "):gsub("%*%*", ""):gsub("[{}]", "")
  s = s:gsub("^[%s%-%*#>]+", "")
  s = s:gsub("#(%d)", "%1"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function amu_is_noise(s)
  local l = s:lower()
  return l == "" or l:find("^merge ") or l:find("^stylua") or l:find("auto%-format") or l:find("^update readme")
    or l:find("^initial commit")
end

-- Builds the rows of the hover box (called by the game when you hover / focus the row).
local function amu_changelog_tip(args)
  args = args or {}
  local folder, display = args.folder or "", args.display or args.folder or ""
  local dark = G.C.UI.TEXT_DARK or RGBA(0.2, 0.2, 0.25, 1)
  local blue = G.C.BLUE or dark
  local maxw = 6.2
  local rows = {}
  local function add(text, scale, colour)
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = amu_fit(text, scale, maxw), scale = scale, colour = colour or dark } } } }
  end

  add(display .. "  -  " .. mod_version_line(folder), 0.34, blue)

  if amu_restore_in_progress and amu_restore_folder == folder then
    add("Reverting... this list refreshes when it's done.", 0.3)
  else
    local pin = config.mod_pinned and config.mod_pinned[folder]
    if type(pin) == "table" and pin.pinned then
      add("Pinned: you reverted this mod, so updates are paused.", 0.28)
    end
    local info = amu_changelogs()[folder]
    local shown = 0
    if type(info) == "table" then
      if info.restored then add("This is the reverted copy (its files come from the backup).", 0.27) end
      local dt = info.date
      if (not dt or dt == "") and type(info.commits) == "table" and info.commits[1] then dt = info.commits[1].d end
      if dt and dt ~= "" then add("Latest version dated " .. tostring(dt), 0.28) end
      local lines = {}
      if type(info.commits) == "table" then
        for _, c in ipairs(info.commits) do lines[#lines + 1] = { amu_clean_note(c.s), c.d } end
      elseif type(info.notes) == "table" then
        for _, n in ipairs(info.notes) do lines[#lines + 1] = { amu_clean_note(n) } end
      end
      local seen = {}
      for _, ln in ipairs(lines) do
        local t = ln[1]
        if shown < 5 and not amu_is_noise(t) and not seen[t] then
          add("\226\128\162 " .. t, 0.3)
          shown = shown + 1
          seen[t] = true
        end
      end
      if shown == 0 and #lines > 0 then
        add("(only minor changes: merges and formatting)", 0.28)
      end
    end
    if shown == 0 and not (type(info) == "table" and #(info.commits or info.notes or {}) > 0) then
      add("No change notes saved yet for this mod.", 0.3)
      add("They fill in after the next 'Check for updates now'.", 0.27)
    end
  end

  return { n = G.UIT.R, config = { align = "cl", padding = 0.03 }, nodes = {
    { n = G.UIT.C, config = { align = "cl", padding = 0.03 }, nodes = rows } } }
end

-- Paginated list of all mods with version, last-update date, pin state and buttons.
-- NOTE: this is assigned to the forward-declared local 'build_backup_mods_page'.
build_backup_mods_page = function(page)
  local entries = get_sorted_mod_entries(config.sort_backups)
  local total_pages = math.max(1, math.ceil(#entries / AMU_BK_PER))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_BACKUP_PAGE = page

  local umap = build_last_update_map()
  local grey = RGBA(0.78, 0.78, 0.88, 1)
  local orange = RGBA(0.98, 0.62, 0.12, 1)

  local rows = {}
  local start_i = (page - 1) * AMU_BK_PER + 1
  local end_i   = math.min(#entries, page * AMU_BK_PER)

  for i = start_i, end_i do
    local entry = entries[i]
    if entry then
      local row_i     = i - start_i + 1
      local folder    = entry.folder
      local display   = entry.display
      local pin_info  = config.mod_pinned and config.mod_pinned[folder]
      local is_pinned = type(pin_info) == "table" and pin_info.pinned == true

      G.FUNCS["amu_open_backups_" .. row_i] = function(e)
        local backups = list_backups_for_mod(folder)
        open_overlay(G.UIDEF.amu_backup_picker({ folder = folder, display = display, backups = backups }))
      end

      G.FUNCS["amu_unpin_mod_" .. row_i] = function(e)
        unpin_mod(folder)
        amu_update_area("amu_backup_mod_list", build_backup_mods_page(AMU_BACKUP_PAGE))
      end

      -- Two lines to the right of the name: version, then last update / pin info
      local line1 = amu_fit(mod_version_line(folder), 0.32, 3.55)
      local line2, line2_colour
      if is_pinned then
        local pd = fmt_date(parse_stamp(pin_info.backup_file or ""))
        line2 = pd and ("Pinned to backup " .. pd) or "Pinned to a backup"
        line2_colour = orange
      else
        local ud = fmt_date(last_update_for(folder, umap))
        line2 = ud and ("Updated " .. ud) or "Never updated here"
        line2_colour = grey
      end
      line2 = amu_fit(line2, 0.29, 3.55)

      local tip = { filler = { func = amu_changelog_tip, args = { folder = folder, display = display } } }

      local pin_badge
      if is_pinned then
        pin_badge = { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 1.0, minh = 0.32, r = 0.08,
          colour = RGBA(0.7, 0.45, 0.0, 0.95) }, nodes = {
          { n = G.UIT.T, config = { text = "PINNED", scale = 0.25, colour = RGBA(1, 1, 1, 1) } } } }
      else
        pin_badge = { n = G.UIT.B, config = { h = 0.1, w = 1.0 } }
      end

      local unpin_node
      if is_pinned then
        unpin_node = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.05, minh = 0.42, r = 0.09,
          colour = G.C.RED, button = "amu_unpin_mod_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Unpin", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } }
      else
        unpin_node = { n = G.UIT.B, config = { h = 0.1, w = 1.05 } }
      end

      local row_nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 3.9 }, nodes = {
          { n = G.UIT.T, config = { text = amu_fit(display, 0.44, 3.8), scale = 0.44, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.C, config = { align = "cl", padding = 0, minw = 3.7 }, nodes = {
          { n = G.UIT.R, config = { align = "cl", padding = 0 }, nodes = {
            { n = G.UIT.T, config = { text = line1, scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } },
          { n = G.UIT.R, config = { align = "cl", padding = 0 }, nodes = {
            { n = G.UIT.T, config = { text = line2, scale = 0.29, colour = line2_colour } } } },
        }},
        pin_badge,
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.45, minh = 0.42, r = 0.09,
          colour = G.C.BLUE, button = "amu_open_backups_" .. row_i, hover = true, shadow = true,
          on_demand_tooltip = tip }, nodes = {
          { n = G.UIT.T, config = { text = "Backups", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        unpin_node,
      }

      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_BK_ROW_H, on_demand_tooltip = tip }, nodes = row_nodes }
    end
  end

  local shown = math.max(0, end_i - start_i + 1)
  for _ = shown + 1, AMU_BK_PER do
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_BK_ROW_H }, nodes = {
      { n = G.UIT.B, config = { h = AMU_BK_ROW_H - 0.04, w = AMU_BK_W - 0.5 } } } }
  end

  return amu_list_root(rows, AMU_BK_W, AMU_BK_H)
end

-- Sort button on the Backups screen
G.FUNCS.amu_sort_backups = function(e)
  config.sort_backups = (config.sort_backups == "recent") and "az" or "recent"
  amu_sort_set("backups", config.sort_backups)
  amu_update_area("amu_backup_mod_list", build_backup_mods_page(AMU_BACKUP_PAGE))
end

---------------------------------------------------------------------------
-- FORK FINDER: helper functions, build_fork_mods_page, and picker overlay
-- (defined here, after open_overlay/close_overlay are in scope)
---------------------------------------------------------------------------

load_fork_suggestions = function()
  local mod_path = amu_mod_path()
  if mod_path == "" then return nil end
  local data = read_all(join_path(mod_path, "fork_suggestions.json"))
  if not data then return nil end
  return decode_json(data)
end

-- A fork counts as "newer" when it is the original project (upstream), or it has commits the
-- installed copy doesn't have AND was updated on/after the day the installed copy was made.
local function amu_fork_is_newer(fork, installed_date)
  if fork.is_upstream or fork.kind == "original" or fork.kind == "parent" then return true end
  if (fork.commits_ahead or 0) <= 0 then return false end
  local pushed = tostring(fork.pushed_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
  if not pushed or not installed_date or installed_date == "" then return true end
  return pushed >= installed_date
end

local function amu_installed_date(folder, umap, cls)
  local info = cls and cls[folder]
  local d = info and type(info.commits) == "table" and info.commits[1] and info.commits[1].d
  if type(d) == "string" and d ~= "" then return d end
  return fmt_date(last_update_for(folder, umap)) or ""
end

-- What kind of copy is a fork? original / parent / parent_fork / fork_fork / fork
--   original    = the repo the whole family started from
--   parent      = the repo your installed copy was forked from (only when that is not the original)
--   parent_fork = another fork of the original / parent (a "sibling" of your copy)
--   fork_fork   = a fork of YOUR installed copy
--   fork        = a fork of your installed copy when it is itself the original project
local AMU_FORK_KIND = {
  original    = { tag = "ORIGINAL",    word = "original",    rank = 1 },
  parent      = { tag = "PARENT",      word = "parent",      rank = 2 },
  parent_fork = { tag = "PARENT FORK", word = "parent fork", rank = 3 },
  fork_fork   = { tag = "FORK-FORK",   word = "fork-fork",   rank = 4 },
  fork        = { tag = "FORK",        word = "fork",        rank = 5 },
}

local function amu_fork_kind(f)
  if f.kind and AMU_FORK_KIND[f.kind] then return f.kind end
  if f.is_upstream then return "original" end   -- fork_suggestions.json from an older version
  return "fork"
end

local function amu_fork_kind_colour(kind)
  if kind == "original" or kind == "parent" then return (G.C and G.C.ORANGE) or RGBA(0.85, 0.5, 0.05, 1) end
  if kind == "fork_fork" then return G.C.GREEN end
  if kind == "parent_fork" then return G.C.BLUE end
  return G.C.UI.TEXT_LIGHT
end

-- "Is this fork only a translation?"  (name says so, OR most changed files are language files,
-- OR most of its commit messages are about translating)
local AMU_TR_WORDS = { "espanol", "espa\195\177ol", "spanish", "castellano", "translat", "traduc", "traduz", "locali[sz]",
  "portugu", "brasil", "chinese", "japanese", "korean", "russian", "french", "german", "italian", "polish", "turkish",
  "vietnam", "indonesia", "arabic", "ukrain", "dutch", "czech", "swedish", "hungar", "romanian" }
local AMU_TR_TOKENS = { esp = true, spa = true, ptbr = true, pt = true, cn = true, zh = true, tw = true, jp = true,
  ru = true, kr = true, lang = true, l10n = true, i18n = true, loc = true }

local function amu_fork_is_translation(f)
  if f._tr ~= nil then return f._tr end
  local result = false
  local kind = amu_fork_kind(f)
  if kind ~= "original" and kind ~= "parent" then
    local name = tostring(f.repo or ""):lower():match("/(.+)$") or ""
    for _, w in ipairs(AMU_TR_WORDS) do
      if name:find(w) then result = true break end
    end
    if not result then
      for tok in name:gmatch("[a-z0-9]+") do
        if AMU_TR_TOKENS[tok] then result = true break end
      end
    end
    if not result and (f.files_changed or 0) > 0 and (f.loc_files or 0) / f.files_changed >= 0.75 then result = true end
    if not result and type(f.changelog) == "table" and #f.changelog > 0 then
      local hits = 0
      for _, m in ipairs(f.changelog) do
        local l = tostring(m):lower()
        if l:find("translat") or l:find("traduc") or l:find("traduz") or l:find("locali[sz]ation") or l:find("spanish")
           or l:find("espa\195\177ol") or l:find("espanol") or l:find("%f[%a]lang%f[%A]") then hits = hits + 1 end
      end
      if hits / #f.changelog >= 0.6 then result = true end
    end
  end
  f._tr = result
  return result
end

-- Where can the player read about the mod they have installed RIGHT NOW? (GitHub and/or Nexus)
local function amu_current_page_links(folder, installed_repo)
  local links = {}
  local src = config.mod_fork_source and config.mod_fork_source[folder]
  local repo = src and src.fork_repo or nil
  local nexus_id = nil
  local ok, uj = pcall(function()
    local mods_dir = join_path(love.filesystem.getSaveDirectory(), "Mods")
    local raw = read_all(join_path(join_path(mods_dir, folder), "update.json"))
    return raw and decode_json(raw) or nil
  end)
  if ok and type(uj) == "table" then
    if uj.provider == "github" and type(uj.repo) == "string" and uj.repo ~= "" and not repo then repo = uj.repo end
    if uj.provider == "nexus" and uj.mod_id then nexus_id = tostring(uj.mod_id) end
  end
  if (not repo or repo == "") and type(installed_repo) == "string" and installed_repo ~= "" then repo = installed_repo end
  if repo and repo ~= "" then
    links[#links + 1] = { label = "Open GitHub page", url = "https://github.com/" .. repo, name = repo }
  end
  if nexus_id then
    links[#links + 1] = { label = "Open Nexus page", url = "https://www.nexusmods.com/balatro/mods/" .. nexus_id, name = "Nexus #" .. nexus_id }
  end
  return links
end

-- keep_tr = true: do not remove translation-only forks even when that option is on (used for counting)
get_fork_mod_entries = function(force_all, keep_tr)
  if not amu_fork_suggestions or not amu_fork_suggestions.suggestions then return {} end
  local newer_only = (config.fork_newer_only ~= false) and not force_all
  local hide_tr = (config.fork_hide_translations ~= false) and not keep_tr
  local umap = newer_only and build_last_update_map() or nil
  local cls = newer_only and amu_changelogs() or nil
  local entries = {}
  for folder_name, data in pairs(amu_fork_suggestions.suggestions) do
    if type(data) == "table" and type(data.forks) == "table" and #data.forks > 0 then
      local installed = newer_only and amu_installed_date(folder_name, umap, cls) or ""
      local list = {}
      for _, f in ipairs(data.forks) do
        local keep = (not newer_only or amu_fork_is_newer(f, installed)) and not (hide_tr and amu_fork_is_translation(f))
        if keep then list[#list + 1] = f end
      end
      -- newest push first, whatever kind of fork it is
      table.sort(list, function(a, b)
        local pa, pb = tostring(a.pushed_at or ""), tostring(b.pushed_at or "")
        if pa ~= pb then return pa > pb end
        return AMU_FORK_KIND[amu_fork_kind(a)].rank < AMU_FORK_KIND[amu_fork_kind(b)].rank
      end)
      if #list > 0 then
        local counts, has_upstream, fork_only_count = {}, false, 0
        for _, f in ipairs(list) do
          local k = amu_fork_kind(f)
          counts[k] = (counts[k] or 0) + 1
          if k == "original" then has_upstream = true else fork_only_count = fork_only_count + 1 end
        end
        entries[#entries + 1] = {
          folder         = folder_name,
          display        = get_display_name(folder_name),
          current_repo   = data.current_repo or folder_name,
          installed_repo = data.installed_repo or data.current_repo or folder_name,
          forks          = list,
          total_forks    = #data.forks,
          has_upstream   = has_upstream,
          fork_count     = fork_only_count,
          counts         = counts,
        }
      end
    end
  end
  table.sort(entries, function(a, b) return a.display:lower() < b.display:lower() end)
  return entries
end

amu_fork_filter_text = function()
  return (config.fork_newer_only ~= false) and "Show all forks" or "Show newer forks only"
end

amu_fork_tr_text = function()
  return (config.fork_hide_translations ~= false) and "Translations: Hidden" or "Translations: Shown"
end

local function amu_count_forks(entries)
  local n = 0
  for _, e in ipairs(entries) do n = n + #e.forks end
  return n
end

-- One-line description of what the list is showing right now.
amu_fork_summary = function()
  if not amu_fork_suggestions or not amu_fork_suggestions.suggestions then
    return "No fork data yet - press Scan Now."
  end
  local shown_entries = get_fork_mod_entries()
  local shown = #shown_entries
  local all = #get_fork_mod_entries(true, true)
  local text
  if config.fork_newer_only ~= false then
    text = "Showing newer forks only: " .. shown .. " mod(s)  (" .. all .. " have any fork)"
  else
    text = "Showing every fork: " .. shown .. " mod(s)"
  end
  if config.fork_hide_translations ~= false then
    local hidden = amu_count_forks(get_fork_mod_entries(nil, true)) - amu_count_forks(shown_entries)
    if hidden > 0 then text = text .. "  [" .. hidden .. " translation(s) hidden]" end
  end
  return text
end

G.FUNCS.amu_fork_filter = function(e)
  config.fork_newer_only = (config.fork_newer_only == false) and true or false
  amu_fork_filter_label.text = amu_fork_filter_text()
  AMU_FORK_PAGE = 1
  if not amu_fork_scanning then amu_fork_status.text = amu_fork_summary() end
  amu_reopen_if_open("amu_fork_mod_list")   -- the number of pages changes, so rebuild the tab
end

G.FUNCS.amu_fork_tr_filter = function(e)
  config.fork_hide_translations = (config.fork_hide_translations == false) and true or false
  amu_fork_tr_label.text = amu_fork_tr_text()
  AMU_FORK_PAGE = 1
  if not amu_fork_scanning then amu_fork_status.text = amu_fork_summary() end
  amu_reopen_if_open("amu_fork_mod_list")
end

local function run_fork_scan()
  if amu_fork_scanning then return end
  if not is_windows() then
    amu_fork_status.text = "Windows only"
    return
  end

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)

  pcall(write_ps1_config_overlay)

  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then
    amu_fork_status.text = "Missing autoupdate.ps1!"
    return
  end

  if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
    amu_fork_status.text = "No thread support"
    return
  end

  amu_fork_scanning = true
  amu_fork_status.text = "Scanning for forks... (may take a minute)"

  local channel = love.thread.getChannel("amu_fork_scan")
  channel:clear()

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-CheckForks",
  }, " ")

  local thread_code = [[
    local cmd = ...
    local ok = pcall(function() os.execute(cmd) end)
    local ch = love.thread.getChannel("amu_fork_scan")
    ch:push(ok and "done" or "error")
  ]]
  local t = love.thread.newThread(thread_code)
  t:start(cmd)

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    func = function()
      local msg = channel:pop()
      if msg then
        amu_fork_scanning = false
        amu_fork_suggestions = load_fork_suggestions()
        amu_fork_status.text = amu_fork_summary()
        local ts = amu_fork_suggestions and amu_fork_suggestions.token_status
        if ts == "bad" then
          amu_fork_status.text = "GitHub token rejected - replace it to scan."
        elseif ts == "rate_limited" then
          amu_fork_status.text = "Stopped early (GitHub limit) - list is partial."
        end
        amu_reopen_if_open("amu_fork_mod_list")
        if G.OVERLAY_MENU and (ts == "bad" or ts == "rate_limited") then
          local has_token = config.github_token and config.github_token ~= ""
          local kind = (ts == "bad") and "bad" or (has_token and "limit_token" or "limit")
          open_overlay(G.UIDEF.amu_token_problem(kind))
        end
        return true
      end
      return false
    end
  }))
end

amu_run_fork_scan = run_fork_scan

local function switch_to_fork(folder_name, fork_repo)
  if not is_windows() then
    amu_fork_status.text = "Windows only"
    return
  end

  if not config.mod_fork_source then config.mod_fork_source = {} end
  config.mod_fork_source[folder_name] = {
    fork_repo   = fork_repo,
    switched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  pcall(write_ps1_config_overlay)

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
  local ps1 = join_path(mod_path, "autoupdate.ps1")

  if not file_exists(ps1) then
    amu_fork_status.text = "Missing autoupdate.ps1!"
    return
  end

  amu_fork_status.text = "Switching " .. folder_name .. " to fork..."

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-SwitchModName", safe_quote(folder_name),
    "-SwitchToForkRepo", safe_quote(fork_repo),
  }, " ")

  if love and love.thread and love.thread.newThread and love.thread.getChannel then
    local channel = love.thread.getChannel("amu_fork_switch")
    channel:clear()
    local thread_code = [[
      local cmd = ...
      local ok = pcall(function() os.execute(cmd) end)
      local ch = love.thread.getChannel("amu_fork_switch")
      ch:push(ok and "done" or "error")
    ]]
    local t = love.thread.newThread(thread_code)
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false,
      blocking = false,
      func = function()
        local msg = channel:pop()
        if msg then
          if msg == "done" then
            amu_fork_status.text = folder_name .. " switched to fork. Restart to apply."
          else
            amu_fork_status.text = folder_name .. " switch error. See last_run.json."
          end
          pcall(amu_update_areas, {
            ["amu_fork_mod_list"] = build_fork_mods_page(AMU_FORK_PAGE)
          })
          return true
        end
        return false
      end
    }))
  else
    os.execute(cmd)
    amu_fork_status.text = folder_name .. " switched to fork. Restart to apply."
  end
end

local function switch_back_fork(folder_name)
  if not is_windows() then
    amu_fork_status.text = "Windows only"
    return
  end

  if config.mod_fork_source then config.mod_fork_source[folder_name] = nil end
  pcall(write_ps1_config_overlay)

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
  local ps1 = join_path(mod_path, "autoupdate.ps1")

  if not file_exists(ps1) then
    amu_fork_status.text = "Missing autoupdate.ps1!"
    return
  end

  amu_fork_status.text = "Switching " .. folder_name .. " back to original..."

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-SwitchBackModName", safe_quote(folder_name),
  }, " ")

  if love and love.thread and love.thread.newThread and love.thread.getChannel then
    local channel = love.thread.getChannel("amu_fork_switchback")
    channel:clear()
    local thread_code = [[
      local cmd = ...
      local ok = pcall(function() os.execute(cmd) end)
      local ch = love.thread.getChannel("amu_fork_switchback")
      ch:push(ok and "done" or "error")
    ]]
    local t = love.thread.newThread(thread_code)
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false,
      blocking = false,
      func = function()
        local msg = channel:pop()
        if msg then
          if msg == "done" then
            amu_fork_status.text = folder_name .. " reverted to original. Restart to apply."
          else
            amu_fork_status.text = folder_name .. " revert error. See last_run.json."
          end
          pcall(amu_update_areas, {
            ["amu_fork_mod_list"] = build_fork_mods_page(AMU_FORK_PAGE)
          })
          return true
        end
        return false
      end
    }))
  else
    os.execute(cmd)
    amu_fork_status.text = folder_name .. " reverted to original. Restart to apply."
  end
end

-- Register scan button handler
G.FUNCS.amu_scan_forks = function(e)
  run_fork_scan()
end

-- Hover box for one fork: a SHORT summary of what changed (never more than ~9 lines).
local function amu_fork_tip(args)
  local fork = (args and args.fork) or {}
  local dark = G.C.UI.TEXT_DARK or RGBA(0.2, 0.2, 0.25, 1)
  local blue = G.C.BLUE or dark
  local maxw = 6.0
  local rows = {}
  local function add(text, scale, colour)
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = amu_fit(text, scale, maxw), scale = scale, colour = colour or dark } } } }
  end

  add(tostring(fork.repo or "fork"), 0.34, blue)
  local bits = { "+" .. (fork.commits_ahead or 0) .. " new commits" }
  if (fork.commits_behind or 0) > 0 then bits[#bits + 1] = (fork.commits_behind) .. " behind" end
  local pd = tostring(fork.pushed_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
  if pd then bits[#bits + 1] = "updated " .. pd end
  add(table.concat(bits, "  -  "), 0.27)

  local shown, seen = 0, {}
  if type(fork.changelog) == "table" then
    for _, m in ipairs(fork.changelog) do
      local t = amu_clean_note(m)
      if shown < 4 and not amu_is_noise(t) and not seen[t] then
        add("\226\128\162 " .. t, 0.28)
        shown = shown + 1
        seen[t] = true
      end
    end
  end
  if shown == 0 then add("(no readable change notes)", 0.27) end

  local rel = tostring(fork.latest_release_tag or "")
  if rel ~= "" then
    add("Release " .. rel, 0.3, blue)
    local notes, n = tostring(fork.latest_release_notes or ""), 0
    for line in notes:gmatch("[^\r\n]+") do
      local t = amu_clean_note(line)
      if t ~= "" and n < 2 then add("- " .. t, 0.26); n = n + 1 end
    end
  end

  return { n = G.UIT.R, config = { align = "cl", padding = 0.03 }, nodes = {
    { n = G.UIT.C, config = { align = "cl", padding = 0.03 }, nodes = rows } } }
end

local amu_fork_picker_ref = nil

G.FUNCS.amu_fork_picker_prev = function(e)
  if not amu_fork_picker_ref then return end
  amu_fork_picker_ref.page = math.max(1, (amu_fork_picker_ref.page or 1) - 1)
  open_overlay(G.UIDEF.amu_fork_picker(amu_fork_picker_ref))
end
G.FUNCS.amu_fork_picker_next = function(e)
  if not amu_fork_picker_ref then return end
  amu_fork_picker_ref.page = (amu_fork_picker_ref.page or 1) + 1
  open_overlay(G.UIDEF.amu_fork_picker(amu_fork_picker_ref))
end

-- Overlay showing the forks of a single mod: 3 per page, each with its changes, a
-- switch button and an "open page" button (GitHub etc.).
G.UIDEF.amu_fork_picker = function(ref)
  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.14, 0.14, 0.16, 0.96)
  local orange = RGBA(0.85, 0.5, 0.05, 1)

  amu_fork_picker_ref = ref
  local folder  = ref.folder  or ""
  local display = ref.display or folder
  local forks   = ref.forks   or {}

  local PER = 3
  local total_pages = math.max(1, math.ceil(#forks / PER))
  local page = math.max(1, math.min(ref.page or 1, total_pages))
  ref.page = page
  local first = (page - 1) * PER + 1
  local last  = math.min(#forks, page * PER)

  local is_switched   = config.mod_fork_source and config.mod_fork_source[folder] ~= nil
  local cur_fork_repo = is_switched and config.mod_fork_source[folder].fork_repo or nil

  local CARD_W = 8.2
  local rows = {}

  -- "Your current copy" row: lets you read about what you have BEFORE switching away from it
  local cur_links = amu_current_page_links(folder, ref.installed_repo)
  local cur_row = nil
  if #cur_links > 0 then
    local cur_nodes = {
      { n = G.UIT.C, config = { align = "cl", padding = 0.03, minw = 3.3 }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit("Your current: " .. tostring(cur_links[1].name), 0.3, 3.2), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
    }
    for ci, link in ipairs(cur_links) do
      G.FUNCS["amu_open_current_" .. ci] = function(e)
        local ok = pcall(function() love.system.openURL(link.url) end)
        amu_fork_status.text = ok and ("Opened " .. tostring(link.name) .. " in your browser.") or "Couldn't open a browser."
      end
      cur_nodes[#cur_nodes + 1] = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.3, minh = 0.4, r = 0.09,
        colour = G.C.BLUE, button = "amu_open_current_" .. ci, hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = link.label, scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } }
      cur_nodes[#cur_nodes + 1] = { n = G.UIT.B, config = { w = 0.1, h = 0.1 } }
    end
    cur_row = { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = cur_nodes }
  end

  for i = first, last do
    local fork        = forks[i]
    local slot        = i - first + 1
    local is_cur      = (cur_fork_repo == fork.repo)
    local kind        = amu_fork_kind(fork)
    local is_upstream = (kind == "original" or kind == "parent")
    local diverged    = (not is_upstream) and ((fork.commits_behind or 0) > 0) and ((fork.commits_ahead or 0) > 0)
    local is_tr       = amu_fork_is_translation(fork)
    local kind_tag    = AMU_FORK_KIND[kind].tag .. (is_tr and "  /  TRANSLATION" or "")
    local url = tostring(fork.html_url or "")
    if url == "" then url = "https://github.com/" .. tostring(fork.repo or "") end

    G.FUNCS["amu_switch_fork_" .. slot] = function(e)
      switch_to_fork(folder, fork.repo)
      G.FUNCS.amu_back_to_menu()   -- land on the Fork Finder tab again, not the main menu
    end
    G.FUNCS["amu_open_fork_" .. slot] = function(e)
      local ok = pcall(function() love.system.openURL(url) end)
      amu_fork_status.text = ok and ("Opened " .. tostring(fork.repo) .. " in your browser.") or "Couldn't open a browser."
    end

    local pushed_str = tostring(fork.pushed_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or ""
    local info_parts = { "+" .. (fork.commits_ahead or 0) .. " commits" }
    if (fork.commits_behind or 0) > 0 then
      info_parts[#info_parts + 1] = "-" .. fork.commits_behind .. (is_upstream and "" or " (diverged)")
    end
    if (fork.stars or 0) > 0 then info_parts[#info_parts + 1] = "\226\152\133 " .. fork.stars end
    if pushed_str ~= "" then info_parts[#info_parts + 1] = pushed_str end
    local info_str = amu_fit("   " .. table.concat(info_parts, "   "), 0.27, CARD_W - 0.5 - amu_text_w(kind_tag, 0.27))

    local display_name, name_colour = tostring(fork.repo or ""), G.C.UI.TEXT_LIGHT
    if is_upstream then
      name_colour = orange
    elseif diverged then
      display_name, name_colour = "\226\154\160 " .. display_name, orange
    end
    display_name = amu_fit(display_name, 0.36, CARD_W - 2.9)

    local btn_node
    if is_cur then
      btn_node = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.1, minh = 0.42, r = 0.1, colour = panel }, nodes = {
        { n = G.UIT.T, config = { text = "\226\156\147 Active", scale = 0.3, colour = G.C.GREEN } } } }
    else
      btn_node = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.1, minh = 0.42, r = 0.1,
        colour = is_upstream and orange or G.C.GREEN, button = "amu_switch_fork_" .. slot, hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = (kind == "original") and "Switch to Original" or ((kind == "parent") and "Switch to Parent" or "Switch to Fork"),
            scale = 0.27, colour = purple } } } }
    end

    local tip = { filler = { func = amu_fork_tip, args = { fork = fork } } }

    local card = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.03, minw = CARD_W - 2.5 }, nodes = {
          { n = G.UIT.T, config = { text = display_name, scale = 0.36, colour = name_colour } } } },
        btn_node,
      }},
      { n = G.UIT.R, config = { align = "cl", padding = 0.01, on_demand_tooltip = tip }, nodes = {
        { n = G.UIT.T, config = { text = kind_tag, scale = 0.27, colour = amu_fork_kind_colour(kind), shadow = true } },
        { n = G.UIT.T, config = { text = info_str, scale = 0.27, colour = purple } } } },
    }

    local shown = 0
    if type(fork.changelog) == "table" then
      local seen_msg = {}
      for _, m in ipairs(fork.changelog) do
        local t = amu_clean_note(m)
        if shown < 1 and not amu_is_noise(t) and not seen_msg[t] then
          card[#card + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.005, on_demand_tooltip = tip }, nodes = {
            { n = G.UIT.T, config = { text = amu_fit("  \226\128\162 " .. t, 0.26, CARD_W - 0.4), scale = 0.26, colour = G.C.UI.TEXT_LIGHT } } } }
          shown = shown + 1
          seen_msg[t] = true
        end
      end
    end
    if shown == 0 then
      card[#card + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.005 }, nodes = {
        { n = G.UIT.T, config = { text = "  (no readable change notes)", scale = 0.26, colour = G.C.UI.TEXT_LIGHT } } } }
    end

    -- the "open the fork's page" button, right under the changes
    local rel = tostring(fork.latest_release_tag or "")
    local open_label = "Open fork page" .. (rel ~= "" and ("     Release: " .. rel) or "")
    card[#card + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = CARD_W - 0.5, minh = 0.38, r = 0.09,
          colour = G.C.BLUE, button = "amu_open_fork_" .. slot, hover = true, shadow = true, on_demand_tooltip = tip }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit(open_label, 0.3, CARD_W - 0.8), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } } } }

    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
      { n = G.UIT.C, config = { align = "cl", padding = 0.08, minw = CARD_W, r = 0.1, colour = panel }, nodes = card } } }
  end

  if #forks == 0 then
    rows[1] = { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
      { n = G.UIT.T, config = { text = "No forks to show.", scale = 0.38, colour = purple } } } }
  end

  local footer = {}
  if total_pages > 1 then
    footer[#footer + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.8, minh = 0.42, r = 0.1,
          colour = page > 1 and G.C.BLUE or panel, button = page > 1 and "amu_fork_picker_prev" or nil,
          hover = page > 1, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "< Previous", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
      { n = G.UIT.C, config = { align = "cm", minw = 2.0 }, nodes = {
        { n = G.UIT.T, config = { text = "Forks " .. first .. "-" .. last .. " of " .. #forks, scale = 0.28, colour = purple } } } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.8, minh = 0.42, r = 0.1,
          colour = page < total_pages and G.C.BLUE or panel, button = page < total_pages and "amu_fork_picker_next" or nil,
          hover = page < total_pages, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Next >", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = 8.8, padding = 0.14, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit("Forks: " .. display, 0.5, 8.0), scale = 0.5, colour = purple, shadow = true } } } },
      cur_row or { n = G.UIT.B, config = { h = 0.02, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = rows },
      footer[1] or { n = G.UIT.B, config = { h = 0.02, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 2.4, minh = 0.5, r = 0.12,
          colour = panel, button = "amu_back_to_menu", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Back", scale = 0.38, colour = purple } } } },
        { n = G.UIT.B, config = { h = 0.1, w = 0.3 } },
        amu_close_all_node(2.6),
      }},
    }
  }
end

-- Paginated list of mods with fork suggestions.
build_fork_mods_page = function(page)
  local entries = get_fork_mod_entries()
  local total_pages = math.max(1, math.ceil(#entries / AMU_FORK_PER))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_FORK_PAGE = page

  local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)
  local orange = (G.C and G.C.ORANGE) or RGBA(0.85, 0.5, 0.05, 1)
  local rows = {}

  if #entries == 0 then
    local msg = (amu_fork_suggestions and amu_fork_suggestions.suggestions)
      and ((config.fork_newer_only ~= false) and "No newer forks found." or "No forks found.")
      or "No fork data yet. Press 'Scan Now'."
    rows[1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = {
      { n = G.UIT.T, config = { text = msg, scale = 0.36, colour = purple } } } }
    if amu_fork_suggestions and amu_fork_suggestions.suggestions and config.fork_newer_only ~= false then
      rows[2] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = {
        { n = G.UIT.T, config = { text = "Press 'Show all forks' to see older ones too.", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } }
    end
    for _ = #rows + 1, AMU_FORK_PER do
      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = {
        { n = G.UIT.B, config = { h = AMU_FORK_ROW_H - 0.04, w = AMU_FORK_W - 0.5 } } } }
    end
  else
    local start_i = (page - 1) * AMU_FORK_PER + 1
    local end_i   = math.min(#entries, page * AMU_FORK_PER)

    for i = start_i, end_i do
      local entry = entries[i]
      if entry then
        local row_i      = i - start_i + 1
        local folder     = entry.folder
        local display    = entry.display
        local fork_count = entry.fork_count or #entry.forks
        local has_upstream = entry.has_upstream
        local is_switched = config.mod_fork_source and config.mod_fork_source[folder] ~= nil

        G.FUNCS["amu_view_forks_" .. row_i] = function(e)
          open_overlay(G.UIDEF.amu_fork_picker({
            folder       = folder,
            display      = display,
            forks        = entry.forks,
            current_repo = entry.current_repo,
            installed_repo = entry.installed_repo,
          }))
        end

        G.FUNCS["amu_switch_back_fork_" .. row_i] = function(e)
          switch_back_fork(folder)
        end

        G.FUNCS["amu_page_current_" .. row_i] = function(e)
          local links = amu_current_page_links(folder, entry.installed_repo)
          if not links[1] then amu_fork_status.text = "No page known for " .. display .. "." return end
          local ok = pcall(function() love.system.openURL(links[1].url) end)
          amu_fork_status.text = ok and ("Opened " .. tostring(links[1].name) .. " in your browser.") or "Couldn't open a browser."
        end

        local label_parts = {}
        local counts = entry.counts or {}
        for _, k in ipairs({ "original", "parent", "parent_fork", "fork_fork", "fork" }) do
          local n = counts[k] or 0
          if n > 0 then
            local w = AMU_FORK_KIND[k].word
            if k == "original" or k == "parent" then
              label_parts[#label_parts + 1] = w:sub(1, 1):upper() .. w:sub(2)
            else
              label_parts[#label_parts + 1] = n .. " " .. w .. (n == 1 and "" or "s")
            end
          end
        end
        local fork_label = amu_fit(table.concat(label_parts, " + "), 0.28, 3.4)
        local label_colour = has_upstream and orange or (is_switched and G.C.GREEN or G.C.UI.TEXT_LIGHT)

        local action_btn
        if is_switched then
          action_btn = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.8, minh = 0.4, r = 0.09,
            colour = G.C.RED, button = "amu_switch_back_fork_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "Switch Back", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } }
        else
          action_btn = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.8, minh = 0.4, r = 0.09,
            colour = G.C.BLUE, button = "amu_view_forks_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "View Forks", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } }
        end

        rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = {
          { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 3.2 }, nodes = {
            { n = G.UIT.T, config = { text = amu_fit(display, 0.4, 3.1), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } } } },
          { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 3.4 }, nodes = {
            { n = G.UIT.T, config = { text = fork_label, scale = 0.28, colour = label_colour } } } },
          { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.0, minh = 0.4, r = 0.09,
            colour = G.C.BLUE, button = "amu_page_current_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "Page", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
          action_btn,
        }}
      end
    end

    local shown = math.max(0, end_i - start_i + 1)
    for _ = shown + 1, AMU_FORK_PER do
      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = {
        { n = G.UIT.B, config = { h = AMU_FORK_ROW_H - 0.04, w = AMU_FORK_W - 0.5 } } } }
    end
  end

  return amu_list_root(rows, AMU_FORK_W, AMU_FORK_H)
end

local AMU_PROMPT = { title = "Mod Updater", lines = {}, has_updates = false }

local function sanitize_line(s)
  s = tostring(s or "")
  s = s:gsub("\t", "  ")
  s = s:gsub("\r", "")
  s = s:gsub("\n", " ")
  s = s:gsub("%s%s%s+", "  ")
  return s
end

local function wrap_line(s, max_chars)
  s = sanitize_line(s)
  max_chars = max_chars or 58
  local out = {}
  while #s > max_chars do
    local cut = max_chars
    for i = max_chars, math.max(20, max_chars - 18), -1 do
      if s:sub(i, i) == " " then cut = i; break end
    end
    table.insert(out, (s:sub(1, cut):gsub("%s+$","")))
    s = s:sub(cut + 1):gsub("^%s+","")
  end
  if #s > 0 then table.insert(out, s) end
  return out
end

local function wrap_lines(lines, max_chars)
  local out = {}
  for _, line in ipairs(lines) do
    local parts = wrap_line(line, max_chars)
    for _, p in ipairs(parts) do table.insert(out, p) end
  end
  return out
end

local function build_prompt_lines(summary)
  local lines = {}
  local updated = summary.updated_mods or {}
  local errors = summary.errors or {}
  local skipped = summary.skipped_mods or {}

  if #updated > 0 then
    table.insert(lines, "Updated " .. tostring(#updated) .. " mod(s):")
    for i = 1, math.min(#updated, 30) do table.insert(lines, "    " .. tostring(updated[i])) end
    if #updated > 30 then table.insert(lines, "    ...") end
    table.insert(lines, "")
    table.insert(lines, "Restart recommended so Balatro loads the new files.")
    table.insert(lines, "")
  end

  if #errors > 0 then
    table.insert(lines, "Errors (" .. tostring(#errors) .. "):")
    for i = 1, math.min(#errors, 20) do table.insert(lines, "    " .. tostring(errors[i])) end
    if #errors > 20 then table.insert(lines, "    ...") end
    table.insert(lines, "")
  end

  local available = summary.available_updates or {}
  if #available > 0 then
    table.insert(lines, "Updates to download yourself (" .. tostring(#available) .. "):")
    for i = 1, math.min(#available, 10) do table.insert(lines, "    " .. tostring(available[i])) end
    table.insert(lines, "")
  end

  if summary.framework_staged then
    table.insert(lines, "Steamodded/Lovely update ready - click Restart now.")
    table.insert(lines, "")
  end

  local untracked = summary.untracked_mods or {}
  if #untracked > 0 and (#updated > 0 or #errors > 0) and config.show_untracked_note ~= false then
    table.insert(lines, tostring(#untracked) .. " mod(s) have no git/update.json and are never")
    table.insert(lines, "checked. Add links in the 'No Source' tab.")
    table.insert(lines, "")
  end

  if #skipped > 0 and #updated == 0 then
    -- Mods you switched off are just counted; only show skips that tell you something.
    local shown, off = {}, 0
    for _, v in ipairs(skipped) do
      local sv = tostring(v)
      if sv:find("(updates disabled)", 1, true) or sv:find("[Framework debug]", 1, true) then
        off = off + 1
      else
        shown[#shown+1] = sv
      end
    end
    if #shown > 0 then
      table.insert(lines, "Notes (" .. tostring(#shown) .. "):")
      for i = 1, math.min(#shown, 20) do table.insert(lines, "    " .. shown[i]) end
      if #shown > 20 then table.insert(lines, "    ...") end
    end
    if off > 0 then
      table.insert(lines, tostring(off) .. " mod(s) have updates turned off.")
    end
  end

  if #lines == 0 then table.insert(lines, "No mod updates were applied.") end
  return wrap_lines(lines, 46)
end

function show_prompt(summary)
  local updated = summary and summary.updated_mods or {}
  local errors = summary and summary.errors or {}
  local available = summary and summary.available_updates or {}
  local fw = summary and summary.framework_staged == true
  local should = (#updated > 0) or fw or (#available > 0) or ((config.prompt_on_errors ~= false) and (#errors > 0))
  if not should then return end

  AMU_PROMPT.title = "Mod Updater"
  AMU_PROMPT.lines = build_prompt_lines(summary)
  AMU_PROMPT.has_updates = (#updated > 0) or fw

  AMU_PROMPT.page = 1
  open_overlay(G.UIDEF.amu_restart_prompt(AMU_PROMPT))
end

-- The results window shows a fixed number of lines per page so it always fits on
-- screen, with the Restart/Later buttons right under the title (they used to sit at
-- the bottom and get pushed off-screen by long results).
local AMU_PROMPT_PAGE_SIZE = 12

G.UIDEF.amu_restart_prompt = function(ref)
  local purple = (G.C and (G.C.PURPLE or (G.C.UI and G.C.UI.PURPLE))) or RGBA(0.62, 0.33, 0.92, 1)
  local bg    = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel = RGBA(0.12, 0.12, 0.12, 0.96)

  local lines = ref.lines or {}
  local page_size = AMU_PROMPT_PAGE_SIZE
  local pages = math.max(1, math.ceil(#lines / page_size))
  ref.page = math.max(1, math.min(tonumber(ref.page) or 1, pages))
  local first = (ref.page - 1) * page_size + 1
  local last = math.min(#lines, first + page_size - 1)

  local max_len = 0
  for i = 1, #lines do
    local s = tostring(lines[i] or "")
    if #s > max_len then max_len = #s end
  end

  local w = math.min(15.5, math.max(10.0, 6.4 + max_len * 0.11))
  local line_h = 0.42
  -- same height on every page so the window doesn't jump around
  local content_h = math.max(1.9, math.min(#lines, page_size) * line_h + 0.3)

  local text_rows = {}
  for i = first, last do
    text_rows[#text_rows+1] = {
      n = G.UIT.R,
      config = { align = "cl", padding = 0.01 },
      nodes = {
        { n = G.UIT.T, config = { text = tostring(lines[i]), scale = 0.4, colour = purple } }
      }
    }
  end

  local function btn(label, func, colour, minw)
    return { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = minw or 3.0, minh = 0.75, r = 0.15, colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.5, colour = purple } }
    }}
  end
  local gap = { n = G.UIT.B, config = { h = 0.1, w = 0.3 } }

  local buttons_row = { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {} }
  if ref.has_updates and (config.prompt_restart ~= false) then
    buttons_row.nodes = { btn("Restart now", "amu_restart_now", G.C.GREEN, 3.6), gap, btn("Later", "amu_close_prompt", panel, 2.6) }
  else
    buttons_row.nodes = { btn("OK", "amu_close_prompt", panel, 3.0) }
  end

  local nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.T, config = { text = ref.title or "Mod Updater", scale = 0.65, colour = purple, shadow = true } }
    }},
    buttons_row,
    { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
      { n = G.UIT.C, config = { align = "tl", padding = 0.10, minw = w - 1.0, minh = content_h, r = 0.16, colour = panel }, nodes = text_rows }
    }},
  }

  if pages > 1 then
    nodes[#nodes+1] = { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      btn("< Prev", "amu_prompt_prev", ref.page > 1 and panel or bg, 2.2), gap,
      { n = G.UIT.C, config = { align = "cm", minw = 2.4 }, nodes = {
        { n = G.UIT.T, config = { text = "Page " .. ref.page .. " / " .. pages, scale = 0.45, colour = purple } }
      }}, gap,
      btn("Next >", "amu_prompt_next", ref.page < pages and panel or bg, 2.2),
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = w, padding = 0.2, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = nodes
  }
end

local function amu_prompt_goto(delta)
  local pages = math.max(1, math.ceil(#(AMU_PROMPT.lines or {}) / AMU_PROMPT_PAGE_SIZE))
  local target = math.max(1, math.min(pages, (AMU_PROMPT.page or 1) + delta))
  if target == AMU_PROMPT.page then return end
  AMU_PROMPT.page = target
  close_overlay()
  open_overlay(G.UIDEF.amu_restart_prompt(AMU_PROMPT))
end
function G.FUNCS.amu_prompt_next(e) amu_prompt_goto(1) end
function G.FUNCS.amu_prompt_prev(e) amu_prompt_goto(-1) end

function G.FUNCS.amu_close_prompt(e) close_overlay() end
function G.FUNCS.amu_restart_now(e)
  close_overlay()

  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)

  local pending_file = join_path(mod_path, config.framework_pending_file or "pending_apply.json")
  local apply_script  = join_path(mod_path, config.framework_apply_script or "apply_pending.ps1")

  if file_exists(pending_file) and file_exists(apply_script) then
    local cmd = table.concat({
      "powershell","-NoProfile","-ExecutionPolicy","Bypass",
      "-File", safe_quote(winpath(apply_script)),
      "-SelfDir", safe_quote(winpath(mod_path)),
      "-SteamAppId", safe_quote(tostring(config.steam_appid or "2379780")),
      "-WaitProcessName", safe_quote("Balatro"),
    }, " ")
    os.execute('start "" ' .. cmd)
    love.event.quit()
    return
  end

  if config.auto_relaunch_via_steam ~= false and config.steam_appid then
    local url = "steam://rungameid/" .. tostring(config.steam_appid)
    os.execute('start "" "' .. url .. '"')
  end
  love.event.quit()
end

local function read_summary(mod_path)
  local summary_path = join_path(mod_path, "last_run.json")
  if not file_exists(summary_path) then return nil end
  local data = read_all(summary_path)
  if not data then return nil end
  return decode_json(data)
end

-- Write the launch sentinel so PS1 knows the game started successfully after
-- the most recent update run (used for crash detection on the next PS1 run).
local function write_launch_sentinel(mod_path)
  if not is_windows() then return end
  if not mod_path or mod_path == "" then return end
  pcall(function()
    local f = io.open(join_path(mod_path, "_launch_sentinel"), "wb")
    if f then
      f:write(os.date("!%Y-%m-%dT%H:%M:%SZ"))
      f:close()
    end
  end)
end

-- Called after every full (non-single-mod) PS1 run completes.
-- Writes the launch sentinel, processes any crash rollback report, and shows
-- the appropriate in-game notification to the user.
on_full_update_done = function(mod_path)
  -- (The sentinel is now written when the main menu is reached, not here.)

  -- Process crash rollback report (written by PS1 when it detects a crash)
  local rollback_mods = {}
  local report_path = join_path(mod_path, "_crash_rollback_report.json")
  if file_exists(report_path) then
    local data = read_all(report_path)
    pcall(function() os.remove(report_path) end)
    local report = data and decode_json(data)
    if report and report.mods then
      for _, entry in ipairs(report.mods) do
        if entry.mod_name then
          if not entry.error then
            rollback_mods[#rollback_mods + 1] = tostring(entry.mod_name)
            -- Sync the rollback pin into the Lua runtime config so the UI
            -- shows the correct pinned state and write_ps1_config_overlay
            -- preserves it on the next write.
            config.mod_pinned = config.mod_pinned or {}
            config.mod_update_enabled = config.mod_update_enabled or {}
            config.mod_pinned[entry.mod_name] = {
              pinned = true,
              backup_file = tostring(entry.backup_file or ""),
              pinned_at = tostring(report.rolled_back_at or os.date("!%Y-%m-%dT%H:%M:%SZ")),
              auto_rolled_back = true,
            }
            config.mod_update_enabled[entry.mod_name] = false
          end
        end
      end
      if #rollback_mods > 0 then
        pcall(write_ps1_config_overlay)
      end
    end
  end

  local summary = read_summary(mod_path)

  if #rollback_mods > 0 then
    -- Show crash notification (with optional update info appended)
    local lines = {
      "Crash detected! The following mod(s) caused",
      "a startup crash and were reverted to their",
      "previous version and pinned:",
      "",
    }
    for _, name in ipairs(rollback_mods) do
      lines[#lines + 1] = "  " .. name
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "These mods won't update until you manually"
    lines[#lines + 1] = "unpin them in Mod Updater settings."
    if summary and #(summary.updated_mods or {}) > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Also updated " .. #summary.updated_mods .. " other mod(s)."
    end
    if summary and #(summary.errors or {}) > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Update errors: " .. #(summary.errors or {})
    end
    AMU_PROMPT.title    = "Mod Updater - Crash Detected"
    AMU_PROMPT.lines    = wrap_lines(lines, 46)
    AMU_PROMPT.page = 1
    AMU_PROMPT.has_updates = (summary ~= nil and (#(summary.updated_mods or {}) > 0 or summary.framework_staged == true))
    open_overlay(G.UIDEF.amu_restart_prompt(AMU_PROMPT))
  elseif summary then
    show_prompt(summary)
  end
end

---------------------------------------------------------------------------
-- "Shuffling mods..." placement on the main menu
-- The line sits between the Balatro logo and the main menu buttons. While it's
-- showing, the main menu bar (with the language box) and the Profile button
-- slide down a little to make room, then slide back when the check is done.
---------------------------------------------------------------------------
local AMU_LOADING = { box = nil, shift = 0, waiting = false }
local AMU_MENU_SHIFT = 0.45   -- how far the bottom menus move down (Balatro units)
local AMU_TEXT_RAISE = 0.015   -- lift the text above the logo/menu midpoint, as a share of screen height

local function amu_shift_menus(dy)
  for _, box in ipairs({ G.MAIN_MENU_UI, G.PROFILE_BUTTON }) do
    if box and box.alignment and box.alignment.offset then
      box.alignment.offset.y = (box.alignment.offset.y or 0) + dy
      pcall(function() box:align_to_major() end)
    end
  end
end

-- Fraction (0..1) of the logo sprite's height where its lowest visible pixel is.
-- Logos from texture packs often have empty space at the bottom, so we look at the
-- actual pixels instead of the sprite's box. Cached per atlas image.
local amu_logo_frac_cache = {}
local function amu_logo_visible_frac()
  local atlas = G.ASSET_ATLAS and G.ASSET_ATLAS["balatro"]
  if not atlas then return 1 end
  local key = tostring(atlas.image or atlas)
  if amu_logo_frac_cache[key] then return amu_logo_frac_cache[key] end
  local frac = 1
  pcall(function()
    local data = atlas.image_data
    if not data and atlas.full_path then data = love.image.newImageData(atlas.full_path) end
    if not data and atlas.path then data = love.image.newImageData(atlas.path) end
    if not data then return end
    local w, h = data:getWidth(), data:getHeight()
    local step = math.max(1, math.floor(w / 200))
    for y = h - 1, 0, -1 do
      for x = 0, w - 1, step do
        local _, _, _, a = data:getPixel(x, y)
        if a > 0.25 then frac = (y + 1) / h; return end
      end
    end
  end)
  amu_logo_frac_cache[key] = frac
  return frac
end

-- Top edge of the actual Play/Collection/Options bar (not the whole menu block,
-- whose top is set by the taller Discord/X + language column on the right).
local function amu_menu_bar_top()
  local menu = G.MAIN_MENU_UI
  if not menu then return nil end
  local play = menu.get_UIE_by_ID and menu:get_UIE_by_ID('main_menu_play')
  local node = play
  while node do
    if node.config and node.config.mid then return node.T.y end
    node = node.parent
  end
  if play and play.T then return play.T.y - 0.2 end
  return menu.T.y
end

local function amu_place_loading()
  local box, room = AMU_LOADING.box, G.ROOM_ATTACH
  if not (box and room and box.T and box.alignment) then return end
  local bar_top = amu_menu_bar_top()
  if not bar_top then return end
  local logo_bottom
  if G.SPLASH_LOGO and G.SPLASH_LOGO.T then
    logo_bottom = G.SPLASH_LOGO.T.y + G.SPLASH_LOGO.T.h * amu_logo_visible_frac()
  else
    logo_bottom = bar_top - 2
  end
  -- Centre the text halfway between the two. Measure where it really is and nudge,
  -- so this stays right whatever the alignment maths does.
  local raise = AMU_TEXT_RAISE * ((G.ROOM and G.ROOM.T and G.ROOM.T.h) or 11.5)
  local want_centre = (logo_bottom + bar_top) / 2 - raise
  local have_centre = box.T.y + box.T.h / 2
  local err = want_centre - have_centre
  if math.abs(err) > 0.005 then
    -- half-steps: converges smoothly even if the box's position updates a frame late
    box.alignment.offset.y = (box.alignment.offset.y or 0) + err * 0.5
    pcall(function() box:align_to_major() end)
  end
end

local function amu_show_loading(ref)
  AMU_LOADING.waiting = true
  G.E_MANAGER:add_event(Event({
    blockable = false, blocking = false, no_delete = true,
    func = function()
      if not AMU_LOADING.waiting then return true end
      -- wait until the main menu has slid in (it appears a few seconds after start-up)
      if not (G.MAIN_MENU_UI and G.ROOM_ATTACH and G.STAGE == G.STAGES.MAIN_MENU) then return false end
      local ok = pcall(function()
        AMU_LOADING.box = UIBox{
          definition = G.UIDEF.amu_loading_box(ref),
          config = { align = "bmi", offset = { x = 0, y = 0 }, major = G.ROOM_ATTACH, bond = "Weak" }
        }
      end)
      if not ok then AMU_LOADING.box = nil; return true end
      amu_shift_menus(AMU_MENU_SHIFT)
      AMU_LOADING.shift = AMU_MENU_SHIFT
      amu_place_loading()
      return true
    end
  }))
  -- keep the text glued above the menu while it settles (Profile button arrives a frame later)
  G.E_MANAGER:add_event(Event({
    blockable = false, blocking = false, no_delete = true,
    func = function()
      if not AMU_LOADING.waiting then return true end
      if AMU_LOADING.box then
        if G.PROFILE_BUTTON and not AMU_LOADING.profile_shifted and AMU_LOADING.shift ~= 0 then
          -- Profile button is created one frame after the menu; give it the same shift
          if (G.PROFILE_BUTTON.alignment.offset.y or 0) < AMU_LOADING.shift then
            G.PROFILE_BUTTON.alignment.offset.y = (G.PROFILE_BUTTON.alignment.offset.y or 0) + AMU_LOADING.shift
            pcall(function() G.PROFILE_BUTTON:align_to_major() end)
          end
          AMU_LOADING.profile_shifted = true
        end
        amu_place_loading()
      end
      return false
    end
  }))
end

local function amu_hide_loading()
  AMU_LOADING.waiting = false
  if AMU_LOADING.box then
    pcall(function() AMU_LOADING.box:remove() end)
    AMU_LOADING.box = nil
  end
  if AMU_LOADING.shift ~= 0 then
    if G.STAGE == G.STAGES.MAIN_MENU then
      if G.MAIN_MENU_UI and G.MAIN_MENU_UI.alignment then
        G.MAIN_MENU_UI.alignment.offset.y = (G.MAIN_MENU_UI.alignment.offset.y or 0) - AMU_LOADING.shift
        pcall(function() G.MAIN_MENU_UI:align_to_major() end)
      end
      if G.PROFILE_BUTTON and G.PROFILE_BUTTON.alignment and AMU_LOADING.profile_shifted then
        G.PROFILE_BUTTON.alignment.offset.y = (G.PROFILE_BUTTON.alignment.offset.y or 0) - AMU_LOADING.shift
        pcall(function() G.PROFILE_BUTTON:align_to_major() end)
      end
    end
    AMU_LOADING.shift = 0
    AMU_LOADING.profile_shifted = false
  end
end

local function run_update_async(mods_dir, mod_path)
  pcall(write_ps1_config_overlay)

  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then
    show_msg("Mod Updater", "Missing autoupdate.ps1 in:\n" .. tostring(mod_path), {"OK"}, "error")
    return
  end

  local pending_file = join_path(mod_path, config.framework_pending_file or "pending_apply.json")
  local apply_script  = join_path(mod_path, config.framework_apply_script or "apply_pending.ps1")
  if (config.framework_apply_on_launch ~= false) and file_exists(pending_file) and file_exists(apply_script) then
    local cmd = table.concat({
      "powershell","-NoProfile","-ExecutionPolicy","Bypass",
      "-File", safe_quote(winpath(apply_script)),
      "-SelfDir", safe_quote(winpath(mod_path)),
      "-SteamAppId", safe_quote(tostring(config.steam_appid or "2379780")),
      "-WaitProcessName", safe_quote("Balatro"),
    }, " ")

    local dbg = {
      started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      mod_path = mod_path,
      mods_dir = mods_dir,
      ps1 = ps1,
      config_path = join_path(mod_path, "autoupdater_config.json"),
      cmd = cmd,
    }
    pcall(function()
      local f = io.open(join_path(mod_path, "launcher_debug.json"), "wb")
      if f then f:write(encode_json(dbg)); f:close() end
    end)
    os.execute('start "" ' .. cmd)
    love.event.quit()
    return
  end

  if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
    local cmd = table.concat({
      "powershell","-NoProfile","-ExecutionPolicy","Bypass",
      "-File", safe_quote(winpath(ps1)),
      "-ModsDir", safe_quote(winpath(mods_dir)),
      "-SelfDir", safe_quote(winpath(mod_path)),
    }, " ")
    os.execute(cmd)
    on_full_update_done(mod_path)
    return
  end

  local ref = { text = "Shuffling mods...", suits = "♠  ♥  ♦  ♣" }
  local channel = love.thread.getChannel("amu_update_status")
  channel:clear()

  local cmd = table.concat({
    "powershell","-NoProfile","-ExecutionPolicy","Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
  }, " ")

  local thread_code = [[
    local cmd = ...
    local ok = pcall(function() os.execute(cmd) end)
    local ch = love.thread.getChannel("amu_update_status")
    ch:push(ok and "done" or "error")
  ]]
  local t = love.thread.newThread(thread_code)
  t:start(cmd)

  if config.show_loading_overlay ~= false then
    amu_show_loading(ref)
  end

  local start_time = love.timer and love.timer.getTime and love.timer.getTime() or 0
  local dots = 0

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true, -- survive the event-queue wipe when you start a run mid-check
    func = function()

      local msg = channel:pop()
      if msg then
        amu_hide_loading()
        on_full_update_done(mod_path)
        return true
      end

      if love.timer and love.timer.getTime and (love.timer.getTime() - start_time) > (tonumber(config.ui_timeout_seconds) or 300) then
        amu_hide_loading()
        show_msg("Mod Updater", "Updater timed out waiting for PowerShell.\nYou can still play.", {"OK"}, "warning")
        return true
      end
      return false
    end
  }))
end

if is_windows() and (config.auto_run ~= false) then
  if G and G.E_MANAGER and Event then
    G.E_MANAGER:add_event(Event({
      trigger = "after",
      delay = 0.4,
      blockable = false,
      blocking = false,
      func = function()
        local save_dir = love.filesystem.getSaveDirectory()
        local mods_dir = join_path(save_dir, "Mods")
        local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
        run_update_async(mods_dir, mod_path)
        return true
      end
    }))
  end
end
