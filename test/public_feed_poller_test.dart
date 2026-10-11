import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:iroh_quic/iroh_quic.dart' show IrohKeyException;
import 'package:noosphere/wire.dart' show ProtocolErrorCode;
import 'package:noosphere_client/public_feed.dart';
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';

// Deliberately no wallet controller, signer, FROST or private storage imports.
final feedId = PublicFeedId('01' * 32);
final eventId = PublicFeedId('ab' * 32);

PublicFeedEntry entry(
  int cursor, {
  PublicFeedLifecycle state = PublicFeedLifecycle.requested,
  PublicFeedId? event,
  DateTime? observedAt,
}) => PublicFeedEntry(
  cursor: cursor,
  eventId: event ?? eventId,
  category: PublicFeedCategory.signing,
  state: state,
  observedAt: observedAt ?? DateTime.now().toUtc(),
);

PublicFeedPage page(
  int after,
  int latest, {
  List<PublicFeedEntry> entries = const [],
  int oldest = 1,
  PublicFeedId? id,
}) => PublicFeedPage(
  feedId: id ?? feedId,
  entries: entries,
  oldestAvailableCursor: oldest,
  latestCursor: latest,
  nextCursor: entries.isEmpty
      ? (latest > after ? latest : after)
      : entries.last.cursor,
  hasMore: entries.isNotEmpty && entries.last.cursor < latest,
  historyGap: after < oldest - 1,
  generatedAt: DateTime.now().toUtc(),
  afterCursor: after,
);

final class FakeConnection(
  final Future<PublicFeedPage> Function(int cursor) response,
) implements FeedConnection {
  final cursors = <int>[];
  bool closed = false;
  @override
  Future<PublicFeedPage> fetch(
    PublicFeedId id, {
    required int afterCursor,
    required int limit,
  }) {
    expect(limit, 100);
    cursors.add(afterCursor);
    return response(afterCursor);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late Directory directory;
  late PublicFeedStore store;
  late String key;
  late Map<int, String> shown;

  Future<Map> feed([String? scope]) async =>
      ((await store.snapshot())['feeds'] as Map)[scope ?? key] as Map;
  Future<void> baseline() => store.commitPage(key, page(0, 0), DateTime.now());
  PublicFeedPoller poller(
    FakeConnection connection, {
    Future<bool> Function(int, String)? notify,
    int maxPages = 5,
    Duration maxDuration = const Duration(seconds: 45),
  }) => PublicFeedPoller(
    store,
    connect: (_) async => connection,
    maxPages: maxPages,
    maxDuration: maxDuration,
    notify:
        notify ??
        (id, category) async {
          shown[id] = category;
          return true;
        },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sygnature-public-feed-');
    store = await PublicFeedStore.open(directory.path);
    key = await store.subscribe(
      groupId: 'g1',
      address: 'mock-address',
      pin: 'pin-a',
      feedId: feedId.hex,
    );
    shown = {};
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('locked-wallet service needs only public storage and never initializes signer native libraries', () async {
    final connection = FakeConnection(
      (_) async => page(0, 1, entries: [entry(1)]),
    );
    await poller(connection).run();
    expect((await feed())['cursor'], 1);
    expect(connection.closed, isTrue);
    expect(shown, isEmpty); // First retained history is silent.
    expect(Hive.isBoxOpen('sygnature_roast_private_v1'), isFalse);
    expect(Hive.isBoxOpen('sygnature_private_v1'), isFalse);
    final imports = File('lib/services/public_feed_poller.dart')
        .readAsStringSync();
    for (final prohibited in [
      'ClientNodeOptions(',
      'GetPrivateKey',
      'ClientStorageInterface',
      'NoosphereFlutter',
      'loadCoinlib',
      'RoastRuntimeManager',
    ]) {
      expect(imports, isNot(contains(prohibited)));
    }
  });

  test('host ID, scoped cursor, status and initial baseline survive database restart', () async {
    final id = await store.configureHost('g1', true);
    expect(id, hasLength(64));
    expect(await store.configureHost('g1', true), id);
    final other = await store.configureHost('g2', true);
    expect(other, isNot(id));
    await store.configureHost('g1', false);
    expect(await store.enabledHostId('g1'), isNull);
    expect(await store.configureHost('g1', true), id);
    await store.commitPage(
      key,
      page(
        0,
        2,
        entries: [
          entry(1),
          entry(2, state: PublicFeedLifecycle.completed),
        ],
      ),
      DateTime.now(),
    );
    await store.close();
    store = await PublicFeedStore.open(directory.path);
    expect(await store.enabledHostId('g1'), id);
    expect((await feed())['cursor'], 2);
    expect(((await feed())['events'] as Map).length, 1);
    expect(
      ((await feed())['events'] as Map)[eventId.hex]['state'],
      'completed',
    );
    expect((await feed())['initialThrough'], 2);
  });

  test('exclusive ordered pagination is bounded and initial history stays silent across runs', () async {
    final first = FakeConnection(
      (cursor) async => page(
        cursor,
        3,
        entries: [
          entry(
            cursor + 1,
            event: PublicFeedId('${cursor + 1}'.padLeft(64, '0')),
          ),
        ],
      ),
    );
    await poller(first, maxPages: 2).run();
    expect(first.cursors, [0, 1]);
    expect((await feed())['cursor'], 2);
    expect(shown, isEmpty);
    final second = FakeConnection(
      (cursor) async => page(
        cursor,
        4,
        entries: [
          entry(3, event: PublicFeedId('03' * 32)),
          entry(4, event: PublicFeedId('04' * 32)),
        ],
      ),
    );
    await poller(second).run();
    expect(second.cursors, [2]);
    expect(
      shown.length,
      1,
    ); // Cursor 4 arrived after initial retained baseline.
    expect((await feed())['cursor'], 4);
  });

  test(
    'empty retained page uses nextCursor and records a sticky history gap',
    () async {
      final connection = FakeConnection((_) async => page(0, 15, oldest: 16));
      await poller(connection).run();
      expect((await feed())['cursor'], 15);
      expect((await feed())['historyGap'], isTrue);
      await store.commitPage(key, page(15, 15, oldest: 16), DateTime.now());
      expect((await feed())['historyGap'], isTrue);
      expect(shown, isEmpty);
    },
  );

  test('crash after display retries the durable outbox with the SAME notification ID', () async {
    await baseline();
    final connection = FakeConnection(
      (cursor) async => page(cursor, 1, entries: cursor == 0 ? [entry(1)] : []),
    );
    var attempts = 0;
    final ids = <int>[];
    final service = poller(
      connection,
      notify: (id, category) async {
        ids.add(id);
        shown[id] = category;
        attempts++;
        if (attempts == 1) {
          throw StateError('Simulated crash before acknowledgement');
        }
        return true;
      },
    );
    await service.run();
    expect((await feed())['cursor'], 1); // Atomically committed with intent.
    expect(((await feed())['outbox'] as Map).length, 1);
    await store.close();
    store = await PublicFeedStore.open(directory.path);
    await store.retry(key);
    await poller(
      FakeConnection((cursor) async => page(cursor, 1)),
      notify: (id, category) async {
        ids.add(id);
        shown[id] = category;
        return true;
      },
    ).run();
    expect(ids.length, 2);
    expect(ids.first, ids.last);
    expect(shown.length, 1);
    expect((await feed())['outbox'], isEmpty);
    expect((await feed())['events'], hasLength(1));
  });

  test('duplicate/concurrent runs do not reprocess committed events', () async {
    await baseline();
    final gate = Completer<PublicFeedPage>();
    final connection = FakeConnection((_) => gate.future);
    final service = poller(connection);
    final first = service.run();
    final second = service.run();
    gate.complete(page(0, 1, entries: [entry(1)]));
    await Future.wait([first, second]);
    expect(connection.cursors, [0]);
    expect(shown.length, 1);
    await poller(FakeConnection((cursor) async => page(cursor, 1))).run();
    expect(shown.length, 1);
    expect((await feed())['events'], hasLength(1));
  });

  test('terminal updates correlate only by public event ID and suppress pending notifications', () async {
    await baseline();
    await store.commitPage(
      key,
      page(
        0,
        2,
        entries: [
          entry(1),
          entry(2, state: PublicFeedLifecycle.rejected),
        ],
      ),
      DateTime.now(),
    );
    expect((await feed())['events'], hasLength(1));
    expect(((await feed())['events'] as Map)[eventId.hex]['state'], 'rejected');
    expect((await feed())['outbox'], isEmpty);
  });

  test('old and expired requests never flood notifications after an offline period', () async {
    await baseline();
    await poller(
      FakeConnection(
        (_) async => page(
          0,
          1,
          entries: [
            entry(
              1,
              observedAt: DateTime.now().subtract(const Duration(days: 1)),
            ),
          ],
        ),
      ),
    ).run();
    expect((await feed())['cursor'], 1);
    expect(shown, isEmpty);
  });

  test(
    'notification window defaults to one hour and persists up to 24 hours',
    () async {
      expect(await store.notificationWindow(), const Duration(hours: 1));
      await store.setNotificationWindow(const Duration(hours: 24));
      await store.close();
      store = await PublicFeedStore.open(directory.path);
      expect(await store.notificationWindow(), const Duration(hours: 24));
      await expectLater(
        store.setNotificationWindow(const Duration(hours: 24, minutes: 1)),
        throwsFormatException,
      );
      await expectLater(
        store.setNotificationWindow(Duration.zero),
        throwsFormatException,
      );
    },
  );

  test(
    'configured window includes recent catch-up and excludes older requests',
    () async {
      await baseline();
      await store.setNotificationWindow(const Duration(hours: 24));
      await poller(
        FakeConnection(
          (_) async => page(
            0,
            1,
            entries: [
              entry(
                1,
                observedAt: DateTime.now().subtract(const Duration(hours: 23)),
              ),
            ],
          ),
        ),
      ).run();
      expect(shown, hasLength(1));
      await poller(
        FakeConnection(
          (_) async => page(
            1,
            2,
            entries: [
              entry(
                2,
                event: PublicFeedId('02' * 32),
                observedAt: DateTime.now().subtract(const Duration(hours: 25)),
              ),
            ],
          ),
        ),
      ).run();
      expect(shown, hasLength(1));
      expect((await feed())['cursor'], 2);
    },
  );

  test(
    'delivery uses the latest configured window for a durable outbox',
    () async {
      await baseline();
      await store.commitPage(
        key,
        page(
          0,
          1,
          entries: [
            entry(
              1,
              observedAt: DateTime.now().subtract(const Duration(minutes: 30)),
            ),
          ],
        ),
        DateTime.now(),
      );
      expect(((await feed())['outbox'] as Map), hasLength(1));
      await store.setNotificationWindow(const Duration(minutes: 15));
      await poller(FakeConnection((cursor) async => page(cursor, 1))).run();
      expect(shown, isEmpty);
      expect((await feed())['outbox'], isEmpty);
    },
  );

  test('network errors retain cursor, persist backoff and do not reconnect immediately', () async {
    await baseline();
    var connections = 0;
    final service = PublicFeedPoller(
      store,
      notify: (_, _) async => true,
      connect: (_) async {
        connections++;
        throw const SocketException('offline');
      },
    );
    await service.run();
    await service.run();
    expect(connections, 1);
    expect((await feed())['cursor'], 0);
    expect((await feed())['retryAt'], isNotNull);
    expect((await feed())['blocked'], isFalse);
  });

  test(
    'security errors discard response and block polling with cursor unchanged',
    () async {
      await baseline();
      final connection = FakeConnection(
        (_) async => throw const FormatException(
          'Invalid public feed checkpoint signature',
        ),
      );
      await poller(connection).run();
      expect((await feed())['cursor'], 0);
      expect((await feed())['blocked'], isTrue);
      expect((await feed())['issue'], contains('Security error'));
      expect(connection.closed, isTrue);
      final unexpected = FakeConnection(
        (_) async => throw StateError('Must not connect'),
      );
      await poller(unexpected).run();
      expect(unexpected.cursors, isEmpty);
    },
  );

  test('malformed signature bytes are a security error rather than a network retry', () async {
    final connection = FakeConnection(
      (_) async => throw const IrohKeyException('signature must be 64 bytes'),
    );
    await poller(connection).run();
    expect((await feed())['cursor'], 0);
    expect((await feed())['blocked'], isTrue);
    expect((await feed())['issue'], contains('Security error'));
    expect(connection.closed, isTrue);
  });

  test('NOT_FOUND is unavailable, never starts a signer fallback', () async {
    final connection = FakeConnection(
      (_) async =>
          throw PublicFeedException(ProtocolErrorCode.PROTOCOL_ERROR_NOT_FOUND),
    );
    await poller(connection).run();
    expect((await feed())['cursor'], 0);
    expect((await feed())['issue'], contains('unknown or disabled'));
    expect(Hive.isBoxOpen('sygnature_roast_private_v1'), isFalse);
  });

  test('rollback is reported and never resets the persisted cursor', () async {
    await store.commitPage(key, page(0, 20, oldest: 21), DateTime.now());
    await poller(FakeConnection((_) async => page(20, 3, oldest: 4))).run();
    expect((await feed())['cursor'], 20);
    expect((await feed())['blocked'], isTrue);
    expect((await feed())['issue'], contains('rollback'));
  });

  test('cursor is isolated by coordinator AND feed, and resubscription preserves it', () async {
    await store.commitPage(key, page(0, 7, oldest: 8), DateTime.now());
    final otherPin = await store.subscribe(
      groupId: 'g2',
      address: 'address-b',
      pin: 'pin-b',
      feedId: feedId.hex,
    );
    final otherFeed = await store.subscribe(
      groupId: 'g3',
      address: 'address-c',
      pin: 'pin-a',
      feedId: '02' * 32,
    );
    expect((await feed(otherPin))['cursor'], 0);
    expect((await feed(otherFeed))['cursor'], 0);
    await store.unsubscribe('g1');
    expect(
      await store.subscribe(
        groupId: 'g1',
        address: 'updated-hints',
        pin: 'pin-a',
        feedId: feedId.hex,
      ),
      key,
    );
    expect((await feed())['cursor'], 7);
  });

  test(
    'run deadline closes stalled transport without advancing cursor',
    () async {
      final connection = FakeConnection(
        (_) => Completer<PublicFeedPage>().future,
      );
      await poller(
        connection,
        maxDuration: const Duration(milliseconds: 20),
      ).run();
      expect(connection.closed, isTrue);
      expect((await feed())['cursor'], 0);
      expect((await feed())['issue'], contains('Retrying later'));
    },
  );

  test(
    'stopping local host polling persists independently from publication',
    () async {
      final id = await store.configureHost('g1', true);
      expect(await store.hostPollingEnabled('g1'), isTrue);
      await store.unsubscribe('g1');
      expect(await store.enabledHostId('g1'), id);
      expect(await store.hostPollingEnabled('g1'), isFalse);
      await store.close();
      store = await PublicFeedStore.open(directory.path);
      expect(await store.hostPollingEnabled('g1'), isFalse);
      expect(await store.enabledHostId('g1'), id);
    },
  );

  test(
    'a timed-out connection is closed if it completes after the run',
    () async {
      final ready = Completer<FeedConnection>();
      final connection = FakeConnection((_) async => page(0, 0));
      final service = PublicFeedPoller(
        store,
        notify: (_, _) async => true,
        connect: (_) => ready.future,
        maxDuration: const Duration(milliseconds: 20),
      );
      await service.run();
      expect((await feed())['cursor'], 0);
      ready.complete(connection);
      await Future<void>.delayed(Duration.zero);
      expect(connection.closed, isTrue);
      expect(connection.cursors, isEmpty);
    },
  );

  test(
    'failed local page transaction preserves cursor, event cache and outbox',
    () async {
      await baseline();
      await expectLater(
        store.commitPage(
          key,
          page(0, 2, entries: [entry(2), entry(1)]),
          DateTime.now(),
        ),
        throwsFormatException,
      );
      expect((await feed())['cursor'], 0);
      expect((await feed())['events'], isEmpty);
      expect((await feed())['outbox'], isEmpty);
    },
  );
}
