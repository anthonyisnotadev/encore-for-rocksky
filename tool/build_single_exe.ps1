#Requires -Version 5.1
<#
.SYNOPSIS
    Builds encore for rocksky as one self-contained .exe.

.DESCRIPTION
    Flutter's Windows output is a directory: the .exe is a host stub that loads
    flutter_windows.dll and reads data\ beside itself, so it cannot be handed
    out on its own. This packs that whole directory into a cabinet, embeds it as
    a resource in the launcher from tool\sfx, and produces a single file.

    Running it unpacks into a private folder under %TEMP%, starts the app, and
    deletes the unpacked copy when the app exits. Nothing is installed.

    Everything used here already ships with Windows or with the Visual Studio
    C++ toolchain that `flutter build windows` requires, so this adds no build
    dependency beyond what the project already needs.

.PARAMETER OutputName
    Filename to produce. Defaults to encore-for-rocksky.exe.

.PARAMETER SkipBuild
    Pack the existing Release output instead of rebuilding.

.PARAMETER KeepIntermediates
    Leave build\sfx\ in place for inspection.

.EXAMPLE
    pwsh -File tool\build_single_exe.ps1

.EXAMPLE
    pwsh -File tool\build_single_exe.ps1 -OutputName rockstar.exe
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'encore-for-rocksky.exe',
    [switch]$SkipBuild,
    [switch]$KeepIntermediates
)

$ErrorActionPreference = 'Stop'

# Runs a native command, collecting stdout and stderr together and leaving its
# exit code in $script:LastNativeExit. Without this, 'Stop' turns any stderr
# output from a native tool into a terminating error regardless of exit code,
# and both makecab and the compiler write ordinary progress there.
function Invoke-NativeCapture {
    param([scriptblock]$Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Command
        $script:LastNativeExit = $LASTEXITCODE
        return $output
    } finally {
        $ErrorActionPreference = $previous
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$sfxSrc = Join-Path $PSScriptRoot 'sfx'
$stageDir = Join-Path $repoRoot 'build\sfx'
$outputDir = Join-Path $repoRoot 'build\portable'

if ($OutputName -notmatch '\.exe$') { $OutputName = "$OutputName.exe" }
if ($OutputName -match '[\\/:*?"<>|]') { throw "OutputName must be a filename, not a path: $OutputName" }

# --- Version, for the .exe's version resource ------------------------------

$pubspec = Get-Content (Join-Path $repoRoot 'pubspec.yaml') -Raw
if ($pubspec -match '(?m)^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?') {
    # Windows version resources are four numbers; pubspec's +build suffix
    # supplies the fourth, defaulting to 0 when it is absent.
    $buildNumber = if ($Matches[4]) { $Matches[4] } else { '0' }
    $verParts = @($Matches[1], $Matches[2], $Matches[3], $buildNumber)
} else {
    throw 'Could not read version: from pubspec.yaml'
}
$versionCsv = $verParts -join ','
$versionStr = $verParts -join '.'

# --- Toolchain -------------------------------------------------------------

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found. Visual Studio with the C++ workload is required (the same toolchain `flutter build windows` uses)." }

$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsPath) { throw 'No Visual Studio installation with the C++ build tools was found.' }

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsPath" }

$makecab = Join-Path $env:SystemRoot 'System32\makecab.exe'
if (-not (Test-Path $makecab)) { throw 'makecab.exe not found in System32.' }

# --- Application build -----------------------------------------------------

if (-not $SkipBuild) {
    Write-Host 'Building Windows release...' -ForegroundColor Cyan
    # No --dart-define=ENABLE_SPOTIFY_IMPORT: the experimental import can
    # irreversibly delete records from a user's PDS and must not ship in a
    # distributable build. See lib/feature_flags.dart.
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path $releaseDir)) { throw "No release build at $releaseDir. Run without -SkipBuild." }

# --- Stage -----------------------------------------------------------------

if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Cabinet directive file. Each line pairs a source path with the name the file
# takes inside the cabinet; that second name carries the relative path, which is
# what preserves data\flutter_assets\... on extraction.
$payloadFiles = Get-ChildItem $releaseDir -Recurse -File
$ddfLines = @(
    '.OPTION EXPLICIT'
    '.Set CabinetNameTemplate=payload.cab'
    ".Set DiskDirectory1=`"$stageDir`""
    '.Set Cabinet=on'
    '.Set Compress=on'
    # LZX with the largest window the format allows. Slower to pack than MSZIP,
    # and roughly halves the payload.
    '.Set CompressionType=LZX'
    '.Set CompressionMemory=21'
    # A single cabinet of unlimited size, rather than floppy-sized volumes.
    '.Set MaxDiskSize=0'
    '.Set UniqueFiles=off'
    ".Set InfFileName=`"$(Join-Path $stageDir 'setup.inf')`""
    ".Set RptFileName=`"$(Join-Path $stageDir 'setup.rpt')`""
)
foreach ($file in $payloadFiles) {
    $relative = $file.FullName.Substring($releaseDir.Length).TrimStart('\')
    $ddfLines += "`"$($file.FullName)`" `"$relative`""
}
$ddfPath = Join-Path $stageDir 'payload.ddf'
$ddfLines | Set-Content $ddfPath -Encoding ASCII

Write-Host "Packing $($payloadFiles.Count) files..." -ForegroundColor Cyan
$cabLog = Invoke-NativeCapture { & $makecab /F $ddfPath 2>&1 }
if ($script:LastNativeExit -ne 0) {
    $cabLog | Write-Host
    throw "makecab failed with exit code $script:LastNativeExit"
}
$cabPath = Join-Path $stageDir 'payload.cab'
if (-not (Test-Path $cabPath)) { throw 'makecab reported success but produced no payload.cab' }

$rawMb = [math]::Round((($payloadFiles | Measure-Object Length -Sum).Sum / 1MB), 1)
$cabMb = [math]::Round(((Get-Item $cabPath).Length / 1MB), 1)
Write-Host "  $rawMb MB -> $cabMb MB" -ForegroundColor DarkGray

# Resource compilation resolves these by bare filename, so they have to sit
# next to the .rc in the staging directory.
Copy-Item (Join-Path $sfxSrc 'sfx.rc') $stageDir
Copy-Item (Join-Path $sfxSrc 'sfx.manifest') $stageDir
Copy-Item (Join-Path $sfxSrc 'sfx_stub.cpp') $stageDir
Copy-Item (Join-Path $repoRoot 'assets\app_icon.ico') $stageDir

@"
// Generated by tool\build_single_exe.ps1 from the version in pubspec.yaml.
// Edits here are overwritten on the next build.
#define SFX_VERSION_CSV $versionCsv
#define SFX_VERSION_STR "$versionStr"
"@ | Set-Content (Join-Path $stageDir 'sfx_version.h') -Encoding ASCII

# --- Compile and link ------------------------------------------------------

Write-Host 'Compiling launcher...' -ForegroundColor Cyan
$outputPath = Join-Path $outputDir $OutputName

# /MT statically links the C runtime, so the result needs no Visual C++
# redistributable on the machines it is handed to. /O1 favours size: the stub's
# work is dominated by disk and decompression, not by its own code.
$build = @(
    # Silenced because vcvars64.bat probes for vswhere.exe on PATH, does not
    # find it, prints "not recognized" and carries on successfully. That noise
    # would otherwise look like a failure.
    "call `"$vcvars`" >nul 2>&1"
    "cd /d `"$stageDir`""
    'rc.exe /nologo /fo sfx.res sfx.rc'
    'cl.exe /nologo /O1 /MT /EHsc /W4 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN sfx_stub.cpp sfx.res /Fe:launcher.exe /link /SUBSYSTEM:WINDOWS /ENTRY:wWinMainCRTStartup'
# && both short-circuits and leaves the failing command's exit code as cmd's
# own, so no explicit errorlevel checks are wanted here. An `if errorlevel 1
# exit /b 1` between these would swallow the rest of the chain instead of
# guarding it: && binds inside the if body, so the steps after it become part
# of the branch that only runs on failure.
) -join ' && '

# Merging stderr into the pipeline turns anything a native tool writes there
# into a PowerShell error record, which $ErrorActionPreference = 'Stop' treats
# as terminating — even when the tool succeeds. Compilers write warnings to
# stderr routinely, so exit codes have to be what decides success here.
$compileLog = Invoke-NativeCapture { & cmd.exe /c $build 2>&1 }
$launcher = Join-Path $stageDir 'launcher.exe'
# Checked as well as the exit code: a chain of native tools behind cmd /c has
# more ways to report success without producing anything than is comfortable.
if ($script:LastNativeExit -ne 0 -or -not (Test-Path $launcher)) {
    $compileLog | Write-Host
    throw "Compiling the launcher failed (exit code $script:LastNativeExit)"
}

Copy-Item $launcher $outputPath -Force
if (-not $KeepIntermediates) { Remove-Item $stageDir -Recurse -Force }

$outMb = [math]::Round(((Get-Item $outputPath).Length / 1MB), 1)
Write-Host "  $outputPath ($outMb MB)" -ForegroundColor Green
Write-Host ''
Write-Host 'Hand this single file out. It is unsigned, so SmartScreen will warn' -ForegroundColor DarkGray
Write-Host 'on first run until enough people have run it.' -ForegroundColor DarkGray
