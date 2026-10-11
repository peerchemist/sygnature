// Synthetic coordinator for Android device verification. No wallet data is used.
// Writes a trusted share to the requested local file; never prints capabilities.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coinlib/coinlib.dart' as cl;
import 'package:iroh_quic/iroh_quic.dart';
import 'package:noosphere_server/noosphere_server.dart';
import 'package:noosphere_server/testing.dart';

Future<void> main(List<String> arguments) async {
  await cl.loadCoinlib();
  await loadFrosty(); // Synthetic test coordinator only, never the worker.
  await Iroh.init();
  final key = cl.ECPrivateKey.fromHex('00' * 31 + '09');
  final id = Identifier.fromUint16(1);
  final feedId = PublicFeedId.generate();
  final config = ServerConfig(
    group: GroupConfig(
      id: 'android-device-verification',
      participants: {
        id: cl.ECCompressedPublicKey.fromPubkey(key.pubkey),
        Identifier.fromUint16(2): cl.ECCompressedPublicKey.fromPubkey(
          cl.ECPrivateKey.fromHex('00' * 31 + '0a').pubkey,
        ),
      },
    ),
    publicFeed: PublicFeedConfig(feedId: feedId),
  );
  final handler = ServerApiHandler(
    config: config,
    persistence: InMemoryServerPersistence(),
  );
  final server = await IrohServer.start(
    IrohConfig(server: config),
    secretKey: SecretKey.generate(),
    handler: handler,
    persistence: handler.persistence,
  );
  unawaited(server.serve());
  final challenge = await handler.login(
    groupFingerprint: config.group.fingerprint,
    participantId: id,
  );
  final session = await handler.respondToChallenge(
    Signed.sign(obj: challenge.challenge, key: key),
  );
  unawaited(session.events.drain<void>());
  await server.endpoint
      .watchAddr()
      .firstWhere((address) => address.relayUrls.isNotEmpty)
      .timeout(const Duration(seconds: 30));
  await File(arguments.single).writeAsString(
    jsonEncode({
      'address': base64UrlEncode(server.address.encode()),
      'pin': server.id.toZ32(),
      'feedId': feedId.hex,
    }),
    flush: true,
  );
  await Process.run('chmod', ['600', arguments.single]);
  stdout.writeln(
    'Coordinator ready; type event to create a public DKG request.',
  );
  var sequence = 0;
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'quit') break;
    if (command != 'event') continue;
    await handler.requestNewDkg(
      sid: session.id,
      signedDetails: Signed.sign(
        obj: NewDkgDetails(
          description: 'Synthetic Android worker verification',
          name: 'device-check-${sequence++}',
          threshold: 2,
          expiry: Expiry(const Duration(hours: 1)),
        ),
        key: key,
      ),
      commitment: DkgPart1(identifier: id, threshold: 2, n: 2).public,
    );
    stdout.writeln('Public request committed.');
  }
  await server.close();
}
