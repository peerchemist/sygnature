# Sygnature encrypted wallet backup, version 1

Extension: `.sygnaturebkp`. The extension is a UI convention; the binary magic
is `ROASTBAK`. This is a new format, with no legacy decoding or migrations.
All keys, identifiers and passwords below are public synthetic test data.

## Envelope

The file is `header || ciphertext || tag`. Header length is exactly 60 bytes;
tag length is exactly 16 bytes. There are no lengths, terminators, filenames or
identifiers outside the ciphertext. Every multibyte header integer is unsigned,
big-endian. Offsets are zero-based.

| Offset | Bytes | Value |
| --- | --- | --- |
| 0 | 8 | ASCII `ROASTBAK` (`524f41535442414b`) |
| 8 | 1 | Format version `1` |
| 9 | 1 | KDF `1`: Argon2id v1.3 (version integer 19) |
| 10 | 1 | Cipher `1`: XChaCha20-Poly1305-IETF |
| 11 | 4 | Argon2 memory cost in KiB |
| 15 | 4 | Argon2 iteration count |
| 19 | 1 | Argon2 parallelism |
| 20 | 16 | Random salt |
| 36 | 24 | Random nonce |
| 60 | file length minus 76 | Ciphertext |
| file length minus 16 | 16 | Poly1305 tag |

Reject unknown format, KDF and cipher identifiers before deriving a key.
Accepted file sizes are 77 through 16,777,216 bytes. A v1 document is larger than
the minimal envelope. Before allocating KDF memory, enforce memory 65,536 through
262,144 KiB, iterations 3 through 10, and parallelism 1 through 4; memory must be
divisible by `4 * parallelism`. Export always uses 65,536 KiB, 3 iterations,
parallelism 1 and a 32-byte output. Never downgrade these parameters on failure.

The backup passphrase is encoded **exactly as UTF-8**: no trimming, case folding,
Unicode normalization or implicit terminator. This differs from BIP-39's seed
derivation normalization. UI export requires at least **8 Unicode scalar
characters** and matching confirmation; import does not impose a minimum on
historical passwords. The format itself does not encode a password policy.
Long, randomly chosen passphrases remain strongly recommended.

Derive `K = Argon2id(password_utf8, salt, memory, iterations, parallelism,
output_length=32, version=19)`, with no optional secret or associated data inputs.
Encrypt the deterministic CBOR bytes with XChaCha20-Poly1305-IETF using `K`, the
24-byte nonce, and **all original 60 header bytes as AAD**. Append ciphertext then
the 16-byte tag, without an additional nonce or length prefix. Authentication
must succeed before CBOR parsing, previewing wallet metadata, or modifying any
database. Each real export generates a new salt and nonce from a secure RNG.

Production uses `package:cryptography`'s pure-Dart Argon2id and
`Xchacha20.poly1305Aead()`, in a separate isolate. Export decrypts its own result
with the derived key and compares the exact plaintext before offering the file.
Plaintext CBOR is never written to disk. Mutable owned entropy/share/plaintext
buffers are cleared where practical; Dart GC, immutable strings, domain objects
and isolate copies prevent any guarantee of memory erasure.

## Deterministic CBOR profile

Use RFC 8949 section 4.2.1 core deterministic encoding. All maps have text keys,
sorted lexicographically by the **complete encoded CBOR key bytes**, not by Dart
insertion order or text comparison. Use shortest integer and length encodings,
definite-length arrays, maps, byte strings and UTF-8 text strings. Permitted
values are unsigned integers (at most `2^53-1`), text, byte strings, arrays,
maps, booleans and null. No negative integers, floats, tags, indefinite lengths
or trailing data. Reject duplicate/nonascending map keys and invalid UTF-8
before decoding into a map. There is exactly one root document.

Reject depth greater than 24, more than 100,000 total items, or arrays/maps with
more than 10,000 entries. Scalar text fields are at most 4,096 UTF-16 code units;
IDs and names are nonempty unless explicitly noted below. All listed map fields
are required, including nullable fields. Missing or unknown keys are errors.

Collections without semantic ordering have these additional rules:

- Groups sort by `setup_id`, accounts by `id`, transitions by `transition_id`,
  using lexicographic UTF-8 bytes (without Unicode normalization).
- Participants, verification shares, acknowledgements and enrollment times sort
  by the exact 32-byte participant identifier, lexicographically.
- Signing keys sort by their 33-byte group public key, lexicographically.
- Relay URLs, IP addresses, migration operation IDs and transaction IDs sort
  lexicographically by UTF-8 bytes.

Reject duplicate account/setup/group/transition IDs, participant identifiers,
identity public keys, card IDs, signing group public keys, acknowledgement
signers and room enrollment identifiers. Re-encoding a decoded DTO must produce
exactly the authenticated input bytes, including collection ordering.

Notation below: `u` = nonnegative integer; `t` = text; `bN` = byte string of
exactly N bytes; `?` = nullable; `[T]` = array. Times ending `_ms` are UTC Unix
milliseconds, from 0 through 8,640,000,000,000,000. Root `created_at` is UTC Unix
**seconds**, from 0 through 8,640,000,000,000.

## Exact payload schema

```text
Root = {
  "schema_version": 1,
  "created_at": u,
  "wallets": [Wallet],                # zero or one; app has one mnemonic vault
  "groups": [Group]
}
Wallet = {
  "wallet_id": "local",
  "mnemonic": Mnemonic?,
  "next_account_index": u,            # 0..2^31
  "accounts": [Account],
  "transitions": [Transition]
}
Mnemonic = {
  "type": "bip39",
  "entropy": bytes,                  # exactly 16 or 32 bytes (12 or 24 words)
  "language": t,
  "passphrase": ""                   # app does not support BIP-39 passphrases
}
Account = {
  "id": t, "name": t,
  "account_index": u,                 # 0..2^31-1
  "blockchain_id": "peercoin",
  "network_id": "mainnet" | "testnet",
  "key_source": "personal" | "watchOnly" | "roast",
  "source_id": t?,                    # roast setup_id, otherwise existing value
  "key_id": t?,                       # application key name for roast, not key bytes
  "derivation_path": t?,
  "address": t?,
  "private_key": b32?,                # personal Taproot-tweaked spend key only
  "created_at_ms": u,
  "archived_at_ms": u?
}
Group = {
  "setup_id": t, "group_id": t, "name": t,
  "role": "host" | "member",
  "protocol": "noosphere/0.1.1",
  "protocol_version": 1,
  "frost_ciphersuite": "FROST-secp256k1-SHA256-TR-v1",
  "threshold": u,                     # 2..participant_count
  "participant_count": u,             # 2..65535, also subject to CBOR limits
  "blockchain_id": "peercoin",
  "network_id": "mainnet" | "testnet",
  "local_card_id": t,
  "identity_private_key": b32,
  "key_name": t,                      # 3..40 UTF-16 code units
  "created_at_ms": u,
  "iroh_identity_index": u,            # 0..2^31-1
  "uses_room_enrollment": bool,
  "host_participant_id": b32?,         # required nonnull for functioning groups
  "coordinator_id": t?,               # required nonnull: pinned Iroh public key z32
  "coordinator_relay_urls": [t],
  "coordinator_ip_addrs": [t],
  "group_fingerprint": b32?,          # required nonnull for functioning groups
  "group_public_key": b33?,           # required nonnull; one of keys
  "participants": [Participant],
  "keys": [SigningKey],
  "room": Room?
}
Participant = {
  "card_id": t, "name": t,
  "participant_id": b32,
  "identity_public_key": b33
}
SigningKey = {
  "group_public_key": b33,
  "threshold": u,
  "participant_id": b32,
  "secret_share": b32,
  "name": t, "description": t,        # description may be empty
  "verification_shares": [VerificationShare],
  "acknowledgements": [Acknowledgement]
}
VerificationShare = { "participant_id": b32, "public_key": b33 }
Acknowledgement = {
  "participant_id": b32, "accepted": bool, "signature": b64
}
Room = {
  "coordinator_endpoint_id": b32,
  "enrollment_times": [EnrollmentTime]
}
EnrollmentTime = { "participant_id": b32, "enrolled_at_ms": u }
Transition = {
  "transition_id": t, "source_setup_id": t, "successor_setup_id": t,
  "proposal": bytes,
  "dkg_details": { t: bytes },         # key-plan ID -> NewDkgDetails bytes
  "signed_approvals": { t: bytes },    # lowercase SEC1 identity hex -> signed approval
  "phase": "proposed" | "preparing" | "ready" | "migrationPending" |
           "active" | "retired" | "failed" | "outcomeUnknown",
  "migration_operation_ids": [t],
  "transaction_ids": [t],
  "created_at_ms": u, "updated_at_ms": u
}
```

`group_id` is the application's exact text ID, not an invented cryptographic
identifier. `protocol` pins the application's Noosphere dependency release;
the dependency package itself currently reports 0.1.0. The wire version is 1.
No group epoch exists in the current persistent model; none is fabricated.

## Mnemonics, keys and identity

Language IDs are `english`, `czech`, `french`, `italian`, `japanese`, `korean`,
`portuguese`, `spanish`, `chinese-simplified`, `chinese-traditional`. Reconstruct
the standard BIP-39 checksum and word list from entropy and language and verify
the entropy round trip. Nonstandard mnemonics and nonempty BIP-39 passphrases are
unsupported, not silently discarded. The backup encryption passphrase is
unrelated to the empty BIP-39 seed passphrase.

Personal account paths are existing BIP-86 paths, currently
`m/86'/6'/account'/0/0` on mainnet and `m/86'/1'/account'/0/0` on testnet. Derive
using the standard BIP-39 seed and BIP-32, then BIP-341 Taproot key-path tweaking;
compare stored path, address and spend private key. Addresses use the network's
existing Peercoin parameters. Preserve ROAST paths exactly, as `R/n/n/...`;
these are the existing threshold derivation path, not BIP-32 private derivation.
For a ROAST account, `key_id` is the exact textual application key name and must
equal its referenced group's `key_name`. Resolve the unique signing key with
that name and the group's expected key description; its `group_public_key`
must equal the group's `group_public_key`. Derive the account address using
that public key, not `key_id`. Cryptographic key material remains byte strings.
The expected key description is the compact JSON array (no formatting spaces)
`["sygnature-roast-wallet-v1", group.name, group.blockchain_id, group.network_id,
group.threshold, group.participant_count, lowercase_hex(group.group_fingerprint)]`.
String elements use JSON escaping; integer elements are JSON numbers.

All secp256k1 scalars/private keys/FROST identifiers are exactly 32-byte
big-endian encodings, nonzero and below the curve order. Public keys are SEC1
compressed points (33 bytes, prefix 02 or 03); Schnorr signatures are BIP-340
64-byte encodings. Do not reinterpret generic secp256k1 FROST as this Taproot
ciphersuite. Each key contains the **actual DKG-generated local share**. The
mnemonic cannot regenerate it. Only keys with the local roster participant's
identifier are exportable; duplicates do not increase the participant count.
Multiple group keys/local shares within that participant are preserved.

Validate the complete roster with the existing ROAST validator, including count,
threshold, identifier/public key encodings and uniqueness. The local identity
private key must produce the roster identity public key. Verification shares
must cover the roster exactly. The local secret share must produce its matching
verification public key. Each acknowledgement signature verifies with its
signer's roster identity, over the tagged hash `DkgAck` of
`compressed_group_key33 || accepted_byte` (0 or 1); tagged hash is
`SHA256(SHA256(tag_utf8) || SHA256(tag_utf8) || message)`. Preserve negative
acknowledgements: they are meaningful protocol state, not evidence of readiness.

The group fingerprint is SHA256 of `S(group_id) || u16LE(participant_count) ||`
the roster entries sorted by numeric identifier, each `identifier32 || pubkey33`.
`S` is specified in the binary consent section below.

The Iroh coordinator identity uses the existing deterministic BIP-85 scheme:
derive the BIP-32 private key at `m/83696968'/128169'/32'/index'` from the BIP-39
seed. Compute HMAC-SHA512 with key UTF-8 `bip-entropy-from-k` and message the
derived 32-byte private key; the first 32 result bytes are the Ed25519/Iroh secret
seed. Use standard Ed25519 key derivation. The public key is encoded in z-base-32
(alphabet `ybndrfg8ejkmcpqxot1uwisza345h769`, no padding, MSB-first) for
`coordinator_id`, or raw 32 bytes for room `coordinator_endpoint_id`. Host export
verifies both against the mnemonic and the exact index. All restored groups
require a mnemonic because the current runtime uses this derivation for local
Iroh identities. The separate secp256k1 participant identity private key is
backed up explicitly; it is not assumed mnemonic-derived.

A room is present only for a host with room enrollment. It must have been fully
frozen, with roster/count/threshold/fingerprint matching the group. Restore
reconstructs that public frozen room from the group and enrollment times, with
no invite tokens. Incomplete rooms, incomplete DKGs, orphaned signing keys,
HDParticipantKeyInfo and reconstructed/shared-private-key collection state fail
export descriptively instead of producing an incomplete backup.

## Persistent transition consent binary records

These byte strings preserve an existing language-neutral signed protocol,
**not Hive adapter bytes or Dart objects**. Unlike the outer header, all fixed
width integers in these records are **little-endian**. `B(x)` is Bitcoin
CompactSize(length) followed by exact bytes, and `S(x)` is `B(UTF8(x))`.
CompactSize is one byte for 0..252; otherwise fd + u16LE for 253..65535,
fe + u32LE through 2^32-1, or ff + u64LE; use shortest forms. Times are u64LE
UTC Unix milliseconds. No trailing bytes are allowed.

Proposal bytes concatenate, in order:

1. `S("noosphere/group-transition-proposal/1")`, u16LE(version=1),
   `S(transition_id)`, `B(source GroupConfig)`.
2. `S(successor_room_id)`, coordinator endpoint ID32, u16LE(successor count),
   successor SEC1 public keys33 sorted lexicographically.
3. u16LE(key-plan count), then plans sorted lexicographically by UTF-8 key ID
   bytes: `S(key_id)`, source group
   public key33, u16LE(source threshold), u16LE(target threshold), DKG hash32.
4. `S(migration_policy_kind)`, u16LE(policy version), `B(policy payload)`.
5. u64LE(created milliseconds), u64LE(expiry milliseconds).

Source GroupConfig uses the group fingerprint preimage described above.
Proposal hash is SHA256 of these complete bytes. Group/transition IDs in a
proposal are 1..255 UTF-8 bytes. Successor keys and plans are unique; both groups
and source fingerprint must match the corresponding backup group references.

NewDkgDetails bytes are `S(name) || S(description) || u16LE(threshold) ||`
`u64LE(expiry milliseconds)`. The plan's DKG hash is the tagged hash
`NewDkgDetails` of those bytes. Expired consent is preserved but never treated
as permission to run a new signing session.

Signed approval bytes are `S("noosphere/group-transition-approval/1") ||`
`proposal_hash32 || identity_public_key33 || u64LE(approved milliseconds) ||`
`signature64`. Verify a BIP-340 signature over SHA256 of all preceding approval
bytes, under that identity public key. Approval must name this proposal, an
identity in its source or successor roster, and a time inside its validity
window. Its map key is the lowercase hex of that public key.

Only migration policy kind `sygnature/peercoin-wallet-transition`, version 1,
is supported. Its payload concatenates:

```text
S("sygnature/wallet-transition-policy/1")
u16LE(1)
S(source_account_id) S(blockchain_id) S(network_id) S(key_id)
u16LE(path component count) repeated u32LE(path component)
u64LE(max_total_fee_sats) u32LE(max_fee_rate_sats_per_kb)
u16LE(minimum_confirmations) u16LE(max_migration_attempts)
one byte sweep_late_deposits (0 or 1)
```

Preserve the exact proposal, DKG details, approvals and transaction/operation
references. Terminal active/retired/failed progress stays terminal; all other
phases restore as `outcomeUnknown`, requiring chain/live-group reconciliation.
No migration or signing operation is automatically resumed from consent.

## Persistence audit and recovery policy

The original wallet data is one encrypted Hive CE box `sygnature_private_v1`,
key `wallet_vault`. It contains mnemonic/language/count, account derivation and
spend keys, ROAST setup identity keys/rosters, transitions, activity and UI
selection. There are no wallet-specific Hive adapters. ROAST has a second
encrypted box `sygnature_roast_private_v1`:

| Record | Recovery treatment |
| --- | --- |
| `client:setupId`, keys | Decode domain keys, export explicit DTO fields above |
| `rooms:setupId` | Export only frozen public room essentials above |
| client nonces, prepared/rejected requests | Never export or restore |
| `server-v1:setupId` | Never export; DKG/signing/session state is temporary |
| `wallet-signing-operations-v1` | Never export or restore |
| wallet activity, selection, UI/error/presence state | Excluded; resync/rebuild |

Secrets are mnemonic entropy, account private keys, participant identity private
keys and local secret shares. Public recovery data includes IDs, derivation
paths, public keys, verification shares, signatures, pinned peer addresses,
rosters, thresholds and consent. Hive encryption keys and platform key-store
contents are not needed by an independent reader and are not exported.

The controller blocks new signing and serializes wallet writes during export.
It waits for in-progress background connections and queued events, then rejects
genuinely active signing or ROAST operations. Expired, rejected and terminal
signing inbox records are not active operations. The runtime blocks new starts
and timer retries, drains background tasks, awaits acknowledged shutdown of all
local roles, and closes its worker before snapshotting durable recovery fields.
After the snapshot/encryption, it reconnects only groups that were previously
started, also on export failure. Previously offline groups remain offline;
restored groups requiring reconciliation are never automatically started.
Reconnect failures are reported separately and do not discard a valid backup.

Import first authenticates and validates **everything**, displays only counts,
networks and UTC creation date, then requires explicit confirmation. The file
digest is rechecked before committing. Current policy is intentionally
**empty wallet AND empty ROAST storage only**: no merging, duplicate participant
creation or silent overwrite of group IDs. A flushed import journal in ROAST
storage precedes any writes; signer/room records flush first, then the wallet
record with a commit marker flushes. On failure, staged records are removed.
If the process dies, startup compares that marker with the journal and either
keeps the complete import or removes uncommitted staging before exposing any
wallet or starting a signer. A rollback failure retains the journal and must
be resolved before use. This does not claim cross-box Hive transactions.

Every restored group starts interrupted/offline with reconciliation required.
Backups cannot prove freshness: compare pinned coordinator identity, roster,
fingerprint, threshold, keys and migration status with authenticated live
participants before explicitly allowing reconnection. There is no persisted
group epoch to compare. Never run two copies of the same participant share
concurrently. All nonce pools, active sessions, commitments, prepared requests,
coordination messages and temporary reconstructed secrets are absent; generate
fresh signing nonces with the existing signing implementation.

## Known-answer vector and example file

The empty-vault example has creation time 0, no wallets and no groups. It was
independently generated using Python argon2-cffi (Argon2 version 19), cbor2
canonical encoding, and PyNaCl's XChaCha20-Poly1305-IETF. These are test-vector
tools, not application dependencies. Fixed randomness is **test-only**.

```text
Passphrase: synthetic backup 🔐
Passphrase UTF-8 hex: 73796e746865746963206261636b757020f09f9490
Memory KiB: 65536   Iterations: 3   Parallelism: 1
Salt: 000102030405060708090a0b0c0d0e0f
Nonce: 101112131415161718191a1b1c1d1e1f2021222324252627
Derived key: 15479c7cda408971c7d9329ddc7762931436f536daf097e0b300ce0a5f79381e
CBOR (46 bytes):
a46667726f757073806777616c6c657473806a637265617465645f6174006e736368656d615f76657273696f6e01
Complete file (122 bytes):
524f41535442414b010101000100000000000301000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262780df443a76c32b93641f04e893c8239e754d579dd1c2b74b5023f769045c00b2176daf3b132c195a3d7e6d669b8f4691fc0d9a4c02fe7f4009cb503c9e74
```

`docs/fixtures/empty-v1.sygnaturebkp.hex` contains that complete example in hex.
Produce the binary file with:

```sh
xxd -r -p docs/fixtures/empty-v1.sygnaturebkp.hex empty-v1.sygnaturebkp
```

Independent reproduction (requires argon2-cffi, cbor2 and pynacl):

```python
from argon2.low_level import hash_secret_raw, Type
from nacl.bindings import crypto_aead_xchacha20poly1305_ietf_encrypt
import cbor2, struct
password = "synthetic backup 🔐".encode("utf-8")
salt, nonce = bytes(range(16)), bytes(range(16, 40))
header = b"ROASTBAK" + bytes([1, 1, 1]) + struct.pack(">IIB", 65536, 3, 1) + salt + nonce
key = hash_secret_raw(password, salt, 3, 65536, 1, 32, Type.ID, version=19)
plaintext = cbor2.dumps(dict(schema_version=1, created_at=0, wallets=[], groups=[]), canonical=True)
file = header + crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, header, nonce, key)
print(file.hex())  # synthetic test vector only; never print real wallet plaintext/keys
```

Additional deterministic vectors: `{"b":1,"a":2}` encodes
`a2616102616201`; bytes `[0,255]` encode `4200ff`;
`[0,23,24,255,256,65536,4294967296]` encodes
`870017181818ff1901001a000100001b0000000100000000`.
The synthetic signing fixture uses polynomial `f(x)=1+2x`, identifiers 1,2,
secret shares 3,5 and group secret 1, with identity secrets 9,10. The tests recover
its local share and produce/verify a fresh BIP-340 Taproot signature. These are
public fixtures, never production wallets.

## Versioning, UI and verification status

Envelope version and payload schema version are independent and currently both
1. Unknown versions, fields, protocols, ciphersuites and policy types fail
closed. Incompatible recovery metadata or semantic changes need a new schema
and/or envelope version; there is no guessing or legacy fallback.

Settings and onboarding provide backup export/import. Export uses the native
Save dialog with suggested name `wallet-YYYY-MM-DD.sygnaturebkp` (UTC). The app
sets no default directory: the desktop/provider chooses the initial location,
and the user chooses the destination. Only encrypted bytes reach the file
picker. Linux requires a working session D-Bus/XDG desktop file chooser portal;
fully restart the app after installing new plugins. Errors expose a fixed
operation stage and exception class, never an exception's potentially secret
contents. Import never applies changes before preview confirmation.

Linux unit/integration tests cover CBOR, independent crypto vectors, tampering,
real encrypted Hive persistence, crash/rollback, nonce exclusion and restored
signing. The benchmark tool runs default KDF encryption/self-verification and
decryption on synthetic data, printing timings and process RSS only:
`dart run tool/benchmark_wallet_backup.dart`. A Linux JIT sample took 559 ms for
export/self-verification and 491 ms for import; process peak RSS was about
490 MiB, including VM/compiler overhead, not just the 64 MiB Argon2 allocation.
This is not a mobile performance claim. Real Android/iOS memory/responsiveness
and desktop save-dialog testing remain required on supported hardware; never
lower parameters automatically. Existing runtime/native signing platform
support still applies; backup encryption adds no native cryptographic library.
