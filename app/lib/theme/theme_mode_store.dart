/// Which of the two brightnesses this device shows (`docs/ui-ux.md`, "Which of
/// the two a person gets").
///
/// **Device-local, on purpose.** It is not in the portable profile: that
/// document is described to the user as their saved settings and setups, and a
/// screen preference is neither. It belongs to the phone the eyes are in front
/// of, not to the workflows — so it lives in its own preference key here, and
/// `workflow_profile.dart` never learns that it exists.
///
/// The seam is the same one `connection/endpoint_store.dart` and the three
/// `workflows/*_store.dart` files use: a small abstract class, one on-device
/// implementation over `SharedPreferencesAsync`, and the real one constructed
/// in `main.dart` and nowhere else.
///
/// **Nothing said is not the same as "system".** [ThemeModeStore.load] answers
/// `null` for a device nobody has told anything, which is what a first run and
/// a phone with cleared app data both are. `ThemeMode.system` is what the app
/// does about that, and it is the app's decision rather than this file's —
/// which is why a person who deliberately chose *follow the system* is written
/// down like the other two, and reads back as a choice rather than as silence.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

abstract class ThemeModeStore {
  /// The choice this device remembers, or `null` when it has never been told
  /// anything — including when what is stored is not one of the three words
  /// this store writes.
  Future<ThemeMode?> load();

  /// Remembers [mode], all three of them alike.
  Future<void> save(ThemeMode mode);
}

/// The on-device implementation.
class PreferencesThemeModeStore implements ThemeModeStore {
  PreferencesThemeModeStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  /// Namespaced the way the remembered endpoint is, and outside
  /// `localcanvas.defaults.` — which the profile is built by scanning, and
  /// which this must therefore never be inside.
  static const String _key = 'localcanvas.theme_mode';

  final SharedPreferencesAsync _prefs;

  @override
  Future<ThemeMode?> load() async => _decode(await _prefs.getString(_key));

  @override
  Future<void> save(ThemeMode mode) => _prefs.setString(_key, _encode(mode));

  /// A word rather than an index: an enum's ordinal is a detail of the SDK's
  /// declaration order, and a stored number would re-mean itself the day that
  /// order changed.
  ///
  /// Exhaustive, so a fourth [ThemeMode] would fail to compile here rather
  /// than be written down as something unreadable.
  static String _encode(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'system',
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
  };

  /// Anything else — absent, empty, a word from a future build, something
  /// hand-edited — reads as nothing said.
  static ThemeMode? _decode(String? stored) => switch (stored) {
    'system' => ThemeMode.system,
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => null,
  };
}
