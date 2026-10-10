part of 'wallet_controller.dart';

extension WalletBackupController on WalletController {
  bool get backupAvailable => _backupService != null;

  Future<Uint8List> exportEncryptedBackup(String passphrase) async {
    final service = _backupService;
    if (service == null) {
      throw const FormatException('Backup storage is unavailable.');
    }
    Uint8List? result;
    await _guard(() async {
      _backupInProgress = true;
      try {
        // Auto-connect is background initialization, not an active signing
        // operation. Let it settle instead of making the user export twice.
        await Future.wait(_roastStarts.values.toList());
        await _drainBackupEvents();
        void requireIdle() {
          final now = DateTime.now();
          if (_sending ||
              _pendingRoastSends.isNotEmpty ||
              _pendingRoastMessages.isNotEmpty) {
            throw const FormatException(
              'Finish the active signing operation before exporting.',
            );
          }
          if (_roastOperations.isNotEmpty) {
            throw const FormatException(
              'A ROAST configuration operation is still in progress. Wait for it to finish before exporting.',
            );
          }
          if (_roastSigningRequests.values.any(
            (item) =>
                item.request.expiry.isAfter(now) &&
                item.request.status != 'rejected' &&
                item.request.progress.stage != 'completed' &&
                item.request.progress.stage != 'failed',
          )) {
            throw const FormatException(
              'There are unexpired signing requests awaiting approval or completion. Finish or reject them before exporting.',
            );
          }
        }

        requireIdle();
        Future<void> snapshot() async {
          await _drainBackupEvents();
          // A request may have arrived while shutdown was in progress.
          requireIdle();
          if (_roastRuntime != null) {
            for (final setup in roastSetups) {
              if (setup.isActive) {
                await _updateSetup(
                  setup.id,
                  (s) => s.copyWith(status: RoastSetupStatus.interrupted),
                );
              }
            }
          }
          _roastPresence.clear();
          await _queueVaultMutation(() async {
            result = await service.exportEncrypted(passphrase);
          });
        }

        final runtime = _roastRuntime;
        try {
          if (runtime == null) {
            await snapshot();
          } else {
            try {
              await runtime.withPausedForBackup(snapshot);
            } on NoosphereWorkerException catch (error) {
              // Only documented fixed codes are safe to expose. Worker error
              // messages can contain domain material and must remain private.
              final code = switch (error.code) {
                'invalid_state' ||
                'setup_busy' ||
                'host_timeout' ||
                'worker_closed' ||
                'worker_closing' ||
                'worker_crashed' ||
                'worker_exited' ||
                'timeout' => error.code,
                _ => 'operation_failed',
              };
              AppLogger.warn('[BACKUP] ROAST shutdown failed ($code).');
              throw FormatException(
                'Unable to stop ROAST signers safely ($code). Export cancelled. '
                'Restart the app and retry if the problem persists.',
              );
            }
          }
        } finally {
          // Reconnect events are persisted before reporting export completion.
          await _drainBackupEvents();
        }
      } finally {
        _backupInProgress = false;
      }
    });
    return result!;
  }

  Future<void> _drainBackupEvents() async {
    while (true) {
      final pending = _roastEventQueue;
      await pending;
      if (identical(pending, _roastEventQueue)) return;
    }
  }

  Future<BackupPreview> previewEncryptedBackup(
    Uint8List bytes,
    String passphrase,
  ) async {
    final service = _backupService;
    if (service == null) {
      throw const FormatException('Backup storage is unavailable.');
    }
    BackupPreview? preview;
    await _guard(() async {
      preview = await service.previewImport(bytes, passphrase);
    });
    return preview!;
  }

  Future<void> importEncryptedBackup(
    Uint8List bytes,
    String passphrase,
    BackupPreview preview,
  ) => _guard(() async {
    final service = _backupService;
    if (service == null) {
      throw const FormatException('Backup storage is unavailable.');
    }
    if (_vault != null || _sending || _roastOperations.isNotEmpty) {
      throw const FormatException('Restore requires an empty, offline wallet.');
    }
    await _queueVaultMutation(() async {
      await service.importEncrypted(bytes, passphrase, ImportOptions(preview));
      _vault = await _repository.load();
      _selectedAccountId = accounts.firstOrNull?.id;
      _storedRoastSigningOperations.clear();
      _roastSigningRequests.clear();
      _completedRoastMessages.clear();
      _pendingRoastMessageProgress.clear();
      _roastPresence.clear();
    });
    for (final network in accounts.map(networkForAccount).toSet()) {
      await _ensureNetworkService(network);
    }
    await _restartElectrumxSync();
  });

  /// Called after the user compares the restored public state against the
  /// authenticated live group. The backup itself cannot prove freshness.
  Future<void> confirmBackupGroupReconciliation(String setupId) async {
    if (_busy) throw StateError('Another wallet operation is in progress.');
    await _updateSetup(
      setupId,
      (s) => s.copyWith(requiresBackupReconciliation: false),
    );
    await resumeRoastSetup(setupId);
  }
}
