# Sygnature ROAST messaging architecture

Status: implementation documentation checked against Sygnature and the pinned
Noosphere revision on 2026-10-07. Sygnature supports participant-bound room
enrollment and the preconfigured-roster flow, durable client, room and
coordinator state, DKG, successor-group transitions, transaction and message
signing, and retry-safe transaction broadcast persistence. Cross-peer UTXO
reservations are not implemented; reservations are local to each wallet
instance. A locally constructed DKG key is exposed to the wallet only after
every configured participant has acknowledged it. Broadcast inputs remain
locally reserved until a later ElectrumX snapshot no longer reports those
outpoints.

## 1. Topology and responsibilities

Each participant client maintains an authenticated Iroh connection to one
coordinator. Participants do not gossip signing proposals directly to one
another.

```text
                         Iroh/QUIC
 Participant A  ─────────────────────────┐
                                        │
 Participant B  ────────────────────────┼── Coordinator
                                        │      ├── group/session state
 Participant C  ────────────────────────┘      ├── event fan-out
                                               └── ROAST coordination
```

The coordinator:

- authenticates participants and associates each connection with exactly one
  finalized group;
- validates incoming requests before making them visible to the group;
- keeps the active DKG, signing-round and completed-signature state;
- pushes events to connected participants;
- includes still-active state in the login snapshot of a reconnecting client;
- selects ROAST rounds, verifies signature shares and aggregates completed
  signatures.

Hosting the coordinator does not constitute a signing approval. A host that is
also a signer runs a separate local participant client and counts once.

The coordinator is trusted for availability and message delivery, but not for
proposal integrity. It may observe, delay, omit or stop forwarding a proposal.
It cannot change a correctly signed proposal without invalidating the creator's
signature. There is currently no direct client-to-client fallback.

## 2. Iroh connection and identity

Noosphere uses Iroh's QUIC connection with the ALPN `noosphere/roast/1`. Iroh
may establish a direct route or use a configured relay; that choice does not
change the application wire format.

For new setups, the coordinator's Iroh endpoint secret is deterministically
derived from the validated wallet BIP-39 seed using the domain-separated path
`m/83696968'/128169'/32'/index'`. The non-secret per-setup index and expected
endpoint ID are persisted, but the derived secret is not. A valid legacy secret
is still read for an existing setup so an upgrade preserves its pinned endpoint.
The invitation supplies only the pinned coordinator endpoint ID. Iroh discovery
finds the route, and the client verifies the remote endpoint identity while
establishing the connection.

The Iroh endpoint identity and the ROAST participant authentication key have
different roles:

- the endpoint identity authenticates the coordinator transport endpoint;
- the participant key authenticates a member of the finalized ROAST group;
- FROST key shares authorize threshold signing and are separate from both.

Participant authentication is a challenge/response exchange. The client first
sends the group fingerprint, participant ID and domain protocol version. It
then signs the returned challenge with its participant authentication key. Only
after successful authentication may the connection start a group session.

Before that finalized group session exists, a new setup can use the separate
`noosphere/roast-enrollment/1` protocol. The host persists room state and issues
participant-bound, expiring invitations. A joining participant proves control
of the expected authentication key while redeeming its invitation. When every
expected participant has enrolled, the host freezes the roster and starts the
ordinary coordinator and signer session for that immutable group. Room state
survives a restart; an interrupted invitation redemption is reconciled instead
of being replayed blindly.

The coordinator address may be replaced without changing the participant group
or FROST key, but only after pending signing operations and nonce records have
been reconciled. Membership or threshold changes instead create a successor
group. A canonical transition proposal binds the source group, successor room
and roster, target key plan, approved DKG details and migration policy. The
successor DKG is accepted only when it matches that approved plan, and
Sygnature persists transition approvals and progress.

## 3. Streams on one connection

Noosphere uses two stream patterns over the same Iroh connection.

### RPC streams

Every RPC opens a new bidirectional QUIC stream:

```text
client                                  coordinator
  │ openBi()                                 │
  │── operation varint + request protobuf ──►│
  │ finish sending                           │
  │◄─ status varint + response protobuf ─────│
  │ stream closes                            │
```

The core Noosphere client and server libraries have generic defaults of 32
concurrent streams. The Flutter adapter deliberately narrows these defaults:

- `ClientNodeOptions` permits two concurrent RPC streams. One domain operation
  can be in flight while a session-extension, acknowledgement or other control
  RPC still makes progress.
- `EmbeddedServerOptions` accepts four simultaneous streams per client
  connection. This includes the long-lived event stream, the client's two RPC
  streams and one transition/cleanup slot.

The client limit counts RPC streams only; the server limit counts every stream
on that connection. Both remain configurable. The independent server limit
protects the coordinator from a faulty or hostile client that ignores the
client-side limit. Authentication RPCs use the authentication timeout; other
RPCs use the normal RPC timeout.

### Session event stream

After challenge authentication, the client opens one long-lived bidirectional
stream:

```text
client                                  coordinator
  │── StartSession ─────────────────────────►│
  │◄─ SessionStarted(session ID, snapshot) ──│
  │◄─ EventMessage ──────────────────────────│
  │◄─ EventMessage ──────────────────────────│
  │                 ...                      │
  │ close connection                         │
```

The snapshot and live stream form one logical state feed. The server subscribes
the session to queued/live events before writing the snapshot, preserving the
snapshot boundary without a separate `Ready` message.

## 4. Wire encoding layers

A Noosphere message is not encoded entirely as protobuf. Each operation uses a
concrete protobuf type, while most cryptographic domain objects use a
deterministic Noosphere/coinlib binary representation carried in protobuf
`bytes` fields.

```text
Iroh QUIC stream
├── operation/status QUIC varint
└── concrete protobuf body, delimited by FIN
    └── bytes fields
        └── Noosphere domain binary encoding
            └── transaction, keys, commitments, signed details, ...
```

RPC request and response bodies are delimited by stream FIN and do not carry a
message-length prefix. Only the persistent session stream frames its
`SessionStarted` and `EventMessage` records, using QUIC-varint lengths so an
incremental decoder can handle arbitrary transport chunks.

The preview `/1` ALPN remains in use, but the former envelope format is not
decoded. Clients and servers must therefore be upgraded together. The login
domain `protocol_version` remains separate from transport framing.

### Size limits

The default `maxMessageLength` is 1 MiB (1,048,576 bytes) on both client and
server. It bounds a FIN-delimited protobuf body and each persistent record. The
effective limit is the smaller of the client and server configurations.

The signed request explanation in `SignaturesRequestDetails.message` is
separately limited to 1 KiB (1024 UTF-8 bytes). Constructors enforce the limit
before signing, and decoders enforce it before exposing the proposal. This is
not a 1 KiB limit on the complete request: transaction data, prevouts,
group-key information, commitments, expiry and signatures may legitimately
make the request larger. Both peers still enforce the independent 1 MiB
transport limit.

## 5. Protobuf transport messages

Each `RoastOperation` or `EnrollmentOperation` ID selects one concrete request
and response protobuf pair. QUIC stream ownership correlates the pair; response
status `0` carries the success type and status `1` carries `ProtocolError`.
Signature creation uses:

```text
SignaturesRequest
  sid                 bytes
  keys                repeated bytes
  signed_details      bytes
  commitments         repeated bytes
```

The fields named `bytes` are opaque to protobuf. After protobuf parsing, the
connection handler passes each byte sequence to its specific Noosphere domain
decoder. Protobuf therefore provides transport routing and field framing, but
does not describe the internal transaction, FROST or proposal structures.

Server-to-client events use an `EventMessage` protobuf `oneof` whose selected
field identifies the concrete event payload:

```text
EventMessage
  oneof event
    signatures_request
    signature_new_rounds
    signatures_complete
    ...
```

Unknown selections are protocol errors rather than arbitrary application data.

## 6. Domain binary parsing

Noosphere domain values implement coinlib's `Writable` interface. Writers emit
fields in a fixed order. Readers must consume the same order using
`BytesReader`. Common conventions include:

- fixed-size identifiers: 32 bytes;
- compressed public keys: 33 bytes;
- Schnorr signatures: 64 bytes;
- booleans: one byte (`0` or `1`);
- counts for many collections and maps: unsigned 16-bit integers;
- times: unsigned 64-bit Unix time in milliseconds;
- strings: UTF-8 length-prefixed byte slices;
- nested writable vectors: a length followed by individually length-prefixed
  domain byte strings.

`Signed<T>` is encoded as the exact bytes of `T` followed by a 64-byte Schnorr
signature. The signature is calculated over `T.sigHash`, not over the outer
protobuf representation. Reordering protobuf fields or changing protobuf's
wire representation therefore does not change the domain signature; changing
any byte of the domain object does.

`SignaturesRequestDetails` is encoded in this order:

```text
uint16                    required-signature count
SingleSignatureDetails[] required signatures
SignatureMetadata         type byte followed by type-specific data
Expiry                    uint64 timestamp
Message length            canonical CompactSize integer
Message                    UTF-8 bytes
```

Its tagged hash covers this entire encoding. The proposal/request ID is the
first 16 bytes of that hash. `Signed<SignaturesRequestDetails>` appends the
creator's 64-byte Schnorr signature. Consequently, the required signatures,
metadata, expiry and explanation are all bound to both the creator signature
and proposal ID.

Parsing is intentionally layered:

1. decode the operation or response-status QUIC varint;
2. read the FIN-delimited body, or one QUIC-varint-length session record;
3. decode the concrete protobuf selected by the operation;
4. route the selected `EventMessage` field for persistent events;
5. extract protobuf `bytes` fields;
6. invoke the exact domain `fromBytes`/`fromReader` decoder;
7. validate lengths, ranges, expiry and object relationships;
8. verify the participant signature against the group manifest;
9. apply the state transition or expose a validated application event.

Protobuf forward compatibility does not automatically extend to domain bytes.
Each new domain format needs explicit framing, versioning and a registered
decoder.

## 7. Signed request explanation and metadata

`SignaturesRequestDetails` has two application-facing review channels:

- a closed registry of typed `SignatureMetadata`; and
- a free-form UTF-8 explanation in `message`, limited to 1024 bytes.

The supported metadata types are empty metadata, Taproot transaction metadata
and versioned signed-message metadata. Embedded unknown metadata is rejected;
Sygnature also marks any unsupported decoded type as unapprovable. Transaction
metadata binds the transaction and per-input signing details. Message metadata
binds a versioned text payload to one untweaked BIP-340 signature request.

The explanation is included in the deterministic proposal bytes, proposal ID
and creator signature. Changing it creates a different request and requires new
approvals. It is review information only: the final aggregate signature still
signs the transaction sighash or signed-message digest, so the explanation is
not committed on-chain and is not part of the portable signed-message result.

There is no structured URL/reference request-context format in the current
protocol. Such a format would require a new registered, versioned and bounded
metadata codec rather than application-defined unknown metadata.

## 8. Signature-request distribution

The complete online flow is:

```text
Creator                  Coordinator                 Other participants
   │                          │                                │
   │ requestSignatures RPC    │                                │
   │ signed proposal +        │                                │
   │ keys + commitments       │                                │
   │─────────────────────────►│                                │
   │                          │ validate session, group,       │
   │                          │ keys, expiry, duplicate ID,    │
   │                          │ creator signature              │
   │                          │                                │
   │                          │ store SignaturesCoordination   │
   │                          │ state and creator commitments  │
   │                          │                                │
   │                          │── SignaturesRequestEvent ─────►│
   │◄── RPC success ──────────│                                │
   │                          │                    verify creator signature
   │                          │                    parse/display metadata and message
```

The coordinator sends the initial request event to every currently active
session in the authenticated group except the originating session. The creator
has already installed its local state after the RPC succeeds. The event contains
the original `Signed<SignaturesRequestDetails>`; the coordinator does not
reconstruct or re-sign it.

Each receiving client:

- verifies that the claimed creator is another member of its configured group;
- verifies the creator's Schnorr signature over the exact proposal bytes;
- checks expiry and duplicate request state;
- checks that it owns the requested group keys;
- parses and validates the transaction and recognized metadata version;
- emits an application-level incoming-request event for review.

Rejecting or accepting a request sends a new RPC to the coordinator. Signing
round events normally refer to the established proposal by its 16-byte request
ID and carry only the commitments or shares required for that round; the full
proposal is not repeated in every round. The coordinator sends round-start
events only to participants selected for that ROAST round. On completion, it
stores the aggregate signatures and notifies the participants.

## 9. Offline clients, buffering and reconnect

For a connected session, the coordinator pushes events through the long-lived
session stream. If consumption is temporarily paused, the current server keeps
up to 100 events in that session's ring buffer. A lost stream ends the session;
the buffer is not a durable queue.

An offline participant is recovered through state reconciliation rather than
event replay. After it authenticates again, `SessionStarted.snapshot` contains:

- currently online participants;
- outstanding DKG requests;
- unexpired signature requests, including their original signed details;
- signing rounds in which this participant is expected to act;
- completed signatures not yet acknowledged;
- pending encrypted secret-share events.

The client validates and installs the snapshot before consuming later records
from the same stream. There is no separate wire-level `Ready` message. The
server establishes its internal ready phase before it writes `SessionStarted`
and the queued/live events that follow it.

Live connections and their event buffers are transient. DKG requests, signing
requests and rounds, completed signatures and encrypted secret-share state are
stored as one versioned `ServerStateSnapshot` after each protocol mutation.
Sygnature stores that snapshot durably for each setup, so coordinator restart
restores protocol state but requires clients to reconnect and reconcile through
a new login snapshot. Ambiguous mutating RPCs are not replayed automatically
because a previous attempt may already have consumed signing nonces.

## 10. Security properties and limits

The design provides:

- an encrypted, authenticated Iroh/QUIC connection to a pinned coordinator;
- group-member authentication independent of the transport identity;
- creator authentication and proposal integrity through a Schnorr signature;
- deterministic proposal IDs derived from the exact proposal bytes;
- independent verification by every signing client;
- durable coordinator protocol state and durable participant nonce state;
- bounded transport messages and bounded signed request explanations.

It does not provide:

- confidentiality of proposal metadata or explanations from the coordinator
  or other group participants;
- proof that the coordinator delivered a proposal to every participant;
- availability when the coordinator is offline;
- cross-peer coordination of UTXO reservations;
- structured binding of external documents or URLs;
- on-chain commitment to the human-readable request explanation.

The coordinator must never be the sole validator. Each participant validates
prevouts, wallet/key/path ownership, outputs, change, fee, network, sighash
policy, Taproot tweaks, metadata and request explanation before authorizing its
signature share.

### Durable state boundaries

Sygnature stores all security-critical ROAST state in encrypted durable
storage. Participant state includes FROST keys, nonces, prepared operations and
rejected requests. Host state includes room enrollment and the versioned
Noosphere server snapshot. Creator-side transaction operations are keyed by
`setupId:requestId` and include the exact proposal, unsigned transaction data,
reserved outpoints, expiry, aggregate signatures, signed bytes and broadcast
outcome.

This persistence makes a completed signature or uncertain broadcast
recoverable without creating a new proposal or signing different bytes. It does
not make live connections durable. It also does not distribute local UTXO
reservations to other participants, so every signer must independently reject
unknown, unavailable or locally reserved inputs during approval.

## 11. Implementation source map

The behavior described above is defined primarily in:

- `lib/controllers/wallet_controller_roast_setup.dart`
- `lib/controllers/wallet_controller_signing.dart`
- `lib/controllers/wallet_controller_sync.dart`
- `lib/models/group_transition.dart`
- `lib/models/roast_signing_operation.dart`
- `lib/services/roast_runtime_manager.dart`
- `lib/services/roast_runtime_rooms.dart`
- `lib/services/roast_runtime_signing_mapper.dart`
- `lib/storage/roast_storage.dart`
- [Noosphere at the pinned revision](https://github.com/peerchemist/noosphere/tree/fafb28dba31a2d3acc17d9c90060a3ad46d7300d):
  `packages/noosphere/proto/noosphere.proto`,
  `packages/noosphere/lib/src/framing.dart`,
  `packages/noosphere/lib/api/`,
  `packages/noosphere_client/lib/src/iroh/`,
  `packages/noosphere_server/lib/src/iroh/`, and
  `packages/noosphere_server/lib/src/server/`
