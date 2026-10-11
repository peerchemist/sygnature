import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:noosphere_client/public_feed.dart';
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';

import 'public_feed_poller_test.dart' show FakeConnection, entry, feedId, page;

final class IsolateConnection(
  final Future<PublicFeedPage> Function(int) response,
) implements FeedConnection {
  @override
  Future<PublicFeedPage> fetch(
    PublicFeedId id, {
    required int afterCursor,
    required int limit,
  }) => response(afterCursor);
  @override
  Future<void> close() async {}
}

// Independent connections in real isolates, with a deliberately stalled fetch.
Future<void> compete((String, SendPort, int) args) async {
  final (directory, parent, index) = args;
  final control = ReceivePort();
  final store = await PublicFeedStore.open(directory);
  final commands = StreamIterator(control);
  parent.send(('ready', control.sendPort));
  await commands.moveNext();
  await store.configureHost('host-$index', true);
  await PublicFeedPoller(
    store,
    connect: (_) async => IsolateConnection((after) async {
      parent.send(('fetch', index));
      await commands.moveNext();
      return page(after, 1, entries: [entry(1)]);
    }),
    notify: (id, _) async {
      parent.send(('notify', id));
      return true;
    },
  ).run();
  await store.close();
  parent.send(('done', index));
  await commands.cancel();
  control.close();
}

Future<void> coldOpen((String, SendPort, int) args) async {
  final (directory, parent, index) = args;
  final controls = ReceivePort();
  final commands = StreamIterator(controls);
  parent.send(controls.sendPort);
  await commands.moveNext();
  final store = await PublicFeedStore.open(directory);
  await store.configureHost('cold-$index', true);
  parent.send(index);
  await commands.moveNext();
  await store.close();
  parent.send(index);
  await commands.cancel();
  controls.close();
}

Future<void> interruptedWorker((String, SendPort) args) async {
  final (directory, parent) = args;
  final hold = ReceivePort();
  final store = await PublicFeedStore.open(directory);
  final old = DateTime.now().subtract(const Duration(minutes: 10));
  await store.acquirePollingLease(now: old);
  await store.configureHost('interrupted-worker', true);
  parent.send(hold.sendPort);
  await hold.first; // The parent kills us; there is intentionally no close().
}

void main() {
  late Directory directory;
  late PublicFeedStore store;
  late String key;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'public-feed-concurrency-',
    );
    store = await PublicFeedStore.open(directory.path);
    key = await store.subscribe(
      groupId: 'g',
      address: 'address',
      pin: 'pin',
      feedId: feedId.hex,
    );
    await store.commitPage(key, page(0, 0), DateTime.now());
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('foreground and headless connections serialize polling and see latest cursor', () async {
    final background = await PublicFeedStore.open(directory.path);
    final started = Completer<void>();
    final release = Completer<void>();
    var notifications = 0;
    var connections = 0;
    Future<bool> notify(int _, String _) async {
      notifications++;
      return true;
    }

    final foreground = PublicFeedPoller(
      store,
      notify: notify,
      connect: (_) async {
        connections++;
        started.complete();
        await release.future;
        return FakeConnection(
          (after) async => page(after, 1, entries: [entry(1)]),
        );
      },
    ).run();
    await started.future;
    await PublicFeedPoller(
      background,
      notify: notify,
      connect: (_) async {
        connections++;
        return FakeConnection((after) async => page(after, 1));
      },
    ).run();
    await background.configureHost('concurrent-change', true);
    release.complete();
    await foreground;
    final state = await background.snapshot();
    expect(connections, 1);
    expect(notifications, 1);
    expect((state['feeds'] as Map)[key]['cursor'], 1);
    expect((state['hosts'] as Map).containsKey('concurrent-change'), isTrue);
    expect(state['pollingLease'], isNull);
    await background.close();
  });

  test('expired lease recovers a killed worker and fences its late commit and release', () async {
    final old = await store.acquirePollingLease(
      now: DateTime.now().subtract(const Duration(minutes: 10)),
    );
    final recovered = await store.acquirePollingLease();
    expect(recovered, isNotNull);
    expect(recovered, isNot(old));
    await expectLater(
      store.commitPage(
        key,
        page(0, 1, entries: [entry(1)]),
        DateTime.now(),
        leaseOwner: old,
      ),
      throwsA(isA<FeedLeaseLost>()),
    );
    await store.releasePollingLease(old!);
    expect(await store.acquirePollingLease(), isNull);
    await store.commitPage(
      key,
      page(0, 1, entries: [entry(1)]),
      DateTime.now(),
      leaseOwner: recovered,
    );
    await store.releasePollingLease(recovered!);
    expect((await store.snapshot())['pollingLease'], isNull);
  });

  test('concurrent real isolates cannot both fetch, commit or notify the same cursor', () async {
    final messages = ReceivePort();
    final stream = StreamIterator(messages);
    final controls = <SendPort>[];
    final workers = <Isolate>[];
    for (var index = 0; index < 2; index++) {
      workers.add(
        await Isolate.spawn(compete, (
          directory.path,
          messages.sendPort,
          index,
        )),
      );
    }
    addTearDown(() {
      for (final worker in workers) {
        worker.kill();
      }
      messages.close();
    });
    while (controls.length < 2) {
      expect(await stream.moveNext(), isTrue);
      final event = stream.current as (String, SendPort);
      expect(event.$1, 'ready');
      controls.add(event.$2);
    }
    for (final control in controls) {
      control.send('start');
    }
    var fetches = 0;
    var done = 0;
    var notified = 0;
    while (fetches == 0 || done == 0) {
      expect(await stream.moveNext(), isTrue);
      final event = stream.current as (String, int);
      if (event.$1 == 'fetch') fetches++;
      if (event.$1 == 'done') done++;
    }
    for (final control in controls) {
      control.send('complete');
    }
    while (done < 2) {
      expect(await stream.moveNext(), isTrue);
      final event = stream.current as (String, int);
      if (event.$1 == 'fetch') fetches++;
      if (event.$1 == 'notify') notified++;
      if (event.$1 == 'done') done++;
    }
    expect(fetches, 1);
    expect(notified, 1);
    final state = await store.snapshot();
    expect((state['feeds'] as Map)[key]['cursor'], 1);
    expect((state['feeds'] as Map)[key]['outbox'], isEmpty);
    expect((state['hosts'] as Map).keys, containsAll(['host-0', 'host-1']));
    await stream.cancel();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
    'simultaneous first opens elect one Hive owner and retain both mutations',
    () async {
      final fresh = await Directory.systemTemp.createTemp('public-feed-cold-');
      final messages = ReceivePort();
      final events = StreamIterator(messages);
      final workers = <Isolate>[];
      try {
        for (var index = 0; index < 2; index++) {
          workers.add(
            await Isolate.spawn(coldOpen, (
              fresh.path,
              messages.sendPort,
              index,
            )),
          );
        }
        final controls = <SendPort>[];
        while (controls.length < 2) {
          await events.moveNext();
          controls.add(events.current as SendPort);
        }
        for (final control in controls) {
          control.send('open');
        }
        for (var index = 0; index < 2; index++) {
          await events.moveNext();
        }
        final reader = await PublicFeedStore.open(fresh.path);
        expect(
          (await reader.snapshot())['hosts'].keys,
          containsAll(['cold-0', 'cold-1']),
        );
        for (final control in controls) {
          control.send('close');
        }
        for (var index = 0; index < 2; index++) {
          await events.moveNext();
        }
        await reader.close();
      } finally {
        for (final worker in workers) {
          worker.kill();
        }
        await events.cancel();
        messages.close();
        await fresh.delete(recursive: true);
      }
    },
  );

  test('killing the worker that spawned the Hive owner does not block another engine', () async {
    final fresh = await Directory.systemTemp.createTemp(
      'public-feed-killed-worker-',
    );
    final ready = ReceivePort();
    final exited = ReceivePort();
    final worker = await Isolate.spawn(interruptedWorker, (
      fresh.path,
      ready.sendPort,
    ), onExit: exited.sendPort);
    try {
      await ready.first;
      // Attach before the creator exits: its shared store must survive it.
      final survivor = await PublicFeedStore.open(fresh.path);
      worker.kill(priority: Isolate.immediate);
      await exited.first;
      expect(
        (await survivor.snapshot())['hosts']['interrupted-worker']['enabled'],
        isTrue,
      );
      final recovered = await survivor.acquirePollingLease();
      expect(recovered, isNotNull);
      await survivor.releasePollingLease(recovered!);
      await survivor.close();
      final restarted = await PublicFeedStore.open(fresh.path);
      expect((await restarted.snapshot())['pollingLease'], isNull);
      await restarted.close();
    } finally {
      worker.kill();
      ready.close();
      exited.close();
      await fresh.delete(recursive: true);
    }
  });

  test('a killed Hive owner is unregistered and the next open recovers flushed data', () async {
    final fresh = await Directory.systemTemp.createTemp(
      'public-feed-killed-owner-',
    );
    Isolate? owner;
    final connection = await PublicFeedStore.open(
      fresh.path,
      onOwnerSpawned: (isolate) => owner = isolate,
    );
    await connection.configureHost('durable', true);
    final name = 'sygnature-public-feed:${await fresh.resolveSymbolicLinks()}';
    final port = ui.IsolateNameServer.lookupPortByName(name);
    final exited = ReceivePort();
    try {
      owner!.addOnExitListener(exited.sendPort);
      owner!.kill(priority: Isolate.immediate);
      await exited.first;
      for (
        var attempt = 0;
        attempt < 100 && ui.IsolateNameServer.lookupPortByName(name) == port;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(ui.IsolateNameServer.lookupPortByName(name), isNull);
      final reopened = await PublicFeedStore.open(fresh.path);
      expect(
        (await reopened.snapshot())['hosts']['durable']['enabled'],
        isTrue,
      );
      await expectLater(
        connection.close(),
        throwsA(isA<FeedStoreUnavailable>()),
      );
      await reopened.close();
    } finally {
      exited.close();
      await fresh.delete(recursive: true);
    }
  });

  test('unsubscribing during a fetch prevents stale cursor commit and notification', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final run = PublicFeedPoller(
      store,
      notify: (_, _) async => throw StateError('must not notify'),
      connect: (_) async => FakeConnection((after) async {
        started.complete();
        await release.future;
        return page(after, 1, entries: [entry(1)]);
      }),
    ).run();
    await started.future;
    await store.unsubscribe('g');
    release.complete();
    await run;
    expect((await store.snapshot())['feeds'][key]['cursor'], 0);
  });

  test(
    'existing Hive v1 state remains readable and writable without migration',
    () async {
      final legacyDirectory = await Directory.systemTemp.createTemp(
        'public-feed-legacy-',
      );
      try {
        final original = await store.snapshot();
        await store.commitPage(
          key,
          page(0, 1, entries: [entry(1)]),
          DateTime.now(),
        );
        final saved = await store.snapshot();
        expect(saved, isNot(original));
        final legacy = await Hive.openBox<dynamic>(
          PublicFeedStore.boxName,
          path: legacyDirectory.path,
        );
        await legacy.put('state', jsonEncode(saved));
        await legacy.close();
        final existing = await PublicFeedStore.open(legacyDirectory.path);
        expect(await existing.snapshot(), saved);
        await existing.configureHost('new-host', true);
        await existing.close();
        // It is still the original box/JSON format, with no second database.
        final originalBox = await Hive.openBox<dynamic>(
          PublicFeedStore.boxName,
          path: legacyDirectory.path,
        );
        final raw = jsonDecode(originalBox.get('state') as String) as Map;
        expect(raw['hosts']['new-host']['enabled'], isTrue);
        expect(raw['feeds'][key], saved['feeds'][key]);
        await originalBox.close();
        expect(
          await legacyDirectory.list().any(
            (file) => file.path.contains('.sqlite'),
          ),
          isFalse,
        );
        final reopened = await PublicFeedStore.open(legacyDirectory.path);
        expect(
          (await reopened.snapshot())['hosts']['new-host']['enabled'],
          isTrue,
        );
        expect((await reopened.snapshot())['feeds'][key], saved['feeds'][key]);
        await reopened.close();
      } finally {
        await legacyDirectory.delete(recursive: true);
      }
    },
  );
}
