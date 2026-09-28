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
  generation (DKG), quorum health, transaction and message-signing approvals,
  and persistent recovery of interrupted transaction operations.
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

1. Someone creates a ROAST group and decides how many people can sign and how
   many signatures are needed to spend.
2. Each signer shares the public key from their device with the group creator.
   It is only used to identify them—no private keys or wallet shares are sent.
3. The creator adds those public keys and makes a separate invite for each
   signer. An invite only works for the person it was made for.
4. Each signer pastes their invite into Sygnature and joins over an encrypted
   Iroh connection.
5. Once everyone is in, the signers approve DKG. This creates the shared wallet
   address, while every signer keeps their own private share on their device.
6. The shared Taproot address can now receive Peercoin like any other wallet.
7. When someone wants to spend, Sygnature asks the other signers to review and
   approve the transaction. As soon as enough people approve, the transaction
   is signed and sent to the Peercoin network through ElectrumX.
8. An active ROAST setup can also sign exact text with its untweaked group key.
   Signers review the exact text separately from the authenticated request note;
   the requester receives a verified, portable Noosphere signed-message JSON.

Wallet names are local labels and may differ between participants. Participant
aliases are also editable; cryptographic identities and key fingerprints are
the authoritative identifiers.

## ROAST events

Noosphere delivers changes in a ROAST group as events, allowing every connected
wallet to update its screen from the same coordinator state. A signature
request event tells signers that a transaction or exact text needs approval and
includes validated metadata, an optional authenticated note and an expiry.

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
- ROAST runtime support currently targets Android, Linux and macOS.

Detailed design notes are available in [roast-workflow.md](roast-workflow.md)
and [ARCHITECTURE.md](ARCHITECTURE.md).

## Development

```sh
flutter analyze
flutter test
flutter run -d linux
```
