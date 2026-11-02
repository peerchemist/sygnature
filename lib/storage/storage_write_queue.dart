import 'dart:async';

/// Serializes mutations without letting one failure poison later operations.
final class StorageWriteQueue {
  Future<void> _pending = Future.value();

  Future<void> get drained => _pending;

  Future<T> run<T>(FutureOr<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
