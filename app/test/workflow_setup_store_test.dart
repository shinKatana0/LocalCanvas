/// Saved setups, through the real store.
///
/// `PreferencesWorkflowSetupStore` is exercised over the package's own
/// in-memory platform, exactly as the two stores beside it are — so what the
/// assertions read is what the preferences would actually hold on a phone,
/// keys and documents included.
///
/// The rules these tests exist for, said once here and asserted repeatedly
/// below: a setup holds what a draft holds and nothing else, its identity is
/// not its name, and nothing in this file ever deletes a setup that was not
/// asked about by id.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/graph_vocabulary.dart';
import 'support/workflow_payloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesWorkflowSetupStore store;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = PreferencesWorkflowSetupStore();
  });

  /// Everything in the preferences, read around the store rather than through
  /// it — so an assertion about what was written cannot be satisfied by the
  /// same code that wrote it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  /// The keys this store owns, sorted.
  Future<List<String>> setupKeys() async => <String>[
    for (final key in (await preferences()).keys)
      if (key.startsWith('localcanvas.setup.')) key,
  ]..sort();

  /// Every stored document, decoded around the store.
  Future<List<Map<String, Object?>>> documents() async => <Map<String, Object?>>[
    for (final key in await setupKeys())
      jsonDecode((await preferences())[key]! as String) as Map<String, Object?>,
  ];

  group('what it keeps', () {
    test('a workflow nobody has saved anything for comes back empty', () async {
      expect(await store.load('example_txt2img'), isEmpty);
    });

    test('prose and every safe value come back as their own type', () async {
      final made = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{
          'prompt': 'a lighthouse in a storm',
          'steps': 44,
          'guidance': 7.5,
          'loop': true,
          'sampler': 'dpmpp_2m',
        },
      );

      final loaded = await store.load('example_txt2img');
      expect(loaded, hasLength(1));
      expect(loaded.single.id, made.id);
      expect(loaded.single.name, 'Night alley');
      expect(loaded.single.values, <String, Object?>{
        'prompt': 'a lighthouse in a storm',
        'steps': 44,
        'guidance': 7.5,
        'loop': true,
        'sampler': 'dpmpp_2m',
      });
    });

    test('a value it cannot write is left out rather than coerced', () async {
      await store.create(
        workflowId: 'example_img2img',
        name: 'From a photo',
        values: <String, Object?>{
          'prompt': 'a lighthouse',
          // How a reference to an uploaded file would arrive if the layer
          // above ever stopped filtering them. Written as text it would come
          // back as an id naming a file that is very likely gone.
          'source_image': <String, Object?>{'media_id': 'm-3f9c1a'},
          // And how something structural would: a fragment of a graph, which
          // this store must be unable to hold whatever hands it one.
          'binding': <String, Object?>{'3': 'KSampler.text'},
          'nothing': null,
        },
      );

      expect((await store.load('example_img2img')).single.values, <String, Object?>{
        'prompt': 'a lighthouse',
      });
      final written = jsonEncode(await preferences());
      expect(written, isNot(contains('m-3f9c1a')));
      expect(written, isNot(contains('KSampler')));
    });

    test('a document holds three things and no more', () async {
      await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'prompt': 'a lighthouse', 'steps': 44},
      );

      final document = (await documents()).single;
      expect(document.keys.toSet(), <String>{'workflow', 'name', 'values'});
      expect(document['workflow'], 'example_txt2img');
      expect(document['name'], 'Night alley');
      expect(document['values'], <String, Object?>{
        'prompt': 'a lighthouse',
        'steps': 44,
      });
    });

    test('one key per setup, and nothing else in the namespace', () async {
      // The storage shape, asserted: there is no index beside the documents,
      // so there is nothing that can come to disagree with them.
      for (var i = 0; i < 3; i++) {
        await store.create(
          workflowId: 'example_txt2img',
          name: 'Setup $i',
          values: <String, Object?>{'steps': i},
        );
      }

      final keys = await setupKeys();
      expect(keys, hasLength(3));
      for (final key in keys) {
        expect(key, startsWith('localcanvas.setup.'));
        expect(
          (await preferences())[key],
          isA<String>(),
          reason: 'every key in this namespace is one setup`s document',
        );
      }
    });

    test('a field id with a dot in it round-trips whole', () async {
      // `docs/workflow-schema.md` asks only that field ids are unique, so a
      // dotted one is a real curator's workflow rather than a hypothesis —
      // which is why both stores beside this one pin the same case.
      //
      // It survives here because the values live inside one JSON document and
      // nothing in this store ever splits a key on a dot. That is exactly what
      // a later refactor to a key per field
      // (`localcanvas.setup.<id>.<fieldId>`) would change, so the key is
      // asserted **verbatim** below rather than merely counted: such a
      // refactor fails this test whether or not it also mangles the ids.
      final made = await store.create(
        workflowId: 'example_txt2img',
        name: 'Dotted',
        values: <String, Object?>{
          'sampler.name': 'dpmpp_2m',
          'lora.0.strength': 0.75,
          'plain': 3,
        },
      );

      expect(
        (await store.load('example_txt2img')).single.values,
        <String, Object?>{
          'sampler.name': 'dpmpp_2m',
          'lora.0.strength': 0.75,
          'plain': 3,
        },
      );
      expect(await setupKeys(), <String>['localcanvas.setup.${made.id}']);
      expect(
        made.id,
        isNot(contains('.')),
        reason: 'so nothing after the prefix can be read as a workflow and a '
            'field',
      );
      // And the dotted ids are the document's own keys, unflattened and
      // unsplit.
      final values = (await documents()).single['values']! as Map<String, Object?>;
      expect(values.keys, <String>[
        'sampler.name',
        'lora.0.strength',
        'plain',
      ]);
    });

    test('what the app already remembers is left alone', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.endpoint': 'http://192.0.2.42:7801',
            'localcanvas.defaults.example_txt2img.steps': 44,
            'localcanvas.draft.example_txt2img.prompt': 'a harbour',
          });
      store = PreferencesWorkflowSetupStore();

      await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'prompt': 'a lighthouse'},
      );

      final stored = await preferences();
      expect(stored['localcanvas.endpoint'], 'http://192.0.2.42:7801');
      expect(stored['localcanvas.defaults.example_txt2img.steps'], 44);
      expect(stored['localcanvas.draft.example_txt2img.prompt'], 'a harbour');
      expect(
        await setupKeys(),
        hasLength(1),
        reason: 'and none of those three was read as a setup',
      );
    });

    test('something unreadable under a key of ours is skipped, not deleted',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.setup.rubbish': 'not json at all',
            'localcanvas.setup.half': '{"name":"no workflow"}',
          });
      store = PreferencesWorkflowSetupStore();

      expect(await store.load('example_txt2img'), isEmpty);
      expect(await setupKeys(), <String>[
        'localcanvas.setup.half',
        'localcanvas.setup.rubbish',
      ]);
    });
  });

  group('identity is the id, and the id is not the name', () {
    test('renaming keeps the id, the key and the values', () async {
      final made = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'prompt': 'a lighthouse', 'steps': 44},
      );
      final keysBefore = await setupKeys();

      await store.rename(made.id, 'Rainy alley');

      final loaded = (await store.load('example_txt2img')).single;
      expect(loaded.id, made.id);
      expect(loaded.name, 'Rainy alley');
      expect(loaded.values, made.values);
      expect(await setupKeys(), keysBefore);
    });

    test('two setups may share a name and are still two', () async {
      final first = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 10},
      );
      final second = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 20},
      );

      expect(second.id, isNot(first.id));
      final loaded = await store.load('example_txt2img');
      expect(loaded, hasLength(2));
      expect(loaded.map((setup) => setup.name), <String>[
        'Night alley',
        'Night alley',
      ]);
      expect(
        loaded.map((setup) => setup.values['steps']).toSet(),
        <Object?>{10, 20},
      );
    });

    test('saving the same thing twice makes two setups, not one', () async {
      // Nothing here overwrites by name: a setup is created only when the
      // user asks, and asking twice is asking twice.
      await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 10},
      );
      await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 10},
      );

      expect(await store.load('example_txt2img'), hasLength(2));
      expect(await setupKeys(), hasLength(2));
    });

    test('renaming one that is gone does nothing at all', () async {
      final made = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 10},
      );
      await store.delete(made.id);

      await store.rename(made.id, 'Back again');

      expect(await store.load('example_txt2img'), isEmpty);
      expect(await setupKeys(), isEmpty);
    });

    test('the order does not change between two reads', () async {
      for (final name in <String>['zebra', 'Apple', 'apple', 'mango']) {
        await store.create(
          workflowId: 'example_txt2img',
          name: name,
          values: <String, Object?>{'steps': 1},
        );
      }

      final first = await store.load('example_txt2img');
      final again = await PreferencesWorkflowSetupStore().load(
        'example_txt2img',
      );

      expect(first.map((setup) => setup.id), again.map((setup) => setup.id));
      // Case-insensitively, and the two that differ only in case are not
      // asserted against each other: their order is decided by the ids, which
      // are minted and therefore not the test's to predict. What is asserted
      // is that whatever it is, it is the same on the second read.
      expect(first.map((setup) => setup.name.toLowerCase()), <String>[
        'apple',
        'apple',
        'mango',
        'zebra',
      ]);
    });
  });

  group('one workflow`s setups are its own', () {
    test('two workflows declaring the same field do not share a setup',
        () async {
      // The case a store that kept one list would pass: both workflows have a
      // field whose logical id is `prompt`, and both have `steps`.
      await store.create(
        workflowId: 'example_txt2img',
        name: 'Mine',
        values: <String, Object?>{'prompt': 'a lighthouse', 'steps': 44},
      );
      await store.create(
        workflowId: 'all_types',
        name: 'Mine',
        values: <String, Object?>{'prompt': 'a harbour', 'steps': 8},
      );

      final txt2img = await store.load('example_txt2img');
      final allTypes = await store.load('all_types');
      expect(txt2img.single.values['prompt'], 'a lighthouse');
      expect(allTypes.single.values['prompt'], 'a harbour');
      expect(txt2img.single.id, isNot(allTypes.single.id));
    });

    test('a setup whose workflow is not installed is not returned, and not '
        'deleted', () async {
      final dormant = await store.create(
        workflowId: 'gone_away',
        name: 'From the old server',
        values: <String, Object?>{'prompt': 'a lighthouse'},
      );
      await store.create(
        workflowId: 'example_txt2img',
        name: 'Here',
        values: <String, Object?>{'prompt': 'a harbour'},
      );

      // Every read a running app performs, for every workflow it does know
      // about. None of them may take the other one with it.
      expect((await store.load('example_txt2img')).single.name, 'Here');
      expect(await store.load('all_types'), isEmpty);

      final still = await PreferencesWorkflowSetupStore().load('gone_away');
      expect(still.single.id, dormant.id);
      expect(still.single.values['prompt'], 'a lighthouse');
      expect(await setupKeys(), hasLength(2));
    });
  });

  group('delete takes exactly one', () {
    test('the others survive, including one that shares its name', () async {
      final first = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 10},
      );
      final twin = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 20},
      );
      final other = await store.create(
        workflowId: 'all_types',
        name: 'Night alley',
        values: <String, Object?>{'steps': 30},
      );

      await store.delete(first.id);

      final left = await store.load('example_txt2img');
      expect(left.single.id, twin.id);
      expect(left.single.values['steps'], 20);
      expect((await store.load('all_types')).single.id, other.id);
      expect(await setupKeys(), hasLength(2));
    });

    test('deleting one that is already gone is not an error', () async {
      final made = await store.create(
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'steps': 10},
      );

      await store.delete(made.id);
      await store.delete(made.id);

      expect(await store.load('example_txt2img'), isEmpty);
    });
  });

  group('what a setup may hold is the rule a draft follows', () {
    List<WorkflowField> fieldsOf(Map<String, Object?> body) =>
        WorkflowDetail.tryFromJson(body)!.inputs;

    test('it is isDraftable, and not a third rule', () {
      // The reuse, asserted rather than trusted: a setup holds prose plus the
      // tuning `isSafeToKeep` admits, which is exactly what `isDraftable`
      // answers, so a change to either of the first two rules cannot leave a
      // setup behind holding something they no longer allow.
      final fields = <WorkflowField>[
        ...fieldsOf(allTypesDetail()),
        ...fieldsOf(oddAdvancedDetail()),
      ];

      for (final field in fields) {
        expect(
          isDraftable(field),
          isSafeToKeep(field) || isProse(field),
          reason: field.id,
        );
      }
      // And the fixtures really do contain both answers, so the loop above is
      // not two identical empty lists.
      expect(fields.map(isDraftable), contains(true));
      expect(fields.map(isDraftable), contains(false));
    });
  });

  group('the store never learns a field id or a node id', () {
    /// Ids a curator plausibly writes. None of them may appear as a string
    /// the store compares against: what a setup may hold is decided by type,
    /// and a store that recognised a name would keep nothing for the next
    /// user, whose fields are called something else.
    const List<String> vocabulary = <String>[
      'prompt',
      'negative_prompt',
      'seed',
      'noise_seed',
      'steps',
      'cfg',
      'cfg_scale',
      'guidance',
      'denoise',
      'sampler',
      'sampler_name',
      'scheduler',
      'width',
      'height',
      'strength',
      'batch_size',
      'frames',
      'fps',
      'checkpoint',
      'lora',
      'clip_skip',
    ];

    /// Every single-quoted string literal in [source].
    List<String> literalsIn(String source) => <String>[
      for (final match in RegExp(
        "'([^'\\\\\n]*)'",
      ).allMatches(withoutComments(source)))
        match.group(1)!,
    ];

    /// The literals that name a field a curator chose.
    List<String> namesIn(String source) => <String>[
      for (final literal in literalsIn(source))
        if (vocabulary.contains(literal.toLowerCase())) literal,
    ];

    // `graphReadsIn` — anything that would only be there to reach into a
    // graph — is the one scan, in `support/graph_vocabulary.dart` (T-0264).

    test('the graph scan frees only what it names, and refuses every read '
        'shape', () {
      expectGraphScanHoldsItsShapes(graphReadsIn);
    });

    test('the two checks below catch what they are looking for', () {
      // Otherwise the assertions on the real file could pass because the
      // detectors never fire at all.
      const offending = '''
const _setupById = <String>{'prompt', 'negative_prompt', 'seed'};
String keyFor(Map<String, Object?> field) =>
    'localcanvas.setup.\${field['node_id']}.\${field['input']}';
''';
      expect(namesIn(offending), <String>[
        'prompt',
        'negative_prompt',
        'seed',
      ]);
      expect(graphReadsIn(offending), <String>['node']);

      // A comment is not code, and an ordinary key is not a graph.
      expect(namesIn("// a curator writes 'prompt' and 'steps'"), isEmpty);
      expect(graphReadsIn('/// never a node id'), isEmpty);
      expect(graphReadsIn("const prefix = 'localcanvas.setup.';"), isEmpty);
      expect(namesIn("const prefix = 'localcanvas.setup.';"), isEmpty);
    });

    test('workflow_setup_store.dart names no field and reads no graph', () {
      final file = File('lib/workflows/workflow_setup_store.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'cwd is ${Directory.current.path}',
      );
      final source = file.readAsStringSync();

      expect(
        namesIn(source),
        isEmpty,
        reason: 'what a setup holds is decided by type, never by a name',
      );
      expect(
        graphReadsIn(source),
        isEmpty,
        reason: 'the app has never seen a node id and must not learn one',
      );
      // And the file really is the one holding the store, so neither
      // assertion above is about an empty file.
      expect(source, contains('class PreferencesWorkflowSetupStore'));
      expect(source, contains('class WorkflowSetup'));
    });
  });
}
