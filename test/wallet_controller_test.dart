import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  test(
    'persists multiple account shells and accepts coinlib material',
    () async {
      final repository = MemoryWalletRepository();
      final controller = WalletController(repository);
      await controller.load();

      await controller.createWalletShell(
        languageId: 'english',
        mnemonicWordCount: 24,
      );
      await controller.addAccount('Savings');
      await controller.attachDerivedMaterial(
        accountIndex: 1,
        address: 'PexampleAddress',
        privateKeyHex: 'deadbeef',
        derivationPath: "m/86'/6'/1'/0/0",
      );

      final restored = WalletController(repository);
      await restored.load();
      expect(restored.accounts, hasLength(2));
      expect(restored.accounts[1].name, 'Savings');
      expect(restored.accounts[1].address, 'PexampleAddress');
      expect(restored.accounts[1].privateKeyHex, 'deadbeef');
      expect(restored.vault?.languageId, 'english');
      expect(restored.vault?.mnemonicWordCount, 24);
    },
  );
}
