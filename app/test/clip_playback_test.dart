/// A clip result that plays (T-0211).
///
/// There is no decoder in a widget test, so what is asserted is everything the
/// app is responsible for *around* one, against a recording [ClipPlayback]:
///
/// * **what is fetched** — a clip only when there is something to play it
///   with, and then once — named by path, never counted;
/// * **what the player was handed** — the very bytes the gateway served;
/// * **the start state** — muted and playing — which the surface must apply,
///   because the fake player arrives as neither;
/// * **ownership** — every player opened is disposed exactly once, when the
///   clip on display changes or the surface goes, and never drawn after that.
///   `FakeClipPlayer.buildFrame` throws after dispose, so a frame drawn from a
///   released player fails the test rather than passing unnoticed.
///
/// What this file cannot say — that ExoPlayer decodes and loops on a phone —
/// is stated in the card rather than implied here.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/clip_playback.dart';
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

final Uint8List clipOne = Uint8List.fromList(List<int>.generate(64, (i) => i));
final Uint8List clipTwo = Uint8List.fromList(
  List<int>.generate(64, (i) => 255 - i),
);

String pathOf(String jobId) => '/api/v1/jobs/$jobId/result/0';

JobResultRef clipRef(String jobId) => JobResultRef(
  index: 0,
  kind: 'video',
  mediaType: 'video/mp4',
  path: pathOf(jobId),
);

JobResultRef pictureRef(String jobId) => JobResultRef(
  index: 0,
  kind: 'image',
  mediaType: 'image/png',
  path: pathOf(jobId),
);

/// A gateway that serves each path's own bytes with its own media type, and
/// names every fetch.
class MediaServer implements JobsApi {
  JobSubmission submission = const JobSubmission(
    jobId: 'j-one',
    state: JobState.queued,
  );
  final Map<String, (Uint8List, String)> served =
      <String, (Uint8List, String)>{};
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
    final entry = served[result.path];
    if (entry == null) {
      throw StateError('MediaServer has nothing at ${result.path}');
    }
    return ResultBytes(
      bytes: entry.$1,
      mediaType: entry.$2,
      filename: resultFilename(result, mediaType: entry.$2),
    );
  }
}

void main() {
  late MediaServer api;
  late FakeJobEventSource events;
  late GenerationController generation;
  late RecordingClipPlayback playback;
  late RecordingResultExporter exporter;

  Future<Widget> shell({bool withPlayback = true}) async {
    api = MediaServer();
    events = FakeJobEventSource();
    playback = RecordingClipPlayback();
    exporter = RecordingResultExporter();
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
    generation = GenerationController(
      api: api,
      events: events,
      exporter: exporter,
      clipPlayback: withPlayback ? playback : null,
    );
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

  Future<void> start(WidgetTester tester, {bool withPlayback = true}) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await shell(withPlayback: withPlayback));
    await tester.pumpAndSettle();
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

  /// Lets fetches, opens and the surface's own awaits land.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pump();
  }

  Future<void> generate(
    WidgetTester tester,
    String jobId,
    JobResultRef ref,
    Uint8List bytes, {
    bool again = false,
    bool spinning = false,
  }) async {
    // A spinner on screen never settles, which is the point of it; time is
    // pumped forward instead.
    Future<void> frames() => spinning
        ? tester.pump(const Duration(milliseconds: 500))
        : tester.pumpAndSettle();
    if (again) {
      await tester.ensureVisible(find.byKey(LcKeys.generateAgain));
      await frames();
      await tester.tap(find.byKey(LcKeys.generateAgain));
      await frames();
      await frames();
    }
    api.submission = JobSubmission(jobId: jobId, state: JobState.queued);
    api.served[ref.path] = (bytes, ref.mediaType);
    api.snapshots[jobId] = snapshotOf(
      JobState.completed,
      jobId: jobId,
      results: <JobResultRef>[ref],
    );
    await tester.ensureVisible(find.byKey(LcKeys.generate));
    await frames();
    await tester.tap(find.byKey(LcKeys.generate));
    await tester.pump();
    await tester.pump();
    events.latest.emit(JobResultsEvent(<JobResultRef>[ref]));
    events.latest.emit(const JobStateEvent(JobState.completed));
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pump();
    await tester.tap(find.byKey(key));
    await settle(tester);
  }

  group('what is fetched', () {
    testWidgets('with a player, the clip is fetched once and handed over', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);

      expect(api.fetched, <String>[pathOf('j-clip')]);
      expect(playback.opened, hasLength(1));
      // The very bytes the gateway served, not a copy that merely matches.
      expect(identical(playback.opened.single.bytes, clipOne), isTrue);
      expect(playback.opened.single.mediaType, 'video/mp4');
    });

    testWidgets('without one, nothing is fetched and the panel is as it was', (
      tester,
    ) async {
      await start(tester, withPlayback: false);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);

      expect(api.fetched, isEmpty);
      expect(find.byKey(LcKeys.resultClip), findsNothing);
      expect(find.text('Your clip is ready.'), findsOneWidget);
    });
  });

  group('the clip on screen', () {
    testWidgets('is the player\'s frame, muted and playing, with Save/Share', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);

      final player = playback.players.single;
      expect(find.byKey(LcKeys.resultClip), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(LcKeys.resultClip),
          matching: find.byKey(FakeClipPlayer.frameKey),
        ),
        findsOneWidget,
      );
      expect(find.byKey(LcKeys.resultPlaceholder), findsNothing);
      expect(player.muted, isTrue);
      expect(player.playing, isTrue);
      expect(find.byKey(LcKeys.resultSave), findsOneWidget);
      expect(find.byKey(LcKeys.resultShare), findsOneWidget);
    });

    testWidgets('a tap on the frame pauses it, and another plays it', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);
      final player = playback.players.single;

      await tapKey(tester, LcKeys.resultClipPlayPause);
      expect(player.playing, isFalse);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      await tapKey(tester, LcKeys.resultClipPlayPause);
      expect(player.playing, isTrue);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('the sound button turns the sound on, and off again', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);
      final player = playback.players.single;
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

      await tapKey(tester, LcKeys.resultClipSound);
      expect(player.muted, isFalse);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

      await tapKey(tester, LcKeys.resultClipSound);
      expect(player.muted, isTrue);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    });

    testWidgets('a clip this phone cannot play says so, and Save still works', (
      tester,
    ) async {
      await start(tester);
      playback.failure = const ClipPlaybackFailure();
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);

      expect(find.byKey(LcKeys.resultClip), findsNothing);
      expect(find.byKey(LcKeys.resultClipProblem), findsOneWidget);
      expect(find.text("This phone can't play the clip."), findsOneWidget);

      await tapKey(tester, LcKeys.resultSave);
      expect(exporter.saved.single.bytes, clipOne);
      // Save used the bytes already here.
      expect(api.fetched, <String>[pathOf('j-clip')]);
    });
  });

  group('almost full screen', () {
    testWidgets('draws the same player, and closing leaves it playing', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);

      await tapKey(tester, LcKeys.resultClipExpand);
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.resultViewer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(LcKeys.resultViewerClip),
          matching: find.byKey(FakeClipPlayer.frameKey),
        ),
        findsOneWidget,
      );
      // One decoder, not two.
      expect(playback.opened, hasLength(1));

      await tester.tap(find.byKey(LcKeys.resultViewerClose));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.resultViewer), findsNothing);
      final player = playback.players.single;
      expect(player.disposed, isFalse);
      expect(player.playing, isTrue);
    });

    testWidgets('closes before the player it draws is released', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-one', pictureRef('j-one'), tinyPng);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne, again: true);
      await tapKey(tester, LcKeys.resultClipExpand);
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.resultViewer), findsOneWidget);

      // Behind the viewer, the surface steps back to the picture.
      generation.showPreviousResult();
      await settle(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.resultViewer), findsNothing);
      expect(playback.players.single.disposeCount, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('every player is released exactly once', () {
    testWidgets('when a new job replaces the clip', (tester) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);
      final first = playback.players.single;

      await generate(tester, 'j-two', pictureRef('j-two'), tinyPng, again: true);

      expect(first.disposeCount, 1);
      expect(find.byKey(LcKeys.resultClip), findsNothing);
      expect(find.byKey(LcKeys.resultPreview), findsOneWidget);
    });

    testWidgets('when history steps from one clip to another and back', (
      tester,
    ) async {
      await start(tester);
      await generate(tester, 'j-one', clipRef('j-one'), clipOne);
      await generate(tester, 'j-two', clipRef('j-two'), clipTwo, again: true);
      expect(playback.players, hasLength(2));
      expect(playback.players[0].disposeCount, 1);
      expect(identical(playback.players[1].clip.bytes, clipTwo), isTrue);

      await tapKey(tester, LcKeys.resultPrevious);
      expect(playback.players, hasLength(3));
      expect(identical(playback.players[2].clip.bytes, clipOne), isTrue);
      expect(playback.players[1].disposeCount, 1);

      await tapKey(tester, LcKeys.resultNext);
      expect(playback.players, hasLength(4));
      expect(playback.players[2].disposeCount, 1);
      // Only the one on screen is alive.
      expect(
        playback.players.map((p) => p.disposeCount).toList(),
        <int>[1, 1, 1, 0],
      );
    });

    testWidgets('when the clip goes while its player is still opening', (
      tester,
    ) async {
      await start(tester);
      playback.gate = Completer<void>();
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);
      expect(playback.opened, hasLength(1));
      expect(playback.players, isEmpty);

      await generate(
        tester,
        'j-two',
        pictureRef('j-two'),
        tinyPng,
        again: true,
        spinning: true,
      );
      playback.gate!.complete();
      await settle(tester);

      expect(playback.players.single.disposeCount, 1);
      expect(find.byKey(LcKeys.resultClip), findsNothing);
    });

    testWidgets('when the shell itself goes', (tester) async {
      await start(tester);
      await generate(tester, 'j-clip', clipRef('j-clip'), clipOne);
      final player = playback.players.single;

      await tester.pumpWidget(const SizedBox());
      await settle(tester);

      expect(player.disposeCount, 1);
    });
  });
}
