/// Generate says no **before** the tap while a generation is progressing
/// (T-0182), and is usable again the moment nothing is.
///
/// The defect this file guards: `GenerationController.submit` refuses a second
/// submission while one is in flight, and the refusal used to change nothing
/// and say nothing. A primary action that takes a tap and drops it leaves the
/// person's model of the app wrong with nothing to correct it. The fix is that
/// the button is not there to press, and the sentence under it says why — which
/// is what `docs/ui-ux.md` already asks of Generate ("communicates why it is
/// unavailable rather than failing silently").
///
/// Four things make these assertions worth something:
///
/// * **every check is on what the screen actually carries** — the live
///   `FilledButton`'s `onPressed`, and the sentence found by its own words.
///   Nothing here reads [GenerationController.state] and calls that proof the
///   button changed;
/// * **the sentence is asserted absent before it is asserted present.** A test
///   that only ever looked for it while busy would pass against a screen that
///   shows it always;
/// * **submissions are compared verbatim, never counted.** Every check names
///   the workflow ids and the input maps that reached the gateway, so a run
///   that submitted the wrong thing twice cannot pass by arriving at a number;
/// * **both layouts.** The button is in the controls column, which the narrow
///   layout stacks and the wide one puts in a pane of its own, and a test
///   pointed at one of the two says nothing about the other.
///
/// The recovery half of the file is the other direction, and it is the reason
/// this card was not trivial: [LifecycleState.isProgressing] is the predicate
/// the recovery path shares, so every state where the app has *lost track* of a
/// job has to leave a screen a person can generate from. Each of those is
/// driven to the end — the button is pressed, and a real submission is what
/// proves it usable.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_events.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// The English words under the button. Spelled out here so a change to the copy
/// has to be made deliberately in both places, and so every assertion below is
/// about a sentence rather than about a key that might hold anything.
const String kBusyReason =
    'Generate is unavailable until this generation finishes.';

/// A workflow with a prompt and one setting and **no Advanced section**, so the
/// whole form fits the windows below without scrolling and without the test
/// font overflowing a 368 dp pane (the artefact `generate_reveals_status_test`
/// documents).
Map<String, Object?> plainDetail() => <String, Object?>{
  'id': 'plain',
  'name': 'Plain',
  'presentation': <String, Object?>{'group': 'Create'},
  'required_media': <Object?>[],
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
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
  ],
};

/// What every accepted submission in this file sends. Named once so each check
/// can compare the whole map rather than probe one key of it.
const Map<String, Object?> kSubmitted = <String, Object?>{
  'prompt': 'a rainy alley at night',
  'steps': 20,
};

/// A jobs API whose `POST /api/v1/jobs` can be held open, so a test can look at
/// the screen while the app is still in [LifecycleState.uploading] — the state
/// that otherwise lasts less than one frame.
class HeldSubmitJobsApi implements JobsApi {
  HeldSubmitJobsApi(this.inner);

  final ScriptedJobsApi inner;

  /// While true, a submit parks here instead of answering.
  bool hold = false;

  final List<Completer<JobSubmission>> held = <Completer<JobSubmission>>[];

  @override
  Future<JobSubmission> submit(
    Endpoint endpoint, {
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  }) {
    // Recorded on the inner script either way, so the verbatim comparisons
    // below see a held submission exactly as they see an answered one.
    final answer = inner.submit(
      endpoint,
      workflowId: workflowId,
      inputs: inputs,
      translate: translate,
    );
    if (!hold) return answer;
    final completer = Completer<JobSubmission>();
    held.add(completer);
    unawaited(answer);
    return completer.future;
  }

  @override
  Future<JobSnapshot?> snapshot(Endpoint endpoint, String jobId) =>
      inner.snapshot(endpoint, jobId);

  @override
  Future<JobSnapshot> cancel(Endpoint endpoint, String jobId) =>
      inner.cancel(endpoint, jobId);

  @override
  Future<ResultBytes> fetchResult(Endpoint endpoint, JobResultRef result) =>
      inner.fetchResult(endpoint, result);
}

void main() {
  late ScriptedJobsApi jobs;
  late HeldSubmitJobsApi api;
  late FakeJobEventSource events;
  late GenerationController generation;

  /// A window tall enough that the whole form and the creation area are on
  /// screen at once. Nothing in this file is about scrolling, and a button the
  /// harness had to scroll to would hide a button the app had disabled.
  void window(WidgetTester tester, {required double width}) {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The shell, connected, over one workflow, following its job over a socket
  /// that says nothing until a test makes it — so a submitted job stays exactly
  /// in the state the test left it in, with no poll timer racing the frame.
  Future<Widget> shell({bool cancel = true}) async {
    jobs = ScriptedJobsApi(
      submission: const JobSubmission(jobId: 'j-first', state: JobState.queued),
    );
    api = HeldSubmitJobsApi(jobs);
    events = FakeJobEventSource();

    final body = plainDetail();
    final workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[body]),
        ),
        details: <String, WorkflowDetail>{
          'plain': WorkflowDetail.tryFromJson(body)!,
        },
      ),
    );
    addTearDown(workflows.dispose);

    final connection = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(
          e,
          testIdentity(
            capabilities: GatewayCapabilities(cancel: cancel, events: true),
          ),
        ),
      ),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);

    generation = GenerationController(api: api, events: events);
    addTearDown(generation.dispose);
    final session = testSession(
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

  /// Chooses the workflow and writes the prompt, leaving Generate ready.
  Future<void> compose(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    // The card's own title, not the card's centre. With this workflow's short
    // card and the test font's square glyphs, the centre of the card lands on
    // the "What this does" button inside it, which opens the help sheet instead
    // of choosing anything — an artefact of the harness, and one that silently
    // leaves the picker open.
    await tester.tap(
      find.descendant(
        of: find.byKey(LcKeys.workflowCard('plain')),
        matching: find.text('Plain'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(LcKeys.field('prompt')),
      'a rainy alley at night',
    );
    await tester.pumpAndSettle();
  }

  /// The live button's own callback. `null` is a button a tap cannot use.
  VoidCallback? generatePress(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed;

  /// Presses Generate without settling — a queued job draws an indeterminate
  /// sweep that never settles, and settling here would hang.
  Future<void> pressGenerate(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.generate));
    await tester.pump();
    await tester.pump();
  }

  /// What the button looks like when a person may use it, checked as a pair so
  /// neither half can pass alone: the tap works **and** nothing claims it
  /// cannot.
  void expectGenerateOffered(WidgetTester tester) {
    expect(generatePress(tester), isNotNull);
    expect(find.text(kBusyReason), findsNothing);
  }

  /// And when they may not.
  void expectGenerateRefusedOutLoud(WidgetTester tester) {
    expect(generatePress(tester), isNull);
    expect(find.byKey(LcKeys.generateReason), findsOneWidget);
    expect(find.text(kBusyReason), findsOneWidget);
  }

  group('a generation in flight takes Generate away and says so', () {
    for (final (String layout, double width) in <(String, double)>[
      ('folded, one column', 420),
      ('unfolded, two panes', 1024),
    ]) {
      testWidgets('$layout: the second tap of two cannot land, and the screen '
          'explains itself', (tester) async {
        window(tester, width: width);
        await tester.pumpWidget(await shell());
        await tester.pumpAndSettle();
        await compose(tester);

        // The sentence was not on screen to begin with, and the button was
        // usable — without this the checks after the tap could pass against a
        // screen that always says this and a button that is never usable.
        expectGenerateOffered(tester);
        expect(find.byKey(LcKeys.generateReason), findsNothing);

        await pressGenerate(tester);

        // The job is the gateway's and has not started. That is a progressing
        // state, and the button is gone for it.
        expect(find.text('Waiting in the queue'), findsOneWidget);
        expectGenerateRefusedOutLoud(tester);

        // The second tap, as fast as a person can give it. It finds nothing to
        // press, which is the whole fix.
        await tester.tap(find.byKey(LcKeys.generate));
        await tester.pump();
        await tester.pump();

        // One submission, named rather than counted — both what it was for and
        // what it carried.
        expect(jobs.submittedWorkflows, <String>['plain']);
        expect(jobs.submittedInputs, <Map<String, Object?>>[kSubmitted]);
        expect(generation.jobId, 'j-first');

        // And the screen is the job that is running, not a picture from before
        // it with nothing to explain the dropped tap.
        expect(find.byKey(LcKeys.generationProgress), findsOneWidget);
        expect(find.byKey(LcKeys.resultPreview), findsNothing);
        expectGenerateRefusedOutLoud(tester);
      });
    }

    testWidgets('all three progressing states, one at a time', (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);
      expectGenerateOffered(tester);

      // uploading — the inputs are still going to the server. Held open, since
      // otherwise it does not last a frame.
      api.hold = true;
      await pressGenerate(tester);
      expect(find.text('Sending this to the server…'), findsOneWidget);
      expectGenerateRefusedOutLoud(tester);

      // queued — the gateway has it and has not started.
      api.held.single.complete(
        const JobSubmission(jobId: 'j-first', state: JobState.queued),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Waiting in the queue'), findsOneWidget);
      expectGenerateRefusedOutLoud(tester);

      // generating — the server's own `running`.
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();
      await tester.pump();
      expect(find.text('Generating'), findsOneWidget);
      expectGenerateRefusedOutLoud(tester);
    });

    test('the guard stands on its own: a second submit on a running job '
        'starts nothing', () async {
      // Driven at the controller, because the button cannot be pressed any
      // more — and the invariant the button protects has to hold whoever calls
      // it. This is the check that dies if the early return is deleted.
      final script = ScriptedJobsApi(
        submission: const JobSubmission(
          jobId: 'j-first',
          state: JobState.queued,
        ),
      );
      final socket = FakeJobEventSource();
      final controller = GenerationController(api: script, events: socket);
      addTearDown(controller.dispose);
      controller.attach(
        endpoint: Endpoint.tryParse('192.0.2.42')!,
        // Followed over the socket, so the job stays queued without a poll
        // timer outliving the check.
        capabilities: const GatewayCapabilities(events: true),
      );
      script.snapshots.add(snapshotOf(JobState.queued, jobId: 'j-first'));

      await controller.submit(
        workflowId: 'plain',
        inputs: <String, Object?>{'prompt': 'the first one'},
      );
      expect(controller.state, LifecycleState.queued);

      script.submission = const JobSubmission(
        jobId: 'j-second',
        state: JobState.queued,
      );
      await controller.submit(
        workflowId: 'other',
        inputs: <String, Object?>{'prompt': 'the second one'},
      );

      // Nothing of the second attempt reached the gateway, and the job being
      // followed is still the first one.
      expect(script.submittedWorkflows, <String>['plain']);
      expect(script.submittedInputs, <Map<String, Object?>>[
        <String, Object?>{'prompt': 'the first one'},
      ]);
      expect(controller.jobId, 'j-first');
      expect(controller.workflowId, 'plain');
    });
  });

  group('everything that is not progress leaves a usable screen', () {
    testWidgets('a bounded reconnect does not read as a refusal',
        (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);

      generation.beginReconnect();
      await tester.pump();
      await tester.pump();

      // The reconnect is genuinely on screen — without this the checks below
      // would pass against a reconnect that never started.
      expect(find.byKey(LcKeys.reconnecting), findsOneWidget);
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(generation.state, LifecycleState.reconnecting);

      expectGenerateOffered(tester);
      expect(find.byKey(LcKeys.generateReason), findsNothing);

      // And it is offered for real: the tap submits.
      await pressGenerate(tester);
      expect(jobs.submittedWorkflows, <String>['plain']);
      expect(jobs.submittedInputs, <Map<String, Object?>>[kSubmitted]);
    });

    testWidgets('a reconnect over a result on screen disturbs neither',
        (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);

      await pressGenerate(tester);
      events.latest.emit(
        const JobResultsEvent(<JobResultRef>[
          JobResultRef(
            index: 0,
            kind: 'image',
            mediaType: 'image/png',
            path: '/api/v1/jobs/j-first/result/0',
          ),
        ]),
      );
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
      expectGenerateOffered(tester);

      generation.beginReconnect();
      // Pumped rather than settled: the reconnect indicator spins for as long
      // as the reconnect lasts, so there is nothing here that ever settles.
      await tester.pump();
      await tester.pump();

      expect(find.byKey(LcKeys.reconnecting), findsOneWidget);
      // The result is untouched (`docs/recovery.md`) and so is the button.
      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
      expectGenerateOffered(tester);
    });

    testWidgets('interrupted: contact lost with a job in flight',
        (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);

      await pressGenerate(tester);
      expectGenerateRefusedOutLoud(tester);

      generation.connectionLost();
      await tester.pump();
      await tester.pump();

      expect(generation.state, LifecycleState.interrupted);
      expect(find.byKey(LcKeys.generationInterrupted), findsOneWidget);
      expect(find.text('Connection lost.'), findsOneWidget);
      expectGenerateOffered(tester);

      jobs.submission = const JobSubmission(
        jobId: 'j-second',
        state: JobState.queued,
      );
      await pressGenerate(tester);
      expect(jobs.submittedWorkflows, <String>['plain', 'plain']);
      expect(jobs.submittedInputs, <Map<String, Object?>>[
        kSubmitted,
        kSubmitted,
      ]);
      expect(generation.jobId, 'j-second');
    });

    testWidgets('disconnected: the server went away with nothing in flight',
        (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);

      generation.connectionLost();
      await tester.pump();
      await tester.pump();

      expect(generation.state, LifecycleState.disconnected);
      expectGenerateOffered(tester);

      await pressGenerate(tester);
      expect(jobs.submittedWorkflows, <String>['plain']);
      expect(jobs.submittedInputs, <Map<String, Object?>>[kSubmitted]);
    });

    testWidgets('a recovery that ends unknown: the app stopped looking and '
        'still does not know', (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);

      await pressGenerate(tester);
      generation.connectionLost();
      await tester.pump();

      // The snapshot does not come back, which is the one answer that leaves
      // the fate of the job unknown.
      jobs.snapshotFailure = const JobFailure.unreachable();
      await generation.recoverJob();
      await tester.pump();
      await tester.pump();

      expect(generation.state, LifecycleState.interrupted);
      expect(generation.recovery, JobRecovery.unknown);
      expect(generation.isCheckingSurvival, isFalse);
      expect(
        find.text(
          'The server is still unreachable, so whether the generation '
          'survived is unknown. Reconnect, or choose another server.',
        ),
        findsOneWidget,
      );
      expectGenerateOffered(tester);

      jobs.snapshotFailure = null;
      jobs.submission = const JobSubmission(
        jobId: 'j-second',
        state: JobState.queued,
      );
      await pressGenerate(tester);
      expect(jobs.submittedWorkflows, <String>['plain', 'plain']);
      expect(jobs.submittedInputs, <Map<String, Object?>>[
        kSubmitted,
        kSubmitted,
      ]);
      expect(generation.jobId, 'j-second');
    });

    testWidgets('cancel is reachable the whole time a job runs, and Generate '
        'comes back after it', (tester) async {
      window(tester, width: 420);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);

      await pressGenerate(tester);
      expectGenerateRefusedOutLoud(tester);

      // Queued, and then running: Cancel is offered in both, which is what
      // keeps the screen usable while Generate is not.
      expect(
        tester
            .widget<TextButton>(find.byKey(LcKeys.cancelGeneration))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Cancel'), findsOneWidget);

      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(LcKeys.cancelGeneration))
            .onPressed,
        isNotNull,
      );

      jobs.cancelReply = snapshotOf(JobState.cancelled, jobId: 'j-first');
      await tester.tap(find.byKey(LcKeys.cancelGeneration));
      await tester.pumpAndSettle();

      expect(jobs.cancels, 1);
      expect(generation.state, LifecycleState.cancelled);
      expect(find.text('Cancelled.'), findsOneWidget);
      expectGenerateOffered(tester);

      jobs.submission = const JobSubmission(
        jobId: 'j-second',
        state: JobState.queued,
      );
      await pressGenerate(tester);
      expect(jobs.submittedWorkflows, <String>['plain', 'plain']);
      expect(jobs.submittedInputs, <Map<String, Object?>>[
        kSubmitted,
        kSubmitted,
      ]);
    });
  });

  group('the copy is the bundle\'s, not this file\'s', () {
    testWidgets('the Russian bundle says it in Russian', (tester) async {
      window(tester, width: 420);
      final app = await shell();
      // The same shell under the other locale. A sentence that only exists in
      // English would show the English one here and pass every other check in
      // this file.
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: (app as MaterialApp).home,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(LcKeys.workflowCard('plain')),
          matching: find.text('Plain'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a rainy alley at night',
      );
      await tester.pumpAndSettle();

      expect(find.text(kBusyReason), findsNothing);
      await pressGenerate(tester);

      expect(generatePress(tester), isNull);
      expect(
        find.text('Кнопка «Сгенерировать» недоступна, пока идёт эта генерация.'),
        findsOneWidget,
      );
      // And not the English one, which is what a missing translation would
      // leave on screen.
      expect(find.text(kBusyReason), findsNothing);
    });
  });
}
