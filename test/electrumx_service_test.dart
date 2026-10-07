import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';

const _mainnetAddress = 'PRq95DFpcQHMs3XqewNtuvB8vKkXCuLN6c';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('computes the Electrum script hash for a Peercoin address', () {
    expect(
      PeercoinElectrumxService.scriptHashForAddress(
        _mainnetAddress,
        PeercoinElectrumxNetworks.mainnet.network,
      ),
      '841d76bb56709c81d85175bd07a438a2e37072372ee2d9792f5fa1e536dba87c',
    );
  });

  test('rejects malformed or negative UTXO fields', () {
    expect(
      () => ElectrumxUtxo.fromJson(
        address: _mainnetAddress,
        value: {
          'tx_hash': 'not-a-hash',
          'tx_pos': -1,
          'height': 0,
          'value': -1,
        },
      ),
      throwsFormatException,
    );
  });

  test('handshakes, verifies the network, and parses UTXOs', () async {
    final connection = _FakeConnection();
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => connection,
    );
    addTearDown(service.close);

    final utxos = await service.fetchUtxos(_mainnetAddress);

    expect(
      connection.methods,
      containsAllInOrder([
        'server.version',
        'server.features',
        'blockchain.scripthash.listunspent',
      ]),
    );
    expect(utxos, hasLength(1));
    expect(utxos.single.address, _mainnetAddress);
    expect(
      utxos.single.txHash,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(utxos.single.txPos, 2);
    expect(utxos.single.height, 42);
    expect(utxos.single.value, 1250000);
    expect(utxos.single.isConfirmed, isTrue);
    expect(connection.closed, isTrue);
  });

  test('fails over from the preferred backend to the next server', () async {
    final attempts = <Uri>[];
    final connection = _FakeConnection();
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (uri) async {
        attempts.add(uri);
        if (attempts.length == 1) throw StateError('offline');
        return connection;
      },
    );
    addTearDown(service.close);

    final result = await service.broadcastTransaction('deadbeef');

    expect(result, 'transaction-id');
    expect(attempts, PeercoinElectrumxNetworks.mainnet.servers);
  });

  test('uses a custom WebSocket endpoint before built-in servers', () async {
    final attempts = <Uri>[];
    final customEndpoint = Uri.parse('wss://electrum.example.com:50004');
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      preferredServer: customEndpoint,
      connector: (uri) async {
        attempts.add(uri);
        return _FakeConnection();
      },
    );
    addTearDown(service.close);

    await service.fetchUtxos(_mainnetAddress);

    expect(attempts, [customEndpoint]);
  });

  test('validates custom Electrum WebSocket endpoints', () {
    expect(
      PeercoinElectrumxService.parseEndpoint(
        '  wss://electrum.example.com:50004  ',
      ),
      Uri.parse('wss://electrum.example.com:50004'),
    );
    expect(
      () => PeercoinElectrumxService.parseEndpoint(
        'https://electrum.example.com',
      ),
      throwsFormatException,
    );
    expect(
      () => PeercoinElectrumxService.parseEndpoint('wss:///missing-host'),
      throwsFormatException,
    );
  });

  test('preserves the JSON-RPC rejection after all backends fail', () async {
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => _FakeConnection(
        broadcastError: const {
          'code': -26,
          'message': 'bad-txns-inputs-missingorspent',
        },
      ),
    );
    addTearDown(service.close);

    await expectLater(
      service.broadcastTransaction('deadbeef'),
      throwsA(
        isA<ElectrumxException>().having(
          (error) => (error.cause as ElectrumxException).cause,
          'JSON-RPC error',
          const {'code': -26, 'message': 'bad-txns-inputs-missingorspent'},
        ),
      ),
    );
  });

  test('rejects a backend for a different blockchain', () async {
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => _FakeConnection(genesisHash: 'wrong-network'),
      timeout: const Duration(milliseconds: 100),
    );
    addTearDown(service.close);

    await expectLater(
      service.fetchUtxos(_mainnetAddress),
      throwsA(isA<ElectrumxException>()),
    );
  });

  test('subscription emits an initial UTXO snapshot', () async {
    final connection = _FakeConnection();
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => connection,
      reconnectDelay: Duration.zero,
    );
    addTearDown(service.close);

    final snapshot = await service.watchUtxosForAddresses([
      _mainnetAddress,
      _mainnetAddress,
    ]).first;

    expect(snapshot.address, _mainnetAddress);
    expect(snapshot.utxos.single.value, 1250000);
    expect(snapshot.history.single.height, 0);
    expect(
      snapshot.history.single.transactionId,
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );
    expect(
      connection.methods.where(
        (method) => method == 'blockchain.scripthash.subscribe',
      ),
      hasLength(1),
    );
  });

  test('keeps an active subscription alive with server ping', () async {
    final connection = _FakeConnection();
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => connection,
      keepAliveInterval: const Duration(milliseconds: 10),
    );
    addTearDown(service.close);

    final subscription = service
        .watchUtxosForAddresses([_mainnetAddress])
        .listen((_) {});
    addTearDown(subscription.cancel);

    await connection.pingReceived.future.timeout(const Duration(seconds: 1));

    expect(connection.methods, contains('server.ping'));
  });

  test('reconnects after a snapshot request times out', () async {
    final stale = _FakeConnection();
    final replacement = _FakeConnection();
    var attempts = 0;
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => attempts++ == 0 ? stale : replacement,
      timeout: const Duration(milliseconds: 30),
      reconnectDelay: Duration.zero,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(service.close);
    final initial = Completer<void>();
    final recovered = Completer<void>();
    final errors = <Object>[];
    final subscription = service
        .watchUtxosForAddresses([_mainnetAddress])
        .listen((_) {
          if (!initial.isCompleted) {
            initial.complete();
          } else if (!recovered.isCompleted) {
            recovered.complete();
          }
        }, onError: errors.add);
    addTearDown(subscription.cancel);
    await initial.future;
    stale.ignoredMethods.add('blockchain.scripthash.listunspent');
    stale.notifyStatus();

    await recovered.future.timeout(const Duration(seconds: 1));
    expect(attempts, 2);
    expect(errors, isNotEmpty);
  });

  test('silent socket with stalled close cannot block reconnect', () async {
    final closeCompletion = Completer<void>();
    final stale = _FakeConnection(closeCompletion: closeCompletion);
    final replacement = _FakeConnection();
    var attempts = 0;
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => attempts++ == 0 ? stale : replacement,
      timeout: const Duration(milliseconds: 30),
      reconnectDelay: Duration.zero,
      keepAliveInterval: const Duration(milliseconds: 10),
    );
    addTearDown(service.close);
    final initial = Completer<void>();
    final recovered = Completer<void>();
    final subscription = service
        .watchUtxosForAddresses([_mainnetAddress])
        .listen((_) {
          if (!initial.isCompleted) {
            initial.complete();
          } else if (!recovered.isCompleted) {
            recovered.complete();
          }
        }, onError: (Object _) {});
    addTearDown(subscription.cancel);
    addTearDown(() => closeCompletion.complete());
    await initial.future;
    stale.ignoredMethods.add('server.ping');

    await recovered.future.timeout(const Duration(seconds: 1));
    expect(attempts, 2);
    expect(stale.closed, isTrue);
  });

  test('refresh checks a cached socket before subscribing again', () async {
    final stale = _FakeConnection();
    final replacement = _FakeConnection();
    var attempts = 0;
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => attempts++ == 0 ? stale : replacement,
      timeout: const Duration(milliseconds: 30),
      reconnectDelay: Duration.zero,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(service.close);
    await service.watchUtxosForAddresses([_mainnetAddress]).first;
    stale.ignoredMethods.addAll([
      'server.ping',
      'blockchain.scripthash.subscribe',
    ]);

    final snapshot = await service
        .watchUtxosForAddresses([_mainnetAddress])
        .handleError((Object _) {})
        .first
        .timeout(const Duration(seconds: 1));
    expect(snapshot.address, _mainnetAddress);
    expect(attempts, 2);
  });

  test('closes a connection that arrives after its connect timeout', () async {
    final lateConnection = Completer<ElectrumxConnection>();
    final stale = _FakeConnection();
    final replacement = _FakeConnection();
    var attempts = 0;
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) =>
          attempts++ == 0 ? lateConnection.future : Future.value(replacement),
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(service.close);
    await service.fetchUtxos(_mainnetAddress);
    lateConnection.complete(stale);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(stale.closed, isTrue);
  });

  test('resume checks the socket without waiting for the heartbeat', () async {
    final stale = _FakeConnection();
    final replacement = _FakeConnection();
    var attempts = 0;
    final service = PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.mainnet,
      connector: (_) async => attempts++ == 0 ? stale : replacement,
      timeout: const Duration(milliseconds: 30),
      reconnectDelay: Duration.zero,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(service.close);
    final initial = Completer<void>();
    final recovered = Completer<void>();
    final subscription = service
        .watchUtxosForAddresses([_mainnetAddress])
        .listen((_) {
          if (!initial.isCompleted) {
            initial.complete();
          } else if (!recovered.isCompleted) {
            recovered.complete();
          }
        }, onError: (Object _) {});
    addTearDown(subscription.cancel);
    await initial.future;
    stale.ignoredMethods.add('server.ping');
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );

    await recovered.future.timeout(const Duration(seconds: 1));
    expect(attempts, 2);
  });

  test(
    'service closed during connect does not retain the new socket',
    () async {
      final connecting = Completer<ElectrumxConnection>();
      final started = Completer<void>();
      final connection = _FakeConnection();
      var attempts = 0;
      final service = PeercoinElectrumxService(
        electrumNetwork: PeercoinElectrumxNetworks.mainnet,
        connector: (_) {
          attempts++;
          started.complete();
          return connecting.future;
        },
      );
      final subscription = service
          .watchUtxosForAddresses([_mainnetAddress])
          .listen(
            (_) => fail('A closed service must not emit a snapshot.'),
            onError: (Object _) {},
          );
      addTearDown(subscription.cancel);
      addTearDown(service.close);
      await started.future;
      final closing = service.close();
      connecting.complete(connection);

      await closing.timeout(const Duration(seconds: 1));
      expect(connection.closed, isTrue);
      expect(attempts, 1);
    },
  );

  test(
    'subscription cancellation completes after the initial snapshot',
    () async {
      final connection = _FakeConnection();
      final service = PeercoinElectrumxService(
        electrumNetwork: PeercoinElectrumxNetworks.mainnet,
        connector: (_) async => connection,
        reconnectDelay: Duration.zero,
      );
      addTearDown(service.close);
      final firstSnapshot = Completer<PeercoinElectrumxUtxoSnapshot>();

      final subscription = service
          .watchUtxosForAddresses([_mainnetAddress])
          .listen((snapshot) {
            if (!firstSnapshot.isCompleted) firstSnapshot.complete(snapshot);
          }, onError: firstSnapshot.completeError);
      await firstSnapshot.future;
      await Future<void>.delayed(Duration.zero);

      await subscription.cancel().timeout(const Duration(seconds: 1));
      final restartedSnapshot = await service
          .watchUtxosForAddresses([_mainnetAddress])
          .first
          .timeout(const Duration(seconds: 1));

      expect(restartedSnapshot.address, _mainnetAddress);
    },
  );
}

class _FakeConnection({
  final String genesisHash =
      '0000000032fe677166d54963b62a4677d8957e87c508eaa4fd7eb1c880cd27e3',
  final Map<String, Object>? broadcastError,
  final Completer<void>? closeCompletion,
}) implements ElectrumxConnection {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final List<String> methods = [];
  final Set<String> ignoredMethods = {};
  String? _scriptHash;
  final Completer<void> pingReceived = Completer<void>();
  bool closed = false;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void send(String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    final id = request['id'] as int;
    final method = request['method'] as String;
    methods.add(method);
    if (method == 'blockchain.scripthash.subscribe') {
      _scriptHash = (request['params'] as List).single as String;
    }
    if (ignoredMethods.contains(method)) return;
    if (method == 'server.ping' && !pingReceived.isCompleted) {
      pingReceived.complete();
    }
    if (method == 'blockchain.transaction.broadcast' &&
        broadcastError != null) {
      scheduleMicrotask(
        () => _controller.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': broadcastError}),
        ),
      );
      return;
    }
    final result = switch (method) {
      'server.version' => ['ElectrumX 1.20', '1.4'],
      'server.features' => {
        'genesis_hash': genesisHash,
        'hash_function': 'sha256',
        'protocol_max': '1.4.3',
      },
      'server.ping' => null,
      'blockchain.scripthash.subscribe' => 'status-1',
      'blockchain.scripthash.listunspent' => [
        {
          'tx_hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'tx_pos': 2,
          'height': 42,
          'value': 1250000,
        },
      ],
      'blockchain.scripthash.get_history' => [
        {
          'tx_hash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'height': 0,
          'fee': 1000,
        },
      ],
      'blockchain.transaction.broadcast' => 'transaction-id',
      _ => throw StateError('Unexpected ElectrumX method: $method'),
    };
    scheduleMicrotask(
      () => _controller.add(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      ),
    );
  }

  void notifyStatus() {
    _controller.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'blockchain.scripthash.subscribe',
        'params': [_scriptHash, 'status-2'],
      }),
    );
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // Closing an unlistened fake stream can wait forever, just like a stale
    // transport. Allow tests to model that explicitly with closeCompletion.
    unawaited(_controller.close());
    await closeCompletion?.future;
  }
}
