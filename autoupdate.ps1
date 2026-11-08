param(
  [Parameter(Mandatory=$true)][string]$ModsDir,
  [Parameter(Mandatory=$true)][string]$SelfDir,
  [string]$RestoreModName = "",
  [string]$RestoreBackupFile = "",
  [string]$TargetMod = "",
  # Put an earlier Steamodded ("smods") or Lovely ("lovely") back from one of its backups (in-game Backups tab).
  [string]$RestoreFrameworkName = "",
  [string]$RestoreFrameworkFile = "",
  # Play a saved copy of the game itself (in-game Backups tab > Balatro game files, or "Use backed up game.bat").
  # A backup name, "steam" (= back to the version Steam has installed) or "interactive" (ask in this console).
  [string]$UseGameBackup = "",
  [switch]$CheckForks,
  # With -CheckForks: look at every recently active fork (Fork Finder set to "Show all forks"). Without it only forks that could be newer than the installed copy are compared.
  [switch]$AllForks,
  [string]$SwitchModName = "",
  [string]$SwitchToForkRepo = "",
  [string]$SwitchBackModName = "",
  [switch]$RollbackRecent,
  # With -RollbackRecent: a JSON file {"mods":["A","B"]} saying which mods to put back (the in-game picker writes it).
  [string]$SelectionFile = "",
  # With -RollbackRecent: list the mods and ask which ones to put back (used by "Undo last update.bat").
  [switch]$Interactive
)

$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Read-JsonIfExists([string]$path) {
  if (Test-Path -LiteralPath $path) {
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Save-JsonNoBom([string]$path, $obj) {
  $json = ($obj | ConvertTo-Json -Depth 10)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

# ---- changelogs.json: short "what changed" notes shown when you hover a mod in the Backups tab ----
# Refreshed after every update and every restore, so it always describes the INSTALLED version.
function Get-GitLogEntries([string]$folderPath, [string]$until = "", [int]$max = 12) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $a = @("-C", $folderPath, "log", "-n", "$max", "--no-merges", "--date=short", "--format=%h|%ad|%s")
    if ($until -ne "") { $a += "--until=$until" }
    $out = & git @a 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }
    $list = @()
    foreach ($line in @($out)) {
      $p = ([string]$line).Split("|", 3)
      if ($p.Count -eq 3) { $list += @{ h = $p[0]; d = $p[1]; s = $p[2] } }
    }
    return $list
  } catch { return @() } finally { $ErrorActionPreference = $old }
}

function Set-ChangelogEntry([string]$modName, $entry) {
  try {
    $path = Join-Path $selfDirResolved "changelogs.json"
    $cl = Read-JsonIfExists $path
    $mods = @{}
    if ($cl -and $cl.mods) { foreach ($p in $cl.mods.PSObject.Properties) { $mods[$p.Name] = $p.Value } }
    $mods[$modName] = $entry
    Save-JsonNoBom $path @{ generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm"); mods = $mods }
  } catch {}
}

function Refresh-GitChangelog([string]$modName, [string]$folderPath, [string]$until = "") {
  try {
    $commits = @(Get-GitLogEntries $folderPath $until 12)
    if ($commits.Count -eq 0) { return }
    $entry = @{ source = "git"; head = $commits[0].h; date = $commits[0].d; commits = $commits }
    if ($until -ne "") { $entry.restored = $true }
    Set-ChangelogEntry $modName $entry
  } catch {}
}

# Turns a release description (markdown) into a few short plain lines.
function Split-ReleaseNotes([string]$body, [int]$max = 8) {
  $out = @()
  if (-not $body) { return $out }
  foreach ($line in ($body -split "\r?\n")) {
    $t = ($line -replace "^\s*[#>\-\*\+]+\s*", "" -replace "\*\*", "" -replace "\s+", " ").Trim()
    if ($t.Length -lt 3) { continue }
    if ($t.Length -gt 160) { $t = $t.Substring(0, 157) + "..." }
    $out += $t
    if ($out.Count -ge $max) { break }
  }
  return $out
}

$script:releaseNotes = @{}   # folder name -> @{ tag = ...; notes = @(...) } for non-git updates done in this run

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
# Windows PowerShell 5.1's progress bar makes Invoke-WebRequest downloads many times slower.
$ProgressPreference = "SilentlyContinue"

$ModsDir = $ModsDir.Trim().Trim('"')
$SelfDir = $SelfDir.Trim().Trim('"')

$summary = @{
  ran_at = (Get-Date).ToString("o")
  updated_mods = @()
  skipped_mods = @()
  errors = @()
  available_updates = @()   # updates found that need a manual download (e.g. Nexus without Premium)
  untracked_mods = @()      # mods with no git repo and no update.json (never checked)
  framework_staged = $false # true when Steamodded/Lovely updates are waiting for a restart
  github_token_bad = $false # true when GitHub rejected the saved token (expired); the game then asks for a new one
}

# Tracks mods updated this run so crash detection can roll them back if needed
$recentlyUpdatedEntries = [System.Collections.Generic.List[hashtable]]::new()

try { $modsDirResolved = (Resolve-Path -LiteralPath $ModsDir).Path } catch { $modsDirResolved = $ModsDir; $summary.errors += "Resolve-Path failed for ModsDir '$ModsDir': $($_.Exception.Message)" }
try { $selfDirResolved = (Resolve-Path -LiteralPath $SelfDir).Path } catch { $selfDirResolved = $SelfDir; $summary.errors += "Resolve-Path failed for SelfDir '$SelfDir': $($_.Exception.Message)" }

try { Ensure-Dir $selfDirResolved } catch { $summary.errors += "Couldn't create SelfDir '$selfDirResolved': $($_.Exception.Message)" }

$selfFolderName = Split-Path -Leaf $selfDirResolved

$summaryPath           = Join-Path $selfDirResolved "last_run.json"
$recentlyUpdatedPath   = Join-Path $selfDirResolved "_recently_updated.json"
$launchSentinelPath    = Join-Path $selfDirResolved "_launch_sentinel"
$crashReportPath       = Join-Path $selfDirResolved "_crash_rollback_report.json"
# Mods that were updated right before a startup crash and are waiting for the player's decision
# (put back / keep). Written by main.lua (or by this script), answered in game or by "Undo last update.bat".
$crashPendingPath      = Join-Path $selfDirResolved "_crash_pending.json"
$forkSuggestionsPath   = Join-Path $selfDirResolved "fork_suggestions.json"


# The "no update source" and "folder name out of date" lists come from the last full update check. Keep them while this
# run starts (and for a Fork Finder scan, which does not rebuild them), so the game does not lose them.
$prevUntracked = @(); $prevStale = @()
try {
  if (Test-Path -LiteralPath $summaryPath) {
    $prevRun = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($prevRun.untracked_mods)    { $prevUntracked = @($prevRun.untracked_mods | ForEach-Object { [string]$_ }) }
    if ($prevRun.folder_name_stale) { $prevStale     = @($prevRun.folder_name_stale | ForEach-Object { [string]$_ }) }
  }
} catch {}
$summary.untracked_mods    = @($prevUntracked)
$summary.folder_name_stale = @($prevStale)

# early save: create/refresh last_run.json immediately so you can confirm the script actually ran
try { Save-JsonNoBom $summaryPath $summary } catch {}

$defaults = [ordered]@{
  update_git = $true
  update_updatejson = $true
  make_backups = $true
  skip_folders = @("smods", "_Balatro-Mod-Updater_Backups")
  nexus_api_key = ""
  nexus_game_domain = "balatro"
  git_pull_mode = "ff-only"  # "ff-only" (default) or "rebase"
  update_frameworks = $false
  update_steamodded = $false
  update_lovely = $false
  pinned_mods = [PSCustomObject]@{}
  balatro_game_dir = ""  # optional override
  github_token = ""      # optional: a GitHub token raises the API limit from 60 to 5000 requests/hour
  git_reset_on_diverge = $false  # if true, a mod whose history was force-pushed upstream is reset to upstream (after backup)
  report_untracked = $true       # list mods that have no git repo and no update.json, so you know they're never checked
  game_backup = $true            # save a copy of the Balatro game files for every Steam build (so a game update can be sidestepped)
  game_backup_keep = 3           # how many saved copies of the game to keep
  game_auto_switch = $true       # when Steam updates the game, switch back to the saved copy of the version you were on and freeze mod/framework updates until you turn them on
  allow_updates_on_backup_game = $false  # false: mod and framework updates are paused while a backed up game is installed
  pin_retry_newer = $true        # a pinned mod/framework is tried again (straight to the LATEST version) once its source has a different version than the one that was put back
}

# Forks not pushed within this many months are considered stale and skipped during fork scanning
$ForkStalenessMonths = 12
# Max forks compared per source repo (installed / parent / original) during a fork scan (keeps a scan inside GitHub's API limit)
$ForkMaxComparesPerMod = 6

$configPath = Join-Path $selfDirResolved "autoupdater_config.json"
$config = Read-JsonIfExists $configPath
if (-not $config) {
  $config = $defaults
} else {
  foreach ($k in $defaults.Keys) {
    if ($null -eq $config.$k) { $config | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force }
  }
  if (-not $config.skip_folders) { $config.skip_folders = $defaults.skip_folders }
}

$skipSet = @{}
foreach ($n in $config.skip_folders) { $skipSet[$n] = $true }

# (moved up from the framework section so the put-back code can use them)
function Get-SteamLibraries() {
  $libs = @()
  try {
    $steam = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
    $steamPath = $steam.SteamPath
    if (-not $steamPath) { $steamPath = $steam.InstallPath }
    if ($steamPath) { $steamPath = $steamPath -replace "/", "\"; $libs += $steamPath }
    if ($steamPath) {
      $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"
      if (Test-Path -LiteralPath $vdf) {
        $txt = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        $matches = [regex]::Matches($txt, '"path"\s*"([^"]+)"')
        foreach ($m in $matches) {
          $p = $m.Groups[1].Value -replace "\\\\", "\"
          if ($p -and -not ($libs -contains $p)) { $libs += $p }
        }
      }
    }
  } catch {}
  return $libs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

function Get-BalatroGameDir() {
  if ($config.balatro_game_dir -and $config.balatro_game_dir.Trim() -ne "") {
    return ($config.balatro_game_dir.Trim().Trim('"'))
  }
  $appid = 2379780
  foreach ($lib in (Get-SteamLibraries)) {
    $acf = Join-Path $lib "steamapps\appmanifest_$appid.acf"
    if (Test-Path -LiteralPath $acf) {
      $txt = Get-Content -LiteralPath $acf -Raw -Encoding UTF8
      $m = [regex]::Match($txt, '"installdir"\s*"([^"]+)"')
      if ($m.Success) {
        $dir = $m.Groups[1].Value
        $gameDir = Join-Path $lib ("steamapps\common\" + $dir)
        if (Test-Path -LiteralPath $gameDir) { return $gameDir }
      }
    }
  }
  return $null
}


# Headers for GitHub API calls. Adds the optional token so we don't hit the 60/hour anonymous limit.
function Get-GhHeaders() {
  $h = @{ "User-Agent"="BalatroModUpdater"; "Accept"="application/vnd.github+json" }
  if ($config.github_token -and ([string]$config.github_token).Trim() -ne "" -and -not $script:ghTokenBad) {
    $h["Authorization"] = "Bearer " + ([string]$config.github_token).Trim()
  }
  return $h
}

# Check the saved GitHub token once per run (/rate_limit does not count against the limit). An expired token makes EVERY
# GitHub call fail with 401 (releases, Steamodded, Lovely). So a rejected token is left out for this run (updates then work
# anonymously, 60 checks/hour) and last_run.json says github_token_bad so the game can ask for a new one.
$script:ghTokenBad = $false
# Switching a mod to a fork (or back) and putting mods back never call the GitHub API, so they skip this check: it is a network
# round trip that can take seconds (up to the 10 second timeout when GitHub answers slowly), and the game's "Restart now / Later"
# window only opens once the script has finished.
$script:skipTokenCheck = ($SwitchModName -ne "" -or $SwitchBackModName -ne "" -or $RollbackRecent)
if (-not $script:skipTokenCheck -and $config.github_token -and ([string]$config.github_token).Trim() -ne "") {
  try {
    Invoke-RestMethod -Uri "https://api.github.com/rate_limit" -Headers (Get-GhHeaders) -TimeoutSec 10 | Out-Null
  } catch {
    $tokSt = 0
    try { $tokSt = [int]$_.Exception.Response.StatusCode } catch {}
    if ($tokSt -eq 401) { $script:ghTokenBad = $true; $summary.github_token_bad = $true }
  }
}

# Returns the HTTP status code from a failed Invoke-RestMethod/Invoke-WebRequest, or 0 if unknown.
function Get-HttpStatus($err) {
  try { if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode } } catch {}
  return 0
}

# ---- Timing (written to update_timing_detail.txt at the end of every run) ----
$script:swTotal = [System.Diagnostics.Stopwatch]::StartNew()
$script:timing = New-Object System.Collections.ArrayList
$script:ghCacheHits = 0      # GitHub said "unchanged": the saved answer was reused (free, no download)
$script:ghCacheFresh = 0     # fresh answers downloaded and saved
$script:forkEntryReused = 0  # fork comparisons reused from the last scan (nothing pushed since)
$script:forkEntryBuilt = 0   # fork comparisons made fresh
$script:forkUnrelated = 0     # repos with no common history with the installed copy (skipped, not an error)
$script:gitSecTotal = 0.0    # seconds spent inside git commands (all of them)
$script:gitNetSec = 0.0      # ...of which git fetch / pull / ls-remote / clone (the ones that talk to the internet)
$script:gitCalls = 0
$script:apiSecTotal = 0.0    # seconds spent waiting for the GitHub API
function Add-Timing([string]$what, $sw) {
  try { [void]$script:timing.Add(@{ what = $what; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }) } catch {}
}
function Write-TimingDetail([string]$mode) {
  try {
    $lines = @()
    $lines += "Updater timing  $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  mode: $mode"
    $lines += "Total: $([math]::Round($script:swTotal.Elapsed.TotalSeconds, 1))s"
    $lines += "GitHub answers reused: $script:ghCacheHits   fetched fresh: $script:ghCacheFresh"
    $lines += "Fork comparisons reused: $script:forkEntryReused   made fresh: $script:forkEntryBuilt"
    $lines += ("Time in git: {0}s over {1} commands (network ones: {2}s)   Time in GitHub API calls: {3}s" -f [math]::Round($script:gitSecTotal, 1), $script:gitCalls, [math]::Round($script:gitNetSec, 1), [math]::Round($script:apiSecTotal, 1))
    $lines += "Slowest steps:"
    $top = @($script:timing | Sort-Object { [double]$_.sec } -Descending | Select-Object -First 20)
    foreach ($t in $top) { $lines += ("  {0,7}s  {1}" -f $t.sec, $t.what) }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $selfDirResolved "update_timing_detail.txt"), ($lines -join "`r`n") + "`r`n", $utf8NoBom)
    # one line per run, kept (the detail file above only ever shows the latest run)
    try {
      $histPath = Join-Path $selfDirResolved "update_timing_history.txt"
      $hist = @()
      if (Test-Path -LiteralPath $histPath) { $hist = @(Get-Content -LiteralPath $histPath -Encoding UTF8 -ErrorAction SilentlyContinue) }
      $hist += ("{0}  {1,-12} total {2,6}s  git {3,6}s  api {4,5}s  GitHub answers reused {5}/{6}  fork comparisons reused {7}/{8}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $mode, [math]::Round($script:swTotal.Elapsed.TotalSeconds, 1), [math]::Round($script:gitSecTotal, 1), [math]::Round($script:apiSecTotal, 1), $script:ghCacheHits, ($script:ghCacheHits + $script:ghCacheFresh), $script:forkEntryReused, ($script:forkEntryReused + $script:forkEntryBuilt))
      if ($hist.Count -gt 60) { $hist = $hist[($hist.Count - 60)..($hist.Count - 1)] }
      [System.IO.File]::WriteAllText($histPath, ($hist -join "`r`n") + "`r`n", $utf8NoBom)
    } catch {}
  } catch {}
}

# ---- GitHub answer cache ----
# GitHub can answer "has this changed since I last asked?" with a tiny 304 reply that does not count against the hourly
# limit. We keep the last answer (and its ETag) in _gh_cache and reuse it on a 304, so nothing is ever stale: if GitHub says
# it changed, the new answer is downloaded. Turn off with "use_github_cache": false in autoupdater_config.json.
$script:ghCacheDir = Join-Path $selfDirResolved "_gh_cache"
function Get-GhCacheKey([string]$s) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)) } finally { $sha.Dispose() }
  return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}
function Get-GhJson([string]$uri, $headers) {
  if ($config.use_github_cache -eq $false) { return (Invoke-RestMethod -Uri $uri -Headers $headers) }
  $key = Get-GhCacheKey $uri
  $etagFile = Join-Path $script:ghCacheDir "$key.etag"
  $bodyFile = Join-Path $script:ghCacheDir "$key.json"
  $h = @{}
  foreach ($k in $headers.Keys) { $h[$k] = $headers[$k] }
  $haveCache = $false
  try {
    if ((Test-Path -LiteralPath $etagFile) -and (Test-Path -LiteralPath $bodyFile)) {
      $et = ([System.IO.File]::ReadAllText($etagFile)).Trim()
      if ($et -ne "") { $h["If-None-Match"] = $et; $haveCache = $true }
    }
  } catch { $haveCache = $false }
  $swApi = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = Invoke-WebRequest -Uri $uri -Headers $h -UseBasicParsing
    try { $script:apiSecTotal += $swApi.Elapsed.TotalSeconds } catch {}
  } catch {
    try { $script:apiSecTotal += $swApi.Elapsed.TotalSeconds } catch {}
    if ($haveCache -and (Get-HttpStatus $_) -eq 304) {
      $script:ghCacheHits++
      $raw = [System.IO.File]::ReadAllText($bodyFile, [System.Text.Encoding]::UTF8)
      try { [System.IO.File]::SetLastWriteTime($bodyFile, (Get-Date)) } catch {}
      return (ConvertFrom-Json -InputObject $raw)
    }
    throw
  }
  $content = [string]$resp.Content
  $script:ghCacheFresh++
  try {
    $etag = ""
    try { $etag = [string]$resp.Headers["ETag"] } catch {}
    if ($etag -and $content.Length -lt 900000) {
      if (-not (Test-Path -LiteralPath $script:ghCacheDir)) { New-Item -ItemType Directory -Path $script:ghCacheDir -Force | Out-Null }
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($bodyFile, $content, $utf8NoBom)
      [System.IO.File]::WriteAllText($etagFile, $etag, $utf8NoBom)
    }
  } catch {}
  return (ConvertFrom-Json -InputObject $content)
}
# Old cache files (not used for 30 days) are removed at the end of a run.
function Clear-OldGhCache() {
  try {
    if (Test-Path -LiteralPath $script:ghCacheDir) {
      $cut = (Get-Date).AddDays(-30)
      Get-ChildItem -LiteralPath $script:ghCacheDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

# When -TargetMod is provided, only process that single mod folder
$targetModFilter = $TargetMod.Trim().Trim('"')

$backupRoot = Join-Path $modsDirResolved "_Balatro-Mod-Updater_Backups"
try { Ensure-Dir $backupRoot } catch { $summary.errors += "Couldn't create backup folder '$backupRoot': $($_.Exception.Message)" }

function Backup-Folder([string]$folderPath, [string]$folderName) {
  if (-not $config.make_backups) { return $null }
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $dest = Join-Path $backupRoot "$folderName-$stamp.zip"
  try {
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    try {
      Compress-Archive -Path (Join-Path $folderPath "*") -DestinationPath $dest -Force -ErrorAction Stop
    } catch {
      # A file can vanish or be locked while it is zipped: the game rewrites the Updater's own timing logs during a run, which made
      # the backup fail with "Could not find file ...update_timing.log". Zip a copy instead; files that disappear while copying are skipped.
      $tmp = Join-Path ([IO.Path]::GetTempPath()) ("amu_backup_" + [Guid]::NewGuid().ToString("N"))
      try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Get-ChildItem -LiteralPath $folderPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
          Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tmp $_.Name) -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Compress-Archive -Path (Join-Path $tmp "*") -DestinationPath $dest -Force -ErrorAction Stop
      } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    return (Split-Path -Leaf $dest)
  } catch {
    $summary.errors += "Backup failed for ${folderName}: $($_.Exception.Message)"
    return $null
  }
}

# Files/folders that hold THIS mod's own settings and per-user data (API keys, GitHub token, toggles, saved lists,
# staged framework updates...). A fresh copy from the repo only has blank defaults, so these must survive the updater
# updating or restoring itself.
$script:SelfKeepNames = @(
  "config.lua", "autoupdater_config.json", "changelogs.json", "toggle_snapshot.json",
  "update.json", "update.json.off", ".autoupdater_state.json", ".framework_state.json",
  "fork_suggestions.json", "last_run.json", "_recently_updated.json", "_crash_pending.json", "launcher_debug.json",
  "pending_apply_log.json", "pending_apply.json", "_pending_framework_updates",
  "update_timing_detail.txt", "_gh_cache", "_framework_backups",
  "pin_versions.json", "_pin_released.json", ".game_state.json", "ui_state.json"
)

function Test-IsSelfFolder([string]$folderPath) {
  try {
    $a = [IO.Path]::GetFullPath($folderPath).TrimEnd('\','/')
    $b = [IO.Path]::GetFullPath($selfDirResolved).TrimEnd('\','/')
    return ($a -ieq $b)
  } catch { return $false }
}

# ---- Pin memory: which version a pinned mod/framework was put back FROM ----
# A pin used to mean "stay here until the player unpins". Now the updater also remembers the version it went back from (the one
# that crashed, or the one installed when you pressed Restore & Pin) in pin_versions.json. Every update check looks whether the
# source serves a DIFFERENT version by now. If it does, the pin is released and the mod goes straight to the LATEST version
# (not to the next one), with crash protection watching it like any other update. A source that still serves the same version
# leaves the pin alone. Turn it off with "pin_retry_newer": false in autoupdater_config.json (or on the Config page).
$script:PinVersionsPath = Join-Path $selfDirResolved "pin_versions.json"
$script:PinReleasedPath = Join-Path $selfDirResolved "_pin_released.json"
$script:lastRestoreFromIdent = ""
$script:pinsReleased = New-Object System.Collections.ArrayList

function Get-PinVersions() {
  $h = @{}
  $o = Read-JsonIfExists $script:PinVersionsPath
  if ($o) { foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
  return $h
}

function Save-PinVersions($h) {
  $o = [ordered]@{}
  foreach ($k in ($h.Keys | Sort-Object)) { $o[[string]$k] = $h[$k] }
  try { Save-JsonNoBom $script:PinVersionsPath $o } catch { $summary.errors += "Couldn't save pin_versions.json: $($_.Exception.Message)" }
}

# Remember the version a pin went back from. A blank version never overwrites a good one that is already recorded.
function Set-PinVersion([string]$name, [string]$ver, [string]$why) {
  if (-not $name) { return }
  $h = Get-PinVersions
  if (-not $ver -and $h.ContainsKey($name) -and $h[$name].from_version) { return }
  $h[$name] = [ordered]@{ from_version = $ver; why = $why; recorded_at = (Get-Date).ToString("o") }
  Save-PinVersions $h
}

# git without the timing bookkeeping of Run-Git (Run-Git is defined further down, after the put-back code that needs this).
function Invoke-GitQuick([string]$folderPath, [string[]]$gitArgs) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & git -C $folderPath @gitArgs 2>&1
    return @{ out = @($out); code = $LASTEXITCODE }
  } catch {
    return @{ out = @(); code = 1 }
  } finally { $ErrorActionPreference = $old }
}

# The version a mod folder is at right now, in the same form the update code records it:
# GitHub release = tag, GitHub branch = commit sha, Nexus = file id, git = HEAD sha. "" when unknown.
function Get-ModIdentity([string]$folderPath) {
  try {
    $ujp = Join-Path $folderPath "update.json"
    $uj = $null
    if (Test-Path -LiteralPath $ujp) { $uj = Read-JsonIfExists $ujp }
    $prov = if ($uj -and $uj.provider) { ([string]$uj.provider).ToLower() } else { "" }
    if ($prov -eq "github" -or $prov -eq "nexus") {
      $st = Read-JsonIfExists (Join-Path $folderPath ".autoupdater_state.json")
      if ($st) {
        if ($prov -eq "nexus" -and $st.file_id) { return [string]$st.file_id }
        if ($st.tag) { return [string]$st.tag }
        if ($st.commit) { return [string]$st.commit }
      }
      return ""
    }
    if (Test-Path -LiteralPath (Join-Path $folderPath ".git")) {
      $r = Invoke-GitQuick $folderPath @("rev-parse", "HEAD")
      if ($r.code -eq 0 -and $r.out.Count -gt 0) { return ([string]($r.out | Select-Object -First 1)).Trim() }
    }
  } catch {}
  return ""
}

function Format-ShortVersion([string]$v) {
  if ($v -match '^[0-9a-fA-F]{40}$') { return $v.Substring(0, 7) }
  return $v
}

# Restore a named backup zip over a mod folder.
# Preserves update.json so the updater can resume normally after the mod is unpinned.
function Restore-ModBackup([string]$modName, [string]$backupFile) {
  $modPath = Join-Path $modsDirResolved $modName
  $backupPath = Join-Path $backupRoot $backupFile
  if (-not (Test-Path -LiteralPath $backupPath)) { throw "Backup file not found: $backupPath" }
  if (-not (Test-Path -LiteralPath $modPath))    { throw "Mod folder not found: $modPath" }

  # The version being left (needed to notice later when the source has something newer; see Set-PinVersion).
  $script:lastRestoreFromIdent = Get-ModIdentity $modPath

  # Save files we never want to overwrite
  $preserve = @("update.json")
  if (Test-IsSelfFolder $modPath) { $preserve = @($script:SelfKeepNames) }
  $tmpPreserve = Join-Path ([IO.Path]::GetTempPath()) ("amu_preserve_" + [Guid]::NewGuid().ToString("N"))
  Ensure-Dir $tmpPreserve
  foreach ($p in $preserve) {
    $pp = Join-Path $modPath $p
    if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $tmpPreserve $p) -Recurse -Force }
  }

  # Extract backup to a temp directory first so we can copy cleanly
  $tmpExtract = Join-Path ([IO.Path]::GetTempPath()) ("amu_restore_" + [Guid]::NewGuid().ToString("N"))
  Ensure-Dir $tmpExtract
  Expand-Archive -LiteralPath $backupPath -DestinationPath $tmpExtract -Force

  # Remove existing mod contents (keep .git to avoid destroying git history)
  Get-ChildItem -LiteralPath $modPath -Force |
    Where-Object { $_.Name -ne ".git" } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

  # Copy restored files into mod folder
  Get-ChildItem -LiteralPath $tmpExtract -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $modPath $_.Name) -Recurse -Force
  }

  # Restore preserved files
  foreach ($p in $preserve) {
    $pp = Join-Path $tmpPreserve $p
    if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $modPath $p) -Recurse -Force }
  }

  # Clear autoupdater state so the version is re-evaluated after unpinning
  $statePath = Join-Path $modPath ".autoupdater_state.json"
  if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }

  # If this is a git mod, leave a marker so the updater can reset the working
  # tree to HEAD after the mod is unpinned (backup files differ from HEAD).
  $gitDir = Join-Path $modPath ".git"
  if (Test-Path -LiteralPath $gitDir -PathType Container) {
    $markerPath = Join-Path $modPath ".amu_restored_backup"
    try { Set-Content -LiteralPath $markerPath -Value (Get-Date).ToString("o") -Encoding UTF8 } catch {
      $summary.errors += "Failed to create restore marker for ${modName}: $($_.Exception.Message)"
    }
  }

  # Refresh the "what changed" notes so they describe the version that was just restored.
  try {
    $until = ""
    $sm = [regex]::Match($backupFile, '(\d{8})_(\d{6})\.zip$')
    if ($sm.Success) {
      $dt = [datetime]::ParseExact($sm.Groups[1].Value + $sm.Groups[2].Value, "yyyyMMddHHmmss", $null)
      $until = $dt.ToString("yyyy-MM-dd HH:mm:ss")
    }
    if (Test-Path -LiteralPath $gitDir -PathType Container) {
      Refresh-GitChangelog $modName $modPath $until
    } else {
      $when = if ($until -ne "") { $until } else { $backupFile }
      Set-ChangelogEntry $modName @{ source = "backup"; restored = $true; date = $(if ($until -ne "") { $until.Substring(0,10) } else { "" }); notes = @("Reverted to the copy saved on $when") }
    }
  } catch {}

  Remove-Item -LiteralPath $tmpExtract  -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmpPreserve -Recurse -Force -ErrorAction SilentlyContinue
}

# Build a fast-lookup set of pinned mod names from config.pinned_mods
$pinnedSet = @{}
if ($config.pinned_mods) {
  try {
    if ($config.pinned_mods -is [System.Collections.IDictionary]) {
      foreach ($key in $config.pinned_mods.Keys) { $pinnedSet[$key] = $true }
    } else {
      foreach ($prop in $config.pinned_mods.PSObject.Properties) { $pinnedSet[$prop.Name] = $true }
    }
  } catch {
    $summary.errors += "Failed to parse pinned_mods from config: $($_.Exception.Message)"
  }
}

# ---- Startup-crash detection and the "put the old versions back?" question ----
# Only active in normal update mode (not restore-only and not single-mod target).
#
# How it works:
#   * This script writes _recently_updated.json after updating (and deletes the old sentinel/flags).
#   * main.lua writes _launch_attempt very early while the game is loading, and
#     _launch_sentinel once the main menu is reached.
#   * If main.lua starts and finds _launch_attempt but no _launch_sentinel, the previous launch never reached
#     the menu. main.lua then moves the mods from _recently_updated.json into _crash_pending.json and ASKS the
#     player in game: put them all back / choose which / keep them. (If this script sees _crash_flag first, it
#     does the same move.)
#   * Nothing is put back until the player decides. While a decision is waiting, those mods are not updated again.
#   * -RollbackRecent puts mods back and pins them. It is used by the in-game question (with -SelectionFile) and by
#     "Undo last update.bat" (with -Interactive), which also works when Balatro won't start at all.
$launchAttemptPath = Join-Path $selfDirResolved "_launch_attempt"
$crashFlagPath     = Join-Path $selfDirResolved "_crash_flag"

function Clear-LaunchMarkers() {
  foreach ($p in @($launchSentinelPath, $launchAttemptPath, $crashFlagPath)) {
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  }
}

# JSON dates may come back as DateTime objects; keep them as ISO text so the game can read them.
function ConvertTo-IsoText($v) {
  if ($null -eq $v) { return "" }
  if ($v -is [datetime]) { return $v.ToString("o") }
  return [string]$v
}

# The mods that could have caused a startup crash: the ones waiting for a decision plus the ones from the last update.
function Get-CrashCandidates() {
  $byName = [ordered]@{}
  $recent = Read-JsonIfExists $recentlyUpdatedPath
  if ($recent) { foreach ($e in @($recent)) { if ($e.mod_name) { $byName[[string]$e.mod_name] = $e } } }
  $pend = Read-JsonIfExists $crashPendingPath
  if ($pend -and $pend.mods) { foreach ($e in @($pend.mods)) { if ($e.mod_name) { $byName[[string]$e.mod_name] = $e } } }
  return @($byName.Values)
}

# One clean, plain entry (text only) for the files that main.lua also reads.
function New-CrashEntry($e) {
  return [ordered]@{
    mod_name           = [string]$e.mod_name
    backup_file        = [string]$e.backup_file
    updated_to_version = [string]$e.updated_to_version
    updated_at         = (ConvertTo-IsoText $e.updated_at)
    restore_to         = [string]$e.restore_to
  }
}

# Remember the mods from the last update as "waiting for a decision". No mod files are touched.
function Save-CrashPending($entries) {
  $merged = [ordered]@{}
  $old = Read-JsonIfExists $crashPendingPath
  if ($old -and $old.mods) { foreach ($e in @($old.mods)) { if ($e.mod_name) { $merged[[string]$e.mod_name] = $e } } }
  foreach ($e in @($entries)) { if ($e.mod_name) { $merged[[string]$e.mod_name] = $e } }
  $list = @()
  foreach ($e in $merged.Values) { $list += New-CrashEntry $e }
  Save-JsonNoBom $crashPendingPath ([ordered]@{ detected_at = (Get-Date).ToString("o"); mods = @($list) })
}

# ---- Steamodded / Lovely: putting an earlier version back ----
# Backups live in the Updater's _framework_backups folder:  smods-<date>.zip  and  lovely-<date>-winmm.dll
$script:FrameworkBackupRoot = Join-Path $selfDirResolved "_framework_backups"

function Get-FrameworkDisplay([string]$name) { if ($name -eq "smods") { return "Steamodded" } else { return "Lovely" } }

# The installed Steamodded folder (same choice the framework update makes).
function Get-SmodsInstallDir() {
  $valid = @()
  foreach ($c in @(Get-ChildItem -LiteralPath $modsDirResolved -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^smods($|-)" })) {
    $loader = Get-ChildItem -LiteralPath $c.FullName -Recurse -File -Filter "loader.lua" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '[\\/]src[\\/]' } | Select-Object -First 1
    if ($loader) { $valid += $c }
  }
  if ($valid.Count -gt 0) { return ($valid | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
  return (Join-Path $modsDirResolved "smods")
}

# A backup can be given as a full path or as just its file name inside _framework_backups.
function Resolve-FrameworkBackup([string]$file) {
  if (-not $file) { return $null }
  $f = $file.Trim().Trim('"')
  if ($f -eq "") { return $null }
  if (Test-Path -LiteralPath $f -PathType Leaf) { return (Resolve-Path -LiteralPath $f).Path }
  $p = Join-Path $script:FrameworkBackupRoot $f
  if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
  return $null
}

# "lovely-20261103_173000-winmm.dll" -> "winmm.dll"
function Get-LovelyDllNameFromBackup([string]$backupPath) {
  $m = [regex]::Match([IO.Path]::GetFileName($backupPath), '(winmm\.dll|version\.dll)$', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return "winmm.dll"
}

function Set-FrameworkPin([string]$name, [string]$backupFile, [string]$crashedVer) {
  if (-not $config.framework_pins) { $config | Add-Member -NotePropertyName framework_pins -NotePropertyValue ([PSCustomObject]@{}) -Force }
  $pin = [PSCustomObject]@{ pinned = $true; backup_file = $backupFile; pinned_at = (Get-Date).ToString("o"); crashed_version = $crashedVer }
  $config.framework_pins | Add-Member -NotePropertyName $name -NotePropertyValue $pin -Force
}

function Test-FrameworkPinned([string]$name) {
  try {
    $p = $config.framework_pins.$name
    return [bool]($p -and $p.pinned -eq $true)
  } catch { return $false }
}

# Put Steamodded / Lovely back RIGHT NOW (the startup crash screen: nothing else has the files open except the crashed
# game, which is about to be restarted). A loaded dll cannot be overwritten, but it can be renamed out of the way.
function Restore-FrameworkNow([string]$name, [string]$backupFile, [string]$restoreTo) {
  $bk = Resolve-FrameworkBackup $backupFile
  if (-not $bk) { throw "backup file not found: $backupFile" }
  if ($name -eq "smods") {
    $dst = $restoreTo
    if (-not $dst) { $dst = Get-SmodsInstallDir }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("amu_fwnow_" + [Guid]::NewGuid().ToString("N"))
    Ensure-Dir $tmp
    try {
      Expand-Archive -LiteralPath $bk -DestinationPath $tmp -Force
      if (-not (Get-ChildItem -LiteralPath $tmp -Force | Select-Object -First 1)) { throw "the backup zip is empty" }
      if (Test-Path -LiteralPath $dst) {
        Get-ChildItem -LiteralPath $dst -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
      } else {
        Ensure-Dir $dst
      }
      Copy-Item -Path (Join-Path $tmp "*") -Destination $dst -Recurse -Force
    } finally {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  } else {
    $dst = $restoreTo
    if (-not $dst) {
      $gd = Get-BalatroGameDir
      if (-not $gd) { throw "could not find the Balatro game folder" }
      $dst = Join-Path $gd (Get-LovelyDllNameFromBackup $bk)
    }
    try {
      Copy-Item -LiteralPath $bk -Destination $dst -Force -ErrorAction Stop
    } catch {
      $aside = "$dst.crashed_" + (Get-Date -Format "yyyyMMdd_HHmmss")
      Move-Item -LiteralPath $dst -Destination $aside -Force
      Copy-Item -LiteralPath $bk -Destination $dst -Force
    }
    # only one Lovely dll may be present (two would load Lovely twice)
    $gdir = Split-Path -Parent $dst
    foreach ($other in @("winmm.dll", "version.dll")) {
      $op = Join-Path $gdir $other
      if (($other -ine (Split-Path -Leaf $dst)) -and (Test-Path -LiteralPath $op)) {
        Move-Item -LiteralPath $op -Destination ("$op.old_" + (Get-Date -Format "yyyyMMdd_HHmmss")) -Force
      }
    }
  }
}

# First time only: save the Steamodded and Lovely that are installed right now, so the Backups tab always has something
# to go back to (normally a backup is only made right before an update replaces them).
function Ensure-FrameworkBaseline() {
  try {
    Ensure-Dir $script:FrameworkBackupRoot
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if (-not (Get-ChildItem -LiteralPath $script:FrameworkBackupRoot -Filter "smods-*.zip" -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      $sd = Get-SmodsInstallDir
      if ((Test-Path -LiteralPath $sd) -and (Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Compress-Archive -Path (Join-Path $sd "*") -DestinationPath (Join-Path $script:FrameworkBackupRoot "smods-$stamp.zip") -Force
        $summary.skipped_mods += "[Framework] Saved your current Steamodded as a backup you can go back to"
      }
    }
    if (-not (Get-ChildItem -LiteralPath $script:FrameworkBackupRoot -Filter "lovely-*" -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      $gd = Get-BalatroGameDir
      if ($gd) {
        foreach ($n in @("winmm.dll", "version.dll")) {
          $f = Join-Path $gd $n
          if (Test-Path -LiteralPath $f) {
            Copy-Item -LiteralPath $f -Destination (Join-Path $script:FrameworkBackupRoot "lovely-$stamp-$n") -Force
            $summary.skipped_mods += "[Framework] Saved your current Lovely as a backup you can go back to"
            break
          }
        }
      }
    }
    # Older Lovely files the updater itself left in the game folder (winmm.dll.bak_<date>, version.dll.old_<date>) are
    # copied in too, so earlier Lovely versions show up in the list.
    $gd2 = Get-BalatroGameDir
    if ($gd2 -and (Test-Path -LiteralPath $gd2)) {
      foreach ($f in @(Get-ChildItem -LiteralPath $gd2 -File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, '^(winmm|version)\.dll\.(?:bak|old)_(\d{8}_\d{6})$', 'IgnoreCase')
        if ($m.Success) {
          $dest = Join-Path $script:FrameworkBackupRoot ("lovely-" + $m.Groups[2].Value + "-" + $m.Groups[1].Value.ToLower() + ".dll")
          if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            $summary.skipped_mods += "[Framework] Found an earlier Lovely ($($f.Name)) and added it to the backups"
          }
        }
      }
    }
  } catch {
    $summary.skipped_mods += "[Framework] Could not save a first Steamodded/Lovely backup: $($_.Exception.Message)"
  }
}

# ---- The game itself: a saved copy per Steam build, and playing from one ----
# Steam updates Balatro on its own, and mods/Lovely/Steamodded built for the NEW game can crash the OLD one (or the other way
# round). So every update check saves a copy of the installed game files (once per game build, about 85 MB) in
# AMU_GameBackups next to the Mods folder. "Play" a saved copy = apply_pending.ps1 puts its files back into the Steam folder
# when the game quits and starts the game through Steam, so Steam's Play button, overlay and playtime keep working.
# While a saved copy is installed, mod and framework updates are paused (a mod built for the newer game would likely crash it)
# unless "allow_updates_on_backup_game" is on.
$script:GameBackupRoot = Join-Path (Split-Path -Parent $modsDirResolved) "AMU_GameBackups"
$script:GameStatePath  = Join-Path $selfDirResolved ".game_state.json"
$script:holdUpdates = $false

function Get-GameState() {
  $h = @{}
  $o = Read-JsonIfExists $script:GameStatePath
  if ($o) { foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
  return $h
}
function Save-GameState($h) {
  $o = [ordered]@{}
  foreach ($k in ($h.Keys | Sort-Object)) { $o[[string]$k] = $h[$k] }
  try { Save-JsonNoBom $script:GameStatePath $o } catch { $summary.errors += "Couldn't save .game_state.json: $($_.Exception.Message)" }
}

# SHA-256 of Balatro.exe, remembered by size + modified time so most checks don't read 56 MB again.
function Get-GameExeHash([string]$exe) {
  $fi = Get-Item -LiteralPath $exe
  $st = Get-GameState
  $mt = [string]$fi.LastWriteTimeUtc.Ticks
  if ($st.ContainsKey("exe_cache") -and $st["exe_cache"] -and [long]$st["exe_cache"].size -eq $fi.Length -and [string]$st["exe_cache"].mtime -eq $mt -and $st["exe_cache"].sha) {
    return [string]$st["exe_cache"].sha
  }
  $h = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
  $st["exe_cache"] = [ordered]@{ size = $fi.Length; mtime = $mt; sha = $h }
  Save-GameState $st
  return $h
}

# Steam's build number of the installed game (from appmanifest_2379780.acf), "" when it can't be read.
function Get-SteamBuildId() {
  try {
    foreach ($lib in (Get-SteamLibraries)) {
      $acf = Join-Path $lib "steamapps\appmanifest_2379780.acf"
      if (Test-Path -LiteralPath $acf) {
        $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw -Encoding UTF8), '"buildid"\s+"(\d+)"')
        if ($m.Success) { return $m.Groups[1].Value }
      }
    }
  } catch {}
  return ""
}

# Saved copies of the game, newest first. Each has a folder with the game files and amu_backup.json.
function Get-GameBackups() {
  $out = @()
  if (-not (Test-Path -LiteralPath $script:GameBackupRoot)) { return $out }
  foreach ($d in @(Get-ChildItem -LiteralPath $script:GameBackupRoot -Directory -ErrorAction SilentlyContinue)) {
    if ($d.Name.StartsWith("_tmp_")) { continue }
    $m = Read-JsonIfExists (Join-Path $d.FullName "amu_backup.json")
    if ($m -and $m.exe_sha256 -and (Test-Path -LiteralPath (Join-Path $d.FullName "Balatro.exe"))) {
      $out += [PSCustomObject]@{ name = $d.Name; dir = $d.FullName; created_at = [string]$m.created_at; buildid = [string]$m.buildid; exe_sha256 = [string]$m.exe_sha256
                                 lovely_tag = [string]$m.lovely_tag; steamodded_tag = [string]$m.steamodded_tag }
    }
  }
  return @($out | Sort-Object created_at -Descending)
}

function Test-SkipGameFile([string]$name) {
  return ($name -match '\.(bak|old|crashed)_\d' -or $name -match '\.lnk$' -or $name -eq "amu_backup.json")
}

# Copy the installed game into a new saved copy (unless this exact Balatro.exe is already saved). Returns a note or "".
function New-GameBackup([string]$gameDir) {
  $exe = Join-Path $gameDir "Balatro.exe"
  if (-not (Test-Path -LiteralPath $exe)) { return "" }
  $sha = Get-GameExeHash $exe
  foreach ($b in (Get-GameBackups)) { if ($b.exe_sha256 -eq $sha) { return "" } }
  $bid = Get-SteamBuildId
  $stampG = Get-Date -Format "yyyyMMdd_HHmmss"
  $name = $stampG + $(if ($bid) { "_b$bid" } else { "" })
  $nTry = 2
  while (Test-Path -LiteralPath (Join-Path $script:GameBackupRoot $name)) { $name = $stampG + "_$nTry" + $(if ($bid) { "_b$bid" } else { "" }); $nTry++ }
  Ensure-Dir $script:GameBackupRoot
  $tmp  = Join-Path $script:GameBackupRoot ("_tmp_" + $name)
  $dest = Join-Path $script:GameBackupRoot $name
  try {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Ensure-Dir $tmp
    $base = $gameDir.TrimEnd('\','/')
    foreach ($f in @(Get-ChildItem -LiteralPath $gameDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      if (Test-SkipGameFile $f.Name) { continue }
      $rel = $f.FullName.Substring($base.Length).TrimStart('\','/')
      $to = Join-Path $tmp $rel
      Ensure-Dir (Split-Path -Parent $to)
      Copy-Item -LiteralPath $f.FullName -Destination $to -Force
    }
    if ((Get-FileHash -LiteralPath (Join-Path $tmp "Balatro.exe") -Algorithm SHA256).Hash -ne $sha) { throw "the copy of Balatro.exe doesn't match the original" }
    $fs = Read-JsonIfExists (Join-Path $selfDirResolved ".framework_state.json")
    $meta = [ordered]@{
      name = $name; created_at = (Get-Date).ToString("o"); buildid = $bid; exe_sha256 = $sha
      exe_size = (Get-Item -LiteralPath $exe).Length
      lovely_tag = $(if ($fs) { [string]$fs.lovely_tag } else { "" }); steamodded_tag = $(if ($fs) { [string]$fs.steamodded_tag } else { "" })
    }
    Save-JsonNoBom (Join-Path $tmp "amu_backup.json") $meta
    Move-Item -LiteralPath $tmp -Destination $dest -Force
  } catch {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    throw
  }
  # keep the newest few; never remove the one that is installed right now or the one being played
  $keep = 3
  try { if ($config.game_backup_keep -and [int]$config.game_backup_keep -ge 1) { $keep = [int]$config.game_backup_keep } } catch {}
  $st = Get-GameState
  $active = if ($st.ContainsKey("active_backup")) { [string]$st["active_backup"] } else { "" }
  $all = @(Get-GameBackups)
  # also keep the version the player was on before a Steam update (last_seen_sha is not updated yet) and any copy a staged swap points at
  $lastSeenKeep = if ($st.ContainsKey("last_seen_sha")) { [string]$st["last_seen_sha"] } else { "" }
  $stagedKeep = @()
  $pendOld = Read-JsonIfExists (Join-Path $selfDirResolved "pending_apply.json")
  if ($pendOld -and $pendOld.tasks) { foreach ($pt in @($pendOld.tasks)) { if ([string]$pt.type -eq "swap_game") { $stagedKeep += [string]$pt.name } } }
  if ($all.Count -gt $keep) {
    foreach ($b in @($all | Select-Object -Skip $keep)) {
      if ($b.exe_sha256 -eq $sha -or $b.name -eq $active -or ($lastSeenKeep -and $b.exe_sha256 -eq $lastSeenKeep) -or $stagedKeep -contains $b.name) { continue }
      Remove-Item -LiteralPath $b.dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  return "[Game] Saved a copy of Balatro" + $(if ($bid) { " (Steam build $bid)" } else { "" }) + " you can play later if a game update breaks your mods"
}

# Which saved copy is installed right now, "" when it is Steam's own version. The state is only trusted while Balatro.exe still
# matches that copy (a Steam update over it clears it).
function Get-ActiveGameBackup() {
  $st = Get-GameState
  $name = if ($st.ContainsKey("active_backup")) { [string]$st["active_backup"] } else { "" }
  if (-not $name) { return "" }
  $gd = Get-BalatroGameDir
  $meta = Read-JsonIfExists (Join-Path (Join-Path $script:GameBackupRoot $name) "amu_backup.json")
  if ($gd -and $meta -and (Test-Path -LiteralPath (Join-Path $gd "Balatro.exe"))) {
    try { if ((Get-GameExeHash (Join-Path $gd "Balatro.exe")) -eq [string]$meta.exe_sha256) { return $name } } catch {}
  }
  $st["active_backup"] = ""
  Save-GameState $st
  return ""
}

# Run at the start of every full update check: save the game if needed, notice a Steam update, switch back to the saved copy of the
# version the player was on (game_auto_switch), and decide about pausing updates.
# Updates stay frozen ("frozen" in .game_state.json) until the player turns them back on (Backups tab > Balatro game files).
function Invoke-GameCheck() {
  if ($config.game_backup -eq $false) { return }
  try {
    $gd = Get-BalatroGameDir
    if (-not $gd -or -not (Test-Path -LiteralPath (Join-Path $gd "Balatro.exe"))) { return }
    $sha = Get-GameExeHash (Join-Path $gd "Balatro.exe")
    $st = Get-GameState
    $last = if ($st.ContainsKey("last_seen_sha")) { [string]$st["last_seen_sha"] } else { "" }
    $active = Get-ActiveGameBackup
    $updated = ($last -and $last -ne $sha -and -not $active)
    # the saved copy of the version the player was on, found BEFORE the new build is saved
    $prev = $null
    if ($updated) { $prev = @(Get-GameBackups | Where-Object { $_.exe_sha256 -eq $last }) | Select-Object -First 1 }
    $note = New-GameBackup $gd
    if ($note) { $summary.skipped_mods += $note }
    $st = Get-GameState
    $st["last_seen_sha"] = $sha
    if ($updated) {
      $summary.game_updated = $true
      $canSwitch = ($prev -and $config.game_auto_switch -ne $false -and $targetModFilter -eq "" -and $UseGameBackup -eq "")
      if ($canSwitch) {
        Save-GameState $st
        try {
          Stage-GameSwap $prev.name | Out-Null
          $st = Get-GameState
          $st["frozen"] = $true
          $st["frozen_at"] = (Get-Date).ToString("o")
          $summary.skipped_mods += "[Game] Balatro was updated by Steam. The new version is saved, and the version you were on ($($prev.name)) is put back when the game restarts. Mod and Steamodded/Lovely updates are frozen until you turn them back on (Backups tab > Balatro game files)."
        } catch {
          $summary.skipped_mods += "[Game] Balatro was updated by Steam but switching back to the earlier saved copy failed: $($_.Exception.Message)"
          $st = Get-GameState
        }
      } else {
        $summary.skipped_mods += "[Game] Balatro was updated by Steam since the last check. If your mods now crash, Mod Updater > Backups > Balatro game files lets you play the saved earlier version."
      }
    }
    Save-GameState $st
    # updates stay frozen after an automatic switch until the player turns them on
    $allow = ($config.allow_updates_on_backup_game -eq $true)
    $frozen = ($st.ContainsKey("frozen") -and $st["frozen"] -eq $true)
    if ($frozen -and $allow) { $st["frozen"] = $false; Save-GameState $st; $frozen = $false }
    $summary.game_backup_active = $active
    $summary.game_updates_frozen = ($frozen -or [bool]$active) -and (-not $allow)
    if (($active -or $frozen) -and $targetModFilter -eq "") {
      if ($allow) {
        $summary.skipped_mods += "[Game] You are playing a saved copy of the game ($active). Mod and framework updates are ON (you allowed them)."
      } else {
        $script:holdUpdates = $true
        $why = if ($active) { "You are playing a saved copy of the game ($active)" } else { "Balatro was updated by Steam and its earlier version is being kept" }
        $summary.skipped_mods += "[Game] $why, so mod and Steamodded/Lovely updates are paused (a mod built for the newer game would likely crash it). Turn them back on in the Backups tab under Balatro game files."
      }
    }
  } catch {
    $summary.skipped_mods += "[Game] Couldn't check or save the game files: $($_.Exception.Message)"
  }
}

# Stage "play this saved copy": apply_pending.ps1 does the swap after the game quits, then starts the game through Steam.
function Stage-GameSwap([string]$which) {
  $gd = Get-BalatroGameDir
  if (-not $gd -or -not (Test-Path -LiteralPath (Join-Path $gd "Balatro.exe"))) { throw "could not find the Balatro game folder (set balatro_game_dir in autoupdater_config.json)" }
  $list = @(Get-GameBackups)
  if ($list.Count -eq 0) { throw "no saved copy of the game exists yet (one is made on the next update check)" }
  $goSteam = ($which.Trim().ToLower() -eq "steam")
  $pick = $null
  if ($goSteam) {
    $bid = Get-SteamBuildId
    if ($bid) { $pick = $list | Where-Object { $_.buildid -eq $bid } | Select-Object -First 1 }
    if (-not $pick) { $pick = $list[0] }
  } else {
    $pick = $list | Where-Object { $_.name -eq $which.Trim() } | Select-Object -First 1
    if (-not $pick) { throw "no saved copy of the game is called '$which'" }
  }
  if ((Get-FileHash -LiteralPath (Join-Path $pick.dir "Balatro.exe") -Algorithm SHA256).Hash -ne $pick.exe_sha256) { throw "the saved copy $($pick.name) is damaged (Balatro.exe changed), nothing was changed" }
  # already on that exact game: nothing to swap (and no pointless restart); just make sure updates are on
  if ($goSteam -and ((Get-GameExeHash (Join-Path $gd "Balatro.exe")) -eq $pick.exe_sha256)) {
    $gst = Get-GameState; $gst["frozen"] = $false; $gst["active_backup"] = ""; Save-GameState $gst
    $summary.skipped_mods += "[Game] Balatro is already on Steam's version, so nothing was changed. Mod and framework updates are on."
    return $pick
  }
  $pendingRoot = Join-Path $selfDirResolved "_pending_framework_updates"
  Ensure-Dir $pendingRoot
  $pendingFile = Join-Path $selfDirResolved "pending_apply.json"
  $pendingNew = @{ pending_root = $pendingRoot; tasks = @(); notes = @() }
  $oldPending = Read-JsonIfExists $pendingFile
  if ($oldPending -and $oldPending.tasks) {
    foreach ($ot in @($oldPending.tasks)) {
      if ([string]$ot.type -eq "swap_game") { continue }
      $h = @{}; foreach ($pr in $ot.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
      $pendingNew.tasks += $h
    }
  }
  $pendingNew.tasks += @{ type = "swap_game"; src = $pick.dir; dst = $gd; label = "game"; version = $pick.name; name = $pick.name
                          exe_sha256 = $pick.exe_sha256; steam_buildid = (Get-SteamBuildId); make_active = (-not $goSteam); backup_root = $script:GameBackupRoot }
  Save-JsonNoBom $pendingFile $pendingNew
  $summary.framework_staged = $true
  if ($goSteam) { $gst = Get-GameState; $gst["frozen"] = $false; Save-GameState $gst }
  if ($goSteam) { $summary.skipped_mods += "[Game staged] Balatro goes back to Steam's version ($($pick.name)) when the game restarts, and updates are on again" }
  else { $summary.skipped_mods += "[Game staged] Balatro $($pick.name) is played when the game restarts (through Steam). Mod and framework updates are paused until you go back." }
  return $pick
}

function Read-GameChoice($list) {
  Write-Host ""
  Write-Host "Saved copies of Balatro (newest first):"
  Write-Host ""
  for ($i = 0; $i -lt $list.Count; $i++) {
    $b = $list[$i]
    $when = ""; try { $when = ([datetime]$b.created_at).ToString("yyyy-MM-dd HH:mm") } catch {}
    $bits = @(); if ($b.buildid) { $bits += "Steam build $($b.buildid)" }; if ($b.lovely_tag) { $bits += "Lovely $($b.lovely_tag)" }; if ($b.steamodded_tag) { $bits += "Steamodded $($b.steamodded_tag)" }
    Write-Host ("  {0,2})  saved {1}   {2}" -f ($i + 1), $when, ($bits -join ", "))
  }
  Write-Host ""
  Write-Host "  number = play that saved copy (mod and framework updates pause)"
  Write-Host "  S      = go back to the version Steam has installed (updates on again)"
  Write-Host "  Q      = change nothing"
  Write-Host ""
  while ($true) {
    $ans = ""
    try { $ans = [string](Read-Host "Your choice") } catch { return "" }
    $ans = $ans.Trim()
    if ($ans -match '^(q|quit|n|no)$' -or $ans -eq "") { return "" }
    if ($ans -match '^(s|steam)$') { return "steam" }
    $n = 0
    if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { return $list[$n - 1].name }
    Write-Host "  Please type a number from the list, S or Q."
  }
}

# Put the previous version of each mod back and pin it so it is not updated again until the player unpins it.
# $entries = the mods to put back; $keptNames = mods that were offered but are staying as they are.
function Invoke-CrashRollback($entries, $keptNames) {
  if (-not $config.pinned_mods) { $config.pinned_mods = [PSCustomObject]@{} }
  $rollbackReport = @{ rolled_back_at = (Get-Date).ToString("o"); mods = @(); kept = @($keptNames) }

  foreach ($entry in @($entries)) {
    $modName    = [string]$entry.mod_name
    $backupFile = [string]$entry.backup_file
    $crashedVer = if ($entry.updated_to_version) { [string]$entry.updated_to_version } else { "" }
    if (-not $modName) { continue }

    if ($modName -eq "smods" -or $modName -eq "lovely") {
      # Steamodded / Lovely: put back from _framework_backups, then pin so the framework is not updated again
      try {
        Restore-FrameworkNow $modName $backupFile ([string]$entry.restore_to)
        Set-FrameworkPin $modName $backupFile $crashedVer
        Set-PinVersion $modName $crashedVer "crash"
        $summary.skipped_mods += "$(Get-FrameworkDisplay $modName) (put back to the previous version after a startup crash)"
        $rollbackReport.mods  += @{ mod_name = $modName; backup_file = $backupFile; crashed_version = $crashedVer }
      } catch {
        $summary.errors      += "Rollback failed for ${modName}: $($_.Exception.Message)"
        $rollbackReport.mods += @{ mod_name = $modName; backup_file = $backupFile; error = $_.Exception.Message }
      }
      continue
    }

    try {
      if ($backupFile -and (Test-Path -LiteralPath (Join-Path $backupRoot $backupFile))) {
        Restore-ModBackup $modName $backupFile
        $fromV = if ($crashedVer) { $crashedVer } else { $script:lastRestoreFromIdent }
        Set-PinVersion $modName $fromV "crash"

        # Pin the mod to prevent it re-updating until a newer version than the one that crashed shows up (or the user unpins it)
        $pinInfo = [PSCustomObject]@{
          pinned           = $true
          backup_file      = $backupFile
          pinned_at        = (Get-Date).ToString("o")
          auto_rolled_back = $true
          crashed_version  = $crashedVer
        }
        $config.pinned_mods | Add-Member -NotePropertyName $modName -NotePropertyValue $pinInfo -Force
        $skipSet[$modName]   = $true
        $pinnedSet[$modName] = $true

        $summary.skipped_mods += "$modName (put back to the previous version after a startup crash)"
        $rollbackReport.mods  += @{ mod_name = $modName; backup_file = $backupFile; crashed_version = $crashedVer }
      } else {
        $errMsg = if ($backupFile) { "backup file not found: $backupFile" } else { "no backup file recorded" }
        $summary.errors      += "Rollback skipped for ${modName}: $errMsg"
        $rollbackReport.mods += @{ mod_name = $modName; backup_file = $backupFile; error = $errMsg }
      }
    } catch {
      $summary.errors      += "Rollback failed for ${modName}: $($_.Exception.Message)"
      $rollbackReport.mods += @{ mod_name = $modName; backup_file = $backupFile; error = $_.Exception.Message }
    }
  }

  # Persist the updated config so the Lua side also knows about the new pins on next run
  try { Save-JsonNoBom $configPath $config } catch {
    $summary.errors += "Failed to save config after crash rollback: $($_.Exception.Message)"
  }

  # Write the report so the game can tell the player what was put back
  if ($rollbackReport.mods.Count -gt 0) {
    try { Save-JsonNoBom $crashReportPath $rollbackReport } catch {
      $summary.errors += "Failed to write crash rollback report: $($_.Exception.Message)"
    }
  }
  return $rollbackReport
}

# For "Undo last update.bat": list the mods and ask which to put back.
# Returns the chosen entries (an empty list = keep everything).
function Read-CrashChoice($cands) {
  Write-Host ""
  Write-Host "Mods that were updated last time (the likely cause if Balatro will not start):"
  Write-Host ""
  for ($i = 0; $i -lt $cands.Count; $i++) {
    $c = $cands[$i]
    $when = ""
    try { if ($c.updated_at) { $when = "   (updated " + ([datetime]$c.updated_at).ToString("yyyy-MM-dd HH:mm") + ")" } } catch {}
    $note = if ($c.backup_file) { "" } else { "   - no backup saved, cannot be put back" }
    Write-Host ("  {0,2})  {1}{2}{3}" -f ($i + 1), $c.mod_name, $when, $note)
  }
  Write-Host ""
  Write-Host "  A      = put back the previous version of ALL of them (just press Enter)"
  Write-Host "  1,3    = put back only those numbers (separate with commas)"
  Write-Host "  K      = keep everything as it is"
  Write-Host ""
  while ($true) {
    $ans = ""
    try { $ans = [string](Read-Host "Your choice") } catch { return @($cands) }   # no console: act like the old 'undo everything'
    $ans = $ans.Trim()
    if ($ans -eq "" -or $ans -match '^(a|all)$') { return @($cands) }
    if ($ans -match '^(k|keep|n|no|q|quit)$') { return @() }
    $picked = @(); $seen = @{}; $bad = $false
    foreach ($tok in ($ans -split '[,\s;]+')) {
      if ($tok -eq "") { continue }
      $n = 0
      if ([int]::TryParse($tok, [ref]$n) -and $n -ge 1 -and $n -le $cands.Count) {
        if (-not $seen.ContainsKey($n)) { $seen[$n] = $true; $picked += $cands[$n - 1] }
      } else { $bad = $true }
    }
    if (-not $bad -and $picked.Count -gt 0) { return @($picked) }
    Write-Host "  Please type A, K, or numbers from the list (for example 1,3)."
  }
}

$crashPendingSet = @{}
if ($RestoreModName -eq "" -and $TargetMod -eq "" -and $RestoreFrameworkName -eq "" -and $UseGameBackup -eq "") {
  $sentinelExists    = Test-Path -LiteralPath $launchSentinelPath
  $recentlyUpdExists = Test-Path -LiteralPath $recentlyUpdatedPath
  $crashFlagExists   = Test-Path -LiteralPath $crashFlagPath

  if ($RollbackRecent) {
    # The player asked for it (in-game question or "Undo last update.bat").
    $cands = @(Get-CrashCandidates)
    if ($cands.Count -eq 0) {
      $summary.errors += "Undo last update: nothing to undo (no recently updated mods are recorded)."
    } else {
      $chosen = $cands
      $selectionOk = $true
      if ($SelectionFile -ne "") {
        $selectionOk = $false
        $sel = Read-JsonIfExists $SelectionFile
        if ($sel -and $null -ne $sel.mods) {
          $want = @{}
          foreach ($n in @($sel.mods)) { $want[[string]$n] = $true }
          $chosen = @($cands | Where-Object { $want.ContainsKey([string]$_.mod_name) })
          $selectionOk = $true
        } else {
          $summary.errors += "Undo last update: couldn't read the selection file, so nothing was changed."
        }
      } elseif ($Interactive) {
        $chosen = @(Read-CrashChoice $cands)
      }

      if ($selectionOk) {
        $chosenNames = @{}
        foreach ($c in $chosen) { $chosenNames[[string]$c.mod_name] = $true }
        $kept = @($cands | Where-Object { -not $chosenNames.ContainsKey([string]$_.mod_name) } | ForEach-Object { [string]$_.mod_name })
        if ($chosen.Count -gt 0) {
          [void](Invoke-CrashRollback $chosen $kept)
        } elseif ($Interactive) {
          Write-Host ""
          Write-Host "Nothing was changed."
        }
        # The question is answered: nothing is waiting any more.
        Remove-Item -LiteralPath $crashPendingPath   -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $recentlyUpdatedPath -Force -ErrorAction SilentlyContinue
        Clear-LaunchMarkers
        # Mods that stay as they are remain suspects until the game has started fine once: the next launch
        # tests them again (and asks again if it fails too), and "Undo last update.bat" can still find them.
        $stillSuspect = @($cands | Where-Object { -not $chosenNames.ContainsKey([string]$_.mod_name) })
        if ($stillSuspect.Count -gt 0) {
          $again = @(); foreach ($e in $stillSuspect) { $again += New-CrashEntry $e }
          try { Save-JsonNoBom $recentlyUpdatedPath @($again) } catch {
            $summary.errors += "Couldn't remember the mods you kept: $($_.Exception.Message)"
          }
        }
      }
    }
    if ($SelectionFile -ne "") { Remove-Item -LiteralPath $SelectionFile -Force -ErrorAction SilentlyContinue }
  } elseif ($recentlyUpdExists -and $crashFlagExists) {
    # A launch after the last update never reached the main menu. Don't change any mod on our own: keep the list
    # for the in-game question (put all back / choose / keep).
    $recentlyUpdated = Read-JsonIfExists $recentlyUpdatedPath
    $parked = $true
    if ($recentlyUpdated) {
      try { Save-CrashPending @($recentlyUpdated) } catch {
        $parked = $false
        $summary.errors += "Couldn't save the list of mods to ask about after the crash: $($_.Exception.Message)"
      }
    }
    if ($parked) {
      Remove-Item -LiteralPath $recentlyUpdatedPath -Force -ErrorAction SilentlyContinue
      Clear-LaunchMarkers
    }
  } elseif ($recentlyUpdExists -and $sentinelExists) {
    # Game reached the main menu after the last update. Clean up.
    Remove-Item -LiteralPath $recentlyUpdatedPath -Force -ErrorAction SilentlyContinue
    Clear-LaunchMarkers
  } elseif (-not $recentlyUpdExists) {
    # No pending update to judge: stale markers from a run with no updates.
    Clear-LaunchMarkers
  }
  # else: update applied but the game hasn't been relaunched yet. Keep waiting.

  # Mods waiting for the player's decision are left alone (not updated again) until it is made.
  if (-not $RollbackRecent) {
    $pendNow = Read-JsonIfExists $crashPendingPath
    if ($pendNow -and $pendNow.mods) {
      foreach ($e in @($pendNow.mods)) {
        if ($e.mod_name) { $crashPendingSet[[string]$e.mod_name] = $true; $skipSet[[string]$e.mod_name] = $true }
      }
    }
  }
}

if ($RollbackRecent) {
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}

# Framework restore mode: stage putting an earlier Steamodded / Lovely back. It is applied after the game quits (the files are
# in use), exactly like a framework update, and the framework is pinned so the updater does not update it again.
if ($RestoreFrameworkName -ne "") {
  try {
    $fwName = $RestoreFrameworkName.Trim().ToLower()
    if ($fwName -ne "smods" -and $fwName -ne "lovely") { throw "unknown framework '$RestoreFrameworkName'" }
    $bk = Resolve-FrameworkBackup $RestoreFrameworkFile
    if (-not $bk) { throw "backup file not found: $RestoreFrameworkFile" }
    $pendingRoot = Join-Path $selfDirResolved "_pending_framework_updates"
    Ensure-Dir $pendingRoot
    $pendingFile = Join-Path $selfDirResolved "pending_apply.json"
    $pendingNew = @{ pending_root = $pendingRoot; tasks = @(); notes = @() }
    # keep anything else that is already staged, but drop an older staged change to the same framework
    $oldPending = Read-JsonIfExists $pendingFile
    if ($oldPending -and $oldPending.tasks) {
      foreach ($ot in @($oldPending.tasks)) {
        $lab = [string]$ot.label
        $sameFw = ($lab -eq $fwName) -or ($fwName -eq "lovely" -and $lab -eq "lovely-old")
        if ([string]$ot.type -eq "swap_game") {
          $h = @{}; foreach ($pr in $ot.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
          $pendingNew.tasks += $h
        } elseif (-not $sameFw) {
          $pendingNew.tasks += @{ type = [string]$ot.type; src = [string]$ot.src; dst = [string]$ot.dst; label = $lab; version = [string]$ot.version; backup_root = [string]$ot.backup_root }
        }
      }
    }
    if ($fwName -eq "smods") {
      $pendingNew.tasks += @{ type = "restore_zip"; src = $bk; dst = (Get-SmodsInstallDir); label = "smods"; version = "restored"; backup_root = $script:FrameworkBackupRoot }
    } else {
      $gd = Get-BalatroGameDir
      if (-not $gd) { throw "could not find the Balatro game folder (set balatro_game_dir in autoupdater_config.json)" }
      $dllName = Get-LovelyDllNameFromBackup $bk
      $pendingNew.tasks += @{ type = "copy_file"; src = $bk; dst = (Join-Path $gd $dllName); label = "lovely"; version = "restored" }
      foreach ($other in @("winmm.dll", "version.dll")) {
        if ($other -ne $dllName -and (Test-Path -LiteralPath (Join-Path $gd $other))) {
          $pendingNew.tasks += @{ type = "disable_file"; dst = (Join-Path $gd $other); label = "lovely-old"; version = "restored" }
        }
      }
    }
    Save-JsonNoBom $pendingFile $pendingNew
    Set-FrameworkPin $fwName (Split-Path -Leaf $bk) ""
    try {
      $fwSt = Read-JsonIfExists (Join-Path $selfDirResolved ".framework_state.json")
      $fwFrom = ""
      if ($fwSt) { $fwFrom = if ($fwName -eq "smods") { [string]$fwSt.steamodded_tag } else { [string]$fwSt.lovely_tag } }
      Set-PinVersion $fwName $fwFrom "manual"
    } catch {}
    try { Save-JsonNoBom $configPath $config } catch { $summary.errors += "Couldn't save the pin for $fwName : $($_.Exception.Message)" }
    $summary.framework_staged = $true
    $summary.skipped_mods += "[Framework staged] $(Get-FrameworkDisplay $fwName) goes back to $(Split-Path -Leaf $bk) when the game restarts (and stays pinned)"
  } catch {
    $summary.errors += "ERROR restoring framework ${RestoreFrameworkName}: $($_.Exception.Message)"
  }
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}

# Game swap mode: stage playing a saved copy of Balatro (or going back to Steam's version). Applied after the game quits.
if ($UseGameBackup -ne "") {
  try {
    $which = $UseGameBackup.Trim()
    if ($which.ToLower() -eq "interactive") {
      $list = @(Get-GameBackups)
      if ($list.Count -eq 0) { throw "no saved copy of the game exists yet (one is made on the next update check)" }
      $which = Read-GameChoice $list
      if ($which -eq "") { Write-Host ""; Write-Host "Nothing was changed."; $summary.skipped_mods += "Game: nothing was changed"; try { Save-JsonNoBom $summaryPath $summary } catch {}; exit 0 }
    }
    $picked = Stage-GameSwap $which
    if ($UseGameBackup.Trim().ToLower() -eq "interactive") { Write-Host ""; Write-Host "Ready: $($picked.name) is put back when the helper runs." }
  } catch {
    $summary.errors += "ERROR with the game backup: $($_.Exception.Message)"
    if ($UseGameBackup.Trim().ToLower() -eq "interactive") { Write-Host ""; Write-Host "Nothing was changed: $($_.Exception.Message)" }
  }
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}

# Restore-only mode: when called with -RestoreModName and -RestoreBackupFile, just restore and exit.
if ($RestoreModName -ne "" -and $RestoreBackupFile -ne "") {
  try {
    Restore-ModBackup $RestoreModName $RestoreBackupFile
    Set-PinVersion $RestoreModName $script:lastRestoreFromIdent "manual"
    $summary.skipped_mods += "Restored $RestoreModName from $RestoreBackupFile"
  } catch {
    $summary.errors += "ERROR restoring ${RestoreModName}: $($_.Exception.Message)"
  }
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}


function Run-Git([string]$folderPath, [string[]]$gitArgs) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $swGit = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $out = & git -C $folderPath @gitArgs 2>&1
    $code = $LASTEXITCODE
    return @{ out = $out; code = $code }
  } finally {
    $ErrorActionPreference = $old
    try { $script:gitSecTotal += $swGit.Elapsed.TotalSeconds; $script:gitCalls++; if ($gitArgs.Count -gt 0 -and (($gitArgs -contains "fetch") -or ($gitArgs[0] -in @("pull","ls-remote","clone")))) { $script:gitNetSec += $swGit.Elapsed.TotalSeconds } } catch {}
  }
}

function Short-Out($out) {
  if (-not $out) { return "" }
  $s = ($out | Select-Object -First 4) -join " "
  return ($s -replace "\s+", " ").Trim()
}

function Get-UnmergedFiles([string]$folderPath) {
  $r = Run-Git $folderPath @("diff","--name-only","--diff-filter=U")
  if ($r.code -ne 0 -or -not $r.out) { return @() }
  return @($r.out | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne "" })
}

# Reads an optional update.json inside a git mod. Supported keys for git mods:
#   "provider": "git"            (optional, just documents intent)
#   "branch":   "stable"         follow this branch instead of whatever is checked out
# If update.json says provider "github" or "nexus", that wins over git (see Update-OneMod).
function Get-ModUpdateJson([string]$folderPath) {
  $p = Join-Path $folderPath "update.json"
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  return (Read-JsonIfExists $p)
}

# When the updater is itself a git clone, a pull can replace config.lua with the repo's blank defaults (or stash it
# as a "local edit"). Save the settings/key files first and put them back afterwards.
function Update-GitMod([string]$folderPath, [string]$folderName) {
  if (-not (Test-IsSelfFolder $folderPath)) { return (Update-GitModCore $folderPath $folderName) }
  $keepTmp = Join-Path ([IO.Path]::GetTempPath()) ("amu_selfkeep_" + [Guid]::NewGuid().ToString("N"))
  Ensure-Dir $keepTmp
  foreach ($n in $script:SelfKeepNames) {
    $src = Join-Path $folderPath $n
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $keepTmp $n) -Recurse -Force }
  }
  try {
    return (Update-GitModCore $folderPath $folderName)
  } finally {
    foreach ($n in $script:SelfKeepNames) {
      $k = Join-Path $keepTmp $n
      if (Test-Path -LiteralPath $k) {
        $dst = Join-Path $folderPath $n
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $k -Destination $dst -Recurse -Force
      }
    }
    Remove-Item -LiteralPath $keepTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Update-GitModCore([string]$folderPath, [string]$folderName) {
  if (-not $config.update_git) { return $false }
  $gitDir = Join-Path $folderPath ".git"
  if (-not (Test-Path -LiteralPath $gitDir)) { return $false }

  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { $summary.skipped_mods += "$folderName (git: no git in PATH)"; return $true }

  $uj = Get-ModUpdateJson $folderPath
  $wantBranch = if ($uj -and $uj.branch) { ([string]$uj.branch).Trim() } else { "" }

  # If a backup was restored while the mod was pinned, reset the working tree
  # to match HEAD so the updater can properly compare and pull new changes.
  $markerPath = Join-Path $folderPath ".amu_restored_backup"
  $wasRestored = Test-Path -LiteralPath $markerPath
  if ($wasRestored) {
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    try {
      Run-Git $folderPath @("checkout","--",".") | Out-Null
      Run-Git $folderPath @("clean","-fd") | Out-Null
    } catch {
      $summary.errors += "Failed to reset working tree for ${folderName} after backup restore: $($_.Exception.Message)"
    }
  }

  try {
    # Repair a mod left half-merged by an earlier run (conflict markers like <<<<<<< break mods).
    $leftover = Get-UnmergedFiles $folderPath
    if ($leftover.Count -gt 0) {
      [void](Backup-Folder $folderPath "$folderName-conflicted")
      Run-Git $folderPath @("rebase","--abort") | Out-Null
      Run-Git $folderPath @("merge","--abort") | Out-Null
      Run-Git $folderPath @("reset","--hard","HEAD") | Out-Null
      $summary.skipped_mods += "$folderName (git: repaired leftover merge conflict in $($leftover -join ', '); your old edits are still in 'git stash list')"
    }

    $fetch = Run-Git $folderPath @("fetch","--all","--prune")
    if ($fetch.code -ne 0) {
      $summary.errors += "ERROR updating (git) ${folderName}: fetch failed ($($fetch.code)) " + (Short-Out $fetch.out)
      return $true
    }

    $localRes = Run-Git $folderPath @("rev-parse","HEAD")
    if ($localRes.code -ne 0) {
      $summary.errors += "ERROR updating (git) ${folderName}: rev-parse HEAD failed ($($localRes.code)) " + (Short-Out $localRes.out)
      return $true
    }
    $local = ($localRes.out | Select-Object -First 1).Trim()

    # Branch override from update.json (e.g. JokerDisplay must follow "stable", not "main").
    $switchedBranch = $false
    if ($wantBranch -ne "") {
      $curRes = Run-Git $folderPath @("rev-parse","--abbrev-ref","HEAD")
      $cur = if ($curRes.code -eq 0) { ($curRes.out | Select-Object -First 1).Trim() } else { "" }
      if ($cur -ne $wantBranch) {
        $exists = Run-Git $folderPath @("rev-parse","--verify","--quiet","refs/remotes/origin/$wantBranch")
        if ($exists.code -ne 0) {
          $summary.errors += "ERROR updating (git) ${folderName}: update.json asks for branch '$wantBranch' but origin has no such branch"
          return $true
        }
        $bk = Backup-Folder $folderPath $folderName
        $co = Run-Git $folderPath @("checkout","-f","-B",$wantBranch,"--track","origin/$wantBranch")
        if ($co.code -ne 0) {
          $summary.errors += "ERROR updating (git) ${folderName}: couldn't switch to branch '$wantBranch' " + (Short-Out $co.out)
          return $true
        }
        $switchedBranch = $true
        $newHead = ((Run-Git $folderPath @("rev-parse","HEAD")).out | Select-Object -First 1).Trim()
        $summary.updated_mods += "$folderName (switched to branch $wantBranch)"
        $recentlyUpdatedEntries.Add(@{ mod_name = $folderName; backup_file = if ($bk) { $bk } else { "" }; updated_to_version = $newHead; updated_at = (Get-Date).ToString("o") })
        return $true
      }
    }

    $upRes = Run-Git $folderPath @("rev-parse","@{u}")
    if ($upRes.code -ne 0) {
      # No tracking branch (e.g. detached HEAD or a manual clone). Track origin's default branch.
      $def = Get-GitDefaultBranch $folderPath
      $hasDef = Run-Git $folderPath @("rev-parse","--verify","--quiet","refs/remotes/origin/$def")
      if ($hasDef.code -ne 0) {
        $summary.skipped_mods += "$folderName (git: no upstream tracking branch)"
        return $true
      }
      $cur = ((Run-Git $folderPath @("rev-parse","--abbrev-ref","HEAD")).out | Select-Object -First 1).Trim()
      if ($cur -eq "HEAD") {
        $summary.skipped_mods += "$folderName (git: detached HEAD - add update.json with `"branch`" to follow a branch)"
        return $true
      }
      Run-Git $folderPath @("branch","--set-upstream-to=origin/$def") | Out-Null
      $upRes = Run-Git $folderPath @("rev-parse","@{u}")
      if ($upRes.code -ne 0) {
        $summary.skipped_mods += "$folderName (git: no upstream tracking branch)"
        return $true
      }
    }
    $upstream = ($upRes.out | Select-Object -First 1).Trim()

    if ($local -eq $upstream) {
      if ($wasRestored) { $summary.updated_mods += $folderName }
      return $true
    }

    # Already contains upstream (local is ahead, e.g. your own unpushed commits): nothing to pull.
    $isAhead = Run-Git $folderPath @("merge-base","--is-ancestor",$upstream,"HEAD")
    if ($isAhead.code -eq 0) {
      $summary.skipped_mods += "$folderName (git: local is ahead of upstream, nothing to pull)"
      return $true
    }

    $bkFile = Backup-Folder $folderPath $folderName
    $oldHead = $local

    # Local edits: git's --autostash handles both modes. If re-applying them conflicts we
    # throw the edits back into the stash (never leave <<<<<<< markers in a mod).
    $pullArgs = @("pull","--autostash")
    if ($config.git_pull_mode -and [string]$config.git_pull_mode -eq "rebase") {
      $pullArgs += @("--rebase")
    } else {
      $pullArgs += @("--ff-only")
    }
    $pull = Run-Git $folderPath $pullArgs

    # Untracked local files that upstream now ships (e.g. release-notes/v5.0.1.md made by hand, then
    # committed upstream): git refuses to pull. Stash just those files (recoverable) and retry once.
    if ($pull.code -ne 0 -and ([string]($pull.out -join "`n")) -match "untracked working tree files would be overwritten") {
      $txt = [string]($pull.out -join "`n")
      $m = [regex]::Match($txt, "(?s)overwritten by (?:merge|checkout):\s*(.*?)\s*(?:Please move|Aborting|$)")
      $paths = @()
      if ($m.Success) { $paths = @($m.Groups[1].Value -split "[\r\n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch "^(error|warning):" }) }
      if ($paths.Count -gt 0) {
        $st = Run-Git $folderPath (@("stash","push","-u","-q","-m","amu: untracked files that upstream now ships","--") + $paths)
        if ($st.code -eq 0) {
          $pull = Run-Git $folderPath $pullArgs
          if ($pull.code -eq 0) { $summary.skipped_mods += "$folderName (git: moved your untracked $($paths -join ', ') aside because upstream now ships it; saved in 'git stash list')" }
        }
      }
    }

    $conflicts = Get-UnmergedFiles $folderPath
    if ($conflicts.Count -gt 0) {
      Run-Git $folderPath @("rebase","--abort") | Out-Null
      # After --abort the tree is back to the old commit; move to upstream cleanly.
      Run-Git $folderPath @("stash","push","-q","-m","amu: local edits that conflicted with update") | Out-Null
      Run-Git $folderPath @("reset","--hard",$upstream) | Out-Null
      $summary.skipped_mods += "$folderName (git: your local edits conflicted with the update; update applied, edits saved in 'git stash list')"
      $pull = @{ code = 0; out = $null }
    }

    if ($pull.code -ne 0) {
      # Most common cause: the author force-pushed / rewrote history.
      $diverged = Run-Git $folderPath @("merge-base","--is-ancestor","HEAD",$upstream)
      if ($diverged.code -ne 0 -and $config.git_reset_on_diverge) {
        Run-Git $folderPath @("stash","push","-q","-m","amu: local edits before diverge reset") | Out-Null
        $rs = Run-Git $folderPath @("reset","--hard",$upstream)
        if ($rs.code -eq 0) {
          $summary.skipped_mods += "$folderName (git: upstream history was rewritten; reset to upstream, backup $bkFile)"
          $pull = @{ code = 0; out = $null }
        }
      }
      if ($pull.code -ne 0) {
        $hint = if ($diverged.code -ne 0) { " (history diverged from upstream - set git_reset_on_diverge=true in autoupdater_config.json to auto-fix)" } else { "" }
        $summary.errors += "ERROR updating (git) ${folderName}: pull failed ($($pull.code)) [mode=$($config.git_pull_mode)]$hint " + (Short-Out $pull.out)
        return $true
      }
    }

    $newHeadRes = Run-Git $folderPath @("rev-parse","HEAD")
    if ($newHeadRes.code -ne 0) {
      $summary.updated_mods += $folderName
      $recentlyUpdatedEntries.Add(@{ mod_name = $folderName; backup_file = if ($bkFile) { $bkFile } else { "" }; updated_to_version = ""; updated_at = (Get-Date).ToString("o") })
      return $true
    }
    $newHead = ($newHeadRes.out | Select-Object -First 1).Trim()

    if ($newHead -and $newHead -ne $oldHead) {
      $summary.updated_mods += $folderName
      $recentlyUpdatedEntries.Add(@{ mod_name = $folderName; backup_file = if ($bkFile) { $bkFile } else { "" }; updated_to_version = $newHead; updated_at = (Get-Date).ToString("o") })
    } else {
      $summary.skipped_mods += "$folderName (git: no changes applied)"
    }
  } catch {
    $summary.errors += "ERROR updating (git) ${folderName}: $($_.Exception.Message)"
  }
  return $true
}

# Downloads a zip and replaces the mod folder's contents with it.
# update.json and .autoupdater_state.json are kept. If copying fails, the backup is restored.
function Install-ZipIntoMod([string]$folderPath, [string]$folderName, [string]$url, [hashtable]$headers, [bool]$stripTop, [string]$bkFile) {
  $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("balatro_modupd_" + [Guid]::NewGuid().ToString("N"))
  Ensure-Dir $tmpRoot
  try {
    $zipPath = Join-Path $tmpRoot "download.zip"
    $extractPath = Join-Path $tmpRoot "extract"
    Ensure-Dir $extractPath

    Invoke-WebRequest -Uri $url -OutFile $zipPath -Headers $headers -UseBasicParsing | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

    $children = @(Get-ChildItem -LiteralPath $extractPath -Force)
    if ($children.Count -eq 0) { throw "Downloaded archive was empty." }
    $srcRoot = $extractPath
    if ($stripTop) {
      $dirs = @($children | Where-Object { $_.PSIsContainer })
      if ($dirs.Count -eq 1 -and $children.Count -eq 1) { $srcRoot = $dirs[0].FullName }
    }

    $preserve = @("update.json", ".autoupdater_state.json")
    # When the updater updates ITSELF, also keep its settings, API keys and per-user data.
    if (Test-IsSelfFolder $folderPath) { $preserve = @($script:SelfKeepNames) }
    $preserveTemp = Join-Path $tmpRoot "preserve"
    Ensure-Dir $preserveTemp
    foreach ($p in $preserve) {
      $pp = Join-Path $folderPath $p
      if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $preserveTemp $p) -Recurse -Force }
    }

    try {
      Get-ChildItem -LiteralPath $folderPath -Force | ForEach-Object {
        if ($preserve -contains $_.Name) { return }
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
      }
      Copy-Item -Path (Join-Path $srcRoot "*") -Destination $folderPath -Recurse -Force
    } catch {
      $msg = $_.Exception.Message
      if ($bkFile) {
        try {
          Expand-Archive -LiteralPath (Join-Path $backupRoot $bkFile) -DestinationPath $folderPath -Force
          throw "Install failed ($msg); restored the previous version from backup."
        } catch { throw $_ }
      }
      throw "Install failed ($msg) and no backup was available."
    }

    foreach ($p in $preserve) {
      $pp = Join-Path $preserveTemp $p
      if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $folderPath $p) -Recurse -Force }
    }
  } finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# GitHub provider. update.json keys:
#   "repo":  "Owner/Repo"                      (required)
#   "track": "auto" | "release" | "branch"     (default "auto")
#       auto    = use releases if the repo has any, otherwise follow the newest commit
#       release = only releases (error if none)
#       branch  = always follow the newest commit on "branch" (or the default branch)
#   "branch": "main"                            (branch to follow in branch mode)
#   "include_prereleases": false                (also accept pre-releases)
#   "asset_regex": ".*\.zip$"                   (which release asset to use; falls back to the source zip)
#   "strip_single_top_folder": true
function Update-GitHubReleaseMod([string]$folderPath, [string]$folderName, $uj) {
  $statePath = Join-Path $folderPath ".autoupdater_state.json"
  $state = Read-JsonIfExists $statePath
  $repo = ([string]$uj.repo).Trim()
  $track = if ($uj.track) { ([string]$uj.track).ToLower() } else { "auto" }
  $gh = Get-GhHeaders
  $stripTop = ($uj.strip_single_top_folder -ne $false)

  $rel = $null
  if ($track -ne "branch") {
    try {
      if ($uj.include_prereleases -eq $true) {
        $list = @(Get-GhJson "https://api.github.com/repos/$repo/releases?per_page=10" $gh)
        $rel = $list | Where-Object { -not $_.draft } | Select-Object -First 1
      } else {
        $rel = Get-GhJson "https://api.github.com/repos/$repo/releases/latest" $gh
      }
    } catch {
      $code = Get-HttpStatus $_
      if ($code -eq 404) { $rel = $null }      # repo has no (non-pre) releases
      elseif ($code -eq 403 -or $code -eq 429) { throw "GitHub API rate limit hit. Add a github_token to autoupdater_config.json." }
      else { throw }
    }
    if (-not $rel -and $track -eq "release") { throw "Repo $repo has no releases (set `"track`": `"auto`" to follow commits instead)." }
  }

  if ($rel) {
    # ---------- Release mode ----------
    $tag = [string]$rel.tag_name
    if (-not $tag) { throw "GitHub release missing tag_name" }
    $installedTag = if ($state -and $state.tag) { [string]$state.tag } else { "" }
    if ($installedTag -eq $tag) { return $true }

    $assetRegex = if ($uj.asset_regex) { [string]$uj.asset_regex } else { ".*\.zip$" }
    $dl = $null
    foreach ($a in $rel.assets) { if ($a.name -match $assetRegex) { $dl = [string]$a.browser_download_url; break } }
    if (-not $dl) {
      # Many mods publish releases with no uploaded zip - use the release's source code zip.
      $dl = "https://github.com/$repo/archive/refs/tags/$tag.zip"
    }

    $bkFile = Backup-Folder $folderPath $folderName
    Install-ZipIntoMod $folderPath $folderName $dl @{ "User-Agent"="BalatroModUpdater" } $stripTop $bkFile

    Save-JsonNoBom $statePath @{ provider="github"; track="release"; tag=$tag; repo=$repo; updated_at=(Get-Date).ToString("o") }
    $script:releaseNotes[$folderName] = @{ tag = $tag; notes = @(Split-ReleaseNotes ([string]$rel.body)) }
    $summary.updated_mods += "$folderName ($tag)"
    $recentlyUpdatedEntries.Add(@{ mod_name = $folderName; backup_file = if ($bkFile) { $bkFile } else { "" }; updated_to_version = $tag; updated_at = (Get-Date).ToString("o") })
    return $true
  }

  # ---------- Branch / commit mode ----------
  $branch = if ($uj.branch) { [string]$uj.branch } else { "" }
  if ($branch -eq "") {
    $info = Get-GhJson "https://api.github.com/repos/$repo" $gh
    $branch = [string]$info.default_branch
    if (-not $branch) { $branch = "main" }
  }
  $commit = Get-GhJson "https://api.github.com/repos/$repo/commits/$branch" $gh
  $sha = [string]$commit.sha
  if (-not $sha) { throw "Couldn't read the latest commit of $repo@$branch" }
  $installedSha = if ($state -and $state.commit) { [string]$state.commit } else { "" }
  if ($installedSha -eq $sha) { return $true }

  $bkFile = Backup-Folder $folderPath $folderName
  Install-ZipIntoMod $folderPath $folderName "https://github.com/$repo/archive/$sha.zip" @{ "User-Agent"="BalatroModUpdater" } $stripTop $bkFile

  Save-JsonNoBom $statePath @{ provider="github"; track="branch"; branch=$branch; commit=$sha; repo=$repo; updated_at=(Get-Date).ToString("o") }
  $short = $sha.Substring(0, [Math]::Min(7, $sha.Length))
  $commitMsg = ""
  try { $commitMsg = ([string]$commit.commit.message -split "\r?\n")[0] } catch {}
  $script:releaseNotes[$folderName] = @{ tag = "$branch@$short"; notes = @(Split-ReleaseNotes $commitMsg 1) }
  $summary.updated_mods += "$folderName ($branch@$short)"
  $recentlyUpdatedEntries.Add(@{ mod_name = $folderName; backup_file = if ($bkFile) { $bkFile } else { "" }; updated_to_version = $sha; updated_at = (Get-Date).ToString("o") })
  return $true
}

function Invoke-Nexus([string]$url) {
  if (-not $config.nexus_api_key -or $config.nexus_api_key.Trim() -eq "") {
    throw "Nexus API key not set in autoupdater_config.json (nexus_api_key)."
  }
  return Invoke-RestMethod -Uri $url -Headers @{ "apikey"=$config.nexus_api_key; "accept"="application/json"; "User-Agent"="BalatroModUpdater" }
}

# Nexus provider. update.json keys:
#   "mod_id": 123                  (required)
#   "game_domain": "balatro"       (optional)
#   "file_name_regex": "..."       (optional: pick a specific file when a mod has several MAIN files)
# Only MAIN files are considered (old/optional/archived files are ignored), newest upload wins.
# Nexus only lets Premium accounts download through the API. For free accounts we report
# "update available" with a link instead of failing.
function Update-NexusMod([string]$folderPath, [string]$folderName, $uj) {
  $domain = if ($uj.game_domain) { [string]$uj.game_domain } elseif ($config.nexus_game_domain) { [string]$config.nexus_game_domain } else { "balatro" }
  $modId = [int]$uj.mod_id
  if (-not $modId) { throw "update.json provider=nexus missing mod_id" }

  $statePath = Join-Path $folderPath ".autoupdater_state.json"
  $state = Read-JsonIfExists $statePath
  $installedFileId = if ($state -and $state.file_id) { [int]$state.file_id } else { 0 }

  $latest = Get-NexusLatestFile $domain $modId $uj

  $latestFileId = [int]$latest.file_id
  if ($installedFileId -eq $latestFileId) { return $true }
  $verLabel = if ($latest.version) { [string]$latest.version } else { [string]$latestFileId }

  $dl = $null
  try {
    $dl = Invoke-Nexus "https://api.nexusmods.com/v1/games/$domain/mods/$modId/files/$latestFileId/download_link.json"
  } catch {
    $code = Get-HttpStatus $_
    if ($code -eq 403) {
      $page = "https://www.nexusmods.com/$domain/mods/$modId" + "?tab=files"
      $summary.available_updates += "$folderName -> $verLabel (Nexus needs Premium for auto-download; get it at $page)"
      return $true
    }
    throw
  }
  if (-not $dl -or $dl.Count -lt 1 -or -not $dl[0].URI) { throw "Nexus download_link.json returned no usable URI." }
  $uri = [string]$dl[0].URI

  $bkFile = Backup-Folder $folderPath $folderName
  Install-ZipIntoMod $folderPath $folderName $uri @{ "User-Agent"="BalatroModUpdater" } $true $bkFile

  Save-JsonNoBom $statePath @{ provider="nexus"; game_domain=$domain; mod_id=$modId; file_id=$latestFileId; version=$verLabel; updated_at=(Get-Date).ToString("o") }
  $summary.updated_mods += "$folderName ($verLabel)"
  $recentlyUpdatedEntries.Add(@{ mod_name = $folderName; backup_file = if ($bkFile) { $bkFile } else { "" }; updated_to_version = [string]$latestFileId; updated_at = (Get-Date).ToString("o") })
  return $true
}

function Update-UpdateJsonMod([string]$folderPath, [string]$folderName) {
  if (-not $config.update_updatejson) { return $false }
  $updateJsonPath = Join-Path $folderPath "update.json"
  if (-not (Test-Path -LiteralPath $updateJsonPath)) { return $false }
  $uj = Read-JsonIfExists $updateJsonPath
  if (-not $uj) { $summary.skipped_mods += "$folderName (bad update.json - must be plain JSON, no comment text)"; return $true }

  $provider = ([string]$uj.provider).ToLower()
  try {
    if ($provider -eq "nexus") {
      [void](Update-NexusMod $folderPath $folderName $uj); return $true
    } elseif ($provider -eq "github") {
      if (-not $uj.repo) { throw "update.json provider=github missing repo" }
      [void](Update-GitHubReleaseMod $folderPath $folderName $uj); return $true
    } elseif ($provider -eq "git" -or $provider -eq "") {
      return $false
    } else {
      $summary.skipped_mods += "$folderName (unknown provider '$provider')"; return $true
    }
  } catch {
    $summary.errors += "ERROR updating (${provider}) ${folderName}: $($_.Exception.Message)"
    return $true
  }
}

# Latest MAIN file of a Nexus mod (shared by the updater and the pin check).
function Get-NexusLatestFile([string]$domain, [int]$modId, $uj) {
  $files = Invoke-Nexus "https://api.nexusmods.com/v1/games/$domain/mods/$modId/files.json"
  if (-not $files -or -not $files.files) { throw "Nexus files.json response missing 'files'." }
  $candidates = @($files.files | Where-Object { [string]$_.category_name -eq "MAIN" -or [int]$_.category_id -eq 1 })
  if ($candidates.Count -eq 0) {
    $candidates = @($files.files | Where-Object { @("OLD_VERSION","ARCHIVED","DELETED","REMOVED") -notcontains [string]$_.category_name })
  }
  if ($uj -and $uj.file_name_regex) {
    $rx = [string]$uj.file_name_regex
    $candidates = @($candidates | Where-Object { ([string]$_.name -match $rx) -or ([string]$_.file_name -match $rx) })
  }
  $latest = $candidates | Sort-Object -Property @{ Expression = { [long]$_.uploaded_timestamp } }, @{ Expression = { [long]$_.file_id } } | Select-Object -Last 1
  if (-not $latest) { throw "No MAIN files found on Nexus for $domain/$modId." }
  return $latest
}

# What does a pinned mod's source serve right now, if it is not the version that was put back? Returns that version in the
# same form the updater records it (tag, commit sha or Nexus file id), or "" when there is nothing different.
# Always the LATEST the source has: the update that follows a released pin goes straight there, never to "the next one".
function Get-PinnedNewerVersion([string]$folderPath, [string]$folderName, [string]$fromVer) {
  $uj = Get-ModUpdateJson $folderPath
  $prov = if ($uj -and $uj.provider) { ([string]$uj.provider).ToLower() } else { "" }

  if ($prov -eq "github" -and $uj.repo) {
    $repo = ([string]$uj.repo).Trim()
    $track = if ($uj.track) { ([string]$uj.track).ToLower() } else { "auto" }
    $gh = Get-GhHeaders
    $latest = ""
    if ($track -ne "branch") {
      try {
        if ($uj.include_prereleases -eq $true) {
          $list = @(Get-GhJson "https://api.github.com/repos/$repo/releases?per_page=10" $gh)
          $rel = $list | Where-Object { -not $_.draft } | Select-Object -First 1
        } else {
          $rel = Get-GhJson "https://api.github.com/repos/$repo/releases/latest" $gh
        }
        if ($rel) { $latest = [string]$rel.tag_name }
      } catch {
        $code = Get-HttpStatus $_
        if ($code -ne 404) { throw }
      }
    }
    if (-not $latest) {
      $branch = if ($uj.branch) { [string]$uj.branch } else { "" }
      if ($branch -eq "") {
        $info = Get-GhJson "https://api.github.com/repos/$repo" $gh
        $branch = [string]$info.default_branch
        if (-not $branch) { $branch = "main" }
      }
      $commit = Get-GhJson "https://api.github.com/repos/$repo/commits/$branch" $gh
      $latest = [string]$commit.sha
    }
    if ($latest -and $latest -ne $fromVer) { return $latest }
    return ""
  }

  if ($prov -eq "nexus") {
    $domain = if ($uj.game_domain) { [string]$uj.game_domain } elseif ($config.nexus_game_domain) { [string]$config.nexus_game_domain } else { "balatro" }
    $modId = [int]$uj.mod_id
    if (-not $modId) { return "" }
    $latest = Get-NexusLatestFile $domain $modId $uj
    $id = [string]([int]$latest.file_id)
    if ($id -ne $fromVer) { return $id }
    return ""
  }

  if (Test-Path -LiteralPath (Join-Path $folderPath ".git")) {
    $fetch = Run-Git $folderPath @("fetch","--all","--prune")
    if ($fetch.code -ne 0) { throw "fetch failed (" + (Short-Out $fetch.out) + ")" }
    $wantBranch = if ($uj -and $uj.branch) { ([string]$uj.branch).Trim() } else { "" }
    $upRes = $null
    if ($wantBranch -ne "") { $upRes = Run-Git $folderPath @("rev-parse","origin/$wantBranch") } else { $upRes = Run-Git $folderPath @("rev-parse","@{u}") }
    if ($upRes.code -ne 0) {
      $def = Get-GitDefaultBranch $folderPath
      $upRes = Run-Git $folderPath @("rev-parse","origin/$def")
    }
    if ($upRes.code -ne 0) { return "" }
    $upstream = ($upRes.out | Select-Object -First 1).ToString().Trim()
    if ($upstream -eq $fromVer) { return "" }
    # the source being merely BEHIND the version that was put back (for example your own unpushed commits) is not newer
    $anc = Run-Git $folderPath @("merge-base","--is-ancestor",$upstream,$fromVer)
    if ($anc.code -eq 0) { return "" }
    return $upstream
  }
  return ""
}

function Remove-ModPinFromConfig([string]$name) {
  try {
    if ($config.pinned_mods -is [System.Collections.IDictionary]) { $config.pinned_mods.Remove($name) }
    elseif ($config.pinned_mods) { $config.pinned_mods.PSObject.Properties.Remove($name) }
  } catch {}
}

# Decide what to do with one pinned mod: stay pinned (with a note saying why) or release the pin.
function Invoke-PinRetryCheck([string]$path, [string]$name) {
  $res = @{ release = $false; note = "$name (pinned at backup)"; from = ""; to = "" }
  $from = ""
  try {
    $pv = Get-PinVersions
    if ($pv.ContainsKey($name) -and $pv[$name].from_version) { $from = [string]$pv[$name].from_version }
    if (-not $from -and $config.pinned_mods -and $config.pinned_mods.$name -and $config.pinned_mods.$name.crashed_version) { $from = [string]$config.pinned_mods.$name.crashed_version }
  } catch {}
  if (-not $from) {
    $res.note = "$name (pinned at backup; the version it went back from isn't recorded, so it can't tell when a newer one appears)"
    return $res
  }
  $newer = ""
  try { $newer = Get-PinnedNewerVersion $path $name $from } catch {
    $res.note = "$name (pinned at backup; couldn't check for a newer version: " + (Short-Out @($_.Exception.Message)) + ")"
    return $res
  }
  if (-not $newer) {
    $res.note = "$name (pinned at backup; no version newer than " + (Format-ShortVersion $from) + " yet)"
    return $res
  }
  if ($config.pin_retry_newer -eq $false) {
    $res.note = "$name (pinned - newer version " + (Format-ShortVersion $newer) + " is available; automatic retry is off)"
    return $res
  }
  $res.release = $true; $res.from = $from; $res.to = $newer
  $res.note = "$name (pin released: " + (Format-ShortVersion $newer) + " is newer than " + (Format-ShortVersion $from) + ", the version that was put back; updating to the latest)"
  return $res
}

# Decides how one mod folder is updated:
#   1) update.json with provider github/nexus  -> that source (explicit choice wins, even in a git folder)
#   2) a .git folder                            -> git pull (update.json "branch" can pick the branch)
#   3) nothing                                  -> reported as untracked
function Update-OneMod([string]$path, [string]$name) {
  $uj = Get-ModUpdateJson $path
  $prov = if ($uj -and $uj.provider) { ([string]$uj.provider).ToLower() } else { "" }
  if ($prov -eq "github" -or $prov -eq "nexus") {
    [void](Update-UpdateJsonMod $path $name)
    return
  }
  $handled = (Update-GitMod $path $name)
  if (-not $handled) { $handled = (Update-UpdateJsonMod $path $name) }
  if (-not $handled -and $config.report_untracked -ne $false) {
    $hasLua = @(Get-ChildItem -LiteralPath $path -Filter "*.lua" -File -ErrorAction SilentlyContinue).Count -gt 0
    $hasToml = (Test-Path -LiteralPath (Join-Path $path "lovely.toml")) -or (Test-Path -LiteralPath (Join-Path $path "lovely"))
    if ($hasLua -or $hasToml) {
      $summary.untracked_mods += $name
    }
  }
}

# ---- Fork Discovery & Switching ----

function Get-GitHubRepoForMod([string]$folderPath) {
  $gitDir = Join-Path $folderPath ".git"
  if (Test-Path -LiteralPath $gitDir) {
    $remoteRes = Run-Git $folderPath @("remote", "get-url", "origin")
    if ($remoteRes.code -eq 0) {
      $url = ($remoteRes.out | Select-Object -First 1).Trim()
      if ($url -match "github\.com[:/](.+?/[^./]+?)(\.git)?$") {
        return $Matches[1]
      }
    }
  }
  $ujPath = Join-Path $folderPath "update.json"
  if (Test-Path -LiteralPath $ujPath) {
    $uj = Read-JsonIfExists $ujPath
    if ($uj -and [string]$uj.provider -eq "github" -and $uj.repo) {
      return [string]$uj.repo
    }
  }
  return $null
}

function Get-GitDefaultBranch([string]$folderPath) {
  $branchRes = Run-Git $folderPath @("symbolic-ref", "refs/remotes/origin/HEAD")
  if ($branchRes.code -eq 0) {
    $ref = ($branchRes.out | Select-Object -First 1).Trim()
    if ($ref -match "refs/remotes/origin/(.+)$") { return $Matches[1] }
  }
  return "main"
}

# Files that look like translation work. The Fork Finder uses this to tell "just a translation" forks apart.
$script:TranslationFileRegex = '(?i)(^|/)(localization|localisation|locales?|lang|languages?|i18n|translations?)/(?!en[-_./])|(^|/)(es|fr|de|it|pt|ru|ja|ko|zh|pl|tr|nl|id|vi|ar|uk|cs|hu|sv|fi|th|ro)([_-][a-z]{2,4})?\.(lua|json|toml)$'

function Register-ForkError($err, [string]$what) {
  $st = Get-HttpStatus $err
  if ($st -eq 403 -or $st -eq 429) { $script:forkRateLimited = $true }
  elseif ($st -eq 401) { $script:forkBadToken = $true }
  else { $summary.errors += "Fork scan: error ${what}: $($err.Exception.Message)" }
}

function Format-ForkDate($d) {
  if ($d -is [datetime]) { return $d.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
  return [string]$d
}

# Compares one repo ($info = its GitHub API object) against the copy the user has installed.
# Returns $null when it has nothing new to offer, otherwise one entry for fork_suggestions.json.
#   kind: original | parent | parent_fork | fork_fork | fork
function New-ForkEntry([string]$kind, $info, [string]$installedRepo, [string]$installedBranch, $headers) {
  $owner  = [string]$info.owner.login
  $branch = if ($info.default_branch) { [string]$info.default_branch } else { "main" }
  $full   = "$owner/$($info.name)"

  # Same fork, same push, same installed copy as the last scan: the comparison cannot have changed, so reuse it.
  # (Only the latest release tag is asked again, since publishing a release does not change the push time.)
  $entryFile = $null
  if ($config.use_github_cache -ne $false -and $script:forkInstPushed -and $info.pushed_at) {
    $ekey = "forkentry3|$kind|$installedRepo|$installedBranch|$($script:forkInstPushed)|$full|$(Format-ForkDate $info.pushed_at)"
    $entryFile = Join-Path $script:ghCacheDir ("fe_" + (Get-GhCacheKey $ekey) + ".json")
    $prev = Read-JsonIfExists $entryFile
    if ($prev) {
      $script:forkEntryReused++
      try { [System.IO.File]::SetLastWriteTime($entryFile, (Get-Date)) } catch {}
      if ($prev.none) { return $null }
      try {
        $relNow = Get-GhJson "https://api.github.com/repos/$full/releases/latest" $headers
        $prev.latest_release_tag   = if ($relNow.tag_name) { [string]$relNow.tag_name } else { "" }
        $prev | Add-Member -NotePropertyName latest_release_at -NotePropertyValue $(if ($relNow.published_at) { Format-ForkDate $relNow.published_at } else { "" }) -Force
        $prev.latest_release_notes = if ($relNow.body)     { [string]$relNow.body     } else { "" }
      } catch {}
      return $prev
    }
  }
  $script:forkEntryBuilt++

  # A 404 here means "No common ancestor": that repo and the installed copy have unrelated histories (one was re-created or its
  # history rewritten), so there is nothing to compare. That is not a scan error: skip it quietly.
  try {
    $compare = Get-GhJson "https://api.github.com/repos/$installedRepo/compare/${installedBranch}...${owner}:${branch}" $headers
  } catch {
    if ((Get-HttpStatus $_) -eq 404) { $script:forkUnrelated++; return $null }
    throw
  }
  $ahead   = if ($compare.ahead_by)  { [int]$compare.ahead_by  } else { 0 }
  $behind  = if ($compare.behind_by) { [int]$compare.behind_by } else { 0 }
  if ($ahead -eq 0) {
    if ($entryFile) {
      try {
        if (-not (Test-Path -LiteralPath $script:ghCacheDir)) { New-Item -ItemType Directory -Path $script:ghCacheDir -Force | Out-Null }
        Save-JsonNoBom $entryFile @{ none = $true }
      } catch {}
    }
    return $null
  }

  # Newest commit messages first (the compare API lists oldest first), first line only, up to 20.
  $changelog = @()
  $lastCommitAt = ""
  if ($compare.commits) {
    $commits = @($compare.commits)
    # Date of the newest commit the fork has that the installed copy lacks (the repo's push date also moves for syncs and other
    # branches, so it can look newer than the code is). Only trusted when the compare list is complete.
    if ($commits.Count -ge 1 -and [int]$compare.total_commits -le $commits.Count) {
      $newest = $commits[$commits.Count - 1]
      $cd = if ($newest.commit.committer.date) { $newest.commit.committer.date } else { $newest.commit.author.date }
      if ($cd) { $lastCommitAt = Format-ForkDate $cd }
    }
    [array]::Reverse($commits)
    $limit = [Math]::Min($commits.Count, 20)
    for ($i = 0; $i -lt $limit; $i++) {
      $msg = $commits[$i].commit.message
      if ($msg) { $changelog += ($msg -split "`n")[0].Trim() }
    }
  }

  # The day the installed copy's own newest commit was made (the compare answer names the base commit): lets the game say which
  # copy is the most recently changed one.
  $instHeadAt = ""
  try {
    $bc = $compare.base_commit
    if ($bc) {
      $hd = if ($bc.commit.committer.date) { $bc.commit.committer.date } else { $bc.commit.author.date }
      if ($hd) { $instHeadAt = Format-ForkDate $hd }
    }
  } catch {}

  # How much of the change is translation files?
  $filesChanged = 0
  $locFiles     = 0
  if ($compare.files) {
    foreach ($cf in @($compare.files)) {
      $filesChanged++
      if (([string]$cf.filename) -match $script:TranslationFileRegex) { $locFiles++ }
    }
  }

  # Latest GitHub release (best-effort)
  $relTag = ""; $relNotes = ""; $relAt = ""
  try {
    $rel      = Get-GhJson "https://api.github.com/repos/$full/releases/latest" $headers
    $relTag   = if ($rel.tag_name) { [string]$rel.tag_name } else { "" }
    $relNotes = if ($rel.body)     { [string]$rel.body     } else { "" }
    $relAt    = if ($rel.published_at) { Format-ForkDate $rel.published_at } else { "" }
  } catch {}

  $result = @{
    repo                 = $full
    owner                = $owner
    kind                 = $kind
    is_upstream          = ($kind -eq "original")
    pushed_at            = (Format-ForkDate $info.pushed_at)
    last_commit_at       = $lastCommitAt
    stars                = [int]$info.stargazers_count
    commits_ahead        = $ahead
    commits_behind       = $behind
    changelog            = $changelog
    files_changed        = $filesChanged
    loc_files            = $locFiles
    latest_release_tag   = $relTag
    latest_release_notes = $relNotes
    latest_release_at    = $relAt
    installed_head_at    = $instHeadAt
    html_url             = [string]$info.html_url
  }
  if ($entryFile) {
    try {
      if (-not (Test-Path -LiteralPath $script:ghCacheDir)) { New-Item -ItemType Directory -Path $script:ghCacheDir -Force | Out-Null }
      Save-JsonNoBom $entryFile $result
    } catch {}
  }
  return $result
}

# A fork the player ticked "Ignore scans" for: no comparison is made (no API calls, no scan time). Only a stub is kept so the
# game can still list it ("Ignored: Shown") and let the player un-ignore it.
function New-IgnoredForkStub([string]$kind, $info) {
  return @{
    repo                 = [string]$info.full_name
    owner                = [string]$info.owner.login
    kind                 = $kind
    is_upstream          = ($kind -eq "original")
    ignored              = $true
    pushed_at            = (Format-ForkDate $info.pushed_at)
    stars                = [int]$info.stargazers_count
    commits_ahead        = 0
    commits_behind       = 0
    changelog            = @()
    files_changed        = 0
    loc_files            = 0
    latest_release_tag   = ""
    latest_release_notes = ""
    html_url             = [string]$info.html_url
  }
}

function Check-Forks() {
  $ignoreSet = @{}
  foreach ($ig in @($config.fork_ignore)) { if ($ig -is [string] -and $ig.Trim() -ne "") { $ignoreSet[$ig.Trim().ToLower()] = $true } }
  # whole mods the player ignores: never scanned (no GitHub calls), their last results are kept so they can be un-ignored
  $ignoreMods = @{}
  foreach ($ig in @($config.fork_ignore_mods)) { if ($ig -is [string] -and $ig.Trim() -ne "") { $ignoreMods[$ig.Trim().ToLower()] = $true } }
  $prevSug = Read-JsonIfExists $forkSuggestionsPath
  $suggestions = @{
    checked_at  = (Get-Date).ToString("o")
    scan_mode   = $(if ($AllForks) { "all" } else { "newer" })
    suggestions = @{}
  }
  $script:forkRateLimited = $false
  $script:forkBadToken    = $false
  $hasToken = [bool]($config.github_token -and ([string]$config.github_token).Trim() -ne "")

  try {
    $ghHeaders = Get-GhHeaders

    # Validate the token up front (/rate_limit does not count against the limit)
    if ($hasToken) {
      try {
        Invoke-RestMethod -Uri "https://api.github.com/rate_limit" -Headers $ghHeaders -TimeoutSec 20 | Out-Null
      } catch {
        $st = 0
        try { $st = [int]$_.Exception.Response.StatusCode } catch {}
        if ($st -eq 401) { $script:forkBadToken = $true }
      }
    }

    Get-ChildItem -LiteralPath $modsDirResolved -Directory -Force | ForEach-Object {
      $name = $_.Name
      $path = $_.FullName
      if ($script:forkRateLimited -or $script:forkBadToken) { return }
      if ($skipSet.ContainsKey($name)) { return }
      if ($name -eq "_Balatro-Mod-Updater_Backups") { return }
      if ($name -eq "_Balatro-Automatic-Mod-Updater_Backups") { return }
      if ($name -eq "_AutoModUpdater_Backups") { return }
      if ($ignoreMods.ContainsKey($name.ToLower())) {
        try {
          if ($prevSug -and $prevSug.suggestions -and ($prevSug.suggestions.PSObject.Properties.Name -contains $name)) {
            $keepH = @{}
            foreach ($pr in $prevSug.suggestions.$name.PSObject.Properties) { $keepH[$pr.Name] = $pr.Value }
            $keepH["mod_ignored"] = $true
            $suggestions.suggestions[$name] = $keepH
          }
        } catch {}
        return
      }

      $swFork = [System.Diagnostics.Stopwatch]::StartNew()
      $ownerRepo = $null
      try {
        $ownerRepo = Get-GitHubRepoForMod $path
        if (-not $ownerRepo) { return }

        # The copy the user has installed right now. Everything else is compared against it.
        $instInfo        = Get-GhJson "https://api.github.com/repos/$ownerRepo" $ghHeaders
        $script:forkInstPushed = Format-ForkDate $instInfo.pushed_at
        $instPushedDt = $null
        try { if ($instInfo.pushed_at) { $instPushedDt = [datetime]$instInfo.pushed_at } } catch {}
        $installedRepo   = [string]$instInfo.full_name
        $installedBranch = if ($instInfo.default_branch) { [string]$instInfo.default_branch } else { "main" }
        $installedIsFork = [bool]$instInfo.fork

        # Walk up the family tree: installed -> parent (if different) -> original (root of the network)
        $rootInfo   = $instInfo
        $parentInfo = $null
        if ($installedIsFork -and $instInfo.source -and $instInfo.source.full_name) {
          $rootName = [string]$instInfo.source.full_name
          $rootInfo = Get-GhJson "https://api.github.com/repos/$rootName" $ghHeaders
          $parentName = if ($instInfo.parent -and $instInfo.parent.full_name) { [string]$instInfo.parent.full_name } else { $rootName }
          if ($parentName -ne $rootName) {
            $parentInfo = Get-GhJson "https://api.github.com/repos/$parentName" $ghHeaders
          }
        }
        $rootRepo = [string]$rootInfo.full_name

        $staleThreshold = (Get-Date).AddMonths(-$ForkStalenessMonths)
        $activeForks    = @()
        $seen           = @{}
        $seen[$installedRepo.ToLower()] = $true

        # 1) The original and (if there is one in between) the parent: only listed when they are ahead of the installed copy.
        if ($installedIsFork) {
          $seen[$rootRepo.ToLower()] = $true
          try {
            if ($ignoreSet.ContainsKey($rootRepo.ToLower())) { $activeForks += (New-IgnoredForkStub "original" $rootInfo) }
            else {
              $e = New-ForkEntry "original" $rootInfo $installedRepo $installedBranch $ghHeaders
              if ($e) { $activeForks += $e }
            }
          } catch { Register-ForkError $_ "comparing the original of '$name' ($rootRepo)" }
          if ($parentInfo) {
            $seen[([string]$parentInfo.full_name).ToLower()] = $true
            try {
              if ($ignoreSet.ContainsKey(([string]$parentInfo.full_name).ToLower())) { $activeForks += (New-IgnoredForkStub "parent" $parentInfo) }
              else {
                $e = New-ForkEntry "parent" $parentInfo $installedRepo $installedBranch $ghHeaders
                if ($e) { $activeForks += $e }
              }
            } catch { Register-ForkError $_ "comparing the parent of '$name'" }
          }
        }

        # 2) Forks of: the installed copy (fork-forks), then the parent and the original (parent forks).
        $targets = @()
        $targets += @{ info = $instInfo; kind = $(if ($installedIsFork) { "fork_fork" } else { "fork" }) }
        if ($parentInfo)       { $targets += @{ info = $parentInfo; kind = "parent_fork" } }
        if ($installedIsFork)  { $targets += @{ info = $rootInfo;   kind = "parent_fork" } }

        foreach ($t in $targets) {
          if ($script:forkRateLimited -or $script:forkBadToken) { break }
          if (-not $t.info -or [int]$t.info.forks_count -le 0) { continue }
          $tRepo = [string]$t.info.full_name

          $list = $null
          try {
            # sort=pushed is not allowed here (400 Bad Request): fetch 'newest', then rank by last push ourselves.
            $list = Get-GhJson "https://api.github.com/repos/$tRepo/forks?sort=newest&per_page=100" $ghHeaders
          } catch { Register-ForkError $_ "listing forks of $tRepo"; continue }

          # Drop abandoned forks and forks that were never pushed to since being created, newest push first,
          # and only compare the top few so a scan stays inside the GitHub API limit.
          # Newer-only scan (the default): a fork last pushed before the installed copy's last push cannot be newer, so it is not
          # compared. "Show all forks" scan (-AllForks): every fork pushed to since it was created, however old.
          $liveForks = @($list | Where-Object {
              $_.pushed_at -and ([datetime]$_.pushed_at) -gt ([datetime]$_.created_at) -and
              ($AllForks -or (([datetime]$_.pushed_at) -ge $staleThreshold -and (-not $instPushedDt -or ([datetime]$_.pushed_at) -ge $instPushedDt)))
            } | Sort-Object { [datetime]$_.pushed_at } -Descending)
          # forks ticked "Ignore scans" are not compared and do not use up the few comparisons a scan makes per mod
          foreach ($f in @($liveForks | Where-Object { $ignoreSet.ContainsKey(("$([string]$_.owner.login)/$($_.name)").ToLower()) } | Select-Object -First 30)) {
            $fnI = "$([string]$f.owner.login)/$($f.name)"
            if ($seen.ContainsKey($fnI.ToLower())) { continue }
            $seen[$fnI.ToLower()] = $true
            $activeForks += (New-IgnoredForkStub $t.kind $f)
          }
          $cands = @($liveForks | Where-Object { -not $ignoreSet.ContainsKey(("$([string]$_.owner.login)/$($_.name)").ToLower()) } | Select-Object -First $(if ($AllForks) { 25 } else { $ForkMaxComparesPerMod }))

          foreach ($f in $cands) {
            if ($script:forkRateLimited -or $script:forkBadToken) { break }
            $fn = "$([string]$f.owner.login)/$($f.name)"
            if ($seen.ContainsKey($fn.ToLower())) { continue }
            $seen[$fn.ToLower()] = $true
            try {
              $e = New-ForkEntry $t.kind $f $installedRepo $installedBranch $ghHeaders
              if ($e) { $activeForks += $e }
            } catch { Register-ForkError $_ "checking fork $fn of $tRepo" }
          }
        }

        if ($activeForks.Count -gt 0) {
          # Newest push first across every kind of fork
          $activeForks = @($activeForks | Sort-Object { [string]$_.pushed_at } -Descending)
          # When was the installed copy last changed? Its newest commit (from the comparisons) and, when it is not a git clone, its
          # latest release. The game shows this next to each fork so the newest copy is easy to see.
          $instHead = ""
          foreach ($ae in $activeForks) { if (-not $instHead -and $ae.installed_head_at) { $instHead = [string]$ae.installed_head_at } }
          $instRelTag = ""; $instRelAt = ""
          if (-not (Test-Path -LiteralPath (Join-Path $path ".git"))) {
            try {
              $ir = Get-GhJson "https://api.github.com/repos/$installedRepo/releases/latest" $ghHeaders
              if ($ir.tag_name)     { $instRelTag = [string]$ir.tag_name }
              if ($ir.published_at) { $instRelAt  = Format-ForkDate $ir.published_at }
            } catch {}
          }
          $suggestions.suggestions[$name] = @{
            current_repo     = $rootRepo
            installed_repo   = $installedRepo
            installed_is_fork = $installedIsFork
            installed_head_at     = $instHead
            installed_pushed_at   = $script:forkInstPushed
            installed_release_at  = $instRelAt
            installed_release_tag = $instRelTag
            forks            = $activeForks
          }
        }
      } catch {
        Register-ForkError $_ "processing mod '$name'"
      } finally {
        if ($ownerRepo) { Add-Timing "fork scan: $name" $swFork }
      }
    }
  } catch {
    $summary.errors += "Fork scan failed: $($_.Exception.Message)"
  }

  if ($script:forkRateLimited) {
    if ($config.github_token -and ([string]$config.github_token).Trim() -ne "") {
      $summary.errors += "Fork scan stopped early: GitHub API limit reached even with your token. Try again in an hour."
    } else {
      $summary.errors += "Fork scan stopped early: GitHub allows only 60 requests/hour without a token. In the Fork Finder tab click 'GitHub token' to make a free one (takes 1 minute), then scan again."
    }
  }
  if ($script:forkBadToken) {
    $summary.errors += "Fork scan stopped: GitHub rejected your token (expired or mistyped). In the Fork Finder tab click 'GitHub token' to make a new one."
  }

  if ($script:forkBadToken) { $suggestions.token_status = "bad" }
  elseif ($script:forkRateLimited) { $suggestions.token_status = "rate_limited" }
  elseif ($hasToken) { $suggestions.token_status = "ok" }
  else { $suggestions.token_status = "none" }

  try { Save-JsonNoBom $forkSuggestionsPath $suggestions } catch {
    $summary.errors += "Failed to write fork_suggestions.json: $($_.Exception.Message)"
  }
}

# ---- Impossible "Lovely (>=X)" requirement fixer ----
# Some forks ask for a Lovely version that does not exist yet (e.g. Balatro-History's fork wants Lovely >= 0.15
# while the newest Lovely is 0.10.0). Steamodded then refuses to load the mod ("Missing Dependencies") and puts
# it on the blacklist. For mods that are on a fork we lower such a requirement to the Lovely version installed.
function Compare-DottedVersion([string]$a, [string]$b) {
  $pa = @($a -split '\.' | ForEach-Object { $d = ($_ -replace '\D', ''); if ($d -eq '') { 0 } else { [int]$d } })
  $pb = @($b -split '\.' | ForEach-Object { $d = ($_ -replace '\D', ''); if ($d -eq '') { 0 } else { [int]$d } })
  $n = [Math]::Max($pa.Count, $pb.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
    $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
    if ($x -gt $y) { return 1 }
    if ($x -lt $y) { return -1 }
  }
  return 0
}

function Get-InstalledLovelyVersion() {
  # 1) what Lovely itself reported last time the game started (first line of its newest log: "Lovely 0.10.0")
  try {
    $logDir = Join-Path $modsDirResolved "lovely\log"
    if (Test-Path -LiteralPath $logDir) {
      $log = Get-ChildItem -LiteralPath $logDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($log) {
        $line = Get-Content -LiteralPath $log.FullName -TotalCount 1 -ErrorAction Stop
        if ([string]$line -match 'Lovely\s+v?(\d+(\.\d+)*)') { return $Matches[1] }
      }
    }
  } catch {}
  # 2) the tag the updater installed
  try {
    $fs = Read-JsonIfExists (Join-Path $selfDirResolved ".framework_state.json")
    if ($fs -and $fs.lovely_tag -and ([string]$fs.lovely_tag) -match 'v?(\d+(\.\d+)*)') { return $Matches[1] }
  } catch {}
  return $null
}

function Repair-LovelyDependency([string]$modPath, [string]$modName) {
  $installed = Get-InstalledLovelyVersion
  if (-not $installed) { return }

  # Newest Lovely that really exists (a requirement at or below this is fixed by updating Lovely, not by editing the mod)
  $newest = $installed
  if ($null -eq $script:latestLovelyVer) {
    $script:latestLovelyVer = ""
    try {
      $rel = Github-LatestRelease "ethangreen-dev/lovely-injector"
      if ([string]$rel.tag_name -match 'v?(\d+(\.\d+)*)') { $script:latestLovelyVer = $Matches[1] }
    } catch {}
  }
  if ($script:latestLovelyVer -and (Compare-DottedVersion $script:latestLovelyVer $newest) -gt 0) { $newest = $script:latestLovelyVer }

  $rx = '"\s*Lovely\s*\(\s*>=\s*(?<ver>\d+(?:\.\d+)*)\s*\)\s*"'
  $files = @(Get-ChildItem -LiteralPath $modPath -Filter "*.json" -File -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike ".*" -and $_.Name -ne "update.json" })
  foreach ($f in $files) {
    try {
      $bytes  = [IO.File]::ReadAllBytes($f.FullName)
      $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
      $text   = [Text.Encoding]::UTF8.GetString($bytes)
      if ($hasBom) { $text = $text.Substring(1) }
      if ($text -notmatch '"dependencies"') { continue }
      $m = [regex]::Match($text, $rx)
      if (-not $m.Success) { continue }
      $g   = $m.Groups['ver']
      $req = $g.Value
      if ((Compare-DottedVersion $req $newest) -le 0) { continue }

      $parts = $installed -split '\.'
      $fixed = if ($parts.Count -ge 2) { "$($parts[0]).$($parts[1])" } else { $installed }
      $newText = $text.Substring(0, $g.Index) + $fixed + $text.Substring($g.Index + $g.Length)
      [IO.File]::WriteAllText($f.FullName, $newText, (New-Object System.Text.UTF8Encoding($hasBom)))
      $summary.updated_mods += "$modName (fixed impossible Lovely requirement >=$req -> >=$fixed in $($f.Name); restart to apply)"
    } catch {
      $summary.errors += "Could not check the Lovely requirement of ${modName} ($($f.Name)): $($_.Exception.Message)"
    }
  }
}

# Every mod that is currently switched to a fork gets the check (after every update run and right after a switch).
function Repair-ForkLovelyDeps() {
  try {
    Get-ChildItem -LiteralPath $modsDirResolved -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      $st = Read-JsonIfExists (Join-Path $_.FullName ".autoupdater_state.json")
      if ($st -and $st.fork_repo) { Repair-LovelyDependency $_.FullName $_.Name }
    }
  } catch {
    $summary.errors += "Lovely requirement check failed: $($_.Exception.Message)"
  }
}

# Step times of a fork switch (seconds since the script started), appended to update_timing_history.txt so a slow switch can be explained.
$script:switchMarks = New-Object System.Collections.ArrayList
function Mark-SwitchStep([string]$what) {
  try { [void]$script:switchMarks.Add(("{0} {1:N1}s" -f $what, $script:swTotal.Elapsed.TotalSeconds)) } catch {}
}
function Save-SwitchTiming([string]$mode, [string]$modName) {
  try {
    $line = "{0}  switch {1} {2}  total {3:N1}s  git {4:N1}s (network {5:N1}s)  steps: {6}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $mode, $modName, $script:swTotal.Elapsed.TotalSeconds, $script:gitSecTotal, $script:gitNetSec, ($script:switchMarks -join ", ")
    Add-Content -LiteralPath (Join-Path $selfDirResolved "update_timing_history.txt") -Value $line -Encoding UTF8
  } catch {}
}

function Switch-ToFork([string]$modName, [string]$forkRepo) {
  $modPath = Join-Path $modsDirResolved $modName
  if (-not (Test-Path -LiteralPath $modPath)) { throw "Mod folder not found: $modPath" }

  # Picking the repo this mod was originally installed from is a Switch Back: do exactly that, so no leftover "switched" state stays behind.
  $st0 = Read-JsonIfExists (Join-Path $modPath ".autoupdater_state.json")
  if ($st0 -and $st0.original_repo -and ([string]$st0.original_repo).ToLower() -eq $forkRepo.Trim().ToLower()) {
    Switch-BackFork $modName
    return
  }

  # Back up current version before switching
  Backup-Folder $modPath $modName | Out-Null
  Mark-SwitchStep "backup"

  $statePath = Join-Path $modPath ".autoupdater_state.json"
  $state     = Read-JsonIfExists $statePath
  if (-not $state) { $state = @{} }

  $gitDir = Join-Path $modPath ".git"
  if (Test-Path -LiteralPath $gitDir) {
    # Git mod: store original remote, point to fork, fetch and hard-reset
    $currentRemote = Run-Git $modPath @("remote", "get-url", "origin")
    if ($currentRemote.code -eq 0) {
      $url = ($currentRemote.out | Select-Object -First 1).Trim()
      if ($url -match "github\.com[:/](.+?/[^./]+?)(\.git)?$") {
        if (-not $state.original_repo) {
          $state | Add-Member -NotePropertyName "original_repo" -NotePropertyValue $Matches[1] -Force
        }
      }
    }

    $newUrl    = "https://github.com/$forkRepo.git"
    $setUrlRes = Run-Git $modPath @("remote", "set-url", "origin", $newUrl)
    if ($setUrlRes.code -ne 0) { throw "Failed to set remote URL: " + (Short-Out $setUrlRes.out) }

    $fetchRes = Run-Git $modPath @("-c", "gc.auto=0", "-c", "maintenance.auto=false", "fetch", "--no-tags", "origin")
    if ($fetchRes.code -ne 0) { throw "Failed to fetch from fork: " + (Short-Out $fetchRes.out) }
    Mark-SwitchStep "fetch"

    $forkBranch = Get-GitDefaultBranch $modPath
    $resetRes   = Run-Git $modPath @("reset", "--hard", "origin/$forkBranch")
    if ($resetRes.code -ne 0) { throw "Failed to reset to fork HEAD: " + (Short-Out $resetRes.out) }
    Mark-SwitchStep "reset"

    $state | Add-Member -NotePropertyName "fork_repo"    -NotePropertyValue $forkRepo -Force
    $state | Add-Member -NotePropertyName "switched_at"  -NotePropertyValue (Get-Date).ToString("o") -Force
    Save-JsonNoBom $statePath $state
  } else {
    # update.json mod: rewrite the repo field, clear state so next update picks up the fork's releases
    $ujPath = Join-Path $modPath "update.json"
    if (Test-Path -LiteralPath $ujPath) {
      $uj = Read-JsonIfExists $ujPath
      if ($uj) {
        if (-not $state.original_repo) {
          $state | Add-Member -NotePropertyName "original_repo" -NotePropertyValue ([string]$uj.repo) -Force
        }
        $uj.repo = $forkRepo
        Save-JsonNoBom $ujPath $uj
      }
    }
    # Remove old state so the next update cycle fetches fresh from the fork
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
    $newState = @{
      original_repo = $state.original_repo
      fork_repo     = $forkRepo
      switched_at   = (Get-Date).ToString("o")
    }
    Save-JsonNoBom $statePath $newState
  }

  $summary.updated_mods += "$modName (switched to fork: $forkRepo)"
  Mark-SwitchStep "state saved"
  # Some forks ask for a Lovely version that does not exist; make the fork loadable with the Lovely we have.
  Repair-LovelyDependency $modPath $modName
  Mark-SwitchStep "lovely check"
}

function Switch-BackFork([string]$modName) {
  $modPath = Join-Path $modsDirResolved $modName
  if (-not (Test-Path -LiteralPath $modPath)) { throw "Mod folder not found: $modPath" }

  $statePath    = Join-Path $modPath ".autoupdater_state.json"
  $state        = Read-JsonIfExists $statePath
  if (-not $state -or -not $state.original_repo) { throw "No original_repo stored in state for $modName" }
  $originalRepo = [string]$state.original_repo

  # Back up current fork version before reverting
  Backup-Folder $modPath $modName | Out-Null
  Mark-SwitchStep "backup"

  $gitDir = Join-Path $modPath ".git"
  if (Test-Path -LiteralPath $gitDir) {
    $newUrl    = "https://github.com/$originalRepo.git"
    $setUrlRes = Run-Git $modPath @("remote", "set-url", "origin", $newUrl)
    if ($setUrlRes.code -ne 0) { throw "Failed to set remote URL: " + (Short-Out $setUrlRes.out) }

    $fetchRes = Run-Git $modPath @("-c", "gc.auto=0", "-c", "maintenance.auto=false", "fetch", "--no-tags", "origin")
    if ($fetchRes.code -ne 0) { throw "Failed to fetch from original: " + (Short-Out $fetchRes.out) }
    Mark-SwitchStep "fetch"

    $origBranch = Get-GitDefaultBranch $modPath
    $resetRes   = Run-Git $modPath @("reset", "--hard", "origin/$origBranch")
    if ($resetRes.code -ne 0) { throw "Failed to reset to original HEAD: " + (Short-Out $resetRes.out) }
    Mark-SwitchStep "reset"

    $state | Add-Member -NotePropertyName "fork_repo"     -NotePropertyValue $null -Force
    $state | Add-Member -NotePropertyName "original_repo" -NotePropertyValue $null -Force
    $state | Add-Member -NotePropertyName "switched_at"   -NotePropertyValue (Get-Date).ToString("o") -Force
    Save-JsonNoBom $statePath $state
  } else {
    # update.json mod: restore original repo field, clear state
    $ujPath = Join-Path $modPath "update.json"
    if (Test-Path -LiteralPath $ujPath) {
      $uj = Read-JsonIfExists $ujPath
      if ($uj) {
        $uj.repo = $originalRepo
        Save-JsonNoBom $ujPath $uj
      }
    }
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
  }

  $summary.updated_mods += "$modName (switched back to original: $originalRepo)"
}

# ---- Fork switch-back mode ----
if ($SwitchBackModName -ne "") {
  try {
    Switch-BackFork $SwitchBackModName
    Save-SwitchTiming "back" $SwitchBackModName
  } catch {
    $summary.errors += "ERROR switching back ${SwitchBackModName}: $($_.Exception.Message)"
  }
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}

# ---- Fork switch mode ----
if ($SwitchModName -ne "" -and $SwitchToForkRepo -ne "") {
  try {
    Switch-ToFork $SwitchModName $SwitchToForkRepo
    Save-SwitchTiming "to-fork" $SwitchModName
  } catch {
    $summary.errors += "ERROR switching fork ${SwitchModName}: $($_.Exception.Message)"
  }
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}

# a full update check rebuilds both lists from scratch (fork scans and switches above kept the carried-over ones)
$summary.untracked_mods = @()
$summary.folder_name_stale = @()

# Save the game files if this Steam build isn't saved yet; may pause the mod and framework updates below (see Invoke-GameCheck).
Invoke-GameCheck

if (-not $script:holdUpdates) {
try {
  Get-ChildItem -LiteralPath $modsDirResolved -Directory -Force | ForEach-Object {
    $name = $_.Name
    $path = $_.FullName
    # When targeting a single mod, skip everything else
    if ($targetModFilter -ne "" -and $name -ne $targetModFilter) { return }
    # A pinned mod is checked for a newer version: if its source serves something other than the version that was put back, the pin
    # is released and the mod is updated to the latest version right here (see Invoke-PinRetryCheck).
    $pinNote = ""
    if ($skipSet.ContainsKey($name) -and $pinnedSet.ContainsKey($name) -and -not $crashPendingSet.ContainsKey($name)) {
      $pr = Invoke-PinRetryCheck $path $name
      if ($pr.release) {
        $skipSet.Remove($name) | Out-Null
        $pinnedSet.Remove($name) | Out-Null
        Remove-ModPinFromConfig $name
        [void]$script:pinsReleased.Add([ordered]@{ mod_name = $name; from_version = $pr.from; to_version = $pr.to; released_at = (Get-Date).ToString("o") })
        $summary.skipped_mods += $pr.note
      } else {
        $pinNote = $pr.note
      }
    }
    if ($skipSet.ContainsKey($name)) {
      if ($pinnedSet.ContainsKey($name)) {
        $skippedMsg = if ($pinNote) { $pinNote } else { "$name (pinned at backup)" }
        $summary.skipped_mods += $skippedMsg
      } elseif ($crashPendingSet.ContainsKey($name)) {
        $summary.skipped_mods += "$name (not updated: waiting for your answer about the startup crash)"
      } else {
        $summary.skipped_mods += "$name (updates disabled)"
      }
      return
    }
    if ($name -eq "_Balatro-Mod-Updater_Backups") { return }
    if ($name -eq "_Balatro-Automatic-Mod-Updater_Backups") { return }
    if ($name -eq "_AutoModUpdater_Backups") { return }

    $swMod = [System.Diagnostics.Stopwatch]::StartNew()
    try { Update-OneMod $path $name } finally { Add-Timing "update check: $name" $swMod }
  }
} catch {
  $summary.errors += "Top-level scan failed: $($_.Exception.Message)"
}
}

# Keep changelogs.json current: refresh every mod updated in this run, and add git mods that have no entry yet.
try {
  foreach ($e in $recentlyUpdatedEntries) {
    $mn = [string]$e.mod_name
    $mp = Join-Path $modsDirResolved $mn
    if (Test-Path -LiteralPath (Join-Path $mp ".git") -PathType Container) {
      Refresh-GitChangelog $mn $mp
    } elseif ($script:releaseNotes.ContainsKey($mn)) {
      $rn = $script:releaseNotes[$mn]
      $notes = @($rn.notes)
      if ($notes.Count -eq 0) { $notes = @("Updated to " + [string]$rn.tag) }
      Set-ChangelogEntry $mn @{ source = "release"; head = [string]$rn.tag; date = (Get-Date).ToString("yyyy-MM-dd"); notes = $notes }
    } else {
      Set-ChangelogEntry $mn @{ source = "update"; head = [string]$e.updated_to_version; date = (Get-Date).ToString("yyyy-MM-dd"); notes = @("Updated " + (Get-Date).ToString("yyyy-MM-dd") + " (no change notes available for this source)") }
    }
  }
  $have = Read-JsonIfExists (Join-Path $selfDirResolved "changelogs.json")
  $known = @{}
  if ($have -and $have.mods) { foreach ($p in $have.mods.PSObject.Properties) { $known[$p.Name] = $true } }
  Get-ChildItem -LiteralPath $modsDirResolved -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name.StartsWith("_") -or $known.ContainsKey($_.Name)) { return }
    if (Test-Path -LiteralPath (Join-Path $_.FullName ".git") -PathType Container) { Refresh-GitChangelog $_.Name $_.FullName }
  }
} catch {}

# Write _recently_updated.json so that crash detection on the next run can roll
# back these mods if the game fails to start after this update.
# Skipped in single-mod-check and restore-only modes to avoid false detections.
if ($recentlyUpdatedEntries.Count -gt 0 -and $RestoreModName -eq "" -and $targetModFilter -eq "") {
  try { Save-JsonNoBom $recentlyUpdatedPath $recentlyUpdatedEntries } catch {
    $summary.errors += "Failed to write _recently_updated.json: $($_.Exception.Message)"
  }
  # This session already reached the menu; the NEXT launch is the one that tests the update.
  Clear-LaunchMarkers
}


# ---------------- Framework Updates (Steamodded + Lovely) ----------------

function Github-LatestRelease([string]$repo) {
  $api = "https://api.github.com/repos/$repo/releases/latest"
  return Invoke-RestMethod -Uri $api -Headers (Get-GhHeaders)
}


function Get-DirTreeHash([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return $null }
  $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files -or $files.Count -eq 0) { return $null }

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($f in ($files | Sort-Object FullName)) {
    $rel = $f.FullName.Substring($dir.Length).TrimStart('\','/')
    try {
      $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
      $lines.Add(($rel.ToLower() + "|" + $h))
    } catch {
      return $null
    }
  }

  $joined = [string]::Join("`n", $lines)
  $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
  $ms = New-Object IO.MemoryStream(,$bytes)
  try { return (Get-FileHash -InputStream $ms -Algorithm SHA256).Hash } finally { $ms.Dispose() }
}


function Normalize-Tag([string]$t) {
  if (-not $t) { return "" }
  return ($t.Trim().TrimStart('v','V')).ToLower()
}

# Reads Steamodded's version.lua ('return "26.1002.0"'). Returns $null if not found.
function Get-InstalledSteamoddedVersion([string]$dir) {
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
  foreach ($rel in @("version.lua", "release.lua", "src\version.lua")) {
    $p = Join-Path $dir $rel
    if (Test-Path -LiteralPath $p) {
      $txt = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
      $m = [regex]::Match([string]$txt, '"([^"]+)"')
      if ($m.Success) { return $m.Groups[1].Value }
    }
  }
  return $null
}

function Stage-FrameworkUpdate([hashtable]$pending, [string]$type, [string]$src, [string]$dst, [string]$label, [string]$version = "") {
  if ($type -eq "copy_file") {
    $pending.tasks += @{ type="copy_file"; src=$src; dst=$dst; label=$label; version=$version }
  } elseif ($type -eq "replace_dir") {
    $pending.tasks += @{ type="replace_dir"; src=$src; dst=$dst; label=$label; version=$version; backup_root=(Join-Path $selfDirResolved "_framework_backups") }
  }
}

# A pinned Steamodded / Lovely: stays pinned while GitHub still serves the version that was put back; once its latest release is a
# different version the pin is released (in memory, for this run) and the normal framework update below carries on to the latest.
function Invoke-FrameworkPinRetry([string]$name, [string]$repo, $keepPend) {
  $disp = Get-FrameworkDisplay $name
  $stay = "[Framework] $disp is pinned to an earlier version (unpin it in the Backups tab to update again)"
  try {
    # a restore that is still waiting for the game to quit must be applied first
    if ($keepPend -and $keepPend.tasks) {
      foreach ($kt in @($keepPend.tasks)) { if ([string]$kt.version -eq "restored" -and (([string]$kt.label -eq $name) -or ($name -eq "lovely" -and [string]$kt.label -eq "lovely-old"))) { $summary.skipped_mods += $stay; return } }
    }
    $from = ""
    $pv = Get-PinVersions
    if ($pv.ContainsKey($name) -and $pv[$name].from_version) { $from = [string]$pv[$name].from_version }
    if (-not $from) {
      try { $from = [string]$config.framework_pins.$name.crashed_version } catch {}
    }
    if (-not $from) { $summary.skipped_mods += $stay + " (the version it went back from isn't recorded, so it can't tell when a newer one appears)"; return }
    $rel = Get-GhJson "https://api.github.com/repos/$repo/releases/latest" (Get-GhHeaders)
    $tag = [string]$rel.tag_name
    if (-not $tag -or (Normalize-Tag $tag) -eq (Normalize-Tag $from)) {
      $summary.skipped_mods += "[Framework] $disp is pinned to an earlier version (no release newer than $from yet)"
      return
    }
    if ($config.pin_retry_newer -eq $false) {
      $summary.skipped_mods += "[Framework] $disp is pinned - $tag is available, but automatic retry is off"
      return
    }
    $config.framework_pins.$name.pinned = $false
    [void]$script:pinsReleased.Add([ordered]@{ mod_name = $name; from_version = $from; to_version = $tag; released_at = (Get-Date).ToString("o") })
    $summary.skipped_mods += "[Framework] $disp pin released: $tag is newer than $from, the version that was put back; updating to the latest"
  } catch {
    $summary.skipped_mods += $stay + " (couldn't check for a newer version: " + (Short-Out @($_.Exception.Message)) + ")"
  }
}

# End of a run: tell the game which pins were released (it owns the pin list), drop notes for pins that no longer exist.
function Save-PinReleases() {
  try {
    if ($script:pinsReleased.Count -gt 0) {
      $all = New-Object System.Collections.ArrayList
      $old = Read-JsonIfExists $script:PinReleasedPath
      if ($old) { foreach ($o in @($old)) { if ($o -and $o.mod_name) { [void]$all.Add($o) } } }
      foreach ($r in $script:pinsReleased) { [void]$all.Add($r) }
      Save-JsonNoBom $script:PinReleasedPath @($all)
      $summary.pins_released = @($script:pinsReleased | ForEach-Object { [string]$_.mod_name })
      Save-JsonNoBom $configPath $config
    }
    if ($targetModFilter -eq "" -and $RestoreModName -eq "") {
      $pv = Get-PinVersions
      $changed = $false
      foreach ($k in @($pv.Keys)) {
        $stillPinned = $pinnedSet.ContainsKey($k) -or (Test-FrameworkPinned $k)
        if (-not $stillPinned) { $pv.Remove($k); $changed = $true }
      }
      if ($changed) { Save-PinVersions $pv }
    }
  } catch { $summary.errors += "Couldn't save the released pins: $($_.Exception.Message)" }
}

function Update-Frameworks() {
  if ($targetModFilter -ne "") { return }  # skip frameworks when checking a single mod
  Ensure-FrameworkBaseline
  if (-not $config.update_frameworks) { return }
  $pendingRoot = Join-Path $selfDirResolved "_pending_framework_updates"
  Ensure-Dir $pendingRoot

  $pending = @{ pending_root = $pendingRoot; tasks = @(); notes = @() }

  # A restore chosen in the Backups tab (version "restored") stays staged until it has been applied, even though the
  # pinned framework itself is skipped below.
  $keepPend = Read-JsonIfExists (Join-Path $selfDirResolved "pending_apply.json")
  if ($keepPend -and $keepPend.tasks) {
    foreach ($kt in @($keepPend.tasks)) {
      if ([string]$kt.type -eq "swap_game") {
        $sh = @{}; foreach ($pr in $kt.PSObject.Properties) { $sh[$pr.Name] = $pr.Value }
        $pending.tasks += $sh
      } elseif ([string]$kt.version -eq "restored") {
        $pending.tasks += @{ type = [string]$kt.type; src = [string]$kt.src; dst = [string]$kt.dst; label = [string]$kt.label; version = "restored"; backup_root = [string]$kt.backup_root }
      }
    }
  }

  $statePath = Join-Path $selfDirResolved ".framework_state.json"
  $state = Read-JsonIfExists $statePath
  if (-not $state) { $state = @{ steamodded_tag=""; lovely_tag="" } }
  # Make sure every field exists. A state object read from JSON can't gain new
  # properties by plain assignment (that's what broke 'lovely_file' in v0.7.1).
  foreach ($k in @("steamodded_tag","steamodded_hash","lovely_tag","lovely_hash","lovely_file")) {
    if ($state -is [System.Collections.IDictionary]) {
      if (-not $state.Contains($k)) { $state[$k] = "" }
    } elseif (-not ($state.PSObject.Properties.Name -contains $k)) {
      $state | Add-Member -NotePropertyName $k -NotePropertyValue ""
    }
  }

  # 1) Steamodded (Balatro modding framework)
  # Steamodded may be installed as:
  # - %AppData%/Balatro/Mods/smods  (git clone method)
  # - %AppData%/Balatro/Mods/smods-<version> (zip release / Nexus method)
  # We'll detect the existing folder and update it in-place to avoid duplicates.
  if ($config.update_steamodded -and (Test-FrameworkPinned "smods")) {
    Invoke-FrameworkPinRetry "smods" "Steamodded/smods" $keepPend
  }
  if ($config.update_steamodded -and -not (Test-FrameworkPinned "smods")) {
    try {
      $rel = Github-LatestRelease "Steamodded/smods"
      $tag = [string]$rel.tag_name
      if (-not $tag) { throw "Missing tag_name from GitHub latest release." }

      function Find-InstalledSteamoddedDir() {
        $candidates = Get-ChildItem -LiteralPath $modsDirResolved -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match "^smods($|-)" }
        $valid = @()
        foreach ($c in $candidates) {
          $loader = Get-ChildItem -LiteralPath $c.FullName -Recurse -File -Filter "loader.lua" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]src[\\/]' } | Select-Object -First 1
          if ($loader) { $valid += $c }
        }
        if ($valid.Count -gt 0) {
          return ($valid | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        }
        return (Join-Path $modsDirResolved "smods")
      }

      $dstDir = Find-InstalledSteamoddedDir
      $installedVer = Get-InstalledSteamoddedVersion $dstDir
      $installedHash = $null

      if (-not $state.steamodded_hash) { $state.steamodded_hash = "" }

      # Fast path: Steamodded ships src/../version.lua (return "26.1002.0"). If it equals the
      # latest tag we're current. This replaces the old folder-hash check, which re-staged the
      # same version forever whenever any extra file (e.g. an update.json) sat in the smods folder.
      if ($installedVer -and (Normalize-Tag $installedVer) -eq (Normalize-Tag $tag)) {
        $summary.skipped_mods += "[Framework] Steamodded already current ($tag)"
        $state.steamodded_tag = $tag
      } elseif (-not $installedVer -and ($installedHash = Get-DirTreeHash $dstDir) -and $state.steamodded_tag -eq $tag -and ($state.steamodded_hash -eq $installedHash)) {
        $summary.skipped_mods += "[Framework] Steamodded already current ($tag)"
      } else {
        if ($installedVer) { $summary.skipped_mods += "[Framework] Steamodded $installedVer installed, $tag available" }
        # Download latest Steamodded to compute hash + optionally stage.
        $asset = $null
        foreach ($a in $rel.assets) {
          if ($a.name -match "^smods-.*\.zip$" -or $a.name -match "^smods.*\.zip$") { $asset = $a; break }
        }

        $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("balatro_smods_" + [Guid]::NewGuid().ToString("N"))
        Ensure-Dir $tmpRoot
        $zipPath = Join-Path $tmpRoot $(if ($asset) { $asset.name } else { "smods.zip" })
        $extract = Join-Path $tmpRoot "extract"
        Ensure-Dir $extract

        if ($asset) {
          Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ "User-Agent"="BalatroModUpdater" } | Out-Null
        } else {
          # Prefer the stable GitHub tag archive (more reliable than api.zipball_url under rate-limit/HTML error conditions)
          $zipUrl = "https://github.com/Steamodded/smods/archive/refs/tags/$tag.zip"
          $headers = @{ "User-Agent"="BalatroModUpdater"; "Accept"="application/octet-stream" }

          try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -Headers $headers | Out-Null
            $summary.skipped_mods += "[Framework debug] Steamodded download: tag archive ($tag)"
          } catch {
            $zipUrl2 = $rel.zipball_url
            if (-not $zipUrl2) { throw "GitHub release missing zipball_url" }
            Invoke-WebRequest -Uri $zipUrl2 -OutFile $zipPath -Headers $headers | Out-Null
            $summary.skipped_mods += "[Framework debug] Steamodded download: zipball_url"
          }
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

        # Locate the Steamodded root by finding a src\loader.lua (handles extra nesting in the zip)
        $loader = Get-ChildItem -LiteralPath $extract -Recurse -File -Filter "loader.lua" -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match '[\\/]src[\\/]' } | Select-Object -First 1

        if (-not $loader) {
          # Fallback: find a src directory that contains loader.lua directly
          $srcDir = Get-ChildItem -LiteralPath $extract -Recurse -Directory -Filter "src" -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "loader.lua") } | Select-Object -First 1
          if ($srcDir) { $loader = Get-Item -LiteralPath (Join-Path $srcDir.FullName "loader.lua") }
        }

        if (-not $loader) { throw "Could not locate src\\loader.lua inside downloaded Steamodded archive." }
        $full = $loader.FullName
            $summary.skipped_mods += "[Framework debug] Steamodded loader path: $full"
            # loader.lua lives in <root>/src/ (or deeper, e.g. <root>/src/preflight/); root = parent of that "src"
            $srcDirItem = $loader.Directory
            while ($srcDirItem -and $srcDirItem.Name -ine 'src') { $srcDirItem = $srcDirItem.Parent }
            if (-not $srcDirItem) { throw "Found loader.lua but could not determine src root from path: $full" }
            $srcRoot = $srcDirItem.Parent.FullName

        $newHash = Get-DirTreeHash $srcRoot
        if (-not $installedHash) { $installedHash = Get-DirTreeHash $dstDir }

        if ($installedHash -and $newHash -and ($installedHash -eq $newHash)) {
          $summary.skipped_mods += "[Framework] Steamodded already current ($tag)"
          $state.steamodded_tag = $tag
          $state.steamodded_hash = $newHash
          try { Save-JsonNoBom $statePath $state } catch {}
          Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        } else {
          # Stage folder replace
          $stageDir = Join-Path $pendingRoot "smods"
          if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
          Ensure-Dir $stageDir
          Copy-Item -Path (Join-Path $srcRoot "*") -Destination $stageDir -Recurse -Force

          Stage-FrameworkUpdate $pending "replace_dir" $stageDir $dstDir "smods" $tag

          $pending.notes += "Steamodded staged: $tag"
          $summary.skipped_mods += "[Framework staged] Steamodded ($tag)"
          $state.steamodded_tag = $tag
          $state.steamodded_hash = $(if ($newHash) { $newHash } else { "" })
          try { Save-JsonNoBom $statePath $state } catch {}

          Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
    } catch {
      $summary.errors += "ERROR updating (framework) Steamodded: $($_.Exception.Message)"
    }
  }

  # 2) Lovely (winmm.dll since v0.10.0, version.dll before) in game folder
  if ($config.update_lovely -and (Test-FrameworkPinned "lovely")) {
    Invoke-FrameworkPinRetry "lovely" "ethangreen-dev/lovely-injector" $keepPend
  }
  if ($config.update_lovely -and -not (Test-FrameworkPinned "lovely")) {
    try {
      $gameDir = Get-BalatroGameDir
      if (-not $gameDir) { throw "Could not locate Balatro game directory. Set balatro_game_dir in autoupdater_config.json." }

      $rel = Github-LatestRelease "ethangreen-dev/lovely-injector"
      $tag = [string]$rel.tag_name
      if (-not $tag) { throw "Missing tag_name from GitHub latest release." }

      # Lovely's Windows file was renamed in v0.10.0: version.dll -> winmm.dll.
      # Exactly ONE of them may be in the game folder (two would load Lovely twice).
      $lovelyNames = @("winmm.dll", "version.dll")
      $presentDlls = @($lovelyNames | Where-Object { Test-Path -LiteralPath (Join-Path $gameDir $_) })

      # Fast path: same tag as last time, the recorded file is the only Lovely dll present,
      # and its hash still matches.
      $stateFile = if ($state.lovely_file) { [string]$state.lovely_file } else { "version.dll" }
      if ($state.lovely_tag -eq $tag -and $state.lovely_hash -and $presentDlls.Count -eq 1 -and $presentDlls[0] -eq $stateFile) {
        $curHash = $null
        try { $curHash = (Get-FileHash -LiteralPath (Join-Path $gameDir $stateFile) -Algorithm SHA256).Hash } catch {}
        if ($curHash -eq $state.lovely_hash) {
          $summary.skipped_mods += "[Framework] Lovely already current ($tag)"
          throw [System.OperationCanceledException]::new("lovely-current")
        }
      }

      # Pick the Windows MSVC zip asset
      $assetRegex = "lovely-x86_64-pc-windows-msvc\.zip$"
      $asset = $null
      foreach ($a in $rel.assets) { if ($a.name -match $assetRegex) { $asset = $a; break } }
      if (-not $asset) { throw "No Lovely asset matched '$assetRegex' in latest release." }

      $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("balatro_lovely_" + [Guid]::NewGuid().ToString("N"))
      Ensure-Dir $tmpRoot
      $zipPath = Join-Path $tmpRoot $asset.name
      $extract = Join-Path $tmpRoot "extract"
      Ensure-Dir $extract

      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ "User-Agent"="BalatroModUpdater" } -UseBasicParsing | Out-Null
      Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

      $dll = $null
      foreach ($n in $lovelyNames) {
        $dll = Get-ChildItem -LiteralPath $extract -Recurse -File -Filter $n | Select-Object -First 1
        if ($dll) { break }
      }
      if (-not $dll) { throw "Neither winmm.dll nor version.dll found inside the Lovely archive." }
      $newName = $dll.Name.ToLower()
      $dstDll = Join-Path $gameDir $newName
      $oldDlls = @($presentDlls | Where-Object { $_ -ne $newName })

      $newHash = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash
      $oldHash = $null
      if (Test-Path -LiteralPath $dstDll) {
        try { $oldHash = (Get-FileHash -LiteralPath $dstDll -Algorithm SHA256).Hash } catch { $oldHash = $null }
      }

      if ($oldHash -and $newHash -and ($newHash -eq $oldHash) -and $oldDlls.Count -eq 0) {
        $state.lovely_tag = $tag
        $state.lovely_hash = $newHash
        $state.lovely_file = $newName
        try { Save-JsonNoBom $statePath $state } catch {}
        $summary.skipped_mods += "[Framework] Lovely already current ($tag)"
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
      } else {
        $stageDll = Join-Path $pendingRoot $newName
        Copy-Item -LiteralPath $dll.FullName -Destination $stageDll -Force
        if (-not ($oldHash -and $newHash -eq $oldHash)) {
          Stage-FrameworkUpdate $pending "copy_file" $stageDll $dstDll "lovely" $tag
        }
        # Old-named Lovely dll (e.g. version.dll after the switch to winmm.dll) gets renamed
        # out of the way when the update is applied, so Lovely isn't loaded twice.
        foreach ($old in $oldDlls) {
          $pending.tasks += @{ type="disable_file"; dst=(Join-Path $gameDir $old); label="lovely-old"; version=$tag }
          $pending.notes += "Old Lovely $old will be renamed to $old.old_<date>"
        }

        $pending.notes += "Lovely staged: $tag ($newName)"
        $summary.skipped_mods += "[Framework staged] Lovely ($tag, $newName)"
        $state.lovely_tag = $tag
        $state.lovely_hash = $newHash
        $state.lovely_file = $newName
        try { Save-JsonNoBom $statePath $state } catch {}

        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch [System.OperationCanceledException] {
      # already current (fast path)
    } catch {
      $summary.errors += "ERROR updating (framework) Lovely: $($_.Exception.Message)"
    }
  }

  $pendingPath = Join-Path $selfDirResolved "pending_apply.json"
  if ($pending.tasks.Count -gt 0) {
    Save-JsonNoBom $pendingPath $pending
    try { Save-JsonNoBom $statePath $state } catch {}
    $summary.framework_staged = $true
    $summary.skipped_mods += "Framework updates staged. Click 'Restart now' to apply."
  } else {
    # Nothing to apply any more: remove a stale pending_apply.json so an old staged
    # version can never be applied later over a newer one.
    if (Test-Path -LiteralPath $pendingPath) {
      Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
      $summary.skipped_mods += "[Framework] Removed stale pending framework update (already current)"
    }
    Get-ChildItem -LiteralPath $pendingRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    try { Save-JsonNoBom $statePath $state } catch {}
  }
}


# ---- Fork scan mode (-CheckForks) ----
# Skip framework updates when we only need to discover forks (saves API quota).
if ($CheckForks) {
  Check-Forks
  Clear-OldGhCache
  Write-TimingDetail "fork scan"
  try { Save-JsonNoBom $summaryPath $summary } catch {}
  exit 0
}

Repair-ForkLovelyDeps

if ($script:holdUpdates) { Ensure-FrameworkBaseline } else { Update-Frameworks }
Save-PinReleases

# Mod folders whose NAME carries a version (e.g. "Some-Mod-v1.3.0") that no longer matches the mod's own manifest version.
# An update changes the files but not the folder name, so the name goes stale. Only reported (the game shows a note).
try {
  $staleNames = @()
  Get-ChildItem -LiteralPath $modsDirResolved -Directory -Force | ForEach-Object {
    $m = [regex]::Match($_.Name, '(?i)[-_ ]v?(\d+(?:\.\d+)+)\s*$')
    if (-not $m.Success) { return }
    $nameVer = $m.Groups[1].Value
    foreach ($jf in @(Get-ChildItem -LiteralPath $_.FullName -Filter *.json -File -ErrorAction SilentlyContinue | Select-Object -First 8)) {
      $mf = $null
      try { $mf = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
      if ($mf -and $mf.id -and $mf.version) {
        $modVer = ([string]$mf.version).TrimStart("v", "V")
        if ($modVer -ne $nameVer) { $staleNames += ("{0}  (name says {1}, mod is {2})" -f $_.Name, $nameVer, $modVer) }
        break
      }
    }
  }
  $summary.folder_name_stale = @($staleNames)
} catch {}

Clear-OldGhCache
Write-TimingDetail "update check"
try { Save-JsonNoBom $summaryPath $summary } catch {}
