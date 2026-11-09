-- Mod Updater (Steamodded) v1.0.0
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
AMU_RUN = function(c) return os.execute(c) end
AMU_HIDE_SRC = "local function amu_run(c) return os.execute(c) end\n"
do
  local mp = mod and mod.path
  if mp and mp ~= "" then
    -- Crash recovery screen for crashes BEFORE the main menu (crash_guard.lua). Lovely normally loads it at the very
    -- start of the game (lovely.toml); load it here too in case that did not happen. Tell it where this folder is.
    pcall(function()
      if not (AMU_CRASH_GUARD and AMU_CRASH_GUARD.installed) then dofile(join_path(mp, "crash_guard.lua")) end
      if AMU_CRASH_GUARD then AMU_CRASH_GUARD.mod_dir = (tostring(mp):gsub("[/\\]+$", "")) end
    end)
    -- Run a command with no window (see crash_guard.lua). AMU_HIDE_SRC is the same function as source text, put in
    -- front of the worker threads' code (a thread is a separate Lua state).
    AMU_RUN = (AMU_CRASH_GUARD and AMU_CRASH_GUARD.run_hidden) or function(c) return os.execute(c) end
    AMU_HIDE_SRC = (AMU_CRASH_GUARD and AMU_CRASH_GUARD.RUNNER_SRC) or "local function amu_run(c) return os.execute(c) end\n"
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
        if AMU_CRASH_GUARD then AMU_CRASH_GUARD.reached_menu = true end   -- crashes from now on get the normal report
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
-- CRASH RECOVERY - data side
-- When the game does not reach the main menu after an update, the mods that were
-- updated are kept in _crash_pending.json until the player answers: put them all
-- back / choose which / keep them. The screens and actions are further down.
-- Everything lives in this ONE table because Lua allows only 200 top-level locals per file.
---------------------------------------------------------------------------
local AMU_CRASH = {
  mods = {},          -- waiting for an answer: list of { mod_name, backup_file, updated_to_version, updated_at }
  sel = {},           -- picker check boxes: sel[mod_name] == true means "put this one back"
  page = 1,           -- picker page
  busy = false,       -- a put-back is running
  shown = false,      -- the question was already put on screen this session
  in_flight = false,  -- an update run is going; the question waits for it
  extra_note = nil,   -- line under the question, e.g. "Also updated 2 other mod(s) just now."
}

function AMU_CRASH.path(name) return join_path(amu_mod_path(), name) end

-- The JSON files hold a list, but PowerShell writes a one-item list as a single object. Accept both.
function AMU_CRASH.as_list(v)
  if type(v) == "string" then return { v } end
  if type(v) ~= "table" then return {} end
  if v.mod_name ~= nil then return { v } end
  return v
end

function AMU_CRASH.clean_entry(e)
  if type(e) ~= "table" or type(e.mod_name) ~= "string" or e.mod_name == "" then return nil end
  return {
    mod_name = e.mod_name,
    backup_file = type(e.backup_file) == "string" and e.backup_file or "",
    updated_to_version = (e.updated_to_version ~= nil) and tostring(e.updated_to_version) or "",
    updated_at = type(e.updated_at) == "string" and e.updated_at or "",
  }
end

-- _crash_pending.json -> list of clean entries
function AMU_CRASH.read_pending()
  local out = {}
  local data = decode_json(read_all(AMU_CRASH.path("_crash_pending.json")) or "")
  if type(data) == "table" then
    for _, e in ipairs(AMU_CRASH.as_list(data.mods)) do
      local c = AMU_CRASH.clean_entry(e)
      if c then out[#out + 1] = c end
    end
  end
  return out
end

function AMU_CRASH.write_json(name, value)
  local f = io.open(AMU_CRASH.path(name), "wb")
  if not f then return false end
  f:write(encode_json(value))
  f:close()
  return true
end

function AMU_CRASH.write_pending(list)
  return AMU_CRASH.write_json("_crash_pending.json", { detected_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), mods = list })
end

-- At load time: "the last launch never reached the menu" (autoupdate.ps1 left _crash_flag next to the list of mods
-- it updated) becomes a pending question. Nothing is reverted here; the player decides on the main menu.
-- Done here, in Lua, so it works even when the auto-check at startup is off.
function AMU_CRASH.park_at_load()
  local flag, recent = AMU_CRASH.path("_crash_flag"), AMU_CRASH.path("_recently_updated.json")
  if not (file_exists(flag) and file_exists(recent)) then return end
  local data = decode_json(read_all(recent) or "")
  if type(data) ~= "table" then return end      -- unreadable: leave it for autoupdate.ps1
  local merged, index = {}, {}
  for _, e in ipairs(AMU_CRASH.read_pending()) do
    merged[#merged + 1] = e
    index[e.mod_name] = #merged
  end
  for _, e in ipairs(AMU_CRASH.as_list(data)) do
    local c = AMU_CRASH.clean_entry(e)
    if c then
      if index[c.mod_name] then
        merged[index[c.mod_name]] = c
      else
        merged[#merged + 1] = c
        index[c.mod_name] = #merged
      end
    end
  end
  if AMU_CRASH.write_pending(merged) then
    pcall(os.remove, recent)
    pcall(os.remove, flag)
  end
end
pcall(AMU_CRASH.park_at_load)

-- Keep these mods as suspects: the next launch tests them again, and asks again if that one fails too.
function AMU_CRASH.rearm(list)
  if not AMU_CRASH.write_json("_recently_updated.json", list) then return false end
  for _, n in ipairs({ "_launch_attempt", "_launch_sentinel", "_crash_flag" }) do pcall(os.remove, AMU_CRASH.path(n)) end
  return true
end

-- Reload what is waiting for an answer. Returns how many mods are waiting.
function AMU_CRASH.load()
  local list = AMU_CRASH.read_pending()
  table.sort(list, function(a, b) return a.mod_name:lower() < b.mod_name:lower() end)
  AMU_CRASH.mods = list
  local known = {}
  for _, e in ipairs(list) do
    known[e.mod_name] = true
    if AMU_CRASH.sel[e.mod_name] == nil then AMU_CRASH.sel[e.mod_name] = true end   -- everything ticked at first
  end
  for k in pairs(AMU_CRASH.sel) do
    if not known[k] then AMU_CRASH.sel[k] = nil end
  end
  return #list
end

-- "2026-10-17 18:30" from the ISO time autoupdate.ps1 writes
function AMU_CRASH.when(e)
  local y, mo, d, h, mi = tostring(e.updated_at or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)")
  if y then return y .. "-" .. mo .. "-" .. d .. " " .. h .. ":" .. mi end
  return ""
end

-- short version text: a long commit id becomes its first 7 characters
function AMU_CRASH.ver(e)
  local v = tostring(e.updated_to_version or "")
  if v:match("^%x+$") and #v > 7 then v = v:sub(1, 7) end
  if #v > 14 then v = v:sub(1, 13) .. ".." end
  return v
end

function AMU_CRASH.detail(e)
  local parts = {}
  local v, w = AMU_CRASH.ver(e), AMU_CRASH.when(e)
  if v ~= "" then parts[#parts + 1] = "now " .. v end
  if w ~= "" then parts[#parts + 1] = "updated " .. w end
  return table.concat(parts, "   ")
end

function AMU_CRASH.label(e)
  local d = AMU_CRASH.detail(e)
  local nm = (e.mod_name == "smods" and "Steamodded") or (e.mod_name == "lovely" and "Lovely") or e.mod_name
  if d == "" then return nm end
  return nm .. "   (" .. d .. ")"
end

-- Apply a put-back report (_crash_rollback_report.json) to this mod's own settings: the put-back mods are pinned and
-- their updates are off. Returns three lists: put back, could not be put back (with the reason), kept as they are.
function AMU_CRASH.apply_report(report)
  local reverted, failed, kept = {}, {}, {}
  if type(report) ~= "table" then return reverted, failed, kept end
  config.mod_pinned = config.mod_pinned or {}
  config.mod_update_enabled = config.mod_update_enabled or {}
  for _, entry in ipairs(AMU_CRASH.as_list(report.mods)) do
    if type(entry) == "table" and entry.mod_name then
      if entry.error then
        failed[#failed + 1] = tostring(entry.mod_name) .. " - " .. tostring(entry.error)
      else
        reverted[#reverted + 1] = tostring(entry.mod_name)
        if entry.mod_name == "smods" or entry.mod_name == "lovely" then
          -- Steamodded / Lovely are pinned in their own list (they are not normal mods)
          config.framework_pins = config.framework_pins or {}
          config.framework_pins[entry.mod_name] = {
            pinned = true,
            backup_file = tostring(entry.backup_file or ""),
            pinned_at = tostring(report.rolled_back_at or os.date("!%Y-%m-%dT%H:%M:%SZ")),
            auto_rolled_back = true,
          }
        else
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
  end
  for _, n in ipairs(AMU_CRASH.as_list(report.kept)) do kept[#kept + 1] = tostring(n) end
  return reverted, failed, kept
end

-- autoupdate.ps1 releases a pin when the mod's source serves a version other than the one that was put back (_pin_released.json).
-- Drop those pins from this mod's own lists so the mod is updated (to the latest version) again.
function AMU_CRASH.adopt_pin_releases()
  local pth = AMU_CRASH.path("_pin_released.json")
  local data = decode_json(read_all(pth) or "")
  if type(data) ~= "table" then return end
  config.mod_update_enabled = config.mod_update_enabled or {}
  for _, e in ipairs(AMU_CRASH.as_list(data)) do
    if type(e) == "table" and e.mod_name then
      local n = tostring(e.mod_name)
      if n == "smods" or n == "lovely" then
        if config.framework_pins then config.framework_pins[n] = nil end
      else
        if config.mod_pinned then config.mod_pinned[n] = nil end
        config.mod_update_enabled[n] = true
      end
    end
  end
  pcall(os.remove, pth)
end

-- A put-back made while the game was closed ("Undo last update.bat") saved its pins only in autoupdater_config.json.
-- Adopt them before anything rewrites that file from this mod's own settings (see write_ps1_config_overlay).
function AMU_CRASH.adopt_report_pins_at_load()
  local data = decode_json(read_all(AMU_CRASH.path("_crash_rollback_report.json")) or "")
  if type(data) == "table" then AMU_CRASH.apply_report(data) end
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
  ["lovely"] = true,        -- Lovely's own data folder (dumps, logs), not a mod
  [mod_folder_name] = true,
  ["_Balatro-Mod-Updater_Backups"] = true,
}

-- Subset of always_skip that should appear in skip_folders in the generated config.
-- The updater's own folder is excluded so it can self-update via git/GitHub releases.
local config_always_skip = {
  ["smods"] = true,
  ["lovely"] = true,
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

pcall(AMU_CRASH.adopt_pin_releases)   -- before scan_mods_and_init_config, which keeps pinned mods switched off
pcall(scan_mods_and_init_config)
-- A put-back made while the game was closed ("Undo last update.bat") saved its pins only in autoupdater_config.json.
-- Adopt them now, before anything rewrites that file from this mod's own settings.
pcall(AMU_CRASH.adopt_report_pins_at_load)

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
    framework_pins = (function()
      local out = {}
      for name, info in pairs(config.framework_pins or {}) do
        if type(info) == "table" and info.pinned then
          if name ~= "_game" then out[name] = { pinned = true, backup_file = info.backup_file or "", pinned_at = info.pinned_at or "" } end
        end
      end
      return out
    end)(),
    pin_retry_newer = config.cfg_pin_retry ~= false,
    game_backup = config.cfg_game_backup ~= false,
    game_auto_switch = config.cfg_game_auto_switch ~= false,
    allow_updates_on_backup_game = config.cfg_allow_updates_on_backup == true,
    fork_ignore_mods = (function()
      local out = {}
      for name, on in pairs(config.fork_ignored_mods or {}) do if on == true then out[#out + 1] = tostring(name) end end
      table.sort(out)
      return out
    end)(),
    fork_ignore = (function()
      local out = {}
      for repo, on in pairs(config.fork_ignored or {}) do if on == true then out[#out + 1] = tostring(repo) end end
      table.sort(out)
      return out
    end)(),
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
  -- Every change that matters (a pin, an unpin, a toggle, a fork switch) passes through here: also save this mod's
  -- Steamodded config right now. Steamodded only does that when the Mods menu is left, so a pin made just before
  -- "Restart now" (which closes the game) was lost and the mod showed no PINNED badge after the restart.
  pcall(function() AMU_UI.save_config() end)
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
-- GitHub does not allow two tokens with the same name, so every new token gets the next number:
-- "Balatro Mod Updater Token 2", "... Token 3" and so on (the first token, made before numbering, counts as 1).
local function amu_gh_next_serial()
  local have = config.github_token and config.github_token ~= ""
  return (tonumber(config.github_token_serial) or (have and 1 or 0)) + 1
end
local function amu_gh_token_name() return "Balatro Mod Updater Token " .. tostring(amu_gh_next_serial()) end
local function amu_gh_token_url()
  return "https://github.com/settings/personal-access-tokens/new"
    .. "?name=" .. amu_gh_token_name():gsub(" ", "+")
    .. "&description=Lets+Balatro+Mod+Updater+scan+mod+forks+%28read-only%2C+public+data%29"
    .. "&expires_in=90"
end

local function mask_gh_token(tok)
  if not tok or tok == "" then return "GitHub token: not set (limit 60 checks/hour)" end
  if AMU_TOKEN_UI and AMU_TOKEN_UI.bad_for == tok then return "GitHub token: EXPIRED - press GitHub token to replace it" end
  return "GitHub token: " .. tok:sub(1, 11) .. string.rep("*", 8) .. "  (set)"
end

local amu_gh_display = { text = mask_gh_token(config.github_token) }
local amu_gh_msg = { text = "" }

-- Fork Finder token status: no token = flashing red, token set = solid green, token expired = flashing orange.
-- The memo line and the "GitHub token" button read these colour tables; G.FUNCS.amu_token_flash changes them every frame.
AMU_TOKEN_UI = AMU_TOKEN_UI or { memo_col = { 1, 1, 1, 1 }, btn_col = { 0.2, 0.4, 0.9, 1 } }
do
  local U = AMU_TOKEN_UI
  function U.state()
    local tok = config.github_token
    if not tok or tok == "" then return "none" end
    if U.bad_for and U.bad_for == tok then return "expired" end
    return "ok"
  end
  -- called when an update check or a fork scan learns whether GitHub accepted the saved token
  function U.set_bad(is_bad)
    local tok = config.github_token
    if not tok or tok == "" then return end
    U.bad_for = is_bad and tok or nil
    amu_gh_display.text = mask_gh_token(config.github_token)
  end
  function U.on_summary(summary)
    if type(summary) == "table" then U.set_bad(summary.github_token_bad == true) end
  end
  function U.init()
    if U.inited then return end
    U.inited = true
    local tok = config.github_token
    if tok and tok ~= "" then
      local d = decode_json(read_all(join_path(amu_mod_path(), "last_run.json")) or "")
      if type(d) == "table" and d.github_token_bad == true then U.bad_for = tok end
    end
    amu_gh_display.text = mask_gh_token(config.github_token)
  end
  local function lerp3(a, c, k) return { a[1] + (c[1] - a[1]) * k, a[2] + (c[2] - a[2]) * k, a[3] + (c[3] - a[3]) * k } end
  function G.FUNCS.amu_token_flash(e)
    local s = U.state()
    local t = (G.TIMERS and G.TIMERS.REAL) or 0
    local k = 0.5 + 0.5 * math.sin(t * 6.3)
    local m, bt
    if s == "none" then
      m = lerp3({ 0.5, 0.08, 0.08 }, { 1, 0.25, 0.25 }, k); bt = lerp3({ 0.42, 0.05, 0.05 }, { 0.92, 0.15, 0.15 }, k)
    elseif s == "expired" then
      m = lerp3({ 0.6, 0.3, 0.03 }, { 1, 0.62, 0.1 }, k); bt = lerp3({ 0.5, 0.24, 0.02 }, { 1, 0.55, 0.05 }, k)
    else
      m = { 0.35, 0.95, 0.45 }; bt = { 0.2, 0.65, 0.3 }
    end
    for i = 1, 3 do U.memo_col[i] = m[i]; U.btn_col[i] = bt[i] end
    U.memo_col[4] = 1; U.btn_col[4] = 1
  end
end

---------------------------------------------------------------------------
-- CHECK FOR UPDATES NOW (manual trigger)
---------------------------------------------------------------------------

local on_full_update_done  -- forward declaration (assigned further down)
local amu_check_status = amu_status_tbl(0.48, 6.6, "")
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

  local thread_code = AMU_HIDE_SRC .. [[
    local cmd = ...
    local ok = pcall(function() amu_run(cmd) end)
    local ch = love.thread.getChannel("amu_manual_check")
    ch:push(ok and "done" or "error")
  ]]
  local t = love.thread.newThread(thread_code)
  t:start(cmd)

  -- While this runs, the main menu shows "Shuffling mods..." again (also when you go back to it from the Mods menu).
  -- The animation and the Checking... line under the button are one thing: both run while any check is running.
  local shown_loading = false
  if AMU_LOADING_API then
    shown_loading = pcall(AMU_LOADING_API.show, { text = "Shuffling mods...", suits = "\226\153\160  \226\153\165  \226\153\166  \226\153\163" }, "manual")
  end

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true,
    func = function()
      local msg = channel:pop()
      if msg then
        amu_is_checking = false
        local summary_path = join_path(mod_path, "last_run.json")
        local data = read_all(summary_path)
        local summary = data and decode_json(data) or nil
        local final
        if summary then
          local updated = summary.updated_mods or {}
          local errors = summary.errors or {}
          if #updated > 0 then
            final = "Done! " .. #updated .. " mod(s) updated."
          elseif #errors > 0 then
            final = "Done with " .. #errors .. " error(s)."
          elseif summary.game_updates_frozen == true then
            final = "Updates paused: saved game"
          else
            final = "All mods up to date!"
          end
        else
          final = msg == "done" and "Done!" or "Error running script."
        end
        local hidden = false
        if shown_loading and AMU_LOADING_API then hidden = pcall(AMU_LOADING_API.hide, "manual", final) end
        if not hidden then amu_check_status.text = final end
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

local function run_single_mod_check(folder_name, on_done)
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

  local thread_code = AMU_HIDE_SRC .. string.format([[
    local cmd = ...
    local ok = pcall(function() amu_run(cmd) end)
    local ch = love.thread.getChannel(%q)
    ch:push(ok and "done" or "error")
  ]], ch_name)
  local t = love.thread.newThread(thread_code)
  t:start(cmd)
  local single_t0 = love.timer and love.timer.getTime and love.timer.getTime() or 0
  local single_os0 = os.time()

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true,   -- survive the event-queue wipe when a run starts
    func = function()
      local msg = channel:pop()
      -- Safety net like the startup check: if PowerShell never reports back, stop waiting after the usual timeout and use
      -- last_run.json when it was written after this check started, so the message can never stay on "Checking..." for good.
      if not msg and love.timer and love.timer.getTime and (love.timer.getTime() - single_t0) > (tonumber(config.ui_timeout_seconds) or 300) then
        local fresh = false
        pcall(function()
          local info = love.filesystem.getInfo("Mods/" .. tostring(mod_path):match("([^/\\]+)[/\\]*$") .. "/last_run.json")
          if info and info.modtime and info.modtime >= single_os0 - 2 then fresh = true end
        end)
        msg = fresh and "done" or "error"
      end
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
        if on_done then pcall(on_done, amu_per_mod_status[folder_name], summary) end
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
local amu_sort_label = { toggles_now = "A-Z", toggles_next = "Next: Recent", backups_now = "A-Z", backups_next = "Next: Recent",
  forks_now = "A-Z", forks_next = "Next: Recent" }
local amu_nosrc_msg = amu_status_tbl(0.32, 14.4, "")
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
local AMU_BK_PER, AMU_BK_ROW_H, AMU_BK_W, AMU_BK_H = 6, 0.78, 15.2, 6 * 0.78
local AMU_FORK_PER, AMU_FORK_ROW_H, AMU_FORK_W, AMU_FORK_H = 6, 0.72, 15.2, 6 * 0.72
local AMU_NS_ROW_H = 0.72
local AMU_NS_PER, AMU_NS_W, AMU_NS_H = 6, 15.2, 6 * 0.72
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

---------------------------------------------------------------------------
-- SEARCH on the Mod Toggles and Backups tabs (same idea as Balatro Mod Search and Sort):
-- a text box next to the page selector, the list narrows while you type, every word has to match.
-- S (keyboard) or R3 (press the right stick) jumps into the box; holding it clears the box.
-- Everything lives in this ONE table because Lua allows only 200 top-level locals per file.
---------------------------------------------------------------------------
local AMU_FIND = {
  scan_label = { text = "Scan Now" },   -- Scan Now button text; reads "Scanning" while a scan runs
  MAX = 20,                                   -- longest search text
  HOLD = 0.6,                                 -- seconds to hold S / R3 to clear the box
  toggles = { text = "" },                    -- the text boxes write what you type into these
  backups = { text = "" },
  forks   = { text = "" },
  KINDS   = { "toggles", "backups", "forks" },
  applied = { toggles = "", backups = "", forks = "" },   -- (normalised) text the list is showing right now
  info    = { toggles = { text = "" }, backups = { text = "" }, forks = { text = "" } },   -- "Found 3 of 71" / the hint
  total   = { toggles = 0, backups = 0, forks = 0 },
  shown   = { toggles = 0, backups = 0, forks = 0 },
  pager   = {},                               -- the page selector's settings, per tab
  pending = {},                               -- a list refresh is already queued
  source  = {},                               -- which = function(mode) -> sorted list (default: all mods)
  list_id = { toggles = "amu_mod_toggle_list", backups = "amu_backup_mod_list", forks = "amu_fork_mod_list" },
  hold    = nil,                              -- { id = "s" | "rightstick", t0, fired, which }
  installed = false,
  filter  = { toggles = "all", backups = "all" },   -- the "Show:" button on those two tabs (all / on / off / pinned)
  filter_now  = { toggles = { text = "All" }, backups = { text = "All" } },                 -- "Show: <this>" pill
  filter_nxt  = { toggles = { text = "Next: ON" }, backups = { text = "Next: Pinned" } },   -- the button
  pg      = {},                               -- the page selector of each list (for the << and >> buttons), by list id
  sh      = { btn = nil, fired = false, t0 = nil, ticked = false },   -- LB / RB being held on a page screen (hold LB = first page, RB = last)
  HOLD_SH = 0.45,                             -- seconds to hold LB / RB to jump to the first / last page
}

function AMU_FIND.words(text)
  local words = {}
  for w in string.gmatch(tostring(text or ""):lower(), "%S+") do words[#words + 1] = w end
  return words, table.concat(words, " ")
end

function AMU_FIND.active(which)
  return #AMU_FIND.words(AMU_FIND[which].text) > 0
end

-- Is the "Show:" filter of this tab on (anything but All)?
function AMU_FIND.filtering(which)
  local f = AMU_FIND.filter[which]
  return f ~= nil and f ~= "all"
end

-- Does this row pass the "Show:" filter? Toggles: updates ON / OFF. Backups: pinned only.
function AMU_FIND.filter_pass(which, e)
  local f = AMU_FIND.filter[which]
  if f == nil or f == "all" then return true end
  if which == "toggles" then
    local v = config.mod_update_enabled and config.mod_update_enabled[e.folder]
    if f == "on" then return v ~= false end
    return v == false
  end
  local info
  if e.folder == "_game" then info = AMU_GAME.pin_info()
  elseif AMU_FRAMEWORKS[e.folder] then info = config.framework_pins and config.framework_pins[e.folder]
  else info = config.mod_pinned and config.mod_pinned[e.folder] end
  return type(info) == "table" and info.pinned == true
end

function AMU_FIND.set_info(which)
  local i = AMU_FIND.info[which]
  if AMU_FIND.active(which) or AMU_FIND.filtering(which) then
    i.text = "Found " .. AMU_FIND.shown[which] .. " of " .. AMU_FIND.total[which]
  else
    i.text = "S / R3 = search"
  end
end

-- The mods this tab shows right now: sorted like before, then narrowed by the search.
-- Every word typed has to appear in the mod's name or its folder name.
function AMU_FIND.entries(which, mode)
  local src = AMU_FIND.source[which]
  local everything = src and src(mode) or get_sorted_mod_entries(mode)
  local all = everything
  if AMU_FIND.filtering(which) then
    all = {}
    for _, e in ipairs(everything) do
      if AMU_FIND.filter_pass(which, e) then all[#all + 1] = e end
    end
  end
  local words = AMU_FIND.words(AMU_FIND[which].text)
  local out = all
  if #words > 0 then
    out = {}
    for _, e in ipairs(all) do
      local hay = (tostring(e.display or "") .. " " .. tostring(e.folder or "") .. " "
        .. tostring(e.installed_repo or "")):lower()
      local good = true
      for _, w in ipairs(words) do
        if not string.find(hay, w, 1, true) then good = false; break end
      end
      if good then out[#out + 1] = e end
    end
  end
  AMU_FIND.total[which], AMU_FIND.shown[which] = #everything, #out
  AMU_FIND.set_info(which)
  return out
end

AMU_FIND.source.backups = function(mode)
  local list = get_sorted_mod_entries(mode)
  for _, key in ipairs({ "smods", "lovely", "_game" }) do
    list[#list + 1] = { folder = key, display = AMU_FRAMEWORKS[key].display, updated = AMU_FRAMEWORKS.updated(), framework = true }
  end
  table.sort(list, function(a, b)
    if mode == "recent" and a.updated ~= b.updated then return a.updated > b.updated end
    local al, bl = a.display:lower(), b.display:lower()
    if al ~= bl then return al < bl end
    return a.folder < b.folder
  end)
  return list
end

function AMU_FIND.walk(node, fn)
  if type(node) ~= "table" then return end
  fn(node)
  if type(node.nodes) == "table" then
    for _, c in ipairs(node.nodes) do AMU_FIND.walk(c, fn) end
  end
end

-- The page selector keeps its options in one table (its arrows read it every time they are used).
function AMU_FIND.find_args(node)
  local found
  AMU_FIND.walk(node, function(n)
    local c = n.config
    if not found and type(c) == "table" and type(c.ref_table) == "table" and type(c.ref_table.options) == "table" then
      found = c.ref_table
    end
  end)
  return found
end

-- The search narrowed (or widened) the list: rewrite the "Page x/y" selector to match.
function AMU_FIND.sync_pager(which, pages, page)
  local a = AMU_FIND.pager[which]
  if type(a) ~= "table" then return end
  pages = math.max(1, pages)
  page = math.max(1, math.min(tonumber(page) or 1, pages))
  local opts = {}
  for i = 1, pages do opts[i] = "Page " .. i .. "/" .. pages end
  a.options = opts
  a.current_option = page
  a.current_option_val = opts[page]
end

function AMU_FIND.owns_hook(h)
  if not (h and h.config and type(h.config.ref_table) == "table") then return false end
  local r = h.config.ref_table.ref_table
  return r ~= nil and (r == AMU_FIND.toggles or r == AMU_FIND.backups or r == AMU_FIND.forks)
end

function AMU_FIND.drop_hook()
  local C = G and G.CONTROLLER
  if C and AMU_FIND.owns_hook(C.text_input_hook) then C.text_input_hook = nil end
end

-- Leaving the Mods menu: start from an empty search next time (so mods never look like they went missing).
function AMU_FIND.reset_all()
  for _, w in ipairs(AMU_FIND.KINDS) do
    AMU_FIND[w].text = ""
    AMU_FIND.applied[w] = ""
    AMU_FIND.pending[w] = nil
  end
  AMU_FIND.hold = nil
  -- (the Show: filters are NOT reset here any more - they are remembered, see AMU_UI)
  pcall(AMU_FIND.filter_sync, "toggles")
  pcall(AMU_FIND.filter_sync, "backups")
end

-- Which search row is on screen? (nil = none of our tabs is showing it)
function AMU_FIND.which_open()
  local om = G and G.OVERLAY_MENU
  if not (om and om.get_UIE_by_ID) then return nil end
  for _, w in ipairs(AMU_FIND.KINDS) do
    local ok, row = pcall(om.get_UIE_by_ID, om, "amu_find_row_" .. w)
    if ok and row then return w end
  end
  return nil
end

function AMU_FIND.available()
  local C = G and G.CONTROLLER
  if not C or C.text_input_hook or C.screen_keyboard or C.locked then return nil end
  return AMU_FIND.which_open()
end

-- Tap = jump into the box; hold for AMU_FIND.HOLD seconds = clear it.
-- A few log lines in _hold_s.log (capped, only when AMU_FIND.DEBUG is on) so a hotkey that does nothing can be traced.
AMU_FIND.DEBUG = false   -- (on for the LB / RB hold test, switch back to false afterwards) set to true to write _hold_s.log while tracing the search hotkeys

-- Header / title colour. The game's purple (G.C.PURPLE) is used as it is when a colour mod (Trance and the like) changed it, and
-- when the UI is stock. When a colour mod recoloured the UI (G.C.RED differs from the stock red) but left PURPLE at the stock
-- purple, the headers use that theme's main colour instead, lightened a little so it stays readable on the dark panels.
function AMU_FIND.theme_purple()
  local fallback = RGBA(0.62, 0.33, 0.92, 1)
  local C = G and G.C
  if type(C) ~= "table" then return fallback end
  local p = C.PURPLE or (C.UI and C.UI.PURPLE)
  if type(p) ~= "table" then return fallback end
  local function same(a, b)
    return type(a) == "table" and math.abs((a[1] or 0) - b[1]) < 0.02 and math.abs((a[2] or 0) - b[2]) < 0.02
      and math.abs((a[3] or 0) - b[3]) < 0.02
  end
  if not same(p, { 0.5333, 0.4039, 0.6471 }) then return p end            -- the theme picked its own purple: follow it
  local r = C.RED
  if type(r) ~= "table" or same(r, { 0.9961, 0.3725, 0.3333 }) then return p end   -- stock UI: keep the purple
  local lum = 0.2126 * (r[1] or 0) + 0.7152 * (r[2] or 0) + 0.0722 * (r[3] or 0)
  local t = 0
  if lum < 0.45 then t = math.min(0.7, (0.45 - lum) / (1 - lum)) end
  return { (r[1] or 0) + (1 - (r[1] or 0)) * t, (r[2] or 0) + (1 - (r[2] or 0)) * t, (r[3] or 0) + (1 - (r[3] or 0)) * t, 1 }
end
AMU_FIND.dbg_n = 0
function AMU_FIND.dbg(msg)
  if not AMU_FIND.DEBUG then return end
  if AMU_FIND.dbg_n >= 30 then return end
  AMU_FIND.dbg_n = AMU_FIND.dbg_n + 1
  pcall(function()
    local dir = AMU_CRASH_GUARD and AMU_CRASH_GUARD.mod_dir
    if not dir then return end
    local f = io.open(dir .. "/_hold_s.log", "a")
    if f then
      f:write(string.format("%.2f %s\n", (G.TIMERS and G.TIMERS.REAL) or 0, msg))
      f:close()
    end
  end)
end

function AMU_FIND.hold_begin(id)
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  local h = AMU_FIND.hold
  if h and h.id == id and now - h.t0 < 10 then return true end    -- key repeat
  local which = AMU_FIND.available()
  AMU_FIND.dbg("press " .. tostring(id) .. " row=" .. tostring(which))
  if not which then return false end
  AMU_FIND.hold = { id = id, t0 = now, fired = false, which = which }
  return true
end

function AMU_FIND.hold_end(id)
  local h = AMU_FIND.hold
  if not (h and h.id == id) then return end
  AMU_FIND.hold = nil
  if not h.fired then pcall(AMU_FIND.focus, h.which) end
end

-- called once per frame (from the controller hook)
function AMU_FIND.hold_tick()
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  if AMU_FIND.scan_poll then pcall(AMU_FIND.scan_poll) end
  local h = AMU_FIND.hold
  if h and not h.fired and now - h.t0 >= AMU_FIND.HOLD then
    h.fired = true
    AMU_FIND.dbg("hold fired (" .. tostring(h.id) .. ")")
    pcall(AMU_FIND.clear, h.which)
  end
  -- Keyboard safety net: ask the keyboard itself whether S is still down. If another mod swallowed the key events
  -- (so the press/release hooks above never saw the hold), this still clears the box after AMU_FIND.HOLD seconds.
  local down = false
  if love and love.keyboard and love.keyboard.isDown then
    local ok, d = pcall(love.keyboard.isDown, "s")
    down = (ok and d) and true or false
  end
  local p = AMU_FIND.poll
  local C = G and G.CONTROLLER
  if not down then
    AMU_FIND.poll = nil
  elseif not p then
    -- which == nil: S went down on a screen that has no search row -> ignore it until it is released.
    -- While the cursor is still IN our search box, S types an "s"; holding it for AMU_FIND.HOLD seconds clears the box.
    local w = AMU_FIND.available()
    if not w and C and AMU_FIND.owns_hook(C.text_input_hook) then w = AMU_FIND.which_open() end
    AMU_FIND.poll = { t0 = now, which = w, fired = false }
    AMU_FIND.dbg("S down row=" .. tostring(w) .. " typing=" .. tostring(C and C.text_input_hook ~= nil))
  elseif p.which and not p.fired and now - p.t0 >= AMU_FIND.HOLD then
    p.fired = true
    local h2 = AMU_FIND.hold
    if h2 and h2.fired then return end            -- the normal path already cleared it
    if h2 then h2.fired = true end                -- so letting go does not jump into the box
    AMU_FIND.dbg("poll fired (keyboard S)")
    pcall(AMU_FIND.clear, p.which)
  end
  pcall(AMU_FIND.heal_tick)
end

-- The tab box of the open search tab (the box that sits inside the Mods menu's tab area).
function AMU_FIND.tab_box(which)
  local om = G and G.OVERLAY_MENU
  if not (om and om.get_UIE_by_ID and which) then return nil end
  local ok, row = pcall(om.get_UIE_by_ID, om, "amu_find_row_" .. which)
  return ok and row and row.UIBox or nil
end

-- Leaving the search box (B on a controller, Enter, Esc) makes the game lay the tab out again, and a tab that sits
-- inside another box then lands too far to the right. Remember where the tab was while the cursor was in the box;
-- when the box is let go, watch for about a second and rebuild just the tab (like Clear does) if it moved.
-- The controller's on-screen keyboard. The game removes it from the search box's own per-frame update; if that box is
-- rebuilt first, the keyboard (and the extra cursor layer it adds) is left behind and the keyboard and controller go
-- dead while the mouse still works. Close it the same way the game does.
function AMU_FIND.close_osk()
  local C = G and G.CONTROLLER
  local osk = C and C.screen_keyboard
  if not osk then return false end
  local par = osk.config and osk.config.parent
  if par and par.children and par.children.controller_keyboard == osk then par.children.controller_keyboard = nil end
  pcall(function() osk:remove() end)
  C.screen_keyboard = nil
  if C.mod_cursor_context_layer then pcall(C.mod_cursor_context_layer, C, -1) end
  AMU_FIND.dbg("closed a stale on-screen keyboard")
  return true
end

function AMU_FIND.heal_tick()
  local C = G and G.CONTROLLER
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  -- safety net: an on-screen keyboard with no text box to type into for over half a second is left over
  if C and C.screen_keyboard and not C.text_input_hook then
    AMU_FIND.osk_t0 = AMU_FIND.osk_t0 or now
    if now - AMU_FIND.osk_t0 > 0.5 then AMU_FIND.osk_t0 = nil; pcall(AMU_FIND.close_osk) end
  else
    AMU_FIND.osk_t0 = nil
  end
  local owned = C and AMU_FIND.owns_hook(C.text_input_hook)
  if owned then
    if not AMU_FIND.hooked then
      local w = AMU_FIND.which_open()
      local b = AMU_FIND.tab_box(w)
      if b and b.T then AMU_FIND.hooked = { which = w, x = b.T.x, y = b.T.y } end
    end
    AMU_FIND.heal = nil
    return
  end
  if AMU_FIND.hooked then
    AMU_FIND.heal = { which = AMU_FIND.hooked.which, x = AMU_FIND.hooked.x, y = AMU_FIND.hooked.y, t0 = now }
    AMU_FIND.hooked = nil
  end
  local h = AMU_FIND.heal
  if not h then return end
  if now - h.t0 > 1.2 then AMU_FIND.heal = nil return end
  if AMU_FIND.which_open() ~= h.which then AMU_FIND.heal = nil return end
  local b = AMU_FIND.tab_box(h.which)
  if not (b and b.T) then return end
  if math.abs(b.T.x - h.x) > 0.05 or math.abs(b.T.y - h.y) > 0.05 then
    AMU_FIND.heal = nil
    AMU_FIND.dbg(string.format("tab moved (%.2f,%.2f) -> rebuilding", b.T.x - h.x, b.T.y - h.y))
    AMU_FIND.swap_tab("amu_find_row_" .. h.which)
  end
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
  pcall(AMU_FIND.drop_hook)
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

-- Small pop-up in the bottom right corner (update check / fork scan finished). Fades away by itself; a click can run an action.
AMU_FIND.toast = { box = nil, token = 0 }
function AMU_FIND.toast.hide()
  local T = AMU_FIND.toast
  T.token = T.token + 1
  if T.box then pcall(function() T.box:remove() end); T.box = nil end
end
function AMU_FIND.toast.show(text, opts)
  opts = opts or {}
  local T = AMU_FIND.toast
  if not (G and G.E_MANAGER and Event and UIBox and G.UIT and G.ROOM_ATTACH) then return false end
  T.hide()
  local ok = pcall(function()
    -- Where can the pop-up go? In a run the deck fills the bottom right of the game area, but the strip to the right of the deck
    -- (the game's right margin plus the gap beside the deck) is empty. Use that strip, in the bottom right corner of the screen, and
    -- wrap the text to fit it. Outside a run the box sits in the bottom right corner of the game area on one line per message line.
    -- Everything is in game units, so this follows any window, monitor or borderless size.
    local strip, ox, oy = nil, -0.4, -0.2
    pcall(function()
      if G.STAGE == G.STAGES.RUN and G.deck and G.deck.T and G.ROOM and G.TILE_W and G.TILE_H and love and love.graphics then
        local sw, sh = love.graphics.getDimensions()
        local unit = G.TILESIZE * G.TILESCALE
        local rmx = sw / unit - G.ROOM.T.x - G.TILE_W      -- empty margin right of the game area
        local rmy = sh / unit - G.ROOM.T.y - G.TILE_H      -- empty margin below the game area
        -- the deck's area is wider than the card drawn in it: use the card's visible right edge (area centre + half a card)
        local cw = tonumber(G.CARD_W) or 2.05
        local dright, dy = G.deck.T.x + G.deck.T.w / 2 + cw / 2 + 0.05, G.deck.T.y
        if type(dy) == "number" and dy > G.TILE_H * 0.5 and dy < G.TILE_H and dright > G.TILE_W * 0.5 and dright < G.TILE_W + 0.5 then
          strip = math.min(math.max(rmx + (G.TILE_W - dright) + 0.0, 1.1), 4.5)
          ox = math.max(rmx - 0.15, -0.4)
          oy = math.max(rmy - 0.25, -0.2)
        end
      end
    end)
    local function wrap(piece, scale, avail)
      local out, cur = {}, ""
      for word in tostring(piece):gmatch("%S+") do
        local try = (cur == "") and word or (cur .. " " .. word)
        if cur == "" or #try * 0.56 * scale <= avail then cur = try else out[#out + 1] = cur; cur = word end
      end
      if cur ~= "" then out[#out + 1] = cur end
      return out
    end
    local pieces = type(text) == "table" and text or { text }
    local scale = 0.3
    if strip then
      local avail = strip - 0.3
      local longest = 1
      for _, t in ipairs(pieces) do for w in tostring(t):gmatch("%S+") do longest = math.max(longest, #w) end end
      for _, s in ipairs({ 0.3, 0.27, 0.24, 0.22 }) do scale = s; if longest * 0.56 * s <= avail then break end end
    end
    local hint_scale = scale * 0.7
    local lines = {}
    local function add_line(t, sc, col)
      lines[#lines + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { text = t, scale = sc, colour = col, shadow = sc >= 0.3 } } } }
    end
    for _, t in ipairs(pieces) do
      for _, ln in ipairs(strip and wrap(t, scale, strip - 0.3) or { t }) do add_line(ln, scale, G.C.UI.TEXT_LIGHT or G.C.WHITE) end
    end
    if opts.click_hint then
      for _, ln in ipairs(strip and wrap(opts.click_hint, hint_scale, strip - 0.3) or { opts.click_hint }) do
        add_line(ln, hint_scale, G.C.UI.TEXT_INACTIVE or G.C.GREY)
      end
    end
    local card = { n = G.UIT.C, config = { align = "cm", padding = 0.09, r = 0.1, emboss = 0.04,
      colour = G.C.L_BLACK or G.C.BLACK, outline = 0.9, outline_colour = opts.colour or G.C.GREEN,
      button = opts.action and "amu_toast_click" or nil, hover = opts.action and true or nil, shadow = true }, nodes = lines }
    T.box = UIBox({
      definition = { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR }, nodes = { card } },
      -- "bri" = inside the bottom right corner of the game area (without the "i" the box sits OUTSIDE it, below and to the right, and gets
      -- cut off). ox and oy push it out into the empty margin so it ends up in the corner of the screen itself.
      config = { align = "bri", offset = { x = ox, y = oy }, major = G.ROOM_ATTACH, bond = "Weak", instance_type = "POPUP" },
    })
    T.action = opts.action
  end)
  if not ok then T.box = nil; return false end
  T.token = T.token + 1
  local my, started, life = T.token, nil, opts.seconds or 6
  G.E_MANAGER:add_event(Event({ blockable = false, blocking = false, no_delete = true, func = function()
    if T.token ~= my then return true end
    local now = (G.TIMERS and G.TIMERS.REAL) or 0
    started = started or now
    if (now - started) < life then return false end
    T.hide()
    return true
  end }))
  return true
end
G.FUNCS.amu_toast_click = function(e)
  local act = AMU_FIND.toast.action
  AMU_FIND.toast.hide()
  if act then pcall(act) end
end

-- Open Mods > Mod Updater on the Fork Finder tab.
function AMU_FIND.open_fork_finder()
  pcall(function()
    local tabs = mod.extra_tabs and mod.extra_tabs() or {}
    for i, t in ipairs(tabs) do
      if t.label == "Fork Finder" then SMODS.LAST_SELECTED_MOD_TAB = ((mod and mod.id) or "modupdater") .. "_" .. i end
    end
  end)
  G.FUNCS.amu_back_to_menu()
end

-- Every (mod, fork) pair the Fork Finder list shows right now.
function AMU_FIND.fork_keys()
  local keys = {}
  local ok, entries = pcall(get_fork_mod_entries)
  if ok and type(entries) == "table" then
    for _, e in ipairs(entries) do
      for _, f in ipairs(e.forks or {}) do keys[tostring(e.folder) .. "|" .. tostring(f.repo or f.full_name or f.name)] = true end
    end
  end
  return keys
end

-- Rebuild the whole tab (pager included) when it is on screen. Used when the NUMBER of rows changes.
local function amu_reopen_if_open(area_id)
  local om = G and G.OVERLAY_MENU
  if om and om.get_UIE_by_ID and om:get_UIE_by_ID(area_id) then
    if not AMU_FIND.swap_tab(area_id) then G.FUNCS.amu_back_to_menu() end
  end
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

-- Is this gamepad button physically down? Checks the game's held-button list AND the gamepad itself (see amu_b_down).
function AMU_FIND.pad_down(ctl, name)
  if ctl and ctl.held_buttons and ctl.held_buttons[name] then return true end
  if love and love.joystick and love.joystick.getJoysticks then
    local raw = name
    if G and G.button_mapping then
      for k, v in pairs(G.button_mapping) do if v == name then raw = k end end
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

-- The list id of the page selector that is on screen right now (every tab registers its own in AMU_FIND.pg).
function AMU_FIND.active_pager()
  local om = G and G.OVERLAY_MENU
  if not (om and om.get_UIE_by_ID) then return nil end
  for id in pairs(AMU_FIND.pg) do
    local ok, el = pcall(om.get_UIE_by_ID, om, id)
    if ok and el then return id end
  end
  return nil
end

-- The page the on-screen selector shows (nil when there is none).
function AMU_FIND.cur_page()
  local id = AMU_FIND.active_pager()
  local r = id and AMU_FIND.pg[id]
  local a = r and r.args
  return a and a.current_option
end

-- A tap of LB / RB: click the < or > arrow, exactly what the game itself does for these buttons (controller.lua:
-- cycle_shoulders.children[1].children[1 or 3]:click()). Skipped when the page already changed since the press,
-- so a press that the game handled itself is never turned twice.
function AMU_FIND.shoulder_tap(btn, page0)
  local cur = AMU_FIND.cur_page()
  if page0 ~= nil and cur ~= nil and cur ~= page0 then return end
  local om = G and G.OVERLAY_MENU
  local cs = om and om.get_UIE_by_ID and om:get_UIE_by_ID('cycle_shoulders')
  local t = cs and cs.children and cs.children[1]
  local arrow = t and t.children and t.children[btn == "leftshoulder" and 1 or 3]
  AMU_FIND.dbg("shoulder " .. tostring(btn) .. " tap: page " .. tostring(cur) .. ", arrow " .. tostring(arrow ~= nil))
  if arrow and arrow.click then arrow:click() end
end

-- Once per frame: LB / RB held long enough = jump to the first / last page. (A tap is handled on release.)
function AMU_FIND.shoulder_tick(ctl)
  local sh = AMU_FIND.sh
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  if not sh.btn then
    -- Not started by the press hook: another mod (Better Mouse and Gamepad) can swallow the press before it reaches us,
    -- exactly like for Hold-B. So also start timing from the pad itself: LB / RB physically down on a page screen.
    if not ctl then return end
    for _, name in ipairs({ "leftshoulder", "rightshoulder" }) do
      if AMU_FIND.pad_down(ctl, name) then
        local om = G and G.OVERLAY_MENU
        if ctl.text_input_hook or ctl.screen_keyboard or not amu_screen_open()
           or not (om and om.get_UIE_by_ID and om:get_UIE_by_ID('cycle_shoulders')) then return end
        sh.btn, sh.fired, sh.t0, sh.ticked, sh.page0 = name, false, now, true, AMU_FIND.cur_page()
        AMU_FIND.dbg("shoulder " .. name .. " down (seen by polling)")
        return
      end
    end
    return
  end
  if not AMU_FIND.pad_down(ctl, sh.btn) then
    -- let go without the release event reaching us: a short press is still a page turn
    local b, fired, p0 = sh.btn, sh.fired, sh.page0
    sh.btn, sh.fired, sh.t0, sh.ticked, sh.page0 = nil, false, nil, false, nil
    if not fired then pcall(AMU_FIND.shoulder_tap, b, p0) end
    return
  end
  if sh.fired then return end
  if now - (sh.t0 or now) < AMU_FIND.HOLD_SH then return end
  sh.fired = true
  local id = AMU_FIND.active_pager()
  AMU_FIND.dbg("shoulder " .. tostring(sh.btn) .. " held: jump on list " .. tostring(id))
  if id then AMU_FIND.jump(id, sh.btn == "rightshoulder") end
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
  pcall(AMU_FIND.hold_tick)
  pcall(AMU_FIND.shoulder_tick, ctl)
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
    -- The crash question is open but the cursor is still on the main menu behind it: move it onto the question first.
    if button ~= "b" and not self.locks.frame and AMU_CRASH.ensure_focus then
      local ok, moved = pcall(AMU_CRASH.ensure_focus, self)
      if ok and moved then self.interrupt.focus = false; return end
    end
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
      -- On a page screen a TAP still turns the page (done when you let go, in the release hook below);
      -- HOLDING LB goes to the first page and RB to the last (timed in amu_hold_tick).
      if not self.text_input_hook and not self.screen_keyboard then
        local sh = AMU_FIND.sh
        if not sh.btn then
          sh.btn, sh.fired, sh.t0, sh.ticked, sh.page0 = button, false, amu_now(), false, AMU_FIND.cur_page()
          AMU_FIND.dbg("shoulder " .. button .. " down (seen by the press hook)")
        end
        self.held_button_times[button] = 0
        self.interrupt.focus = false
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
    if (button == "leftshoulder" or button == "rightshoulder") and AMU_FIND.sh.btn == button then
      local sh = AMU_FIND.sh
      local was_tap, p0 = not sh.fired, sh.page0
      sh.btn, sh.fired, sh.t0, sh.ticked, sh.page0 = nil, false, nil, false, nil
      if was_tap and G.OVERLAY_MENU then pcall(AMU_FIND.shoulder_tap, button, p0) end   -- the page turn
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
local function amu_close_all_node(minw, inline)
  local dim = RGBA(0.78, 0.8, 0.88, 1)
  local using_pad = G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller
  local hint
  if using_pad then
    hint = {
      { n = G.UIT.T, config = { text = "Hold ", scale = 0.305, colour = dim } },
      { n = G.UIT.C, config = { minw = 0.493, minh = 0.436, align = "cm", func = "set_button_pip",
          focus_args = { button = "b", type = "none", orientation = "cm", scale = 0.464, offset = { x = 0, y = 0 } } }, nodes = {} },
      { n = G.UIT.T, config = { text = " or press Esc", scale = 0.305, colour = dim } },
    }
  else
    hint = { { n = G.UIT.T, config = { text = "Hold B or press Esc", scale = 0.305, colour = dim } } }
  end
  if inline then
    -- title row: the button and its hint sit side by side on one line
    return { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
        { n = G.UIT.B, config = { id = "amu_marker", w = 0, h = 0 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = minw or 2.6, minh = 0.46, r = 0.09,
            colour = G.C.RED, button = "amu_close_all", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Close All Menus", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.B, config = { w = 0.16, h = 0.1 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
          { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = hint } } },
      }},
    }}
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
  local purple = AMU_FIND.theme_purple()
  -- a little air under the title row so it is not flush with the buttons below it (the lists give that space back)
  return { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
      { n = G.UIT.T, config = { text = title, scale = scale or 0.5, colour = purple, shadow = true } },
      { n = G.UIT.B, config = { w = 0.5, h = 0.1 } },
      amu_close_all_node(2.6, true),
    }},
    { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { { n = G.UIT.B, config = { w = 0.1, h = 0.14 } } } },
  }}}}
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

---------------------------------------------------------------------------
-- WEBPAGE LINKS: where a mod came from (used by the "Webpage" buttons in Fork Finder, Mod Toggles and Backups)
-- Order: the fork you switched to, then update.json (what the updater or a pasted link set), then the mod's own
-- git remote, then Nexus. Kept in a table (not locals) because main.lua is close to Lua's local variable limit.
---------------------------------------------------------------------------
-- Steamodded and Lovely are not normal mods (they are updated after you quit the game), but they have fixed homes.
AMU_FRAMEWORKS = {
  smods  = { display = "Steamodded",      repo = "Steamodded/smods",               tag_key = "steamodded_tag",
             note = "Pick an earlier Steamodded to go back to it (applied on restart)." },
  lovely = { display = "Lovely Injector", repo = "ethangreen-dev/lovely-injector", tag_key = "lovely_tag",
             note = "Pick an earlier Lovely to go back to it (applied on restart)." },
}
local function amu_fw_log_time()
  local info = love.filesystem.getInfo("Mods/" .. mod_folder_name .. "/pending_apply_log.json")
  return info and info.modtime or 0
end
-- the two lines shown in the Backups list: version, then last applied update
function AMU_FRAMEWORKS.lines(folder)
  if folder == "_game" then return AMU_GAME.lines() end
  local fw = AMU_FRAMEWORKS[folder]
  if type(fw) ~= "table" then return nil end
  local tag
  local st = decode_json(read_all(join_path(amu_mod_path(), ".framework_state.json")) or "")
  if type(st) == "table" and type(st[fw.tag_key]) == "string" and st[fw.tag_key] ~= "" then tag = st[fw.tag_key] end
  local d = fmt_date(amu_fw_log_time())
  return tag or "version unknown", d and ("Updated " .. d) or "Never updated here"
end
function AMU_FRAMEWORKS.updated() return amu_fw_log_time() end

-- Saved copies of the Balatro game files (made by autoupdate.ps1 into <save folder>\AMU_GameBackups).
-- Shown as a third row in the Backups tab. Kept in global tables (main.lua is close to Lua's limit of local variables).
AMU_FRAMEWORKS._game = { display = "Balatro game files", game = true,
  note = "Pick a saved copy of the game to play (applied on restart). Mod and framework updates pause while one is installed." }
AMU_GAME = AMU_GAME or {}
function AMU_GAME.state()
  return decode_json(read_all(join_path(amu_mod_path(), ".game_state.json")) or "") or {}
end
function AMU_GAME.copies()
  local out = {}
  local ok, items = pcall(love.filesystem.getDirectoryItems, "AMU_GameBackups")
  if ok and type(items) == "table" then
    for _, n in ipairs(items) do
      if n:sub(1, 5) ~= "_tmp_" and love.filesystem.getInfo("AMU_GameBackups/" .. n .. "/amu_backup.json") then out[#out + 1] = n end
    end
  end
  table.sort(out, function(a, b) return a > b end)   -- newest first
  return out
end
-- what a staged swap (waiting for the game to close) will do: nil, "steam", or the saved copy's name
function AMU_GAME.pending_swap()
  local d = decode_json(read_all(join_path(amu_mod_path(), "pending_apply.json")) or "")
  if type(d) ~= "table" or type(d.tasks) ~= "table" then return nil end
  for _, t in ipairs(d.tasks) do
    if type(t) == "table" and t.type == "swap_game" then
      if t.make_active == true then return tostring(t.name or "") end
      return "steam"
    end
  end
  return nil
end
-- The pin shown in the Backups tab comes from the real state of the game files, never from the saved config
-- (a config saved before a restart used to leave PINNED showing after going back to Steam's version).
function AMU_GAME.pin_info()
  local st = AMU_GAME.state()
  local act = type(st.active_backup) == "string" and st.active_backup or ""
  if AMU_GAME.pending_swap() == "steam" then return nil end
  if act ~= "" or st.frozen == true then return { pinned = true, backup_file = act } end
  return nil
end
function AMU_GAME.lines()
  local st = AMU_GAME.state()
  local act = type(st.active_backup) == "string" and st.active_backup or ""
  local frozen = st.frozen == true
  local pend = AMU_GAME.pending_swap()
  local n = #AMU_GAME.copies()
  local l1, l2
  if pend == "steam" then
    return "Steam's newest version comes back on restart", "Mod updates ON after the restart"
  elseif pend and pend ~= "" then
    return "Saved copy plays on restart: " .. AMU_FRAMEWORKS.label(pend), "Mod updates paused"
  end
  if act ~= "" then l1 = "Playing saved copy " .. AMU_FRAMEWORKS.label(act)
  elseif frozen then l1 = "Earlier saved copy comes back on restart"
  else l1 = "Steam's own version" end
  if act ~= "" or frozen then
    l2 = (config.cfg_allow_updates_on_backup == true) and "Mod updates ON (you allowed them)" or "Mod updates paused"
  else
    l2 = n .. " saved " .. (n == 1 and "copy" or "copies")
  end
  return l1, l2
end
-- keep the Backups-tab pin for the game in step with what the last update check found
-- Line under "Check for updates now": says so when mod updates are paused because of the game copy (also after the startup check).
function AMU_GAME.status_text()
  local pin = AMU_GAME.pin_info()
  if not pin then return nil end
  local why = (pin.backup_file and pin.backup_file ~= "") and "saved game" or "game updated"
  if config.cfg_allow_updates_on_backup == true then return "Mod updates ON (allowed)" end
  return "Updates paused: " .. why
end
function AMU_GAME.sync_status()
  local cur = tostring(amu_check_status.text or "")
  local s = AMU_GAME.status_text()
  if s then
    if cur == "" or cur == "All mods up to date!" or cur:find("^Updates paused") or cur:find("^Mod updates ON") then amu_check_status.text = s end
  elseif cur:find("^Updates paused") or cur:find("^Mod updates ON") then
    amu_check_status.text = ""
  end
end
function AMU_GAME.reconcile(sum)
  if config.framework_pins then config.framework_pins._game = nil end   -- the game pin is read from .game_state.json instead
end

AMU_WEB = AMU_WEB or {}

-- "git@github.com:owner/repo.git", "https://user:pw@host/owner/repo.git" and friends -> a clean https address
function AMU_WEB.clean_remote(url)
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if url == "" then return nil end
  local host, path = url:match("^[%w%._%-]+@([^:/]+):(.+)$")
  if not host then host, path = url:match("^ssh://[%w%._%-]+@([^/:]+)[:%d]*/(.+)$") end
  if not host then
    url = url:gsub("^(https?://)[^/@]*@", "%1")
    host, path = url:match("^https?://([^/]+)/(.+)$")
  end
  if not host or not path then return nil end
  path = path:gsub("%.git$", ""):gsub("/+$", "")
  if path == "" then return nil end
  return host, path
end

function AMU_WEB.git_remote(folder)
  local ok, res = pcall(function()
    local mods_dir = join_path(love.filesystem.getSaveDirectory(), "Mods")
    local raw = read_all(join_path(join_path(join_path(mods_dir, folder), ".git"), "config"))
    if not raw then return nil end
    raw = raw:gsub("\r", "")
    local body = raw:match('%[remote "origin"%]([^%[]*)')
    if not body then body = raw:match('%[remote "[^"]+"%]([^%[]*)') end
    local url = body and body:match("url%s*=%s*([^\n]+)")
    return url
  end)
  if ok then return res end
  return nil
end

-- Returns a list of { label, url, name }. The first one is what the "Webpage" buttons open.
function AMU_WEB.links(folder, installed_repo)
  local links = {}
  local fw = AMU_FRAMEWORKS[folder]
  if folder == "_game" then
    -- Balatro itself: its update history (every build and patch note), then the official Steam news
    links[1] = { label = "Balatro update history", url = "https://steamdb.info/app/2379780/patchnotes/", name = "SteamDB: Balatro patch notes" }
    links[2] = { label = "Steam news", url = "https://store.steampowered.com/news/app/2379780", name = "Balatro news on Steam" }
    return links
  end
  if type(fw) == "table" and fw.repo then
    links[1] = { label = "GitHub webpage", url = "https://github.com/" .. fw.repo, name = fw.repo }
    return links
  end
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
  local other_url, other_name
  if not repo or repo == "" then
    local host, path = AMU_WEB.clean_remote(AMU_WEB.git_remote(folder))
    if host and path then
      if host:lower() == "github.com" or host:lower() == "www.github.com" then
        repo = path
      else
        other_url, other_name = "https://" .. host .. "/" .. path, path
      end
    end
  end
  if (not repo or repo == "") and type(installed_repo) == "string" and installed_repo ~= "" then repo = installed_repo end
  if repo and repo ~= "" then
    links[#links + 1] = { label = "GitHub webpage", url = "https://github.com/" .. repo, name = repo }
  end
  if other_url then
    links[#links + 1] = { label = "Webpage", url = other_url, name = other_name }
  end
  if nexus_id then
    links[#links + 1] = { label = "Nexus webpage", url = "https://www.nexusmods.com/balatro/mods/" .. nexus_id, name = "Nexus #" .. nexus_id }
  end
  return links
end

-- Opens the first link; returns the message to show.
function AMU_WEB.open_first(folder, display, installed_repo, short)
  local links = AMU_WEB.links(folder, installed_repo)
  if not links[1] then
    if short then return "No webpage known yet." end
    return "No webpage known for " .. tostring(display) .. ". Add its link in the 'No Source' tab."
  end
  local ok = pcall(function() love.system.openURL(links[1].url) end)
  if short then return ok and "Opened in your browser." or "Couldn't open a browser." end
  if ok then return "Opened " .. tostring(links[1].name) .. " in your browser." end
  return "Couldn't open a browser."
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
  args.scale = args.scale or 0.42
  local t = create_toggle(args)
  if type(t) == "table" and type(t.config) == "table" then t.config.padding = 0.03 end
  return t
end

local AMU_TOG_ROW_H = 0.66
local AMU_TOG_W, AMU_TOG_H = 14.9, 7 * 0.66

build_mod_toggles_page = function(page)
  local entries = AMU_FIND.entries("toggles", config.sort_toggles)
  local total_pages = math.max(1, math.ceil(#entries / MODS_PER_PAGE))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_CONFIG_PAGE = page
  AMU_FIND.sync_pager("toggles", total_pages, page)

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

      -- Webpage: where this mod was downloaded from (git, Nexus, or the link pasted in 'No Source')
      local has_web = AMU_WEB.links(folder)[1] ~= nil
      G.FUNCS["amu_web_mod_" .. row_i] = function(e)
        amu_per_mod_status[folder] = AMU_WEB.open_first(folder, entry.display, nil, true)
      end

      -- name on the left, the update status, Webpage, then toggle + Check together on the far right
      local row_nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 5.9 }, nodes = {
          { n = G.UIT.T, config = { text = amu_fit(entry.display, 0.5, 5.7), scale = 0.5, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.C, config = { align = "cl", padding = 0.04, minw = 3.7 }, nodes = {
          { n = G.UIT.T, config = { ref_table = amu_per_mod_status, ref_value = folder, scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 1.8, minh = 0.5, r = 0.09,
          colour = has_web and G.C.BLUE or RGBA(0.5, 0.5, 0.5, 0.9), button = "amu_web_mod_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Webpage", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.C, config = { align = "cm", padding = 0, minw = 1.2 }, nodes = {
          amu_tight_toggle {
            scale = 0.5,
            ref_table = config.mod_update_enabled,
            ref_value = entry.folder,
            callback = function()
              write_ps1_config_overlay()
            end
          },
        }},
        { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 2.0, minh = 0.5, r = 0.09,
          colour = check_colour, button = "amu_check_mod_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Check", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } }
        }},
      }
      rows[#rows+1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_TOG_ROW_H }, nodes = row_nodes }
    end
  end

  local shown = math.max(0, end_i - start_i + 1)
  local blank_from = shown + 1
  if shown == 0 and (AMU_FIND.active("toggles") or AMU_FIND.filtering("toggles")) then
    rows[#rows+1] = { n = G.UIT.R, config = { align = "cm", padding = 0.02, minh = AMU_TOG_ROW_H, minw = AMU_TOG_W - 0.5 }, nodes = {
      { n = G.UIT.T, config = { text = "No mods match your search or filter", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } } } }
    blank_from = 2
  end
  for _ = blank_from, MODS_PER_PAGE do rows[#rows+1] = amu_blank_row(AMU_TOG_W - 0.5, AMU_TOG_ROW_H) end

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
  pcall(AMU_UI.save)
  amu_sort_set("toggles", config.sort_toggles)
  amu_refresh_toggles()
end

-- Turn updates on/off for EVERY mod at once (pinned mods always stay off).
-- The first time, the current on/off list is saved automatically so it can be restored.
local function amu_set_all_updates(val)
  -- While a search is active, only the mods it found are changed.
  local only = nil
  if AMU_FIND.active("toggles") or AMU_FIND.filtering("toggles") then
    only = {}
    for _, e in ipairs(AMU_FIND.entries("toggles", config.sort_toggles)) do only[e.folder] = true end
  end
  local changed = 0
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
    if not only or only[folder] then
      local pin = config.mod_pinned and config.mod_pinned[folder]
      if type(pin) == "table" and pin.pinned then
        config.mod_update_enabled[folder] = false
      else
        config.mod_update_enabled[folder] = val
      end
      changed = changed + 1
    end
  end
  pcall(write_ps1_config_overlay)
  if only then
    amu_snap_info.text = "Updates turned " .. (val and "ON" or "OFF") .. " for the " .. changed
      .. " mod(s) shown (pinned mods stay off)."
  else
    amu_snap_info.text = amu_snap_label()
  end
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
    local thread_code = AMU_HIDE_SRC .. [[
      local cmd = ...
      local ok = pcall(function() amu_run(cmd) end)
      local ch = love.thread.getChannel("amu_restore_status")
      ch:push(ok and "done" or "error")
    ]]
    local t = love.thread.newThread(thread_code)
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false,
      blocking = false,
      no_delete = true,   -- survive the event-queue wipe when a run starts
      func = function()
        local msg = channel:pop()
        if msg then
          amu_restore_in_progress = false; amu_restore_folder = nil
          amu_backup_status.text = folder_name ..
            (msg == "done" and " restored. Restart to apply." or " restore error. See last_run.json.")
          if msg == "done" then
            local ok, shown, why = pcall(function()
              return AMU_CRASH.ask_restart({
                folder_name .. " was put back to the saved copy and pinned.",
                "Pinned mods are not updated again until you unpin them (Mod Updater > Backups).",
              })
            end)
            if ok and shown == false then amu_backup_status.text = folder_name .. " restore error: " .. amu_fit(tostring(why or "see last_run.json"), 0.3, 8.5) end
          end
          return true
        end
        return false
      end
    }))
  else
    AMU_RUN(cmd)
    amu_restore_in_progress = false; amu_restore_folder = nil
    amu_backup_status.text = folder_name .. " restored. Restart to apply."
    pcall(function()
      AMU_CRASH.ask_restart({
        folder_name .. " was put back to the saved copy and pinned.",
        "Pinned mods are not updated again until you unpin them (Mod Updater > Backups).",
      })
    end)
  end
end

-- Unpin a mod so auto-updates resume on the next cycle.
local function unpin_mod(folder_name)
  if config.mod_pinned then config.mod_pinned[folder_name] = nil end
  if config.mod_update_enabled then config.mod_update_enabled[folder_name] = true end
  pcall(write_ps1_config_overlay)
  amu_backup_status.text = folder_name .. " unpinned. Updates will resume."
  -- Check this one mod right away: if the source has a newer version it is updated now and the usual results window
  -- (with Restart now / Later) opens. Nothing changes on disk when it is already the newest, so no restart is needed then.
  amu_backup_status.text = folder_name .. " unpinned. Checking for a newer version..."
  run_single_mod_check(folder_name, function(status, summary)
    local text
    if type(summary) == "table" and summary.game_updates_frozen == true then
      text = " unpinned. Updates are paused while a saved game copy is installed, so it was not updated."
    elseif status == "Updated!" then
      text = " unpinned and updated to the newest version. Restart to apply."
    elseif status == "Error" then
      text = " unpinned, but the check had an error. See last_run.json."
    else
      text = " unpinned. It is already on the newest version."
    end
    amu_backup_status.text = folder_name .. text
    pcall(function() amu_update_area("amu_backup_mod_list", build_backup_mods_page(AMU_BACKUP_PAGE)) end)
  end)
  if not amu_per_mod_checking[folder_name] then   -- the check could not start (not Windows, script missing, ...)
    amu_backup_status.text = folder_name .. " unpinned. Updates will resume."
  end
end

-- Steamodded / Lovely backups: smods-<date>.zip and lovely-<date>-winmm.dll in the Updater's _framework_backups folder.
-- (Kept on the AMU_FRAMEWORKS table: main.lua is close to Lua's limit of local variables.)
function AMU_FRAMEWORKS.backups(folder)
  if folder == "_game" then return AMU_GAME.copies() end
  local out = {}
  local ok, items = pcall(love.filesystem.getDirectoryItems, "Mods/" .. mod_folder_name .. "/_framework_backups")
  if not (ok and type(items) == "table") then return out end
  local prefix = folder .. "-"
  for _, name in ipairs(items) do
    local low = name:lower()
    if name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d") then
      if (folder == "smods" and low:sub(-4) == ".zip") or (folder == "lovely" and low:sub(-4) == ".dll") then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out, function(a, b) return a > b end)   -- newest first
  return out
end

function AMU_FRAMEWORKS.label(file)
  local y, mo, d, h, mi, sec = tostring(file):match("(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)(%d%d)")
  local text = y and (y .. "-" .. mo .. "-" .. d .. "  " .. h .. ":" .. mi .. ":" .. sec) or tostring(file)
  if tostring(file):lower():find("version%.dll$") then text = text .. "  (old file name)" end
  local build = tostring(file):match("_b(%d+)$")
  if build then text = text .. "  (build " .. build .. ")" end
  return text
end

function AMU_FRAMEWORKS.unpin(folder)
  if folder == "_game" then return AMU_FRAMEWORKS.game_run("steam") end
  local fw = AMU_FRAMEWORKS[folder]
  if config.framework_pins then config.framework_pins[folder] = nil end
  pcall(write_ps1_config_overlay)
  amu_backup_status.text = ((fw and fw.display) or folder) .. " unpinned. It updates again on the next check."
end

-- Put an earlier Steamodded / Lovely back: autoupdate.ps1 stages it (and pins it), the game then offers Restart now.
-- Nothing is changed until the game restarts, because both are in use while the game runs.
function AMU_FRAMEWORKS.revert(folder, file)
  if folder == "_game" then return AMU_FRAMEWORKS.game_run(file) end
  local fw = AMU_FRAMEWORKS[folder]
  if not fw then return end
  local name = fw.display
  if not is_windows() then amu_backup_status.text = "Windows only"; return end
  local mods_dir = join_path(love.filesystem.getSaveDirectory(), "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then amu_backup_status.text = "autoupdate.ps1 is missing, " .. name .. " was not changed."; return end

  config.framework_pins = config.framework_pins or {}
  local had_pin = config.framework_pins[folder]
  config.framework_pins[folder] = { pinned = true, backup_file = file, pinned_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  pcall(write_ps1_config_overlay)

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-RestoreFrameworkName", safe_quote(folder),
    "-RestoreFrameworkFile", safe_quote(file),
  }, " ")
  amu_backup_status.text = "Getting " .. name .. " ready to go back..."

  local function finish()
    local sum = decode_json(read_all(join_path(mod_path, "last_run.json")) or "")
    local errs = type(sum) == "table" and sum.errors or nil
    if type(errs) == "string" then errs = { errs } end
    if type(sum) == "table" and sum.framework_staged == true and not (type(errs) == "table" and #errs > 0) then
      amu_backup_status.text = name .. " goes back to " .. AMU_FRAMEWORKS.label(file) .. " when the game restarts."
      if type(show_prompt) == "function" then pcall(show_prompt, sum) end
    else
      config.framework_pins[folder] = had_pin
      pcall(write_ps1_config_overlay)
      local why = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "see last_run.json"
      amu_backup_status.text = name .. " was not changed: " .. amu_fit(why, 0.3, 8.5)
    end
  end

  if love and love.thread and love.thread.newThread and love.thread.getChannel then
    local channel = love.thread.getChannel("amu_fw_restore")
    channel:clear()
    local thread_code = AMU_HIDE_SRC .. [[
      local cmd = ...
      local ok = pcall(function() amu_run(cmd) end)
      love.thread.getChannel("amu_fw_restore"):push(ok and "done" or "error")
    ]]
    love.thread.newThread(thread_code):start(cmd)
    G.E_MANAGER:add_event(Event({ blockable = false, blocking = false, no_delete = true, func = function()
      local msg = channel:pop()
      if not msg then return false end
      if msg == "done" then finish() else
        config.framework_pins[folder] = had_pin
        pcall(write_ps1_config_overlay)
        amu_backup_status.text = name .. " was not changed (the helper did not run)."
      end
      return true
    end }))
  else
    AMU_RUN(cmd)
    finish()
  end
end

-- Play a saved copy of the game (which = its folder name) or go back to Steam's newest version ("steam", which also turns
-- mod and framework updates back on). autoupdate.ps1 -UseGameBackup stages it; apply_pending.ps1 swaps the files after the
-- game quits and starts the game through Steam.
function AMU_FRAMEWORKS.game_run(which)
  if not is_windows() then amu_backup_status.text = "Windows only"; return end
  local mods_dir = join_path(love.filesystem.getSaveDirectory(), "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then amu_backup_status.text = "autoupdate.ps1 is missing, the game was not changed."; return end
  local going_steam = (which == "steam")
  pcall(write_ps1_config_overlay)
  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-UseGameBackup", safe_quote(which),
  }, " ")
  amu_backup_status.text = "Getting the game files ready..."

  local function finish()
    local sum = decode_json(read_all(join_path(mod_path, "last_run.json")) or "")
    local errs = type(sum) == "table" and sum.errors or nil
    if type(errs) == "string" then errs = { errs } end
    if type(sum) == "table" and sum.framework_staged == true and not (type(errs) == "table" and #errs > 0) then
      if going_steam then
        amu_backup_status.text = "Steam's newest game version comes back and updates turn on when the game restarts."
      else
        amu_backup_status.text = "That saved game copy is played when the game restarts. Mod updates stay paused."
      end
      pcall(function() amu_update_area("amu_backup_mod_list", build_backup_mods_page(AMU_BACKUP_PAGE)) end)
      if type(show_prompt) == "function" then pcall(show_prompt, sum) end
    elseif going_steam and type(sum) == "table" and not (type(errs) == "table" and #errs > 0) then
      amu_backup_status.text = "Already on Steam's version. Mod and framework updates are on."
      pcall(function() amu_update_area("amu_backup_mod_list", build_backup_mods_page(AMU_BACKUP_PAGE)) end)
    else
      local why = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "see last_run.json"
      amu_backup_status.text = "The game was not changed: " .. amu_fit(why, 0.3, 8.5)
    end
  end

  if love and love.thread and love.thread.newThread and love.thread.getChannel then
    local channel = love.thread.getChannel("amu_game_run")
    channel:clear()
    local thread_code = AMU_HIDE_SRC .. [[
      local cmd = ...
      local ok = pcall(function() amu_run(cmd) end)
      love.thread.getChannel("amu_game_run"):push(ok and "done" or "error")
    ]]
    love.thread.newThread(thread_code):start(cmd)
    G.E_MANAGER:add_event(Event({ blockable = false, blocking = false, no_delete = true, func = function()
      local msg = channel:pop()
      if not msg then return false end
      if msg == "done" then finish() else amu_backup_status.text = "The game was not changed (the helper did not run)." end
      return true
    end }))
  else
    AMU_RUN(cmd)
    finish()
  end
end

---------------------------------------------------------------------------
-- CONFIG TAB: Settings (general toggles + Nexus key + check now)
---------------------------------------------------------------------------

-- Remembers the sorting and the Fork Finder's list filters in ui_state.json the moment they change. Steamodded only saves
-- its config when the Mods menu is left, so a choice was lost when the game was closed (or restarted) any other way.
AMU_UI = { keys = { "sort_toggles", "sort_backups", "sort_forks", "fork_newer_only", "fork_hide_translations", "fork_show_ignored" } }
AMU_UI.ready = false
function AMU_UI.save_config()
  if not AMU_UI.ready then return end   -- not while this mod is still loading
  local m = mod or (SMODS and SMODS.current_mod)
  if not m then return end
  if type(m.save_mod_config) == "function" then pcall(m.save_mod_config, m)
  elseif SMODS and type(SMODS.save_mod_config) == "function" then pcall(SMODS.save_mod_config, m) end
end
function AMU_UI.path()
  local d = amu_mod_path()
  if d == "" then return nil end
  return join_path(d, "ui_state.json")
end
function AMU_UI.save()
  local path = AMU_UI.path()
  if not path then return end
  local out = {}
  for _, k in ipairs(AMU_UI.keys) do
    if config[k] ~= nil then out[k] = config[k] end
  end
  out.filter_toggles = AMU_FIND.filter.toggles
  out.filter_backups = AMU_FIND.filter.backups
  local f = io.open(path, "wb")
  if f then f:write(encode_json(out)); f:close() end
end
function AMU_UI.load()
  local path = AMU_UI.path()
  local d = path and decode_json(read_all(path) or "")
  if type(d) ~= "table" then return end
  -- the Show: filters (the pill and button text is rebuilt from AMU_FIND.filter when the tab is drawn)
  local valid = { toggles = { all = true, on = true, off = true }, backups = { all = true, pinned = true } }
  for w, ok in pairs(valid) do
    local v = d["filter_" .. w]
    if type(v) == "string" and ok[v] then AMU_FIND.filter[w] = v end
  end
  for _, k in ipairs(AMU_UI.keys) do
    local v = d[k]
    if v ~= nil then
      if string.sub(k, 1, 5) == "sort_" then
        if v == "az" or v == "recent" then config[k] = v end
      elseif type(v) == "boolean" then
        config[k] = v
      end
    end
  end
end
pcall(AMU_UI.load)
AMU_UI.ready = true

-- Hover explainers for the General Settings toggles (shown in the game's own tooltip popup).
-- Keep every line short: the popup does not wrap text.
AMU_FIND.CFG_TIPS = {
  auto_run = { "When Balatro starts, the Updater checks for", "new mod versions in the background.", "Off: nothing is checked until you press", "Check for updates now." },
  cfg_update_git = { "Mods installed from Git (they have a .git", "folder) are brought up to date from their", "repository. Backed up first if Make backups", "is on." },
  cfg_update_updatejson = { "Mods that ship an update.json file are", "checked and updated from the source it", "names: a GitHub release, a GitHub branch", "or Nexus Mods." },
  cfg_make_backups = { "Before a mod is changed, its current files", "are saved as a zip in the Updater's backups", "folder. That is what the Backups tab and the", "startup crash screen put back." },
  cfg_update_steamodded = { "Download new Steamodded versions. A new one", "is put in place when the game restarts,", "with your old copy kept in case of a crash." },
  cfg_update_lovely = { "Download new Lovely Injector versions. A new", "one is put in place when the game restarts,", "with your old copy kept in case of a crash." },
  cfg_show_framework_current = { "After a check, also say when Steamodded and", "Lovely were already up to date.", "Off hides that note. New versions and", "problems are always shown." },
  cfg_pin_retry = { "A pinned mod (put back after a crash, or", "pinned by you) is tried again, straight to its", "LATEST version, once its source offers a", "different version than the one you pinned." },
  cfg_game_auto_switch = { "When Steam updates Balatro, the saved copy of", "the version you were on is put back, so your", "mods keep working. Mod, Steamodded and Lovely", "updates pause until you turn them on in", "Backups > Balatro game files." },
}

-- Red text that pulses (used for "Your downloaded copy does NOT have it yet"): a shared colour table, changed every frame.
AMU_FIND.BLINK_RED = { 0.85, 0.1, 0.1, 1 }
G.FUNCS = G.FUNCS or {}
G.FUNCS.amu_blink_red = function(e)
  local t = (G.TIMERS and G.TIMERS.REAL) or 0
  local k = 0.5 + 0.5 * math.sin(t * 6.3)
  local c = AMU_FIND.BLINK_RED
  c[1] = 0.55 + 0.4 * k; c[2] = 0.04 + 0.1 * k; c[3] = 0.04 + 0.1 * k; c[4] = 0.35 + 0.65 * k
end

function AMU_FIND.cfg_tip(title, lines)
  return { filler = { func = function()
    local dark = (G.C.UI and G.C.UI.TEXT_DARK) or RGBA(0.2, 0.2, 0.25, 1)
    local rows = { { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = tostring(title), scale = 0.34, colour = G.C.BLUE or dark } } } } }
    for _, t in ipairs(lines or {}) do
      local txt, col = t, dark
      if type(t) == "table" then txt, col = t.text, t.colour or dark end   -- a line can be { text = ..., colour = ... }
      local tcfg = { text = tostring(txt), scale = 0.27, colour = col }
      if type(t) == "table" and t.blink then tcfg.colour = AMU_FIND.BLINK_RED; tcfg.func = "amu_blink_red" end
      local tnode = { n = G.UIT.T, config = tcfg }
      if type(t) == "table" and (t.bullet or t.indent) then
        -- bullet drawn as a small square (the game font has no bullet glyph); wrapped lines sit under the text
        local sq = t.bullet and { n = G.UIT.B, config = { w = 0.12, h = 0.12, colour = tcfg.colour } } or { n = G.UIT.B, config = { w = 0.12, h = 0.12 } }
        if t.star then
          -- a small plus-shaped star (3 x 3 tiny squares) so this line looks different from the square bullets
          local function cell(on) return { n = G.UIT.B, config = { w = 0.04, h = 0.04, colour = on and tcfg.colour or (G.C.CLEAR or { 0, 0, 0, 0 }) } } end
          local function rw(a, b, c) return { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { cell(a), cell(b), cell(c) } } end
          sq = { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = { rw(false, true, false), rw(true, true, true), rw(false, true, false) } }
        end
        rows[#rows + 1] = { n = G.UIT.R, config = { align = "tl", padding = 0.01 }, nodes = {
          { n = G.UIT.C, config = { align = "tm", padding = 0.04 }, nodes = { sq } },
          { n = G.UIT.B, config = { w = 0.1, h = 0.1 } },
          { n = G.UIT.C, config = { align = "tl", padding = 0 }, nodes = { tnode } } } }
      else
        rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.01 }, nodes = { tnode } }
      end
    end
    return { n = G.UIT.R, config = { align = "cl", padding = 0.03 }, nodes = {
      { n = G.UIT.C, config = { align = "cl", padding = 0.03 }, nodes = rows } } }
  end, args = {} } }
end

-- Put a tooltip on a node and everything inside it (so hovering the label, the gap or the box all show it).
function AMU_FIND.attach_tip(node, tip)
  if type(node) ~= "table" or not tip then return node end
  if node.n ~= G.UIT.O then
    node.config = node.config or {}
    node.config.on_demand_tooltip = tip
  end
  for _, c in ipairs(node.nodes or {}) do AMU_FIND.attach_tip(c, tip) end
  return node
end

SMODS.current_mod.config_tab = function()
  local purple = AMU_FIND.theme_purple()
  local panel = RGBA(0.15, 0.15, 0.15, 0.95)

  amu_nexus_display.text = mask_nexus_key(config.nexus_api_key)
  pcall(AMU_GAME.sync_status)

  local function section(title, nodes, minw)
    local rows = { { n = G.UIT.R, config = { align = "cm", padding = 0.05, minh = 0.6 }, nodes = {
      { n = G.UIT.T, config = { text = title, scale = 0.52, colour = purple, shadow = true } } } } }
    for _, nd in ipairs(nodes) do rows[#rows + 1] = nd end
    return { n = G.UIT.C, config = { align = "tm", padding = 0.12, minw = minw, minh = 5.0, r = 0.12, colour = panel }, nodes = rows }
  end

  -- LEFT: general settings (big toggles, room for controller glyphs)
  -- Controller: a toggle only answers Up/Down to the toggles in its own column ('tall' navigation), so Up/Down on the
  -- right-hand buttons never jumps over to a toggle on the left.
  local function tall(node)
    if type(node) ~= "table" then return node end
    if node.config and node.config.focus_args then node.config.focus_args.nav = "tall" end
    for _, c in ipairs(node.nodes or {}) do tall(c) end
    return node
  end
  local function trow(label, key, with_cb)
    local tg = tall(create_toggle { label = label, ref_table = config, ref_value = key, w = 0, scale = 0.5,
      callback = with_cb and function() write_ps1_config_overlay() end or nil })
    local tl = AMU_FIND.CFG_TIPS[key]
    if tl then AMU_FIND.attach_tip(tg, AMU_FIND.cfg_tip(label, tl)) end
    return { n = G.UIT.R, config = { align = "cl", padding = 0.03, minh = 0.5 }, nodes = {
      { n = G.UIT.B, config = { w = 0.35, h = 0.1 } },
      tg,
    }}
  end
  local left = section("General Settings", {
    trow("Auto-check at startup", "auto_run", false),
    trow("Update from Git repos", "cfg_update_git", true),
    trow("Update via update.json", "cfg_update_updatejson", true),
    trow("Make backups", "cfg_make_backups", true),
    trow("Update Steamodded", "cfg_update_steamodded", true),
    trow("Update Lovely Injector", "cfg_update_lovely", true),
    trow("Say when frameworks current", "cfg_show_framework_current", false),
    trow("Retry pinned mods when newer", "cfg_pin_retry", true),
    trow("Auto-switch to saved game", "cfg_game_auto_switch", true),
  }, 7.2)

  -- RIGHT: Nexus key, then the "check now" button
  local rnodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 6.6, minh = 0.7, r = 0.1, colour = G.C.BLACK }, nodes = {
        { n = G.UIT.T, config = { ref_table = amu_nexus_display, ref_value = "text", scale = 0.42, colour = G.C.UI.TEXT_LIGHT } } } } } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 3.9, minh = 0.7, r = 0.1, colour = G.C.BLUE,
          button = "amu_paste_nexus_key", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Paste from clipboard", scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } },
      { n = G.UIT.B, config = { h = 0.1, w = 0.2 } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 2.4, minh = 0.7, r = 0.1, colour = G.C.RED,
          button = "amu_clear_nexus_key", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Clear", scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } },
    }},
    { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 6.6, minh = 0.55, r = 0.1, colour = G.C.BLUE,
          button = "amu_nx_help_open", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "How do I get a key?  (opens Nexus)", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } } } } } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 6.6, minh = 0.95, r = 0.12, colour = G.C.GREEN,
          button = "amu_check_updates_now", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Check for updates now", scale = 0.52, colour = purple } } } },
    }},
    { n = G.UIT.R, config = { align = "cm", padding = 0.03, minh = 0.62 }, nodes = {
      { n = G.UIT.T, config = { ref_table = amu_check_status, ref_value = "text", scale = 0.48, colour = G.C.UI.TEXT_LIGHT } } } },
  }
  -- mods are waiting for an answer about a startup crash (after "Not now"): button to bring the question back
  local n_waiting = #AMU_CRASH.read_pending()
  if n_waiting > 0 then
    rnodes[#rnodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 6.6, minh = 0.65, r = 0.1,
          colour = G.C.ORANGE or purple, button = "amu_crash_review", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = "Startup crash: review " .. n_waiting .. " mod(s)", scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } } } }
  end
  local right = section("Nexus API Key", rnodes, 7.2)

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.08, colour = G.C.BLACK, r = 0.1, emboss = 0.05, minh = 6.2, minw = 15.6 },
    nodes = {
      amu_header_row("Mod Updater", 0.5),
      { n = G.UIT.R, config = { align = "tm", padding = 0.1 }, nodes = { left, { n = G.UIT.B, config = { w = 0.2, h = 0.1 } }, right } },
    }
  }
end

---------------------------------------------------------------------------
-- DESCRIPTION PAGE (the first tab): short cards instead of one block of text
---------------------------------------------------------------------------
SMODS.current_mod.custom_ui = function(modNodes)
  local ok, node = pcall(function()
    local card_bg = RGBA(0.15, 0.15, 0.15, 0.95)
    local light = G.C.UI.TEXT_LIGHT
    local function card(title, col, lines)
      local rows = { { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        { n = G.UIT.T, config = { text = title, scale = 0.42, colour = col, shadow = true } } } } }
      for _, ln in ipairs(lines) do
        rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.015 }, nodes = {
          { n = G.UIT.T, config = { text = ln, scale = 0.31, colour = light } } } }
      end
      return { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 6.2, minh = 1.45, r = 0.12, colour = card_bg }, nodes = rows }
    end
    local gap = { n = G.UIT.B, config = { w = 0.2, h = 0.1 } }
    local function row(a, b)
      return { n = G.UIT.R, config = { align = "cm", padding = 0.07 }, nodes = { a, gap, b } }
    end
    return { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.T, config = { text = "Keeps your Balatro mods up to date, safely.", scale = 0.42, colour = light, shadow = true } } } },
      row(card("Updates", G.C.GREEN or light, { "Mods, Steamodded and Lovely.", "A backup before every change." }),
          card("Search & Sort", G.C.BLUE or light, { "Find mods fast on Toggles,", "Backups and Fork Finder." })),
      row(card("Fork Finder", G.C.PURPLE or light, { "Original, parent and forks,", "newest first. Switch in one press." }),
          card("Crash Protection", G.C.RED or light, { "Puts updated mods back if the", "game won't start." })),
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.T, config = { text = "Also saves your game files. Works with mouse, keyboard and controller.", scale = 0.32, colour = light } } } },
    }}
  end)
  if ok and node then
    -- slot 1 is the author line, slot 2 the plain description text: swap that one
    if modNodes[2] then modNodes[2] = node else modNodes[#modNodes + 1] = node end
  end
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
  local purple = AMU_FIND.theme_purple()

  local rows = {}
  local start_i = (page - 1) * AMU_NS_PER + 1
  local end_i = math.min(#entries, page * AMU_NS_PER)

  if #entries == 0 then
    rows[1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_NS_ROW_H }, nodes = {
      { n = G.UIT.T, config = { text = "Every checked mod has an update source.", scale = 0.5, colour = purple } } } }
    rows[2] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_NS_ROW_H }, nodes = {
      { n = G.UIT.T, config = { text = "(Run 'Check for updates now' to refresh this list.)", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } }
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
          amu_nosrc_msg.text = "Copy the mod's GitHub or Nexus webpage link first, then press again."
          return
        end
        if write_update_json(folder, kind, val) then
          amu_nosrc_msg.text = display .. ": saved (" .. kind .. " " .. tostring(val) .. "). Checked from the next update run."
        else
          amu_nosrc_msg.text = "Couldn't write update.json for " .. display
        end
        amu_update_area("amu_nosrc_list", build_nosrc_page(AMU_NOSRC_PAGE))
      end
      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_NS_ROW_H }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 10.4 }, nodes = {
          { n = G.UIT.T, config = { text = amu_fit(display, 0.5, 10.2), scale = 0.5, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 3.6, minh = 0.56, r = 0.1,
          colour = G.C.BLUE, button = "amu_nosrc_paste_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Paste link", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } } } },
      }}
    end
  end

  local filled = (#entries == 0) and 2 or math.max(0, end_i - start_i + 1)
  for _ = filled + 1, AMU_NS_PER do
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_NS_ROW_H }, nodes = {
      { n = G.UIT.B, config = { h = AMU_NS_ROW_H - 0.04, w = AMU_NS_W - 0.5 } } } }
  end

  return amu_list_root(rows, AMU_NS_W, AMU_NS_H)
end

G.FUNCS.amu_nosrc_page = function(args)
  if not args or not args.cycle_config then return end
  AMU_NOSRC_PAGE = args.cycle_config.current_option or 1
  amu_update_areas({ ["amu_nosrc_list"] = build_nosrc_page(AMU_NOSRC_PAGE) })
end

---------------------------------------------------------------------------
-- SEARCH: screen parts and actions (data side is near get_sorted_mod_entries)
---------------------------------------------------------------------------

-- Rebuild a tab's list for the new search, starting at page 1.
function AMU_FIND.refresh(which)
  if which == "toggles" then
    AMU_CONFIG_PAGE = 1
    amu_update_area(AMU_FIND.list_id.toggles, build_mod_toggles_page(1))
  elseif which == "forks" then
    AMU_FORK_PAGE = 1
    amu_update_area(AMU_FIND.list_id.forks, build_fork_mods_page(1))
  else
    AMU_BACKUP_PAGE = 1
    amu_update_area(AMU_FIND.list_id.backups, build_backup_mods_page(1))
  end
end

-- The "Show:" button: All -> ON -> OFF (Mod Toggles), All -> Pinned (Backups). Not remembered after the menu closes
-- (like the search box, so mods never look like they went missing).
AMU_FIND.FILTER_ORDER = { toggles = { "all", "on", "off" }, backups = { "all", "pinned" } }
AMU_FIND.FILTER_TEXT = {
  toggles = { all = "All", on = "ON", off = "OFF" },
  backups = { all = "All", pinned = "Pinned" },
}
-- Same idea as the sort control: a "Show: <what is shown now>" pill and a "Next: <what the button switches to>" button.
function AMU_FIND.filter_after(which, cur)
  local order = AMU_FIND.FILTER_ORDER[which]
  local idx = 1
  for i, v in ipairs(order) do if v == cur then idx = i end end
  return order[(idx % #order) + 1]
end
function AMU_FIND.filter_sync(which)
  local cur = AMU_FIND.filter[which]
  local names = AMU_FIND.FILTER_TEXT[which]
  AMU_FIND.filter_now[which].text = names[cur] or "All"
  AMU_FIND.filter_nxt[which].text = "Next: " .. (names[AMU_FIND.filter_after(which, cur)] or "All")
end
function AMU_FIND.filter_node(which, now_w, next_w)
  AMU_FIND.filter_sync(which)
  local pill = HEX and HEX("2B2B35") or { 0.17, 0.17, 0.21, 1 }
  local dim  = HEX and HEX("A9A9B8") or { 0.66, 0.66, 0.72, 1 }
  return { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = now_w, minh = 0.44, r = 0.1, colour = pill }, nodes = {
        { n = G.UIT.T, config = { text = "Show: ", scale = 0.28, colour = dim } },
        { n = G.UIT.T, config = { ref_table = AMU_FIND.filter_now[which], ref_value = "text", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } },
      { n = G.UIT.B, config = { w = 0.08, h = 0.1 } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = next_w, minh = 0.44, r = 0.1,
          colour = G.C.BLUE, button = "amu_filter_" .. which, hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { ref_table = AMU_FIND.filter_nxt[which], ref_value = "text", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } },
    } } } }
end
function AMU_FIND.filter_next(which, _e)
  AMU_FIND.filter[which] = AMU_FIND.filter_after(which, AMU_FIND.filter[which])
  AMU_FIND.filter_sync(which)
  pcall(AMU_UI.save)
  pcall(AMU_FIND.refresh, which)
end
G.FUNCS.amu_filter_toggles = function(e) AMU_FIND.filter_next("toggles", e) end
G.FUNCS.amu_filter_backups = function(e) AMU_FIND.filter_next("backups", e) end

-- Runs every frame on the glyph cell inside << and >>: shows the "hold" label only while a controller is the active input.
G.FUNCS.amu_pg_pip = function(e)
  local pad = (G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller) and true or false
  local par = e.parent
  if par and par.children then
    for _, ch in pairs(par.children) do
      if type(ch) == "table" and ch.config and ch.config.id == "amu_pg_hold" and type(ch.config.colour) == "table" then
        ch.config.colour[4] = pad and 1 or 0
      end
    end
  end
  return G.FUNCS.set_button_pip(e)
end

-- Runs every frame on the << / >> label: the button reserves a row above it for "hold [LB]"; with no controller that row is
-- invisible, so the label is drawn that much higher (AMU_FIND.SKIP_DY, game units) to sit in the middle of its button.
-- Only the drawn position changes (no re-layout). A fresh layout offset is detected and used as the new base.
AMU_FIND.SKIP_DY = 0.16
G.FUNCS.amu_pg_label = function(e)
  local c = e.config
  local off = e.role and e.role.offset
  if not off then return end
  local pad = (G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller) and true or false
  c.refresh_movement = true
  if c._amu_off ~= off or off.y ~= c._amu_y then c._amu_base = off.y end
  local target = c._amu_base - (pad and 0 or AMU_FIND.SKIP_DY)
  off.y = target
  c._amu_off, c._amu_y = off, target
end

-- Runs every frame on the < and > page arrows: the game draws them a little higher than the middle of the Page box, so
-- their drawn position gets a small push down (AMU_FIND.ARROW_DY, in game units). A re-layout hands the arrow a fresh
-- offset, which is pushed down once more; the counter stops any runaway.
AMU_FIND.ARROW_DY = 0.06
-- ARROW_DX: the left arrow is also drawn this much further left and the right arrow further right, so the gap between
-- each skip button and its arrow equals the gap between the arrow and the Page box.
AMU_FIND.ARROW_DX = 0.0225
G.FUNCS.amu_pg_arrow = function(e)
  local c = e.config
  local off = e.role and e.role.offset
  if not off then return end
  c.refresh_movement = true
  if c._amu_off ~= off or off.y ~= c._amu_y or off.x ~= c._amu_x then
    c._amu_n = (c._amu_n or 0) + 1
    if c._amu_n <= 40 then
      off.y = off.y + AMU_FIND.ARROW_DY
      off.x = off.x + (c.ref_value == "l" and -AMU_FIND.ARROW_DX or AMU_FIND.ARROW_DX)
      c._amu_off, c._amu_y, c._amu_x = off, off.y, off.x
    end
  end
end

-- The << and >> buttons next to the page selector: first page / last page of that list.
function AMU_FIND.jump(id, last)
  local r = AMU_FIND.pg[id]
  if not r then return end
  local a = r.args
  local n = (type(a) == "table" and type(a.options) == "table") and #a.options or 1
  local target = last and math.max(1, n) or 1
  if type(a) == "table" and type(a.options) == "table" then
    a.current_option = target
    a.current_option_val = a.options[target]
  end
  pcall(r.set_page, target)
  amu_update_area(id, r.build(target))
end

-- Runs every frame on a node in the search row: re-filter when the text changed.
function AMU_FIND.watch(which)
  local _, norm = AMU_FIND.words(AMU_FIND[which].text)
  if norm == AMU_FIND.applied[which] then return end
  AMU_FIND.applied[which] = norm
  if AMU_FIND.pending[which] then return end
  AMU_FIND.pending[which] = true
  G.E_MANAGER:add_event(Event({
    blocking = false, blockable = false,
    func = function()
      AMU_FIND.pending[which] = nil
      pcall(AMU_FIND.refresh, which)
      return true
    end
  }))
end
G.FUNCS.amu_find_watch_toggles = function(_e) AMU_FIND.watch("toggles") end
G.FUNCS.amu_find_watch_backups = function(_e) AMU_FIND.watch("backups") end
G.FUNCS.amu_find_watch_forks = function(_e) AMU_FIND.watch("forks") end

-- Find the text box of a tab's search row.
function AMU_FIND.box(which)
  local om = G and G.OVERLAY_MENU
  local row = om and om.get_UIE_by_ID and om:get_UIE_by_ID("amu_find_row_" .. which)
  return row and om:get_UIE_by_ID("text_input", row)
end

-- Jump into the box and start typing (on a controller the game opens its on-screen keyboard).
function AMU_FIND.focus(which)
  local C = G and G.CONTROLLER
  if not C or C.text_input_hook or C.screen_keyboard or C.locked then return false end
  local box = AMU_FIND.box(which)
  if not box or not G.FUNCS.select_text_input then return false end
  G.FUNCS.select_text_input(box)
  return true
end

-- Build the open tab's contents again IN PLACE - exactly what the game does when you switch tabs, so nothing slides
-- and the menu around it stays put. `any_id` = the id of any node on the tab. Returns true when it worked.
function AMU_FIND.swap_tab(any_id)
  if G and G.CONTROLLER and G.CONTROLLER.screen_keyboard and not G.CONTROLLER.text_input_hook then pcall(AMU_FIND.close_osk) end
  local om = G and G.OVERLAY_MENU
  local node = om and om.get_UIE_by_ID and om:get_UIE_by_ID(any_id)
  local box = node and node.UIBox
  local tc = box and box.config and box.config.parent
  local def = AMU_FIND.current_def
  if node and not (tc and tc.config and tc.config.id == "tab_contents" and tc.config.object == box) then
    -- the node sits in a nested box: use the menu's own tab area instead
    local t2 = om and om.get_UIE_by_ID and om:get_UIE_by_ID("tab_contents")
    tc = (t2 and t2.config and t2.config.object and t2.UIBox) and t2 or nil
  end
  if not (tc and tc.config and tc.config.object and type(def) == "function") then
    return false
  end
  local ok = pcall(function()
    tc.config.object:remove()
    tc.config.object = UIBox({
      definition = def(),
      config = { offset = { x = 0, y = 0 }, parent = tc, type = "cm" },
    })
    tc.UIBox:recalculate()
  end)
  if not ok then return false end
  if AMU_FIND.last_fill then pcall(AMU_FIND.last_fill) end   -- fill the list now (no empty frame)
  return true
end

-- Put the controller cursor on a button of the open menu (after its tab was rebuilt).
function AMU_FIND.snap_to_button(button)
  local C = G and G.CONTROLLER
  if not (C and C.HID and C.HID.controller and C.snap_to) then return end
  -- Returns true once the cursor is on the button. The game can drop the focus for a few frames after a rebuild (and
  -- after the on-screen keyboard closes), so this is repeated each frame for up to about 0.7 s until it sticks.
  local function go()
    local n = amu_find_node(function(c) return c.button == button end)
    if not n then return false end
    if C.focused and C.focused.target == n then return true end
    if C.interrupt then C.interrupt.focus = false end
    C:snap_to({ node = n })
    if C.update_cursor then C:update_cursor() end
    return C.focused and C.focused.target == n
  end
  if pcall(go) and C.focused and C.focused.target and C.focused.target.config and C.focused.target.config.button == button then
    return
  end
  if G.E_MANAGER and Event then
    local t0 = (G.TIMERS and G.TIMERS.REAL) or 0
    G.E_MANAGER:add_event(Event({ blocking = false, blockable = false, no_delete = true, func = function()
      local ok, done = pcall(go)
      if ok and done then return true end
      return ((G.TIMERS and G.TIMERS.REAL) or 0) - t0 > 0.7
    end }))
  end
end

-- Empty the text box's own letters (used when the tab cannot be rebuilt in place) so the box shows its prompt again.
function AMU_FIND.reset_box(which)
  local om = G and G.OVERLAY_MENU
  local row = om and om.get_UIE_by_ID and om:get_UIE_by_ID("amu_find_row_" .. which)
  if not row then return end
  local seen = {}
  local function rec(n, depth)
    if type(n) ~= "table" or seen[n] or depth > 12 then return end
    seen[n] = true
    local rt = n.config and n.config.ref_table
    if type(rt) == "table" and type(rt.text) == "table" and type(rt.text.letters) == "table" then
      for k in pairs(rt.text.letters) do rt.text.letters[k] = "" end
      rt.text.current_position = 0
    end
    if type(n.children) == "table" then for _, c in pairs(n.children) do rec(c, depth + 1) end end
  end
  rec(row, 0)
end

-- Clear: empty the search and rebuild only the tab's contents (no slide, the rest of the menu stays still).
-- (Emptying the box through the game's own text-box code made the game lay the tab out twice in one frame, which
-- pushed the whole tab to the right.) The controller cursor is left to the game (no forced jump to Clear).
function AMU_FIND.clear(which)
  local st = AMU_FIND[which]
  local C = G and G.CONTROLLER
  if C and AMU_FIND.owns_hook(C.text_input_hook) then C.text_input_hook = nil end
  if st.text == "" then return end
  st.text = ""
  AMU_FIND.applied[which] = ""
  AMU_FIND.pending[which] = nil
  if which == "toggles" then AMU_CONFIG_PAGE = 1 elseif which == "forks" then AMU_FORK_PAGE = 1 else AMU_BACKUP_PAGE = 1 end
  if not AMU_FIND.swap_tab("amu_find_row_" .. which) then
    -- never reopen the whole menu (that is the slide-up reload): update the list and the box where they are
    pcall(AMU_FIND.reset_box, which)
    pcall(AMU_FIND.refresh, which)
    return
  end
end
G.FUNCS.amu_find_clear_toggles = function(_e) AMU_FIND.clear("toggles") end
G.FUNCS.amu_find_clear_backups = function(_e) AMU_FIND.clear("backups") end
G.FUNCS.amu_find_clear_forks = function(_e) AMU_FIND.clear("forks") end

-- Hooks the search needs (installed the first time a search row is built, when Steamodded's menu exists).
function AMU_FIND.install()
  if AMU_FIND.installed then return end
  AMU_FIND.installed = true

  -- The game turns the key "0" into the letter "o" in every text box; searching for "v1.0" needs the real zero.
  local old_key = G.FUNCS.text_input_key
  if type(old_key) == "function" then
    G.FUNCS.text_input_key = function(args)
      local hook = G.CONTROLLER and G.CONTROLLER.text_input_hook
      if args and args.key == "0" and AMU_FIND.owns_hook(hook)
         and type(TRANSPOSE_TEXT_INPUT) == "function" and type(MODIFY_TEXT_INPUT) == "function" then
        local cfg = hook.config.ref_table
        local text = cfg.text
        if cfg.max_length > string.len(text.ref_table[text.ref_value]) then
          TRANSPOSE_TEXT_INPUT(0)
          MODIFY_TEXT_INPUT{ letter = "0", text_table = text, pos = text.current_position + 1 }
          TRANSPOSE_TEXT_INPUT(1)
        end
        return
      end
      return old_key(args)
    end
  end

  -- Never leave our box hooked to a menu that is gone (every key would be swallowed).
  for _, name in ipairs({ "overlay_menu", "exit_overlay_menu" }) do
    local old_fn = G.FUNCS[name]
    if type(old_fn) == "function" then
      G.FUNCS[name] = function(...)
        pcall(AMU_FIND.drop_hook)
        return old_fn(...)
      end
    end
  end

  -- Esc while typing only leaves the box (the game does that itself right after this); it must not close the menu.
  -- Leaving the Mods menu for real empties both searches.
  local old_exit = G.FUNCS.exit_mods
  if type(old_exit) == "function" then
    G.FUNCS.exit_mods = function(e, ...)
      if not e and G.CONTROLLER and AMU_FIND.owns_hook(G.CONTROLLER.text_input_hook) then return end
      pcall(AMU_FIND.drop_hook)
      AMU_FIND.reset_all()
      return old_exit(e, ...)
    end
  end

  -- S (keyboard) / R3 (right stick press): tap = jump into the box, hold = clear it.
  if Controller and not Controller._amu_find_keys then
    Controller._amu_find_keys = true
    local kp, kr = Controller.key_press_update, Controller.key_release_update
    if type(kp) == "function" then
      Controller.key_press_update = function(self, key, ...)
        if key == "s" and not self.text_input_hook then
          local ok, done = pcall(AMU_FIND.hold_begin, "s")
          if ok and done then return end
        end
        return kp(self, key, ...)
      end
    end
    if type(kr) == "function" then
      Controller.key_release_update = function(self, key, ...)
        if key == "s" then pcall(AMU_FIND.hold_end, "s") end
        return kr(self, key, ...)
      end
    end
    local bp, br = Controller.button_press_update, Controller.button_release_update
    if type(bp) == "function" then
      Controller.button_press_update = function(self, button, ...)
        if button == "rightstick" and not self.text_input_hook and not (self.locks and self.locks.frame) then
          local ok, done = pcall(AMU_FIND.hold_begin, "rightstick")
          if ok and done then return end
        end
        return bp(self, button, ...)
      end
    end
    if type(br) == "function" then
      Controller.button_release_update = function(self, button, ...)
        if button == "rightstick" then pcall(AMU_FIND.hold_end, "rightstick") end
        return br(self, button, ...)
      end
    end
  end
end

-- Left of the page selector: "[ Search: ] [ type here ] [Clear]"
function AMU_FIND.left(which, side_w, box_w, with_label)
  local input = create_text_input({
    w = box_w,
    max_length = AMU_FIND.MAX,
    text_scale = 0.34,
    prompt_text = "Type to search...",
    ref_table = AMU_FIND[which],
    ref_value = "text",
    extended_corpus = true,   -- allows spaces, - _ . and digits
    colour = HEX and HEX("3A3550") or nil,
    hooked_colour = HEX and HEX("5A2D82") or nil,
  })
  -- The blinking cursor is 0.4 tall by default; make it match the smaller text.
  AMU_FIND.walk(input, function(n)
    if n.config and n.config.id == "position" then n.config.h = 0.36 end
  end)
  local cells = {
    -- this (tiny) node's func runs every frame and notices when the text changed
    { n = G.UIT.C, config = { align = "cm", padding = 0, minw = 0.02, func = "amu_find_watch_" .. which }, nodes = {} },
  }
  if with_label then
    cells[#cells + 1] = { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.T, config = { text = "Search:", scale = 0.34, colour = G.C.UI.TEXT_LIGHT, shadow = true } } } }
  end
  cells[#cells + 1] = input
  cells[#cells + 1] = { n = G.UIT.C, config = { minw = 0.08 }, nodes = {} }
  cells[#cells + 1] = { n = G.UIT.C, config = { align = "cm", padding = 0.05, r = 0.1, minw = 1.0, minh = 0.46,
    colour = G.C.RED, hover = true, shadow = true, button = "amu_find_clear_" .. which }, nodes = {
    { n = G.UIT.T, config = { text = "Clear", scale = 0.33, colour = G.C.UI.TEXT_LIGHT, shadow = true } } } }
  return { n = G.UIT.C, config = { align = "cm", padding = 0, minw = side_w }, nodes = {
    { n = G.UIT.R, config = { id = "amu_find_row_" .. which, align = "cm", padding = 0 }, nodes = cells } } }
end

-- Right of the page selector: "Found 3 of 71" (or the hotkey hint) and how to clear.
function AMU_FIND.right(which, side_w)
  local dim = RGBA(0.78, 0.8, 0.88, 1)
  return { n = G.UIT.C, config = { align = "cm", padding = 0, minw = side_w }, nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.01, minw = side_w }, nodes = {
      { n = G.UIT.T, config = { ref_table = AMU_FIND.info[which], ref_value = "text", scale = 0.32,
        colour = G.C.UI.TEXT_LIGHT, no_recalc = true } } } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.01, minw = side_w }, nodes = {
      { n = G.UIT.T, config = { text = "Hold S / R3 = clear", scale = 0.26, colour = dim } } } },
  }}
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
  local bottom_gap = math.max(0.02, above - 0.33)

  local col = {}
  for _, n in ipairs(o.top) do col[#col + 1] = n end
  col[#col + 1] = spacer(o.gap_top or 0.1)
  col[#col + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
    { n = G.UIT.O, config = { id = o.id, w = o.list_w, h = o.list_h, object = Moveable(), func = "amu_fill_watch" } } } }
  if o.after and o.gap_after then col[#col + 1] = spacer(o.gap_after) end   -- breathing room between the list and the line under it
  for _, n in ipairs(o.after or {}) do col[#col + 1] = n end
  col[#col + 1] = spacer(gap_pager)
  local cyc = {
    w = 3.4, scale = 0.72, options = page_options, current_option = page,
    opt_callback = o.cb, cycle_shoulders = true, no_pips = true,
  }
  local pager_node = create_option_cycle(cyc)
  -- the selector reserves ~0.7 of empty room on each side (for the LB / RB controller icons); shrink it so << and >> sit close
  -- (the game's own columns: minw 0.7 with func = 'set_button_pip', and the 'cycle_shoulders' column with padding 0.1 around the selector)
  AMU_FIND.walk(pager_node, function(n)
    local c = n.config
    if n.n == G.UIT.C and type(c) == "table" then
      if c.func == "set_button_pip" and type(c.minw) == "number" then
        c.minw = 0.01
        -- no glyph here any more: this thin, the game draws it ON TOP of the << and >> buttons.
        -- The LB / RB glyphs now sit inside those two buttons (pg_btn below), where they cannot overlap anything.
        c.func, c.focus_args = nil, nil
      end
      if c.ref_table and (c.ref_value == "l" or c.ref_value == "r") then c.func = "amu_pg_arrow" end   -- the < and > arrows
      if c.id == "cycle_shoulders" then
        c.padding = 0
        local inner = n.nodes and n.nodes[1]   -- the selector itself, which has its own padding 0.1
        if inner and type(inner.config) == "table" then inner.config.padding = 0 end
      end
    end
  end)
  -- << (first page) and >> (last page), one on each side; the gaps keep the LB / RB glyph room next to the arrows
  AMU_FIND.pg[o.id] = { args = AMU_FIND.find_args(pager_node) or cyc, build = o.build, set_page = o.set_page }
  G.FUNCS["amu_pg_first_" .. o.id] = function(_e) AMU_FIND.jump(o.id, false) end
  G.FUNCS["amu_pg_last_" .. o.id]  = function(_e) AMU_FIND.jump(o.id, true) end
  -- (wrapped in a column + row so the button keeps its own small height instead of stretching to the page selector's)
  -- With a controller the button also shows "hold [LB]" / "hold [RB]" above the arrows: holding that bumper does the same
  -- as pressing the button. The glyph is a layout cell inside the button (not an overlay), so nothing can overlap.
  local pad_now = (G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller) and true or false
  local function pg_btn(label, func, pad_button)
    local content = {}
    if pad_button then
      -- The label + glyph row always takes the same room (so the layout never has to be recalculated, which shifted the
      -- text of the whole tab); G.FUNCS.amu_pg_pip (below) only makes the label invisible unless a controller is the
      -- input being used right now. The game removes / adds the glyph itself.
      content[#content + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
        { n = G.UIT.T, config = { id = "amu_pg_hold", text = "hold ", scale = 0.2, colour = RGBA(0.86, 0.88, 0.95, pad_now and 1 or 0) } },
        { n = G.UIT.C, config = { minw = 0.34, minh = 0.15, align = "cm", func = "amu_pg_pip",
            focus_args = { button = pad_button, type = "none", orientation = "cm", scale = 0.34, offset = { x = 0, y = 0 } } }, nodes = {} },
      } }
    end
    content[#content + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.4, colour = G.C.UI.TEXT_LIGHT, func = pad_button and "amu_pg_label" or nil } } } }
    return { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 0.7, minh = 0.5, r = 0.12, colour = G.C.RED,
          button = func, hover = true, shadow = true }, nodes = content } } } } }
  end
  local function pg_pad() return { n = G.UIT.C, config = { minw = 0 }, nodes = {} } end
  local pg_first = pg_btn("<<", "amu_pg_first_" .. o.id, "leftshoulder")
  local pg_last  = pg_btn(">>", "amu_pg_last_" .. o.id, "rightshoulder")
  if total_pages <= 1 then
    -- a single page: nothing to skip to, so no << / >> buttons at all
    pg_first = { n = G.UIT.C, config = { minw = 0 }, nodes = {} }
    pg_last  = { n = G.UIT.C, config = { minw = 0 }, nodes = {} }
  end
  if o.find then
    -- search box on the left of the page selector, "Found x of y" on the right (the selector stays centred)
    AMU_FIND.install()
    AMU_FIND.pager[o.find] = AMU_FIND.find_args(pager_node) or cyc
    local _, norm = AMU_FIND.words(AMU_FIND[o.find].text)
    AMU_FIND.applied[o.find] = norm
    col[#col + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      AMU_FIND.left(o.find, o.find_side, o.find_box, o.find_label),
      { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = { pg_first } },
      pg_pad(),
      { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = { pager_node } },
      pg_pad(),
      { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = { pg_last } },
      AMU_FIND.right(o.find, o.find_side),
    } }
  else
    col[#col + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      pg_first, pg_pad(), pager_node, pg_pad(), pg_last } }
  end
  col[#col + 1] = spacer(bottom_gap)

  local static_def = { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
    { n = G.UIT.C, config = { align = "tm", padding = 0.03, minw = o.panel_w - 0.3 }, nodes = col } } }

  -- fill the list on the next frame (the overlay has to exist first), or right away when the tab is swapped in place
  local filled = { done = false }
  local function fill()
    if filled.done then return end
    filled.done = true
    amu_update_area(o.id, o.build(page))
  end
  AMU_FIND.last_fill = fill
  -- The event below waits in the game's main queue. During a run that queue can be backed up, and the list stayed blank until the
  -- queue caught up (or a page was changed). So the list area also asks to be filled on its own first frame (UI elements run their
  -- func every frame, no queue involved). fill() only runs once, so whichever comes first wins.
  AMU_FIND.fills = AMU_FIND.fills or {}
  AMU_FIND.fills[o.id] = fill
  G.FUNCS.amu_fill_watch = function(e)
    if e.config.amu_seen then return end
    local om = G.OVERLAY_MENU
    if not (om and om.get_UIE_by_ID and om:get_UIE_by_ID(e.config.id)) then return end   -- area not in the menu yet: try next frame
    e.config.amu_seen = true
    local f = AMU_FIND.fills and AMU_FIND.fills[e.config.id]
    if f then pcall(f) end
  end
  G.E_MANAGER:add_event(Event({ func = function()
    fill()
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

local amu_extra_tabs_raw
amu_extra_tabs_raw = function()
  local purple = AMU_FIND.theme_purple()
  return {
    {
      label = "Mod Toggles",
      tab_definition_function = function()
        amu_sort_set("toggles", config.sort_toggles)
        local sn = amu_sort_nodes("toggles", "amu_sort_toggles", 1.8, 2.0)
        amu_snap_info.text = amu_snap_label()
        return amu_make_tab({
          id = "amu_mod_toggle_list", cb = "amu_mod_toggles_page", build = build_mod_toggles_page,
          count = #AMU_FIND.entries("toggles", config.sort_toggles), per_page = MODS_PER_PAGE,
          find = "toggles", find_side = 4.7, find_box = 2.3, find_label = true,
          get_page = function() return AMU_CONFIG_PAGE end, set_page = function(p) AMU_CONFIG_PAGE = p end,
          panel_w = 15.6, list_w = AMU_TOG_W, list_h = AMU_TOG_H, gap_top = 0.1, gap_after = 0.14,
          top = {
            amu_header_row("Mod Update Toggles", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
              sn[1], sn[2], sn[3],
              amu_gap(0.12),
              AMU_FIND.filter_node("toggles", 1.5, 1.6),
              amu_gap(0.12),
              amu_btn("All on", "amu_toggles_all_on", G.C.GREEN, 1.5, 0.36),
              amu_gap(0.12),
              amu_btn("All off", "amu_toggles_all_off", G.C.RED, 1.5, 0.36),
              amu_gap(0.15),
              amu_btn("Save list", "amu_snap_save", G.C.PURPLE or purple, 1.8, 0.36),
              amu_gap(0.12),
              amu_btn("Restore list", "amu_snap_restore", G.C.ORANGE or RGBA(0.85, 0.5, 0.05, 1), 2.2, 0.36),
            }},
          },
          after = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_snap_info, ref_value = "text", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } },
          },
        })
      end
    },
    {
      label = "Backups",
      tab_definition_function = function()
        amu_sort_set("backups", config.sort_backups)
        local sn = amu_sort_nodes("backups", "amu_sort_backups", 2.2, 2.4)
        return amu_make_tab({
          id = "amu_backup_mod_list", cb = "amu_backup_mods_page", build = build_backup_mods_page,
          count = #AMU_FIND.entries("backups", config.sort_backups), per_page = AMU_BK_PER,
          find = "backups", find_side = 4.7, find_box = 2.3, find_label = true,
          get_page = function() return AMU_BACKUP_PAGE end, set_page = function(p) AMU_BACKUP_PAGE = p end,
          panel_w = 15.6, list_w = AMU_BK_W, list_h = AMU_BK_H, gap_top = 0.17,
          top = {
            amu_header_row("Mod Backups & Pinning", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
              sn[1], sn[2], sn[3],
              amu_gap(0.12),
              AMU_FIND.filter_node("backups", 1.8, 2.3),
            }},
          },
          after = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_backup_status, ref_value = "text", scale = 0.32, colour = purple } } } },
          },
        })
      end
    },
    {
      label = "Fork Finder",
      tab_definition_function = function()
        if not amu_fork_suggestions then amu_fork_suggestions = load_fork_suggestions() end
        AMU_FIND.scan_label.text = amu_fork_scanning and "Scanning" or "Scan Now"
        if not amu_fork_scanning then pcall(function() amu_fork_status.text = amu_fork_summary() end) end
        AMU_TOKEN_UI.init()
        G.FUNCS.amu_token_flash()
        amu_fork_filter_label.text = amu_fork_filter_text()
        amu_fork_tr_label.text = amu_fork_tr_text()
        AMU_FORKIGN.label_ref.text = AMU_FORKIGN.label()
        amu_sort_set("forks", config.sort_forks)
        local sn = amu_sort_nodes("forks", "amu_sort_forks", 1.8, 2.1)
        return amu_make_tab({
          id = "amu_fork_mod_list", cb = "amu_fork_mods_page", build = build_fork_mods_page,
          count = #AMU_FIND.entries("forks", config.sort_forks), per_page = AMU_FORK_PER,
          find = "forks", find_side = 4.7, find_box = 2.3, find_label = true,
          get_page = function() return AMU_FORK_PAGE end, set_page = function(p) AMU_FORK_PAGE = p end,
          panel_w = 15.6, list_w = AMU_FORK_W, list_h = AMU_FORK_H, gap_top = 0.14,
          top = {
            amu_header_row("Fork Finder", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
              sn[1], sn[2], sn[3],
              amu_gap(0.2),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.8, minh = 0.5, r = 0.1,
                colour = amu_fork_scanning and RGBA(0.5, 0.5, 0.5, 0.9) or G.C.GREEN,
                button = "amu_scan_forks", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { ref_table = AMU_FIND.scan_label, ref_value = "text", scale = 0.34, colour = purple } } } },
              amu_gap(0.12),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 3.1, minh = 0.5, r = 0.1,
                colour = G.C.BLUE, button = "amu_fork_filter", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { ref_table = amu_fork_filter_label, ref_value = "text", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } } } },
              amu_gap(0.12),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 3.2, minh = 0.5, r = 0.1,
                colour = G.C.BLUE, button = "amu_fork_tr_filter", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { ref_table = amu_fork_tr_label, ref_value = "text", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } } } },
              amu_gap(0.12),
              { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.2, minh = 0.5, r = 0.1,
                colour = AMU_TOKEN_UI.btn_col, func = "amu_token_flash", button = "amu_gh_help_open", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { text = "GitHub token", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } } } },
            }},
            { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { { n = G.UIT.B, config = { w = 0.1, h = 0.07 } } } },
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.34 }, nodes = {
              { n = G.UIT.O, config = { object = AMU_WAVE_TEXT({ ref_table = amu_fork_status, ref_value = "text", scale = 0.33, colour = purple,
                -- only the scanning message waves; other messages shown during a scan ("Opened ... in your browser.") stay still
                active = function() return amu_fork_scanning and tostring(amu_fork_status.text or ""):sub(1, 18) == "Scanning for forks" end }) } },
              amu_gap(0.2),
              { n = G.UIT.C, config = { align = "cm", padding = 0.02, minw = 2.3, minh = 0.36, r = 0.09,
                colour = G.C.BLUE, button = "amu_fork_ign_filter", hover = true, shadow = true }, nodes = {
                { n = G.UIT.T, config = { ref_table = AMU_FORKIGN.label_ref, ref_value = "text", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } } } },
            { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { { n = G.UIT.B, config = { w = 0.1, h = 0.06 } } } },
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.3 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_gh_display, ref_value = "text", scale = 0.3, colour = AMU_TOKEN_UI.memo_col } } } },
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
          panel_w = 15.6, list_w = AMU_NS_W, list_h = AMU_NS_H, gap_top = 0.04,
          top = {
            amu_header_row("Mods With No Update Source", 0.5),
            { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
              { n = G.UIT.T, config = { text = "Copy a mod's GitHub or Nexus webpage link, then press 'Paste link'.", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } },
            { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
              create_toggle { label = "Show the 'no update source' note after update checks",
                ref_table = config, ref_value = "show_untracked_note", w = 0, scale = 0.4 },
            }},
          },
          after = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
              { n = G.UIT.T, config = { ref_table = amu_nosrc_msg, ref_value = "text", scale = 0.32, colour = G.C.GREEN } } } },
          },
        })
      end
    },
  }
end

-- Every tab remembers that it is the one on screen, so a rebuild in place (AMU_FIND.swap_tab) knows what to build.
SMODS.current_mod.extra_tabs = function(...)
  local tabs = amu_extra_tabs_raw(...)
  for _, t in ipairs(tabs or {}) do
    local f = t.tab_definition_function
    if type(f) == "function" then
      local wrapped
      wrapped = function(...)
        AMU_FIND.current_def = wrapped
        return f(...)
      end
      t.tab_definition_function = wrapped
    end
  end
  return tabs
end

-- Write the config overlay once on startup
pcall(write_ps1_config_overlay)

---------------------------------------------------------------------------
-- Loading definition: transparent (no panel), purple text
---------------------------------------------------------------------------

-- A line of text whose letters ride the same travelling wave as "Shuffling mods..." on the main menu, with "..." counting up.
-- o.text = fixed text, or o.ref_table / o.ref_value = text that follows a table field (the line resizes itself when it changes).
-- o.active = optional function: the wave only runs while it returns true (otherwise the text sits still).
function AMU_WAVE_TEXT(o)
  o = o or {}
  local str = o.ref_table and { { ref_table = o.ref_table, ref_value = o.ref_value or "text" } } or { tostring(o.text or "") }
  local text = DynaText({
    string = str, colours = { o.colour or G.C.UI.TEXT_LIGHT }, scale = o.scale or 0.4, shadow = o.shadow, silent = true,
  })
  local orig_align = text.align_letters
  text.align_letters = function(self)
    orig_align(self)
    local on = (o.active == nil) or (o.active() and true or false)
    local amp = (on and not (G.SETTINGS and G.SETTINGS.reduced_motion))
      and math.sqrt(self.scale) * (self.font.FONTSCALE / G.TILESIZE) * 3000 or 0
    local t = G.TIMERS.REAL
    local letters = self.strings[self.focused_string] and self.strings[self.focused_string].letters or {}
    local shown = 1 + math.floor(t * 2.5) % 3
    local dot_n = 0
    for k, letter in ipairs(letters) do
      letter.offset.y = amp * math.sin(4.2 * t - 0.42 * k)
      if letter.char == "." then
        dot_n = dot_n + 1
        -- only the first three dots count up (the "..."), and only while the wave runs; hidden dots keep their space
        letter.pop_in = (on and dot_n <= 3 and dot_n > shown) and 0 or 1
      end
    end
  end
  return text
end

G.UIDEF.amu_loading_box = function(ref)
  ref = ref or {}
  local purple = AMU_FIND.theme_purple()
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
  local ok = pcall(function() love.system.openURL(amu_gh_token_url()) end)
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
  local old_tok = config.github_token
  if old_tok ~= clip then config.github_token_serial = amu_gh_next_serial() end
  config.github_token = clip
  amu_gh_display.text = mask_gh_token(clip)
  amu_gh_msg.text = "Token saved! Click Scan Now to look for forks."
  -- GitHub gives programs no way to delete a token, so the old one has to be deleted by hand on github.com
  -- (Settings > Developer settings > Personal access tokens). The numbered names keep new ones from clashing with it.
  if type(old_tok) == "string" and old_tok ~= "" and old_tok ~= clip then
    amu_gh_msg.text = "Token saved! Delete the old one on github.com when you like. Click Scan Now to scan."
  end
  pcall(write_ps1_config_overlay)
end

G.FUNCS.amu_gh_clear_token = function(e)
  config.github_token = ""
  amu_gh_display.text = mask_gh_token("")
  amu_gh_msg.text = "Token removed."
  pcall(write_ps1_config_overlay)
end

G.UIDEF.amu_github_token_help = function()
  local purple = AMU_FIND.theme_purple()
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.15, 0.15, 0.15, 0.95)
  amu_gh_display.text = mask_gh_token(config.github_token)

  local function line(txt, colour)
    return { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = txt, scale = 0.33, colour = colour or G.C.UI.TEXT_LIGHT } }
    }}
  end
  local function button(label, func, colour, w, id)
    return { n = G.UIT.C, config = { id = id, align = "cm", padding = 0.06, minw = w or 2.8, minh = 0.6, r = 0.1,
      colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.34, colour = G.C.UI.TEXT_LIGHT } }
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = 9.5, padding = 0.22, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.06, func = "amu_modal_tick" }, nodes = {
        { n = G.UIT.T, config = { text = "Get a free GitHub token", scale = 0.5, colour = purple, shadow = true } }
      }},
      line("Without one, GitHub allows only 60 checks per hour, so Fork Finder stops early.", purple),
      line("A token makes it 5000 per hour. It is free, read-only and only sees public data."),
      { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
      line("1.  Click 'Open GitHub page' (log in if GitHub asks)."),
      line("2.  Name: " .. amu_gh_token_name() .. "      (should already be filled in)"),
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
        button("Open GitHub page", "amu_gh_open_page", G.C.BLUE, 3.2, "amu_modal_main"),
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

-- Same rule as the results window: while one of these small windows is open, the controller cursor stays inside it.
-- (Runs every frame through the title row's config.func; if the cursor is anywhere else, it goes back to the main button.)
G.FUNCS.amu_modal_tick = function(e)
  if AMU_MODAL then AMU_MODAL.touch(); AMU_MODAL.grid_om = e.UIBox end
  local c = G.CONTROLLER
  if not c then return end
  local using_pad = c.HID and c.HID.controller and c.snap_to
  local om = G.OVERLAY_MENU
  if not (using_pad and om and e.UIBox == om) then return end
  local t = c.focused and c.focused.target
  -- same rule as the results window: only at the start, or when the cursor is really outside (never on an empty focus)
  local fresh = AMU_MODAL and AMU_MODAL.first_om ~= om
  local stray = t and t.UIBox ~= om
  if not (fresh or stray) then return end
  if c.locks and c.locks.frame then return end
  local n = om.get_UIE_by_ID and om:get_UIE_by_ID("amu_modal_main")
  if n then
    if AMU_MODAL then AMU_MODAL.first_om = om end
    pcall(c.snap_to, c, { node = n })
    if c.update_cursor then pcall(c.update_cursor, c) end
    if c.interrupt then c.interrupt.focus = false end
  end
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
  -- reopen the menu on the Fork Finder tab (not whichever tab was last used)
  pcall(function()
    local tabs = mod.extra_tabs and mod.extra_tabs() or {}
    for i, t in ipairs(tabs) do
      if t.label == "Fork Finder" then SMODS.LAST_SELECTED_MOD_TAB = ((mod and mod.id) or "modupdater") .. "_" .. i end
    end
  end)
  G.FUNCS.amu_back_to_menu()
  if amu_run_fork_scan then amu_run_fork_scan() end
end

---------------------------------------------------------------------------
-- NEXUS API KEY HELP SCREEN (same idea as the GitHub token screen)
---------------------------------------------------------------------------
AMU_FIND.nx_msg = { text = "" }
AMU_FIND.nx_url = "https://www.nexusmods.com/users/myaccount?tab=api"

G.UIDEF.amu_nexus_key_help = function()
  local purple = AMU_FIND.theme_purple()
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.15, 0.15, 0.15, 0.95)
  amu_nexus_display.text = mask_nexus_key(config.nexus_api_key)
  local function line(txt, colour)
    return { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = txt, scale = 0.33, colour = colour or G.C.UI.TEXT_LIGHT } } } }
  end
  local function button(label, func, colour, w)
    return { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = w or 2.8, minh = 0.6, r = 0.1,
      colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.34, colour = G.C.UI.TEXT_LIGHT } } } }
  end
  local gap = { n = G.UIT.B, config = { h = 0.1, w = 0.15 } }
  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = 9.5, padding = 0.22, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.T, config = { text = "Get your Nexus Mods API key", scale = 0.5, colour = purple, shadow = true } } } },
      line("Only needed for mods that update from Nexus Mods. It is free and stays on this computer.", purple),
      { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
      line("1.  Click 'Open Nexus page' (log in if Nexus asks)."),
      line("2.  Scroll down: 'Personal API Key' is usually at the bottom of that page."),
      line("3.  If it says 'Request', click it to create your key."),
      line("4.  Copy the long key."),
      line("5.  Come back here and click 'Paste key'."),
      { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 7.5, minh = 0.45, r = 0.1, colour = panel }, nodes = {
          { n = G.UIT.T, config = { ref_table = amu_nexus_display, ref_value = "text", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { ref_table = AMU_FIND.nx_msg, ref_value = "text", scale = 0.28, colour = G.C.GREEN } } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        button("Open Nexus page", "amu_nx_open_page", G.C.BLUE, 3.2), gap,
        button("Paste key", "amu_nx_paste_key", G.C.GREEN, 2.8), gap,
        button("Clear", "amu_nx_clear_key", G.C.RED, 1.5) } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        button("Back", "amu_back_to_menu", panel, 2.0), gap,
        button("Close All Menus", "amu_close_all", G.C.RED, 3.2) } },
    }
  }
end

G.FUNCS.amu_nx_help_open = function(e)
  AMU_FIND.nx_msg.text = ""
  open_overlay(G.UIDEF.amu_nexus_key_help())
end

G.FUNCS.amu_nx_open_page = function(e)
  local ok = pcall(function() love.system.openURL(AMU_FIND.nx_url) end)
  AMU_FIND.nx_msg.text = ok and "Opened Nexus Mods in your browser. Follow the steps, then come back."
                        or "Couldn't open a browser. Go to nexusmods.com, then your account settings, API tab."
end

G.FUNCS.amu_nx_paste_key = function(e)
  local clip = ""
  pcall(function() clip = love.system.getClipboardText() or "" end)
  clip = clip:gsub("%s+", "")
  if clip == "" then
    AMU_FIND.nx_msg.text = "Clipboard is empty. Copy your key on the Nexus page first."
    return
  end
  if #clip < 20 then
    AMU_FIND.nx_msg.text = "That looks too short to be a Nexus key. Copy the whole key."
    return
  end
  G.FUNCS.amu_paste_nexus_key(e)
  AMU_FIND.nx_msg.text = "Key saved."
end

G.FUNCS.amu_nx_clear_key = function(e)
  G.FUNCS.amu_clear_nexus_key(e)
  AMU_FIND.nx_msg.text = "Key removed."
end

-- Shown after a fork scan when the token is bad/expired or GitHub's hourly limit was hit.
-- kind: "bad" | "limit" (no token yet) | "limit_token" (limit hit even with a token)
G.UIDEF.amu_token_problem = function(kind)
  local purple = AMU_FIND.theme_purple()
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.15, 0.15, 0.15, 0.95)
  local lines
  if kind == "bad_update" then
    lines = { "Your GitHub token has expired or was rejected.",
              "Updates still work without it, but only 60 checks per hour.",
              "Replace it now? (about a minute)" }
  elseif kind == "missing" then
    lines = { "You have no GitHub token yet.",
              "Without one GitHub allows only 60 checks per hour,",
              "so Fork Finder scans stop early and the list is partial.",
              "Get a free token now? (about a minute)" }
  elseif kind == "bad" then
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
    { n = G.UIT.R, config = { align = "cm", padding = 0.08, func = "amu_modal_tick" }, nodes = {
      { n = G.UIT.T, config = { text = "GitHub token", scale = 0.5, colour = purple, shadow = true } } } },
  }
  for i, t in ipairs(lines) do nodes[#nodes + 1] = line(t, (i == #lines) and purple or nil) end
  nodes[#nodes + 1] = { n = G.UIT.B, config = { h = 0.15, w = 0.1 } }
  local function b(label, func, colour, w, id)
    return { n = G.UIT.C, config = { id = id, align = "cm", padding = 0.06, minw = w, minh = 0.62, r = 0.1,
      colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } }
  end
  local gap = { n = G.UIT.B, config = { h = 0.1, w = 0.15 } }
  if kind == "limit_token" then
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      b("Back", "amu_back_to_menu", panel, 2.4, "amu_modal_main"), gap, b("Close All Menus", "amu_close_all", G.C.RED, 3.2) } }
  else
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      b((kind == "missing") and "Yes, get one" or "Yes, replace it", "amu_gh_help_open", G.C.GREEN, 3.2, "amu_modal_main"), gap,
      b("Not now", (kind == "bad_update" or kind == "missing") and "amu_token_not_now" or "amu_back_to_menu", panel, 2.2), gap,
      b("Close All Menus", "amu_close_all", G.C.RED, 3.2) } }
  end
  return { n = G.UIT.ROOT, config = { align = "cm", minw = 9.0, padding = 0.22, r = 0.2, colour = bg, shadow = true, hover = true }, nodes = nodes }
end

---------------------------------------------------------------------------
-- BACKUP BROWSER: build_backup_mods_page and amu_backup_picker overlay
-- (defined here, after open_overlay/close_overlay are in scope)
---------------------------------------------------------------------------

-- DELETE BACKUPS (picker): a red Delete button and a tick box per backup, plus "Delete Selected" above them.
-- Deleting always asks first, sends the files to the Recycle Bin (delete_backups.ps1) and comes back to the list.
-- (Kept on one global table: main.lua is close to Lua's limit of local variables.)
AMU_BKDEL = { sel = {}, count = { text = "Delete Selected (0)" }, ref = nil, files = {} }

function AMU_BKDEL.tick()
  local n = 0
  for _, v in pairs(AMU_BKDEL.sel) do if v then n = n + 1 end end
  AMU_BKDEL.count.text = "Delete Selected (" .. n .. ")"
  return n
end

-- Open the picker again with a fresh list. No backups left: go back to the Backups tab itself.
function AMU_BKDEL.picker()
  local ref = AMU_BKDEL.ref or {}
  local backups
  if ref.framework then backups = AMU_FRAMEWORKS.backups(ref.folder) else backups = list_backups_for_mod(ref.folder) end
  if #backups == 0 then
    close_overlay()
    G.FUNCS.amu_back_to_menu()
    return
  end
  open_overlay(G.UIDEF.amu_backup_picker({ folder = ref.folder, display = ref.display, backups = backups, framework = ref.framework }))
end

function AMU_BKDEL.ask(files)
  AMU_BKDEL.files = files
  open_overlay(G.UIDEF.amu_backup_delete_confirm(false))
end

G.FUNCS.amu_bkdel_selected = function(e)
  local ref = AMU_BKDEL.ref or {}
  local files = {}
  for i, bf in ipairs(ref.backups or {}) do
    if AMU_BKDEL.sel["k" .. i] then files[#files + 1] = bf end
  end
  if #files == 0 then AMU_BKDEL.count.text = "Tick a backup first"; return end
  AMU_BKDEL.ask(files)
end

G.FUNCS.amu_bkdel_cancel = function(e) AMU_BKDEL.picker() end

-- "Yes, delete": hand the files to delete_backups.ps1 (Recycle Bin), then show the list again.
G.FUNCS.amu_bkdel_yes = function(e)
  local ref, files = AMU_BKDEL.ref or {}, AMU_BKDEL.files or {}
  if #files == 0 then AMU_BKDEL.picker(); return end
  local save_dir = love.filesystem.getSaveDirectory()
  local mods_dir = join_path(save_dir, "Mods")
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or join_path(mods_dir, mod_folder_name)
  local ps1 = join_path(mod_path, "delete_backups.ps1")
  local bk_dir = ref.framework and join_path(mod_path, "_framework_backups") or join_path(mods_dir, "_Balatro-Mod-Updater_Backups")
  local rel_dir = ref.framework and ("Mods/" .. mod_folder_name .. "/_framework_backups") or "Mods/_Balatro-Mod-Updater_Backups"
  if not (is_windows() and file_exists(ps1)) then
    amu_backup_status.text = "Nothing was deleted: " .. (is_windows() and "delete_backups.ps1 is missing." or "Windows only.")
    AMU_BKDEL.picker()
    return
  end
  local list = {}
  for _, bf in ipairs(files) do list[#list + 1] = winpath(join_path(bk_dir, bf)) end
  pcall(love.filesystem.remove, "AMU_delete_result.txt")
  pcall(love.filesystem.write, "AMU_delete_list.txt", table.concat(list, "\n") .. "\n")
  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
    "-File", safe_quote(winpath(ps1)),
    "-ListFile", safe_quote(winpath(join_path(save_dir, "AMU_delete_list.txt"))),
    "-ResultFile", safe_quote(winpath(join_path(save_dir, "AMU_delete_result.txt"))),
    "-AllowedDir", safe_quote(winpath(bk_dir)),
  }, " ")

  local function finish()
    local gone, left = 0, 0
    for _, bf in ipairs(files) do
      if love.filesystem.getInfo(rel_dir .. "/" .. bf) then left = left + 1 else gone = gone + 1 end
    end
    pcall(love.filesystem.remove, "AMU_delete_list.txt")
    local why = ""
    pcall(function()
      for l in tostring(love.filesystem.read("AMU_delete_result.txt") or ""):gmatch("[^\r\n]+") do
        if l:sub(1, 5) == "fail|" then why = l:match("^fail|[^|]*|(.*)$") or ""; break end
      end
    end)
    pcall(love.filesystem.remove, "AMU_delete_result.txt")
    if left == 0 then
      amu_backup_status.text = (ref.display or ref.folder or "") .. ": " .. (gone == 1 and "1 backup" or (gone .. " backups")) .. " moved to the Recycle Bin."
    else
      amu_backup_status.text = (ref.display or ref.folder or "") .. ": " .. left .. " not deleted" .. (why ~= "" and (" (" .. amu_fit(why, 0.3, 6.5) .. ")") or ".")
    end
    AMU_BKDEL.picker()
  end

  open_overlay(G.UIDEF.amu_backup_delete_confirm(true))   -- "Moving to the Recycle Bin..." while it runs
  if love and love.thread and love.thread.newThread and love.thread.getChannel then
    local channel = love.thread.getChannel("amu_bkdel_status")
    channel:clear()
    local t = love.thread.newThread(AMU_HIDE_SRC .. [[
      local cmd = ...
      local ok = pcall(function() amu_run(cmd) end)
      love.thread.getChannel("amu_bkdel_status"):push(ok and "done" or "error")
    ]])
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false, blocking = false, no_delete = true,
      func = function()
        if channel:pop() then finish(); return true end
        return false
      end
    }))
  else
    AMU_RUN(cmd)
    finish()
  end
end

G.UIDEF.amu_backup_delete_confirm = function(busy)
  local purple = AMU_FIND.theme_purple()
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.12, 0.12, 0.12, 0.96)
  local ref    = AMU_BKDEL.ref or {}
  local files  = AMU_BKDEL.files or {}
  local n = #files
  local function line(t, c, s)
    return { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = t, scale = s or 0.36, colour = c or G.C.UI.TEXT_LIGHT } } } }
  end
  local title = busy and "Deleting..." or (n == 1 and "Delete this backup?" or ("Delete " .. n .. " backups?"))
  local nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.08, func = "amu_modal_tick" }, nodes = {
      { n = G.UIT.T, config = { text = title, scale = 0.5, colour = purple, shadow = true } } } },
    line(tostring(ref.display or ref.folder or ""), purple, 0.4),
  }
  local pin = ref.framework and (config.framework_pins and config.framework_pins[ref.folder]) or (not ref.framework and config.mod_pinned and config.mod_pinned[ref.folder])
  local pinned_file = type(pin) == "table" and pin.backup_file or ""
  local has_pin = false
  for i, bf in ipairs(files) do
    if bf == pinned_file then has_pin = true end
    if i <= 5 then nodes[#nodes + 1] = line(ref.framework and AMU_FRAMEWORKS.label(bf) or format_backup_label(ref.folder, bf)) end
  end
  nodes[#nodes + 1] = { n = G.UIT.B, config = { h = 0.1, w = 0.1 } }
  if busy then
    nodes[#nodes + 1] = line("Moving to the Recycle Bin...", purple)
  else
    nodes[#nodes + 1] = line("They move to your Recycle Bin.", nil, 0.34)
    nodes[#nodes + 1] = line("You can take them back out of it there.", nil, 0.34)
    if has_pin then nodes[#nodes + 1] = line("One is the copy this mod is pinned at. It stays pinned.", purple, 0.32) end
    nodes[#nodes + 1] = { n = G.UIT.B, config = { h = 0.15, w = 0.1 } }
    local function b(label, func, colour, w, id)
      return { n = G.UIT.C, config = { id = id, align = "cm", padding = 0.06, minw = w, minh = 0.62, r = 0.1,
        colour = colour, button = func, hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = label, scale = 0.4, colour = G.C.UI.TEXT_LIGHT } } } }
    end
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      b("Cancel", "amu_bkdel_cancel", panel, 2.4, "amu_modal_main"),
      { n = G.UIT.B, config = { h = 0.1, w = 0.2 } },
      b("Yes, delete", "amu_bkdel_yes", G.C.RED, 3.0) } }
  end
  return { n = G.UIT.ROOT, config = { align = "cm", minw = 8.2, padding = 0.22, r = 0.2, colour = bg, shadow = true, hover = true }, nodes = nodes }
end

-- Overlay that lists available backups for a single mod and lets the user
-- revert to one (which also pins the mod so updates are frozen).
G.UIDEF.amu_backup_picker = function(ref)
  local purple = AMU_FIND.theme_purple()
  local bg     = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel  = RGBA(0.12, 0.12, 0.12, 0.96)

  local folder   = ref.folder  or ""
  local display  = ref.display or folder
  local backups  = ref.backups or {}

  local is_fw = ref.framework == true
  local pinned_info
  if folder == "_game" then pinned_info = AMU_GAME.pin_info()
  elseif is_fw then pinned_info = config.framework_pins and config.framework_pins[folder]
  else pinned_info = config.mod_pinned and config.mod_pinned[folder] end
  local pinned_backup = pinned_info and pinned_info.backup_file or ""

  local max_show = 5
  local shown = math.min(#backups, max_show)
  local is_game = (folder == "_game")
  local can_delete = (not is_game) and is_windows() and #backups > 0

  AMU_BKDEL.ref = { folder = folder, display = display, backups = backups, framework = is_fw }
  AMU_BKDEL.sel = {}
  AMU_BKDEL.count.text = "Delete Selected (0)"
  AMU_BKDEL.files = {}

  -- Register one revert G.FUNC per visible backup entry
  for i = 1, shown do
    local bf = backups[i]
    AMU_BKDEL.sel["k" .. i] = false
    G.FUNCS["amu_bkdel_" .. tostring(i)] = function(e) AMU_BKDEL.ask({ bf }) end
    G.FUNCS["amu_revert_" .. tostring(i)] = function(e)
      close_overlay()
      if is_fw then AMU_FRAMEWORKS.revert(folder, bf) else revert_and_pin_mod(folder, bf) end
      G.FUNCS.amu_back_to_menu()   -- back to the Backups page, not the main menu
    end
  end

  local rows = {}
  if can_delete then
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cr", padding = 0.03 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.05, minw = 2.8, minh = 0.45, r = 0.1, colour = G.C.RED,
          button = "amu_bkdel_selected", hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { ref_table = AMU_BKDEL.count, ref_value = "text", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } } } }
  end
  for i = 1, shown do
    local bf    = backups[i]
    local label = is_fw and AMU_FRAMEWORKS.label(bf) or format_backup_label(folder, bf)
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
          { n = G.UIT.T, config = { text = is_game and "Play this copy" or (is_fw and "Restore & Pin" or "Revert & Pin"), scale = 0.32, colour = purple } }
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
        can_delete and { n = G.UIT.B, config = { h = 0.1, w = 0.15 } } or nil,
        can_delete and amu_tight_toggle({ ref_table = AMU_BKDEL.sel, ref_value = "k" .. i, callback = AMU_BKDEL.tick }) or nil,
        can_delete and { n = G.UIT.C, config = { align = "cm", padding = 0.05, minw = 1.3, minh = 0.45, r = 0.1, colour = G.C.RED,
          button = "amu_bkdel_" .. tostring(i), hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Delete", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } } or nil,
      }
    }
  end

  if #backups == 0 then
    rows[1] = {
      n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.T, config = { text = is_game and "No saved game copy yet. One is made on the next update check." or (is_fw and "No backups yet. One is made right before each update." or "No backups found."), scale = 0.38, colour = purple } }
      }
    }
  elseif #backups > max_show then
    rows[#rows + 1] = {
      n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.T, config = { text = "(showing " .. max_show .. " most recent of " .. #backups .. ")", scale = 0.3, colour = purple } }
      }
    }
  end

  local minh = math.max(3.5, shown * (can_delete and 0.68 or 0.55) + 2.2 + (can_delete and 0.5 or 0))

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = can_delete and 10.4 or 7.4, minh = minh, padding = 0.24, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.T, config = { text = "Backups: " .. display, scale = 0.52, colour = purple, shadow = true } }
      }},
      is_fw and { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { text = is_game and "Takes effect when the game restarts. Mod updates pause on a saved copy." or "Takes effect when the game restarts. Stays pinned until you press Unpin.", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } } } }
        or { n = G.UIT.B, config = { h = 0.12, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.12, minw = can_delete and 9.6 or 6.6, r = 0.12, colour = panel }, nodes = rows }
      }},
      { n = G.UIT.B, config = { h = 0.14, w = 0.1 } },
      is_game and { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.03 }, nodes = {
          { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
            { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 6.6, minh = 0.6, r = 0.1, colour = G.C.GREEN,
                button = "amu_game_latest", hover = true, shadow = true }, nodes = {
              { n = G.UIT.T, config = { text = "Use Steam's newest game + turn updates on", scale = 0.36, colour = purple } } } } } },
          { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
            { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 6.6, minh = 0.5, r = 0.1, colour = G.C.BLUE,
                button = "amu_game_allow", hover = true, shadow = true }, nodes = {
              { n = G.UIT.T, config = { text = "Allow mod updates on a saved copy: " .. ((config.cfg_allow_updates_on_backup == true) and "ON" or "OFF"), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } } } },
        } } } } or { n = G.UIT.B, config = { h = 0.01, w = 0.1 } },
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

-- Fork notes: the readable "what is different" lines of a fork. A bare version number ("Version 1.2.1"), "Changelog",
-- "What's Changed" and the like tell the player nothing, so they are skipped. Commit messages come first, then the lines
-- of the latest release notes. Returns the list.
function AMU_FIND.fork_noise(t)
  if amu_is_noise(t) then return true end
  local l = tostring(t or ""):lower():gsub("^[%s%p]+", "")
  if #l < 4 then return true end
  if l:find("^changelog") or l:find("^change log") or l:find("^what'?s changed") or l:find("^full changelog")
     or l:find("^release notes?") or l:find("^new release") or l:find("^bump ") then return true end
  if l:find("^v?%d[%w%.%-]*$") then return true end
  if l:find("^version%s*v?%d[%w%.%-]*$") or l:find("^release%s*v?%d[%w%.%-]*$") or l:find("^v%d[%w%.%-]*%s*release$") then return true end
  return false
end

function AMU_FIND.fork_notes(fork)
  local out, seen = {}, {}
  local function take(m)
    local t = amu_clean_note(m)
    local k = t:lower()
    if t ~= "" and not seen[k] and not AMU_FIND.fork_noise(t) then seen[k] = true; out[#out + 1] = t end
  end
  if type(fork.changelog) == "table" then for _, m in ipairs(fork.changelog) do take(m) end end
  for line in tostring(fork.latest_release_notes or ""):gmatch("[^\r\n]+") do take(line) end
  return out
end

-- Used when a fork has no readable note: say what the file counts show instead of nothing.
function AMU_FIND.fork_fallback(fork)
  local fc, lf = fork.files_changed or 0, fork.loc_files or 0
  if fc > 0 and lf >= fc then return "Only language / translation files differ." end
  if fc > 0 then
    return "Changes " .. fc .. " file" .. (fc == 1 and "" or "s") .. "; the notes say nothing readable (open the fork page)."
  end
  return "(no readable change notes)"
end

-- "1 new commit you don't have", "you have 2 it lacks", date: the numbers compare the fork with the copy you have installed.
function AMU_FIND.fork_date(fork)
  local lc = tostring(fork.last_commit_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
  if lc then return "changed " .. lc end
  local pd = tostring(fork.pushed_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
  if pd then return "pushed " .. pd end
  return nil
end

-- Wrap text into at most `maxlines` lines that each fit `maxw` (the last one ends with ".." when text is left over).
function AMU_FIND.wrap(text, scale, maxw, maxlines)
  text = tostring(text or ""):gsub("[\r\n\t]+", " ")
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    local try = (cur == "") and word or (cur .. " " .. word)
    if cur == "" or amu_text_w(try, scale) <= maxw then
      cur = try
    else
      lines[#lines + 1] = cur
      cur = word
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  maxlines = maxlines or 2
  if #lines > maxlines then
    local kept = {}
    for i = 1, maxlines - 1 do kept[i] = lines[i] end
    local rest = {}
    for i = maxlines, #lines do rest[#rest + 1] = lines[i] end
    kept[maxlines] = table.concat(rest, " ")
    lines = kept
  end
  for i, l in ipairs(lines) do lines[i] = amu_fit(l, scale, maxw) end
  return lines
end

function AMU_FIND.d10(s) return tostring(s or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") end

-- The day a fork last changed: its newest commit the installed copy lacks, else the repo's last push.
function AMU_FIND.fork_day(f) return AMU_FIND.d10(f.last_commit_at) or AMU_FIND.d10(f.pushed_at) end

-- "2026-03-03T10:11:12Z" (or just a day) -> "2026-03-03T10:11:12" so two times can be compared as text.
function AMU_FIND.norm_stamp(s)
  s = tostring(s or "")
  local d = s:match("^(%d%d%d%d%-%d%d%-%d%d)")
  if not d then return nil end
  return d .. "T" .. (s:match("^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)") or "00:00:00")
end

-- How recently a fork was updated: its newest commit you lack (the push time if that is not known), or its latest release if
-- that is newer.
function AMU_FIND.fork_stamp(f)
  local c = AMU_FIND.norm_stamp(f.last_commit_at) or AMU_FIND.norm_stamp(f.pushed_at)
  local r = AMU_FIND.norm_stamp(f.latest_release_at)
  if r and (not c or r > c) then c = r end
  return c
end

-- The day of the copy you run right now and how that day was found (git clone / release / GitHub).
-- `scan` is the mod's entry from the last Fork Finder scan (installed_head_at, installed_release_at, installed_release_tag).
function AMU_FIND.current_info(folder, scan)
  scan = scan or {}
  local out = { date = nil, how = "" }
  local ok, cls = pcall(amu_changelogs)
  local info = ok and cls and cls[folder] or nil
  local head = AMU_FIND.d10(scan.installed_head_at)
  if info and info.source == "git" then
    local loc = type(info.commits) == "table" and info.commits[1] and AMU_FIND.d10(info.commits[1].d) or nil
    local has = scan.installed_has_head   -- true / false from the scan (a git clone only), nil = unknown
    if head and has ~= nil then
      -- the scan checked the real commits: the copy either has GitHub's newest commit or it does not
      out.date, out.how = head, "newest commit on GitHub"
      out.lacks = (has == false)
      out.stamp = AMU_FIND.norm_stamp(scan.installed_head_at)
    elseif loc and head and head > loc then
      out.date, out.how = head, "newest commit on GitHub"
      out.stamp = AMU_FIND.norm_stamp(scan.installed_head_at)
    elseif loc then
      out.date, out.how = loc, "last commit in your git clone"
      out.stamp = (head and head == loc) and AMU_FIND.norm_stamp(scan.installed_head_at) or AMU_FIND.norm_stamp(loc)
    elseif head then
      out.date, out.how = head, "last commit on GitHub"
      out.stamp = AMU_FIND.norm_stamp(scan.installed_head_at)
    end
  else
    local rel = AMU_FIND.d10(scan.installed_release_at)
    local tag = tostring(scan.installed_release_tag or "")
    if rel then
      out.date, out.how = rel, "latest release" .. (tag ~= "" and (" " .. tag) or "") .. " of your source"
      out.stamp = AMU_FIND.norm_stamp(scan.installed_release_at)
    elseif head then
      out.date, out.how = head, "last commit on GitHub"
      out.stamp = AMU_FIND.norm_stamp(scan.installed_head_at)
    elseif info and AMU_FIND.d10(info.date) then
      out.date, out.how = AMU_FIND.d10(info.date), "when it was last updated here"
      out.stamp = AMU_FIND.norm_stamp(info.date)
    end
  end
  return out
end

AMU_FIND.NEWEST_DARK = RGBA(0.1, 0.5, 0.2, 1)   -- readable on the white hover box

-- Builds the rows of the hover box (called by the game when you hover / focus the row).
G.FUNCS.amu_game_latest = function(e)
  close_overlay()
  AMU_FRAMEWORKS.game_run("steam")
  G.FUNCS.amu_back_to_menu()
end
G.FUNCS.amu_game_allow = function(e)
  config.cfg_allow_updates_on_backup = not (config.cfg_allow_updates_on_backup == true)
  pcall(write_ps1_config_overlay)
  close_overlay()
  open_overlay(G.UIDEF.amu_backup_picker({ folder = "_game", display = AMU_FRAMEWORKS._game.display, backups = AMU_GAME.copies(), framework = true }))
end

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
  local entries = AMU_FIND.entries("backups", config.sort_backups)
  local total_pages = math.max(1, math.ceil(#entries / AMU_BK_PER))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_BACKUP_PAGE = page
  AMU_FIND.sync_pager("backups", total_pages, page)

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
      local pin_info
      if folder == "_game" then pin_info = AMU_GAME.pin_info()
      elseif AMU_FRAMEWORKS[folder] then pin_info = config.framework_pins and config.framework_pins[folder]
      else pin_info = config.mod_pinned and config.mod_pinned[folder] end
      local is_pinned = type(pin_info) == "table" and pin_info.pinned == true

      -- Balatro game files / Lovely / Steamodded: green while on the newest version, red while on a saved older copy
      local name_col = G.C.UI.TEXT_LIGHT
      if AMU_FRAMEWORKS[folder] then
        local older = is_pinned
        if folder == "_game" then
          local pend = AMU_GAME.pending_swap()
          if pend and pend ~= "" and pend ~= "steam" then older = true end
        end
        name_col = older and RGBA(1.0, 0.36, 0.36, 1) or RGBA(0.34, 0.9, 0.42, 1)
      end

      G.FUNCS["amu_open_backups_" .. row_i] = function(e)
        if AMU_FRAMEWORKS[folder] then
          amu_backup_status.text = AMU_FRAMEWORKS[folder].note
          open_overlay(G.UIDEF.amu_backup_picker({ folder = folder, display = display, backups = AMU_FRAMEWORKS.backups(folder), framework = true }))
          return
        end
        local backups = list_backups_for_mod(folder)
        open_overlay(G.UIDEF.amu_backup_picker({ folder = folder, display = display, backups = backups }))
      end

      local has_web = AMU_WEB.links(folder)[1] ~= nil
      G.FUNCS["amu_web_bk_" .. row_i] = function(e)
        amu_backup_status.text = AMU_WEB.open_first(folder, display)
      end

      G.FUNCS["amu_unpin_mod_" .. row_i] = function(e)
        if AMU_FRAMEWORKS[folder] then AMU_FRAMEWORKS.unpin(folder) else unpin_mod(folder) end
        amu_update_area("amu_backup_mod_list", build_backup_mods_page(AMU_BACKUP_PAGE))
      end

      -- Two lines to the right of the name: version, then last update / pin info
      local fw1, fw2
      if AMU_FRAMEWORKS[folder] then fw1, fw2 = AMU_FRAMEWORKS.lines(folder) end
      local line1 = amu_fit(fw1 or mod_version_line(folder), 0.35, 4.0)
      local line2, line2_colour
      if fw2 and not is_pinned then
        line2, line2_colour = fw2, grey
      elseif is_pinned then
        local pd = fmt_date(parse_stamp(pin_info.backup_file or ""))
        line2 = pd and ("Pinned to backup " .. pd) or "Pinned to a backup"
        line2_colour = orange
      else
        local ud = fmt_date(last_update_for(folder, umap))
        line2 = ud and ("Updated " .. ud) or "Never updated here"
        line2_colour = grey
      end
      line2 = amu_fit(line2, 0.31, 4.0)

      local tip = { filler = { func = amu_changelog_tip, args = { folder = folder, display = display } } }

      local pin_badge
      if is_pinned then
        pin_badge = { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 1.1, minh = 0.36, r = 0.08,
          colour = RGBA(0.7, 0.45, 0.0, 0.95) }, nodes = {
          { n = G.UIT.T, config = { text = "PINNED", scale = 0.28, colour = RGBA(1, 1, 1, 1) } } } }
      else
        pin_badge = { n = G.UIT.B, config = { h = 0.1, w = 1.1 } }
      end

      local unpin_node
      if is_pinned then
        unpin_node = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.1, minh = 0.48, r = 0.09,
          colour = G.C.RED, button = "amu_unpin_mod_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Unpin", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } }
      else
        unpin_node = { n = G.UIT.B, config = { h = 0.1, w = 1.1 } }
      end

      -- Width budget (the list area is 15.2 wide, about 14.7 usable): 0.2 + 4.4 + 4.15 + 0.15 + 1.1 + 0.1 + 1.6 + 0.1 + 1.7 + 0.1 + 1.1 = 14.7.
      -- The version/pin column is wide enough for "Pinned to backup YYYY-MM-DD" (its text is cut at 4.0), and a gap sits in front of
      -- the PINNED badge, so the text never runs behind the badge and the Unpin button stays inside the panel.
      local row_nodes = {
        { n = G.UIT.B, config = { h = 0.1, w = 0.2 } },
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 4.4 }, nodes = {
          { n = G.UIT.T, config = { text = amu_fit(display, 0.5, 4.2), scale = 0.5, colour = name_col } } } },
        { n = G.UIT.C, config = { align = "cl", padding = 0, minw = 4.15 }, nodes = {
          { n = G.UIT.R, config = { align = "cl", padding = 0 }, nodes = {
            { n = G.UIT.T, config = { text = line1, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } } } },
          { n = G.UIT.R, config = { align = "cl", padding = 0 }, nodes = {
            { n = G.UIT.T, config = { text = line2, scale = 0.31, colour = line2_colour } } } },
        }},
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        pin_badge,
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.6, minh = 0.48, r = 0.09,
          colour = has_web and G.C.BLUE or RGBA(0.5, 0.5, 0.5, 0.9), button = "amu_web_bk_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Webpage", scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.7, minh = 0.48, r = 0.09,
          colour = G.C.BLUE, button = "amu_open_backups_" .. row_i, hover = true, shadow = true,
          on_demand_tooltip = tip }, nodes = {
          { n = G.UIT.T, config = { text = "Backups", scale = 0.38, colour = G.C.UI.TEXT_LIGHT } } } },
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        unpin_node,
      }

      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_BK_ROW_H, on_demand_tooltip = tip }, nodes = row_nodes }
    end
  end

  local shown = math.max(0, end_i - start_i + 1)
  local blank_from = shown + 1
  if shown == 0 and (AMU_FIND.active("backups") or AMU_FIND.filtering("backups")) then
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.02, minh = AMU_BK_ROW_H, minw = AMU_BK_W - 0.5 }, nodes = {
      { n = G.UIT.T, config = { text = "No mods match your search or filter", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } } } }
    blank_from = 2
  end
  for _ = blank_from, AMU_BK_PER do
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_BK_ROW_H }, nodes = {
      { n = G.UIT.B, config = { h = AMU_BK_ROW_H - 0.04, w = AMU_BK_W - 0.5 } } } }
  end

  return amu_list_root(rows, AMU_BK_W, AMU_BK_H)
end

-- Sort button on the Backups screen
G.FUNCS.amu_sort_backups = function(e)
  config.sort_backups = (config.sort_backups == "recent") and "az" or "recent"
  pcall(AMU_UI.save)
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
  -- "Show every fork" reads the last every-fork scan, so a newer-only scan in between does not wipe it.
  local data
  if config.fork_newer_only == false then data = read_all(join_path(mod_path, "fork_suggestions_all.json")) end
  data = data or read_all(join_path(mod_path, "fork_suggestions.json"))
  if not data then return nil end
  return decode_json(data)
end

-- The fork a mod was switched to. config.mod_fork_source[folder].fork_repo is saved the moment you press Switch, so the Fork Finder
-- can show it right away; switch_pending[folder] is true only until the game restarts (it lives in memory), which is how the list tells
-- "switched, restart to apply" from "restarted, you are on it now".
AMU_FIND.switch_pending = AMU_FIND.switch_pending or {}
-- back_now[folder] = the original repo you just pressed Switch Back to (memory only, like switch_pending). Before the restart the
-- mod is still the fork on disk, but the lists already treat the original as the copy you run.
AMU_FIND.back_now = AMU_FIND.back_now or {}
AMU_FIND.left_behind = AMU_FIND.left_behind or {}   -- folder -> { repo, date, stamp } of the copy you left with a switch (until the restart)
function AMU_FIND.fork_now(folder)
  local src = config.mod_fork_source and config.mod_fork_source[folder]
  local r = type(src) == "table" and src.fork_repo or nil
  if type(r) == "string" and r ~= "" then return r end
  local b = AMU_FIND.back_now[folder]
  if type(b) == "string" and b ~= "" then return b end
  return nil
end
function AMU_FIND.fork_now_how(folder)
  local src = config.mod_fork_source and config.mod_fork_source[folder]
  if type(src) == "table" and src.fork_repo then return "the fork you use now" end
  return "the original you switched back to"
end
function AMU_FIND.is_fork_now(folder, repo)
  local r = AMU_FIND.fork_now(folder)
  return r ~= nil and tostring(repo or ""):lower() == r:lower()
end
-- Day and exact time of the fork you run now, from the last scan: "Your copy" is right before the next scan too.
function AMU_FIND.fork_now_day(folder)
  local r = AMU_FIND.fork_now(folder)
  local data = r and amu_fork_suggestions and amu_fork_suggestions.suggestions and amu_fork_suggestions.suggestions[folder]
  if type(data) ~= "table" or type(data.forks) ~= "table" then return nil end
  for _, f in ipairs(data.forks) do
    if tostring(f.repo or ""):lower() == r:lower() then
      local st = AMU_FIND.fork_stamp(f)
      return AMU_FIND.d10(st), st
    end
  end
  return nil
end

-- A copy counts as "newer" when it has commits the installed copy doesn't have AND its newest change (commit or release) is
-- strictly newer than the newest commit of the copy you run. `cur` is AMU_FIND.current_info(): the exact time of your copy's newest
-- commit (GitHub head when your clone is older). This holds for the original and the parent too: if your copy is the most recently
-- updated one (a tie counts as yours), nothing is newer and the mod is not listed. A copy whose date is unknown stays listed.
local function amu_fork_is_newer(fork, cur)
  if (fork.commits_ahead or 0) <= 0 then return false end
  local st = AMU_FIND.fork_stamp(fork)
  local cs = cur and (cur.stamp or (cur.date and AMU_FIND.norm_stamp(cur.date)))
  if not st or not cs then return true end
  return st > cs
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

-- THE most recently updated copy among yours and the listed forks: returns "cur" (your copy) or the fork table. Compared by
-- exact commit / release time. Copies sharing the very same newest commit (a fork that just synced with its parent) tie: the
-- original wins, then the parent, then other forks; your own copy wins a tie with any of them. nil when your own date is unknown
-- (then nothing is marked, because your copy might be the newest).
function AMU_FIND.newest_pick(cur, forks, left)
  if not (cur and cur.date) then return nil end
  local win, wstamp, wrank = "cur", cur.stamp or (cur.date .. "T00:00:00"), 0
  -- The copy you just switched away from is not in the fork list (the scan compares against the installed copy), but it still
  -- counts: if it is newer than the copy you switched to, it is the most recently updated one, not yours.
  if type(left) == "table" and left.repo and left.stamp and left.stamp > wstamp then
    win, wstamp, wrank = { repo = left.repo, last_commit_at = left.stamp, _left = true }, left.stamp, 99
  end
  for _, f in ipairs(forks or {}) do
    local st = AMU_FIND.fork_stamp(f)
    if st then
      local rank = AMU_FORK_KIND[amu_fork_kind(f)].rank
      if st > wstamp or (st == wstamp and rank < wrank) then win, wstamp, wrank = f, st, rank end
    end
  end
  return win
end

-- Remember the copy that is installed right now (name and newest commit time) before a switch, so it stays a candidate for
-- "most recently updated". Only the first switch counts: until the restart the installed copy does not change.
function AMU_FIND.remember_left(folder)
  pcall(function()
    if AMU_FIND.left_behind[folder] then return end
    local d = amu_fork_suggestions and amu_fork_suggestions.suggestions and amu_fork_suggestions.suggestions[folder]
    if type(d) ~= "table" then return end
    local info = AMU_FIND.current_info(folder, d)
    local repo = d.installed_repo or d.current_repo
    if info and info.date and type(repo) == "string" and repo ~= "" then
      AMU_FIND.left_behind[folder] = { repo = repo, date = info.date, stamp = info.stamp or AMU_FIND.norm_stamp(info.date) }
    end
  end)
end
-- true when the copy you run (after a switch) is the most recently updated one
function AMU_FIND.now_is_newest(folder, entry)
  local ok, res = pcall(function()
    local cur = AMU_FIND.current_info(folder, entry)
    local nd, ns = AMU_FIND.fork_now_day(folder)
    if nd then cur = { date = nd, stamp = ns } end
    return AMU_FIND.newest_pick(cur, entry.forks, AMU_FIND.left_behind[folder]) == "cur"
  end)
  return ok and res == true
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
  local fc, lf = f.files_changed or 0, f.loc_files or 0
  if kind ~= "original" and kind ~= "parent" then
    local name = tostring(f.repo or ""):lower():match("/(.+)$") or ""
    local named = false
    for _, w in ipairs(AMU_TR_WORDS) do
      if name:find(w) then named = true break end
    end
    if not named then
      for tok in name:gmatch("[a-z0-9]+") do
        if AMU_TR_TOKENS[tok] then named = true break end
      end
    end
    if fc > 0 then
      -- A language word in the repo name is enough to call it a translation, unless it clearly changes much more than a few
      -- non-language files (config, version, icon and similar small edits do not count as "more").
      -- Without a language word in the name, (almost) every changed file must be a language file.
      if named then result = (fc - lf) <= 6
      else result = (fc - lf) <= 1 and lf >= 1 end
    else
      result = named
    end
  end
  if kind ~= "original" and kind ~= "parent" and fc == 0 then
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
  return AMU_WEB.links(folder, installed_repo)
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
    if type(data) == "table" and type(data.forks) == "table" and #data.forks > 0
       and (AMU_FORKIGN.show() or not AMU_FORKIGN.mod_is(folder_name)) then
      local cur
      if newer_only then
        cur = AMU_FIND.current_info(folder_name, data)
        if not cur.date then
          local d = amu_installed_date(folder_name, umap, cls)
          if d ~= "" then cur = { date = AMU_FIND.d10(d), stamp = AMU_FIND.norm_stamp(d) } end
        end
        -- on a fork: compare the other copies with that fork, not with the copy from before the switch
        local nd, ns = AMU_FIND.fork_now_day(folder_name)
        if nd then cur = { date = nd, stamp = ns, how = AMU_FIND.fork_now_how(folder_name) } end
      end
      local list = {}
      local on_now = newer_only and not AMU_FIND.switch_pending[folder_name]
      for _, f in ipairs(data.forks) do
        local keep = (not newer_only or amu_fork_is_newer(f, cur)) and not (hide_tr and amu_fork_is_translation(f))
          and not (on_now and AMU_FIND.is_fork_now(folder_name, f.repo))
          and (AMU_FORKIGN.show() or not AMU_FORKIGN.is(f))
        if keep then list[#list + 1] = f end
      end
      -- most recently changed first (newest commit or release, push time only when that is unknown), whatever kind of fork it is
      table.sort(list, function(a, b)
        local pa, pb = AMU_FIND.fork_stamp(a) or "", AMU_FIND.fork_stamp(b) or ""
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
          installed_head_at     = data.installed_head_at,
          installed_release_at  = data.installed_release_at,
          installed_release_tag = data.installed_release_tag,
          forks          = list,
          total_forks    = #data.forks,
          has_upstream   = has_upstream,
          fork_count     = fork_only_count,
          counts         = counts,
          mod_ignored    = AMU_FORKIGN.mod_is(folder_name),
        }
      end
    end
  end
  table.sort(entries, function(a, b) return a.display:lower() < b.display:lower() end)
  return entries
end

-- "Ignore scans" for single forks: config.fork_ignored["owner/repo" in lower case] = true. The scan (autoupdate.ps1 -CheckForks) does
-- not compare an ignored fork (it only keeps a stub so the fork can be un-ignored here), and the Fork Finder list hides it
-- unless "Ignored: Shown" is on.
AMU_FORKIGN = {}
function AMU_FORKIGN.is(f)
  return type(f) == "table" and type(config.fork_ignored) == "table" and config.fork_ignored[tostring(f.repo or ""):lower()] == true
end
-- "Ignore" for a whole mod: config.fork_ignored_mods[folder in lower case] = true. The scan skips the mod (its last results are
-- kept so it can be un-ignored here) and the list hides it unless "Ignored: Shown" is on.
function AMU_FORKIGN.mod_is(folder)
  return type(config.fork_ignored_mods) == "table" and config.fork_ignored_mods[tostring(folder or ""):lower()] == true
end
function AMU_FORKIGN.toggle_mod(folder)
  config.fork_ignored_mods = config.fork_ignored_mods or {}
  local k = tostring(folder or ""):lower()
  if k == "" then return false end
  if config.fork_ignored_mods[k] then config.fork_ignored_mods[k] = nil else config.fork_ignored_mods[k] = true end
  pcall(write_ps1_config_overlay)
  return config.fork_ignored_mods[k] == true
end
function AMU_FORKIGN.mod_tip(args)
  local dark = G.C.UI.TEXT_DARK or RGBA(0.2, 0.2, 0.25, 1)
  local rows = {}
  local function add(text, scale, colour)
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = amu_fit(text, scale, 6.0), scale = scale, colour = colour or dark } } } }
  end
  add("Ignore this whole mod", 0.34, G.C.BLUE or dark)
  add("Fork scans skip it completely.", 0.28)
  add("It leaves this list unless Ignored: Shown is on.", 0.27)
  add("Tick it again to scan the mod again.", 0.27)
  return { n = G.UIT.R, config = { align = "cl", padding = 0.03 }, nodes = {
    { n = G.UIT.C, config = { align = "cl", padding = 0.03 }, nodes = rows } } }
end
function AMU_FORKIGN.show() return config.fork_show_ignored == true end
function AMU_FORKIGN.toggle(repo)
  config.fork_ignored = config.fork_ignored or {}
  local k = tostring(repo or ""):lower()
  if k == "" then return false end
  if config.fork_ignored[k] then config.fork_ignored[k] = nil else config.fork_ignored[k] = true end
  pcall(write_ps1_config_overlay)
  return config.fork_ignored[k] == true
end
-- Hover text for a Fork Finder row: the whole story the short row text leaves out.
function AMU_FORKIGN.row_tip(args)
  local entry = (args and args.entry) or {}
  local dark = G.C.UI.TEXT_DARK or RGBA(0.2, 0.2, 0.25, 1)
  local blue = G.C.BLUE or dark
  local rows = {}
  local function add(text, scale, colour)
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = amu_fit(text, scale, 6.0), scale = scale, colour = colour or dark } } } }
  end
  add(tostring(args and args.display or ""), 0.34, blue)
  local counts, parts = entry.counts or {}, {}
  for _, k in ipairs({ "original", "parent", "parent_fork", "fork_fork", "fork" }) do
    local n = counts[k] or 0
    if n > 0 then
      local w = AMU_FORK_KIND[k].word
      parts[#parts + 1] = (k == "original" or k == "parent") and ("the " .. w) or (n .. " " .. w .. (n == 1 and "" or "s"))
    end
  end
  do
    -- the original and the parent are named (Owner/Name) like everywhere else in this menu
    local named = {}
    for _, k in ipairs({ "original", "parent" }) do
      if (counts[k] or 0) > 0 then
        for _, f in ipairs(entry.forks or {}) do
          if amu_fork_kind(f) == k then named[k] = named[k] or tostring(f.repo or "") end
        end
      end
    end
    for i, part in ipairs(parts) do
      for _, k in ipairs({ "original", "parent" }) do
        if part == "the " .. AMU_FORK_KIND[k].word and named[k] and named[k] ~= "" then
          parts[i] = AMU_FORK_KIND[k].word .. " (" .. named[k] .. ")"
        end
      end
    end
  end
  -- (the "Found: ..." and "Your copy: ..." lines are gone: the green and blue lines below say what matters)
  local cur = AMU_FIND.current_info(args and args.folder or "", entry)
  do
    local nd, ns = AMU_FIND.fork_now_day(args and args.folder or "")
    if nd then cur = { date = nd, stamp = ns, how = AMU_FIND.fork_now_how(args and args.folder or "") } end
  end
  local win = AMU_FIND.newest_pick(cur, entry.forks, AMU_FIND.left_behind[args and args.folder or ""])
  local function addw(text, scale, colour, maxlines)
    for _, ln in ipairs(AMU_FIND.wrap(text, scale, 6.0, maxlines or 2)) do add(ln, scale, colour) end
  end
  if win ~= nil then
    local who, day
    if win == "cur" then
      local nm = AMU_FIND.fork_now(args and args.folder or "") or tostring(entry.installed_repo or "")
      who, day = "your current copy" .. (nm ~= "" and (" (" .. nm .. ")") or ""), cur.date
    else who, day = tostring(win.repo or ""), AMU_FIND.d10(AMU_FIND.fork_stamp(win)) end
    addw("Most recently updated: " .. who .. "  " .. tostring(day or ""), 0.27, AMU_FIND.NEWEST_DARK, 2)
  else
    local newest = entry.forks and entry.forks[1] and AMU_FIND.d10(AMU_FIND.fork_stamp(entry.forks[1]))
    if newest then add("Newest change: " .. newest .. "  (" .. tostring(entry.forks[1].repo or "") .. ")", 0.27) end
  end
  local ign = 0
  for _, f in ipairs(entry.forks or {}) do if AMU_FORKIGN.is(f) then ign = ign + 1 end end
  if ign > 0 then add(ign .. " of them ignored by scans", 0.27) end
  local now_repo = AMU_FIND.fork_now(args and args.folder or "")
  if now_repo then
    local wait = AMU_FIND.switch_pending[args and args.folder or ""]
    add("Using now: " .. tostring(now_repo), 0.27, blue)
    if wait then add("(restart to apply)", 0.27, blue) end   -- own line: on one line the hover box cut it off
  elseif win ~= nil and win ~= "cur" and tostring(entry.installed_repo or "") ~= "" then
    -- same rule everywhere: when you are not on the most recently updated copy, say what you ARE using (blue)
    add("Using now: " .. tostring(entry.installed_repo), 0.27, blue)
  end
  addw("Press the View Forks button to read about each fork and tick Ignore scans.", 0.26, nil, 2)
  return { n = G.UIT.R, config = { align = "cl", padding = 0.03 }, nodes = {
    { n = G.UIT.C, config = { align = "cl", padding = 0.03 }, nodes = rows } } }
end
function AMU_FORKIGN.label() return AMU_FORKIGN.show() and "Ignored: Shown" or "Ignored: Hidden" end
AMU_FORKIGN.label_ref = { text = "" }

-- Fork Finder list for the search: A-Z, or "Recent" = the mods whose newest fork (newest commit or release) changed most recently first.
AMU_FIND.source.forks = function(mode)
  local list = get_fork_mod_entries()
  if mode == "recent" then
    table.sort(list, function(a, b)
      local pa = a.forks and a.forks[1] and AMU_FIND.fork_stamp(a.forks[1]) or ""
      local pb = b.forks and b.forks[1] and AMU_FIND.fork_stamp(b.forks[1]) or ""
      if pa ~= pb then return pa > pb end
      return a.display:lower() < b.display:lower()
    end)
  end
  return list
end

G.FUNCS.amu_sort_forks = function(e)
  config.sort_forks = (config.sort_forks == "recent") and "az" or "recent"
  pcall(AMU_UI.save)
  amu_sort_set("forks", config.sort_forks)
  AMU_FORK_PAGE = 1
  amu_update_area("amu_fork_mod_list", build_fork_mods_page(1))
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
  -- A switch waiting for a restart always stays on this line, so it cannot be missed (it lives in memory until the restart).
  do
    local names = {}
    for folder, on in pairs(AMU_FIND.switch_pending) do if on then names[#names + 1] = folder end end
    if #names > 0 then
      table.sort(names)
      return amu_fit("Restart to apply: " .. table.concat(names, ", "), 0.3, 8.6)
    end
  end
  if not amu_fork_suggestions or not amu_fork_suggestions.suggestions then
    return "No fork data yet - press Scan Now."
  end
  local shown = #get_fork_mod_entries()
  local all = #get_fork_mod_entries(true, true)
  local text
  -- the filter button already says which list this is, so the line only gives the numbers
  if config.fork_newer_only ~= false then
    text = shown .. " new fork(s) (" .. all .. " have any fork)"
  else
    text = shown .. " any fork(s)"
  end
  local mode = amu_fork_suggestions.scan_mode
  local d, t = tostring(amu_fork_suggestions.checked_at or ""):match("^%d%d%d%d%-(%d%d%-%d%d)T(%d%d:%d%d)")
  if d then
    text = text .. " - last scanned " .. d .. " " .. t
    if config.fork_newer_only == false and mode == "newer" then text = text .. " (newer only, Scan Now for all)" end
  end
  return amu_fit(text, 0.3, 8.6)
end

G.FUNCS.amu_fork_filter = function(e)
  config.fork_newer_only = (config.fork_newer_only == false) and true or false
  pcall(AMU_UI.save)
  if not amu_fork_scanning then amu_fork_suggestions = load_fork_suggestions() or amu_fork_suggestions end
  amu_fork_filter_label.text = amu_fork_filter_text()
  AMU_FORK_PAGE = 1
  if not amu_fork_scanning then amu_fork_status.text = amu_fork_summary() end
  amu_reopen_if_open("amu_fork_mod_list")   -- the number of pages changes, so rebuild the tab
  AMU_FIND.snap_to_button("amu_fork_filter")
end

G.FUNCS.amu_fork_tr_filter = function(e)
  config.fork_hide_translations = (config.fork_hide_translations == false) and true or false
  pcall(AMU_UI.save)
  amu_fork_tr_label.text = amu_fork_tr_text()
  AMU_FORK_PAGE = 1
  if not amu_fork_scanning then amu_fork_status.text = amu_fork_summary() end
  amu_reopen_if_open("amu_fork_mod_list")
  AMU_FIND.snap_to_button("amu_fork_tr_filter")
end

G.FUNCS.amu_fork_ign_filter = function(e)
  config.fork_show_ignored = not (config.fork_show_ignored == true)
  pcall(AMU_UI.save)
  AMU_FORKIGN.label_ref.text = AMU_FORKIGN.label()
  AMU_FORK_PAGE = 1
  amu_reopen_if_open("amu_fork_mod_list")
  AMU_FIND.snap_to_button("amu_fork_ign_filter")
end

local function run_fork_scan()
  -- a scan whose result never arrived (watcher lost) must not block new scans for ever
  if amu_fork_scanning and (os.time() - (AMU_FIND.scan_started or 0)) < 400 then return end
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
  AMU_FIND.scan_label.text = "Scanning"
  amu_fork_status.text = "Scanning for forks... (may take a minute)"
  AMU_FIND.scan_started = os.time()
  pcall(function()
    if #AMU_FIND.entries("forks", config.sort_forks) == 0 then amu_reopen_if_open("amu_fork_mod_list") end
  end)
  local keys_before = AMU_FIND.fork_keys()

  local channel = love.thread.getChannel("amu_fork_scan")
  channel:clear()

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-CheckForks",
    (config.fork_newer_only == false) and "-AllForks" or "",   -- "Show all forks" = scan every fork; default = newer ones only
  }, " ")

  local thread_code = AMU_HIDE_SRC .. [[
    local cmd = ...
    local ok = pcall(function() amu_run(cmd) end)
    local ch = love.thread.getChannel("amu_fork_scan")
    ch:push(ok and "done" or "error")
  ]]
  local t = love.thread.newThread(thread_code)
  t:start(cmd)

  AMU_FIND.scan_seq = (AMU_FIND.scan_seq or 0) + 1
  local scan_id = AMU_FIND.scan_seq
  local function finish_check()
      local msg = channel:pop()
      if msg then
        amu_fork_scanning = false
        AMU_FIND.scan_label.text = "Scan Now"
        amu_fork_suggestions = load_fork_suggestions()
        amu_fork_status.text = amu_fork_summary()
        local ts = amu_fork_suggestions and amu_fork_suggestions.token_status
        if ts == "bad" then AMU_TOKEN_UI.set_bad(true) elseif ts == "ok" then AMU_TOKEN_UI.set_bad(false) end
        if ts == "bad" then
          amu_fork_status.text = "GitHub token rejected - replace it to scan."
        elseif ts == "rate_limited" then
          amu_fork_status.text = "Stopped early (GitHub limit) - list is partial."
        end
        amu_cl_cache.stamp, amu_cl_cache.data = nil, nil   -- the scan can rewrite changelogs.json: read it again
        AMU_FORK_PAGE = 1
        amu_reopen_if_open("amu_fork_mod_list")
        -- Rebuild the list once more a moment later. Right after a scan the list could still show the old result until a filter
        -- button was pressed (twice, to get back to the chosen filter). Skipped while the search box is in use.
        do
          local t0
          G.E_MANAGER:add_event(Event({ blockable = false, blocking = false, no_delete = true, func = function()
            local now = (G.TIMERS and G.TIMERS.REAL) or 0
            t0 = t0 or now
            if (now - t0) < 0.6 then return false end
            pcall(function()
              if not AMU_FIND.active("forks") then
                amu_fork_status.text = amu_fork_summary()
                amu_reopen_if_open("amu_fork_mod_list")
              end
            end)
            return true
          end }))
        end
        if ts ~= "bad" and ts ~= "rate_limited" and amu_fork_suggestions then
          local n = 0
          for k in pairs(AMU_FIND.fork_keys()) do if not keys_before[k] then n = n + 1 end end
          if n > 0 then
            pcall(AMU_FIND.toast.show, { "Fork scan done:", n .. " new fork" .. (n == 1 and "" or "s") .. " found" },
              { seconds = 10, colour = G.C.BLUE, action = AMU_FIND.open_fork_finder, click_hint = "Click to open Fork Finder" })
          else
            pcall(AMU_FIND.toast.show, { "Fork scan done:", "no new forks" }, { seconds = 5 })
          end
        end
        if G.OVERLAY_MENU and (ts == "bad" or ts == "rate_limited") then
          local has_token = config.github_token and config.github_token ~= ""
          local kind = (ts == "bad") and "bad" or (has_token and "limit_token" or "limit")
          open_overlay(G.UIDEF.amu_token_problem(kind))
        end
        return true
      end
      return false
  end
  -- Two watchers: an event (survives most queue wipes) and a per-frame poll from the controller hook. If the event is
  -- ever lost (for example around a fork switch), the poll still ends the scan, so Scan Now never stays greyed out.
  AMU_FIND.scan_poll = function()
    if not amu_fork_scanning or AMU_FIND.scan_seq ~= scan_id then return end
    finish_check()
  end
  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true,   -- survive the event-queue wipe when a run starts
    func = function()
      if AMU_FIND.scan_seq ~= scan_id or not amu_fork_scanning then return true end
      return finish_check()
    end
  }))
end

amu_run_fork_scan = run_fork_scan

local function switch_to_fork(folder_name, fork_repo)
  if not is_windows() then
    amu_fork_status.text = "Windows only"
    return
  end

  AMU_FIND.remember_left(folder_name)
  if not config.mod_fork_source then config.mod_fork_source = {} end
  config.mod_fork_source[folder_name] = {
    fork_repo   = fork_repo,
    switched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  AMU_FIND.switch_pending[folder_name] = true   -- cleared by the restart (memory only)
  AMU_FIND.back_now[folder_name] = nil
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
    local thread_code = AMU_HIDE_SRC .. [[
      local cmd = ...
      local ok = pcall(function() amu_run(cmd) end)
      local ch = love.thread.getChannel("amu_fork_switch")
      ch:push(ok and "done" or "error")
    ]]
    local t = love.thread.newThread(thread_code)
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false,
      blocking = false,
      no_delete = true,   -- survive the event-queue wipe when a run starts
      func = function()
        local msg = channel:pop()
        if msg then
          if msg == "done" then
            amu_fork_status.text = folder_name .. " switched to fork. Restart to apply."
          else
            amu_fork_status.text = folder_name .. " switch error. See last_run.json."
          end
          pcall(amu_reopen_if_open, "amu_fork_mod_list")   -- same rebuild the filter button does; the list alone kept the old state
          pcall(amu_update_areas, {
            ["amu_fork_mod_list"] = build_fork_mods_page(AMU_FORK_PAGE)
          })
          if msg == "done" then
            local ok, shown, why = pcall(function()
              return AMU_CRASH.ask_restart({
                folder_name .. " now uses the fork you picked.",
                "Press Switch Back in Mod Updater > Fork Finder to return to the original.",
              })
            end)
            if ok and shown == false then amu_fork_status.text = folder_name .. " switch error: " .. amu_fit(tostring(why or "see last_run.json"), 0.3, 8.5) end
          end
          return true
        end
        return false
      end
    }))
  else
    AMU_RUN(cmd)
    amu_fork_status.text = folder_name .. " switched to fork. Restart to apply."
    pcall(function()
      AMU_CRASH.ask_restart({
        folder_name .. " now uses the fork you picked.",
        "Press Switch Back in Mod Updater > Fork Finder to return to the original.",
      })
    end)
  end
end

local function switch_back_fork(folder_name)
  if not is_windows() then
    amu_fork_status.text = "Windows only"
    return
  end

  AMU_FIND.remember_left(folder_name)
  -- which repo is "the original"? The saved source knows; else the scan's entry of kind original.
  do
    local st = config.mod_fork_source and config.mod_fork_source[folder_name]
    local orig = type(st) == "table" and st.original_repo or nil
    -- the copy that was installed before the switch IS what Switch Back restores (it is not always listed as kind "original")
    local lb = AMU_FIND.left_behind[folder_name]
    if not orig and type(lb) == "table" and type(lb.repo) == "string" and lb.repo ~= "" then orig = lb.repo end
    if not orig then
      local d = amu_fork_suggestions and amu_fork_suggestions.suggestions and amu_fork_suggestions.suggestions[folder_name]
      for _, f in ipairs(type(d) == "table" and d.forks or {}) do
        if amu_fork_kind(f) == "original" then orig = f.repo; break end
      end
    end
    if type(orig) == "string" and orig ~= "" then AMU_FIND.back_now[folder_name] = orig end
    AMU_FIND.switch_pending[folder_name] = true   -- cleared by the restart (memory only)
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
    local thread_code = AMU_HIDE_SRC .. [[
      local cmd = ...
      local ok = pcall(function() amu_run(cmd) end)
      local ch = love.thread.getChannel("amu_fork_switchback")
      ch:push(ok and "done" or "error")
    ]]
    local t = love.thread.newThread(thread_code)
    t:start(cmd)
    G.E_MANAGER:add_event(Event({
      blockable = false,
      blocking = false,
      no_delete = true,   -- survive the event-queue wipe when a run starts
      func = function()
        local msg = channel:pop()
        if msg then
          if msg == "done" then
            amu_fork_status.text = folder_name .. " reverted to original. Restart to apply."
          else
            amu_fork_status.text = folder_name .. " revert error. See last_run.json."
          end
          pcall(amu_reopen_if_open, "amu_fork_mod_list")   -- same rebuild the filter button does; the list alone kept the old state
          pcall(amu_update_areas, {
            ["amu_fork_mod_list"] = build_fork_mods_page(AMU_FORK_PAGE)
          })
          if msg == "done" then
            local ok, shown, why = pcall(function()
              return AMU_CRASH.ask_restart({
                folder_name .. " is back on the original mod.",
              })
            end)
            if ok and shown == false then amu_fork_status.text = folder_name .. " revert error: " .. amu_fit(tostring(why or "see last_run.json"), 0.3, 8.5) end
          end
          return true
        end
        return false
      end
    }))
  else
    AMU_RUN(cmd)
    amu_fork_status.text = folder_name .. " reverted to original. Restart to apply."
    pcall(function() AMU_CRASH.ask_restart({ folder_name .. " is back on the original mod." }) end)
  end
end

-- Register scan button handler
G.FUNCS.amu_scan_forks = function(e)
  run_fork_scan()
end

-- Hover box for one fork: a SHORT summary of what changed (never more than ~9 lines).
local function amu_fork_tip(args)
  local fork = (args and args.fork) or {}
  local cur, win = args and args.cur, args and args.win
  local dark = G.C.UI.TEXT_DARK or RGBA(0.2, 0.2, 0.25, 1)
  local blue = G.C.BLUE or dark
  local maxw = 6.4
  local grey = RGBA(0.42, 0.42, 0.48, 1)
  local green = AMU_FIND.NEWEST_DARK or RGBA(0.1, 0.5, 0.25, 1)
  local orange = RGBA(0.78, 0.4, 0.05, 1)
  local rows = {}
  local function add(text, scale, colour)
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.015 }, nodes = {
      { n = G.UIT.T, config = { text = amu_fit(text, scale, maxw), scale = scale, colour = colour or dark } } } }
  end
  local function addw(text, scale, colour, maxlines)
    for _, ln in ipairs(AMU_FIND.wrap(text, scale, maxw, maxlines or 2)) do add(ln, scale, colour) end
  end
  -- thin divider line between sections
  local function divider()
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.03 }, nodes = {
      { n = G.UIT.B, config = { w = maxw, h = 0.025, colour = RGBA(0.75, 0.75, 0.8, 1) } } } }
  end
  -- a bullet drawn as a small coloured square (the game font has no bullet glyph), text wraps with a hanging indent
  local function bullet(text, scale, colour, bcolour)
    local lines = AMU_FIND.wrap(text, scale, maxw - 0.35, 2)
    local col = {}
    for _, ln in ipairs(lines) do
      col[#col + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.01 }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit(ln, scale, maxw - 0.35), scale = scale, colour = colour or dark } } } }
    end
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "tl", padding = 0.02 }, nodes = {
      { n = G.UIT.C, config = { align = "tm", padding = 0.04 }, nodes = {
        { n = G.UIT.B, config = { w = 0.12, h = 0.12, colour = bcolour or blue } } } },
      { n = G.UIT.B, config = { w = 0.1, h = 0.1 } },
      { n = G.UIT.C, config = { align = "tl", padding = 0 }, nodes = col } } }
  end

  local day = AMU_FIND.fork_day(fork)
  add(tostring(fork.repo or "fork"), 0.34, blue)
  if win ~= nil and win == fork then add("Most recently updated copy (commit or release)", 0.27, green) end
  divider()

  -- 1. the numbers, colour coded: green = you are missing it, orange = only your copy has it
  local a, b = fork.commits_ahead or 0, fork.commits_behind or 0
  if a > 0 then bullet(a .. " new commit" .. (a == 1 and "" or "s") .. " you don't have", 0.27, green, green) end
  if b > 0 then bullet("Your copy has " .. b .. " commit" .. (b == 1 and "" or "s") .. " it lacks", 0.27, orange, orange) end

  -- 2. dates on one small grey line
  local bits = {}
  if day then bits[#bits + 1] = (AMU_FIND.d10(fork.last_commit_at) and "Their last change " or "Their last push ") .. day end
  if cur and cur.date then bits[#bits + 1] = "Your copy " .. cur.date end
  if #bits > 0 then add(table.concat(bits, "   |   "), 0.24, grey) end
  divider()

  -- 3. the actual changes, one bullet each
  add("What changed:", 0.27, blue)
  local notes = AMU_FIND.fork_notes(fork)
  local shown = 0
  for _, t in ipairs(notes) do
    if shown < 5 then
      bullet(t, 0.26, nil, blue)
      shown = shown + 1
    end
  end
  if shown == 0 then bullet(AMU_FIND.fork_fallback(fork), 0.26, nil, blue) end
  add("(compared with the copy you have installed)", 0.21, grey)

  local rel = tostring(fork.latest_release_tag or "")
  if rel ~= "" then
    divider()
    local rd = AMU_FIND.d10(fork.latest_release_at)
    add("Latest release: " .. rel .. (rd and ("  (" .. rd .. ")") or ""), 0.27, blue)
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
  local purple = AMU_FIND.theme_purple()
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
  if not cur_fork_repo and AMU_FIND.switch_pending[folder] then cur_fork_repo = AMU_FIND.back_now[folder] end   -- just switched back

  local CARD_W = 8.2
  local rows = {}

  -- "Your current copy" row: lets you read about what you have BEFORE switching away from it
  local cur_links = amu_current_page_links(folder, ref.installed_repo)
  local cur_info = AMU_FIND.current_info(folder, ref.scan)
  do
    local nd, ns = AMU_FIND.fork_now_day(folder)
    if nd then cur_info = { date = nd, stamp = ns, how = AMU_FIND.fork_now_how(folder) } end
  end
  local restart_pending = cur_fork_repo ~= nil and AMU_FIND.switch_pending[folder] == true
  local win = AMU_FIND.newest_pick(cur_info, forks, AMU_FIND.left_behind[folder])
  local cur_newest = (win == "cur")
  local cur_row = nil
  if #cur_links > 0 then
    local label = "Your current: "
    local date_txt = cur_info.date and ("  " .. cur_info.date) or ""
    -- the full name always gets its room first; the date only shows when it still fits
    local cur_name = amu_fit(tostring(cur_links[1].name), 0.3, math.max(1.6, 8.4 - #cur_links * 2.4 - amu_text_w(label, 0.3)))
    if amu_text_w(label, 0.3) + amu_text_w(cur_name, 0.3) + amu_text_w(date_txt, 0.27) > 8.9 - #cur_links * 2.4 then date_txt = "" end
    local cur_tip_lines = {}
    if cur_newest then cur_tip_lines[#cur_tip_lines + 1] = { text = "Your copy is the most recently updated one.", colour = AMU_FIND.NEWEST_DARK }
    elseif win ~= nil then
      cur_tip_lines[#cur_tip_lines + 1] = { text = "Most recently updated: " .. tostring(win.repo or "") .. "  " .. tostring(AMU_FIND.d10(AMU_FIND.fork_stamp(win)) or ""), colour = AMU_FIND.NEWEST_DARK }
      cur_tip_lines[#cur_tip_lines + 1] = { text = "Using now: " .. tostring(cur_links[1].name), colour = G.C.BLUE or dark }
    end
    local function bullets(text, extra)
      for i, l in ipairs(AMU_FIND.wrap(text, 0.27, 5.3, 3)) do
        local row = { text = l, bullet = (i == 1), indent = (i > 1) }
        for k, v in pairs(extra or {}) do if k ~= "star" then row[k] = v end end
        if i == 1 and extra and extra.star then row.star = true end   -- the first line of a starred item gets the star icon
        cur_tip_lines[#cur_tip_lines + 1] = row
      end
    end
    bullets("A green name marks the most recently updated copy.")
    if cur_info.date then
      local y, mo, d = tostring(cur_info.date):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
      local day_txt = y and (mo .. "-" .. d .. "-" .. y:sub(3, 4)) or tostring(cur_info.date)
      local how_txt = tostring(cur_info.how or "")
      how_txt = how_txt:gsub("^newest commit on GitHub$", "on GitHub"):gsub("^last commit on GitHub$", "on GitHub"):gsub("^last commit in your git clone$", "in your git clone")
      bullets("Last change " .. day_txt .. ": " .. how_txt, { star = true })
      if cur_info.lacks then bullets("Your downloaded copy does NOT have it yet", { blink = true }) end
    else
      bullets("Run Scan Now to find out when your copy last changed.")
    end
    local cur_tip = AMU_FIND.cfg_tip("Your current copy", cur_tip_lines)
    local cur_nodes = {
      { n = G.UIT.C, config = { align = "cl", padding = 0.03, minw = 3.3, on_demand_tooltip = cur_tip }, nodes = {
        { n = G.UIT.R, config = { align = "cl", padding = 0, on_demand_tooltip = cur_tip }, nodes = {
          { n = G.UIT.T, config = { text = label, scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
          { n = G.UIT.T, config = { text = cur_name, scale = 0.3,
              colour = cur_newest and G.C.GREEN or G.C.UI.TEXT_LIGHT } },
          { n = G.UIT.T, config = { text = date_txt, scale = 0.27, colour = G.C.UI.TEXT_LIGHT } } } } } },
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
    if restart_pending then
      cur_row = { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = {
          cur_row,
          { n = G.UIT.R, config = { align = "cm", padding = 0.01 }, nodes = {
            { n = G.UIT.T, config = { text = "Restart the game to apply the switch.", scale = 0.27, colour = orange } } } } } } } }
    end
  end

  for i = first, last do
    local fork        = forks[i]
    local slot        = i - first + 1
    local is_cur      = (cur_fork_repo == fork.repo)
    local kind        = amu_fork_kind(fork)
    local is_upstream = (kind == "original" or kind == "parent")
    local diverged    = (not is_upstream) and ((fork.commits_behind or 0) > 0) and ((fork.commits_ahead or 0) > 0)
    local is_tr       = amu_fork_is_translation(fork)
    local is_ign      = AMU_FORKIGN.is(fork)
    local kind_tag    = AMU_FORK_KIND[kind].tag .. (is_tr and "  /  TRANSLATION" or "") .. (is_ign and "  /  IGNORED" or "")
    local url = tostring(fork.html_url or "")
    if url == "" then url = "https://github.com/" .. tostring(fork.repo or "") end

    G.FUNCS["amu_switch_fork_" .. slot] = function(e)
      -- the repo this mod was originally installed from: picking it is a Switch Back (same as the Switch Back button)
      local back = false
      pcall(function()
        local raw = read_all(join_path(join_path(join_path(love.filesystem.getSaveDirectory(), "Mods"), folder), ".autoupdater_state.json"))
        local st = raw and decode_json(raw)
        if type(st) == "table" and st.original_repo and tostring(st.original_repo):lower() == tostring(fork.repo):lower() then back = true end
      end)
      if back then switch_back_fork(folder) else switch_to_fork(folder, fork.repo) end
      G.FUNCS.amu_back_to_menu()   -- land on the Fork Finder tab again, not the main menu
    end
    G.FUNCS["amu_ignore_fork_" .. slot] = function(e)
      local now = AMU_FORKIGN.toggle(fork.repo)
      amu_fork_status.text = tostring(fork.repo) .. (now and " is ignored: the next Fork Finder scan skips it." or " is no longer ignored: the next scan checks it again.")
      if amu_fork_picker_ref then open_overlay(G.UIDEF.amu_fork_picker(amu_fork_picker_ref)) end
    end
    G.FUNCS["amu_open_fork_" .. slot] = function(e)
      local ok = pcall(function() love.system.openURL(url) end)
      amu_fork_status.text = ok and ("Opened " .. tostring(fork.repo) .. " in your browser.") or "Couldn't open a browser."
    end

    local info_parts = { "+" .. (fork.commits_ahead or 0) .. " new" }
    if fork.ignored then info_parts = { "ignored" } end
    if (fork.commits_behind or 0) > 0 then
      info_parts[#info_parts + 1] = "yours has " .. fork.commits_behind .. " more"
    end
    if (fork.stars or 0) > 0 then info_parts[#info_parts + 1] = "\226\152\133 " .. fork.stars end
    local date_str = AMU_FIND.fork_date(fork)
    if date_str then info_parts[#info_parts + 1] = date_str end
    local info_avail = CARD_W - 0.5 - amu_text_w(kind_tag, 0.27)
    local info_scale = 0.27
    local info_str = "   " .. table.concat(info_parts, "   ")
    -- never cut the date off: tighten the gaps first, then use a smaller size
    if amu_text_w(info_str, info_scale) > info_avail then info_str = " " .. table.concat(info_parts, "  ") end
    for _, sc in ipairs({ 0.25, 0.23, 0.21 }) do
      if amu_text_w(info_str, info_scale) <= info_avail then break end
      info_scale = sc
    end
    info_str = amu_fit(info_str, info_scale, info_avail)

    local display_name, name_colour = tostring(fork.repo or ""), G.C.UI.TEXT_LIGHT
    if is_upstream then
      name_colour = orange
    elseif diverged then
      display_name, name_colour = "\226\154\160 " .. display_name, orange
    end
    if win ~= nil and win == fork then name_colour = G.C.GREEN end   -- the one most recently updated copy
    display_name = amu_fit(display_name, 0.36, CARD_W - 2.9)

    local btn_node
    if is_cur then
      btn_node = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.1, minh = 0.42, r = 0.1, colour = panel }, nodes = {
        { n = G.UIT.T, config = { text = restart_pending and "\226\156\147 Restart to apply" or "\226\156\147 Active",
            scale = restart_pending and 0.27 or 0.3, colour = restart_pending and orange or G.C.GREEN } } } }
    else
      btn_node = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.1, minh = 0.42, r = 0.1,
        colour = is_upstream and orange or G.C.GREEN, button = "amu_switch_fork_" .. slot, hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = (kind == "original") and "Switch to Original" or ((kind == "parent") and "Switch to Parent" or "Switch to Fork"),
            scale = 0.27, colour = purple } } } }
    end

    local tip = { filler = { func = amu_fork_tip, args = { fork = fork, cur = cur_info, win = win } } }

    local card = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.03, minw = CARD_W - 2.5 }, nodes = {
          { n = G.UIT.T, config = { text = display_name, scale = 0.36, colour = name_colour } } } },
        btn_node,
      }},
      { n = G.UIT.R, config = { align = "cl", padding = 0.01, on_demand_tooltip = tip }, nodes = {
        { n = G.UIT.T, config = { text = kind_tag, scale = 0.27, colour = amu_fork_kind_colour(kind), shadow = true } },
        { n = G.UIT.T, config = { text = info_str, scale = info_scale, colour = purple } } } },
    }

    local notes = AMU_FIND.fork_notes(fork)
    if #notes > 0 then
      local suffix = (#notes > 1) and ("  (+" .. (#notes - 1) .. " more, hover)") or ""
      card[#card + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.005, on_demand_tooltip = tip }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit("  \226\128\162 " .. notes[1], 0.26, CARD_W - 0.4 - amu_text_w(suffix, 0.26)) .. suffix,
            scale = 0.26, colour = G.C.UI.TEXT_LIGHT } } } }
    else
      card[#card + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.005, on_demand_tooltip = tip }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit("  " .. AMU_FIND.fork_fallback(fork), 0.26, CARD_W - 0.4), scale = 0.26, colour = G.C.UI.TEXT_LIGHT } } } }
    end

    -- the "open the fork's page" button, right under the changes
    local rel = tostring(fork.latest_release_tag or "")
    local reld = AMU_FIND.d10(fork.latest_release_at)
    -- Biggest text that still fits inside the button: try each size with the roomy spacing, then the tighter spacing.
    local wide_label  = "Open fork page" .. (rel ~= "" and ("     Release: " .. rel .. (reld and ("  " .. reld) or "")) or "")
    local tight_label = "Open fork page" .. (rel ~= "" and ("   Release: " .. rel .. (reld and (" " .. reld) or "")) or "")
    -- The button uses the empty space right of "Ignore scans" (it was 0.6 narrower); the text keeps 0.15 clear at each end.
    local OPEN_BTN_W = CARD_W - 2.8
    local OPEN_TXT_W = OPEN_BTN_W - 0.3
    local open_label, open_scale = tight_label, 0.21
    for _, sc in ipairs({ 0.4, 0.38, 0.36, 0.34, 0.32, 0.3, 0.27, 0.24, 0.21 }) do
      if amu_text_w(wide_label, sc) <= OPEN_TXT_W then open_label, open_scale = wide_label, sc; break end
      if amu_text_w(tight_label, sc) <= OPEN_TXT_W then open_label, open_scale = tight_label, sc; break end
    end
    card[#card + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = OPEN_BTN_W, minh = 0.38, r = 0.09,
          colour = G.C.BLUE, button = "amu_open_fork_" .. slot, hover = true, shadow = true, on_demand_tooltip = tip }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit(open_label, open_scale, OPEN_TXT_W), scale = open_scale, colour = G.C.UI.TEXT_LIGHT } } } },
      { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 0.42, minh = 0.42, r = 0.07,
          colour = is_ign and G.C.RED or RGBA(0.78, 0.78, 0.86, 1), button = "amu_ignore_fork_" .. slot, hover = true, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = is_ign and "X" or "  ", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } } } },
      { n = G.UIT.C, config = { align = "cl", padding = 0.04 }, nodes = {
        { n = G.UIT.T, config = { text = "Ignore scans", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } } } } } }

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
  local entries = AMU_FIND.entries("forks", config.sort_forks)
  local total_pages = math.max(1, math.ceil(#entries / AMU_FORK_PER))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_FORK_PAGE = page
  AMU_FIND.sync_pager("forks", total_pages, page)

  local purple = AMU_FIND.theme_purple()
  local orange = (G.C and G.C.ORANGE) or RGBA(0.85, 0.5, 0.05, 1)
  local rows = {}

  if #entries == 0 then
    local msg
    if amu_fork_suggestions and amu_fork_suggestions.suggestions then
      -- "No newer forks found on last scan (11-08-26)." The date is the day of the scan these results come from.
      local y, m, d = tostring(amu_fork_suggestions.checked_at or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
      msg = ((config.fork_newer_only ~= false) and "No newer forks found" or "No forks found") .. " on last scan"
        .. (y and (" (" .. m .. "-" .. d .. "-" .. y:sub(3, 4) .. ")") or "") .. "."
    else
      msg = amu_fork_scanning and "No fork data yet." or "No fork data yet. Press 'Scan Now'."
    end
    local searching = AMU_FIND.active("forks") and AMU_FIND.total.forks > 0
    if searching then msg = "No mods match your search" end
    local first = { { n = G.UIT.T, config = { text = msg, scale = 0.42, colour = purple } } }
    if amu_fork_scanning and not searching then
      first[#first + 1] = { n = G.UIT.B, config = { w = 0.3, h = 0.1 } }
      first[#first + 1] = { n = G.UIT.O, config = { object = AMU_WAVE_TEXT({ text = "NEWER SCAN IN PROGRESS", scale = 0.38, colour = orange }) } }
    end
    rows[1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = first }
    if not searching and amu_fork_suggestions and amu_fork_suggestions.suggestions and config.fork_newer_only ~= false then
      rows[2] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H }, nodes = {
        { n = G.UIT.T, config = { text = "Press 'Show all forks' to see older ones too.", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } }
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
            scan         = entry,
          }))
        end

        G.FUNCS["amu_switch_back_fork_" .. row_i] = function(e)
          switch_back_fork(folder)
        end

        G.FUNCS["amu_page_current_" .. row_i] = function(e)
          amu_fork_status.text = AMU_WEB.open_first(folder, display, entry.installed_repo)
        end

        local counts = entry.counts or {}
        local short, nf = {}, 0
        for _, k in ipairs({ "original", "parent", "parent_fork", "fork_fork", "fork" }) do
          local n = counts[k] or 0
          if n > 0 then
            if k == "original" then short[#short + 1] = "Orig"
            elseif k == "parent" then short[#short + 1] = "Parent"
            else nf = nf + n end
          end
        end
        if nf > 0 then short[#short + 1] = nf .. (nf == 1 and " fork" or " forks") end
        local fork_text = table.concat(short, " + ")
        if config.sort_forks == "recent" then
          local newest = entry.forks and entry.forks[1] and AMU_FIND.d10(AMU_FIND.fork_stamp(entry.forks[1]))
          if newest then fork_text = fork_text .. "  " .. newest end
        end
        local row_tip = { filler = { func = AMU_FORKIGN.row_tip, args = { entry = entry, display = display, folder = folder } } }
        local fork_label = amu_fit(fork_text, 0.34, 3.7)
        -- green = the copy you run now is the most recently updated one; after a switch to something older it is not green
        local label_colour
        if has_upstream then label_colour = orange
        elseif is_switched and AMU_FIND.now_is_newest(folder, entry) then label_colour = G.C.GREEN
        elseif is_switched and (entry.counts or {}).parent then label_colour = orange
        else label_colour = G.C.UI.TEXT_LIGHT end

        local action_btn
        if is_switched then
          action_btn = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.3, minh = 0.48, r = 0.09,
            colour = G.C.RED, button = "amu_switch_back_fork_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "Switch Back", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } }
        else
          action_btn = { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 2.3, minh = 0.48, r = 0.09,
            colour = G.C.BLUE, button = "amu_view_forks_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "View Forks", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } }
        end

        -- a mod you switched to a fork only had Switch Back: this button opens the fork list (where Ignore scans is)
        local forks_btn = is_switched and { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.4, minh = 0.48, r = 0.09,
            colour = G.C.BLUE, button = "amu_view_forks_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "Forks", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } }
          or { n = G.UIT.B, config = { h = 0.1, w = 1.4 } }

        local mod_ign = AMU_FORKIGN.mod_is(folder)
        G.FUNCS["amu_ign_mod_" .. row_i] = function(e)
          local now = AMU_FORKIGN.toggle_mod(folder)
          amu_fork_status.text = display .. (now and " is ignored: fork scans skip it." or " is no longer ignored: scans check it again.")
          amu_reopen_if_open("amu_fork_mod_list")
        end
        local mod_tip = { filler = { func = AMU_FORKIGN.mod_tip, args = {} } }
        local ign_box = { n = G.UIT.C, config = { align = "cm", padding = 0.02, minw = 0.46, minh = 0.46, r = 0.07,
            colour = mod_ign and G.C.RED or RGBA(0.78, 0.78, 0.86, 1), button = "amu_ign_mod_" .. row_i, hover = true, shadow = true,
            on_demand_tooltip = mod_tip }, nodes = {
          { n = G.UIT.T, config = { text = mod_ign and "X" or "  ", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } } } }

        rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_FORK_ROW_H, on_demand_tooltip = row_tip }, nodes = {
          ign_box,
          { n = G.UIT.B, config = { h = 0.1, w = 0.14 } },
          { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 4.6, on_demand_tooltip = row_tip }, nodes = {
            { n = G.UIT.T, config = { text = amu_fit(display, 0.5, 4.4), scale = 0.5, colour = mod_ign and RGBA(0.6, 0.6, 0.66, 1) or G.C.UI.TEXT_LIGHT } } } },
          { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 3.9, on_demand_tooltip = row_tip }, nodes = {
            { n = G.UIT.T, config = { text = fork_label, scale = 0.34, colour = label_colour } } } },
          { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.7, minh = 0.48, r = 0.09,
            colour = G.C.BLUE, button = "amu_page_current_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "Webpage", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } } },
          { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
          forks_btn,
          { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
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

-- Opens the results / restart window. `back` remembers whether it opened on top of one of our own screens: Later / OK then
-- return to the tab you were on (Fork Finder, Backups, ...) instead of leaving for the main menu. Opened over nothing of ours
-- (the update results at start-up), they just close as before.
function AMU_FIND.open_prompt()
  AMU_PROMPT.back = amu_screen_open() and true or false
  open_overlay(G.UIDEF.amu_restart_prompt(AMU_PROMPT))
end

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
  if #s > 0 then table.insert(out, s) elseif #out == 0 then table.insert(out, "") end
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

-- Mods the updater could not check (no git, no update.json). Ones you gave a link since the check are not counted.
local function amu_untracked_count(summary)
  local u = summary and summary.untracked_mods
  if type(u) == "string" then u = { u } end
  if type(u) ~= "table" or config.show_untracked_note == false then return 0 end
  local n = 0
  local mods_dir = join_path(love.filesystem.getSaveDirectory(), "Mods")
  for _, name in ipairs(u) do
    if type(name) == "string" and not file_exists(join_path(join_path(mods_dir, name), "update.json")) then n = n + 1 end
  end
  return n
end

local function build_prompt_lines(summary)
  local lines = {}
  local updated = summary.updated_mods or {}
  local errors = summary.errors or {}
  local skipped = summary.skipped_mods or {}

  -- first, so it is never hidden below the scroll
  if summary.github_token_bad == true then
    table.insert(lines, "Your GitHub token has expired or was rejected.")
    table.insert(lines, "Updates ran without it (GitHub allows 60 checks per hour).")
    table.insert(lines, "When you close this window you can replace it.")
    table.insert(lines, "")
  end
  local untracked_n = amu_untracked_count(summary)
  if untracked_n > 0 then
    table.insert(lines, tostring(untracked_n) .. " mod(s) have no update source, so they are never checked.")
    table.insert(lines, "Add their links in Mods > Mod Updater > No Source.")
    table.insert(lines, "")
  end

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
    -- Nexus answered 401: the key is missing, wrong, or was replaced on the Nexus site
    local nexus_401 = false
    for _, e in ipairs(errors) do
      local t = tostring(e)
      if t:find("(nexus)", 1, true) and (t:find("401", 1, true) or t:lower():find("unauthorized", 1, true)) then nexus_401 = true break end
    end
    if nexus_401 then
      table.insert(lines, "Nexus did not accept your API key. Get a new one:")
      table.insert(lines, "    Mods > Mod Updater > Config > How do I get a key?")
      table.insert(lines, "")
    end
  end

  local stale = summary.folder_name_stale
  if type(stale) == "string" then stale = { stale } end
  if type(stale) == "table" and #stale > 0 then
    table.insert(lines, "Folder names that still show an old version:")
    for i = 1, math.min(#stale, 6) do table.insert(lines, "    " .. tostring(stale[i])) end
    table.insert(lines, "The mod itself is up to date. The name is only a label.")
    table.insert(lines, "To fix it, close the game and rename the folder.")
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

  if #skipped > 0 and #updated == 0 then
    -- Mods you switched off are just counted; only show skips that tell you something.
    local shown, off = {}, 0
    for _, v in ipairs(skipped) do
      local sv = tostring(v)
      local fw_current = sv:find("[Framework] ", 1, true) and sv:find("already current", 1, true)
      if fw_current and config.cfg_show_framework_current ~= true then
        -- hidden by default: only pending restarts and problems are worth a line (switch on in Config)
      elseif sv:find("(updates disabled)", 1, true) or sv:find("[Framework debug]", 1, true) then
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
  if untracked_n > 0 and #updated == 0 and #errors == 0 and #(summary.available_updates or {}) == 0 then
    table.insert(lines, "No mod updates were applied.")
  end
  return wrap_lines(lines, 46)
end

function show_prompt(summary)
  local updated = summary and summary.updated_mods or {}
  local errors = summary and summary.errors or {}
  local available = summary and summary.available_updates or {}
  local fw = summary and summary.framework_staged == true
  if summary then AMU_TOKEN_UI.on_summary(summary) end
  local should = (#updated > 0) or fw or (#available > 0) or ((config.prompt_on_errors ~= false) and (#errors > 0))
    or (amu_untracked_count(summary) > 0) or (summary and summary.github_token_bad == true)
  -- no GitHub token at all: ask about getting one after every update check (turn off with "ask_missing_token": false)
  local no_token = not (config.github_token and config.github_token ~= "") and config.ask_missing_token ~= false
  if not should then
    if summary and not no_token then pcall(AMU_FIND.toast.show, { "All mods up to date!" }, { seconds = 5 }) end
    if no_token and G and G.E_MANAGER and Event then
      G.E_MANAGER:add_event(Event({ trigger = "after", delay = 0.35, blocking = false, func = function()
        open_overlay(G.UIDEF.amu_token_problem("missing"))
        return true
      end }))
    end
    return
  end

  AMU_PROMPT.token_bad = (summary and summary.github_token_bad == true) or false
  AMU_PROMPT.token_missing = no_token and not AMU_PROMPT.token_bad
  AMU_PROMPT.title = "Mod Updater"
  AMU_PROMPT.lines = build_prompt_lines(summary)
  AMU_PROMPT.has_updates = (#updated > 0) or fw

  AMU_PROMPT.page = 1
  AMU_FIND.open_prompt()
end

-- The results window shows 12 lines at a time. Longer results scroll: drag the bar on the right, use the mouse wheel,
-- the right stick, or LB (up) / RB (down). The window is always the same size, so it can never run off the screen.
-- On a controller the cursor starts on the buttons and stays inside this window until you answer it.
-- (State lives in the AMU_SCR table, not in locals: main.lua is close to Lua's limit of local variables.)
AMU_SCR = AMU_SCR or { VISIBLE = 12, SEGS = 36, first = 1, total = 0, vis = 0, lines = {}, view = {}, segs = {}, alive_at = -10, acc = 0 }
do
  local S = AMU_SCR
  S.thumb_col = RGBA(0.62, 0.33, 0.92, 1)
  S.track_col = RGBA(0.3, 0.3, 0.38, 1)

  local function now() return (G and G.TIMERS and G.TIMERS.REAL) or 0 end

  function S.fill()
    for i = 1, S.vis do
      local v = S.lines[S.first + i - 1]
      if v == nil or v == "" then v = " " end
      S.view[i] = v
    end
  end

  -- colour the bar: the purple part is the part of the list you are looking at
  function S.paint()
    local n = S.SEGS
    local span = math.max(1, S.total - S.vis)
    local len = math.max(2, math.min(n, math.floor(n * S.vis / math.max(1, S.total) + 0.5)))
    local start = math.floor((n - len) * (S.first - 1) / span + 0.5)
    for i = 1, n do
      local seg = S.segs[i]
      if seg then seg.colour = (i > start and i <= start + len) and S.thumb_col or S.track_col end
    end
  end

  function S.set_first(f)
    local maxf = math.max(1, S.total - S.vis + 1)
    f = math.max(1, math.min(maxf, math.floor(f + 0.5)))
    if f == S.first then return false end
    S.first = f
    S.fill()
    S.paint()
    return true
  end

  function S.scroll(by) return S.set_first(S.first + by) end

  function S.active() return (now() - (S.alive_at or -10)) < 0.25 and S.total > S.vis end

  -- mouse wheel
  -- Other mods replace love.wheelmoved after we loaded (Better Mouse and Gamepad does, and never calls the old one), which
  -- silently removed this hook. So the hook is put back by the results window itself (S.ensure_wheel, every frame while it
  -- is open), chaining to whatever handler is there at that moment.
  S.wheel_fn = S.wheel_fn or function(x, y, ...)
    if y and y ~= 0 and S.active() then
      S.scroll(y > 0 and -3 or 3)
      return
    end
    if S.in_wheel then return end -- a mod that wrapped us calls us again: stop the loop
    local prev = S.wheel_prev
    if prev then
      S.in_wheel = true
      local ok, err = pcall(prev, x, y, ...)
      S.in_wheel = false
      if not ok then error(err, 0) end
    end
  end

  function S.ensure_wheel()
    if love and love.wheelmoved ~= S.wheel_fn then
      S.wheel_prev = love.wheelmoved
      love.wheelmoved = S.wheel_fn
    end
  end
  S.ensure_wheel()

  -- While one of our windows is open, the game may not focus anything outside it. (The tick functions only used to pull the
  -- cursor back after it had jumped, which showed as a flicker.) Rejecting outside nodes here means the cursor never leaves.
  AMU_MODAL = AMU_MODAL or { alive_at = -10 }
  function AMU_MODAL.touch() AMU_MODAL.alive_at = now() end
  function AMU_MODAL.active()
    return G and G.OVERLAY_MENU and (now() - (AMU_MODAL.alive_at or -10)) < 0.25
  end
  if Controller and not Controller._amu_modal_focus then
    Controller._amu_modal_focus = true
    local orig_focusable = Controller.is_node_focusable
    function Controller:is_node_focusable(node)
      local ok = orig_focusable(self, node)
      if ok and AMU_MODAL.active() and node.UIBox ~= G.OVERLAY_MENU then return false end
      return ok
    end
  end

  -- Token windows: D-pad moves over a fixed grid (rows of buttons, left to right) instead of the game's "closest node" guess,
  -- which skipped buttons and jumped rows out of order. Left/Right wrap inside a row; Up/Down keep the column number.
  function AMU_MODAL.grid_move(ctrl, dir)
    local om = G.OVERLAY_MENU
    local cur = ctrl.focused and ctrl.focused.target
    local items = {}
    for _, v in pairs(G.MOVEABLES) do
      if v.UIBox == om and v.T and ctrl:is_node_focusable(v) then
        items[#items + 1] = { n = v, x = v.T.x + 0.5 * v.T.w, y = v.T.y + 0.5 * v.T.h }
      end
    end
    if #items < 2 then return false end
    table.sort(items, function(a, b) return a.y < b.y end)
    local rows = {}
    for _, it in ipairs(items) do
      local last = rows[#rows]
      if last and math.abs(it.y - last.y) < 0.25 then last[#last + 1] = it
      else rows[#rows + 1] = { it, y = it.y } end
    end
    local ri, ci
    for r, row in ipairs(rows) do
      table.sort(row, function(a, b) return a.x < b.x end)
      for i, it in ipairs(row) do if it.n == cur then ri, ci = r, i end end
    end
    if not ri then return false end
    local tr, tc = ri, ci
    if dir == "L" then tc = (ci - 2) % #rows[ri] + 1
    elseif dir == "R" then tc = ci % #rows[ri] + 1
    elseif dir == "U" then tr = (ri - 2) % #rows + 1; tc = math.min(ci, #rows[tr])
    elseif dir == "D" then tr = ri % #rows + 1; tc = math.min(ci, #rows[tr])
    else return false end
    local target = rows[tr][tc].n
    if target == cur then return true end
    ctrl.focused.prev_target = cur
    if cur.states and cur.states.focus then cur.states.focus.is = false end
    ctrl.focused.target = target
    target.states.focus.is = true
    ctrl:update_cursor()
    return true
  end
  if Controller and not Controller._amu_grid_nav then
    Controller._amu_grid_nav = true
    local orig_nav = Controller.navigate_focus
    function Controller:navigate_focus(dir)
      local om = G.OVERLAY_MENU
      if dir and om and AMU_MODAL.active() and AMU_MODAL.grid_om == om
         and self.HID and self.HID.controller and not self.interrupt.focus
         and self.focused and self.focused.target and self.focused.target.UIBox == om then
        local ok, handled = pcall(AMU_MODAL.grid_move, self, dir)
        if ok and handled then return end
      end
      return orig_nav(self, dir)
    end
  end

  -- While the results window is open the right stick scrolls it (it must not move the pointer, which would switch the
  -- game to pointer mode and take the highlight off the buttons). So the game is shown the stick as "centred".
  if Controller and not Controller._amu_prompt_axis then
    Controller._amu_prompt_axis = true
    local orig_axis = Controller.update_axis
    function Controller:update_axis(dt)
      local gp = self.GAMEPAD
      local real = gp and gp.object
      if real and S.active() or (real and (now() - (S.alive_at or -10)) < 0.25) then
        local okr, ry = pcall(real.getGamepadAxis, real, "righty")
        S.stick_y = okr and ry or 0
        local proxy = setmetatable({}, { __index = function(_, k)
          if k == "getGamepadAxis" then
            return function(_, name, ...)
              if name == "righty" or name == "rightx" then return 0 end
              return real:getGamepadAxis(name, ...)
            end
          end
          local v = real[k]
          if type(v) == "function" then return function(_, ...) return v(real, ...) end end
          return v
        end })
        gp.object = proxy
        local ok, res = pcall(orig_axis, self, dt)
        gp.object = real
        if not ok then error(res, 0) end
        return res
      end
      S.stick_y = 0
      return orig_axis(self, dt)
    end
  end

  -- run every frame by the results window itself (so it stops by itself when the window is gone)
  function G.FUNCS.amu_prompt_tick(e)
    S.alive_at = now()
    AMU_MODAL.touch()
    S.ensure_wheel()
    local c = G.CONTROLLER
    if not c then return end
    local using_pad = c.HID and c.HID.controller and c.snap_to
    -- 1. keep the controller cursor inside this window
    if using_pad then
      local om = G.OVERLAY_MENU
      local t = c.focused and c.focused.target
      -- Only when the window is new, or the cursor is really on something outside it. A momentarily empty focus (the game
      -- clears it while the stick is used) must NOT snap back: that made the highlight blink between buttons.
      local fresh = AMU_MODAL.first_om ~= om
      local stray = t and t.UIBox ~= om
      if om and e.UIBox == om and (fresh or stray) and not c.locks.frame then
        local n = e.UIBox.get_UIE_by_ID and e.UIBox:get_UIE_by_ID("amu_prompt_main")
        if n then
          AMU_MODAL.first_om = om
          pcall(c.snap_to, c, { node = n })
          if c.update_cursor then pcall(c.update_cursor, c) end
          c.interrupt.focus = false
        end
      end
    end
    -- 2. controller scrolling: right stick (up/down) and LB / RB
    if S.total > S.vis then
      local dt = (love.timer and love.timer.getDelta and love.timer.getDelta()) or 0.016
      local sy = S.stick_y or 0
      if math.abs(sy) > 0.25 then
        S.acc = S.acc + sy * 18 * dt
        local whole = S.acc >= 0 and math.floor(S.acc) or math.ceil(S.acc)
        if whole ~= 0 then S.acc = S.acc - whole; S.scroll(whole) end
      else
        S.acc = 0
      end
      local real = c.GAMEPAD and c.GAMEPAD.object
      if real then
        local okl, lb = pcall(real.isGamepadDown, real, "leftshoulder")
        local okr, rb = pcall(real.isGamepadDown, real, "rightshoulder")
        local dir = (okl and lb and -1) or (okr and rb and 1) or 0
        if dir == 0 then
          S.held_dir, S.next_rep = 0, nil
        else
          local t = now()
          if S.held_dir ~= dir then
            S.held_dir, S.next_rep = dir, t + 0.4
            S.scroll(dir * 3)
          elseif S.next_rep and t >= S.next_rep then
            S.next_rep = t + 0.08
            S.scroll(dir * 3)
          end
        end
      end
    end
  end

  -- the bar: click or drag it
  function G.FUNCS.amu_scroll_track(e)
    e.states.drag.can = true
    local c = G.CONTROLLER
    if not c then return end
    if c.dragging.target == e or (c.is_cursor_down and c.cursor_down.target == e) then
      local h = e.T.h
      if h and h > 0 then
        local ratio = (G.CURSOR.T.y - G.ROOM.T.y - e.T.y) / h
        local frac = S.vis / math.max(1, S.total)
        local pos = (ratio - frac / 2) / math.max(0.001, 1 - frac)
        pos = math.max(0, math.min(1, pos))
        S.set_first(1 + pos * math.max(0, S.total - S.vis))
      end
    end
  end
end

G.UIDEF.amu_restart_prompt = function(ref)
  local S = AMU_SCR
  local purple = AMU_FIND.theme_purple()
  local bg    = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel = RGBA(0.12, 0.12, 0.12, 0.96)

  local lines = ref.lines or {}
  S.lines, S.total = lines, #lines
  S.vis = math.min(#lines, S.VISIBLE)
  S.first, S.acc, S.view, S.segs = 1, 0, {}, {}
  S.fill()
  local need_bar = #lines > S.vis

  local max_len = 0
  for i = 1, #lines do
    local s = tostring(lines[i] or "")
    if #s > max_len then max_len = #s end
  end

  local w = math.min(15.5, math.max(10.0, 6.4 + max_len * 0.11))
  local line_h = 0.42
  -- the same height whatever is scrolled to, so the window never jumps around
  local content_h = math.max(1.9, S.vis * line_h + 0.3)

  local text_rows = {}
  for i = 1, S.vis do
    text_rows[#text_rows+1] = {
      n = G.UIT.R,
      config = { align = "cl", padding = 0.01 },
      nodes = {
        { n = G.UIT.T, config = { ref_table = S.view, ref_value = i, scale = 0.4, colour = purple, no_recalc = true } }
      }
    }
  end

  local function btn(label, func, colour, minw, id, tcol, tscale)
    return { n = G.UIT.C, config = { id = id, align = "cm", padding = 0.1, minw = minw or 3.0, minh = 0.75, r = 0.15, colour = colour, button = func, hover = true, shadow = true }, nodes = {
      { n = G.UIT.T, config = { text = label, scale = tscale or 0.5, colour = tcol or purple } }
    }}
  end
  local gap = { n = G.UIT.B, config = { h = 0.1, w = 0.3 } }

  local buttons_row = { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {} }
  if ref.has_updates and (config.prompt_restart ~= false) then
    buttons_row.nodes = { btn("Restart now", "amu_restart_now", G.C.GREEN, 3.3, "amu_prompt_main"), gap, btn("Later", "amu_close_prompt", panel, 2.2) }
  else
    buttons_row.nodes = { btn("OK", "amu_close_prompt", panel, 3.0, "amu_prompt_main") }
  end
  -- Later / OK return to the page you were on; this one leaves every menu instead
  if ref.back then
    buttons_row.nodes[#buttons_row.nodes + 1] = gap
    buttons_row.nodes[#buttons_row.nodes + 1] = btn("Close All Menus", "amu_close_all", G.C.RED, 3.0, nil, G.C.UI.TEXT_LIGHT, 0.4)
  end

  local list_row = { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
    { n = G.UIT.C, config = { align = "tl", padding = 0.10, minw = w - 1.2, minh = content_h, r = 0.16, colour = panel, func = "amu_prompt_tick" }, nodes = text_rows }
  }}

  if need_bar then
    local seg_h = content_h / S.SEGS
    local seg_rows = {}
    for i = 1, S.SEGS do
      local cfg = { w = 0.3, h = seg_h, colour = S.track_col }
      S.segs[i] = cfg
      seg_rows[i] = { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = { { n = G.UIT.B, config = cfg } } }
    end
    S.paint()
    list_row.nodes[#list_row.nodes+1] = { n = G.UIT.B, config = { h = 0.1, w = 0.12 } }
    list_row.nodes[#list_row.nodes+1] = { n = G.UIT.C, config = { id = "amu_scr_track", align = "tm", padding = 0, minw = 0.3, minh = content_h,
      r = 0.08, colour = S.track_col, collideable = true, hover = true, func = "amu_scroll_track" }, nodes = seg_rows }
  end

  local nodes = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.T, config = { text = ref.title or "Mod Updater", scale = 0.65, colour = purple, shadow = true } }
    }},
    buttons_row,
    list_row,
  }

  if need_bar then
    nodes[#nodes+1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
      { n = G.UIT.T, config = { text = "Scroll: mouse wheel, drag the bar, right stick, or LB / RB", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = w, padding = 0.2, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = nodes
  }
end


function G.FUNCS.amu_close_prompt(e)
  local ask = AMU_PROMPT and AMU_PROMPT.token_bad
  local ask_missing = AMU_PROMPT and AMU_PROMPT.token_missing
  local back = AMU_PROMPT and AMU_PROMPT.back
  if AMU_PROMPT then AMU_PROMPT.token_bad = false; AMU_PROMPT.token_missing = false; AMU_PROMPT.back = false end
  -- opened on top of one of our screens (a fork switch, a restore ...): go back to the tab you were on
  if back and not (ask or ask_missing) then
    G.FUNCS.amu_back_to_menu(e)
    return
  end
  close_overlay()
  -- expired or missing GitHub token: ask about a new one once this window is gone
  if (ask or ask_missing) and G and G.E_MANAGER and Event then
    G.E_MANAGER:add_event(Event({ trigger = "after", delay = 0.35, blocking = false, func = function()
      open_overlay(G.UIDEF.amu_token_problem(ask and "bad_update" or "missing"))
      return true
    end }))
  end
end
G.FUNCS.amu_token_not_now = function(e) close_overlay() end
function G.FUNCS.amu_restart_now(e)
  pcall(function() AMU_UI.save_config() end)
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
    AMU_RUN(cmd, true)
    love.event.quit()
    return
  end

  if config.auto_relaunch_via_steam ~= false and config.steam_appid then
    -- The helper (crash_guard.lua) waits for the game to close and starts it again; a plain "start steam://..." from
    -- inside the game is often ignored by Steam ("Game already running"). Fall back to that only if the helper can't run.
    local okh, started = pcall(function() return AMU_CRASH_GUARD and AMU_CRASH_GUARD.relaunch_helper and AMU_CRASH_GUARD.relaunch_helper() end)
    if not (okh and started) then
      local url = "steam://rungameid/" .. tostring(config.steam_appid)
      pcall(love.system.openURL, url)
    end
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

---------------------------------------------------------------------------
-- CRASH RECOVERY - screens and actions
--   1. "Crash Detected": put them all back / choose which / not now
--   2. the picker: one check box per mod, then Revert selected / Revert all / Keep all
-- Mouse, keyboard and controller all work: every button is a normal game button, so D-pad / stick move between
-- them and A presses; B (or Esc) is the screen's Back button; holding B closes every menu (see the navigation
-- section above). The picker's page selector answers LB / RB.
---------------------------------------------------------------------------
AMU_CRASH.PER, AMU_CRASH.ROW_H = 6, 0.60
AMU_CRASH.W, AMU_CRASH.H = 9.6, 6 * 0.60
AMU_CRASH.status = amu_status_tbl(0.32, 9.0, "")
AMU_CRASH.count  = amu_status_tbl(0.3, 4.2, "")

function AMU_CRASH.colours()
  return {
    purple = AMU_FIND.theme_purple(),
    bg     = RGBA(0.08, 0.08, 0.08, 0.96),
    panel  = RGBA(0.12, 0.12, 0.12, 0.96),
    grey   = RGBA(0.27, 0.27, 0.31, 1),
    light  = G.C.UI.TEXT_LIGHT,
  }
end

function AMU_CRASH.ticked()
  local out = {}
  for _, e in ipairs(AMU_CRASH.mods) do
    if AMU_CRASH.sel[e.mod_name] then out[#out + 1] = e.mod_name end
  end
  return out
end

function AMU_CRASH.all_names()
  local out = {}
  for _, e in ipairs(AMU_CRASH.mods) do out[#out + 1] = e.mod_name end
  return out
end

function AMU_CRASH.refresh_count()
  AMU_CRASH.count.text = "Ticked: " .. #AMU_CRASH.ticked() .. " of " .. #AMU_CRASH.mods
end

-- A big button for the question screen. `id` marks the Back button (B / Esc press it).
function AMU_CRASH.big_btn(label, func, colour, minw, id)
  return { n = G.UIT.C, config = { id = id, align = "cm", padding = 0.1, minw = minw, minh = 0.72, r = 0.14,
      colour = colour, button = func, hover = true, shadow = true }, nodes = {
    { n = G.UIT.T, config = { text = label, scale = 0.46, colour = G.C.UI.TEXT_LIGHT, shadow = true } } } }
end

-- Text lines of the question: what was updated, and what the choices do.
function AMU_CRASH.prompt_lines()
  local lines = {}
  local function add(text, kind)
    for _, part in ipairs(wrap_line(text, 76)) do lines[#lines + 1] = { text = part, kind = kind or "t" } end
  end
  add("Balatro did not start properly after the last update.", "h")
  add("These mods were updated just before it:", "t")
  local mods = AMU_CRASH.mods
  for i = 1, math.min(#mods, 8) do
    lines[#lines + 1] = { text = "    " .. amu_fit(AMU_CRASH.label(mods[i]), 0.36, 9.6), kind = "t" }
  end
  if #mods > 8 then lines[#lines + 1] = { text = "    ...and " .. (#mods - 8) .. " more", kind = "t" } end
  lines[#lines + 1] = { text = "", kind = "t" }
  add("Put them back to the versions you had before? They are pinned afterwards, so they are not updated again until you unpin them (Mod Updater > Backups).", "t")
  if AMU_CRASH.extra_note then add(AMU_CRASH.extra_note, "t") end
  return lines
end

G.UIDEF.amu_crash_prompt = function()
  local c = AMU_CRASH.colours()
  AMU_CRASH.load()
  AMU_CRASH.status.text = ""

  local text_rows = {}
  for _, ln in ipairs(AMU_CRASH.prompt_lines()) do
    text_rows[#text_rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.012, minh = 0.3 }, nodes = {
      { n = G.UIT.T, config = { text = (ln.text ~= "" and ln.text or " "), scale = 0.36,
          colour = (ln.kind == "h") and c.purple or c.light } } } }
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = 11.4, padding = 0.22, r = 0.2, colour = c.bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.B, config = { id = "amu_marker", w = 0, h = 0 } },
        { n = G.UIT.B, config = { id = "amu_crash_marker", w = 0, h = 0 } },
        { n = G.UIT.T, config = { text = "Crash Detected", scale = 0.66, colour = c.purple, shadow = true } } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.12, minw = 10.4, r = 0.16, colour = c.panel }, nodes = text_rows } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.04, minh = 0.4 }, nodes = {
        { n = G.UIT.T, config = { ref_table = AMU_CRASH.status, ref_value = "text", scale = 0.32, colour = c.purple } } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        AMU_CRASH.big_btn("Yes, put them all back", "amu_crash_revert_all", G.C.GREEN, 4.2),
        { n = G.UIT.B, config = { w = 0.25, h = 0.1 } },
        AMU_CRASH.big_btn("Choose mods...", "amu_crash_choose", G.C.BLUE, 3.4),
        { n = G.UIT.B, config = { w = 0.25, h = 0.1 } },
        AMU_CRASH.big_btn("Not now", "amu_crash_later", c.grey, 2.4, "overlay_menu_back_button"),
      } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { text = "Not now: nothing changes, and you are asked again the next time you start the game.",
            scale = 0.26, colour = c.light } } } },
    },
  }
end

---------------------------------------------------------------------------
-- The picker
---------------------------------------------------------------------------

function AMU_CRASH.build_page(page)
  local mods, per = AMU_CRASH.mods, AMU_CRASH.PER
  local total_pages = math.max(1, math.ceil(#mods / per))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_CRASH.page = page

  local c = AMU_CRASH.colours()
  local rows = {}
  local first, last = (page - 1) * per + 1, math.min(#mods, page * per)
  for i = first, last do
    local e = mods[i]
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02, minh = AMU_CRASH.ROW_H }, nodes = {
      { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 4.4 }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit(e.mod_name, 0.44, 4.3), scale = 0.44, colour = c.light } } } },
      { n = G.UIT.C, config = { align = "cl", padding = 0.04, minw = 3.9 }, nodes = {
        { n = G.UIT.T, config = { text = amu_fit(AMU_CRASH.detail(e), 0.27, 3.8), scale = 0.27, colour = c.light } } } },
      { n = G.UIT.C, config = { align = "cm", padding = 0, minw = 0.9 }, nodes = {
        amu_tight_toggle {
          ref_table = AMU_CRASH.sel,
          ref_value = e.mod_name,
          callback = function() AMU_CRASH.refresh_count() end,
        },
      } },
    } }
  end
  local shown = math.max(0, last - first + 1)
  for _ = shown + 1, per do rows[#rows + 1] = amu_blank_row(AMU_CRASH.W - 0.5, AMU_CRASH.ROW_H) end
  return amu_list_root(rows, AMU_CRASH.W, AMU_CRASH.H)
end

G.FUNCS.amu_crash_pick_page = function(args)
  if not args or not args.cycle_config then return end
  amu_update_area("amu_crash_list", AMU_CRASH.build_page(args.cycle_config.current_option or 1))
end

G.UIDEF.amu_crash_picker = function()
  local c = AMU_CRASH.colours()
  AMU_CRASH.load()
  AMU_CRASH.refresh_count()
  AMU_CRASH.status.text = ""

  local tab = amu_make_tab({
    id = "amu_crash_list", cb = "amu_crash_pick_page", build = AMU_CRASH.build_page,
    count = #AMU_CRASH.mods, per_page = AMU_CRASH.PER,
    get_page = function() return AMU_CRASH.page end, set_page = function(p) AMU_CRASH.page = p end,
    panel_w = 10.4, list_w = AMU_CRASH.W, list_h = AMU_CRASH.H, gap_top = 0.1,
    top = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        { n = G.UIT.B, config = { id = "amu_marker", w = 0, h = 0 } }, { n = G.UIT.B, config = { id = "amu_crash_marker", w = 0, h = 0 } },
        { n = G.UIT.T, config = { text = "Choose what to put back", scale = 0.5, colour = c.purple, shadow = true } } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { text = "Ticked mods go back to the version from before the update, and are pinned.",
            scale = 0.3, colour = c.light } } } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        amu_btn("Revert selected", "amu_crash_revert_selected", G.C.GREEN, 2.6, 0.34),
        amu_gap(0.1),
        amu_btn("Revert all", "amu_crash_pick_revert_all", G.C.ORANGE or RGBA(0.85, 0.5, 0.05, 1), 1.9, 0.34),
        amu_gap(0.1),
        amu_btn("Keep all", "amu_crash_keep_all", G.C.BLUE, 1.8, 0.34),
      } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        amu_btn("Tick all", "amu_crash_sel_all", c.grey, 1.5, 0.3),
        amu_gap(0.1),
        amu_btn("Untick all", "amu_crash_sel_none", c.grey, 1.7, 0.3),
        amu_gap(0.15),
        { n = G.UIT.C, config = { align = "cm", minw = 3.0 }, nodes = {
          { n = G.UIT.T, config = { ref_table = AMU_CRASH.count, ref_value = "text", scale = 0.3, colour = c.light } } } },
      } },
    },
    after = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.01, minh = 0.4 }, nodes = {
        { n = G.UIT.T, config = { ref_table = AMU_CRASH.status, ref_value = "text", scale = 0.3, colour = c.purple } } } },
    },
  })

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.16, r = 0.2, colour = c.bg, shadow = true, hover = true },
    nodes = {
      tab.nodes[1],
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        AMU_CRASH.big_btn("Back", "amu_crash_pick_back", c.grey, 2.6, "overlay_menu_back_button"),
      } },
    },
  }
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Tick / untick everything and redraw the visible page
function AMU_CRASH.set_all(value)
  for _, e in ipairs(AMU_CRASH.mods) do AMU_CRASH.sel[e.mod_name] = value and true or false end
  AMU_CRASH.refresh_count()
  amu_update_area("amu_crash_list", AMU_CRASH.build_page(AMU_CRASH.page))
end
G.FUNCS.amu_crash_sel_all  = function(e) AMU_CRASH.set_all(true) end
G.FUNCS.amu_crash_sel_none = function(e) AMU_CRASH.set_all(false) end

-- Show a text window (the same one the update results use). `restart` adds the Restart now / Later buttons.
function AMU_CRASH.show_lines(title, lines, restart)
  AMU_PROMPT.title = title
  AMU_PROMPT.lines = wrap_lines(lines, 46)
  AMU_PROMPT.page = 1
  AMU_PROMPT.has_updates = restart and true or false
  AMU_FIND.open_prompt()
end

-- After a revert or a fork switch has finished: if the helper reported no error, show the same "Restart now / Later"
-- window the updates use (the files only load when the game restarts). Returns true when the window was shown,
-- or false and the first error text when the helper reported a problem.
function AMU_CRASH.ask_restart(lines)
  local sum = decode_json(read_all(AMU_CRASH.path("last_run.json")) or "")
  local errs = type(sum) == "table" and sum.errors or nil
  if type(errs) == "string" then errs = { errs } end
  if type(errs) == "table" and #errs > 0 then return false, tostring(errs[1]) end
  local out = {}
  for i = 1, #lines do out[#out + 1] = lines[i] end
  out[#out + 1] = ""
  out[#out + 1] = "Restart Balatro so it loads the changed files."
  AMU_CRASH.show_lines("Mod Updater", out, true)
  return true
end

-- Tell the player what was put back (and pinned), what stayed as it is, and what could not be put back.
-- `fresh` = it just happened in this session (so the game still has to be restarted to load the old versions).
function AMU_CRASH.show_result(reverted, failed, kept, fresh)
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  if #reverted > 0 then
    add("Put back to the version from before the update, and pinned (" .. #reverted .. "):")
    for i = 1, math.min(#reverted, 14) do add("    " .. reverted[i]) end
    if #reverted > 14 then add("    ...and " .. (#reverted - 14) .. " more") end
    add("")
    add("Pinned mods are not updated again until you unpin them (Mod Updater > Backups).")
  end
  if #kept > 0 then
    if #lines > 0 then add("") end
    add("Kept as they are (" .. #kept .. "):")
    for i = 1, math.min(#kept, 10) do add("    " .. kept[i]) end
    if #kept > 10 then add("    ...and " .. (#kept - 10) .. " more") end
    add("If the game crashes again, you are asked again.")
  end
  if #failed > 0 then
    if #lines > 0 then add("") end
    add("Could not be put back (" .. #failed .. "):")
    for i = 1, math.min(#failed, 8) do add("    " .. failed[i]) end
  end
  if #reverted > 0 and fresh then
    add("")
    add("Restart Balatro so it loads the old versions.")
  end
  AMU_CRASH.show_lines("Mod Updater - Crash Recovery", lines, fresh and #reverted > 0)
end

-- Read (and delete) the put-back report. Returns the lists from AMU_CRASH.apply_report.
function AMU_CRASH.process_report()
  local report_path = AMU_CRASH.path("_crash_rollback_report.json")
  if not file_exists(report_path) then return {}, {}, {} end
  local data = read_all(report_path)
  pcall(os.remove, report_path)
  local reverted, failed, kept = AMU_CRASH.apply_report(data and decode_json(data))
  if #reverted > 0 then pcall(write_ps1_config_overlay) end
  return reverted, failed, kept
end

-- autoupdate.ps1 finished a put-back: say what happened.
function AMU_CRASH.finish()
  local reverted, failed, kept = AMU_CRASH.process_report()
  local waiting = AMU_CRASH.load()
  if #reverted > 0 or #failed > 0 then
    AMU_CRASH.show_result(reverted, failed, kept, true)
  elseif waiting > 0 then
    -- the script could not do it (see last_run.json): put the question back so the player can try again
    AMU_CRASH.shown = true
    open_overlay(G.UIDEF.amu_crash_prompt())
    AMU_CRASH.status.text = "The put-back did not run. Details: last_run.json"
  else
    AMU_CRASH.show_lines("Mod Updater - Crash Recovery", { "Nothing was changed.", "", "Details: last_run.json" }, false)
  end
end

-- Put the previous version of these mods back (autoupdate.ps1 does the work in the background).
function AMU_CRASH.run_revert(names)
  if AMU_CRASH.busy then return end
  if #names == 0 then
    AMU_CRASH.status.text = "Nothing is ticked. Tick a mod, or press Keep all."
    return
  end
  if not is_windows() then AMU_CRASH.status.text = "Windows only"; return end
  if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
    AMU_CRASH.status.text = "No thread support"
    return
  end

  -- No trailing slash on the folders: Windows reads a backslash right before a closing quote as an escaped quote,
  -- which would swallow the arguments after it (the older commands get away with it because -SelfDir is their last one).
  local mods_dir = (join_path(love.filesystem.getSaveDirectory(), "Mods"):gsub("[/\\]+$", ""))
  local mod_path = (amu_mod_path():gsub("[/\\]+$", ""))
  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then AMU_CRASH.status.text = "autoupdate.ps1 is missing"; return end

  -- which mods: a small file next to the script (mod names can hold spaces and brackets, so not on the command line)
  if not AMU_CRASH.write_json("_crash_selection.json", { mods = names }) then
    AMU_CRASH.status.text = "Could not write _crash_selection.json"
    return
  end
  pcall(write_ps1_config_overlay)

  local cmd = table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", safe_quote(winpath(ps1)),
    "-ModsDir", safe_quote(winpath(mods_dir)),
    "-SelfDir", safe_quote(winpath(mod_path)),
    "-RollbackRecent",
    "-SelectionFile", safe_quote(winpath(AMU_CRASH.path("_crash_selection.json"))),
  }, " ")

  AMU_CRASH.busy = true
  AMU_CRASH.status.text = "Putting the old versions back... please wait."

  local channel = love.thread.getChannel("amu_crash_revert")
  channel:clear()
  local thread_code = AMU_HIDE_SRC .. [[
    local cmd = ...
    local ok = pcall(function() amu_run(cmd) end)
    love.thread.getChannel("amu_crash_revert"):push(ok and "done" or "error")
  ]]
  love.thread.newThread(thread_code):start(cmd)

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true,   -- survive the event-queue wipe when a run starts
    func = function()
      if not channel:pop() then return false end
      AMU_CRASH.busy = false
      AMU_CRASH.finish()
      return true
    end
  }))
end

-- "Keep all": nothing is changed, but the mods stay suspects until the game has started fine once.
function AMU_CRASH.keep_all()
  if AMU_CRASH.busy then return end
  AMU_CRASH.load()
  local mods = AMU_CRASH.mods
  AMU_CRASH.rearm(mods)
  pcall(os.remove, AMU_CRASH.path("_crash_pending.json"))
  pcall(os.remove, AMU_CRASH.path("_crash_selection.json"))
  AMU_CRASH.mods, AMU_CRASH.sel = {}, {}
  AMU_CRASH.show_lines("Mod Updater - Crash Recovery", {
    "Keeping all " .. #mods .. " updated mod(s) as they are.",
    "",
    "If the game crashes again at start, you are asked again. You can also close the game and run 'Undo last update.bat' in the Mod Updater folder.",
  }, false)
end

G.FUNCS.amu_crash_revert_all = function(e) AMU_CRASH.run_revert(AMU_CRASH.all_names()) end
G.FUNCS.amu_crash_pick_revert_all = function(e) AMU_CRASH.run_revert(AMU_CRASH.all_names()) end
G.FUNCS.amu_crash_revert_selected = function(e) AMU_CRASH.run_revert(AMU_CRASH.ticked()) end
G.FUNCS.amu_crash_keep_all = function(e) AMU_CRASH.keep_all() end

G.FUNCS.amu_crash_choose = function(e)
  if AMU_CRASH.busy then return end
  open_overlay(G.UIDEF.amu_crash_picker())
end

-- Back from the picker: back to the question
G.FUNCS.amu_crash_pick_back = function(e)
  if AMU_CRASH.busy then return end
  open_overlay(G.UIDEF.amu_crash_prompt())
end

-- Not now: nothing changes; the question comes back the next time the game starts.
G.FUNCS.amu_crash_later = function(e)
  if AMU_CRASH.busy then return end
  AMU_CRASH.answered = true   -- asked again the next time the game starts
  amu_close_everything()
end

-- Button in the Mod Updater settings: bring the question back (after a "Not now").
G.FUNCS.amu_crash_review = function(e)
  if AMU_CRASH.load() == 0 then return end
  AMU_CRASH.shown = true
  AMU_CRASH.answered = false
  if open_overlay(G.UIDEF.amu_crash_prompt()) then AMU_CRASH.start_poller() end
end

-- Is the main menu showing, with nothing on top of it?
function AMU_CRASH.menu_idle()
  if not (G and G.STAGES and G.STAGE == G.STAGES.MAIN_MENU) or G.OVERLAY_MENU then return false end
  return (G.MAIN_MENU_UI or (G.STATES and G.STATE == G.STATES.MENU)) and true or false
end

-- A short note for troubleshooting when the question has been waiting a long time (written at most twice).
function AMU_CRASH.note_wait(secs)
  pcall(function()
    local f = io.open(AMU_CRASH.path("_crash_poller.log"), "ab")
    if not f then return end
    f:write(string.format("%s waiting %ds: STAGE=%s STATE=%s MAIN_MENU_UI=%s OVERLAY=%s in_flight=%s answered=%s busy=%s\n",
      os.date("%Y-%m-%d %H:%M:%S"), secs, tostring(G.STAGE), tostring(G.STATE), tostring(G.MAIN_MENU_UI ~= nil),
      tostring(G.OVERLAY_MENU ~= nil and G.OVERLAY_MENU ~= false), tostring(AMU_CRASH.in_flight),
      tostring(AMU_CRASH.answered), tostring(AMU_CRASH.busy)))
    f:close()
  end)
end

-- Is the question (or the picker) the open menu?
function AMU_CRASH.prompt_on_screen()
  local om = G and G.OVERLAY_MENU
  if not (om and om.get_UIE_by_ID) then return false end
  local ok, n = pcall(om.get_UIE_by_ID, om, "amu_crash_marker")
  return (ok and n) and true or false
end

function AMU_CRASH.has_work()
  return #AMU_CRASH.read_pending() > 0 or file_exists(AMU_CRASH.path("_crash_rollback_report.json"))
end

-- On a controller, the cursor must start on the question, not on something behind it on the main menu.
-- Returns true when it had to move the cursor.
function AMU_CRASH.ensure_focus(ctrl)
  ctrl = ctrl or (G and G.CONTROLLER)
  if not (ctrl and ctrl.HID and ctrl.HID.controller and ctrl.snap_to) then return false end
  local om = G.OVERLAY_MENU
  if not (om and AMU_CRASH.prompt_on_screen()) then return false end
  local t = ctrl.focused and ctrl.focused.target
  if t and t.UIBox == om then return false end
  -- the picker's check boxes are in their own box inside the menu: that counts as inside too
  local par = t and t.UIBox and t.UIBox.config and t.UIBox.config.parent
  if par and par.UIBox == om then return false end
  local n = amu_find_node(function(c) return c.button == "amu_crash_revert_all" end)
         or amu_find_node(function(c) return c.button == "amu_crash_revert_selected" end)
  if not n then return false end
  ctrl:snap_to({ node = n })
  if ctrl.update_cursor then ctrl:update_cursor() end
  return true
end

-- Watches over the question until it is answered:
--   * waits for the main menu (with nothing on top of it) before asking, and for any running update check
--   * keeps the controller cursor on the question
--   * if the question vanished before the player could see it (the game rebuilt the menu), asks again
--   * if it was on screen and then closed (Not now, B, Esc), that was the answer for this session
function AMU_CRASH.start_poller()
  if AMU_CRASH.polling or not (G and G.E_MANAGER and Event) then return end
  AMU_CRASH.polling = true
  local since, opened_at, seen = nil, nil, false
  local started, noted = amu_now(), 0
  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true,   -- survive the event-queue wipe when a run starts
    func = function()
      local now = amu_now()
      if AMU_CRASH.prompt_on_screen() then
        opened_at = opened_at or now
        if now - opened_at >= 1.0 then seen = true end
        pcall(AMU_CRASH.ensure_focus)
        return false
      end
      opened_at = nil
      if AMU_CRASH.busy then return false end     -- a put-back is running; its result window comes next
      if seen then
        seen = false
        if #AMU_CRASH.read_pending() > 0 then AMU_CRASH.answered = true end
      end
      local crash_done = not AMU_CRASH.has_work()
        or (AMU_CRASH.answered and not file_exists(AMU_CRASH.path("_crash_rollback_report.json")))
      if crash_done then
        if not AMU_CRASH.later_summary then
          AMU_CRASH.polling = false
          return true
        end
        -- the update check finished while the crash question was up: show its results now, on the main menu
        if not AMU_CRASH.menu_idle() then since = nil; return false end
        since = since or now
        if (now - since) < 0.5 then return false end
        local sm = AMU_CRASH.later_summary
        AMU_CRASH.later_summary = nil
        pcall(show_prompt, sm)
        AMU_CRASH.polling = false
        return true
      end
      if noted < 2 and (now - started) > (noted == 0 and 30 or 120) then
        noted = noted + 1
        AMU_CRASH.note_wait(math.floor(now - started))
      end
      if not AMU_CRASH.menu_idle() then since = nil; return false end
      since = since or now
      if (now - since) < 1.5 then return false end   -- let the menu finish sliding in
      since = nil
      pcall(AMU_CRASH.startup_check, nil)
      return false
    end
  }))
end

-- Put the question (or the result of a put-back made while the game was closed) on screen, if there is one.
-- Only on the main menu with nothing on top of it; otherwise the watcher above asks as soon as it is.
-- Returns true when something was shown.
function AMU_CRASH.startup_check(summary)
  if summary then
    local n = #(summary.updated_mods or {})
    AMU_CRASH.extra_note = (n > 0) and ("Also updated " .. n .. " other mod(s) just now.") or nil
  end
  if AMU_CRASH.busy then return false end
  if not AMU_CRASH.menu_idle() then
    if AMU_CRASH.has_work() then AMU_CRASH.start_poller() end
    return false
  end
  local reverted, failed, kept = AMU_CRASH.process_report()
  if #reverted > 0 or #failed > 0 then
    AMU_CRASH.show_result(reverted, failed, kept, false)
    return true
  end
  if AMU_CRASH.answered then return false end
  if AMU_CRASH.load() == 0 then return false end
  AMU_CRASH.shown = true
  local ok = open_overlay(G.UIDEF.amu_crash_prompt()) and true or false
  if ok then AMU_CRASH.start_poller() end
  return ok
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
-- Shows what a put-back did, or asks about a startup crash, or shows the usual update results.
on_full_update_done = function(mod_path)
  pcall(AMU_CRASH.adopt_pin_releases)
  AMU_CRASH.in_flight = false
  local summary = read_summary(mod_path)
  pcall(AMU_GAME.reconcile, summary)
  pcall(AMU_GAME.sync_status)
  -- the crash question (or its result) is on screen or still to come: show the update results after it
  if AMU_CRASH.polling or AMU_CRASH.busy or AMU_CRASH.prompt_on_screen() then
    AMU_CRASH.later_summary = summary
    AMU_CRASH.start_poller()
    return
  end
  if AMU_CRASH.startup_check(summary) then return end
  if summary then show_prompt(summary) end
end

-- Something is waiting (a startup crash to ask about, or a put-back made while the game was closed): watch for the
-- main menu and ask there. Works the same with "Auto-check at startup" on or off.
if is_windows() and G and G.E_MANAGER and Event then
  pcall(function() if AMU_CRASH.has_work() then AMU_CRASH.start_poller() end end)
end

---------------------------------------------------------------------------
-- "Shuffling mods..." placement on the main menu
-- The line sits between the Balatro logo and the main menu buttons. While it's
-- showing, the main menu bar (with the language box) and the Profile button
-- slide down a little to make room, then slide back when the check is done.
---------------------------------------------------------------------------
local AMU_LOADING = { box = nil, shift = 0, waiting = false, owners = {}, active = false, menu = nil, deferred = nil, retry_at = 0 }
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

-- One overlay, any number of runs that want it (the startup check, the manual "Check for updates now" button). It is shown while
-- at least one run is going and removed when the last one ends, and the "Checking..." line under the button follows the same rule.
-- One watcher event rebuilds the overlay if the game removed it meanwhile (a rebuilt main menu does that).
local function amu_show_loading(ref, owner)
  AMU_LOADING.owners[owner or "startup"] = true
  AMU_LOADING.waiting = true
  AMU_LOADING.ref = ref or AMU_LOADING.ref or {}
  amu_check_status.text = "Checking..."
  if AMU_LOADING.active then return end
  AMU_LOADING.active = true
  G.E_MANAGER:add_event(Event({
    blockable = false, blocking = false, no_delete = true,
    func = function()
      if not AMU_LOADING.waiting then AMU_LOADING.active = false; return true end
      local box = AMU_LOADING.box
      if box and box.REMOVED then AMU_LOADING.box = nil; box = nil end
      if not box then
        if config.show_loading_overlay == false then return false end
        -- wait until the main menu has slid in (it appears a few seconds after start-up)
        if not (G.MAIN_MENU_UI and G.ROOM_ATTACH and G.STAGE == G.STAGES.MAIN_MENU) then return false end
        local now = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
        if now < (AMU_LOADING.retry_at or 0) then return false end
        -- a menu that was rebuilt starts without our shift
        if AMU_LOADING.menu ~= G.MAIN_MENU_UI then AMU_LOADING.shift = 0; AMU_LOADING.profile_shifted = false end
        local ok = pcall(function()
          AMU_LOADING.box = UIBox{
            definition = G.UIDEF.amu_loading_box(AMU_LOADING.ref),
            config = { align = "bmi", offset = { x = 0, y = 0 }, major = G.ROOM_ATTACH, bond = "Weak" }
          }
        end)
        if not ok then AMU_LOADING.box = nil; AMU_LOADING.retry_at = now + 2; return false end
        if AMU_LOADING.shift == 0 then
          amu_shift_menus(AMU_MENU_SHIFT)
          AMU_LOADING.shift = AMU_MENU_SHIFT
        end
        AMU_LOADING.menu = G.MAIN_MENU_UI
        amu_place_loading()
        return false
      end
      -- keep the text glued above the menu while it settles (Profile button arrives a frame later)
      if G.PROFILE_BUTTON and not AMU_LOADING.profile_shifted and AMU_LOADING.shift ~= 0 then
        -- Profile button is created one frame after the menu; give it the same shift
        if (G.PROFILE_BUTTON.alignment.offset.y or 0) < AMU_LOADING.shift then
          G.PROFILE_BUTTON.alignment.offset.y = (G.PROFILE_BUTTON.alignment.offset.y or 0) + AMU_LOADING.shift
          pcall(function() G.PROFILE_BUTTON:align_to_major() end)
        end
        AMU_LOADING.profile_shifted = true
      end
      amu_place_loading()
      return false
    end
  }))
end

-- `final_text` (optional) is what the line under the button says once the LAST run has ended.
local function amu_hide_loading(owner, final_text)
  AMU_LOADING.owners[owner or "startup"] = nil
  if next(AMU_LOADING.owners) ~= nil then
    -- another check is still running: the animation and the Checking... line stay; the result waits
    if final_text then AMU_LOADING.deferred = final_text end
    return
  end
  AMU_LOADING.waiting = false
  local txt = final_text or AMU_LOADING.deferred
  AMU_LOADING.deferred = nil
  if txt then
    amu_check_status.text = txt
  elseif tostring(amu_check_status.text or "") == "Checking..." then
    amu_check_status.text = ""
  end
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

-- Lets the manual "Check for updates now" (defined much earlier) show the same "Shuffling mods..." line on the main menu.
AMU_LOADING_API = {
  show = amu_show_loading,
  hide = amu_hide_loading,
  is_waiting = function() return next(AMU_LOADING.owners) ~= nil end,
  state = AMU_LOADING,
}

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
    AMU_RUN(cmd, true)
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
    AMU_RUN(cmd)
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

  local thread_code = AMU_HIDE_SRC .. [[
    local cmd, logpath, t0 = ...
    local ok = pcall(function() amu_run(cmd) end)
    -- when PowerShell actually exited (compare with the "done" line the game writes a moment later)
    pcall(function()
      local f = io.open(logpath, "ab")
      if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  powershell exited  " .. tostring(os.time() - t0) .. "s\r\n")
        f:close()
      end
    end)
    local ch = love.thread.getChannel("amu_update_status")
    ch:push(ok and "done" or "error")
  ]]
  local t = love.thread.newThread(thread_code)
  t:start(cmd, join_path(mod_path, "update_timing.log"), os.time())

  amu_show_loading(ref, "startup")   -- also sets the Checking... line; the overlay itself only shows when the setting allows it

  AMU_CRASH.in_flight = true   -- the startup-crash question (if any) waits for this run

  local start_time = love.timer and love.timer.getTime and love.timer.getTime() or 0
  local start_os = os.time()
  local dots = 0
  -- how long each run takes, so a slow one can be traced (update_timing.log in the mod folder)
  local function amu_log_time(tag)
    pcall(function()
      local f = io.open(join_path(mod_path, "update_timing.log"), "ab")
      if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tag .. "  " ..
          string.format("%.0f", (love.timer.getTime() - start_time)) .. "s\r\n")
        f:close()
      end
    end)
  end

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    no_delete = true, -- survive the event-queue wipe when you start a run mid-check
    func = function()

      local msg = channel:pop()
      if msg then
        amu_log_time("done")
        amu_hide_loading()
        on_full_update_done(mod_path)
        return true
      end

      if love.timer and love.timer.getTime and (love.timer.getTime() - start_time) > (tonumber(config.ui_timeout_seconds) or 300) then
        -- The check may simply have finished a moment late: if last_run.json was written after this run started, use it
        -- like a normal finish instead of warning.
        local finished = false
        pcall(function()
          local info = love.filesystem.getInfo("Mods/" .. tostring(mod_path):match("([^/\\]+)[/\\]*$") .. "/last_run.json")
          if info and info.modtime and info.modtime >= start_os - 2 then finished = true end
        end)
        if finished then
          amu_log_time("done (late)")
          amu_hide_loading()
          on_full_update_done(mod_path)
          return true
        end
        amu_log_time("TIMED OUT")
        amu_hide_loading()
        AMU_CRASH.in_flight = false
        show_msg("Mod Updater", "Updater timed out waiting for PowerShell.\nYou can still play.", {"OK"}, "warning")
        pcall(AMU_CRASH.startup_check, nil)
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
