/// The launcher icon, and the name of the file a person sideloads.
///
/// Two things about LocalCanvas are seen before a single Flutter frame is
/// drawn: the mark in the app drawer, and the filename in the file manager the
/// APK is opened from. Neither is a widget, so neither can be covered by a
/// widget test — they are Android resources and a Gradle script, and what a
/// desktop test can do about them is read the committed bytes and hold them to
/// the decisions that produced them.
///
/// Everything here is checked against the **committed assets**, not against a
/// fixture built in this file. A fixture that made the assertion true by itself
/// would be confirming the fixture (T-0182), and the
/// whole point is the files Android will actually load.
///
/// What it deliberately does not claim: whether the icon looks *good*. That was
/// checked by rendering it and looking at it, and is recorded on T-0136. A test
/// that asserted pixels would be dressing a judgement up as arithmetic.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// The Android resource root, relative to the Flutter package `flutter test`
/// runs from — the same anchor `launch_theme_test.dart` uses.
const String kRes = 'android/app/src/main/res';

/// The generator every asset below comes out of.
const String kGenerator = 'tool/generate_launcher_icons.py';

/// The build script that names the APK.
const String kBuildScript = 'android/app/build.gradle.kts';

/// `LcPalette.dark.canvas` — `lib/theme/tokens.dart`.
const List<int> kGround = <int>[0x0E, 0x0F, 0x12];

/// `LcPalette.accent` — `lib/theme/tokens.dart`.
const List<int> kAccent = <int>[0x8F, 0xA5, 0xF7];

/// Android's own table: the pixel size `ic_launcher.png` must be at each
/// density. Written out rather than derived from a base and a multiplier, so
/// that one wrong file is one wrong number and not a formula that still agrees
/// with itself.
const Map<String, int> kDensities = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

/// The adaptive icon's canvas, and the region a launcher mask is guaranteed to
/// keep: the circle inscribed in the centre 72×72dp of a 108×108dp canvas.
const double kViewport = 108;
const double kCentre = kViewport / 2;
const double kSafeRadius = 36;

File resFile(String path) {
  final file = File('$kRes/$path');
  expect(
    file.existsSync(),
    isTrue,
    reason: '$kRes/$path is missing (cwd ${Directory.current.path})',
  );
  return file;
}

// ---------------------------------------------------------------------------
// Just enough PNG to check a PNG.
// ---------------------------------------------------------------------------

/// One chunk of a PNG file, as it lies on disk.
class PngChunk {
  const PngChunk(this.kind, this.payload, this.recordedCrc);

  final String kind;
  final List<int> payload;
  final int recordedCrc;
}

/// CRC-32 as PNG defines it, over the chunk type and the chunk's payload.
///
/// Written out rather than taken from a package: it is fifteen lines, and a
/// checksum verified with the same code that produced it proves nothing. This
/// one is the reference implementation from the PNG specification.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final int byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

int _beInt(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Walks a PNG the way a decoder does: by its chunk lengths, to the last byte.
List<PngChunk> walkPng(List<int> data, {required String where}) {
  expect(
    data.sublist(0, 8),
    <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    reason: '$where does not start with the PNG signature',
  );
  final chunks = <PngChunk>[];
  var offset = 8;
  while (offset < data.length) {
    final int length = _beInt(data, offset);
    final String kind = ascii.decode(data.sublist(offset + 4, offset + 8));
    final List<int> payload = data.sublist(offset + 8, offset + 8 + length);
    final int recorded = _beInt(data, offset + 8 + length);
    chunks.add(PngChunk(kind, payload, recorded));
    offset += 12 + length;
  }
  expect(
    offset,
    data.length,
    reason: '$where does not end where its chunk chain says it does',
  );
  return chunks;
}

/// A decoded 8-bit RGBA image: `pixels[y][x]` is `[r, g, b, a]`.
class DecodedPng {
  const DecodedPng(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final List<List<List<int>>> pixels;
}

DecodedPng decodePng(List<int> data, {required String where}) {
  final List<PngChunk> chunks = walkPng(data, where: where);
  final PngChunk header = chunks.first;
  expect(header.kind, 'IHDR', reason: '$where does not open with IHDR');
  final int width = _beInt(header.payload, 0);
  final int height = _beInt(header.payload, 4);
  expect(header.payload[8], 8, reason: '$where is not 8 bits per channel');
  expect(header.payload[9], 6, reason: '$where is not colour type 6 (RGBA)');
  expect(header.payload[12], 0, reason: '$where is interlaced');

  final idat = <int>[];
  for (final PngChunk chunk in chunks) {
    if (chunk.kind == 'IDAT') {
      idat.addAll(chunk.payload);
    }
  }
  expect(idat, isNotEmpty, reason: '$where carries no image data');

  final List<int> raw = zlib.decode(idat);
  final int stride = width * 4;
  expect(
    raw.length,
    height * (stride + 1),
    reason: '$where decompresses to the wrong number of bytes',
  );

  final rows = <List<List<int>>>[];
  for (var y = 0; y < height; y++) {
    final int base = y * (stride + 1);
    expect(
      raw[base],
      0,
      reason: '$where uses a scanline filter this test cannot undo (row $y)',
    );
    final row = <List<int>>[];
    for (var x = 0; x < width; x++) {
      final int at = base + 1 + x * 4;
      row.add(raw.sublist(at, at + 4));
    }
    rows.add(row);
  }
  return DecodedPng(width, height, rows);
}

// ---------------------------------------------------------------------------
// Just enough of a VectorDrawable to check its reach and its colours.
// ---------------------------------------------------------------------------

/// Every `android:pathData` in a drawable, in document order.
List<String> pathDataOf(String xml) => RegExp(r'android:pathData="([^"]*)"')
    .allMatches(xml)
    .map((RegExpMatch match) => match.group(1)!)
    .toList();

/// Every `android:fillColor` in a drawable, in document order.
List<String> fillColoursOf(String xml) => RegExp(r'android:fillColor="([^"]*)"')
    .allMatches(xml)
    .map((RegExpMatch match) => match.group(1)!)
    .toList();

/// Every coordinate pair a path names, control points included.
///
/// A cubic never leaves the convex hull of its four points, so judging the
/// drawing by *all* of them can only over-state how far it reaches — which is
/// the safe direction for a question about clipping.
List<List<double>> pointsOf(String pathData) {
  final numbers = <double>[];
  for (final String token in pathData.replaceAll(',', ' ').split(RegExp(r'\s+'))) {
    final String body = token.replaceAll(RegExp(r'^[MLCZmlczHhVv]+'), '');
    if (body.isEmpty) {
      continue;
    }
    final double? value = double.tryParse(body);
    expect(value, isNotNull, reason: 'unparsable path token "$token"');
    numbers.add(value!);
  }
  expect(
    numbers.length.isEven,
    isTrue,
    reason: 'a path ended mid-coordinate: ${numbers.length} numbers',
  );
  return <List<double>>[
    for (var i = 0; i < numbers.length; i += 2) <double>[numbers[i], numbers[i + 1]],
  ];
}

/// Runs the generator's own `--check` and hands back what it said.
///
/// Interpreter choice is explicit and ordered: this
/// repository's own `.venv` first, then the ordinary names, and never a bare
/// `py` left to pick whichever installation happens to be newest. The generator
/// imports nothing outside the standard library, so any Python 3.9+ serves —
/// including the gateway's venv, which is being *used* here and never written
/// to.
ProcessResult runGeneratorCheck() {
  const List<List<String>> candidates = <List<String>>[
    <String>[r'..\.venv\Scripts\python.exe'],
    <String>['../.venv/bin/python'],
    <String>['python3'],
    <String>['python'],
    <String>['py', '-3'],
  ];

  final tried = <String>[];
  for (final List<String> candidate in candidates) {
    final String executable = candidate.first;
    if (executable.contains('venv') && !File(executable).existsSync()) {
      tried.add('$executable — not present');
      continue;
    }
    ProcessResult result;
    try {
      result = Process.runSync(executable, <String>[
        ...candidate.skip(1),
        kGenerator,
        '--check',
      ]);
    } on ProcessException catch (error) {
      tried.add('$executable — ${error.message}');
      continue;
    }
    // Windows ships a `python` alias that opens the Store instead of running
    // anything. That is not an answer about the assets, so keep looking. But
    // anything that really did start Python is an answer — including one that
    // says the script is broken — and it is returned rather than skipped, so a
    // broken generator does not masquerade as a missing interpreter.
    final String output = '${result.stdout}${result.stderr}';
    if (result.exitCode == 9009 ||
        output.contains('was not found') ||
        output.contains('Microsoft Store')) {
      tried.add('$executable — not a Python interpreter on this machine');
      continue;
    }
    return result;
  }

  fail(
    'no Python interpreter could run $kGenerator --check, so the claim that the '
    'committed icon assets are reproducible went unverified. Tried: '
    '${tried.join('; ')}. This repository already requires Python for the '
    'gateway (docs/runtime.md) and the generator needs nothing beyond its '
    'standard library.',
  );
}

void main() {
  group('the launcher icon is generated, and it still regenerates', () {
    test('the script that produces every asset below is in the repository', () {
      // The anchor for everything else. If this moves, the assets stop being
      // reproducible and the review's question — can somebody who cloned this
      // repository regenerate the icon? — becomes "no".
      final generator = File(kGenerator);
      expect(
        generator.existsSync(),
        isTrue,
        reason: '$kGenerator is missing (cwd ${Directory.current.path})',
      );

      // Anchored to the argparse call that defines the flag, not to the prose
      // that mentions it. Renaming the flag while leaving four mentions of
      // `--check` in the docstring used to pass this, even though every command
      // in the README and the report would then error out.
      //
      // Line endings normalised first: this repository has `core.autocrlf`, so
      // the script is CRLF in a Windows working tree and LF in the blob, and an
      // anchor that spans a newline would otherwise be a check on the checkout
      // rather than on the code.
      expect(
        generator.readAsStringSync().replaceAll('\r\n', '\n'),
        contains('parser.add_argument(\n        "--check",'),
        reason: '$kGenerator no longer defines a --check flag, so the command '
            'this repository documents for verifying the assets does not exist',
      );
    });

    test('re-running the generator reproduces the committed assets exactly', () {
      // The criterion this file exists under is "reproducible from a committed
      // script, and re-running it produces the same bytes". Asserting that the
      // script *exists* does not check that. A generator that has drifted from
      // the assets, or that has stopped being deterministic, is invisible to
      // every other test here — and this repository has no CI, so `flutter test`
      // is the only gate there is. So run it.
      final result = runGeneratorCheck();
      expect(
        result.exitCode,
        0,
        reason: 'the committed assets are not what $kGenerator produces, or the '
            'script no longer runs:\n${result.stdout}${result.stderr}',
      );
      // Not "it exited 0": the number of files it compared, verbatim. A --check
      // that silently found nothing to compare would exit 0 too.
      expect(
        result.stdout,
        contains('all 8 generated assets match.'),
        reason: 'the check ran but did not compare all eight assets:\n'
            '${result.stdout}${result.stderr}',
      );
    });
  });

  group('the five legacy densities', () {
    test('each exists, at exactly the pixel size its density means', () {
      // Verbatim per density, not `48 * multiplier`: swapping two files is the
      // mutation this has to die on, and a formula that agrees with itself
      // would survive it.
      expect(kDensities.length, 5, reason: 'a density went missing from the table');

      final observed = <String, int>{};
      kDensities.forEach((String density, int expectedSize) {
        final File file = resFile('mipmap-$density/ic_launcher.png');
        final DecodedPng image = decodePng(
          file.readAsBytesSync(),
          where: 'mipmap-$density/ic_launcher.png',
        );
        expect(
          image.width,
          expectedSize,
          reason: 'mipmap-$density/ic_launcher.png is ${image.width}px wide, '
              'and $density means ${expectedSize}px',
        );
        expect(
          image.height,
          expectedSize,
          reason: 'mipmap-$density/ic_launcher.png is ${image.height}px tall, '
              'and $density means ${expectedSize}px',
        );
        observed[density] = image.width;
      });

      expect(observed, <String, int>{
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      });
    });

    test('each is a real PNG, checked by the format\'s own CRC-32s', () {
      // `gateway/tests/media_fixtures.py` reads mipmap-mdpi/ic_launcher.png off
      // disk at run time and verifies exactly these checksums, so a broken file
      // here breaks the gateway's media suite. Catch it on this side too.
      for (final String density in kDensities.keys) {
        final String path = 'mipmap-$density/ic_launcher.png';
        final List<int> data = resFile(path).readAsBytesSync();
        final List<PngChunk> chunks = walkPng(data, where: path);
        expect(chunks.first.kind, 'IHDR', reason: '$path does not open with IHDR');
        expect(chunks.last.kind, 'IEND', reason: '$path does not end with IEND');
        for (final PngChunk chunk in chunks) {
          expect(
            crc32(<int>[...ascii.encode(chunk.kind), ...chunk.payload]),
            chunk.recordedCrc,
            reason: '$path: the ${chunk.kind} chunk fails its own CRC-32',
          );
        }
      }
    });

    test('a text-mode transfer breaks these at byte four and nowhere else', () {
      // THE COUPLING, AND WHY IT IS BYTE-LEVEL.
      //
      // `gateway/tests/media_fixtures.py` reads mipmap-mdpi/ic_launcher.png off
      // disk at run time and builds its "damaged in a text-mode transfer"
      // fixture from it by replacing every CRLF with LF. That damaged file is
      // what T-0126's sniffer must refuse, and the gateway pins its first nine
      // bytes and asserts no CRLF survives the collapse.
      //
      // Compressed data is arbitrary bytes. Regenerating these files — a new
      // shape, a different compressor — produces new arbitrary bytes, and new
      // arbitrary bytes can contain CR and LF in any arrangement. So this is not
      // a property that holds once and stays held; it has to be checked wherever
      // the bytes are made, which is here.
      //
      // What the gateway strictly needs is (2) below: no `\r\r\n`, because
      // collapsing its trailing CRLF leaves a fresh CRLF behind and the
      // "no CRLF survives" assertion silently weakens. (1) is stronger — the
      // signature's CRLF is the *only* one in the file — and is asserted as
      // margin: it keeps the damage confined to byte four, which is the claim
      // the gateway's comment makes about why PNG's four trap bytes exist. If a
      // future regeneration trips (1) while still satisfying (2) this test will
      // fire, and that is the intent: a human should look before an icon drifts
      // one unlucky byte away from breaking another package's test.
      const List<int> signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

      for (final String density in kDensities.keys) {
        final String path = 'mipmap-$density/ic_launcher.png';
        final List<int> real = resFile(path).readAsBytesSync();

        expect(
          real.sublist(0, 8),
          signature,
          reason: '$path does not open with the PNG signature',
        );

        // (1) Every CRLF in the file, by offset. Exactly one, at byte four.
        final crlf = <int>[];
        // (2) Every CR CR LF in the file. None.
        final crCrLf = <int>[];
        for (var i = 0; i + 1 < real.length; i++) {
          if (real[i] == 0x0D && real[i + 1] == 0x0A) {
            crlf.add(i);
            if (i > 0 && real[i - 1] == 0x0D) {
              crCrLf.add(i - 1);
            }
          }
        }
        expect(
          crCrLf,
          isEmpty,
          reason: '$path contains CR CR LF at $crCrLf. Collapsing the trailing '
              'CRLF leaves a new one behind, so the gateway\'s '
              '"no CRLF survives" assertion would pass over a file that still '
              'has one',
        );
        expect(
          crlf,
          <int>[4],
          reason: '$path has CRLF at $crlf. Only the signature\'s, at byte 4, '
              'should be there: that is what makes a text-mode transfer damage '
              'the file exactly where PNG designed it to',
        );

        // And the transformation itself, run the way the gateway runs it, with
        // the gateway's own assertions about the result.
        final damaged = <int>[];
        for (var i = 0; i < real.length; i++) {
          if (real[i] == 0x0D && i + 1 < real.length && real[i + 1] == 0x0A) {
            continue; // the CR is dropped; the LF that follows is kept
          }
          damaged.add(real[i]);
        }
        expect(damaged.sublist(0, 4), real.sublist(0, 4));
        expect(damaged.sublist(0, 8), isNot(real.sublist(0, 8)));
        expect(
          damaged.sublist(0, 8),
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0A, 0x1A, 0x0A, real[8]],
          reason: '$path: after a text-mode transfer the first eight bytes are '
              'not what the gateway pins them to',
        );

        var firstDifference = -1;
        for (var i = 0; i < damaged.length; i++) {
          if (real[i] != damaged[i]) {
            firstDifference = i;
            break;
          }
        }
        expect(
          firstDifference,
          4,
          reason: '$path: a text-mode transfer first changes byte '
              '$firstDifference, not byte 4',
        );
      }
    });
  });

  group('two colours and their blend, and nothing else', () {
    test('every pixel of every density lies on the ground-to-accent line', () {
      for (final MapEntry<String, int> entry in kDensities.entries) {
        final String path = 'mipmap-${entry.key}/ic_launcher.png';
        final DecodedPng image = decodePng(resFile(path).readAsBytesSync(), where: path);

        final distinct = <String>{};
        var groundSeen = false;
        var accentSeen = false;

        for (final List<List<int>> row in image.pixels) {
          for (final List<int> pixel in row) {
            expect(
              pixel[3],
              255,
              reason: '$path has a partly transparent pixel; the legacy icon is '
                  'a solid square',
            );
            distinct.add('${pixel[0]},${pixel[1]},${pixel[2]}');
            if (pixel[0] == kGround[0] &&
                pixel[1] == kGround[1] &&
                pixel[2] == kGround[2]) {
              groundSeen = true;
            }
            if (pixel[0] == kAccent[0] &&
                pixel[1] == kAccent[1] &&
                pixel[2] == kAccent[2]) {
              accentSeen = true;
            }

            // Blue has the widest span of the three channels, so it recovers
            // the blend factor with the least rounding error; the other two are
            // then predictions this pixel has to match.
            final double t = (pixel[2] - kGround[2]) / (kAccent[2] - kGround[2]);
            for (var channel = 0; channel < 3; channel++) {
              final double predicted =
                  kGround[channel] + t * (kAccent[channel] - kGround[channel]);
              expect(
                (pixel[channel] - predicted).abs(),
                lessThanOrEqualTo(2.0),
                reason: '$path has the colour '
                    '#${pixel[0].toRadixString(16).padLeft(2, '0')}'
                    '${pixel[1].toRadixString(16).padLeft(2, '0')}'
                    '${pixel[2].toRadixString(16).padLeft(2, '0')}, which is not '
                    'a blend of #0E0F12 and #8FA5F7',
              );
            }
          }
        }

        // Both ends of the line have to actually be in the file. Without this a
        // uniformly darkened icon — every colour still "on the line" — would
        // pass, and so would an image with no mark in it at all.
        expect(groundSeen, isTrue, reason: '$path never uses #0E0F12 itself');
        expect(accentSeen, isTrue, reason: '$path never uses #8FA5F7 itself');

        // And the edges have to be anti-aliased, which is the only reason there
        // are intermediate colours to hold to a line in the first place.
        expect(
          distinct.length,
          greaterThan(8),
          reason: '$path has only ${distinct.length} distinct colours; its edges '
              'are not anti-aliased, so the line check above proves nothing',
        );
      }
    });
  });

  group('the adaptive icon', () {
    test('names a background and a foreground, and they are different drawables', () {
      final String xml = resFile('mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
      expect(
        xml,
        contains('<adaptive-icon'),
        reason: 'mipmap-anydpi-v26/ic_launcher.xml is not an adaptive icon',
      );

      String layer(String name) {
        final RegExpMatch? match =
            RegExp('<$name\\s+android:drawable="([^"]+)"').firstMatch(xml);
        expect(match, isNotNull, reason: 'the adaptive icon has no <$name>');
        return match!.group(1)!;
      }

      final String background = layer('background');
      final String foreground = layer('foreground');
      expect(background, '@drawable/ic_launcher_background');
      expect(foreground, '@drawable/ic_launcher_foreground');
      expect(
        background,
        isNot(foreground),
        reason: 'both adaptive layers point at the same drawable, so there is '
            'nothing for the launcher to parallax or mask',
      );

      // Both must be real files: a dangling @drawable reference is a build
      // failure on a device and nothing at all here.
      for (final String reference in <String>[background, foreground]) {
        resFile('drawable/${reference.split('/').last}.xml');
      }
    });

    test('the foreground is drawn on the 108dp canvas and stays inside the mask', () {
      final String xml = resFile('drawable/ic_launcher_foreground.xml').readAsStringSync();

      for (final String attribute in <String>['viewportWidth', 'viewportHeight']) {
        final RegExpMatch? match =
            RegExp('android:$attribute="([^"]+)"').firstMatch(xml);
        expect(match, isNotNull, reason: 'the foreground declares no $attribute');
        expect(
          double.parse(match!.group(1)!),
          kViewport,
          reason: 'the foreground\'s $attribute is not the adaptive canvas',
        );
      }

      final List<String> paths = pathDataOf(xml);
      expect(
        paths.length,
        2,
        reason: 'the mark is the frame and the spark: two paths, and this file '
            'has ${paths.length}',
      );

      var points = 0;
      var worst = 0.0;
      for (final String path in paths) {
        final List<List<double>> coordinates = pointsOf(path);
        expect(
          coordinates.length,
          greaterThan(4),
          reason: 'a path with ${coordinates.length} points is not a shape, and '
              'a check that scans nothing passes for the wrong reason',
        );
        for (final List<double> point in coordinates) {
          points++;
          final double distance = _distanceFromCentre(point);
          if (distance > worst) {
            worst = distance;
          }
          expect(
            distance,
            lessThanOrEqualTo(kSafeRadius),
            reason: 'the foreground reaches (${point[0]}, ${point[1]}), '
                '${distance.toStringAsFixed(2)}dp from the centre of the canvas. '
                'A circular launcher mask keeps ${kSafeRadius.toStringAsFixed(0)}dp, '
                'so that corner of the mark would be cut off',
          );
        }
      }
      expect(points, greaterThan(20), reason: 'too few points to be the mark');

      // Not merely inside the mask: filling it. A mark shrunk to a dot would
      // pass every assertion above and look like nothing on a phone.
      expect(
        worst,
        greaterThan(kSafeRadius * 0.6),
        reason: 'the mark only reaches ${worst.toStringAsFixed(2)}dp of the '
            '${kSafeRadius.toStringAsFixed(0)}dp it may use — it would sit lost '
            'in the middle of the icon',
      );
    });

    test('the background covers the whole canvas', () {
      // The background layer is what a launcher masks and parallaxes. Anything
      // less than the full 108dp shows as a seam at the edge of the icon.
      final String xml = resFile('drawable/ic_launcher_background.xml').readAsStringSync();
      final List<String> paths = pathDataOf(xml);
      expect(paths.length, 1, reason: 'the background is one filled rectangle');

      final List<List<double>> corners = pointsOf(paths.single);
      final double minX = corners.map((List<double> p) => p[0]).reduce(_min);
      final double minY = corners.map((List<double> p) => p[1]).reduce(_min);
      final double maxX = corners.map((List<double> p) => p[0]).reduce(_max);
      final double maxY = corners.map((List<double> p) => p[1]).reduce(_max);
      expect(<double>[minX, minY, maxX, maxY], <double>[0, 0, kViewport, kViewport]);
    });

    test('both layers use only the two colours, spelled out', () {
      expect(
        fillColoursOf(resFile('drawable/ic_launcher_foreground.xml').readAsStringSync()),
        everyElement('#FF8FA5F7'),
        reason: 'the mark is drawn in the one accent and nothing else',
      );
      expect(
        fillColoursOf(resFile('drawable/ic_launcher_background.xml').readAsStringSync()),
        everyElement('#FF0E0F12'),
        reason: 'the ground is the app\'s own graphite and nothing else',
      );
    });
  });

  // These read the Gradle script rather than a build's output, and that limit is
  // worth stating: a `flutter test` run has no Android SDK, no seven minutes and
  // no phone. They cannot prove an APK came out right — the real universal and
  // `--split-per-abi` builds on T-0136 do that. What they *can* do is die when
  // the mechanism regresses to the shape that produced two Major defects, which
  // is the thing nobody would notice until they next ran a build.
  group('the APK a person sideloads', () {
    String buildScript() {
      final gradle = File(kBuildScript);
      expect(
        gradle.existsSync(),
        isTrue,
        reason: '$kBuildScript is missing (cwd ${Directory.current.path})',
      );
      return gradle.readAsStringSync();
    }

    test('is named from the artifact the build produced, not from a filename', () {
      final String script = buildScript();

      // The whole of both defects was probing for a bare filename. Under
      // `--split-per-abi` there is no `app-release.apk` to find, and when an
      // older universal build had left one behind it was copied out under this
      // build's name. So: the task's input is the packaging task's declared
      // artifact, and its metadata is where every part of the name comes from.
      expect(
        script,
        contains('apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))'),
        reason: 'the naming task no longer consumes the packaging task\'s own '
            'APK artifact, so it has nothing tying it to the build that ran',
      );
      expect(
        script,
        contains('builtArtifactsLoader.set(variant.artifacts.getBuiltArtifactsLoader())'),
        reason: 'the naming task no longer reads the build metadata AGP wrote '
            'for this build',
      );
      expect(
        script,
        contains('element.versionName'),
        reason: 'the version in the filename is no longer read off the artifact, '
            'so --build-name would produce a name that misdescribes the build',
      );

      // And nothing may go back to naming that file.
      expect(
        script,
        isNot(contains('"app-release.apk"')),
        reason: 'the build script names app-release.apk again. That literal is '
            'the probe that failed --split-per-abi and copied stale bytes out '
            'under a fresh version number',
      );
    });

    test('names the universal build and every ABI of a split build', () {
      final String script = buildScript();

      // Verbatim, both templates and the prefix. `README.md` documents
      // `flutter build apk --split-per-abi`; losing the ABI half of this would
      // make three artifacts collide under one name, or produce none at all.
      expect(script, contains('const val PREFIX = "LocalCanvas-"'));
      expect(
        script,
        contains(r'if (abi == null) "$PREFIX$version.apk" else "$PREFIX$version-$abi.apk"'),
        reason: 'the two filename templates are no longer both there: a split '
            'build needs LocalCanvas-<version>-<abi>.apk and a universal build '
            'needs LocalCanvas-<version>.apk',
      );
      expect(
        script,
        contains('FilterConfiguration.FilterType.ABI'),
        reason: 'the ABI in the filename is no longer read off the artifact\'s '
            'own filter',
      );
      // The loop line verbatim, not the bare symbol. `built.elements` also
      // appears in the emptiness check above it, so matching the symbol alone
      // let `built.elements.take(1)` through — a split build naming one of its
      // three APKs, and the only mutant to survive a campaign.
      expect(
        script,
        contains('for (element in built.elements) {'),
        reason: 'the task no longer walks every artifact the build produced, so '
            'a split build would name at most one of its three',
      );
    });

    test('runs as a dependency of assemble, never as a finalizer', () {
      final String script = buildScript();

      // Gradle runs finalizers even when the finalized task FAILS. As a
      // finalizer this task would still fire after a build that died before
      // packaging, and put this version's name on whatever was lying around.
      // As a dependency it cannot run unless packaging really produced
      // something. This is the single line that difference lives on.
      expect(
        script,
        contains('dependsOn(naming)'),
        reason: 'the naming task is no longer wired as a dependency of assemble',
      );
      expect(
        script,
        isNot(contains('finalizedBy(')),
        reason: 'the naming task is a finalizer again, so a failed build would '
            'name a stale artifact with this build\'s version',
      );
      expect(
        script,
        contains(r'tasks.matching { it.name == "assemble$capitalised" }'),
        reason: 'the naming task is no longer attached to the assemble task',
      );
      expect(
        script,
        contains('onVariants(selector().withBuildType("release"))'),
        reason: 'naming is no longer restricted to release, so a debug build '
            'would claim the same filename as the release one',
      );
    });

    test('an older build\'s name does not survive the next build', () {
      final String script = buildScript();

      // `LocalCanvas-0.1.0.apk` sitting beside `LocalCanvas-0.2.0.apk` looks
      // exactly as current as it does. Only this build's names may remain.
      expect(script, contains('!wanted.containsKey(file.name)'));
      expect(script, contains('file.name.startsWith(PREFIX)'));
      expect(
        script,
        contains('file.delete()'),
        reason: 'names from older builds are no longer removed, so a stale '
            'version sits in the output directory looking current',
      );
    });

    test('there is a version for the filename to be built from', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue);
      final RegExpMatch? version = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
          .firstMatch(pubspec.readAsStringSync());
      expect(
        version,
        isNotNull,
        reason: 'pubspec.yaml declares no version, so flutter.versionName would '
            'fall back to a default and every build would be named alike',
      );
      expect(
        version!.group(1),
        matches(RegExp(r'^\d+\.\d+\.\d+\+\d+$')),
        reason: 'pubspec.yaml\'s version is not a version with a build number',
      );
    });
  });
}

double _distanceFromCentre(List<double> point) =>
    math.sqrt(math.pow(point[0] - kCentre, 2) + math.pow(point[1] - kCentre, 2));

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;
