/// The Android side of [ImageConverter], over a method channel this app owns.
///
/// One method, one argument, one answer. The decoder is Android's own
/// `ImageDecoder` (API 28 and up), which is already on the phone: converting a
/// HEIC needs an HEVC decoder, the platform has one, and adding an image
/// codec to a Flutter app to repeat it would be a dependency this app does not
/// need (the design's own stop condition).
///
/// Every way the channel can go wrong answers `null`, which the seam reads as
/// "not converted" and passes the original through:
///
///   * `MissingPluginException` — the host has no such channel. That is every
///     build that is not the Android app, including the whole test suite, and
///     it must not turn a pick into a failure;
///   * `PlatformException` — the Kotlin side refused the call;
///   * an answer that is not a path.
///
/// The Kotlin half is
/// `android/app/src/main/kotlin/com/localcanvas/localcanvas/HeicJpegConversion.kt`,
/// wired up in `MainActivity`.
library;

import 'package:flutter/services.dart';

import 'heic_conversion.dart';

/// The channel name, under this app's own id so it can collide with nothing.
const String kHeicConversionChannel = 'com.localcanvas.localcanvas/heic_jpeg';

/// The one method it carries.
const String kHeicConversionMethod = 'heicToJpeg';

class PlatformImageConverter implements ImageConverter {
  const PlatformImageConverter();

  static const MethodChannel channel = MethodChannel(kHeicConversionChannel);

  @override
  Future<String?> heicToJpeg(String path) async {
    final Object? answer;
    try {
      answer = await channel.invokeMethod<String>(
        kHeicConversionMethod,
        <String, Object?>{'path': path, 'quality': kHeicJpegQuality},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
    if (answer is! String || answer.isEmpty) return null;
    return answer;
  }
}
