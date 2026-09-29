import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere/domain.dart'
    show GroupTransitionKeyPlan, NewDkgDetails;
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';
import 'package:sygnature_ng/ui/app_theme.dart';

void main() {
  testWidgets('adds a pending ROAST wallet after personal wallet setup', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final runtime = _FakeRoastRuntime();
    final repository = MemoryWalletRepository()
      ..value = WalletVault(
        mnemonic: 'local recovery phrase',
        languageId: 'english',
        mnemonicWordCount: 12,
        accounts: [
          WalletAccount(
            id: 'wallet-0',
            name: 'Main wallet',
            accountIndex: 0,
            blockchainId: 'peercoin',
            networkId: 'mainnet',
            derivationState: WalletDerivationState.ready,
            derivationPath: "m/86'/6'/0'/0/0",
            address: 'pc1ppersonal',
            privateKeyHex: 'personal-private-key',
            createdAt: DateTime.utc(2026),
          ),
        ],
        nextAccountIndex: 1,
      );
    final controller = WalletController(
      repository,
      roastRuntime: runtime,
      roastKeyService: _FakeRoastKeyService(),
      networkServiceFactory: (_) async => null,
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('LOCAL'), findsOneWidget);
    expect(find.text('ROAST'), findsNothing);

    await tester.tap(find.byTooltip('Add sub-wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ROAST shared wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Host coordinator'), findsOneWidget);
    expect(find.textContaining('This device must stay online'), findsOneWidget);
    expect(find.byKey(const Key('roast-participant-name')), findsNothing);
    expect(find.byKey(const Key('roast-setup-back')), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-roast-draft')));
    await tester.pumpAndSettle();

    final participantAlias =
        controller.roastSetups.single.localParticipant.name;
    expect(participantAlias, isNot('This device'));
    expect(participantAlias, isNotEmpty);
    expect(find.text('Shared wallet'), findsWidgets);
    expect(find.text('ROAST · 2 of 2'), findsWidgets);
    expect(find.text('LOCAL'), findsOneWidget);
    expect(find.text('ROAST · HOST'), findsOneWidget);
    expect(find.text('Signer 2 of 2'), findsOneWidget);
    expect(find.byKey(const Key('roast-signer-name-0')), findsOneWidget);
    final remoteAlias = tester
        .widget<TextFormField>(find.byKey(const Key('roast-signer-name-0')))
        .initialValue!;
    expect(remoteAlias, isNotEmpty);
    expect(remoteAlias, isNot(participantAlias));
    expect(find.byKey(const Key('roast-invite-wizard-back')), findsOneWidget);
    expect(find.text('BALANCE'), findsNothing);

    await tester.tap(find.byKey(const Key('roast-invite-wizard-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-roast-invitations')), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-roast-invitations')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('roast-signer-name-0')),
      'Second signer',
    );
    await tester.enterText(
      find.byKey(const Key('roast-signer-public-key-0')),
      '02${'33' * 32}',
    );
    await tester.tap(find.byKey(const Key('roast-invite-wizard-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Create invitations'), findsOneWidget);
    await tester.tap(find.byKey(const Key('roast-invite-wizard-back')));
    await tester.pumpAndSettle();
    expect(find.text('Second signer'), findsOneWidget);
    await tester.tap(find.byKey(const Key('roast-invite-wizard-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-roast-invitations')), findsOneWidget);

    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Wallet settings'));
    await tester.pumpAndSettle();
    expect(find.text('Delete wallet'), findsOneWidget);
    await tester.tap(find.text('Delete wallet'));
    await tester.pumpAndSettle();
    expect(find.textContaining('local signer identity'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pastes and validates a member invitation immediately', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final keyService = _FakeRoastKeyService();
    final controller = WalletController(
      MemoryWalletRepository(),
      roastRuntime: _FakeRoastRuntime(),
      roastKeyService: keyService,
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await controller.createRoastSetupDraft(
      role: RoastSetupRole.member,
      walletName: 'Member wallet',
      participantName: 'Member',
      threshold: 2,
      participantCount: 2,
      network: PeercoinNetworks.mainnet,
    );

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': '  invalid-invite  '}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.text('Paste invite from clipboard'));
    await tester.pumpAndSettle();

    expect(keyService.appliedInvitation, 'invalid-invite');
    expect(find.textContaining('Invalid test invitation'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opens a participant-bound invitation from an app link', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final keyService = _FakeRoastKeyService()..acceptInvitation = true;
    final runtime = _FakeRoastRuntime()
      ..joinSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const [],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: null,
        pendingDkgProposalHex: null,
      );
    final controller = WalletController(
      MemoryWalletRepository(),
      roastRuntime: runtime,
      roastKeyService: keyService,
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await controller.createRoastSetupDraft(
      role: RoastSetupRole.member,
      walletName: 'Member wallet',
      participantName: 'Member',
      threshold: 2,
      participantCount: 2,
      network: PeercoinNetworks.mainnet,
    );
    final participantPublicKey =
        controller.roastSetups.single.localParticipant.publicKeyHex;
    final invitation =
        '${RoastExchangeCodec.uriScheme}:'
        '${base64Url.encode(utf8.encode(jsonEncode({'version': RoastExchangeCodec.version, 'type': 'room-invitation', 'setupName': 'Linked wallet', 'threshold': 2, 'participantCount': 2, 'participantPublicKeyHex': participantPublicKey})))}';

    await tester.pumpWidget(
      SygnatureApp(
        controllerFactory: () async => controller,
        incomingLinks: Stream.value(Uri.parse(invitation)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Join shared wallet?'), findsOneWidget);
    expect(find.text('Linked wallet'), findsOneWidget);
    expect(find.text('2 of 2 signers required'), findsOneWidget);

    await tester.tap(find.byKey(const Key('roast-invite-link-join')));
    await tester.pumpAndSettle();

    expect(keyService.appliedInvitation, invitation);
    expect(find.text('Could not join shared wallet'), findsNothing);
    expect(controller.roastSetups.single.status, RoastSetupStatus.ready);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('reuses a retained signer identity from a transition app link', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final keyService = _FakeRoastKeyService()..acceptInvitation = true;
    final runtime = _FakeRoastRuntime()
      ..startSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['01'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: 'group-key',
        pendingDkgProposalHex: null,
      )
      ..joinSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const [],
        coordinatorId: 'successor-coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: null,
        pendingDkgProposalHex: null,
      );
    final controller = WalletController(
      MemoryWalletRepository()..value = _activeRoastVault(),
      roastRuntime: runtime,
      roastKeyService: keyService,
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    final source = controller.roastSetups.single;
    final invitation =
        '${RoastExchangeCodec.uriScheme}:'
        '${base64Url.encode(utf8.encode(jsonEncode({'version': RoastExchangeCodec.version, 'type': 'room-invitation', 'setupName': 'Successor wallet', 'threshold': 2, 'participantCount': 2, 'participantPublicKeyHex': source.localParticipant.publicKeyHex, 'transitionSourceGroupId': source.groupId})))}';

    await tester.pumpWidget(
      SygnatureApp(
        controllerFactory: () async => controller,
        incomingLinks: Stream.value(Uri.parse(invitation)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Join shared wallet?'), findsOneWidget);
    expect(find.textContaining('existing signer identity'), findsOneWidget);
    await tester.tap(find.byKey(const Key('roast-invite-link-join')));
    await tester.pumpAndSettle();

    expect(controller.roastSetups, hasLength(2));
    final successor = controller.roastSetups.singleWhere(
      (setup) => setup.id != source.id,
    );
    expect(successor.localCardId, source.localCardId);
    expect(
      successor.localParticipantPrivateKeyHex,
      source.localParticipantPrivateKeyHex,
    );
    expect(
      successor.localParticipant.publicKeyHex,
      source.localParticipant.publicKeyHex,
    );
    expect(keyService.appliedInvitation, invitation);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('shows healthy and unavailable ROAST swarm states', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final runtime = _FakeRoastRuntime()
      ..startSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['01'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: null,
        pendingDkgProposalHex: null,
      );
    final repository = MemoryWalletRepository()..value = _finalizedRoastVault();
    final controller = WalletController(
      repository,
      roastRuntime: runtime,
      networkServiceFactory: (_) async => null,
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('Key setup required'), findsOneWidget);
    expect(find.text('Unavailable'), findsNothing);
    var health = find.byKey(const Key('roast-swarm-health-healthy'));
    expect(health, findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: health,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .color,
      AppColors.success,
    );

    final setup = controller.roastSetups.single;
    runtime.emit(
      RoastRuntimeDkgEvent(
        setup.id,
        proposalHex: 'proposal',
        name: setup.keyName,
        threshold: setup.threshold,
        creator: setup.hostParticipantId!,
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(setup),
        stage: 'waiting',
        rejected: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('creator This device (you)'), findsOneWidget);
    expect(
      find.textContaining('creator ${setup.hostParticipantId}'),
      findsNothing,
    );
    final priorityRequests = find.byKey(const Key('roast-priority-requests'));
    final dashboardHeader = find.byKey(const Key('wallet-dashboard-header'));
    expect(priorityRequests, findsOneWidget);
    expect(find.byKey(const Key('roast-dkg-request-card')), findsOneWidget);
    expect(find.text('Approve key creation'), findsOneWidget);
    expect(
      tester.getTopLeft(priorityRequests).dy,
      lessThan(tester.getTopLeft(dashboardHeader).dy),
    );
    expect(
      tester.getTopLeft(priorityRequests).dy,
      lessThan(tester.getTopLeft(health).dy),
    );

    runtime.emit(
      RoastRuntimeDkgEvent(
        setup.id,
        proposalHex: 'proposal',
        name: setup.keyName,
        threshold: setup.threshold,
        creator: setup.hostParticipantId!,
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(setup),
        stage: 'round1',
        rejected: false,
        completedParticipantIds: const ['02'],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Waiting for DKG approvals · 1 of 2 confirmed'), findsOne);

    runtime.emit(
      RoastRuntimeDkgEvent(
        setup.id,
        proposalHex: 'proposal',
        name: setup.keyName,
        threshold: setup.threshold,
        creator: setup.hostParticipantId!,
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(setup),
        stage: 'round2',
        rejected: false,
        completedParticipantIds: const ['01', '02'],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('All signers approved · generating shared key…'),
      findsOne,
    );

    runtime.emit(
      RoastRuntimeSnapshotEvent(
        'setup',
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const [],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
      ),
    );
    await tester.pumpAndSettle();

    health = find.byKey(const Key('roast-swarm-health-unavailable'));
    expect(health, findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: health,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .color,
      AppColors.danger,
    );
    expect(find.text('null'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hides the ROAST derivation path from account details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = MemoryWalletRepository()..value = _activeRoastVault();
    final controller = WalletController(
      repository,
      networkServiceFactory: (_) async => null,
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account details'), findsOneWidget);
    expect(find.text('Derivation path'), findsNothing);
    expect(find.text('R/0/6/0/0/0/0'), findsNothing);
  });

  testWidgets('reviews the exact text before requesting message signatures', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = MemoryWalletRepository()..value = _activeRoastVault();
    final controller = WalletController(
      repository,
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    final signMessage = find.byKey(const Key('sign-roast-message'));
    await tester.ensureVisible(signMessage);
    await tester.tap(signMessage);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('roast-signed-message-field')),
      'Release 1.0\nexact text ',
    );
    await tester.enterText(
      find.byKey(const Key('roast-message-note-field')),
      'Please verify this release.',
    );
    await tester.tap(find.byKey(const Key('review-message-signature')));
    await tester.pumpAndSettle();

    expect(find.text('EXACT TEXT TO SIGN'), findsOneWidget);
    expect(find.text('Release 1.0\nexact text '), findsOneWidget);
    expect(
      find.text('NOTE TO SIGNERS · AUTHENTICATED, NOT SIGNED TEXT'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('request-message-signatures')), findsOneWidget);
  });

  testWidgets('opens signer-group changes from active wallet settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final runtime = _FakeRoastRuntime()
      ..startSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['01'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: 'group-key',
        pendingDkgProposalHex: null,
      );
    final controller = WalletController(
      MemoryWalletRepository()..value = _activeRoastVault(),
      roastRuntime: runtime,
      roastKeyService: _FakeRoastKeyService(),
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Wallet settings'));
    await tester.pumpAndSettle();
    expect(find.text('Change signers'), findsOneWidget);
    await tester.tap(find.text('Change signers'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('transition-wallet-name')), findsOneWidget);
    expect(find.text('This device (this device)'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('Bob')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('transition-add-signer')), findsOneWidget);
    expect(find.textContaining('balance is not moved automatically'), findsOne);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('can close a pending message request and view its result later', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final runtime = _FakeRoastRuntime()
      ..startSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['02'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: 'group-key',
        pendingDkgProposalHex: null,
      );
    final controller = WalletController(
      MemoryWalletRepository()..value = _activeRoastVault(),
      roastRuntime: runtime,
      roastKeyService: _FakeRoastKeyService(),
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    final signMessage = find.byKey(const Key('sign-roast-message'));
    await tester.ensureVisible(signMessage);
    await tester.tap(signMessage);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('roast-signed-message-field')),
      'Hello world',
    );
    await tester.tap(find.byKey(const Key('review-message-signature')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('request-message-signatures')));
    await tester.pump();

    final close = find.byKey(const Key('close-message-signing'));
    expect(close, findsOneWidget);
    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Sign message with ROAST'), findsNothing);
    expect(find.text('Signing message…'), findsOneWidget);
    expect(find.text('Message signature requested'), findsOneWidget);

    runtime.emit(
      RoastRuntimeMessageSigningResultEvent(
        'setup',
        requestIdHex: 'cc' * 16,
        creator: '02',
        signedMessage: RoastSignedMessage(
          text: 'Hello world',
          publicKeyHex: '11' * 32,
          signatureHex: '22' * 64,
          encoded: '{"format":"noosphere-signed-message"}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final viewResult = find.byKey(const Key('view-signed-message'));
    expect(viewResult, findsOneWidget);
    await tester.ensureVisible(viewResult);
    await tester.tap(viewResult);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Message signed'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Hello world'),
      ),
      findsOneWidget,
    );
    expect(find.text('{"format":"noosphere-signed-message"}'), findsOneWidget);
  });

  testWidgets('shows exact signed text separately from the request note', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final runtime = _FakeRoastRuntime()
      ..startSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['01'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: 'group-key',
        pendingDkgProposalHex: null,
      );
    final controller = WalletController(
      MemoryWalletRepository()..value = _activeRoastVault(),
      roastRuntime: runtime,
      roastKeyService: _FakeRoastKeyService(),
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    runtime.emit(
      RoastRuntimeSigningRequestEvent(
        'setup',
        request: RoastSigningRequest(
          idHex: 'aa' * 16,
          proposalHex: 'bb',
          creator: '01',
          expiry: DateTime.now().add(const Duration(minutes: 5)),
          kind: RoastSigningRequestKind.message,
          hasTransactionMetadata: false,
          usesSupportedSighash: false,
          usesExpectedTaprootTweak: false,
          usesUntweakedKey: true,
          status: 'waiting',
          inputSats: 0,
          transactionInputCount: 0,
          signedInputIndexes: const [],
          previousOutputScripts: const [],
          inputOutpoints: const [],
          outputs: const [],
          masterGroupKeys: const ['group-key'],
          derivationPaths: const [[]],
          message: 'Check the published release.',
          signedMessageText: 'Release 1.0\nSHA256: abc123',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MESSAGE SIGNATURE · ACTION REQUIRED'), findsOneWidget);
    expect(find.text('EXACT MESSAGE TO SIGN'), findsOneWidget);
    expect(find.text('Release 1.0\nSHA256: abc123'), findsOneWidget);
    expect(find.text('REQUEST NOTE · AUTHENTICATED'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('roast-signing-request-message')),
        matching: find.text('Check the published release.'),
      ),
      findsOneWidget,
    );
    expect(find.text('Network fee'), findsNothing);
  });
}

WalletVault _activeRoastVault() {
  final vault = _finalizedRoastVault();
  return vault.copyWith(
    accounts: [
      vault.accounts.single.copyWith(
        derivationState: WalletDerivationState.ready,
        address: 'pc1proast',
        derivationPath: 'R/0/6/0/0/0/0',
      ),
    ],
    roastSetups: [
      vault.roastSetups.single.copyWith(
        status: RoastSetupStatus.active,
        groupKeyHex: 'group-key',
      ),
    ],
  );
}

WalletVault _finalizedRoastVault() => WalletVault(
  accounts: [
    WalletAccount(
      id: 'roast-wallet',
      name: 'Shared wallet',
      accountIndex: 0,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      derivationState: WalletDerivationState.pending,
      keySource: WalletKeySource.roast,
      sourceId: 'setup',
      keyId: 'group-g1',
      createdAt: DateTime.utc(2026),
    ),
  ],
  nextAccountIndex: 0,
  roastSetups: [
    RoastSetup(
      id: 'setup',
      groupId: 'group',
      name: 'Family wallet',
      role: RoastSetupRole.host,
      status: RoastSetupStatus.ready,
      threshold: 2,
      participantCount: 2,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      localCardId: 'local-card',
      localParticipantPrivateKeyHex: '11' * 32,
      participants: [
        RoastParticipant(
          cardId: 'remote-card',
          name: 'Bob',
          identifierHex: '01',
          publicKeyHex: '02${'11' * 32}',
        ),
        RoastParticipant(
          cardId: 'local-card',
          name: 'This device',
          identifierHex: '02',
          publicKeyHex: '03${'22' * 32}',
        ),
      ],
      onlineParticipantIds: const [],
      keyName: 'group-g1',
      createdAt: DateTime.utc(2026),
      usesRoomEnrollment: true,
      hostParticipantId: '02',
      coordinatorId: 'coordinator',
      groupFingerprintHex: 'aa' * 32,
    ),
  ],
);

final class _FakeRoastKeyService extends RoastKeyService {
  int _id = 0;
  String? appliedInvitation;
  bool acceptInvitation = false;

  @override
  RoastParticipantMaterial generateParticipant() => RoastParticipantMaterial(
    cardId: 'local-card',
    privateKeyHex: '11' * 32,
    publicKeyHex: '02${'22' * 32}',
  );

  @override
  String newSetupId() => 'setup-${_id++}';

  @override
  String normalizeParticipantPublicKey(String value) => value.trim();

  @override
  RoastDerivedAddress deriveAddress({
    required String groupKeyHex,
    required int threshold,
    required network,
    required int accountIndex,
    String? pathLabel,
  }) => RoastDerivedAddress(
    path: const [0, 6, 0, 0, 0, 0],
    pathLabel: 'R/0/6/0/0/0/0',
    address: 'pc1proast',
    internalKeyHex: 'internal-key',
  );

  @override
  RoastInvitation applyInvitation(RoastSetup draft, String invitation) {
    appliedInvitation = invitation;
    if (acceptInvitation) {
      return RoastInvitation(
        setup: draft.copyWith(status: RoastSetupStatus.ready),
        roomInvite: 'room-invite',
      );
    }
    throw const FormatException('Invalid test invitation.');
  }
}

final class _FakeRoastRuntime implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  RoastRuntimeSnapshot? startSnapshot;
  RoastRuntimeSnapshot? joinSnapshot;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  void emit(RoastRuntimeEvent event) => _events.add(event);

  @override
  Future<RoastRuntimeSnapshot> startSetup(setup) async =>
      startSnapshot ?? (throw UnimplementedError());

  @override
  Future<RoastRoomCreation> createRoom(
    setup, {
    Future<void> Function(RoastRoomCreation room)? beforeInvitations,
  }) => throw UnimplementedError();

  @override
  Future<RoastRuntimeSnapshot> joinRoom(setup, String encodedInvite) async =>
      joinSnapshot ?? (throw UnimplementedError());

  @override
  Future<void> requestDkg(
    setup, {
    NewDkgDetails? approvedDetails,
    GroupTransitionKeyPlan? transitionKeyPlan,
  }) => throw UnimplementedError();

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) =>
      throw UnimplementedError();

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) =>
      throw UnimplementedError();

  @override
  RoastSigningProposal createTransactionSigningProposal(
    setup,
    transaction,
    List<int> derivationPath, {
    String message = '',
  }) => throw UnimplementedError();

  @override
  RoastSigningProposal createMessageSigningProposal(
    setup,
    String text, {
    String message = '',
  }) => RoastSigningProposal(
    idHex: 'cc' * 16,
    proposalHex: 'dd',
    expiry: DateTime.now().add(const Duration(minutes: 1)),
  );

  @override
  Future<void> requestSignatures(setup, RoastSigningProposal proposal) async {}

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) =>
      throw UnimplementedError();

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) =>
      throw UnimplementedError();

  @override
  Future<void> stopSetup(String setupId) async {}

  @override
  Future<void> deleteSetup(String setupId) async {}

  @override
  Future<void> close() => _events.close();
}
