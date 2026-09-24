/// The form inside the shell: controls, Advanced, Generate, and the state that
/// has to survive a fold and a trip to the picker (`docs/ui-ux.md`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/ui/workflows/field_controls.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/l10n.dart';
import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  late ScriptedWorkflowsApi registry;
  late WorkflowsController workflows;

  /// What `POST /api/v1/jobs` was actually given, once Generate is pressed.
  late ScriptedJobsApi jobs;

  /// Tall enough that the whole form is laid out and tappable.
  void tallView(WidgetTester tester, {double width = 420, double height = 2400}) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  ConnectionController connection() {
    final controller = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(e, testIdentity()),
      ),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// A shell connected to a server publishing [details].
  Future<Widget> shellFor(
    List<Map<String, Object?>> details, {
    WorkflowsFailure? listFailure,
    WorkflowSettingsStore? settings,
  }) async {
    registry = ScriptedWorkflowsApi(
      summaries: WorkflowSummary.listFromJson(registryOf(details)),
      details: <String, WorkflowDetail>{
        for (final body in details)
          body['id']! as String: WorkflowDetail.tryFromJson(body)!,
      },
      listFailure: listFailure,
    );
    workflows = WorkflowsController(api: registry, settings: settings);
    addTearDown(workflows.dispose);
    // The same inert submission `testSession` would have made for itself,
    // held here so a test can read the body that went out.
    jobs = ScriptedJobsApi(
      submission: const JobSubmission(
        jobId: 'j-inert',
        state: JobState.completed,
      ),
    );
    final controller = connection();
    await controller.connectTo(Endpoint.tryParse('192.0.2.42')!);
    return MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: lcDarkTheme(),
      home: ConnectedShell(
        session: testSession(
          connection: controller,
          workflows: workflows,
          jobs: jobs,
        ),
      ),
    );
  }

  Future<void> choose(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard(id)));
    await tester.pumpAndSettle();
  }

  group('before a workflow is chosen', () {
    testWidgets('the registry arrives and the shell offers the picker',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();

      expect(registry.listCalls, 1);
      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.creationIdle), findsOneWidget);
      expect(find.text('Pick something to create'), findsOneWidget);
      expect(find.byKey(LcKeys.workflowForm), findsNothing);
    });

    testWidgets('a registry that does not arrive says so and offers one action',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(
        <Map<String, Object?>>[txt2imgDetail()],
        listFailure: const WorkflowsFailure.unreachable(),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowsFailed), findsOneWidget);
      expect(find.text("The server didn't answer."), findsOneWidget);
      expect(find.byKey(LcKeys.chooseWorkflow), findsNothing);

      registry.listFailure = null;
      await tester.tap(find.byKey(LcKeys.workflowsRetry));
      await tester.pumpAndSettle();

      expect(registry.listCalls, 2);
      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);
    });
  });

  group('the form', () {
    testWidgets('main fields are visible and Advanced is collapsed',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.byKey(LcKeys.field('prompt')), findsOneWidget);
      expect(find.byKey(LcKeys.field('width')), findsOneWidget);
      expect(find.byKey(LcKeys.field('height')), findsOneWidget);

      // Advanced is behind an affordance that says how much is behind it.
      expect(find.byKey(LcKeys.advancedSection), findsNothing);
      expect(find.byKey(LcKeys.field('seed')), findsNothing);
      expect(find.text('Advanced'), findsOneWidget);
      expect(find.text('5 settings'), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      for (final id in <String>[
        'negative_prompt',
        'steps',
        'guidance',
        'sampler',
        'seed',
      ]) {
        expect(find.byKey(LcKeys.field(id)), findsOneWidget, reason: id);
      }
    });

    testWidgets('every field type gets its own natural control',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        allTypesDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'all_types');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      // string and multiline: text entries, the second one taller.
      expect(
        find.byKey(LcKeys.field('title')),
        findsOneWidget,
      );
      final title = tester.widget<TextField>(find.byKey(LcKeys.field('title')));
      final prompt = tester.widget<TextField>(
        find.byKey(LcKeys.field('prompt')),
      );
      expect(title.maxLines, 1);
      expect(prompt.minLines, greaterThan(1));

      // boolean: a switch, already on because the registry said so.
      final loop = tester.widget<Switch>(find.byKey(LcKeys.field('loop')));
      expect(loop.value, isTrue);

      // integer and float with a range: sliders honouring min/max/step.
      final steps = tester.widget<Slider>(find.byKey(LcKeys.field('steps')));
      expect(steps.min, 1);
      expect(steps.max, 50);
      expect(steps.value, 20);
      final strength = tester.widget<Slider>(
        find.byKey(LcKeys.field('strength')),
      );
      expect(strength.divisions, 20);
      expect(strength.value, closeTo(0.55, 0.0001));

      // select: the options, by their labels.
      expect(find.widgetWithText(ChoiceChip, 'Euler'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'DPM++ 2M'), findsOneWidget);

      // image and video: stated, not faked.
      expect(find.byKey(LcKeys.field('source_image')), findsOneWidget);
      expect(find.byKey(LcKeys.field('source_clip')), findsOneWidget);

      // seed: an entry, because its range is not a slider's business.
      expect(
        tester.widget<TextField>(find.byKey(LcKeys.field('seed'))).maxLines,
        1,
      );
    });

    testWidgets('a long list of choices becomes a menu, not a wall of chips',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        awkwardFieldsDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'awkward_fields');

      final selector = find.byKey(LcKeys.field('sampler'));
      expect(selector, findsOneWidget);
      expect(
        find.byType(ChoiceChip),
        findsNothing,
        reason: 'six chips is a wall; the menu is the kinder control',
      );
      expect(workflows.form!.entry('sampler'), 'euler');

      await tester.tap(selector);
      await tester.pumpAndSettle();
      // The menu offers every option by its label, not by its value.
      expect(find.text('DPM++ 3M SDE'), findsWidgets);
      await tester.tap(find.text('DPM++ 3M SDE').last);
      await tester.pumpAndSettle();

      expect(workflows.form!.entry('sampler'), 'dpmpp_3m_sde');
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();
      expect(
        workflows.form!.validate().inputs['sampler'],
        'dpmpp_3m_sde',
      );
    });

    testWidgets('a field type from a later schema is shown, not dropped',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        awkwardFieldsDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'awkward_fields');

      // The field is on screen, under its own label, saying what it is.
      expect(find.byKey(LcKeys.fieldRow('region')), findsOneWidget);
      expect(find.text('Region'), findsOneWidget);
      expect(
        find.text('This app version cannot show this kind of input yet.'),
        findsOneWidget,
      );
      // Nothing pretends to accept a value for it.
      expect(
        find.descendant(
          of: find.byKey(LcKeys.fieldRow('region')),
          matching: find.byType(EditableText),
        ),
        findsNothing,
      );

      // And because it is required, Generate stays off and says why -- a
      // workflow silently running without one of its inputs would be worse.
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed,
        isNull,
      );
      expect(find.textContaining('cannot show yet'), findsOneWidget);
      expect(workflows.form!.validate().inputs.containsKey('region'), isFalse);
    });

    testWidgets('a build with no picker states the media field, not fakes it',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      final media = find.byKey(LcKeys.field('source_image'));
      expect(media, findsOneWidget);
      expect(
        find.text('This workflow works from a picture you choose.'),
        findsOneWidget,
      );
      expect(
        find.text('Choosing one is not available on this device.'),
        findsOneWidget,
      );
      // Nothing inside it invites a tap it cannot honour.
      expect(
        find.descendant(of: media, matching: find.byType(ButtonStyleButton)),
        findsNothing,
      );
      expect(
        find.descendant(of: media, matching: find.byType(InkWell)),
        findsNothing,
      );
    });

    testWidgets('a hinted pair shares a line and a hint-free one does not',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      final width = tester.getTopLeft(find.byKey(LcKeys.fieldRow('width')));
      final height = tester.getTopLeft(find.byKey(LcKeys.fieldRow('height')));
      expect(width.dy, height.dy);
      expect(width.dx, lessThan(height.dx));
    });
  });

  group('hints are hints', () {
    testWidgets('a schema with no role and no pair still renders a usable form',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        withoutHints(txt2imgDetail()),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      // Every field is there, each with a control of its own.
      for (final id in <String>[
        'prompt',
        'width',
        'height',
        'negative_prompt',
        'steps',
        'guidance',
        'sampler',
        'seed',
      ]) {
        expect(find.byKey(LcKeys.field(id)), findsOneWidget, reason: id);
      }

      // No pairing: width and height are on lines of their own.
      final width = tester.getTopLeft(find.byKey(LcKeys.fieldRow('width')));
      final height = tester.getTopLeft(find.byKey(LcKeys.fieldRow('height')));
      expect(width.dy, lessThan(height.dy));
      expect(width.dx, height.dx);

      // No Random, and the seed is still editable and still a number.
      expect(find.byKey(LcKeys.fieldRandom('seed')), findsNothing);
      await tester.enterText(find.byKey(LcKeys.field('seed')), '4242');
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();

      final validated = workflows.form!.validate();
      expect(validated.isReady, isTrue);
      expect(validated.inputs['seed'], 4242);
      expect(validated.inputs['width'], 768);
      expect(validated.inputs['height'], 768);
    });

    testWidgets('a seed that declares its role offers Random beside it',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.fieldRandom('seed')), findsOneWidget);
      expect(workflows.form!.text('seed'), '0');

      // A random seed is inside the declared range, and is not always zero.
      final seen = <String>{};
      for (var attempt = 0; attempt < 8; attempt++) {
        await tester.tap(find.byKey(LcKeys.fieldRandom('seed')));
        await tester.pumpAndSettle();
        final value = int.parse(workflows.form!.text('seed'));
        expect(value, inInclusiveRange(0, 4294967295));
        seen.add(workflows.form!.text('seed'));
      }
      expect(seen.length, greaterThan(1));
      expect(
        tester.widget<TextField>(find.byKey(LcKeys.field('seed'))).controller!.text,
        workflows.form!.text('seed'),
        reason: 'the visible text must follow the value it was given',
      );
    });
  });

  group('a declared duration', () {
    /// Every word the form puts on screen, in the order it draws them.
    List<String> formTexts(WidgetTester tester) => <String>[
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(LcKeys.workflowForm),
          matching: find.byType(Text),
        ),
      ))
        if (text.data != null && text.data!.isNotEmpty) text.data!,
    ];

    /// The form this workflow draws with no `duration` anywhere in it — the
    /// form every workflow written before this hint existed still draws.
    /// Pinned as words rather than as "no duration widget", so a change
    /// anywhere in the numeric control shows up here.
    const List<String> plainForm = <String>[
      'Prompt',
      'Required',
      'Text inside "quotes" is preserved.',
      'Length',
      '25',
      'How long the clip runs.',
      'Advanced',
      '1 setting',
      'Generate',
      'Generate needs Prompt.',
    ];

    /// The same form once the workflow declares a rate.
    const List<String> hintedForm = <String>[
      'Prompt',
      'Required',
      'Text inside "quotes" is preserved.',
      'Length',
      '25',
      '≈ 1.04 s at 24 fps',
      'How long the clip runs.',
      'Advanced',
      '1 setting',
      'Generate',
      'Generate needs Prompt.',
    ];

    testWidgets('the duration is read out beside the frame count it comes from',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        videoLengthDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_length');

      expect(find.byKey(LcKeys.fieldDuration('length')), findsOneWidget);
      // Rounded in the label, and saying so.
      expect(find.text('≈ 1.04 s at 24 fps'), findsOneWidget);
      // And the number that will actually be sent is still on screen.
      expect(find.text('25'), findsOneWidget);
      expect(workflows.form!.text('length'), '25');
      expect(formTexts(tester), hintedForm);
    });

    testWidgets('a workflow that declares nothing renders what it renders today',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        withoutDuration(videoLengthDetail()),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_length');

      expect(find.byKey(LcKeys.fieldDuration('length')), findsNothing);
      expect(formTexts(tester), plainForm);
    });

    test('declaring one adds the reading and changes nothing else', () {
      // The two pinned forms above, side by side. Every word of the
      // undeclared form survives into the declared one, in the same order,
      // and the whole of the difference is the reading.
      expect(hintedForm.where(plainForm.contains).toList(), plainForm);
      expect(
        hintedForm.where((text) => !plainForm.contains(text)).toList(),
        <String>['≈ 1.04 s at 24 fps'],
      );
    });

    testWidgets('the reading follows the value, and the value stays on the grid',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        videoLengthDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_length');

      // All the way to the right: the maximum, which is on the step grid.
      await tester.drag(find.byKey(LcKeys.field('length')), const Offset(600, 0));
      await tester.pumpAndSettle();

      expect(workflows.form!.text('length'), '121');
      expect(find.text('≈ 5.04 s at 24 fps'), findsOneWidget);

      // And back to the left: the minimum, never below it.
      await tester.drag(find.byKey(LcKeys.field('length')), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(workflows.form!.text('length'), '25');
      expect(find.text('≈ 1.04 s at 24 fps'), findsOneWidget);
    });

    testWidgets('every value the slider can reach is a legal frame count',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        videoLengthDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_length');

      final legal = <int>{for (var n = 25; n <= 121; n += 4) n};
      final slider = find.byKey(LcKeys.field('length'));
      // Twenty small drags across the track: a step of 4 does not divide
      // 25..121 into whole seconds, so a naive `seconds * fps` would land
      // between the ticks somewhere along here.
      for (var move = 0; move < 20; move++) {
        await tester.drag(slider, const Offset(13, 0));
        await tester.pumpAndSettle();
        final value = int.parse(workflows.form!.text('length'));
        expect(legal.contains(value), isTrue, reason: '$value is off the grid');
        // The reading names that very frame count and no other.
        final reading =
            find.byKey(LcKeys.fieldDuration('length')).evaluate().single;
        final text = (reading.widget as Padding).child! as Text;
        final seconds = double.parse(
          RegExp(r'([0-9.]+) s at').firstMatch(text.data!)!.group(1)!,
        );
        expect((seconds * 24).round(), value);
      }
    });

    testWidgets('what is submitted is the frame count', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        videoLengthDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_length');

      await tester.drag(find.byKey(LcKeys.field('length')), const Offset(600, 0));
      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a quiet street',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      // The body the gateway receives: frames, as an int, and no second key
      // beside it. 121 is not a whole number of seconds at 24 fps, and it is
      // sent unrounded all the same. `fps` is the workflow's own independent
      // integer field, untouched by the hint on `length`.
      expect(jobs.submittedInputs.single, <String, Object?>{
        'prompt': 'a quiet street',
        'length': 121,
        'fps': 24,
      });
      expect(jobs.submittedInputs.single['length'], isA<int>());
    });
  });

  group('Use example', () {
    /// The example as the registry wrote it, so the assertion below compares
    /// against the fixture's own words rather than against a copy of them.
    String exampleOf(Map<String, Object?> body) =>
        (body['presentation']! as Map<String, Object?>)['example_prompt']!
            as String;

    testWidgets('offered where there is an example, absent where there is not',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
        allTypesDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      expect(find.byKey(LcKeys.useExample), findsOneWidget);
      expect(find.text('Use example'), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('all_types')));
      await tester.pumpAndSettle();

      // `all_types` declares no example. Nothing is offered at all — not a
      // greyed-out button, not an empty affordance.
      expect(find.byKey(LcKeys.useExample), findsNothing);
      expect(find.text('Use example'), findsNothing);
      expect(
        (allTypesDetail()['presentation']! as Map)['example_prompt'],
        isNull,
        reason: 'the fixture has to be the one without an example',
      );
    });

    testWidgets('an example with nowhere to go is not offered either',
        (tester) async {
      tallView(tester);
      final body = txt2imgDetail();
      body['inputs'] = <Object?>[
        <String, Object?>{
          'id': 'steps',
          'label': 'Steps',
          'type': 'integer',
          'section': 'main',
          'default': 20,
          'min': 1,
          'max': 50,
        },
      ];
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[body]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      expect(exampleOf(body), isNotEmpty);
      expect(find.byKey(LcKeys.useExample), findsNothing);
    });

    testWidgets('one tap fills the field, character for character',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      await tester.tap(find.byKey(LcKeys.useExample));
      await tester.pumpAndSettle();

      final example = exampleOf(txt2imgDetail());
      expect(workflows.form!.text('prompt'), example);
      expect(
        tester
            .widget<TextField>(find.byKey(LcKeys.field('prompt')))
            .controller!
            .text,
        example,
      );
      // An empty field is nobody's work, so nothing was asked.
      expect(find.byKey(LcKeys.useExampleConfirm), findsNothing);
    });

    testWidgets('what it fills is ordinary text, and is what gets sent',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      await tester.tap(find.byKey(LcKeys.useExample));
      await tester.pumpAndSettle();

      final edited = '${exampleOf(txt2imgDetail())}, seen from a balcony';
      await tester.enterText(find.byKey(LcKeys.field('prompt')), edited);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      expect(jobs.submittedWorkflows, <String>['example_txt2img']);
      expect(jobs.submittedInputs.single['prompt'], edited);
    });

    testWidgets('text already in the field is a question, not a replacement',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      const mine = 'a half-written thought I have not finished';
      await tester.enterText(find.byKey(LcKeys.field('prompt')), mine);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.useExample));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.useExampleConfirm), findsOneWidget);
      expect(
        workflows.form!.text('prompt'),
        mine,
        reason: 'the question is asked before anything is replaced',
      );

      await tester.tap(find.byKey(LcKeys.useExampleKeep));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.useExampleConfirm), findsNothing);
      expect(workflows.form!.text('prompt'), mine);
      expect(
        tester
            .widget<TextField>(find.byKey(LcKeys.field('prompt')))
            .controller!
            .text,
        mine,
      );

      // Asked again and answered yes, it replaces.
      await tester.tap(find.byKey(LcKeys.useExample));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.useExampleReplace));
      await tester.pumpAndSettle();
      expect(workflows.form!.text('prompt'), exampleOf(txt2imgDetail()));
    });

    testWidgets('it fills the field the quote hint attaches to', (tester) async {
      tallView(tester);
      // `title` is a one-line string declared *before* the prose field, so a
      // second rule of the "first text field" kind would fill the wrong one.
      final body = allTypesDetail();
      const example = 'a lantern-lit street just after the rain';
      (body['presentation']! as Map<String, Object?>)['example_prompt'] =
          example;
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[body]));
      await tester.pumpAndSettle();
      await choose(tester, 'all_types');

      expect(find.byKey(LcKeys.useExample), findsOneWidget);
      for (final key in <Key>[LcKeys.useExample, LcKeys.quoteHint]) {
        expect(
          find.descendant(
            of: find.byKey(LcKeys.fieldRow('prompt')),
            matching: find.byKey(key),
          ),
          findsOneWidget,
          reason: 'both belong to the workflow\'s one prose field',
        );
        expect(
          find.descendant(
            of: find.byKey(LcKeys.fieldRow('title')),
            matching: find.byKey(key),
          ),
          findsNothing,
        );
      }

      await tester.tap(find.byKey(LcKeys.useExample));
      await tester.pumpAndSettle();
      expect(workflows.form!.text('prompt'), example);
      expect(workflows.form!.text('title'), 'Untitled');
    });
  });

  group('Advanced groups', () {
    testWidgets('headings appear only when Advanced is open, and gather it',
        (tester) async {
      tallView(tester);
      // Width and height moved under Advanced, so the pair is grouped there.
      final body = txt2imgDetail();
      for (final field in body['inputs']! as List<Object?>) {
        final map = field as Map<String, Object?>;
        if (map['pair'] != null) map['section'] = 'advanced';
      }
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[body]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      // Collapsed by default, and a collapsed section shows no headings.
      expect(find.byKey(LcKeys.advancedSection), findsNothing);
      for (final heading in <String>['Text', 'Size', 'Numbers', 'Seed']) {
        expect(find.byKey(LcKeys.advancedGroup(heading)), findsNothing);
      }

      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      for (final heading in <String>[
        'Text',
        'Size',
        'Numbers',
        'Choices',
        'Seed',
      ]) {
        expect(
          find.byKey(LcKeys.advancedGroup(heading)),
          findsOneWidget,
          reason: heading,
        );
      }

      double topOf(Key key) => tester.getTopLeft(find.byKey(key)).dy;

      // Width and height share their line, under the heading of their own
      // group and above the next one.
      final width = tester.getTopLeft(find.byKey(LcKeys.fieldRow('width')));
      final height = tester.getTopLeft(find.byKey(LcKeys.fieldRow('height')));
      expect(width.dy, height.dy);
      expect(width.dx, lessThan(height.dx));
      expect(topOf(LcKeys.advancedGroup('Size')), lessThan(width.dy));
      expect(topOf(LcKeys.advancedGroup('Numbers')), greaterThan(width.dy));

      // The seed keeps its Random affordance, under a heading of its own.
      expect(
        find.descendant(
          of: find.byKey(LcKeys.fieldRow('seed')),
          matching: find.byKey(LcKeys.fieldRandom('seed')),
        ),
        findsOneWidget,
      );
      expect(
        topOf(LcKeys.advancedGroup('Seed')),
        lessThan(topOf(LcKeys.fieldRow('seed'))),
      );

      // And it still toggles shut.
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.advancedSection), findsNothing);
      expect(find.byKey(LcKeys.advancedGroup('Seed')), findsNothing);
    });

    testWidgets('a field that fits no group is shown, last, in order',
        (tester) async {
      tallView(tester);
      final body = oddAdvancedDetail();
      // Counted from the schema, not from the grouping that is under test.
      final advanced = WorkflowDetail.tryFromJson(body)!.advancedFields;
      expect(advanced.map((field) => field.id), <String>[
        'region',
        'palette',
        'output_name',
        'only_width',
      ]);

      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[body]));
      await tester.pumpAndSettle();
      await choose(tester, 'odd_advanced');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      // Every advanced field is drawn, and exactly as many as were declared.
      expect(
        tester
            .widgetList<FieldControl>(
              find.descendant(
                of: find.byKey(LcKeys.advancedSection),
                matching: find.byType(FieldControl),
              ),
            )
            .length,
        advanced.length,
      );
      for (final field in advanced) {
        expect(
          find.byKey(LcKeys.fieldRow(field.id)),
          findsOneWidget,
          reason: field.id,
        );
      }

      double topOf(Key key) => tester.getTopLeft(find.byKey(key)).dy;

      // The two the app cannot place are under the catch-all, which comes
      // last even though they were declared first — and they keep the order
      // the registry gave them.
      expect(find.byKey(LcKeys.advancedGroup('Other')), findsOneWidget);
      expect(
        topOf(LcKeys.advancedGroup('Other')),
        greaterThan(topOf(LcKeys.advancedGroup('Text'))),
      );
      expect(
        topOf(LcKeys.fieldRow('region')),
        greaterThan(topOf(LcKeys.advancedGroup('Other'))),
      );
      expect(
        topOf(LcKeys.fieldRow('palette')),
        greaterThan(topOf(LcKeys.fieldRow('region'))),
      );
    });

    testWidgets('grouping changes nothing that is sent', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a rainy alley at night',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      // Character for character the body the ungrouped form sent — the map
      // pinned by "says what it is waiting for, then yields the input map".
      expect(jobs.submittedInputs.single, <String, Object?>{
        'prompt': 'a rainy alley at night',
        'negative_prompt': '',
        'width': 768,
        'height': 768,
        'steps': 20,
        'guidance': 6.0,
        'sampler': 'euler',
        'seed': 0,
      });
    });
  });

  group('Generate', () {
    testWidgets('says what it is waiting for, then yields the input map',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      final button = find.byKey(LcKeys.generate);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.byKey(LcKeys.generateReason), findsOneWidget);
      expect(find.text('Generate needs Prompt.'), findsOneWidget);
      // Non-punitive: the requirement is stated, not scolded.
      expect(find.text('Required'), findsOneWidget);

      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a rainy alley at night',
      );
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(find.byKey(LcKeys.generateReason), findsNothing);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(workflows.requestedGeneration?.inputs, <String, Object?>{
        'prompt': 'a rainy alley at night',
        'negative_prompt': '',
        'width': 768,
        'height': 768,
        'steps': 20,
        'guidance': 6.0,
        'sampler': 'euler',
        'seed': 0,
      });
    });

    testWidgets('a required picture keeps Generate off and explains why',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'golden hour');
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed,
        isNull,
      );
      expect(
        find.textContaining('Choosing a picture or a clip is not available'),
        findsOneWidget,
      );
      expect(workflows.requestedGeneration, isNull);
    });

    testWidgets('a value out of range is shown on the field that carries it',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.enterText(find.byKey(LcKeys.field('seed')), '99999999999');
      await tester.pumpAndSettle();

      expect(
        find.text('Seed has to be between 0 and 4294967295.'),
        findsWidgets,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed,
        isNull,
      );
    });
  });

  group('what survives', () {
    testWidgets('a size change keeps the prompt, the workflow and Advanced',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a wet alley');
      await tester.pumpAndSettle();

      // The fold.
      tester.view.physicalSize = const Size(1000, 2400);
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      expect(workflows.form!.text('prompt'), 'a wet alley');
      expect(
        tester
            .widget<TextField>(find.byKey(LcKeys.field('prompt')))
            .controller!
            .text,
        'a wet alley',
      );
      expect(registry.listCalls, 1, reason: 'a fold is not a restart');
    });

    testWidgets('coming back from the picker keeps what was typed',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a wet alley');
      await tester.pumpAndSettle();

      // Open the picker and come back without choosing.
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.workflowPicker), findsOneWidget);
      Navigator.of(tester.element(find.byKey(LcKeys.workflowPicker))).pop();
      await tester.pumpAndSettle();

      expect(workflows.form!.text('prompt'), 'a wet alley');
      expect(registry.detailCalls, <String>['example_txt2img']);

      // Go elsewhere and back again: the first form is still the first form.
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_img2img')));
      await tester.pumpAndSettle();
      expect(workflows.form!.text('prompt'), '');

      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();

      expect(workflows.form!.text('prompt'), 'a wet alley');
      expect(
        registry.detailCalls,
        <String>['example_txt2img', 'example_img2img'],
        reason: 'a schema already in hand is not asked for again',
      );
    });
  });

  group('My defaults', () {
    /// The store the shell is given, over the package's own in-memory
    /// platform. Absent from every other test in this file, which is what
    /// makes those the "no defaults kept" case.
    PreferencesWorkflowSettingsStore aStore() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      return PreferencesWorkflowSettingsStore();
    }

    Future<void> openTxt2img(WidgetTester tester, {
      WorkflowSettingsStore? settings,
      double width = 420,
    }) async {
      tallView(tester, width: width);
      await tester.pumpWidget(await shellFor(
        <Map<String, Object?>>[txt2imgDetail()],
        settings: settings,
      ));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
    }

    testWidgets('a build that keeps no defaults offers nothing about them',
        (tester) async {
      await openTxt2img(tester);

      // The form as it was before this feature existed: the fields, Advanced,
      // Generate, and not one affordance that would write nowhere.
      expect(find.byKey(LcKeys.saveMyDefaults), findsNothing);
      expect(find.byKey(LcKeys.resetToMyDefaults), findsNothing);
      expect(find.byKey(LcKeys.resetToWorkflowDefaults), findsNothing);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.byKey(LcKeys.generate), findsOneWidget);
      expect(
        tester.widget<Slider>(find.byKey(LcKeys.field('steps'))).value,
        20,
      );
    });

    testWidgets('saving keeps what is on screen, and says so', (tester) async {
      final store = aStore();
      await openTxt2img(tester, settings: store);

      // Nothing saved yet: there is nothing to go back to.
      expect(find.byKey(LcKeys.saveMyDefaults), findsOneWidget);
      expect(find.byKey(LcKeys.resetToMyDefaults), findsNothing);

      await tester.drag(find.byKey(LcKeys.field('steps')), const Offset(60, 0));
      await tester.pumpAndSettle();
      final chosen = tester
          .widget<Slider>(find.byKey(LcKeys.field('steps')))
          .value;
      expect(chosen, isNot(20));

      await tester.tap(find.byKey(LcKeys.saveMyDefaults));
      await tester.pumpAndSettle();

      expect(
        await store.load('example_txt2img'),
        containsPair('steps', chosen.round()),
      );
      expect(
        find.text('Settings saved as your defaults for Example Text to Image.'),
        findsOneWidget,
      );
      // And now there is a way back to them.
      expect(find.byKey(LcKeys.resetToMyDefaults), findsOneWidget);
    });

    testWidgets('the two resets go where their labels say', (tester) async {
      final store = aStore();
      await store.save(
        'example_txt2img',
        <String, Object?>{'steps': 44},
        declaredFields: <String>{'steps'},
      );
      // A narrow phone, where all three affordances are on screen at once:
      // they have to wrap onto a second line rather than overflow, which
      // this pump would report as an error.
      await openTxt2img(tester, settings: store, width: 360);
      expect(
        tester.getTopLeft(find.byKey(LcKeys.resetToWorkflowDefaults)).dy,
        greaterThan(tester.getTopLeft(find.byKey(LcKeys.saveMyDefaults)).dy),
        reason: 'three of them do not fit on one line of a phone',
      );

      double stepsOnScreen() =>
          tester.widget<Slider>(find.byKey(LcKeys.field('steps'))).value;

      expect(stepsOnScreen(), 44, reason: 'my defaults are what opens');
      // Every label says what the button touches, so someone reading only the
      // button can predict what survives it.
      expect(find.text('Save settings as my defaults'), findsOneWidget);
      expect(find.text('Reset settings to my defaults'), findsOneWidget);
      expect(find.text('Reset settings to workflow defaults'), findsOneWidget);

      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a lighthouse in a storm',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.resetToWorkflowDefaults));
      await tester.pumpAndSettle();
      expect(stepsOnScreen(), 20);
      // And the prompt is still on screen, because a settings reset is not a
      // form wipe.
      expect(find.text('a lighthouse in a storm'), findsOneWidget);
      // The workflow's values are on screen and mine are still kept — which
      // is exactly why the way back to them is still offered.
      expect(find.byKey(LcKeys.resetToMyDefaults), findsOneWidget);
      expect(
        await store.load('example_txt2img'),
        <String, Object?>{'steps': 44},
      );

      await tester.tap(find.byKey(LcKeys.resetToMyDefaults));
      await tester.pumpAndSettle();
      expect(stepsOnScreen(), 44);
      expect(find.text('a lighthouse in a storm'), findsOneWidget);
    });
  });

  testWidgets('nothing the app draws speaks of a graph', (tester) async {
    tallView(tester);
    await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
      txt2imgDetail(),
      img2imgDetail(),
      videoDetail(),
    ]));
    await tester.pumpAndSettle();

    // Everything the curator wrote, so that a word of theirs is never counted
    // as a word of ours.
    final curator = <String>{
      for (final body in <Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
        videoDetail(),
      ])
        ..._stringsIn(body),
    };

    final drawn = <String>{};
    void collect() {
      drawn.addAll(
        tester
            .widgetList<Text>(find.byType(Text))
            .map(
              (widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '',
            )
            .where((text) => text.isNotEmpty),
      );
    }

    // The picker, then a prompt-only form with Advanced open, then a form
    // whose main input is a picture — the three places words come from.
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    collect();
    await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.advancedToggle));
    await tester.pumpAndSettle();
    collect();
    await tester.tap(find.byKey(LcKeys.changeWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard('example_img2img')));
    await tester.pumpAndSettle();
    collect();

    final forbidden = <RegExp>[
      RegExp(r'\bnodes?\b', caseSensitive: false),
      RegExp(r'\bbind\b', caseSensitive: false),
      RegExp('class_type'),
      RegExp('KSampler'),
      RegExp(r'\bgraph\b', caseSensitive: false),
      RegExp('ComfyUI'),
      RegExp(r'\blatent\b', caseSensitive: false),
      RegExp(r'\bcheckpoint\b', caseSensitive: false),
    ];
    for (final text in drawn) {
      if (curator.contains(text)) continue;
      for (final pattern in forbidden) {
        expect(
          pattern.hasMatch(text),
          isFalse,
          reason: 'the app wrote "$text", which names ${pattern.pattern}',
        );
      }
    }
    // The fixture really does contain the word, so the exemption above is
    // doing work rather than covering an empty case.
    expect(
      curator.any((text) => text.contains('ComfyUI')),
      isTrue,
    );
  });
}

/// Every string anywhere in a JSON body.
Set<String> _stringsIn(Object? json) {
  final found = <String>{};
  void walk(Object? value) {
    if (value is String) {
      found.add(value);
    } else if (value is Map) {
      value.forEach((key, item) {
        if (key is String) found.add(key);
        walk(item);
      });
    } else if (value is List) {
      value.forEach(walk);
    }
  }

  walk(json);
  return found;
}
