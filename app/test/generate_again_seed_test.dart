/// Generate Again varies the seed, Freeze seed holds it, and nothing else
/// moves either way (T-0124).
///
/// Four things are checked here, and the third is the one that would break
/// silently:
///
/// * a second run sends a **different** seed, and a third differs from the
///   second — "each time", not "once";
/// * with Freeze seed on it sends the **same** seed, asserted verbatim across
///   three submissions;
/// * everything other than the seed is **identical**, compared as whole maps
///   rather than field by field. A Generate Again that rebuilt the request
///   from the schema's defaults would vary the seed correctly and quietly
///   throw away the prompt, the picture and every setting the user chose, and
///   only a whole-map comparison over non-default values catches it;
/// * the seed on screen is the seed that was sent. Without that clause,
///   varying by default would destroy the one thing seeds are for.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/job_models.dart';
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

import 'support/l10n.dart';
import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Endpoint.tryParse('192.0.2.42')!;
  late ScriptedJobsApi jobs;
  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;
  late WorkflowsController workflows;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
  });

  /// Tall enough that the whole form is laid out, so a tap never has to
  /// scroll first.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(440, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The shell, connected, over the given workflows. The gateway answers every
  /// submission with a job that is already finished, so a test about what was
  /// *sent* inherits no clock and no socket.
  Future<Widget> shell(List<Map<String, Object?>> details) async {
    jobs = ScriptedJobsApi(
      submission: const JobSubmission(
        jobId: 'j-inert',
        state: JobState.completed,
      ),
    );
    workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(registryOf(details)),
        details: <String, WorkflowDetail>{
          for (final body in details)
            body['id']! as String: WorkflowDetail.tryFromJson(body)!,
        },
      ),
      mediaPicker: picker,
      mediaApi: uploads,
    );
    addTearDown(workflows.dispose);

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

    final session = testSession(
      connection: connection,
      workflows: workflows,
      jobs: jobs,
    );
    addTearDown(session.dispose);

    return MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: lcDarkTheme(),
      home: ConnectedShell(session: session),
    );
  }

  Future<void> choose(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard(id)));
    await tester.pumpAndSettle();
  }

  Future<void> openAdvanced(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.advancedToggle));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String fieldId, String value) async {
    await tester.enterText(find.byKey(LcKeys.field(fieldId)), value);
    await tester.pumpAndSettle();
  }

  /// Moves a slider off wherever it is. The value it lands on does not matter;
  /// that it is no longer the curator's does.
  Future<void> nudge(WidgetTester tester, String fieldId) async {
    await tester.drag(find.byKey(LcKeys.field(fieldId)), const Offset(60, 0));
    await tester.pumpAndSettle();
  }

  Future<void> pressGenerate(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.generate));
    await tester.pumpAndSettle();
  }

  Future<void> pressGenerateAgain(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.generateAgain));
    await tester.pumpAndSettle();
  }

  /// The text actually in the Seed box on screen.
  String seedOnScreen(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(LcKeys.field('seed')))
      .controller!
      .text;

  /// One submission's inputs, minus the seed: the part that must never move.
  Map<String, Object?> withoutSeed(Map<String, Object?> inputs) =>
      Map<String, Object?>.from(inputs)..remove('seed');

  List<int> seedsSent() => <int>[
    for (final inputs in jobs.submittedInputs) inputs['seed']! as int,
  ];

  group('Generate Again varies the seed', () {
    testWidgets('a second run and a third each send a new one', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await type(tester, 'prompt', 'a rainy alley at night');
      await openAdvanced(tester);

      // The curator's own seed, before anything has varied anything.
      expect(seedOnScreen(tester), '0');

      await pressGenerate(tester);
      await pressGenerateAgain(tester);
      await pressGenerate(tester);
      await pressGenerateAgain(tester);
      await pressGenerate(tester);

      final seeds = seedsSent();
      expect(seeds, hasLength(3));
      // The first is the field's own value, untouched.
      expect(seeds[0], 0);
      // And each Again is a new one -- not merely "not the first".
      expect(seeds[1], isNot(seeds[0]));
      expect(seeds[2], isNot(seeds[1]));
      expect(seeds[2], isNot(seeds[0]));
      for (final seed in seeds) {
        expect(seed, inInclusiveRange(0, 4294967295));
      }
    });

    testWidgets('the field shows the seed that was sent', (tester) async {
      // The clause that keeps a result reproducible. A seed that varied
      // without being reported would leave a picture nobody could get back.
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await type(tester, 'prompt', 'a rainy alley at night');
      await openAdvanced(tester);

      await pressGenerate(tester);
      await pressGenerateAgain(tester);

      // Before the second submission the new seed is already on screen: it is
      // in the field, where the user can read it and where Generate reads it.
      final shown = seedOnScreen(tester);
      expect(shown, isNot('0'));
      await pressGenerate(tester);

      expect(seedsSent().last.toString(), shown);
      await pressGenerateAgain(tester);
      expect(seedOnScreen(tester), isNot(shown));
    });

    testWidgets('the first Generate sends what the user typed', (tester) async {
      // Nothing varies before a generation has been asked for twice, so a
      // curated default -- or a number somebody entered by hand to reproduce
      // a picture -- still means what it says on a first run.
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await type(tester, 'prompt', 'a rainy alley at night');
      await openAdvanced(tester);
      await type(tester, 'seed', '271828');

      await pressGenerate(tester);

      expect(seedsSent(), <int>[271828]);
      expect(seedOnScreen(tester), '271828');
    });

    testWidgets('the seed varied is the one that made the result, not the one '
        'now selected', (tester) async {
      // Generate Again belongs to the result on screen. A user may change the
      // workflow while that result is still up -- the picker is right there
      // under it -- and the button must still vary the form the picture came
      // from, not whichever form happens to be in front of them. Reading the
      // selection instead would move a number in a workflow that generated
      // nothing, and leave the one that did untouched.
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
        withField(
          renamed(txt2imgDetail(), id: 'other_one', name: 'The Other One'),
          'seed',
          <String, Object?>{'default': 500},
        ),
      ]));
      await tester.pumpAndSettle();

      await choose(tester, 'example_txt2img');
      await type(tester, 'prompt', 'a rainy alley at night');
      await openAdvanced(tester);
      expect(seedOnScreen(tester), '0');
      await pressGenerate(tester);

      // The result is up, and the user changes workflow underneath it.
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('other_one')));
      await tester.pumpAndSettle();
      await openAdvanced(tester);
      expect(seedOnScreen(tester), '500');
      // Still the first workflow's result on screen, which is the whole point
      // of this arrangement.
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);

      await pressGenerateAgain(tester);

      // The workflow that generated nothing is untouched...
      expect(seedOnScreen(tester), '500');
      // ...and the one that made the result has a new seed waiting in it.
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      expect(seedOnScreen(tester), isNot('0'));
      expect(find.text('a rainy alley at night'), findsOneWidget);
    });
  });

  group('Freeze seed', () {
    testWidgets('off by default, and it says what Generate Again will do', (
      tester,
    ) async {
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await openAdvanced(tester);

      expect(find.byKey(LcKeys.freezeSeed('seed')), findsOneWidget);
      expect(
        tester.widget<Switch>(find.byKey(LcKeys.freezeSeed('seed'))).value,
        isFalse,
      );
      expect(find.text('Freeze seed'), findsOneWidget);
      expect(find.text('Generate Again uses a new seed.'), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.freezeSeed('seed')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Switch>(find.byKey(LcKeys.freezeSeed('seed'))).value,
        isTrue,
      );
      expect(find.text('Generate Again reuses this seed.'), findsOneWidget);
      expect(find.text('Generate Again uses a new seed.'), findsNothing);
    });

    testWidgets('on, the same seed goes out every time', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await type(tester, 'prompt', 'a rainy alley at night');
      await openAdvanced(tester);
      await type(tester, 'seed', '31337');
      await tester.tap(find.byKey(LcKeys.freezeSeed('seed')));
      await tester.pumpAndSettle();

      await pressGenerate(tester);
      await pressGenerateAgain(tester);
      await pressGenerate(tester);
      await pressGenerateAgain(tester);
      await pressGenerate(tester);

      expect(seedsSent(), <int>[31337, 31337, 31337]);
      expect(seedOnScreen(tester), '31337');
    });

    testWidgets('freezing after a run holds the seed that produced it', (
      tester,
    ) async {
      // The path the whole design exists for: a person likes what came back,
      // reads the seed off the field, and freezes it.
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await type(tester, 'prompt', 'a rainy alley at night');
      await openAdvanced(tester);

      await pressGenerate(tester);
      await pressGenerateAgain(tester);
      await pressGenerate(tester);
      final liked = seedsSent().last;
      expect(seedOnScreen(tester), liked.toString());

      await tester.tap(find.byKey(LcKeys.freezeSeed('seed')));
      await tester.pumpAndSettle();
      for (var again = 0; again < 3; again++) {
        await pressGenerateAgain(tester);
        await pressGenerate(tester);
      }

      // The two before the switch went on, then three that are the liked one
      // exactly.
      expect(seedsSent(), hasLength(5));
      expect(seedsSent().sublist(2), <int>[liked, liked, liked]);
      expect(seedOnScreen(tester), liked.toString());
    });

    testWidgets('a workflow with no seed has no switch', (tester) async {
      // Not a switch that does nothing: `role: seed` is what puts it there,
      // and a workflow that declared none is drawn exactly as it was before
      // any of this existed.
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');
      await openAdvanced(tester);

      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      expect(find.text('Freeze seed'), findsNothing);
      expect(find.byKey(LcKeys.freezeSeed('output_name')), findsNothing);
      expect(find.textContaining('Generate Again uses'), findsNothing);
    });

    testWidgets('freeze survives navigating away and back', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await openAdvanced(tester);
      await tester.tap(find.byKey(LcKeys.freezeSeed('seed')));
      await tester.pumpAndSettle();

      // Away to another workflow, and back.
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_img2img')));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.freezeSeed('seed')), findsNothing);

      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Switch>(find.byKey(LcKeys.freezeSeed('seed'))).value,
        isTrue,
        reason: 'coming back must not silently unfreeze it',
      );
      expect(find.text('Generate Again reuses this seed.'), findsOneWidget);
    });
  });

  group('everything other than the seed', () {
    testWidgets('is identical between Generate and Generate Again', (
      tester,
    ) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[
        tempSelection(name: 'IMG_0142.jpg', contents: realPng),
      ];
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        allTypesDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'all_types');

      // Every type the schema has, all of them moved off what the registry
      // declared -- so a request rebuilt from the defaults cannot come out
      // looking the same.
      await type(tester, 'title', 'A harbour at dawn');
      await type(tester, 'prompt', 'кот в шляпе на мокрой улице');
      await nudge(tester, 'steps');
      await nudge(tester, 'strength');
      await tester.tap(find.byKey(LcKeys.field('loop')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DPM++ 2M'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();
      await openAdvanced(tester);

      await pressGenerate(tester);
      final first = jobs.submittedInputs.single;

      // The fixture is not making the assertion true by itself: what was sent
      // really is the user's work and really is not the schema's defaults.
      expect(first['title'], 'A harbour at dawn');
      expect(first['prompt'], 'кот в шляпе на мокрой улице');
      expect(first['steps'], isNot(20));
      expect(first['strength'], isNot(0.55));
      expect(first['loop'], isFalse);
      expect(first['sampler'], 'dpmpp_2m');
      expect(first['source_image'], <String, Object?>{
        'media_id': 'm-3f9c1a-1',
      });
      // An optional media field nobody filled stays out of the map.
      expect(first.containsKey('source_clip'), isFalse);

      await pressGenerateAgain(tester);
      await pressGenerate(tester);
      final second = jobs.submittedInputs.last;

      // Verbatim, as whole maps: the same keys, the same values, nothing
      // added and nothing dropped.
      expect(withoutSeed(second), withoutSeed(first));
      expect(second['seed'], isNot(first['seed']));
      // And the picture was not sent up a second time to get there.
      expect(uploads.calls, 1);
    });

    testWidgets('a workflow with no seed resubmits everything unchanged', (
      tester,
    ) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[
        tempSelection(name: 'IMG_0142.jpg', contents: realPng),
      ];
      await tester.pumpWidget(await shell(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');
      await type(tester, 'prompt', 'the same scene at golden hour');
      await nudge(tester, 'strength');
      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();
      await openAdvanced(tester);
      await type(tester, 'output_name', 'Harbour');

      await pressGenerate(tester);
      await pressGenerateAgain(tester);
      await pressGenerate(tester);

      final first = jobs.submittedInputs.first;
      final second = jobs.submittedInputs.last;
      expect(jobs.submittedInputs, hasLength(2));
      // The whole map this time, seed included -- there is no seed to leave
      // out, and this workflow behaves exactly as it did before the card.
      expect(second, first);
      expect(first.containsKey('seed'), isFalse);
      expect(first['prompt'], 'the same scene at golden hour');
      expect(first['output_name'], 'Harbour');
      expect(first['strength'], isNot(0.55));
      expect(first['source_image'], <String, Object?>{
        'media_id': 'm-3f9c1a-1',
      });
    });
  });

  group('the frozen seed is kept with the draft', () {
    /// A registry with the real draft store behind it. Calling it twice is the
    /// app being opened twice on the same device.
    Future<WorkflowsController> opened() async {
      final controller = WorkflowsController(
        api: ScriptedWorkflowsApi(
          summaries: WorkflowSummary.listFromJson(
            registryOf(<Map<String, Object?>>[txt2imgDetail()]),
          ),
          details: <String, WorkflowDetail>{
            'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
          },
        ),
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
      );
      addTearDown(controller.dispose);
      await controller.load(endpoint);
      await controller.select('example_txt2img');
      return controller;
    }

    Future<Map<String, Object?>> preferences() =>
        SharedPreferencesAsync().getAll();

    test('it comes back after the app was killed', () async {
      final first = await opened();
      first.form!.freezeSeed = true;
      first.form!.setEntry('prompt', 'a lighthouse in a storm');
      await first.flushDrafts();

      final next = await opened();

      expect(next.form!.freezeSeed, isTrue);
      // Beside the rest of the draft, not instead of it.
      expect(next.form!.text('prompt'), 'a lighthouse in a storm');
    });

    test('unfrozen is stored as nothing at all', () async {
      // The same rule the translation override follows: there is one
      // representation of "nothing was said", so unfreezing leaves nothing
      // behind that could freeze it again.
      final first = await opened();
      first.form!.freezeSeed = true;
      await first.flushDrafts();
      expect(
        (await preferences()).keys,
        contains('localcanvas.draft.example_txt2img#seed-frozen'),
        reason: 'it must be written before its absence means anything',
      );

      first.form!.freezeSeed = false;
      await first.flushDrafts();

      expect(
        (await preferences()).keys,
        isNot(contains('localcanvas.draft.example_txt2img#seed-frozen')),
      );
      expect((await opened()).form!.freezeSeed, isFalse);
    });

    test('the key is this workflow\'s and cannot be read as a field', () async {
      final first = await opened();
      first.form!.freezeSeed = true;
      await first.flushDrafts();

      final draft = await PreferencesWorkflowDraftStore().load(
        'example_txt2img',
      );
      expect(draft.freezeSeed, isTrue);
      // It is not swept up as a value of some field called `#seed-frozen`.
      expect(draft.values.keys, isNot(contains('#seed-frozen')));
      for (final key in draft.values.keys) {
        expect(key, isNot(contains('#')));
      }
    });
  });

  group('the form on its own', () {
    WorkflowFormController formOf(Map<String, Object?> body) {
      final form = WorkflowFormController(WorkflowDetail.tryFromJson(body)!);
      addTearDown(form.dispose);
      return form;
    }

    test('varySeed moves the seed and nothing else', () {
      final form = formOf(txt2imgDetail())
        ..setEntry('prompt', 'a lighthouse in a storm')
        ..setEntry('negative_prompt', 'blurry')
        ..setEntry('steps', '44')
        ..setEntry('guidance', '12.5')
        ..setEntry('sampler', 'dpmpp_2m')
        ..setEntry('width', '1024');
      final before = form.validate().inputs;

      form.varySeed();
      final after = form.validate().inputs;

      expect(
        Map<String, Object?>.from(after)..remove('seed'),
        Map<String, Object?>.from(before)..remove('seed'),
      );
      expect(after['seed'], isNot(before['seed']));
    });

    test('a frozen form varies nothing', () {
      final form = formOf(txt2imgDetail())..freezeSeed = true;
      final before = form.validate().inputs;

      form
        ..varySeed()
        ..varySeed();

      expect(form.validate().inputs, before);
    });

    test('a workflow with no seed field is left entirely alone', () {
      final form = formOf(img2imgDetail())
        ..setEntry('prompt', 'a harbour at dawn')
        ..setEntry('output_name', 'Harbour');
      final before = form.validate().inputs;

      form.varySeed();

      expect(form.hasSeedField, isFalse);
      expect(form.validate().inputs, before);
    });

    test('neither Reset touches the freeze', () {
      // "Reset settings" is about values, and a freeze is not one: it is a
      // choice about what a button means. Silently unfreezing here would take
      // the reproducibility this card exists to protect away from someone who
      // only wanted an unrelated slider back — and the line two above it in
      // that method does reset the translation policy, so the asymmetry is
      // deliberate and has to be held by something.
      final form = formOf(txt2imgDetail())
        ..adoptMyDefaults(<String, Object?>{'steps': 44})
        ..setEntry('seed', '271828')
        ..setEntry('steps', '7')
        ..freezeSeed = true;

      form.resetSettingsToWorkflowDefaults();

      // The reset really ran: the seed is the curator's again, and so is the
      // slider beside it.
      expect(form.text('seed'), '0');
      expect(form.text('steps'), '20');
      expect(form.freezeSeed, isTrue);

      form
        ..setEntry('seed', '314159')
        ..resetSettingsToMyDefaults();

      expect(form.text('seed'), '0');
      expect(form.text('steps'), '44', reason: 'this one went back to mine');
      expect(form.freezeSeed, isTrue);

      // And the flag is still in force, not merely still set: what the user
      // froze is what the next Generate Again reuses.
      form.varySeed();
      expect(form.text('seed'), '0');
    });

    test('every declared seed is varied, not only the first', () {
      // A workflow may declare two. Leaving one of them behind would make
      // Generate Again half a repeat, which is neither of the two things the
      // switch promises.
      final body = <String, Object?>{
        ...txt2imgDetail(),
        'inputs': <Object?>[
          ...txt2imgDetail()['inputs']! as List<Object?>,
          <String, Object?>{
            'id': 'refiner_seed',
            'label': 'Refiner seed',
            'type': 'integer',
            'required': false,
            'section': 'advanced',
            'default': 7,
            'min': 0,
            'max': 4294967295,
            'role': 'seed',
          },
        ],
      };
      final form = formOf(body);
      expect(form.seedFields.map((f) => f.id), <String>['seed', 'refiner_seed']);

      form.varySeed();

      expect(form.text('seed'), isNot('0'));
      expect(form.text('refiner_seed'), isNot('7'));
    });

    test('the seed the user is looking at is not rolled again', () {
      // Over a range of two, where a plain draw returns the current value
      // half the time. A Generate Again that reproduced the same picture
      // would read as a broken button.
      final field = WorkflowDetail.tryFromJson(
        withField(txt2imgDetail(), 'seed', <String, Object?>{
          'min': 0,
          'max': 1,
          'default': 0,
        }),
      )!.inputs.firstWhere((f) => f.id == 'seed');

      final random = math.Random(20260909);
      for (var draw = 0; draw < 200; draw++) {
        expect(randomSeedValue(field, avoid: 0, random: random), 1);
        expect(randomSeedValue(field, avoid: 1, random: random), 0);
      }
    });

    test('a rolled seed stays inside the declared range', () {
      final field = WorkflowDetail.tryFromJson(
        withField(txt2imgDetail(), 'seed', <String, Object?>{
          'min': 100,
          'max': 140,
        }),
      )!.inputs.firstWhere((f) => f.id == 'seed');

      final random = math.Random(20260909);
      for (var draw = 0; draw < 500; draw++) {
        final value = randomSeedValue(field, avoid: 120, random: random);
        expect(value, inInclusiveRange(100, 140));
        expect(value, isNot(120));
      }
    });
  });
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
