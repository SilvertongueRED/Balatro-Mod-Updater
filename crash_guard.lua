-- [Mod Updater] crash guard -------------------------------------------------------------------------------------
-- If Balatro crashes while it is still starting (before the main menu) and the Mod Updater has just updated some
-- mods, this shows a recovery screen instead of going straight to the crash report:
--   * Put them all back and restart
--   * Choose which mods to put back
--   * Show the crash report (nothing changes)
-- Works with mouse, keyboard (arrows / Enter / Esc) and controller (D-pad or stick / A / B).
-- Lovely copies this file to the top of the game's main.lua (see lovely.toml), so it also catches crashes very early
-- in startup. main.lua of the Mod Updater loads it again (harmless) in case that patch did not run.
-- Everything is inside pcall: a problem here can never stop the game from starting or hide the normal crash report.
-----------------------------------------------------------------------------------------------------------------------
pcall(function()
  if type(love) ~= "table" then return end
  if AMU_CRASH_GUARD and AMU_CRASH_GUARD.installed then return end

  local CG = AMU_CRASH_GUARD or {}
  AMU_CRASH_GUARD = CG
  CG.installed = true
  CG.reached_menu = CG.reached_menu or false   -- the Mod Updater sets this once the main menu is up

  -- ---------------------------------------------------------------- the error handler slot
  -- Whoever sets love.errorhandler after us (Steamodded's crash report) becomes the "next" handler. We stay in front
  -- by keeping the slot empty in the table itself and answering reads of it through a metatable.
  CG.next = rawget(love, "errorhandler")
  rawset(love, "errorhandler", nil)
  local mt = getmetatable(love)
  if mt == nil then mt = {}; setmetatable(love, mt) end
  local old_index, old_newindex = mt.__index, mt.__newindex
  mt.__index = function(t, k)
    if k == "errorhandler" then return CG.handler end
    if type(old_index) == "function" then return old_index(t, k) end
    if type(old_index) == "table" then return old_index[k] end
    return nil
  end
  mt.__newindex = function(t, k, v)
    if k == "errorhandler" then
      if v ~= CG.handler then CG.next = v end
      return
    end
    if type(old_newindex) == "function" then return old_newindex(t, k, v) end
    rawset(t, k, v)
  end

  -- ---------------------------------------------------------------- files
  local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
  end

  local function read_all(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
  end

  -- The Mod Updater's folder (main.lua fills CG.mod_dir in; before that, look for it).
  function CG.find_mod_dir()
    if CG.mod_dir and exists(CG.mod_dir .. "/autoupdate.ps1") then return CG.mod_dir end
    local mods
    local okl, lv = pcall(require, "lovely")
    if okl and type(lv) == "table" and type(lv.mod_dir) == "string" then mods = lv.mod_dir end
    if not mods then mods = love.filesystem.getSaveDirectory() .. "/Mods" end
    mods = mods:gsub("[/\\]+$", "")
    if exists(mods .. "/Balatro-Mod-Updater/autoupdate.ps1") then return mods .. "/Balatro-Mod-Updater" end
    local okd, items = pcall(love.filesystem.getDirectoryItems, "Mods")
    if okd and type(items) == "table" then
      local base = love.filesystem.getSaveDirectory() .. "/Mods/"
      for _, it in ipairs(items) do
        if exists(base .. it .. "/automodupdater.json") and exists(base .. it .. "/autoupdate.ps1") then return base .. it end
      end
    end
    return nil
  end

  function CG.decoder(dir)
    local okj, j = pcall(dofile, dir .. "/json.lua")
    if okj and type(j) == "table" and type(j.decode) == "function" then return j.decode end
    return nil
  end

  -- The mods the updater changed right before this start (waiting for an answer, or just updated).
  function CG.suspects(dir)
    local decode = CG.decoder(dir)
    if not decode then return {} end
    local out, seen = {}, {}
    local function add(list)
      if type(list) ~= "table" then return end
      if list.mod_name then list = { list } end   -- PowerShell writes a one-item list as an object
      for _, e in ipairs(list) do
        if type(e) == "table" and type(e.mod_name) == "string" and e.mod_name ~= "" and not seen[e.mod_name] then
          seen[e.mod_name] = true
          out[#out + 1] = {
            name = e.mod_name,
            ver = e.updated_to_version ~= nil and tostring(e.updated_to_version) or "",
            at = type(e.updated_at) == "string" and e.updated_at or "",
          }
        end
      end
    end
    local okp, p = pcall(decode, read_all(dir .. "/_crash_pending.json") or "")
    if okp and type(p) == "table" then add(p.mods) end
    local okr, r = pcall(decode, read_all(dir .. "/_recently_updated.json") or "")
    if okr and type(r) == "table" then add(r) end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
  end

  local function jstr(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  end

  -- Run autoupdate.ps1 to put these mods back (and pin them). Blocks until it is done.
  function CG.put_back(dir, names)
    local parts = {}
    for _, n in ipairs(names) do parts[#parts + 1] = jstr(n) end
    local sel = dir .. "/_crash_selection.json"
    local f = io.open(sel, "wb")
    if not f then return false, "Could not write _crash_selection.json" end
    f:write('{"mods":[' .. table.concat(parts, ",") .. ']}')
    f:close()
    os.remove(dir .. "/_crash_rollback_report.json")
    local function win(p) return '"' .. (p:gsub("/", "\\"):gsub("[\\]+$", "")) .. '"' end
    local mods_dir = dir:gsub("[/\\][^/\\]+$", "")
    local cmd = table.concat({
      "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
      "-File", win(dir .. "/autoupdate.ps1"),
      "-ModsDir", win(mods_dir),
      "-SelfDir", win(dir),
      "-RollbackRecent",
      "-SelectionFile", win(sel),
    }, " ")
    pcall(os.execute, cmd)
    local decode = CG.decoder(dir)
    local okr, rep = pcall(decode or error, read_all(dir .. "/_crash_rollback_report.json") or "")
    if not (okr and type(rep) == "table") then return false, "The put-back did not run (see last_run.json)." end
    local done, failed = {}, {}
    local list = rep.mods
    if type(list) == "table" and list.mod_name then list = { list } end
    for _, e in ipairs(type(list) == "table" and list or {}) do
      if type(e) == "table" and e.mod_name then
        if e.error then failed[#failed + 1] = tostring(e.mod_name) .. " - " .. tostring(e.error)
        else done[#done + 1] = tostring(e.mod_name) end
      end
    end
    return true, done, failed
  end

  -- ---------------------------------------------------------------- restarting the game (Windows)
  -- Same method as Balatro Mod Search and Sort: a hidden PowerShell helper waits until Balatro has really closed,
  -- waits for Steam to stop counting the game as running, starts it again (Steam, or the exe directly) and checks
  -- that it came up. The helper is started through the Task Scheduler so it is NOT a child of the game - otherwise
  -- Steam says "Game already running". Files go to Balatro's save folder. Returns true when the helper is on its way.
  -- Used by the crash screen and by the Mod Updater's "Restart now" buttons.
  function CG.relaunch_helper()
    if not (love.system and love.system.getOS and love.system.getOS() == "Windows") then return false end
    if not (love.filesystem and love.filesystem.write and love.filesystem.getSaveDirectory) then return false end
    local APP, TASK = "2379780", "AMU_Restart"
    local HELPER, LAUNCHER = "amu_restart_helper.ps1", "amu_restart_launcher.ps1"
    local function q(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

    local exe = tostring(love.filesystem.getSource and love.filesystem.getSource() or ""):gsub("/", "\\")
    local dir = exe:match("^(.*)\\[^\\]*$") or ""
    local have_exe = exe:lower():match("%.exe$") ~= nil
    local is_steam = exe:lower():find("steamapps", 1, true) ~= nil
    if not is_steam and not have_exe then return false end

    local lines = {
      "$ErrorActionPreference = 'SilentlyContinue'",
      "$log = Join-Path $PSScriptRoot 'amu_restart_helper.log'",
      "function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) }",
      "Set-Content -Path $log -Value 'restart helper started'",
      "$p = Get-Process -Name 'Balatro'",
      "if ($p) { $p | Wait-Process -Timeout 3 }",
      "$p = Get-Process -Name 'Balatro'",
      "if ($p) { Log 'game still running after 3s, force closing'; $p | Stop-Process -Force }",
      "for ($i = 0; $i -lt 30 -and (Get-Process -Name 'Balatro'); $i++) { Start-Sleep -Milliseconds 500 }",
      "Log 'game process is gone'",
      "Start-Sleep -Seconds 2",
      "$flag = 'HKCU:\\Software\\Valve\\Steam\\Apps\\" .. APP .. "'",
      "function Test-SteamRunning { $v = (Get-ItemProperty -Path $flag -Name Running -ErrorAction SilentlyContinue).Running; return ($v -eq 1) }",
      "$w = 0",
      "$maxwait = " .. (have_exe and "6" or "90"),
      "while ((Test-SteamRunning) -and $w -lt $maxwait) { Start-Sleep -Seconds 1; $w++ }",
      "$up = $false",
      "Start-Sleep -Seconds 1",
    }
    if have_exe then
      lines[#lines + 1] = "if (Test-SteamRunning) { Log 'starting the exe directly'; Start-Process -FilePath " .. q(exe) ..
        " -WorkingDirectory " .. q(dir) .. "; for ($i = 0; $i -lt 70; $i++) { Start-Sleep -Milliseconds 500; if (Get-Process -Name 'Balatro') { $up = $true; break } } }"
    end
    local more = {
      "for ($try = 1; $try -le 3 -and -not $up; $try++) {",
      "  Log ('asking Steam to start the game, try ' + $try)",
      "  Start-Process " .. q("steam://rungameid/" .. APP),
      "  for ($i = 0; $i -lt 70; $i++) { Start-Sleep -Milliseconds 500; if (Get-Process -Name 'Balatro') { $up = $true; break } }",
      "  if (-not $up) { Start-Sleep -Seconds 5 }",
      "}",
    }
    for _, l in ipairs(more) do lines[#lines + 1] = l end
    if have_exe then
      lines[#lines + 1] = "if (-not $up) { Log 'Steam did not start it, starting the exe directly'; Start-Process -FilePath " ..
        q(exe) .. " -WorkingDirectory " .. q(dir) .. " }"
    end
    lines[#lines + 1] = "if ($up) { Log 'game is running again' }"
    lines[#lines + 1] = "Unregister-ScheduledTask -TaskName '" .. TASK .. "' -Confirm:$false | Out-Null"
    if not pcall(love.filesystem.write, HELPER, table.concat(lines, "\r\n") .. "\r\n") then return false end

    local script = (love.filesystem.getSaveDirectory() .. "/" .. HELPER):gsub("/", "\\")
    local launcher = {
      "$ErrorActionPreference = 'Stop'",
      "try {",
      "  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument " ..
        q('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. script .. '"'),
      "  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable",
      "  Register-ScheduledTask -TaskName '" .. TASK .. "' -Action $a -Settings $s -Force | Out-Null",
      "  Start-ScheduledTask -TaskName '" .. TASK .. "'",
      "  exit 0",
      "} catch { exit 1 }",
    }
    local ran = false
    if pcall(love.filesystem.write, LAUNCHER, table.concat(launcher, "\r\n") .. "\r\n") then
      local lf = (love.filesystem.getSaveDirectory() .. "/" .. LAUNCHER):gsub("/", "\\")
      local okc, rc = pcall(os.execute, 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. lf .. '"')
      ran = okc and (rc == 0 or rc == true)
    end
    if not ran then
      -- no Task Scheduler: start the helper in its own (hidden) window instead
      local okp = pcall(os.execute, 'start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. script .. '"')
      ran = okp
    end
    return ran
  end

  -- ---------------------------------------------------------------- the screen
  local S = {}   -- screen state (one crash per run)

  local function colour(r, g, b, a) love.graphics.setColor(r, g, b, a or 1) end

  local function short_ver(v)
    if v:match("^%x+$") and #v > 7 then return v:sub(1, 7) end
    if #v > 14 then return v:sub(1, 13) .. ".." end
    return v
  end

  local function when(at)
    local y, mo, d, h, mi = at:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)")
    if y then return y .. "-" .. mo .. "-" .. d .. " " .. h .. ":" .. mi end
    return ""
  end

  local function label(m)
    local bits = {}
    local v = short_ver(m.ver)
    if v ~= "" then bits[#bits + 1] = "now " .. v end
    local w = when(m.at)
    if w ~= "" then bits[#bits + 1] = "updated " .. w end
    if #bits == 0 then return m.name end
    return m.name .. "    (" .. table.concat(bits, "   ") .. ")"
  end

  -- what can be selected on the current page: { kind = "row"|"button", text, act, mod }
  local function build_items()
    local items = {}
    if S.mode == "main" then
      items[#items + 1] = { kind = "button", text = "Put them all back and restart", act = "all" }
      items[#items + 1] = { kind = "button", text = "Choose which mods to put back...", act = "choose" }
      items[#items + 1] = { kind = "button", text = "Show the crash report (change nothing)", act = "report" }
    elseif S.mode == "pick" then
      for _, m in ipairs(S.mods) do items[#items + 1] = { kind = "row", mod = m } end
      items[#items + 1] = { kind = "button", text = "Put back the ticked mods and restart", act = "selected" }
      items[#items + 1] = { kind = "button", text = "Put back all and restart", act = "all" }
      items[#items + 1] = { kind = "button", text = "Back", act = "back" }
    elseif S.mode == "done" then
      if S.ok and #S.done > 0 then
        items[#items + 1] = { kind = "button", text = "Restart Balatro", act = "restart" }
      end
      items[#items + 1] = { kind = "button", text = "Close the game", act = "quit" }
      items[#items + 1] = { kind = "button", text = "Show the crash report", act = "report" }
    end
    S.items = items
    if not S.focus or S.focus > #items then S.focus = 1 end
  end

  local function set_mode(mode, focus)
    S.mode = mode
    S.focus = focus or 1
    S.scroll = 0
    build_items()
  end

  local function restart()
    -- stop the game's helper threads first (they keep the process alive)
    pcall(function()
      if G then
        for _, m in ipairs({ G.SOUND_MANAGER, G.SAVE_MANAGER, G.HTTP_MANAGER }) do
          if m and m.channel then m.channel:push({ type = "kill" }) end
        end
      end
    end)
    -- A restart "in place" does not bring the game back on every PC, so a small helper waits for the game to close
    -- and starts it again (through Steam, or the exe). Only if that cannot be set up, try the in-place restart.
    local okh, started = pcall(CG.relaunch_helper)
    if okh and started then return 0 end
    pcall(function() require("lovely").reload_patches() end)
    return "restart"
  end

  local function start_put_back(names)
    S.work = names
    set_mode("working")
  end

  local function activate(i)
    local it = S.items[i or S.focus]
    if not it then return nil end
    S.focus = i or S.focus
    if it.kind == "row" then
      S.ticked[it.mod.name] = not S.ticked[it.mod.name]
      return nil
    end
    local a = it.act
    if a == "all" then
      local names = {}
      for _, m in ipairs(S.mods) do names[#names + 1] = m.name end
      start_put_back(names)
    elseif a == "choose" then
      set_mode("pick")
    elseif a == "back" then
      set_mode("main", 2)
    elseif a == "selected" then
      local names = {}
      for _, m in ipairs(S.mods) do if S.ticked[m.name] then names[#names + 1] = m.name end end
      if #names == 0 then S.note = "Nothing is ticked: tick a mod first (or choose Back)." else start_put_back(names) end
    elseif a == "report" then
      S.mode = "report"
    elseif a == "restart" then
      return restart()
    elseif a == "quit" then
      return 0
    end
    return nil
  end

  local function move(d)
    if not S.items or #S.items == 0 then return end
    S.focus = ((S.focus - 1 + d) % #S.items) + 1
    S.note = nil
  end

  local function back()
    if S.mode == "pick" then set_mode("main", 2)
    elseif S.mode == "main" or S.mode == "done" then S.mode = "report" end
  end

  -- layout + draw; also records where each item is, for the mouse
  local function draw()
    local W, H = love.graphics.getDimensions()
    local fs = math.max(14, math.floor(H / 34))
    if not S.font or S.font_size ~= fs then
      local okf, f = pcall(love.graphics.newFont, "resources/fonts/m6x11plus.ttf", fs)
      if not okf then f = love.graphics.newFont(fs) end
      local okt, t = pcall(love.graphics.newFont, "resources/fonts/m6x11plus.ttf", math.floor(fs * 1.5))
      if not okt then t = love.graphics.newFont(math.floor(fs * 1.5)) end
      local oks, sm = pcall(love.graphics.newFont, "resources/fonts/m6x11plus.ttf", math.floor(fs * 0.8))
      if not oks then sm = love.graphics.newFont(math.floor(fs * 0.8)) end
      S.font, S.title_font, S.small_font, S.font_size = f, t, sm, fs
    end
    local f, lh = S.font, S.font:getHeight()
    love.graphics.origin()
    love.graphics.clear(0.13, 0.13, 0.17, 1)
    local x0, maxw = math.floor(W * 0.08), math.floor(W * 0.84)
    local y = math.floor(H * 0.06)

    love.graphics.setFont(S.title_font)
    colour(0.72, 0.5, 1)
    love.graphics.printf(S.mode == "done" and "Crash recovery" or "Balatro crashed while starting", x0, y, maxw, "center")
    y = y + S.title_font:getHeight() + lh * 0.6
    love.graphics.setFont(f)

    local function para(text, r, g, b)
      colour(r or 0.93, g or 0.93, b or 0.96)
      local _, lines = f:getWrap(text, maxw)
      love.graphics.printf(text, x0, y, maxw, "left")
      y = y + #lines * lh
    end

    S.hit = {}
    if S.mode == "main" then
      para("The Mod Updater updated these mods just before this start. One of them may have caused the crash:")
      y = y + lh * 0.4
      local shown = math.min(#S.mods, 8)
      for i = 1, shown do para("    " .. label(S.mods[i]), 0.82, 0.86, 1) end
      if #S.mods > shown then para("    ...and " .. (#S.mods - shown) .. " more", 0.82, 0.86, 1) end
      y = y + lh * 0.4
      para("Put back = the version you had before, pinned so it is not updated again until you unpin it (Mod Updater > Backups).", 0.7, 0.72, 0.8)
      y = y + lh * 0.8
    elseif S.mode == "pick" then
      para("Tick the mods to put back. Tip: put back half of them, start the game, and see if it still crashes.")
      y = y + lh * 0.5
    elseif S.mode == "done" then
      if not S.ok then
        para(S.err or "Nothing was put back.", 1, 0.6, 0.4)
      else
        if #S.done > 0 then
          para("Put back and pinned:", 0.6, 1, 0.6)
          for _, n in ipairs(S.done) do para("    " .. n) end
        end
        if #S.failed > 0 then
          y = y + lh * 0.3
          para("Could not be put back:", 1, 0.6, 0.4)
          for _, n in ipairs(S.failed) do para("    " .. n) end
        end
        if #S.done == 0 and #S.failed == 0 then para("Nothing was changed.") end
      end
      y = y + lh * 0.6
      if S.ok and #S.done > 0 then
        para("Restart Balatro to load the old versions. If the game does not come back by itself, start it again.", 0.7, 0.72, 0.8)
        y = y + lh * 0.6
      end
    elseif S.mode == "working" then
      para("Putting the old versions back... please wait.")
    end

    -- the selectable items; long pick lists scroll so the focused one stays visible
    local footer_h = lh * 3.2
    local avail = H - y - footer_h
    local row_h = math.floor(lh * 1.45)
    local first = 1
    if S.mode == "pick" and S.items then
      local fit = math.max(3, math.floor(avail / row_h))
      if S.focus - S.scroll > fit then S.scroll = S.focus - fit end
      if S.focus <= S.scroll then S.scroll = S.focus - 1 end
      first = S.scroll + 1
      if first > 1 then
        colour(0.7, 0.72, 0.8); love.graphics.printf("(more above)", x0, y - lh, maxw, "right")
      end
    end
    local bw = math.floor(math.min(maxw, f:getWidth("Put back the ticked mods and restart") + lh * 4))
    local bx = math.floor((W - bw) / 2)
    for i = first, #(S.items or {}) do
      if y + row_h > H - footer_h then
        colour(0.7, 0.72, 0.8); love.graphics.printf("(more below)", x0, y - lh * 0.2, maxw, "right")
        break
      end
      local it = S.items[i]
      local focused = (i == S.focus)
      if it.kind == "row" then
        local rx, rw = x0, maxw
        if focused then colour(0.36, 0.22, 0.55); love.graphics.rectangle("fill", rx, y, rw, row_h - 4, 6, 6) end
        local box = math.floor(lh * 0.8)
        colour(1, 1, 1)
        love.graphics.rectangle("line", rx + lh * 0.5, y + (row_h - box) / 2 - 2, box, box, 3, 3)
        if S.ticked[it.mod.name] then
          colour(0.45, 0.9, 0.45)
          love.graphics.rectangle("fill", rx + lh * 0.5 + 3, y + (row_h - box) / 2 + 1, box - 6, box - 6, 2, 2)
        end
        colour(0.95, 0.95, 1)
        love.graphics.print(label(it.mod), rx + lh * 1.8, y + (row_h - lh) / 2 - 2)
        S.hit[#S.hit + 1] = { i = i, x = rx, y = y, w = rw, h = row_h - 4 }
      else
        if focused then colour(0.25, 0.55, 0.95) else colour(0.25, 0.27, 0.36) end
        love.graphics.rectangle("fill", bx, y, bw, row_h - 6, 8, 8)
        if focused then colour(1, 1, 1); love.graphics.rectangle("line", bx - 2, y - 2, bw + 4, row_h - 2, 9, 9) end
        colour(1, 1, 1)
        love.graphics.printf(it.text, bx, y + (row_h - 6 - lh) / 2, bw, "center")
        S.hit[#S.hit + 1] = { i = i, x = bx, y = y, w = bw, h = row_h - 6 }
      end
      y = y + row_h
    end

    -- footer: note, controls, and the first line of the error
    local fy = H - footer_h + lh * 0.3
    if S.note then colour(1, 0.75, 0.3); love.graphics.printf(S.note, x0, fy - lh * 1.1, maxw, "center") end
    love.graphics.setFont(S.small_font)
    colour(0.7, 0.72, 0.8)
    if S.mode ~= "working" then
      love.graphics.printf("D-pad / stick / arrow keys: move     A / Enter: choose     B / Esc: "
        .. (S.mode == "pick" and "back" or "crash report") .. "     Mouse works too", x0, fy, maxw, "center")
    end
    local first_line = tostring(S.msg or ""):match("^[^\n]*") or ""
    if #first_line > 160 then first_line = first_line:sub(1, 157) .. "..." end
    colour(0.55, 0.57, 0.66)
    love.graphics.printf("Error: " .. first_line, x0, fy + S.small_font:getHeight() * 1.4, maxw, "center")
    love.graphics.present()
  end

  local function hit_test(x, y)
    for _, h in ipairs(S.hit or {}) do
      if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then return h.i end
    end
    return nil
  end

  -- one frame of our screen; returns a value to quit / restart (like any LOVE error-handler loop)
  local function step()
    if S.mode == "report" then
      if S.next_loop == nil and not S.next_called then
        S.next_called = true
        local h = CG.next or rawget(love, "errhand")
        if type(h) == "function" then
          local okh, loop = pcall(h, S.msg)
          if okh and type(loop) == "function" then S.next_loop = loop end
        end
      end
      if type(S.next_loop) == "function" then return S.next_loop() end
      return 1
    end

    if S.mode == "working" then
      draw()                      -- show "please wait" first
      local okp, a, b, c = pcall(CG.put_back, S.dir, S.work)
      S.ok = okp and a or false
      if S.ok then S.done, S.failed = b or {}, c or {}
      else S.done, S.failed, S.err = {}, {}, (okp and b) or tostring(a) end
      set_mode("done")
      draw()
      return nil
    end

    love.event.pump()
    for e, a, b, c in love.event.poll() do
      if e == "quit" then
        return a or 0
      elseif e == "keypressed" then
        if a == "up" or a == "w" or (a == "tab" and love.keyboard.isDown("lshift", "rshift")) then move(-1)
        elseif a == "down" or a == "s" or a == "tab" then move(1)
        elseif a == "return" or a == "kpenter" or a == "space" then local r = activate(); if r ~= nil then return r end
        elseif a == "escape" or a == "backspace" then back() end
      elseif e == "gamepadpressed" then
        if b == "dpup" then move(-1)
        elseif b == "dpdown" then move(1)
        elseif b == "a" then local r = activate(); if r ~= nil then return r end
        elseif b == "b" or b == "back" then back() end
      elseif e == "gamepadaxis" then
        if b == "lefty" then
          if math.abs(c) < 0.3 then S.axis = nil
          elseif not S.axis then S.axis = true; move(c > 0 and 1 or -1) end
        end
      elseif e == "mousemoved" then
        local i = hit_test(a, b)
        if i then S.focus = i end
      elseif e == "mousepressed" then
        local i = hit_test(a, b)
        if i then local r = activate(i); if r ~= nil then return r end end
      elseif e == "wheelmoved" then
        move(b > 0 and -1 or 1)
      end
    end
    if S.mode == "report" then return nil end
    draw()
    if love.timer then love.timer.sleep(0.03) end
    return nil
  end

  -- ---------------------------------------------------------------- the handler itself
  function CG.should_show()
    if CG.reached_menu then return nil end
    if not (love.system and love.system.getOS and love.system.getOS() == "Windows") then return nil end
    if not (love.window and love.graphics and love.event) then return nil end
    local dir = CG.find_mod_dir()
    if not dir then return nil end
    local mods = CG.suspects(dir)
    if #mods == 0 then return nil end
    return dir, mods
  end

  function CG.handler(msg)
    msg = tostring(msg)
    local okc, dir, mods = pcall(CG.should_show)
    if not (okc and dir) then
      local h = CG.next or rawget(love, "errhand")
      if type(h) == "function" then return h(msg) end
      return nil
    end

    -- Let a modern crash report (Steamodded's) prepare now, while the crash's stack trace is still there;
    -- it only runs if the player asks for it.
    if type(CG.next) == "function" then
      S.next_called = true
      local okh, loop = pcall(CG.next, msg)
      if okh and type(loop) == "function" then S.next_loop = loop end
    end

    local okw = pcall(function()
      if not love.graphics.isCreated() or not love.window.isOpen() then error("no window") end
      if love.mouse then
        love.mouse.setVisible(true)
        love.mouse.setGrabbed(false)
        love.mouse.setRelativeMode(false)
        if love.mouse.isCursorSupported() then love.mouse.setCursor() end
      end
      if love.joystick then
        for _, j in ipairs(love.joystick.getJoysticks()) do pcall(j.setVibration, j) end
      end
      if love.audio then love.audio.stop() end
      love.graphics.reset()
    end)
    if not okw then
      if type(S.next_loop) == "function" then return S.next_loop end
      local h = rawget(love, "errhand")
      if type(h) == "function" then return h(msg) end
      return nil
    end

    S.msg, S.dir, S.mods, S.ticked = msg, dir, mods, {}
    for _, m in ipairs(mods) do S.ticked[m.name] = true end
    set_mode("main")
    pcall(function()
      local f = io.open(dir .. "/_crash_last_error.txt", "wb")
      if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. msg); f:close() end
    end)

    return function()
      local okstep, r = pcall(step)
      if okstep then return r end
      -- something went wrong in this screen: fall back to the normal crash report
      S.mode = "report"
      local ok2, r2 = pcall(step)
      if ok2 then return r2 end
      return 1
    end
  end
end)
