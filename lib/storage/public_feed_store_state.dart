part of 'public_feed_store.dart';

/// All read/change/write logic executes only in the shared Hive owner.
final class _FeedState(final Map<String, dynamic> data) {
  Future<T> _mutate<T>(
    T Function(Map<String, dynamic>) change, {
    String? leaseOwner,
    String? feedKey,
  }) async {
    if (leaseOwner != null) _checkLease(data, leaseOwner, feedKey: feedKey);
    return change(data);
  }

  /// A killed engine releases no lease; another owner recovers after expiry.
  Future<String?> acquirePollingLease({
    DateTime? now,
    Duration duration = const Duration(minutes: 2),
  }) => _mutate((data) {
    final time = (now ?? DateTime.now()).toUtc();
    final lease = data['pollingLease'] as Map?;
    if (lease != null &&
        DateTime.parse(lease['expiresAt'] as String).isAfter(time)) {
      return null;
    }
    final random = Random.secure();
    final owner = base64UrlEncode(
      List.generate(24, (_) => random.nextInt(256)),
    );
    data['pollingLease'] = {
      'owner': owner,
      'expiresAt': time.add(duration).toIso8601String(),
    };
    return owner;
  });

  Future<void> releasePollingLease(String owner) => _mutate((data) {
    if ((data['pollingLease'] as Map?)?['owner'] == owner) {
      data.remove('pollingLease');
    }
  });

  static void _checkLease(Map data, String owner, {String? feedKey}) {
    final lease = data['pollingLease'] as Map?;
    if (lease == null ||
        lease['owner'] != owner ||
        !DateTime.parse(lease['expiresAt'] as String)
            .isAfter(DateTime.now().toUtc())) {
      throw const FeedLeaseLost();
    }
    // A concurrent unsubscribe must also stop delivery from a stale snapshot.
    if (feedKey != null && !(data['bindings'] as Map).containsValue(feedKey)) {
      throw const FeedLeaseLost();
    }
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
    DateTime now, {
    String? leaseOwner,
  }) => _mutate(
    (data) {
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
            entry.observedAt.isBefore(
              now.subtract(const Duration(minutes: 5)),
            ) ||
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
    },
    leaseOwner: leaseOwner,
    feedKey: key,
  );

  Future<void> delivered(String key, String cursor, {String? leaseOwner}) =>
      _mutate(
        (data) {
          (((data['feeds'] as Map)[key] as Map)['outbox'] as Map).remove(
            cursor,
          );
        },
        leaseOwner: leaseOwner,
        feedKey: key,
      );

  Future<void> failure(
    String key,
    String issue,
    DateTime now, {
    bool blocked = false,
    String? leaseOwner,
  }) => _mutate(
    (data) {
      final feed = (data['feeds'] as Map)[key] as Map;
      final count = ((feed['failures'] as int) + 1).clamp(1, 10);
      feed['failures'] = count;
      feed['issue'] = issue;
      feed['blocked'] = blocked;
      feed['retryAt'] = now
          .add(Duration(seconds: (15 * (1 << count)).clamp(30, 3600)))
          .toUtc()
          .toIso8601String();
    },
    leaseOwner: leaseOwner,
    feedKey: key,
  );

  Future<void> retry(String key) => _mutate((data) {
    final feed = (data['feeds'] as Map)[key] as Map;
    feed['blocked'] = false;
    feed.remove('retryAt');
  });
}
