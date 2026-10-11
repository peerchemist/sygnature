// Standalone VM probe: spawnUri creates a separate isolate group, matching the
// message restrictions between foreground and headless Flutter engines.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:sygnature_ng/storage/public_feed_store_registry.dart'
    as registry;

Future<void> main(List<String> arguments, [Object? message]) async {
  if (message is List) {
    final owner = message[0] as SendPort;
    final directory = message[1] as String;
    final parent = message[2] as SendPort;
    registry.remember(owner, 'sygnature-public-feed:$directory');
    final store = await PublicFeedStore.open(directory);
    final control = ReceivePort();
    try {
      await store.configureHost('headless-engine', true);
      final lease = await store.acquirePollingLease();
      if (lease == null) throw StateError('Missing lease');
      parent.send(control.sendPort);
      await control.first;
      await store.releasePollingLease(lease);
    } finally {
      control.close();
      await store.close();
    }
    parent.send(true);
    return;
  }
  final directory = await Directory.systemTemp.createTemp('feed-engine-probe-');
  final store = await PublicFeedStore.open(directory.path);
  final messages = ReceivePort();
  final events = StreamIterator(messages);
  try {
    final canonical = await directory.resolveSymbolicLinks();
    final owner = registry.lookup('sygnature-public-feed:$canonical')!;
    await Isolate.spawnUri(
      Platform.script,
      ['child'],
      [owner, canonical, messages.sendPort],
    );
    if (!await events.moveNext()) throw StateError('Worker exited');
    final control = events.current as SendPort;
    if (await store.acquirePollingLease() != null) {
      throw StateError('Concurrent engines acquired the lease');
    }
    await store.configureHost('foreground-engine', true);
    control.send(null);
    if (!await events.moveNext() || events.current != true) {
      throw StateError('Worker failed');
    }
    final hosts = (await store.snapshot())['hosts'] as Map;
    if (hosts.length != 2) throw StateError('Lost engine mutation');
    final lease = await store.acquirePollingLease();
    if (lease == null) throw StateError('Lease was not released');
    await store.releasePollingLease(lease);
  } finally {
    await events.cancel();
    messages.close();
    await store.close();
    await directory.delete(recursive: true);
  }
  stdout.writeln('ok');
}
