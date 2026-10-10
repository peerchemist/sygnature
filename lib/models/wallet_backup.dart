import 'dart:typed_data';
import 'dart:convert';

import 'package:bip39_mnemonic/bip39_mnemonic.dart' as bip39;
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../services/backup_cbor.dart';
import '../services/peercoin_network_service.dart';
import '../services/roast_key_service.dart';
import '../services/wallet_key_service.dart';
import 'mnemonic_seed.dart';
import 'group_transition.dart';
import 'roast_setup.dart';
import 'wallet_account.dart';
import 'wallet_vault.dart';

/// Explicit recovery DTOs. These never call Hive/domain JSON serializers.
final class WalletBackupV1({
  required final int createdAt,
  required final BackupWallet? wallet,
  required final List<BackupGroup> groups,
}) {
  Map<String, Object?> toCbor() => {
    'schema_version': 1,
    'created_at': createdAt,
    'wallets': [if (wallet != null) wallet!.toCbor()],
    'groups':
        (groups.toList()..sort((a, b) => _compareText(a.setup.id, b.setup.id)))
            .map((g) => g.toCbor())
            .toList(),
  };

  Uint8List encode() => BackupCbor.encode(toCbor());

  /// Only owned mutable buffers are cleared. Dart/GC, immutable strings, domain
  /// objects and isolate transfer copies cannot be guaranteed erased.
  void clearSecrets() {
    final entropy = wallet?.mnemonic?.entropy;
    entropy?.fillRange(0, entropy.length, 0);
    for (final g in groups) {
      for (final key in g.keys) {
        key.secretShare.fillRange(0, key.secretShare.length, 0);
      }
    }
  }

  factory WalletBackupV1.decode(Uint8List bytes) {
    final r = BackupRecord(BackupCbor.decode(bytes), {
      'schema_version',
      'created_at',
      'wallets',
      'groups',
    });
    if (r.integer('schema_version', max: 1) != 1) {
      backupInvalid('Unsupported payload schema.');
    }
    final wallets = r.list('wallets');
    if (wallets.length > 1) {
      backupInvalid('This application supports one mnemonic vault.');
    }
    final result = WalletBackupV1(
      createdAt: r.integer('created_at', max: 8640000000000),
      wallet: wallets.isEmpty ? null : BackupWallet.fromCbor(wallets.single),
      groups: r.list('groups').map(BackupGroup.fromCbor).toList(),
    );
    result.validate();
    if (!cl.bytesEqual(bytes, result.encode())) {
      backupInvalid('Noncanonical backup collection ordering.');
    }
    return result;
  }

  void validate() {
    if (createdAt < 0 || createdAt > 8640000000000) {
      backupInvalid('Invalid creation time.');
    }
    final w = wallet;
    if (w == null && groups.isNotEmpty) {
      backupInvalid('Groups require a wallet.');
    }
    w?.validate();
    _unique(groups.map((g) => g.setup.id));
    _unique(groups.map((g) => g.setup.groupId));
    for (final group in groups) {
      group.validate(hasMnemonic: w?.mnemonic != null);
      if (group.setup.role == RoastSetupRole.host) {
        final seed = CoinlibWalletKeyService.mnemonicToSeed(
          w!.mnemonic!.phrase,
          language: MnemonicLanguage.byId(w.mnemonic!.language),
        );
        try {
          final identity = deriveIrohSecretKeyFromBip39Seed(
            seed,
            index: group.setup.irohIdentityIndex,
          );
          if (identity.publicKey.toZ32() != group.setup.coordinatorId ||
              (group.room != null &&
                  !cl.bytesEqual(
                    identity.publicKey.asBytes(),
                    group.room!.coordinatorEndpointId,
                  ))) {
            backupInvalid(
              'Coordinator identity does not match the current mnemonic derivation scheme.',
            );
          }
        } finally {
          seed.fillRange(0, seed.length, 0);
        }
      }
    }
    for (final dto in w?.transitions ?? <BackupTransition>[]) {
      final t = dto.transition;
      final source = groups
          .where((g) => g.setup.id == t.sourceSetupId)
          .singleOrNull;
      final successor = groups
          .where((g) => g.setup.id == t.successorSetupId)
          .singleOrNull;
      if (source == null ||
          successor == null ||
          t.proposal.sourceGroup.id != source.setup.groupId ||
          t.proposal.successorRoomId != successor.setup.groupId ||
          !cl.bytesEqual(
            t.proposal.sourceGroupFingerprint,
            source.group.fingerprint,
          )) {
        backupInvalid(
          'Transition references missing or inconsistent recovery groups.',
        );
      }
      BackupTransition.fromCbor(dto.toCbor());
    }
    for (final account in w?.accounts ?? <BackupAccount>[]) {
      final a = account.account;
      if (a.keySource != WalletKeySource.roast) continue;
      final g = groups.where((g) => g.setup.id == a.sourceId).singleOrNull;
      final key = g?.keys
          .where(
            (k) =>
                k.name == a.keyId &&
                k.description == roastKeyDescription(g.setup),
          )
          .singleOrNull;
      if (g == null ||
          g.setup.blockchainId != a.blockchainId ||
          g.setup.networkId != a.networkId ||
          a.keyId != g.setup.keyName ||
          key == null ||
          cl.bytesToHex(key.groupPublicKey) != g.setup.groupKeyHex) {
        backupInvalid('ROAST account references missing signing material.');
      }
      if (a.address != null) {
        final derived = const RoastKeyService().deriveAddress(
          groupKeyHex: g.setup.groupKeyHex!,
          accountIndex: a.accountIndex,
          threshold: g.setup.threshold,
          pathLabel: a.derivationPath,
          network: PeercoinNetworks.byId(a.networkId),
        );
        if (derived.address != a.address ||
            derived.pathLabel != a.derivationPath) {
          backupInvalid('ROAST account derivation metadata mismatch.');
        }
      }
    }
  }

  WalletVault? toVault({String? restoreId}) => wallet?.toVault(
    groups.map((g) => g.setup).toList(),
    restoreId: restoreId,
  );
}

final class BackupMnemonic(final Uint8List entropy, final String language) {
  factory BackupMnemonic.fromVault(WalletVault vault) {
    final phrase = vault.mnemonic!;
    final language = MnemonicLanguage.byId(vault.languageId!);
    final parsed = bip39.Mnemonic.fromWords(
      words: phrase.split(RegExp(r'\s+')),
      language: language.bip39Language,
    );
    if (parsed.words.length != vault.mnemonicWordCount) {
      backupInvalid('Stored mnemonic word count mismatch.');
    }
    return BackupMnemonic(Uint8List.fromList(parsed.entropy), language.id);
  }
  factory BackupMnemonic.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'type',
      'entropy',
      'language',
      'passphrase',
    });
    if (r.string('type') != 'bip39' ||
        r.string('passphrase', empty: true) != '') {
      backupInvalid('Unsupported mnemonic type or BIP-39 passphrase.');
    }
    final entropy = r.bytes('entropy');
    if (entropy.length != 16 && entropy.length != 32) {
      backupInvalid('Unsupported mnemonic entropy length.');
    }
    return BackupMnemonic(entropy, r.string('language'));
  }
  Map<String, Object?> toCbor() => {
    'type': 'bip39',
    'entropy': entropy,
    'language': language,
    'passphrase': '',
  };
  String get phrase {
    if (entropy.length != 16 && entropy.length != 32) {
      backupInvalid('Invalid mnemonic entropy.');
    }
    final l = MnemonicLanguage.byId(language);
    final reconstructed = bip39.Mnemonic(entropy, l.bip39Language);
    final checked = bip39.Mnemonic.fromWords(
      words: reconstructed.words,
      language: l.bip39Language,
    );
    if (!cl.bytesEqual(Uint8List.fromList(checked.entropy), entropy)) {
      backupInvalid('Mnemonic reconstruction failed.');
    }
    return reconstructed.words.join(' ');
  }
}

final class BackupWallet(
  final BackupMnemonic? mnemonic,
  final int nextAccountIndex,
  final List<BackupAccount> accounts, {
  final List<BackupTransition> transitions = const [],
}) {
  factory BackupWallet.fromVault(WalletVault vault) {
    return BackupWallet(
      vault.mnemonic == null ? null : BackupMnemonic.fromVault(vault),
      vault.nextAccountIndex,
      vault.accounts.map(BackupAccount.new).toList(),
      transitions: vault.groupTransitions.map(BackupTransition.new).toList(),
    );
  }
  factory BackupWallet.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'wallet_id',
      'mnemonic',
      'next_account_index',
      'accounts',
      'transitions',
    });
    if (r.string('wallet_id') != 'local') {
      backupInvalid('Unsupported wallet identifier.');
    }
    return BackupWallet(
      r.data['mnemonic'] == null
          ? null
          : BackupMnemonic.fromCbor(r.data['mnemonic']),
      r.integer('next_account_index', max: 0x80000000),
      r.list('accounts').map(BackupAccount.fromCbor).toList(),
      transitions: r
          .list('transitions')
          .map(BackupTransition.fromCbor)
          .toList(),
    );
  }
  Map<String, Object?> toCbor() => {
    'wallet_id': 'local',
    'mnemonic': mnemonic?.toCbor(),
    'next_account_index': nextAccountIndex,
    'accounts':
        (accounts.toList()
              ..sort((a, b) => _compareText(a.account.id, b.account.id)))
            .map((a) => a.toCbor())
            .toList(),
    'transitions':
        (transitions.toList()..sort(
              (a, b) => _compareText(
                a.transition.transitionId,
                b.transition.transitionId,
              ),
            ))
            .map((t) => t.toCbor())
            .toList(),
  };
  void validate() {
    final phrase = mnemonic?.phrase;
    _unique(accounts.map((a) => a.account.id));
    _unique(transitions.map((t) => t.transition.transitionId));
    if (nextAccountIndex < 0 || nextAccountIndex > 0x80000000) {
      backupInvalid('Invalid next account index.');
    }
    for (final dto in accounts) {
      final a = dto.account;
      if (a.accountIndex < 0 || a.accountIndex >= 0x80000000) {
        backupInvalid('Invalid account index.');
      }
      final network = PeercoinNetworks.byId(a.networkId);
      if (a.blockchainId != network.blockchainId) {
        backupInvalid('Unsupported blockchain.');
      }
      if (a.privateKeyHex != null) cl.ECPrivateKey.fromHex(a.privateKeyHex!);
      if (a.address != null) {
        const RoastKeyService().scriptHexForAddress(network, a.address!);
      }
      if (a.keySource == WalletKeySource.personal) {
        if (phrase == null || a.accountIndex >= nextAccountIndex) {
          backupInvalid('Personal account recovery metadata is incomplete.');
        }
        final derived = CoinlibWalletKeyService().deriveAccount(
          network: network,
          mnemonic: phrase,
          language: MnemonicLanguage.byId(mnemonic!.language),
          accountIndex: a.accountIndex,
        );
        if (a.address != derived.address ||
            a.derivationPath != derived.derivationPath ||
            a.privateKeyHex != derived.privateKeyHex) {
          backupInvalid('Personal account does not match mnemonic derivation.');
        }
      } else if (a.privateKeyHex != null) {
        backupInvalid('Unexpected private key in nonpersonal account.');
      }
    }
  }

  WalletVault toVault(List<RoastSetup> groups, {String? restoreId}) =>
      WalletVault(
        mnemonic: mnemonic?.phrase,
        languageId: mnemonic?.language,
        mnemonicWordCount: mnemonic == null
            ? null
            : (mnemonic!.entropy.length == 16 ? 12 : 24),
        accounts: accounts.map((a) => a.account).toList(),
        nextAccountIndex: nextAccountIndex,
        roastSetups: groups,
        groupTransitions: transitions.map((t) => t.forRestore()).toList(),
        backupRestoreId: restoreId,
      );
}

/// Transition consent is an existing language-neutral binary protocol. Its
/// exact byte layouts are specified in docs/wallet-backup-format.md.
final class BackupTransition(final WalletGroupTransition transition) {
  Map<String, Object?> toCbor() => {
    'transition_id': transition.transitionId,
    'source_setup_id': transition.sourceSetupId,
    'successor_setup_id': transition.successorSetupId,
    'proposal': cl.hexToBytes(transition.proposalHex),
    'dkg_details': <String, Object?>{
      for (final e in transition.dkgDetailsHexByKey.entries)
        e.key: cl.hexToBytes(e.value),
    },
    'signed_approvals': <String, Object?>{
      for (final e in transition.signedApprovalsHexByParticipant.entries)
        e.key: cl.hexToBytes(e.value),
    },
    'phase': transition.phase.name,
    'migration_operation_ids': _sorted(transition.migrationOperationIds),
    'transaction_ids': _sorted(transition.transactionIds),
    'created_at_ms': transition.createdAt.millisecondsSinceEpoch,
    'updated_at_ms': transition.updatedAt.millisecondsSinceEpoch,
  };
  factory BackupTransition.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'transition_id',
      'source_setup_id',
      'successor_setup_id',
      'proposal',
      'dkg_details',
      'signed_approvals',
      'phase',
      'migration_operation_ids',
      'transaction_ids',
      'created_at_ms',
      'updated_at_ms',
    });
    Map<String, String> hexMap(String field) {
      final map = r.data[field];
      if (map is! Map<String, Object?> || map.length > 10000) {
        backupInvalid('Invalid transition records.');
      }
      return {
        for (final e in map.entries)
          e.key: e.value is Uint8List
              ? cl.bytesToHex(e.value as Uint8List)
              : backupInvalid(
                  'Transition cryptographic records must be byte strings.',
                ),
      };
    }

    // Reuse the existing proposal/approval validation without importing any
    // Hive schema into the file format.
    final t = WalletGroupTransition.fromJson({
      'transitionId': r.string('transition_id'),
      'sourceSetupId': r.string('source_setup_id'),
      'successorSetupId': r.string('successor_setup_id'),
      'proposalHex': cl.bytesToHex(r.bytes('proposal')),
      'dkgDetailsHexByKey': hexMap('dkg_details'),
      'signedApprovalsHexByParticipant': hexMap('signed_approvals'),
      'phase': r.string('phase'),
      'migrationOperationIds': r.strings('migration_operation_ids'),
      'transactionIds': r.strings('transaction_ids'),
      'createdAt': r.time('created_at_ms').toIso8601String(),
      'updatedAt': r.time('updated_at_ms').toIso8601String(),
    });
    final policy = t.proposal.migrationPolicy;
    if (policy.kind != sygnatureWalletTransitionPolicyKind ||
        policy.version != 1) {
      backupInvalid('Unsupported transition migration policy.');
    }
    SygnatureWalletTransitionPolicy.fromBytes(policy.payload);
    return BackupTransition(t);
  }
  WalletGroupTransition forRestore() => switch (transition.phase) {
    WalletGroupTransitionPhase.active ||
    WalletGroupTransitionPhase.retired ||
    WalletGroupTransitionPhase.failed => transition,
    _ => transition.copyWith(
      phase: WalletGroupTransitionPhase.outcomeUnknown,
      updatedAt: transition.updatedAt,
      clearError: true,
    ),
  };
}

final class BackupAccount(final WalletAccount account) {
  Map<String, Object?> toCbor() => {
    'id': account.id,
    'name': account.name,
    'account_index': account.accountIndex,
    'blockchain_id': account.blockchainId,
    'network_id': account.networkId,
    'key_source': account.keySource.name,
    'source_id': account.sourceId,
    'key_id': account.keyId,
    'derivation_path': account.derivationPath,
    'address': account.address,
    'private_key': account.privateKeyHex == null
        ? null
        : cl.hexToBytes(account.privateKeyHex!),
    'created_at_ms': account.createdAt.millisecondsSinceEpoch,
    'archived_at_ms': account.archivedAt?.millisecondsSinceEpoch,
  };
  factory BackupAccount.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'id',
      'name',
      'account_index',
      'blockchain_id',
      'network_id',
      'key_source',
      'source_id',
      'key_id',
      'derivation_path',
      'address',
      'private_key',
      'created_at_ms',
      'archived_at_ms',
    });
    final source = WalletKeySource.values.byName(r.string('key_source'));
    final address = r.optionalString('address');
    return BackupAccount(
      WalletAccount(
        id: r.string('id'),
        name: r.string('name'),
        accountIndex: r.integer('account_index', max: 0x7fffffff),
        blockchainId: r.string('blockchain_id'),
        networkId: r.string('network_id'),
        keySource: source,
        sourceId: r.optionalString('source_id'),
        keyId: r.optionalString('key_id'),
        derivationPath: r.optionalString('derivation_path'),
        address: address,
        privateKeyHex: r.optionalHex('private_key', 32),
        derivationState: source == WalletKeySource.watchOnly
            ? WalletDerivationState.watchOnly
            : address == null
            ? WalletDerivationState.pending
            : WalletDerivationState.ready,
        createdAt: r.time('created_at_ms'),
        archivedAt: r.data['archived_at_ms'] == null
            ? null
            : r.time('archived_at_ms'),
      ),
    );
  }
}

final class BackupSigningKey({
  required final Uint8List groupPublicKey,
  required final int threshold,
  required final Uint8List participantId,
  required final Uint8List secretShare,
  required final List<(Uint8List, Uint8List)> verificationShares,
  required final String name,
  required final String description,
  required final List<(Uint8List, bool, Uint8List)> acknowledgements,
}) {
  factory BackupSigningKey.fromKey(FrostKeyWithDetails key) {
    if (key.keyInfo is HDParticipantKeyInfo ||
        key.keyConstruction is! KeyConstructionProgress ||
        (key.keyConstruction as KeyConstructionProgress).secrets.isNotEmpty) {
      backupInvalid(
        'Unsupported HD or reconstructed/shared private key state; recovery data cannot be omitted.',
      );
    }
    return BackupSigningKey(
      groupPublicKey: key.groupKey.data,
      threshold: key.keyInfo.group.threshold,
      participantId: key.keyInfo.private.identifier.toBytes(),
      secretShare: Uint8List.fromList(key.keyInfo.private.share.data),
      verificationShares: key.keyInfo.publicShares.list
          .map((s) => (s.$1.toBytes(), s.$2.data))
          .toList(),
      name: key.name,
      description: key.description,
      acknowledgements: key.acks
          .map(
            (a) => (
              a.signer.toBytes(),
              a.signed.obj.accepted,
              a.signed.signature.data,
            ),
          )
          .toList(),
    );
  }
  Map<String, Object?> toCbor() => {
    'group_public_key': groupPublicKey,
    'threshold': threshold,
    'participant_id': participantId,
    'secret_share': secretShare,
    'name': name,
    'description': description,
    'verification_shares':
        (verificationShares.toList()
              ..sort((a, b) => BackupCbor.compareBytes(a.$1, b.$1)))
            .map(
              (s) => <String, Object?>{
                'participant_id': s.$1,
                'public_key': s.$2,
              },
            )
            .toList(),
    'acknowledgements':
        (acknowledgements.toList()
              ..sort((a, b) => BackupCbor.compareBytes(a.$1, b.$1)))
            .map(
              (a) => <String, Object?>{
                'participant_id': a.$1,
                'accepted': a.$2,
                'signature': a.$3,
              },
            )
            .toList(),
  };
  factory BackupSigningKey.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'group_public_key',
      'threshold',
      'participant_id',
      'secret_share',
      'name',
      'description',
      'verification_shares',
      'acknowledgements',
    });
    return BackupSigningKey(
      groupPublicKey: r.bytes('group_public_key', 33),
      threshold: r.integer('threshold', max: 65535),
      participantId: r.bytes('participant_id', 32),
      secretShare: r.bytes('secret_share', 32),
      name: r.string('name'),
      description: r.string('description', empty: true),
      verificationShares: r.list('verification_shares').map((v) {
        final s = BackupRecord(v, {'participant_id', 'public_key'});
        return (s.bytes('participant_id', 32), s.bytes('public_key', 33));
      }).toList(),
      acknowledgements: r.list('acknowledgements').map((v) {
        final a = BackupRecord(v, {'participant_id', 'accepted', 'signature'});
        return (
          a.bytes('participant_id', 32),
          a.boolean('accepted'),
          a.bytes('signature', 64),
        );
      }).toList(),
    );
  }
  FrostKeyWithDetails toKey() {
    var result = FrostKeyWithDetails(
      keyInfo: ParticipantKeyInfo(
        group: GroupKeyInfo(
          groupKey: cl.ECCompressedPublicKey(groupPublicKey),
          threshold: threshold,
        ),
        publicShares: PublicSharesKeyInfo(
          publicShares: verificationShares
              .map(
                (s) => (
                  Identifier.fromBytes(s.$1),
                  cl.ECCompressedPublicKey(s.$2),
                ),
              )
              .toList(),
        ),
        private: PrivateKeyInfo(
          identifier: Identifier.fromBytes(participantId),
          share: cl.ECPrivateKey(secretShare),
        ),
      ),
      name: name,
      description: description,
    );
    for (final a in acknowledgements) {
      result = result.addOrReplaceAck(
        SignedDkgAck(
          signer: Identifier.fromBytes(a.$1),
          signed: Signed(
            obj: DkgAck(groupKey: result.groupKey, accepted: a.$2),
            signature: cl.SchnorrSignature(a.$3),
          ),
        ),
      );
    }
    return result;
  }
}

final class BackupGroup({
  required final RoastSetup setup,
  required final List<BackupSigningKey> keys,
  required final BackupRoom? room,
}) {
  Map<String, Object?> toCbor() => {
    'setup_id': setup.id,
    'group_id': setup.groupId,
    'name': setup.name,
    'role': setup.role.name,
    'protocol': 'noosphere/0.1.1',
    'protocol_version': noosphereRoastProtocolVersion,
    'frost_ciphersuite': 'FROST-secp256k1-SHA256-TR-v1',
    'threshold': setup.threshold,
    'participant_count': setup.participantCount,
    'blockchain_id': setup.blockchainId,
    'network_id': setup.networkId,
    'local_card_id': setup.localCardId,
    'identity_private_key': cl.hexToBytes(setup.localParticipantPrivateKeyHex),
    'key_name': setup.keyName,
    'created_at_ms': setup.createdAt.millisecondsSinceEpoch,
    'iroh_identity_index': setup.irohIdentityIndex,
    'uses_room_enrollment': setup.usesRoomEnrollment,
    'host_participant_id': setup.hostParticipantId == null
        ? null
        : cl.hexToBytes(setup.hostParticipantId!),
    'coordinator_id': setup.coordinatorId,
    'coordinator_relay_urls': _sorted(setup.coordinatorRelayUrls),
    'coordinator_ip_addrs': _sorted(setup.coordinatorIpAddrs),
    'group_fingerprint': setup.groupFingerprintHex == null
        ? null
        : cl.hexToBytes(setup.groupFingerprintHex!),
    'group_public_key': setup.groupKeyHex == null
        ? null
        : cl.hexToBytes(setup.groupKeyHex!),
    'participants':
        (setup.participants.toList()
              ..sort((a, b) => a.identifierHex.compareTo(b.identifierHex)))
            .map(
              (p) => <String, Object?>{
                'card_id': p.cardId,
                'name': p.name,
                'participant_id': cl.hexToBytes(p.identifierHex),
                'identity_public_key': cl.hexToBytes(p.publicKeyHex),
              },
            )
            .toList(),
    'keys':
        (keys.toList()..sort(
              (a, b) =>
                  BackupCbor.compareBytes(a.groupPublicKey, b.groupPublicKey),
            ))
            .map((k) => k.toCbor())
            .toList(),
    'room': room?.toCbor(),
  };
  factory BackupGroup.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'setup_id',
      'group_id',
      'name',
      'role',
      'protocol',
      'protocol_version',
      'frost_ciphersuite',
      'threshold',
      'participant_count',
      'blockchain_id',
      'network_id',
      'local_card_id',
      'identity_private_key',
      'key_name',
      'created_at_ms',
      'iroh_identity_index',
      'uses_room_enrollment',
      'host_participant_id',
      'coordinator_id',
      'coordinator_relay_urls',
      'coordinator_ip_addrs',
      'group_fingerprint',
      'group_public_key',
      'participants',
      'keys',
      'room',
    });
    if (r.integer('protocol_version') != noosphereRoastProtocolVersion ||
        r.string('protocol') != 'noosphere/0.1.1' ||
        r.string('frost_ciphersuite') != 'FROST-secp256k1-SHA256-TR-v1') {
      backupInvalid('Unsupported ROAST protocol or FROST ciphersuite.');
    }
    return BackupGroup(
      setup: RoastSetup(
        id: r.string('setup_id'),
        groupId: r.string('group_id'),
        name: r.string('name'),
        role: RoastSetupRole.values.byName(r.string('role')),
        status: RoastSetupStatus.interrupted,
        threshold: r.integer('threshold', max: 65535),
        participantCount: r.integer('participant_count', max: 65535),
        blockchainId: r.string('blockchain_id'),
        networkId: r.string('network_id'),
        localCardId: r.string('local_card_id'),
        localParticipantPrivateKeyHex: cl.bytesToHex(
          r.bytes('identity_private_key', 32),
        ),
        keyName: r.string('key_name'),
        createdAt: r.time('created_at_ms'),
        irohIdentityIndex: r.integer('iroh_identity_index', max: 0x7fffffff),
        usesRoomEnrollment: r.boolean('uses_room_enrollment'),
        hostParticipantId: r.optionalHex('host_participant_id', 32),
        coordinatorId: r.optionalString('coordinator_id'),
        coordinatorRelayUrls: r.strings('coordinator_relay_urls'),
        coordinatorIpAddrs: r.strings('coordinator_ip_addrs'),
        groupFingerprintHex: r.optionalHex('group_fingerprint', 32),
        groupKeyHex: r.optionalHex('group_public_key', 33),
        requiresBackupReconciliation: true,
        participants: r.list('participants').map((v) {
          final p = BackupRecord(v, {
            'card_id',
            'name',
            'participant_id',
            'identity_public_key',
          });
          return RoastParticipant(
            cardId: p.string('card_id'),
            name: p.string('name'),
            identifierHex: cl.bytesToHex(p.bytes('participant_id', 32)),
            publicKeyHex: cl.bytesToHex(p.bytes('identity_public_key', 33)),
          );
        }).toList(),
      ),
      keys: r.list('keys').map(BackupSigningKey.fromCbor).toList(),
      room: r.data['room'] == null ? null : BackupRoom.fromCbor(r.data['room']),
    );
  }
  GroupConfig get group => GroupConfig(
    id: setup.groupId,
    participants: {
      for (final p in setup.participants)
        Identifier.fromHex(p.identifierHex): cl.ECCompressedPublicKey.fromHex(
          p.publicKeyHex,
        ),
    },
  );
  void validate({required bool hasMnemonic}) {
    final s = setup;
    if (!s.isFinalized ||
        s.threshold < 2 ||
        s.threshold > s.participantCount ||
        s.pendingDkgProposalHex != null) {
      backupInvalid('ROAST group is incomplete or has an unfinished DKG.');
    }
    if (s.keyName.length < 3 ||
        s.keyName.length > 40 ||
        s.irohIdentityIndex < 0 ||
        s.irohIdentityIndex > 0x7fffffff) {
      backupInvalid('Invalid ROAST key or identity metadata.');
    }
    _unique(s.participants.map((p) => p.cardId));
    _unique(s.participants.map((p) => p.identifierHex));
    _unique(s.participants.map((p) => p.publicKeyHex));
    final network = PeercoinNetworks.byId(s.networkId);
    if (network.blockchainId != s.blockchainId) {
      backupInvalid('Unsupported ROAST blockchain.');
    }
    final local = s.localParticipant;
    if (cl.ECCompressedPublicKey.fromPubkey(
          cl.ECPrivateKey.fromHex(s.localParticipantPrivateKeyHex).pubkey,
        ).hex !=
        local.publicKeyHex) {
      backupInvalid('Participant identity private/public key mismatch.');
    }
    if (s.groupFingerprintHex == null ||
        s.groupFingerprintHex != cl.bytesToHex(group.fingerprint)) {
      backupInvalid('Missing or inconsistent ROAST group fingerprint.');
    }
    if (!hasMnemonic) {
      backupInvalid('Coordinator identity requires the wallet mnemonic.');
    }
    if (s.coordinatorId == null) {
      backupInvalid('Missing pinned coordinator identity.');
    }
    PublicKey.fromZ32(s.coordinatorId!);
    if (s.hostParticipantId == null ||
        !s.participants.any((p) => p.identifierHex == s.hostParticipantId)) {
      backupInvalid('Missing host participant.');
    }
    const RoastKeyService().validateRoster(
      participants: s.participants,
      participantCount: s.participantCount,
      threshold: s.threshold,
      hostParticipantId: s.hostParticipantId!,
    );
    if (keys.isEmpty ||
        s.groupKeyHex == null ||
        !keys.any((k) => cl.bytesToHex(k.groupPublicKey) == s.groupKeyHex)) {
      backupInvalid('Missing locally held DKG signing share.');
    }
    _unique(keys.map((k) => cl.bytesToHex(k.groupPublicKey)));
    for (final k in keys) {
      final key = k.toKey();
      if (k.threshold != s.threshold ||
          cl.bytesToHex(k.participantId) != local.identifierHex ||
          k.verificationShares.length != s.participantCount ||
          !k.verificationShares.every(
            (v) => s.participants.any(
              (p) => p.identifierHex == cl.bytesToHex(v.$1),
            ),
          )) {
        backupInvalid(
          'Signing key does not match the local participant/group.',
        );
      }
      final public = key.keyInfo.publicShares.list
          .singleWhere((p) => p.$1 == key.keyInfo.private.identifier)
          .$2;
      if (cl.ECCompressedPublicKey.fromPubkey(
            key.keyInfo.private.share.pubkey,
          ) !=
          public) {
        backupInvalid(
          'Secret signing share does not match its verification share.',
        );
      }
      _unique(k.acknowledgements.map((a) => cl.bytesToHex(a.$1)));
      for (final a in key.acks) {
        final identity = group.participants[a.signer];
        if (identity == null || !a.signed.verify(identity)) {
          backupInvalid('Invalid signed DKG acknowledgement.');
        }
      }
    }
    if (s.role == RoastSetupRole.host && s.usesRoomEnrollment) {
      if (room == null) backupInvalid('Missing frozen room recovery metadata.');
      room!.validate(this);
    } else if (room != null) {
      backupInvalid('Unexpected room recovery metadata.');
    }
  }
}

final class BackupRoom(
  final Uint8List coordinatorEndpointId,
  final List<(Uint8List, int)> enrollmentTimes,
) {
  factory BackupRoom.fromSnapshot(RoomSnapshot room) {
    if (room.lifecycle != RoomLifecycle.frozen ||
        room.groupConfig == null ||
        room.participants.any((p) => p.identifier == null)) {
      backupInvalid('Only a fully frozen room can be backed up.');
    }
    return BackupRoom(
      room.coordinatorEndpointId,
      room.participants
          .map(
            (p) =>
                (p.identifier!.toBytes(), p.enrolledAt.millisecondsSinceEpoch),
          )
          .toList(),
    );
  }
  Map<String, Object?> toCbor() => {
    'coordinator_endpoint_id': coordinatorEndpointId,
    'enrollment_times':
        (enrollmentTimes.toList()
              ..sort((a, b) => BackupCbor.compareBytes(a.$1, b.$1)))
            .map(
              (p) => <String, Object?>{
                'participant_id': p.$1,
                'enrolled_at_ms': p.$2,
              },
            )
            .toList(),
  };
  factory BackupRoom.fromCbor(Object? value) {
    final r = BackupRecord(value, {
      'coordinator_endpoint_id',
      'enrollment_times',
    });
    return BackupRoom(
      r.bytes('coordinator_endpoint_id', 32),
      r.list('enrollment_times').map((v) {
        final p = BackupRecord(v, {'participant_id', 'enrolled_at_ms'});
        return (
          p.bytes('participant_id', 32),
          p.integer('enrolled_at_ms', max: 8640000000000000),
        );
      }).toList(),
    );
  }
  void validate(BackupGroup g) {
    _unique(enrollmentTimes.map((p) => cl.bytesToHex(p.$1)));
    if (enrollmentTimes.length != g.setup.participantCount ||
        !enrollmentTimes.every(
          (p) => g.setup.participants.any(
            (v) => v.identifierHex == cl.bytesToHex(p.$1),
          ),
        )) {
      backupInvalid('Frozen room roster mismatch.');
    }
  }

  RoomSnapshot toSnapshot(BackupGroup g) => RoomSnapshot(
    roomId: g.setup.groupId,
    lifecycle: RoomLifecycle.frozen,
    expectedParticipants: g.setup.participantCount,
    threshold: g.setup.threshold,
    coordinatorEndpointId: coordinatorEndpointId,
    invites: const [],
    participants: enrollmentTimes.map(
      (p) => RoomParticipantSnapshot(
        publicKey: g.group.participants[Identifier.fromBytes(p.$1)]!,
        enrolledAt: DateTime.fromMillisecondsSinceEpoch(p.$2, isUtc: true),
        identifier: Identifier.fromBytes(p.$1),
      ),
    ),
    groupConfig: g.group,
  );
}

final class BackupFormatException extends FormatException {
  const BackupFormatException(super.message);
}

Never backupInvalid(String message) => throw BackupFormatException(message);
void _unique(Iterable<String> values) {
  final list = values.toList();
  if (list.toSet().length != list.length) {
    backupInvalid('Duplicate backup identifier.');
  }
}

int _compareText(String a, String b) =>
    BackupCbor.compareBytes(utf8.encode(a), utf8.encode(b));
List<String> _sorted(List<String> values) =>
    values.toList()..sort(_compareText);

/// Strict field/type checks, with errors that never include field contents.
final class BackupRecord {
  BackupRecord(Object? value, Set<String> fields) {
    if (value is! Map<String, Object?> ||
        value.length != fields.length ||
        !fields.containsAll(value.keys)) {
      backupInvalid('Missing or unexpected backup fields.');
    }
    data = value;
  }
  late final Map<String, Object?> data;
  String string(String field, {bool empty = false}) {
    final v = data[field];
    if (v is! String || (!empty && v.isEmpty) || v.length > 4096) {
      backupInvalid('Invalid text field: $field.');
    }
    return v;
  }

  String? optionalString(String field) =>
      data[field] == null ? null : string(field);
  int integer(String field, {int max = 0x1fffffffffffff}) {
    final v = data[field];
    if (v is! int || v < 0 || v > max) {
      backupInvalid('Invalid integer field: $field.');
    }
    return v;
  }

  DateTime time(String field) => DateTime.fromMillisecondsSinceEpoch(
    integer(field, max: 8640000000000000),
    isUtc: true,
  );
  bool boolean(String field) {
    final v = data[field];
    if (v is! bool) backupInvalid('Invalid boolean field: $field.');
    return v;
  }

  Uint8List bytes(String field, [int? length]) {
    final v = data[field];
    if (v is! Uint8List || (length != null && v.length != length)) {
      backupInvalid('Invalid byte field: $field.');
    }
    return v;
  }

  String? optionalHex(String field, int length) =>
      data[field] == null ? null : cl.bytesToHex(bytes(field, length));
  List<Object?> list(String field) {
    final v = data[field];
    if (v is! List<Object?> || v.length > 10000) {
      backupInvalid('Invalid collection field: $field.');
    }
    return v;
  }

  List<String> strings(String field) => list(field).map((v) {
    if (v is! String || v.isEmpty || v.length > 4096) {
      backupInvalid('Invalid string collection: $field.');
    }
    return v;
  }).toList();
}
