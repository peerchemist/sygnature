import 'dart:async';
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
import 'ios_public_feed_work.dart';
import 'public_feed_poller.dart';

const publicFeedWorkUniqueName = 'network.noosphere.sygnature.public-feed';
const publicFeedWorkTaskName = 'publicFeedPoll';
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
  final bool registerDartPlugins = true,
  final Duration? initializationBudget,
}) {
  Future<bool> execute(String task) async {
    if (task != publicFeedWorkTaskName) {
      return true;
    }
    final elapsed = Stopwatch()..start();
    Future<T> initializeWithinBudget<T>(Future<T> Function() action) {
      final budget = initializationBudget;
      if (budget == null) return action();
      final remaining = budget - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Public feed initialization budget');
      }
      return action().timeout(remaining);
    }

    PublicFeedStore? store;
    try {
      try {
        if (registerDartPlugins) {
          await initializeWithinBudget(initializePlugins);
        } else {
          // This is the root isolate of a selectively registered iOS engine.
          WidgetsFlutterBinding.ensureInitialized();
        }
        final directory = await initializeWithinBudget(supportDirectory);
        await initializeWithinBudget(
          () => AppDiagnostics.initialize(directory.path),
        );
        await AppDiagnostics.record(AppDiagnosticEvent.backgroundWorkStarted);
        await initializeWithinBudget(initializeNative);
        var abandoned = false;
        try {
          store = await initializeWithinBudget(
            () => openStore(directory.path).then((opened) async {
              if (abandoned) {
                await opened.close();
                throw TimeoutException('Public feed store open abandoned');
              }
              return opened;
            }),
          );
        } on TimeoutException {
          abandoned = true;
          rethrow;
        }
        final delivery = notifications();
        await initializeWithinBudget(delivery.initialize);
        await poll(store!, delivery.publicFeedRequested);
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

Future<void> initializePublicFeedBackgroundWork({
  TargetPlatform? platform,
  bool? isWeb,
  Workmanager? workmanager,
}) async {
  await initializeAndroidPublicFeedWork(
    platform: platform,
    isWeb: isWeb,
    workmanager: workmanager,
  );
  await initializeIosPublicFeedWork(platform: platform, isWeb: isWeb);
}
