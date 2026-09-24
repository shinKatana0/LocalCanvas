/// The profile leaving and entering the app on Android, behind
/// [ProfileTransport].
///
/// Three plugins, all of which the app already had a reason for except the
/// last:
///
/// * `path_provider` names the app's own cache directory. The document has to
///   exist as a real file for a moment, because the share sheet hands the
///   receiving app a provider URI backed by one, and `Directory.systemTemp` is
///   not that directory on Android.
/// * `share_plus` opens the system share sheet — the same native Share the
///   result already uses. Where the profile ends up is the user's decision and
///   this app never learns it.
/// * `file_selector` opens the system document picker on the way back in. It
///   is the ninth dependency and the only one this feature adds; `pubspec.yaml`
///   says why in full.
///
/// The staged copy is written into a directory of ours inside the cache and
/// deleted after the platform call returns, exactly as a shared result is.
/// Nothing is kept: this app has no file of its own outside the preferences.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart' as chooser;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'profile_transport.dart';
import 'workflow_profile.dart';

class PlatformProfileTransport implements ProfileTransport {
  const PlatformProfileTransport();

  /// Where the staged copy goes, under the app's cache. Named so it is obvious
  /// in a file listing what put it there.
  static const String _stagingDirectoryName = 'localcanvas-profile';

  /// What the document is, for the picker and for the share sheet alike.
  static const String _mediaType = 'application/json';

  @override
  Future<void> send(ProfileDocument document) async {
    try {
      final cache = await getTemporaryDirectory();
      final directory = Directory('${cache.path}/$_stagingDirectoryName');
      await directory.create(recursive: true);
      final staged = File('${directory.path}/${document.filename}');
      await staged.writeAsString(document.text, flush: true);
      try {
        await SharePlus.instance.share(
          ShareParams(
            files: <XFile>[
              XFile(
                staged.path,
                mimeType: _mediaType,
                name: document.filename,
              ),
            ],
            fileNameOverrides: <String>[document.filename],
          ),
        );
      } finally {
        try {
          await staged.delete();
        } on FileSystemException {
          // The receiving app may still be reading it, or the system may have
          // swept the cache already. Neither is worth telling the user about.
        }
      }
    } on ProfileFailure {
      rethrow;
    } catch (_) {
      throw const ProfileFailure.failed();
    }
  }

  @override
  Future<String?> receive({String? typeLabel}) async {
    try {
      final chosen = await chooser.openFile(
        acceptedTypeGroups: <chooser.XTypeGroup>[
          // Both are given because the two halves of Android answer to
          // different ones: the document picker filters on the MIME type, and
          // a file whose provider reports nothing useful is still recognisable
          // by its extension.
          chooser.XTypeGroup(
            label: typeLabel,
            extensions: <String>['json'],
            mimeTypes: <String>[_mediaType],
          ),
        ],
      );
      // Choosing nothing is an answer. It is not a failure and nothing is said
      // about it afterwards.
      if (chosen == null) return null;
      return await chosen.readAsString();
    } catch (_) {
      throw const ProfileFailure.failed();
    }
  }
}
