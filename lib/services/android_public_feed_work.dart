import 'dart:io';
import 'dart:ui';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../storage/public_feed_store.dart';
import 'app_diagnostics.dart';
import 'public_feed_notifications.dart';
import 'public_feed_poller.dart';

const publicFeedWorkUniqueName = 'network.noosphere.sygnature.public-feed';
const publicFeedWorkTaskName = 'publicFeedPoll';
const iosPublicFeedRefreshTaskName =
    'network.noosphere.sygnature.public-feed.refresh';
const androidPublicFeedWorkFrequencyStorageKey =
    'notifications.android_public_feed_frequency_minutes';
const androidPublicFeedDefaultWorkFrequency = Duration(hours: 1);
const androidPublicFeedWorkFrequencies = [
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 3),
  Duration(hours: 6),
];

const _preferenceStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: false),
);

Future<Duration> loadAndroidPublicFeedWorkFrequency({
  FlutterSecureStorage storage = _preferenceStorage,
}) async {
  try {
    final minutes = int.tryParse(
      await storage.read(key: androidPublicFeedWorkFrequencyStorageKey) ?? '',
    );
    final frequency = Duration(minutes: minutes ?? 0);
    return androidPublicFeedWorkFrequencies.contains(frequency)
        ? frequency
        : androidPublicFeedDefaultWorkFrequency;
  } on Object {
    return androidPublicFeedDefaultWorkFrequency;
  }
}

/// This callback is also retained in release AOT builds. No app bootstrap runs
/// in this engine, and WorkManager carries no subscription/capability inputData.
@pragma('vm:entry-point')
void publicFeedWorkDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask(
    (task, _) => PublicFeedBackgroundTask().execute(task),
  );
}

Future<void> _initializePlugins() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
}

Future<void> _initializeNative() async {
  await loadCoinlib();
  await initializePublicFeedNative();
}

typedef PublicFeedBackgroundPoll = Future<void> Function(
  PublicFeedStore store,
  Future<bool> Function(int, String) notify,
);

Future<void> _pollOnce(
  PublicFeedStore store,
  Future<bool> Function(int, String) notify,
) => PublicFeedPoller(
  store,
  notify: notify,
  source: PublicFeedPollSource.background,
).run();

/// Injectable boundaries keep execution tests independent of an Android job.
/// Expected feed failures are handled by the poller's durable per-feed backoff;
/// only task infrastructure failures return false (WorkManager retry).
final class PublicFeedBackgroundTask({
  final Future<void> Function() initializePlugins = _initializePlugins,
  final Future<void> Function() initializeNative = _initializeNative,
  final Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
  final Future<PublicFeedStore> Function(String) openStore =
      PublicFeedStore.open,
  final PublicFeedNotifications Function() notifications =
      PublicFeedNotifications.new,
  final PublicFeedBackgroundPoll poll = _pollOnce,
}) {
  Future<bool> execute(String task) async {
    if (task != publicFeedWorkTaskName &&
        task != iosPublicFeedRefreshTaskName) {
      return true;
    }
    PublicFeedStore? store;
    try {
      try {
        await initializePlugins();
        final directory = await supportDirectory();
        await AppDiagnostics.initialize(directory.path);
        await AppDiagnostics.record(AppDiagnosticEvent.backgroundWorkStarted);
        await initializeNative();
        store = await openStore(directory.path);
        final delivery = notifications();
        await delivery.initialize();
        await poll(store, delivery.publicFeedRequested);
      } finally {
        await store?.close();
      }
      await AppDiagnostics.record(AppDiagnosticEvent.backgroundWorkSucceeded);
      return true;
    } on Object catch (error) {
      await AppDiagnostics.record(
        AppDiagnosticEvent.backgroundWorkFailed,
        error: error,
      );
      // Never log exceptions: native/transport errors may contain capabilities.
      return false;
    }
  }
}

/// The OS may defer this periodic work (Doze, battery policy, force-stop).
/// Re-registering updates the existing work without cancelling it.
Future<void> initializeAndroidPublicFeedWork({
  TargetPlatform? platform,
  bool? isWeb,
  Workmanager? workmanager,
  Duration? frequency,
  FlutterSecureStorage storage = _preferenceStorage,
}) async {
  if ((isWeb ?? kIsWeb) ||
      (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return;
  }
  final manager = workmanager ?? Workmanager();
  final configuredFrequency =
      frequency ?? await loadAndroidPublicFeedWorkFrequency(storage: storage);
  await manager.initialize(publicFeedWorkDispatcher);
  await manager.registerPeriodicTask(
    publicFeedWorkUniqueName,
    publicFeedWorkTaskName,
    frequency: configuredFrequency,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

Future<void> setAndroidPublicFeedWorkFrequency(
  Duration frequency, {
  Workmanager? workmanager,
  FlutterSecureStorage storage = _preferenceStorage,
}) async {
  if (!androidPublicFeedWorkFrequencies.contains(frequency)) {
    throw ArgumentError.value(frequency, 'frequency');
  }
  await initializeAndroidPublicFeedWork(
    platform: TargetPlatform.android,
    isWeb: false,
    workmanager: workmanager,
    frequency: frequency,
  );
  await storage.write(
    key: androidPublicFeedWorkFrequencyStorageKey,
    value: '${frequency.inMinutes}',
  );
}

/// Registers the iOS 13+ BGAppRefreshTask used as a best-effort catch-up path.
///
/// iOS treats [initialDelay] only as an earliest-start hint. The operating
/// system chooses the actual cadence and does not launch refresh tasks after a
/// user force-quits the application.
Future<void> initializeIosPublicFeedWork({
  TargetPlatform? platform,
  bool? isWeb,
  Workmanager? workmanager,
}) async {
  if ((isWeb ?? kIsWeb) ||
      (platform ?? defaultTargetPlatform) != TargetPlatform.iOS) {
    return;
  }
  final manager = workmanager ?? Workmanager();
  await manager.initialize(publicFeedWorkDispatcher);
  await manager.registerPeriodicTask(
    iosPublicFeedRefreshTaskName,
    publicFeedWorkTaskName,
    initialDelay: const Duration(minutes: 15),
  );
}

Future<void> initializePublicFeedBackgroundWork({
  TargetPlatform? platform,
  bool? isWeb,
  Workmanager? workmanager,
}) async {
  final target = platform ?? defaultTargetPlatform;
  await initializeAndroidPublicFeedWork(
    platform: target,
    isWeb: isWeb,
    workmanager: workmanager,
  );
  await initializeIosPublicFeedWork(
    platform: target,
    isWeb: isWeb,
    workmanager: workmanager,
  );
}
