/// The real store, over the preferences package's own in-memory platform.
///
/// `remembered_workflow_test.dart` drives the launch, which is where the
/// behaviour a user sees lives. This file owns the two things a controller test
/// cannot see: what is actually written into the preference file, and what a
/// *second* store instance over that same file reads back — which is what a
/// relaunch is.
///
/// Every case is a round trip through a real `SharedPreferencesAsync`, and the
/// raw key is read around the store as well as through it, so an assertion
/// about what is stored cannot be satisfied by the same object that stored it.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/workflows/selected_workflow_store.dart';
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

  /// The one key this store is allowed to own. Spelled out here rather than
  /// read off the class: a constant asked for its own value agrees with any
  /// answer it gives.
  const String key = 'localcanvas.selected_workflow';

  final studio = Endpoint.tryParse('192.0.2.42')!;
  final laptop = Endpoint.tryParse('192.0.2.77')!;

  group('the pair survives the trip', () {
    test('what is written is the server and the workflow, verbatim', () async {
      await PreferencesSelectedWorkflowStore().remember(
        studio,
        'example_txt2img',
      );

      // What is on the device, as text, exactly. Written out here rather than
      // re-encoded by the test, so a change to the shape of the stored value
      // has to be made deliberately in two places.
      expect(
        (await preferences())[key],
        '{"endpoint":"http://192.0.2.42:7801","workflow":"example_txt2img"}',
      );
      // And what the next launch — a new store over the same file — sees.
      expect(
        await PreferencesSelectedWorkflowStore().load(studio),
        'example_txt2img',
      );
    });

    test('it is one value and not two, so nothing can be half-written',
        () async {
      // The reason this store holds a JSON object instead of a key each: a
      // process that died between two writes would leave one server's address
      // beside another server's workflow id, which reads back as a valid
      // memory and is a lie.
      await PreferencesSelectedWorkflowStore().remember(studio, 'a_workflow');

      expect((await preferences()).keys.toList(), <String>[key]);
    });

    test('a later choice replaces the earlier one rather than joining it',
        () async {
      final store = PreferencesSelectedWorkflowStore();
      await store.remember(studio, 'example_txt2img');
      await store.remember(studio, 'example_img2img');

      expect(await store.load(studio), 'example_img2img');
      // One slot, not a history.
      expect((await preferences()).keys.toList(), <String>[key]);
    });

    test('forget leaves the file without the key at all', () async {
      final store = PreferencesSelectedWorkflowStore();
      await store.remember(studio, 'example_txt2img');
      // The positive control: it really was there to be removed.
      expect((await preferences()).containsKey(key), isTrue);

      await store.forget();

      expect((await preferences()).containsKey(key), isFalse);
      expect(await PreferencesSelectedWorkflowStore().load(studio), isNull);
    });
  });

  group('it belongs to the server it was made against', () {
    test('another gateway reads nothing, and the same one still reads it',
        () async {
      await PreferencesSelectedWorkflowStore().remember(
        studio,
        'example_txt2img',
      );

      // The memory is ignored here.
      expect(await PreferencesSelectedWorkflowStore().load(laptop), isNull);
      // And this is what makes that a fact about the server rather than about
      // an empty file: the very same file, asked about the server the
      // selection was made on, answers.
      expect(
        await PreferencesSelectedWorkflowStore().load(studio),
        'example_txt2img',
      );
      // Reading for the wrong server is a read, not a wipe: what was stored is
      // still stored, so glancing at another gateway does not cost the user
      // their place on this one.
      expect((await preferences()).containsKey(key), isTrue);
    });

    test('a second gateway on the same host is a different server', () async {
      // The sharp case, and the one a host-only comparison would get wrong:
      // two gateways on one PC, which `docs/connection.md` has no rule
      // against. A workflow id from the first means nothing on the second.
      final first = Endpoint.tryParse('192.0.2.42:7801')!;
      final second = Endpoint.tryParse('192.0.2.42:7802')!;
      await PreferencesSelectedWorkflowStore().remember(first, 'upscale');

      expect(await PreferencesSelectedWorkflowStore().load(second), isNull);
      expect(await PreferencesSelectedWorkflowStore().load(first), 'upscale');
    });

    test('a gateway behind a path prefix is not the one at the root', () async {
      // `docs/transport-boundary.md` §3: the prefix is part of the endpoint.
      final mounted = Endpoint.tryParse('http://192.0.2.42:7801/canvas')!;
      final root = Endpoint.tryParse('http://192.0.2.42:7801')!;
      await PreferencesSelectedWorkflowStore().remember(mounted, 'upscale');

      expect(await PreferencesSelectedWorkflowStore().load(root), isNull);
      expect(await PreferencesSelectedWorkflowStore().load(mounted), 'upscale');
    });

    test('the same server typed two ways is the same server', () async {
      // Deciding that is `Endpoint`'s job and is not restated in the store, so
      // this is the test that says the store asks it rather than comparing
      // text of its own.
      //
      // Which is why the memory is seeded around the store and not through
      // `remember` (T-0203): `remember` writes `endpoint.canonical`, so a
      // memory written that way can only ever be compared with a canonical
      // form of itself, and a store comparing strings passes. A memory in the
      // shape a person types — no scheme, no port — is what only an
      // endpoint comparison can match.
      const String typed = '192.0.2.42';
      await SharedPreferencesAsync().setString(
        key,
        '{"endpoint":"$typed","workflow":"example_txt2img"}',
      );
      // The seed really is not the text either side would compare against,
      // so the answer below cannot come from two equal strings.
      expect(typed, isNot(studio.canonical));

      expect(
        await PreferencesSelectedWorkflowStore().load(studio),
        'example_txt2img',
      );
      expect(
        await PreferencesSelectedWorkflowStore().load(
          Endpoint.tryParse('http://192.0.2.42:7801/')!,
        ),
        'example_txt2img',
      );
      // And a server that is not this one is still not, however it is typed.
      expect(await PreferencesSelectedWorkflowStore().load(laptop), isNull);
    });
  });

  group('what a device that has said nothing reads as', () {
    test('an empty preference file answers null', () async {
      expect(await PreferencesSelectedWorkflowStore().load(studio), isNull);
      expect((await preferences()).containsKey(key), isFalse);
    });

    test('contents this build cannot read answer null, and are not guessed at',
        () async {
      // A hand-edited file, a half-written object, a value a later build put
      // there. The store is the only thing that can tell these apart from a
      // memory, so it is asserted here or nowhere.
      const List<String> unreadable = <String>[
        '',
        'not json at all',
        '[]',
        '"example_txt2img"',
        '{}',
        // An endpoint with no workflow beside it, and the reverse.
        '{"endpoint":"http://192.0.2.42:7801"}',
        '{"workflow":"example_txt2img"}',
        // An address this client cannot express, so no server it could belong
        // to (`connection/endpoint.dart`).
        '{"endpoint":"ftp://192.0.2.42","workflow":"example_txt2img"}',
        '{"endpoint":"","workflow":"example_txt2img"}',
        // A workflow named by nothing.
        '{"endpoint":"http://192.0.2.42:7801","workflow":""}',
        // Both present, neither a string.
        '{"endpoint":7801,"workflow":"example_txt2img"}',
        '{"endpoint":"http://192.0.2.42:7801","workflow":12}',
      ];

      for (final stored in unreadable) {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData(<String, Object>{
              key: stored,
            });
        expect(
          await PreferencesSelectedWorkflowStore().load(studio),
          isNull,
          reason: '"$stored" was read as a remembered workflow',
        );
      }
    });

    test('a value of the wrong type answers null rather than throwing',
        () async {
      // `getString` on an int throws inside the package. The remembered
      // brightness lets that escape and is caught by its controller
      // (`theme_mode_store_test.dart`); there is no controller of one's own
      // here, so this store answers instead — a phone whose preference file
      // holds nonsense must still launch.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{key: 3});

      expect(await PreferencesSelectedWorkflowStore().load(studio), isNull);
    });

    test('the positive control: that same list of shapes, written properly, '
        'does read back', () async {
      // Without this the test above would pass for a store whose `load`
      // returned null unconditionally.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            key: jsonEncode(<String, Object?>{
              'endpoint': studio.canonical,
              'workflow': 'example_txt2img',
            }),
          });

      expect(
        await PreferencesSelectedWorkflowStore().load(studio),
        'example_txt2img',
      );
    });
  });

  test('it writes under its own key and nowhere near either namespace the '
      'profile is built by scanning', () async {
    // The portable profile is assembled from `localcanvas.defaults.` and
    // `localcanvas.setup.` (`workflows/profile_exchange.dart`). A key inside
    // either prefix would leave the phone with the workflows, and which
    // workflow this phone had open is not part of who the user is.
    await PreferencesSelectedWorkflowStore().remember(studio, 'example_video');

    final keys = (await preferences()).keys.toList();
    expect(keys, <String>[key]);
    expect(keys.where((k) => k.startsWith('localcanvas.defaults.')), isEmpty);
    expect(keys.where((k) => k.startsWith('localcanvas.setup.')), isEmpty);
    expect(keys.where((k) => k.startsWith('localcanvas.draft.')), isEmpty);
  });
}
