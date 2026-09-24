/// The resource bundles themselves, and the rule that nothing may bypass them.
///
/// Two things this file owns, and neither can be checked from inside a widget:
///
/// * **the two `.arb` files say the same things.** A key present in `en` and
///   missing from `ru` is not an error — `gen_l10n` fills the gap with the
///   English string and generation succeeds — so a Russian user meets an
///   English sentence and nothing anywhere goes red. This is the only place
///   that catches it.
/// * **no user-facing sentence is left in Dart.** A literal that never reached
///   an `.arb` file cannot be translated, and the way that happens is not
///   malice: it is one more `Text('…')` added next year by somebody who did
///   not think of it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/l10n/app_locales.dart';

import 'support/l10n.dart';

void main() {
  /// The `.arb` files, by locale tag, read as JSON.
  ///
  /// Anchored on the template: a scan that silently found nothing — a moved
  /// directory, a renamed file — fails here rather than passing empty.
  Map<String, Map<String, Object?>> bundlesOnDisk() {
    final directory = Directory('lib/l10n');
    expect(
      directory.existsSync(),
      isTrue,
      reason: 'cwd ${Directory.current.path}',
    );
    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.arb'))
        .toList();
    expect(
      files.any((f) => f.path.endsWith('app_en.arb')),
      isTrue,
      reason: 'app_en.arb — the template — was not scanned',
    );
    return <String, Map<String, Object?>>{
      for (final file in files)
        (jsonDecode(file.readAsStringSync())
                    as Map<String, Object?>)['@@locale']
                as String:
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    };
  }

  /// The message keys of a bundle: everything that is not an `@`-prefixed
  /// annotation and not the locale marker.
  Set<String> messagesOf(Map<String, Object?> bundle) =>
      bundle.keys.where((k) => !k.startsWith('@')).toSet();

  group('the two bundles say the same things', () {
    test('there is exactly one .arb file per shipped locale, and no other', () {
      final onDisk = bundlesOnDisk().keys.toSet();
      final shipped = kSupportedLocales.map((l) => l.languageCode).toSet();

      expect(onDisk, shipped);
      // And the set is not empty, which both sides being empty would satisfy.
      expect(shipped, isNotEmpty);
      expect(shipped, contains(kFallbackLocale.languageCode));
    });

    test('every key in one is in the other, named rather than counted', () {
      // A count passes a pair of files that translated every key wrongly and
      // also a pair that agree on a total by accident. The names are what
      // matter, and the difference is what a failure has to print.
      final bundles = bundlesOnDisk();
      final template = messagesOf(bundles[kFallbackLocale.languageCode]!);
      expect(template, isNotEmpty);

      bundles.forEach((tag, bundle) {
        final keys = messagesOf(bundle);
        expect(
          keys.difference(template),
          isEmpty,
          reason: '$tag has keys the template does not',
        );
        expect(
          template.difference(keys),
          isEmpty,
          reason: '$tag is missing keys the template has',
        );
      });
    });

    test('no translation was left as a copy of the English', () {
      // Not a rule about every key — "OK", "LocalCanvas" and the two language
      // names are the same word in both — but a rule about the *sentences*.
      // A bundle produced by copying the template and forgetting to translate
      // it passes every other test in this file.
      final bundles = bundlesOnDisk();
      final template = bundles[kFallbackLocale.languageCode]!;
      for (final entry in bundles.entries) {
        if (entry.key == kFallbackLocale.languageCode) continue;
        final shared = <String>[
          for (final key in messagesOf(entry.value))
            if (entry.value[key] == template[key] &&
                RegExp(r'[A-Za-z]{2,}[ ][A-Za-z]{2,}')
                    .hasMatch(template[key]! as String))
              key,
        ];
        expect(
          shared,
          isEmpty,
          reason:
              '${entry.key} repeats the English sentence for: '
              '${shared.join(', ')}',
        );
      }
    });

    test(
      'every placeholder the template uses appears in every translation',
      () {
        // `{workflowName}` dropped from a Russian sentence compiles, ships, and
        // shows a person a sentence with a hole where the name should be.
        final bundles = bundlesOnDisk();
        final template = bundles[kFallbackLocale.languageCode]!;
        final placeholder = RegExp(r'\{(\w+)\}');

        for (final key in messagesOf(template)) {
          final wanted = placeholder
              .allMatches(template[key]! as String)
              .map((m) => m.group(1)!)
              .toSet();
          if (wanted.isEmpty) continue;
          for (final entry in bundles.entries) {
            final translated = placeholder
                .allMatches(entry.value[key]! as String)
                .map((m) => m.group(1)!)
                .toSet();
            expect(
              wanted.difference(translated),
              isEmpty,
              reason:
                  '$key loses ${wanted.difference(translated)} in '
                  '${entry.key}',
            );
          }
        }
      },
    );

    test('the generated class answers for every key of the template', () {
      // The bundles above are files; this is the thing the app actually reads.
      // Without it, a `.arb` pair that agreed perfectly with each other and
      // with nothing the app was regenerated from would pass.
      final template = messagesOf(
        bundlesOnDisk()[kFallbackLocale.languageCode]!,
      );
      final generated = File('lib/l10n/app_localizations.dart')
          .readAsStringSync();
      expect(generated, contains('abstract class L'));

      for (final key in template) {
        expect(
          generated,
          contains(RegExp('\\b$key\\b')),
          reason:
              '$key is in the template and not in the generated class — '
              'run `flutter gen-l10n`',
        );
      }
    });
  });

  group('nothing in lib/ speaks for itself', () {
    /// A literal that reads as a sentence: two or more words of two letters
    /// or more, in any alphabet this app writes in.
    ///
    /// Deliberately not "any literal": a route, a preference key and a MIME
    /// type are strings too, and a rule that flagged them would be turned off
    /// within a week. What it catches is prose — which is the only kind of
    /// string a person reads.
    final RegExp prose = RegExp(r'''(?<!\w)(['"])((?:[^'"\\\n]|\\.)*?)\1''');
    final RegExp twoWords = RegExp(
      r'[A-Za-zА-Яа-яЁё]{2,}[ ][A-Za-zА-Яа-яЁё]{2,}',
    );

    /// **There are no exemptions any more.** There were three, written when
    /// this guard was designed — the wordmark, the multipart envelope, and a
    /// `toString` for a debugger — and not one of them was ever needed: a
    /// wordmark is two literals of one word each, and a header line breaks its
    /// words on `:` and `;` rather than on a space, so none of them is prose by
    /// the rule above in the first place. A whole-file exemption held on a
    /// symbol that happens to be in the file is a hole the size of the file —
    /// a sentence added anywhere in `media_api.dart` was unscanned. They are
    /// gone rather than narrowed, which is the stronger fix and needs no
    /// upkeep.
    ///
    /// **Only the generated bundles are skipped, and by name rather than by
    /// directory.** `lib/l10n/` also holds five hand-written files —
    /// `locale_controller.dart`, `locale_store.dart`, `gateway_errors.dart`,
    /// `accept_language.dart` and `app_locales.dart` — and excluding the
    /// directory left every one of them unscanned, which is exactly the quiet
    /// hole this test exists to refuse.
    bool isGenerated(File file) =>
        file.path.replaceAll(r'\', '/').contains('lib/l10n/app_localizations');

    List<File> librarySources() {
      final root = Directory('lib');
      expect(
        root.existsSync(),
        isTrue,
        reason: 'cwd ${Directory.current.path}',
      );
      return root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !isGenerated(f))
          .toList();
    }

    test('the scan reaches the files it is about', () {
      // The guard below is an absence, and an absence over an empty list is
      // free. Anchored on symbols that must exist: the shell, the control this
      // card added, and the widest file of sentences in the app.
      final files = librarySources();
      expect(files.length, greaterThan(30));

      for (final anchor in <String, String>{
        'connected_shell.dart': 'class ConnectedShell',
        'language_bar.dart': 'class LanguageBar',
        'connection_problem.dart': 'ConnectionNotice',
        // The file a whole-file exemption used to cover entirely.
        'media_api.dart': 'class HttpMediaApi',
        // The hand-written half of `lib/l10n/`, which an exclusion by
        // directory used to skip along with the generated half.
        'locale_controller.dart': 'class LocaleController',
        'gateway_errors.dart': 'gatewayErrorSentence',
        'app_locales.dart': 'resolveAppLocale',
      }.entries) {
        final file = files.singleWhere(
          (f) => f.path.endsWith(anchor.key),
          orElse: () => throw StateError('${anchor.key} was not scanned'),
        );
        expect(file.readAsStringSync(), contains(anchor.value));
      }

      // And the generated bundles really were left out — otherwise the guard
      // would be reporting every translated sentence in the app.
      expect(files.where((f) => f.path.contains('app_localizations')), isEmpty);
    });

    test('the only thing skipped is the generated bundle, and it is skipped by '
        'name', () {
      // The one hole left in the guard, held to its exact size. `lib/l10n/`
      // holds three generated files and five written by hand; excluding the
      // directory took all eight.
      final skipped =
          Directory('lib/l10n')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .where(isGenerated)
              .map((f) => f.uri.pathSegments.last)
              .toList()
            ..sort();
      expect(skipped, <String>[
        'app_localizations.dart',
        'app_localizations_en.dart',
        'app_localizations_ru.dart',
      ]);

      // And the rest of that directory is genuinely in the scan.
      final scanned =
          librarySources()
              .map((f) => f.path.replaceAll(r'\', '/'))
              .where((p) => p.contains('lib/l10n/'))
              .map((p) => p.split('/').last)
              .toList()
            ..sort();
      expect(scanned, <String>[
        'accept_language.dart',
        'app_locales.dart',
        'gateway_errors.dart',
        'locale_controller.dart',
        'locale_store.dart',
      ]);
    });

    test('no prose literal survives outside the .arb files', () {
      final offenders = <String>[];
      for (final file in librarySources()) {
        final path = file.path.replaceAll(r'\', '/');
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final code = line.trimLeft();
          // Comments are prose on purpose, and this app's are long.
          if (code.startsWith('//') || code.startsWith('///')) continue;
          if (code.startsWith('*') || code.startsWith('/*')) continue;
          for (final match in prose.allMatches(line)) {
            final text = match.group(2)!;
            if (!twoWords.hasMatch(text)) continue;
            offenders.add('$path:${i + 1}  "$text"');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these sentences cannot be translated:\n${offenders.join('\n')}',
      );
    });

    test('and the guard would notice one if it were there', () {
      // The assertion above is an absence over a real scan; this is the state
      // of the world that makes it fail, exercised directly. Without it the
      // regex could match nothing at all and the guard would be green for ever.
      final probe = <String>[
        "  Text('Nothing to create with yet'),",
        '  Text("That workflow is no longer available."),',
        "  const Text('Пока нечем создавать'),",
      ];
      for (final line in probe) {
        final matched = prose
            .allMatches(line)
            .map((m) => m.group(2)!)
            .where(twoWords.hasMatch)
            .toList();
        expect(matched, isNotEmpty, reason: 'the guard would miss: $line');
      }
      // And it lets the strings that are not prose through, which is the other
      // half of being a usable guard.
      for (final line in <String>[
        "  headers: const {'Accept': 'application/json'},",
        "  static const String _key = 'localcanvas.theme_mode';",
        "  'image/png' => '.png',",
        "  Key('lc.appearance.system')",
      ]) {
        final matched = prose
            .allMatches(line)
            .map((m) => m.group(2)!)
            .where(twoWords.hasMatch)
            .toList();
        expect(matched, isEmpty, reason: 'the guard would flag: $line');
      }
    });
  });

  group('the sentences a contract pins', () {
    test('the recovery contract is quoted word for word in English', () {
      // `docs/recovery.md` prints these. The English bundle is where they now
      // live, so this is where the wording is held to the contract.
      expect(en.connectionLostTitle, 'Connection lost.');
      expect(en.checkingSurvival, 'Checking whether the generation survived.');
      expect(en.stateUnrecoverable, 'Generation state could not be recovered.');
    });

    test('the privacy sentence is byte for byte what it was', () {
      // `docs/privacy-security.md` makes precision about what leaves the phone
      // a rule rather than a courtesy, so this is pinned rather than described.
      expect(
        en.profileNote,
        'Your saved settings and setups, as one file you can move to another '
        'phone. Nothing about this server, and nothing you have generated, is '
        'in it.',
      );
      // And the Russian makes the same two claims and no others: what is in
      // the file, and the two things that are not. A translation that widened
      // either half would be a privacy defect rather than a typo.
      expect(
        ru.profileNote,
        'Ваши сохранённые настройки и наборы — одним файлом, который можно '
        'перенести на другой телефон. В нём нет ничего об этом сервере и '
        'ничего из того, что вы сгенерировали.',
      );
    });

    test('the quote hint names the character the gateway actually honours, in '
        'both locales', () {
      // The gateway copies text inside straight ASCII double quotes through
      // untranslated and knows nothing about «guillemets». A Russian hint that
      // used the typographic pair would be telling a person to type something
      // that does nothing.
      for (final bundle in bundles.values) {
        expect(bundle.quoteHint, contains('"'));
        expect(bundle.quoteHint, isNot(contains('«')));
        expect(bundle.quoteHint, isNot(contains('“')));
      }
    });
  });

  // ------------------------------------------------------------- T-0151
  group('the committed Dart says what the .arb says, word for word', () {
    // `flutter test` does not regenerate the localisations - measured on T-0142's
    // review, and reproduced on T-0152, where an .arb corrected without
    // `flutter gen-l10n` ran the suite against the old strings. Key parity (above)
    // catches a renamed key; only this catches a changed VALUE.
    //
    // It compares literal WORDS, not code: every run of text an ICU message
    // contains outside its placeholders and selectors must appear in the body the
    // generator wrote for that key. A value edited without regenerating leaves at
    // least one run the generated body does not contain.

    /// The literal runs of an ICU message. No `select` messages exist in these
    /// bundles (checked when this was written), so selectors are the plural
    /// keywords and `=N`.
    List<String> literalRuns(String message) {
      var text = message;
      text = text.replaceAll(RegExp(r'\{\s*\w+\s*,\s*plural\s*,'), '\u0000');
      text = text.replaceAll(
        RegExp(r'(=\d+|zero|one|two|few|many|other)\{'),
        '\u0000',
      );
      text = text.replaceAll(RegExp(r'\{\s*\w+\s*\}'), '\u0000');
      text = text.replaceAll(RegExp(r'[{}]'), '\u0000');
      return text
          .split('\u0000')
          .map((run) => run.trim())
          .where((run) => run.isNotEmpty)
          .toList();
    }

    /// The generated body of [key]: from its declaration to the next member.
    String? bodyOf(String source, String key) {
      final start = RegExp(
        '(get ${RegExp.escape(key)} =>|String ${RegExp.escape(key)}[(])',
      ).firstMatch(source);
      if (start == null) return null;
      final end = source.indexOf('@override', start.end);
      // Raw source, still escaped: unescaping here would turn `didn\'t` into a
      // quote that ends the literal early. `_unescape` runs per literal, after
      // the literal has been found.
      return source.substring(start.start, end < 0 ? source.length : end);
    }

    /// The literal runs of the generated body: the text inside each Dart
    /// string literal, split where a `$name` or `${...}` interpolation sits.
    List<String> generatedRuns(String body) => <String>[
      // Single- or double-quoted: the generator writes a value that contains an
      // apostrophe in double quotes.
      for (final literal in _dartLiteral.allMatches(body))
        ...(literal.group(1) ?? literal.group(2)!)
            .split(_interpolation)
            .map(_unescape)
            .map((run) => run.trim())
            .where((run) => run.isNotEmpty),
    ];

    /// Every key whose generated literal runs are not the .arb's, as a
    /// MULTISET. Containment was not enough: a plural form edited to repeat
    /// another form's word (`байта` -> `байт`) still "appeared" in the body,
    /// and that mutant survived. Sorted lists compare the forms one for one.
    List<String> drift(Map<String, Object?> bundle, String source) => <String>[
      for (final entry in bundle.entries)
        if (!entry.key.startsWith('@') && entry.value is String)
          if (!_sameRuns(
            literalRuns(entry.value! as String),
            generatedRuns(bodyOf(source, entry.key) ?? ''),
          ))
            '${entry.key}: ${literalRuns(entry.value! as String)}',
    ];

    String generated(String tag) =>
        File('lib/l10n/app_localizations_$tag.dart').readAsStringSync();

    for (final tag in <String>['en', 'ru']) {
      test('$tag: every value in the .arb is in the committed Dart', () {
        final bundle = bundlesOnDisk()[tag]!;
        // Anchored: a scan over an empty bundle or a missing file would pass.
        expect(bundle.length, greaterThan(100));
        expect(bodyOf(generated(tag), 'generate'), isNotNull);
        expect(drift(bundle, generated(tag)), isEmpty);
      });
    }

    test('the comparison sees a value changed without regenerating', () {
      // The control: take the real Russian bundle, change one word of one value
      // and one form of one plural, and the check must name both.
      final bundle = Map<String, Object?>.of(bundlesOnDisk()['ru']!)
        ..['generate'] = 'Создать'
        ..['byteCount'] =
            '{count, plural, one{{count} байт} few{{count} байтика} '
            'many{{count} байт} other{{count} байта}}';
      final found = drift(bundle, generated('ru'));
      // In the bundle's own order: byteCount is declared first.
      expect(found.map((line) => line.split(':').first).toList(), <String>[
        'byteCount',
        'generate',
      ]);
    });
  });
}

bool _sameRuns(List<String> a, List<String> b) {
  final left = List<String>.of(a)..sort();
  final right = List<String>.of(b)..sort();
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

/// A Dart string literal in single or double quotes. The generator writes a
/// value containing an apostrophe in double quotes.
final RegExp _dartLiteral = RegExp(
  r"'((?:[^'\\]|\\.)*)'"
  '|'
  r'"((?:[^"\\]|\\.)*)"',
);

/// An unescaped `$name` or `${...}` interpolation inside a literal.
final RegExp _interpolation = RegExp(r'(?<!\\)\$\{[^}]*\}|(?<!\\)\$\w+');

/// The characters a Dart literal escapes, back to themselves.
String _unescape(String text) => text
    .replaceAll(r"\'", "'")
    .replaceAll(r'\"', '"')
    .replaceAll(r'\$', r'$')
    .replaceAll(r'\\', r'\');
