/// Playing a result clip, as an interface (`docs/ui-ux.md`: "Video result:
/// local preview where practical"; T-0211).
///
/// A platform surface, so it lives behind this the way Save and Share do: the
/// app is handed one at composition time, a test is handed a recording, and a
/// build that has none draws the "your clip is ready" panel it always drew
/// rather than a player that cannot play.
///
/// **A player is handed bytes, never an address.** The bytes came through
/// `JobsApi.fetchResult`, which is the one place a result path becomes a URL
/// (`docs/transport-boundary.md`). A player that opened the gateway's URL
/// itself would be a second one, without the timeout, the language header or
/// the error mapping the first carries.
library;

import 'package:flutter/widgets.dart';

import 'jobs_api.dart';

/// Opens players.
abstract interface class ClipPlayback {
  /// A player over [clip], ready to draw and looping — a generated clip is
  /// short enough that looping is the ordinary way to look at one.
  ///
  /// Whether it is muted or playing is **not** this method's promise: the
  /// surface sets both on every player it gets (T-0211), so the rule "starts
  /// muted" lives in the one place a test can watch it being applied.
  ///
  /// Throws [ClipPlaybackFailure] when this device cannot play it. The bytes
  /// are not wrong for that — Save and Share still work.
  Future<ClipPlayer> open(ResultBytes clip);
}

/// One clip, playing or paused. Tells its listeners when either changes.
abstract interface class ClipPlayer implements Listenable {
  /// Width over height of the frame.
  double get aspectRatio;

  bool get isPlaying;
  bool get isMuted;

  Future<void> play();
  Future<void> pause();
  Future<void> setMuted(bool muted);

  /// The frame. May be built in more than one place at once — the surface
  /// and the almost-full-screen viewer draw the same decoder.
  Widget buildFrame();

  /// Stops playback and releases everything the player took, including any
  /// file it staged. Nothing may be called after it.
  Future<void> dispose();
}

/// This device could not play the clip.
class ClipPlaybackFailure implements Exception {
  const ClipPlaybackFailure();

  @override
  String toString() => 'ClipPlaybackFailure';
}
