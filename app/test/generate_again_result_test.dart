/// The picture on screen is the one the **last** generation produced (T-0175).
///
/// The reported defect is that Generate Again varies the seed and brings back
/// the same picture on the fastest workflow. Three causes were proposed: a
/// fast result landing before the previous one is cleared, a result widget
/// keyed on something that does not change between runs, and a submission
/// carrying a value captured before the reroll. This file drives two
/// generations whose results are **different bytes** and asks, of each
/// ordering the app can actually meet, which picture ends up painted.
///
/// Two things make these assertions worth something:
///
/// * **They read the pixels the render tree is painting**, not a field on the
///   controller and not the `ImageProvider` the widget was handed. A widget
///   can carry new bytes while `gaplessPlayback` keeps the old frame on
///   screen, so the provider is not proof that anything changed; `RawImage`'s
///   decoded `ui.Image` is what the user is looking at.
/// * **They name the bytes verbatim.** Every check spells out which of the two
///   pictures it expects, and the fetches are compared against the exact two
///   result paths, so a run that quietly fetched one thing twice fails rather
///   than counting to two and passing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

/// Two real, decodable 4×4 PNGs. Different bytes **and** different pixels, so
/// neither a byte comparison nor a look at the screen can take one for the
/// other, and a picture that failed to change is visible as the wrong colour
/// rather than as a missing widget.
final Uint8List pictureA = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGO4IycHRwzEcQDT'
  'IxGBFNCZswAAAABJRU5ErkJggg==',
);
final Uint8List pictureB = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGOQs7kDRwzEcQDs'
  'IxNhKYyREgAAAABJRU5ErkJggg==',
);

/// The first pixel of each, opaque. What the screen has to be painting.
const List<int> paintedA = <int>[220, 30, 30, 255];
const List<int> paintedB = <int>[30, 60, 220, 255];

const String firstResultPath = '/api/v1/jobs/j-first/result/0';
const String secondResultPath = '/api/v1/jobs/j-second/result/0';

/// A jobs API that can hold result fetches open, so a test can decide which of
/// two downloads answers first — the case where a second generation finishes
/// while the first picture is still on the wire.
class GatedJobsApi implements JobsApi {
  GatedJobsApi(this.inner);

  final ScriptedJobsApi inner;

  /// Every result path this API was asked for, in order. Compared verbatim,
  /// never counted.
  final List<String> fetched = <String>[];

  final List<Completer<ResultBytes>> held = <Completer<ResultBytes>>[];

  /// While true, a fetch parks in [held] instead of answering.
  bool hold = false;

  @override
  Future<JobSubmission> submit(
    Endpoint endpoint, {
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  }) => inner.submit(
    endpoint,
    workflowId: workflowId,
    inputs: inputs,
    translate: translate,
  );

  @override
  Future<JobSnapshot?> snapshot(Endpoint endpoint, String jobId) =>
      inner.snapshot(endpoint, jobId);

  @override
  Future<JobSnapshot> cancel(Endpoint endpoint, String jobId) =>
      inner.cancel(endpoint, jobId);

  @override
  Future<ResultBytes> fetchResult(Endpoint endpoint, JobResultRef result) {
    fetched.add(result.path);
    if (!hold) return inner.fetchResult(endpoint, result);
    final completer = Completer<ResultBytes>();
    held.add(completer);
    return completer.future;
  }
}

void main() {
  late ScriptedJobsApi jobs;
  late GatedJobsApi api;
  late FakeJobEventSource events;
  late GenerationController generation;
  late WorkflowsController workflows;
  late SessionController session;
  late ConnectionController connection;

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The shell, connected, over one workflow. [socket] false is the build that
  /// follows a job by snapshot alone.
  Future<Widget> shell({bool socket = true}) async {
    jobs = ScriptedJobsApi();
    api = GatedJobsApi(jobs);
    events = FakeJobEventSource();
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
        (e) => HandshakeSucceeded(
          e,
          GatewayIdentity(
            apiVersion: kSupportedApiVersion,
            gatewayVersion: '0.1.0',
            displayName: 'Studio PC',
            comfyStatus: ComfyStatus.ready,
            comfyDetail: null,
            capabilities: GatewayCapabilities(cancel: true, events: socket),
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
      api: api,
      events: socket ? events : null,
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

  Future<void> chooseWorkflow(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(LcKeys.field('prompt')),
      'a rainy alley at night',
    );
    await tester.pumpAndSettle();
  }

  JobResultRef refFor(String jobId) => JobResultRef(
    index: 0,
    kind: 'image',
    mediaType: 'image/png',
    path: '/api/v1/jobs/$jobId/result/0',
  );

  /// What the gateway will answer for the next run: a job id of its own and
  /// the bytes that job produced.
  void arm(String jobId, Uint8List bytes) {
    jobs.submission = JobSubmission(jobId: jobId, state: JobState.queued);
    jobs.resultBytes = ResultBytes(
      bytes: bytes,
      mediaType: 'image/png',
      filename: 'localcanvas-0.png',
    );
    jobs.snapshots
      ..clear()
      ..add(
        snapshotOf(
          JobState.completed,
          jobId: jobId,
          results: <JobResultRef>[refFor(jobId)],
        ),
      );
  }

  /// The pixels the render tree is painting, read off `RawImage`'s decoded
  /// image rather than off the widget that asked for it.
  ///
  /// The real async gap is what lets the decode finish; without it this reads
  /// whatever `gaplessPlayback` is still holding, which is exactly the stale
  /// frame the card is about.
  Future<List<int>> painted(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final found = find.descendant(
      of: find.byKey(LcKeys.resultPreview),
      matching: find.byType(RawImage),
    );
    if (found.evaluate().isEmpty) return const <int>[];
    final picture = tester.widget<RawImage>(found).image;
    if (picture == null) return const <int>[];
    final data = await tester.runAsync(
      () => picture.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return data!.buffer.asUint8List().take(4).toList();
  }

  /// The bytes the surface handed to `Image.memory`. Weaker than [painted] and
  /// kept beside it: the two failing together is a controller that kept the
  /// old result, the second failing alone is a screen that never repainted.
  Uint8List provided(WidgetTester tester) {
    final image = tester.widget<Image>(find.byKey(LcKeys.resultPreview));
    return (image.image as MemoryImage).bytes;
  }

  Future<void> pressGenerate(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.generate));
    await tester.pump();
    await tester.pump();
  }

  Future<void> settleResult(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  group('the second generation is what ends up on screen', () {
    testWidgets('results then state — the order the gateway documents',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      arm('j-first', pictureA);
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-first')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);
      expect(await painted(tester), paintedA);
      expect(provided(tester), pictureA);

      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();

      arm('j-second', pictureB);
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-second')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
      // Two different results were genuinely asked for. Spelled out, so a run
      // that fetched the first one twice cannot pass by arriving at two.
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);
    });

    testWidgets('state then results — a job already finished when the socket '
        'opens', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      arm('j-first', pictureA);
      await pressGenerate(tester);
      events.latest.emit(const JobStateEvent(JobState.completed));
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-first')]));
      await settleResult(tester);
      expect(await painted(tester), paintedA);

      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();

      arm('j-second', pictureB);
      await pressGenerate(tester);
      events.latest.emit(const JobStateEvent(JobState.completed));
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-second')]));
      await settleResult(tester);

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);
    });

    testWidgets('a completion with no results delta at all, twice over',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      arm('j-first', pictureA);
      await pressGenerate(tester);
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);
      await tester.pump();
      expect(await painted(tester), paintedA);

      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();

      arm('j-second', pictureB);
      await pressGenerate(tester);
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);
      await tester.pump();

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);
    });

    testWidgets('with no socket, followed by the snapshot alone',
        (tester) async {
      await tester.pumpWidget(await shell(socket: false));
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      Future<void> poll() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 6));
        }
      }

      arm('j-first', pictureA);
      await tester.tap(find.byKey(LcKeys.generate));
      await poll();
      expect(await painted(tester), paintedA);

      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();

      arm('j-second', pictureB);
      await tester.tap(find.byKey(LcKeys.generate));
      await poll();

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);
    });

    testWidgets('Generate Again and Generate inside one frame', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      arm('j-first', pictureA);
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-first')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);
      expect(await painted(tester), paintedA);

      arm('j-second', pictureB);
      await tester.tap(find.byKey(LcKeys.generateAgain));
      // One pump only: the form is never looked at, which is the fastest a
      // person can go round the loop.
      await tester.pump();
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-second')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);
    });

    testWidgets('the stale download that answers last is not what gets drawn',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      // Neither picture is allowed to arrive until this test says so.
      api.hold = true;

      arm('j-first', pictureA);
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-first')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pump();
      await tester.pump();

      // Off again while the first picture is still on the wire.
      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();
      arm('j-second', pictureB);
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-second')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await tester.pump();
      await tester.pump();

      // Both downloads were started, for two different results.
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);

      // The second answers first, and then the abandoned first answers — the
      // ordering that would repaint the previous run's picture over the
      // current one if the reply were not tied to the job that asked for it.
      api.held[1].complete(
        ResultBytes(
          bytes: pictureB,
          mediaType: 'image/png',
          filename: 'localcanvas-0.png',
        ),
      );
      await tester.pump();
      await tester.pump();
      api.held[0].complete(
        ResultBytes(
          bytes: pictureA,
          mediaType: 'image/png',
          filename: 'localcanvas-0.png',
        ),
      );
      await settleResult(tester);

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);

      // And it is still the second picture after the surface redraws for a
      // reason of its own. Without this the check is blind to a stale reply
      // that was written into the result and simply not drawn yet: the next
      // repaint for any reason would put the previous run's picture back, and
      // a reconnect indicator is the smallest honest thing that repaints
      // without touching the result (`docs/recovery.md`).
      generation.beginReconnect();
      await settleResult(tester);
      expect(find.byKey(LcKeys.reconnecting), findsOneWidget);
      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
    });

    testWidgets('a slow generation still ends with its own picture',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await chooseWorkflow(tester);

      arm('j-first', pictureA);
      await pressGenerate(tester);
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-first')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);
      expect(await painted(tester), paintedA);

      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();

      arm('j-second', pictureB);
      await pressGenerate(tester);
      events.latest.emit(const JobStateEvent(JobState.running));
      for (var step = 1; step <= 28; step++) {
        events.latest.emit(JobProgressEvent(JobProgress(step: step, total: 28)));
        await tester.pump(const Duration(milliseconds: 400));
      }
      // Still the job's own picture after all that waiting, and still not the
      // one that was on screen when it started.
      events.latest.emit(JobResultsEvent(<JobResultRef>[refFor('j-second')]));
      events.latest.emit(const JobStateEvent(JobState.completed));
      await settleResult(tester);

      expect(await painted(tester), paintedB);
      expect(provided(tester), pictureB);
      expect(api.fetched, <String>[firstResultPath, secondResultPath]);
    });
  });
}
