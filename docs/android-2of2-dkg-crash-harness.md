# Android 2-of-2 DKG crash harness

This harness verifies that an Android signer resumes a DKG after its process is
killed during round 2. The Linux side owns the coordinator and participant 1;
the Android emulator owns participant 2. All identities and payloads are public,
deterministic test data and must never be used with funds.

The entrypoints are:

- `test/support/roast_2of2_crash_linux.dart`
- `test/support/roast_2of2_crash_device.dart`
- `test/support/roast_2of2_crash_common.dart`

Build the device entrypoint with the isolated verification application ID:

```sh
ORG_GRADLE_PROJECT_publicFeedVerification=true \
  flutter build apk --debug \
  --target=test/support/roast_2of2_crash_device.dart
```

Confirm that the APK package is
`network.noosphere.sygnature.publicfeedtest`, then install it and clear that
package. Do not install the harness over `network.noosphere.sygnature`.

Start the Linux process with a private temporary configuration path:

```sh
dart run test/support/roast_2of2_crash_linux.dart \
  /tmp/sygnature-2of2-crash-config.json
```

Copy that JSON file into the test package's application-support `files`
directory as `crash_device_config.json`, then launch its `MainActivity`. Wait
until `crash_device_status.json` reports `connected=true` and one online peer.

Send `dkg-offline` to the Linux process. It requests the DKG and disconnects
participant 1, preventing the ceremony from completing too early. Wait for the
Android status file to contain all of:

```json
{"keys":0,"dkgStage":"round2","dkgCanResume":true,"onlinePeers":0}
```

Send the activity to Home and use `adb shell am kill` for the test package. Do
not use `force-stop` or clear package data. Confirm its PID disappears and the
package remains `stopped=false`. Some emulator images retain a previous-process
for a while; if its PID does not disappear, send `kill -9` through `run-as` for
that package. This models a process crash without putting the package into
Android's stopped state.

Send `reconnect` to Linux while Android is dead, then relaunch Android. A pass
requires Android to report `phase=dkg-restored`, `keys=1`, no active DKG, and
no error. Send `sign` to Linux. The final cryptographic assertion is:

```text
SIGNATURE VERIFIED: true
```

The Android status should finish with `phase=signature-approved`, `keys=1`,
and `error=null`. Send `quit` to stop the Linux coordinator cleanly.
