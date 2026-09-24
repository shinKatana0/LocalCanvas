/// My defaults, through the real store.
///
/// `PreferencesWorkflowSettingsStore` is exercised over the package's own
/// in-memory platform, so what the assertions read is what the preferences
/// would actually hold on a phone — the keys included, because a key is the
/// half of this feature that has to survive a workflow being re-numbered,
/// re-ordered and re-published.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/graph_vocabulary.dart';
import 'support/workflow_payloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesWorkflowSettingsStore store;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = PreferencesWorkflowSettingsStore();
  });

  /// Everything in the preferences, read around the store rather than through
  /// it — so an assertion about what was written cannot be satisfied by the
  /// same code that wrote it.
  Future<Map<String, Object?>> preferences() => SharedPreferencesAsync().getAll();

  /// A save whose declared set is exactly what it is given, which is the
  /// ordinary case. The tests about clearing a value pass their own.
  Future<void> save(String workflowId, Map<String, Object?> values) =>
      store.save(workflowId, values, declaredFields: values.keys.toSet());

  group('what it keeps', () {
    test('a workflow nobody has saved anything for comes back empty', () async {
      expect(await store.load('example_txt2img'), isEmpty);
    });

    test('every kind of safe value comes back as its own type', () async {
      await save('example_txt2img', <String, Object?>{
        'steps': 44,
        'guidance': 7.5,
        'loop': true,
        'sampler': 'dpmpp_2m',
      });

      expect(await store.load('example_txt2img'), <String, Object?>{
        'steps': 44,
        'guidance': 7.5,
        'loop': true,
        'sampler': 'dpmpp_2m',
      });
    });

    test('saving again replaces the value, field by field', () async {
      await save('example_txt2img', <String, Object?>{'steps': 44});
      await save('example_txt2img', <String, Object?>{'guidance': 9.0});
      await save('example_txt2img', <String, Object?>{'steps': 12});

      expect(await store.load('example_txt2img'), <String, Object?>{
        'steps': 12,
        'guidance': 9.0,
      });
    });

    test('a value it cannot write is left out rather than coerced', () async {
      await save('example_txt2img', <String, Object?>{
        'steps': 20,
        // Neither of these is a scalar the preferences can hold. Written as
        // text they would read back as a number nobody could generate with.
        'nothing': null,
        'structured': <String, Object?>{'media_id': 'm-3f9c1a'},
      });

      expect(await store.load('example_txt2img'), <String, Object?>{
        'steps': 20,
      });
      expect(await preferences(), <String, Object?>{
        'localcanvas.defaults.example_txt2img.steps': 20,
      });
    });
  });

  group('a save replaces what was there', () {
    test('a setting the user cleared loses its stored default', () async {
      await save('example_txt2img', <String, Object?>{
        'steps': 44,
        'guidance': 7.5,
      });

      // The next save is made from a form where `steps` was cleared: the
      // workflow still declares it, so it is in the declared set with no
      // value of its own.
      await store.save(
        'example_txt2img',
        <String, Object?>{'guidance': 7.5},
        declaredFields: <String>{'steps', 'guidance'},
      );

      expect(await store.load('example_txt2img'), <String, Object?>{
        'guidance': 7.5,
      });
      expect(
        (await preferences()).containsKey(
          'localcanvas.defaults.example_txt2img.steps',
        ),
        isFalse,
        reason: 'a user has to be able to unset one of their own defaults',
      );
    });

    test('a field the workflow no longer declares survives a save', () async {
      await save('example_txt2img', <String, Object?>{
        'steps': 44,
        'sampler': 'dpmpp_2m',
      });

      // The workflow was republished without `sampler`, so it is outside the
      // declared set — and outside what a save is allowed to touch.
      await store.save(
        'example_txt2img',
        <String, Object?>{'steps': 12},
        declaredFields: <String>{'steps'},
      );

      expect(await store.load('example_txt2img'), <String, Object?>{
        'steps': 12,
        'sampler': 'dpmpp_2m',
      });
    });

    test('another workflow is not touched by a save', () async {
      await save('all_types', <String, Object?>{'steps': 8});

      await store.save(
        'example_txt2img',
        <String, Object?>{},
        declaredFields: <String>{'steps', 'sampler'},
      );

      expect(await store.load('all_types'), <String, Object?>{'steps': 8});
    });
  });

  group('the key is the workflow and the field, and nothing else', () {
    test('it is namespaced, and names both halves', () async {
      await save('example_txt2img', <String, Object?>{
        'steps': 44,
        'sampler': 'euler',
      });

      expect(await SharedPreferencesAsync().getKeys(), <String>{
        'localcanvas.defaults.example_txt2img.steps',
        'localcanvas.defaults.example_txt2img.sampler',
      });
    });

    test('the endpoint the app already remembers is left alone', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.endpoint': 'http://192.0.2.42:7801',
          });
      store = PreferencesWorkflowSettingsStore();

      await save('example_txt2img', <String, Object?>{'steps': 44});

      expect(await store.load('example_txt2img'), <String, Object?>{
        'steps': 44,
      });
      expect(
        (await preferences())['localcanvas.endpoint'],
        'http://192.0.2.42:7801',
        reason: 'a namespace nobody else writes into is only half the rule; '
            'reading must stay inside it too',
      );
    });

    test('two workflows declaring the same field do not share a value',
        () async {
      // The case a single global key would pass: both workflows have a field
      // whose logical id is `steps`.
      await save('example_txt2img', <String, Object?>{'steps': 44});
      await save('all_types', <String, Object?>{'steps': 8});

      expect(await store.load('example_txt2img'), <String, Object?>{
        'steps': 44,
      });
      expect(await store.load('all_types'), <String, Object?>{'steps': 8});
    });

    test('a workflow nothing was saved for stays empty beside one that was',
        () async {
      await save('example_txt2img', <String, Object?>{'steps': 44});

      expect(await store.load('example_video'), isEmpty);
    });

    test('a field id with a dot in it round-trips whole', () async {
      // Nothing in this project constrains a field id's charset — the schema
      // asks only that it is unique within its workflow — so a curator may
      // write one with a dot, and splitting a key on dots would cut it in
      // half or lose it.
      await save('example_txt2img', <String, Object?>{
        'sampler.name': 'dpmpp_2m',
        'lora.0.strength': 0.75,
      });

      expect(await store.load('example_txt2img'), <String, Object?>{
        'sampler.name': 'dpmpp_2m',
        'lora.0.strength': 0.75,
      });
      expect(await SharedPreferencesAsync().getKeys(), <String>{
        'localcanvas.defaults.example_txt2img.sampler.name',
        'localcanvas.defaults.example_txt2img.lora.0.strength',
      });
    });

    test('a dotted field id cannot be read as another workflow', () async {
      // `a` + `b.c` and `ab` + `c` are two different defaults, and the two
      // keys they build must not be one key.
      await save('a', <String, Object?>{'b.c': 1});
      await save('ab', <String, Object?>{'c': 2});

      expect(await store.load('a'), <String, Object?>{'b.c': 1});
      expect(await store.load('ab'), <String, Object?>{'c': 2});
    });
  });

  group('what may be kept is decided by the field type', () {
    List<WorkflowField> fieldsOf(Map<String, Object?> body) =>
        WorkflowDetail.tryFromJson(body)!.inputs;

    WorkflowField byId(Map<String, Object?> body, String id) =>
        fieldsOf(body).firstWhere((field) => field.id == id);

    test('tuning yes, prose and media no', () {
      final body = allTypesDetail();

      expect(isSafeToKeep(byId(body, 'steps')), isTrue); // integer
      expect(isSafeToKeep(byId(body, 'strength')), isTrue); // float
      expect(isSafeToKeep(byId(body, 'loop')), isTrue); // boolean
      expect(isSafeToKeep(byId(body, 'sampler')), isTrue); // select

      expect(isSafeToKeep(byId(body, 'title')), isFalse); // string
      expect(isSafeToKeep(byId(body, 'prompt')), isFalse); // multiline
      expect(isSafeToKeep(byId(body, 'source_image')), isFalse); // image
      expect(isSafeToKeep(byId(body, 'source_clip')), isFalse); // video
      expect(
        isSafeToKeep(byId(oddAdvancedDetail(), 'region')),
        isFalse,
        reason: 'a type this build cannot show has no value to keep',
      );
    });

    test('the same field under another name is decided identically', () {
      // The rule cannot be a list of names, so renaming every field in a
      // workflow may not change a single answer.
      final plain = fieldsOf(allTypesDetail());
      final renamed = fieldsOf(<String, Object?>{
        ...allTypesDetail(),
        'inputs': <Object?>[
          for (final field in allTypesDetail()['inputs']! as List<Object?>)
            <String, Object?>{
              ...field! as Map<String, Object?>,
              'id': 'x_${(field as Map<String, Object?>)['id']}',
            },
        ],
      });

      expect(
        renamed.map(isSafeToKeep).toList(),
        plain.map(isSafeToKeep).toList(),
      );
      // And the fixture really does contain both answers, so the comparison
      // is not two identical lists of `false`.
      expect(plain.map(isSafeToKeep), contains(true));
      expect(plain.map(isSafeToKeep), contains(false));
    });
  });

  group('the store never learns a field id or a node id', () {
    /// Ids a curator plausibly writes. None of them may appear as a string
    /// the store compares against: the rule about what may be kept is about
    /// types, and a store that recognised a name would keep nothing for the
    /// next user, whose fields are called something else.
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
const _keepById = <String>{'steps', 'guidance', 'sampler'};
String keyFor(Map<String, Object?> field) =>
    'localcanvas.defaults.\${field['node_id']}.\${field['input']}';
''';
      expect(namesIn(offending), <String>['steps', 'guidance', 'sampler']);
      expect(graphReadsIn(offending), <String>['node']);

      // A comment is not code, and an ordinary key is not a graph.
      expect(namesIn("// a curator writes 'steps' and 'guidance'"), isEmpty);
      expect(graphReadsIn('/// never a node id'), isEmpty);
      expect(graphReadsIn("const prefix = 'localcanvas.defaults.';"), isEmpty);
      expect(namesIn("const prefix = 'localcanvas.defaults.';"), isEmpty);
    });

    test('workflow_settings_store.dart names no field and reads no graph', () {
      final file = File('lib/workflows/workflow_settings_store.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'cwd is ${Directory.current.path}',
      );
      final source = file.readAsStringSync();

      expect(
        namesIn(source),
        isEmpty,
        reason: 'what may be kept is decided by type, never by a name',
      );
      expect(
        graphReadsIn(source),
        isEmpty,
        reason: 'the app has never seen a node id and must not learn one',
      );
      // And the file really is the one holding the store, so neither
      // assertion above is about an empty file.
      expect(source, contains('class PreferencesWorkflowSettingsStore'));
      expect(source, contains('bool isSafeToKeep'));
    });
  });
}
