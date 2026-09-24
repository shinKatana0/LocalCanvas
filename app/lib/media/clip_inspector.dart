/// A still frame and a length for a chosen clip, as an interface
/// (`docs/ui-ux.md`: "Video: picker, preview/thumbnail where practical,
/// filename, size and duration where easily available"; T-0022).
///
/// A platform surface, so it lives behind this the way `ClipPlayback` does:
/// the app is handed one at composition time, a test is handed a recording,
/// and a build that has none draws the marked tile it always drew.
///
/// **It opens the file the picker already gave** — [MediaSource.previewFile] —
/// and nothing else. It reads no bytes for the upload and makes no copy; the
/// upload path does not know it exists.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';

/// How long a chosen clip is given to produce a frame before the field stops
/// waiting for one.
///
/// Five seconds, for a file that is already on this device. Until then the
/// field shows the marked tile it would show anyway, so the wait costs nothing
/// visible; past it the tile simply stays, and a result that arrives later is
/// released unseen. The number is a choice, not a measurement: how long
/// opening a clip takes on a given phone is not something the widget suite
/// can see, and it has not been timed on one.
const Duration kClipInspectionBound = Duration(seconds: 5);

/// Opens clips far enough to draw one frame of them.
abstract interface class ClipInspector {
  /// A paused view of [clip] at its start, with its length.
  ///
  /// Throws [ClipInspectionFailure] when this device cannot decode it. The
  /// clip is not wrong for that — it is still uploaded as it was.
  Future<ClipInspection> inspect(File clip);
}

/// One clip, opened and paused. Whoever receives it owns it and disposes it.
abstract interface class ClipInspection {
  /// The clip's length, or `null` when the decoder could not say.
  Duration? get duration;

  /// The still frame, filling whatever box it is drawn in without distortion.
  Widget buildFrame();

  /// Releases the decoder. Nothing may be called after it.
  Future<void> dispose();
}

/// This device could not open the clip.
class ClipInspectionFailure implements Exception {
  const ClipInspectionFailure();

  @override
  String toString() => 'ClipInspectionFailure';
}
