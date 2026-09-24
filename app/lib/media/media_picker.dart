/// Choosing a picture or a clip.
///
/// The interface only. The implementation that talks to Android's own picker
/// is `gallery_picker.dart`, and it is the single file in this feature that
/// cannot run off a device — the same split the discovery backend uses, and
/// for the same reason: the form, the upload and every state they produce are
/// exercised in tests without a platform channel.
library;

import 'media_selection.dart';

abstract interface class MediaPicker {
  /// Opens the picker. `null` means the user backed out, which is a decision
  /// and must not be reported as an error.
  ///
  /// Throws [MediaFailure] when the platform refused.
  Future<MediaSelection?> pick(MediaKind kind);
}
