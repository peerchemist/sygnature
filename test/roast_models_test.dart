import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:iroh_flutter/iroh_flutter.dart' show Iroh;
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';

void main() {
  setUpAll(() async {
    await loadCoinlib();
    await Iroh.init();
  });

  test('migrates schema 1 vaults without changing personal account data', () {
    final vault = WalletVault.fromJson({
      'schemaVersion': 1,
      'mnemonic': 'test phrase',
      'languageId': 'english',
      'mnemonicWordCount': 12,
      'accounts': [
        {
          'id': 'peercoin-mainnet-0',
          'name': 'Main wallet',
          'accountIndex': 0,
          'blockchainId': 'peercoin',
          'networkId': 'mainnet',
          'derivationPath': "m/86'/6'/0'/0/0",
          'address': 'pc1ptest',
          'privateKeyHex': 'secret',
          'createdAt': '2026-01-01T00:00:00.000Z',
        },
      ],
      'nextAccountIndex': 1,
    });

    expect(vault.roastSetups, isEmpty);
    expect(vault.accounts.single.name, 'Main wallet');
    expect(vault.accounts.single.privateKeyHex, 'secret');
    expect(vault.toJson()['schemaVersion'], WalletVault.schemaVersion);
  });

  test('participant cards and legacy invitations round trip', () {
    final service = _InvitationTestRoastKeyService();
    final memberKey = ECPrivateKey.generate();
    final memberPublicKey = ECCompressedPublicKey.fromPubkey(memberKey.pubkey);
    final card = RoastExchangeCodec.encodeParticipantCard(
      cardId: 'card-b',
      name: 'Computer B',
      publicKeyHex: memberPublicKey.hex,
    );
    expect(RoastExchangeCodec.decodeParticipantCard(card).name, 'Computer B');

    final coordinator = PublicKey.fromHex(
      'ae58ff8833241ac82d6ff7611046ed67b5072d142c588d0063e942d9a75502b6',
    );
    final expiresAt = DateTime.now().toUtc().add(const Duration(days: 1));
    final roomInvite = RoomInvite(
      roomId: 'group-1',
      inviteId: 'invite-1',
      token: Uint8List(32),
      expectedParticipantPublicKey: memberPublicKey,
      coordinatorEndpointId: coordinator.asBytes(),
      ipAddrs: const ['192.168.1.251:40660'],
      expiresAt: expiresAt,
    );
    final setup = RoastSetup(
      id: 'local-setup',
      groupId: 'group-1',
      name: 'Family',
      role: RoastSetupRole.member,
      status: RoastSetupStatus.ready,
      threshold: 2,
      participantCount: 2,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      localCardId: 'card-b',
      localParticipantPrivateKeyHex: bytesToHex(memberKey.data),
      participants: [
        RoastParticipant(
          cardId: 'card-a',
          name: 'Computer A',
          identifierHex: '01',
          publicKeyHex: ECCompressedPublicKey.fromPubkey(
            ECPrivateKey.generate().pubkey,
          ).hex,
        ),
        RoastParticipant(
          cardId: 'card-b',
          name: 'Computer B',
          identifierHex: '02',
          publicKeyHex: memberPublicKey.hex,
        ),
      ],
      onlineParticipantIds: const [],
      keyName: 'family:generation:1',
      createdAt: DateTime.utc(2026),
      usesRoomEnrollment: true,
      hostParticipantId: '01',
      coordinatorId: coordinator.toString(),
      coordinatorIpAddrs: roomInvite.ipAddrs,
      groupFingerprintHex: 'fingerprint',
    );

    final encodedInvitation = RoastExchangeCodec.encodeInvitation(
      setup,
      roomInvite: roomInvite.encode(),
      participantPublicKeyHex: memberPublicKey.hex,
      expiresAt: expiresAt,
    );
    final invitation = RoastExchangeCodec.decodeInvitation(encodedInvitation);
    expect(invitation['setupName'], 'Family');
    expect(invitation['threshold'], 2);
    expect(invitation['participants'], hasLength(2));
    expect(invitation['roomInvite'], roomInvite.encode());
    expect(invitation['participantPublicKeyHex'], memberPublicKey.hex);
    expect(invitation['coordinatorId'], startsWith('PublicKey('));

    final decoded = service.applyInvitation(setup, encodedInvitation);

    expect(decoded.setup.coordinatorId, coordinator.toZ32());
    expect(decoded.setup.coordinatorIpAddrs, roomInvite.ipAddrs);
    expect(
      () => PublicKey.fromZ32(decoded.setup.coordinatorId!),
      returnsNormally,
    );
  });

  test('builds participant cards from signer public keys, not addresses', () {
    const publicKey =
        '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    final service = const RoastKeyService();
    final card = RoastExchangeCodec.decodeParticipantCard(
      service.participantCardFromPublicKey(
        name: 'Alice laptop',
        publicKeyHex: publicKey.toUpperCase(),
      ),
    );

    expect(card.name, 'Alice laptop');
    expect(card.publicKeyHex, publicKey);
    expect(card.cardId, isNotEmpty);
    expect(
      () => service.participantCardFromPublicKey(
        name: 'Alice laptop',
        publicKeyHex: 'pc1pnot-a-signer-public-key',
      ),
      throwsFormatException,
    );
  });

  test('migrates schema 2 ROAST setups with the host first in the roster', () {
    final setup = <String, Object?>{
      'id': 'setup',
      'groupId': 'group',
      'name': 'Family',
      'role': 'member',
      'status': 'ready',
      'threshold': 2,
      'participantCount': 2,
      'blockchainId': 'peercoin',
      'networkId': 'mainnet',
      'localCardId': 'member-card',
      'localParticipantPrivateKeyHex': 'private',
      'participants': [
        {
          'cardId': 'host-card',
          'name': 'Host',
          'identifierHex': '01',
          'publicKeyHex': '02${'22' * 32}',
        },
        {
          'cardId': 'member-card',
          'name': 'Member',
          'identifierHex': '02',
          'publicKeyHex': '03${'33' * 32}',
        },
      ],
      'onlineParticipantIds': <String>[],
      'keyName': 'setup:generation:1',
      'createdAt': '2026-01-01T00:00:00.000Z',
    };
    final vault = WalletVault.fromJson({
      'schemaVersion': 2,
      'accounts': <Object?>[],
      'nextAccountIndex': 0,
      'roastSetups': [setup],
    });

    expect(vault.roastSetups.single.hostParticipantId, '01');
    expect(vault.toJson()['schemaVersion'], WalletVault.schemaVersion);
  });

  test('rejects unsupported exchange payloads', () {
    expect(
      () => RoastExchangeCodec.decodeParticipantCard('not-an-invitation'),
      throwsFormatException,
    );
  });

  test('rejects duplicate participant authentication keys', () {
    expect(
      () => const RoastKeyService().validateRoster(
        participants: [
          RoastParticipant(
            cardId: 'a',
            name: 'A',
            identifierHex: '01',
            publicKeyHex: '02${'11' * 32}',
          ),
          RoastParticipant(
            cardId: 'b',
            name: 'B',
            identifierHex: '02',
            publicKeyHex: '02${'11' * 32}',
          ),
        ],
        participantCount: 2,
        threshold: 2,
        hostParticipantId: '01',
      ),
      throwsFormatException,
    );
  });
}

final class _InvitationTestRoastKeyService() extends RoastKeyService {
  @override
  void validateRoster({
    required List<RoastParticipant> participants,
    required int participantCount,
    required int threshold,
    required String hostParticipantId,
  }) {}

  @override
  String groupFingerprint(RoastSetup setup) => 'fingerprint';
}
