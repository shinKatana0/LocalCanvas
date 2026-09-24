/// Pressing Generate brings the status into view on the folded layout, and
/// leaves the unfolded one alone (T-0123).
///
/// Everything below is driven at a real width. There is no assertion anywhere
/// in this file that a scroll method was called: what is checked is where the
/// status card and the controls actually end up on screen, which is the only
/// thing the person holding the phone can see.
///
/// **About the widths.** The layout branch is decided by available width and
/// by nothing else (`docs/ui-ux.md`), so "folded" here is one narrow window
/// and "unfolded" is a window past the two-pane threshold. The unfolded cases
/// below use 1024 and 1280 for the full form, and a foldable's own ~841 dp with a
/// small workflow: at 841 the controls pane is at its 320 dp minimum, and the
/// test font — which draws every glyph as a square, roughly twice the width of
/// the real one — makes the Advanced toggle's two labels overflow a pane they
/// fit on a device. That is an artefact of the font in this harness and not a
/// defect in the app, so the narrow-pane case is driven with a workflow that
/// has no Advanced section rather than papered over.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/l10n.dart';
import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';

/// A workflow with a prompt and one setting, and no Advanced section at all.
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

void main() {
  late ScriptedJobsApi jobs;
  late GenerationController generation;

  void window(
    WidgetTester tester, {
    required double width,
    double height = 700,
  }) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Size screenOf(WidgetTester tester) =>
      tester.view.physicalSize / tester.view.devicePixelRatio;

  /// Whether a widget is somewhere a person can see it: laid out at all, and
  /// wholly inside the window.
  bool inView(WidgetTester tester, Finder finder) {
    if (finder.evaluate().isEmpty) return false;
    final rect = tester.getRect(finder);
    final screen = screenOf(tester);
    return rect.height > 0 && rect.top >= 0 && rect.bottom <= screen.height;
  }

  /// The scroll view inside [key]. `.first` is the outer one: a text field
  /// carries a scrollable of its own further down the tree.
  Finder scrollableIn(Key key) => find
      .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
      .first;

  ScrollPosition positionIn(WidgetTester tester, Key key) =>
      tester.state<ScrollableState>(scrollableIn(key)).position;

  /// The shell over one workflow, with a gateway that leaves the job queued —
  /// so the status card stays on screen to be looked for. It is followed over
  /// a socket that never says anything, which is how the job stays queued
  /// without a poll timer outliving the test.
  Future<Widget> shell({Map<String, Object?>? detail}) async {
    final body = detail ?? txt2imgDetail();
    jobs = ScriptedJobsApi(
      submission: const JobSubmission(jobId: 'j-8f21', state: JobState.queued),
    );
    final workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[body]),
        ),
        details: <String, WorkflowDetail>{
          body['id']! as String: WorkflowDetail.tryFromJson(body)!,
        },
      ),
    );
    addTearDown(workflows.dispose);

    final connection = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(
          e,
          testIdentity(capabilities: const GatewayCapabilities(events: true)),
        ),
      ),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);

    generation = GenerationController(api: jobs, events: FakeJobEventSource());
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

  /// Chooses the workflow and writes a prompt, leaving Generate ready.
  Future<void> compose(
    WidgetTester tester, {
    String id = 'example_txt2img',
    bool prompt = true,
  }) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard(id)));
    await tester.pumpAndSettle();
    if (!prompt) return;
    await tester.enterText(
      find.byKey(LcKeys.field('prompt')),
      'a rainy alley at night',
    );
    await tester.pumpAndSettle();
  }

  /// Scrolls until Generate is on screen, the way a user reaching for it does.
  Future<double> reachGenerate(WidgetTester tester, Key scrollView) async {
    await tester.scrollUntilVisible(
      find.byKey(LcKeys.generate),
      120,
      scrollable: scrollableIn(scrollView),
    );
    await tester.pumpAndSettle();
    final scrolled = positionIn(tester, scrollView).pixels;
    expect(
      scrolled,
      greaterThan(0),
      reason: 'the user had to scroll down to reach Generate',
    );
    expect(inView(tester, find.byKey(LcKeys.generate)), isTrue);
    return scrolled;
  }

  /// Long enough for the reveal to have finished, without ever settling: the
  /// queued state draws an indeterminate spinner that never does.
  Future<void> pumpReveal(WidgetTester tester) async {
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(LcMotion.normal);
    }
  }

  testWidgets('folded: Generate brings the status into view', (tester) async {
    window(tester, width: 400);
    await tester.pumpWidget(await shell());
    await tester.pumpAndSettle();
    await compose(tester);

    // The complaint itself, before anything is pressed: the form is longer
    // than this screen, and Generate is below the fold — which is where it
    // belongs, at the end of the form it submits.
    expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
    expect(
      inView(tester, find.byKey(LcKeys.generate)),
      isFalse,
      reason: 'the fixture must put Generate below the fold',
    );
    final scrolled = await reachGenerate(tester, LcKeys.shellCompact);

    await tester.tap(find.byKey(LcKeys.generate));
    await pumpReveal(tester);

    // What the user asked for: the status is on screen, without them having
    // scrolled back up to find it.
    expect(find.byKey(LcKeys.generationStatus), findsOneWidget);
    expect(find.text('Waiting in the queue'), findsOneWidget);
    expect(inView(tester, find.byKey(LcKeys.generationStatus)), isTrue);
    expect(positionIn(tester, LcKeys.shellCompact).pixels, lessThan(scrolled));
  });

  testWidgets('folded: a Generate that is refused moves nothing', (
    tester,
  ) async {
    // The reveal belongs to a submission, not to a tap. With the prompt empty
    // Generate is unavailable and says why, and the view stays where the user
    // put it.
    window(tester, width: 400);
    await tester.pumpWidget(await shell());
    await tester.pumpAndSettle();
    await compose(tester, prompt: false);
    final scrolled = await reachGenerate(tester, LcKeys.shellCompact);

    await tester.tap(find.byKey(LcKeys.generate), warnIfMissed: false);
    await pumpReveal(tester);

    expect(jobs.submits, 0);
    expect(positionIn(tester, LcKeys.shellCompact).pixels, scrolled);
  });

  for (final width in <double>[1024, 1280]) {
    testWidgets(
      'unfolded at ${width.toInt()}: Generate leaves the controls where the '
      'user left them',
      (tester) async {
        window(tester, width: width);
        await tester.pumpWidget(await shell());
        await tester.pumpAndSettle();
        await compose(tester);

        expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
        // There is somewhere to jump *from*, which is what makes the
        // assertion below mean anything: the pane scrolls, and it is scrolled.
        expect(
          positionIn(tester, LcKeys.controlsPane).maxScrollExtent,
          greaterThan(0),
        );
        final scrolled = await reachGenerate(tester, LcKeys.controlsPane);

        await tester.tap(find.byKey(LcKeys.generate));
        await pumpReveal(tester);

        // Nothing jumped: the pane is exactly where it was.
        expect(positionIn(tester, LcKeys.controlsPane).pixels, scrolled);
        // And this layout never had the problem — the status is in the other
        // pane, in view, with nothing having moved to put it there.
        expect(find.byKey(LcKeys.generationStatus), findsOneWidget);
        expect(inView(tester, find.byKey(LcKeys.generationStatus)), isTrue);
        expect(inView(tester, find.byKey(LcKeys.generate)), isTrue);
      },
    );
  }

  testWidgets('unfolded at a foldable\'s own width: nothing jumps there either', (
    tester,
  ) async {
    // 841 dp is the inner display this was reported on. The pane is at its
    // 320 dp minimum here, so the workflow is a small one — see the note at
    // the top of this file.
    window(tester, width: 841, height: 420);
    await tester.pumpWidget(await shell(detail: plainDetail()));
    await tester.pumpAndSettle();
    await compose(tester, id: 'plain');

    expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
    expect(
      positionIn(tester, LcKeys.controlsPane).maxScrollExtent,
      greaterThan(0),
    );
    final scrolled = await reachGenerate(tester, LcKeys.controlsPane);

    await tester.tap(find.byKey(LcKeys.generate));
    await pumpReveal(tester);

    expect(positionIn(tester, LcKeys.controlsPane).pixels, scrolled);
    expect(find.byKey(LcKeys.generationStatus), findsOneWidget);
    expect(inView(tester, find.byKey(LcKeys.generationStatus)), isTrue);
  });
}
