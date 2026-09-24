/// Test doubles and real fixtures for the media feature.
///
/// The files are real files in a real temporary directory, read through the
/// production [FileMediaSource]. That is deliberate: the lapsed-permission
/// case is exercised by deleting one, so the check under test is the same
/// `File.exists` the app runs on a phone rather than a flag a fake agreed to
/// flip.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/media/clip_inspector.dart';
import 'package:localcanvas/media/media_api.dart';
import 'package:localcanvas/media/media_picker.dart';
import 'package:localcanvas/media/media_selection.dart';

/// A picker driven by the test instead of by Android.
class ScriptedMediaPicker implements MediaPicker {
  ScriptedMediaPicker([this.answers = const <MediaSelection?>[]]);

  /// Handed out in order; the last one repeats once the list runs out.
  List<MediaSelection?> answers;

  /// Thrown instead of answering, for the refused-permission case.
  MediaFailure? failure;

  int calls = 0;
  final List<MediaKind> asked = <MediaKind>[];

  /// When set, the pick waits for it — so a test can look at the interface
  /// while the picker is open.
  Completer<void>? gate;

  @override
  Future<MediaSelection?> pick(MediaKind kind) async {
    calls++;
    asked.add(kind);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    if (answers.isEmpty) return null;
    return calls <= answers.length ? answers[calls - 1] : answers.last;
  }
}

/// An upload driven by the test: it counts its calls, can be held open, and
/// can report whatever progress the test wants to see rendered.
class ScriptedMediaApi implements MediaApi {
  int calls = 0;
  final List<MediaSelection> uploaded = <MediaSelection>[];

  /// Thrown once the gate opens, for the failed-upload case.
  MediaFailure? failure;

  String nextMediaId = 'm-3f9c1a';

  /// What the gateway claims it stored. `null` echoes the selection's own
  /// size, which is what a real one does.
  int? reportedByteCount;

  /// Held open until [finish] is called, when true.
  bool manual = false;

  Completer<void>? _gate;
  MediaProgress? _progress;

  @override
  Future<UploadedMedia> upload(
    Endpoint endpoint,
    MediaSelection selection, {
    MediaProgress? onProgress,
  }) async {
    // The identity of *this* upload, fixed before the gate. Reading `calls`
    // at return time would give a held reply the id of whichever upload
    // started last, and a test asking whether a stale reply was discarded
    // could then never fail.
    final id = '$nextMediaId-${++calls}';
    uploaded.add(selection);
    _progress = onProgress;
    if (manual) {
      final gate = _gate = Completer<void>();
      await gate.future;
    }
    final failure = this.failure;
    if (failure != null) throw failure;
    return UploadedMedia(
      mediaId: id,
      filename: selection.filename,
      // A real gateway always counts the bytes it stored, so the default
      // echoes the file's own size rather than `null`. A `null` here would
      // quietly skip the `copyWith` in `_accept`, and with it every
      // assertion about which selection a reply was written into.
      byteCount: reportedByteCount ?? selection.byteCount,
    );
  }

  /// Reports progress the way the real transport does: from the body stream.
  void report(int sent, int? total) => _progress?.call(sent, total);

  /// Lets a held upload finish.
  void finish() => _gate?.complete();
}

/// Clip inspection, recorded rather than decoded (T-0022).
///
/// Every file it was asked to open, every inspection it handed out, and — on
/// each inspection — how many times it was disposed: the facts the panel is
/// responsible for. Modelled on `RecordingClipPlayback`.
///
/// It answers **only** with what an inspection is: a frame and a length. It
/// never touches the selection, so a length that reaches the detail line got
/// there because the app wrote it there.
class RecordingClipInspector implements ClipInspector {
  final List<File> asked = <File>[];
  final List<FakeClipInspection> inspections = <FakeClipInspection>[];

  /// Thrown by [inspect] instead of answering. Usually a
  /// [ClipInspectionFailure]; anything else stands for an inspector that
  /// broke its contract (T-0231).
  Object? failure;

  /// The length the next inspection reports, decided when it is asked.
  Duration? duration = const Duration(seconds: 7);

  /// Hold one answer: the next [inspect] takes the gate, decides its answer
  /// at once, and returns only when the test completes it. Taken by exactly
  /// one call, so a second clip chosen meanwhile is answered straight away.
  Completer<void>? gate;

  @override
  Future<ClipInspection> inspect(File clip) async {
    asked.add(clip);
    final refused = failure;
    final length = duration;
    final pending = gate;
    gate = null;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    final inspection = FakeClipInspection(
      clip,
      length,
      serial: inspections.length,
    );
    inspections.add(inspection);
    return inspection;
  }
}

/// An inspection with no decoder: a frame that is only a keyed box, a length,
/// and a record of being disposed. Using either after dispose throws, so a
/// frame drawn from a released inspection fails the test that drew it.
class FakeClipInspection implements ClipInspection {
  FakeClipInspection(this.clip, this._duration, {required int serial})
    : frameKey = ValueKey<String>('test.clip-frame.$serial');

  final File clip;
  final Duration? _duration;

  /// The key on this inspection's frame, and on no other's.
  final Key frameKey;

  int disposeCount = 0;

  void _use() {
    if (disposeCount > 0) {
      throw StateError('FakeClipInspection used after dispose');
    }
  }

  @override
  Duration? get duration {
    _use();
    return _duration;
  }

  @override
  Widget buildFrame() {
    _use();
    return ColoredBox(key: frameKey, color: const Color(0xFF304050));
  }

  @override
  Future<void> dispose() async {
    // Counted, never refused: a second dispose is a defect to observe.
    disposeCount++;
  }
}

/// A real file on disk, cleaned up when the test ends.
File writeTempMedia(String name, {int bytes = 2048, List<int>? contents}) {
  final dir = Directory.systemTemp.createTempSync('localcanvas_media_test');
  addTearDown(() {
    // Windows keeps a decoded image's file open for a moment after the test
    // ends; a temporary directory that outlives the run is untidy, not a
    // failure, and must not be reported as one.
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the system to sweep up.
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  file.writeAsBytesSync(
    contents ?? (Uint8List(bytes)..fillRange(0, bytes, 0x41)),
  );
  return file;
}

/// A selection of a real file, as the picker would have produced it.
MediaSelection tempSelection({
  MediaKind kind = MediaKind.image,
  String name = 'IMG_0142.jpg',
  int bytes = 2048,
  String? filename,
  bool named = true,
  bool knownSize = true,
  Duration? duration,
  List<int>? contents,
}) {
  final file = writeTempMedia(name, bytes: bytes, contents: contents);
  return MediaSelection(
    kind: kind,
    source: FileMediaSource(file.path),
    filename: named ? (filename ?? humanFilename(name)) : null,
    byteCount: knownSize ? (contents?.length ?? bytes) : null,
    duration: duration,
  );
}

/// A source that yields exactly the chunks it was given.
///
/// Two things depend on that. With [length] left null it is a stream whose
/// size cannot be learned, which is what makes an upload honestly
/// indeterminate. With chunks of chosen, uneven sizes it pins the progress
/// count to the stream itself: a fabricated ramp can look monotonic and can
/// end in the right place, but it cannot land on 7, 1007, 1040.
class ChunkedMediaSource implements MediaSource {
  ChunkedMediaSource(this.chunks, {this.length});

  final List<List<int>> chunks;
  final int? length;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<int?> byteLength() async => length;

  @override
  Stream<List<int>> openRead() async* {
    for (final chunk in chunks) {
      yield chunk;
    }
  }

  @override
  File? get previewFile => null;
}

/// A real 8×8 PNG, so a preview test decodes real bytes rather than trusting
/// that a decoder was asked.
final Uint8List realPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08,
  0x08, 0x06, 0x00, 0x00, 0x00, 0xC4, 0x0F, 0xBE, 0x8B, 0x00, 0x00, 0x00,
  0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0x11, 0x65, 0xF3,
  0x1F, 0x1F, 0x66, 0x18, 0x19, 0x0A, 0x00, 0xF1, 0xAB, 0x97, 0x41, 0xF5,
  0x8F, 0xBA, 0xEA, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
