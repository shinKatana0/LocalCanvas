/// The one thing that decides which language the interface is drawn in, and
/// the three facts about it the app needs.
///
/// Flutter's own [ChangeNotifier] and nothing else, for the same reason
/// `ThemeModeController` is one: there is one of these and one screen.
///
/// **The starting choice is "follow the system", and that is not a
/// placeholder.** The stored answer is read asynchronously, so at the first
/// frame there is no answer yet — and the correct thing to show a device that
/// has said nothing is exactly what the correct thing is to show a device whose
/// answer has not arrived: the language the phone itself is set to, if this
/// build has it. A first run is therefore never "wrong then corrected".
///
/// **[restored] is what makes the other case right too.** A device that *has*
/// said something spends the window between launch and the read completing
/// following its system language, which may be the other one. That window is
/// not something this class can shorten, so it publishes it instead, and
/// `app.dart` keeps the startup intro over the app until it closes — the same
/// cover, and the same bound, the stored brightness already had. Nothing else
/// waits on it: the connection sequence, the registry and Generate are all
/// indifferent to it (`docs/ui-ux.md` — readiness is never gated).
///
/// **Nothing here throws.** A phone with cleared app data, a preference file
/// that will not open, a platform channel that refuses — every one of them is a
/// device that has said nothing, and a device that has said nothing follows the
/// system. An app that could not start because it did not know what language to
/// be would be a worse answer than any language.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;

import 'app_locales.dart';
import 'locale_store.dart';

class LocaleController extends ChangeNotifier {
  LocaleController({required this.store, List<Locale>? systemLocales})
    : _systemLocales = List<Locale>.unmodifiable(
        systemLocales ?? const <Locale>[],
      );

  final LocaleStore store;

  LocaleChoice _choice = LocaleChoice.system;
  List<Locale> _systemLocales;
  bool _restored = false;
  bool _disposed = false;

  /// What this device was told, including "follow the system" and including
  /// "nothing yet".
  LocaleChoice get choice => _choice;

  /// Whether a person has picked a language, as opposed to following the
  /// phone. Drawn by the control as the chip that is on.
  Locale? get chosenLocale => _choice.locale;

  /// The platform's own ordered language preferences, kept up to date by
  /// `app.dart` from `didChangeLocales`.
  ///
  /// It lives here rather than being read off `PlatformDispatcher.instance` at
  /// the point of use, because that instance is not the one a widget test
  /// overrides — code that reached for it directly would be code no test could
  /// put a Russian phone in front of.
  List<Locale> get systemLocales => _systemLocales;

  set systemLocales(List<Locale> locales) {
    if (listEquals(_systemLocales, locales)) return;
    final before = locale;
    _systemLocales = List<Locale>.unmodifiable(locales);
    if (locale != before) _notify();
  }

  /// The locale the interface is actually drawn in: the choice if there is one,
  /// otherwise the best match for the phone, otherwise English.
  Locale get locale {
    final chosen = _choice.locale;
    if (chosen != null) return resolveAppLocale(<Locale>[chosen]);
    return resolveAppLocale(_systemLocales);
  }

  /// The bare tag that goes on `Accept-Language` — `ru` or `en`.
  String get languageTag => languageTagOf(locale);

  /// Whether the stored answer has arrived — by being found, by being absent,
  /// or by the read failing. All three end the window; only the first can
  /// change [locale].
  bool get restored => _restored;

  /// Reads the remembered choice. Called once, at launch, and never awaited by
  /// anything on the path to readiness.
  Future<void> restore() async {
    try {
      final stored = await store.load();
      // An unset store is a device that has said nothing, and [_choice]
      // already says what this app does about that. It is not written over
      // with a second copy of the same answer, so that "nothing was stored"
      // and "system was chosen" stay the same outcome by arriving at it the
      // same way.
      if (stored.isSet) _choice = stored;
    } catch (_) {
      // Deliberately swallowed — see the library comment. The device follows
      // the system, which is where it already is.
    } finally {
      _restored = true;
      _notify();
    }
  }

  /// The user chose [choice]. Applied to the interface first and written down
  /// second: the tap must land on this frame, and the preference file is not on
  /// the path between a finger and a language.
  Future<void> choose(LocaleChoice choice) async {
    if (_choice != choice) {
      _choice = choice;
      _notify();
    }
    try {
      await store.save(choice);
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
