import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/services/roast_runtime.dart';
import 'package:sygnature_ng/services/roast_signing_request_state.dart';

void main() {
  late List<RoastRuntimeEvent> events;
  late RoastSigningRequestState state;
  late WorkerSigningRequest request;
  final requestId = '01' * 16;

  setUp(() {
    events = [];
    state = RoastSigningRequestState(
      'setup',
      emit: events.add,
      mapRequest: _mapMessageRequest,
    );
    request = WorkerSigningRequest(
      id: Uint8List.fromList(List.filled(16, 1)),
      proposalBytes: Uint8List.fromList([1]),
      creator: '01',
      expiry: DateTime.now().add(const Duration(minutes: 5)),
      status: 'waiting',
      progress: WorkerSigningProgress(
        threshold: 2,
        contributingParticipants: const ['01'],
        stage: 'collecting',
      ),
    );
  });

  test('an older refresh cannot remove a live message request', () {
    final refreshRevision = state.revision;
    final staleSnapshot = _snapshot();

    state.receive(request);
    expect(
      state.applySnapshot(staleSnapshot, expectedRevision: refreshRevision),
      isFalse,
    );
    expect(state[requestId], same(request));
    expect(events.single, isA<RoastRuntimeSigningRequestEvent>());

    expect(
      state.applySnapshot(
        _snapshot(requests: [request]),
        expectedRevision: state.revision,
      ),
      isTrue,
    );
    expect(events, hasLength(1));
  });

  test('snapshots deduplicate requests until explicit replay', () {
    final missed = WorkerSigningRequest(
      id: Uint8List.fromList(List.filled(16, 2)),
      proposalBytes: Uint8List.fromList([2]),
      creator: request.creator,
      expiry: request.expiry,
      status: request.status,
      progress: request.progress,
    );
    state.receive(request);
    expect(state.applySnapshot(_snapshot(connected: false)), isTrue);
    expect(state[requestId], same(request));
    expect(events, hasLength(1));

    state.applySnapshot(_snapshot(requests: [request, missed]));
    expect(events, hasLength(2));
    expect(
      (events.last as RoastRuntimeSigningRequestEvent).request.idHex,
      '02' * 16,
    );

    events.clear();
    state.replay();
    expect(
      events.whereType<RoastRuntimeSigningRequestEvent>().map(
        (event) => event.request.idHex,
      ),
      [requestId, '02' * 16],
    );
  });

  test('cancellation wins over in-flight refreshes and repeated proposals', () {
    state.receive(request);
    final refreshRevision = state.revision;
    final snapshot = _snapshot(requests: [request]);

    state.cancel(requestId, request.expiry);
    expect(
      state.applySnapshot(snapshot, expectedRevision: refreshRevision),
      isFalse,
    );
    state.applySnapshot(snapshot);
    state.receive(request);
    state.replay();

    expect(state[requestId], isNull);
    expect(events, [
      isA<RoastRuntimeSigningRequestEvent>(),
      isA<RoastRuntimeSigningRequestCancelledEvent>(),
    ]);
  });

  test('completion invalidates a refresh with the old pending request', () {
    state.receive(request);
    final refreshRevision = state.revision;
    final snapshot = _snapshot(requests: [request]);

    state.complete(requestId);
    expect(
      state.applySnapshot(snapshot, expectedRevision: refreshRevision),
      isFalse,
    );
    expect(state[requestId], isNull);
    expect(events, hasLength(1));
  });
}

NoosphereWorkerSnapshot _snapshot({
  bool connected = true,
  List<WorkerSigningRequest> requests = const [],
}) => NoosphereWorkerSnapshot(
  setupId: 'setup',
  generation: 1,
  serverRunning: false,
  signerRunning: connected,
  connected: connected,
  coordinator: null,
  onlineParticipants: const [],
  dkgs: const [],
  signingRequests: requests,
  keys: const [],
);

RoastSigningRequest _mapMessageRequest(
  WorkerSigningRequest request,
  String id,
) => RoastSigningRequest(
  idHex: id,
  proposalHex: '01',
  creator: request.creator,
  expiry: request.expiry,
  kind: RoastSigningRequestKind.message,
  hasTransactionMetadata: false,
  usesSupportedSighash: false,
  usesExpectedTaprootTweak: false,
  usesUntweakedKey: true,
  status: request.status,
  progress: RoastSigningProgress(
    threshold: request.progress.threshold,
    contributingParticipants: request.progress.contributingParticipants,
    stage: request.progress.stage,
  ),
  inputSats: 0,
  transactionInputCount: 0,
  signedInputIndexes: const [],
  previousOutputScripts: const [],
  previousOutputValues: const [],
  inputOutpoints: const [],
  outputs: const [],
  masterGroupKeys: const ['group-key'],
  derivationPaths: const [[]],
  signedMessageText: 'Approve this message',
);
