/// What the app tells the gateway about the language on screen.
///
/// One bare tag — `ru` or `en` — on every request the app makes. No region, no
/// q-value, no list: `docs/api.md`'s companion decision in T-0143 settles the
/// wire as the bare tag on both sides, so neither half has to parse the other's
/// generality.
///
/// **It is read per request, never captured.** A client is composed once, at
/// launch, and the language can change at any moment after that; a client that
/// had been handed the *value* would go on announcing the language the app
/// started in for the rest of the session. So what it is handed is a
/// [LanguageTagSource] — a function it calls each time it builds a header.
///
/// Nothing in the app depends on the gateway doing anything with it. An older
/// gateway ignores an `Accept-Language` it does not read, which is what the
/// header is for.
library;

/// Answers the tag of the language the app is showing, right now.
typedef LanguageTagSource = String Function();

/// What a build with no language of its own says.
///
/// It exists for exactly one caller — a test that is not about language and
/// does not want to say so — and the three real clients require a source
/// rather than falling back to this, so a composition that forgot to wire the
/// language does not compile.
const String kFallbackLanguageTag = 'en';

/// The headers every JSON request in this app carries.
///
/// One function rather than three literals, so the three clients cannot drift
/// into announcing different things.
Map<String, String> jsonHeaders(LanguageTagSource language) =>
    <String, String>{
      'Accept': 'application/json',
      'Accept-Language': language(),
    };
