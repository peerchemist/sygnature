// Manual cross-device harness. Uses public, deterministic test keys only.
// Never use these identities with funds.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as cl;
import 'package:iroh_quic/iroh_quic.dart';
import 'package:noosphere_client/iroh_transport.dart';
import 'package:noosphere_client/noosphere_client.dart';
import 'package:noosphere_client/testing.dart';
import 'package:noosphere_server/noosphere_server.dart';
import 'package:noosphere_server/testing.dart';

const _groupId = 'android-real-world-2-of-3';
const _dkgName = 'android-real-world-key';
const _message = 'Sygnature Android background recovery E2E';

Future<T> _waitFor<T>(
  T? Function() read, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('Timed out waiting for test state.', timeout);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run <script> <device-config.json>');
    exitCode = 64;
    return;
  }
  await cl.loadCoinlib();
  await loadFrosty();
  await Iroh.init();

  final keys = [
    for (var value = 1; value <= 3; value++)
      cl.ECPrivateKey(Uint8List(32)..last = value),
  ];
  final ids = [
    for (var value = 1; value <= 3; value++) Identifier.fromUint16(value),
  ];
  final group = GroupConfig(
    id: _groupId,
    participants: {
      for (var i = 0; i < ids.length; i++)
        ids[i]: cl.ECCompressedPublicKey.fromPubkey(keys[i].pubkey),
    },
  );
  final feedId = PublicFeedId.generate();
  final serverConfig = ServerConfig(
    group: group,
    publicFeed: PublicFeedConfig(feedId: feedId),
  );
  final persistence = InMemoryServerPersistence();
  final handler = ServerApiHandler(
    config: serverConfig,
    persistence: persistence,
  );
  final server = await IrohServer.start(
    IrohConfig(server: serverConfig),
    secretKey: SecretKey.generate(),
    handler: handler,
    persistence: persistence,
  );
  unawaited(server.serve());
  final address = await server.endpoint
      .watchAddr()
      .firstWhere(
        (candidate) =>
            candidate.relayUrls.isNotEmpty || candidate.ipAddrs.isNotEmpty,
      )
      .timeout(const Duration(seconds: 30));

  final stores = [InMemoryClientStorage(), InMemoryClientStorage()];
  final desktops = <ReconnectingIrohClient>[];
  StreamSubscription<ClientEvent>? resultEvents;
  try {
    for (var i = 0; i < 2; i++) {
      desktops.add(
        await ReconnectingIrohClient.connect(
          clientConfig: ClientConfig(group: group, id: ids[i]),
          transportConfig: IrohClientTransportConfig(
            bootstrapAddress: address,
            pinnedServerId: address.id,
          ),
          store: stores[i],
          getPrivateKey: (_) async => keys[i],
        ),
      );
    }

    await File(arguments.single).writeAsString(
      jsonEncode({
        'address': base64UrlEncode(address.encode()),
        'pin': address.id.toZ32(),
        'feedId': feedId.hex,
      }),
      flush: true,
    );
    await Process.run('chmod', ['600', arguments.single]);

    resultEvents = desktops.first.current.events.listen((event) {
      if (event is! SignaturesCompleteClientEvent) return;
      final signed = event.toSignedMessage();
      stdout.writeln(
        signed.text == _message && signed.verify()
            ? 'SIGNATURE VERIFIED: true'
            : 'SIGNATURE VERIFIED: false',
      );
    });

    stdout.writeln(
      'Coordinator and two desktop clients ready. Commands: dkg, sign, status, quit.',
    );
    await for (final command
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (command == 'quit') break;
      if (command == 'dkg') {
        await desktops.first.current.requestDkg(
          NewDkgDetails(
            name: _dkgName,
            description: 'Synthetic Android 2-of-3 recovery test',
            threshold: 2,
            expiry: Expiry(const Duration(hours: 2)),
            groupFingerprint: group.fingerprint,
          ),
        );
        final proposal = await _waitFor<DkgInProgress>(() {
          final requests = desktops[1].current.dkgRequests;
          return requests
              .where((item) => item.details.name == _dkgName)
              .firstOrNull;
        });
        await desktops[1].current.acceptDkg(
          proposal.details.name,
          proposal.details.ceremonyId,
        );
        stdout.writeln('DKG requested; desktop participant 2 accepted.');
      } else if (command == 'sign') {
        final key = await _waitFor<FrostKeyWithDetails>(
          () => desktops.first.current.keys.values.firstOrNull,
        );
        await desktops.first.current.requestSignatures(
          SignaturesRequestDetails.forMessage(
            text: _message,
            groupKey: key.groupKey,
            expiry: Expiry(const Duration(hours: 1)),
          ),
        );
        stdout.writeln('Message signing request committed.');
      } else if (command == 'status') {
        stdout.writeln(
          'Desktop keys: ${desktops.map((client) => client.current.keys.length).join(', ')}; '
          'pending signatures: ${desktops.first.current.signaturesRequests.length}.',
        );
      }
    }
  } finally {
    await resultEvents?.cancel();
    for (final client in desktops.reversed) {
      await client.close();
    }
    await server.close();
  }
}
