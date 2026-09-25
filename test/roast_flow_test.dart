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
    expect(find.text('Copy participant card'), findsOneWidget);
    expect(find.text('BALANCE'), findsNothing);

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
}

final class _FakeRoastRuntime implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  @override
  Future<RoastRuntimeSnapshot> startSetup(setup) => throw UnimplementedError();

  @override
  Future<void> requestDkg(setup) => throw UnimplementedError();

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) =>
      throw UnimplementedError();

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) =>
      throw UnimplementedError();

  @override
  Future<String> requestTransactionSignatures(
    setup,
    transaction,
    List<int> derivationPath,
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
  Future<void> close() => _events.close();
}
