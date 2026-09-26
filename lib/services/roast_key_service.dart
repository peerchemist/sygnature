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

class RoastInvitation({
  required final RoastSetup setup,
  required final String roomInvite,
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
    final canonicalCards = [
      for (final card in cards)
        (
          cardId: card.cardId,
          name: card.name,
          publicKeyHex: ECCompressedPublicKey.fromHex(card.publicKeyHex).hex,
        ),
    ]..sort((a, b) => a.publicKeyHex.compareTo(b.publicKeyHex));
    final participants = [
      for (var i = 0; i < canonicalCards.length; i++)
        RoastParticipant(
          cardId: canonicalCards[i].cardId,
          name: canonicalCards[i].name.trim(),
          identifierHex: Identifier.fromUint16(i + 1).toString(),
          publicKeyHex: canonicalCards[i].publicKeyHex,
        ),
    ];
    validateRoster(
      participants: participants,
      participantCount: setup.participantCount,
      threshold: setup.threshold,
      hostParticipantId: participants
          .singleWhere((participant) => participant.cardId == setup.localCardId)
          .identifierHex,
    );
    return participants;
  }

  void validateRoster({
    required List<RoastParticipant> participants,
    required int participantCount,
    required int threshold,
    required String hostParticipantId,
  }) {
    if (threshold < 2 ||
        threshold > participantCount ||
        participants.length != participantCount) {
      throw const FormatException('The ROAST roster has an invalid policy.');
    }
    if (participants.any(
      (participant) =>
          participant.cardId.trim().isEmpty ||
          participant.name.trim().isEmpty ||
          participant.identifierHex.trim().isEmpty,
    )) {
      throw const FormatException('The ROAST roster is incomplete.');
    }
    if (participants.map((item) => item.cardId).toSet().length !=
            participants.length ||
        participants.map((item) => item.identifierHex).toSet().length !=
            participants.length ||
        participants.map((item) => item.publicKeyHex).toSet().length !=
            participants.length) {
      throw const FormatException(
        'ROAST participant identifiers and keys must be unique.',
      );
    }
    for (final participant in participants) {
      Identifier.fromHex(participant.identifierHex);
      ECCompressedPublicKey.fromHex(participant.publicKeyHex);
    }
    if (!participants.any(
      (participant) => participant.identifierHex == hostParticipantId,
    )) {
      throw const FormatException('The ROAST host is not in the roster.');
    }
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

  RoastInvitation applyInvitation(RoastSetup draft, String encodedInvitation) {
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
    final hostParticipantId = json['hostParticipantId']! as String;
    final expiry = DateTime.parse(json['expiresAt']! as String);
    if (!expiry.isAfter(DateTime.now())) {
      throw const FormatException('The ROAST invitation has expired.');
    }
    validateRoster(
      participants: participants,
      participantCount: participantCount,
      threshold: threshold,
      hostParticipantId: hostParticipantId,
    );
    if (json['participantPublicKeyHex'] !=
        draft.localParticipant.publicKeyHex) {
      throw const FormatException(
        'This room invitation is bound to another participant key.',
      );
    }
    final roomInvite = json['roomInvite'];
    if (roomInvite is! String || roomInvite.trim().isEmpty) {
      throw const FormatException('The room invitation is missing.');
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
      usesRoomEnrollment: true,
      hostParticipantId: hostParticipantId,
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
    return RoastInvitation(setup: invited, roomInvite: roomInvite);
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
