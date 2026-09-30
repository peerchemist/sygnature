param(
    [string]$WorkRoot = "C:\SygnatureBuild"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is not available: $Name"
    }
}

function Mirror-Directory(
    [string]$Source,
    [string]$Destination,
    [string[]]$ExcludedDirectories = @()
) {
    $arguments = @(
        $Source,
        $Destination,
        "/MIR",
        "/R:2",
        "/W:1",
        "/NFL",
        "/NDL"
    )
    if ($ExcludedDirectories.Count -gt 0) {
        $arguments += "/XD"
        $arguments += $ExcludedDirectories
    }
    & robocopy @arguments
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
}

foreach ($command in @("flutter", "git", "rustc")) {
    Require-Command $command
}

$sharedRoot = "Z:\"
$projectSource = Join-Path $sharedRoot "sygnature_ng"
$noosphereSource = Join-Path $sharedRoot "noosphere"
if (-not (Test-Path $projectSource)) {
    throw "Sygnature share is unavailable at $projectSource"
}
if (-not (Test-Path $noosphereSource)) {
    throw "Noosphere share is unavailable at $noosphereSource"
}

$projectCopy = Join-Path $WorkRoot "sygnature_ng"
$noosphereCopy = Join-Path $WorkRoot "noosphere"
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

Write-Host "Copying sources to the Windows disk..."
Mirror-Directory $projectSource $projectCopy @(
    ".dart_tool",
    ".windows-builder",
    "build"
)
Mirror-Directory $noosphereSource $noosphereCopy @(
    ".dart_tool",
    "build"
)

Push-Location $projectCopy
try {
    flutter --version
    rustc --version
    flutter config --enable-windows-desktop
    flutter pub get
    flutter build windows --release --no-pub
} finally {
    Pop-Location
}

$releaseDirectory = Join-Path $projectCopy "build\windows\x64\runner\Release"
$executable = Join-Path $releaseDirectory "sygnature.exe"
if (-not (Test-Path $executable)) {
    throw "Flutter did not create the expected executable: $executable"
}

$hostOutput = Join-Path $projectSource "build\windows-local"
Write-Host "Copying the release bundle back to the Linux host..."
Mirror-Directory $releaseDirectory $hostOutput

$archive = Join-Path $projectSource "build\sygnature-windows-x64.zip"
Compress-Archive -Path (Join-Path $hostOutput "*") -DestinationPath $archive -Force

Write-Host "Windows executable: $(Join-Path $hostOutput 'sygnature.exe')"
Write-Host "Windows bundle: $archive"
