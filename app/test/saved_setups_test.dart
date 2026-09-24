/// Saved setups, from the store to the form and the screen.
///
/// The store here is the real `PreferencesWorkflowSetupStore` over the
/// package's own in-memory platform, beside the real settings and draft
/// stores, and the workflows arrive as the wire bodies in
/// `support/workflow_payloads.dart`. Nothing in between is faked, so "the app
/// was killed and opened again" is two `opened()` calls: new controllers, the
/// same preferences.
///
/// Three rules run through everything below:
///
/// * what is written down is the **original** text — what the user typed —
///   and never the effective text a translated submission was bound with;
/// * a reference to an uploaded file is never written down at all, and
///   neither is anything structural;
/// * a setup is **explicit**. Opening a workflow that has ten of them changes
///   nothing about the form.
library;

import 'support/l10n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/ui/workflows/setups_bar.dart';
import 'package:localcanvas/ui/workflows/workflow_form_view.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

/// What the user typed. Never rewritten, never replaced.
const String kOriginal = 'кот в шляпе на мокрой улице';

/// What the gateway bound into the graph for one run. Deliberately nothing
/// like the original, so a setup holding the wrong one cannot pass by
/// resembling the right one.
const String kEffective = 'a cat in a hat on a wet street';

/// The body `POST /api/v1/jobs` answers with when it translated the prompt.
Map<String, Object?> translatedBody() => <String, Object?>{
  'job_id': 'j-8f21',
  'state': 'completed',
  'translation': <String, Object?>{
    'applied': true,
    'fields': <String, Object?>{
      'prompt': <String, Object?>{
        'original': kOriginal,
        'effective': kEffective,
        'translation': <String, Object?>{
          'applied': true,
          'source': 'ru',
          'target': 'en',
        },
      },
    },
  },
};

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

  Future<List<String>> setupKeys() async => <String>[
    for (final key in (await preferences()).keys)
      if (key.startsWith('localcanvas.setup.')) key,
  ]..sort();

  /// Every setup document, as text, read around the store.
  Future<List<String>> setupDocuments() async {
    final stored = await preferences();
    return <String>[for (final key in await setupKeys()) stored[key]! as String];
  }

  /// A registry, connected, with the real stores behind it. Calling this twice
  /// in one test is the app being opened twice on the same device.
  Future<WorkflowsController> opened(
    List<Map<String, Object?>> details, {
    bool keepsSetups = true,
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
      settings: PreferencesWorkflowSettingsStore(),
      drafts: PreferencesWorkflowDraftStore(),
      setups: keepsSetups ? PreferencesWorkflowSetupStore() : null,
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

  /// The same body with one field's declaration changed.
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

  group('saved, and come back to', () {
    test('the prompt and the settings return after the app was killed',
        () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img'))
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('negative_prompt', 'blurry')
        ..setEntry('steps', '44')
        ..setEntry('guidance', '9.5')
        ..setEntry('sampler', 'dpmpp_2m');
      final saved = await first.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Night alley',
      );
      expect(saved, isNotNull);

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');

      // Opening the workflow put none of it back: a setup is not a layer the
      // form is built from, and this is the state the form would be in if no
      // setup had ever been saved.
      expect(form.text('prompt'), '');
      expect(form.text('steps'), '20');
      expect(form.entry('sampler'), 'euler');

      final setup = next.setupsFor('example_txt2img').single;
      expect(setup.name, 'Night alley');
      next.applySetup(setup);

      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('negative_prompt'), 'blurry');
      expect(form.text('steps'), '44');
      expect(form.text('guidance'), '9.5');
      expect(form.entry('sampler'), 'dpmpp_2m');
      expect(form.text('width'), '768', reason: 'and the rest is the curator`s');
    });

    test('a half-typed number is not saved as a value nobody could generate '
        'with', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form
        ..setEntry('prompt', 'a lighthouse')
        ..setEntry('steps', '4-');

      await app.saveSetup(workflowId: 'example_txt2img', name: 'Half typed');

      final setup = app.setupsFor('example_txt2img').single;
      expect(setup.values['prompt'], 'a lighthouse');
      expect(setup.values.containsKey('steps'), isFalse);
      // And the value that could not be kept leaves the field alone when the
      // setup is applied: the form keeps what it has.
      form.setEntry('steps', '33');
      app.applySetup(setup);
      expect(form.text('steps'), '33');
    });

    test('a build that keeps no setups saves none, and answers with none',
        () async {
      final app = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        keepsSetups: false,
      );
      final form = await formOf(app, 'example_txt2img');
      form.setEntry('prompt', 'a lighthouse');

      expect(
        await app.saveSetup(workflowId: 'example_txt2img', name: 'Nowhere'),
        isNull,
      );
      expect(app.setupsFor('example_txt2img'), isEmpty);
      expect(app.canSaveSetupFor('example_txt2img'), isFalse);
      expect(await setupKeys(), isEmpty);
    });
  });

  group('the original, never the effective text', () {
    test('a submission that really translated leaves the user`s own words in '
        'the setup', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form
        ..setEntry('prompt', kOriginal)
        ..setEntry('steps', '44');

      final jobs = ScriptedJobsApi(
        submission: JobSubmission.tryFromJson(translatedBody())!,
      );
      final generation = GenerationController(api: jobs);
      addTearDown(generation.dispose);
      generation.attach(
        endpoint: endpoint,
        capabilities: const GatewayCapabilities(),
      );
      await generation.submit(
        workflowId: 'example_txt2img',
        inputs: form.validate().inputs,
      );

      // The condition under which the wrong text could be written really
      // exists: the effective text is in the session, right now, and is not
      // the original.
      expect(kEffective, isNot(kOriginal));
      expect(generation.translation.appliedFor('prompt')!.effective, kEffective);
      expect(jobs.submittedInputs.single['prompt'], kOriginal);

      await app.saveSetup(workflowId: 'example_txt2img', name: 'Night alley');

      final written = (await setupDocuments()).single;
      expect(written, contains(jsonEncode(kOriginal).replaceAll('"', '')));
      expect(
        written,
        isNot(contains(kEffective)),
        reason: 'a setup that stored the translation would hand the user back '
            'what the machine made of their words, under a name they chose '
            'for their own',
      );
      expect(written, isNot(contains('a cat')));
      expect(
        app.setupsFor('example_txt2img').single.values['prompt'],
        kOriginal,
      );

      // And the next launch gives back what was typed, character for
      // character.
      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form2 = await formOf(next, 'example_txt2img');
      next.applySetup(next.setupsFor('example_txt2img').single);
      expect(form2.text('prompt'), kOriginal);
    });
  });

  group('nothing about a picture, and nothing structural, is written', () {
    test('a form with an uploaded image keeps the prompt and not the media',
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
      final selection = form.media('source_image')!.selection!;
      final path = (selection.source as FileMediaSource).path;
      // All three really are in the form, and the first really would be sent —
      // so the assertions below are about what was refused, not about values
      // that were never there.
      expect(form.validate().inputs['source_image'], <String, Object?>{
        'media_id': mediaId,
      });
      expect(selection.displayName(en), 'IMG_0142.jpg');
      expect(path, isNotEmpty);

      await app.saveSetup(workflowId: 'example_img2img', name: 'From a photo');

      final written = (await setupDocuments()).single;
      expect(written, isNot(contains(mediaId)));
      expect(written, isNot(contains('media_id')));
      expect(written, isNot(contains('IMG_0142')));
      expect(written, isNot(contains(path)));
      expect(written, isNot(contains('.jpg')));
      // What is in there is the prose and the settings, and exactly the
      // fields the workflow declares.
      final document = jsonDecode(written) as Map<String, Object?>;
      final values = document['values']! as Map<String, Object?>;
      expect(values, <String, Object?>{
        'prompt': 'a lighthouse in a storm',
        'strength': 0.8,
        'output_name': 'Seascapes',
      });
      expect(
        values.keys.toSet().difference(
          form.detail.inputs.map((field) => field.id).toSet(),
        ),
        isEmpty,
        reason: 'every key is a field this workflow declared',
      );
      // Nothing structural could even be in reach: the app`s own model of a
      // workflow carries the fields and nothing else — no definition, no node
      // and no address — which is why the guard that keeps it that way is a
      // guard on the source (`workflow_setup_store_test.dart`).
      expect(document.keys.toSet(), <String>{'workflow', 'name', 'values'});
      expect(written, isNot(contains('192.168')));
      expect(written, isNot(contains('http')));
    });

    test('the form itself offers no media field to a setup', () async {
      // The first of the two guards, on its own: the store is not involved at
      // all here, and the picture is genuinely ready — the input map the same
      // form would submit carries the reference, so the assertions below are
      // about what the form left out and not about a value that was never
      // there.
      picker.answers = <MediaSelection?>[tempSelection()];
      final form = WorkflowFormController(
        WorkflowDetail.tryFromJson(allTypesDetail())!,
        picker: picker,
        uploader: (selection, onProgress) =>
            uploads.upload(endpoint, selection, onProgress: onProgress),
      );
      addTearDown(form.dispose);
      form.setEntry('prompt', 'a lighthouse');
      await form.media('source_image')!.choose();

      expect(form.media('source_image')!.phase, MediaPhase.ready);
      expect(form.validate().inputs['source_image'], <String, Object?>{
        'media_id': form.media('source_image')!.mediaId,
      });

      expect(form.draftableValues().keys, isNot(contains('source_image')));
      expect(form.draftableValues().keys, isNot(contains('source_clip')));
      expect(form.draftableValues().keys, contains('prompt'));
      expect(form.draftableValues().keys, contains('steps'));
    });

    test('a media reference someone wrote into a setup never reaches a field',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.setup.handmade': jsonEncode(<String, Object?>{
              'workflow': 'example_img2img',
              'name': 'Handmade',
              'values': <String, Object?>{
                'prompt': 'a lighthouse',
                'source_image': 'm-3f9c1a',
              },
            }),
          });

      final app = await opened(
        <Map<String, Object?>>[img2imgDetail()],
        withMedia: true,
      );
      final form = await formOf(app, 'example_img2img');
      app.applySetup(app.setupsFor('example_img2img').single);

      expect(form.text('prompt'), 'a lighthouse');
      expect(form.media('source_image')!.phase, MediaPhase.empty);
      expect(form.entry('source_image'), isNull);
      expect(
        form.validate().issueFor('source_image')!.kind,
        FieldIssueKind.missing,
        reason: 'the field asks for the picture again, which is the point',
      );
    });
  });

  group('several under one workflow, and none of another', () {
    test('setups do not leak between two workflows declaring the same field',
        () async {
      // Both workflows have a field whose logical id is `prompt` and one
      // called `steps`: the case a store that was not per workflow would pass.
      final registry = <Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ];
      final app = await opened(registry);
      (await formOf(app, 'example_txt2img'))
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('steps', '44');
      await app.saveSetup(workflowId: 'example_txt2img', name: 'Mine');
      (await formOf(app, 'all_types'))
        ..setEntry('prompt', 'a harbour at dawn')
        ..setEntry('steps', '8');
      await app.saveSetup(workflowId: 'all_types', name: 'Mine');

      final next = await opened(registry);
      final txt2img = await formOf(next, 'example_txt2img');
      final allTypes = await formOf(next, 'all_types');
      expect(next.setupsFor('example_txt2img'), hasLength(1));
      expect(next.setupsFor('all_types'), hasLength(1));

      next.applySetup(next.setupsFor('example_txt2img').single);
      next.applySetup(next.setupsFor('all_types').single);

      expect(txt2img.text('prompt'), 'a lighthouse in a storm');
      expect(txt2img.text('steps'), '44');
      expect(allTypes.text('prompt'), 'a harbour at dawn');
      expect(allTypes.text('steps'), '8');
    });

    test('several coexist under one workflow, each with its own values',
        () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');

      form
        ..setEntry('prompt', 'a lighthouse')
        ..setEntry('steps', '10');
      await app.saveSetup(workflowId: 'example_txt2img', name: 'Quick');
      form
        ..setEntry('prompt', 'a harbour')
        ..setEntry('steps', '40');
      await app.saveSetup(workflowId: 'example_txt2img', name: 'Slow');

      expect(app.setupsFor('example_txt2img').map((s) => s.name), <String>[
        'Quick',
        'Slow',
      ]);
      app.applySetup(app.setupsFor('example_txt2img').first);
      expect(form.text('prompt'), 'a lighthouse');
      expect(form.text('steps'), '10');
      app.applySetup(app.setupsFor('example_txt2img').last);
      expect(form.text('prompt'), 'a harbour');
      expect(form.text('steps'), '40');
    });
  });

  group('renaming does not change identity', () {
    test('applying still works after a rename, and the id is the same',
        () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('steps', '44');
      final made = await app.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Night alley',
      );

      await app.renameSetup(made!, 'Rainy alley');

      final renamed = app.setupsFor('example_txt2img').single;
      expect(renamed.id, made.id);
      expect(renamed.name, 'Rainy alley');
      form
        ..setEntry('prompt', 'something else entirely')
        ..setEntry('steps', '7');
      app.applySetup(renamed);
      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('steps'), '44');

      // And it is still one setup after a restart, under the new name.
      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await formOf(next, 'example_txt2img');
      expect(next.setupsFor('example_txt2img').single.id, made.id);
      expect(next.setupsFor('example_txt2img').single.name, 'Rainy alley');
    });

    test('two setups may share a name, and delete takes exactly one',
        () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form.setEntry('steps', '10');
      final first = await app.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Night alley',
      );
      form.setEntry('steps', '20');
      final second = await app.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Night alley',
      );
      expect(second!.id, isNot(first!.id));
      expect(app.setupsFor('example_txt2img'), hasLength(2));

      await app.deleteSetup(first);

      final left = app.setupsFor('example_txt2img');
      expect(left.single.id, second.id);
      expect(left.single.name, 'Night alley');
      form.setEntry('steps', '33');
      app.applySetup(left.single);
      expect(form.text('steps'), '20');
      expect(await setupKeys(), hasLength(1));
    });
  });

  group('applying after the workflow changed', () {
    /// One setup, written straight into the preferences as an earlier version
    /// of the workflow would have left it.
    Future<void> given(
      String workflowId,
      Map<String, Object?> values, {
      String name = 'Saved earlier',
    }) => PreferencesWorkflowSetupStore().create(
      workflowId: workflowId,
      name: name,
      values: values,
    );

    test('compatible fields apply and obsolete ones are skipped without error',
        () async {
      await given('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse in a storm',
        'steps': 44,
        // A field this version of the workflow no longer declares.
        'sampler': 'dpmpp_2m',
      });

      final app = await opened(<Map<String, Object?>>[
        withoutField(txt2imgDetail(), 'sampler'),
      ]);
      final form = await formOf(app, 'example_txt2img');
      app.applySetup(app.setupsFor('example_txt2img').single);

      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('steps'), '44');
      expect(form.entry('sampler'), isNull);
      expect(form.validate().inputs.containsKey('sampler'), isFalse);
      expect(form.validate().issues, isEmpty);
      // And it is kept in the store: the field may come back with the next
      // sync.
      expect((await setupDocuments()).single, contains('dpmpp_2m'));
    });

    test('a field the setup says nothing about takes the current default',
        () async {
      // Saved when the workflow had no `guidance` at all.
      await given('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse',
        'steps': 44,
      });

      final app = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'guidance', <String, Object?>{
          'default': 11.5,
        }),
      ]);
      final form = await formOf(app, 'example_txt2img');
      app.applySetup(app.setupsFor('example_txt2img').single);

      expect(form.text('steps'), '44');
      expect(form.text('guidance'), '11.5');
    });

    test('a value outside a changed range is discarded, not loaded', () async {
      await given('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse',
        'steps': 48,
      });

      final app = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'steps', <String, Object?>{'max': 30}),
      ]);
      final form = await formOf(app, 'example_txt2img');
      form.setEntry('steps', '25');
      app.applySetup(app.setupsFor('example_txt2img').single);

      expect(form.text('prompt'), 'a lighthouse', reason: 'the rest applies');
      expect(form.text('steps'), '25', reason: 'what the form had, kept');
      expect(
        form.validate().issueFor('steps'),
        isNull,
        reason: 'a form is never loaded with a value it cannot validate',
      );
    });

    test('a choice the workflow no longer offers is discarded', () async {
      await given('example_txt2img', <String, Object?>{
        'prompt': 'a lighthouse',
        'sampler': 'dpmpp_2m',
      });

      final app = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'sampler', <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'value': 'euler', 'label': 'Euler'},
          ],
        }),
      ]);
      final form = await formOf(app, 'example_txt2img');
      app.applySetup(app.setupsFor('example_txt2img').single);

      expect(form.entry('sampler'), 'euler');
      expect(form.validate().issueFor('sampler'), isNull);
      expect(
        form.text('prompt'),
        'a lighthouse',
        reason: 'one illegal value does not cost the user the rest',
      );
    });

    test('a value of the wrong kind is discarded', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.setup.handmade': jsonEncode(<String, Object?>{
              'workflow': 'example_txt2img',
              'name': 'Handmade',
              'values': <String, Object?>{
                'steps': 'many',
                'sampler': 7,
                'guidance': true,
                // Prose is checked too: a number is not something a person
                // typed.
                'prompt': 44,
              },
            }),
          });

      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      app.applySetup(app.setupsFor('example_txt2img').single);

      expect(form.text('steps'), '20');
      expect(form.entry('sampler'), 'euler');
      expect(form.text('guidance'), '6');
      expect(form.text('prompt'), '');
    });
  });

  group('a setup whose workflow is not installed', () {
    test('survives a launch that never sees that workflow', () async {
      final registry = <Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ];
      final first = await opened(registry);
      (await formOf(first, 'all_types')).setEntry('prompt', 'a harbour');
      final dormant = await first.saveSetup(
        workflowId: 'all_types',
        name: 'From the old server',
      );
      (await formOf(first, 'example_txt2img')).setEntry('prompt', 'a lighthouse');
      await first.saveSetup(workflowId: 'example_txt2img', name: 'Still here');
      expect(await setupKeys(), hasLength(2));

      // The server publishes one of the two now. The whole launch runs: the
      // registry is fetched, the surviving workflow is opened, its setups are
      // read, one is applied, one is renamed and one is deleted — every path
      // that touches the store.
      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');
      final here = next.setupsFor('example_txt2img').single;
      next.applySetup(here);
      await next.renameSetup(here, 'Renamed');
      await next.saveSetup(workflowId: 'example_txt2img', name: 'And another');
      await next.deleteSetup(next.setupsFor('example_txt2img').last);

      expect(form.text('prompt'), 'a lighthouse');
      expect(
        next.setupsFor('all_types'),
        isEmpty,
        reason: 'a workflow that is not installed is not listed',
      );
      // And the dormant one is still in the store, whole.
      final still = await PreferencesWorkflowSetupStore().load('all_types');
      expect(still.single.id, dormant!.id);
      expect(still.single.name, 'From the old server');
      expect(still.single.values['prompt'], 'a harbour');
      expect(await setupKeys(), hasLength(2));
    });

    test('changing server does not delete anything', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(app, 'example_txt2img')).setEntry('prompt', 'a lighthouse');
      await app.saveSetup(workflowId: 'example_txt2img', name: 'Night alley');
      final before = await setupKeys();

      await app.load(Endpoint.tryParse('192.0.2.99')!);

      expect(
        app.setupsFor('example_txt2img'),
        isEmpty,
        reason: 'nothing is listed until a workflow is opened again',
      );
      expect(await setupKeys(), before);
      await formOf(app, 'example_txt2img');
      expect(app.setupsFor('example_txt2img'), hasLength(1));
    });
  });

  group('a result kept as a setup', () {
    test('carries the original prompt and what the user saw', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form
        ..setEntry('prompt', kOriginal)
        ..setEntry('steps', '44');

      final jobs = ScriptedJobsApi(
        submission: JobSubmission.tryFromJson(translatedBody())!,
      );
      final generation = GenerationController(api: jobs);
      addTearDown(generation.dispose);
      generation.attach(
        endpoint: endpoint,
        capabilities: const GatewayCapabilities(),
      );
      await generation.submit(
        workflowId: 'example_txt2img',
        inputs: form.validate().inputs,
      );
      expect(generation.state, LifecycleState.completed);
      expect(generation.workflowId, 'example_txt2img');
      expect(generation.translation.appliedFor('prompt')!.effective, kEffective);

      // Exactly what the surface offers: the workflow the generation was
      // submitted for, and a name.
      expect(app.canSaveSetupFor(generation.workflowId!), isTrue);
      await app.saveSetup(
        workflowId: generation.workflowId!,
        name: 'That good one',
      );

      final setup = app.setupsFor('example_txt2img').single;
      expect(setup.values['prompt'], kOriginal);
      expect(setup.values['steps'], 44);
      expect((await setupDocuments()).single, isNot(contains(kEffective)));
    });

    test('a result whose workflow this session never opened offers nothing',
        () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);

      expect(
        app.canSaveSetupFor('example_txt2img'),
        isFalse,
        reason: 'there is no form to read the user`s own words out of',
      );
      // And it is true as soon as there is one, so the answer above is about
      // the form and not about the store.
      await formOf(app, 'example_txt2img');
      expect(app.canSaveSetupFor('example_txt2img'), isTrue);
    });
  });

  group('in the form', () {
    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(460, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// The form on its own, with or without setups — the second argument is
    /// exactly the difference this card makes to it.
    Widget host(
      WorkflowDetail detail,
      WorkflowFormController form, {
      SetupActions? setups,
    }) => MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: lcDarkTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkflowFormView(
            detail: detail,
            form: form,
            onGenerate: (_) {},
            onSaveDefaults: () {},
            setups: setups,
          ),
        ),
      ),
    );

    /// Every string the form draws, in order.
    List<String> textsIn(WidgetTester tester) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(LcKeys.workflowForm),
            matching: find.byType(Text),
          ),
        )
        .map((widget) => widget.data ?? '')
        .toList();

    /// Every key the app itself gives a widget in the form.
    ///
    /// `ValueKey<String>` is what `LcKeys` is made of; Material's own
    /// [GlobalKey]s are left out because a fresh instance of one is a
    /// different object on every build and would make any two trees differ.
    Set<Key> keysIn(WidgetTester tester) => <Key>{
      for (final element in find
          .descendant(
            of: find.byKey(LcKeys.workflowForm),
            matching: find.byWidgetPredicate(
              (widget) => widget.key is ValueKey<String>,
            ),
          )
          .evaluate())
        element.widget.key!,
    };

    testWidgets('a workflow with no setups draws the form it always drew, '
        'plus one affordance', (tester) async {
      tallView(tester);
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      final form = WorkflowFormController(detail);
      addTearDown(form.dispose);

      // The pre-change path: the form as it was built before this card, with
      // no setups argument at all.
      await tester.pumpWidget(host(detail, form));
      await tester.pumpAndSettle();
      final beforeTexts = textsIn(tester);
      final beforeKeys = keysIn(tester);
      expect(beforeKeys, contains(LcKeys.generate));

      await tester.pumpWidget(
        host(
          detail,
          form,
          setups: SetupActions(
            setups: const <WorkflowSetup>[],
            onSave: (_) {},
            onApply: (_) {},
            onRename: (_, _) {},
            onDelete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      const String label = 'Save prompt and settings as a setup';
      expect(
        textsIn(tester).where((text) => text != label).toList(),
        beforeTexts,
      );
      expect(keysIn(tester).difference(beforeKeys), <Key>{LcKeys.saveSetup});
      expect(find.byKey(LcKeys.setups), findsNothing);
      expect(find.text(label), findsOneWidget);

      // And the comparison can fail: one setup and it does.
      const saved = WorkflowSetup(
        id: 's-1',
        workflowId: 'example_txt2img',
        name: 'Night alley',
      );
      await tester.pumpWidget(
        host(
          detail,
          form,
          setups: SetupActions(
            setups: const <WorkflowSetup>[saved],
            onSave: (_) {},
            onApply: (_) {},
            onRename: (_, _) {},
            onDelete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        textsIn(tester).where((text) => text != label).toList(),
        isNot(beforeTexts),
      );
      expect(
        keysIn(tester).difference(beforeKeys),
        isNot(<Key>{LcKeys.saveSetup}),
      );
      expect(find.byKey(LcKeys.setups), findsOneWidget);
      expect(find.text('Night alley'), findsOneWidget);
    });

    testWidgets('a long name fits the narrowest pane the shell ever gives',
        (tester) async {
      // `LcLayout.controlsPaneMin`: the least width the two-pane layout gives
      // the controls (`docs/ui-ux.md`). A row that overflowed here would fail
      // this test on the spot — Flutter raises on overflow — so this is the
      // check that the three affordances still fit beside a name nobody
      // budgeted for.
      tester.view.physicalSize = const Size(320, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      final form = WorkflowFormController(detail);
      addTearDown(form.dispose);
      const long = WorkflowSetup(
        id: 's-1',
        workflowId: 'example_txt2img',
        name: 'The one with the rainy alley, the warm rim light and the very '
            'long name somebody typed in one go',
      );
      var applied = 0;

      await tester.pumpWidget(
        host(
          detail,
          form,
          setups: SetupActions(
            setups: const <WorkflowSetup>[long],
            onSave: (_) {},
            onApply: (_) => applied++,
            onRename: (_, _) {},
            onDelete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // One line, and all three affordances are there and take a tap.
      expect(tester.getSize(find.byKey(LcKeys.setup(long.id))).height,
          lessThanOrEqualTo(56));
      expect(find.byKey(LcKeys.renameSetup(long.id)), findsOneWidget);
      expect(find.byKey(LcKeys.deleteSetup(long.id)), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.applySetup(long.id)));
      await tester.pumpAndSettle();
      expect(applied, 1);
      final name = tester.widget<Text>(
        find.descendant(
          of: find.byKey(LcKeys.applySetup(long.id)),
          matching: find.byType(Text),
        ),
      );
      expect(name.overflow, TextOverflow.ellipsis);
      expect(name.data, long.name, reason: 'nothing is truncated in the data');
    });

    testWidgets('the label says what will be kept', (tester) async {
      tallView(tester);
      // A workflow of nothing but numbers and choices: there is no prompt to
      // promise, and the label does not promise one.
      final body = withoutField(
        withoutField(txt2imgDetail(), 'prompt'),
        'negative_prompt',
      );
      final detail = WorkflowDetail.tryFromJson(body)!;
      final form = WorkflowFormController(detail);
      addTearDown(form.dispose);

      await tester.pumpWidget(
        host(
          detail,
          form,
          setups: SetupActions(
            setups: const <WorkflowSetup>[],
            onSave: (_) {},
            onApply: (_) {},
            onRename: (_, _) {},
            onDelete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Save settings as a setup'), findsOneWidget);
      expect(find.text('Save prompt and settings as a setup'), findsNothing);
    });
  });

  /// Applying, and the one thing it may not do quietly: take away words
  /// somebody wrote. There is no undo anywhere in this app.
  ///
  /// The form is the real one and `onApply` really applies, so every
  /// assertion below is about the text in the form rather than about the
  /// dialog that asked — a test that read the answer back out of the question
  /// would be certifying the mechanism with itself.
  group('applying over something written', () {
    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(460, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// The question, word for word, as a person reads it.
    const String question = 'Replace what you wrote?';
    String body(String name) =>
        '“$name” would take the place of the text you have written in this '
        'form.';

    /// What somebody is in the middle of writing.
    const String written = 'a half-written prompt I care about';

    /// The form with one setup in it, wired so that applying really applies.
    /// [applied] counts the times the form was asked to take the setup on.
    Future<WorkflowFormController> given(
      WidgetTester tester,
      WorkflowSetup setup,
      List<String> applied,
    ) async {
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      final form = WorkflowFormController(detail);
      addTearDown(form.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: WorkflowFormView(
                detail: detail,
                form: form,
                onGenerate: (_) {},
                onSaveDefaults: () {},
                setups: SetupActions(
                  setups: <WorkflowSetup>[setup],
                  onSave: (_) {},
                  onApply: (applying) {
                    applied.add(applying.id);
                    form.adoptSetup(applying);
                  },
                  onRename: (_, _) {},
                  onDelete: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return form;
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(LcKeys.field('prompt')), text);
      await tester.pumpAndSettle();
    }

    Future<void> apply(WidgetTester tester, WorkflowSetup setup) async {
      await tester.ensureVisible(find.byKey(LcKeys.applySetup(setup.id)));
      await tester.tap(find.byKey(LcKeys.applySetup(setup.id)));
      await tester.pumpAndSettle();
    }

    testWidgets('the setup that empties a prompt asks first, and only a '
        'deliberate yes empties it', (tester) async {
      tallView(tester);
      // T-0051's review probe: a setup made from a form holding only
      // `steps = 44` carries `prompt: ''` — a value, not a missing one.
      const setup = WorkflowSetup(
        id: 's-1',
        workflowId: 'example_txt2img',
        name: 'Night alley',
        values: <String, Object?>{'prompt': '', 'steps': 44},
      );
      final applied = <String>[];
      final form = await given(tester, setup, applied);
      await type(tester, written);

      await apply(tester, setup);

      expect(find.byKey(LcKeys.applySetupConfirm), findsOneWidget);
      expect(find.text(question), findsOneWidget);
      expect(find.text(body('Night alley')), findsOneWidget);
      expect(applied, isEmpty, reason: 'nothing is applied while it asks');
      expect(form.text('prompt'), written);

      // Keep mine.
      await tester.tap(find.byKey(LcKeys.applySetupKeep));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.applySetupConfirm), findsNothing);
      expect(applied, isEmpty);
      expect(form.text('prompt'), written);
      expect(form.text('steps'), '20', reason: 'and not the settings either');

      // A tap outside — the third value `showDialog` answers with, and the
      // one an `== false` reading of it would treat as a yes.
      await apply(tester, setup);
      expect(find.byKey(LcKeys.applySetupConfirm), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.applySetupConfirm), findsNothing);
      expect(applied, isEmpty);
      expect(form.text('prompt'), written);

      // And the deliberate yes, which is allowed to do exactly what it says.
      await apply(tester, setup);
      await tester.tap(find.byKey(LcKeys.applySetupReplace));
      await tester.pumpAndSettle();
      expect(applied, <String>['s-1']);
      expect(form.text('prompt'), '');
      expect(form.text('steps'), '44');
    });

    testWidgets('a written prompt the setup would rewrite asks the same '
        'question', (tester) async {
      tallView(tester);
      const setup = WorkflowSetup(
        id: 's-2',
        workflowId: 'example_txt2img',
        name: 'Rainy alley',
        values: <String, Object?>{'prompt': 'a rainy alley', 'steps': 44},
      );
      final applied = <String>[];
      final form = await given(tester, setup, applied);
      await type(tester, written);

      await apply(tester, setup);
      expect(find.text(body('Rainy alley')), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.applySetupKeep));
      await tester.pumpAndSettle();
      expect(form.text('prompt'), written);
      expect(form.text('steps'), '20');

      await apply(tester, setup);
      await tester.tap(find.byKey(LcKeys.applySetupReplace));
      await tester.pumpAndSettle();
      expect(applied, <String>['s-2']);
      expect(form.text('prompt'), 'a rainy alley');
      expect(form.text('steps'), '44');
    });

    testWidgets('an empty prompt is applied onto with no question at all',
        (tester) async {
      tallView(tester);
      const setup = WorkflowSetup(
        id: 's-3',
        workflowId: 'example_txt2img',
        name: 'Rainy alley',
        values: <String, Object?>{'prompt': 'a rainy alley'},
      );
      final applied = <String>[];
      final form = await given(tester, setup, applied);

      await apply(tester, setup);
      expect(find.byKey(LcKeys.applySetupConfirm), findsNothing);
      expect(find.text(question), findsNothing);
      expect(applied, <String>['s-3']);
      expect(form.text('prompt'), 'a rainy alley');

      // Whitespace is what an empty field looks like everywhere else in this
      // form, so it is not text worth protecting either.
      await type(tester, '   ');
      await apply(tester, setup);
      expect(find.byKey(LcKeys.applySetupConfirm), findsNothing);
      expect(applied, <String>['s-3', 's-3']);
      expect(form.text('prompt'), 'a rainy alley');

      // And the finders above can find a dialog: with words in the field,
      // this very setup puts one up. Without this the two absences are free.
      await type(tester, written);
      await apply(tester, setup);
      expect(find.byKey(LcKeys.applySetupConfirm), findsOneWidget);
      expect(find.text(question), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.applySetupKeep));
      await tester.pumpAndSettle();
      expect(form.text('prompt'), written);
    });

    testWidgets('a setup whose words are already on screen asks nothing',
        (tester) async {
      tallView(tester);
      const setup = WorkflowSetup(
        id: 's-4',
        workflowId: 'example_txt2img',
        name: 'Rainy alley',
        values: <String, Object?>{'prompt': 'a rainy alley', 'steps': 44},
      );
      final applied = <String>[];
      final form = await given(tester, setup, applied);
      await type(tester, 'a rainy alley');

      await apply(tester, setup);

      expect(
        find.byKey(LcKeys.applySetupConfirm),
        findsNothing,
        reason: 'nothing would be lost, so there is nothing to ask about',
      );
      expect(applied, <String>['s-4']);
      expect(form.text('prompt'), 'a rainy alley');
      expect(form.text('steps'), '44', reason: 'and it really was applied');

      // The same setup over one different character does ask, so the silence
      // above is about the words and not about this setup.
      await type(tester, 'a rainy alleyway');
      await apply(tester, setup);
      expect(find.byKey(LcKeys.applySetupConfirm), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.applySetupKeep));
      await tester.pumpAndSettle();
      expect(form.text('prompt'), 'a rainy alleyway');
    });

    testWidgets('a setup of nothing but settings never asks, and still '
        'applies', (tester) async {
      tallView(tester);
      const setup = WorkflowSetup(
        id: 's-5',
        workflowId: 'example_txt2img',
        name: 'Slow and careful',
        values: <String, Object?>{
          'steps': 44,
          'guidance': 9.5,
          'sampler': 'dpmpp_2m',
        },
      );
      final applied = <String>[];
      final form = await given(tester, setup, applied);
      await type(tester, written);

      await apply(tester, setup);

      expect(find.byKey(LcKeys.applySetupConfirm), findsNothing);
      expect(applied, <String>['s-5']);
      expect(form.text('prompt'), written, reason: 'untouched, as promised');
      expect(form.text('steps'), '44');
      expect(form.text('guidance'), '9.5');
      expect(form.entry('sampler'), 'dpmpp_2m');
    });

    testWidgets('a value this workflow cannot hold is not a reason to ask',
        (tester) async {
      tallView(tester);
      // A number is not something a person typed, so applying would skip it
      // and the prose would survive anyway — asking would be a question about
      // nothing. This is the admission rule the form owns, seen from outside.
      const setup = WorkflowSetup(
        id: 's-6',
        workflowId: 'example_txt2img',
        name: 'Handmade',
        values: <String, Object?>{'prompt': 44, 'steps': 44},
      );
      final applied = <String>[];
      final form = await given(tester, setup, applied);
      await type(tester, written);

      await apply(tester, setup);

      expect(find.byKey(LcKeys.applySetupConfirm), findsNothing);
      expect(applied, <String>['s-6']);
      expect(form.text('prompt'), written);
      expect(form.text('steps'), '44');
    });
  });

  group('through the screen', () {
    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(460, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// The connected shell over the real stores.
    Future<(Widget, WorkflowsController, ScriptedJobsApi)> shell({
      bool keepsSetups = true,
    }) async {
      final workflows = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        keepsSetups: keepsSetups,
      );
      final jobs = ScriptedJobsApi(
        submission: const JobSubmission(
          jobId: 'j-8f21',
          state: JobState.completed,
        ),
      );
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);
      final generation = GenerationController(
        api: jobs,
        events: FakeJobEventSource(),
        pollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(generation.dispose);
      final session = testSession(
        connection: connection,
        workflows: workflows,
        generation: generation,
      );
      addTearDown(session.dispose);
      return (
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(session: session),
        ),
        workflows,
        jobs,
      );
    }

    Future<void> choose(WidgetTester tester) async {
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
    }

    Future<void> nameIt(WidgetTester tester, String name) async {
      await tester.enterText(find.byKey(LcKeys.setupNameField), name);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.setupNameConfirm));
      await tester.pumpAndSettle();
    }

    testWidgets('save, apply, rename and delete, all from the form',
        (tester) async {
      tallView(tester);
      final (widget, workflows, _) = await shell();
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();
      await choose(tester);
      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a lighthouse in a storm',
      );
      await tester.pumpAndSettle();

      // Save.
      await tester.ensureVisible(find.byKey(LcKeys.saveSetup));
      await tester.tap(find.byKey(LcKeys.saveSetup));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.setupName), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.setupNameConfirm)).onPressed,
        isNull,
        reason: 'a setup called nothing at all is a row nobody can tell apart',
      );
      await nameIt(tester, 'Night alley');

      expect(find.text('Saved as “Night alley”.'), findsOneWidget);
      final saved = workflows.setupsFor('example_txt2img').single;
      expect(find.byKey(LcKeys.setup(saved.id)), findsOneWidget);
      expect(find.text('Night alley'), findsOneWidget);

      // Apply, over a prompt that has since changed — which is words the user
      // wrote, so it is asked about before it goes, and taken only on a yes.
      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'something else',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(LcKeys.applySetup(saved.id)));
      await tester.tap(find.byKey(LcKeys.applySetup(saved.id)));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.applySetupConfirm), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.applySetupReplace));
      await tester.pumpAndSettle();
      expect(
        workflows.form!.text('prompt'),
        'a lighthouse in a storm',
      );

      // Rename, through the same dialog the save used.
      await tester.ensureVisible(find.byKey(LcKeys.renameSetup(saved.id)));
      await tester.tap(find.byKey(LcKeys.renameSetup(saved.id)));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.setupName), findsOneWidget);
      await nameIt(tester, 'Rainy alley');

      expect(find.text('Rainy alley'), findsOneWidget);
      expect(find.text('Night alley'), findsNothing);
      expect(
        find.byKey(LcKeys.setup(saved.id)),
        findsOneWidget,
        reason: 'the same setup, under another name',
      );

      // Delete, which asks first — and the answer that costs nothing keeps it.
      await tester.ensureVisible(find.byKey(LcKeys.deleteSetup(saved.id)));
      await tester.tap(find.byKey(LcKeys.deleteSetup(saved.id)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.deleteSetupKeep));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.setup(saved.id)), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.deleteSetup(saved.id)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.deleteSetupAccept));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.setup(saved.id)), findsNothing);
      expect(find.byKey(LcKeys.setups), findsNothing);
      expect(workflows.setupsFor('example_txt2img'), isEmpty);
      expect(await setupKeys(), isEmpty);

      // The draft this typing started is written now rather than left to a
      // wait the test would end in the middle of.
      await workflows.flushDrafts();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a build that keeps no setups draws nothing about them',
        (tester) async {
      tallView(tester);
      final (widget, _, _) = await shell(keepsSetups: false);
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();
      await choose(tester);

      // The same finders that find their targets in the test above.
      expect(find.byKey(LcKeys.saveSetup), findsNothing);
      expect(find.byKey(LcKeys.setups), findsNothing);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.byKey(LcKeys.saveMyDefaults), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a finished result offers to keep what produced it',
        (tester) async {
      tallView(tester);
      final (widget, workflows, _) = await shell();
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();
      await choose(tester);
      await tester.enterText(find.byKey(LcKeys.field('prompt')), kOriginal);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.resultSurface), findsOneWidget);
      await tester.ensureVisible(find.byKey(LcKeys.resultSaveSetup));
      await tester.tap(find.byKey(LcKeys.resultSaveSetup));
      await tester.pumpAndSettle();
      await nameIt(tester, 'That good one');

      final setup = workflows.setupsFor('example_txt2img').single;
      expect(setup.name, 'That good one');
      expect(setup.values['prompt'], kOriginal);

      await workflows.flushDrafts();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a build that keeps no setups offers nothing on a result '
        'either', (tester) async {
      tallView(tester);
      final (widget, workflows, _) = await shell(keepsSetups: false);
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();
      await choose(tester);
      await tester.enterText(find.byKey(LcKeys.field('prompt')), kOriginal);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      // The surface is there, and the affordance is not.
      expect(find.byKey(LcKeys.resultSurface), findsOneWidget);
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);
      expect(find.byKey(LcKeys.resultSaveSetup), findsNothing);

      await workflows.flushDrafts();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a setup saved while the prompt was empty cannot blank a '
        'written one behind the user`s back', (tester) async {
      tallView(tester);
      // T-0051's review probe, end to end through the real store: a setup
      // made from a form holding only `steps = 44`, applied over words
      // somebody is in the middle of writing.
      final (widget, workflows, _) = await shell();
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();
      await choose(tester);
      // The one setting of the probe. Set through the form rather than by
      // dragging its slider to a value: what this test is about is the empty
      // prompt beside it, and the taps that matter are below.
      workflows.form!.setEntry('steps', '44');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(LcKeys.saveSetup));
      await tester.tap(find.byKey(LcKeys.saveSetup));
      await tester.pumpAndSettle();
      await nameIt(tester, 'Just the steps');

      // The document really carries an empty prompt — read around the store,
      // so this is the sharp edge and not an assumption about it.
      expect((await setupDocuments()).single, contains('"prompt":""'));
      final saved = workflows.setupsFor('example_txt2img').single;
      expect(saved.values['prompt'], '');

      const String written = 'a half-written prompt I care about';
      await tester.ensureVisible(find.byKey(LcKeys.field('prompt')));
      await tester.enterText(find.byKey(LcKeys.field('prompt')), written);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(LcKeys.applySetup(saved.id)));
      await tester.tap(find.byKey(LcKeys.applySetup(saved.id)));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.applySetupConfirm), findsOneWidget);
      expect(find.text('Replace what you wrote?'), findsOneWidget);
      expect(
        find.text('“Just the steps” would take the place of the text you have '
            'written in this form.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(LcKeys.applySetupKeep));
      await tester.pumpAndSettle();
      expect(workflows.form!.text('prompt'), written);

      // And the user can still have what they asked for, by saying so.
      await tester.tap(find.byKey(LcKeys.applySetup(saved.id)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.applySetupReplace));
      await tester.pumpAndSettle();
      expect(workflows.form!.text('prompt'), '');

      await workflows.flushDrafts();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
