/// My defaults, laid over the curator's: the whole path from the store to the
/// form the shell shows.
///
/// The store here is the real `PreferencesWorkflowSettingsStore` over the
/// package's own in-memory platform, and the workflows arrive as the wire
/// bodies in `support/workflow_payloads.dart`. Nothing in between is faked, so
/// what these tests assert about "the next time the app is opened" is what the
/// app would do.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Endpoint.tryParse('192.0.2.42')!;
  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
  });

  /// Everything the preferences hold, read around the app rather than through
  /// it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  /// A registry, connected, with the real store behind it. Calling this twice
  /// in one test is the app being opened twice on the same device: the
  /// controllers are new, the preferences are not.
  Future<WorkflowsController> opened(
    List<Map<String, Object?>> details, {
    bool keepsDefaults = true,
    bool withMedia = false,
  }) async {
    final controller = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(registryOf(details)),
        details: <String, WorkflowDetail>{
          for (final body in details)
            body['id']! as String: WorkflowDetail.tryFromJson(body)!,
        },
      ),
      settings: keepsDefaults ? PreferencesWorkflowSettingsStore() : null,
      mediaPicker: withMedia ? picker : null,
      mediaApi: withMedia ? uploads : null,
    );
    addTearDown(controller.dispose);
    await controller.load(endpoint);
    return controller;
  }

  /// The chosen workflow's form.
  Future<WorkflowFormController> formOf(
    WorkflowsController controller,
    String workflowId,
  ) async {
    await controller.select(workflowId);
    return controller.form!;
  }

  /// The same body with one field's declaration changed — a curator editing
  /// their workflow between two launches of the app.
  Map<String, Object?> withField(
    Map<String, Object?> body,
    String fieldId,
    Map<String, Object?> changes,
  ) => <String, Object?>{
    ...body,
    'inputs': <Object?>[
      for (final field in body['inputs']! as List<Object?>)
        if ((field! as Map<String, Object?>)['id'] == fieldId)
          <String, Object?>{...field as Map<String, Object?>, ...changes}
        else
          field,
    ],
  };

  /// The same body with one field removed.
  Map<String, Object?> withoutField(
    Map<String, Object?> body,
    String fieldId,
  ) => <String, Object?>{
    ...body,
    'inputs': <Object?>[
      for (final field in body['inputs']! as List<Object?>)
        if ((field! as Map<String, Object?>)['id'] != fieldId) field,
    ],
  };

  group('the layering', () {
    test('a saved default is applied the next time the form is built',
        () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img'))
        ..setEntry('steps', '44')
        ..setEntry('sampler', 'dpmpp_2m')
        ..setEntry('guidance', '9.5');
      await first.saveMyDefaults();

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.text('steps'), '44');
      expect(form.entry('sampler'), 'dpmpp_2m');
      expect(form.text('guidance'), '9.5');
      expect(form.hasMyDefaults, isTrue);
      // And what was never touched is still the curator's.
      expect(form.text('width'), '768');
    });

    test('a workflow with nothing saved is the form it has always been',
        () async {
      // With the endpoint the app has already remembered sitting in the same
      // preferences, because on a device it always is.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.endpoint': 'http://192.0.2.42:7801',
            'localcanvas.endpoint.display_name': 'Studio PC',
          });
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');

      // Against the form as it is built with no store at all — the code path
      // that existed before there was one.
      final asBefore = WorkflowFormController(
        WorkflowDetail.tryFromJson(txt2imgDetail())!,
      );
      addTearDown(asBefore.dispose);
      for (final field in asBefore.detail.inputs) {
        expect(form.entry(field.id), asBefore.entry(field.id), reason: field.id);
      }
      // And against the registry's own words, so two paths broken the same
      // way could not agree their way past this.
      expect(form.text('width'), '768');
      expect(form.text('steps'), '20');
      expect(form.text('guidance'), '6');
      expect(form.entry('sampler'), 'euler');
      expect(form.text('prompt'), '');
      expect(form.hasMyDefaults, isFalse);
      expect(
        (await preferences()).keys,
        <String>{'localcanvas.endpoint', 'localcanvas.endpoint.display_name'},
        reason: 'nothing was saved, so nothing was written',
      );
    });

    test('saving is scoped to the workflow it was saved from', () async {
      // Both workflows declare a field whose logical id is `steps`: the case
      // a key that was not per workflow would pass.
      final registry = <Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ];
      final first = await opened(registry);
      (await formOf(first, 'example_txt2img')).setEntry('steps', '44');
      await first.saveMyDefaults();

      final next = await opened(registry);
      expect((await formOf(next, 'example_txt2img')).text('steps'), '44');
      expect(
        (await formOf(next, 'all_types')).text('steps'),
        '20',
        reason: 'the other workflow declared 20 and nobody saved over it',
      );
    });
  });

  group('nothing personal is written', () {
    test('a filled prompt and a chosen picture reach the form and not the store',
        () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final app = await opened(
        <Map<String, Object?>>[img2imgDetail()],
        withMedia: true,
      );
      final form = await formOf(app, 'example_img2img');
      form
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('output_name', 'Seascapes')
        ..setEntry('strength', '0.8');
      await form.media('source_image')!.choose();
      expect(form.media('source_image')!.phase, MediaPhase.ready);
      final mediaId = form.media('source_image')!.mediaId!;

      await app.saveMyDefaults();

      // What the store actually wrote, read straight from the preferences.
      expect(await preferences(), <String, Object?>{
        'localcanvas.defaults.example_img2img.strength': 0.8,
      });
      final written = jsonEncode(await preferences());
      expect(written, isNot(contains('a lighthouse in a storm')));
      expect(written, isNot(contains('Seascapes')));
      expect(written, isNot(contains(mediaId)));
      expect(written, isNot(contains('IMG_0142')));
      // The values themselves are untouched by having been saved around.
      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.media('source_image')!.phase, MediaPhase.ready);
    });

    test('a prompt someone wrote into the preferences never reaches a field',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.defaults.example_txt2img.prompt': 'a lighthouse',
            'localcanvas.defaults.example_txt2img.negative_prompt': 'blurry',
            'localcanvas.defaults.example_txt2img.steps': 44,
          });

      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');

      expect(form.text('prompt'), '');
      expect(form.text('negative_prompt'), '');
      expect(form.text('steps'), '44');
    });
  });

  group('a workflow whose graph was re-numbered', () {
    /// The same registry view, from a definition whose nodes carry [firstNode]
    /// onwards.
    ///
    /// The gateway never sends a node id (`docs/workflow-schema.md`), so these
    /// bodies carry them the way a curator's own definition does and let the
    /// parser drop them. What has to survive the re-numbering is the key, and
    /// the key is built from what the app can actually see.
    Map<String, Object?> boundTo(Map<String, Object?> body, int firstNode) {
      var node = firstNode;
      return <String, Object?>{
        ...body,
        'inputs': <Object?>[
          for (final field in body['inputs']! as List<Object?>)
            <String, Object?>{
              ...field! as Map<String, Object?>,
              'bind': <String, Object?>{
                'node': '${node++}',
                'input': 'value',
              },
            },
        ],
      };
    }

    test('keeps every override', () async {
      final before = boundTo(txt2imgDetail(), 76);
      final after = boundTo(txt2imgDetail(), 512);
      expect(
        jsonEncode(before),
        isNot(jsonEncode(after)),
        reason: 'the two fixtures must really differ, or this proves nothing',
      );

      final first = await opened(<Map<String, Object?>>[before]);
      (await formOf(first, 'example_txt2img'))
        ..setEntry('steps', '44')
        ..setEntry('sampler', 'dpmpp_2m');
      await first.saveMyDefaults();

      final keys = await SharedPreferencesAsync().getKeys();
      expect(keys, <String>{
        'localcanvas.defaults.example_txt2img.steps',
        'localcanvas.defaults.example_txt2img.sampler',
        'localcanvas.defaults.example_txt2img.width',
        'localcanvas.defaults.example_txt2img.height',
        'localcanvas.defaults.example_txt2img.guidance',
        'localcanvas.defaults.example_txt2img.seed',
      });

      final next = await opened(<Map<String, Object?>>[after]);
      final form = await formOf(next, 'example_txt2img');
      expect(form.text('steps'), '44');
      expect(form.entry('sampler'), 'dpmpp_2m');
    });
  });

  group('a workflow whose fields changed', () {
    /// Saves `steps: 44` and `sampler: dpmpp_2m` under the txt2img id, from
    /// the workflow as it was published then.
    Future<void> saveUnderTxt2img() async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(app, 'example_txt2img'))
        ..setEntry('steps', '44')
        ..setEntry('sampler', 'dpmpp_2m');
      await app.saveMyDefaults();
    }

    test('a field the workflow no longer declares is ignored, not resurrected',
        () async {
      await saveUnderTxt2img();

      final next = await opened(<Map<String, Object?>>[
        withoutField(txt2imgDetail(), 'sampler'),
      ]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.text('steps'), '44');
      expect(form.entry('sampler'), isNull);
      expect(form.validate().inputs.containsKey('sampler'), isFalse);
      // Kept in the store: the field may come back with the next sync.
      expect(
        (await preferences())['localcanvas.defaults.example_txt2img.sampler'],
        'dpmpp_2m',
      );
    });

    test('a field that was not there when it was saved takes the workflow '
        'default', () async {
      await saveUnderTxt2img();

      final next = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'steps', <String, Object?>{}),
      ]);
      final form = await formOf(next, 'example_txt2img');

      // `loop` never existed under this workflow when the defaults were
      // written; it is the curator's value, and no error.
      final grown = await opened(<Map<String, Object?>>[
        <String, Object?>{
          ...txt2imgDetail(),
          'inputs': <Object?>[
            ...txt2imgDetail()['inputs']! as List<Object?>,
            <String, Object?>{
              'id': 'loop',
              'label': 'Loop the result',
              'type': 'boolean',
              'section': 'advanced',
              'default': true,
            },
          ],
        },
      ]);
      final grownForm = await formOf(grown, 'example_txt2img');

      expect(form.text('steps'), '44');
      expect(grownForm.flag('loop'), isTrue);
      expect(grownForm.text('steps'), '44');
    });

    test('a saved value outside a range that has since changed is discarded',
        () async {
      await saveUnderTxt2img();

      final next = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'steps', <String, Object?>{'max': 30}),
      ]);
      final form = await formOf(next, 'example_txt2img');

      expect(
        form.text('steps'),
        '20',
        reason: '44 is outside 1..30 now, so the workflow default stands',
      );
      expect(
        form.validate().issueFor('steps'),
        isNull,
        reason: 'a form is never loaded with a value it cannot validate',
      );
      // The one that is still legal is still applied.
      expect(form.entry('sampler'), 'dpmpp_2m');
    });

    test('a saved choice the workflow no longer offers is discarded', () async {
      await saveUnderTxt2img();

      final next = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'sampler', <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'value': 'euler', 'label': 'Euler'},
          ],
        }),
      ]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.entry('sampler'), 'euler');
      expect(form.validate().issueFor('sampler'), isNull);
    });

    test('a saved value of the wrong kind is discarded', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            // A whole number where the field wants a whole number is fine;
            // these are not.
            'localcanvas.defaults.example_txt2img.steps': 'many',
            'localcanvas.defaults.example_txt2img.sampler': 7,
            'localcanvas.defaults.example_txt2img.guidance': true,
          });

      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');

      expect(form.text('steps'), '20');
      expect(form.entry('sampler'), 'euler');
      expect(form.text('guidance'), '6');
      expect(form.hasMyDefaults, isFalse);
    });
  });

  group('the two resets', () {
    test('reset to my defaults comes back to what was saved', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form.setEntry('steps', '44');
      await app.saveMyDefaults();

      form.setEntry('steps', '7');
      form.resetSettingsToMyDefaults();

      expect(form.text('steps'), '44');
    });

    test('neither reset touches a prompt or a picture', () async {
      // Both buttons live in a row about settings, one tap away from
      // Generate. Neither may throw away the prompt someone has been writing
      // or the picture they have already uploaded: My defaults contains
      // neither, so neither is a reset's to restore or to take.
      picker.answers = <MediaSelection?>[tempSelection()];
      final app = await opened(
        <Map<String, Object?>>[img2imgDetail()],
        withMedia: true,
      );
      final form = await formOf(app, 'example_img2img');
      form.setEntry('strength', '0.9');
      await app.saveMyDefaults();

      form
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('output_name', 'Seascapes')
        ..setEntry('strength', '0.2');
      await form.media('source_image')!.choose();
      expect(form.media('source_image')!.phase, MediaPhase.ready);
      final mediaId = form.media('source_image')!.mediaId;

      form.resetSettingsToMyDefaults();

      expect(form.text('strength'), '0.9', reason: 'the setting did come back');
      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('output_name'), 'Seascapes');
      expect(form.media('source_image')!.phase, MediaPhase.ready);
      expect(form.media('source_image')!.mediaId, mediaId);

      form.setEntry('strength', '0.2');
      form.resetSettingsToWorkflowDefaults();

      expect(
        form.text('strength'),
        '0.55',
        reason: 'and the workflow value came back too',
      );
      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('output_name'), 'Seascapes');
      expect(form.media('source_image')!.phase, MediaPhase.ready);
      expect(form.media('source_image')!.mediaId, mediaId);
      // What would be sent still carries the picture.
      expect(form.validate().inputs['source_image'], <String, Object?>{
        'media_id': mediaId,
      });
    });

    test('reset to workflow defaults returns the settings and keeps what was '
        'saved', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form.setEntry('steps', '44');
      await app.saveMyDefaults();

      form.resetSettingsToWorkflowDefaults();

      expect(form.text('steps'), '20');
      // The promise this button makes is about the form. What was saved is
      // still saved, is still offered, and is still there on the next launch.
      expect(form.hasMyDefaults, isTrue);
      expect(
        (await preferences())['localcanvas.defaults.example_txt2img.steps'],
        44,
      );
      form.resetSettingsToMyDefaults();
      expect(form.text('steps'), '44');

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect((await formOf(next, 'example_txt2img')).text('steps'), '44');
    });

    test('saving takes what is in the form, and never a half-typed number',
        () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form
        ..setEntry('steps', '44')
        ..setEntry('guidance', '');
      await app.saveMyDefaults();

      expect(
        (await preferences())['localcanvas.defaults.example_txt2img.steps'],
        44,
      );
      expect(
        (await preferences()).containsKey(
          'localcanvas.defaults.example_txt2img.guidance',
        ),
        isFalse,
        reason: 'an empty optional number is not a default anybody chose',
      );

      // And saving again is a replacement, not a second copy.
      form.setEntry('steps', '12');
      await app.saveMyDefaults();
      expect(
        (await preferences())['localcanvas.defaults.example_txt2img.steps'],
        12,
      );
    });

    test('a setting cleared and saved again does not come back next launch',
        () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img')).setEntry('steps', '44');
      await first.saveMyDefaults();

      // Second launch: the user clears the value and saves, which is the only
      // way they have of saying "I no longer want a default here".
      final second = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(second, 'example_txt2img');
      expect(form.text('steps'), '44');
      form.setEntry('steps', '');
      await second.saveMyDefaults();

      expect(
        (await preferences()).containsKey(
          'localcanvas.defaults.example_txt2img.steps',
        ),
        isFalse,
      );
      final third = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect(
        (await formOf(third, 'example_txt2img')).text('steps'),
        '20',
        reason: 'an unset default falls back to what the workflow declares',
      );
    });
  });
}
