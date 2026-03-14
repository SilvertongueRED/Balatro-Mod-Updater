param(
  [Parameter(Mandatory=$true)][string]$ModsDir,
  [Parameter(Mandatory=$true)][string]$SelfDir
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

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ModsDir = $ModsDir.Trim().Trim('"')
$SelfDir = $SelfDir.Trim().Trim('"')

$summary = @{
  ran_at = (Get-Date).ToString("o")
  updated_mods = @()
  skipped_mods = @()
  errors = @()
}

try { $modsDirResolved = (Resolve-Path -LiteralPath $ModsDir).Path } catch { $modsDirResolved = $ModsDir; $summary.errors += "Resolve-Path failed for ModsDir '$ModsDir': $($_.Exception.Message)" }
try { $selfDirResolved = (Resolve-Path -LiteralPath $SelfDir).Path } catch { $selfDirResolved = $SelfDir; $summary.errors += "Resolve-Path failed for SelfDir '$SelfDir': $($_.Exception.Message)" }

try { Ensure-Dir $selfDirResolved } catch { $summary.errors += "Couldn't create SelfDir '$selfDirResolved': $($_.Exception.Message)" }

$selfFolderName = Split-Path -Leaf $selfDirResolved

$summaryPath = Join-Path $selfDirResolved "last_run.json"


# early save: create/refresh last_run.json immediately so you can confirm the script actually ran
try { Save-JsonNoBom $summaryPath $summary } catch {}

$defaults = [ordered]@{
  update_git = $true
  update_updatejson = $true
  make_backups = $true
  skip_folders = @("smods", $selfFolderName, "_AutoModUpdater_Backups")
  nexus_api_key = ""
  nexus_game_domain = "balatro"
  git_pull_mode = "ff-only"  # "ff-only" (default) or "rebase"
  update_frameworks = $false
  update_steamodded = $false
  update_lovely = $false
  balatro_game_dir = ""  # optional override
}

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

$backupRoot = Join-Path $modsDirResolved "_AutoModUpdater_Backups"
try { Ensure-Dir $backupRoot } catch { $summary.errors += "Couldn't create backup folder '$backupRoot': $($_.Exception.Message)" }

function Backup-Folder([string]$folderPath, [string]$folderName) {
  if (-not $config.make_backups) { return }
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $dest = Join-Path $backupRoot "$folderName-$stamp.zip"
  try {
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    Compress-Archive -Path (Join-Path $folderPath "*") -DestinationPath $dest -Force
  } catch {
    $summary.errors += "Backup failed for ${folderName}: $($_.Exception.Message)"
  }
}

function Run-Git([string]$folderPath, [string[]]$gitArgs) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & git -C $folderPath @gitArgs 2>&1
    $code = $LASTEXITCODE
    return @{ out = $out; code = $code }
  } finally {
    $ErrorActionPreference = $old
  }
}

function Short-Out($out) {
  if (-not $out) { return "" }
  $s = ($out | Select-Object -First 4) -join " "
  return ($s -replace "\s+", " ").Trim()
}

function Update-GitMod([string]$folderPath, [string]$folderName) {
  if (-not $config.update_git) { return $false }
  $gitDir = Join-Path $folderPath ".git"
  if (-not (Test-Path -LiteralPath $gitDir)) { return $false }

  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { $summary.skipped_mods += "$folderName (git: no git in PATH)"; return $true }

  try {
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

    $upRes = Run-Git $folderPath @("rev-parse","@{u}")
    if ($upRes.code -ne 0) {
      $summary.skipped_mods += "$folderName (git: no upstream tracking branch)"
      return $true
    }
    $upstream = ($upRes.out | Select-Object -First 1).Trim()

    if ($local -eq $upstream) { return $true }

    Backup-Folder $folderPath $folderName
    $oldHead = $local

    # Stash any local changes to prevent "Your local changes would be
    # overwritten" errors (e.g. runtime-generated config files that were
    # previously tracked before being added to .gitignore).
    $didStash = $false
    $dirtyCheck = Run-Git $folderPath @("diff-index","--quiet","HEAD","--")
    if ($dirtyCheck.code -ne 0) {
      $stashRes = Run-Git $folderPath @("stash","push","-q")
      if ($stashRes.code -eq 0) { $didStash = $true }
    }

    $pullArgs = @("pull")
    if ($config.git_pull_mode -and [string]$config.git_pull_mode -eq "rebase") {
      $pullArgs += @("--rebase","--autostash")
    } else {
      $pullArgs += @("--ff-only")
    }
    $pull = Run-Git $folderPath $pullArgs

    # Restore stashed local changes (best-effort).
    if ($didStash) {
      Run-Git $folderPath @("stash","pop","-q") | Out-Null
    }

    if ($pull.code -ne 0) {
      $summary.errors += "ERROR updating (git) ${folderName}: pull failed ($($pull.code)) [mode=$($config.git_pull_mode)] " + (Short-Out $pull.out)
      return $true
    }

    $newHeadRes = Run-Git $folderPath @("rev-parse","HEAD")
    if ($newHeadRes.code -ne 0) {
      # Can't verify; report as updated conservatively
      $summary.updated_mods += $folderName
      return $true
    }
    $newHead = ($newHeadRes.out | Select-Object -First 1).Trim()

    if ($newHead -and $newHead -ne $oldHead) {
      $summary.updated_mods += $folderName
    } else {
      $summary.skipped_mods += "$folderName (git: no changes applied)"
    }
  } catch {
    $summary.errors += "ERROR updating (git) ${folderName}: $($_.Exception.Message)"
  }
  return $true
}

function Update-GitHubReleaseMod([string]$folderPath, [string]$folderName, $uj) {
  $statePath = Join-Path $folderPath ".autoupdater_state.json"
  $state = Read-JsonIfExists $statePath
  $installedTag = if ($state -and $state.tag) { [string]$state.tag } else { "" }

  $repo = [string]$uj.repo
  $api = "https://api.github.com/repos/$repo/releases/latest"
  $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent"="AutoModUpdater"; "Accept"="application/vnd.github+json" }
  $tag = [string]$rel.tag_name
  if (-not $tag) { throw "GitHub release missing tag_name" }
  if ($installedTag -eq $tag) { return $true }

  $assetRegex = if ($uj.asset_regex) { [string]$uj.asset_regex } else { ".*\.zip$" }
  $asset = $null
  foreach ($a in $rel.assets) { if ($a.name -match $assetRegex) { $asset = $a; break } }
  if (-not $asset) { throw "No GitHub release asset matched regex '$assetRegex'." }

  $dl = [string]$asset.browser_download_url
  if (-not $dl) { throw "GitHub asset missing browser_download_url." }

  Backup-Folder $folderPath $folderName

  $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("balatro_ghupd_" + [Guid]::NewGuid().ToString("N"))
  Ensure-Dir $tmpRoot
  $zipPath = Join-Path $tmpRoot $asset.name
  $extractPath = Join-Path $tmpRoot "extract"
  Ensure-Dir $extractPath

  Invoke-WebRequest -Uri $dl -OutFile $zipPath -Headers @{ "User-Agent"="AutoModUpdater" } | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

  $children = Get-ChildItem -LiteralPath $extractPath -Force
  $srcRoot = $extractPath
  if ($uj.strip_single_top_folder -ne $false) {
    $dirs = $children | Where-Object { $_.PSIsContainer }
    if ($dirs.Count -eq 1 -and ($children.Count -eq 1)) { $srcRoot = $dirs[0].FullName }
  }

  $preserve = @("update.json", ".autoupdater_state.json")
  $preserveTemp = Join-Path $tmpRoot "preserve"
  Ensure-Dir $preserveTemp
  foreach ($p in $preserve) {
    $pp = Join-Path $folderPath $p
    if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $preserveTemp $p) -Force }
  }

  Get-ChildItem -LiteralPath $folderPath -Force | ForEach-Object {
    if ($preserve -contains $_.Name) { return }
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
  Copy-Item -Path (Join-Path $srcRoot "*") -Destination $folderPath -Recurse -Force

  foreach ($p in $preserve) {
    $pp = Join-Path $preserveTemp $p
    if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $folderPath $p) -Force }
  }

  Save-JsonNoBom $statePath @{ provider="github"; tag=$tag; repo=$repo; updated_at=(Get-Date).ToString("o") }
  $summary.updated_mods += $folderName
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  return $true
}

function Invoke-Nexus([string]$url) {
  if (-not $config.nexus_api_key -or $config.nexus_api_key.Trim() -eq "") {
    throw "Nexus API key not set in autoupdater_config.json (nexus_api_key)."
  }
  return Invoke-RestMethod -Uri $url -Headers @{ "apikey"=$config.nexus_api_key; "accept"="application/json"; "User-Agent"="AutoModUpdater" }
}

function Update-NexusMod([string]$folderPath, [string]$folderName, $uj) {
  $domain = if ($uj.game_domain) { [string]$uj.game_domain } elseif ($config.nexus_game_domain) { [string]$config.nexus_game_domain } else { "balatro" }
  $modId = [int]$uj.mod_id
  if (-not $modId) { throw "update.json provider=nexus missing mod_id" }

  $statePath = Join-Path $folderPath ".autoupdater_state.json"
  $state = Read-JsonIfExists $statePath
  $installedFileId = if ($state -and $state.file_id) { [int]$state.file_id } else { 0 }

  $filesUrl = "https://api.nexusmods.com/v1/games/$domain/mods/$modId/files.json"
  $files = Invoke-Nexus $filesUrl
  if (-not $files -or -not $files.files) { throw "Nexus files.json response missing 'files'." }

  $latest = $null
  foreach ($f in $files.files) { if (-not $latest -or ([int]$f.file_id -gt [int]$latest.file_id)) { $latest = $f } }
  if (-not $latest) { throw "No files found on Nexus for $domain/$modId." }

  $latestFileId = [int]$latest.file_id
  if ($installedFileId -eq $latestFileId) { return $true }

  $dlUrl = "https://api.nexusmods.com/v1/games/$domain/mods/$modId/files/$latestFileId/download_link.json"
  $dl = Invoke-Nexus $dlUrl
  if (-not $dl -or $dl.Count -lt 1 -or -not $dl[0].URI) { throw "Nexus download_link.json returned no usable URI." }
  $uri = [string]$dl[0].URI

  Backup-Folder $folderPath $folderName

  $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("balatro_nexusupd_" + [Guid]::NewGuid().ToString("N"))
  Ensure-Dir $tmpRoot
  $zipPath = Join-Path $tmpRoot ("nexus_" + $latestFileId + ".zip")
  $extractPath = Join-Path $tmpRoot "extract"
  Ensure-Dir $extractPath

  Invoke-WebRequest -Uri $uri -OutFile $zipPath -Headers @{ "User-Agent"="AutoModUpdater" } | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

  $children = Get-ChildItem -LiteralPath $extractPath -Force
  $srcRoot = $extractPath
  $dirs = $children | Where-Object { $_.PSIsContainer }
  if ($dirs.Count -eq 1 -and ($children.Count -eq 1)) { $srcRoot = $dirs[0].FullName }

  $preserve = @("update.json", ".autoupdater_state.json")
  $preserveTemp = Join-Path $tmpRoot "preserve"
  Ensure-Dir $preserveTemp
  foreach ($p in $preserve) {
    $pp = Join-Path $folderPath $p
    if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $preserveTemp $p) -Force }
  }

  Get-ChildItem -LiteralPath $folderPath -Force | ForEach-Object {
    if ($preserve -contains $_.Name) { return }
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
  Copy-Item -Path (Join-Path $srcRoot "*") -Destination $folderPath -Recurse -Force

  foreach ($p in $preserve) {
    $pp = Join-Path $preserveTemp $p
    if (Test-Path -LiteralPath $pp) { Copy-Item -LiteralPath $pp -Destination (Join-Path $folderPath $p) -Force }
  }

  Save-JsonNoBom $statePath @{ provider="nexus"; game_domain=$domain; mod_id=$modId; file_id=$latestFileId; updated_at=(Get-Date).ToString("o") }
  $summary.updated_mods += $folderName
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  return $true
}

function Update-UpdateJsonMod([string]$folderPath, [string]$folderName) {
  if (-not $config.update_updatejson) { return $false }
  $updateJsonPath = Join-Path $folderPath "update.json"
  if (-not (Test-Path -LiteralPath $updateJsonPath)) { return $false }
  $uj = Read-JsonIfExists $updateJsonPath
  if (-not $uj) { $summary.skipped_mods += "$folderName (bad update.json)"; return $true }

  $provider = [string]$uj.provider
  try {
    if ($provider -eq "nexus") {
      [void](Update-NexusMod $folderPath $folderName $uj); return $true
    } elseif ($provider -eq "github") {
      if (-not $uj.repo) { throw "update.json provider=github missing repo" }
      [void](Update-GitHubReleaseMod $folderPath $folderName $uj); return $true
    } else {
      $summary.skipped_mods += "$folderName (unknown provider '$provider')"; return $true
    }
  } catch {
    $summary.errors += "ERROR updating (${provider}) ${folderName}: $($_.Exception.Message)"
    return $true
  }
}

try {
  Get-ChildItem -LiteralPath $modsDirResolved -Directory -Force | ForEach-Object {
    $name = $_.Name
    $path = $_.FullName
    if ($skipSet.ContainsKey($name)) { return }
    if ($name -eq $selfFolderName -or $name -eq "_AutoModUpdater_Backups") { return }

    $handled = (Update-GitMod $path $name)
    if (-not $handled) { [void](Update-UpdateJsonMod $path $name) }
  }
} catch {
  $summary.errors += "Top-level scan failed: $($_.Exception.Message)"
}


# ---------------- Framework Updates (Steamodded + Lovely) ----------------

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

function Github-LatestRelease([string]$repo) {
  $api = "https://api.github.com/repos/$repo/releases/latest"
  return Invoke-RestMethod -Uri $api -Headers @{ "User-Agent"="AutoModUpdater"; "Accept"="application/vnd.github+json" }
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


function Stage-FrameworkUpdate([hashtable]$pending, [string]$type, [string]$src, [string]$dst, [string]$label) {
  if ($type -eq "copy_file") {
    $pending.tasks += @{ type="copy_file"; src=$src; dst=$dst }
  } elseif ($type -eq "replace_dir") {
    $pending.tasks += @{ type="replace_dir"; src=$src; dst=$dst; label=$label; backup_root=(Join-Path $selfDirResolved "_framework_backups") }
  }
}

function Update-Frameworks() {
  if (-not $config.update_frameworks) { return }
  $pendingRoot = Join-Path $selfDirResolved "_pending_framework_updates"
  Ensure-Dir $pendingRoot

  $pending = @{ pending_root = $pendingRoot; tasks = @(); notes = @() }

  $statePath = Join-Path $selfDirResolved ".framework_state.json"
  $state = Read-JsonIfExists $statePath
  if (-not $state) { $state = @{ steamodded_tag=""; lovely_tag="" } }

  # 1) Steamodded (Balatro modding framework)
  # Steamodded may be installed as:
  # - %AppData%/Balatro/Mods/smods  (git clone method)
  # - %AppData%/Balatro/Mods/smods-<version> (zip release / Nexus method)
  # We'll detect the existing folder and update it in-place to avoid duplicates.
  if ($config.update_steamodded) {
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
            Where-Object { ($_.FullName).ToLower().Contains('\src\') } | Select-Object -First 1
          if ($loader) { $valid += $c }
        }
        if ($valid.Count -gt 0) {
          return ($valid | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        }
        return (Join-Path $modsDirResolved "smods")
      }

      $dstDir = Find-InstalledSteamoddedDir
      $installedHash = Get-DirTreeHash $dstDir

      if (-not $state.steamodded_hash) { $state.steamodded_hash = "" }

      # Fast path: if tag matches and stored hash matches installed, we're current (no download needed).
      if ($state.steamodded_tag -eq $tag -and $state.steamodded_hash -and $installedHash -and ($state.steamodded_hash -eq $installedHash)) {
        $summary.skipped_mods += "[Framework] Steamodded already current ($tag)"
      } else {
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
          Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ "User-Agent"="AutoModUpdater" } | Out-Null
        } else {
          # Prefer the stable GitHub tag archive (more reliable than api.zipball_url under rate-limit/HTML error conditions)
          $zipUrl = "https://github.com/Steamodded/smods/archive/refs/tags/$tag.zip"
          $headers = @{ "User-Agent"="AutoModUpdater"; "Accept"="application/octet-stream" }

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
          Where-Object { ($_.FullName).ToLower().Contains('\src\') } | Select-Object -First 1

        if (-not $loader) {
          # Fallback: find a src directory that contains loader.lua directly
          $srcDir = Get-ChildItem -LiteralPath $extract -Recurse -Directory -Filter "src" -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "loader.lua") } | Select-Object -First 1
          if ($srcDir) { $loader = Get-Item -LiteralPath (Join-Path $srcDir.FullName "loader.lua") }
        }

        if (-not $loader) { throw "Could not locate src\\loader.lua inside downloaded Steamodded archive." }
        $full = $loader.FullName
            $summary.skipped_mods += "[Framework debug] Steamodded loader path: $full"
            $lower = $full.ToLower()
            $ix = $lower.LastIndexOf('\src\')
            if ($ix -lt 0) { throw "Found loader.lua but could not determine src root from path: $full" }
            $srcRoot = $full.Substring(0, $ix)  # everything before \src\ is root

        $newHash = Get-DirTreeHash $srcRoot

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

          Stage-FrameworkUpdate $pending "replace_dir" $stageDir $dstDir "smods"

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

  # 2) Lovely version.dll in game folder
# version.dll in game folder
# 2) Lovely version.dll in game folder
  if ($config.update_lovely) {
    try {
      $gameDir = Get-BalatroGameDir
      if (-not $gameDir) { throw "Could not locate Balatro game directory. Set balatro_game_dir in autoupdater_config.json." }

      $rel = Github-LatestRelease "ethangreen-dev/lovely-injector"
      $tag = [string]$rel.tag_name
      if (-not $tag) { throw "Missing tag_name from GitHub latest release." }

      # Pick the Windows MSVC zip asset (contains version.dll)
      $assetRegex = "lovely-x86_64-pc-windows-msvc\.zip$"
      $asset = $null
      foreach ($a in $rel.assets) { if ($a.name -match $assetRegex) { $asset = $a; break } }
      if (-not $asset) { throw "No Lovely asset matched '$assetRegex' in latest release." }

      $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("balatro_lovely_" + [Guid]::NewGuid().ToString("N"))
      Ensure-Dir $tmpRoot
      $zipPath = Join-Path $tmpRoot $asset.name
      $extract = Join-Path $tmpRoot "extract"
      Ensure-Dir $extract

      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ "User-Agent"="AutoModUpdater" } | Out-Null
      Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

      $dll = Get-ChildItem -LiteralPath $extract -Recurse -File -Filter "version.dll" | Select-Object -First 1
      if (-not $dll) { throw "version.dll not found inside Lovely archive." }

      $dstDll = Join-Path $gameDir "version.dll"

      # Compare hashes: if the existing version.dll matches the latest release dll, don't stage anything.
      $newHash = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash
      $oldHash = $null
      if (Test-Path -LiteralPath $dstDll) {
        try { $oldHash = (Get-FileHash -LiteralPath $dstDll -Algorithm SHA256).Hash } catch { $oldHash = $null }
      }

      if ($oldHash -and $newHash -and ($newHash -eq $oldHash)) {
        # Already current; update state so we stop re-staging on every run.
        $state.lovely_tag = $tag
        $state.lovely_hash = $newHash
        try { Save-JsonNoBom $statePath $state } catch {}
        $summary.skipped_mods += "[Framework] Lovely already current ($tag)"
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
      } else {
        $stageDll = Join-Path $pendingRoot "version.dll"
        Copy-Item -LiteralPath $dll.FullName -Destination $stageDll -Force

        Stage-FrameworkUpdate $pending "copy_file" $stageDll $dstDll "lovely"

        $pending.notes += "Lovely staged: $tag"
        $summary.skipped_mods += "[Framework staged] Lovely ($tag)"
        $state.lovely_tag = $tag
        $state.lovely_hash = $newHash
        try { Save-JsonNoBom $statePath $state } catch {}

        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {
      $summary.errors += "ERROR updating (framework) Lovely: $($_.Exception.Message)"
    }
  }

  if ($pending.tasks.Count -gt 0) {
    $pendingPath = Join-Path $selfDirResolved "pending_apply.json"
    Save-JsonNoBom $pendingPath $pending
    try { Save-JsonNoBom $statePath $state } catch {}
    $summary.skipped_mods += "Framework updates staged. Click 'Restart now' to apply."
  } else {
    try { Save-JsonNoBom $statePath $state } catch {}
  }
}


Update-Frameworks

try { Save-JsonNoBom $summaryPath $summary } catch {}
