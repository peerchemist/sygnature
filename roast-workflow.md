ROAST wallet workflow — design proposal
=====================================

Status: proposal based on the local Sygnature, noosphere_flutter,
noosphere_roast_client, noosphere_roast_server and Frosty sources inspected on
2026-09-24. This document does not implement the feature. UI copy is English.

The central product decision is to keep wallets as the objects in the existing
wallet switcher. A ROAST setup supplies signing authority to multiple wallets.
The setup owns the participant group and shared key; its coordinator is a
replaceable connection/hosting role. Creating another wallet under that key
does not create another server, signer identity or DKG ceremony.

**What exists today.** Sygnature already derives personal BIP-86 accounts from
one mnemonic, persists them in an encrypted vault and synchronizes their
addresses through ElectrumX. Its README lags behind the implementation.
The current Add wallet dialog asks for a name and network. Send is still a
placeholder: transaction construction and signing need implementation for both
personal and ROAST wallets.

Noosphere provides embedded server, reconnecting client and combined roles;
authenticated Iroh sessions; DKG; signing requests with HD paths; and Taproot
transaction metadata. The Flutter integration test exercises real 2-of-2 DKG
and a signature, but uses an empty derivation path and scriptSpend on a test
message. It does not establish Peercoin transaction compatibility, derived
wallet signing or production persistence.

Important current boundaries:

- noosphere_flutter supports Linux and macOS only, for both client and server.
- ServerConfig requires a GroupConfig containing at least two known participant
  public keys. ClientConfig also needs the complete group and a member ID.
  An Iroh address alone cannot enroll an unknown participant.
- SingleSignatureDetails.hdDerivation supports unhardened indexes only.
- Client storage must durably and atomically prepare signing operations and
  their nonce changes before network transmission.
- Server session/DKG/signing state is currently held in memory. Preserving the
  Iroh identity does not persist an in-progress ceremony.
- Reconnection replaces the Client instance and does not replay mutating RPCs.

**1. One creation entry point.** Both first launch and Add wallet open the same
type chooser: Personal wallet / ROAST shared wallet. Personal creation keeps
the existing mnemonic workflow; adding another personal account retains the
short name/network dialog. A ROAST-only user does not have to create a personal
wallet first. If that user later adds a personal wallet, initialize the mnemonic
without replacing existing ROAST records.

For ROAST, offer Use existing setup when the device already has a completed
setup. Otherwise, or after choosing New setup, show:

- Connect to a coordinator.
- Host a coordinator on this device.

Explain the host choice with one operational sentence: "This device must stay
online while participants create keys or sign." Hosting normally starts both
the server and a local participant client. Hosting itself is not a signing vote;
the local participant counts once, exactly like a remote participant.

Once a setup draft is saved, return to the normal shell with a pending wallet
entry. Clicking it resumes setup. Waiting for peers must not hold the existing
WalletController's global busy flag or prevent use of other wallets.

**2. Host flow.** The guided sequence is:

1. Name the shared setup and its first wallet; choose the network and signing
   policy, for example 2 of 3. Restrict the initial implementation to 2 <= t <= n.
2. Persist a coordinator Iroh identity and a separate participant authentication
   key. Create a durable setup draft before sharing anything.
3. Open an enrollment lobby and display Share invitation, Copy and QR actions.
4. Peers open the invitation and send their participant public keys with proof
   of possession. The host verifies and approves each person. A display name
   alone is not identity verification.
5. Freeze the roster, assign stable participant IDs and distribute the complete
   group manifest. Every participant sees the same names/key fingerprints,
   threshold, network and setup fingerprint before approving key creation.
6. Activate the ROAST server with that GroupConfig, connect the host's own
   client and run DKG. Show Waiting for participants, Creating shared key and
   Securing your key share, plus per-participant progress.
7. Persist the completed local FROST key package, verify the common public key
   and collect the library's DKG acknowledgments. Confirm a recoverable encrypted
   backup of the local share and descriptor before exposing the first Receive
   address. Other participants' readiness remains visible.
8. Create account index 0 and open its normal wallet dashboard.

The enrollment lobby is NEW functionality. To support this exact address-first
flow, extend Noosphere's endpoint lifecycle to permit enrollment before a
GroupConfig exists, then attach the finalized ROAST group. Use a separate,
versioned enrollment protocol with bounded messages and host approval; do not
weaken ROAST authentication. Retain the pinned coordinator identity across the
transition. A close/rebind transition with the same identity is an acceptable
first implementation if clients explicitly handle it; two simultaneous
endpoints must not use the same coordinator secret.

The immediate prototype using existing APIs has a different sequence: exchange
participant cards via QR/files first, finalize GroupConfig, then start
NoosphereNode and share the connection invitation. Label this as a prototype
constraint, not as already-supported address-first enrollment.

An invitation is a versioned application envelope containing a setup draft ID,
coordinator Iroh ID, optional relay/direct address hints, enrollment nonce and
expiry. A finalized connection invitation additionally carries the complete
group manifest, its fingerprint and the agreed policy. Authenticate the envelope
and verify the coordinator fingerprint through the trusted invitation channel;
self-signing an invitation does not establish who sent it. Never include secret
shares or private keys. If a user pastes only an Iroh ID, request/import the
missing setup information rather than assuming membership.

**3. Join and restore flow.** Open/scan the invitation, verify the coordinator,
then show the setup summary. During enrollment, generate the participant key
locally and show Waiting for host approval. After roster confirmation, connect
with pinnedServerId, review the DKG proposal and explicitly accept it.

Joining a coordinator that already has a key is a separate case. An existing
member restores their own encrypted share and authentication identity, then
reconnects. A new participant cannot acquire a share by importing a group public
key or connecting to the server. For the first version, changing membership or
threshold creates a new key/setup and requires an explicit funds migration.
Do not present shareKeySecret as enrollment: that API can enable reconstruction
of the underlying private key. Resharing without changing addresses requires a
separately supported and reviewed protocol.

**4. Several wallets, one shared key.** Use this conceptual relationship:

```text
Vault
  Personal key source
    Main wallet
    Savings
  ROAST setup: Family, 2 of 3
    Coordinator connection + local participant
    Shared key K, generation 1
      Household wallet, account 0
        receive addresses / change addresses
      Travel wallet, account 1
        receive addresses / change addresses
```

GroupConfig can describe multiple FROST keys. Keep a separate key ID even if the
first UI supports one active key per setup. A wallet references that exact key
generation, not whichever key is currently active on the coordinator.

Use existing setup -> Family -> wallet name/network -> Create allocates a new
account descriptor. It requires no DKG and no threshold signature. All wallets
under K share participants and threshold. Separate balances are accounting
boundaries; they do not create separate signing authority or key-compromise
boundaries. A different policy needs a different shared key.

Define and version a ROAST derivation scheme, for example:

```text
scheme: sygnature-roast-v1 (proposed application convention)
root:   Frosty's HD master information for shared key K
path:   R / usage / coin / network / account / change / addressIndex

usage = 0 for coin transactions; other uses require separately defined domains
coin = 6 for Peercoin
network = 0 for mainnet, 1 for testnet
change = 0 for receive, 1 for change
all path components are unhardened
```

Here R denotes the DKG root, not a mnemonic master or BIP-86 root. Persist the
scheme version, root public material/HD metadata and exact integer path. Use
Frosty's derivation on both aggregate public information and local participant
information; apply the Taproot key-spend tweak once, with matching parity
handling. The existing privateKeyHex field must stay absent for ROAST accounts.

The existing personal path m/86'/coin'/account'/change/index has hardened
levels. Consequently the roadmap's strict "BIP-86 accounts only" requirement
needs an explicit revision: personal wallets retain BIP-86; ROAST wallets use
versioned shared-key derivation and Taproot key-path outputs. Calling the proposed
path BIP-86 would imply incorrect recovery compatibility.
[BIP-86](https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki) specifies
the hardened hierarchy and Taproot output-key construction.

Creating accounts on several peers also needs shared metadata coordination.
For version one, the coordinator owns a durable registry of account descriptors
and per-network/per-key allocation counters. Any authenticated member may request
an account; allocation is atomic and idempotent using an operation ID. Distribute
versioned records to all peers and reject conflicting bindings of an account
index. Persist replicas for restore and coordinator migration. Never reuse an
allocated index, even after archival. Names may have local display overrides.
This registry is new application functionality, not an existing Noosphere RPC.

Use the same registry to reserve fresh receive/change indexes across devices.
Version one reserves new indexes while connected; an already saved receive
address remains usable with the coordinator offline. Address derivation itself
requires only public information. Offline issuance of new addresses can later
use preallocated per-device ranges. Discovery must scan receive and change
branches and recover saved high-water marks; a generic address gap limit alone
cannot recover arbitrarily skipped account indexes or wallet names.

**5. The regular wallet screen.** Reuse the existing sidebar/mobile switcher,
balance, address and activity areas. Add a small "ROAST · 2 of 3" badge and a
Shared setup row linking to participants, coordinator and recovery. On wide
screens wallets can be grouped under their setup; on mobile show the setup name
below the wallet name. This must still feel like selecting an ordinary wallet.

Represent chain synchronization and signing availability separately:

- "Balance synced" comes from ElectrumX.
- "Coordinator offline" describes the transport.
- "1 of 3 signers online · 2 required" describes available quorum.
- "Your signer locked" describes local authorization.

A coordinator outage must not hide balances or disable an existing Receive
address. A pending setup shows Resume setup instead of a fabricated zero balance.
Shared setup settings are shared by every child wallet. Archive wallet hides an
account locally; leaving a setup or deleting a share is a distinct operation
with an explicit scope. Removing the final wallet must not silently erase the
signer or stop a coordinator serving other peers.

**6. Sending and incoming approvals.** Build the common send/review workflow once.
Personal wallets sign locally; ROAST wallets turn the reviewed transaction into
a persisted signing proposal:

```text
Draft -> Review -> Awaiting approvals -> Signing -> Signed
      -> Broadcast -> Confirming -> Confirmed
```

Provide Expired, Rejected, Interrupted and Broadcast outcome unknown branches
where appropriate. Online peers are not approvals, and UI approvals are not
completed signature shares. In a t-of-n request one participant's rejection
does not necessarily prevent the others from reaching threshold.

Incoming requests appear in a global Requests inbox/badge and in the affected
wallet's activity, including when another wallet is selected. Show recipient,
amount, fee, change, network, requesting participant and expiry. The requesting
user's Send confirmation authorizes requestSignatures; other participants use
acceptSignaturesRequest only after reviewing the same immutable proposal.

Reuse TaprootTransactionSignatureMetadata where compatible. It already binds
required signature hashes to transaction signing details. Independently validate
prevouts, wallet/key/path ownership, change, fee, network, sighash policy and
Taproot tweaks. Its decoder currently calls coinlib Transaction.fromReader, so
Peercoin-specific transaction round trips and sighashes must be demonstrated;
extend versioned metadata if that decoder cannot preserve the required fields.
Do not treat the generic-message integration test as proof of transaction support.

Add a versioned Sygnature request-context metadata block inside the signed
SignaturesRequestDetails for a human-readable reason and URL references. Limit
the complete serialized context block, including its version, lengths, labels,
URLs and optional content hashes, to 1 KiB (1024 bytes). Enforce the limit both
before requesting signatures and immediately after decoding, before rendering
or persisting the context. The reason and exact URL bytes are thereby bound to
the requester's signature and proposal ID; changing either creates a new
proposal and requires fresh approvals. A URL only binds the reference, not the
mutable resource at that location, so include a SHA-256 content hash when the
referenced document is material to approval. Do not fetch previews automatically,
and reject unsupported metadata versions rather than approving an incompletely
understood proposal. This application-level limit does not reduce Noosphere's
transport-envelope limit: the containing message also carries the transaction,
prevouts, keys, commitments and signatures and may legitimately exceed 1 KiB.

For each input, supply the master groupKey and its exact hdDerivation. After
aggregation, verify the resulting signatures against the actual output keys,
assemble the transaction and broadcast through the existing ElectrumX service.
Use one designated broadcaster and persist the signed transaction/txid before
broadcast. An uncertain broadcast is reconciled by txid or rebroadcasting the
same bytes, rather than creating a new payment. Persist and synchronize UTXO
reservations to prevent accidental conflicting proposals from honest peers.
Each signer independently enforces transaction policy.

Cancellation before signing stops the local proposal flow; it cannot revoke a
signature or transaction already obtained by another participant. Reconnection
must inspect prepared-operation records and the new snapshot. An ambiguous
signing RPC is never automatically replayed; the existing client rejects such
prepared requests on reconciliation. Any fresh attempt requires new nonces and
review of whether the previous request already completed.

**7. Runtime ownership and lifecycle.** Introduce an application-owned
RoastRuntimeManager, keyed by setup/connection, above the widget tree. It owns
NoosphereNode, subscriptions and shutdown. Selecting another wallet does not
restart it. The current Flutter adapter starts one configured server group per
node; multiple independent hosted setups can initially have separate nodes.
Adding accounts under a setup shares the same node.

The current adapter can be prototyped in the main isolate, but the production
hosting design should target a long-lived worker owning the whole ROAST runtime
once worker initialization is verified. Moving only the Iroh wrapper provides
little benefit: the installed iroh_quic 1.0.3 rust/src/runtime.rs already runs
network operations on a process-wide, multithreaded Tokio runtime. In contrast,
Frosty's rust/src/api/main.rs marks DKG, signing and aggregation calls with
#[frb(sync)], which blocks the calling Dart isolate until those calls return.
Profile their actual latency; this inspection establishes synchronous execution,
not a measured UI performance problem.

Keep protocol parsing, coordinator/client state, crypto calls and signing-store
ownership together in the worker. Send UI commands and public state/events over
ports; keep native handles and nonce state with their owner. One worker can
manage multiple setup nodes, and derived wallets do not need separate isolates.
The UI owns widgets, lifecycle signals and user authorization. This isolates
Dart scheduling and mutable state, but is not a process-level security boundary.

Follow noosphere_flutter's consuming-application dependency pins, including the
matching Frosty/frosty_flutter overrides; dependency overrides do not propagate
from a package. Reconcile Sygnature's existing loadCoinlib startup with the
adapter's native initialization and verify the resolved dependency graph and
native library loading on both supported desktop platforms.

A worker isolate requires proven plugin/FFI initialization and single ownership
of native handles and signing storage. The current initialization calls
WidgetsFlutterBinding.ensureInitialized(), so wrapping NoosphereNode.start in
Isolate.run is not a supported drop-in solution. Flutter documents isolate
memory separation and platform-channel restrictions in its
[isolate guidance](https://docs.flutter.dev/perf/isolates).

Restore the coordinator's same Iroh identity and finalized GroupConfig on app
restart. Subscribe to reconnectingClient.sessions and replace old client/event
subscriptions. After locking, do not allow an already-live client to continue
signing from cached shares: stop/dispose the signer session and reopen it after
unlock. Keeping the server running while the signer is locked needs separate
role lifetimes, such as a server-only node plus a client-only node; closing the
current combined node closes both. Define explicit awaited shutdown rather than
relying solely on Widget.dispose or detached events.

An isolate ends with its application process. For this release, closing the app
stops hosted coordination. A persistent external coordinator is the supported
choice for availability beyond the app lifetime. Mobile client/background
hosting needs separate platform support and lifecycle work; do not expose a
functional ROAST creation option on currently unsupported targets. Preserve
existing personal-wallet builds through a conditional platform adapter.

**8. State and custody.** Extend the model around these responsibilities:

| Record | Owns |
| --- | --- |
| WalletVault | Optional personal mnemonic, accounts, ROAST setups, schema version |
| RoastSetup | Stable setup ID, finalized group, coordinator connection, hosting preference, local member and key references |
| RoastKey | DKG attempt/generation, group key, HD scheme, threshold, public descriptor, local share reference |
| WalletAccount | Personal/ROAST source reference, network, account index, name and address state |
| SetupDraft | Enrollment state and confirmed manifest, separate from spendable accounts |
| SigningProposal | Immutable reviewed transaction, request ID, approvals/progress, reservations and broadcast state |

Use stable account IDs including their source identity; the current
blockchain-network-index ID and one global nextAccountIndex are insufficient
once several independent key sources exist. Scope counters by source/key and
network according to the descriptor scheme. Extend address tracking beyond
WalletAccount.address so balance/coin selection includes every discovered receive
and change address. Keep application DTOs outside coinlib/Frosty types.

Keep Iroh server identity, participant authentication key and DKG secret share
distinct. Secure storage supplies protected wrapping/identity keys; encrypted
durable storage holds the share packages and signing state. Implement the full
ClientStorageInterface atomic preparation contract. A series of independent
Hive puts is insufficient: choose a transactional store, or first prove a
single-record encrypted persistence design meets atomicity and crash durability.

The ordinary mnemonic does not recreate a randomly generated DKG share. A ROAST
recovery package must include the participant identity, local completed key
package, public group/key descriptors and allocation metadata, encrypted with
a recoverable user-controlled mechanism. Coordinator recovery also needs its
identity and registry. Restore must not reactivate old nonce caches or duplicate
an active signer identity on two devices; invalidate old signing sessions and
establish fresh nonce state. Define and test the restore procedure explicitly.

The current client persistence interface does not store unfinished DKG secrets.
Persist the setup draft, but show Interrupted after a process loss and reconcile
any locally completed key before offering a fresh DKG attempt. A new attempt
gets a new ceremony ID and must not replace a key that already received funds.
Do not promise automatic DKG continuation merely because the UI draft survives.

Changing only coordinator location preserves the key and wallet addresses.
Require authenticated approval of a new endpoint pin and restore the finalized
group/registry on the new coordinator. Losing the coordinator does not itself
lose funds; losing too many usable shares can. For an initial release use an
explicit move/restore workflow rather than transparent coordinator election.

**9. Implementation sequence and acceptance criteria.**

1. Add explicit key-source references, setup drafts, states and address records;
   extend the existing creation flow and preserve personal accounts. Version the
   vault format and retain existing keys, paths and indexes during upgrade.
2. Prove the desktop adapter, identity persistence and production client storage
   with two real app instances. First use preconfigured participant cards, then
   add address-first enrollment and manifest confirmation as a distinct layer.
3. Complete DKG, backup/restore, the account registry and public derivation. Show
   multiple wallets under one key through the existing ElectrumX dashboard.
4. Implement common send/review and ROAST requests, derived Taproot signing,
   transaction validation, UTXO reservations and broadcast reconciliation.
5. Exercise interruptions and coordinator migration before widening platform
   support. Keep future delegated event decisions behind the same explicit
   proposal/authorization boundary described in roadmap.md.

Acceptance checks must include a 2-of-3 setup, all three participants present
during DKG, successful signing with any authorized pair, equal derived addresses
on all peers, distinct account/network paths, concurrent account/index
allocation, offline receive/balance behavior, hidden-wallet incoming requests,
client replacement on reconnect, DKG interruption, a crash between signing
preparation and RPC response, share restoration without nonce reuse, and a real
Peercoin transaction with derived receive and change keys. The existing personal
wallet workflow and unsupported-platform builds must continue to work.

Source map for implementation:

- Sygnature: lib/main.dart, lib/ui/onboarding_screen.dart,
  lib/ui/wallet_home.dart, lib/controllers/wallet_controller.dart,
  lib/models/wallet_account.dart, lib/models/wallet_vault.dart,
  lib/services/wallet_key_service.dart and roadmap.md.
- ../noosphere_flutter: README.md, lib/src/node.dart,
  lib/src/initialization.dart, lib/src/lifecycle.dart and
  integration_test/roast_2_of_2_test.dart.
- ../noosphere_roast_client/lib/src: config/group.dart, config/client.dart,
  client/client.dart, client/storage_interface.dart,
  api/types/single_signature_details.dart and api/types/signature_metadata.dart.
- ../noosphere_roast_server/lib/src: config/server.dart, iroh/server.dart and
  server/state/state.dart.
- ../frosty/frosty/lib/src/key_info/hd: hd_key_info.dart, aggregate.dart and
  participant.dart.
