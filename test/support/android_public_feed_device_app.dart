// Manual device harness. Build with a separate applicationId; never install over
// a real wallet. Copy a synthetic trusted share into the app-private files dir.
import 'dart:convert';
import 'dart:io';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sygnature_ng/services/android_public_feed_work.dart';
import 'package:sygnature_ng/services/app_notifications.dart';
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:workmanager/workmanager.dart';

const _manualWorkName =
    'network.noosphere.sygnature.public-feed.device-verification';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await initializePublicFeedNative();
  final directory = await getApplicationSupportDirectory();
  final store = await PublicFeedStore.open(directory.path);
  final share = File('${directory.path}/public_feed_device_share.json');
  if (await share.exists()) {
    final credentials = jsonDecode(await share.readAsString()) as Map;
    await store.subscribe(
      groupId: 'device-check',
      address: credentials['address'] as String,
      pin: credentials['pin'] as String,
      feedId: credentials['feedId'] as String,
    );
  }
  final notifications = AppNotifications();
  await notifications.initialize(); // Foreground permission request only.
  await PublicFeedPoller(
    store,
    notify: notifications.publicFeedRequested,
  ).run();
  await initializeAndroidPublicFeedWork();
  final status = ValueNotifier(
    'No wallet loaded. Tap to inspect public status.',
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Public feed device verification')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: () async {
                  final state = await store.snapshot();
                  final key = (state['bindings'] as Map)['device-check'];
                  final feed = key == null
                      ? null
                      : (state['feeds'] as Map)[key] as Map?;
                  final cursor = feed?['cursor'] ?? 0;
                  final issue = feed?['issue'];
                  // Only status is displayed. Never expose a capability or request detail.
                  status.value =
                      'No wallet loaded. Cursor: $cursor. Issue: ${issue == null ? "none" : "present"}';
                },
                child: ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, value, _) => Text(value),
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () async {
                  await Workmanager().registerOneOffTask(
                    _manualWorkName,
                    publicFeedWorkTaskName,
                    initialDelay: const Duration(seconds: 30),
                    constraints: Constraints(
                      networkType: NetworkType.connected,
                    ),
                    existingWorkPolicy: ExistingWorkPolicy.replace,
                  );
                  status.value = 'No wallet loaded. One-off worker scheduled in 30 seconds.';
                },
                child: const Text('Schedule one-off worker'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
