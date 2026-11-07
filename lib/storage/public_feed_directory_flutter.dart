import 'dart:io';

import 'package:flutter/services.dart';

Future<String> preparePublicFeedDirectory(String directory) async {
  if (!Platform.isIOS) return directory;
  // Only a storage path crosses this channel, never feed credentials.
  return (await const MethodChannel(
    'network.noosphere.sygnature/public-feed-storage',
  ).invokeMethod<String>('prepare', {'directory': directory}))!;
}
