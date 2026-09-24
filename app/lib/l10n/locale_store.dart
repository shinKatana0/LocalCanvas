/// Which language this device shows (T-0142).
///
/// **Device-local, on purpose** — the same decision, for the same reason, as
/// `theme/theme_mode_store.dart`. A language is about the phone the eyes are in
/// front of, not about the workflows, so it is not in the portable profile:
/// it lives in its own preference key here, outside the `localcanvas.defaults.`
/// prefix the profile is built by scanning, and `workflow_profile.dart` never
/// learns that it exists.
///
/// The seam is the one every other store in this app uses: a small abstract
/// class, one on-device implementation over `SharedPreferencesAsync`, and the
/// real one constructed in `main.dart` and nowhere else.
///
/// **Nothing said is not the same as "follow the system".** [LocaleStore.load]
/// answers [LocaleChoice.unset] for a device nobody has told anything, which is
/// what a first run and a phone with cleared app data both are.
/// [LocaleChoice.system] is what a person who *deliberately chose* to follow
/// their phone gets written down as, and it reads back as a choice rather than
/// as silence — exactly as `system` does for the theme.
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_locales.dart';

/// What this device was told about language: a locale, follow the system, or
/// nothing at all.
///
/// A small class rather than a `Locale?`, because `null` already has a meaning
/// in `MaterialApp.locale` ("follow the system") and this type has to be able
/// to say a third thing — that nobody has said anything yet.
class LocaleChoice {
  const LocaleChoice._(this.locale, this.isSet);

  /// A person chose to follow whatever the phone is set to.
  static const LocaleChoice system = LocaleChoice._(null, true);

  /// Nobody has said anything. A first run, or cleared app data.
  static const LocaleChoice unset = LocaleChoice._(null, false);

  /// A person chose this locale.
  const LocaleChoice.of(Locale this.locale) : isSet = true;

  /// The chosen locale, or `null` for [system] and [unset] alike.
  final Locale? locale;

  /// Whether this device has been told anything at all.
  final bool isSet;

  @override
  bool operator ==(Object other) =>
      other is LocaleChoice && other.locale == locale && other.isSet == isSet;

  @override
  int get hashCode => Object.hash(locale, isSet);

  @override
  String toString() =>
      isSet ? 'LocaleChoice(${locale?.languageCode ?? 'system'})' : 'LocaleChoice(unset)';
}

abstract class LocaleStore {
  /// The choice this device remembers, or [LocaleChoice.unset] when it has
  /// never been told anything — including when what is stored is not one of
  /// the words this store writes.
  Future<LocaleChoice> load();

  /// Remembers [choice], `system` alike with the rest.
  Future<void> save(LocaleChoice choice);
}

/// The on-device implementation.
class PreferencesLocaleStore implements LocaleStore {
  PreferencesLocaleStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  /// Namespaced the way the remembered endpoint and the theme are, and
  /// outside `localcanvas.defaults.` — which the profile is built by scanning,
  /// and which this must therefore never be inside.
  static const String _key = 'localcanvas.locale';

  /// The word written down for "follow whatever the phone says".
  ///
  /// It cannot collide with a language tag: ISO 639 codes are two or three
  /// letters and `system` is six.
  static const String _systemWord = 'system';

  final SharedPreferencesAsync _prefs;

  @override
  Future<LocaleChoice> load() async => decodeLocaleChoice(
    await _prefs.getString(_key),
  );

  @override
  Future<void> save(LocaleChoice choice) =>
      _prefs.setString(_key, encodeLocaleChoice(choice));

  /// A tag rather than an index, for the reason the theme store gives about
  /// its own three words: an enum's ordinal is a detail of a declaration order,
  /// and a stored number would re-mean itself the day that order changed.
  static String encodeLocaleChoice(LocaleChoice choice) {
    if (!choice.isSet) return '';
    final locale = choice.locale;
    return locale == null ? _systemWord : locale.languageCode;
  }

  /// Anything else — absent, empty, a language a later build dropped, something
  /// hand-edited — reads as nothing said.
  ///
  /// **A tag is checked against what this build actually has**, rather than
  /// trusted: a device that stored `ja` under a build that shipped Japanese and
  /// then downgraded must not come back holding a locale with no `.arb` file
  /// behind it.
  static LocaleChoice decodeLocaleChoice(
    String? stored, {
    Iterable<Locale>? supported,
  }) {
    if (stored == null) return LocaleChoice.unset;
    final tag = stored.trim();
    if (tag.isEmpty) return LocaleChoice.unset;
    if (tag == _systemWord) return LocaleChoice.system;
    for (final locale in supported ?? kSupportedLocales) {
      if (locale.languageCode == tag) return LocaleChoice.of(locale);
    }
    return LocaleChoice.unset;
  }
}
