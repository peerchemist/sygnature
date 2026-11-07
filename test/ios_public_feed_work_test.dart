import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/android_public_feed_work.dart'
    show publicFeedWorkTaskName;
import 'package:sygnature_ng/services/ios_public_feed_work.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:workmanager/workmanager.dart';

class RecordingWorkmanager implements Workmanager {
  final calls = <Invocation>[];
  bool failScheduling = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    if (failScheduling && invocation.memberName == #registerPeriodicTask) {
      return Future<void>.error(StateError('unavailable'));
    }
    return Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PublicFeedStore store;
  late RecordingWorkmanager workmanager;
  late IosPublicFeedScheduler scheduler;

  Future<void> sync() => syncIosPublicFeedWork(
    store,
    platform: TargetPlatform.iOS,
    isWeb: false,
    scheduler: scheduler,
  );
  Future<void> subscribe() => store.subscribe(
    groupId: 'group',
    address: 'private-address',
    pin: 'pin',
    feedId: '01' * 32,
  );

  setUp(() async {
    workmanager = RecordingWorkmanager();
    scheduler = IosPublicFeedScheduler(workmanager: workmanager);
    directory = await Directory.systemTemp.createTemp('ios-public-feed-');
    store = await PublicFeedStore.open(directory.path);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'repeated startup uses one periodic app refresh without feed credentials',
    () async {
      await subscribe();
      await sync();
      await sync();
      final initializations = workmanager.calls.where(
        (c) => c.memberName == #initialize,
      );
      expect(initializations, hasLength(1));
      expect(
        initializations.single.positionalArguments.single,
        iosPublicFeedWorkDispatcher,
      );
      final registrations = workmanager.calls.where(
        (c) => c.memberName == #registerPeriodicTask,
      );
      expect(registrations, hasLength(2));
      for (final call in registrations) {
        expect(call.positionalArguments, [
          iosPublicFeedWorkId,
          publicFeedWorkTaskName,
        ]);
        expect(call.namedArguments[#frequency], const Duration(hours: 1));
        expect(call.namedArguments[#initialDelay], const Duration(minutes: 15));
        expect(call.namedArguments[#inputData], isNull);
        expect(call.toString(), isNot(contains('private-address')));
        expect(call.toString(), isNot(contains('01' * 32)));
      }
    },
  );

  test(
    'empty store cancels work and subscription changes reconcile it',
    () async {
      await sync();
      expect(workmanager.calls.last.memberName, #cancelByUniqueName);
      expect(workmanager.calls.last.positionalArguments, [iosPublicFeedWorkId]);
      await store.close();
      store = await PublicFeedStore.open(
        directory.path,
        onBindingsChanged: (_) => sync(),
      );
      await subscribe();
      expect(workmanager.calls.last.memberName, #registerPeriodicTask);
      await store.unsubscribe('group');
      expect(workmanager.calls.last.memberName, #cancelByUniqueName);
      await store.bindFeedFromSetup(
        groupId: 'group',
        address: 'address',
        pin: 'pin',
        feedId: '01' * 32,
      );
      expect(
        workmanager.calls.last.memberName,
        #cancelByUniqueName,
      ); // Explicit opt-out survives enrollment.
    },
  );

  test('failed registration retains subscription and later reconciliation recovers', () async {
    await subscribe();
    workmanager.failScheduling = true;
    await sync();
    expect((await store.snapshot())['bindings'], contains('group'));
    workmanager.failScheduling = false;
    await sync();
    expect(workmanager.calls.last.memberName, #registerPeriodicTask);
  });

  test('other platforms and web never initialize the scheduler', () async {
    await syncIosPublicFeedWork(
      store,
      platform: TargetPlatform.android,
      isWeb: false,
    );
    await syncIosPublicFeedWork(
      store,
      platform: TargetPlatform.iOS,
      isWeb: true,
      scheduler: scheduler,
    );
    expect(workmanager.calls, isEmpty);
  });
}
