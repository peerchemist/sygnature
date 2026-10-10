part of 'roast_runtime_manager.dart';

extension _RoastDkgRuntime on RoastRuntimeManager {
  Future<void> _requestDkg(
    RoastSetup setup, {
    NewDkgDetails? approvedDetails,
    GroupTransitionKeyPlan? transitionKeyPlan,
  }) async {
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Requesting DKG',
    );
    if ((approvedDetails == null) != (transitionKeyPlan == null)) {
      throw ArgumentError(
        'Approved DKG details and transition key plan must be provided together.',
      );
    }
    if (approvedDetails != null) {
      if (approvedDetails.expiry.isExpired ||
          approvedDetails.name != setup.keyName ||
          approvedDetails.threshold != setup.threshold ||
          transitionKeyPlan!.targetThreshold != setup.threshold ||
          !transitionKeyPlan.matchesDkgDetails(approvedDetails)) {
        throw StateError(
          'The DKG does not match the approved transition plan.',
        );
      }
      _approvedDkgDetailsBySetup[setup.id] = Uint8List.fromList(
        approvedDetails.toBytes(),
      );
    } else {
      _approvedDkgDetailsBySetup.remove(setup.id);
    }
    final worker = await _ensureWorker();
    final existing = await _resolveExistingDkg(
      worker,
      setup,
      await worker.snapshot(setup.id),
    );
    if (existing == _ExistingDkgResolution.resumed) return;

    final details =
        approvedDetails ??
        NewDkgDetails(
          name: setup.keyName,
          description: roastKeyDescription(setup),
          threshold: setup.threshold,
          expiry: Expiry(roastDkgAttemptTtl),
        );
    try {
      await worker.requestDkg(setup.id, details);
    } catch (error, stackTrace) {
      if (!_isDuplicateDkgError(error)) {
        AppLogger.error(
          '${RoastRuntimeManager._roastScope(setup.id)} DKG request failed',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      AppLogger.warn(
        '${RoastRuntimeManager._roastScope(setup.id)} Coordinator already has this DKG name; '
        'reloading the signer session before retrying',
      );
      final recovered = await _reloadExistingDkg(worker, setup);
      if (recovered == _ExistingDkgResolution.resumed) return;
      if (recovered == _ExistingDkgResolution.cancelled) {
        await _runDkgCommand(
          setup.id,
          'DKG retry after cancelling the conflicting proposal',
          () => worker.requestDkg(setup.id, details),
        );
      } else {
        AppLogger.error(
          '${RoastRuntimeManager._roastScope(setup.id)} Existing DKG could not be recovered',
          error: error,
          stackTrace: stackTrace,
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} DKG request submitted; '
      'waiting for signer approvals',
    );
  }

  Future<_ExistingDkgResolution> _reloadExistingDkg(
    NoosphereWorker worker,
    RoastSetup setup,
  ) async {
    AppLogger.info(
      '${RoastRuntimeManager._irohScope(setup.id)} Restarting signer session to synchronize DKGs',
    );
    _synchronizingDkgSetups.add(setup.id);
    try {
      await worker.stopSetup(setup.id, roles: NoosphereWorkerRoles.signer);
      _signerSetups.remove(setup.id);
      if (!_serverSetups.contains(setup.id)) _workerSetups.remove(setup.id);
      await _startSetup(setup, scheduleRoomRetry: false, publishDkgs: false);
      final snapshot = await worker.snapshot(setup.id);
      AppLogger.info(
        '${RoastRuntimeManager._irohScope(setup.id)} Signer session synchronized; '
        '${snapshot.dkgs.length} DKG proposal(s) loaded',
      );
      return await _resolveExistingDkg(worker, setup, snapshot);
    } finally {
      _synchronizingDkgSetups.remove(setup.id);
    }
  }

  Future<_ExistingDkgResolution> _resolveExistingDkg(
    NoosphereWorker worker,
    RoastSetup setup,
    NoosphereWorkerSnapshot snapshot,
  ) async {
    final sameName = snapshot.dkgs
        .where((proposal) => proposal.name == setup.keyName)
        .toList(growable: false);
    if (sameName.isEmpty) return _ExistingDkgResolution.none;
    if (sameName.length > 1) {
      throw StateError('Multiple DKG proposals use the expected key name.');
    }
    final proposal = sameName.single;
    final proposalHex = bytesToHex(proposal.proposalBytes);
    if (_dkgMatchesSetup(proposal, setup)) {
      AppLogger.info(
        '${RoastRuntimeManager._roastScope(setup.id)} Resuming existing DKG '
        '${RoastRuntimeManager._shortId(proposalHex)} at stage=${proposal.stage}',
      );
      _rememberDkgs(snapshot);
      _emitSnapshot(snapshot);
      return _ExistingDkgResolution.resumed;
    }

    AppLogger.warn(
      '${RoastRuntimeManager._roastScope(setup.id)} Cancelling incompatible DKG '
      '${RoastRuntimeManager._shortId(proposalHex)} before creating a replacement',
    );
    await _runDkgCommand(
      setup.id,
      'Conflicting DKG cancellation',
      () => worker.rejectDkg(setup.id, proposal),
    );
    _dkgProposals.remove('${setup.id}:$proposalHex');
    return _ExistingDkgResolution.cancelled;
  }

  bool _isDuplicateDkgError(Object error) =>
      error is NoosphereWorkerException &&
      error.code == 'iroh_protocol_error' &&
      error.message.contains('DKG request with same name exists');

  Future<void> _acceptDkg(String setupId, String proposalHex) async {
    final proposal = _dkgProposals['$setupId:$proposalHex'];
    if (proposal == null) {
      throw StateError('The DKG proposal is no longer available.');
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setupId)} Accepting DKG '
      '${RoastRuntimeManager._shortId(proposalHex)}',
    );
    final worker = await _ensureWorker();
    await _runDkgCommand(
      setupId,
      'DKG approval',
      () => worker.acceptDkg(setupId, proposal),
    );
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setupId)} DKG approved locally',
    );
  }

  Future<void> _rejectDkg(String setupId, String proposalHex) async {
    final proposal = _dkgProposals['$setupId:$proposalHex'];
    if (proposal == null) {
      throw StateError('The DKG proposal is no longer available.');
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setupId)} Rejecting DKG '
      '${RoastRuntimeManager._shortId(proposalHex)}',
    );
    final worker = await _ensureWorker();
    await _runDkgCommand(
      setupId,
      'DKG rejection',
      () => worker.rejectDkg(setupId, proposal),
    );
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setupId)} DKG rejected locally',
    );
  }

  Future<void> _runDkgCommand(
    String setupId,
    String operation,
    Future<void> Function() command,
  ) async {
    try {
      await command();
    } catch (error, stackTrace) {
      AppLogger.error(
        '${RoastRuntimeManager._roastScope(setupId)} $operation failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
