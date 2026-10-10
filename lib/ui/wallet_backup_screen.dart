import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controllers/wallet_controller.dart';
import '../services/backup_envelope.dart';
import '../services/app_logger.dart';

class const WalletBackupScreen({
  super.key,
  required final WalletController controller,
}) extends StatefulWidget {
  @override
  State<WalletBackupScreen> createState() => _WalletBackupScreenState();
}

class _WalletBackupScreenState extends State<WalletBackupScreen> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  String? _message;
  String _stage = 'Backup operation';

  @override
  void dispose() {
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on WalletBusyFailure {
      if (mounted) {
        setState(
          () =>
              _message = 'Another wallet operation is in progress. Try again.',
        );
      }
    } catch (error) {
      // Exception messages/objects can contain decrypted domain data. Log only
      // a fixed stage and the exception class, never the exception itself.
      final hint = _stage == 'Saving encrypted backup'
          ? 'Check the desktop file chooser and destination permissions.'
          : 'No success was reported; the backup operation did not complete.';
      final message = '$_stage failed (${error.runtimeType}). $hint';
      AppLogger.warn('[BACKUP] $message');
      if (mounted) {
        setState(() => _message = message);
      }
    } finally {
      if (mounted) {
        _password.clear();
        _confirmation.clear();
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _export() => _run(() async {
    _stage = 'Preparing encrypted backup';
    if (_password.text.runes.length < 8 ||
        _password.text != _confirmation.text) {
      throw const FormatException(
        'Use at least 8 characters and enter the same passphrase twice.',
      );
    }
    final bytes = await widget.controller.exportEncryptedBackup(_password.text);
    if (!mounted) return;
    _stage = 'Saving encrypted backup';
    final saved = await FilePicker.saveFile(
      fileName:
          'wallet-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}.sygnaturebkp',
      bytes: bytes,
      mimeType: 'application/octet-stream',
      dialogTitle: 'Save encrypted wallet backup',
    );
    if (mounted) {
      setState(
        () => _message = saved == null
            ? 'Saving was cancelled. Previously running ROAST groups were asked to reconnect; check their connection status.'
            : 'Encrypted backup saved. Previously running ROAST groups were asked to reconnect; check their connection status.',
      );
    }
  });

  Future<void> _import() async {
    if (widget.controller.hasWallet) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Wallet already exists'),
          content: const Text(
            'Importing a backup requires an empty wallet. '
            'Your existing wallet and ROAST groups will not be overwritten or merged. '
            'Use an empty wallet installation to restore this backup.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await _run(() async {
      _stage = 'Opening encrypted backup';
      final password = _password.text;
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['sygnaturebkp'],
        dialogTitle: 'Select encrypted wallet backup',
      );
      if (file == null) return;
      _stage = 'Reading encrypted backup';
      final size = file.lengthSync();
      if (size != null && size > BackupEnvelope.maxFileBytes) {
        throw const FormatException('Backup exceeds 16 MiB.');
      }
      // A bounded stream protects even platforms/providers with missing or
      // inaccurate size metadata. Only ciphertext is ever read from disk.
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (builder.length + chunk.length > BackupEnvelope.maxFileBytes) {
          throw const FormatException('Backup exceeds 16 MiB.');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      _stage = 'Validating encrypted backup';
      final preview = await widget.controller.previewEncryptedBackup(
        bytes,
        password,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore encrypted backup?'),
          content: SingleChildScrollView(
            child: Text(
              '${preview.walletCount} mnemonic vault(s), ${preview.accountCount} wallet account(s), ${preview.groupCount} ROAST group(s)\n'
              'Networks: ${preview.networks.isEmpty ? 'none' : preview.networks.join(', ')}\n'
              'Created: ${preview.createdAt.toIso8601String()}\n\n${preview.conflictPolicy}\n\n'
              'Signing sessions and nonces are excluded. Fresh signing nonces will be generated. '
              'Do not run another copy of the same participant concurrently.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-backup-import'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      _stage = 'Restoring encrypted backup';
      await widget.controller.importEncryptedBackup(bytes, password, preview);
      if (mounted) {
        setState(
          () => _message = 'Backup restored and saved. Verify restored ROAST groups with live participants before reconnecting.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Encrypted wallet backup')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Anyone with this file and its passphrase can recover your wallet and local signing shares. '
                  'Choose a high-entropy passphrase, such as several randomly chosen words, and store it separately. '
                  'Spaces, capitalization and Unicode characters must match exactly.',
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('backup-passphrase'),
                  controller: _password,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableInteractiveSelection: false,
                  autofillHints: const [],
                  decoration: const InputDecoration(
                    labelText: 'Backup passphrase',
                  ),
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('backup-passphrase-confirmation'),
                  controller: _confirmation,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableInteractiveSelection: false,
                  autofillHints: const [],
                  decoration: const InputDecoration(
                    labelText: 'Confirm passphrase (export only)',
                  ),
                  enabled: !_busy,
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      key: const Key('export-backup'),
                      onPressed: _busy || !widget.controller.hasWallet
                          ? null
                          : _export,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Export .sygnaturebkp'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('import-backup'),
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.restore),
                      label: const Text('Import .sygnaturebkp'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Export pauses ROAST and closes its worker for a consistent snapshot, then reconnects previously running groups. Finish pending signing operations first. '
                  'Import requires an empty wallet and never overwrites existing records.',
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_message!, key: const Key('backup-result')),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
