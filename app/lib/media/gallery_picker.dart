/// Android's own media picker, behind [MediaPicker].
///
/// On Android 13 and later `image_picker` goes through the system photo
/// picker, which grants access to the one item the user chose and asks for no
/// storage permission at all; on older releases it opens a document chooser,
/// which also grants per-item access. That is why this feature adds no
/// `READ_MEDIA_*` permission to the manifest: asking for the whole gallery in
/// order to read one file would be exactly the kind of over-reach
/// `docs/privacy-security.md` exists to prevent.
///
/// It is also why a selection can lapse. Per-item access is not a promise, and
/// the copy the plugin leaves in the app's cache can be swept away by the
/// system, so what comes out of here is re-checked on restore rather than
/// trusted until upload (`docs/recovery.md`).
///
/// Whatever Android called the item goes through [humanFilename] here, so a
/// value that is a reference rather than a name is dropped at the boundary
/// instead of relying on a widget further along to remember the rule. There
/// is no second guess at the name if that one comes back empty: the only
/// other string on hand is the plugin's cache path, and
/// `image_picker_ABC123.jpg` is a worse label than "Chosen picture".
///
/// **`pickImage` is called with no size and no quality, deliberately.** Those
/// parameters would convert a HEIC — `image_picker` documents it — but they
/// re-encode *every* picked photo on the way past, JPEG and PNG alike
/// (measured in T-0127). A HEIC is converted here instead, by
/// `heic_conversion.dart`, from the file's own bytes and for no other file
/// (T-0280).
library;

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'heic_conversion.dart';
import 'media_picker.dart';
import 'media_selection.dart';
import 'platform_image_converter.dart';

class GalleryMediaPicker implements MediaPicker {
  GalleryMediaPicker({ImagePicker? picker, ImageConverter? converter})
    : _picker = picker ?? ImagePicker(),
      _conversion = PickedImageConversion(
        converter: converter ?? const PlatformImageConverter(),
      );

  final ImagePicker _picker;

  /// What a HEIC becomes before it is uploaded. Off a phone its converter
  /// finds no channel, answers `null`, and every pick passes straight through.
  final PickedImageConversion _conversion;

  @override
  Future<MediaSelection?> pick(MediaKind kind) async {
    final XFile? file;
    try {
      file = switch (kind) {
        MediaKind.image => await _picker.pickImage(source: ImageSource.gallery),
        MediaKind.video => await _picker.pickVideo(source: ImageSource.gallery),
      };
    } on PlatformException {
      throw const MediaFailure.notAllowed();
    }
    if (file == null) return null;

    // The size is cheap and worth showing. A clip's duration is not available
    // here: the picker reports none, so the field is left `null` rather than
    // filled with a guess. Learning it means opening the clip, which is the
    // `ClipInspector`'s job once the panel draws the choice (T-0022).
    int? bytes;
    try {
      bytes = await file.length();
    } on Exception {
      bytes = null;
    }

    // A HEIC photo becomes a JPEG here and nothing else is touched, so what
    // leaves this method is either exactly what Android handed over or a file
    // this app wrote from it (T-0280).
    return _conversion.apply(
      MediaSelection(
        kind: kind,
        source: FileMediaSource(file.path),
        filename: humanFilename(file.name),
        byteCount: bytes,
      ),
    );
  }
}
