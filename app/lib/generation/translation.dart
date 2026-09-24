/// What the gateway did to this submission's text (`docs/api.md`, "Prompt
/// translation — a gateway stage, before binding").
///
/// Two texts exist once a submission has been answered, and the distinction is
/// the whole contract:
///
/// * the **original** is what the user typed. It is canonical — it is what the
///   app displays and what Generate Again resubmits;
/// * the **effective** text is what was bound into the graph for that one run.
///
/// Which is why the effective text arrives here and stops here. This is a
/// record *about* a generation, held beside it, and nothing in the app writes
/// it back into a form controller: a prompt field re-seeded from [effective]
/// would destroy the user's own words on their next keystroke, and the app
/// would have no copy of them left.
///
/// The report is also the reason no language list lives in a widget. The one
/// place this app knows anything about a language at all is
/// [kLanguageLabels] below, and a code that is not in it still renders — as
/// its own uppercase — so a gateway configured for a language this build never
/// heard of shows `XX → EN` rather than a blank chip.
///
/// [TranslationCapability] is the same subject read from the other end: what
/// the server said it *can* do, before anything was submitted. It lives here
/// for the same reason — it speaks in language codes, and this is the file
/// that knows what one looks like to a person. Its silent default is
/// [TranslationCapability.unknown], because a gateway older than the feature
/// says nothing, and silence is not the same statement as "off".
library;

import 'package:flutter/foundation.dart';

/// The short labels the indicator uses.
///
/// **The app's only knowledge of any language.** It maps a code to the label
/// shown to a person; anything absent falls back to the uppercased code, so
/// this map is a courtesy and never a gate. Nothing branches on an entry, and
/// there is no code path that behaves differently for one language than for
/// another.
const Map<String, String> kLanguageLabels = <String, String>{
  'en': 'EN',
  'ru': 'RU',
  'ja': 'JA',
  'ko': 'KO',
  'zh': 'ZH',
  'zh-hans': 'ZH',
  'zh-hant': 'ZH',
  'de': 'DE',
  'es': 'ES',
  'fr': 'FR',
  'it': 'IT',
  'pt': 'PT',
  'pt-br': 'PT',
};

/// The label for one language code — the map above, or the code's own
/// uppercase for anything it does not carry.
String languageLabel(String code) {
  final trimmed = code.trim();
  return kLanguageLabels[trimmed.toLowerCase()] ?? trimmed.toUpperCase();
}

/// What `capabilities.translation` said about the server (`docs/api.md`).
///
/// Four situations, and the app owes each a different sentence — or, twice
/// over, none at all.
enum TranslationSupport {
  /// The gateway said nothing about translation. **Older than the feature,
  /// not "off"**: reading silence as `false` would state as a fact something
  /// the server never said, so the app behaves exactly as it did before the
  /// key existed and shows nothing.
  unknown,

  /// The stage is switched off on that PC. Prompts go as typed, there is
  /// nothing to override, and the form says nothing — a permanent line about
  /// an optional stage nobody switched on is noise, not honesty.
  off,

  /// Switched on, and the backend is not installed on that PC. **A prompt in
  /// another language does not go through untranslated here — it fails**
  /// (`translation_unavailable`, `docs/api.md`), which is why this state gets
  /// a sentence of its own and the override that avoids it.
  notInstalled,

  /// Switched on, the backend is there, and no language is installed. The same
  /// outcome by a different missing step, and a different command fixes it.
  noLanguages,

  /// Switched on and able to translate.
  active,
}

/// One `{source, target}` pair the gateway really has.
@immutable
class TranslationPair {
  const TranslationPair({required this.source, required this.target});

  final String source;
  final String target;

  /// `RU → EN`, in the same notation the after-the-fact indicator uses.
  String get label => '${languageLabel(source)} → ${languageLabel(target)}';

  static TranslationPair? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final source = json['source'];
    final target = json['target'];
    if (source is! String || target is! String) return null;
    if (source.trim().isEmpty || target.trim().isEmpty) return null;
    return TranslationPair(source: source.trim(), target: target.trim());
  }

  @override
  bool operator ==(Object other) =>
      other is TranslationPair &&
      other.source == source &&
      other.target == target;

  @override
  int get hashCode => Object.hash(source, target);

  @override
  String toString() => '$source>$target';
}

/// What the gateway can translate, known before anything is submitted.
///
/// It is a description of *that PC*, not of this build, which is why it is
/// read on every handshake rather than remembered. The app draws exactly one
/// quiet line from it and offers exactly one control, and never in the two
/// states where neither would mean anything.
@immutable
class TranslationCapability {
  const TranslationCapability({
    required this.support,
    this.pairs = const <TranslationPair>[],
  });

  /// The gateway is older than the feature. **The default**, so a code path
  /// that forgets to pass a capability shows nothing rather than claiming the
  /// stage is off.
  static const TranslationCapability unknown = TranslationCapability(
    support: TranslationSupport.unknown,
  );

  final TranslationSupport support;

  /// The pairs the gateway said it has, in its own order. Empty in every
  /// state but [TranslationSupport.active].
  final List<TranslationPair> pairs;

  /// Whether a prompt submitted now would be offered to the translator.
  bool get translates => support == TranslationSupport.active;

  /// Whether the stage will be **attempted** on that PC.
  ///
  /// Not the same question as [translates]: a PC that is switched on and has
  /// nothing installed still attempts it, and the attempt is what fails.
  bool get isEnabled => translates || isSwitchedOnButUnusable;

  /// Whether the app may offer the per-submission override.
  ///
  /// Wherever switching it off changes the outcome, which is wherever the
  /// stage is attempted at all. Where it translates, off means "send my text
  /// as typed"; where it is switched on and cannot, off is the difference
  /// between a refused submission and a generation. Where the stage is off or
  /// unknown it changes nothing, and a control that changes nothing is the
  /// kind of confident lie this project keeps refusing.
  bool get canOverride => isEnabled;

  /// Whether the PC is set up to translate but cannot — so a prompt in another
  /// language fails rather than going through as typed.
  bool get isSwitchedOnButUnusable =>
      support == TranslationSupport.notInstalled ||
      support == TranslationSupport.noLanguages;

  /// The languages this gateway translates *from*, as short labels.
  List<String> get sourceLabels =>
      <String>[for (final pair in pairs) languageLabel(pair.source)];

  /// The language it translates *into*, when every pair agrees on one — which
  /// is every real configuration, since the target is a single setting.
  String? get targetLabel {
    if (pairs.isEmpty) return null;
    final targets = <String>{for (final pair in pairs) pair.target};
    return targets.length == 1 ? languageLabel(targets.first) : null;
  }

  /// Reads the block. Anything unreadable is [unknown], never `off`.
  static TranslationCapability fromJson(Object? json) {
    if (json is! Map) return unknown;
    if (json['enabled'] != true) return const TranslationCapability(support: TranslationSupport.off);
    final raw = json['pairs'];
    final pairs = <TranslationPair>[];
    if (raw is List) {
      for (final entry in raw) {
        final pair = TranslationPair.tryFromJson(entry);
        if (pair != null) pairs.add(pair);
      }
    }
    if (pairs.isNotEmpty) {
      return TranslationCapability(
        support: TranslationSupport.active,
        pairs: List<TranslationPair>.unmodifiable(pairs),
      );
    }
    // Switched on and translating nothing. Which of the two missing steps it
    // is decides which sentence the person at the PC is given.
    return TranslationCapability(
      support: json['installed'] == true
          ? TranslationSupport.noLanguages
          : TranslationSupport.notInstalled,
    );
  }
}

/// What happened to one submitted field's text.
///
/// Built only from a `fields` entry the gateway sent. [applied] is that
/// entry's own answer: the report carries one entry per translatable field the
/// submission supplied, **whether or not its text was changed**, so a field
/// that was looked at and left alone is a fact the gateway states rather than
/// one the app infers.
@immutable
class FieldTranslation {
  const FieldTranslation({
    required this.fieldId,
    required this.original,
    required this.effective,
    required this.applied,
    this.source,
    this.target,
  });

  /// The field `id` this is about — the same id the form and the input map
  /// use.
  final String fieldId;

  /// What the user typed. Canonical.
  final String original;

  /// What was bound into the graph for that run. Shown on request, stored
  /// nowhere as the user's prompt.
  final String effective;

  /// Whether this field's own text was translated.
  final bool applied;

  /// The language the gateway detected, and the one it translated into.
  /// `source` is `null` when nothing was translated (`docs/api.md`).
  final String? source;
  final String? target;

  /// `RU → EN`, or `null` when the pair is not both there.
  ///
  /// A pair with a half missing is not rendered rather than rendered half
  /// empty: the indicator's entire content is the two languages, and one of
  /// them alone says nothing a person can act on.
  String? get pairLabel {
    final from = source;
    final to = target;
    if (from == null || from.trim().isEmpty) return null;
    if (to == null || to.trim().isEmpty) return null;
    return '${languageLabel(from)} → ${languageLabel(to)}';
  }

  static FieldTranslation? tryFromJson(String fieldId, Object? json) {
    if (json is! Map) return null;
    final original = json['original'];
    final effective = json['effective'];
    if (original is! String || effective is! String) return null;
    final translation = json['translation'];
    final applied = translation is Map && translation['applied'] == true;
    final source = translation is Map ? translation['source'] : null;
    final target = translation is Map ? translation['target'] : null;
    return FieldTranslation(
      fieldId: fieldId,
      original: original,
      effective: effective,
      applied: applied,
      source: source is String && source.trim().isNotEmpty ? source : null,
      target: target is String && target.trim().isNotEmpty ? target : null,
    );
  }
}

/// The `translation` block of a `POST /api/v1/jobs` answer.
///
/// **Absence is the ordinary case.** `applied: false` with an empty `fields`
/// is what a gateway with no translation backend answers, which is most of
/// them — so a missing or unreadable block is [none] and nothing appears on
/// screen, never a degraded state or a warning.
@immutable
class TranslationReport {
  const TranslationReport({
    this.applied = false,
    this.fields = const <String, FieldTranslation>{},
  });

  /// Nothing was translated, and nothing is drawn.
  static const TranslationReport none = TranslationReport();

  /// Whether the stage changed anything at all in this submission.
  final bool applied;

  /// One entry per translatable field the submission supplied, by field id.
  final Map<String, FieldTranslation> fields;

  /// The translation to *show* for one field.
  ///
  /// Only a field whose own text was actually translated has one: a report
  /// that ran and changed nothing draws no indicator, and neither does an
  /// untouched field on a submission where some other field was translated.
  FieldTranslation? appliedFor(String fieldId) {
    if (!applied) return null;
    final entry = fields[fieldId];
    if (entry == null || !entry.applied) return null;
    if (entry.pairLabel == null) return null;
    return entry;
  }

  /// Reads the block. Never `null`: anything unreadable is [none], because
  /// "the gateway said nothing about translation" and "the gateway said it did
  /// nothing" are the same thing to the interface.
  static TranslationReport fromJson(Object? json) {
    if (json is! Map) return none;
    final rawFields = json['fields'];
    final fields = <String, FieldTranslation>{};
    if (rawFields is Map) {
      for (final entry in rawFields.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final field = FieldTranslation.tryFromJson(key, entry.value);
        if (field != null) fields[key] = field;
      }
    }
    return TranslationReport(
      applied: json['applied'] == true,
      fields: Map<String, FieldTranslation>.unmodifiable(fields),
    );
  }
}
