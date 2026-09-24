/// Save and Share, as an interface (`docs/ui-ux.md`).
///
/// Both are platform surfaces, so they live behind this the way the media
/// picker does: the app is handed one at composition time, a test is handed a
/// script, and a build that has neither offers neither affordance rather than
/// a button that cannot honour a tap.
library;

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';

/// One finished result, ready to leave the app.
@immutable
class ResultFile {
  const ResultFile({
    required this.bytes,
    required this.filename,
    required this.mediaType,
  });

  final Uint8List bytes;

  /// A name, never a path (`docs/ui-ux.md`).
  final String filename;
  final String mediaType;

  bool get isVideo => mediaType.startsWith('video/');
}

/// The four ways saving or sharing can fail.
enum ExportFailureKind {
  /// The gallery said no. The one failure with an action attached to it.
  accessDenied,
  notEnoughSpace,
  unsupportedFormat,
  failed,
}

/// Why saving or sharing did not work.
@immutable
class ExportFailure implements Exception {
  const ExportFailure(this.kind);

  const ExportFailure.accessDenied() : kind = ExportFailureKind.accessDenied;
  const ExportFailure.notEnoughSpace()
    : kind = ExportFailureKind.notEnoughSpace;
  const ExportFailure.unsupportedFormat()
    : kind = ExportFailureKind.unsupportedFormat;
  const ExportFailure.failed() : kind = ExportFailureKind.failed;

  final ExportFailureKind kind;

  String title(L l) => switch (kind) {
    ExportFailureKind.accessDenied => l.exportAccessDeniedTitle,
    ExportFailureKind.notEnoughSpace => l.exportNotEnoughSpaceTitle,
    ExportFailureKind.unsupportedFormat => l.exportUnsupportedFormatTitle,
    ExportFailureKind.failed => l.didntWorkTitle,
  };

  String message(L l) => switch (kind) {
    ExportFailureKind.accessDenied => l.exportAccessDeniedMessage,
    ExportFailureKind.notEnoughSpace => l.exportNotEnoughSpaceMessage,
    ExportFailureKind.unsupportedFormat => l.exportUnsupportedFormatMessage,
    ExportFailureKind.failed => l.tryAgainMessage,
  };

  @override
  bool operator ==(Object other) =>
      other is ExportFailure && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'ExportFailure(${kind.name})';
}

/// Putting a result somewhere outside the app.
abstract interface class ResultExporter {
  /// Into the device's own gallery.
  Future<void> save(ResultFile file);

  /// Into Android's share sheet.
  Future<void> share(ResultFile file);
}
