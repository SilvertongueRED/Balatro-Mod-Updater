param(
  [Parameter(Mandatory=$true)][string]$SelfDir,
  [Parameter(Mandatory=$false)][string]$SteamAppId = "2379780",
  [Parameter(Mandatory=$false)][string]$WaitProcessName = "Balatro"
)

$ErrorActionPreference = "Stop"

# A crash anywhere below must still leave a log the game and the test can read.
trap {
  try {
    $crashLog = @{ applied_at = (Get-Date).ToString("o"); results = @(); errors = @("apply_pending.ps1 crashed: " + $_.Exception.Message + " (line " + $_.InvocationInfo.ScriptLineNumber + ")") }
    [System.IO.File]::WriteAllText((Join-Path ([string]$SelfDir).Trim().Trim('"') "pending_apply_log.json"), ($crashLog | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  exit 1
}

function Read-Json([string]$path) {
  return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Ensure-Dir([string]$path) { if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null } }
function Save-JsonNoBom([string]$path, $obj) {
  $json = ($obj | ConvertTo-Json -Depth 12)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

$SelfDir = $SelfDir.Trim().Trim('"')
$pendingPath = Join-Path $SelfDir "pending_apply.json"
if (-not (Test-Path -LiteralPath $pendingPath)) { exit 0 }

# Wait for Balatro to exit so DLL/file locks are gone
$deadline = (Get-Date).AddMinutes(3)
$stillRunning = $false
while ($true) {
  $p = Get-Process -Name $WaitProcessName -ErrorAction SilentlyContinue
  if (-not $p) { break }
  if ((Get-Date) -gt $deadline) { $stillRunning = $true; break }
  Start-Sleep -Milliseconds 400
}
# Give Windows a moment to release file handles after the process exits.
Start-Sleep -Milliseconds 800

if ($stillRunning) {
  # Applying now would leave Steamodded half-copied / version.dll locked. Keep everything
  # staged so the next restart can try again.
  try {
    Save-JsonNoBom (Join-Path $SelfDir "pending_apply_log.json") @{
      applied_at = (Get-Date).ToString("o"); results = @()
      errors = @("Balatro was still running after 3 minutes - nothing applied, update kept for next time.")
    }
  } catch {}
  exit 1
}

$pending = Read-Json $pendingPath

function Get-SmodsVersion([string]$dir) {
  $p = Join-Path $dir "version.lua"
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  $m = [regex]::Match((Get-Content -LiteralPath $p -Raw), '"([^"]+)"')
  if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}
$tasks = @()
if ($pending.tasks) { $tasks = $pending.tasks }

$log = @{
  applied_at = (Get-Date).ToString("o")
  results = @()
  errors = @()
}

function Backup-File([string]$dst) {
  if (-not (Test-Path -LiteralPath $dst)) { return $null }
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $bak = "$dst.bak_$stamp"
  Copy-Item -LiteralPath $dst -Destination $bak -Force
  return $bak
}

# Steamodded / Lovely changes are remembered here so the startup crash check can offer to put them back.
$recentFw = New-Object System.Collections.ArrayList
function Add-RecentFramework([string]$label, [string]$backupFile, [string]$version, [string]$restoreTo) {
  if (-not $backupFile) { return }
  try {
    [void]$recentFw.Add([ordered]@{
      mod_name = $label; backup_file = $backupFile; restore_to = $restoreTo
      updated_to_version = $version; updated_at = (Get-Date).ToString("o")
    })
  } catch {}
}

# Lovely's dll is also copied into the Updater's _framework_backups folder, so the in-game Backups tab can list it.
function Copy-ToFrameworkBackups([string]$file, [string]$label) {
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  $root = Join-Path $SelfDir "_framework_backups"
  Ensure-Dir $root
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $dest = Join-Path $root ("$label-$stamp-" + [IO.Path]::GetFileName($file))
  Copy-Item -LiteralPath $file -Destination $dest -Force
  return $dest
}

function Backup-FolderToZip([string]$folderPath, [string]$label, [string]$backupRoot) {
  if (-not (Test-Path -LiteralPath $folderPath)) { return $null }
  Ensure-Dir $backupRoot
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $zip = Join-Path $backupRoot "$label-$stamp.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $folderPath "*") -DestinationPath $zip -Force
  return $zip
}

foreach ($t in $tasks) {
  try {
    if ($t.type -eq "copy_file") {
      $src = [string]$t.src
      $dst = [string]$t.dst
      if (-not (Test-Path -LiteralPath $src)) { throw "missing src '$src'" }
      if ((Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash)) {
        $log.results += "skipped (already identical): $dst"
        continue
      }
      $bak = Backup-File $dst
      $fwBak = $null
      if ($bak -and [string]$t.label -eq "lovely") { try { $fwBak = Copy-ToFrameworkBackups $dst "lovely" } catch {} }
      Ensure-Dir ([IO.Path]::GetDirectoryName($dst))
      Copy-Item -LiteralPath $src -Destination $dst -Force
      $log.results += "copied: $src -> $dst" + ($(if($bak){" (backup: $bak)"}else{""}))
      if ($fwBak) { Add-RecentFramework "lovely" $fwBak ([string]$t.version) $dst }
    } elseif ($t.type -eq "disable_file") {
      # Rename (not delete) an old file, e.g. Lovely's version.dll after switching to winmm.dll.
      $dst = [string]$t.dst
      # Never remove the old Lovely if installing the new one failed - you'd have no Lovely at all.
      if ($log.errors.Count -gt 0) { throw "skipped renaming $dst because an earlier step failed" }
      if (Test-Path -LiteralPath $dst) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $newPath = "$dst.old_$stamp"
        Move-Item -LiteralPath $dst -Destination $newPath -Force
        $log.results += "renamed old file: $dst -> $newPath"
      } else {
        $log.results += "skipped (already gone): $dst"
      }
    } elseif ($t.type -eq "replace_dir") {
      $src = [string]$t.src
      $dst = [string]$t.dst
      if (-not (Test-Path -LiteralPath $src)) { throw "missing src dir '$src'" }
      # Never replace a Steamodded install with the same version (e.g. you updated it by hand).
      $stagedVer = Get-SmodsVersion $src
      $installedVer = Get-SmodsVersion $dst
      if ($t.force -eq $true) {
        # a restore chosen by the player: no same-version or older-version check
      } elseif ($stagedVer -and $installedVer -and ($stagedVer -eq $installedVer)) {
        $log.results += "skipped (already $installedVer): $dst"
        continue
      }
      $sv = $null; $iv = $null
      if ($t.force -ne $true -and [version]::TryParse([string]$stagedVer, [ref]$sv) -and [version]::TryParse([string]$installedVer, [ref]$iv) -and $sv -lt $iv) {
        $log.results += "skipped (staged $stagedVer is older than installed $installedVer): $dst"
        continue
      }
      $backupRoot = if ($t.backup_root) { [string]$t.backup_root } else { Join-Path $SelfDir "_framework_backups" }
      $label = if ($t.label) { [string]$t.label } else { "dirbackup" }
      $zip = Backup-FolderToZip $dst $label $backupRoot
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
      Ensure-Dir $dst
      Copy-Item -Path (Join-Path $src "*") -Destination $dst -Recurse -Force
      $log.results += "replaced dir: $dst from $src" + ($(if($zip){" (backup: $zip)"}else{""}))
      if ($zip -and $label -eq "smods") { Add-RecentFramework "smods" $zip ([string]$t.version) $dst }
    } elseif ($t.type -eq "swap_game") {
      # Play a saved copy of Balatro (or go back to Steam's version): put its files into the Steam game folder.
      $src = [string]$t.src
      $dst = [string]$t.dst
      if (-not (Test-Path -LiteralPath (Join-Path $src "Balatro.exe"))) { throw "missing saved game copy '$src'" }
      if (-not (Test-Path -LiteralPath $dst)) { throw "missing game folder '$dst'" }
      if ($t.exe_sha256 -and (Get-FileHash -LiteralPath (Join-Path $src "Balatro.exe") -Algorithm SHA256).Hash -ne [string]$t.exe_sha256) { throw "the saved copy is damaged (Balatro.exe changed), nothing was changed" }
      $gbRoot = if ($t.backup_root) { [string]$t.backup_root } else { Join-Path (Split-Path -Parent (Split-Path -Parent $SelfDir)) "AMU_GameBackups" }
      Ensure-Dir $gbRoot
      # 1) make sure the game that is installed right now is saved too (so going back is always possible)
      $curExe = Join-Path $dst "Balatro.exe"
      if (Test-Path -LiteralPath $curExe) {
        $curSha = (Get-FileHash -LiteralPath $curExe -Algorithm SHA256).Hash
        $haveCur = $false
        foreach ($d in @(Get-ChildItem -LiteralPath $gbRoot -Directory -ErrorAction SilentlyContinue)) {
          $mj = Join-Path $d.FullName "amu_backup.json"
          if (Test-Path -LiteralPath $mj) { try { if ([string](Read-Json $mj).exe_sha256 -eq $curSha) { $haveCur = $true; break } } catch {} }
        }
        if (-not $haveCur) {
          $nm = (Get-Date -Format "yyyyMMdd_HHmmss") + "_before_swap"
          $dstSave = Join-Path $gbRoot $nm
          Ensure-Dir $dstSave
          $baseCur = $dst.TrimEnd('\','/')
          foreach ($f in @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force)) {
            if ($f.Name -match '\.(bak|old|crashed)_\d' -or $f.Name -match '\.lnk$') { continue }
            $rel = $f.FullName.Substring($baseCur.Length).TrimStart('\','/')
            $to = Join-Path $dstSave $rel
            Ensure-Dir (Split-Path -Parent $to)
            Copy-Item -LiteralPath $f.FullName -Destination $to -Force
          }
          Save-JsonNoBom (Join-Path $dstSave "amu_backup.json") ([ordered]@{ name = $nm; created_at = (Get-Date).ToString("o"); buildid = [string]$t.steam_buildid; exe_sha256 = $curSha; exe_size = (Get-Item -LiteralPath $curExe).Length; lovely_tag = ""; steamodded_tag = "" })
          $log.results += "saved the installed game first: $dstSave"
        }
      }
      # 2) copy the saved files over the game folder (Balatro.exe last, so a failure part-way leaves the old exe)
      $baseSrc = $src.TrimEnd('\','/')
      $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force | Where-Object { $_.Name -ne "amu_backup.json" })
      $ordered = @($files | Where-Object { $_.Name -ne "Balatro.exe" }) + @($files | Where-Object { $_.Name -eq "Balatro.exe" })
      foreach ($f in $ordered) {
        $rel = $f.FullName.Substring($baseSrc.Length).TrimStart('\','/')
        $to = Join-Path $dst $rel
        Ensure-Dir (Split-Path -Parent $to)
        Copy-Item -LiteralPath $f.FullName -Destination $to -Force
      }
      # only one Lovely dll may be present (two would load Lovely twice)
      $srcHasWinmm = Test-Path -LiteralPath (Join-Path $src "winmm.dll")
      $srcHasVersion = Test-Path -LiteralPath (Join-Path $src "version.dll")
      foreach ($pair in @(@("winmm.dll", $srcHasWinmm, $srcHasVersion), @("version.dll", $srcHasVersion, $srcHasWinmm))) {
        $other = Join-Path $dst $pair[0]
        if ((-not $pair[1]) -and $pair[2] -and (Test-Path -LiteralPath $other)) {
          Move-Item -LiteralPath $other -Destination ("$other.old_" + (Get-Date -Format "yyyyMMdd_HHmmss")) -Force
          $log.results += "renamed the other Lovely file: $other"
        }
      }
      # 3) remember what is installed
      $gsPath = Join-Path $SelfDir ".game_state.json"
      $gs = [ordered]@{}
      if (Test-Path -LiteralPath $gsPath) { try { foreach ($pr in (Read-Json $gsPath).PSObject.Properties) { $gs[$pr.Name] = $pr.Value } } catch {} }
      $gs["active_backup"] = $(if ($t.make_active -eq $true) { [string]$t.name } else { "" })
      $gs["swapped_at"] = (Get-Date).ToString("o")
      $gs.Remove("exe_cache")
      $gs["last_seen_sha"] = (Get-FileHash -LiteralPath $curExe -Algorithm SHA256).Hash
      Save-JsonNoBom $gsPath $gs
      $log.results += "game files: " + $(if ($t.make_active -eq $true) { "now playing the saved copy $($t.name)" } else { "back on Steam's version ($($t.name))" })
    } elseif ($t.type -eq "restore_zip") {
      # Put an earlier Steamodded back from one of its backup zips (chosen in the game's Backups tab).
      $src = [string]$t.src
      $dst = [string]$t.dst
      if (-not (Test-Path -LiteralPath $src)) { throw "missing backup zip '$src'" }
      $backupRoot = if ($t.backup_root) { [string]$t.backup_root } else { Join-Path $SelfDir "_framework_backups" }
      $label = if ($t.label) { [string]$t.label } else { "dirbackup" }
      $tmpX = Join-Path ([IO.Path]::GetTempPath()) ("amu_fwrestore_" + [Guid]::NewGuid().ToString("N"))
      Ensure-Dir $tmpX
      try {
        # unpack first: if the zip is bad nothing in the installed folder has been touched yet
        Expand-Archive -LiteralPath $src -DestinationPath $tmpX -Force
        if (-not (Get-ChildItem -LiteralPath $tmpX -Force | Select-Object -First 1)) { throw "the backup zip is empty" }
        $zip = Backup-FolderToZip $dst $label $backupRoot
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Ensure-Dir $dst
        Copy-Item -Path (Join-Path $tmpX "*") -Destination $dst -Recurse -Force
      } finally {
        Remove-Item -LiteralPath $tmpX -Recurse -Force -ErrorAction SilentlyContinue
      }
      $log.results += "restored dir: $dst from $src" + ($(if($zip){" (backup of what was there: $zip)"}else{""}))
      if ($zip -and $label -eq "smods") { Add-RecentFramework "smods" $zip "restored" $dst }
    }
  } catch {
    $log.errors += "Failed task $($t.type): $($_.Exception.Message)"
  }
}

try { Save-JsonNoBom (Join-Path $SelfDir "pending_apply_log.json") $log } catch {}

# Remember what was changed: if the next start crashes, the crash screen offers to put Steamodded / Lovely back.
if ($recentFw.Count -gt 0) {
  try {
    $rp = Join-Path $SelfDir "_recently_updated.json"
    $merged = @()
    if (Test-Path -LiteralPath $rp) {
      $ex = $null
      try { $ex = Read-Json $rp } catch {}
      foreach ($e in @($ex)) {
        if ($e -and $e.mod_name -and -not (@($recentFw | Where-Object { $_.mod_name -eq [string]$e.mod_name }).Count -gt 0)) { $merged += $e }
      }
    }
    foreach ($e in $recentFw) { $merged += $e }
    Save-JsonNoBom $rp @($merged)
  } catch {}
}

# Only clear the staged update when everything worked; otherwise keep it so it can be retried.
if ($log.errors.Count -eq 0) {
  try { Remove-Item -LiteralPath $pendingPath -Force } catch {}
  try { if ($pending.pending_root -and (Test-Path -LiteralPath $pending.pending_root)) { Remove-Item -LiteralPath $pending.pending_root -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
}

# "none" = do not start Steam (the test passes it: Windows PowerShell 5.1 drops empty-string arguments when it starts another script)
if ($SteamAppId -and $SteamAppId.Trim() -ne "" -and $SteamAppId.Trim() -ne "none") {
  try { Start-Process ("steam://rungameid/" + $SteamAppId) | Out-Null } catch {}
}
