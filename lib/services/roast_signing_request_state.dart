import 'package:coinlib/coinlib.dart' show bytesEqual, bytesToHex;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:noosphere_flutter/noosphere_flutter.dart';

import 'roast_runtime.dart';

/// Reconciles one setup's live signing events and worker snapshots.
final class RoastSigningRequestState {
  RoastSigningRequestState(
    this._setupId, {
    required this._emit,
    required this._mapRequest,
  });

  final String _setupId;
  final void Function(RoastRuntimeEvent) _emit;
  final RoastSigningRequest Function(WorkerSigningRequest, String) _mapRequest;
  final Map<String, WorkerSigningRequest> _requests = {};
  final Map<String, DateTime> _cancelled = {};
  int _revision = 0;

  int get revision => _revision;

  WorkerSigningRequest? operator [](String id) => _requests[id];

  void invalidateSnapshots() => _revision++;

  bool applySnapshot(
    NoosphereWorkerSnapshot snapshot, {
    int? expectedRevision,
  }) {
    if (expectedRevision != null && expectedRevision != _revision) return false;
    invalidateSnapshots();
    // A stopped or disconnected signer has no authoritative request list.
    if (!snapshot.connected || !snapshot.signerRunning) return true;

    final now = DateTime.now();
    _cancelled.removeWhere((_, expiry) => !expiry.isAfter(now));
    for (final request in snapshot.cancelledRequests) {
      _rememberCancellation(bytesToHex(request.requestId), request.expiresAt);
    }

    final current = {
      for (final request in snapshot.signingRequests)
        if (request.expiry.isAfter(now)) bytesToHex(request.id): request,
    };
    final removed = _requests.keys
        .where((id) => !current.containsKey(id))
        .toList(growable: false);
    for (final id in removed) {
      final request = _requests.remove(id)!;
      _emit(
        RoastRuntimeSigningRequestRemovedEvent(
          _setupId,
          requestIdHex: id,
          expired: !request.expiry.isAfter(now),
        ),
      );
    }
    for (final entry in current.entries) {
      _rememberRequest(entry.key, entry.value);
    }
    return true;
  }

  void receive(WorkerSigningRequest request) {
    invalidateSnapshots();
    if (!request.expiry.isAfter(DateTime.now())) return;
    _rememberRequest(bytesToHex(request.id), request);
  }

  void cancel(String id, DateTime expiresAt) {
    invalidateSnapshots();
    _rememberCancellation(id, expiresAt);
  }

  void complete(String id) {
    invalidateSnapshots();
    _requests.remove(id);
  }

  void replay() {
    final now = DateTime.now();
    for (final entry in _requests.entries) {
      if (entry.value.expiry.isAfter(now)) _publish(entry.key, entry.value);
    }
  }

  void _rememberRequest(String id, WorkerSigningRequest request) {
    if (_cancelled.containsKey(id)) return;
    final previous = _requests[id];
    if (previous != null &&
        bytesEqual(previous.proposalBytes, request.proposalBytes) &&
        previous.creator == request.creator &&
        previous.expiry == request.expiry &&
        previous.status == request.status &&
        previous.progress.stage == request.progress.stage &&
        previous.progress.threshold == request.progress.threshold &&
        listEquals(
          previous.progress.contributingParticipants,
          request.progress.contributingParticipants,
        )) {
      return;
    }
    _publish(id, request);
    _requests[id] = request;
  }

  void _publish(String id, WorkerSigningRequest request) => _emit(
    RoastRuntimeSigningRequestEvent(
      _setupId,
      request: _mapRequest(request, id),
    ),
  );

  void _rememberCancellation(String id, DateTime expiresAt) {
    if (_cancelled[id] == expiresAt || !expiresAt.isAfter(DateTime.now())) {
      return;
    }
    _cancelled[id] = expiresAt;
    _requests.remove(id);
    _emit(
      RoastRuntimeSigningRequestCancelledEvent(
        _setupId,
        requestIdHex: id,
        expiresAt: expiresAt,
      ),
    );
  }
}
