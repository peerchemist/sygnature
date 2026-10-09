import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:iroh_flutter/iroh_flutter.dart' show Iroh;
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';

void main() {
  setUpAll(() async {
    await loadCoinlib();
    await Iroh.init();
  });

  test('reads schema 1 vaults without changing personal account data', () {
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
      'roastSetups': const [],
      'activities': const [],
    });

    expect(vault.roastSetups, isEmpty);
    expect(vault.accounts.single.name, 'Main wallet');
    expect(vault.accounts.single.privateKeyHex, 'secret');
    expect(vault.accounts.single.derivationState, WalletDerivationState.ready);
    expect(vault.toJson()['schemaVersion'], WalletVault.schemaVersion);
  });

  test('participant cards and clickable room invites round trip', () {
    const groupId = 'abcdef0123456789abcdef0123456789';
    final service = _InvitationTestRoastKeyService();
    final memberKey = ECPrivateKey.generate();
    final memberPublicKey = ECCompressedPublicKey.fromPubkey(memberKey.pubkey);
    final hostPublicKey = ECCompressedPublicKey.fromPubkey(
      ECPrivateKey.generate().pubkey,
    );
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
      roomId: groupId,
      inviteId: 'invite-1',
      token: Uint8List(32),
      expectedParticipantPublicKey: memberPublicKey,
      coordinatorEndpointId: coordinator.asBytes(),
      expiresAt: expiresAt,
    );
    final draft = RoastSetup(
      id: 'local-setup',
      groupId: 'local-draft',
      name: 'Family',
      role: RoastSetupRole.member,
      status: RoastSetupStatus.draft,
      threshold: 2,
      participantCount: 2,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      localCardId: 'card-b',
      localParticipantPrivateKeyHex: bytesToHex(memberKey.data),
      participants: [
        RoastParticipant(
          cardId: 'card-b',
          name: 'Computer B',
          identifierHex: '',
          publicKeyHex: memberPublicKey.hex,
        ),
      ],
      keyName: 'local-draft-g1',
      createdAt: DateTime.utc(2026),
      usesRoomEnrollment: true,
    );

    final encodedInvitation = NoosphereRoomInvite(
      prefix: sygnatureRoomInvitePrefix,
      invite: roomInvite,
    ).encode();
    const prefix = sygnatureRoomInvitePrefix;
    expect(encodedInvitation, startsWith(prefix));
    expect(
      () => NoosphereRoomInvite.decode(
        encodedInvitation.substring(prefix.length),
        prefix: prefix,
      ),
      throwsFormatException,
    );
    final invitation = NoosphereRoomInvite.decode(
      encodedInvitation,
      prefix: prefix,
    );
    expect(invitation.invite.toBytes(), roomInvite.toBytes());
    service.validateRoomInvite(draft, invitation);

    final wrongKey = ECPrivateKey.generate();
    final wrongKeyDraft = RoastSetup(
      id: draft.id,
      groupId: draft.groupId,
      name: draft.name,
      role: draft.role,
      status: draft.status,
      threshold: draft.threshold,
      participantCount: draft.participantCount,
      blockchainId: draft.blockchainId,
      networkId: draft.networkId,
      localCardId: draft.localCardId,
      localParticipantPrivateKeyHex: bytesToHex(wrongKey.data),
      participants: draft.participants,
      keyName: draft.keyName,
      createdAt: draft.createdAt,
      usesRoomEnrollment: true,
    );
    expect(
      () => service.validateRoomInvite(wrongKeyDraft, invitation),
      throwsArgumentError,
    );

    final setup = service.applyRoomEnrollment(
      draft,
      invitation.invite,
      _roomSnapshot(
        roomId: groupId,
        coordinatorEndpointId: coordinator.asBytes(),
        hostPublicKey: hostPublicKey,
        memberPublicKey: memberPublicKey,
      ),
    );
    expect(setup.coordinatorId, coordinator.toZ32());
    expect(setup.coordinatorIpAddrs, isEmpty);
    expect(setup.coordinatorRelayUrls, isEmpty);
    expect(setup.keyName, '$groupId-g1');
    expect(() => PublicKey.fromZ32(setup.coordinatorId!), returnsNormally);
  });

  test('issued invitation state round trips with its local progress', () {
    final invitation = RoastIssuedInvitation(
      participantName: 'Computer B',
      participantPublicKeyHex: '02${'11' * 32}',
      encoded: 'secret-invitation',
      issuedAt: DateTime.utc(2026, 1),
      expiresAt: DateTime.utc(2026, 2),
      copiedAt: DateTime.utc(2026, 1, 2),
      sentAt: DateTime.utc(2026, 1, 3),
      joinedAt: DateTime.utc(2026, 1, 4),
      serverStatus: RoastInvitationServerStatus.used,
    );

    final restored = RoastIssuedInvitation.fromJson(invitation.toJson());

    expect(restored.participantName, invitation.participantName);
    expect(
      restored.participantPublicKeyHex,
      invitation.participantPublicKeyHex,
    );
    expect(restored.encoded, invitation.encoded);
    expect(restored.issuedAt, invitation.issuedAt);
    expect(restored.expiresAt, invitation.expiresAt);
    expect(restored.copiedAt, invitation.copiedAt);
    expect(restored.sentAt, invitation.sentAt);
    expect(restored.joinedAt, invitation.joinedAt);
    expect(restored.serverStatus, RoastInvitationServerStatus.used);
    expect(
      restored.statusAt(DateTime.utc(2026, 3)),
      RoastInvitationDisplayStatus.joined,
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

  test('reads schema 1 ROAST setups with the host first in the roster', () {
    const groupId = 'abcdef0123456789abcdef0123456789';
    final setup = <String, Object?>{
      'id': 'setup',
      'groupId': groupId,
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
      'keyName': '$groupId:generation:1',
      'createdAt': '2026-01-01T00:00:00.000Z',
    };
    final vault = WalletVault.fromJson({
      'schemaVersion': 1,
      'accounts': <Object?>[],
      'nextAccountIndex': 0,
      'roastSetups': [setup],
      'activities': const [],
    });

    expect(vault.roastSetups.single.hostParticipantId, '01');
    expect(vault.roastSetups.single.keyName, '$groupId-g1');
    expect(
      vault.roastSetups.single.irohIdentityIndex,
      irohIdentityIndexForSetup('setup'),
    );
    expect(vault.toJson()['schemaVersion'], WalletVault.schemaVersion);
    final restored = WalletVault.fromJson(vault.toJson()).roastSetups.single;
    expect(restored.id, 'setup');
    expect(
      restored.irohIdentityIndex,
      vault.roastSetups.single.irohIdentityIndex,
    );
    expect(
      irohIdentityIndexForSetup('another-setup'),
      isNot(restored.irohIdentityIndex),
    );
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

RoomSnapshot _roomSnapshot({
  required String roomId,
  required Uint8List coordinatorEndpointId,
  required ECCompressedPublicKey hostPublicKey,
  required ECCompressedPublicKey memberPublicKey,
}) {
  final now = DateTime.now().toUtc();
  RoomInviteSnapshot invite(String id, ECCompressedPublicKey publicKey) =>
      RoomInviteSnapshot(
        inviteId: id,
        expectedParticipantPublicKey: publicKey,
        tokenHash: Uint8List(32),
        issuedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
        usedAt: null,
        revokedAt: null,
        status: RoomInviteStatus.pending,
      );
  return RoomSnapshot(
    roomId: roomId,
    lifecycle: RoomLifecycle.enrolling,
    expectedParticipants: 2,
    threshold: 2,
    coordinatorEndpointId: coordinatorEndpointId,
    invites: [invite('host', hostPublicKey), invite('member', memberPublicKey)],
    participants: [
      RoomParticipantSnapshot(
        publicKey: hostPublicKey,
        enrolledAt: now,
        identifier: null,
      ),
    ],
    groupConfig: null,
  );
}
