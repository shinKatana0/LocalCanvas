/// A refusal from the gateway, in the language on screen (T-0142).
///
/// `docs/api.md` contracts `code` as "a stable token a client may branch on"
/// and `message` as what a person reads. Until this card the app showed the
/// `message` — the gateway's English — which is how a fully translated app
/// still met a Russian user in English the first time an upload was refused.
///
/// Two properties, and they pull in opposite directions, which is why both are
/// asserted here:
///
/// * a code this app knows is rendered in **this app's** words, verbatim, in
///   every locale;
/// * a code it does not know falls back to the **gateway's** words rather than
///   being swallowed — an untranslated sentence a person can quote to whoever
///   runs the PC is worth more than a generic one they cannot.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/l10n/gateway_errors.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/workflows/workflow_api.dart';

import 'support/l10n.dart';

void main() {
  /// Every code, and the sentence each locale owes it. Written out rather than
  /// read off the bundle: a table that asked `L` what it says would agree with
  /// whatever it said, including a Russian bundle that had quietly kept the
  /// English.
  const Map<String, Map<String, String>> sentences =
      <String, Map<String, String>>{
        'unsupported_media_type': <String, String>{
          'en': 'This server does not accept that kind of file.',
          'ru': 'Этот сервер не принимает файлы такого вида.',
        },
        // T-0127: a HEIC or HEIF photo, refused at upload by its bytes. The
        // sentence says what to do, which the generic one above cannot.
        'unsupported_image_heic': <String, String>{
          'en': 'That photo is in HEIC format, which LocalCanvas cannot use '
              'yet. Choose a JPEG or PNG, or turn off high-efficiency (HEIC) '
              'photos in the camera settings.',
          'ru': 'Это фото в формате HEIC, который LocalCanvas пока не '
              'поддерживает. Выберите JPEG или PNG либо отключите в настройках '
              'камеры высокоэффективный формат фото (HEIC).',
        },
        'empty_upload': <String, String>{
          'en': 'That file is empty.',
          'ru': 'Этот файл пуст.',
        },
        'invalid_filename': <String, String>{
          'en': "That file's name cannot be used. Rename it, then choose it "
              'again.',
          'ru': 'Имя этого файла использовать нельзя. Переименуйте его и '
              'выберите снова.',
        },
        'file_too_large': <String, String>{
          'en': 'That file is larger than this server accepts. Choose a '
              'smaller one.',
          'ru': 'Этот файл больше, чем принимает сервер. Выберите файл '
              'поменьше.',
        },
        'media_kind_mismatch': <String, String>{
          'en': 'That file is not the kind this field asks for.',
          'ru': 'Этот файл не того вида, какой нужен этому полю.',
        },
        'workflow_not_found': <String, String>{
          'en': 'That workflow is no longer on this server.',
          'ru': 'Этого воркфлоу больше нет на этом сервере.',
        },
      };

  group('the seven codes this app has its own sentence for', () {
    test('the set under test is the set the app ships, neither more nor less',
        () {
      // Without this, a code added to the app and forgotten here would be
      // untested, and a code removed from the app would leave a row above
      // asserting about nothing.
      expect(sentences.keys.toSet(), kTranslatedGatewayErrorCodes.toSet());
      expect(kTranslatedGatewayErrorCodes.length, 7);
    });

    test('every one of them is a code the contract actually defines', () {
      // The silent failure this catches is a typo. A misspelled token never
      // matches anything the gateway sends, so the app falls back to English
      // for ever and every other test in this file still passes — they ask
      // the app about a string this file also holds.
      final contract = File('../docs/api.md');
      expect(
        contract.existsSync(),
        isTrue,
        reason: 'cwd ${Directory.current.path}',
      );
      final text = contract.readAsStringSync();
      // Anchored: the contract really is the one that enumerates them.
      expect(text, contains('a stable token a client may branch on'));

      for (final code in kTranslatedGatewayErrorCodes) {
        expect(
          text,
          contains('`$code`'),
          reason: '$code is not a code `docs/api.md` defines',
        );
      }
    });

    sentences.forEach((code, perLocale) {
      perLocale.forEach((tag, sentence) {
        test('$code reads as this app\'s own sentence in $tag', () {
          expect(gatewayErrorSentence(bundles[tag]!, code), sentence);
        });
      });

      test('$code reads differently in the two locales', () {
        // A pair of rows above could both be satisfied by a Russian bundle
        // that had never been translated, if somebody also copied the English
        // into this table. This says the two are not the same string.
        expect(
          gatewayErrorSentence(ru, code),
          isNot(gatewayErrorSentence(en, code)),
        );
      });
    });

    test('a refusal shows the sentence and never the gateway\'s own words',
        () {
      // The whole point, at the level a person meets it: the failure holds
      // the server's English and does not show it.
      const serverWords = 'That image is too large to send. The limit is 20 MB.';
      for (final entry in bundles.entries) {
        final failure = const MediaFailure.refused(
          code: 'file_too_large',
          serverMessage: serverWords,
        );
        expect(failure.serverMessage, serverWords);
        expect(
          failure.message(entry.value),
          sentences['file_too_large']![entry.key],
        );
        expect(failure.message(entry.value), isNot(contains('20 MB')));
      }
    });
  });

  group('a code this app does not know', () {
    const unknown = 'comfy_rejected_workflow';

    test('is not one of the seven, so this group is about the other path', () {
      expect(kTranslatedGatewayErrorCodes, isNot(contains(unknown)));
    });

    test('falls back to the gateway\'s own words, in every locale', () {
      const words = 'ComfyUI refused the submitted graph.';
      for (final bundle in bundles.values) {
        expect(gatewayErrorSentence(bundle, unknown), isNull);
        expect(
          refusalSentence(bundle, code: unknown, serverMessage: words),
          words,
        );
      }
    });

    test('and so does a refusal that carried no code at all', () {
      const words = 'The server said something this app has never seen.';
      for (final bundle in bundles.values) {
        expect(refusalSentence(bundle, serverMessage: words), words);
        expect(
          refusalSentence(bundle, code: '', serverMessage: words),
          words,
        );
      }
    });

    test('a refusal with neither a known code nor any words says so rather '
        'than showing nothing', () {
      expect(refusalSentence(en), 'The server did not say why.');
      expect(refusalSentence(ru), 'Сервер не сказал почему.');
      expect(refusalSentence(en, code: 'nonsense', serverMessage: '   '),
          'The server did not say why.');
    });
  });

  group('the three failures that carry a refusal all render it the same way',
      () {
    // One rule, three classes. A copy that drifted would show a person the
    // gateway's English on one screen and this app's sentence on another.
    test('media, jobs and the registry agree, in both locales', () {
      for (final entry in bundles.entries) {
        final bundle = entry.value;
        final expected = sentences['workflow_not_found']![entry.key];

        expect(
          const MediaFailure.refused(
            code: 'workflow_not_found',
            serverMessage: 'gone',
          ).message(bundle),
          expected,
        );
        expect(
          const JobFailure.refused(
            code: 'workflow_not_found',
            serverMessage: 'gone',
          ).message(bundle),
          expected,
        );
        expect(
          const WorkflowsFailure.refused(
            code: 'workflow_not_found',
            serverMessage: 'gone',
          ).message(bundle),
          expected,
        );
      }
    });

    test('and each keeps its own title, because they are not the same event',
        () {
      const code = 'file_too_large';
      expect(
        const MediaFailure.refused(code: code).title(en),
        'The server could not take that file.',
      );
      expect(
        const JobFailure.refused(code: code).title(en),
        'The server could not do that.',
      );
      expect(
        const MediaFailure.refused(code: code).title(ru),
        'Сервер не смог принять этот файл.',
      );
      expect(
        const JobFailure.refused(code: code).title(ru),
        'Сервер не смог это сделать.',
      );
    });
  });

  group('a code this app knows is still recognised the way the wire sends it',
      () {
    test('surrounding whitespace does not turn a known code into an unknown '
        'one', () {
      expect(
        gatewayErrorSentence(en, '  file_too_large  '),
        sentences['file_too_large']!['en'],
      );
    });

    test('and a code that merely contains one is not mistaken for it', () {
      // `startsWith`/`contains` would be the easy wrong implementation, and it
      // would render `file_too_large_for_preview` as this app's sentence about
      // a different thing.
      expect(gatewayErrorSentence(en, 'file_too_large_for_preview'), isNull);
      expect(gatewayErrorSentence(en, 'not_workflow_not_found'), isNull);
    });
  });
}
