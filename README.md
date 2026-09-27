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

1. The host creates a room and chooses the participant count and threshold.
2. Each signer generates a participant identity locally and gives its public
   participant card to the host.
3. The host creates a separate, short-lived invitation bound to that signer's
   public key. The invitation cannot be used by another participant identity.
4. Signers import their invitations and join the room over Iroh. Once the
   expected roster is present, the room is frozen.
5. The host requests DKG and every signer reviews and approves it. DKG creates
   one shared public key and a private key share on each participant device.
6. The resulting Taproot address can receive Peercoin like a normal wallet.
7. Spending creates an immutable ROAST request containing Taproot transaction
   metadata and an optional authenticated message. Signers review the
   recipients, change, fee and expiry. Once the threshold is reached, the
   aggregate signature is applied and the transaction is broadcast through
   ElectrumX.

Wallet names are local labels and may differ between participants. Participant
aliases are also editable; cryptographic identities and key fingerprints are
the authoritative identifiers.

## Iroh connectivity and star topology

[Iroh](https://www.iroh.computer/) provides authenticated QUIC connectivity,
NAT traversal and relay fallback. Noosphere supplies the room, authentication,
DKG and ROAST coordination protocol carried over those connections.

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

Iroh tries to establish a direct path, including NAT hole punching. If that is
not possible, an [Iroh relay](https://www.iroh.computer/services/hosting)
forwards the encrypted QUIC traffic. The route may change without changing the
ROAST protocol. Relays cannot read the connection payload; the coordinator is
the application endpoint and distributes room events to the signers.

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
