/// Which language a person gets, and who decides.
///
/// Two locales ship today — English and Russian — and **nothing here assumes
/// two.** The set is [L.supportedLocales], which the generator builds from
/// whatever `.arb` files are in this directory, so a third locale is a third
/// file and a row in the layout matrix. The one thing that is named by hand is
/// [kFallbackLocale], because "the first entry of a generated list" is a
/// property of file ordering rather than a decision anybody made.
///
/// **The resolution rule is a language match and nothing else.** Flutter's own
/// `basicLocaleListResolution` falls back to matching on *country* when it
/// cannot match a language — so a phone set to Chinese in Russia
/// (`zh_RU`) resolves to `ru`, and its owner is shown an interface in a
/// language they did not ask for and may not read. That is worse than English,
/// which is at least the language this app was written in. [resolveAppLocale]
/// therefore compares `languageCode` and only `languageCode`.
///
/// Region is deliberately ignored on both sides: `ru_UA`, `ru_BY` and `ru_RU`
/// are one interface here, and the app has no per-region text to choose
/// between.
library;

import 'package:flutter/widgets.dart' show Locale;

import 'app_localizations.dart';

/// Every locale this build has an `.arb` file for.
List<Locale> get kSupportedLocales => L.supportedLocales;

/// What a device gets when it asks for a language this build does not have.
///
/// English, because it is the language the app is written and reviewed in, and
/// because a wrong guess at the user's language is worse than the language
/// they at least know the product ships in.
const Locale kFallbackLocale = Locale('en');

/// The bare tag the app puts on `Accept-Language` and stores in preferences.
///
/// A language and no region, per `docs/api.md`'s companion decision in T-0143:
/// `ru` or `en`, never `ru-RU`, never a q-value.
String languageTagOf(Locale locale) => locale.languageCode;

/// The locale the interface is drawn in, given what the device asked for.
///
/// [requested] is the platform's ordered preference list — Android hands out
/// more than one — or the single locale the user chose in the app. The first
/// entry whose **language** this build has wins; if none does, [kFallbackLocale].
///
/// An empty or absent list is a device that has said nothing, and it takes the
/// same answer as a device asking for a language nobody translated.
Locale resolveAppLocale(
  Iterable<Locale>? requested, {
  Iterable<Locale>? supported,
}) {
  final available = (supported ?? kSupportedLocales).toList(growable: false);
  for (final locale in requested ?? const <Locale>[]) {
    for (final candidate in available) {
      if (candidate.languageCode == locale.languageCode) return candidate;
    }
  }
  return kFallbackLocale;
}

/// A language's own name for itself, which is the name to offer it under.
///
/// The same in every locale on purpose: a person who cannot read the interface
/// they are looking at is exactly the person who has to find their language in
/// this list, and "Russian" is no help to them. It is not in the `.arb` files
/// for that reason — there is nothing here to translate.
const Map<String, String> kLocaleAutonyms = <String, String>{
  'en': 'English',
  'ru': 'Русский',
};

/// The name to offer [locale] under, or its uppercase tag for a locale nobody
/// has written a name for — a courtesy that never becomes a gate.
String localeAutonym(Locale locale) =>
    kLocaleAutonyms[locale.languageCode] ?? locale.languageCode.toUpperCase();
