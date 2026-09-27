# Sygnature

Sygnature is a cross-platform Peercoin light wallet built with Flutter. It
supports ordinary single-user wallets and ROAST threshold wallets in which no
participant ever holds the complete private key.

## Core features

- Peercoin mainnet and testnet with Taproot key-path transactions.
- Personal wallets derived from a BIP-39 recovery phrase using BIP-86.
- Multiple locally named wallets and encrypted Hive storage backed by platform
  secure storage.
- ElectrumX balance and UTXO synchronization, server failover, transaction
  construction, signing and broadcast.
- ROAST shared wallets with participant-bound invitations, distributed key
  generation (DKG), quorum health, signing approvals and persistent recovery
  of interrupted operations.
- A recent-activity feed for DKG, signature requests, signing and broadcast
  events.

## Personal wallet workflow

```text
Create or import recovery phrase
  -> create a named Peercoin account
  -> synchronize through ElectrumX
  -> receive or prepare a payment
  -> review and sign locally
  -> broadcast through ElectrumX
```

## ROAST shared-wallet workflow

1. The host creates a ROAST group, chooses how many signers it has and how many
   approvals are required.
2. Each signer generates a participant identity on their device and sends its
   public key to the host. This is an authentication key, not a private key or
   wallet key share.
3. The host enters those public keys and creates one invitation for each
   signer. Every invitation is bound to its intended public key, so it cannot
   be used from a different participant identity.
4. The host sends each invitation to its signer. The signer pastes it into
   Sygnature and joins the group through an encrypted Iroh connection.
5. When everyone has joined, the group is locked and the signers approve DKG.
   DKG creates one shared public key while leaving each device with only its
   own private share.
6. The resulting Taproot address receives Peercoin like a normal wallet.
7. Spending creates a ROAST signature request containing Taproot transaction
   metadata and an optional authenticated message. Signers review the
   recipients, change, fee and expiry. Once the threshold is reached, the
   aggregate signature is applied and the transaction is broadcast through
   ElectrumX.

Wallet names are local labels and may differ between participants. Participant
aliases are also editable; cryptographic identities and key fingerprints are
the authoritative identifiers.

## ROAST events

Noosphere delivers changes in a ROAST group as events, allowing every connected
wallet to update its screen from the same coordinator state. A signature
request event, for example, tells signers that a transaction needs approval and
includes the authenticated transaction metadata, optional message and expiry.

Other events report signer availability, DKG requests and progress, new signing
rounds, completion, rejection or failure. Sygnature presents requests requiring
attention at the top of the ROAST screen and records relevant lifecycle events
in Recent Activity; low-level Iroh network traffic is not activity history.

## Iroh connectivity and star topology

[Iroh](https://www.iroh.computer/) gives the coordinator a cryptographic
endpoint identity and opens encrypted QUIC connections from signers, first
trying a direct path with NAT traversal and then using a relay when necessary.
Each signer connects only to the coordinator, which distributes Noosphere room,
DKG and ROAST events in a star topology while any relay only forwards encrypted
traffic.

Sygnature deliberately uses a star topology rather than a signer-to-signer
mesh:

```text
                       Iroh / QUIC
Signer A  ---------------------------------+
Signer B  ---------------------------------+--> Coordinator
Signer C  ---------------------------------+       |- room and session state
                                                  |- event distribution
                                                  `- DKG/ROAST coordination
```

Every signer establishes its own authenticated connection to the coordinator.
The coordinator may also run a separate local signer, but hosting does not
count as an approval by itself. Invitations pin the coordinator's Iroh endpoint
identity and contain direct-address or relay hints.

The coordinator is required for room availability and message delivery, but it
cannot produce a threshold signature alone. Iroh endpoint identity, participant
authentication keys and FROST key shares are separate cryptographic roles.

## Security and current scope

- Secret wallet material and ROAST state are stored in encrypted local vaults.
- Signing requests are validated against the expected shared key, derivation
  path, wallet scripts, known unspent outputs and supported sighash mode.
- Transaction metadata is displayed before approval and is cryptographically
  bound to the requested signatures.
- ElectrumX is the current blockchain data and broadcast provider.
- ROAST runtime support currently targets Linux and macOS.

Detailed design notes are available in [roast-workflow.md](roast-workflow.md)
and [ARCHITECTURE.md](ARCHITECTURE.md).

## Development

```sh
flutter analyze
flutter test
flutter run -d linux
```
