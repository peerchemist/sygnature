// Linux coordinator/requester for the Android process-death DKG harness.
// It uses deterministic public test identities and must never hold funds.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:iroh_quic/iroh_quic.dart';
import 'package:noosphere_client/iroh_transport.dart';
import 'package:noosphere_client/noosphere_client.dart';
import 'package:noosphere_client/testing.dart';
import 'package:noosphere_server/noosphere_server.dart';
import 'package:noosphere_server/testing.dart';

import 'roast_2of2_crash_common.dart';

Future<T> _waitFor<T>(
  T? Function() read, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('Timed out waiting for test state.', timeout);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run <script> <device-config.json>');
    exitCode = 64;
    return;
  }
  await coinlib.loadCoinlib();
  await loadFrosty();
  await Iroh.init();

  final group = crashGroup;
  final config = ServerConfig(group: group);
  final serverPersistence = InMemoryServerPersistence();
  final handler = ServerApiHandler(
    config: config,
    persistence: serverPersistence,
  );
  final server = await IrohServer.start(
    IrohConfig(server: config),
    secretKey: SecretKey.generate(),
    handler: handler,
    persistence: serverPersistence,
  );
  unawaited(server.serve());
  final address = await server.endpoint
      .watchAddr()
      .firstWhere(
        (candidate) =>
            candidate.relayUrls.isNotEmpty || candidate.ipAddrs.isNotEmpty,
      )
      .timeout(const Duration(seconds: 30));

  final store = InMemoryClientStorage();
  final secrets = <String, Uint8List>{};
  ReconnectingIrohClient? client;
  StreamSubscription<ClientEvent>? events;

  Future<void> connect() async {
    final runtime = await ReconnectingIrohClient.connect(
      clientConfig: ClientConfig(group: group, id: crashIds.first),
      transportConfig: IrohClientTransportConfig(
        bootstrapAddress: address,
        pinnedServerId: address.id,
      ),
      store: store,
      getPrivateKey: (_) async => crashIdentityKeys.first,
      persistDkgSecret: (name, state) async {
        secrets[name] = Uint8List.fromList(state);
      },
      reconnectConfig: const IrohReconnectConfig(
        initialDelay: Duration(milliseconds: 100),
        maxDelay: Duration(seconds: 1),
        jitter: 0,
      ),
    );
    client = runtime;
    events = runtime.current.events.listen((event) {
      if (event is CompletedDkgClientEvent) {
        stdout.writeln('LINUX KEY READY');
      } else if (event is SignaturesCompleteClientEvent) {
        final signed = event.toSignedMessage();
        stdout.writeln(
          'SIGNATURE VERIFIED: '
          '${signed.text == crashMessage && signed.verify()}',
        );
      }
    });
    for (final secret in secrets.values) {
      await runtime.current.importDkgSecret(secret);
    }
  }

  await connect();
  await File(arguments.single).writeAsString(
    jsonEncode({'coordinator': encodeCrashEndpoint(address)}),
    flush: true,
  );
  await Process.run('chmod', ['600', arguments.single]);
  stdout.writeln(
    'LINUX READY; commands: dkg-offline, reconnect, sign, status, quit',
  );

  try {
    await for (final command
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      try {
        if (command == 'dkg-offline') {
          final runtime = client ?? (throw StateError('Linux is offline.'));
          await runtime.current.requestDkg(
            NewDkgDetails(
              name: crashKeyName,
              description: 'Android 2-of-2 process-death recovery test',
              threshold: 2,
              expiry: Expiry(const Duration(hours: 1)),
              groupFingerprint: group.fingerprint,
            ),
          );
          await events?.cancel();
          events = null;
          await runtime.close();
          client = null;
          stdout.writeln('DKG REQUESTED; LINUX SIGNER OFFLINE');
        } else if (command == 'reconnect') {
          if (client != null) throw StateError('Linux is already connected.');
          await connect();
          stdout.writeln('LINUX SIGNER RECONNECTED');
        } else if (command == 'sign') {
          final runtime = client ?? (throw StateError('Linux is offline.'));
          final key = await _waitFor<FrostKeyWithDetails>(
            () => runtime.current.keys.values.firstOrNull,
          );
          await runtime.current.requestSignatures(
            SignaturesRequestDetails.forMessage(
              text: crashMessage,
              groupKey: key.groupKey,
              expiry: Expiry(const Duration(minutes: 5)),
            ),
          );
          stdout.writeln('SIGNING REQUESTED');
        } else if (command == 'status') {
          final runtime = client;
          if (runtime == null) {
            stdout.writeln('LINUX STATUS offline secrets=${secrets.length}');
          } else {
            final current = runtime.current;
            stdout.writeln(
              'LINUX STATUS keys=${current.keys.length} '
              'dkgs=${current.acceptedDkgs.length} '
              'peers=${current.onlineParticipants.length}',
            );
          }
        } else if (command == 'quit') {
          break;
        }
      } catch (error, stackTrace) {
        stderr.writeln('LINUX ERROR: $error');
        stderr.writeln(stackTrace);
      }
    }
  } finally {
    await events?.cancel();
    await client?.close();
    await server.close();
    for (final secret in secrets.values) {
      secret.fillRange(0, secret.length, 0);
    }
  }
}
