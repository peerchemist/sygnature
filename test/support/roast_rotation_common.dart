import 'dart:convert';
import 'dart:typed_data';

import 'package:noosphere_flutter/noosphere_flutter.dart';

const rotationGroupId = 'sygnature-cross-platform-rotation-e2e';
const rotationKeyName = 'sygnature-rotation-e2e-key';
const rotationSetupId = 'rotation-signer';
const rotationMessage = 'Sygnature 2-of-3 coordinator rotation E2E';

List<Identifier> get rotationIds => [
  for (var value = 1; value <= 3; value++) Identifier.fromUint16(value),
];

List<ECPrivateKey> get rotationKeys => [
  for (var value = 1; value <= 3; value++)
    ECPrivateKey(Uint8List(32)..last = value),
];

GroupConfig get rotationGroup {
  final ids = rotationIds;
  final keys = rotationKeys;
  return GroupConfig(
    id: rotationGroupId,
    participants: {
      for (var index = 0; index < ids.length; index++)
        ids[index]: ECCompressedPublicKey.fromPubkey(keys[index].pubkey),
    },
  );
}

ClientNodeOptions rotationClientOptions({
  required int participant,
  required EndpointAddr coordinator,
  required ClientStorageInterface storage,
}) => ClientNodeOptions(
  clientConfig: ClientConfig(
    group: rotationGroup,
    id: rotationIds[participant - 1],
  ),
  bootstrapAddress: coordinator,
  pinnedServerId: coordinator.id,
  storage: storage,
  getPrivateKey: (_) async => rotationKeys[participant - 1],
  reconnect: const IrohReconnectConfig(
    initialDelay: Duration(milliseconds: 100),
    maxDelay: Duration(seconds: 1),
    jitter: 0,
  ),
);

EndpointAddr endpointFromWorker(WorkerCoordinatorAddress address) =>
    EndpointAddr(
      PublicKey.fromZ32(address.id),
      relayUrls: [for (final value in address.relayUrls) RelayUrl.parse(value)],
      ipAddrs: address.ipAddrs,
    );

String encodeEndpoint(EndpointAddr address) =>
    base64UrlEncode(address.encode());

EndpointAddr decodeEndpoint(String value) =>
    EndpointAddr.decode(base64Url.decode(value));
