import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coinlib/coinlib.dart' show ECCompressedPublicKey;
import 'package:iroh_quic/iroh_quic.dart';
import 'package:noosphere_server/noosphere_server.dart';
import 'package:noosphere_server/testing.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart' show NoosphereFlutter;
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:sygnature_ng/ui/public_feed_dialog.dart';

import 'fixtures/wallet_backup_fixture.dart';

void main() {
  // The coordinator is authenticated business logic. The subprocess below does
  // not inherit this initialization or have access to any private storage.
  setUpAll(NoosphereFlutter.initializeNative);

  testWidgets('public feed opt-in saves an ID before restart', (tester) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'sygnature-feed-ui-',
      );
      final store = await PublicFeedStore.open(directory.path);
      try {
        final setup = WalletBackupFixture(roomHost: true).setup;
        await tester.pumpWidget(
          MaterialApp(
            home: PublicFeedDialog(store: store, setup: setup),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
        expect(await store.enabledHostId(setup.groupId), isNull);
        expect(
          find.textContaining('unlisted metadata is not private'),
          findsOneWidget,
        );
        expect(find.text('Add feed from clipboard'), findsNothing);
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('public-feed-host-enabled')),
            )
            .onChanged!(true);
        await store.snapshot();
        await tester.pumpAndSettle();
        expect(await store.enabledHostId(setup.groupId), hasLength(64));
        expect((await store.snapshot())['feeds'], isEmpty);
        expect(
          find.byKey(const Key('public-feed-notification-window')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('member feed uses the enrolled coordinator without clipboard', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'sygnature-feed-member-',
      );
      final store = await PublicFeedStore.open(directory.path);
      try {
        final setup = WalletBackupFixture().setup;
        await tester.pumpWidget(
          MaterialApp(
            home: PublicFeedDialog(store: store, setup: setup),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(find.byType(OutlinedButton), findsNothing);
        final enabled = find.byKey(const Key('public-feed-member-enabled'));
        expect(tester.widget<SwitchListTile>(enabled).value, isFalse);
        tester.widget<SwitchListTile>(enabled).onChanged!(true);
        await store.snapshot();
        await tester.pump();
        final data = await store.snapshot();
        final key = (data['bindings'] as Map)[setup.groupId] as String;
        final feed = (data['feeds'] as Map)[key] as Map;
        expect(feed['pin'], setup.coordinatorId);
        expect(feed['feedId'], await publicFeedIdForGroup(setup.groupId));
        await tester.pumpWidget(const SizedBox());
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    });
  });

  test(
    'independent engine isolate groups share Hive state and polling lease',
    () async {
      final result = await Process.run('dart', [
        'run',
        'test/support/public_feed_store_engine_probe.dart',
      ]).timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect((result.stdout as String).trim(), 'ok');
    },
  );

  test('fresh locked process polls real Iroh feed with no signer session or presence change', () async {
    final fixture = WalletBackupFixture();
    final id = PublicFeedId.generate();
    final handler = ServerApiHandler(
      config: ServerConfig(
        group: GroupConfig(
          id: 'native-feed',
          participants: {
            for (final participant in fixture.setup.participants)
              Identifier.fromHex(participant.identifierHex):
                  ECCompressedPublicKey.fromHex(participant.publicKeyHex),
          },
        ),
        publicFeed: PublicFeedConfig(feedId: id),
      ),
      persistence: InMemoryServerPersistence(),
    );
    final server = await IrohServer.start(
      IrohConfig(server: handler.config, relay: IrohRelayConfig.disabled()),
      secretKey: SecretKey.generate(),
      persistence: handler.persistence,
      handler: handler,
    );
    unawaited(server.serve());
    addTearDown(server.close);
    final before = handler.state.toBytes();
    final address = EndpointAddr(
      server.id,
      ipAddrs: server.endpoint.boundSockets.map((address) {
        final split = address.lastIndexOf(':');
        return address.startsWith('[')
            ? '[::1]${address.substring(split)}'
            : '127.0.0.1${address.substring(split)}';
      }).toList(),
    );
    final directory = await Directory.systemTemp.createTemp(
      'sygnature-locked-feed-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = await PublicFeedStore.open(directory.path);
    await store.subscribe(
      groupId: 'native-feed',
      address: base64UrlEncode(address.encode()),
      pin: server.id.toZ32(),
      feedId: id.hex,
    );
    await store.close();
    final result = await Process.run('dart', [
      'run',
      'test/support/public_feed_locked_probe.dart',
      directory.path,
    ]).timeout(const Duration(seconds: 60));
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(jsonDecode((result.stdout as String).trim()), {
      'cursor': 0,
      'issue': null,
      'events': 0,
      'privateStorageOpen': false,
      'signerLibrariesLoaded': Platform.isLinux ? false : null,
    });
    expect(handler.debugState.clientSessions.values, isEmpty);
    expect(handler.debugState.participantToSession.values, isEmpty);
    expect(handler.debugState.challenges.values, isEmpty);
    expect(handler.state.toBytes(), before);
  });

  test('real public client rejects address identity mismatch without cursor changes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sygnature-pin-feed-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = await PublicFeedStore.open(directory.path);
    addTearDown(() => store.close());
    final address = EndpointAddr(SecretKey.generate().publicKey);
    final key = await store.subscribe(
      groupId: 'g',
      address: base64UrlEncode(address.encode()),
      pin: SecretKey.generate().publicKey.toZ32(),
      feedId: PublicFeedId.generate().hex,
    );
    await PublicFeedPoller(store, notify: (_, _) async => true).run();
    final feed = ((await store.snapshot())['feeds'] as Map)[key] as Map;
    expect(feed['cursor'], 0);
    expect(feed['blocked'], isTrue);
    expect(feed['issue'], contains('identity mismatch'));
  });
}
