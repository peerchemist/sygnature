import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:iroh_quic/iroh_quic.dart';
import 'package:noosphere/wire.dart' show ProtocolErrorCode;
import 'package:noosphere_client/iroh_transport.dart'
    show PinnedEndpointMismatchException;
import 'package:noosphere_client/public_feed.dart';

import '../storage/public_feed_store.dart';

abstract interface class FeedConnection {
  Future<PublicFeedPage> fetch(
    PublicFeedId id, {
    required int afterCursor,
    required int limit,
  });
  Future<void> close();
}

final class _Connection(final PublicFeedClient client)
    implements FeedConnection {
  @override
  Future<PublicFeedPage> fetch(
    PublicFeedId id, {
    required int afterCursor,
    required int limit,
  }) => client.fetch(id, afterCursor: afterCursor, limit: limit);
  @override
  Future<void> close() => client.close();
}

/// Only Iroh is loaded in the calling process/isolate. No wallet bootstrap.
Future<void> initializePublicFeedNative({String? libraryPath}) async {
  if (libraryPath == null && Platform.isMacOS) {
    final executable = File(Platform.resolvedExecutable).parent;
    final framework = File(
      '${executable.parent.path}/Frameworks/iroh_flutter.framework/iroh_flutter',
    );
    if (framework.existsSync()) libraryPath = framework.path;
  }
  await Iroh.init(libraryPath: libraryPath);
}

Future<FeedConnection> connectPublicFeed(Map feed) async {
  await initializePublicFeedNative();
  return _Connection(
    await PublicFeedClient.connect(
      EndpointAddr.decode(base64Url.decode(feed['address'] as String)),
      EndpointId.fromZ32(feed['pin'] as String),
    ),
  );
}

/// UI-independent, locked-wallet polling. The injected delivery callback must
/// replace notifications by the persisted ID and report failures for retries.
final class PublicFeedPoller(
  final PublicFeedStore store, {
  required final Future<bool> Function(int id, String category) notify,
  final Future<FeedConnection> Function(Map feed) connect = connectPublicFeed,
  final int maxPages = 5,
  final Duration maxDuration = const Duration(seconds: 45),
}) {
  Future<void>? _running;
  Timer? _timer;
  int _nextFeed = 0;

  // Same in-process timer mechanism as the existing wallet background work.
  void start() {
    _timer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(run().catchError((Object _) {})),
    );
    unawaited(run().catchError((Object _) {}));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _running;
  }

  Future<void> run() =>
      _running ??= _withLease().whenComplete(() => _running = null);

  Future<void> _withLease() async {
    final owner = await store.acquirePollingLease(
      duration: maxDuration + const Duration(minutes: 2),
    );
    if (owner == null) return;
    try {
      await _run(owner);
    } on FeedLeaseLost {
      // A recovered lease or concurrent unsubscribe is a successful no-op.
    } finally {
      await store.releasePollingLease(owner);
    }
  }

  Future<void> _run(String owner) async {
    final budget = Stopwatch()..start();
    var remaining = maxPages;
    Duration timeLeft() {
      final left = maxDuration - budget.elapsed;
      if (left <= Duration.zero) {
        throw TimeoutException('Public feed run budget');
      }
      return left;
    }

    final state = await store.snapshot();
    final active = (state['bindings'] as Map).values
        .toSet()
        .cast<String>()
        .toList();
    final start = active.isEmpty ? 0 : _nextFeed % active.length;
    for (var index = 0; index < active.length; index++) {
      final position = (start + index) % active.length;
      final key = active[position];
      if (remaining <= 0 || budget.elapsed >= maxDuration) break;
      _nextFeed = position + 1;
      var feed = ((await store.snapshot())['feeds'] as Map)[key] as Map;
      if (feed['blocked'] == true) continue;
      final retryAt = feed['retryAt'] as String?;
      if (retryAt != null && DateTime.parse(retryAt).isAfter(DateTime.now())) {
        continue;
      }
      FeedConnection? client;
      try {
        // Drain committed intent even when the coordinator is temporarily offline.
        await _deliver(key, feed, timeLeft, owner);
        var abandoned = false;
        final connecting = connect(feed).then((connection) async {
          if (abandoned) {
            await connection.close();
            throw TimeoutException('Public feed connection abandoned');
          }
          return connection;
        });
        client = await connecting.timeout(
          timeLeft(),
          onTimeout: () {
            abandoned = true;
            throw TimeoutException('Public feed connection budget');
          },
        );
        while (remaining > 0 && budget.elapsed < maxDuration) {
          remaining--;
          final page = await client
              .fetch(
                PublicFeedId(feed['feedId'] as String),
                afterCursor: feed['cursor'] as int,
                limit: 100,
              )
              .timeout(timeLeft());
          await store.commitPage(
            key,
            page,
            DateTime.now().toUtc(),
            leaseOwner: owner,
          );
          feed = ((await store.snapshot())['feeds'] as Map)[key] as Map;
          await _deliver(key, feed, timeLeft, owner);
          if (!page.hasMore) break;
        }
      } on FeedLeaseLost {
        rethrow;
      } on FeedRollback {
        await store.failure(
          key,
          'Coordinator rollback / configuration mismatch. Cursor retained.',
          DateTime.now(),
          leaseOwner: owner,
          blocked: true,
        );
      } on PinnedEndpointMismatchException {
        await store.failure(
          key,
          'Security error: coordinator identity mismatch.',
          DateTime.now(),
          leaseOwner: owner,
          blocked: true,
        );
      } on FormatException {
        await store.failure(
          key,
          'Security error: invalid signed public feed response.',
          DateTime.now(),
          leaseOwner: owner,
          blocked: true,
        );
      } on IrohKeyException {
        // Malformed signature/key bytes also fail inside the public client.
        await store.failure(
          key,
          'Security error: invalid public feed identity or signature.',
          DateTime.now(),
          leaseOwner: owner,
          blocked: true,
        );
      } on PublicFeedException catch (error) {
        // NOT_FOUND deliberately does not distinguish disabled/unknown feeds.
        await store.failure(
          key,
          error.code == ProtocolErrorCode.PROTOCOL_ERROR_NOT_FOUND
              ? 'Feed unavailable (unknown or disabled).'
              : 'Public feed request failed.',
          DateTime.now(),
          leaseOwner: owner,
        );
      } on Object {
        // Do not log arbitrary transport errors: they may include capabilities.
        await store.failure(
          key,
          'Public feed connection or notification failed. Retrying later.',
          DateTime.now(),
          leaseOwner: owner,
        );
      } finally {
        try {
          await client?.close().timeout(const Duration(seconds: 3));
        } on Object {
          /* No cursor change. */
        }
      }
    }
  }

  Future<void> _deliver(
    String key,
    Map feed,
    Duration Function() timeLeft,
    String owner,
  ) async {
    final notificationWindow = await store.notificationWindow();
    for (final entry in (feed['outbox'] as Map).entries) {
      await store.checkPollingLease(owner, key);
      final item = entry.value as Map;
      final now = DateTime.now().toUtc();
      final expiry = item['expiresAt'] as String?;
      final stale =
          DateTime.parse(item['observedAt'] as String)
              .isBefore(now.subtract(notificationWindow)) ||
          (expiry != null && !DateTime.parse(expiry).isAfter(now));
      if (!stale &&
          !await notify(
            item['id'] as int,
            item['category'] as String,
          ).timeout(timeLeft())) {
        throw StateError('Notification delivery failed');
      }
      await store.delivered(key, entry.key as String, leaseOwner: owner);
    }
  }
}
