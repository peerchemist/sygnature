import 'dart:convert';
import 'dart:io';

import 'package:coinlib/coinlib.dart' as cl;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noosphere_client/testing.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_server/noosphere_server.dart';
import 'package:noosphere_server/testing.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

import '../test/fixtures/wallet_backup_fixture.dart';

const _isolatedAndroidPackage =
    'network.noosphere.sygnature.roomenrollmenttest';
const _runTests = bool.fromEnvironment('RUN_ROOM_ENROLLMENT_SECURITY_TESTS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(NoosphereFlutter.initializeNative);

  _deviceTest(
    'expired and wrong-room invitations do not mutate rooms',
    () async {
      final manager = await RoomManager.open(
        coordinatorEndpointId: Uint8List(32)..last = 1,
        persistence: InMemoryRoomPersistence(),
      );
      addTearDown(manager.close);
      final issuedAt = DateTime.utc(2030);
      final participantKey = syntheticPrivateKey(9);
      final participantPublicKey = cl.ECCompressedPublicKey.fromPubkey(
        participantKey.pubkey,
      );
      for (final roomId in ['room-a', 'room-b']) {
        await manager.createRoom(
          roomId: roomId,
          expectedParticipants: 2,
          threshold: 2,
        );
      }
      final expired = await manager.issueRoomInvite(
        roomId: 'room-a',
        expectedParticipantPublicKey: participantPublicKey,
        expiresAt: issuedAt.add(const Duration(minutes: 1)),
        now: issuedAt,
      );
      await expectLater(
        manager.beginEnrollment(
          invite: expired,
          participantPublicKey: participantPublicKey,
          now: issuedAt.add(const Duration(minutes: 2)),
        ),
        throwsA(_roomFailure(RoomFailureCode.expiredInvite)),
      );

      final afterExpiry = issuedAt.add(const Duration(minutes: 2));
      final valid = await manager.issueRoomInvite(
        roomId: 'room-a',
        expectedParticipantPublicKey: participantPublicKey,
        expiresAt: issuedAt.add(const Duration(days: 1)),
        now: afterExpiry,
      );
      final wrongRoom = RoomInvite(
        roomId: 'room-b',
        inviteId: valid.inviteId,
        token: valid.token,
        expectedParticipantPublicKey: valid.expectedParticipantPublicKey,
        coordinatorEndpointId: valid.coordinatorEndpointId,
        expiresAt: valid.expiresAt,
      );
      await expectLater(
        manager.beginEnrollment(
          invite: wrongRoom,
          participantPublicKey: participantPublicKey,
          now: afterExpiry,
        ),
        throwsA(_roomFailure(RoomFailureCode.unknownInvite)),
      );

      for (final roomId in ['room-a', 'room-b']) {
        expect((await manager.getRoom(roomId)).participants, isEmpty);
      }
    },
  );

  _deviceTest(
    'frozen enrollment resumes before DKG and completes after storage restart',
    () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final setupId = 'room-restart-$suffix';
      final groupId = 'room-restart-group-$suffix';
      final fixture = WalletBackupFixture(
        roomHost: true,
        setupId: setupId,
        groupId: groupId,
      );
      final cipherKey = Uint8List.fromList(List.filled(32, 17));
      final firstFactory = RoastPersistenceFactory(cipherKey: cipherKey);
      final coordinatorId = PublicKey.fromZ32(fixture.setup.coordinatorId!);
      final manager = await RoomManager.open(
        coordinatorEndpointId: coordinatorId.asBytes(),
        persistence: (await firstFactory.open()).roomPersistence(setupId),
      );
      await manager.createRoom(
        roomId: groupId,
        expectedParticipants: 2,
        threshold: 2,
      );
      final keys = [syntheticPrivateKey(9), syntheticPrivateKey(10)];
      for (final key in keys) {
        final invite = await manager.issueRoomInvite(
          roomId: groupId,
          expectedParticipantPublicKey: cl.ECCompressedPublicKey.fromPubkey(
            key.pubkey,
          ),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        );
        await RoomEnrollmentClient(manager).joinRoom(invite, (_) async => key);
      }
      final frozen = await manager.freezeRoom(groupId);
      final hostPublicKey = cl.ECCompressedPublicKey.fromPubkey(
        keys.first.pubkey,
      );
      final participants = [
        for (final (index, participant) in frozen.participants.indexed)
          RoastParticipant(
            cardId: participant.publicKey == hostPublicKey ? 'host' : 'member',
            name: 'Signer ${index + 1}',
            identifierHex: participant.identifier!.toString(),
            publicKeyHex: participant.publicKey.hex,
          ),
      ];
      final setup = RoastSetup(
        id: setupId,
        groupId: groupId,
        name: 'Restart test',
        role: RoastSetupRole.host,
        status: RoastSetupStatus.ready,
        threshold: 2,
        participantCount: 2,
        blockchainId: 'peercoin',
        networkId: 'testnet',
        localCardId: 'host',
        localParticipantPrivateKeyHex: cl.bytesToHex(keys.first.data),
        participants: participants,
        keyName: roastKeyName(groupId),
        createdAt: DateTime.now().toUtc(),
        irohIdentityIndex: fixture.setup.irohIdentityIndex,
        usesRoomEnrollment: true,
        hostParticipantId: participants
            .singleWhere((participant) => participant.cardId == 'host')
            .identifierHex,
        coordinatorId: coordinatorId.toZ32(),
        groupFingerprintHex: cl.bytesToHex(frozen.groupFingerprint!),
      );
      expect(
        await (await firstFactory.open()).dkgSecretStorage(setupId).loadAll(),
        isEmpty,
      );
      await manager.close();
      await Hive.close();

      final reopenedFactory = RoastPersistenceFactory(cipherKey: cipherKey);
      final runtime = RoastRuntimeManager(
        reopenedFactory,
        getWalletBip39Seed: () =>
            CoinlibWalletKeyService.mnemonicToSeed(fixture.vault.mnemonic!),
      );
      final cosigner = await NoosphereWorker.startNativeForTesting();
      try {
        final restored = await runtime
            .startSetup(setup)
            .timeout(const Duration(seconds: 30));
        expect(restored.connected, isTrue);
        expect(restored.signerRunning, isTrue);
        expect(restored.groupKeyHex, isNull);
        expect(restored.pendingDkgProposalHex, isNull);
        expect(restored.pendingDkgName, isNull);
        expect(
          await (await reopenedFactory.open())
              .dkgSecretStorage(setupId)
              .loadAll(),
          isEmpty,
        );
        var coordinatorRelayUrls = restored.coordinatorRelayUrls;
        var coordinatorIpAddrs = restored.coordinatorIpAddrs;
        if (coordinatorRelayUrls.isEmpty && coordinatorIpAddrs.isEmpty) {
          final reachable = await _nextEvent<RoastRuntimeSnapshotEvent>(
            runtime.events,
            (event) =>
                event.setupId == setupId &&
                (event.coordinatorRelayUrls.isNotEmpty ||
                    event.coordinatorIpAddrs.isNotEmpty),
          ).timeout(const Duration(seconds: 20));
          coordinatorRelayUrls = reachable.coordinatorRelayUrls;
          coordinatorIpAddrs = reachable.coordinatorIpAddrs;
        }

        final member = participants.singleWhere(
          (participant) => participant.cardId == 'member',
        );
        final memberSetupId = '$setupId-member';
        final memberProposal = _nextEvent<WorkerDkgEvent>(
          cosigner.events,
          (event) => event.setupId == memberSetupId && !event.rejected,
        );
        final hostKey = _nextEvent<RoastRuntimeKeyEvent>(
          runtime.events,
          (event) => event.setupId == setupId,
        );
        final memberKey = _nextEvent<WorkerKeyUpdatedEvent>(
          cosigner.events,
          (event) => event.setupId == memberSetupId,
        );
        final bothOnline = _nextEvent<RoastRuntimeSnapshotEvent>(
          runtime.events,
          (event) =>
              event.setupId == setupId &&
              event.onlineParticipantIds.length == participants.length - 1,
        );
        await cosigner.startSetup(
          setupId: memberSetupId,
          client: ClientNodeOptions(
            clientConfig: ClientConfig(
              group: frozen.groupConfig!,
              id: Identifier.fromHex(member.identifierHex),
            ),
            bootstrapAddress: EndpointAddr(
              PublicKey.fromZ32(restored.coordinatorId!),
              relayUrls: [
                for (final relay in coordinatorRelayUrls) RelayUrl.parse(relay),
              ],
              ipAddrs: coordinatorIpAddrs,
            ),
            pinnedServerId: PublicKey.fromZ32(restored.coordinatorId!),
            storage: InMemoryClientStorage(),
            getPrivateKey: (_) async => keys.last,
          ),
        );
        await bothOnline.timeout(const Duration(seconds: 20));
        await runtime.requestDkg(setup);
        final proposal = await memberProposal.timeout(
          const Duration(seconds: 20),
        );
        await cosigner.acceptDkg(memberSetupId, proposal.status);
        final completed = await Future.wait([
          hostKey.timeout(const Duration(seconds: 30)),
          memberKey.timeout(const Duration(seconds: 30)),
        ]);
        expect(
          (completed.first as RoastRuntimeKeyEvent).groupKeyHex,
          (completed.last as WorkerKeyUpdatedEvent).key.groupKeyHex,
        );
      } finally {
        await runtime.close();
        await cosigner.close();
        await reopenedFactory.deleteSetupData(setupId);
        await Hive.close();
      }
    },
    timeout: const Duration(minutes: 3),
  );
}

Matcher _roomFailure(RoomFailureCode code) =>
    isA<RoomException>().having((error) => error.code, 'code', code);

Future<T> _nextEvent<T>(
  Stream<Object> events,
  bool Function(T event) matches,
) => events.where((event) => event is T).cast<T>().firstWhere(matches);

void _deviceTest(
  String description,
  Future<void> Function() body, {
  Duration timeout = const Duration(minutes: 1),
}) {
  testWidgets(
    description,
    (_) async {
      await _expectIsolatedAndroidPackage();
      await body();
    },
    skip: !_runTests,
    timeout: Timeout(timeout),
  );
}

Future<void> _expectIsolatedAndroidPackage() async {
  expect(defaultTargetPlatform, TargetPlatform.android);
  final commandLine = await File('/proc/self/cmdline').readAsBytes();
  final terminator = commandLine.indexOf(0);
  expect(
    utf8.decode(
      commandLine.sublist(0, terminator < 0 ? commandLine.length : terminator),
    ),
    _isolatedAndroidPackage,
    reason: 'Run with ORG_GRADLE_PROJECT_roomEnrollmentVerification=true.',
  );
}
