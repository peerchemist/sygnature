# Sygnature

Cross-platform Peercoin light-wallet foundation built with Flutter.

## Current scope

- responsive mobile/tablet/desktop wallet shell;
- English-only, utilitarian interface;
- compact two-step onboarding for mnemonic configuration and the future BIP-86
  derivation stage;
- multiple named sub-wallet accounts under one future root seed;
- AES-256 encrypted Hive CE vault;
- vault encryption key stored separately through `flutter_secure_storage`;
- Linux data stored under the XDG application-support directory instead of the
  user's Documents directory;
- application identifier `com.github.peerchemist.sygnature` across Linux,
  Android, iOS and macOS;
- nullable address, derivation path and private-key fields ready for coinlib;
- one `attachDerivedMaterial` integration seam for persisting coinlib output.

No addresses or private keys are fabricated. BIP-39/BIP-32 and Peercoin key
derivation are intentionally deferred to the coinlib integration.

The wallet will support Taproot BIP-86 accounts only. See [roadmap.md](roadmap.md)
for the planned integration sequence.

## UI model

- Under 920 px: app bar, horizontal wallet switcher and one-column dashboard.
- From 920 px: persistent wallet sidebar and two-column detail cards.
- Sub-wallet creation works now; accounts remain in a "waiting for coinlib"
  state until derived material is attached.

## Structure

```text
lib/
  controllers/   presentation state and coinlib integration seam
  models/        serializable vault and sub-wallet records
  storage/       encrypted Hive CE repository
  ui/            onboarding, responsive wallet shell, theme
```

Run checks with:

```sh
flutter analyze
flutter test
```
