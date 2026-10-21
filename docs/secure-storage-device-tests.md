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
installed Sygnature wallet. On macOS, the non-interactive Keychain test can be
run on an iOS Simulator or connected iPhone with the first command, without the
Android-only Gradle environment variable.
