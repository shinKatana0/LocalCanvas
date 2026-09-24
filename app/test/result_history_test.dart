/// A way back to a result from earlier in this session (T-0178).
///
/// The feature is a list of **job ids**, not of images: the gateway serves every
/// result of its current run at `/api/v1/jobs/{job_id}/result/{index}`, so the
/// app keeps addresses and fetches bytes when it needs them.
///
/// Four things make these assertions worth something, and three of them are
/// inherited from T-0175 rather than rediscovered:
///
/// * **they read the pixels the render tree is painting.** `RawImage`'s decoded
///   `ui.Image`, not the controller's list and not the `ImageProvider` the
///   widget was handed — `Image.memory` with `gaplessPlayback: true` can carry
///   new bytes while still painting the old frame, so neither of the other two
///   is proof that the screen changed. Asserting `resultHistory` would prove
///   nothing at all;
/// * **every picture is a different colour**, so a result that failed to change
///   shows up as the wrong colour and not as a missing widget;
/// * **the fetches are named verbatim.** Each check spells out which result
///   paths were asked for, in order, so a run that fetched one thing twice
///   fails instead of counting to two and passing;
/// * **identity is asserted as identity.** What a tap acts on is a job id and an
///   index; the "2 of 3" on screen is a label, and the eviction test is what
///   separates the two.
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
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/profile_transport.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// Four real, decodable 4×4 PNGs, each a different solid colour. Different
/// bytes **and** different pixels, so neither a byte comparison nor a look at
/// the screen can take one for another.
final Uint8List pictureA = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR42mO4IycHRwzE'
  'cQDTIxGB/NE2PAAAAABJRU5ErkJggg==',
);
final Uint8List pictureB = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR42mOQs7kDRwzE'
  'cQDsIxNhwY0+nQAAAABJRU5ErkJggg==',
);
final Uint8List pictureC = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR42mOQOxEFRwzE'
  'cQAEkhQBNEIGpgAAAABJRU5ErkJggg==',
);
final Uint8List pictureD = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR42mN4dkIDjhiI'
  '4wAACAEdYRo0KmgAAAAASUVORK5CYII=',
);

/// The first pixel of each, opaque. What the screen has to be painting.
const List<int> paintedA = <int>[220, 30, 30, 255];
const List<int> paintedB = <int>[30, 60, 220, 255];
const List<int> paintedC = <int>[30, 200, 90, 255];
const List<int> paintedD = <int>[230, 200, 40, 255];

String pathOf(String jobId) => '/api/v1/jobs/$jobId/result/0';

JobResultRef refFor(String jobId) => JobResultRef(
  index: 0,
  kind: 'image',
  mediaType: 'image/png',
  path: pathOf(jobId),
);

/// A gateway that remembers its jobs, which is the property this whole feature
/// rests on: a result stays fetchable after its job stopped being the current
/// one, and stops being fetchable if this test says so.
class ResultServer implements JobsApi {
  JobSubmission submission = const JobSubmission(
    jobId: 'j-one',
    state: JobState.queued,
  );

  /// The bytes behind each result path.
  final Map<String, Uint8List> served = <String, Uint8List>{};

  /// Paths the gateway will no longer answer for — a restarted gateway, or a
  /// job it has forgotten.
  final Set<String> gone = <String>{};

  /// Paths whose fetch parks instead of answering, so a test can decide when a
  /// download lands and what has happened on screen by then.
  final Set<String> slow = <String>{};

  /// The parked fetches, in the order they were asked for.
  final List<Completer<ResultBytes>> held = <Completer<ResultBytes>>[];

  /// Every result path this API was asked for, in order. Compared verbatim,
  /// never counted.
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
      // Not a 404 — a test that forgot to say what this path holds.
      throw StateError('ResultServer has nothing at ${result.path}');
    }
    final answer = ResultBytes(
      bytes: bytes,
      mediaType: 'image/png',
      filename: 'localcanvas-0.png',
    );
    if (!slow.contains(result.path)) return answer;
    final completer = Completer<ResultBytes>();
    held.add(completer);
    return completer.future;
  }
}

/// The share sheet, recorded rather than performed.
class RecordingProfileTransport implements ProfileTransport {
  final List<ProfileDocument> sent = <ProfileDocument>[];

  String get sentText => sent.last.text;

  @override
  Future<void> send(ProfileDocument document) async => sent.add(document);

  @override
  Future<String?> receive({String? typeLabel}) async => null;
}

/// A workflow with a prompt and one setting and no Advanced section.
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
  late ResultServer api;
  late FakeJobEventSource events;
  late GenerationController generation;
  late WorkflowsController workflows;
  late RecordingProfileTransport transport;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    transport = RecordingProfileTransport();
  });

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The shell, connected, over one workflow. [stores] true wires the real
  /// device stores and the profile transport, for the test that is about what
  /// gets written down.
  Future<Widget> shell({bool stores = false}) async {
    api = ResultServer();
    events = FakeJobEventSource();

    final body = plainDetail();
    workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[body]),
        ),
        details: <String, WorkflowDetail>{
          'plain': WorkflowDetail.tryFromJson(body)!,
        },
      ),
      settings: stores ? PreferencesWorkflowSettingsStore() : null,
      drafts: stores ? PreferencesWorkflowDraftStore() : null,
      setups: stores ? PreferencesWorkflowSetupStore() : null,
      profiles: stores ? transport : null,
    );
    addTearDown(workflows.dispose);

    final connection = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(
          e,
          testIdentity(
            capabilities: const GatewayCapabilities(events: true),
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

  Future<void> compose(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    // The card's own title rather than its centre, which the test font puts
    // under the "What this does" button inside the card.
    await tester.tap(
      find.descendant(
        of: find.byKey(LcKeys.workflowCard('plain')),
        matching: find.text('Plain'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(LcKeys.field('prompt')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(LcKeys.field('prompt')),
      'a rainy alley at night',
    );
    await tester.pumpAndSettle();
  }

  /// The pixels the render tree is painting, read off `RawImage`'s decoded
  /// image rather than off the widget that asked for it (the technique T-0175
  /// established, reused here unchanged).
  ///
  /// The real async gap is what lets the decode finish; without it this reads
  /// whatever `gaplessPlayback` is still holding.
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

  /// One whole generation, end to end, exactly as the app drives it: Generate,
  /// the gateway's result delta, the state that commits it.
  Future<void> generate(
    WidgetTester tester,
    String jobId,
    Uint8List bytes, {
    bool again = false,
  }) async {
    if (again) {
      await tester.tap(find.byKey(LcKeys.generateAgain));
      await tester.pumpAndSettle();
    }
    api.submission = JobSubmission(jobId: jobId, state: JobState.queued);
    api.served[pathOf(jobId)] = bytes;
    api.snapshots[jobId] = snapshotOf(
      JobState.completed,
      jobId: jobId,
      results: <JobResultRef>[refFor(jobId)],
    );
    // Scrolled to on a window too short to hold the whole form, which is the
    // point of the unfolded case below; a no-op on the tall ones.
    await tester.ensureVisible(find.byKey(LcKeys.generate));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.generate));
    await tester.pump();
    await tester.pump();
    events.latest.emit(JobResultsEvent(<JobResultRef>[refFor(jobId)]));
    events.latest.emit(const JobStateEvent(JobState.completed));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> step(WidgetTester tester, Key which) async {
    await tester.ensureVisible(find.byKey(which));
    // Pumped rather than settled: a fetch still in flight leaves a spinner in
    // the placeholder, and there is nothing for a settle to wait for the end
    // of.
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.tap(find.byKey(which));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// What the history holds, as the two things that identify each entry.
  List<String> identities() => <String>[
    for (final entry in generation.resultHistory)
      '${entry.jobId}#${entry.result.index}',
  ];

  group('three generations, and the previous two still reachable', () {
    testWidgets('each one shows its own picture, and the fetches say which',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      expect(await painted(tester), paintedA);
      await generate(tester, 'j-two', pictureB, again: true);
      expect(await painted(tester), paintedB);
      await generate(tester, 'j-three', pictureC, again: true);

      // The newest is what a finished generation shows, and it says so.
      expect(await painted(tester), paintedC);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(
        api.fetched,
        <String>[pathOf('j-one'), pathOf('j-two'), pathOf('j-three')],
      );

      await step(tester, LcKeys.resultPrevious);
      expect(await painted(tester), paintedB);
      expect(find.text('2 of 3'), findsOneWidget);

      await step(tester, LcKeys.resultPrevious);
      expect(await painted(tester), paintedA);
      expect(find.text('1 of 3'), findsOneWidget);
      // At the oldest kept there is nowhere further back.
      expect(
        tester.widget<IconButton>(find.byKey(LcKeys.resultPrevious)).onPressed,
        isNull,
      );

      await step(tester, LcKeys.resultNext);
      expect(await painted(tester), paintedB);
      expect(find.text('2 of 3'), findsOneWidget);

      await step(tester, LcKeys.resultNext);
      expect(await painted(tester), paintedC);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byKey(LcKeys.resultNext)).onPressed,
        isNull,
      );

      // Spelled out: every step went to the gateway for the result it named,
      // and no step fetched somebody else's.
      expect(api.fetched, <String>[
        pathOf('j-one'),
        pathOf('j-two'),
        pathOf('j-three'),
        pathOf('j-two'),
        pathOf('j-one'),
        pathOf('j-two'),
        pathOf('j-three'),
      ]);
      expect(identities(), <String>['j-one#0', 'j-two#0', 'j-three#0']);
    });

    testWidgets('a new generation puts the newest back on screen', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);
      await generate(tester, 'j-three', pictureC, again: true);

      // Deliberately looking at the oldest when the next one finishes.
      await step(tester, LcKeys.resultPrevious);
      await step(tester, LcKeys.resultPrevious);
      expect(await painted(tester), paintedA);
      expect(find.text('1 of 3'), findsOneWidget);

      await generate(tester, 'j-four', pictureD, again: true);

      expect(await painted(tester), paintedD);
      expect(find.text('4 of 4'), findsOneWidget);
      expect(generation.viewedResult, isNull);
    });
  });

  group('the unfolded layout, where the result area has a bounded height', () {
    // The narrow layout scrolls, so the way back is reachable there whatever it
    // costs in height. The wide one gives the creation area a **finite** box,
    // and everything under the picture has to fit inside it — which is the one
    // thing inserting a row under the picture can break, and the thing a test
    // pointed only at the folded screen would never see.
    //
    // Three heights, because the picture's own cap saturates on a tall window:
    // below it, the room left for the controls is what decides whether they are
    // on screen at all.
    for (final double height in <double>[640, 700, 820]) {
      testWidgets(
          'at ${height.toInt()} dp the way back fits, and so does everything '
          'under it', (tester) async {
        tester.view.physicalSize = Size(1024, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(await shell());
        await tester.pumpAndSettle();
        expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
        await compose(tester);

        await generate(tester, 'j-one', pictureA);
        await generate(tester, 'j-two', pictureB, again: true);
        await generate(tester, 'j-three', pictureC, again: true);

        /// Whole, inside the window, and not merely present in the tree.
        void inView(Finder finder, String what) {
          expect(finder, findsOneWidget, reason: what);
          final rect = tester.getRect(finder);
          expect(rect.height, greaterThan(0), reason: what);
          expect(rect.top, greaterThanOrEqualTo(0.0), reason: what);
          expect(rect.bottom, lessThanOrEqualTo(height), reason: what);
        }

        // The decode first: until it finishes, `Image.memory` has no intrinsic
        // size and lays out at zero height, which would make every measurement
        // below a fact about this harness instead of about the layout.
        expect(await painted(tester), paintedC);

        inView(find.byKey(LcKeys.resultPreview), 'the picture');
        inView(find.byKey(LcKeys.resultHistory), 'the way back');
        // The control the row was inserted above. If room was taken from what
        // was already there rather than made for the row, this is what goes
        // off the bottom.
        inView(find.byKey(LcKeys.generateAgain), 'Generate Again');
        expect(find.text('3 of 3'), findsOneWidget);

        await step(tester, LcKeys.resultPrevious);
        expect(await painted(tester), paintedB);
        expect(find.text('2 of 3'), findsOneWidget);
        expect(api.fetched.last, pathOf('j-two'));
      });
    }
  });

  group('the cap', () {
    testWidgets('the oldest falls off, and nothing on screen is broken by it',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      // Two more than the bound. The first two must be gone and the rest must
      // still name their own jobs.
      const int over = GenerationController.kResultHistoryLimit + 2;
      for (var n = 1; n <= over; n++) {
        await generate(
          tester,
          'j-$n',
          // The two that matter to the eye are the oldest kept and the newest;
          // the rest only have to be distinct addresses.
          n == 3 ? pictureA : (n == over ? pictureD : pictureB),
          again: n > 1,
        );
      }

      expect(identities(), <String>[
        for (var n = 3; n <= over; n++) 'j-$n#0',
      ]);
      expect(generation.resultHistory.length,
          GenerationController.kResultHistoryLimit);
      expect(find.text('10 of 10'), findsOneWidget);
      expect(await painted(tester), paintedD);

      // All the way back to the oldest still kept: a real picture, not an
      // empty tile, and it is that job's own.
      for (var n = 1; n < GenerationController.kResultHistoryLimit; n++) {
        await step(tester, LcKeys.resultPrevious);
      }
      expect(find.text('1 of 10'), findsOneWidget);
      expect(await painted(tester), paintedA);
      expect(api.fetched.last, pathOf('j-3'));
      expect(find.byKey(LcKeys.resultProblem), findsNothing);
    });
  });

  group('identity is a job id plus an index', () {
    test('two results are the same one only when both halves agree', () {
      const first = ResultHistoryEntry(
        jobId: 'j-one',
        result: JobResultRef(
          index: 0,
          kind: 'image',
          mediaType: 'image/png',
          path: '/api/v1/jobs/j-one/result/0',
        ),
      );
      const sameJobSameIndex = ResultHistoryEntry(
        jobId: 'j-one',
        result: JobResultRef(
          index: 0,
          kind: 'image',
          mediaType: 'image/png',
          // A different path for the same job and index is still the same
          // result: the address is derived, the identity is not.
          path: '/api/v1/jobs/j-one/result/0?x=1',
        ),
      );
      const sameJobOtherIndex = ResultHistoryEntry(
        jobId: 'j-one',
        result: JobResultRef(
          index: 1,
          kind: 'image',
          mediaType: 'image/png',
          path: '/api/v1/jobs/j-one/result/1',
        ),
      );
      const otherJobSameIndex = ResultHistoryEntry(
        jobId: 'j-two',
        result: JobResultRef(
          index: 0,
          kind: 'image',
          mediaType: 'image/png',
          path: '/api/v1/jobs/j-two/result/0',
        ),
      );

      expect(first.sameAs(sameJobSameIndex), isTrue);
      expect(first.sameAs(sameJobOtherIndex), isFalse);
      // The one that matters: index alone would call these the same, and every
      // job's first output has index 0.
      expect(first.sameAs(otherJobSameIndex), isFalse);
    });

    testWidgets('an evicted entry is gone, and does not resolve to whatever '
        'took its place', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      final oldest = generation.resultHistory.single;
      expect(oldest.jobId, 'j-one');

      // Enough more that j-one falls off the front. Something else is at
      // position 0 now.
      for (var n = 2; n <= GenerationController.kResultHistoryLimit + 1; n++) {
        await generate(
          tester,
          'j-$n',
          n == GenerationController.kResultHistoryLimit + 1
              ? pictureD
              : pictureB,
          again: true,
        );
      }
      expect(identities().first, 'j-2#0');
      expect(identities(), isNot(contains('j-one#0')));
      expect(await painted(tester), paintedD);

      final asked = List<String>.from(api.fetched);
      generation.showResult(oldest);
      await tester.pump();
      await tester.pump();

      // Nothing happened: no fetch, no change of what is painted. A history
      // that resolved by position would have shown `j-2`'s picture instead.
      expect(api.fetched, asked);
      expect(generation.viewedResult, isNull);
      expect(await painted(tester), paintedD);
      expect(find.text('10 of 10'), findsOneWidget);
    });

    testWidgets('an entry that is still kept resolves to its own job, though '
        'its position has moved', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);
      final second = generation.resultHistory.last;
      expect(second.jobId, 'j-two');
      // Position 1 of two entries when it was taken.
      expect(generation.resultHistory.indexOf(second), 1);

      await generate(tester, 'j-three', pictureC, again: true);
      // Position 1 now means something else entirely — this one moved.
      expect(generation.resultHistory.indexOf(second), 1);
      expect(generation.resultHistory.last.jobId, 'j-three');

      generation.showResult(second);
      await tester.pump();
      await tester.pump();

      expect(await painted(tester), paintedB);
      expect(api.fetched.last, pathOf('j-two'));
      expect(generation.viewedResult!.jobId, 'j-two');
    });
  });

  group('a result evicted while it is on screen (T-0204)', () {
    testWidgets('is forgotten, so the label and the picture both say the '
        'newest', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);
      await generate(tester, 'j-three', pictureC, again: true);
      await step(tester, LcKeys.resultPrevious);
      await step(tester, LcKeys.resultPrevious);
      // Looking at the oldest, and the screen agrees with itself.
      expect(find.text('1 of 3'), findsOneWidget);
      expect(await painted(tester), paintedA);
      expect(generation.viewedResult!.jobId, 'j-one');

      // What every listener is told, at the moment it is told it. The screen
      // cannot tell this apart — a frame merges the notifications before it —
      // but a listener reads the controller at each one, so a check that ran
      // after `notifyListeners` rather than before would hand it a viewed
      // result the label cannot place.
      final heard = <String>[];
      void listener() {
        final viewing = generation.viewedResult;
        final count = generation.resultHistory.length;
        final at = generation.viewedPosition;
        heard.add(
          '${viewing == null ? 'newest' : 'viewing ${viewing.jobId}'} '
          'labelled ${(at ?? count - 1) + 1} of $count'
          '${viewing != null && at == null ? ' — NOT IN THE HISTORY' : ''}',
        );
      }

      generation.addListener(listener);
      addTearDown(() => generation.removeListener(listener));

      // An eviction that does not pass through `_clearJob` — the one kind
      // nothing in the app has today, and the kind this defends against.
      generation.debugEvictOldestResult();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      generation.removeListener(listener);

      // A listener was told about the eviction — otherwise the absence below
      // is a listener that never ran — and never while the result it was
      // shown was one the history no longer holds.
      expect(heard, isNotEmpty);
      expect(
        heard.where((said) => said.contains('NOT IN THE HISTORY')),
        isEmpty,
        reason: 'every notification: $heard',
      );

      // It really took the entry on display, so what follows is about that.
      expect(identities(), <String>['j-two#0', 'j-three#0']);
      expect(find.text('2 of 2'), findsOneWidget);
      expect(
        await painted(tester),
        paintedC,
        reason: 'the label says the newest, so the picture has to be the '
            'newest — anything else is one result shown and another claimed',
      );
      expect(generation.viewedResult, isNull);
      expect(api.fetched.last, pathOf('j-three'));
      expect(find.byKey(LcKeys.resultProblem), findsNothing);
    });
  });

  group('a result the gateway can no longer serve', () {
    testWidgets('says so, and is not a blank that reads as a picture',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);

      // Before: the picture is there to be seen, so the absence below is about
      // the failed fetch and not about a screen that never had one.
      await step(tester, LcKeys.resultPrevious);
      expect(await painted(tester), paintedA);
      expect(find.byKey(LcKeys.resultProblem), findsNothing);
      await step(tester, LcKeys.resultNext);

      // The gateway forgets the first job — a restart, from the app's side.
      api.gone.add(pathOf('j-one'));
      await step(tester, LcKeys.resultPrevious);

      expect(find.byKey(LcKeys.resultPreview), findsNothing);
      expect(find.byKey(LcKeys.resultProblem), findsOneWidget);
      expect(find.text("The picture couldn't be fetched."), findsOneWidget);
      expect(
        find.text(
          'It may have gone off the network or been stopped. Check that it is '
          'running, then try again.',
        ),
        findsOneWidget,
      );
      // Still says which one it is looking at, so the screen is not lying
      // about where the user is.
      expect(find.text('1 of 2'), findsOneWidget);
      expect(api.fetched.last, pathOf('j-one'));

      // And it is recoverable: the gateway answers again and Try again works.
      api.gone.clear();
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(await painted(tester), paintedA);
      expect(find.byKey(LcKeys.resultProblem), findsNothing);
    });
  });

  group('a download that answers after the user has moved on', () {
    testWidgets('does not paint over the result they moved to', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);
      expect(await painted(tester), paintedB);

      // The older picture is slow to arrive from here on.
      api.slow.add(pathOf('j-one'));
      await step(tester, LcKeys.resultPrevious);
      // Nothing to paint yet, and nothing pretending there is.
      expect(find.byKey(LcKeys.resultPreview), findsNothing);
      expect(find.byKey(LcKeys.resultProblem), findsNothing);
      expect(api.held, hasLength(1));

      // Back to the newest before the old one lands.
      await step(tester, LcKeys.resultNext);
      expect(await painted(tester), paintedB);

      // And now the abandoned download answers.
      api.held.single.complete(
        ResultBytes(
          bytes: pictureA,
          mediaType: 'image/png',
          filename: 'localcanvas-0.png',
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(await painted(tester), paintedB);
      expect(
        (tester.widget<Image>(find.byKey(LcKeys.resultPreview)).image
                as MemoryImage)
            .bytes,
        pictureB,
      );
      expect(find.text('2 of 2'), findsOneWidget);

      // And still, after the surface redraws for a reason of its own. Without
      // this the check is blind to stale bytes that were written in and simply
      // not drawn yet — the strengthening T-0175 had to make to its own.
      generation.beginReconnect();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(LcKeys.reconnecting), findsOneWidget);
      expect(await painted(tester), paintedB);
    });
  });

  group('another server has never heard of these job ids', () {
    testWidgets('moving to one forgets the results it cannot answer for',
        (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);
      expect(identities(), <String>['j-one#0', 'j-two#0']);
      expect(find.byKey(LcKeys.resultHistory), findsOneWidget);

      // A different gateway. A job id means nothing here, and an address built
      // from one would be answered for something else or not at all.
      generation.attach(
        endpoint: Endpoint.tryParse('192.0.2.77')!,
        capabilities: const GatewayCapabilities(events: true),
      );
      await tester.pump();
      await tester.pump();

      expect(identities(), isEmpty);
      expect(generation.viewedResult, isNull);
      expect(find.byKey(LcKeys.resultHistory), findsNothing);
      expect(find.byKey(LcKeys.resultPreview), findsNothing);
    });
  });

  group('someone who never goes back sees what they saw before', () {
    testWidgets('one generation draws no way back at all', (tester) async {
      await tester.pumpWidget(await shell());
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);

      expect(await painted(tester), paintedA);
      // Nothing about a history, because there is no way back from the only
      // result there has been.
      expect(find.byKey(LcKeys.resultHistory), findsNothing);
      expect(find.byKey(LcKeys.resultPrevious), findsNothing);
      expect(find.byKey(LcKeys.resultNext), findsNothing);
      // The rest of the result surface is what it always was.
      expect(find.byKey(LcKeys.resultSurface), findsOneWidget);
      expect(find.byKey(LcKeys.generateAgain), findsOneWidget);
      // One result, one fetch. Nothing about this feature asks for bytes it
      // was not asked for.
      expect(api.fetched, <String>[pathOf('j-one')]);

      // And the row was there to be found — without this, the absence above
      // could be a key that never renders under any circumstances.
      await generate(tester, 'j-two', pictureB, again: true);
      expect(find.byKey(LcKeys.resultHistory), findsOneWidget);
      expect(find.byKey(LcKeys.resultPrevious), findsOneWidget);
      expect(await painted(tester), paintedB);
    });
  });

  group('nothing about a result is written down', () {
    testWidgets('not to the device, and not into the portable profile',
        (tester) async {
      await tester.pumpWidget(await shell(stores: true));
      tallView(tester);
      await tester.pumpAndSettle();
      await compose(tester);

      await generate(tester, 'j-one', pictureA);
      await generate(tester, 'j-two', pictureB, again: true);
      await generate(tester, 'j-three', pictureC, again: true);
      await step(tester, LcKeys.resultPrevious);
      expect(await painted(tester), paintedB);
      expect(identities(), <String>['j-one#0', 'j-two#0', 'j-three#0']);

      // Something really is being written to this device, so the absences
      // below are about the history and not about an empty store.
      await workflows.saveMyDefaults();
      await workflows.flushDrafts();
      final stored = await SharedPreferencesAsync().getAll();
      expect(stored, isNotEmpty);

      bool storedHolds(Map<String, Object?> from, String needle) => from.entries
          .any((e) => e.key.contains(needle) || '${e.value}'.contains(needle));

      for (final needle in <String>[
        'j-one',
        'j-two',
        'j-three',
        '/api/v1/jobs/',
        'result/0',
        'history',
      ]) {
        expect(storedHolds(stored, needle), isFalse, reason: needle);
      }
      // The search can find one. Without this the six absences above would be
      // satisfied by a search that finds nothing ever.
      await SharedPreferencesAsync().setString('localcanvas.probe', 'j-two');
      expect(
        storedHolds(await SharedPreferencesAsync().getAll(), 'j-two'),
        isTrue,
      );

      // And the document that leaves the phone.
      expect(await workflows.exportProfile(), isTrue);
      final text = transport.sentText;
      for (final needle in <String>[
        'j-one',
        'j-two',
        'j-three',
        '/api/v1/jobs/',
        'result/0',
        'history',
      ]) {
        expect(text, isNot(contains(needle)), reason: needle);
      }
      // The same proof for the document: a setup named after a job id is in
      // it, so the search above was capable of finding one.
      await workflows.saveSetup(workflowId: 'plain', name: 'j-two');
      expect(await workflows.exportProfile(), isTrue);
      expect(transport.sentText, contains('j-two'));
    });
  });
}
