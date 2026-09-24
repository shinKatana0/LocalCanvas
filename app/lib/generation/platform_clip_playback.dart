/// Clip playback on Android, behind [ClipPlayback] (T-0211).
///
/// `video_player` is the Flutter team's own package, over ExoPlayer. It is
/// handed a **file**, never a URL: the bytes were fetched through the jobs API,
/// staged into this app's cache the way `PlatformResultExporter` stages a clip
/// it saves, and the staged copy is deleted when the player is disposed.
///
/// Nothing here is exercised by the widget suite — a test has no decoder. What
/// the suite covers is everything around this file, through a recording
/// [ClipPlayback]; what this file does on a phone is verified on a phone.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'clip_playback.dart';
import 'jobs_api.dart';

class PlatformClipPlayback implements ClipPlayback {
  const PlatformClipPlayback();

  /// Where staged clips go, under the app's cache. Its own directory, apart
  /// from the export's, so neither ever deletes a file the other is using.
  static const String _stagingDirectoryName = 'localcanvas-play';

  static int _staged = 0;

  @override
  Future<ClipPlayer> open(ResultBytes clip) async {
    File? staged;
    VideoPlayerController? controller;
    try {
      final cache = await getTemporaryDirectory();
      final directory = Directory('${cache.path}/$_stagingDirectoryName');
      await directory.create(recursive: true);
      // A counter in the name: two results can carry the same filename, and a
      // player still open on one must not have its file replaced under it.
      staged = File('${directory.path}/${_staged++}-${clip.filename}');
      await staged.writeAsBytes(clip.bytes, flush: true);

      controller = VideoPlayerController.file(staged);
      await controller.initialize();
      if (controller.value.hasError) throw const ClipPlaybackFailure();
      await controller.setLooping(true);
      return _PlatformClipPlayer(controller, staged);
    } catch (_) {
      await controller?.dispose();
      await _deleteQuietly(staged);
      throw const ClipPlaybackFailure();
    }
  }
}

class _PlatformClipPlayer implements ClipPlayer {
  _PlatformClipPlayer(this._controller, this._file);

  final VideoPlayerController _controller;
  final File _file;

  @override
  double get aspectRatio => _controller.value.aspectRatio;

  @override
  bool get isPlaying => _controller.value.isPlaying;

  @override
  bool get isMuted => _controller.value.volume == 0;

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> setMuted(bool muted) => _controller.setVolume(muted ? 0 : 1);

  @override
  Widget buildFrame() => VideoPlayer(_controller);

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);

  @override
  Future<void> dispose() async {
    await _controller.dispose();
    await _deleteQuietly(_file);
  }
}

Future<void> _deleteQuietly(File? file) async {
  if (file == null) return;
  try {
    await file.delete();
  } on FileSystemException {
    // Already gone, or the system swept the cache. Nothing to tell anyone.
  }
}
