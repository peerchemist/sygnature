import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';

void main() {
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

  test('participant cards and finalized invitations round trip', () {
    final card = RoastExchangeCodec.encodeParticipantCard(
      cardId: 'card-b',
      name: 'Computer B',
      publicKeyHex: '02${'11' * 32}',
    );
    expect(RoastExchangeCodec.decodeParticipantCard(card).name, 'Computer B');

    final setup = RoastSetup(
      id: 'local-setup',
      groupId: 'group-1',
      name: 'Family',
      role: RoastSetupRole.host,
      status: RoastSetupStatus.ready,
      threshold: 2,
      participantCount: 2,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      localCardId: 'card-a',
      localParticipantPrivateKeyHex: 'private',
      participants: [
        RoastParticipant(
          cardId: 'card-a',
          name: 'Computer A',
          identifierHex: '01',
          publicKeyHex: '02${'22' * 32}',
        ),
        RoastParticipant(
          cardId: 'card-b',
          name: 'Computer B',
          identifierHex: '02',
          publicKeyHex: '03${'33' * 32}',
        ),
      ],
      onlineParticipantIds: const [],
      keyName: 'family:generation:1',
      createdAt: DateTime.utc(2026),
      coordinatorId: 'coordinator-id',
      groupFingerprintHex: 'fingerprint',
    );

    final invitation = RoastExchangeCodec.decodeInvitation(
      RoastExchangeCodec.encodeInvitation(setup),
    );
    expect(invitation['setupName'], 'Family');
    expect(invitation['threshold'], 2);
    expect(invitation['participants'], hasLength(2));
  });

  test('rejects unsupported exchange payloads', () {
    expect(
      () => RoastExchangeCodec.decodeParticipantCard('not-an-invitation'),
      throwsFormatException,
    );
  });
}
