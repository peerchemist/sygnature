import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/wallet_backup.dart';
import '../storage/roast_storage.dart';
import '../storage/wallet_repository.dart';
import 'backup_envelope.dart';

final class BackupPreview({
  required final int walletCount,
  required final int accountCount,
  required final int groupCount,
  required final List<String> networks,
  required final DateTime createdAt,
  required final String fileDigest,
}) {
  String get conflictPolicy =>
      'Restore requires an empty wallet and empty ROAST storage. '
      'No existing wallet or group will be overwritten. Restored groups stay offline '
      'until you verify their roster, threshold and keys with the live participants.';
}

final class ImportOptions(final BackupPreview confirmedPreview);

/// The caller must serialize wallet mutations and stop all signing runtimes for
/// snapshot export. Imports are supported only into an empty, offline wallet.
final class WalletBackupService(
  final WalletRepository repository,
  final RoastPersistenceFactory? roastPersistence,
) {
  Future<Uint8List> exportEncrypted(String passphrase) async {
    try {
      return await _export(passphrase);
    } on BackupFormatException {
      rethrow;
    } catch (error) {
      // Only the type is safe: native/domain error messages may contain keys.
      backupInvalid(
        'Backup export failed (${error.runtimeType}). No backup was created.',
      );
    }
  }

  Future<Uint8List> _export(String passphrase) async {
    final vault = await repository.load();
    if (vault != null &&
        vault.roastSetups.isNotEmpty &&
        roastPersistence == null) {
      backupInvalid(
        'ROAST signing storage is unavailable; no backup was created.',
      );
    }
    final backup = WalletBackupV1(
      createdAt: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      wallet: vault == null ? null : BackupWallet.fromVault(vault),
      groups: vault == null || roastPersistence == null
          ? []
          : await roastPersistence!.backupGroups(vault),
    );
    Uint8List? plaintext;
    try {
      backup.validate();
      plaintext = backup.encode();
      // Round-trip the independent schema before encrypting; the envelope also
      // authenticates/decrypts its result and compares the exact plaintext.
      WalletBackupV1.decode(plaintext).clearSecrets();
      return await BackupEnvelope.encrypt(plaintext, passphrase);
    } finally {
      plaintext?.fillRange(0, plaintext.length, 0);
      backup.clearSecrets();
    }
  }

  Future<WalletBackupV1> _decode(Uint8List file, String passphrase) async {
    final plaintext = await BackupEnvelope.decrypt(file, passphrase);
    try {
      return WalletBackupV1.decode(plaintext);
    } on BackupFormatException {
      rethrow;
    } catch (_) {
      // Domain parser exceptions can carry key material. Never forward them to
      // UI, logging, crash reporting or analytics.
      backupInvalid('Backup recovery data failed cryptographic validation.');
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static Future<String> _digest(Uint8List file) async =>
      (await Sha256().hash(file)).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  Future<BackupPreview> previewImport(
    Uint8List encryptedBackup,
    String passphrase,
  ) async {
    final backup = await _decode(encryptedBackup, passphrase);
    try {
      return BackupPreview(
        walletCount: backup.wallet == null ? 0 : 1,
        accountCount: backup.wallet?.accounts.length ?? 0,
        groupCount: backup.groups.length,
        networks: <String>{
          for (final a in backup.wallet?.accounts ?? <BackupAccount>[])
            '${a.account.blockchainId}:${a.account.networkId}',
          for (final g in backup.groups)
            '${g.setup.blockchainId}:${g.setup.networkId}',
        }.toList()..sort(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          backup.createdAt * 1000,
          isUtc: true,
        ),
        fileDigest: await _digest(encryptedBackup),
      );
    } finally {
      backup.clearSecrets();
    }
  }

  Future<void> importEncrypted(
    Uint8List encryptedBackup,
    String passphrase,
    ImportOptions options,
  ) async {
    BackupEnvelope.validateHeader(encryptedBackup);
    if (await _digest(encryptedBackup) != options.confirmedPreview.fileDigest) {
      backupInvalid(
        'The selected file changed after preview. Preview it again.',
      );
    }
    final backup = await _decode(encryptedBackup, passphrase);
    try {
      final persistence = roastPersistence;
      if (persistence == null) {
        backupInvalid('Backup restore storage is unavailable on this target.');
      }
      await persistence.commitBackupImport(
        repository,
        backup,
        options.confirmedPreview.fileDigest,
      );
    } finally {
      backup.clearSecrets();
    }
  }
}
