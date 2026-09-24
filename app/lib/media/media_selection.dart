/// What the app knows about a chosen picture or clip — and, deliberately, what
/// it refuses to say out loud.
///
/// A selection carries a [MediaSource]: the handle the bytes are read through.
/// That handle is a filesystem path or a content URI, and **neither is ever
/// shown**. `docs/ui-ux.md` states the rule and this file is where it is
/// enforced rather than remembered: the only string the interface may take
/// from here is [MediaSelection.displayName], which is a filename or a human
/// sentence, never a reference.
///
/// A source can also stop working. Android hands out a permission for a picked
/// item, not a promise, and a cached copy can be evicted. So a source answers
/// [MediaSource.isAvailable] and the form asks it again on restore, rather
/// than discovering the loss at upload time (`docs/recovery.md`).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import '../l10n/gateway_errors.dart';

/// The two media kinds the schema declares (`docs/workflow-schema.md`).
enum MediaKind {
  image,
  video;

  /// The value `POST /api/v1/media` expects in its `kind` part.
  String get wireName => name;

  /// "picture" / "clip" — the words the interface uses for a person.
  String noun(L l) =>
      this == MediaKind.image ? l.mediaNounPicture : l.mediaNounClip;
}

/// Where the bytes come from.
///
/// An interface, so a test reads a real file from a real temporary directory
/// while the app reads whatever the Android picker handed back.
abstract interface class MediaSource {
  /// Whether the bytes can still be read. False once a permission has lapsed
  /// or a cached copy has been swept away.
  Future<bool> isAvailable();

  /// The length in bytes, or `null` when it cannot be learned without reading
  /// the whole thing. A `null` here is what makes an upload's progress
  /// honestly indeterminate rather than a made-up percentage.
  Future<int?> byteLength();

  /// The bytes, read as they are consumed.
  Stream<List<int>> openRead();

  /// A local file the framework can decode for a preview, when there is one.
  ///
  /// This is the one place a path leaves this class, and it goes to an image
  /// decoder — never to a [Text]. A source that has no local file returns
  /// `null` and the interface shows no preview, which is honest.
  File? get previewFile;
}

/// A source backed by a file on this device.
class FileMediaSource implements MediaSource {
  const FileMediaSource(this.path);

  /// Never displayed. See the library comment.
  final String path;

  File get _file => File(path);

  @override
  Future<bool> isAvailable() => _file.exists();

  @override
  Future<int?> byteLength() async {
    try {
      return await _file.length();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Stream<List<int>> openRead() => _file.openRead();

  @override
  File? get previewFile => _file;

  @override
  bool operator ==(Object other) =>
      other is FileMediaSource && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// One chosen picture or clip.
@immutable
class MediaSelection {
  const MediaSelection({
    required this.kind,
    required this.source,
    this.filename,
    this.byteCount,
    this.duration,
  });

  final MediaKind kind;
  final MediaSource source;

  /// The name a person would recognise, already reduced to a name by
  /// [humanFilename]. `null` when the platform gave nothing human.
  final String? filename;

  /// Size in bytes, where the platform reported one.
  final int? byteCount;

  /// A clip's length, where one is known. Android's own picker reports none;
  /// where this build can open the clip, the length its `ClipInspector`
  /// measured is written in by `MediaFieldController.adoptClipDuration`
  /// (T-0022). Nothing invents a number to fill the gap.
  final Duration? duration;

  /// What the interface writes next to the preview.
  ///
  /// The fallback is a sentence, not the reference. "Chosen picture" says less
  /// than a filename and is true; `content://media/external/...` says more
  /// than a person can use and breaks the rule in `docs/ui-ux.md`.
  String displayName(L l) =>
      filename ??
      (kind == MediaKind.image ? l.mediaChosenPicture : l.mediaChosenClip);

  /// Size and, for a clip, duration — only the parts that are known.
  ///
  /// Empty when nothing is known, so the interface shows no line at all rather
  /// than a row of dashes.
  String detailLine(L l) {
    final parts = <String>[
      if (duration != null) formatMediaDuration(duration!),
      if (byteCount != null) formatByteCount(l, byteCount!),
    ];
    return parts.join(' · ');
  }

  MediaSelection copyWith({int? byteCount, Duration? duration}) =>
      MediaSelection(
        kind: kind,
        source: source,
        filename: filename,
        byteCount: byteCount ?? this.byteCount,
        duration: duration ?? this.duration,
      );
}

/// Reduces whatever the platform called a file to something a person can read,
/// or to `null`.
///
/// The rule is the contract's: a filename may be shown, a reference may not.
/// So a URI is refused outright rather than mined for a last segment — the
/// tail of `content://media/external/images/media/1024` is a row id, and the
/// tail of a document URI is a percent-encoded tree path. Both would satisfy a
/// naive "take the basename" and neither is a name.
String? humanFilename(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (value.contains('://')) return null;
  final cut = value.lastIndexOf(RegExp(r'[/\\]'));
  if (cut >= 0) value = value.substring(cut + 1);
  value = value.trim();
  if (value.isEmpty) return null;
  // What is left of `C:` or of `primary:Pictures` is not a filename either.
  // A colon is legal on ext4 — `2026-09-02 10:30.jpg` is a real name — so
  // this does refuse a few genuine ones; it errs towards the sentence, which
  // is always readable, over a fragment of a document id, which is not.
  if (value.contains(':')) return null;
  return value;
}

/// A size a person reads, in the units a phone gallery uses.
///
/// The **number** keeps the digits and the decimal point every other number in
/// this app is written with, in every locale. A size drawn `1,4 MB` beside a
/// field the app writes `1.4` into would be two conventions on one screen for
/// no gain; only the unit, and the word for a plain count of bytes, are
/// translated.
String formatByteCount(L l, int bytes) {
  if (bytes < 0) return '';
  if (bytes < 1000) return l.byteCount(bytes);
  final List<String> units = <String>[
    l.byteUnitKilo,
    l.byteUnitMega,
    l.byteUnitGiga,
    l.byteUnitTera,
  ];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value < 10 ? 1 : 0;
  return l.byteSize(value.toStringAsFixed(digits), units[unit]);
}

/// A clip's length as a clock reads it: `0:07`, `1:04`, `1:02:03`.
String formatMediaDuration(Duration duration) {
  final total = duration.inSeconds;
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = (total ~/ 60) % 60;
  final hours = total ~/ 3600;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

/// The five ways choosing or sending media can fail.
enum MediaFailureKind {
  /// The picker refused, most often because the choice was not granted.
  notAllowed,

  /// The file was gone by the time it was needed.
  gone,

  /// Nothing answered, or the answer never arrived.
  unreachable,

  /// Something answered with a body this app cannot read as a media document.
  unreadable,

  /// The gateway said no, and named which of its codes it was.
  refused,
}

/// Why choosing or sending media did not work.
///
/// Same shape and same discipline as `WorkflowsFailure`: a status code, a
/// socket error and a denied permission are three things to a programmer and
/// one thing to a person — "it did not go" — plus what to do next. No
/// exception text ever reaches the screen (`docs/ui-ux.md`).
///
/// **This is where the whole of T-0142 turns on one field.** Before it, a
/// refusal was the gateway's own English sentence, stored here and shown as
/// it arrived — so a fully translated app still met a person in English the
/// first time an upload was refused. Now the refusal carries the `code`
/// `docs/api.md` promises is stable, and the panel that draws it says what
/// *this app* has to say about that code, in the language on screen. The
/// gateway's words are kept for codes this app has nothing of its own to say
/// about, because a sentence a person can quote to whoever runs the PC beats a
/// generic one they cannot.
@immutable
class MediaFailure implements Exception {
  const MediaFailure(this.kind, {this.code, this.serverMessage});

  const MediaFailure.notAllowed()
    : kind = MediaFailureKind.notAllowed,
      code = null,
      serverMessage = null;

  const MediaFailure.gone()
    : kind = MediaFailureKind.gone,
      code = null,
      serverMessage = null;

  const MediaFailure.unreachable()
    : kind = MediaFailureKind.unreachable,
      code = null,
      serverMessage = null;

  const MediaFailure.unreadable()
    : kind = MediaFailureKind.unreadable,
      code = null,
      serverMessage = null;

  const MediaFailure.refused({this.code, this.serverMessage})
    : kind = MediaFailureKind.refused;

  final MediaFailureKind kind;

  /// The gateway's stable token, where it sent one.
  final String? code;

  /// What the gateway wrote, kept only so a code this app does not know can
  /// still be quoted rather than swallowed.
  final String? serverMessage;

  String title(L l) => switch (kind) {
    MediaFailureKind.notAllowed => l.mediaNotAllowedTitle,
    MediaFailureKind.gone => l.mediaGoneTitle,
    MediaFailureKind.unreachable => l.mediaUploadUnreachableTitle,
    MediaFailureKind.unreadable => l.serverUnreadableTitle,
    MediaFailureKind.refused => l.mediaUploadRefusedTitle,
  };

  String message(L l) => switch (kind) {
    MediaFailureKind.notAllowed => l.mediaNotAllowedMessage,
    MediaFailureKind.gone => l.mediaGoneMessage,
    MediaFailureKind.unreachable => l.serverUnreachableMessage,
    MediaFailureKind.unreadable => l.serverUnreadableMessage,
    MediaFailureKind.refused => refusalSentence(
      l,
      code: code,
      serverMessage: serverMessage,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is MediaFailure &&
      other.kind == kind &&
      other.code == code &&
      other.serverMessage == serverMessage;

  @override
  int get hashCode => Object.hash(kind, code, serverMessage);

  @override
  String toString() => 'MediaFailure(${kind.name}, code: $code)';
}
