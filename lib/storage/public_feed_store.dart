import 'dart:async';
import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:noosphere_client/public_feed.dart';

/// App-private notification database. Never opens the vault, keyring or ROAST
/// storage. One flushed Hive record is the commit point for a page + outbox.
final class PublicFeedStore(final Box<dynamic> _box) {
  Future<void> _writes = Future.value();
  static const boxName = 'sygnature_public_feed_v1';

  static Future<PublicFeedStore> open(String directory) async {
    return PublicFeedStore(
      await Hive.openBox<dynamic>(boxName, path: directory),
    );
  }

  Map<String, dynamic> _read() => jsonDecode(
    _box.get(
      'state',
      defaultValue: '{"hosts":{},"feeds":{},"bindings":{},"nextNotificationId":1073741824}',
    ) as String,
  ) as Map<String, dynamic>;

  Future<T> _mutate<T>(T Function(Map<String, dynamic>) change) {
    final result = Completer<T>();
    _writes = _writes.then((_) async {
      try {
        final data = _read();
        final value = change(data);
        await _box.put('state', jsonEncode(data));
        await _box.flush();
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<Map<String, dynamic>> snapshot() async {
    await _writes;
    return _read();
  }

  /// Persist before starting the coordinator. Disabling retains the random ID.
  Future<String?> configureHost(String groupId, bool enabled) =>
      _mutate((data) {
        final hosts = data['hosts'] as Map;
        final host = (hosts[groupId] as Map?) ?? <String, dynamic>{};
        if (enabled) {
          host['feedId'] ??= PublicFeedId.generate().hex;
          if (host['enabled'] != true) host['polling'] = true;
        }
        host['enabled'] = enabled;
        hosts[groupId] = host;
        return host['feedId'] as String?;
      });

  Future<String?> enabledHostId(String groupId) async {
    final host = ((await snapshot())['hosts'] as Map)[groupId] as Map?;
    return host?['enabled'] == true ? host!['feedId'] as String : null;
  }

  Future<bool> hostPollingEnabled(String groupId) async =>
      (((await snapshot())['hosts'] as Map)[groupId] as Map?)?['polling'] !=
      false;

  /// Call only with credentials obtained via the trusted local/share flow.
  /// Address is postcard EndpointAddr bytes; pin is independently approved.
  Future<String> subscribe({
    required String groupId,
    required String address,
    required String pin,
    required String feedId,
  }) => _mutate((data) {
    PublicFeedId(feedId);
    final key = '$pin:$feedId';
    final feeds = data['feeds'] as Map;
    feeds[key] ??= {
      'pin': pin,
      'feedId': feedId,
      'cursor': 0,
      'events': <String, dynamic>{},
      'outbox': <String, dynamic>{},
      'historyGap': false,
      'failures': 0,
    };
    (feeds[key] as Map)['address'] = address;
    (data['bindings'] as Map)[groupId] = key;
    final host = (data['hosts'] as Map)[groupId] as Map?;
    if (host != null) host['polling'] = true;
    return key;
  });

  Future<void> unsubscribe(String groupId) => _mutate((data) {
    (data['bindings'] as Map).remove(groupId);
    final host = (data['hosts'] as Map)[groupId] as Map?;
    if (host != null) host['polling'] = false;
    // Keep scoped cursor/outbox bookkeeping for a later re-subscription.
  });

  Future<void> commitPage(
    String key,
    PublicFeedPage page,
    DateTime now,
  ) => _mutate((data) {
    final feed = (data['feeds'] as Map)[key] as Map;
    final cursor = feed['cursor'] as int;
    if (page.latestCursor < cursor) throw const FeedRollback();
    if (page.afterCursor != cursor || page.feedId.hex != feed['feedId']) {
      throw const FormatException('Public feed page scope mismatch');
    }
    // No initial history notifications, including multi-run catch-up.
    feed['initialThrough'] ??= page.latestCursor;
    final events = feed['events'] as Map;
    final outbox = feed['outbox'] as Map;
    var previous = cursor;
    for (final entry in page.entries) {
      if (entry.cursor <= previous) {
        throw const FormatException('Public feed entries out of order');
      }
      previous = entry.cursor;
      events.remove(entry.eventId.hex);
      events[entry.eventId.hex] = {
        'cursor': entry.cursor,
        'category': entry.category.name,
        'state': entry.state.name,
        'observedAt': entry.observedAt.toUtc().toIso8601String(),
        'expiresAt': entry.expiresAt?.toUtc().toIso8601String(),
      };
      if (entry.state != PublicFeedLifecycle.requested) {
        outbox.removeWhere(
          (_, value) => (value as Map)['eventId'] == entry.eventId.hex,
        );
        continue;
      }
      if (entry.cursor <= (feed['initialThrough'] as int) ||
          entry.observedAt.isBefore(now.subtract(const Duration(minutes: 5))) ||
          entry.observedAt.isAfter(now.add(const Duration(minutes: 1))) ||
          (entry.expiresAt != null && !entry.expiresAt!.isAfter(now))) {
        continue;
      }
      final id = data['nextNotificationId'] as int;
      if (id >= 0x7fffffff) throw StateError('Notification IDs exhausted');
      data['nextNotificationId'] = id + 1;
      outbox['${entry.cursor}'] = {
        'id': id,
        'eventId': entry.eventId.hex,
        'category': entry.category.name,
        'observedAt': entry.observedAt.toUtc().toIso8601String(),
        'expiresAt': entry.expiresAt?.toUtc().toIso8601String(),
      };
    }
    // Only a bounded recent public status cache, never protocol request IDs.
    while (events.length > 200) {
      events.remove(events.keys.first);
    }
    feed['historyGap'] = feed['historyGap'] == true || page.historyGap;
    feed['cursor'] = page.nextCursor; // Empty pages advance too.
    feed['failures'] = 0;
    feed.remove('retryAt');
    feed.remove('issue');
  });

  Future<void> delivered(String key, String cursor) => _mutate((data) {
    (((data['feeds'] as Map)[key] as Map)['outbox'] as Map).remove(cursor);
  });

  Future<void> failure(
    String key,
    String issue,
    DateTime now, {
    bool blocked = false,
  }) => _mutate((data) {
    final feed = (data['feeds'] as Map)[key] as Map;
    final count = ((feed['failures'] as int) + 1).clamp(1, 10);
    feed['failures'] = count;
    feed['issue'] = issue;
    feed['blocked'] = blocked;
    feed['retryAt'] = now
        .add(Duration(seconds: (15 * (1 << count)).clamp(30, 3600)))
        .toUtc()
        .toIso8601String();
  });

  Future<void> retry(String key) => _mutate((data) {
    final feed = (data['feeds'] as Map)[key] as Map;
    feed['blocked'] = false;
    feed.remove('retryAt');
  });
}

final class const FeedRollback() implements Exception;
