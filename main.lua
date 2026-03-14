-- Auto Mod Updater (Steamodded) v0.6.6
-- In-game config with two tabs: Settings (general + Nexus key + check now) and Mod Toggles (paginated).
-- Uses Steamodded's DynamicUIManager for proper pagination.
-- Git pull mode: rebase (default and recommended).

local mod = SMODS.current_mod
local config = mod and mod.config or {}

SMODS.Atlas {
  key = 'modicon',
  path = 'modicon.png',
  px = 34,
  py = 34,
}

-- Derive the actual folder name of this mod dynamically so it works
-- regardless of what the user names the mod folder (e.g. after cloning the repo).
local mod_folder_name = "AutoModUpdater"
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

G.UIDEF = G.UIDEF or {}
G.FUNCS = G.FUNCS or {}

---------------------------------------------------------------------------
-- SCAN MODS DIRECTORY
---------------------------------------------------------------------------

local always_skip = {
  ["smods"] = true,
  [mod_folder_name] = true,
  ["_Balatro-Automatic-Mod-Updater_Backups"] = true,
}

-- Subset of always_skip that should appear in skip_folders in the generated config.
-- The updater's own folder is excluded so it can self-update via git/GitHub releases.
local config_always_skip = {
  ["smods"] = true,
  ["_Balatro-Automatic-Mod-Updater_Backups"] = true,
}

-- Legacy folder names from older versions that should never appear in the
-- generated autoupdater_config.json skip_folders list.  They may still be
-- present in SMODS-persisted config.skip_folders from a previous release.
local legacy_skip_deny = {
  ["AutoModUpdater"] = true,
  ["_AutoModUpdater_Backups"] = true,
}

local function scan_mods_and_init_config()
  if not config.mod_update_enabled then
    config.mod_update_enabled = {}
  end
  if not config.mod_pinned then
    config.mod_pinned = {}
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

local function write_ps1_config_overlay()
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or ""
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
  }

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
-- CHECK FOR UPDATES NOW (manual trigger)
---------------------------------------------------------------------------

local amu_check_status = { text = "" }
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
          show_prompt(summary)
        else
          amu_check_status.text = msg == "done" and "Done!" or "Error running script."
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

local MODS_PER_PAGE = 8
local AMU_CONFIG_PAGE = 1

-- Backup browser state (forward-declared; build_backup_mods_page defined after open_overlay)
local AMU_BACKUP_PAGE = 1
local amu_backup_status = { text = "" }
local amu_restore_in_progress = false
local build_backup_mods_page  -- forward declaration; assigned after close_overlay is defined

local function get_display_name(folder_name)
  local display = folder_name
  if SMODS and SMODS.Mods then
    for _, m in pairs(SMODS.Mods) do
      if m.path then
        local escaped = folder_name:gsub("%-", "%%-")
        if m.path:match("[/\\]" .. escaped .. "[/\\]?$") or m.path:match("[/\\]" .. escaped .. "$") then
          display = m.name or m.display_name or folder_name
          break
        end
      end
    end
  end
  if #display > 32 then display = display:sub(1, 29) .. "..." end
  return display
end

local function get_sorted_mod_entries()
  local entries = {}
  if config.mod_update_enabled then
    for folder_name, _ in pairs(config.mod_update_enabled) do
      entries[#entries+1] = {
        folder = folder_name,
        display = get_display_name(folder_name),
      }
    end
  end
  table.sort(entries, function(a, b) return a.display:lower() < b.display:lower() end)
  return entries
end

-- Builds the dynamic mod-toggle list content for a given page
local function build_mod_toggles_page(page)
  local entries = get_sorted_mod_entries()
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
      rows[#rows+1] = {
        n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
          create_toggle {
            label = entry.display,
            ref_table = config.mod_update_enabled,
            ref_value = entry.folder,
            w = 0,
            scale = 0.7,
            callback = function()
              write_ps1_config_overlay()
            end
          },
        }
      }
    end
  end

  -- Pad with empty rows to keep height consistent
  local shown = end_i - start_i + 1
  for _ = shown + 1, MODS_PER_PAGE do
    rows[#rows+1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      { n = G.UIT.B, config = { h = 0.38, w = 4 } }
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", colour = G.C.CLEAR, padding = 0.02 },
    nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = rows }
    }
  }
end

-- Callback for the mod toggles page cycle
G.FUNCS.amu_mod_toggles_page = function(args)
  if not args or not args.cycle_config then return end
  local page = args.cycle_config.current_option or 1
  AMU_CONFIG_PAGE = page
  SMODS.GUI.DynamicUIManager.updateDynamicAreas({
    ["amu_mod_toggle_list"] = build_mod_toggles_page(page)
  })
end

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
  SMODS.GUI.DynamicUIManager.updateDynamicAreas({
    ["amu_backup_mod_list"] = build_backup_mods_page(page)
  })
end

---------------------------------------------------------------------------
-- BACKUP BROWSER: helper functions
---------------------------------------------------------------------------

-- Return a sorted list (newest first) of backup zip files for a given mod folder.
local function list_backups_for_mod(folder_name)
  local backups = {}
  local items = love.filesystem.getDirectoryItems("Mods/_Balatro-Automatic-Mod-Updater_Backups")
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
          amu_restore_in_progress = false
          amu_backup_status.text = folder_name ..
            (msg == "done" and " restored. Restart to apply." or " restore error. See last_run.json.")
          return true
        end
        return false
      end
    }))
  else
    os.execute(cmd)
    amu_restore_in_progress = false
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

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.05, colour = G.C.BLACK, r = 0.1, emboss = 0.05, minh = 6, minw = 6 },
    nodes = {
      -- General settings header
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.T, config = { text = "General Settings", scale = 0.45, colour = purple, shadow = true } }
      }},
      -- Toggles
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        create_toggle { label = "Update Git repos", ref_table = config, ref_value = "cfg_update_git", w = 0, scale = 0.75,
          callback = function() write_ps1_config_overlay() end },
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        create_toggle { label = "Update via update.json", ref_table = config, ref_value = "cfg_update_updatejson", w = 0, scale = 0.75,
          callback = function() write_ps1_config_overlay() end },
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        create_toggle { label = "Make backups", ref_table = config, ref_value = "cfg_make_backups", w = 0, scale = 0.75,
          callback = function() write_ps1_config_overlay() end },
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        create_toggle { label = "Update Steamodded", ref_table = config, ref_value = "cfg_update_steamodded", w = 0, scale = 0.75,
          callback = function() write_ps1_config_overlay() end },
      }},
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        create_toggle { label = "Update Lovely Injector", ref_table = config, ref_value = "cfg_update_lovely", w = 0, scale = 0.75,
          callback = function() write_ps1_config_overlay() end },
      }},
      -- Divider
      { n = G.UIT.B, config = { h = 0.08, w = 0.1 } },
      -- Nexus API Key section
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.T, config = { text = "Nexus API Key", scale = 0.4, colour = purple, shadow = true } }
      }},
      -- Key status display
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 5.0, minh = 0.45, r = 0.1, colour = panel }, nodes = {
          { n = G.UIT.T, config = { ref_table = amu_nexus_display, ref_value = "text", scale = 0.35, colour = G.C.UI.TEXT_LIGHT } }
        }}
      }},
      -- Paste + Clear buttons row
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 2.6, minh = 0.55, r = 0.1, colour = G.C.BLUE, button = "amu_paste_nexus_key", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Paste from clipboard", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.B, config = { h = 0.1, w = 0.15 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.06, minw = 1.4, minh = 0.55, r = 0.1, colour = G.C.RED, button = "amu_clear_nexus_key", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Clear", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } }
        }},
      }},
      -- Divider
      { n = G.UIT.B, config = { h = 0.08, w = 0.1 } },
      -- Check for updates now
      { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
        { n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 3.8, minh = 0.7, r = 0.12, colour = G.C.GREEN, button = "amu_check_updates_now", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Check for updates now", scale = 0.4, colour = purple } }
        }},
      }},
      -- Status text
      { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { ref_table = amu_check_status, ref_value = "text", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
      }},
    }
  }
end

---------------------------------------------------------------------------
-- EXTRA TAB: Mod Toggles (paginated, 8 per page)
-- Note: SMODS.GUI.DynamicUIManager.initTab wraps staticPageDefinition
-- inside a ROOT node with minh=6, minw=8, align="cm".
-- updateDynamicAreas creates UIBox with offset y=0.5, so we account for that.
---------------------------------------------------------------------------

SMODS.current_mod.extra_tabs = function()
  return {
    {
      label = "Mod Toggles",
      tab_definition_function = function()
        local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)

        local entries = get_sorted_mod_entries()
        local total_pages = math.max(1, math.ceil(#entries / MODS_PER_PAGE))
        if AMU_CONFIG_PAGE > total_pages then AMU_CONFIG_PAGE = total_pages end
        if AMU_CONFIG_PAGE < 1 then AMU_CONFIG_PAGE = 1 end

        local page_options = {}
        for p = 1, total_pages do
          page_options[p] = "Page " .. p .. "/" .. total_pages
        end

        local static_def = {
          n = G.UIT.R,
          config = { align = "cm", padding = 0.05 },
          nodes = {
            { n = G.UIT.C, config = { align = "tm", padding = 0.05, minw = 6 }, nodes = {
              -- Header
              { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
                { n = G.UIT.T, config = { text = "Mod Update Toggles", scale = 0.5, colour = purple, shadow = true } }
              }},
              -- Dynamic placeholder for mod toggles
              { n = G.UIT.R, config = { align = "cm", padding = 0.2, minh = 4.5, minw = 5.5 }, nodes = {
                { n = G.UIT.O, config = { align = "cm", id = "amu_mod_toggle_list", object = Moveable() } },
              }},
              -- Spacer to push page selector below the toggles
              { n = G.UIT.B, config = { h = 1.5, w = 0.1 } },
              -- Page selector
              (total_pages > 1) and {
                n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
                  create_option_cycle {
                    w = 4.5,
                    scale = 0.7,
                    label = "",
                    options = page_options,
                    current_option = AMU_CONFIG_PAGE,
                    opt_callback = "amu_mod_toggles_page",
                    cycle_shoulders = true,
                    no_pips = true,
                  }
                }
              } or nil,
            }}
          }
        }

        return SMODS.GUI.DynamicUIManager.initTab({
          updateFunctions = {
            amu_mod_toggle_list = function(args)
              local page = (args and args.cycle_config and args.cycle_config.current_option) or AMU_CONFIG_PAGE or 1
              SMODS.GUI.DynamicUIManager.updateDynamicAreas({
                ["amu_mod_toggle_list"] = build_mod_toggles_page(page)
              })
            end,
          },
          staticPageDefinition = static_def,
        })
      end
    },
    {
      label = "Backups",
      tab_definition_function = function()
        local purple = (G.C and G.C.PURPLE) or RGBA(0.62, 0.33, 0.92, 1)

        local entries = get_sorted_mod_entries()
        local total_pages = math.max(1, math.ceil(#entries / MODS_PER_PAGE))
        if AMU_BACKUP_PAGE > total_pages then AMU_BACKUP_PAGE = total_pages end
        if AMU_BACKUP_PAGE < 1 then AMU_BACKUP_PAGE = 1 end

        local page_options = {}
        for p = 1, total_pages do
          page_options[p] = "Page " .. p .. "/" .. total_pages
        end

        local static_def = {
          n = G.UIT.R,
          config = { align = "cm", padding = 0.05 },
          nodes = {
            { n = G.UIT.C, config = { align = "tm", padding = 0.05, minw = 6 }, nodes = {
              -- Header
              { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
                { n = G.UIT.T, config = { text = "Mod Backups & Pinning", scale = 0.5, colour = purple, shadow = true } }
              }},
              -- Dynamic placeholder for backup mod list
              { n = G.UIT.R, config = { align = "cm", padding = 0.2, minh = 4.5, minw = 5.5 }, nodes = {
                { n = G.UIT.O, config = { align = "cm", id = "amu_backup_mod_list", object = Moveable() } },
              }},
              -- Status line
              { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
                { n = G.UIT.T, config = { ref_table = amu_backup_status, ref_value = "text", scale = 0.3, colour = purple } }
              }},
              -- Spacer
              { n = G.UIT.B, config = { h = 0.8, w = 0.1 } },
              -- Page selector
              (total_pages > 1) and {
                n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
                  create_option_cycle {
                    w = 4.5,
                    scale = 0.7,
                    label = "",
                    options = page_options,
                    current_option = AMU_BACKUP_PAGE,
                    opt_callback = "amu_backup_mods_page",
                    cycle_shoulders = true,
                    no_pips = true,
                  }
                }
              } or nil,
            }}
          }
        }

        return SMODS.GUI.DynamicUIManager.initTab({
          updateFunctions = {
            amu_backup_mod_list = function(args)
              local page = (args and args.cycle_config and args.cycle_config.current_option) or AMU_BACKUP_PAGE or 1
              SMODS.GUI.DynamicUIManager.updateDynamicAreas({
                ["amu_backup_mod_list"] = build_backup_mods_page(page)
              })
            end,
          },
          staticPageDefinition = static_def,
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
  ref = ref or { text = "Shuffling mods...", suits = "♠  ♥  ♦  ♣" }

  local purple = (G.C and (G.C.PURPLE or (G.C.UI and G.C.UI.PURPLE))) or RGBA(0.62, 0.33, 0.92, 1)
  local clear  = (G.C and (G.C.CLEAR or (G.C.UI and G.C.UI.TRANSPARENT_LIGHT))) or RGBA(0,0,0,0)

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.0, r = 0, colour = clear },
    nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.02, colour = clear }, nodes = {
        { n = G.UIT.T, config = { ref_table = ref, ref_value = "text", scale = 0.72, colour = purple, shadow = true } },
        { n = G.UIT.B, config = { h = 0.15, w = 0.1 } },
        { n = G.UIT.T, config = { ref_table = ref, ref_value = "suits", scale = 0.7, colour = purple, shadow = true } },
      }}
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
      pcall(SMODS.GUI.DynamicUIManager.updateDynamicAreas, {
        ["amu_backup_mod_list"] = build_backup_mods_page(AMU_BACKUP_PAGE)
      })
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
        { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 2.5, minh = 0.7, r = 0.12,
          colour = panel, button = "amu_close_prompt", hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Close", scale = 0.42, colour = purple } }
        }},
      }},
    }
  }
end

-- Paginated list of all mods with their pin state and backup/unpin buttons.
-- NOTE: this is assigned to the forward-declared local 'build_backup_mods_page'.
build_backup_mods_page = function(page)
  local entries = get_sorted_mod_entries()
  local total_pages = math.max(1, math.ceil(#entries / MODS_PER_PAGE))
  page = math.max(1, math.min(page or 1, total_pages))
  AMU_BACKUP_PAGE = page

  local rows = {}
  local start_i = (page - 1) * MODS_PER_PAGE + 1
  local end_i   = math.min(#entries, page * MODS_PER_PAGE)

  for i = start_i, end_i do
    local entry = entries[i]
    if entry then
      local row_i     = i - start_i + 1
      local folder    = entry.folder
      local display   = entry.display
      local pin_info  = config.mod_pinned and config.mod_pinned[folder]
      local is_pinned = type(pin_info) == "table" and pin_info.pinned == true

      -- Register per-row button handlers (overwritten each page rebuild)
      G.FUNCS["amu_open_backups_" .. row_i] = function(e)
        local backups = list_backups_for_mod(folder)
        open_overlay(G.UIDEF.amu_backup_picker({ folder = folder, display = display, backups = backups }))
      end

      G.FUNCS["amu_unpin_mod_" .. row_i] = function(e)
        unpin_mod(folder)
        SMODS.GUI.DynamicUIManager.updateDynamicAreas({
          ["amu_backup_mod_list"] = build_backup_mods_page(AMU_BACKUP_PAGE)
        })
      end

      -- Build the row node list
      local pin_badge
      if is_pinned then
        pin_badge = {
          n = G.UIT.C, config = { align = "cm", padding = 0.03, minw = 0.95, minh = 0.32,
            r = 0.08, colour = RGBA(0.7, 0.45, 0.0, 0.95) }, nodes = {
            { n = G.UIT.T, config = { text = "PINNED", scale = 0.25, colour = RGBA(1,1,1,1) } }
          }
        }
      else
        pin_badge = { n = G.UIT.B, config = { h = 0.1, w = 0.95 } }
      end

      local row_nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.02, minw = 2.3 }, nodes = {
          { n = G.UIT.T, config = { text = display, scale = 0.34, colour = G.C.UI.TEXT_LIGHT } }
        }},
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        pin_badge,
        { n = G.UIT.B, config = { h = 0.1, w = 0.1 } },
        { n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 1.1, minh = 0.38, r = 0.09,
          colour = G.C.BLUE, button = "amu_open_backups_" .. row_i, hover = true, shadow = true }, nodes = {
          { n = G.UIT.T, config = { text = "Backups", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
        }},
      }

      if is_pinned then
        row_nodes[#row_nodes + 1] = { n = G.UIT.B, config = { h = 0.1, w = 0.1 } }
        row_nodes[#row_nodes + 1] = {
          n = G.UIT.C, config = { align = "cm", padding = 0.04, minw = 0.9, minh = 0.38, r = 0.09,
            colour = G.C.RED, button = "amu_unpin_mod_" .. row_i, hover = true, shadow = true }, nodes = {
            { n = G.UIT.T, config = { text = "Unpin", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
          }
        }
      end

      rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = row_nodes }
    end
  end

  -- Pad remaining rows to keep height consistent
  local shown = end_i - start_i + 1
  for _ = shown + 1, MODS_PER_PAGE do
    rows[#rows + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      { n = G.UIT.B, config = { h = 0.38, w = 5.5 } }
    }}
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", colour = G.C.CLEAR, padding = 0.02 },
    nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0 }, nodes = rows }
    }
  }
end

local AMU_PROMPT = { title = "Auto Mod Updater", lines = {}, has_updates = false }

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

  if #skipped > 0 and #updated == 0 then
    table.insert(lines, "Skipped (" .. tostring(#skipped) .. "):")
    for i = 1, math.min(#skipped, 20) do table.insert(lines, "    " .. tostring(skipped[i])) end
    if #skipped > 20 then table.insert(lines, "    ...") end
  end

  if #lines == 0 then table.insert(lines, "No mod updates were applied.") end
  return wrap_lines(lines, 46)
end

function show_prompt(summary)
  local updated = summary and summary.updated_mods or {}
  local errors = summary and summary.errors or {}
  local should = (#updated > 0) or ((config.prompt_on_errors ~= false) and (#errors > 0))
  if not should then return end

  AMU_PROMPT.title = "Auto Mod Updater"
  AMU_PROMPT.lines = build_prompt_lines(summary)
  AMU_PROMPT.has_updates = (#updated > 0)

  open_overlay(G.UIDEF.amu_restart_prompt(AMU_PROMPT))
end

G.UIDEF.amu_restart_prompt = function(ref)
  local purple = (G.C and (G.C.PURPLE or (G.C.UI and G.C.UI.PURPLE))) or RGBA(0.62, 0.33, 0.92, 1)
  local bg    = RGBA(0.08, 0.08, 0.08, 0.96)
  local panel = RGBA(0.12, 0.12, 0.12, 0.96)

  local max_show = 40
  local show_n = math.min(#ref.lines, max_show)

  local max_len = 0
  for i = 1, show_n do
    local s = tostring(ref.lines[i] or "")
    if #s > max_len then max_len = #s end
  end
  if #ref.lines > max_show then
    local s = "(more in " .. mod_folder_name .. "/last_run.json)"
    if #s > max_len then max_len = #s end
  end

  local w = math.min(15.5, math.max(10.0, 6.4 + max_len * 0.11))
  local line_h = 0.34
  local content_h = math.min(8.8, math.max(1.9, show_n * line_h + 0.45))
  local h = math.min(11.5, math.max(5.6, content_h + 2.7))

  local text_rows = {}
  for i = 1, show_n do
    text_rows[#text_rows+1] = {
      n = G.UIT.R,
      config = { align = "cl", padding = 0.01 },
      nodes = {
        { n = G.UIT.T, config = { text = tostring(ref.lines[i]), scale = 0.45, colour = purple } }
      }
    }
  end
  if #ref.lines > max_show then
    text_rows[#text_rows+1] = {
      n = G.UIT.R,
      config = { align = "cl", padding = 0.01 },
      nodes = {
        { n = G.UIT.T, config = { text = "(more in " .. mod_folder_name .. "/last_run.json)", scale = 0.41, colour = purple } }
      }
    }
  end

  local buttons_row = { n = G.UIT.R, config = { align = "cm", padding = 0.12 }, nodes = {} }
  if ref.has_updates and (config.prompt_restart ~= false) then
    buttons_row.nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 4.0, minh = 0.9, r = 0.15, colour = G.C.GREEN, button = "amu_restart_now" }, nodes = {
        { n = G.UIT.T, config = { text = "Restart now", scale = 0.55, colour = purple } }
      }},
      { n = G.UIT.B, config = { h = 0.1, w = 0.35 } },
      { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 3.0, minh = 0.9, r = 0.15, colour = panel, button = "amu_close_prompt" }, nodes = {
        { n = G.UIT.T, config = { text = "Later", scale = 0.55, colour = purple } }
      }},
    }
  else
    buttons_row.nodes = {
      { n = G.UIT.C, config = { align = "cm", padding = 0.1, minw = 3.5, minh = 0.9, r = 0.15, colour = panel, button = "amu_close_prompt" }, nodes = {
        { n = G.UIT.T, config = { text = "OK", scale = 0.55, colour = purple } }
      }},
    }
  end

  return {
    n = G.UIT.ROOT,
    config = { align = "cm", minw = w, minh = h, padding = 0.24, r = 0.2, colour = bg, shadow = true, hover = true },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.08 }, nodes = {
        { n = G.UIT.T, config = { text = ref.title or "Auto Mod Updater", scale = 0.72, colour = purple, shadow = true } }
      }},
      { n = G.UIT.B, config = { h = 0.18, w = 0.1 } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.10 }, nodes = {
        { n = G.UIT.C, config = { align = "cl", padding = 0.10, minw = w - 1.0, minh = content_h, r = 0.16, colour = panel }, nodes = text_rows }
      }},
      { n = G.UIT.B, config = { h = 0.18, w = 0.1 } },
      buttons_row
    }
  }
end

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

local function run_update_async(mods_dir, mod_path)
  pcall(write_ps1_config_overlay)

  local ps1 = join_path(mod_path, "autoupdate.ps1")
  if not file_exists(ps1) then
    show_msg("Auto Mod Updater", "Missing autoupdate.ps1 in:\n" .. tostring(mod_path), {"OK"}, "error")
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
    local summary = read_summary(mod_path)
    if summary then show_prompt(summary) end
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
    local align = config.loading_align or "tm"
    local off = config.loading_offset or {x = 0, y = 2.2}
    open_overlay(G.UIDEF.amu_loading_box(ref), { no_esc = true, align = align, offset = off })
  end

  local start_time = love.timer and love.timer.getTime and love.timer.getTime() or 0
  local dots = 0

  G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    func = function()
      dots = (dots + 1) % 30
      ref.text = "Shuffling mods" .. string.rep(".", math.floor(dots / 10))

      local msg = channel:pop()
      if msg then
        close_overlay()
        local summary = read_summary(mod_path)
        if summary then show_prompt(summary) end
        return true
      end

      if love.timer and love.timer.getTime and (love.timer.getTime() - start_time) > (tonumber(config.ui_timeout_seconds) or 300) then
        close_overlay()
        show_msg("Auto Mod Updater", "Updater timed out waiting for PowerShell.\nYou can still play.", {"OK"}, "warning")
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
