/// Getting a profile out of the app and back into it, as an interface.
///
/// The same shape as `generation/result_export.dart`, and for the same reason:
/// both ends are platform surfaces, so the app is handed one of these at
/// composition time, a test is handed a script, and a build that has none
/// offers neither affordance rather than a button that cannot honour a tap.
///
/// It carries **text**, not a file. Where the document is staged on the way
/// out, and how the user is asked for one on the way in, are the platform's
/// business and stay on the far side of this seam — which is what keeps
/// everything above it free of a path.
library;

import 'package:flutter/foundation.dart';

/// A profile on its way out of the app.
@immutable
class ProfileDocument {
  const ProfileDocument({required this.text, required this.filename});

  /// The whole document.
  final String text;

  /// A name, never a path (`docs/ui-ux.md`).
  final String filename;
}

/// Handing a profile to the system, and taking one back from it.
abstract interface class ProfileTransport {
  /// Offers [document] to whatever the user picks — a messenger, a cloud
  /// drive, a file manager. Where it ends up is their decision and this app
  /// never learns it.
  Future<void> send(ProfileDocument document);

  /// Asks the user for a document and answers with its text, or `null` when
  /// they chose none.
  ///
  /// Cancelling is an answer, not a failure: it produces `null`, and nothing
  /// is said about it afterwards.
  ///
  /// [typeLabel] is what the system's own document picker calls this kind of
  /// file. It is handed down from the screen rather than written here, because
  /// it is the one sentence on that surface this app gets to choose and a
  /// person reads it in whatever language the app is in (T-0142).
  Future<String?> receive({String? typeLabel});
}
