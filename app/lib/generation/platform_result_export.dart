/// Save and Share on Android, behind [ResultExporter].
///
/// Two plugins and one directory:
///
/// * `gal` writes into the device's own gallery. It has no transitive
///   dependencies and adds no permission to the manifest — on Android 10 and
///   later saving through MediaStore needs none, and this app's `minSdk` is
///   the Flutter default, above the releases that did.
/// * `share_plus` opens the system share sheet, which is what
///   `docs/ui-ux.md` means by *native Android Share*. It contributes a
///   `FileProvider` and a broadcast receiver to the merged manifest, under the
///   app's own id, so that the receiving app is granted a URI rather than a
///   path.
/// * `path_provider` names the app's own cache directory. Both a shared file
///   and a saved clip need a real file on disk — `Gal.putVideo` takes a path,
///   and the share sheet hands the receiver a provider URI backed by one — and
///   `Directory.systemTemp` is not that directory on Android.
///
/// Staged files are written into a directory of ours inside the cache and
/// deleted after the platform call returns. Nothing is kept: there is no
/// gallery and no history in this app (`docs/ui-ux.md`).
library;

import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'result_export.dart';

class PlatformResultExporter implements ResultExporter {
  const PlatformResultExporter();

  /// Where staged copies go, under the app's cache. Named so it is obvious in
  /// a file listing what put it there.
  static const String _stagingDirectoryName = 'localcanvas-share';

  @override
  Future<void> save(ResultFile file) async {
    try {
      if (file.isVideo) {
        // A clip has to exist as a file before the gallery will take it.
        await _withStagedFile(file, (staged) => Gal.putVideo(staged.path));
        return;
      }
      await Gal.putImageBytes(file.bytes, name: _bareName(file.filename));
    } on GalException catch (error) {
      throw switch (error.type) {
        GalExceptionType.accessDenied => const ExportFailure.accessDenied(),
        GalExceptionType.notEnoughSpace => const ExportFailure.notEnoughSpace(),
        GalExceptionType.notSupportedFormat =>
          const ExportFailure.unsupportedFormat(),
        GalExceptionType.unexpected => const ExportFailure.failed(),
      };
    } on FileSystemException {
      throw const ExportFailure.notEnoughSpace();
    } on ExportFailure {
      rethrow;
    } catch (_) {
      throw const ExportFailure.failed();
    }
  }

  @override
  Future<void> share(ResultFile file) async {
    try {
      await _withStagedFile(file, (staged) async {
        await SharePlus.instance.share(
          ShareParams(
            files: <XFile>[
              XFile(staged.path, mimeType: file.mediaType, name: file.filename),
            ],
            fileNameOverrides: <String>[file.filename],
          ),
        );
      });
    } on ExportFailure {
      rethrow;
    } on FileSystemException {
      throw const ExportFailure.notEnoughSpace();
    } catch (_) {
      throw const ExportFailure.failed();
    }
  }

  /// Writes the bytes into the cache, runs [use], and takes the copy away
  /// again — whether [use] succeeded or not.
  Future<void> _withStagedFile(
    ResultFile file,
    Future<void> Function(File staged) use,
  ) async {
    final cache = await getTemporaryDirectory();
    final directory = Directory('${cache.path}/$_stagingDirectoryName');
    await directory.create(recursive: true);
    final staged = File('${directory.path}/${file.filename}');
    await staged.writeAsBytes(file.bytes, flush: true);
    try {
      await use(staged);
    } finally {
      try {
        await staged.delete();
      } on FileSystemException {
        // The share sheet may still be reading it, or the system may have
        // swept the cache already. Neither is worth telling the user about.
      }
    }
  }

  /// `Gal.putImageBytes` appends the extension itself, so it gets the stem.
  static String _bareName(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 ? filename : filename.substring(0, dot);
  }
}
