/// The native launch window — everything the user sees *before* the first
/// Flutter frame (`docs/ui-ux.md`, "Startup experience").
///
/// `startup_test.dart` covers the frames Flutter draws. It cannot cover the
/// window the OS paints while the process is still starting, because no widget
/// is involved: that window is Android resource XML, and the only thing a
/// desktop test can do about it is read the XML and hold it to the same tokens
/// the widgets use. So that is what this file does.
///
/// It exists because the stock Flutter template shipped `@android:color/white`
/// here, which is the blank white screen the contract forbids by name. Whether
/// the hand-over is *visually* seamless is a device observation and is not
/// claimed here; whether both sides are the same colour is not, and is.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/theme/tokens.dart';

/// The Android resource root, relative to the Flutter package `flutter test`
/// runs from.
const String kRes = 'android/app/src/main/res';

/// Every `values*` directory that defines the two window themes, paired with
/// the palette its colours must come from.
const Map<String, Brightness> kThemeDirs = <String, Brightness>{
  'values': Brightness.light,
  'values-night': Brightness.dark,
  'values-v31': Brightness.light,
  'values-night-v31': Brightness.dark,
};

/// The two launch-window drawables. `drawable-v21` is the one every supported
/// device actually resolves; `drawable` is the floor, and both are checked so
/// neither can be left behind.
const List<String> kLaunchDrawables = <String>[
  'drawable/launch_background.xml',
  'drawable-v21/launch_background.xml',
];

String readRes(String path) {
  final file = File('$kRes/$path');
  expect(
    file.existsSync(),
    isTrue,
    reason: '$kRes/$path is missing (cwd ${Directory.current.path})',
  );
  return file.readAsStringSync();
}

/// `#AARRGGBB`, the form Android writes and `Color` stores.
String hexOf(Color colour) =>
    '#${colour.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}';

/// The value of `<color name="...">` in a resource file.
String? colourNamed(String xml, String name) =>
    RegExp('<color\\s+name="$name"\\s*>\\s*([^<]+?)\\s*</color>')
        .firstMatch(xml)
        ?.group(1);

/// The body of `<style name="...">…</style>`.
String styleNamed(String xml, String name, {required String where}) {
  final match = RegExp(
    '<style\\s+name="$name"[^>]*>(.*?)</style>',
    dotAll: true,
  ).firstMatch(xml);
  expect(match, isNotNull, reason: '$where does not define a $name style');
  return match!.group(1)!;
}

/// The value of one `<item name="...">` inside a style body.
String? itemNamed(String style, String name) =>
    RegExp('<item\\s+name="$name"\\s*>\\s*([^<]+?)\\s*</item>')
        .firstMatch(style)
        ?.group(1);

void main() {
  group('the canvas is one token, expressed twice', () {
    test('each colors.xml carries its own half of LcPalette.canvas', () {
      expect(
        colourNamed(readRes('values/colors.xml'), 'lc_canvas'),
        hexOf(LcPalette.light.canvas),
        reason: 'the light launch window is not the light canvas',
      );
      expect(
        colourNamed(readRes('values-night/colors.xml'), 'lc_canvas'),
        hexOf(LcPalette.dark.canvas),
        reason: 'the dark launch window is not the dark canvas',
      );
    });

    test('the two halves are different colours', () {
      // A copy-paste that gave dark mode the light value would satisfy every
      // "is a hex string" check and be wrong on half the phones.
      expect(
        colourNamed(readRes('values/colors.xml'), 'lc_canvas'),
        isNot(colourNamed(readRes('values-night/colors.xml'), 'lc_canvas')),
      );
    });
  });

  group('the launch drawable', () {
    for (final path in kLaunchDrawables) {
      test('$path is a flat fill of the canvas colour', () {
        final xml = readRes(path);
        expect(
          RegExp('<item[^>]*android:drawable="@color/lc_canvas"').hasMatch(xml),
          isTrue,
          reason: '$path does not fill with @color/lc_canvas',
        );
        // One layer. `StartupIntro`'s frame 0 is this same canvas with the
        // mark at opacity 0, so a flat fill is the pixel-exact still of the
        // frame this window hands over to; a second layer here would create a
        // discontinuity rather than cover one. (What Android 12+ draws over
        // the top of it is the platform's own splash icon, which this drawable
        // does not control — see the file's own comment.)
        expect(
          RegExp('<item[\\s>]').allMatches(xml).length,
          1,
          reason: '$path has more than the single fill',
        );
      });
    }
  });

  group('the window themes', () {
    kThemeDirs.forEach((dir, brightness) {
      test('$dir paints both themes in the canvas', () {
        final xml = readRes('$dir/styles.xml');
        final launch = styleNamed(xml, 'LaunchTheme', where: dir);
        final normal = styleNamed(xml, 'NormalTheme', where: dir);

        expect(
          itemNamed(launch, 'android:windowBackground'),
          '@drawable/launch_background',
          reason: '$dir LaunchTheme does not use the launch drawable',
        );
        // The attribute the rest of the platform reads when it wants to know
        // what colour this window is.
        for (final style in <String>[launch, normal]) {
          expect(
            itemNamed(style, 'android:colorBackground'),
            '@color/lc_canvas',
            reason: '$dir leaves colorBackground on the platform default',
          );
        }
        expect(
          itemNamed(normal, 'android:windowBackground'),
          '@color/lc_canvas',
          reason: '$dir NormalTheme does not use the canvas',
        );
        // And the parent that decides every attribute not listed above still
        // matches the brightness this directory is for.
        expect(
          RegExp('<style\\s+name="LaunchTheme"\\s+parent="([^"]+)"')
              .firstMatch(xml)
              ?.group(1),
          brightness == Brightness.dark
              ? '@android:style/Theme.Black.NoTitleBar'
              : '@android:style/Theme.Light.NoTitleBar',
          reason: '$dir inherits the wrong platform theme for $brightness',
        );
      });

      test('$dir names no platform default colour', () {
        final xml = readRes('$dir/styles.xml');
        // `?android:colorBackground` resolved through the platform parents to
        // pure white and pure black; `@android:color/white` was the template's
        // own value. Either one back in this file is the defect returning.
        for (final forbidden in <String>[
          '?android:colorBackground',
          '@android:color/white',
          '@android:color/black',
          '@android:color/background_light',
          '@android:color/background_dark',
        ]) {
          expect(
            xml,
            isNot(contains(forbidden)),
            reason: '$dir still names $forbidden',
          );
        }
      });
    });

    for (final path in kLaunchDrawables) {
      test('$path names no platform default colour', () {
        final xml = readRes(path);
        for (final forbidden in <String>[
          '?android:colorBackground',
          '@android:color/white',
          '@android:color/black',
        ]) {
          expect(xml, isNot(contains(forbidden)), reason: '$path names $forbidden');
        }
      });
    }
  });

  group('Android 12 draws its own splash, so it is told the colour', () {
    for (final dir in <String>['values-v31', 'values-night-v31']) {
      test('$dir sets windowSplashScreenBackground', () {
        final launch = styleNamed(
          readRes('$dir/styles.xml'),
          'LaunchTheme',
          where: dir,
        );
        expect(
          itemNamed(launch, 'android:windowSplashScreenBackground'),
          '@color/lc_canvas',
          reason:
              '$dir leaves the API 31+ splash background to a platform '
              'fallback',
        );
      });
    }

    test('the night copy exists, because night outranks version', () {
      // Android resolves qualifiers in a fixed order and night mode is ranked
      // above platform version, so `values-night/` wins over `values-v31/` on
      // a dark Android 12 phone. Without `values-night-v31/` that phone gets
      // no splash colour at all.
      expect(File('$kRes/values-night-v31/styles.xml').existsSync(), isTrue);
    });
  });

  test('the manifest still uses the themes this file checks', () {
    // Everything above is inert if the activity is pointed somewhere else.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:theme="@style/LaunchTheme"'));
    expect(manifest, contains('android:resource="@style/NormalTheme"'));
  });
}
