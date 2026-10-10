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
    final server = await _ensureRoomServer(setup);
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
    final issued = <NoosphereRoomInvite>[];
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
          NoosphereRoomInvite(
            prefix: sygnatureRoomInvitePrefix,
            invite: invite,
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

  Future<RoomSnapshot> _joinRoom(
    RoastSetup setup,
    NoosphereRoomInvite link,
  ) async {
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Validating room invite',
    );
    final invite = link.invite;
    if (invite.expectedParticipantPublicKey.hex !=
        setup.localParticipant.publicKeyHex) {
      throw const FormatException(
        'The room invite is bound to another participant key.',
      );
    }
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    invite.requirePrivateKey(privateKey);
    late final RoomSnapshot room;
    try {
      room = await _joinRoomInvite(invite, privateKey);
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
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.timeout,
          cause: error,
        ),
        stackTrace,
      );
    } on FormatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.malformedResponse,
          cause: error,
        ),
        stackTrace,
      );
    } on Object catch (error, stackTrace) {
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
    if (room.roomId != invite.roomId ||
        bytesToHex(room.coordinatorEndpointId) !=
            bytesToHex(invite.coordinatorEndpointId) ||
        room.participants.isEmpty) {
      throw const FormatException(
        'The enrollment response does not match the room invitation.',
      );
    }
    return room;
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
    if (_backupPaused) return;
    if (_roomSignerTimers.containsKey(setup.id)) return;
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setup.id)} Waiting for the frozen room; signer connection '
      'will retry in the background',
    );
    _runBackground(_connectRoomSigner(setup));
    _roomSignerTimers[setup.id] = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _runBackground(_connectRoomSigner(setup)),
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

  Future<IrohServer> _ensureRoomServer(RoastSetup setup) async {
    final existing = _roomServers[setup.id];
    if (existing != null) return existing;
    AppLogger.info(
      '${RoastRuntimeManager._irohScope(setup.id)} Starting room coordinator',
    );
    await NoosphereFlutter.initialize();
    final persistence = await _persistenceFactory.open();
    final secretKey = await _irohSecretKey(setup);
    final rooms = await RoomManager.open(
      coordinatorEndpointId: secretKey.publicKey.asBytes(),
      persistence: persistence.roomPersistence(setup.id),
    );
    final server = await IrohServer.start(
      IrohConfig(
        server: ServerConfig(
          group: RoastRuntimeManager._bootstrapGroup(setup.groupId),
        ),
        maxStreamsPerConnection: defaultServerMaxStreamsPerConnection,
      ),
      secretKey: secretKey,
      persistence: persistence.serverPersistence(setup.id),
      rooms: rooms,
    );
    _roomServers[setup.id] = server;
    unawaited(_serveRoomServer(setup.id, server));
    _roomSubscriptions[setup.id] = rooms.snapshots.listen(
      (room) => _onRoomSnapshot(setup.id, room),
      onError: (Object error) => _emitRoomFailure(setup.id, error),
    );
    for (final room in await rooms.getRooms()) {
      _onRoomSnapshot(setup.id, room);
    }
    AppLogger.info(
      '${RoastRuntimeManager._irohScope(setup.id)} Room coordinator started',
    );
    return server;
  }

  Future<void> _serveRoomServer(String setupId, IrohServer server) async {
    try {
      await server.serve();
    } catch (error, stackTrace) {
      if (identical(_roomServers[setupId], server)) {
        _emitRoomFailure(setupId, error, stackTrace);
      }
    }
  }

  void _onRoomSnapshot(String setupId, RoomSnapshot room) {
    _emitRoomEnrollmentValues(setupId, room);
    if (room.lifecycle != RoomLifecycle.enrolling ||
        !room.isFull ||
        !_freezingRooms.add(setupId)) {
      return;
    }
    AppLogger.info(
      '${RoastRuntimeManager._roastScope(setupId)} Room is full; freezing roster',
    );
    _runBackground(_freezeRoomAndStartSigner(setupId));
  }

  void _emitRoomEnrollmentValues(String setupId, RoomSnapshot room) {
    if (_events.isClosed) return;
    _events.add(
      RoastRuntimeEnrollmentEvent(
        setupId,
        invitations: [
          for (final invite in room.invites)
            RoastRuntimeInvitationEnrollment(
              participantPublicKeyHex: invite.expectedParticipantPublicKey.hex,
              status: switch (invite.status) {
                RoomInviteStatus.pending => RoastInvitationServerStatus.pending,
                RoomInviteStatus.used => RoastInvitationServerStatus.used,
                RoomInviteStatus.revoked => RoastInvitationServerStatus.revoked,
                RoomInviteStatus.expired => RoastInvitationServerStatus.expired,
              },
              usedAt: invite.usedAt,
            ),
        ],
        participants: [
          for (final participant in room.participants)
            RoastRuntimeParticipantEnrollment(
              participantPublicKeyHex: participant.publicKey.hex,
              enrolledAt: participant.enrolledAt,
            ),
        ],
      ),
    );
  }

  Future<void> _freezeRoomAndStartSigner(String setupId) async {
    try {
      final setup = _setups[setupId];
      final server = _roomServers[setupId];
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
        operation: RoastRuntimeOperation.room,
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
  ) => IrohRoomEnrollmentApi.joinRoom(invite, (_) async => privateKey);
}
