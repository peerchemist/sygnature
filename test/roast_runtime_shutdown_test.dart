import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/services/wallet_backup_service.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

import 'fixtures/wallet_backup_fixture.dart';

final class _FailingShutdown implements RoastRuntime {
  final _events = StreamController<RoastRuntimeEvent>.broadcast();
  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;
  @override
  Future<void> stopSetup(String setupId) async =>
      throw const NoosphereWorkerException(
        'host_timeout',
        'SECRET-WORKER-MESSAGE',
      );
  @override
  Future<T> withPausedForBackup<T>(Future<T> Function() snapshot) async {
    await stopSetup('synthetic');
    return snapshot();
  }

  @override
  Future<void> close() => _events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(NoosphereFlutter.initializeNative);

  test(
    'real shutdown failure aborts export with a safe actionable error',
    () async {
      final fixture = WalletBackupFixture();
      final repository = MemoryWalletRepository();
      await repository.save(
        fixture.vault.copyWith(
          roastSetups: [
            fixture.setup.copyWith(requiresBackupReconciliation: true),
          ],
        ),
      );
      final controller = WalletController(
        repository,
        roastRuntime: _FailingShutdown(),
        backupService: WalletBackupService(repository, null),
      );
      addTearDown(controller.dispose);
      await controller.load();
      final before = repository.value;
      await expectLater(
        controller.exportEncryptedBackup('12345678'),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.message,
                'message',
                contains('Unable to stop ROAST signers safely (host_timeout)'),
              )
              .having(
                (error) => error.message,
                'redacted message',
                isNot(contains('SECRET-WORKER-MESSAGE')),
              ),
        ),
      );
      expect(repository.value, same(before));
      expect(controller.busy, isFalse);
    },
  );

  test('Noosphere rejects stopping a setup it does not own', () async {
    final worker = await NoosphereWorker.startForTesting();
    addTearDown(worker.close);
    await expectLater(
      worker.stopSetup('offline-setup'),
      throwsA(
        isA<NoosphereWorkerException>().having(
          (error) => error.code,
          'code',
          'invalid_state',
        ),
      ),
    );
  });

  test('concurrent group connections create only one worker', () async {
    final worker = await NoosphereWorker.startForTesting();
    final ready = Completer<NoosphereWorker>();
    var starts = 0;
    final runtime = RoastRuntimeManager(
      RoastPersistenceFactory(),
      getWalletBip39Seed: () => throw StateError('No seed should be needed.'),
      startWorker: () {
        starts++;
        return ready.future;
      },
    );
    addTearDown(runtime.close);
    final setup = WalletBackupFixture().setup;
    final address = RoastCoordinatorAddress(
      id: setup.coordinatorId!,
      relayUrls: setup.coordinatorRelayUrls,
      ipAddrs: setup.coordinatorIpAddrs,
    );
    final first = expectLater(
      runtime.updateCoordinatorAddress(setup, address),
      throwsStateError,
    );
    final second = expectLater(
      runtime.updateCoordinatorAddress(
        WalletBackupFixture(setupId: 'second').setup,
        address,
      ),
      throwsStateError,
    );
    ready.complete(worker);
    await Future.wait([first, second]);
    expect(starts, 1);
  });

  test('backup closes idle worker, blocks starts, and supports a fresh worker afterwards', () async {
    final workers = <NoosphereWorker>[];
    final runtime = RoastRuntimeManager(
      RoastPersistenceFactory(),
      getWalletBip39Seed: () => throw StateError('No seed should be needed.'),
      startWorker: () async {
        final worker = await NoosphereWorker.startForTesting();
        workers.add(worker);
        return worker;
      },
    );
    addTearDown(runtime.close);
    final setup = WalletBackupFixture().setup;
    Future<void> warmWorker() => expectLater(
      runtime.updateCoordinatorAddress(
        setup,
        RoastCoordinatorAddress(
          id: setup.coordinatorId!,
          relayUrls: setup.coordinatorRelayUrls,
          ipAddrs: setup.coordinatorIpAddrs,
        ),
      ),
      throwsStateError,
    );
    await warmWorker();
    await expectLater(
      runtime.withPausedForBackup<void>(() async {
        expect(workers.single.isClosed, isTrue);
        await expectLater(runtime.startSetup(setup), throwsStateError);
        throw const FormatException('Synthetic export failure');
      }),
      throwsFormatException,
    );
    await warmWorker();
    expect(workers, hasLength(2));
    expect(workers.last.isClosed, isFalse);
  });

  for (final fails in [false, true]) {
    test(
      'runtime attempts reconnect after snapshot (failure=$fails)',
      () async {
        final persistence = _UnavailablePersistence();
        final runtime = RoastRuntimeManager(
          persistence,
          getWalletBip39Seed: () =>
              throw StateError('No seed should be needed.'),
        );
        addTearDown(runtime.close);
        final events = <RoastRuntimeEvent>[];
        final subscription = runtime.events.listen(events.add);
        addTearDown(subscription.cancel);
        final setup = WalletBackupFixture().setup;
        await expectLater(runtime.startSetup(setup), throwsStateError);
        expect(persistence.opens, 1);
        final result = runtime.withPausedForBackup(() async {
          expect(persistence.opens, 1);
          if (fails) throw const FormatException('Synthetic snapshot failure');
          return 42;
        });
        if (fails) {
          await expectLater(result, throwsFormatException);
        } else {
          expect(await result, 42);
        }
        expect(persistence.opens, 2);
        await Future<void>.delayed(Duration.zero);
        expect(
          events.whereType<RoastRuntimeFailureEvent>().single.message,
          contains('Reconnect this group manually'),
        );
        expect(
          events.whereType<RoastRuntimeFailureEvent>().single.message,
          isNot(contains('SECRET-PERSISTENCE-MESSAGE')),
        );
      },
    );
  }

  test(
    'manager shutdown of offline groups is idempotent with a live worker',
    () async {
      final worker = await NoosphereWorker.startForTesting();
      final runtime = RoastRuntimeManager(
        RoastPersistenceFactory(),
        getWalletBip39Seed: () => throw StateError('No seed should be needed.'),
        startWorker: () async => worker,
      );
      addTearDown(runtime.close);
      final setup = WalletBackupFixture().setup;
      // Warm an otherwise idle worker through the ordinary runtime API. The
      // saved offline group has never registered any roles with this worker.
      await expectLater(
        runtime.updateCoordinatorAddress(
          setup,
          RoastCoordinatorAddress(
            id: setup.coordinatorId!,
            relayUrls: setup.coordinatorRelayUrls,
            ipAddrs: setup.coordinatorIpAddrs,
          ),
        ),
        throwsStateError,
      );
      await runtime.stopSetup(setup.id);
      await runtime.stopSetup(setup.id);
      await runtime.stopSetup('another-offline-group');
      expect(worker.isClosed, isFalse);
    },
  );
}

final class _UnavailablePersistence extends RoastPersistenceFactory {
  int opens = 0;
  @override
  Future<RoastPersistence> open() async {
    opens++;
    throw StateError('SECRET-PERSISTENCE-MESSAGE');
  }
}
