/// The one thing that decides `MaterialApp.themeMode`, and the two facts about
/// it the app needs.
///
/// Flutter's own [ChangeNotifier] and nothing else, for the same reason
/// `ConnectionController` is one: there is one of these and one screen.
///
/// **The starting value is [ThemeMode.system], and that is not a placeholder.**
/// The stored answer is read asynchronously, so at the first frame there is no
/// answer yet — and the correct thing to show a device that has said nothing is
/// exactly what the correct thing is to show a device whose answer has not
/// arrived: whatever the phone itself is set to. A first run is therefore never
/// "wrong then corrected"; it is right from frame zero and stays right.
///
/// **[restored] is what makes the other case right too.** A device that *has*
/// said something spends the window between launch and the read completing in
/// system mode, which may be the other brightness. That window is not something
/// this class can shorten, so it publishes it instead, and `app.dart` keeps the
/// startup intro over the app until it closes. Nothing waits on it except the
/// removal of that cover: the connection sequence, the registry and Generate
/// are all indifferent to it (`docs/ui-ux.md` — readiness is never gated).
///
/// **Nothing here throws.** A phone with cleared app data, a preference file
/// that will not open, a platform channel that refuses — every one of them is a
/// device that has said nothing, and a device that has said nothing follows the
/// system. An app that cannot start because it could not find out what colour
/// to be would be a worse answer than any brightness.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';

import 'theme_mode_store.dart';

class ThemeModeController extends ChangeNotifier {
  ThemeModeController({required this.store});

  final ThemeModeStore store;

  ThemeMode _mode = ThemeMode.system;
  bool _restored = false;
  bool _disposed = false;

  /// What `MaterialApp` is handed.
  ThemeMode get mode => _mode;

  /// Whether the stored answer has arrived — by being found, by being absent,
  /// or by the read failing. All three end the window; only the first can
  /// change [mode].
  bool get restored => _restored;

  /// Reads the remembered choice. Called once, at launch, and never awaited by
  /// anything on the path to readiness.
  Future<void> restore() async {
    try {
      final stored = await store.load();
      // A `null` is a device that has said nothing, and [mode] already says
      // what this app does about that. It is not written over with a second
      // copy of the same answer, so that "nothing was stored" and "system was
      // chosen" stay the same outcome by arriving at it the same way.
      if (stored != null) _mode = stored;
    } catch (_) {
      // Deliberately swallowed — see the library comment. The device follows
      // the system, which is where it already is.
    } finally {
      _restored = true;
      _notify();
    }
  }

  /// The user chose [mode]. Applied to the interface first and written down
  /// second: the tap must land on this frame, and the preference file is not
  /// on the path between a finger and a colour.
  Future<void> choose(ThemeMode mode) async {
    if (_mode != mode) {
      _mode = mode;
      _notify();
    }
    try {
      await store.save(mode);
    } catch (_) {
      // A write that could not happen costs the choice its next launch and
      // nothing else. It does not cost the user this one.
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
