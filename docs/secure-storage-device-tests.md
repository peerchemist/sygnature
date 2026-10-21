# Secure-storage device tests

Connect an Android device with USB debugging enabled, accept its authorization
prompt, and find its ID with `flutter devices`. Run the non-interactive native
secure-storage lifecycle test in an isolated Android application:

```sh
ORG_GRADLE_PROJECT_secureStorageVerification=true \
  flutter test integration_test/secure_storage_test.dart -d <device-id>
```

To also test the Android device-authenticated store, run the suite with the
following Dart define and approve each authentication prompt on the device:

```sh
ORG_GRADLE_PROJECT_secureStorageVerification=true \
  flutter test integration_test/secure_storage_test.dart -d <device-id> \
  --dart-define=RUN_DEVICE_AUTH_STORAGE_TESTS=true
```

Run the native DKG secret-lifecycle suite in the same isolated application:

```sh
ORG_GRADLE_PROJECT_secureStorageVerification=true \
  flutter test integration_test/dkg_secret_lifecycle_test.dart -d <device-id> \
  --dart-define=RUN_DKG_SECRET_LIFECYCLE_TESTS=true
```

This suite checks encrypted-at-rest interrupted DKG state, cleanup after native
recovery, completion and rejection, absence from `AppLogger` output and backup
exports, and absence of secret plaintext from the Hive file. It guards against
running under the normal Android application ID before opening storage.

The isolated Android application ID prevents these tests from accessing an
installed Sygnature wallet.

## iOS Simulator Keychain and process restarts

Use a dedicated iOS Simulator with no wallet data. The iOS test uses the normal
application ID (`network.noosphere.sygnature`), so isolation comes from the
simulator rather than an alternate bundle ID. Find available runtime and device
type identifiers with `xcrun simctl list runtimes` and
`xcrun simctl list devicetypes`, then create and boot a test simulator:

```sh
xcrun simctl create Sygnature-Keychain-Verification \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl boot <simulator-id>
xcrun simctl bootstatus <simulator-id> -b
```

Run the shared lifecycle suite against the real `flutter_secure_storage`
Keychain backend (no mock or Android Gradle variable):

```sh
flutter test integration_test/secure_storage_test.dart -d <simulator-id>
```

Verify persistence and deletion across actual process restarts with the runner:

```sh
sh scripts/test_ios_keychain_restart.sh <simulator-id>
```

The runner builds with `RUN_IOS_KEYCHAIN_RESTART_TESTS=true`, installs once,
and launches the same binary three times using `simctl`. It reads Flutter's
unified simulator logs for each PID and requires both the expected phase's
success message and `All tests passed!`. A failure, unexpected phase or timeout
returns a nonzero exit code. The app is terminated on exit.

`flutter test` reinstalls the app, clears its sandbox and removes it when
finished; separate invocations cannot verify ordinary process restarts. The
standalone test stores its next phase in the sandbox rather than depending on
runtime environment overrides, which Dart on iOS does not expose here. The
restart checks use a plain test because they create no widgets; this also avoids
the widget wrapper's semantics-handle assertion during standalone app startup.

The write phase resets its own synthetic Keychain key, then leaves one value and
an app-sandbox PID marker. The read phase verifies the marker survived and the
PID changed, reads the value from Keychain, deletes it, and records its PID. The
cleanup phase checks another PID change, verifies both test keys are absent,
and removes the marker. The read phase deletes the Keychain value even if its
value assertion fails. If a run is interrupted, finish the remaining phases or start again on a
fresh dedicated simulator. Never uninstall the app or erase the simulator
between the write, read and cleanup phases.

These simulator checks cover Keychain access and Flutter's integration-test
runner configuration. They do not exercise physical-device authentication or
hardware-backed security. The optional device-authenticated test and the DKG
device suite remain Android-only.

### Verified 2026-10-21

Host: Flutter 3.47.7 / Dart 3.13.5, Xcode 27.0 (27A266a), Apple Silicon.
Device: dedicated iPhone 17 Pro simulator, iOS 26.5,
`19F9CAE8-89DF-4167-94C6-28A8D5F3065F`.

- Shared lifecycle: passed; Android-only authentication test skipped.
- Standalone restart runner: exit code 0; all three phases reported
  `All tests passed!`.

| Phase | Process ID | Verified |
| --- | --- | --- |
| Write | 73132 | Initial absence, write/read, sandbox marker persisted |
| Read | 73185 | New process, same sandbox, persisted Keychain value, deletion |
| Cleanup | 73217 | Another process, both Keychain test keys absent, marker removed |

The existing iOS plugin registration and Keychain configuration worked without
changes to entitlements or the Xcode test target. Flutter still reports the
existing `iroh_flutter` Swift Package Manager warning; CocoaPods builds work.
