import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  testWidgets('creates a pending ROAST wallet from first launch', (
    tester,
  ) async {
    final runtime = _FakeRoastRuntime();
    final controller = WalletController(
      MemoryWalletRepository(),
      roastRuntime: runtime,
      roastKeyService: _FakeRoastKeyService(),
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('ROAST shared wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Host coordinator'), findsOneWidget);
    expect(find.textContaining('This device must stay online'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-roast-draft')));
    await tester.pumpAndSettle();

    expect(find.text('Shared wallet'), findsWidgets);
    expect(find.text('ROAST · 2 of 2'), findsWidgets);
    expect(find.text('Create signer invitations'), findsOneWidget);
    expect(find.text('BALANCE'), findsNothing);

    await tester.tap(find.byKey(const Key('create-roast-invitations')));
    await tester.pumpAndSettle();
    expect(find.text('Signer 2 of 2'), findsOneWidget);
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
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

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
}

final class _FakeRoastKeyService extends RoastKeyService {
  int _id = 0;

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
}

final class _FakeRoastRuntime implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  @override
  Future<RoastRuntimeSnapshot> startSetup(setup) => throw UnimplementedError();

  @override
  Future<RoastRoomCreation> createRoom(setup) => throw UnimplementedError();

  @override
  Future<RoastRuntimeSnapshot> joinRoom(setup, String encodedInvite) =>
      throw UnimplementedError();

  @override
  Future<void> requestDkg(setup) => throw UnimplementedError();

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
    List<int> derivationPath,
  ) => throw UnimplementedError();

  @override
  Future<void> requestTransactionSignatures(
    setup,
    RoastSigningProposal proposal,
  ) => throw UnimplementedError();

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
