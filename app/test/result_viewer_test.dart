/// The result picture, almost full screen (T-0210).
///
/// Three things make these assertions worth something:
///
/// * **size is the painted picture, not the widget's box.** The viewer's image
///   fills its box and paints the picture contained inside it, and the preview
///   takes the pane's width, so comparing the two boxes would compare two
///   layouts rather than two pictures. The rectangle actually painted is
///   computed with `applyBoxFit` from the image's own size — the same function
///   `RenderImage` paints with;
/// * **the picture is portrait** (2×3), the shape the preview's height cap
///   squeezes, and it is a different colour from the second picture, so "the
///   viewer shows what was tapped" is read off the pixels being painted
///   (T-0175's technique) rather than off the bytes a widget was handed;
/// * **no fetch is counted — the fetches are named.** Opening and closing the
///   viewer must leave the list of result paths asked for exactly as it was.
library;

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
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// A 2×3 red picture and a 3×2 blue one.
final Uint8List portraitRed = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEElEQVR4nGM4oaEBRAwoFABI'
  'vQaRikDLogAAAABJRU5ErkJggg==',
);
final Uint8List landscapeBlue = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGPQ0DgBQQxwFgA9'
  '9AaRV6BAuQAAAABJRU5ErkJggg==',
);
const List<int> paintedRed = <int>[200, 40, 40, 255];
const List<int> paintedBlue = <int>[40, 40, 200, 255];

String pathOf(String jobId) => '/api/v1/jobs/$jobId/result/0';

/// A gateway that serves each job's own bytes and names every fetch.
class PictureServer implements JobsApi {
  JobSubmission submission = const JobSubmission(
    jobId: 'j-one',
    state: JobState.queued,
  );
  final Map<String, Uint8List> served = <String, Uint8List>{};
  final Set<String> gone = <String>{};
  final List<String> fetched = <String>[];
  final Map<String, JobSnapshot> snapshots = <String, JobSnapshot>{};

  @override
  Future<JobSubmission> submit(
    Endpoint endpoint, {
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  }) async => submission;

  @override
  Future<JobSnapshot?> snapshot(Endpoint endpoint, String jobId) async =>
      snapshots[jobId];

  @override
  Future<JobSnapshot> cancel(Endpoint endpoint, String jobId) async =>
      throw StateError('cancel is not part of this file');

  @override
  Future<ResultBytes> fetchResult(
    Endpoint endpoint,
    JobResultRef result,
  ) async {
    fetched.add(result.path);
    if (gone.contains(result.path)) throw const JobFailure.unreachable();
    final bytes = served[result.path];
    if (bytes == null) {
      throw StateError('PictureServer has nothing at ${result.path}');
    }
    return ResultBytes(
      bytes: bytes,
      mediaType: 'image/png',
      filename: 'localcanvas-0.png',
    );
  }
}

void main() {
  late PictureServer api;
  late FakeJobEventSource events;
  late GenerationController generation;

  void view(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<Widget> shell() async {
    api = PictureServer();
    events = FakeJobEventSource();
    final body = txt2imgDetail();
    final workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[body]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(body)!,
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

  Future<void> compose(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(LcKeys.field('prompt')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(LcKeys.field('prompt')),
      'a rainy alley at night',
    );
    await tester.pumpAndSettle();
  }

  /// Waits, bounded, for the job to complete and its picture to stop loading,
  /// rather than pumping a fixed number of frames and hoping. (Written while
  /// chasing a failure it turned out not to explain — the result had loaded,
  /// and its sliver had not been built; see [reveal]. Kept because a wait on
  /// the condition says what it waits for.)
  Future<void> settleResult(WidgetTester tester) async {
    for (var round = 0; round < 50; round++) {
      await tester.pump();
      if (!generation.isLoadingPreview &&
          generation.state == LifecycleState.completed) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
    expect(generation.isLoadingPreview, isFalse, reason: 'never settled');
  }

  /// One generation, end to end, whose result is [result] served as [bytes].
  Future<void> generate(
    WidgetTester tester,
    String jobId,
    Uint8List? bytes, {
    bool again = false,
    JobResultRef? result,
  }) async {
    if (again) {
      await tester.ensureVisible(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();
    }
    final ref =
        result ??
        JobResultRef(
          index: 0,
          kind: 'image',
          mediaType: 'image/png',
          path: pathOf(jobId),
        );
    api.submission = JobSubmission(jobId: jobId, state: JobState.queued);
    if (bytes != null) api.served[ref.path] = bytes;
    api.snapshots[jobId] = snapshotOf(
      JobState.completed,
      jobId: jobId,
      results: <JobResultRef>[ref],
    );
    await tester.ensureVisible(find.byKey(LcKeys.generate));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.generate));
    await tester.pump();
    await tester.pump();
    events.latest.emit(JobResultsEvent(<JobResultRef>[ref]));
    events.latest.emit(const JobStateEvent(JobState.completed));
    await settleResult(tester);
  }


  /// The pixels being painted under [key], read off `RawImage`'s decoded image
  /// after a real async gap that lets a decode finish (T-0175's technique).
  Future<List<int>> painted(WidgetTester tester, Key key) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final found = find.descendant(
      of: find.byKey(key),
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

  /// The rectangle a picture of [intrinsic] shape is painted into inside the
  /// box of the image under [key] — what the eye sees, not the layout box.
  Rect paintedRect(WidgetTester tester, Key key, Size intrinsic) {
    final box = tester.getRect(find.byKey(key));
    final fitted = applyBoxFit(BoxFit.contain, intrinsic, box.size);
    return Alignment.center.inscribe(fitted.destination, box);
  }

  /// Brings the result under [key] on screen. In one column the result sits
  /// above the form and Generate is at the bottom of it, so after pressing
  /// Generate the result can be far enough above the viewport that its sliver
  /// is not built at all — and `ensureVisible` needs an element to exist.
  Future<void> reveal(WidgetTester tester, Key key) async {
    final compact = find.byKey(LcKeys.shellCompact);
    if (compact.evaluate().isNotEmpty) {
      await tester.scrollUntilVisible(
        find.byKey(key),
        -200,
        scrollable: find
            .descendant(of: compact, matching: find.byType(Scrollable))
            .first,
      );
    }
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await reveal(tester, LcKeys.resultPreview);
    await tester.tap(find.byKey(LcKeys.resultPreview));
    await tester.pumpAndSettle();
  }

  Future<void> expectBackAtThePreview(WidgetTester tester) async {
    expect(find.byKey(LcKeys.resultViewer), findsNothing);
    expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
    expect(await painted(tester, LcKeys.resultPreview), paintedRed);
    // The form underneath was never touched.
    expect(find.text('a rainy alley at night'), findsOneWidget);
    expect(api.fetched, <String>[pathOf('j-one')]);
  }

  group('a tap on the picture opens it larger', () {
    for (final (label, size) in <(String, Size)>[
      ('folded', const Size(360, 800)),
      ('unfolded', const Size(840, 700)),
    ]) {
      testWidgets('$label: the same picture, painted larger, fetched once', (
        tester,
      ) async {
        view(tester, size);
        await tester.pumpWidget(await shell());
        await tester.pumpAndSettle();
        await compose(tester);
        await generate(tester, 'j-one', portraitRed);
        await reveal(tester, LcKeys.resultPreview);
        expect(await painted(tester, LcKeys.resultPreview), paintedRed);
        final preview = paintedRect(
          tester,
          LcKeys.resultPreview,
          const Size(2, 3),
        );
        expect(find.byKey(LcKeys.resultViewer), findsNothing);

        await open(tester);

        expect(find.byKey(LcKeys.resultViewer), findsOneWidget);
        expect(await painted(tester, LcKeys.resultViewer), paintedRed);
        final large = paintedRect(
          tester,
          LcKeys.resultViewerImage,
          const Size(2, 3),
        );
        expect(
          large.height,
          greaterThan(preview.height),
          reason: 'viewer $large, preview $preview',
        );
        expect(large.width, greaterThan(preview.width));
        // Inside the screen: "almost" full screen, never past it.
        expect(Offset.zero & size, _contains(large));
        expect(api.fetched, <String>[pathOf('j-one')]);
      });
    }
  });

  group('three ways back, all to the preview as it was', () {
    Future<void> openOnRed(WidgetTester tester) async {
      view(tester, const Size(360, 800));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);
      await generate(tester, 'j-one', portraitRed);
      await open(tester);
      expect(find.byKey(LcKeys.resultViewer), findsOneWidget);
    }

    testWidgets('the close button', (tester) async {
      await openOnRed(tester);
      await tester.tap(find.byKey(LcKeys.resultViewerClose));
      await tester.pumpAndSettle();
      await expectBackAtThePreview(tester);
    });

    testWidgets('system Back', (tester) async {
      await openOnRed(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await expectBackAtThePreview(tester);
    });

    testWidgets('a tap on the picture', (tester) async {
      await openOnRed(tester);
      await tester.tap(find.byKey(LcKeys.resultViewerImage));
      await tester.pumpAndSettle();
      await expectBackAtThePreview(tester);
    });

    testWidgets('a tap on a zoomed picture unzooms it, and the next closes', (
      tester,
    ) async {
      await openOnRed(tester);
      final transform = tester
          .widget<InteractiveViewer>(
            find.descendant(
              of: find.byKey(LcKeys.resultViewer),
              matching: find.byType(InteractiveViewer),
            ),
          )
          .transformationController!;
      transform.value = Matrix4.diagonal3Values(2.5, 2.5, 1);
      await tester.pump();

      // The middle of the viewer, not of the image: a zoomed image's own centre
      // is wherever the zoom put it, which may be off the screen.
      await tester.tap(find.byKey(LcKeys.resultViewer));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.resultViewer), findsOneWidget);
      expect(transform.value, Matrix4.identity());

      await tester.tap(find.byKey(LcKeys.resultViewer));
      await tester.pumpAndSettle();
      await expectBackAtThePreview(tester);
    });
  });

  group('what it shows', () {
    testWidgets('the picture that was tapped, while the surface moves on', (
      tester,
    ) async {
      // Tall, as the history tests are: this is about which picture, not about
      // layout, and a short window adds scrolling that is not under test.
      view(tester, const Size(420, 2400));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);
      await generate(tester, 'j-one', landscapeBlue);
      await generate(tester, 'j-two', portraitRed, again: true);
      await open(tester);
      expect(await painted(tester, LcKeys.resultViewer), paintedRed);

      // Behind the viewer, the surface steps back to the blue one.
      generation.showPreviousResult();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(api.fetched.last, pathOf('j-one'));

      expect(await painted(tester, LcKeys.resultViewer), paintedRed);

      await tester.tap(find.byKey(LcKeys.resultViewerClose));
      await tester.pumpAndSettle();
      expect(await painted(tester, LcKeys.resultPreview), paintedBlue);
    });

    testWidgets('a clip has nothing to open', (tester) async {
      view(tester, const Size(360, 800));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);
      await generate(
        tester,
        'j-clip',
        null,
        result: const JobResultRef(
          index: 0,
          kind: 'video',
          mediaType: 'video/mp4',
          path: '/api/v1/jobs/j-clip/result/0',
        ),
      );
      await reveal(tester, LcKeys.resultPlaceholder);
      expect(find.byKey(LcKeys.resultPlaceholder), findsOneWidget);
      expect(find.byKey(LcKeys.resultOpenViewer), findsNothing);
      await tester.tap(find.byKey(LcKeys.resultPlaceholder));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.resultViewer), findsNothing);
    });

    testWidgets('a picture that could not be fetched has nothing to open', (
      tester,
    ) async {
      view(tester, const Size(360, 800));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await compose(tester);
      api.gone.add(pathOf('j-one'));
      await generate(tester, 'j-one', portraitRed);
      await reveal(tester, LcKeys.resultProblem);
      expect(find.byKey(LcKeys.resultProblem), findsOneWidget);
      expect(find.byKey(LcKeys.resultOpenViewer), findsNothing);
      await tester.tap(find.byKey(LcKeys.resultProblem));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.resultViewer), findsNothing);
    });
  });
}

Matcher _contains(Rect inner) => predicate<Rect>(
  (outer) =>
      inner.left >= outer.left - 0.5 &&
      inner.top >= outer.top - 0.5 &&
      inner.right <= outer.right + 0.5 &&
      inner.bottom <= outer.bottom + 0.5,
  'contains $inner',
);
