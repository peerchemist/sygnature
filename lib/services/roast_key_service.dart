import 'package:coinlib/coinlib.dart'
    show
        Address,
        Output,
        P2TR,
        P2TRAddress,
        bytesToHex,
        generateRandomBytes,
        hexToBytes;
import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../models/roast_setup.dart';
import '../models/wallet_network.dart';
import 'peercoin_network_service.dart';

class RoastParticipantMaterial({
  required final String cardId,
  required final String privateKeyHex,
  required final String publicKeyHex,
});

class RoastDerivedAddress({
  required final List<int> path,
  required final String pathLabel,
  required final String address,
  required final String internalKeyHex,
});

class RoastKeyService {
  const RoastKeyService();

  RoastParticipantMaterial generateParticipant() {
    final key = ECPrivateKey.generate();
    return RoastParticipantMaterial(
      cardId: bytesToHex(generateRandomBytes(16)),
      privateKeyHex: bytesToHex(key.data),
      publicKeyHex: ECCompressedPublicKey.fromPubkey(key.pubkey).hex,
    );
  }

  String newSetupId() => bytesToHex(generateRandomBytes(16));

  List<RoastParticipant> finalizeRoster(
    RoastSetup setup,
    List<String> encodedCards,
  ) {
    final cards = <({String cardId, String name, String publicKeyHex})>[
      (
        cardId: setup.localCardId,
        name: setup.participants.single.name,
        publicKeyHex: setup.participants.single.publicKeyHex,
      ),
      for (final encoded in encodedCards)
        RoastExchangeCodec.decodeParticipantCard(encoded),
    ];
    if (cards.length != setup.participantCount) {
      throw ArgumentError(
        'Expected ${setup.participantCount} participant cards.',
      );
    }
    if (cards.map((item) => item.cardId).toSet().length != cards.length ||
        cards.map((item) => item.publicKeyHex).toSet().length != cards.length) {
      throw ArgumentError('Participant cards must be unique.');
    }
    for (final card in cards) {
      ECCompressedPublicKey.fromHex(card.publicKeyHex);
    }
    return [
      for (var i = 0; i < cards.length; i++)
        RoastParticipant(
          cardId: cards[i].cardId,
          name: cards[i].name.trim(),
          identifierHex: Identifier.fromUint16(i + 1).toString(),
          publicKeyHex: cards[i].publicKeyHex,
        ),
    ];
  }

  String groupFingerprint(RoastSetup setup) => bytesToHex(
    GroupConfig(
      id: setup.groupId,
      participants: {
        for (final participant in setup.participants)
          Identifier.fromHex(participant.identifierHex):
              ECCompressedPublicKey.fromHex(participant.publicKeyHex),
      },
    ).fingerprint,
  );

  RoastSetup applyInvitation(RoastSetup draft, String encodedInvitation) {
    final json = RoastExchangeCodec.decodeInvitation(encodedInvitation);
    final participants = (json['participants']! as List)
        .map((item) => RoastParticipant.fromJson(item as Map))
        .toList(growable: false);
    final local = participants.where(
      (item) => item.publicKeyHex == draft.localParticipant.publicKeyHex,
    );
    if (local.length != 1) {
      throw const FormatException(
        'This invitation does not contain your participant card.',
      );
    }
    final threshold = json['threshold']! as int;
    final participantCount = json['participantCount']! as int;
    if (threshold < 2 ||
        threshold > participantCount ||
        participants.length != participantCount) {
      throw const FormatException('The invitation has an invalid policy.');
    }
    final invited = RoastSetup(
      id: draft.id,
      groupId: json['groupId']! as String,
      name: json['setupName']! as String,
      role: RoastSetupRole.member,
      status: RoastSetupStatus.ready,
      threshold: threshold,
      participantCount: participantCount,
      blockchainId: json['blockchainId']! as String,
      networkId: json['networkId']! as String,
      localCardId: local.single.cardId,
      localParticipantPrivateKeyHex: draft.localParticipantPrivateKeyHex,
      participants: participants,
      onlineParticipantIds: const [],
      keyName: json['keyName']! as String,
      createdAt: draft.createdAt,
      coordinatorId: json['coordinatorId']! as String,
      coordinatorRelayUrls: (json['coordinatorRelayUrls']! as List)
          .cast<String>(),
      coordinatorIpAddrs: (json['coordinatorIpAddrs']! as List).cast<String>(),
      groupFingerprintHex: json['groupFingerprintHex'] as String?,
    );
    final actualFingerprint = groupFingerprint(invited);
    if (invited.groupFingerprintHex != actualFingerprint) {
      throw const FormatException('The invitation fingerprint is invalid.');
    }
    return invited;
  }

  RoastDerivedAddress deriveAddress({
    required String groupKeyHex,
    required int threshold,
    required WalletNetwork network,
    required int accountIndex,
  }) {
    final networkIndex = network.networkId == 'mainnet' ? 0 : 1;
    final path = [0, 6, networkIndex, accountIndex, 0, 0];
    var info = HDGroupKeyInfo.master(
      groupKey: ECCompressedPublicKey.fromHex(groupKeyHex),
      threshold: threshold,
    );
    for (final index in path) {
      info = info.derive(index);
    }
    final preset = PeercoinNetworks.fromWalletNetwork(network);
    final address = P2TRAddress.fromTaproot(
      Taproot(internalKey: info.groupKey),
      hrp: preset.network.bech32Hrp,
    ).toString();
    return RoastDerivedAddress(
      path: path,
      pathLabel: 'R/${path.join('/')}',
      address: address,
      internalKeyHex: info.groupKey.hex,
    );
  }

  String scriptHexForAddress(WalletNetwork network, String address) {
    final preset = PeercoinNetworks.fromWalletNetwork(network);
    return bytesToHex(
      Address.fromString(address, preset.network).program.script.compiled,
    );
  }

  String addressForScript(WalletNetwork network, String scriptHex) {
    final preset = PeercoinNetworks.fromWalletNetwork(network);
    final program = Output.fromScriptBytes(
      BigInt.zero,
      hexToBytes(scriptHex),
    ).program;
    if (program is! P2TR) return 'Unsupported output script';
    return P2TRAddress.fromTweakedKeyX(
      program.data,
      hrp: preset.network.bech32Hrp,
    ).toString();
  }
}
