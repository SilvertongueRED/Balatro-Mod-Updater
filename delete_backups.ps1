# Moves backup files to the Recycle Bin. Started by the Updater's Backups screen (Delete / Delete Selected).
# It only touches .zip / .dll files that sit directly inside the allowed backups folder. Nothing is ever deleted for good:
# if a file can't go to the Recycle Bin it is left where it is and the reason goes into the result file.
param(
  [string]$ListFile,
  [string]$ResultFile,
  [string]$AllowedDir
)
$ErrorActionPreference = 'Stop'
$out = New-Object System.Collections.ArrayList
try {
  Add-Type -AssemblyName Microsoft.VisualBasic
  $allowed = [IO.Path]::GetFullPath($AllowedDir).TrimEnd('\')
  foreach ($line in (Get-Content -LiteralPath $ListFile -Encoding UTF8)) {
    $p = ([string]$line).Trim()
    if (-not $p) { continue }
    try {
      $full = [IO.Path]::GetFullPath($p)
      $dir = [IO.Path]::GetDirectoryName($full).TrimEnd('\')
      $ext = [IO.Path]::GetExtension($full).ToLower()
      if (($dir -ne $allowed) -or (($ext -ne '.zip') -and ($ext -ne '.dll'))) { throw 'not a backup file' }
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { [void]$out.Add("gone|$full"); continue }
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, 'OnlyErrorDialogs', 'SendToRecycleBin')
      [void]$out.Add("ok|$full")
    } catch {
      [void]$out.Add(("fail|{0}|{1}" -f $p, $_.Exception.Message))
    }
  }
} catch {
  [void]$out.Add(("fail||{0}" -f $_.Exception.Message))
}
try { Set-Content -LiteralPath $ResultFile -Value $out -Encoding UTF8 } catch {}
exit 0
