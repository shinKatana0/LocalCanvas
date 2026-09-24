/// How many automatic attempts a lost connection gets on this device
/// (`docs/recovery.md`, "The count is the person's to choose, inside a fixed
/// bound").
///
/// **Device-local, on purpose, and for the reason the theme is** — this file is
/// shaped like `theme/theme_mode_store.dart` rather than being a second
/// pattern. How patient to be with a network is a fact about the phone and the
/// network it is on, not about the workflows, so it has no business in the
/// portable profile (T-0212).
///
/// **The bound lives here, once.** [kMinReconnectAttempts] and
/// [kMaxReconnectAttempts] are the contract's numbers; the stepper that offers
/// the choice and the session that uses it both read them from this file, so a
/// value outside them cannot be offered, stored or used by any one of the three
/// disagreeing with the others.
///
/// **Nothing said is not the same as a number.** [ReconnectAttemptsStore.load]
/// answers `null` for a device nobody has told anything, and for a stored value
/// this store could not have written. Out-of-range is *not* clamped: a 50 read
/// back as 10 would be a choice nobody made. What the app does about `null` is
/// the session's decision — the default, 3.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// The fewest automatic attempts a person can choose. One attempt is a
/// reconnect that does not retry, which is a legitimate thing to want on a
/// network where waiting is worse than deciding.
const int kMinReconnectAttempts = 1;

/// The most. With the handshake's own timeout and the backoff schedule, ten is
/// a little under a minute in the worst case — long, but finite, and chosen by
/// the person who is waiting. There is no "unlimited" (`docs/recovery.md`).
const int kMaxReconnectAttempts = 10;

/// Whether [count] is a number of attempts the contract allows.
bool isAllowedReconnectAttempts(int count) =>
    count >= kMinReconnectAttempts && count <= kMaxReconnectAttempts;

abstract class ReconnectAttemptsStore {
  /// The count this device remembers, or `null` when it has never been told
  /// anything — including when what is stored is outside the bound.
  Future<int?> load();

  /// Remembers [count]. Refuses one outside the bound rather than writing
  /// down something [load] would then ignore.
  Future<void> save(int count);
}

/// The on-device implementation.
class PreferencesReconnectAttemptsStore implements ReconnectAttemptsStore {
  PreferencesReconnectAttemptsStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  /// Namespaced the way the remembered brightness is, and outside
  /// `localcanvas.defaults.` and `localcanvas.setup.` — which the portable
  /// profile is built from, and which this must therefore never be inside.
  ///
  /// Public so the test that reads the raw preference names the very key the
  /// app writes, rather than a copy that would survive a rename.
  static const String key = 'localcanvas.reconnect_attempts';

  final SharedPreferencesAsync _prefs;

  @override
  Future<int?> load() async {
    final int? stored;
    try {
      stored = await _prefs.getInt(key);
    } catch (_) {
      // Something that is not a number under this key — hand-edited, or
      // written by a build that stored it another way. How that fails depends
      // on the implementation: the in-memory one used by the tests raises a
      // Dart cast error (measured in `reconnect_attempts_test.dart`),
      // while Android's reads with `getLong`, whose `ClassCastException`
      // crosses the channel as something else (read at source, not driven).
      // Either way the answer is the same: nothing usable was said.
      return null;
    }
    if (stored == null || !isAllowedReconnectAttempts(stored)) return null;
    return stored;
  }

  @override
  Future<void> save(int count) {
    if (!isAllowedReconnectAttempts(count)) {
      throw RangeError.range(
        count,
        kMinReconnectAttempts,
        kMaxReconnectAttempts,
        'count',
      );
    }
    return _prefs.setInt(key, count);
  }
}
