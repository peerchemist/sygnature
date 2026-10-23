part of 'public_feed_store.dart';

final class const _StoreOwnerClosed() implements Exception;

/// This separate monitor survives a killed store owner. It alone removes that
/// owner's registration, so recovery cannot remove a newer owner's port.
@pragma('vm:entry-point')
Future<void> _publicFeedStoreMonitor(
  (Isolate, SendPort, String, SendPort) args,
) async {
  final (owner, ownerPort, name, ready) = args;
  final exit = ReceivePort();
  owner.addOnExitListener(exit.sendPort);
  ready.send(exit.sendPort);
  final release = await exit.first;
  if (registry.lookup(name) == ownerPort) registry.remove(name);
  owner.removeOnExitListener(exit.sendPort);
  if (release is SendPort) release.send(null);
  exit.close();
}

/// One ordinary Hive box exists exclusively here, never in a foreground or
/// WorkManager client. The mailbox queue spans get/change/put/flush completely.
@pragma('vm:entry-point')
Future<void> _publicFeedStoreOwner((String, String, SendPort) args) async {
  final (directory, name, ready) = args;
  final requests = ReceivePort();
  final monitorReady = ReceivePort();
  // Start monitoring before publishing the port: even a killed startup owner
  // must not leave an unreachable name registered indefinitely.
  await Isolate.spawn(_publicFeedStoreMonitor, (
    Isolate.current,
    requests.sendPort,
    name,
    monitorReady.sendPort,
  ), debugName: 'PublicFeedStore monitor');
  final monitor = await monitorReady.first as SendPort;
  monitorReady.close();

  Future<void> releaseRegistration() async {
    final released = ReceivePort();
    try {
      monitor.send(released.sendPort);
      await released.first;
    } finally {
      released.close();
    }
  }

  if (!registry.register(requests.sendPort, name)) {
    ready.send(registry.lookup(name));
    await releaseRegistration();
    requests.close();
    return;
  }
  final Box<dynamic> box;
  try {
    box = await Hive.openBox<dynamic>(PublicFeedStore.boxName, path: directory);
  } on Object {
    await releaseRegistration();
    ready.send(null);
    requests.close();
    return;
  }
  ready.send(requests.sendPort);

  final clients = <String, Set<String>>{};
  var pending = Future<void>.value();
  var closing = false;
  Map<String, dynamic> read() => jsonDecode(
    box.get(
      'state',
      defaultValue: '{"hosts":{},"feeds":{},"bindings":{},"nextNotificationId":1073741824}',
    ) as String,
  ) as Map<String, dynamic>;

  requests.listen((message) {
    final exit = message is List && message.first == 'exit';
    final reply = exit ? null : (message as List)[0] as SendPort?;
    final operation = exit ? message : message[1] as List;
    pending = pending.then((_) async {
      if (closing) {
        reply?.send([false, 'closed']);
        return;
      }
      try {
        final data = read();
        final state = _FeedState(data);
        Object? result;
        final kind = operation[0];
        switch (kind) {
          case 'attach':
            clients
                .putIfAbsent(operation[1] as String, () => <String>{})
                .add(operation[2] as String);
          case 'detach':
            final id = operation[1] as String;
            clients[id]?.remove(operation[2]);
            if (clients[id]?.isEmpty ?? false) clients.remove(id);
            result = clients.isEmpty;
          case 'exit':
            clients.remove(operation[1]);
          case 'read':
            result = data;
          case 'check':
            _FeedState._checkLease(
              data,
              operation[1] as String,
              feedKey: operation[2] as String,
            );
          case 'acquire':
            result = await state.acquirePollingLease(
              now: operation[1] == null
                  ? null
                  : DateTime.parse(operation[1] as String),
              duration: Duration(milliseconds: operation[2] as int),
            );
          case 'release':
            await state.releasePollingLease(operation[1] as String);
          case 'host':
            result = await state.configureHost(
              operation[1] as String,
              operation[2] as bool,
            );
          case 'enabledHostId':
            result = await state.enabledHostId(operation[1] as String);
          case 'notificationWindow':
            await state.setNotificationWindow(operation[1] as int);
          case 'subscribe':
            result = await state.subscribe(
              groupId: operation[1] as String,
              address: operation[2] as String,
              pin: operation[3] as String,
              feedId: operation[4] as String,
            );
          case 'bindSetupFeed':
            result = await state.bindFeedFromSetup(
              groupId: operation[1] as String,
              address: operation[2] as String,
              pin: operation[3] as String,
              feedId: operation[4] as String,
            );
          case 'unsubscribe':
            await state.unsubscribe(operation[1] as String);
          case 'suppressLocalRequest':
            result = await state.suppressNextLocalRequest(
              groupId: operation[1] as String,
              category: operation[2] as String,
              expiresAt: DateTime.parse(operation[3] as String),
            );
          case 'cancelLocalRequestSuppression':
            await state.cancelLocalRequestSuppression(
              operation[1] as String,
              operation[2] as String,
            );
          case 'commit':
            await state.commitPage(
              operation[1] as String,
              PublicFeedPage.fromBytes(operation[2] as List<int>),
              DateTime.parse(operation[3] as String),
              leaseOwner: operation[4] as String?,
            );
          case 'delivered':
            await state.delivered(
              operation[1] as String,
              operation[2] as String,
              leaseOwner: operation[3] as String?,
            );
          case 'failure':
            await state.failure(
              operation[1] as String,
              operation[2] as String,
              DateTime.parse(operation[3] as String),
              blocked: operation[4] as bool,
              leaseOwner: operation[5] as String?,
            );
          case 'retry':
            await state.retry(operation[1] as String);
          case 'poll':
            await state.recordPoll(
              operation[1] as String,
              DateTime.parse(operation[2] as String),
            );
          default:
            throw const FeedStoreUnavailable();
        }
        if (!['attach', 'detach', 'exit', 'read', 'check'].contains(kind)) {
          await box.put('state', jsonEncode(data));
          await box.flush();
        }
        if (clients.isEmpty && (kind == 'detach' || kind == 'exit')) {
          closing = true;
          try {
            await box.close();
          } finally {
            await releaseRegistration();
            requests.close();
          }
        }
        reply?.send([true, result]);
      } on Object catch (error) {
        // Only safe codes cross isolate groups, never arbitrary error payloads.
        final safe = switch (error) {
          FeedRollback() => 'rollback',
          FeedLeaseLost() => 'lease',
          FormatException() => 'format',
          StateError() => 'state',
          _ => 'unavailable',
        };
        reply?.send([false, safe]);
      }
    });
  });
}
