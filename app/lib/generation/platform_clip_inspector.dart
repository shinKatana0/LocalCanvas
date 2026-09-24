/// A chosen clip's still frame and length on Android, behind [ClipInspector]
/// (T-0022).
///
/// The same `video_player` the result surface plays clips with (T-0211), so
/// this adds no dependency, no permission and no network: it is handed the
/// **file the picker already gave** (`VideoPlayerController.file`, never a
/// URL), this file makes no copy of it, and nothing here calls `play`. The
/// controller is initialised and left there, and its length is read from
/// `value.duration`.
///
/// A test has no decoder, so the widget suite covers what is around this file,
/// through a recording [ClipInspector]. Two paths through this file are driven
/// (`platform_clip_inspector_test.dart`): a real controller whose player is
/// never created, which must not keep [inspect] from answering, and — through
/// [open] — a controller that fails to open, which must be asked to release.
/// Release after a *late* creation is video_player's own ordering and is not
/// driven by any test here. Whether
/// ExoPlayer draws the first frame of a paused, never-played clip into this
/// texture, how long opening one takes, and how a rotated clip is framed are
/// properties of the phone and have not been verified on one.
///
/// **What giving up releases** (read in video_player 2.14.0, not driven on a
/// device; T-0231). `VideoPlayerController.dispose` first waits for the
/// platform player to have been *created*, and only then asks the platform to
/// dispose it. So:
///
/// * a player whose creation completes — even after [kClipInspectionBound] —
///   is disposed the moment it does, by the release started when this gave
///   up;
/// * a player whose creation never completes (the platform never answers, or
///   answers with an error) is never released: that `dispose` never returns,
///   there is no player id on this side to release, and video_player keeps its
///   app-lifecycle observer registered. This file has no handle on either;
/// * after a late creation, `initialize` goes on to subscribe to the player's
///   events once `dispose` has already looked for that subscription, so that
///   subscription is not cancelled by it. That is video_player's own ordering.
///
/// None of this holds up [inspect]: it throws [ClipInspectionFailure] as soon
/// as it gives up and does not wait for the release, so a release that never
/// finishes cannot keep the inspection from answering.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../media/clip_inspector.dart';

class PlatformClipInspector implements ClipInspector {
  const PlatformClipInspector({this.open = VideoPlayerController.file});

  /// Makes the controller for a clip. The app always takes the default; a test
  /// hands in a controller that records what was asked of it (T-0231).
  final VideoPlayerController Function(File clip) open;

  @override
  Future<ClipInspection> inspect(File clip) async {
    VideoPlayerController? controller;
    try {
      controller = open(clip);
      // Bounded here as well as by the panel, because this is the one party
      // holding the controller: the panel cannot dispose what it was never
      // given. What that release can and cannot free is in the library
      // comment above.
      await controller.initialize().timeout(kClipInspectionBound);
      final value = controller.value;
      // No picture to show — an audio-only file, or a decoder that reported
      // nothing — is a failure, not a zero-sized frame drawn as if it were one.
      if (value.hasError || !value.isInitialized || value.size.isEmpty) {
        throw const ClipInspectionFailure();
      }
      return _PlatformClipInspection(controller);
    } catch (_) {
      // Started, never awaited: it finishes when the player's creation does,
      // which may be never (T-0231).
      if (controller != null) unawaited(_release(controller));
      throw const ClipInspectionFailure();
    }
  }

  static Future<void> _release(VideoPlayerController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
      // Already unusable; there is nothing further to release.
    }
  }
}

class _PlatformClipInspection implements ClipInspection {
  _PlatformClipInspection(this._controller);

  final VideoPlayerController _controller;

  /// `video_player` reports an unknown length as zero. Zero is not a length a
  /// person should read, so it is no length.
  @override
  Duration? get duration {
    final value = _controller.value.duration;
    return value > Duration.zero ? value : null;
  }

  /// The frame at its own aspect, scaled to cover the box it is drawn in and
  /// cropped to it — the way a picture's thumbnail is (`BoxFit.cover`).
  @override
  Widget buildFrame() {
    final size = _controller.value.size;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoPlayer(_controller),
      ),
    );
  }

  @override
  Future<void> dispose() => _controller.dispose();
}
