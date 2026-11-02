import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/storage/storage_write_queue.dart';

void main() {
  test('queued mutations remain ordered after a failure', () async {
    final queue = StorageWriteQueue();
    final gate = Completer<void>();
    final calls = <int>[];
    final first = queue.run(() async {
      await gate.future;
      calls.add(1);
      throw StateError('write failed');
    });
    final failure = expectLater(first, throwsStateError);
    final second = queue.run(() => calls.add(2));
    expect(calls, isEmpty);
    gate.complete();
    await failure;
    await second;
    await queue.drained;
    expect(calls, [1, 2]);
  });
}
