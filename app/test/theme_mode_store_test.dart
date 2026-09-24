/// The real store, over the preferences package's own in-memory platform.
///
/// `theme_choice_test.dart` drives the app over a fake store, which is right:
/// composition happens in `main.dart` and only there. But a fake proves
/// nothing about the one thing this file owns — what is actually written into
/// the preference file, and what comes back out of it. Without this file the
/// encoding is exercised for `dark` alone, incidentally, by two tests in
/// `portable_profile_test.dart`, and a build that wrote `light` down as
/// `system` passes the whole suite.
///
/// Every case is a round trip through a real `SharedPreferencesAsync`: write
/// with the store, read back with a *second* store instance, and read the raw
/// key around the store as well — so an assertion about what is stored cannot
/// be satisfied by the same object that stored it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/theme/theme_mode_store.dart';
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
  const String key = 'localcanvas.theme_mode';

  group('every one of the three survives the trip, on its own', () {
    // The word each mode is written as, spelled out here rather than derived
    // from the store — a table that asked the store what it writes would agree
    // with any answer it gave.
    const Map<ThemeMode, String> written = <ThemeMode, String>{
      ThemeMode.light: 'light',
      ThemeMode.dark: 'dark',
      ThemeMode.system: 'system',
    };

    written.forEach((mode, word) {
      test('$mode is stored as "$word" and reads back as itself', () async {
        await PreferencesThemeModeStore().save(mode);

        // What is on the device, verbatim.
        expect((await preferences())[key], word);
        // And what the next launch — a new store over the same file — sees.
        expect(await PreferencesThemeModeStore().load(), mode);
      });
    });

    test('the three words are three different words', () async {
      // A copy-paste that wrote every mode down as the same string would
      // satisfy each round trip above only if it also read them back the same,
      // which it could not — but this says it directly and cheaply.
      final stored = <String?>[];
      for (final mode in ThemeMode.values) {
        await PreferencesThemeModeStore().save(mode);
        stored.add((await preferences())[key] as String?);
      }
      expect(stored, <String>['system', 'light', 'dark']);
      expect(stored.toSet().length, 3);
    });

    test('a later choice replaces the earlier one rather than joining it',
        () async {
      final store = PreferencesThemeModeStore();
      await store.save(ThemeMode.dark);
      await store.save(ThemeMode.light);

      expect(await store.load(), ThemeMode.light);
      // One key, not a history: nothing else in this app's namespace was
      // written, and nothing was left behind under another name.
      expect(
        (await preferences()).keys.where((k) => k.contains('theme')).toList(),
        <String>[key],
      );
    });
  });

  group('what a device that has said nothing reads as', () {
    test('an empty preference file answers null', () async {
      expect(await PreferencesThemeModeStore().load(), isNull);
      expect((await preferences()).containsKey(key), isFalse);
    });

    test('a word this build does not know answers null, and is not guessed at',
        () async {
      // A hand-edited file, or a word a later build wrote. The docstring
      // promises this reads as nothing said; nothing else in the app can tell
      // the difference, so it is asserted here or nowhere.
      for (final unreadable in <String>['', 'Dark', 'auto', 'midnight', '2']) {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData(<String, Object>{
              key: unreadable,
            });
        expect(
          await PreferencesThemeModeStore().load(),
          isNull,
          reason: '"$unreadable" was read as a choice',
        );
      }
    });

    test('a value of the wrong type throws in the store, and the controller '
        'is what catches it', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{key: 3});

      // `getString` on an int throws inside the package; what matters to the
      // app is that a phone whose preference file holds nonsense still starts,
      // and `ThemeModeController` is where that is caught. This test records
      // which of the two it is, so the controller's catch is not mistaken for
      // dead code.
      await expectLater(
        PreferencesThemeModeStore().load(),
        throwsA(isA<TypeError>()),
      );
    });
  });

  test('it writes under its own key and nowhere near the profile namespace',
      () async {
    // The portable profile is built by scanning `localcanvas.defaults.`. A
    // theme key inside that prefix would be exported with the workflows, which
    // is the one thing `docs/ui-ux.md` says this preference must never be.
    await PreferencesThemeModeStore().save(ThemeMode.dark);

    final keys = (await preferences()).keys.toList();
    expect(keys, <String>[key]);
    expect(
      keys.where((k) => k.startsWith('localcanvas.defaults.')),
      isEmpty,
    );
  });
}
