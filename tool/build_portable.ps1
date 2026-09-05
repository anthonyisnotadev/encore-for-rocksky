#Requires -Version 5.1
<#
.SYNOPSIS
    Builds encore for rocksky as a portable app and stages it for distribution.

.DESCRIPTION
    Produces a self-contained folder that runs from anywhere — a USB stick, a
    network share, a Downloads folder — without an installer and without
    keeping settings on the host machine.

    Flutter's Windows output is not a single file: the .exe is a small host
    stub that loads flutter_windows.dll and reads data\ beside itself, so the
    whole directory has to travel together. That directory is already
    installer-free; what this script adds is the PortableData\ marker that
    lib/services/portable_mode.dart looks for, which moves saved settings out
    of %APPDATA% and next to the executable.

.PARAMETER SkipBuild
    Stage from the existing Release output instead of rebuilding. Fails if
    there is nothing built yet.

.PARAMETER NoZip
    Leave the staged folder without also producing a .zip.

.PARAMETER OutputDir
    Where to stage. Defaults to build\portable under the repository root.

.EXAMPLE
    pwsh -File tool\build_portable.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [switch]$SkipBuild,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'build\portable' }

# Read the version out of pubspec so the zip is identifiable once downloaded.
# The +build suffix is dropped; it is a Windows file-version field, not
# something a user needs in a filename.
$pubspec = Get-Content (Join-Path $repoRoot 'pubspec.yaml') -Raw
$version = if ($pubspec -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    $Matches[1]
} else {
    Write-Warning 'No version found in pubspec.yaml; naming the output "dev".'
    'dev'
}

$appName = 'encore-for-rocksky'
$stageName = "$appName-portable-$version"
$stageDir = Join-Path $OutputDir $stageName

if (-not $SkipBuild) {
    Write-Host 'Building Windows release...' -ForegroundColor Cyan
    # Spotify import stays off: the flag defaults to false and the experimental
    # overwrite path can irreversibly delete records on the user's PDS. A
    # distributable build must not carry it. See lib/feature_flags.dart.
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path $releaseDir)) {
    throw "No release build at $releaseDir. Run without -SkipBuild."
}

Write-Host "Staging $stageName..." -ForegroundColor Cyan
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# Copy the whole Release tree: the .exe, flutter_windows.dll, every plugin DLL
# and data\ (app.so, icudtl.dat, flutter_assets). Copying a subset produces a
# binary that launches to a blank window or not at all.
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stageDir -Recurse -Force

# The marker directory. Its presence is the whole switch — see PortableMode.
# Note it is deliberately not called Data: Windows paths are case-insensitive
# and Flutter already ships data\ next to the .exe.
$portableData = Join-Path $stageDir 'PortableData'
$settingsDir = Join-Path $portableData 'settings'
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

# A file has to live in here. Compress-Archive and most extractors drop empty
# directories, which would silently turn portable mode off for anyone who
# unpacked the zip — the app would run, look right, and write to %APPDATA%.
@'
Settings for the portable copy of encore for rocksky live in this folder.

settings\shared_preferences.json holds the window size, the notification
toggle, and your Bluesky session. The session is encrypted using Windows'
own data protection, with a key belonging to the Windows account that
signed in -- so if this folder is copied or the stick is lost, the session
in it cannot be used.

The same thing means the sign-in does not travel. Run this on another PC,
or under another Windows account, and it will ask you to sign in again.
Your window size and notification setting do carry over.

Delete this folder to sign out and reset the app to a clean state.

Do not rename or delete the PortableData folder itself while you want the
app to stay portable. Without it the app falls back to storing settings in
%APPDATA% on whichever machine it is run from.
'@ | Set-Content -Path (Join-Path $portableData 'README.txt') -Encoding UTF8

@"
encore for rocksky $version — portable

Run encore_for_rocksky.exe. No installation, no setup, nothing to uninstall.

Settings, including your Bluesky session tokens, are kept in PortableData\
next to the executable rather than in %APPDATA%, so they travel with this
folder. Copy the folder to a USB stick and it keeps its sign-in.

Requirements
  - Windows 10 or 11 (Mica needs a recent Windows 11 build; older versions
    fall back to an opaque window background).
  - The Spotify desktop app. Detection is through the Windows media
    transport controls, so the web player is not seen.
  - A Bluesky account and an app password from Bluesky's settings.

The window closes to the notification area and keeps scrobbling. Quit with
"End task" in the tray menu.

One thing this does leave on the host machine: showing toast notifications
requires a Start Menu shortcut carrying the app's identifier, which Windows
itself demands of desktop apps, so one is created at
  %APPDATA%\Microsoft\Windows\Start Menu\Programs\encore for rocksky.lnk
Deleting it after use costs nothing but the toasts on the next run.

This is an independent, unofficial app. It is not made by, endorsed by, or
affiliated with Bluesky, Bluesky Social PBC, or Rocksky.
"@ | Set-Content -Path (Join-Path $stageDir 'README.txt') -Encoding UTF8

Copy-Item (Join-Path $repoRoot 'LICENSE') (Join-Path $stageDir 'LICENSE.txt') -Force
if (Test-Path (Join-Path $repoRoot 'CREDITS.md')) {
    Copy-Item (Join-Path $repoRoot 'CREDITS.md') (Join-Path $stageDir 'CREDITS.txt') -Force
}

$sizeMb = [math]::Round(((Get-ChildItem $stageDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum / 1MB), 1)
Write-Host "  $stageDir ($sizeMb MB)" -ForegroundColor Green

if (-not $NoZip) {
    $zipPath = Join-Path $OutputDir "$stageName.zip"
    Write-Host 'Compressing...' -ForegroundColor Cyan
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal
    $zipMb = [math]::Round(((Get-Item $zipPath).Length / 1MB), 1)
    Write-Host "  $zipPath ($zipMb MB)" -ForegroundColor Green
}
