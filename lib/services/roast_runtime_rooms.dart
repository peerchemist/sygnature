part of 'roast_runtime_manager.dart';

extension _RoastRoomRuntime on RoastRuntimeManager {
  Future<RoastRoomCreation> _createRoom(
    RoastSetup setup, {
    Future<void> Function(RoastRoomCreation room)? beforeInvitations,
  }) async {
    if (setup.role != RoastSetupRole.host || !setup.isFinalized) {
      throw StateError('Only a host with a complete roster can create a room.');
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Creating room for '
      '${setup.participantCount} participants (threshold ${setup.threshold})',
    );
    _setups[setup.id] = setup;
    final node = await _ensureRoomServer(setup);
    final server = node.server!;
    await server.createRoom(
      roomId: setup.groupId,
      expectedParticipants: setup.participantCount,
      threshold: setup.threshold,
    );
    final coordinator = RoastRuntimeManager._coordinator(server.address);
    final preparedRoom = RoastRoomCreation(
      invites: const [],
      coordinatorEndpointId: server.address.id.asBytes(),
      coordinatorId: coordinator.id,
      coordinatorRelayUrls: coordinator.relayUrls,
      coordinatorIpAddrs: coordinator.ipAddrs,
    );
    await beforeInvitations?.call(preparedRoom);
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    final issued = <RoastRoomInvite>[];
    for (final participant in setup.participants) {
      final invite = await server.issueRoomInvite(
        roomId: setup.groupId,
        expectedParticipantPublicKey: ECCompressedPublicKey.fromHex(
          participant.publicKeyHex,
        ),
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      if (participant.cardId == setup.localCardId) {
        await _joinRoomInvite(invite, privateKey);
      } else {
        issued.add(
          RoastRoomInvite(
            participantPublicKeyHex: participant.publicKeyHex,
            encoded: invite.encode(),
            expiresAt: invite.expiresAt,
          ),
        );
      }
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Room created; issued ${issued.length} '
      'participant-bound invites',
    );
    return RoastRoomCreation(
      invites: issued,
      coordinatorEndpointId: preparedRoom.coordinatorEndpointId,
      coordinatorId: coordinator.id,
      coordinatorRelayUrls: coordinator.relayUrls,
      coordinatorIpAddrs: coordinator.ipAddrs,
    );
  }

  Future<RoastRuntimeSnapshot> _joinRoom(
    RoastSetup setup,
    String encodedInvite,
  ) async {
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Validating room invite',
    );
    final invite = RoomInvite.decode(encodedInvite);
    if (invite.roomId != setup.groupId ||
        invite.expectedParticipantPublicKey.hex !=
            setup.localParticipant.publicKeyHex ||
        bytesToHex(invite.coordinatorEndpointId) !=
            bytesToHex(PublicKey.fromZ32(setup.coordinatorId!).asBytes())) {
      throw const FormatException(
        'The room invite does not match this participant setup.',
      );
    }
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    invite.requirePrivateKey(privateKey);
    try {
      await _joinRoomInvite(invite, privateKey);
    } on RoomEnrollmentProtocolException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.rejected,
          cause: error,
          roomFailureCode: error.code,
        ),
        stackTrace,
      );
    } on TimeoutException catch (error, stackTrace) {
      _reconcileInterruptedEnrollment(setup);
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.timeout,
          cause: error,
        ),
        stackTrace,
      );
    } on FormatException catch (error, stackTrace) {
      _reconcileInterruptedEnrollment(setup);
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.malformedResponse,
          cause: error,
        ),
        stackTrace,
      );
    } on Object catch (error, stackTrace) {
      _reconcileInterruptedEnrollment(setup);
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.connection,
          cause: error,
        ),
        stackTrace,
      );
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Room enrollment completed',
    );
    _setups[setup.id] = setup;
    _scheduleRoomSignerConnection(setup);
    return _pendingRoomSnapshot(setup);
  }

  void _reconcileInterruptedEnrollment(RoastSetup setup) {
    _setups[setup.id] = setup;
    _scheduleRoomSignerConnection(setup);
  }

  RoastRuntimeSnapshot _pendingRoomSnapshot(RoastSetup setup) =>
      RoastRuntimeSnapshot(
        connected: false,
        signerRunning: false,
        onlineParticipantIds: const [],
        coordinatorId: setup.coordinatorId,
        coordinatorRelayUrls: setup.coordinatorRelayUrls,
        coordinatorIpAddrs: setup.coordinatorIpAddrs,
        groupKeyHex: null,
        pendingDkgProposalHex: null,
      );

  void _scheduleRoomSignerConnection(RoastSetup setup) {
    if (_roomSignerTimers.containsKey(setup.id)) return;
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Waiting for the frozen room; signer connection '
      'will retry in the background',
    );
    unawaited(_connectRoomSigner(setup));
    _roomSignerTimers[setup.id] = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_connectRoomSigner(setup)),
    );
  }

  Future<void> _connectRoomSigner(RoastSetup setup) async {
    if (!_connectingRoomSigners.add(setup.id)) return;
    try {
      final snapshot = await _startSetup(setup, scheduleRoomRetry: false);
      _roomSignerTimers.remove(setup.id)?.cancel();
      AppLogger.info(
        '${RoastRuntimeManager._irohScope(setup.id)} Signer transport connected',
      );
      _emitSnapshotValues(setup.id, snapshot);
    } on Object {
      // The ordinary ROAST group becomes available only after the host freezes
      // the full room. Retry quietly while enrollment is still in progress.
    } finally {
      _connectingRoomSigners.remove(setup.id);
    }
  }

  Future<NoosphereNode> _ensureRoomServer(RoastSetup setup) async {
    final existing = _roomServers[setup.id];
    if (existing != null) return existing;
    AppLogger.info(
      '${RoastRuntimeManager._irohScope(setup.id)} Starting room coordinator',
    );
    final persistence = await _persistenceFactory.open();
    final node = await NoosphereNode.start(
      server: EmbeddedServerOptions(
        serverConfig: ServerConfig(
          group: RoastRuntimeManager._bootstrapGroup(setup.groupId),
        ),
        getIrohSecretKey: () => _irohSecretKey(setup, persistence),
        serverPersistence: persistence.serverPersistence(setup.id),
        roomPersistence: persistence.roomPersistence(setup.id),
      ),
    );
    _roomServers[setup.id] = node;
    _roomSubscriptions[setup.id] = node.server!.rooms!.snapshots.listen(
      (room) => _onRoomSnapshot(setup.id, room),
      onError: (Object error) => _emitRoomFailure(setup.id, error),
    );
    for (final room in await node.server!.rooms!.getRooms()) {
      _onRoomSnapshot(setup.id, room);
    }
    AppLogger.info(
      '${RoastRuntimeManager._irohScope(setup.id)} Room coordinator started',
    );
    return node;
  }

  void _onRoomSnapshot(String setupId, RoomSnapshot room) {
    if (room.lifecycle != RoomLifecycle.enrolling ||
        !room.isFull ||
        !_freezingRooms.add(setupId)) {
      return;
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setupId)} Room is full; freezing roster',
    );
    unawaited(_freezeRoomAndStartSigner(setupId));
  }

  Future<void> _freezeRoomAndStartSigner(String setupId) async {
    try {
      final setup = _setups[setupId];
      final server = _roomServers[setupId]?.server;
      if (setup == null || server == null) return;
      final frozen = await server.freezeRoom(setup.groupId);
      final expected = RoastRuntimeManager._group(setup);
      if (bytesToHex(frozen.groupFingerprint!) !=
          bytesToHex(expected.fingerprint)) {
        throw StateError('The frozen room roster does not match the setup.');
      }
      AppLogger.info(
        '${RoastRuntimeManager._roastScope(setupId)} Room roster frozen and verified',
      );
      final snapshot = await startSetup(setup);
      _emitSnapshotValues(setupId, snapshot);
    } catch (error, stackTrace) {
      _emitRoomFailure(setupId, error, stackTrace);
    } finally {
      _freezingRooms.remove(setupId);
    }
  }

  void _emitRoomFailure(
    String setupId,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    AppLogger.error(
      '${RoastRuntimeManager._roastScope(setupId)} Room operation failed',
      error: error,
      stackTrace: stackTrace,
    );
    if (_events.isClosed) return;
    _events.add(
      RoastRuntimeFailureEvent(
        setupId,
        message: 'ROAST room failed: $error',
        interrupted: true,
        operation: 'room',
      ),
    );
  }

  void _emitSnapshotValues(String setupId, RoastRuntimeSnapshot snapshot) {
    if (_events.isClosed) return;
    _events.add(
      RoastRuntimeSnapshotEvent(
        setupId,
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
        onlineParticipantIds: snapshot.onlineParticipantIds,
        coordinatorId: snapshot.coordinatorId,
        coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
        coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
      ),
    );
  }

  Future<RoomSnapshot> _joinRoomInvite(
    RoomInvite invite,
    ECPrivateKey privateKey,
  ) {
    final endpointId = PublicKey.fromBytes(invite.coordinatorEndpointId);
    return IrohRoomEnrollmentApi.joinRoom(
      IrohClientTransportConfig(
        bootstrapAddress: EndpointAddr(
          endpointId,
          relayUrls: [for (final url in invite.relayUrls) RelayUrl.parse(url)],
          ipAddrs: invite.ipAddrs,
        ),
        pinnedServerId: endpointId,
      ),
      invite,
      (_) async => privateKey,
    );
  }
}
