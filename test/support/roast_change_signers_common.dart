import 'dart:convert';
import 'dart:typed_data';

import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

const oldSetupId = 'change-signers-old';
const successorSetupId = 'change-signers-successor';
const oldGroupId = 'change-signers-old-group';
const successorGroupId = 'change-signers-successor-group';
const oldKeyName = 'change-signers-old-key';
const successorKeyName = 'change-signers-successor-key';

const oldMessageWithAndroid14 = 'old 2-of-3: linux + android 14';
const oldMessageWithAndroid16 = 'old 2-of-3: linux + android 16';
const successorMessageWithAndroid14 =
    'successor 2-of-3: replacement + android 14';
const successorMessageWithLinux = 'successor 2-of-3: replacement + linux';

List<ECPrivateKey> get identityKeys => [
  for (var value = 1; value <= 4; value++)
    ECPrivateKey(Uint8List(32)..last = value),
];

List<Identifier> get oldIds => [
  for (var value = 1; value <= 3; value++) Identifier.fromUint16(value),
];

List<Identifier> get successorIds => [
  for (var value = 1; value <= 3; value++) Identifier.fromUint16(value),
];

GroupConfig get oldGroup => GroupConfig(
  id: oldGroupId,
  participants: {
    for (var index = 0; index < 3; index++)
      oldIds[index]: ECCompressedPublicKey.fromPubkey(
        identityKeys[index].pubkey,
      ),
  },
);

GroupConfig get successorGroup => GroupConfig(
  id: successorGroupId,
  participants: {
    successorIds[0]: ECCompressedPublicKey.fromPubkey(identityKeys[0].pubkey),
    successorIds[1]: ECCompressedPublicKey.fromPubkey(identityKeys[1].pubkey),
    successorIds[2]: ECCompressedPublicKey.fromPubkey(identityKeys[3].pubkey),
  },
);

ClientNodeOptions clientOptions({
  required GroupConfig group,
  required Identifier identifier,
  required int identity,
  required EndpointAddr coordinator,
  required ClientStorageInterface storage,
}) => ClientNodeOptions(
  clientConfig: ClientConfig(group: group, id: identifier),
  bootstrapAddress: coordinator,
  pinnedServerId: coordinator.id,
  storage: storage,
  getPrivateKey: (_) async => identityKeys[identity - 1],
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

String encodeBytes(Uint8List bytes) => base64UrlEncode(bytes);

Uint8List decodeBytes(String value) => base64Url.decode(value);

Future<ClientStorageInterface> openStorage(
  RoastPersistenceFactory persistence,
  String setupId,
) async => (await persistence.open()).clientStorage(setupId);
