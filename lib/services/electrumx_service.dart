import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/electrumx_utxo.dart';
import 'app_logger.dart';
import 'peercoin_network_service.dart';

class PeercoinElectrumxNetwork {
  const PeercoinElectrumxNetwork({
    required this.preset,
    required this.genesisHash,
    required this.requiredProtocol,
    required this.servers,
  });

  final PeercoinNetworkPreset preset;
  final String genesisHash;
  final String requiredProtocol;
  final List<Uri> servers;

  Network get network => preset.network;
}

class PeercoinElectrumxNetworks {
  const PeercoinElectrumxNetworks._();

  static final mainnet = PeercoinElectrumxNetwork(
    preset: PeercoinNetworks.mainnet,
    genesisHash:
        '0000000032fe677166d54963b62a4677d8957e87c508eaa4fd7eb1c880cd27e3',
    requiredProtocol: '1.4',
    servers: List<Uri>.unmodifiable([
      Uri.parse('wss://electrum.peercoinexplorer.net:50004'),
      Uri.parse('wss://allingas.peercoinexplorer.net:50004'),
    ]),
  );

  static final testnet = PeercoinElectrumxNetwork(
    preset: PeercoinNetworks.testnet,
    genesisHash:
        '00000001f757bb737f6596503e17cd17b0658ce630cc727c0cca81aec47c9f06',
    requiredProtocol: '1.4',
    servers: List<Uri>.unmodifiable([
      Uri.parse('wss://testnet-electrum.peercoinexplorer.net:50009'),
      Uri.parse('wss://allingas.peercoinexplorer.net:50009'),
    ]),
  );

  static final values = List<PeercoinElectrumxNetwork>.unmodifiable([
    mainnet,
    testnet,
  ]);

  static PeercoinElectrumxNetwork forPreset(PeercoinNetworkPreset preset) {
    for (final network in values) {
      if (network.preset.id == preset.id) return network;
    }
    throw ArgumentError.value(preset.id, 'preset', 'Unknown Peercoin network.');
  }
}

class ElectrumxException implements Exception {
  const ElectrumxException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return 'ElectrumxException: $message';
    }
    return 'ElectrumxException: $message ($cause)';
  }
}

final class const ElectrumxRpcException(
  final int code,
  super.message, {
  final Object? data,
}) extends ElectrumxException;

class PeercoinElectrumxUtxoSnapshot {
  const PeercoinElectrumxUtxoSnapshot({
    required this.address,
    required this.utxos,
    this.history = const [],
  });

  final String address;
  final List<ElectrumxUtxo> utxos;
  final List<ElectrumxTransactionHistoryEntry> history;
}

typedef ElectrumxConnector = Future<ElectrumxConnection> Function(Uri uri);

abstract interface class ElectrumxConnection {
  Stream<dynamic> get stream;

  void send(String message);

  Future<void> close();
}

abstract interface class ElectrumxService {
  Stream<PeercoinElectrumxUtxoSnapshot> watchUtxosForAddresses(
    Iterable<String> addresses,
  );

  Future<List<ElectrumxUtxo>> fetchUtxos(String address);

  Future<String> broadcastTransaction(String rawTransactionHex);

  Future<void> close();
}

class WebSocketElectrumxConnection implements ElectrumxConnection {
  WebSocketElectrumxConnection._(this._channel);

  final WebSocketChannel _channel;

  static Future<WebSocketElectrumxConnection> connect(Uri uri) async {
    AppLogger.info('Connecting to ElectrumX websocket: $uri');
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    AppLogger.info('ElectrumX websocket connected: $uri');
    return WebSocketElectrumxConnection._(channel);
  }

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() => _channel.sink.close();
}

class PeercoinElectrumxService
    with WidgetsBindingObserver
    implements ElectrumxService {
  PeercoinElectrumxService({
    required this.electrumNetwork,
    this.connector = WebSocketElectrumxConnection.connect,
    this.timeout = const Duration(seconds: 12),
    this.reconnectDelay = const Duration(seconds: 5),
    this.keepAliveInterval = const Duration(seconds: 30),
    Uri? preferredServer,
  }) : preferredServer = preferredServer ?? electrumNetwork.servers.first {
    if (!_isSupportedEndpoint(this.preferredServer)) {
      throw ArgumentError.value(
        this.preferredServer,
        'preferredServer',
        'ElectrumX endpoint must use ws:// or wss:// and include a host.',
      );
    }
    WidgetsBinding.instance.addObserver(this);
  }

  final PeercoinElectrumxNetwork electrumNetwork;
  final ElectrumxConnector connector;
  final Duration timeout;
  final Duration reconnectDelay;
  final Duration keepAliveInterval;
  final Uri preferredServer;
  _ElectrumxClient? _persistentClient;
  Future<_ElectrumxClient>? _persistentClientFuture;
  bool _closed = false;

  static const _settingsBoxName = 'sygnature_electrumx_settings';
  static const _backendKeySuffix = 'backend';

  factory PeercoinElectrumxService.forPreset(
    PeercoinNetworkPreset preset, {
    ElectrumxConnector connector = WebSocketElectrumxConnection.connect,
    Duration timeout = const Duration(seconds: 12),
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration keepAliveInterval = const Duration(seconds: 30),
    Uri? preferredServer,
  }) {
    return PeercoinElectrumxService(
      electrumNetwork: PeercoinElectrumxNetworks.forPreset(preset),
      connector: connector,
      timeout: timeout,
      reconnectDelay: reconnectDelay,
      keepAliveInterval: keepAliveInterval,
      preferredServer: preferredServer,
    );
  }

  static Future<PeercoinElectrumxService> createForPreset(
    PeercoinNetworkPreset preset, {
    ElectrumxConnector connector = WebSocketElectrumxConnection.connect,
    Duration timeout = const Duration(seconds: 12),
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration keepAliveInterval = const Duration(seconds: 30),
  }) async {
    return PeercoinElectrumxService.forPreset(
      preset,
      connector: connector,
      timeout: timeout,
      reconnectDelay: reconnectDelay,
      keepAliveInterval: keepAliveInterval,
      preferredServer: await selectedBackend(preset),
    );
  }

  @override
  Future<List<ElectrumxUtxo>> fetchUtxos(String address) {
    return _withClient((client) => client.fetchUtxos(address));
  }

  Future<_ElectrumxClient> _getPersistentClient() async {
    if (_closed) {
      throw const ElectrumxException('ElectrumX service is closed.');
    }
    final current = _persistentClient;
    if (current != null && !current.isClosed) {
      // Refresh must not reuse a socket that only appears connected after sleep.
      await current.checkConnection();
      if (_closed) {
        throw const ElectrumxException('ElectrumX service is closed.');
      }
      if (!current.isClosed) return current;
    }
    final pending = _persistentClientFuture;
    if (pending != null) {
      return pending;
    }
    final future = _connectPersistentClient();
    _persistentClientFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_persistentClientFuture, future)) {
        _persistentClientFuture = null;
      }
    }
  }

  Future<_ElectrumxClient> _connectPersistentClient() async {
    await _persistentClient?.close();
    _persistentClient = null;

    final failures = <String>[];
    for (final server in _orderedServers) {
      if (_closed) {
        throw const ElectrumxException('ElectrumX service is closed.');
      }
      AppLogger.debug('Connecting persistent ElectrumX server=$server');
      final client = _ElectrumxClient(
        server: server,
        electrumNetwork: electrumNetwork,
        connector: connector,
        timeout: timeout,
        keepAliveInterval: keepAliveInterval,
      );
      try {
        await client.connect();
        if (_closed) {
          await client.close();
          throw const ElectrumxException('ElectrumX service is closed.');
        }
        _persistentClient = client;
        return client;
      } catch (error) {
        failures.add('$server: $error');
        await client.close();
      }
    }
    throw ElectrumxException(
      'All ElectrumX servers failed: ${failures.join('; ')}',
    );
  }

  Stream<List<ElectrumxUtxo>> watchUtxos(String address) async* {
    await for (final snapshot in watchUtxosForAddresses([address])) {
      yield snapshot.utxos;
    }
  }

  @override
  Stream<PeercoinElectrumxUtxoSnapshot> watchUtxosForAddresses(
    Iterable<String> addresses,
  ) async* {
    final uniqueAddresses = {
      for (final address in addresses)
        if (address.trim().isNotEmpty) address.trim(),
    }.toList(growable: false);
    if (uniqueAddresses.isEmpty) {
      return;
    }

    while (!_closed) {
      yield* _watchUtxosUntilFailure(uniqueAddresses);
      if (_closed) return;
      if (reconnectDelay > Duration.zero) {
        await Future<void>.delayed(reconnectDelay);
      }
    }
  }

  Stream<PeercoinElectrumxUtxoSnapshot> _watchUtxosUntilFailure(
    List<String> addresses,
  ) => Stream.multi((output) {
    final subscriptions = <StreamSubscription<PeercoinElectrumxUtxoSnapshot>>[];
    Future<void>? stopping;

    Future<void> stop({Object? error, StackTrace? stackTrace}) =>
        stopping ??= Future<void>(() async {
          if (error != null) output.addError(error, stackTrace);
          await Future.wait(subscriptions.map((item) => item.cancel()));
          // Do not wait for the consumer to receive done: its cancellation can
          // itself be waiting for this stop future.
          unawaited(output.close());
        });

    void fail(Object error, StackTrace stackTrace) {
      if (stopping != null) return;
      AppLogger.warn(
        'watchUtxosForAddresses stream failed for '
        '${addresses.length} address(es): $error. Reconnecting...',
        error: error,
        stackTrace: stackTrace,
      );
      unawaited(stop(error: error, stackTrace: stackTrace));
    }

    Future<void> start() async {
      try {
        final client = await _getPersistentClient();
        for (final address in addresses) {
          if (stopping != null) return;
          final statusStream = await client.subscribeScriptHash(
            scriptHashForAddress(address, electrumNetwork.network),
          );
          if (stopping != null) {
            await statusStream.listen(null).cancel();
            return;
          }
          final subscription = statusStream
              .asyncMap((status) async {
                if (status == null) {
                  return PeercoinElectrumxUtxoSnapshot(
                    address: address,
                    utxos: const [],
                    history: const [],
                  );
                }
                return PeercoinElectrumxUtxoSnapshot(
                  address: address,
                  utxos: await client.fetchUtxos(address),
                  history: await client.fetchHistory(address),
                );
              })
              .listen(
                output.add,
                onError: fail,
                onDone: () => _closed
                    ? unawaited(stop())
                    : fail(
                        const ElectrumxException(
                          'ElectrumX status subscription closed.',
                        ),
                        StackTrace.current,
                      ),
              );
          subscriptions.add(subscription);
        }
      } catch (error, stackTrace) {
        fail(error, stackTrace);
      }
    }

    output.onCancel = () => stop();
    unawaited(start());
  });

  @override
  Future<String> broadcastTransaction(String rawTransactionHex) {
    return _withClient(
      (client) => client.broadcastTransaction(rawTransactionHex),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_closed) {
      unawaited(_persistentClient?.checkConnection());
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    final pendingClient = _persistentClientFuture;
    _persistentClientFuture = null;
    final client = _persistentClient;
    _persistentClient = null;
    await client?.close();
    if (pendingClient != null) {
      try {
        final connectedClient = await pendingClient;
        await connectedClient.close();
      } catch (_) {
        // The pending connection already failed; there is nothing to close.
      }
    }
  }

  static Future<Uri> selectedBackend(PeercoinNetworkPreset preset) async {
    final electrumNetwork = PeercoinElectrumxNetworks.forPreset(preset);
    final box = await _openSettingsBox();
    final stored = box.get(_backendKey(preset));
    if (stored is String) {
      final uri = Uri.tryParse(stored);
      if (uri != null && _isSupportedEndpoint(uri)) {
        return uri;
      }
    }
    return electrumNetwork.servers.first;
  }

  static Uri defaultBackend(PeercoinNetworkPreset preset) =>
      PeercoinElectrumxNetworks.forPreset(preset).servers.first;

  static Uri parseEndpoint(String value) {
    final endpoint = Uri.tryParse(value.trim());
    if (endpoint == null || !_isSupportedEndpoint(endpoint)) {
      throw const FormatException(
        'Use a WebSocket endpoint beginning with ws:// or wss://.',
      );
    }
    return endpoint;
  }

  static Future<void> setSelectedBackend(
    PeercoinNetworkPreset preset,
    Uri backend,
  ) async {
    if (!_isSupportedEndpoint(backend)) {
      throw ArgumentError.value(
        backend,
        'backend',
        'ElectrumX endpoint must use ws:// or wss:// and include a host.',
      );
    }

    final box = await _openSettingsBox();
    await box.put(_backendKey(preset), backend.toString());
    await box.flush();
  }

  Future<T> _withClient<T>(
    Future<T> Function(_ElectrumxClient client) action,
  ) async {
    final failures = <String>[];
    Object? lastError;
    Object? rpcError;
    if (_closed) {
      throw const ElectrumxException('ElectrumX service is closed.');
    }
    for (final server in _orderedServers) {
      AppLogger.debug(
        'Trying ElectrumX server=$server network=${electrumNetwork.preset.id}',
      );
      final client = _ElectrumxClient(
        server: server,
        electrumNetwork: electrumNetwork,
        connector: connector,
        timeout: timeout,
        keepAliveInterval: Duration.zero,
      );
      try {
        await client.connect();
        final result = await action(client);
        AppLogger.info('ElectrumX action succeeded via $server');
        return result;
      } catch (error, stackTrace) {
        lastError = error;
        if (error is ElectrumxRpcException) {
          rpcError ??= error;
        }
        AppLogger.warn(
          'ElectrumX action failed via $server',
          error: error,
          stackTrace: stackTrace,
        );
        failures.add('$server: $error');
      } finally {
        await client.close();
      }
    }

    AppLogger.error(
      'All ElectrumX servers failed for network=${electrumNetwork.preset.id}: '
      '${failures.join('; ')}',
    );
    throw ElectrumxException(
      'All ElectrumX servers failed: ${failures.join('; ')}',
      cause: rpcError ?? lastError,
    );
  }

  static String scriptHashForAddress(String address, Network network) {
    final script = Address.fromString(address, network).program.script.compiled;
    final hash = sha256Hash(Uint8List.fromList(script));
    return bytesToHex(Uint8List.fromList(hash.reversed.toList()));
  }

  static Future<Box<dynamic>> _openSettingsBox() {
    return Hive.openBox<dynamic>(_settingsBoxName);
  }

  static String _backendKey(PeercoinNetworkPreset preset) {
    return '${preset.id}:$_backendKeySuffix';
  }

  static bool _isSupportedEndpoint(Uri endpoint) =>
      (endpoint.scheme == 'ws' || endpoint.scheme == 'wss') &&
      endpoint.host.isNotEmpty;

  Iterable<Uri> get _orderedServers sync* {
    yield preferredServer;
    for (final server in electrumNetwork.servers) {
      if (server != preferredServer) yield server;
    }
  }
}

class _ElectrumxClient({
  required final Uri server,
  required final PeercoinElectrumxNetwork electrumNetwork,
  required final ElectrumxConnector connector,
  required final Duration timeout,
  required final Duration keepAliveInterval,
}) {
  ElectrumxConnection? _connection;
  StreamSubscription<dynamic>? _subscription;
  Timer? _keepAliveTimer;
  final Map<int, Completer<Object?>> _pending = {};
  final Map<String, StreamController<String?>> _subscriptions = {};
  int _nextId = 0;
  bool _usable = false;
  bool _closed = false;
  Future<void>? _closing;
  Future<void>? _checkingConnection;

  bool get isClosed => !_usable;

  Future<void> connect() async {
    if (_usable) {
      return;
    }

    final connection = await connector(server)
        .then((connection) {
          if (_closed) {
            unawaited(_closeConnection(connection));
            throw const ElectrumxException('ElectrumX client closed.');
          }
          return connection;
        })
        .timeout(timeout);
    _connection = connection;
    _subscription = connection.stream.listen(
      _handleIncomingMessage,
      onError: (Object error, StackTrace stackTrace) =>
          _handleTransportFailure(error, stackTrace),
      onDone: () => _handleTransportFailure(
        ElectrumxException('Connection closed by $server.'),
        StackTrace.current,
      ),
    );

    final version = await _request('server.version', [
      'sygnature',
      electrumNetwork.requiredProtocol,
    ]);
    if (version is! List ||
        version.length < 2 ||
        version[1] is! String ||
        !_supportsRequiredProtocol(version[1] as String)) {
      throw ElectrumxException(
        'Server $server did not negotiate Electrum protocol '
        '${electrumNetwork.requiredProtocol}.',
      );
    }

    final features = await _request('server.features', const []);
    if (features is! Map ||
        features['genesis_hash'] != electrumNetwork.genesisHash ||
        (features['hash_function'] ?? 'sha256') != 'sha256') {
      throw ElectrumxException(
        'Server $server reported an incompatible network.',
      );
    }
    if (_closed) {
      throw const ElectrumxException('ElectrumX client closed.');
    }
    _usable = true;
    if (keepAliveInterval > Duration.zero) {
      _keepAliveTimer = Timer.periodic(
        keepAliveInterval,
        (_) => unawaited(checkConnection()),
      );
    }
  }

  Future<List<ElectrumxUtxo>> fetchUtxos(String address) async {
    final scriptHash = PeercoinElectrumxService.scriptHashForAddress(
      address,
      electrumNetwork.network,
    );
    final result = await _request('blockchain.scripthash.listunspent', [
      scriptHash,
    ]);
    if (result is! List) {
      throw const FormatException('Invalid ElectrumX listunspent response.');
    }

    return result
        .map((entry) => ElectrumxUtxo.fromJson(address: address, value: entry))
        .toList(growable: false);
  }

  Future<List<ElectrumxTransactionHistoryEntry>> fetchHistory(
    String address,
  ) async {
    final scriptHash = PeercoinElectrumxService.scriptHashForAddress(
      address,
      electrumNetwork.network,
    );
    final result = await _request('blockchain.scripthash.get_history', [
      scriptHash,
    ]);
    if (result is! List) {
      throw const FormatException('Invalid ElectrumX history response.');
    }
    return result
        .map(ElectrumxTransactionHistoryEntry.fromJson)
        .toList(growable: false);
  }

  Future<Stream<String?>> subscribeScriptHash(String scriptHash) async {
    var controller = _subscriptions[scriptHash];
    if (controller != null) {
      return controller.stream;
    }

    controller = StreamController<String?>.broadcast(
      onCancel: () {
        if (identical(_subscriptions[scriptHash], controller)) {
          _subscriptions.remove(scriptHash);
        }
      },
    );
    _subscriptions[scriptHash] = controller;

    try {
      final result = await _request('blockchain.scripthash.subscribe', [
        scriptHash,
      ]);
      if (result != null && result is! String) {
        throw const FormatException(
          'Invalid ElectrumX scripthash subscription response.',
        );
      }
      final initialStatus = result as String?;
      Timer.run(() {
        if (!controller!.isClosed) {
          controller.add(initialStatus);
        }
      });
    } catch (e) {
      _subscriptions.remove(scriptHash);
      controller.close();
      rethrow;
    }

    return controller.stream;
  }

  Future<String> broadcastTransaction(String rawTransactionHex) async {
    final transactionHex = rawTransactionHex.trim();
    if (transactionHex.isEmpty) {
      throw ArgumentError.value(
        rawTransactionHex,
        'rawTransactionHex',
        'Cannot broadcast an empty transaction.',
      );
    }

    final result = await _request('blockchain.transaction.broadcast', [
      transactionHex,
    ]);
    if (result is! String) {
      throw const FormatException('Invalid ElectrumX broadcast response.');
    }
    return result;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _usable = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final connection = _connection;
    _connection = null;
    // Notify listeners before transport cleanup, which may stall while offline.
    _failPending(const ElectrumxException('ElectrumX client closed.'));
    await Future.wait([
      if (subscription != null) _finishCleanup(subscription.cancel),
      if (connection != null) _closeConnection(connection),
    ]);
  }

  Future<void> _closeConnection(ElectrumxConnection connection) =>
      _finishCleanup(connection.close);

  Future<void> _finishCleanup(Future<void> Function() cleanup) async {
    try {
      await cleanup().timeout(timeout);
    } catch (error, stackTrace) {
      AppLogger.warn(
        'ElectrumX cleanup failed for $server; continuing recovery.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<Object?> _request(String method, List<Object?> params) async {
    final connection = _connection;
    if (connection == null) {
      throw const ElectrumxException('ElectrumX client is not connected.');
    }

    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      connection.send(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
    } catch (error, stackTrace) {
      _pending.remove(id);
      _handleTransportFailure(error, stackTrace);
      rethrow;
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        final error = TimeoutException(
          'ElectrumX $method request $id timed out on $server.',
          timeout,
        );
        _handleTransportFailure(error, StackTrace.current);
        throw error;
      },
    );
  }

  void _handleIncomingMessage(dynamic message) {
    try {
      _handleMessage(message);
    } catch (error, stackTrace) {
      _handleTransportFailure(
        ElectrumxException(
          'Invalid response received from $server.',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  void _handleMessage(dynamic message) {
    final decoded = switch (message) {
      String() => jsonDecode(message),
      List<int>() => jsonDecode(utf8.decode(message)),
      _ => throw const FormatException('Invalid ElectrumX message type.'),
    };

    if (decoded is! Map) {
      throw const FormatException('Invalid ElectrumX JSON-RPC response.');
    }

    final method = decoded['method'];
    if (method == 'blockchain.scripthash.subscribe') {
      final params = decoded['params'];
      if (params is List && params.length == 2) {
        final scriptHash = params[0];
        final status = params[1];
        if (scriptHash is! String || (status != null && status is! String)) {
          throw const FormatException(
            'Invalid ElectrumX scripthash notification.',
          );
        }
        final controller = _subscriptions[scriptHash];
        if (controller != null && !controller.isClosed) {
          controller.add(status as String?);
        }
      }
      return;
    }

    final id = decoded['id'];
    if (id is! int) {
      return;
    }

    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }

    final error = decoded['error'];
    if (error != null) {
      if (error is! Map ||
          error['code'] is! int ||
          error['message'] is! String) {
        completer.completeError(
          const FormatException('Invalid ElectrumX JSON-RPC error response.'),
        );
        return;
      }
      completer.completeError(
        ElectrumxRpcException(
          error['code'] as int,
          error['message'] as String,
          data: error['data'],
        ),
      );
      return;
    }

    completer.complete(decoded['result']);
  }

  bool _supportsRequiredProtocol(String negotiated) {
    return negotiated == electrumNetwork.requiredProtocol ||
        negotiated.startsWith('${electrumNetwork.requiredProtocol}.');
  }

  Future<void> checkConnection() =>
      _checkingConnection ??= _sendKeepAlive().whenComplete(() {
        _checkingConnection = null;
      });

  Future<void> _sendKeepAlive() async {
    if (!_usable) return;
    try {
      await _request('server.ping', const []);
    } catch (error, stackTrace) {
      if (!_usable) return;
      _handleTransportFailure(
        ElectrumxException(
          'ElectrumX keepalive failed for $server.',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  void _handleTransportFailure(Object error, StackTrace stackTrace) {
    if (_closed) return;
    _usable = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _failPending(error, stackTrace);
    unawaited(close());
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
    _pending.clear();
    for (final controller in _subscriptions.values) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
        controller.close();
      }
    }
    _subscriptions.clear();
  }
}
