import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as cl;
import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere/config.dart';
import 'package:noosphere/domain.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart' show NoosphereFlutter;
import 'package:sygnature_ng/models/group_transition.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

void main() {
  setUpAll(NoosphereFlutter.initializeNative);

  test('wallet transition policy has a canonical round trip', () {
    final policy = _policy();

    final restored = SygnatureWalletTransitionPolicy.fromBytes(
      policy.toBytes(),
    );

    expect(restored.toBytes(), policy.toBytes());
    expect(restored.noospherePolicy.kind, sygnatureWalletTransitionPolicyKind);
    expect(restored.destinationDerivationPath, [0, 6, 0, 0, 0, 0]);
    expect(restored.maxTotalFeeSats, 50000);
  });

  test('vault persists a proposal with its exact DKG details', () {
    final fixture = _TransitionFixture();
    final transition = WalletGroupTransition.proposed(
      sourceSetupId: 'source-setup',
      successorSetupId: 'successor-setup',
      proposal: fixture.proposal,
      dkgDetailsByKey: {'wallet-primary': fixture.dkgDetails},
      now: fixture.createdAt,
    );
    final vault = WalletVault(
      accounts: const [],
      nextAccountIndex: 0,
      groupTransitions: [transition],
    );

    final restored = WalletVault.fromJson(vault.toJson());

    expect(restored.groupTransitions, hasLength(1));
    expect(
      restored.groupTransitions.single.proposal.proposalHash,
      fixture.proposal.proposalHash,
    );
    expect(
      restored.groupTransitions.single.dkgDetailsByKey['wallet-primary']!
          .toBytes(),
      fixture.dkgDetails.toBytes(),
    );
  });

  test('rejects DKG details that are not authorized by the proposal', () {
    final fixture = _TransitionFixture();
    final changedDetails = NewDkgDetails(
      name: fixture.dkgDetails.name,
      description: fixture.dkgDetails.description,
      threshold: fixture.dkgDetails.threshold,
      expiry: Expiry.fromTime(
        fixture.dkgDetails.expiry.time.add(const Duration(minutes: 1)),
      ),
    );

    expect(
      () => WalletGroupTransition.proposed(
        sourceSetupId: 'source-setup',
        successorSetupId: 'successor-setup',
        proposal: fixture.proposal,
        dkgDetailsByKey: {'wallet-primary': changedDetails},
      ),
      throwsFormatException,
    );
  });

  test('runtime rejects a DKG outside the approved key plan', () async {
    final fixture = _TransitionFixture();
    final runtime = RoastRuntimeManager(RoastPersistenceFactory());
    addTearDown(runtime.close);
    final setup = RoastSetup(
      id: 'successor-setup',
      groupId: 'successor-group',
      name: 'Successor',
      role: RoastSetupRole.host,
      status: RoastSetupStatus.ready,
      threshold: 2,
      participantCount: 2,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      localCardId: 'local',
      localParticipantPrivateKeyHex: '00' * 32,
      participants: const [],
      onlineParticipantIds: const [],
      keyName: fixture.dkgDetails.name,
      createdAt: fixture.createdAt,
    );
    final wrongPlan = GroupTransitionKeyPlan(
      keyId: 'wallet-primary',
      sourceGroupKey: fixture.sourceGroupKey,
      sourceThreshold: 2,
      targetThreshold: 2,
      dkgDetailsHash: Uint8List(32),
    );

    await expectLater(
      runtime.requestDkg(
        setup,
        approvedDetails: fixture.dkgDetails,
        transitionKeyPlan: wrongPlan,
      ),
      throwsStateError,
    );
  });

  test('persists only identity approvals for the exact proposal', () {
    final fixture = _TransitionFixture();
    final transition = WalletGroupTransition.proposed(
      sourceSetupId: 'source-setup',
      successorSetupId: 'successor-setup',
      proposal: fixture.proposal,
      dkgDetailsByKey: {'wallet-primary': fixture.dkgDetails},
      now: fixture.createdAt,
    );
    final approval = GroupTransitionApproval.forProposal(
      proposal: fixture.proposal,
      participantPublicKey: fixture.retainedParticipant,
      approvedAt: fixture.createdAt.add(const Duration(minutes: 1)),
    ).sign(fixture.retainedParticipantKey);

    final approved = transition.withApproval(approval);
    final restored = WalletGroupTransition.fromJson(approved.toJson());

    expect(
      restored.signedApprovalsHexByParticipant,
      contains(fixture.retainedParticipant.hex),
    );
    expect(
      () => transition.withApproval(
        Signed(
          obj: approval.obj,
          signature: cl.SchnorrSignature.sign(
            cl.ECPrivateKey.generate(),
            approval.obj.sigHash,
          ),
        ),
      ),
      throwsFormatException,
    );
  });
}

SygnatureWalletTransitionPolicy _policy() => SygnatureWalletTransitionPolicy(
  sourceAccountId: 'source-account',
  blockchainId: 'peercoin',
  networkId: 'mainnet',
  keyId: 'wallet-primary',
  destinationDerivationPath: const [0, 6, 0, 0, 0, 0],
  maxTotalFeeSats: 50000,
  maxFeeRateSatsPerKb: 100000,
  minimumConfirmations: 6,
  maxMigrationAttempts: 2,
  sweepLateDeposits: true,
);

final class _TransitionFixture {
  _TransitionFixture() {
    retainedParticipantKey = cl.ECPrivateKey.generate();
    retainedParticipant = cl.ECCompressedPublicKey.fromPubkey(
      retainedParticipantKey.pubkey,
    );
    final second = cl.ECCompressedPublicKey.fromPubkey(
      cl.ECPrivateKey.generate().pubkey,
    );
    final replacement = cl.ECCompressedPublicKey.fromPubkey(
      cl.ECPrivateKey.generate().pubkey,
    );
    sourceGroupKey = cl.ECCompressedPublicKey.fromPubkey(
      cl.ECPrivateKey.generate().pubkey,
    );
    final sourceGroup = GroupConfig(
      id: 'source-group',
      participants: {
        Identifier.fromUint16(1): retainedParticipant,
        Identifier.fromUint16(2): second,
      },
    );
    dkgDetails = NewDkgDetails(
      name: 'successor-primary',
      description: 'sygnature transition test',
      threshold: 2,
      expiry: Expiry.fromTime(createdAt.add(const Duration(hours: 1))),
    );
    proposal = GroupTransitionProposal(
      transitionId: 'transition-1',
      sourceGroup: sourceGroup,
      successorRoomId: 'successor-group',
      coordinatorEndpointId: Uint8List(32),
      successorParticipants: [retainedParticipant, replacement],
      keyPlans: [
        GroupTransitionKeyPlan(
          keyId: 'wallet-primary',
          sourceGroupKey: sourceGroupKey,
          sourceThreshold: 2,
          targetThreshold: 2,
          dkgDetailsHash: dkgDetails.sigHash,
        ),
      ],
      migrationPolicy: _policy().noospherePolicy,
      createdAt: createdAt,
      expiresAt: createdAt.add(const Duration(days: 1)),
    );
  }

  final DateTime createdAt = DateTime.now().toUtc();
  late final cl.ECPrivateKey retainedParticipantKey;
  late final cl.ECCompressedPublicKey retainedParticipant;
  late final cl.ECCompressedPublicKey sourceGroupKey;
  late final NewDkgDetails dkgDetails;
  late final GroupTransitionProposal proposal;
}
