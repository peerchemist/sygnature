# Sygnature

Cross-platform Peercoin light-wallet foundation built with Flutter.

## Current scope

- responsive mobile/tablet/desktop wallet shell;
- English-only, utilitarian interface;
- compact two-step onboarding for creating or importing a BIP-39 recovery
  phrase and deriving BIP-86 accounts;
- multiple named sub-wallet accounts under one root seed;
- AES-256 encrypted Hive CE vault;
- vault encryption key stored separately through `flutter_secure_storage`;
- Linux data stored under the XDG application-support directory instead of the
  user's Documents directory;
- application identifier `com.github.peerchemist.sygnature` across Linux,
  Android, iOS and macOS;
- coinlib-backed BIP-86 address, derivation path and signing material;
- ElectrumX 1.4 WebSocket handshake with Peercoin genesis verification;
- mainnet/testnet backend failover, live UTXO subscriptions and balance display;
- network-validated Taproot send form with coin selection, fee review, local
  key-path signing and ElectrumX broadcast;
- one BIP-86 address per sub-wallet, used for both receiving and change;
- receive-address display and copy action.

No addresses or private keys are fabricated. BIP-39/BIP-32 derivation and
transaction construction/signing remain separate from the ElectrumX transport.

The wallet will support Taproot BIP-86 accounts only. See [roadmap.md](roadmap.md)
for the planned integration sequence.

## UI model

- Under 920 px: app bar, horizontal wallet switcher and one-column dashboard.
- From 920 px: persistent wallet sidebar and two-column detail cards.
- Sub-wallet creation derives one address from the selected network's BIP-86
  account path; that address is used for both receiving and change.

## Structure

```text
lib/
  controllers/   wallet state, synchronization and send orchestration
  models/        serializable vault and sub-wallet records
  services/      key/transaction services, ElectrumX transport and UI sounds
  storage/       encrypted Hive CE repository
  ui/            onboarding, responsive wallet shell, theme
```

Run checks with:

```sh
flutter analyze
flutter test
```
