// Dedicated simulator + isolated macOS wallets only. No funded transactions.
// Run with scripts/test_ios_public_feed.py; never use as the release entry point.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:path_provider/path_provider.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart' show SygnatureApp;
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/services/ios_public_feed_work.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/public_feed_notifications.dart';
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';
import 'package:workmanager/workmanager.dart';

const _bridge = String.fromEnvironment('PUBLIC_FEED_TEST_BRIDGE');

Future<dynamic> _exchange(String key, [Object? value]) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.openUrl(
      value == null ? 'GET' : 'POST',
      Uri.parse('$_bridge/$key'),
    );
    if (value != null) {
      final bytes = utf8.encode(jsonEncode(value));
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    if (response.statusCode != 200) throw StateError('Test bridge unavailable');
    return jsonDecode(await utf8.decoder.bind(response).join());
  } finally {
    client.close(force: true);
  }
}

Future<void> _until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('Test phase');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

class _MacPaths extends PathProviderPlatform {
  _MacPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
}

Future<void> _macCoordinator() async {
  final directory = await Directory.systemTemp.createTemp('sygnature-feed-qa-');
  PathProviderPlatform.instance = _MacPaths(directory.path);
  await NoosphereFlutter.initialize();
  final store = await PublicFeedStore.open(directory.path);
  final persistence = RoastPersistenceFactory(
    cipherKey: Uint8List.fromList(Hive.generateSecureKey()),
  );
  Future<(WalletController, RoastRuntimeManager)> createController() async {
    final repository = MemoryWalletRepository();
    final runtime = RoastRuntimeManager(
      persistence,
      getWalletSeed: () => hexToBytes(repository.value!.rootSeedHex),
      publicFeedStore: Future.value(store),
    );
    final controller = WalletController(
      repository,
      roastRuntime: runtime,
      roastSigningOperations: persistence,
      publicFeedStore: Future.value(store),
    );
    await controller.load();
    return (controller, runtime);
  }

  final (host, hostRuntime) = await createController();
  final (member, memberRuntime) = await createController();
  final frames = Timer.periodic(
    const Duration(milliseconds: 100),
    (_) => WidgetsBinding.instance.scheduleWarmUpFrame(),
  );
  runApp(SygnatureApp(controllerFactory: () async => host));
  final hostId = await host.createRoastSetupDraft(
    role: RoastSetupRole.host,
    walletName: 'Background feed QA',
    participantName: 'macOS coordinator',
    threshold: 2,
    participantCount: 2,
    network: PeercoinNetworks.testnet,
  );
  final memberId = await member.createRoastSetupDraft(
    role: RoastSetupRole.member,
    walletName: 'Background feed QA member',
    participantName: 'Test signer',
    threshold: 2,
    participantCount: 2,
    network: PeercoinNetworks.testnet,
  );
  final invitations = await host.createHostedRoastInvitations(hostId, [
    (name: 'Test signer', publicKeyHex: member.participantPublicKey(memberId)),
  ]);
  await member.joinRoastSetup(memberId, invitations.single.encoded);
  RoastSetup setup() => host.roastSetups.single;
  await _until(() => host.onlineSignerCount(setup()) == 2);
  await _until(
    () async => ((await store.snapshot())['bindings'] as Map).containsKey(
      setup().groupId,
    ),
  );
  final state = await store.snapshot();
  final key = (state['bindings'] as Map)[setup().groupId];
  final feed = (state['feeds'] as Map)[key] as Map;
  // Credentials remain only in the loopback bridge memory, never public logs.
  await _exchange('share', {
    'groupId': setup().groupId,
    'address': feed['address'],
    'pin': feed['pin'],
    'feedId': feed['feedId'],
  });
  await _exchange('mac-ready', true);
  await _until(() async => await _exchange('start-dkg') == true);
  await host.startRoastDkg(
    hostId,
    confirmedGroupFingerprintHex: setup().groupFingerprintHex!,
  );
  await _exchange('dkg-published', true);
  await _until(() async => await _exchange('finish-dkg') == true);
  await _until(() => member.roastSetups.single.pendingDkgProposalHex != null);
  await member.acceptRoastDkg(
    memberId,
    confirmedGroupFingerprintHex:
        member.roastSetups.single.groupFingerprintHex!,
  );
  await _until(() => setup().isActive && member.roastSetups.single.isActive);
  await _exchange('dkg-completed', true);
  await _until(() async => await _exchange('start-signing') == true);
  final signing = host.signRoastMessage(
    host.selectedAccount!,
    text: 'Synthetic public-feed background verification',
    message: 'Simulator QA',
    requestTimeout: const Duration(minutes: 10),
  );
  signing.ignore();
  await _until(() => member.roastSigningRequests.isNotEmpty);
  await _exchange('signing-published', true);
  await _until(() async => await _exchange('stop') == true);
  await hostRuntime.close();
  await memberRuntime.close();
  host.dispose();
  member.dispose();
  await store.close();
  await Hive.close();
  await directory.delete(recursive: true);
  frames.cancel();
  exit(0);
}

Future<File> _reportFile() async => File(
  '${(await getApplicationSupportDirectory()).path}/public-feed-qa-result.json',
);

@pragma('vm:entry-point')
void publicFeedQaWorkDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((_, input) => publicFeedQaWorker(input));
}

/// The wrapper observes the real production callback, never substitutes its I/O.
@pragma('vm:entry-point')
Future<bool> publicFeedQaWorker(Map<String, dynamic>? input) async {
  final elapsed = Stopwatch()..start();
  final nativeState = await const MethodChannel(
    'network.noosphere.sygnature/public-feed-qa',
  ).invokeMapMethod<String, dynamic>('state');
  final result = await iosPublicFeedWorker(input);
  final directory = await getApplicationSupportDirectory();
  final store = await PublicFeedStore.open(directory.path);
  try {
    final state = await store.snapshot();
    final notifications = await FlutterLocalNotificationsPlugin()
        .getActiveNotifications();
    final file = await _reportFile();
    final previous = await file.exists()
        ? jsonDecode(await file.readAsString()) as Map
        : {};
    final data = {
      'runs': (previous['runs'] as int? ?? 0) + 1,
      'nativeState': nativeState,
      'success': result,
      'elapsedMs': elapsed.elapsedMilliseconds,
      'backgroundPoll': state['polls']?['background'],
      'feeds': [
        for (final feed in (state['feeds'] as Map).values)
          {
            'cursor': feed['cursor'],
            'outbox': (feed['outbox'] as Map).length,
            'failures': feed['failures'],
            'hasIssue': feed['issue'] != null,
          },
      ],
      'notificationIds': notifications.map((n) => n.id).toList(),
      'notificationTitles': notifications.map((n) => n.title).toList(),
      'leaseReleased': state['pollingLease'] == null,
    };
    await file.writeAsString(jsonEncode(data), flush: true);
    debugPrint('PUBLIC FEED QA: worker completed, success=$result');
  } finally {
    await store.close();
  }
  return result;
}

class _LifecycleProbe extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(() async {
      final directory = await getApplicationSupportDirectory();
      await File('${directory.path}/public-feed-qa-lifecycle.txt')
          .writeAsString(state.name, flush: true);
    }());
  }
}

Future<void> _iosSubscriber() async {
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Public-feed background QA — no wallet loaded'),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addObserver(_LifecycleProbe());
  final plugin = FlutterLocalNotificationsPlugin();
  final delivery = PublicFeedNotifications(plugin: plugin);
  await delivery.initialize();
  final granted = await plugin
      .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >()!
      .requestPermissions(
        alert: true,
        badge: true,
        sound: true,
        provisional: true,
      );
  await _exchange('ios-permission', granted == true);
  if (granted != true) throw StateError('Notification permission is required');
  final directory = await getApplicationSupportDirectory();
  final store = await PublicFeedStore.open(directory.path);
  final share = await _exchange('share') as Map;
  await store.subscribe(
    groupId: share['groupId'] as String,
    address: share['address'] as String,
    pin: share['pin'] as String,
    feedId: share['feedId'] as String,
  );
  await loadCoinlib();
  await initializePublicFeedNative();
  await PublicFeedPoller(store, notify: delivery.publicFeedRequested).run();
  final state = await store.snapshot();
  final feed = (state['feeds'] as Map).values.single as Map;
  if (feed['initialThrough'] == null || feed['failures'] != 0) {
    throw StateError('Baseline fetch failed');
  }
  await syncIosPublicFeedWork(store);
  // The QA dispatcher wraps the production callback with result capture. It is
  // installed only by this test entry point after production scheduling.
  await Workmanager().initialize(publicFeedQaWorkDispatcher);
  await store.close();
  final window = await const MethodChannel(
    'network.noosphere.sygnature/public-feed-qa',
  ).invokeMethod<bool>('beginWindow');
  if (window != true) throw StateError('QA execution window unavailable');
  // Only this QA build exposes loopback control. It allocates background time;
  // it does not prove that BGTaskScheduler can wake a suspended app.
  final control = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var invocation = 0;
  control.listen((request) async {
    if (request.uri.path != '/enqueue') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    await Workmanager().registerOneOffTask(
      'public-feed-qa-${invocation++}',
      'publicFeedQa',
      inputData: const {},
    );
    request.response.write('scheduled');
    await request.response.close();
  });
  await _exchange('ios-ready', {
    'baselineCursor': feed['cursor'],
    'controlPort': control.port,
    'schedulerProbe': await const MethodChannel(
      'network.noosphere.sygnature/public-feed-qa',
    ).invokeMapMethod<String, dynamic>('schedulerAvailability'),
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_bridge.isEmpty) throw StateError('Run through the dedicated QA script');
  try {
    if (Platform.isMacOS) {
      await _macCoordinator();
    } else {
      await _iosSubscriber();
    }
  } on Object {
    // No underlying transport errors or subscription credentials in logs.
    await _exchange(Platform.isMacOS ? 'mac-failed' : 'ios-failed', true);
    debugPrint('PUBLIC FEED QA: setup failed');
    rethrow;
  }
}
