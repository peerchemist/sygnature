import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as cl;
import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/models/wallet_backup.dart';
import 'package:sygnature_ng/services/backup_cbor.dart';

import 'fixtures/wallet_backup_fixture.dart';

void main() {
  setUpAll(NoosphereFlutter.initializeNative);

  test('stable independent empty document vector', () {
    final backup = WalletBackupV1(createdAt: 0, wallet: null, groups: []);
    expect(
      cl.bytesToHex(backup.encode()),
      'a46667726f757073806777616c6c657473806a637265617465645f6174006e736368656d615f76657273696f6e01',
    );
    expect(WalletBackupV1.decode(backup.encode()).wallet, isNull);
  });
  test(
    'maps are definite and deterministic independently of insertion order',
    () {
      expect(
        BackupCbor.encode({
          'zzz': 1,
          'a': Uint8List.fromList([0, 255]),
          'bb': <Object?>[true, null],
        }),
        BackupCbor.encode({
          'bb': <Object?>[true, null],
          'a': Uint8List.fromList([0, 255]),
          'zzz': 1,
        }),
      );
      expect(
        cl.bytesToHex(BackupCbor.encode({'b': 1, 'a': 2})),
        'a2616102616201',
      );
      final large = List<Object?>.filled(300, 1);
      expect(BackupCbor.encode(large).first, 0x99);
      expect(BackupCbor.decode(BackupCbor.encode(large)), large);
    },
  );
  test('RFC integer and byte string vectors', () {
    expect(
      cl.bytesToHex(
        BackupCbor.encode([0, 23, 24, 255, 256, 65536, 4294967296]),
      ),
      '870017181818ff1901001a000100001b0000000100000000',
    );
    expect(
      cl.bytesToHex(BackupCbor.encode(Uint8List.fromList([0, 255]))),
      '4200ff',
    );
  });
  for (final vector in [
    'a2616101616102',
    'a2616201616102',
    '1817',
    '9f01ff',
    'c001',
    'f90000',
    'a10102',
    '6161ff',
    '61ff',
    'a16161',
    '1bffffffffffffffff',
    '01ff',
    '5affffffff',
    '9a7fffffff',
    'f818',
    '38ff',
  ]) {
    test(
      'reject malformed, duplicate, tagged or noncanonical CBOR $vector',
      () {
        expect(
          () => BackupCbor.decode(cl.hexToBytes(vector)),
          throwsFormatException,
        );
      },
    );
  }
  test('nesting and collection allocation are bounded', () {
    expect(
      () =>
          BackupCbor.decode(Uint8List.fromList([...List.filled(26, 0x81), 0])),
      throwsFormatException,
    );
    expect(
      () => BackupCbor.decode(cl.hexToBytes('992711')),
      throwsFormatException,
    );
  });
  test('schema/type/unknown field validation', () {
    final fields = WalletBackupV1(
      createdAt: 0,
      wallet: null,
      groups: [],
    ).toCbor();
    for (final change in [
      <String, Object?>{'schema_version': 2},
      {'created_at': '0'},
      {'extra': null},
      {'wallets': true},
    ]) {
      expect(
        () => WalletBackupV1.decode(BackupCbor.encode({...fields, ...change})),
        throwsFormatException,
      );
    }
  });
  test('complete signing recovery bytes survive canonical round trip', () {
    final f = WalletBackupFixture(roomHost: true);
    final backup = f.backup;
    backup.validate();
    final restored = WalletBackupV1.decode(backup.encode());
    final key = restored.groups.single.keys.single.toKey();
    expect(key.keyInfo.toBytes(), f.keys.first.keyInfo.toBytes());
    expect(
      key.acks.map((a) => a.toBytes()),
      f.keys.first.acks.map((a) => a.toBytes()),
    );
    expect(restored.wallet!.mnemonic!.phrase, f.vault.mnemonic);
    expect(
      restored.groups.single.setup.localParticipantPrivateKeyHex,
      f.setup.localParticipantPrivateKeyHex,
    );
    expect(restored.groups.single.room!.toCbor(), f.room!.toCbor());
    expect(restored.groups.single.setup.requiresBackupReconciliation, isTrue);
    expect(restored.groups.single.setup.pendingDkgProposalHex, isNull);
    expect(restored.toVault()!.activities, isEmpty);
  });
  test('equivalent unordered public metadata has identical encoding', () {
    final f = WalletBackupFixture();
    final a = f.backup;
    final g = a.groups.single;
    final b = WalletBackupV1(
      createdAt: 0,
      wallet: a.wallet,
      groups: [
        BackupGroup(
          setup: g.setup.copyWith(
            participants: g.setup.participants.reversed.toList(),
          ),
          keys: g.keys,
          room: null,
        ),
      ],
    );
    expect(a.encode(), b.encode());
  });
  test('ROAST account key ID is a textual key name, not public key bytes', () {
    final f = WalletBackupFixture();
    final backup = f.backup;
    final account = backup.wallet!.accounts.singleWhere(
      (a) => a.account.sourceId == f.setup.id,
    );
    expect(account.toCbor()['key_id'], 'synthetic-key');
    final restored = WalletBackupV1.decode(backup.encode());
    final roast = restored.toVault()!.accounts.singleWhere(
      (a) => a.sourceId == f.setup.id,
    );
    expect(roast.keyId, f.setup.keyName);
    expect(roast.address, account.account.address);
    expect(roast.derivationPath, account.account.derivationPath);

    for (final invalid in ['missing-key', f.setup.groupKeyHex, Uint8List(33)]) {
      final map = backup.toCbor();
      final wallet = (map['wallets'] as List).single as Map<String, Object?>;
      final roast = (wallet['accounts'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((a) => a['source_id'] == f.setup.id);
      roast['key_id'] = invalid;
      expect(
        () => WalletBackupV1.decode(BackupCbor.encode(map)),
        throwsFormatException,
      );
    }
  });
  test('multiple groups and locally held keys are preserved, not merged', () {
    final first = WalletBackupFixture();
    final second = WalletBackupFixture(
      groupSecret: 7,
      setupId: 'setup-2',
      groupId: 'group-2',
    );
    final group2 = second.backup.groups.single;
    final group1 = BackupGroup(
      setup: first.setup,
      keys: [
        ...first.backup.groups.single.keys,
        ...second.backup.groups.single.keys,
      ],
      room: null,
    );
    final backup = WalletBackupV1(
      createdAt: 0,
      wallet: first.backup.wallet,
      groups: [group2, group1],
    );
    final restored = WalletBackupV1.decode(backup.encode());
    expect(restored.groups, hasLength(2));
    expect(restored.groups.first.keys, hasLength(2));
    expect(
      restored.groups.first.keys
          .map((k) => cl.bytesToHex(k.secretShare))
          .toSet(),
      {
        cl.bytesToHex(syntheticPrivateKey(3).data),
        cl.bytesToHex(syntheticPrivateKey(9).data),
      },
    );
    expect(
      restored.groups.first.keys
          .map((k) => cl.bytesToHex(k.participantId))
          .toSet(),
      hasLength(1),
    ); // Two keys still represent one local participant.
    expect(restored.groups.first.setup.participantCount, 2);
  });
  test('reject secret share mismatch and duplicate participant copy', () {
    final f = WalletBackupFixture();
    final map = f.backup.toCbor();
    final group = (map['groups'] as List).single as Map<String, Object?>;
    final key = (group['keys'] as List).single as Map<String, Object?>;
    key['secret_share'] = syntheticPrivateKey(4).data;
    expect(
      () => WalletBackupV1.decode(BackupCbor.encode(map)),
      throwsFormatException,
    );
    group['keys'] = [key, key];
    expect(
      () => WalletBackupV1.decode(BackupCbor.encode(map)),
      throwsFormatException,
    );
  });
  test('restored signing shares produce a valid Taproot signature using fresh nonces', () {
    final f = WalletBackupFixture();
    final restored = WalletBackupV1.decode(f.backup.encode())
        .groups
        .single
        .keys
        .single
        .toKey();
    final keys = [restored, f.keys.last];
    final rounds = keys
        .map((k) => SignPart1(privateShare: k.keyInfo.private.share))
        .toList();
    final commitments = SigningCommitmentSet({
      for (var i = 0; i < 2; i++)
        keys[i].keyInfo.private.identifier: rounds[i].commitment,
    });
    final details = SignDetails.keySpend(message: Uint8List(32));
    final shares = [
      for (var i = 0; i < 2; i++)
        (
          keys[i].keyInfo.private.identifier,
          SignPart2(
            identifier: keys[i].keyInfo.private.identifier,
            details: details,
            ourNonces: rounds[i].nonces,
            commitments: commitments,
            info: keys[i].keyInfo.signing,
          ).share,
        ),
    ];
    final signature = SignatureAggregation(
      commitments: commitments,
      details: details,
      shares: shares,
      info: restored.keyInfo.aggregate,
    ).signature;
    final outputKey = cl.Taproot(internalKey: restored.groupKey).tweakedKey;
    expect(signature.verify(outputKey, details.message), isTrue);
    expect(
      SignPart1(privateShare: restored.keyInfo.private.share).nonces.toBytes(),
      isNot(rounds.first.nonces.toBytes()),
    );
  });
}
