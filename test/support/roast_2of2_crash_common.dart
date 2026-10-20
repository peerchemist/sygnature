import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:iroh_quic/iroh_quic.dart';
import 'package:noosphere_client/noosphere_client.dart';

const crashGroupId = 'sygnature-android-2of2-crash-e2e';
const crashSetupId = 'android-2of2-crash-signer';
const crashKeyName = 'android-2of2-crash-key';
const crashMessage = 'Sygnature Android 2-of-2 DKG crash recovery E2E';

List<Identifier> get crashIds => [
  Identifier.fromUint16(1),
  Identifier.fromUint16(2),
];

List<ECPrivateKey> get crashIdentityKeys => [
  ECPrivateKey(Uint8List(32)..last = 1),
  ECPrivateKey(Uint8List(32)..last = 2),
];

GroupConfig get crashGroup {
  final ids = crashIds;
  final keys = crashIdentityKeys;
  return GroupConfig(
    id: crashGroupId,
    participants: {
      for (var index = 0; index < ids.length; index++)
        ids[index]: ECCompressedPublicKey.fromPubkey(keys[index].pubkey),
    },
  );
}

String encodeCrashEndpoint(EndpointAddr address) =>
    base64UrlEncode(address.encode());

EndpointAddr decodeCrashEndpoint(String value) =>
    EndpointAddr.decode(base64Url.decode(value));
