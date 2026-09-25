# Sygnature ROAST messaging architecture

Status: design documentation based on the local Sygnature,
`noosphere_flutter`, `noosphere_roast_client` and `noosphere_roast_server`
sources inspected on 2026-09-25. Sygnature now integrates the transport,
runtime, durable client storage, DKG and Taproot transaction approval/signing
through the preconfigured-roster flow. It also persists creator-side proposals,
aggregate signatures, signed transaction bytes and broadcast outcomes, allowing
an unknown broadcast to retry the exact same bytes after restart. Coordinator
round state, cross-peer UTXO reservations and the Sygnature request-context
extension described below are not implemented yet.

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

The coordinator has a persistent Iroh endpoint secret. The invitation supplies
address hints, while Sygnature separately persists the expected coordinator
endpoint ID. Before connecting, the client requires the ID embedded in the
bootstrap address to equal the pinned ID. It checks the remote endpoint ID again
after Iroh establishes the connection.

The Iroh endpoint identity and the ROAST participant authentication key have
different roles:

- the endpoint identity authenticates the coordinator transport endpoint;
- the participant key authenticates a member of the finalized ROAST group;
- FROST key shares authorize threshold signing and are separate from both.

Participant authentication is a challenge/response exchange. The client first
sends the group fingerprint, participant ID and domain protocol version. It
then signs the returned challenge with its participant authentication key. Only
after successful authentication may the connection start a group session.

## 3. Streams on one connection

Noosphere uses two stream patterns over the same Iroh connection.

### RPC streams

Every RPC opens a new bidirectional QUIC stream:

```text
client                                  coordinator
  │ openBi()                                 │
  │── one framed Envelope/RpcRequest ───────►│
  │ finish sending                           │
  │◄─ one framed Envelope/RpcResponse ───────│
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
  │── Ready ────────────────────────────────►│
  │◄─ Event ─────────────────────────────────│
  │◄─ Event ─────────────────────────────────│
  │                 ...                      │
  │── Logout ───────────────────────────────►│
```

The snapshot and live stream form one logical state feed. The client must parse
and install the snapshot before it consumes subsequent events. The `Ready`
handshake prevents live events from racing ahead of snapshot initialization.

## 4. Wire encoding layers

A Noosphere message is not encoded entirely as protobuf. The transport uses a
protobuf envelope, while most cryptographic domain objects use a deterministic
Noosphere/coinlib binary representation carried in protobuf `bytes` fields.

```text
Iroh QUIC stream
└── 4-byte unsigned big-endian frame-body length
    └── protobuf Envelope
        ├── wire_version
        └── oneof payload
            ├── RpcRequest / RpcResponse
            ├── StartSession / SessionStarted / Ready / Logout
            ├── Events
            └── ProtocolError
                └── bytes fields
                    └── Noosphere domain binary encoding
                        └── transaction, keys, commitments, signed details, ...
```

The sender serializes `Envelope` with protobuf `writeToBuffer()`, verifies that
the body fits the configured maximum, prefixes its length, and writes the frame
to the QUIC stream. The receiver reads arbitrary chunks, reconstructs the
four-byte header and exact frame body, then calls protobuf `Envelope.fromBuffer`.
An empty payload, malformed protobuf, truncated frame or oversized declared
length is rejected before domain dispatch.

The current Iroh wire version is `1`. It is carried in every `Envelope` and is
independent of the domain `protocol_version` sent during login. A first stream
message must be an RPC request, `StartSession` or `Logout`; other payloads are
rejected.

### Size limits

The default maximum protobuf `Envelope` body is 1 MiB (1,048,576 bytes), on
both client and server. The four-byte framing header is outside that body. The
effective limit is the smaller of the client and server configurations.

The planned Sygnature request-context block is separately limited to 1 KiB
(1024 bytes). This is not a 1 KiB limit on the complete Noosphere envelope. A
complete signature request additionally contains the transaction, prevouts,
group-key information, commitments, expiry and signatures and may legitimately
exceed 1 KiB.

The 1 KiB context limit must be checked:

1. after deterministic serialization and before signing/sending;
2. immediately after decoding and before rendering or persistence.

Both sides must also retain the 1 MiB frame limit. The smaller domain limit
prevents an otherwise-valid transport frame from becoming an oversized UI or
storage payload.

## 5. Protobuf transport messages

`Envelope` is the only framed top-level protobuf message. Its payload is a
protobuf `oneof`, so exactly one transport operation is selected.

An RPC request contains a non-empty request ID and another `oneof` identifying
the operation. A response echoes the request ID and contains either the matching
response type or a structured `ProtocolError`. Signature creation uses:

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

Server-to-client events use:

```text
Events
  type                EventType enum
  data                bytes
```

The enum selects the domain decoder for `data`, for example
`SignaturesRequestEvent.fromBytes`, `SignatureNewRoundsEvent.fromBytes` or
`SignaturesCompleteEvent.fromBytes`. Unknown event types are protocol errors;
they are not passed to the application as arbitrary data.

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
```

Its tagged hash covers this entire encoding. The proposal/request ID is the
first 16 bytes of that hash. `Signed<SignaturesRequestDetails>` appends the
creator's 64-byte Schnorr signature. Consequently, the required signatures,
transaction metadata, Sygnature context and expiry are all bound to both the
creator signature and proposal ID.

Parsing is intentionally layered:

1. reconstruct one length-prefixed frame;
2. decode the protobuf `Envelope`;
3. validate `wire_version` and the selected `oneof` payload;
4. match the response request ID or route the event enum;
5. extract protobuf `bytes` fields;
6. invoke the exact domain `fromBytes`/`fromReader` decoder;
7. validate lengths, ranges, expiry and object relationships;
8. verify the participant signature against the group manifest;
9. apply the state transition or expose a validated application event.

Protobuf forward compatibility does not automatically extend to domain bytes.
Each new domain format needs explicit framing, versioning and a registered
decoder.

## 7. Sygnature request context

Sygnature will add a versioned request-context metadata type inside the signed
`SignaturesRequestDetails`. It carries human review information such as:

```text
Sygnature request context, version 1
  reason              UTF-8 text
  references[]
    label             UTF-8 text
    URL               UTF-8 text
    content SHA-256   optional 32-byte digest
```

The complete serialized context—including its version, length fields, reason,
labels, URLs, reference count and optional hashes—must not exceed 1024 bytes.
The exact URL bytes are signed. A URL alone does not bind the mutable resource
served at that location; when document contents influence approval, the context
must also carry their SHA-256 digest.

The context must be part of a recognized, versioned metadata decoder and must
be length-delimited. It cannot be implemented safely as an application-only
unknown metadata subclass. The current Noosphere unknown-metadata fallback
consumes all remaining reader bytes, although `Expiry` follows metadata in
`SignaturesRequestDetails`. A new type therefore requires a coordinated client
library change. Unsupported context or metadata versions must make the proposal
unapprovable rather than silently dropping fields.

The UI treats URLs as untrusted input: it displays the host, does not fetch an
automatic preview and requires explicit user action before opening a link.
Changing the reason, any reference, document hash, transaction or expiry creates
a different proposal ID and requires fresh approvals.

The creator's identity signature binds the context to the signing proposal.
The final aggregate Taproot signature still signs only the transaction sighash;
it does not place the reason or URL on-chain.

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
   │                          │                    parse/display same context
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
context is not repeated in every round. The coordinator sends round-start events
only to participants selected for that ROAST round. On completion, it stores the
aggregate signatures and notifies the participants.

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

The client validates the snapshot with the same signature and structural checks
used for live events, installs it, sends `Ready`, and then processes live events.

Current server session, DKG and signing state is held in memory. Restarting the
coordinator loses active requests and rounds even if its Iroh endpoint identity
is restored. Production Sygnature requires durable coordinator proposal and
registry state or must surface interrupted operations and require a safe fresh
attempt. An ambiguous mutating RPC must not be automatically replayed because
the previous attempt may already have consumed signing nonces.

## 10. Security properties and limits

The design provides:

- an encrypted, authenticated Iroh/QUIC connection to a pinned coordinator;
- group-member authentication independent of the transport identity;
- creator authentication and proposal integrity through a Schnorr signature;
- deterministic proposal IDs derived from the exact proposal bytes;
- independent verification by every signing client;
- bounded outer envelopes and bounded Sygnature context metadata.

It does not provide:

- confidentiality of proposal context from the coordinator or other group
  participants;
- proof that the coordinator delivered a proposal to every participant;
- availability when the coordinator is offline;
- durable in-progress signing state in the current server implementation;
- on-chain commitment to the human-readable reason or referenced URL;
- immutability of URL content without an included content digest.

The coordinator must never be the sole validator. Each participant validates
prevouts, wallet/key/path ownership, outputs, change, fee, network, sighash
policy, Taproot tweaks and request context before authorizing its signature
share.

## 11. Implementation source map

The behavior described above is defined primarily in:

- `../noosphere_roast_client/lib/src/protocol/protos/noosphere.proto`
- `../noosphere_roast_client/lib/src/protocol/framing.dart`
- `../noosphere_roast_client/lib/src/iroh/client_api.dart`
- `../noosphere_roast_client/lib/src/iroh/endpoint.dart`
- `../noosphere_roast_client/lib/src/api/types/signed.dart`
- `../noosphere_roast_client/lib/src/api/types/signatures_request_details.dart`
- `../noosphere_roast_client/lib/src/api/types/signature_metadata.dart`
- `../noosphere_roast_client/lib/src/api/events.dart`
- `../noosphere_roast_client/lib/src/api/responses/login_complete.dart`
- `../noosphere_roast_server/lib/src/iroh/connection_handler.dart`
- `../noosphere_roast_server/lib/src/iroh/dispatcher.dart`
- `../noosphere_roast_server/lib/src/iroh/messages.dart`
- `../noosphere_roast_server/lib/src/server/api_handler.dart`
- `../noosphere_roast_server/lib/src/server/state/client_session.dart`
- `../noosphere_roast_server/lib/src/server/state/signatures_coordination.dart`
- `roast-workflow.md`
