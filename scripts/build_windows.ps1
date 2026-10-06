param(
    [string]$WorkRoot = "C:\SygnatureBuild"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProgressPreference = "SilentlyContinue"

$flutterVersion = "3.47.5"
$flutterSha256 = "0ccd71931f49c2fbe394b1eeb6d79af3d624058a043ea0d03d34160581624fb8"
$toolRoot = Join-Path $env:LOCALAPPDATA "SygnatureBuild\tools"
$downloadRoot = Join-Path $env:TEMP "SygnatureBuildDownloads"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Add-ProcessPath([string]$Directory) {
    if ($env:Path.Split(";") -notcontains $Directory) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Download-File([string]$Uri, [string]$Destination) {
    Write-Host "Downloading $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

function Assert-Sha256([string]$Path, [string]$ExpectedHash) {
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actualHash -ne $ExpectedHash) {
        throw "SHA-256 mismatch for ${Path}: expected $ExpectedHash, got $actualHash"
    }
}

function Ensure-Git {
    $gitRoot = Join-Path $toolRoot "git"
    $gitBin = Join-Path $gitRoot "cmd"
    if (Test-Path (Join-Path $gitBin "git.exe")) {
        Add-ProcessPath $gitBin
        return
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        return
    }

    Write-Host "Installing portable Git..."
    $headers = @{ "User-Agent" = "sygnature-windows-builder" }
    $release = Invoke-RestMethod `
        -Headers $headers `
        -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest"
    $asset = @($release.assets | Where-Object {
        $_.name -match '^MinGit-.+-64-bit\.zip$'
    }) | Select-Object -First 1
    if (-not $asset) {
        throw "The latest Git for Windows release has no 64-bit MinGit archive"
    }

    $archive = Join-Path $downloadRoot $asset.name
    Download-File $asset.browser_download_url $archive
    $digest = $asset.PSObject.Properties["digest"]
    if ($digest -and $digest.Value -and $digest.Value.StartsWith("sha256:")) {
        Assert-Sha256 $archive $digest.Value.Substring(7)
    }
    New-Item -ItemType Directory -Path $gitRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $gitRoot -Force
    Add-ProcessPath $gitBin
}

function Ensure-Flutter {
    $flutterRoot = Join-Path $toolRoot "flutter"
    $versionMarker = Join-Path $flutterRoot ".sygnature-version"
    $installedVersion = if (Test-Path $versionMarker) {
        (Get-Content -Raw -LiteralPath $versionMarker).Trim()
    } else {
        ""
    }

    if ($installedVersion -ne $flutterVersion) {
        Write-Host "Installing Flutter $flutterVersion..."
        $archive = Join-Path $downloadRoot "flutter_windows_${flutterVersion}-stable.zip"
        if ((Test-Path $archive) -and
            ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $flutterSha256)) {
            Remove-Item -LiteralPath $archive -Force
        }
        if (-not (Test-Path $archive)) {
            Download-File `
                "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_${flutterVersion}-stable.zip" `
                $archive
        }
        Assert-Sha256 $archive $flutterSha256
        if (Test-Path $flutterRoot) {
            Remove-Item -LiteralPath $flutterRoot -Recurse -Force
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $toolRoot -Force
        Set-Content -LiteralPath $versionMarker -Value $flutterVersion
    }

    Add-ProcessPath (Join-Path $flutterRoot "bin")
}

function Ensure-Rust {
    $cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
    Add-ProcessPath $cargoBin
    if ((Get-Command rustc -ErrorAction SilentlyContinue) -and
        (Get-Command cargo -ErrorAction SilentlyContinue)) {
        return
    }

    Write-Host "Installing the stable Rust toolchain..."
    $rustup = Join-Path $downloadRoot "rustup-init.exe"
    Download-File "https://win.rustup.rs/x86_64" $rustup
    & $rustup -y --profile minimal --default-toolchain stable
    if ($LASTEXITCODE -ne 0) {
        throw "rustup failed with exit code $LASTEXITCODE"
    }
    Add-ProcessPath $cargoBin
}

function Find-VisualStudio {
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} `
        "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vsWhere)) {
        return $null
    }
    $requirements = @(
        "-latest",
        "-products", "*",
        "-requires",
        "Microsoft.VisualStudio.Workload.VCTools",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "Microsoft.VisualStudio.Component.VC.CMake.Project",
        "Microsoft.VisualStudio.Component.VC.ATL",
        "-property", "installationPath"
    )
    $installation = & $vsWhere @requirements
    if ($LASTEXITCODE -ne 0 -or -not $installation) {
        return $null
    }
    return $installation
}

function Ensure-VisualStudio {
    if (Find-VisualStudio) {
        return
    }

    Write-Host "Installing Visual Studio C++ build tools..."
    Write-Host "Windows may ask you to approve this installer."
    $installer = Join-Path $downloadRoot "vs_BuildTools.exe"
    Download-File "https://aka.ms/vs/17/release/vs_BuildTools.exe" $installer
    $arguments = @(
        "--quiet",
        "--wait",
        "--norestart",
        "--nocache",
        "--installPath", "C:\BuildTools",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
        "--add", "Microsoft.VisualStudio.Component.VC.ATL",
        "--includeRecommended"
    )
    $process = Start-Process `
        -FilePath $installer `
        -ArgumentList $arguments `
        -Verb RunAs `
        -Wait `
        -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Visual Studio Build Tools installer failed with exit code $($process.ExitCode)"
    }
    if (-not (Find-VisualStudio)) {
        throw "Visual Studio C++ workload was not detected after installation"
    }
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is not available: $Name"
    }
}

function Assert-NativeSuccess([string]$Description, [int]$ExitCode) {
    if ($ExitCode -ne 0) {
        throw "$Description failed with exit code $ExitCode"
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

$sharedRoot = "Z:\"
$projectSource = Join-Path $sharedRoot "sygnature_ng"
if (-not (Test-Path $projectSource)) {
    throw "Sygnature share is unavailable at $projectSource"
}

New-Item -ItemType Directory -Path $toolRoot, $downloadRoot -Force | Out-Null
Ensure-Git
Ensure-Flutter
Ensure-Rust
Ensure-VisualStudio

foreach ($command in @("flutter", "git", "rustc", "cargo")) {
    Require-Command $command
}

$projectCopy = Join-Path $WorkRoot "sygnature_ng"
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

foreach ($generatedDirectory in @(
    (Join-Path $projectCopy ".flatpak-builder"),
    (Join-Path $projectCopy "linux\flutter\ephemeral"),
    (Join-Path $projectCopy "windows\flutter\ephemeral")
)) {
    if (Test-Path $generatedDirectory) {
        Remove-Item -LiteralPath $generatedDirectory -Recurse -Force
    }
}

Write-Host "Copying sources to the Windows disk..."
Mirror-Directory $projectSource $projectCopy @(
    ".dart_tool",
    ".flatpak-builder",
    ".windows-builder",
    "ephemeral",
    "build"
)
Push-Location $projectCopy
try {
    flutter --version
    Assert-NativeSuccess "flutter --version" $LASTEXITCODE
    rustc --version
    Assert-NativeSuccess "rustc --version" $LASTEXITCODE
    flutter config --enable-windows-desktop
    Assert-NativeSuccess "flutter config" $LASTEXITCODE
    flutter clean
    Assert-NativeSuccess "flutter clean" $LASTEXITCODE
    Remove-Item -LiteralPath ".flutter-plugins-dependencies" `
        -Force `
        -ErrorAction SilentlyContinue
    flutter pub get
    Assert-NativeSuccess "flutter pub get" $LASTEXITCODE
    flutter build windows --release --no-pub
    Assert-NativeSuccess "flutter build windows" $LASTEXITCODE
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
