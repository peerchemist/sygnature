# Building Sygnature

Sygnature targets Android, Linux, Windows and macOS. Automated equivalents of
these builds are defined in [GitHub Actions](../.github/workflows).

The Linux, Windows and macOS build workflows run for every pushed Git tag and
can also be started manually. The Android workflow is temporarily manual-only.
Together they upload an Android APK, Linux Flatpak, Windows x64 bundle and macOS
ARM64 DMG as workflow artifacts. Manual triggers are useful for testing a
release build or warming its dependency caches before creating a tag.

Tag builds also create a GitHub Release and attach the Flatpak, DMG and Windows
EXE installer. Tags containing a hyphen, such as `0.9.7-alfa`, create a prerelease.
Rerunning a tag build replaces its release asset. Manual builds on a branch
only upload workflow artifacts; Android does not publish to Releases.

## Source dependencies

`pubspec.yaml` fetches Noosphere directly from GitHub at the pinned commit
`fafb28dba31a2d3acc17d9c90060a3ad46d7300d`; no sibling checkout is required.
Android and macOS builds require Git, Flutter 3.47.5, Rust and the native
toolchain for their target platform. The Linux Flatpak and Windows VM scripts
provision their own SDKs.

## Android APK

Building and installing on a connected, authorized Android device requires
Flutter, the Android SDK, Java 17 and `adb`:

```sh
scripts/build_android --release
```

Use `--device SERIAL` when multiple devices are connected. For a build without
installation, run:

```sh
flutter pub get
flutter build apk --release --no-pub
```

The release APK is written to
`build/app/outputs/flutter-apk/app-release.apk`.

## Linux Flatpak

Install `flatpak` and `flatpak-builder`, then run:

```sh
scripts/build_flatpak
```

The script installs the required Freedesktop 26.08 runtime and SDK for the
current user. The bundle is written to
`build/flatpak/network.noosphere.sygnature.flatpak`.

## Windows application

On a Linux host with Podman, KVM and TUN support, start the persistent
`dockur/windows` VM:

```sh
scripts/build_windows start
```

The default Windows credentials are `Docker` / `admin`. Set
`SYGNATURE_WINDOWS_PASSWORD` before the first start to choose another password.
Open `http://127.0.0.1:8006`, wait for the Windows desktop, then use an RDP
client at `127.0.0.1:3389` if clipboard support is needed.

Open `Z:\sygnature_ng\scripts` in Windows File Explorer and double-click
`build_windows.cmd`. The launcher keeps the terminal open so the result remains
visible.

The equivalent PowerShell command is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Z:\sygnature_ng\scripts\build_windows.ps1"
```

The PowerShell script automatically installs portable Git, Flutter 3.47.5,
stable Rust and Visual Studio Build Tools with the **C++ build tools** workload.
The installed C++ components include MSVC, CMake and ATL as required by the
Windows Flutter plugins. Windows might show one administrator confirmation for
the Visual Studio installer. Downloads and the VM disk are retained for
subsequent builds.

The completed Windows bundle is copied to:

```text
build/windows-local/sygnature.exe
build/sygnature-windows-x64.zip
```

Distribute the ZIP or the complete `windows-local` directory because the EXE
requires the adjacent DLLs and `data` directory. GitHub Actions additionally
packages the complete bundle and Visual C++ runtime into
`build/Sygnature-Windows-x64-Setup.exe` using Inno Setup. The installer installs
for the current user without administrator privileges.

Stop the VM gracefully with:

```sh
scripts/build_windows stop
```

## macOS DMG

On macOS with Xcode and Flutter 3.47.5 installed, run:

```sh
flutter pub get
scripts/build_macos --no-pub
```

The result is `build/Sygnature-macOS.dmg`, containing the ARM64 `Sygnature.app`
and an Applications shortcut. Xcode ad-hoc signs the app with its sandbox and
network entitlements; the script then re-signs the complete staged bundle with
one ad-hoc identity and verifies it before packaging. No Apple signing
certificate or provisioning profile is required, including on CI runners.
The testing build disables hardened runtime so macOS can load its ad-hoc signed
frameworks, which have no Apple Team ID. The app sandbox remains enabled.

The app is not notarized. Testers should drag it into Applications and try to
open it. If macOS blocks it, use **System Settings > Privacy & Security > Open
Anyway**. For distribution without this manual approval, use a Developer ID
signing and notarization workflow.

Use `--output PATH.dmg` to choose another output path. Additional arguments,
such as `--build-name` and `--build-number`, are passed to Flutter.
