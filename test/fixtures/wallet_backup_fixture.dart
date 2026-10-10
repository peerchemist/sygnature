import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart' as bip39;
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_backup.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';

/// Public, synthetic test data. Polynomial f(x)=1+2x, identifiers 1 and 2.
cl.ECPrivateKey syntheticPrivateKey(int value) =>
    cl.ECPrivateKey.fromHex(value.toRadixString(16).padLeft(64, '0'));
cl.ECCompressedPublicKey syntheticPublicKey(int value) =>
    cl.ECCompressedPublicKey.fromPubkey(syntheticPrivateKey(value).pubkey);

final class WalletBackupFixture {
  WalletBackupFixture({
    bool roomHost = false,
    int groupSecret = 1,
    String setupId = 'setup-1',
    String groupId = 'synthetic-group',
  }) : _groupSecret = groupSecret {
    final phrase = bip39.Mnemonic(
      Uint8List(16),
      bip39.Language.english,
    ).sentence;
    final seed = CoinlibWalletKeyService.mnemonicToSeed(phrase);
    final identity = deriveIrohSecretKeyFromBip39Seed(seed, index: 7);
    seed.fillRange(0, seed.length, 0);
    final participants = [
      for (var i = 1; i <= 2; i++)
        RoastParticipant(
          cardId: 'card-$i',
          name: 'Signer $i',
          identifierHex: Identifier.fromUint16(i).toString(),
          publicKeyHex: syntheticPublicKey(i + 8).hex,
        ),
    ];
    setup = RoastSetup(
      id: setupId,
      groupId: groupId,
      name: 'Synthetic group',
      role: roomHost ? RoastSetupRole.host : RoastSetupRole.member,
      status: RoastSetupStatus.active,
      threshold: 2,
      participantCount: 2,
      blockchainId: 'peercoin',
      networkId: 'testnet',
      localCardId: 'card-1',
      localParticipantPrivateKeyHex: cl.bytesToHex(syntheticPrivateKey(9).data),
      participants: participants,
      keyName: 'synthetic-key',
      createdAt: DateTime.utc(2026),
      irohIdentityIndex: 7,
      usesRoomEnrollment: roomHost,
      hostParticipantId: participants.first.identifierHex,
      coordinatorId: identity.publicKey.toZ32(),
      coordinatorRelayUrls: const ['https://relay.example.test'],
      groupKeyHex: syntheticPublicKey(groupSecret).hex,
    );
    setup = setup.copyWith(
      groupFingerprintHex: const RoastKeyService().groupFingerprint(setup),
    );
    keys = [for (var i = 1; i <= 2; i++) _key(i)];
    final personal = CoinlibWalletKeyService().deriveAccount(
      network: PeercoinNetworks.testnet,
      mnemonic: phrase,
      language: MnemonicLanguage.english,
      accountIndex: 0,
    );
    final address = const RoastKeyService().deriveAddress(
      groupKeyHex: setup.groupKeyHex!,
      threshold: 2,
      network: PeercoinNetworks.testnet,
      accountIndex: 0,
    );
    vault = WalletVault(
      mnemonic: phrase,
      languageId: 'english',
      mnemonicWordCount: 12,
      nextAccountIndex: 1,
      roastSetups: [setup],
      accounts: [
        WalletAccount(
          id: 'personal',
          name: 'Personal',
          accountIndex: 0,
          blockchainId: 'peercoin',
          networkId: 'testnet',
          derivationState: WalletDerivationState.ready,
          createdAt: DateTime.utc(2026),
          derivationPath: personal.derivationPath,
          address: personal.address,
          privateKeyHex: personal.privateKeyHex,
        ),
        WalletAccount(
          id: 'roast',
          name: 'ROAST',
          accountIndex: 0,
          blockchainId: 'peercoin',
          networkId: 'testnet',
          derivationState: WalletDerivationState.ready,
          keySource: WalletKeySource.roast,
          sourceId: setup.id,
          keyId: setup.keyName,
          createdAt: DateTime.utc(2026),
          derivationPath: address.pathLabel,
          address: address.address,
        ),
      ],
    );
    room = roomHost
        ? BackupRoom(identity.publicKey.asBytes(), [
            for (var i = 1; i <= 2; i++)
              (
                Identifier.fromUint16(i).toBytes(),
                DateTime.utc(2026).millisecondsSinceEpoch,
              ),
          ])
        : null;
  }
  late RoastSetup setup;
  late WalletVault vault;
  late List<FrostKeyWithDetails> keys;
  late BackupRoom? room;
  final int _groupSecret;

  FrostKeyWithDetails _key(int participant) {
    var key = FrostKeyWithDetails(
      keyInfo: ParticipantKeyInfo(
        group: GroupKeyInfo(
          groupKey: syntheticPublicKey(_groupSecret),
          threshold: 2,
        ),
        publicShares: PublicSharesKeyInfo(
          publicShares: [
            (Identifier.fromUint16(1), syntheticPublicKey(_groupSecret + 2)),
            (Identifier.fromUint16(2), syntheticPublicKey(_groupSecret + 4)),
          ],
        ),
        private: PrivateKeyInfo(
          identifier: Identifier.fromUint16(participant),
          share: syntheticPrivateKey(_groupSecret + participant * 2),
        ),
      ),
      name: setup.keyName,
      description: roastKeyDescription(setup),
    );
    for (var i = 1; i <= 2; i++) {
      key = key.addOrReplaceAck(
        SignedDkgAck(
          signer: Identifier.fromUint16(i),
          signed: Signed.sign(
            obj: DkgAck(groupKey: key.groupKey, accepted: true),
            key: syntheticPrivateKey(i + 8),
          ),
        ),
      );
    }
    return key;
  }

  WalletBackupV1 get backup => WalletBackupV1(
    createdAt: 0,
    wallet: BackupWallet.fromVault(vault),
    groups: [
      BackupGroup(
        setup: setup,
        keys: [BackupSigningKey.fromKey(keys.first)],
        room: room,
      ),
    ],
  );
}
