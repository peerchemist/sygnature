# Building Sygnature

Sygnature targets Android, Linux, Windows and macOS. Automated equivalents of
these builds are defined in [GitHub Actions](../.github/workflows).

The Linux, Windows and macOS build workflows run for every pushed Git tag and
can also be started manually. The Android workflow is temporarily manual-only.
Together they upload an Android APK, Linux Flatpak, Windows x64 bundle and macOS
ARM64 and Intel DMGs as workflow artifacts. Manual triggers are useful for testing a
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

The macOS workflow requires five repository secrets: `APPLE_CERTIFICATE_BASE64`
(the base64-encoded Developer ID Application `.p12`, including its private key),
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD` (an Apple ID
app-specific password), and `APPLE_TEAM_ID`. Create the certificate in Xcode's
Accounts settings and export it from Keychain Access. Never commit credentials.

Both architecture jobs import the identity into an isolated temporary Keychain,
validate notarization credentials, and build using the existing Flutter/Xcode
process. The script signs native code and enclosing bundles from the inside out,
with secure timestamps and hardened runtime, preserving the main app's sandbox
and network entitlements. It notarizes and staples the app before creating the
DMG, then signs, notarizes, and staples the DMG. Signature, stapling, and Gatekeeper
checks must pass before artifact upload. A separate release job waits for both
architecture jobs to succeed before publishing the macOS assets. Other platform
workflows can still independently create a shared GitHub Release.

Apple credential authentication, ticket stapling/validation, and Gatekeeper
assessment retry recognized transport failures up to four attempts, waiting
10, 20, and 40 seconds. Invalid signatures, rejected assessments, and unknown
errors fail immediately. Notarization uploads are not automatically repeated,
since losing an upload response could otherwise duplicate a submission. All
existing checks must still succeed before an artifact is uploaded or published.

For a local build, save notarization credentials using the secure interactive
prompt (substitute your Apple Developer account email):

```sh
xcrun notarytool store-credentials Sygnature-GitHub-Actions \
  --apple-id YOUR_APPLE_ID --team-id V274DD3UKN
```

Then select your Developer ID identity from `security find-identity -v -p
codesigning` and run:

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Alchemy d.o.o. (V274DD3UKN)'
export APPLE_TEAM_ID=V274DD3UKN
export NOTARYTOOL_PROFILE=Sygnature-GitHub-Actions
flutter pub get
scripts/build_macos --no-pub
```

The result is `build/Sygnature-macOS.dmg`, containing `Sygnature.app` and an
Applications shortcut. Both architectures target macOS 12.0 or newer. Use
`--arch x86_64` for Intel, and `--output PATH.dmg` to choose another output path.
Additional options, such as `--build-name` and `--build-number`, go to Flutter.
Missing signing credentials or rejected notarization fail the build; there is
no ad-hoc distribution fallback.

Manual runs upload workflow artifacts. Tags also publish release assets; tags
containing a hyphen create prereleases. GitHub Release assets inherit repository
visibility, so a prerelease on a public repository is still publicly accessible.
For a private beta on a public repository, use a manual run and control access
to the downloaded DMGs separately.

Automated signature and Gatekeeper checks do not verify installation or launch.
Before sending a beta to testers, download the DMG through a browser on a clean
Mac, install it through Finder, and launch it normally with Gatekeeper enabled.
