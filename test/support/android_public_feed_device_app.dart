// Manual device harness. Build with a separate applicationId; never install over
// a real wallet. Copy a synthetic trusted share into the app-private files dir.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sygnature_ng/services/android_public_feed_work.dart';
import 'package:sygnature_ng/services/app_notifications.dart';
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:workmanager/workmanager.dart';

const _manualWorkName =
    'network.noosphere.sygnature.public-feed.device-verification';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await NoosphereFlutter.initialize();
  await HiveStorageInitializer.initialize(
    boxName: 'sygnature_roast_private_v1',
  );
  await initializePublicFeedNative();
  final directory = await getApplicationSupportDirectory();
  final store = await PublicFeedStore.open(directory.path);
  final share = File('${directory.path}/public_feed_device_share.json');
  Map<String, dynamic>? credentials;
  if (await share.exists()) {
    credentials = Map<String, dynamic>.from(
      jsonDecode(await share.readAsString()) as Map,
    );
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
      home: _DeviceHarness(
        store: store,
        credentials: credentials,
        status: status,
      ),
    ),
  );
}

final class _DeviceHarness extends StatefulWidget {
  const _DeviceHarness({
    required this.store,
    required this.credentials,
    required this.status,
  });

  final PublicFeedStore store;
  final Map<String, dynamic>? credentials;
  final ValueNotifier<String> status;

  @override
  State<_DeviceHarness> createState() => _DeviceHarnessState();
}

final class _DeviceHarnessState extends State<_DeviceHarness> {
  ReconnectingIrohClient? _client;
  StreamSubscription<ClientEvent>? _events;
  String _signerStatus = 'Signer disconnected';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.credentials != null) unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_client != null || _busy) return;
    setState(() {
      _busy = true;
      _signerStatus = 'Connecting signer…';
    });
    try {
      final ids = [
        for (var value = 1; value <= 3; value++) Identifier.fromUint16(value),
      ];
      final keys = [
        for (var value = 1; value <= 3; value++)
          ECPrivateKey(Uint8List(32)..last = value),
      ];
      final group = GroupConfig(
        id: 'android-real-world-2-of-3',
        participants: {
          for (var i = 0; i < ids.length; i++)
            ids[i]: ECCompressedPublicKey.fromPubkey(keys[i].pubkey),
        },
      );
      final credentials = widget.credentials!;
      final address = EndpointAddr.decode(
        base64Url.decode(credentials['address'] as String),
      );
      final persistence = RoastPersistenceFactory(
        cipherKey: Uint8List.fromList(List<int>.filled(32, 7)),
      );
      final runtime = await ReconnectingIrohClient.connect(
        clientConfig: ClientConfig(group: group, id: ids[2]),
        transportConfig: IrohClientTransportConfig(
          bootstrapAddress: address,
          pinnedServerId: PublicKey.fromZ32(credentials['pin'] as String),
        ),
        store: (await persistence.open()).clientStorage('device-e2e'),
        getPrivateKey: (_) async => keys[2],
      );
      _events = runtime.current.events.listen((_) => _refreshSigner());
      setState(() => _client = runtime);
      _refreshSigner();
    } catch (error) {
      setState(() => _signerStatus = 'Signer error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refreshSigner() {
    final client = _client?.current;
    if (client == null || !mounted) return;
    setState(() {
      _signerStatus =
          'Keys: ${client.keys.length}; DKG requests: '
          '${client.dkgRequests.length}; signing requests: '
          '${client.signaturesRequests.length}; online peers: '
          '${client.onlineParticipants.length}';
    });
  }

  Future<void> _acceptDkg() async {
    final client = _client?.current;
    if (client == null || client.dkgRequests.isEmpty) return;
    setState(() => _busy = true);
    try {
      await client.acceptDkg(client.dkgRequests.first.details.name);
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (client.keys.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (client.keys.isEmpty) {
        throw TimeoutException('DKG did not complete.');
      }
      // Establish a cursor baseline while the app is foregrounded so the
      // later headless run reports only the post-sleep signing request.
      await PublicFeedPoller(widget.store, notify: (_, _) async => true).run();
      _refreshSigner();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approveMessage() async {
    final client = _client?.current;
    if (client == null) return;
    final waiting = client.signaturesRequests.where(
      (request) => request.status == SignaturesRequestStatus.waiting,
    );
    if (waiting.isEmpty) return;
    setState(() => _busy = true);
    try {
      await client.acceptSignaturesRequest(waiting.first.details.id);
      _refreshSigner();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_client?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Public feed device verification')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: () async {
              final state = await widget.store.snapshot();
              final key = (state['bindings'] as Map)['device-check'];
              final feed = key == null
                  ? null
                  : (state['feeds'] as Map)[key] as Map?;
              final cursor = feed?['cursor'] ?? 0;
              final issue = feed?['issue'];
              // Only status is displayed. Never expose a capability or request detail.
              widget.status.value =
                  'No wallet loaded. Cursor: $cursor. Issue: ${issue == null ? "none" : "present"}';
            },
            child: ValueListenableBuilder<String>(
              valueListenable: widget.status,
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
                constraints: Constraints(networkType: NetworkType.connected),
                existingWorkPolicy: ExistingWorkPolicy.replace,
              );
              widget.status.value =
                  'No wallet loaded. One-off worker scheduled in 30 seconds.';
            },
            child: const Text('Schedule one-off worker'),
          ),
          const SizedBox(height: 24),
          Text(_signerStatus, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _acceptDkg,
            child: const Text('Accept pending DKG'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _approveMessage,
            child: const Text('Approve pending message'),
          ),
        ],
      ),
    ),
  );
}
