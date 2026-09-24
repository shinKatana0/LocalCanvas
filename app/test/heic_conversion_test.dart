/// A HEIC photo becomes a JPEG on the phone — and only a HEIC photo (T-0280).
///
/// The decoder is Android's and cannot run here, so it is the one thing these
/// tests script. Everything the card actually decides is in this process: what
/// is converted, what is not, what the converted file is called, and what
/// happens when the conversion does not come off.
///
/// **The fixtures are real files with real bytes.** A hand-built ISO base media
/// `ftyp` box for the HEIC side, a JPEG an encoder produced, and a PNG written
/// here with a genuine zlib stream and a genuinely transparent half — because
/// the claim being tested is about bytes, and a fixture that is not really a
/// PNG could not lose its transparency in the first place (T-0182).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/media/gallery_picker.dart';
import 'package:localcanvas/media/heic_conversion.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';

import 'support/l10n.dart';
import 'support/media_fakes.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A real ISO base media `ftyp` box with the major brand asked for, followed by
/// enough of a `mdat` box that the file is not just a header.
///
/// This is byte for byte what the first 12 bytes of a camera HEIC look like:
/// a big-endian box size, `ftyp`, the major brand, a minor version, and the
/// compatible brands. The sniff reads the major brand and nothing else, and
/// [isoBmff] is what lets a test put one brand in the major position and
/// another in the compatible list — which is exactly how an AVIF lies.
List<int> isoBmff(String major, List<String> compatible) {
  final body = <int>[
    ...ascii.encode('ftyp'),
    ...ascii.encode(major),
    0, 0, 2, 0, // minor version
    for (final brand in compatible) ...ascii.encode(brand),
  ];
  final size = body.length + 4;
  return <int>[
    (size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF,
    ...body,
    // A short `mdat` box, so the file has a body as well as a head.
    0, 0, 0, 0x10, ...ascii.encode('mdat'),
    for (var index = 0; index < 8; index++) 0x5A,
  ];
}

/// An iPhone-shaped HEIC: major brand `heic`, `mif1` among its compatibles.
List<int> heicBytes() => isoBmff('heic', <String>['mif1', 'heic', 'miaf']);

/// A 16x16 JPEG, produced by an encoder (ffmpeg 9.0.1, `-q:v 3`) and pasted
/// here so that the JPEG in these tests is a JPEG and not three magic bytes.
final Uint8List kJpegBytes = base64.decode(
  '/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAxAP/bAEMACAYGBwYHCAgI'
  'CAgICQkJCgoKCQkJCQoKCgoKCgwMDAoKCgoKCgoMDAwMDQ4NDQ0MDQ4ODw8PEhIRERUV'
  'FRkZH//EAEsAAQEAAAAAAAAAAAAAAAAAAAAFAQEAAAAAAAAAAAAAAAAAAAAGEAEAAAAA'
  'AAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AAEQgAEAAQAwEiAAIRAAMRAP/a'
  'AAwDAQACEQMRAD8AggHY4//Z',
);

/// An 8x8 RGBA PNG whose left half is opaque red and whose right half is fully
/// transparent.
///
/// Written here rather than pasted, because the transparency is the point: the
/// alpha channel is put in on purpose and read back out of the bytes that
/// survive the picker ([alphaAt]).
Uint8List pngWithAlpha({int size = 8}) {
  final raw = <int>[];
  for (var y = 0; y < size; y++) {
    raw.add(0); // filter: none
    for (var x = 0; x < size; x++) {
      if (x < size ~/ 2) {
        raw.addAll(<int>[0xE0, 0x30, 0x30, 0xFF]);
      } else {
        raw.addAll(<int>[0x00, 0x00, 0x00, 0x00]);
      }
    }
  }
  final header = <int>[
    (size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF,
    (size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF,
    8, // bit depth
    6, // colour type: truecolour with alpha
    0, 0, 0,
  ];
  return Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._pngChunk('IHDR', header),
    ..._pngChunk('IDAT', zlib.encode(raw)),
    ..._pngChunk('IEND', const <int>[]),
  ]);
}

List<int> _pngChunk(String type, List<int> data) {
  final body = <int>[...ascii.encode(type), ...data];
  final length = data.length;
  final crc = _crc32(body);
  return <int>[
    (length >> 24) & 0xFF, (length >> 16) & 0xFF,
    (length >> 8) & 0xFF, length & 0xFF,
    ...body,
    (crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF,
  ];
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// The alpha of one pixel, read by actually decoding the image.
///
/// This is what makes "transparency intact" a fact rather than a byte
/// comparison restated: the bytes are handed to the framework's own decoder
/// and the channel is read off the raw RGBA it produces.
Future<int> alphaAt(Uint8List png, int x, int y) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  final offset = (y * frame.image.width + x) * 4;
  final alpha = data!.getUint8(offset + 3);
  frame.image.dispose();
  codec.dispose();
  return alpha;
}

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// The Android decoder, scripted.
///
/// It records every path it was asked about, so a test can tell "not converted"
/// from "converted back to the same thing".
class ScriptedImageConverter implements ImageConverter {
  ScriptedImageConverter({this.jpeg});

  /// The bytes it writes out, or `null` for a device that cannot decode HEIF.
  List<int>? jpeg;

  /// Thrown instead of answering.
  Object? failure;

  /// Answers with a path it never wrote, which is a decoder that lied.
  bool loseTheFile = false;

  final List<String> asked = <String>[];

  @override
  Future<String?> heicToJpeg(String path) async {
    asked.add(path);
    final failure = this.failure;
    if (failure != null) throw failure;
    final bytes = jpeg;
    if (bytes == null) return null;
    final written = writeTempMedia('localcanvas-heic-1.jpg', contents: bytes);
    return loseTheFile ? '${written.path}.gone' : written.path;
  }
}

/// `image_picker`'s own class, with the one call this app makes recorded.
///
/// Subclassed rather than mocked so that `GalleryMediaPicker` runs exactly as
/// it does on a phone, down to the `XFile` it reads the name off.
class RecordingImagePicker extends ImagePicker {
  RecordingImagePicker(this.answer);

  final XFile? answer;

  int calls = 0;
  final List<double?> maxWidths = <double?>[];
  final List<double?> maxHeights = <double?>[];
  final List<int?> qualities = <int?>[];

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    maxWidths.add(maxWidth);
    maxHeights.add(maxHeight);
    qualities.add(imageQuality);
    return answer;
  }
}

// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Endpoint.tryParse('192.0.2.42')!;

  late ScriptedImageConverter converter;
  late PickedImageConversion conversion;

  setUp(() {
    converter = ScriptedImageConverter(jpeg: kJpegBytes);
    conversion = PickedImageConversion(converter: converter);
  });

  Future<List<int>> bytesOf(MediaSelection selection) async {
    final chunks = await selection.source.openRead().toList();
    return <int>[for (final chunk in chunks) ...chunk];
  }

  group('what gets converted is decided by the bytes', () {
    for (final brand in kHeicMajorBrands) {
      test('a photo whose major brand is $brand is converted', () async {
        final picked = tempSelection(
          name: 'IMG_0142.heic',
          contents: isoBmff(brand, <String>['mif1', 'miaf']),
        );

        final result = await conversion.apply(picked);

        expect(converter.asked, hasLength(1));
        expect(result, isNot(same(picked)));
        expect(await bytesOf(result), kJpegBytes);
      });
    }

    test('a JPEG the picker called .heic is left exactly as it is', () async {
      final picked = tempSelection(name: 'IMG_0142.heic', contents: kJpegBytes);

      final result = await conversion.apply(picked);

      expect(converter.asked, isEmpty);
      expect(result, same(picked));
      expect(result.filename, 'IMG_0142.heic');
      expect(await bytesOf(result), kJpegBytes);
    });

    test('a HEIC the picker called .jpg is converted all the same', () async {
      final picked = tempSelection(name: 'IMG_0142.jpg', contents: heicBytes());

      final result = await conversion.apply(picked);

      expect(converter.asked, hasLength(1));
      expect(await bytesOf(result), kJpegBytes);
      expect(result.filename, 'IMG_0142.jpg');
    });

    test('an AVIF that names mif1 among its compatible brands is not '
        'handed to a HEIF decoder', () async {
      // The major brand is the file's own statement of what it is; `mif1` in
      // the compatible list is a specification it also conforms to. A reader
      // that scanned the list would convert an AV1 image with a HEVC decoder.
      final picked = tempSelection(
        name: 'photo.avif',
        contents: isoBmff('avif', <String>['avif', 'mif1', 'miaf']),
      );

      final result = await conversion.apply(picked);

      expect(converter.asked, isEmpty);
      expect(result, same(picked));
    });

    test('an MP4 in the same container is not converted', () async {
      final picked = tempSelection(
        name: 'clip.mp4',
        contents: isoBmff('mp42', <String>['isom', 'mp42']),
      );

      final result = await conversion.apply(picked);

      expect(converter.asked, isEmpty);
      expect(result, same(picked));
    });

    test('a clip is never converted, whatever its brand says', () async {
      final picked = tempSelection(
        kind: MediaKind.video,
        name: 'clip.mov',
        contents: heicBytes(),
      );

      final result = await conversion.apply(picked);

      expect(converter.asked, isEmpty);
      expect(result, same(picked));
    });

    test('a file too short to carry a brand is not converted', () async {
      final picked = tempSelection(
        name: 'tiny.bin',
        contents: <int>[0, 0, 0, 0x18, 0x66, 0x74, 0x79],
      );

      final result = await conversion.apply(picked);

      expect(converter.asked, isEmpty);
      expect(result, same(picked));
    });
  });

  group('everything that is not a HEIC passes through byte for byte', () {
    test('a JPEG comes back as the very same selection', () async {
      final picked = tempSelection(name: 'IMG_0142.jpg', contents: kJpegBytes);

      final result = await conversion.apply(picked);

      expect(result, same(picked));
      expect(result.source, same(picked.source));
      expect(result.byteCount, kJpegBytes.length);
      expect(await bytesOf(result), kJpegBytes);
    });

    test('a PNG comes back with its transparency', () async {
      final png = pngWithAlpha();
      final picked = tempSelection(name: 'drawing.png', contents: png);

      final result = await conversion.apply(picked);

      expect(result, same(picked));
      final after = Uint8List.fromList(await bytesOf(result));
      expect(after, png);
      // Read out of the bytes that survived, not out of the fixture.
      expect(await alphaAt(after, 0, 0), 255);
      expect(await alphaAt(after, 7, 0), 0);
    });
  });

  group('the converted photo', () {
    test('sniffs as a JPEG and is named .jpg', () async {
      final picked = tempSelection(name: 'IMG_0142.heic', contents: heicBytes());

      final result = await conversion.apply(picked);
      final bytes = await bytesOf(result);

      expect(bytes.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);
      expect(looksLikeHeic(bytes), isFalse);
      expect(result.filename, 'IMG_0142.jpg');
      expect(result.displayName(en), 'IMG_0142.jpg');
    });

    test('carries the converted file\'s own size, not the HEIC\'s', () async {
      final heic = heicBytes();
      final picked = tempSelection(name: 'IMG_0142.heic', contents: heic);

      final result = await conversion.apply(picked);

      expect(picked.byteCount, heic.length);
      expect(result.byteCount, kJpegBytes.length);
    });

    test('keeps a HEIF name sensible too', () async {
      final picked = tempSelection(
        name: 'photo.HEIF',
        contents: isoBmff('mif1', <String>['mif1', 'miaf']),
      );

      expect((await conversion.apply(picked)).filename, 'photo.jpg');
    });

    test('a name with no extension gains one rather than losing anything',
        () {
      expect(jpegFilename('IMG_0142.heic'), 'IMG_0142.jpg');
      expect(jpegFilename('IMG_0142.HEIC'), 'IMG_0142.jpg');
      expect(jpegFilename('morning walk'), 'morning walk.jpg');
      expect(jpegFilename('2026.09.02 morning'), '2026.09.02 morning.jpg');
      expect(jpegFilename('.heic'), '.heic.jpg');
    });

    test('a picture the platform gave no name for still gets none', () async {
      final picked = tempSelection(
        name: 'IMG_0142.heic',
        named: false,
        contents: heicBytes(),
      );

      final result = await conversion.apply(picked);

      expect(result.filename, isNull);
      expect(result.displayName(en), en.mediaChosenPicture);
    });
  });

  group('a conversion that does not come off uploads the original', () {
    test('a device with no HEIF decoder answers null, and the HEIC goes as '
        'it is', () async {
      converter.jpeg = null;
      final heic = heicBytes();
      final picked = tempSelection(name: 'IMG_0142.heic', contents: heic);

      final result = await conversion.apply(picked);

      expect(converter.asked, hasLength(1));
      expect(result, same(picked));
      expect(result.filename, 'IMG_0142.heic');
      expect(await bytesOf(result), heic);
    });

    test('a decoder that throws is not a failed pick', () async {
      converter.failure = StateError('the decoder fell over');
      final picked = tempSelection(name: 'IMG_0142.heic', contents: heicBytes());

      final result = await conversion.apply(picked);

      expect(result, same(picked));
    });

    test('a decoder that names a file it never wrote is not believed',
        () async {
      converter.loseTheFile = true;
      final heic = heicBytes();
      final picked = tempSelection(name: 'IMG_0142.heic', contents: heic);

      final result = await conversion.apply(picked);

      expect(result, same(picked));
      expect(await bytesOf(result), heic);
    });

    test('a build with no converter at all changes nothing', () async {
      final picked = tempSelection(name: 'IMG_0142.heic', contents: heicBytes());

      final result = await const PickedImageConversion().apply(picked);

      expect(result, same(picked));
    });

    test('the gateway then refuses it, exactly as it did before (T-0127)',
        () async {
      converter.jpeg = null;
      final heic = heicBytes();
      final uploads = ScriptedMediaApi()
        ..failure = const MediaFailure.refused(
          code: 'unsupported_image_heic',
          serverMessage: 'That photo is in HEIC/HEIF format, which LocalCanvas '
              'cannot use yet. Choose a JPEG or PNG instead.',
        );
      final picker = ScriptedMediaPicker(<MediaSelection?>[
        await conversion.apply(
          tempSelection(name: 'IMG_0142.heic', contents: heic),
        ),
      ]);
      final field = MediaFieldController(
        kind: MediaKind.image,
        picker: picker,
        uploader: (selection, onProgress) =>
            uploads.upload(endpoint, selection, onProgress: onProgress),
      );
      addTearDown(field.dispose);

      await field.choose();

      // The original file is what went up.
      expect(uploads.uploaded.single.filename, 'IMG_0142.heic');
      expect(await bytesOf(uploads.uploaded.single), heic);
      // And the refusal is the one the person already had.
      expect(field.phase, MediaPhase.failed);
      expect(field.failure?.code, 'unsupported_image_heic');
      expect(
        field.failure?.message(en),
        en.gatewayErrorUnsupportedImageHeic,
      );
    });
  });

  group('the picker itself', () {
    XFile pickedFile(String name, List<int> contents) =>
        XFile(writeTempMedia(name, contents: contents).path);

    test('asks Android for the photo unchanged — no size, no quality',
        () async {
      // These are the parameters that would convert a HEIC by re-encoding
      // EVERY photo, JPEG and PNG alike (T-0127). The conversion must not come
      // back through this door.
      final plugin = RecordingImagePicker(
        pickedFile('IMG_0142.jpg', kJpegBytes),
      );

      await GalleryMediaPicker(picker: plugin, converter: converter)
          .pick(MediaKind.image);

      expect(plugin.calls, 1);
      expect(plugin.maxWidths, <double?>[null]);
      expect(plugin.maxHeights, <double?>[null]);
      expect(plugin.qualities, <int?>[null]);
    });

    test('converts the HEIC it was handed, and says so by its name', () async {
      final plugin = RecordingImagePicker(
        pickedFile('IMG_0142.heic', heicBytes()),
      );

      final selection = await GalleryMediaPicker(
        picker: plugin,
        converter: converter,
      ).pick(MediaKind.image);

      expect(converter.asked, hasLength(1));
      expect(selection!.filename, 'IMG_0142.jpg');
      expect(await bytesOf(selection), kJpegBytes);
      expect(selection.byteCount, kJpegBytes.length);
    });

    test('hands a PNG on untouched', () async {
      final png = pngWithAlpha();
      final plugin = RecordingImagePicker(pickedFile('drawing.png', png));

      final selection = await GalleryMediaPicker(
        picker: plugin,
        converter: converter,
      ).pick(MediaKind.image);

      expect(converter.asked, isEmpty);
      expect(selection!.filename, 'drawing.png');
      final after = Uint8List.fromList(await bytesOf(selection));
      expect(after, png);
      expect(await alphaAt(after, 7, 0), 0);
    });

    test('backing out of the picker still converts nothing', () async {
      final selection = await GalleryMediaPicker(
        picker: RecordingImagePicker(null),
        converter: converter,
      ).pick(MediaKind.image);

      expect(selection, isNull);
      expect(converter.asked, isEmpty);
    });
  });
}
