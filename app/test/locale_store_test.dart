/// The real language store, over the preferences package's own in-memory
/// platform.
///
/// `language_test.dart` drives the app over a fake store, which is right:
/// composition happens in `main.dart` and only there. But a fake proves
/// nothing about the one thing this file owns — what is actually written into
/// the preference file, and what comes back out of it.
///
/// This is `theme_mode_store_test.dart`'s twin, deliberately down to the shape
/// of each case, and it touches `SharedPreferences` for the same reason that
/// one does: the encoding is the thing under test, and a fake store would be
/// agreeing with itself. Nothing above this file does — no app test, no
/// controller test and no widget test in this suite reaches a real preference
/// file for a language.
///
/// Every case is a round trip through a real `SharedPreferencesAsync`: write
/// with the store, read back with a *second* store instance, and read the raw
/// key around the store as well — so an assertion about what is stored cannot
/// be satisfied by the same object that stored it.
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/l10n/app_locales.dart';
import 'package:localcanvas/l10n/locale_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  /// Everything the preferences hold, read around the store rather than
  /// through it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  /// The one key this store is allowed to own.
  const String key = 'localcanvas.locale';

  group('every answer survives the trip, on its own', () {
    // The word each choice is written as, spelled out here rather than derived
    // from the store — a table that asked the store what it writes would agree
    // with any answer it gave.
    final Map<LocaleChoice, String> written = <LocaleChoice, String>{
      LocaleChoice.of(const Locale('en')): 'en',
      LocaleChoice.of(const Locale('ru')): 'ru',
      LocaleChoice.system: 'system',
    };

    written.forEach((choice, word) {
      test('$choice is stored as "$word" and reads back as itself', () async {
        await PreferencesLocaleStore().save(choice);

        // What is on the device, verbatim.
        expect((await preferences())[key], word);
        // And what the next launch — a new store over the same file — sees.
        expect(await PreferencesLocaleStore().load(), choice);
      });
    });

    test('the three words are three different words', () async {
      final stored = <String?>[];
      for (final choice in written.keys) {
        await PreferencesLocaleStore().save(choice);
        stored.add((await preferences())[key] as String?);
      }
      expect(stored, <String>['en', 'ru', 'system']);
      expect(stored.toSet().length, 3);
    });

    test('a later choice replaces the earlier one rather than joining it',
        () async {
      final store = PreferencesLocaleStore();
      await store.save(LocaleChoice.of(const Locale('ru')));
      await store.save(LocaleChoice.of(const Locale('en')));

      expect(await store.load(), LocaleChoice.of(const Locale('en')));
      // One key, not a history.
      expect(
        (await preferences()).keys.where((k) => k.contains('locale')).toList(),
        <String>[key],
      );
    });
  });

  group('what a device that has said nothing reads as', () {
    test('an empty preference file answers unset', () async {
      expect(await PreferencesLocaleStore().load(), LocaleChoice.unset);
      expect((await preferences()).containsKey(key), isFalse);
    });

    test('a tag this build has no .arb file for answers unset, and is not '
        'guessed at', () async {
      // A phone that stored `ja` under a build that shipped Japanese and then
      // downgraded, a hand-edited file, or a word from a later build. The
      // store promises this reads as nothing said, and a locale with no bundle
      // behind it would throw inside `lookupL` on the first frame.
      for (final unreadable in <String>[
        '',
        'ja',
        'EN',
        'ru-RU',
        'System',
        '2',
      ]) {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData(<String, Object>{
              key: unreadable,
            });
        expect(
          await PreferencesLocaleStore().load(),
          LocaleChoice.unset,
          reason: '"$unreadable" was read as a choice',
        );
      }
    });

    test('and a tag this build does have is not refused with them', () async {
      // The other half of the case above: without this, a store that read
      // *everything* as unset would pass it.
      for (final locale in kSupportedLocales) {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData(<String, Object>{
              key: locale.languageCode,
            });
        expect(
          await PreferencesLocaleStore().load(),
          LocaleChoice.of(locale),
          reason: '"${locale.languageCode}" ships and was refused',
        );
      }
    });

    test('a value of the wrong type throws in the store, and the controller '
        'is what catches it', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{key: 3});

      // What matters to the app is that a phone whose preference file holds
      // nonsense still starts, and `LocaleController` is where that is caught.
      // This test records which of the two it is, so the controller's catch is
      // not mistaken for dead code.
      await expectLater(
        PreferencesLocaleStore().load(),
        throwsA(isA<TypeError>()),
      );
    });
  });

  test('it writes under its own key and nowhere near the profile namespace',
      () async {
    // The portable profile is built by scanning `localcanvas.defaults.`. A
    // language key inside that prefix would be exported with the workflows,
    // which is the one thing this preference must never be.
    await PreferencesLocaleStore().save(LocaleChoice.of(const Locale('ru')));

    final keys = (await preferences()).keys.toList();
    expect(keys, <String>[key]);
    expect(keys.where((k) => k.startsWith('localcanvas.defaults.')), isEmpty);
  });

  test('the word for "follow the phone" cannot collide with a language tag',
      () {
    // `system` is six letters and every ISO 639 code is two or three, so the
    // store can tell them apart without a prefix. Asserted rather than
    // assumed, because a locale whose tag was `system` would read back as
    // "follow the phone" and be impossible to choose.
    for (final locale in kSupportedLocales) {
      expect(locale.languageCode, isNot('system'));
      expect(locale.languageCode.length, lessThan(4));
    }
  });
}
