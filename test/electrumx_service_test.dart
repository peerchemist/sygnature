import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';

const _mainnetAddress = 'PRq95DFpcQHMs3XqewNtuvB8vKkXCuLN6c';

void main() {
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
    expect(
      connection.methods.where(
        (method) => method == 'blockchain.scripthash.subscribe',
      ),
      hasLength(1),
    );
  });

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

class _FakeConnection implements ElectrumxConnection {
  _FakeConnection({
    this.genesisHash =
        '0000000032fe677166d54963b62a4677d8957e87c508eaa4fd7eb1c880cd27e3',
    this.broadcastError,
  });

  final String genesisHash;
  final Map<String, Object>? broadcastError;
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final List<String> methods = [];
  bool closed = false;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void send(String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    final id = request['id'] as int;
    final method = request['method'] as String;
    methods.add(method);
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
      'blockchain.scripthash.subscribe' => 'status-1',
      'blockchain.scripthash.listunspent' => [
        {
          'tx_hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'tx_pos': 2,
          'height': 42,
          'value': 1250000,
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

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _controller.close();
  }
}
