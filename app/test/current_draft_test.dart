/// The current draft, from the store to the form the shell shows.
///
/// The store here is the real `PreferencesWorkflowDraftStore` over the
/// package's own in-memory platform, beside the real settings store, and the
/// workflows arrive as the wire bodies in `support/workflow_payloads.dart`.
/// Nothing in between is faked, so "the app was killed and opened again" is
/// two `opened()` calls: new controllers, the same preferences.
///
/// Two rules run through everything below:
///
/// * what is written down is the **original** text — what the user typed —
///   and never the effective text a translated submission was bound with;
/// * a reference to an uploaded file is never written down at all.
library;

import 'support/l10n.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/app.dart';
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
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
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
/// like the original, so a draft holding the wrong one cannot pass by
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

/// A PC that really translates. The state in which the override is on screen.
GatewayCapabilities translatingPc() =>
    GatewayCapabilities.fromJson(<String, Object?>{
      'translation': <String, Object?>{
        'enabled': true,
        'installed': true,
        'pairs': <Object?>[
          <String, Object?>{'source': 'ru', 'target': 'en'},
        ],
      },
    });

/// A clock the test moves by hand, in place of the autosave's real one.
class ManualClock {
  /// Every wait that was asked for, in order.
  final List<Duration> requested = <Duration>[];

  int cancels = 0;
  _ManualTimer? _pending;

  Timer schedule(Duration delay, void Function() onFire) {
    requested.add(delay);
    return _pending = _ManualTimer(this, onFire);
  }

  bool get isWaiting => _pending?.isActive ?? false;

  /// Lets the wait expire, as real time would have.
  void elapse() {
    final timer = _pending;
    if (timer == null || !timer.isActive) {
      fail('nothing was waiting to be written');
    }
    _pending = null;
    timer.fire();
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this._clock, this._onFire);

  final ManualClock _clock;
  final void Function() _onFire;
  bool _active = true;

  void fire() {
    _active = false;
    _onFire();
  }

  @override
  void cancel() {
    if (!_active) return;
    _active = false;
    _clock.cancels++;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A draft store that counts, for the tests about *when* a write happens.
class RecordingDraftStore implements WorkflowDraftStore {
  final Map<String, WorkflowDraft> stored = <String, WorkflowDraft>{};
  final Map<String, Set<String>> scopes = <String, Set<String>>{};
  final List<String> writes = <String>[];

  @override
  Future<WorkflowDraft> load(String workflowId) async =>
      stored[workflowId] ?? const WorkflowDraft();

  @override
  Future<void> save(
    String workflowId,
    WorkflowDraft draft, {
    required Set<String> draftableFields,
  }) async {
    writes.add(workflowId);
    stored[workflowId] = draft;
    scopes[workflowId] = draftableFields;
  }
}

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

  Future<List<String>> draftKeys() async => <String>[
    for (final key in (await preferences()).keys)
      if (key.startsWith('localcanvas.draft.')) key,
  ]..sort();

  /// A registry, connected, with the real stores behind it. Calling this twice
  /// in one test is the app being opened twice on the same device.
  Future<WorkflowsController> opened(
    List<Map<String, Object?>> details, {
    bool keepsDrafts = true,
    bool withMedia = false,
    WorkflowDraftStore? draftStore,
    ManualClock? clock,
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
      drafts: keepsDrafts
          ? (draftStore ?? PreferencesWorkflowDraftStore())
          : null,
      draftTimerFactory: clock == null ? Timer.new : clock.schedule,
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

  group('what comes back after the app was killed', () {
    test('the prompt is there, under the same workflow', () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img'))
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('negative_prompt', 'blurry')
        ..setEntry('steps', '44');
      await first.flushDrafts();

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('negative_prompt'), 'blurry');
      expect(form.text('steps'), '44');
      // And what was never touched is still the curator's.
      expect(form.text('width'), '768');
    });

    test('a prompt the user emptied stays empty', () async {
      // The other half of the same promise: a draft is the *current* state,
      // so a field the user cleared may not be filled again from beneath.
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final firstForm = await formOf(first, 'example_txt2img');
      firstForm.setEntry('prompt', 'a lighthouse in a storm');
      await first.flushDrafts();
      firstForm.setEntry('prompt', '');
      await first.flushDrafts();

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect((await formOf(next, 'example_txt2img')).text('prompt'), '');
    });

    test('a draft is per workflow and never leaks between two', () async {
      // Both workflows declare a field whose logical id is `prompt` and one
      // called `steps`: the case a key that was not per workflow would pass.
      final registry = <Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ];
      final first = await opened(registry);
      (await formOf(first, 'example_txt2img'))
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('steps', '44');
      (await formOf(first, 'all_types'))
        ..setEntry('prompt', 'a harbour at dawn')
        ..setEntry('steps', '8');
      await first.flushDrafts();

      final next = await opened(registry);
      final txt2img = await formOf(next, 'example_txt2img');
      final allTypes = await formOf(next, 'all_types');

      expect(txt2img.text('prompt'), 'a lighthouse in a storm');
      expect(txt2img.text('steps'), '44');
      expect(allTypes.text('prompt'), 'a harbour at dawn');
      expect(allTypes.text('steps'), '8');
    });

    test('a workflow nobody drafted anything for is untouched beside one that '
        'was', () async {
      final registry = <Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ];
      final first = await opened(registry);
      (await formOf(first, 'example_txt2img')).setEntry('prompt', 'a harbour');
      await first.flushDrafts();

      final next = await opened(registry);
      final untouched = await formOf(next, 'all_types');

      expect(untouched.text('prompt'), '');
      expect(untouched.text('steps'), '20');
    });
  });

  group('the layering is workflow, then mine, then the draft', () {
    test('a field all three disagree about takes the draft', () async {
      // `steps`: the curator says 20, the user saved 44, and 7 is what was in
      // the field when the app died. A wrong order produces 44 or 20 here,
      // not 7, so this cannot pass by accident.
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final firstForm = await formOf(first, 'example_txt2img');
      firstForm
        ..setEntry('steps', '44')
        ..setEntry('sampler', 'dpmpp_2m');
      await first.saveMyDefaults();
      firstForm.setEntry('steps', '7');
      await first.flushDrafts();

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.text('steps'), '7', reason: 'the draft is the top layer');
      expect(
        form.entry('sampler'),
        'dpmpp_2m',
        reason: 'a field the draft agrees about is still what was saved',
      );
      expect(
        form.text('width'),
        '768',
        reason: 'and a field neither of them touched is the curator`s',
      );
      // The three layers really are three different values.
      expect(form.hasMyDefaults, isTrue);
      form.resetSettingsToMyDefaults();
      expect(form.text('steps'), '44');
      form.resetSettingsToWorkflowDefaults();
      expect(form.text('steps'), '20');
    });

    test('a field the draft has no value for keeps the layer beneath',
        () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final firstForm = await formOf(first, 'example_txt2img');
      firstForm.setEntry('steps', '44');
      await first.saveMyDefaults();
      // The draft is written from a workflow whose `steps` field did not
      // exist then, so the stored draft carries no value for it.
      final store = PreferencesWorkflowDraftStore();
      await store.save(
        'example_txt2img',
        const WorkflowDraft(
          values: <String, Object?>{'prompt': 'a lighthouse in a storm'},
        ),
        draftableFields: <String>{'prompt'},
      );

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.text('prompt'), 'a lighthouse in a storm');
      expect(form.text('steps'), '44', reason: 'My defaults, unchallenged');
      expect(form.text('width'), '768');
    });

    test('a draft is not one of My defaults and does not become one',
        () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img')).setEntry('steps', '7');
      await first.flushDrafts();

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(next, 'example_txt2img');

      expect(form.text('steps'), '7');
      expect(
        form.hasMyDefaults,
        isFalse,
        reason: 'nobody pressed Save; there is nothing to go back to',
      );
      expect(
        (await preferences()).keys.where(
          (key) => key.startsWith('localcanvas.defaults.'),
        ),
        isEmpty,
      );

      // And the reset goes back to the curator's value, not to the draft.
      form.resetSettingsToMyDefaults();
      expect(form.text('steps'), '20');
      // …which the draft then follows, because a draft is what is on screen.
      await next.flushDrafts();
      expect(
        (await preferences())['localcanvas.draft.example_txt2img.steps'],
        20,
      );
    });

    test('a workflow with no draft is the form it has always been', () async {
      // Against the two code paths that existed before this card: the form
      // built with no stores at all, and the app composed with a settings
      // store and no draft store.
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img')).setEntry('steps', '44');
      await first.saveMyDefaults();

      final asBefore = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        keepsDrafts: false,
      );
      final before = await formOf(asBefore, 'example_txt2img');
      final now = await formOf(
        await opened(<Map<String, Object?>>[txt2imgDetail()]),
        'example_txt2img',
      );

      for (final field in now.detail.inputs) {
        expect(now.entry(field.id), before.entry(field.id), reason: field.id);
      }
      expect(now.translatePrompt, before.translatePrompt);
      expect(now.hasMyDefaults, before.hasMyDefaults);

      // And against the registry's own words, so two paths broken the same
      // way could not agree their way past this.
      final bare = WorkflowFormController(
        WorkflowDetail.tryFromJson(txt2imgDetail())!,
      );
      addTearDown(bare.dispose);
      expect(now.text('width'), bare.text('width'));
      expect(now.text('prompt'), '');
      expect(now.text('steps'), '44');
      expect(now.entry('sampler'), 'euler');
      expect(now.translatePrompt, isTrue);
      expect(await draftKeys(), isEmpty);
    });
  });

  group('a workflow whose fields changed under a draft', () {
    test('a value that no longer fits the schema falls to the layer beneath',
        () async {
      // 25 was saved as a default, 48 was in the field when the app died, and
      // the curator has since capped the range at 30. Three distinct numbers,
      // so "the layer beneath" is provably not "the workflow default".
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.defaults.example_txt2img.steps': 25,
            'localcanvas.draft.example_txt2img.steps': 48,
          });

      final app = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'steps', <String, Object?>{'max': 30}),
      ]);
      final form = await formOf(app, 'example_txt2img');

      expect(form.text('steps'), '25');
      expect(
        form.validate().issueFor('steps'),
        isNull,
        reason: 'a form is never loaded with a value it cannot validate',
      );
    });

    test('a drafted choice the workflow no longer offers is discarded',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.draft.example_txt2img.sampler': 'dpmpp_2m',
            'localcanvas.draft.example_txt2img.prompt': 'a lighthouse',
          });

      final app = await opened(<Map<String, Object?>>[
        withField(txt2imgDetail(), 'sampler', <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'value': 'euler', 'label': 'Euler'},
          ],
        }),
      ]);
      final form = await formOf(app, 'example_txt2img');

      expect(form.entry('sampler'), 'euler');
      expect(form.validate().issueFor('sampler'), isNull);
      expect(
        form.text('prompt'),
        'a lighthouse',
        reason: 'one illegal value does not cost the user the rest',
      );
    });

    test('a drafted value of the wrong kind is discarded', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.draft.example_txt2img.steps': 'many',
            'localcanvas.draft.example_txt2img.sampler': 7,
            'localcanvas.draft.example_txt2img.guidance': true,
            // Prose is checked too: a number is not something a person typed.
            'localcanvas.draft.example_txt2img.prompt': 44,
          });

      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');

      expect(form.text('steps'), '20');
      expect(form.entry('sampler'), 'euler');
      expect(form.text('guidance'), '6');
      expect(form.text('prompt'), '');
    });

    test('a field the workflow no longer declares is ignored, without error',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.draft.example_txt2img.sampler': 'dpmpp_2m',
            'localcanvas.draft.example_txt2img.prompt': 'a lighthouse',
          });

      final app = await opened(<Map<String, Object?>>[
        withoutField(txt2imgDetail(), 'sampler'),
      ]);
      final form = await formOf(app, 'example_txt2img');

      expect(form.text('prompt'), 'a lighthouse');
      expect(form.entry('sampler'), isNull);
      expect(form.validate().inputs.containsKey('sampler'), isFalse);
      // Kept in the store: the field may come back with the next sync.
      expect(
        (await preferences())['localcanvas.draft.example_txt2img.sampler'],
        'dpmpp_2m',
      );
    });
  });

  group('nothing about a picture is written down', () {
    test('a form with an uploaded image drafts the prompt and not the media',
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
      // The reference really is in the form, and really would be sent — so
      // the assertions below are about what the store refused, not about a
      // value that was never there.
      expect(form.validate().inputs['source_image'], <String, Object?>{
        'media_id': mediaId,
      });

      await app.flushDrafts();

      final written = jsonEncode(await preferences());
      expect(written, isNot(contains(mediaId)));
      expect(written, isNot(contains('IMG_0142')));
      expect(await draftKeys(), <String>[
        'localcanvas.draft.example_img2img.output_name',
        'localcanvas.draft.example_img2img.prompt',
        'localcanvas.draft.example_img2img.strength',
      ]);
      // The prompt and the settings did come back, which is the trade being
      // made here.
      expect(
        (await preferences())['localcanvas.draft.example_img2img.prompt'],
        'a lighthouse in a storm',
      );
    });

    test('the form itself offers no media field to a draft', () {
      // The first of the two guards, on its own: the store is not involved.
      final form = WorkflowFormController(
        WorkflowDetail.tryFromJson(allTypesDetail())!,
      );
      addTearDown(form.dispose);

      expect(form.draftableFieldIds, isNot(contains('source_image')));
      expect(form.draftableFieldIds, isNot(contains('source_clip')));
      expect(form.currentDraft().values.keys, isNot(contains('source_image')));
      expect(form.currentDraft().values.keys, contains('prompt'));
    });

    test('a media id someone wrote into the preferences never reaches a field',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.draft.example_img2img.source_image': 'm-3f9c1a',
            'localcanvas.draft.example_img2img.prompt': 'a lighthouse',
          });

      final app = await opened(
        <Map<String, Object?>>[img2imgDetail()],
        withMedia: true,
      );
      final form = await formOf(app, 'example_img2img');

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

  group('the original, never the effective text', () {
    test('a submission that really translated leaves the user`s own words in '
        'the draft', () async {
      final app = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(app, 'example_txt2img');
      form.setEntry('prompt', kOriginal);

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

      await app.flushDrafts();

      expect(
        (await preferences())['localcanvas.draft.example_txt2img.prompt'],
        kOriginal,
      );
      final written = jsonEncode(await preferences());
      expect(
        written,
        isNot(contains(kEffective)),
        reason: 'a draft that stored the translation would replace what the '
            'user wrote with what the machine made of it',
      );
      expect(written, isNot(contains('a cat')));

      // And the next launch gives back what was typed, character for
      // character.
      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect((await formOf(next, 'example_txt2img')).text('prompt'), kOriginal);
    });
  });

  group('the translation override', () {
    test('switched off, it is still off after a restart', () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final firstForm = await formOf(first, 'example_txt2img');
      expect(firstForm.translatePrompt, isTrue);
      firstForm.translatePrompt = false;
      await first.flushDrafts();

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect((await formOf(next, 'example_txt2img')).translatePrompt, isFalse);
    });

    test('switching it back on is remembered too', () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img')).translatePrompt = false;
      await first.flushDrafts();

      final second = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(second, 'example_txt2img');
      expect(form.translatePrompt, isFalse);
      form.translatePrompt = true;
      await second.flushDrafts();

      final third = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect((await formOf(third, 'example_txt2img')).translatePrompt, isTrue);
    });

    test('it belongs to one workflow, like everything else in a draft',
        () async {
      final registry = <Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ];
      final first = await opened(registry);
      (await formOf(first, 'example_txt2img')).translatePrompt = false;
      await first.flushDrafts();

      final next = await opened(registry);
      expect((await formOf(next, 'example_txt2img')).translatePrompt, isFalse);
      expect((await formOf(next, 'all_types')).translatePrompt, isTrue);
    });
  });

  group('when the draft is written', () {
    /// The controller, with a workflow already chosen and its form ready.
    Future<(WorkflowsController, WorkflowFormController, RecordingDraftStore)>
    watched(ManualClock clock) async {
      final store = RecordingDraftStore();
      final controller = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        draftStore: store,
        clock: clock,
      );
      final form = await formOf(controller, 'example_txt2img');
      return (controller, form, store);
    }

    test('typing does not write on every keystroke', () async {
      final clock = ManualClock();
      final (controller, form, store) = await watched(clock);

      form.setEntry('prompt', 'a');
      form.setEntry('prompt', 'a l');
      form.setEntry('prompt', 'a lighthouse');

      expect(
        store.writes,
        isEmpty,
        reason: 'three changes, and the wait has not run out once',
      );
      expect(
        clock.requested,
        <Duration>[kDraftDebounce, kDraftDebounce, kDraftDebounce],
      );
      expect(
        clock.cancels,
        2,
        reason: 'each change puts the wait back to the start',
      );

      clock.elapse();
      await pumpEventQueue();

      // And the mechanism really is live: one write, of the last thing typed.
      expect(store.writes, <String>['example_txt2img']);
      expect(store.stored['example_txt2img']!.values['prompt'], 'a lighthouse');
      expect(clock.isWaiting, isFalse);
      await controller.flushDrafts();
      expect(store.writes, hasLength(1), reason: 'nothing was left waiting');
    });

    test('a workflow merely opened writes nothing at all', () async {
      // The layering notifies the form as it builds it. None of that is
      // something the user did, and writing it down would freeze the
      // curator's own defaults into a draft nobody made.
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(first, 'example_txt2img')).setEntry('steps', '44');
      await first.saveMyDefaults();
      final beforeOpening = await draftKeys();

      final clock = ManualClock();
      final store = RecordingDraftStore();
      final next = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        draftStore: store,
        clock: clock,
      );
      final form = await formOf(next, 'example_txt2img');

      expect(store.writes, isEmpty);
      expect(clock.isWaiting, isFalse);
      expect(beforeOpening, isEmpty);

      // And a single thing the user does starts it, so the emptiness above is
      // not a listener that was never attached.
      form.setEntry('steps', '7');
      expect(clock.isWaiting, isTrue);
      clock.elapse();
      await pumpEventQueue();
      expect(store.writes, <String>['example_txt2img']);
    });

    test('two drafts waiting are both written, each under its own workflow',
        () async {
      final clock = ManualClock();
      final store = RecordingDraftStore();
      final controller = await opened(
        <Map<String, Object?>>[txt2imgDetail(), allTypesDetail()],
        draftStore: store,
        clock: clock,
      );
      (await formOf(controller, 'example_txt2img'))
          .setEntry('prompt', 'a lighthouse');
      (await formOf(controller, 'all_types')).setEntry('prompt', 'a harbour');

      clock.elapse();
      await pumpEventQueue();

      expect(store.writes, hasLength(2));
      expect(store.stored['example_txt2img']!.values['prompt'], 'a lighthouse');
      expect(store.stored['all_types']!.values['prompt'], 'a harbour');
    });

    test('the scope of a write is the fields a draft covers', () async {
      final clock = ManualClock();
      final (_, form, store) = await watched(clock);

      form.setEntry('prompt', 'a lighthouse');
      clock.elapse();
      await pumpEventQueue();

      expect(store.scopes['example_txt2img'], form.draftableFieldIds);
      expect(store.scopes['example_txt2img'], contains('prompt'));
      expect(store.scopes['example_txt2img'], contains('steps'));
    });

    test('writing twice leaves one draft, not a history', () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(first, 'example_txt2img');
      form.setEntry('prompt', 'a lighthouse');
      await first.flushDrafts();
      final afterOne = await draftKeys();

      form.setEntry('prompt', 'a harbour');
      await first.flushDrafts();
      form.setEntry('prompt', 'a lightship');
      await first.flushDrafts();

      expect(await draftKeys(), afterOne);
      expect(
        (await preferences())['localcanvas.draft.example_txt2img.prompt'],
        'a lightship',
      );
      final written = jsonEncode(await preferences());
      expect(written, isNot(contains('a lighthouse')));
      expect(written, isNot(contains('a harbour')));
    });
  });

  group('leaving the foreground writes what is waiting', () {
    /// The whole app, so the lifecycle callback is the real one.
    Future<(WorkflowsController, RecordingDraftStore, ManualClock)> app(
      WidgetTester tester,
    ) async {
      final clock = ManualClock();
      final store = RecordingDraftStore();
      final workflows = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        draftStore: store,
        clock: clock,
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
      final session = testSession(
        connection: connection,
        workflows: workflows,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        LocalCanvasApp(
          session: session,
          appearance: testAppearance(),
          language: testLanguage(),
        ),
      );
      await tester.pump();
      return (workflows, store, clock);
    }

    testWidgets('a draft still waiting out its debounce is written',
        (tester) async {
      final (workflows, store, clock) = await app(tester);
      final form = await formOf(workflows, 'example_txt2img');
      form.setEntry('prompt', 'a lighthouse in a storm');

      expect(store.writes, isEmpty, reason: 'the wait is not over');
      expect(clock.isWaiting, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      expect(store.writes, <String>['example_txt2img']);
      expect(
        store.stored['example_txt2img']!.values['prompt'],
        'a lighthouse in a storm',
      );
      expect(
        clock.isWaiting,
        isFalse,
        reason: 'and the wait was called off, so coming back does not write '
            'the same draft again',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('coming back to the front writes nothing', (tester) async {
      final (workflows, store, clock) = await app(tester);
      // With a change genuinely waiting, so this is the debounce still being
      // in charge rather than there being nothing to write. The condition
      // under which a write *could* happen has to exist, or the assertion
      // below is true forever whatever the callback does.
      (await formOf(workflows, 'example_txt2img'))
          .setEntry('prompt', 'a lighthouse in a storm');
      expect(clock.isWaiting, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(store.writes, isEmpty);
      expect(clock.isWaiting, isTrue, reason: 'the wait is still running');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('a remembered override never claims the app can translate', () {
    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// A connected shell over a draft that has the override switched off.
    Future<(Widget, ScriptedJobsApi, WorkflowsController)> shellWith(
      GatewayCapabilities capabilities,
    ) async {
      await PreferencesWorkflowDraftStore().save(
        'example_txt2img',
        const WorkflowDraft(
          values: <String, Object?>{'prompt': kOriginal},
          translatePrompt: false,
        ),
        draftableFields: <String>{'prompt'},
      );
      final workflows = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await workflows.select('example_txt2img');

      final jobs = ScriptedJobsApi(
        submission: JobSubmission.tryFromJson(translatedBody())!,
      );
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity(capabilities: capabilities)),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);
      final generation = GenerationController(api: jobs);
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
      supportedLocales: testLocales,theme: lcDarkTheme(), home: ConnectedShell(session: session)),
        jobs,
        workflows,
      );
    }

    testWidgets('a PC that says nothing about translation shows nothing, and '
        'the remembered choice still governs the submission', (tester) async {
      tallView(tester);
      // A gateway older than the feature: `capabilities` carries no
      // translation block at all.
      final (shell, jobs, workflows) = await shellWith(
        const GatewayCapabilities(),
      );
      await tester.pumpWidget(shell);
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.translationNotice('prompt')), findsNothing);
      expect(find.byKey(LcKeys.translationOverride('prompt')), findsNothing);
      expect(
        workflows.form!.translatePrompt,
        isFalse,
        reason: 'the remembered refusal is still the session`s answer',
      );

      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      expect(jobs.submittedTranslate, <bool>[false]);
      expect(jobs.submittedInputs.single['prompt'], kOriginal);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a PC that does translate shows the switch, off, as it was '
        'left', (tester) async {
      tallView(tester);
      final (shell, _, _) = await shellWith(translatingPc());
      await tester.pumpWidget(shell);
      await tester.pumpAndSettle();

      // The same finders as the test above, here finding what they look for —
      // so that absence there is about the PC, not about a broken finder.
      expect(find.byKey(LcKeys.translationNotice('prompt')), findsOneWidget);
      final override = find.byKey(LcKeys.translationOverride('prompt'));
      expect(override, findsOneWidget);
      expect(tester.widget<Switch>(override).value, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
