/// The current draft, through the real store.
///
/// `PreferencesWorkflowDraftStore` is exercised over the package's own
/// in-memory platform, exactly as `workflow_settings_store_test.dart`
/// exercises the store beside it — so what the assertions read is what the
/// preferences would actually hold on a phone, keys included.
///
/// The one rule these tests exist for, said once here and asserted repeatedly
/// below: **what is written down is what the user typed**, one draft per
/// workflow, and never a reference to an uploaded file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/graph_vocabulary.dart';
import 'support/workflow_payloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesWorkflowDraftStore store;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = PreferencesWorkflowDraftStore();
  });

  /// Everything in the preferences, read around the store rather than through
  /// it — so an assertion about what was written cannot be satisfied by the
  /// same code that wrote it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  /// A save whose scope is exactly what it is given, which is the ordinary
  /// case. The tests about clearing a value pass their own.
  Future<void> save(
    String workflowId,
    Map<String, Object?> values, {
    bool translatePrompt = true,
  }) => store.save(
    workflowId,
    WorkflowDraft(values: values, translatePrompt: translatePrompt),
    draftableFields: values.keys.toSet(),
  );

  group('what it keeps', () {
    test('a workflow nobody has drafted anything for comes back empty',
        () async {
      final draft = await store.load('example_txt2img');

      expect(draft.values, isEmpty);
      expect(draft.translatePrompt, isTrue);
      expect(draft.isEmpty, isTrue);
    });

    test('prose and every safe value come back as their own type', () async {
      await save('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse in a storm',
        'steps': 44,
        'guidance': 7.5,
        'loop': true,
        'sampler': 'dpmpp_2m',
      });

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': 'a lighthouse in a storm',
        'steps': 44,
        'guidance': 7.5,
        'loop': true,
        'sampler': 'dpmpp_2m',
      });
    });

    test('an emptied prose field comes back empty, not filled again',
        () async {
      await save('example_txt2img', <String, Object?>{'prompt': 'a lighthouse'});
      await save('example_txt2img', <String, Object?>{'prompt': ''});

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': '',
      });
    });

    test('a value it cannot write is left out rather than coerced', () async {
      await save('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse',
        // How a reference to an uploaded file would arrive if the layer above
        // ever stopped filtering them. Written as text it would come back as
        // an id naming a file that is very likely gone.
        'source_image': <String, Object?>{'media_id': 'm-3f9c1a'},
        'nothing': null,
      });

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': 'a lighthouse',
      });
      expect(await preferences(), <String, Object?>{
        'localcanvas.draft.example_txt2img.prompt': 'a lighthouse',
      });
      expect(jsonEncode(await preferences()), isNot(contains('m-3f9c1a')));
    });
  });

  group('one draft per workflow, overwritten', () {
    test('writing twice leaves one draft and no more keys than the first '
        'write', () async {
      const Set<String> scope = <String>{'prompt', 'steps'};

      await store.save(
        'example_txt2img',
        const WorkflowDraft(
          values: <String, Object?>{'prompt': 'first', 'steps': 10},
        ),
        draftableFields: scope,
      );
      final afterOne = await SharedPreferencesAsync().getKeys();

      await store.save(
        'example_txt2img',
        const WorkflowDraft(
          values: <String, Object?>{'prompt': 'second', 'steps': 20},
        ),
        draftableFields: scope,
      );
      await store.save(
        'example_txt2img',
        const WorkflowDraft(
          values: <String, Object?>{'prompt': 'third', 'steps': 30},
        ),
        draftableFields: scope,
      );

      expect(await SharedPreferencesAsync().getKeys(), afterOne);
      expect(afterOne, hasLength(2));
      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': 'third',
        'steps': 30,
      });
      // And nothing anywhere still holds either of the earlier ones: there is
      // no history, no stack and nothing to undo to.
      final written = jsonEncode(await preferences());
      expect(written, isNot(contains('first')));
      expect(written, isNot(contains('second')));
    });

    test('a field the workflow no longer declares survives a save', () async {
      await save('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse',
        'sampler': 'dpmpp_2m',
      });

      await store.save(
        'example_txt2img',
        const WorkflowDraft(values: <String, Object?>{'prompt': 'a harbour'}),
        draftableFields: <String>{'prompt'},
      );

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': 'a harbour',
        'sampler': 'dpmpp_2m',
      });
    });

    test('another workflow is not touched by a save', () async {
      await save('all_types', <String, Object?>{'prompt': 'a harbour'});

      await store.save(
        'example_txt2img',
        const WorkflowDraft(),
        draftableFields: <String>{'prompt', 'steps'},
      );

      expect((await store.load('all_types')).values, <String, Object?>{
        'prompt': 'a harbour',
      });
    });
  });

  group('the key is the workflow and the field, and nothing else', () {
    test('it is namespaced, and names both halves', () async {
      await save('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse',
        'steps': 44,
      });

      expect(await SharedPreferencesAsync().getKeys(), <String>{
        'localcanvas.draft.example_txt2img.prompt',
        'localcanvas.draft.example_txt2img.steps',
      });
    });

    test('what the app already remembers is left alone', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.endpoint': 'http://192.0.2.42:7801',
            'localcanvas.defaults.example_txt2img.steps': 44,
          });
      store = PreferencesWorkflowDraftStore();

      await save('example_txt2img', <String, Object?>{'prompt': 'a lighthouse'});

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': 'a lighthouse',
      });
      final stored = await preferences();
      expect(stored['localcanvas.endpoint'], 'http://192.0.2.42:7801');
      expect(
        stored['localcanvas.defaults.example_txt2img.steps'],
        44,
        reason: 'the two stores answer different questions and share no key',
      );
    });

    test('two workflows declaring the same field do not share a draft',
        () async {
      // The case a single global key would pass: both workflows have a field
      // whose logical id is `prompt`.
      await save('example_txt2img', <String, Object?>{'prompt': 'a lighthouse'});
      await save('all_types', <String, Object?>{'prompt': 'a harbour'});

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'prompt': 'a lighthouse',
      });
      expect((await store.load('all_types')).values, <String, Object?>{
        'prompt': 'a harbour',
      });
    });

    test('a field id with a dot in it round-trips whole', () async {
      await save('example_txt2img', <String, Object?>{
        'sampler.name': 'dpmpp_2m',
        'lora.0.strength': 0.75,
      });

      expect((await store.load('example_txt2img')).values, <String, Object?>{
        'sampler.name': 'dpmpp_2m',
        'lora.0.strength': 0.75,
      });
    });

    test('a dotted field id cannot be read as another workflow', () async {
      await save('a', <String, Object?>{'b.c': 1});
      await save('ab', <String, Object?>{'c': 2});

      expect((await store.load('a')).values, <String, Object?>{'b.c': 1});
      expect((await store.load('ab')).values, <String, Object?>{'c': 2});
    });
  });

  group('the translation override travels beside the values', () {
    test('switched off is remembered, and is not a field', () async {
      await save(
        'example_txt2img',
        <String, Object?>{'prompt': 'a lighthouse'},
        translatePrompt: false,
      );

      final draft = await store.load('example_txt2img');
      expect(draft.translatePrompt, isFalse);
      expect(
        draft.values.keys,
        <String>['prompt'],
        reason: 'the override is not one of the workflow`s own fields',
      );
      expect(await SharedPreferencesAsync().getKeys(), <String>{
        'localcanvas.draft.example_txt2img.prompt',
        'localcanvas.draft.example_txt2img',
      });
    });

    test('switching it back on leaves nothing behind', () async {
      await save('example_txt2img', <String, Object?>{}, translatePrompt: false);
      expect((await store.load('example_txt2img')).translatePrompt, isFalse);

      await save('example_txt2img', <String, Object?>{}, translatePrompt: true);

      expect((await store.load('example_txt2img')).translatePrompt, isTrue);
      expect(
        (await preferences()).containsKey('localcanvas.draft.example_txt2img'),
        isFalse,
        reason: 'the absence of an override is stored as an absence',
      );
    });

    test('it is not shared with another workflow, or with a field', () async {
      await save('example_txt2img', <String, Object?>{}, translatePrompt: false);

      expect((await store.load('all_types')).translatePrompt, isTrue);
      // A workflow whose id starts with another one's must not read the
      // other one's override, and a field must not be able to occupy its key.
      expect(
        (await store.load('example_txt2img_hd')).translatePrompt,
        isTrue,
      );
      expect((await store.load('example_txt2img')).values, isEmpty);
    });

    test('a value of the wrong kind under that key reads as no override',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.draft.example_txt2img': 'off',
          });
      store = PreferencesWorkflowDraftStore();

      expect((await store.load('example_txt2img')).translatePrompt, isTrue);
    });
  });

  group('what a draft may hold is decided by the field type', () {
    List<WorkflowField> fieldsOf(Map<String, Object?> body) =>
        WorkflowDetail.tryFromJson(body)!.inputs;

    WorkflowField byId(Map<String, Object?> body, String id) =>
        fieldsOf(body).firstWhere((field) => field.id == id);

    test('prose and tuning yes, media no', () {
      final body = allTypesDetail();

      expect(isDraftable(byId(body, 'title')), isTrue); // string
      expect(isDraftable(byId(body, 'prompt')), isTrue); // multiline
      expect(isDraftable(byId(body, 'steps')), isTrue); // integer
      expect(isDraftable(byId(body, 'strength')), isTrue); // float
      expect(isDraftable(byId(body, 'loop')), isTrue); // boolean
      expect(isDraftable(byId(body, 'sampler')), isTrue); // select

      expect(isDraftable(byId(body, 'source_image')), isFalse); // image
      expect(isDraftable(byId(body, 'source_clip')), isFalse); // video
      expect(
        isDraftable(byId(oddAdvancedDetail(), 'region')),
        isFalse,
        reason: 'a type this build cannot show has no value to keep',
      );
    });

    test('it is the settings rule plus prose, and not a second rule', () {
      // The reuse, asserted rather than trusted: every field either store
      // admits is admitted by the same call, so a change to `isSafeToKeep`
      // cannot leave a draft behind.
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
        if (isSafeToKeep(field)) {
          expect(isDraftable(field), isTrue, reason: field.id);
          expect(isProse(field), isFalse, reason: field.id);
        }
      }
      // And the fixtures really do contain all three answers, so none of the
      // comparisons above is two identical lists.
      expect(fields.map(isSafeToKeep), contains(true));
      expect(fields.map(isProse), contains(true));
      expect(fields.map(isDraftable), contains(false));
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
        renamed.map(isDraftable).toList(),
        plain.map(isDraftable).toList(),
      );
      expect(plain.map(isDraftable), contains(true));
      expect(plain.map(isDraftable), contains(false));
    });
  });

  group('the store never learns a field id or a node id', () {
    /// Ids a curator plausibly writes. None of them may appear as a string
    /// the store compares against: what a draft may hold is decided by type,
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
const _draftById = <String>{'prompt', 'negative_prompt', 'seed'};
String keyFor(Map<String, Object?> field) =>
    'localcanvas.draft.\${field['node_id']}.\${field['input']}';
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
      expect(graphReadsIn("const prefix = 'localcanvas.draft.';"), isEmpty);
      expect(namesIn("const prefix = 'localcanvas.draft.';"), isEmpty);
    });

    test('workflow_draft_store.dart names no field and reads no graph', () {
      final file = File('lib/workflows/workflow_draft_store.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'cwd is ${Directory.current.path}',
      );
      final source = file.readAsStringSync();

      expect(
        namesIn(source),
        isEmpty,
        reason: 'what a draft holds is decided by type, never by a name',
      );
      expect(
        graphReadsIn(source),
        isEmpty,
        reason: 'the app has never seen a node id and must not learn one',
      );
      // And the file really is the one holding the store, so neither
      // assertion above is about an empty file.
      expect(source, contains('class PreferencesWorkflowDraftStore'));
      expect(source, contains('bool isDraftable'));
    });
  });
}
