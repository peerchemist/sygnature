// Run as a fresh Dart process with no Flutter engine or signer initialization.
import 'dart:convert';
import 'dart:io';

import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:hive_ce/hive.dart';

Future<void> main(List<String> args) async {
  await initializePublicFeedNative(
    libraryPath: Platform.environment['IROH_NATIVE_LIBRARY'],
  );
  final store = await PublicFeedStore.open(args.single);
  final poller = PublicFeedPoller(
    store,
    notify: (_, _) async => throw StateError('Initial history must be silent'),
  );
  await poller.run();
  final state = await store.snapshot();
  final feed = (state['feeds'] as Map).values.single as Map;
  stdout.writeln(
    jsonEncode({
      'cursor': feed['cursor'],
      'issue': feed['issue'],
      'events': (feed['events'] as Map).length,
      'privateStorageOpen': Hive.isBoxOpen('sygnature_roast_private_v1'),
      'signerLibrariesLoaded': Platform.isLinux
          ? RegExp(r'lib(frosty|secp256k1)')
                .hasMatch(File('/proc/self/maps').readAsStringSync())
          : null,
    }),
  );
  await store.close();
}
