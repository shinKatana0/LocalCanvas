/// Turning a chosen HEIC/HEIF photo into a JPEG on this phone, before it is
/// uploaded — and leaving every other file exactly as it was.
///
/// **Why the app and not the gateway.** T-0127 made the gateway refuse a
/// HEIC/HEIF upload by content, with its own code `unsupported_image_heic` and
/// a sentence in the language on screen, because ComfyUI's `LoadImage` cannot
/// read one unless the person running the PC installed something for it. That
/// refusal is correct and stays exactly as it is. It is a safety net, though,
/// not a feature: the default camera format on modern Samsung and iPhone
/// hardware is HEIC, so on a plain phone the safety net is the *first* thing a
/// person meets. This file is what keeps them from meeting it.
///
/// **The decision is made from the file's bytes, never from its name.** The
/// same ISO base media brand table the gateway reads
/// (`gateway/localcanvas_gateway/media.py`, `_ISOBMFF_IMAGE_BRANDS`): `ftyp`
/// at byte 4 and the **major** brand at byte 8. A name is what the picker,
/// the camera or another app chose to call the file and it is routinely wrong
/// — a JPEG called `.heic` is a real thing, and so is a HEIC called `.jpg`.
/// Believing the name would convert files that need no conversion and skip
/// the ones that do.
///
/// **Everything else passes through byte for byte.** Not "re-encoded at a high
/// quality" — untouched. The selection that comes back for a JPEG or a PNG is
/// the selection that went in, pointing at the same file, so a PNG keeps its
/// transparency and a JPEG is never generation-lossed on the way to a server
/// that would have taken it as it was. That is the whole reason this is not
/// `image_picker`'s `imageQuality`/`maxWidth` route, which re-encodes *every*
/// picked photo (measured in T-0127, `ImageResizer.java:42-45, :95-96`).
///
/// **A conversion that does not happen is not an error.** A phone with no HEIF
/// decoder (Android 8 and below), a file the decoder chokes on, a cache the
/// system swept away mid-pick: in every one of those the original selection is
/// returned unchanged and uploaded as it always was, and T-0127's refusal is
/// what the person sees. Better the old, honest sentence than a dialog about
/// an image codec.
library;

import 'dart:async';
import 'dart:io';

import 'media_selection.dart';

/// The JPEG quality the converted photo is written at.
///
/// 92 is the design's value and is not a measurement: what a given quality
/// costs in bytes and in visible artefacts depends on the photo and on
/// Android's own encoder, and neither can be seen from a test suite on a PC.
/// It is high enough that a re-encode of a camera photo is not meant to be
/// noticeable, and low enough that the JPEG is smaller than a lossless one
/// would be.
const int kHeicJpegQuality = 92;

/// How many bytes of a chosen file are read to decide what it is.
///
/// Twelve, which is exactly where the ISO base media major brand ends: four
/// bytes of box size, `ftyp`, and the brand. Nothing further along is
/// consulted, so nothing further along needs reading.
const int kImageSniffBytes = 12;

/// The ISO base media **major** brands that mean "this holds a still image
/// this app should convert".
///
/// Copied deliberately, not shared: the gateway is a separate program on a
/// separate machine reached over HTTP, and `docs/architecture.md` keeps them
/// from importing each other. The list is the one in
/// `gateway/localcanvas_gateway/media.py` — `heic`/`heix`/`heim`/`heis` and
/// `hevc`/`hevx`/`hevm`/`hevs` are the HEVC-coded images, and `mif1`, `mif2`
/// and `msf1` are the plain HEIF image and image-sequence brands many Android
/// cameras write.
///
/// Only the **major** brand is looked up, for the gateway's own reason: an
/// AVIF — a real still image, coded with AV1, which is neither HEIC nor
/// something this app can convert — names `mif1` among its *compatible*
/// brands. A reader that scanned that list would hand an AVIF to a HEIF
/// decoder. `isom`, `mp42` and `qt  ` are absent because they are videos, and
/// `avif` because it is not ours to convert.
const Set<String> kHeicMajorBrands = <String>{
  'heic',
  'heix',
  'heim',
  'heis',
  'hevc',
  'hevx',
  'hevm',
  'hevs',
  'mif1',
  'mif2',
  'msf1',
};

/// Whether these first bytes are a HEIC/HEIF still image.
///
/// `head` is the start of the file — [kImageSniffBytes] of it is enough, and
/// anything shorter is not one of these at all.
bool looksLikeHeic(List<int> head) {
  if (head.length < kImageSniffBytes) return false;
  if (!_isAscii(head, 4, 'ftyp')) return false;
  final brand = String.fromCharCodes(head.getRange(8, 12));
  return kHeicMajorBrands.contains(brand);
}

bool _isAscii(List<int> bytes, int at, String text) {
  for (var index = 0; index < text.length; index++) {
    if (bytes[at + index] != text.codeUnitAt(index)) return false;
  }
  return true;
}

/// The name the converted picture is shown and uploaded under.
///
/// `IMG_0142.heic` becomes `IMG_0142.jpg`: the same photo, named for what it
/// now is. The extension is only replaced when there really is one — a
/// trailing dot group of at most five letters and digits — so
/// `2026.09.02 morning` gains `.jpg` rather than losing its date.
String jpegFilename(String name) {
  final cut = name.lastIndexOf('.');
  if (cut > 0 && cut < name.length - 1) {
    final extension = name.substring(cut + 1);
    if (extension.length <= 5 && _isAlphanumeric(extension)) {
      return '${name.substring(0, cut)}.jpg';
    }
  }
  return '$name.jpg';
}

bool _isAlphanumeric(String value) {
  for (final unit in value.codeUnits) {
    final digit = unit >= 0x30 && unit <= 0x39;
    final upper = unit >= 0x41 && unit <= 0x5A;
    final lower = unit >= 0x61 && unit <= 0x7A;
    if (!digit && !upper && !lower) return false;
  }
  return true;
}

/// Decoding one HEIC/HEIF file and writing it out as a JPEG.
///
/// A platform surface, behind an interface for the same reason `MediaPicker`
/// and `ClipInspector` are: the decision about *which* file to convert, the
/// name it comes back under and every state the form shows are exercised in
/// tests with no device, while the decoder itself is Android's.
abstract interface class ImageConverter {
  /// Writes [path] out as a JPEG and returns the new file's path.
  ///
  /// `null` — not an exception — is the answer for a device that cannot decode
  /// the file at all. That is an ordinary outcome, not a failure: the original
  /// is uploaded and the gateway's refusal is what the person sees.
  Future<String?> heicToJpeg(String path);
}

/// The seam: what happens to a picked file between the picker and the upload.
///
/// Injectable, and injected with `null` it is a no-op — which is what a build
/// with no converter had before this existed.
class PickedImageConversion {
  const PickedImageConversion({this.converter});

  /// Android's decoder, a test's script, or `null` on a build that has none.
  final ImageConverter? converter;

  /// [selection] itself, or the JPEG it became.
  ///
  /// The identical object comes back whenever nothing was converted, so "was
  /// this passed through?" is answerable by identity and a caller cannot be
  /// handed a quietly rebuilt copy.
  Future<MediaSelection> apply(MediaSelection selection) async {
    final converter = this.converter;
    if (converter == null) return selection;
    // A clip is not this file's business, and its first bytes are the same
    // `ftyp` box — the brand table is what tells the two apart, and a video
    // brand is not in it. The kind check is the cheaper half of the same
    // answer, not a second opinion.
    if (selection.kind != MediaKind.image) return selection;

    // The decoder is handed a path, so a source with no local file — there is
    // none today, and the interface allows one — is passed through.
    final file = selection.source.previewFile;
    if (file == null) return selection;

    final List<int> head;
    try {
      head = await _readHead(selection.source);
    } on Object {
      // The file went away, or could not be read. Nothing here is worth
      // failing a pick over: the upload re-checks it and says so properly.
      return selection;
    }
    if (!looksLikeHeic(head)) return selection;

    final String? jpegPath;
    try {
      jpegPath = await converter.heicToJpeg(file.path);
    } on Object {
      return selection;
    }
    if (jpegPath == null || jpegPath.isEmpty) return selection;

    final int bytes;
    try {
      bytes = await File(jpegPath).length();
    } on FileSystemException {
      // It said it wrote one and there is nothing there. Upload the original.
      return selection;
    }

    final name = selection.filename;
    return MediaSelection(
      kind: selection.kind,
      source: FileMediaSource(jpegPath),
      // Not the converted file's own name: that is a cache path this app
      // owns and `docs/ui-ux.md` forbids showing. The name a person
      // recognises is the one they picked, with the extension it now has.
      filename: name == null ? null : jpegFilename(name),
      byteCount: bytes,
    );
  }

  /// The first [kImageSniffBytes] of the file, or fewer if it is shorter.
  Future<List<int>> _readHead(MediaSource source) async {
    final head = <int>[];
    await for (final chunk in source.openRead()) {
      head.addAll(chunk);
      if (head.length >= kImageSniffBytes) break;
    }
    return head;
  }
}
