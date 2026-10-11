import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:hive_ce/hive.dart';
import 'package:noosphere_client/public_feed.dart';

import 'public_feed_store_registry.dart'
    if (dart.library.ui) 'public_feed_store_registry_flutter.dart'
    as registry;

part 'public_feed_store_owner.dart';
part 'public_feed_store_state.dart';

const publicFeedDefaultNotificationWindow = Duration(hours: 1);
const publicFeedMaxNotificationWindow = Duration(hours: 24);

Duration _notificationWindow(Map data) => Duration(
  minutes:
      data['notificationWindowMinutes'] as int? ??
      publicFeedDefaultNotificationWindow.inMinutes,
);

/// Only the shared owner isolate opens Hive. Clients send whole mutations,
/// never a separate read/modify/write sequence or a cached copy of the box.
final class PublicFeedStore._(
  final SendPort _owner,
  final String _registryName,
  final String _clientId,
) {
  static const boxName = 'sygnature_public_feed_v1';
  static final _isolateId = _randomId();
  bool _closed = false;

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  static Future<PublicFeedStore> open(
    String directory, {
    void Function(Isolate)? onOwnerSpawned,
  }) async {
    await Directory(directory).create(recursive: true);
    final canonical = await Directory(directory).resolveSymbolicLinks();
    final name = 'sygnature-public-feed:$canonical';
    for (var attempt = 0; attempt < 3; attempt++) {
      var owner = registry.lookup(name);
      if (owner == null) {
        final ready = ReceivePort();
        try {
          final spawned = await Isolate.spawn(_publicFeedStoreOwner, (
            canonical,
            name,
            ready.sendPort,
          ), debugName: 'PublicFeedStore');
          onOwnerSpawned?.call(spawned);
          owner = await ready.first.timeout(
            const Duration(seconds: 10),
          ) as SendPort?;
        } finally {
          ready.close();
        }
        if (owner == null) continue;
      }
      final store = PublicFeedStore._(owner, name, _randomId());
      try {
        // Only primitive messages cross Flutter engine isolate groups.
        Isolate.current.addOnExitListener(
          owner,
          response: ['exit', _isolateId],
        );
        await store._request<void>([
          'attach',
          _isolateId,
          store._clientId,
        ], timeout: const Duration(seconds: 2));
        registry.remember(owner, name);
        return store;
      } on _StoreOwnerClosed {
        registry.forget(owner, name);
      } on TimeoutException {
        owner.send([
          null,
          ['detach', _isolateId, store._clientId],
        ]);
        registry.forget(owner, name);
      }
    }
    throw const FeedStoreUnavailable();
  }

  Future<T> _request<T>(
    List<Object?> operation, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closed) throw StateError('Public feed store is closed');
    if (operation.first != 'attach' &&
        registry.lookup(_registryName) != _owner) {
      throw const FeedStoreUnavailable();
    }
    final response = ReceivePort();
    try {
      _owner.send([response.sendPort, operation]);
      final result = await response.first.timeout(timeout) as List;
      final value = result[1];
      if (result[0] != true) {
        throw switch (value) {
          'closed' => const _StoreOwnerClosed(),
          'rollback' => const FeedRollback(),
          'lease' => const FeedLeaseLost(),
          'format' => const FormatException('Invalid public feed state'),
          'state' => StateError('Public feed state mutation failed'),
          _ => const FeedStoreUnavailable(),
        };
      }
      return value as T;
    } finally {
      response.close();
    }
  }

  Future<Map<String, dynamic>> snapshot() => _request(['read']);

  Future<void> close() async {
    if (_closed) return;
    try {
      final closedOwner = await _request<bool>([
        'detach',
        _isolateId,
        _clientId,
      ]);
      if (closedOwner) registry.forget(_owner, _registryName);
    } finally {
      _closed = true;
    }
  }

  Future<String?> acquirePollingLease({
    DateTime? now,
    Duration duration = const Duration(minutes: 2),
  }) => _request([
    'acquire',
    now?.toUtc().toIso8601String(),
    duration.inMilliseconds,
  ]);
  Future<void> releasePollingLease(String owner) =>
      _request(['release', owner]);
  Future<void> checkPollingLease(String owner, String feedKey) =>
      _request(['check', owner, feedKey]);
  Future<String?> configureHost(String groupId, bool enabled) =>
      _request(['host', groupId, enabled]);
  Future<String?> enabledHostId(String groupId) async {
    final host = ((await snapshot())['hosts'] as Map)[groupId] as Map?;
    return host?['enabled'] == true ? host!['feedId'] as String : null;
  }

  Future<bool> hostPollingEnabled(String groupId) async =>
      (((await snapshot())['hosts'] as Map)[groupId] as Map?)?['polling'] !=
      false;

  Future<Duration> notificationWindow() async =>
      _notificationWindow(await snapshot());
  Future<void> setNotificationWindow(Duration value) =>
      _request(['notificationWindow', value.inMinutes]);

  Future<String> subscribe({
    required String groupId,
    required String address,
    required String pin,
    required String feedId,
  }) => _request(['subscribe', groupId, address, pin, feedId]);
  Future<void> unsubscribe(String groupId) =>
      _request(['unsubscribe', groupId]);
  Future<void> commitPage(
    String key,
    PublicFeedPage page,
    DateTime now, {
    String? leaseOwner,
  }) => _request([
    'commit',
    key,
    page.toBytes(),
    now.toUtc().toIso8601String(),
    leaseOwner,
  ]);
  Future<void> delivered(String key, String cursor, {String? leaseOwner}) =>
      _request(['delivered', key, cursor, leaseOwner]);
  Future<void> failure(
    String key,
    String issue,
    DateTime now, {
    bool blocked = false,
    String? leaseOwner,
  }) => _request([
    'failure',
    key,
    issue,
    now.toUtc().toIso8601String(),
    blocked,
    leaseOwner,
  ]);
  Future<void> retry(String key) => _request(['retry', key]);
}

final class const FeedRollback() implements Exception;
final class const FeedLeaseLost() implements Exception;
final class const FeedStoreUnavailable() implements Exception;
