/// Translation, as the app is allowed to treat it (`docs/api.md`, "Prompt
/// translation — a gateway stage, before binding").
///
/// The card is one sentence and the rest is decoration on it: **the user's own
/// text survives a translated generation, character for character.** So the
/// assertions below are mostly about what did *not* happen — the field was not
/// rewritten, the effective text was not stored, and the resubmission carried
/// the original.
///
/// Every fixture here spells the two texts out as different strings, and the
/// Russian one is compared with `equals` against the exact string the test
/// typed. A `contains` would pass on a field holding the English translation
/// with the Russian appended, which is precisely the damage this card exists
/// to prevent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/generation/translation.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// What the user typed. Never rewritten, never replaced, never re-encoded.
const String kOriginal = 'кот в шляпе на мокрой улице';

/// What the gateway bound into the graph for one run. Deliberately nothing
/// like the original, so that a field holding the wrong one cannot pass by
/// resembling the right one.
const String kEffective = 'a cat in a hat on a wet street';

/// The body `POST /api/v1/jobs` answers with when it translated one field.
Map<String, Object?> translatedBody({
  String field = 'prompt',
  String source = 'ru',
  String target = 'en',
  String original = kOriginal,
  String effective = kEffective,
}) => <String, Object?>{
  'job_id': 'j-8f21',
  'state': 'completed',
  'translation': <String, Object?>{
    'applied': true,
    'fields': <String, Object?>{
      field: <String, Object?>{
        'original': original,
        'effective': effective,
        'translation': <String, Object?>{
          'applied': true,
          'source': source,
          'target': target,
        },
      },
    },
  },
};

/// The ordinary answer: no backend installed, so nothing was translated.
Map<String, Object?> untranslatedBody() => <String, Object?>{
  'job_id': 'j-8f21',
  'state': 'completed',
  'translation': <String, Object?>{
    'applied': false,
    'fields': <String, Object?>{},
  },
};

/// A PC that really translates Russian.
Map<String, Object?> translatingPc() => <String, Object?>{
  'enabled': true,
  'installed': true,
  'pairs': <Object?>[
    <String, Object?>{'source': 'ru', 'target': 'en'},
  ],
};

/// Switched on, and the optional extra was never installed there.
Map<String, Object?> notInstalledPc() => <String, Object?>{
  'enabled': true,
  'installed': false,
  'pairs': <Object?>[],
};

/// The extra is there; no language model is.
Map<String, Object?> noLanguagesPc() => <String, Object?>{
  'enabled': true,
  'installed': true,
  'pairs': <Object?>[],
};

/// Installed and idle: the stage is switched off in its configuration.
Map<String, Object?> switchedOffPc() => <String, Object?>{
  'enabled': false,
  'installed': true,
  'pairs': <Object?>[],
};

/// A gateway whose `capabilities` carry that block, or none at all — which is
/// what a gateway older than the feature answers.
GatewayCapabilities gatewayWhose(Map<String, Object?>? translation) =>
    GatewayCapabilities.fromJson(<String, Object?>{'translation': ?translation});

/// A workflow with three text inputs, for the one-hint-per-form rule.
Map<String, Object?> threeTextFieldsDetail() => <String, Object?>{
  'id': 'three_texts',
  'name': 'Three Text Inputs',
  'presentation': <String, Object?>{
    'group': 'Create',
    'badge': 'TXT2IMG',
    'short_description':
        'Three text inputs, so that one hint cannot quietly become three.',
  },
  'required_media': <Object?>[],
  'input_summary': 'Three text inputs',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'negative_prompt',
      'label': 'Avoid',
      'type': 'multiline',
      'required': false,
      'section': 'main',
      'default': '',
    },
    <String, Object?>{
      'id': 'output_name',
      'label': 'Output name',
      'type': 'string',
      'required': false,
      'section': 'advanced',
      'default': 'LocalCanvas',
    },
  ],
};

void main() {
  group('the report, off the wire', () {
    test('the ordinary answer says nothing and shows nothing', () {
      final submission = JobSubmission.tryFromJson(untranslatedBody())!;
      expect(submission.translation.applied, isFalse);
      expect(submission.translation.fields, isEmpty);
      expect(submission.translation.appliedFor('prompt'), isNull);
    });

    test('a 201 with no translation block at all is the same nothing', () {
      final submission = JobSubmission.tryFromJson(<String, Object?>{
        'job_id': 'j-8f21',
        'state': 'queued',
      })!;
      expect(submission.translation.applied, isFalse);
      expect(submission.translation.appliedFor('prompt'), isNull);
    });

    test('a translated field carries both texts and the pair', () {
      final submission = JobSubmission.tryFromJson(translatedBody())!;
      final field = submission.translation.appliedFor('prompt')!;
      expect(field.fieldId, 'prompt');
      expect(field.original, kOriginal);
      expect(field.effective, kEffective);
      expect(field.pairLabel, 'RU → EN');
    });

    test('a field that was looked at and left alone shows no indicator', () {
      // The contract reports one entry per translatable field the submission
      // supplied, changed or not — so "nothing happened to this one" is a
      // fact the gateway states and the app must not draw.
      final report = TranslationReport.fromJson(<String, Object?>{
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
          'negative_prompt': <String, Object?>{
            'original': 'blurry',
            'effective': 'blurry',
            'translation': <String, Object?>{
              'applied': false,
              'source': null,
              'target': 'en',
            },
          },
        },
      });
      expect(report.fields.keys, containsAll(<String>['prompt', 'negative_prompt']));
      expect(report.appliedFor('prompt'), isNotNull);
      expect(report.appliedFor('negative_prompt'), isNull);
    });

    test('`applied` is the condition, not the presence of a block', () {
      // The block is now always in the answer, so "there is a translation
      // key" is worth nothing. These two reports are the only shapes that
      // could talk an interface into drawing an indicator for a run that
      // translated nothing, and both are refused — a naming pair alone is
      // not permission to draw one.
      const pair = FieldTranslation(
        fieldId: 'prompt',
        original: kOriginal,
        effective: kOriginal,
        applied: false,
        source: 'ru',
        target: 'en',
      );
      const stageOff = TranslationReport(
        applied: false,
        fields: <String, FieldTranslation>{'prompt': pair},
      );
      expect(stageOff.appliedFor('prompt'), isNull);

      const otherFieldOnly = TranslationReport(
        applied: true,
        fields: <String, FieldTranslation>{'prompt': pair},
      );
      expect(
        otherFieldOnly.appliedFor('prompt'),
        isNull,
        reason: 'another field being translated says nothing about this one',
      );
    });

    test('a language this build never heard of is its own uppercase', () {
      final report = TranslationReport.fromJson(
        translatedBody(source: 'xx')['translation'],
      );
      expect(kLanguageLabels.containsKey('xx'), isFalse);
      expect(report.appliedFor('prompt')!.pairLabel, 'XX → EN');
      // And the labels the map does carry are not simply the raw code.
      expect(languageLabel('zh-Hans'), 'ZH');
      expect(languageLabel('ru'), 'RU');
    });

    test('a pair with a half missing is not rendered half empty', () {
      final report = TranslationReport.fromJson(<String, Object?>{
        'applied': true,
        'fields': <String, Object?>{
          'prompt': <String, Object?>{
            'original': kOriginal,
            'effective': kEffective,
            // Contradictory, and the app refuses to guess a language for it.
            'translation': <String, Object?>{'applied': true, 'target': 'en'},
          },
        },
      });
      expect(report.appliedFor('prompt'), isNull);
    });

    test('a block that is not a block is nothing, not a crash', () {
      expect(TranslationReport.fromJson(null).applied, isFalse);
      expect(TranslationReport.fromJson('yes').fields, isEmpty);
      expect(
        TranslationReport.fromJson(<String, Object?>{
          'applied': true,
          'fields': <String, Object?>{
            'prompt': <String, Object?>{'original': kOriginal},
          },
        }).fields,
        isEmpty,
        reason: 'an entry with only half the texts is not an entry',
      );
    });
  });

  group('the controller holds it beside the job', () {
    late ScriptedJobsApi jobs;
    late GenerationController generation;

    GenerationController controllerFor(Map<String, Object?> body) {
      jobs = ScriptedJobsApi(submission: JobSubmission.tryFromJson(body)!);
      generation = GenerationController(api: jobs);
      addTearDown(generation.dispose);
      generation.attach(
        endpoint: Endpoint.tryParse('192.0.2.42')!,
        capabilities: const GatewayCapabilities(),
      );
      return generation;
    }

    test('a translated submission is recorded and readable', () async {
      final controller = controllerFor(translatedBody());
      await controller.submit(
        workflowId: 'example_txt2img',
        inputs: <String, Object?>{'prompt': kOriginal},
      );
      expect(controller.translation.appliedFor('prompt')!.effective, kEffective);
      // And the inputs that were sent were the user's own.
      expect(jobs.submittedInputs.single['prompt'], kOriginal);
    });

    test('Generate Again drops it, and the next run replaces it', () async {
      final controller = controllerFor(translatedBody());
      await controller.submit(
        workflowId: 'example_txt2img',
        inputs: <String, Object?>{'prompt': kOriginal},
      );
      expect(controller.translation.applied, isTrue);

      controller.generateAgain();
      expect(controller.translation.applied, isFalse);
      expect(controller.translation.appliedFor('prompt'), isNull);

      // A second gateway, or a second run, that translated nothing leaves
      // nothing behind from the first.
      jobs.submission = JobSubmission.tryFromJson(untranslatedBody())!;
      await controller.submit(
        workflowId: 'example_txt2img',
        inputs: <String, Object?>{'prompt': kOriginal},
      );
      expect(controller.translation.appliedFor('prompt'), isNull);
    });
  });

  group('on screen', () {
    late ScriptedJobsApi jobs;
    late WorkflowsController workflows;
    late GenerationController generation;
    late SessionController session;
    late ConnectionController connection;

    void tallView(
      WidgetTester tester, {
      double width = 420,
      double height = 3000,
    }) {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// A connected shell whose gateway answers a submit with [body].
    ///
    /// The answer is `completed` with no output, which is the one reply that
    /// starts no socket and no poll timer: these tests are about the form, not
    /// about the lifecycle.
    Future<Widget> shellFor(
      Map<String, Object?> body, {
      Map<String, Object?>? detail,
      GatewayCapabilities capabilities = const GatewayCapabilities(),
    }) async {
      final workflowBody = detail ?? txt2imgDetail();
      jobs = ScriptedJobsApi(submission: JobSubmission.tryFromJson(body)!);
      final registry = ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[workflowBody]),
        ),
        details: <String, WorkflowDetail>{
          workflowBody['id']! as String:
              WorkflowDetail.tryFromJson(workflowBody)!,
        },
      );
      workflows = WorkflowsController(api: registry);
      addTearDown(workflows.dispose);

      connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity(capabilities: capabilities)),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);

      generation = GenerationController(api: jobs);
      addTearDown(generation.dispose);
      session = testSession(
        connection: connection,
        workflows: workflows,
        generation: generation,
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

    Future<void> typeAndGenerate(
      WidgetTester tester, {
      String text = kOriginal,
    }) async {
      await tester.enterText(find.byKey(LcKeys.field('prompt')), text);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
    }

    /// What the prompt field actually holds, straight off its controller.
    String promptField(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(LcKeys.field('prompt')))
        .controller!
        .text;

    List<String> visibleText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .where((value) => value.isNotEmpty)
        .toList();

    testWidgets('nothing translated changes nothing on screen',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(untranslatedBody()));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');

      final before = visibleText(tester).toSet();
      await typeAndGenerate(tester, text: 'a rainy alley at night');

      expect(find.byKey(LcKeys.translation('prompt')), findsNothing);
      expect(find.byKey(LcKeys.translationDetail('prompt')), findsNothing);
      expect(find.text('Translated for this generation'), findsNothing);
      expect(find.text('Original'), findsNothing);
      expect(find.text('Sent to workflow'), findsNothing);
      // Nothing new appeared beside the form. The words a generation of its
      // own brings — the outcome panel and its way out — are the lifecycle's
      // and are the same with the stage switched off; what must not be here
      // is a badge, a pair of languages, or an explanation of a translation
      // that did not happen.
      final gained = visibleText(tester).toSet().difference(before);
      expect(gained.where((t) => t.contains('→')), isEmpty);
      expect(
        gained.where((t) => t.toLowerCase().contains('translat')),
        isEmpty,
      );
      expect(promptField(tester), 'a rainy alley at night');
    });

    testWidgets('a translated run shows the pair and keeps the original',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(translatedBody()));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await typeAndGenerate(tester);

      expect(find.byKey(LcKeys.translation('prompt')), findsOneWidget);
      expect(find.text('RU → EN'), findsOneWidget);

      // The whole card, in one assertion: character for character, the string
      // this test typed.
      expect(promptField(tester), kOriginal);
      expect(promptField(tester), isNot(kEffective));
      expect(workflows.form!.text('prompt'), kOriginal);
      // And the English is nowhere on screen while the disclosure is shut.
      expect(find.text(kEffective), findsNothing);
    });

    testWidgets('the two texts are behind a tap, not beside each other',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(translatedBody()));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await typeAndGenerate(tester);

      // Shut: no second copy of the prompt, and no headings for one.
      expect(find.byKey(LcKeys.translationDetail('prompt')), findsNothing);
      expect(find.text('Original'), findsNothing);
      expect(find.text('Sent to workflow'), findsNothing);
      // One copy: the editor's own. The disclosure adds the second, and only
      // while it is open.
      expect(find.text(kOriginal), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.translation('prompt')));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.translationDetail('prompt')), findsOneWidget);
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('Sent to workflow'), findsOneWidget);
      expect(find.text(kOriginal), findsNWidgets(2));
      expect(find.text(kEffective), findsOneWidget);
      // Opening it did not touch the field it describes.
      expect(promptField(tester), kOriginal);

      // And it closes again, so the two prompts are never permanently both on
      // screen.
      await tester.tap(find.byKey(LcKeys.translation('prompt')));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.translationDetail('prompt')), findsNothing);
    });

    testWidgets('the indicator belongs to the workflow it ran under',
        (tester) async {
      tallView(tester);
      // Two workflows, both with a field called `prompt` — which is what the
      // registry calls it, and is why a report keyed by field id has to be
      // scoped to the workflow it is about.
      jobs = ScriptedJobsApi(
        submission: JobSubmission.tryFromJson(translatedBody())!,
      );
      final registry = ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail(), videoDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
          'example_video': WorkflowDetail.tryFromJson(videoDetail())!,
        },
      );
      workflows = WorkflowsController(api: registry);
      addTearDown(workflows.dispose);
      connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);
      generation = GenerationController(api: jobs);
      addTearDown(generation.dispose);
      session = testSession(
        connection: connection,
        workflows: workflows,
        generation: generation,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(session: session),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await typeAndGenerate(tester);
      expect(find.byKey(LcKeys.translation('prompt')), findsOneWidget);

      // Somewhere else entirely. Its prompt is empty and was never sent.
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_video')));
      await tester.pumpAndSettle();

      expect(workflows.form!.text('prompt'), '');
      expect(find.byKey(LcKeys.translation('prompt')), findsNothing);
      expect(find.text('RU → EN'), findsNothing);

      // And back: the run it was about is still the run it is about.
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.translation('prompt')), findsOneWidget);
      expect(promptField(tester), kOriginal);
    });

    testWidgets('a language with no label renders as its code', (tester) async {
      tallView(tester);
      await tester.pumpWidget(
        await shellFor(translatedBody(source: 'xx', target: 'yy')),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await typeAndGenerate(tester);

      expect(find.text('XX → YY'), findsOneWidget);
      // Not an empty chip: something a person can read is always there.
      expect(
        visibleText(tester).where((t) => t.contains('→')),
        <String>['XX → YY'],
      );
    });

    testWidgets('Generate Again sends the original, not the translation',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(translatedBody()));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await typeAndGenerate(tester);

      expect(jobs.submittedInputs.single['prompt'], kOriginal);
      // What the next run will start from, before anything is pressed: an
      // editor re-seeded from the translation would resubmit English the
      // moment the user touches the field.
      expect(promptField(tester), kOriginal);

      await tester.ensureVisible(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();

      // The indicator belongs to a run that is over.
      expect(find.byKey(LcKeys.translation('prompt')), findsNothing);
      expect(promptField(tester), kOriginal);

      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      // The request body, not the widget: the gateway translates again from
      // the user's own words rather than from its own output.
      expect(jobs.submits, 2);
      expect(jobs.submittedInputs.last['prompt'], kOriginal);
      expect(
        jobs.submittedInputs.map((inputs) => inputs['prompt']),
        everyElement(kOriginal),
      );
    });

    testWidgets('a fold and a reconnect leave the original alone',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(translatedBody()));
      await tester.pumpAndSettle();
      await choose(tester, 'example_txt2img');
      await typeAndGenerate(tester);

      // The fold.
      tester.view.physicalSize = const Size(1000, 3000);
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(promptField(tester), kOriginal);

      // The reconnect: registry refreshed, state restored.
      generation.connectionLost();
      await session.reconnect();
      await tester.pumpAndSettle();

      expect(promptField(tester), kOriginal);
      expect(workflows.form!.text('prompt'), kOriginal);
      expect(find.text(kEffective), findsNothing);
    });

    testWidgets('the quote hint appears once, on the prose field',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(
        await shellFor(
          untranslatedBody(),
          detail: threeTextFieldsDetail(),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'three_texts');
      expect(find.byKey(LcKeys.quoteHint), findsOneWidget);
      expect(find.text(en.quoteHint), findsOneWidget);
      // On the first prose control, not on the one-line name under Advanced.
      expect(
        find.descendant(
          of: find.byKey(LcKeys.fieldRow('prompt')),
          matching: find.byKey(LcKeys.quoteHint),
        ),
        findsOneWidget,
      );

      // Opening Advanced brings a third text field into view and still no
      // second hint.
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.field('output_name')), findsOneWidget);
      expect(find.byKey(LcKeys.quoteHint), findsOneWidget);
    });

    // -- before a submission: what the server says it will do -------------

    /// The sentence under the prompt, or `null` when there is none.
    String? notice(WidgetTester tester) {
      final found = find.byKey(LcKeys.translationNotice('prompt'));
      if (found.evaluate().isEmpty) return null;
      return tester.widget<Text>(found).data;
    }

    Future<void> openForm(
      WidgetTester tester, {
      Map<String, Object?>? pc,
      Map<String, Object?>? detail,
    }) async {
      tallView(tester);
      await tester.pumpWidget(
        await shellFor(
          untranslatedBody(),
          detail: detail,
          capabilities: gatewayWhose(pc),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, (detail ?? txt2imgDetail())['id']! as String);
    }

    testWidgets('a gateway that says nothing leaves the form as it was',
        (tester) async {
      // The compatibility case: a gateway older than the capability. Nothing
      // about translation appears, and nothing that was there is disturbed —
      // "unknown" must not be read as "off" and drawn as a claim either.
      await openForm(tester);

      expect(notice(tester), isNull);
      expect(find.byKey(LcKeys.translationOverride('prompt')), findsNothing);
      expect(
        visibleText(tester).where((t) => t.toLowerCase().contains('translat')),
        isEmpty,
      );
      // The form itself is untouched: the hint, the field and Generate.
      expect(find.byKey(LcKeys.quoteHint), findsOneWidget);
      expect(find.byKey(LcKeys.field('prompt')), findsOneWidget);
      expect(find.byKey(LcKeys.generate), findsOneWidget);
    });

    testWidgets('a PC with the stage switched off says nothing either',
        (tester) async {
      // Most PCs. A permanent line about an optional stage nobody switched on
      // would be under every prompt of every workflow, forever.
      await openForm(tester, pc: switchedOffPc());

      expect(notice(tester), isNull);
      expect(find.byKey(LcKeys.translationOverride('prompt')), findsNothing);
      expect(
        visibleText(tester).where((t) => t.toLowerCase().contains('translat')),
        isEmpty,
      );
    });

    testWidgets('a translating PC says so, and names the languages',
        (tester) async {
      await openForm(tester, pc: translatingPc());

      expect(notice(tester), 'A prompt in RU is translated to EN before generating.');
      final override = find.byKey(LcKeys.translationOverride('prompt'));
      expect(override, findsOneWidget);
      expect(tester.widget<Switch>(override).value, isTrue);
    });

    testWidgets('a PC that is set up to translate and cannot says the prompt '
        'will fail, and offers the way past it', (tester) async {
      // The gateway attempts the stage and refuses the submission with
      // `translation_unavailable`; it does not send the text as typed. A
      // sentence saying otherwise would be wrong about the next thing that
      // happens, and hiding the switch would leave no way to act on it.
      await openForm(tester, pc: notInstalledPc());

      expect(
        notice(tester),
        'This PC is set to translate, but the translator is not installed on '
        'it. A prompt in another language will fail unless you send it as '
        'typed.',
      );
      expect(find.byKey(LcKeys.translationOverride('prompt')), findsOneWidget);
    });

    testWidgets('a PC with the backend and no language says the other thing',
        (tester) async {
      await openForm(tester, pc: noLanguagesPc());

      expect(notice(tester), contains('no languages are installed'));
      expect(notice(tester), contains('will fail'));
      expect(find.byKey(LcKeys.translationOverride('prompt')), findsOneWidget);
    });

    testWidgets('switching it off on such a PC is the difference between a '
        'refusal and a generation', (tester) async {
      await openForm(tester, pc: notInstalledPc());
      await tester.enterText(find.byKey(LcKeys.field('prompt')), kOriginal);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.translationOverride('prompt')));
      await tester.pumpAndSettle();

      // Now it really is sent as typed, and the sentence says exactly that.
      expect(notice(tester), 'This prompt is sent as typed, without translation.');

      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      expect(jobs.submittedTranslate, <bool>[false]);
      expect(jobs.submittedInputs.single['prompt'], kOriginal);
    });

    testWidgets('switching it off changes the sentence and the submission',
        (tester) async {
      await openForm(tester, pc: translatingPc());
      await tester.enterText(find.byKey(LcKeys.field('prompt')), kOriginal);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.translationOverride('prompt')));
      await tester.pumpAndSettle();

      expect(notice(tester), 'This prompt is sent as typed, without translation.');
      // The user's own words are untouched by the switch, before and after.
      expect(promptField(tester), kOriginal);

      await tester.ensureVisible(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();

      expect(jobs.submittedTranslate, <bool>[false]);
      expect(jobs.submittedInputs.single['prompt'], kOriginal);
      expect(promptField(tester), kOriginal);
    });

    testWidgets('left alone, a submission asks for nothing at all',
        (tester) async {
      await openForm(tester, pc: translatingPc());
      await typeAndGenerate(tester);

      expect(
        jobs.submittedTranslate,
        <bool>[true],
        reason: 'true is the absence of an override, not a request to '
            'translate: a client cannot switch the stage on',
      );
    });

    testWidgets('the notice sits on the prose field and on no other',
        (tester) async {
      await openForm(
        tester,
        pc: translatingPc(),
        detail: threeTextFieldsDetail(),
      );

      expect(find.byKey(LcKeys.translationNotice('prompt')), findsOneWidget);
      expect(
        find.byKey(LcKeys.translationNotice('negative_prompt')),
        findsNothing,
      );
      expect(find.byKey(LcKeys.translationOverride('prompt')), findsOneWidget);
      // And the switch exists once, not once per text field.
      expect(find.byType(Switch), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      expect(
        find.byKey(LcKeys.translationNotice('output_name')),
        findsNothing,
      );
    });

    testWidgets('a workflow with no text field carries no hint',
        (tester) async {
      tallView(tester);
      final detail = threeTextFieldsDetail();
      detail['id'] = 'no_text';
      detail['inputs'] = <Object?>[
        <String, Object?>{
          'id': 'steps',
          'label': 'Steps',
          'type': 'integer',
          'required': false,
          'section': 'main',
          'default': 20,
          'min': 1,
          'max': 50,
        },
      ];
      await tester.pumpWidget(
        await shellFor(untranslatedBody(), detail: detail),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'no_text');

      expect(find.byKey(LcKeys.quoteHint), findsNothing);
    });
  });

  // ======================================================================
  // What the gateway says it *can* translate, read before a submission, and
  // the one switch that changes it (T-0043).
  // ======================================================================

  group('what the gateway says it can translate', () {
    TranslationCapability read(Object? block) =>
        GatewayCapabilities.fromJson(<String, Object?>{
          'translation': ?block,
        }).translation;

    test('a gateway that says nothing is unknown, which is not off', () {
      final capability = read(null);

      expect(capability.support, TranslationSupport.unknown);
      expect(
        capability.support,
        isNot(TranslationSupport.off),
        reason: 'silence from an older gateway is not a statement that the '
            'stage is off',
      );
      expect(capability.translates, isFalse);
      expect(capability.canOverride, isFalse);
      expect(capability.isSwitchedOnButUnusable, isFalse);
    });

    test('a block this build cannot read is unknown too, never off', () {
      for (final block in <Object>['yes', 42, <Object?>[], true]) {
        expect(
          read(block).support,
          TranslationSupport.unknown,
          reason: 'unreadable block: $block',
        );
      }
    });

    test('a PC with the stage switched off says so', () {
      expect(read(switchedOffPc()).support, TranslationSupport.off);
      expect(read(switchedOffPc()).canOverride, isFalse);
    });

    test('a translating PC carries the pairs it really has', () {
      final capability = read(translatingPc());

      expect(capability.support, TranslationSupport.active);
      expect(capability.translates, isTrue);
      expect(capability.canOverride, isTrue);
      expect(capability.pairs, <TranslationPair>[
        const TranslationPair(source: 'ru', target: 'en'),
      ]);
      expect(capability.sourceLabels, <String>['RU']);
      expect(capability.targetLabel, 'EN');
    });

    test('the two ways of being set up on this PC stay apart', () {
      // Same `enabled`, same empty `pairs`, and two different missing steps.
      expect(read(notInstalledPc()).support, TranslationSupport.notInstalled);
      expect(read(noLanguagesPc()).support, TranslationSupport.noLanguages);
      expect(read(notInstalledPc()).isSwitchedOnButUnusable, isTrue);
      expect(read(noLanguagesPc()).isSwitchedOnButUnusable, isTrue);
    });

    test('the override is offered wherever the stage will be attempted', () {
      // Not "wherever it translates": a PC that is switched on and cannot is
      // where the switch matters most, because there it is the difference
      // between a refused submission and a generation.
      expect(read(translatingPc()).canOverride, isTrue);
      expect(read(notInstalledPc()).canOverride, isTrue);
      expect(read(noLanguagesPc()).canOverride, isTrue);
      expect(read(switchedOffPc()).canOverride, isFalse);
      expect(read(null).canOverride, isFalse);
      // And it follows one predicate, so the sentence and the switch cannot
      // disagree about whether the stage runs.
      for (final block in <Map<String, Object?>?>[
        translatingPc(),
        notInstalledPc(),
        noLanguagesPc(),
        switchedOffPc(),
        null,
      ]) {
        expect(read(block).canOverride, read(block).isEnabled);
      }
    });

    test('a pair with half a language is not a pair', () {
      final capability = read(<String, Object?>{
        'enabled': true,
        'installed': true,
        'pairs': <Object?>[
          <String, Object?>{'source': 'ru'},
          'ru>en',
          <String, Object?>{'source': 'ja', 'target': 'en'},
        ],
      });

      expect(capability.pairs, <TranslationPair>[
        const TranslationPair(source: 'ja', target: 'en'),
      ]);
    });

    test('a language this build never heard of is still named', () {
      final capability = read(<String, Object?>{
        'enabled': true,
        'installed': true,
        'pairs': <Object?>[
          <String, Object?>{'source': 'qq', 'target': 'en'},
        ],
      });

      expect(capability.sourceLabels, <String>['QQ']);
    });

    test('the handshake carries it into the identity', () {
      final identity = GatewayIdentity.tryFromJson(<String, Object?>{
        'service': 'localcanvas',
        'api_version': 1,
        'gateway_version': '0.1.0',
        'display_name': 'Studio PC',
        'comfy': <String, Object?>{'status': 'ready', 'detail': null},
        'capabilities': <String, Object?>{
          'cancel': true,
          'media_upload': true,
          'events': true,
          'translation': translatingPc(),
        },
      });

      expect(identity!.capabilities.translation.translates, isTrue);
    });

    test('an identity from a gateway that predates it reads as unknown', () {
      final identity = GatewayIdentity.tryFromJson(<String, Object?>{
        'service': 'localcanvas',
        'api_version': 1,
        'gateway_version': '0.1.0',
        'display_name': 'Studio PC',
        'comfy': <String, Object?>{'status': 'ready', 'detail': null},
        'capabilities': <String, Object?>{'cancel': true},
      });

      expect(
        identity!.capabilities.translation.support,
        TranslationSupport.unknown,
      );
    });
  });

  group('the override the form holds', () {
    WorkflowFormController formOf(Map<String, Object?> body) {
      final controller = WorkflowFormController(
        WorkflowDetail.tryFromJson(body)!,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('a form starts asking for nothing, which is not asking for on', () {
      expect(formOf(txt2imgDetail()).translatePrompt, isTrue);
    });

    test('switching it off notifies, and switching it back on notifies', () {
      final form = formOf(txt2imgDetail());
      var notifications = 0;
      form.addListener(() => notifications++);

      form.translatePrompt = false;
      form.translatePrompt = false;
      form.translatePrompt = true;

      expect(notifications, 2);
    });

    test('it is never kept as a field', () {
      // It *is* one of My defaults since T-0052 — but never as a value in the
      // form. It travels beside the values, in its own key, because a workflow
      // that happened to declare a field of that name would otherwise collide
      // with it (`workflow_settings_store.dart`).
      final form = formOf(allTypesDetail());
      form.translatePrompt = false;

      final keepable = form.keepableValues();

      expect(keepable.keys.where((key) => key.contains('translat')), isEmpty);
      expect(keepable.values.contains(false), isFalse);
    });

    test('a reset to the workflow returns it to the workflow policy', () {
      // Superseded T-0043's pin deliberately (T-0052): the answer is now one
      // of My defaults, so the two resets have to move it exactly as they move
      // every other saved setting. "The workflow's own" is the absence of a
      // client override — there is no `on` to send (`docs/api.md`).
      final form = formOf(allTypesDetail());
      form.adoptTranslateDefault(false);
      expect(form.translatePrompt, isFalse);

      form.resetSettingsToWorkflowDefaults();

      expect(form.translatePrompt, isTrue);
      // And what was saved is not erased by a reset, exactly as no other saved
      // default is: the way back is still there.
      expect(form.durableTranslatePrompt, isFalse);
      expect(form.hasMyDefaults, isTrue);
    });

    test('a reset to mine brings the saved answer back', () {
      final form = formOf(allTypesDetail());
      form.adoptTranslateDefault(false);
      form.translatePrompt = true;

      form.resetSettingsToMyDefaults();

      expect(form.translatePrompt, isFalse);
    });

    test('a session choice with nothing saved survives neither reset', () {
      // Nothing was ever saved, so both resets go to the same place — which is
      // the workflow's own policy, and is what "no override" means. Both are
      // pressed here, because a claim about two buttons that exercises one is
      // a claim about one button.
      final form = formOf(allTypesDetail());
      form.translatePrompt = false;

      form.resetSettingsToWorkflowDefaults();

      expect(form.translatePrompt, isTrue);
      expect(form.durableTranslatePrompt, isTrue);

      form.translatePrompt = false;
      form.resetSettingsToMyDefaults();

      expect(form.translatePrompt, isTrue);
      expect(form.durableTranslatePrompt, isTrue);
    });
  });

  group('which field the hint lands on', () {
    WorkflowDetail detailOf(Map<String, Object?> body) =>
        WorkflowDetail.tryFromJson(body)!;

    test('the first prose control, main before advanced', () {
      expect(quoteHintFieldId(detailOf(threeTextFieldsDetail())), 'prompt');
      expect(quoteHintFieldId(detailOf(txt2imgDetail())), 'prompt');
      expect(quoteHintFieldId(detailOf(img2imgDetail())), 'prompt');
      // `title` is a one-line string and `prompt` is the prose: the prose
      // wins even though the string is declared first.
      expect(quoteHintFieldId(detailOf(allTypesDetail())), 'prompt');
    });

    test('a string field only where there is no prose at all', () {
      final body = threeTextFieldsDetail();
      body['inputs'] = <Object?>[
        <String, Object?>{
          'id': 'output_name',
          'label': 'Output name',
          'type': 'string',
          'section': 'main',
        },
      ];
      expect(quoteHintFieldId(detailOf(body)), 'output_name');
    });

    test('nothing at all when a workflow has no text input', () {
      final body = threeTextFieldsDetail();
      body['inputs'] = <Object?>[
        <String, Object?>{
          'id': 'steps',
          'label': 'Steps',
          'type': 'integer',
          'section': 'main',
        },
      ];
      expect(quoteHintFieldId(detailOf(body)), isNull);
    });
  });
}
