/// What the screen shows while a generation runs, and afterwards
/// (`docs/recovery.md`, `docs/ui-ux.md`).
///
/// Most of these assertions are about what is *not* drawn. Any of the four
/// lies this card exists to prevent would be a widget: a moving bar under
/// `interrupted`, a percentage under an indeterminate one, a Cancel button on
/// a gateway that cannot cancel, a "still generating" after a 404.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_events.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/l10n.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  late ScriptedJobsApi jobs;
  late FakeJobEventSource events;
  late GenerationController generation;
  late WorkflowsController workflows;
  late SessionController session;
  late ConnectionController connection;

  /// Flipped by a test to make the gateway stop answering.
  late bool gatewayGone;

  void tallView(WidgetTester tester, {double width = 420, double height = 2400}) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The shell, connected, with one workflow and a gateway whose capabilities
  /// the test chooses.
  Future<Widget> shell({
    bool cancel = false,
    RecordingResultExporter? exporter,
  }) async {
    jobs = ScriptedJobsApi();
    events = FakeJobEventSource();
    gatewayGone = false;
    final registry = ScriptedWorkflowsApi(
      summaries: WorkflowSummary.listFromJson(
        registryOf(<Map<String, Object?>>[txt2imgDetail()]),
      ),
      details: <String, WorkflowDetail>{
        'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
      },
    );
    workflows = WorkflowsController(api: registry);
    addTearDown(workflows.dispose);

    connection = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => gatewayGone
            ? HandshakeFailed(
                describeProblem(
                  ConnectionProblem.unreachable,
                  address: e.display,
                ),
              )
            : HandshakeSucceeded(
                e,
                GatewayIdentity(
                  apiVersion: kSupportedApiVersion,
                  gatewayVersion: '0.1.0',
                  displayName: 'Studio PC',
                  comfyStatus: ComfyStatus.ready,
                  comfyDetail: null,
                  capabilities: GatewayCapabilities(
                    cancel: cancel,
                    events: true,
                  ),
                ),
              ),
      ),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);

    generation = GenerationController(
      api: jobs,
      events: events,
      exporter: exporter,
      pollInterval: const Duration(milliseconds: 5),
    );
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

  /// Chooses the workflow, fills the prompt and presses Generate.
  Future<void> generate(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(LcKeys.field('prompt')),
      'a rainy alley at night',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.generate));
    // Not pumpAndSettle: an indeterminate bar never settles, which is the
    // point of it.
    await tester.pump();
    await tester.pump();
  }

  /// Every string on screen.
  List<String> visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .where((value) => value.isNotEmpty)
      .toList();

  group('while it runs', () {
    testWidgets('real progress is drawn, with the gateway\'s own numbers',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);

      events.latest.emit(const JobStateEvent(JobState.running));
      events.latest.emit(
        const JobProgressEvent(JobProgress(step: 7, total: 24)),
      );
      await tester.pump();

      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(LcKeys.generationProgress),
      );
      expect(bar.value, closeTo(7 / 24, 1e-9));
      expect(find.text('Step 7 of 24'), findsOneWidget);
      // The two integers the gateway sent, and not a percentage derived from
      // them: a percentage is a number this app would have made up.
      expect(visibleText(tester).where((t) => t.contains('%')), isEmpty);
    });

    testWidgets('no reported progress is indeterminate, and says no numbers',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);

      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();

      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(LcKeys.generationProgress),
      );
      // `null` is what makes Material sweep rather than fill.
      expect(bar.value, isNull);

      final label = tester.widget<Text>(
        find.byKey(LcKeys.generationProgressLabel),
      );
      // Not a percentage, not a step count, and not a time estimate: with
      // nothing reported there is no number this app is entitled to show.
      expect(label.data, isNot(matches(RegExp(r'\d'))));
      expect(label.data, isNot(contains('%')));
    });

    testWidgets('Cancel is absent when the gateway cannot cancel',
        (tester) async {
      await tester.pumpWidget(await shell(cancel: false));
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();

      // Absent, rather than present and inert.
      expect(find.byKey(LcKeys.cancelGeneration), findsNothing);
    });

    testWidgets('Cancel is offered when it is advertised', (tester) async {
      await tester.pumpWidget(await shell(cancel: true));
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();

      expect(find.byKey(LcKeys.cancelGeneration), findsOneWidget);
    });

    testWidgets('a job that finished first shows completed, with its result',
        (tester) async {
      await tester.pumpWidget(await shell(cancel: true));
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();

      jobs.cancelReply = snapshotOf(
        JobState.completed,
        results: const <JobResultRef>[imageResult],
      );
      await tester.tap(find.byKey(LcKeys.cancelGeneration));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(LcKeys.resultSurface), findsOneWidget);
      expect(find.text('Cancelled.'), findsNothing);
      expect(find.byKey(LcKeys.generationProgress), findsNothing);
    });
  });

  group('interrupted', () {
    testWidgets('never renders as though generation were progressing',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();
      expect(find.byKey(LcKeys.generationProgress), findsOneWidget);

      generation.connectionLost();
      await tester.pump();

      // Not one moving thing in the creation area, and no bar of any kind.
      expect(find.byKey(LcKeys.generationInterrupted), findsOneWidget);
      expect(find.byKey(LcKeys.generationProgress), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(LcKeys.generationSurface),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(find.text(connectionLostTitle(en)), findsOneWidget);
    });

    testWidgets('while a check really is running, it says so — as two lines',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();

      generation.connectionLost();
      // What the session does the instant contact is lost.
      generation.beginReconnect();
      await tester.pump();

      // The contract's sentence, drawn as a heading and the line under it
      // rather than as one string printed twice.
      expect(find.text(connectionLostTitle(en)), findsOneWidget);
      expect(find.text(checkingSurvivalMessage(en)), findsOneWidget);
      expect(find.text(connectionLostMessage(en)), findsNothing);
      expect(
        '${connectionLostTitle(en)} ${checkingSurvivalMessage(en)}',
        connectionLostMessage(en),
        reason: 'the two halves must still add up to the contract sentence',
      );
      // Quoted, not referenced: `docs/recovery.md` prints these words, and a
      // check written against the constant would follow the constant anywhere.
      expect(
        connectionLostMessage(en),
        'Connection lost. Checking whether the generation survived.',
      );
      // And it is said exactly once, not once as a title and once as a body.
      expect(
        visibleText(tester)
            .where((line) => line.contains('Checking whether'))
            .length,
        1,
      );
    });

    testWidgets('when the reconnect runs out it stops claiming to be checking',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();

      // Contact is lost mid-job and the gateway never comes back, so the
      // three bounded attempts run out.
      generation.connectionLost();
      gatewayGone = true;
      await session.reconnect();
      await tester.pumpAndSettle();

      expect(session.failure, isNotNull);
      expect(generation.state, LifecycleState.interrupted);

      // The lie this test exists for: the app has stopped looking, so no
      // sentence anywhere on screen may say it is still looking.
      expect(
        visibleText(tester).where((line) => line.contains('Checking whether')),
        isEmpty,
      );
      expect(find.text(connectionLostTitle(en)), findsOneWidget);
      expect(find.text(survivalUnknownMessage(en)), findsOneWidget);

      // A bound, and an exit: the two decisions `docs/recovery.md` requires
      // are on the same screen as the sentence that names them, plus the way
      // back to the form the inputs are still in.
      expect(find.byKey(LcKeys.recoveryPanel), findsOneWidget);
      expect(find.byKey(LcKeys.reconnectNow), findsOneWidget);
      expect(find.byKey(LcKeys.chooseAnotherServer), findsOneWidget);
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);
      expect(find.byKey(LcKeys.reconnecting), findsNothing);
      expect(find.text('a rainy alley at night'), findsOneWidget);
    });

    testWidgets('pressing Reconnect makes the claim true again',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();
      generation.connectionLost();
      gatewayGone = true;
      await session.reconnect();
      await tester.pumpAndSettle();
      expect(find.text(survivalUnknownMessage(en)), findsOneWidget);

      // Asking again is a real check, and the panel is allowed to say so
      // again — the sentence follows the situation, not the other way round.
      generation.beginReconnect();
      await tester.pump();
      expect(find.text(checkingSurvivalMessage(en)), findsOneWidget);
      expect(find.text(survivalUnknownMessage(en)), findsNothing);
    });

    testWidgets('a 404 says so, and leaves the inputs where they are',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      await tester.pump();
      generation.connectionLost();

      // The gateway is answering again and does not have the job.
      jobs.snapshots.add(null);
      await generation.recoverJob();
      await tester.pump();

      expect(find.text('Generation state could not be recovered.'),
          findsOneWidget);
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);
      expect(find.byKey(LcKeys.generationProgress), findsNothing);

      // The prompt is still typed in, so Generate Again means exactly that.
      expect(find.text('a rainy alley at night'), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();
      expect(generation.state, LifecycleState.ready);
      expect(find.byKey(LcKeys.generate), findsOneWidget);
    });
  });

  group('the result', () {
    Future<void> finish(WidgetTester tester) async {
      events.latest.emit(
        const JobResultsEvent(<JobResultRef>[imageResult]),
      );
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a picture gets the space, with Save, Share and Generate Again',
        (tester) async {
      final exporter = RecordingResultExporter();
      await tester.pumpWidget(await shell(exporter: exporter));
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      await finish(tester);

      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
      expect(find.byKey(LcKeys.resultSave), findsOneWidget);
      expect(find.byKey(LcKeys.resultShare), findsOneWidget);
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.resultSave));
      await tester.pump();
      await tester.pump();
      expect(exporter.saved, hasLength(1));
      expect(find.text('Saved to your gallery.'), findsOneWidget);
    });

    testWidgets('the controls recede once there is something to look at',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();

      List<double> dimming() => tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((widget) => widget.opacity)
          .toList();
      expect(dimming(), isEmpty);

      await generate(tester);
      await finish(tester);

      // Dimmed, not removed: still readable and still usable.
      expect(dimming().single, lessThan(1.0));
      expect(dimming().single, greaterThan(0.0));
      expect(find.byKey(LcKeys.controlsPane), findsOneWidget);
      expect(find.byKey(LcKeys.generate), findsOneWidget);
    });

    testWidgets('in one column the media comes before the controls',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(LcKeys.controlsPane)).dy,
        lessThan(tester.getTopLeft(find.byKey(LcKeys.contentPane)).dy),
      );

      await generate(tester);
      await finish(tester);

      // The hero is at the top; the form the user scrolls back to.
      expect(
        tester.getTopLeft(find.byKey(LcKeys.contentPane)).dy,
        lessThan(tester.getTopLeft(find.byKey(LcKeys.controlsPane)).dy),
      );
    });

    testWidgets('a clip offers the same things, and claims no preview',
        (tester) async {
      final exporter = RecordingResultExporter();
      await tester.pumpWidget(await shell(exporter: exporter));
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);

      events.latest.emit(
        const JobResultsEvent(<JobResultRef>[videoResult]),
      );
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(LcKeys.resultSave), findsOneWidget);
      expect(find.byKey(LcKeys.resultShare), findsOneWidget);
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);
      // No still, and no pretence of one.
      expect(find.byKey(LcKeys.resultPreview), findsNothing);
      expect(find.text('Your clip is ready.'), findsOneWidget);

      // Two lines of words get a panel the size of two lines of words, not the
      // room a picture would have taken. Measured, because an aligned box that
      // expands to its largest allowed size looks identical in the source.
      final panel = tester.getSize(find.byKey(LcKeys.resultPlaceholder));
      expect(panel.height, lessThan(320));
      expect(panel.height, greaterThanOrEqualTo(220));
    });
  });

  group('reconnecting', () {
    testWidgets('is a line, and takes nothing off the screen', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(
        const JobResultsEvent(<JobResultRef>[imageResult]),
      );
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);

      generation.beginReconnect();
      await tester.pump();

      expect(find.byKey(LcKeys.reconnecting), findsOneWidget);
      // Non-modal: nothing was pushed over the app, nothing covers the
      // picture, and the picture is still there to look at.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
      expect(find.byKey(LcKeys.resultSurface), findsOneWidget);
      // It sits above the content rather than on top of it.
      expect(
        tester.getBottomLeft(find.byKey(LcKeys.reconnecting)).dy,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byKey(LcKeys.resultPreview)).dy,
        ),
      );
    });

    testWidgets('failing ends in Reconnect and Choose another server',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await generate(tester);
      events.latest.emit(
        const JobResultsEvent(<JobResultRef>[imageResult]),
      );
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The gateway goes away for good, and the bounded reconnect runs out.
      gatewayGone = true;
      await session.reconnect();
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.recoveryPanel), findsOneWidget);
      expect(find.byKey(LcKeys.reconnectNow), findsOneWidget);
      expect(find.byKey(LcKeys.chooseAnotherServer), findsOneWidget);
      expect(find.byKey(LcKeys.reconnecting), findsNothing);
      // And the picture that was on screen is still on screen.
      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
    });
  });

  group('a workflow that vanished', () {
    testWidgets('is reported rather than quietly replaced', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();

      (workflows.api as ScriptedWorkflowsApi).summaries =
          const <WorkflowSummary>[];
      await workflows.reload();
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.missingWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflow), findsNothing);
    });
  });
}
