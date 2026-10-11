# Android 14 background public-feed test log

Date: 2026-10-11 (Europe/Zagreb)
Repository start revision: `97efd2f`
Target AVD: `Pixel_Android_14`
Target package: `network.noosphere.sygnature.publicfeedtest`

## Scope

Validate the isolated Android public-feed harness and WorkManager behavior without loading a real wallet or using real wallet data. The intended end-to-end path is a synthetic coordinator, a public operation-feed event, background/process termination, periodic worker execution, notification deduplication, and cursor persistence.

## Expected behavior

- The verification APK uses the separate `network.noosphere.sygnature.publicfeedtest` application ID.
- The app loads no wallet, mnemonic, participant key, FROST share, or authenticated signer session.
- Foreground startup subscribes from an app-private synthetic share and performs one poll.
- Android registers one unique, connected-network periodic job with a 15-minute minimum interval.
- After the app process is removed (but not force-stopped), WorkManager can later fetch a newly retained public event.
- A fresh eligible request produces one generic notification; rerunning the worker does not duplicate it.
- Cursor/outbox state survives app and worker process restarts.
- Force-stop prevents background work until the user launches the app again.

## Chronological log

### 16:41 — Preflight

- Confirmed a clean worktree at revision `97efd2f`.
- Confirmed WorkManager implementation (`448e599`) and isolated device harness (`57acd21`) are present.
- Confirmed configured Android 14 AVD: `Pixel_Android_14`.
- Confirmed release manifest includes `INTERNET`, `POST_NOTIFICATIONS`, and `USE_BIOMETRIC`.

Observed deviation (test infrastructure): the first sandboxed `adb devices -l` invocation could not start the ADB server because the sandbox denied the smart-socket listener. This is not an application failure. Relevant error:

```text
Failed to open netlink socket: Operation not permitted
could not install *smartsocket* listener: Operation not permitted
adb: failed to check server version: cannot connect to daemon
```

Next action: start ADB and `Pixel_Android_14` outside the filesystem/process sandbox, then wait for Android boot completion.

### 16:44 — Emulator boot

- Started `Pixel_Android_14` from a cold boot.
- Verified guest version `14`, API level `34`, model `sdk_gphone64_x86_64`.
- Dismissed the keyguard and verified airplane mode is off.

Result: pass.

### 17:09 — Post-worker status inspection

Observed deviation (verification UI only): the status button displayed cursor 0 because it selected the first retained feed record. The store intentionally retains old feed-scoped cursor records, and this run had used multiple fresh synthetic feeds. The UI did not follow the active `device-check` binding.

Impact: display-only; notification delivery and successful worker completion remain observed. The verification entrypoint was corrected to resolve `bindings['device-check']` and display that feed's cursor. No production code changed.

- Rebuilt and reinstalled while preserving the verification package data.
- Corrected UI confirmed the active feed at `Cursor: 1. Issue: none`.

Result: pass after harness-only correction.

### 17:12 — Durable notification deduplication

- Scheduled the same headless callback again without adding another coordinator event.
- Killed the app process before execution.
- Android started another fresh headless process and WorkManager reported `SUCCESS`.
- Notification Manager counters remained unchanged:

```text
numEnqueuedByApp=1
numPostedByApp=1
numUpdatedByApp=0
```

Result: pass. A process restart and repeated background poll did not produce or update a duplicate notification for cursor 1.

### 17:15 — Android force-stop and manual catch-up

- Opened the verification UI, scheduled another 30-second one-off run, returned Home, and force-stopped only the verification package.
- Device package state confirmed `stopped=true`.
- Coordinator committed a second event while the app was force-stopped.
- Observed longer than the prior one-off execution latency. No app process or WorkManager execution started while stopped.
- Manually launched the app. This cleared the stopped state and foreground polling immediately caught up.
- Active feed status became `Cursor: 2. Issue: none`.
- A second generic notification appeared with the next durable ID, `1073741825`.
- Notification counters became two enqueues/posts and zero updates.

Relevant force-stop log:

```text
ActivityManager: Force stopping network.noosphere.sygnature.publicfeedtest
ActivityManager: Killing ... stop network.noosphere.sygnature.publicfeedtest
```

No worker start appears between force-stop and manual relaunch.

Result: pass. Force-stop prevents background execution, but a later user launch catches up retained events and advances the durable cursor.

## Deviations and risks found

1. The host `PATH` resolved `clang` to an invalid direct ccache symlink. Tests/builds work after excluding `/usr/lib64/ccache`; this is a workstation configuration issue.
2. The original synthetic coordinator kept a one-minute Noosphere session past its TTL. It now authenticates immediately before each synthetic event; production code was not affected.
3. The original verification status selected the first retained feed rather than the active binding. It now follows `bindings['device-check']`; production code was not affected.
4. Flutter warns that the current `workmanager_android` plugin applies legacy KGP and will need a future Built-in Kotlin-compatible release.
5. Emulator Iroh startup emits SELinux denials for optional `/proc` and `/sys` network inspection, but transport, polling, commit, and notification all succeeded.
6. The first phase verified registration/JobScheduler state and used a verification-only one-off task for immediate headless execution. The later 2-of-3 phase below also observed an unforced natural periodic run.
7. The original five-minute notification policy conflicted with WorkManager's minimum interval. It was subsequently replaced by a user-configurable 15-minute-to-24-hour window, defaulting to one hour; the later phase below validates a request first observed after more than 15 minutes.

## Current result

- Normal background/process death: headless polling, durable cursor commit, and one generic notification passed.
- Repeated process death/poll: notification deduplication passed.
- Force-stop: background work remained blocked as expected; manual relaunch catch-up passed.
- No real wallet, mnemonic, FROST share, or signer session was loaded by Android.
- This cycle validates the public-feed/WorkManager path. A complete three-device 2-of-3 message-signing ceremony remains a separate E2E phase.

## Final verification

- `flutter analyze test/support/android_public_feed_device_app.dart test/support/public_feed_device_coordinator.dart`: no issues.
- `git diff --check`: clean.
- Synthetic coordinator shut down normally after the test.
- Android 14 emulator remains running for the next E2E phase.

## Real 2-of-3 message-signing E2E phase

### Scope and topology

- Linux process: one real Noosphere coordinator plus desktop participants 1 and 2.
- Android 14 emulator: real participant 3, with its FROST share in the app's durable encrypted client storage.
- Threshold: 2-of-3. Desktop participant 1 requested the signature; Android participant 3 supplied the second signing share. Desktop participant 2 remained online but did not sign.
- Payload: a synthetic text message only; no coins, wallet mnemonic, production key, or production application data was used.
- Public-feed and signer transports were pinned to the same ephemeral coordinator identity. Capability values and private material are intentionally omitted from this log.

The test-only files are `test/support/roast_2of3_device_coordinator.dart` and `test/support/android_public_feed_device_app.dart`. They are reachable only through the dedicated test entrypoint/application ID.

### 17:31–17:39 — Harness validation and DKG

- Static analysis of both test harnesses completed with no issues.
- Built and installed the dedicated `network.noosphere.sygnature.publicfeedtest` APK.
- Started a real coordinator and two authenticated desktop clients on Linux.
- Android connected as participant 3 and reported two online peers.
- Desktop participant 1 requested a 2-of-3 DKG; desktop participant 2 and Android participant 3 accepted it.
- Android reported one completed key, and both desktop stores reported one key.
- The Android test entrypoint then polled the public feed while foregrounded to establish a clean post-DKG baseline. The cursor was `2`, with no issue.

Result: pass. All three clients completed the real DKG, and Android durably stored its share.

Observed harness correction: the first attempted run did not advance the public cursor after DKG, so a later worker would have seen both the old DKG event and the new signing event. That run was discarded before its job became due. The test-only DKG action now waits for key completion and establishes the foreground cursor baseline. No production behavior changed.

### 17:39–17:55 — Process death and natural WorkManager pickup

- At `17:39:33+02:00`, sent the Android activity to Home and killed only its process with `am kill`; the package was not force-stopped.
- Confirmed no Android application process remained.
- The desktop requester committed a one-hour message-signing request immediately afterward.
- Did not use `cmd jobscheduler run`, expedited work, the one-off test action, or a foreground service for this pickup.
- JobScheduler initially reported the registered periodic job with approximately 13 minutes 36 seconds until its earliest run, later transitioning to `Ready: true` and `RUNNABLE`.
- Turned the emulator screen off to model a sleeping phone. Android naturally started the package at `17:55:27` for `SystemJobService`.
- WorkManager loaded a headless Flutter engine and completed successfully at `17:55:29`.

Relevant log:

```text
ActivityManager: Start proc ... network.noosphere.sygnature.publicfeedtest ... for SystemJobService
WM-WorkerWrapper: Starting work for dev.fluttercommunity.workmanager.BackgroundWorker
FlutterJNI: Beginning load of flutter...
WM-WorkerWrapper: Worker result SUCCESS
```

Timing result:

- Signing request age at worker start: approximately 15 minutes 53 seconds.
- Worker start was approximately two minutes after JobScheduler's earliest-run threshold, demonstrating expected inexact batching.
- This is beyond the former five-minute cutoff and inside the configured/default one-hour notification window.

Notification Manager contained exactly one active notification for the isolated package:

```text
id=1073741824
android.title=New signing request
android.text=Open Sygnature and unlock your wallet to review current requests.
```

No message body, signer identity, coordinator capability, or operation detail appeared in the notification.

Result: pass. A natural periodic WorkManager cycle found and notified about a request created while the app process did not exist.

### 17:56–17:58 — User catch-up, approval, signature, and dedup

- Reopened the Android app manually.
- Android restored its persisted FROST key (`Keys: 1`), reconnected to two peers, and displayed one pending signing request.
- Public-feed cursor was durably advanced from the post-DKG baseline `2` to `3`, with no issue.
- Approved the synthetic text-message request on Android.
- The coordinator completed the ceremony using desktop participant 1 plus Android participant 3 and cryptographically verified the signed-message envelope.

```text
SIGNATURE VERIFIED: true
Desktop keys: 1, 1; pending signatures: 0.
```

- Scheduled one verification-only repeat invocation of the identical callback, backgrounded the app, and killed its process again.
- The repeat headless worker returned `SUCCESS`.
- Notification Manager still contained one package notification and one `New signing request` title; no duplicate was added or updated.

Result: pass. Android recovered its durable share after process death, participated in the real 2-of-3 signature, and persistent notification deduplication survived another process restart.

### Platform warnings and errors

The following emulator SELinux denials recurred during native Iroh initialization:

```text
avc: denied { read } for name="max_map_count"
avc: denied { nlmsg_readpriv } ... netlink_route_socket
avc: denied { search } for name="net" ... sysfs_net
```

They did not prevent coordinator connectivity, feed polling, DKG, durable share recovery, message signing, notification delivery, or signature verification.

WorkManager logged `Application was force-stopped, rescheduling` during its startup bookkeeping even though this clean phase used package clear/install followed by `am kill`, not `am force-stop`. Android still dispatched and completed the due work in the same startup. This appears to be WorkManager's internal force-stop/reschedule detection after package/test-state initialization, not evidence that the package was in Android's stopped state.

The existing Kotlin Gradle Plugin migration warning for `workmanager_android` also remains unchanged and non-blocking.

### E2E conclusion

- Real 2-of-3 DKG across Linux and Android: pass.
- Android share persistence across process death: pass.
- Natural Android 14 periodic WorkManager pickup after more than 15 minutes: pass.
- One-hour notification window behavior: pass.
- Manual app catch-up and pending-request recovery: pass.
- Android plus desktop message signature and Schnorr/signed-message verification: pass.
- Persistent notification deduplication after another headless process restart: pass.

### 16:55 — First foreground launch and scheduler registration

- Copied the synthetic share into the dedicated package's app-private `files` directory without printing its contents.
- Cold-launched the verification activity.
- Android displayed `Allow Sygnature to send you notifications?`; accepted it through the system UI.
- Confirmed `POST_NOTIFICATIONS: granted=true`.
- Verification UI displays `No wallet loaded. Tap to inspect public status.`
- Status inspection after the initial poll displays `Cursor: 0. Issue: none`.
- JobScheduler contains the WorkManager system job for the verification package with:
  - no charging requirement;
  - no idle requirement;
  - validated Internet connectivity requirement;
  - approximately 15 minutes minimum latency for the periodic run.
- The initial WorkManager housekeeping job completed successfully according to JobScheduler history.

Result: pass.

Next action: put the activity in the background, kill its process without force-stop, create a fresh coordinator event, and explicitly trigger the already registered periodic system job to test the headless path without waiting for Android's inexact scheduling window.

### 16:57 — First background-event attempt

- Sent the app to Home and used `am kill` on only the verification package.
- Confirmed no application process remained.
- Attempted to create the synthetic event.

Observed deviation (verification harness): event creation failed before the Android worker ran because the harness authenticated once at startup, while Noosphere's default server session TTL is one minute. The test setup exceeded that TTL.

```text
Unhandled exception:
Session ID doesn't exist
ServerApiHandler.getSession
_ServerDkg._requestNewDkg
```

Impact: no public-feed event was committed, so this attempt says nothing about Android background delivery.

Harness correction: authenticate a new synthetic participant session immediately before each requested test event. This changes no production application or Noosphere behavior.

### 17:00 — Corrected coordinator and fresh background event

- Restarted the corrected synthetic coordinator and refreshed the app-private test share.
- Foreground baseline again reached `Cursor: 0. Issue: none`.
- Sent the app to Home, killed its process without force-stop, and confirmed no process remained.
- Created a fresh public DKG request; coordinator confirmed `Public request committed.`

Result: event setup passed.

### 17:01 — First manual scheduler trigger

Observed deviation (test automation): the command targeted stale JobScheduler ID `1`, but WorkManager had assigned a new internal ID after re-registration.

```text
Could not find job 1 in package network.noosphere.sygnature.publicfeedtest / user 0
```

Impact: the worker did not run. No app notification or app error was observed. The next attempt will discover the current JobScheduler ID dynamically.

Follow-up: Android 14 stores WorkManager jobs in namespace `androidx.work.systemjobscheduler`; a namespaced force-run did start a headless app process, but WorkManager correctly rejected execution before its internal periodic due time and rescheduled it.

```text
WM-SystemJobService: onStartJob
WM-SystemJobService: onStopJob
WM-WorkerWrapper: Status ... is ENQUEUED; not doing any work and rescheduling for later execution
```

To exercise the identical production callback promptly, the verification-only entrypoint now provides a button that schedules a connected-network one-off task after 30 seconds. It supplies no input data, does not use expedited work or a foreground service, and is not reachable from the production app entrypoint. The production 15-minute periodic task remains registered for separate observation.

### 17:07 — Headless WorkManager delivery with no app process

- Installed the rebuilt verification APK while preserving its isolated test data.
- Started a fresh synthetic feed, established a clean cursor-0 baseline, and scheduled the verification-only one-off worker for 30 seconds.
- Sent the app to Home and killed its process without force-stop.
- Confirmed the coordinator committed a fresh request before the worker deadline.
- Android later started a new process solely for `SystemJobService`.
- WorkManager started `dev.fluttercommunity.workmanager.BackgroundWorker`, loaded a headless Flutter engine, and reported `Worker result SUCCESS`.
- Notification Manager contains exactly one verification-app notification:
  - stable ID `1073741824`;
  - title `New key generation request`;
  - body `Open Sygnature and unlock your wallet to review current requests.`;
  - no operation details or capability material;
  - no foreground-service notification.
- Notification usage stats show one enqueue, one post, and zero updates.

Relevant successful execution log:

```text
ActivityManager: Start proc ... for SystemJobService
WM-WorkerWrapper: Starting work for dev.fluttercommunity.workmanager.BackgroundWorker
FlutterJNI: Beginning load of flutter
WM-WorkerWrapper: Worker result SUCCESS
```

Non-fatal emulator/platform warnings seen during native Iroh initialization:

```text
avc: denied { read } for name="max_map_count"
avc: denied { nlmsg_readpriv } ... netlink_route_socket
avc: denied { search } for name="net" ... sysfs_net
```

They did not prevent network access, feed fetch, notification delivery, cursor commit, or successful worker completion.

Result: pass.

### 16:46 — Focused automated preflight

Command:

```text
flutter test test/android_public_feed_work_test.dart test/public_feed_concurrency_test.dart test/app_notifications_public_feed_test.dart
```

Observed deviation (host toolchain): tests stopped before loading Dart tests because the `coinlib` native-assets hook resolved `/usr/bin/ccache` as the compiler and passed compiler flags directly to it. No application assertion ran.

```text
/usr/bin/ccache: invalid option -- 'f'
ProcessException: /usr/bin/ccache -fPIC -std=c90 ...
Building assets for package:coinlib failed.
```

Next action: inspect host compiler resolution and retry with an explicit Clang toolchain.

### 16:47 — Toolchain diagnosis and focused-test retry

- Root cause: `/usr/lib64/ccache/clang` is a symlink directly to `/usr/bin/ccache`, and that directory precedes `/usr/bin` in the host `PATH`.
- Retried with `/usr/lib64/ccache` removed from `PATH`, resolving real `/usr/bin/clang`.
- All 24 focused tests passed.

Covered behavior includes:

- one bounded background poll with no wallet bootstrap;
- background notification initialization without a permission prompt;
- stable notification ID and retained outbox across worker interruption;
- single unique 15-minute connected-network periodic registration with no `inputData`;
- foreground/headless serialization, durable global lease, killed-worker recovery, late-owner fencing, and concurrent isolate mutation retention.

Result: pass after correcting the host-only compiler path.

### 16:50 — Verification APK build and install

- Built the debug APK from `test/support/android_public_feed_device_app.dart` with Gradle property `publicFeedVerification=true`.
- Verified APK metadata before installation:
  - package: `network.noosphere.sygnature.publicfeedtest`;
  - version: `0.9.12` (`versionCode=15`);
  - min SDK 30, target SDK 36;
  - `INTERNET`, `POST_NOTIFICATIONS`, `USE_BIOMETRIC`, `VIBRATE`, and network-state permissions are present.
- Installed the APK and cleared only the dedicated verification package to guarantee clean app-private state.
- Device confirms `INTERNET` granted and `POST_NOTIFICATIONS` initially not granted.

Result: pass.

Non-blocking maintenance warning from the build:

```text
workmanager_android applies Kotlin Gradle Plugin (KGP).
Future versions of Flutter will fail to build unless the plugin migrates to Built-in Kotlin.
```

### 16:53 — Synthetic coordinator

- Started the repository's synthetic Noosphere coordinator.
- It generated a new public-feed ID and ephemeral pinned Iroh endpoint.
- Capability material was written only to `/tmp/sygnature-public-feed-device-share.json` with mode `0600`; values are intentionally excluded from this report and console output.
- Coordinator reached: `Coordinator ready; type event to create a public DKG request.`

Result: pass.
