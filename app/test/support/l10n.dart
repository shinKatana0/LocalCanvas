/// The two bundles, for tests that are not widget tests.
///
/// A widget reads `L.of(context)`; a plain unit test has no context, and
/// `lookupL` is the generated entry point that answers without one. Nothing
/// here is a fake: these are the very objects the app draws from, so a
/// sentence asserted here is the sentence a person sees.
library;

import 'package:flutter/widgets.dart' show Locale, LocalizationsDelegate;
import 'package:localcanvas/l10n/app_locales.dart';
import 'package:localcanvas/l10n/app_localizations.dart';

/// The English bundle.
final L en = lookupL(const Locale('en'));

/// The Russian bundle.
final L ru = lookupL(const Locale('ru'));

/// Both, by tag, for a test that wants to say the same thing about each.
final Map<String, L> bundles = <String, L>{'en': en, 'ru': ru};

/// What a test's own `MaterialApp` has to carry to draw a screen of this app.
///
/// The app's real delegates and the app's real locale set, not a stand-in:
/// `L.of(context)` is a null check on one of these having run, so a test that
/// left them out would fail with a null rather than tell anyone what is
/// missing — and a test that supplied a *different* set would be looking at
/// strings the app does not ship.
final List<LocalizationsDelegate<dynamic>> testDelegates =
    L.localizationsDelegates;

final List<Locale> testLocales = kSupportedLocales;
