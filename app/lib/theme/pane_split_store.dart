/// Where this device keeps the split the user dragged between the two panes
/// (`docs/ui-ux.md`, the wide layout).
///
/// **Device-local, on purpose, and for the reason the theme is** — this file
/// is deliberately shaped like `theme_mode_store.dart` rather than being a
/// second pattern. A split chosen on the screen in front of you is a fact
/// about that screen, not about the workflows you build, so it has no business
/// in the portable profile any more than the brightness has (T-0132): the
/// document a person hands to somebody else is described to them as their
/// settings and setups, and this is neither.
///
/// **What is stored is a share of the window, not a number of pixels.** The
/// value replaces the one constant `connected_shell.dart` used to hold, and
/// nothing else about that expression changes: the pane is still that share of
/// the available width, still clamped. Storing dp instead would mean a split
/// chosen on an unfolded screen came back as a very different share of a
/// folded-then-rotated one — the same number, a different layout — and what
/// the person dragging it can see is the share.
///
/// **Nothing said is not the same as a number.** [PaneSplitStore.load] answers
/// `null` for a device nobody has ever dragged, which is what a first run and a
/// phone with cleared app data both are. What the app draws in that case is the
/// app's decision and not this file's, and it is the same proportion it drew
/// before this store existed.
library;

import 'package:shared_preferences/shared_preferences.dart';

abstract class PaneSplitStore {
  /// The share of the window the controls pane was last dragged to, or `null`
  /// when this device has never been dragged — including when what is stored
  /// is not a share this store could have written.
  Future<double?> load();

  /// Remembers [share], a fraction of the window's width.
  Future<void> save(double share);
}

/// The on-device implementation.
class PreferencesPaneSplitStore implements PaneSplitStore {
  PreferencesPaneSplitStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  /// Namespaced the way the remembered brightness is, and outside
  /// `localcanvas.defaults.` — which the portable profile is built by
  /// scanning, and which this must therefore never be inside.
  ///
  /// Public because the test that proves this key never leaves the phone has
  /// to name the very key the app writes; a copy of the string in the test
  /// would go on passing the day this one was renamed.
  static const String key = 'localcanvas.pane_split';

  final SharedPreferencesAsync _prefs;

  @override
  Future<double?> load() async => _decode(await _prefs.getDouble(key));

  @override
  Future<void> save(double share) => _prefs.setDouble(key, share);

  /// Anything that is not a share of a window reads as nothing said: absent, a
  /// zero, a one, a negative, a value past the whole window, a `NaN` written
  /// by a build that had a bug, or something hand-edited into the file. Each
  /// of those would otherwise come back as a pane of no width or of all of it,
  /// and the layout would be unusable before the user had touched anything.
  static double? _decode(double? stored) {
    if (stored == null || !stored.isFinite) return null;
    if (stored <= 0 || stored >= 1) return null;
    return stored;
  }
}
