/// A chosen clip shows a still frame and its length (T-0022).
///
/// There is no decoder in a widget test, so what is asserted is everything the
/// app is responsible for *around* one, against a [RecordingClipInspector]:
///
/// * **a picture is untouched** — its preview is compared, widget by widget,
///   with a shape recorded by running this file's first test against the
///   commit the card started from, and no inspector is ever asked about it;
/// * **a clip's frame and length** — the frame is the inspection's own, drawn
///   over the tile, and the length reaches the detail line because the app
///   wrote it into the selection. The fixture's selection carries no length
///   and the fake never touches the selection, so neither can do it for the
///   app;
/// * **the honest fallbacks** — a failure, an answer past the bound, no
///   inspector and no local file each leave the tile exactly as the app drew
///   it before (also recorded against that commit) and no length. Each proves
///   first that there was something to be seen;
/// * **ownership** — every inspection is disposed exactly once, on a replace,
///   a remove, a change of workflow and the shell going. `FakeClipInspection`
///   throws when used after dispose, so a frame drawn from a released one
///   fails the test rather than passing unnoticed.
///
/// What this file cannot say — that `video_player` draws a first frame and
/// reads a length on a phone — is not claimed here.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/media/clip_inspector.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  late WorkflowsController workflows;
  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;
  late RecordingClipInspector inspector;

  setUp(() {
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
    inspector = RecordingClipInspector();
  });

  Future<void> start(
    WidgetTester tester,
    List<Map<String, Object?>> details, {
    bool withInspector = true,
  }) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final registry = ScriptedWorkflowsApi(
      summaries: WorkflowSummary.listFromJson(registryOf(details)),
      details: <String, WorkflowDetail>{
        for (final body in details)
          body['id']! as String: WorkflowDetail.tryFromJson(body)!,
      },
    );
    workflows = WorkflowsController(
      api: registry,
      mediaPicker: picker,
      mediaApi: uploads,
      clipInspector: withInspector ? inspector : null,
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
    await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        theme: lcDarkTheme(),
        home: ConnectedShell(
          session: testSession(connection: connection, workflows: workflows),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens [id] from the picker — the first one chosen, or a change of mind.
  Future<void> openWorkflow(WidgetTester tester, String id) async {
    final first = find.byKey(LcKeys.chooseWorkflow);
    await tester.tap(
      first.evaluate().isNotEmpty ? first : find.byKey(LcKeys.changeWorkflow),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard(id)));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  /// Chooses the clip without letting the clock move: when this returns the
  /// inspector has been asked, and not a moment of the bound has passed. A
  /// `pumpAndSettle` here would run the button's ink out and spend an unknown
  /// part of the bound before the test starts counting.
  Future<void> tapAndStartInspecting(WidgetTester tester) async {
    await tester.tap(find.byKey(LcKeys.mediaChoose('source_video')));
    await tester.pump();
    expect(inspector.asked, hasLength(1));
  }

  /// The widgets a preview is made of, top down, by type.
  List<String> previewShape(WidgetTester tester, String fieldId) => <String>[
    for (final element
        in find
            .descendant(
              of: find.byKey(LcKeys.mediaPreview(fieldId)),
              matching: find.byWidgetPredicate((_) => true),
            )
            .evaluate())
      element.widget.runtimeType.toString(),
  ];

  /// The picture's preview as the app drew it before this card. Recorded by
  /// running [previewShape] against the commit the card started from.
  const List<String> pictureShapeOnMain = <String>[
    'SizedBox',
    'Stack',
    'ColoredBox',
    'Center',
    'Icon',
    'Semantics',
    'ExcludeSemantics',
    'SizedBox',
    'Center',
    'RichText',
    'Image',
    'Semantics',
    'RawImage',
  ];

  /// A clip's marked tile as the app drew it before this card, recorded the
  /// same way. Nothing but the tile: no frame, no empty box standing in for
  /// one.
  const List<String> clipTileShapeOnMain = <String>[
    'SizedBox',
    'Stack',
    'ColoredBox',
    'Center',
    'Icon',
    'Semantics',
    'ExcludeSemantics',
    'SizedBox',
    'Center',
    'RichText',
  ];

  MediaSelection clip({String name = 'holiday.mp4', int bytes = 8400}) =>
      tempSelection(kind: MediaKind.video, name: name, bytes: bytes);

  MediaFieldController videoField() => workflows.form!.media('source_video')!;

  Finder inPreview(String fieldId, Finder matching) => find.descendant(
    of: find.byKey(LcKeys.mediaPreview(fieldId)),
    matching: matching,
  );

  /// Nothing on screen reads as a length.
  void expectNoLengthOnScreen(WidgetTester tester) {
    for (final widget in tester.allWidgets) {
      if (widget is Text && widget.data != null) {
        expect(widget.data, isNot(matches(RegExp(r'\d:\d\d'))));
      }
    }
  }

  void expectEachDisposedOnce(List<FakeClipInspection> released) {
    for (final inspection in released) {
      expect(inspection.disposeCount, 1);
    }
  }

  group('a picture', () {
    testWidgets('is previewed exactly as it was before clips had frames', (
      tester,
    ) async {
      final chosen = tempSelection(contents: realPng);
      picker.answers = <MediaSelection?>[chosen];
      await start(tester, <Map<String, Object?>>[img2imgDetail()]);
      await openWorkflow(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();

      expect(previewShape(tester, 'source_image'), pictureShapeOnMain);
      final image = tester.widget<Image>(
        inPreview('source_image', find.byType(Image)),
      );
      expect(image.fit, BoxFit.cover);
      expect(image.errorBuilder, isNotNull);
      final resized = image.image as ResizeImage;
      expect(resized.width, 64);
      final file = resized.imageProvider as FileImage;
      expect(file.file.path, (chosen.source as FileMediaSource).path);
      expect(
        tester.widget<Icon>(inPreview('source_image', find.byType(Icon))).icon,
        Icons.image_outlined,
      );
      expect(find.text('IMG_0142.jpg'), findsOneWidget);
      expect(realPng.length, 75);
      expect(find.text('75 bytes'), findsOneWidget);
      expect(chosen.source.previewFile, isA<File>());
    });

    testWidgets('is never shown to the inspector, and gains no length', (
      tester,
    ) async {
      picker.answers = <MediaSelection?>[
        tempSelection(contents: realPng),
        clip(),
      ];
      await start(tester, <Map<String, Object?>>[
        img2imgDetail(),
        videoDetail(),
      ]);
      await openWorkflow(tester, 'example_img2img');
      await tapKey(tester, LcKeys.mediaChoose('source_image'));

      expect(inspector.asked, isEmpty);
      expect(previewShape(tester, 'source_image'), pictureShapeOnMain);
      expect(find.text('75 bytes'), findsOneWidget);
      expectNoLengthOnScreen(tester);
      expect(
        workflows.form!.media('source_image')!.selection!.duration,
        isNull,
      );

      // The same inspector, in the same app, was there to be asked: a clip
      // chosen next is.
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      expect(inspector.asked, hasLength(1));
      expect(find.text('0:07 · 8.4 kB'), findsOneWidget);
    });

    test('a length reported for a picture is not written into it', () async {
      final media = MediaFieldController(
        kind: MediaKind.image,
        picker: ScriptedMediaPicker(<MediaSelection?>[
          tempSelection(contents: realPng),
        ]),
        uploader: (selection, onProgress) =>
            uploads.upload(Endpoint.tryParse('192.0.2.42')!, selection),
        inspector: inspector,
      );
      addTearDown(media.dispose);
      await media.choose();
      final picture = media.selection!;

      media.adoptClipDuration(picture.source, const Duration(seconds: 7));

      expect(media.selection!.duration, isNull);
      expect(identical(media.selection, picture), isTrue);
    });
  });

  group('a clip, with an inspector', () {
    testWidgets('shows the frame over its tile, and its length on the line', (
      tester,
    ) async {
      final chosen = clip();
      expect(chosen.duration, isNull, reason: 'the fixture brings no length');
      picker.answers = <MediaSelection?>[chosen];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));

      expect(inspector.asked.single.path, chosen.source.previewFile!.path);
      final inspection = inspector.inspections.single;
      expect(
        inPreview('source_video', find.byKey(inspection.frameKey)),
        findsOneWidget,
      );
      // Over the tile, not instead of it.
      expect(
        tester.widget<Icon>(inPreview('source_video', find.byType(Icon))).icon,
        Icons.movie_outlined,
      );
      expect(find.text('holiday.mp4'), findsOneWidget);
      expect(find.text('0:07 · 8.4 kB'), findsOneWidget);
      expect(videoField().selection!.duration, const Duration(seconds: 7));
      expect(identical(videoField().selection!.source, chosen.source), isTrue);
    });

    testWidgets('a long clip reads as a clock with hours', (tester) async {
      inspector.duration = const Duration(hours: 1, minutes: 2, seconds: 3);
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));

      expect(find.text('1:02:03 · 8.4 kB'), findsOneWidget);
    });

    testWidgets('the length outlives the upload reply that lands after it', (
      tester,
    ) async {
      uploads.manual = true;
      uploads.reportedByteCount = 8500;
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      expect(videoField().phase, MediaPhase.uploading);
      expect(find.text('0:07 · 8.4 kB'), findsOneWidget);

      uploads.finish();
      await tester.pumpAndSettle();

      expect(videoField().phase, MediaPhase.ready);
      // The gateway's count, and the length measured before it came.
      expect(find.text('0:07 · 8.5 kB'), findsOneWidget);
      expect(find.text('Ready to use'), findsOneWidget);
      // A copy of the same choice redraws the frame it has; it does not open
      // the clip again.
      expect(inspector.asked, hasLength(1));
      expect(inspector.inspections.single.disposeCount, 0);
    });

    testWidgets('the length lands on a selection the upload already replaced', (
      tester,
    ) async {
      final held = Completer<void>();
      inspector.gate = held;
      uploads.reportedByteCount = 8500;
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      expect(videoField().phase, MediaPhase.ready);
      expect(find.text('8.5 kB'), findsOneWidget);

      held.complete();
      await tester.pumpAndSettle();

      expect(find.text('0:07 · 8.5 kB'), findsOneWidget);
    });

    testWidgets('trying a failed upload again does not open the clip again', (
      tester,
    ) async {
      uploads.failure = const MediaFailure.unreachable();
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      expect(videoField().phase, MediaPhase.failed);

      uploads.failure = null;
      await tapKey(tester, LcKeys.mediaRetry('source_video'));

      expect(videoField().phase, MediaPhase.ready);
      expect(inspector.asked, hasLength(1));
      final inspection = inspector.inspections.single;
      expect(inspection.disposeCount, 0);
      expect(
        inPreview('source_video', find.byKey(inspection.frameKey)),
        findsOneWidget,
      );
      expect(find.text('0:07 · 8.4 kB'), findsOneWidget);
    });

    testWidgets('a length the picker already gave is the one on the line', (
      tester,
    ) async {
      // The inspector measures seven seconds; the picker said three. The
      // frame is still drawn, so the length the inspector offered did reach
      // the controller — and was refused there (T-0231).
      final chosen = tempSelection(
        kind: MediaKind.video,
        name: 'holiday.mp4',
        bytes: 8400,
        duration: const Duration(seconds: 3),
      );
      expect(inspector.duration, const Duration(seconds: 7));
      picker.answers = <MediaSelection?>[chosen];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));

      final inspection = inspector.inspections.single;
      expect(inspection.duration, const Duration(seconds: 7));
      expect(
        inPreview('source_video', find.byKey(inspection.frameKey)),
        findsOneWidget,
      );
      expect(find.text('0:03 · 8.4 kB'), findsOneWidget);
      expect(find.text('0:07 · 8.4 kB'), findsNothing);
      expect(videoField().selection!.duration, const Duration(seconds: 3));
    });

    test('a length offered for a clip that has one changes nothing', () async {
      final media = MediaFieldController(
        kind: MediaKind.video,
        picker: ScriptedMediaPicker(<MediaSelection?>[
          tempSelection(
            kind: MediaKind.video,
            name: 'holiday.mp4',
            duration: const Duration(seconds: 3),
          ),
        ]),
        uploader: (selection, onProgress) =>
            uploads.upload(Endpoint.tryParse('192.0.2.42')!, selection),
        inspector: inspector,
      );
      addTearDown(media.dispose);
      await media.choose();
      final chosen = media.selection!;
      expect(chosen.duration, const Duration(seconds: 3));
      var notified = 0;
      media.addListener(() => notified++);

      media.adoptClipDuration(chosen.source, const Duration(seconds: 7));

      expect(media.selection!.duration, const Duration(seconds: 3));
      expect(identical(media.selection, chosen), isTrue);
      expect(notified, 0);
    });

    testWidgets('an answer inside the bound is shown', (tester) async {
      final held = Completer<void>();
      inspector.gate = held;
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapAndStartInspecting(tester);

      await tester.pump(
        kClipInspectionBound - const Duration(milliseconds: 50),
      );
      held.complete();
      await tester.pumpAndSettle();

      final inspection = inspector.inspections.single;
      expect(
        inPreview('source_video', find.byKey(inspection.frameKey)),
        findsOneWidget,
      );
      expect(find.text('0:07 · 8.4 kB'), findsOneWidget);
    });
  });

  group('no frame, and no length', () {
    testWidgets('when the clip cannot be decoded', (tester) async {
      inspector.failure = const ClipInspectionFailure();
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));

      // It was asked, about a file that exists, with a length ready to give.
      expect(inspector.asked, hasLength(1));
      expect(inspector.asked.single.existsSync(), isTrue);
      expect(inspector.duration, isNotNull);
      expect(previewShape(tester, 'source_video'), clipTileShapeOnMain);
      expect(find.text('8.4 kB'), findsOneWidget);
      expectNoLengthOnScreen(tester);
      expect(videoField().selection!.duration, isNull);
    });

    testWidgets('when the inspector throws something other than a failure', (
      tester,
    ) async {
      // Not the contract's `ClipInspectionFailure`: an inspector that broke
      // its contract. The tile stays, and nothing escapes the panel as an
      // unhandled error (T-0231).
      inspector.failure = StateError('not a ClipInspectionFailure');
      picker.answers = <MediaSelection?>[clip(), clip(name: 'beach.mp4')];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      // The choice — and so the preview's `initState` and the inspection it
      // starts — runs inside this zone, so an error the panel lets go of
      // lands here rather than in the binding's own handler.
      final escaped = <Object>[];
      await runZonedGuarded(() async {
        await tapKey(tester, LcKeys.mediaChoose('source_video'));
        // Past the bound, so a timer the throw left running would have fired.
        await tester.pump(kClipInspectionBound + const Duration(seconds: 1));
        await tester.pumpAndSettle();
      }, (error, _) => escaped.add(error));

      expect(escaped, isEmpty);
      expect(inspector.asked, hasLength(1));
      expect(inspector.asked.single.existsSync(), isTrue);
      expect(inspector.inspections, isEmpty);
      expect(previewShape(tester, 'source_video'), clipTileShapeOnMain);
      expect(find.text('8.4 kB'), findsOneWidget);
      expectNoLengthOnScreen(tester);
      expect(videoField().selection!.duration, isNull);

      // The field is not stuck: the clip can still be replaced, and the
      // replacement is inspected as usual.
      inspector.failure = null;
      await tapKey(tester, LcKeys.mediaReplace('source_video'));
      expect(inspector.asked, hasLength(2));
      expect(
        inPreview(
          'source_video',
          find.byKey(inspector.inspections.single.frameKey),
        ),
        findsOneWidget,
      );
    });

    testWidgets('when the answer comes after the bound, and it is released', (
      tester,
    ) async {
      final held = Completer<void>();
      inspector.gate = held;
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapAndStartInspecting(tester);

      await tester.pump(
        kClipInspectionBound + const Duration(milliseconds: 50),
      );
      held.complete();
      await tester.pumpAndSettle();

      // A frame and a length did arrive; neither was used.
      final late = inspector.inspections.single;
      expect(late.disposeCount, 1);
      expect(previewShape(tester, 'source_video'), clipTileShapeOnMain);
      expect(find.text('8.4 kB'), findsOneWidget);
      expectNoLengthOnScreen(tester);
      expect(videoField().selection!.duration, isNull);
    });

    testWidgets('when this build has no inspector', (tester) async {
      final chosen = clip();
      picker.answers = <MediaSelection?>[chosen];
      await start(tester, <Map<String, Object?>>[
        videoDetail(),
      ], withInspector: false);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));

      // A file an inspector could have opened was there.
      expect(chosen.source.previewFile!.existsSync(), isTrue);
      expect(videoField().inspector, isNull);
      expect(inspector.asked, isEmpty);
      expect(previewShape(tester, 'source_video'), clipTileShapeOnMain);
      expect(find.text('8.4 kB'), findsOneWidget);
      expectNoLengthOnScreen(tester);
    });

    testWidgets('when the source has no local file to open', (tester) async {
      picker.answers = <MediaSelection?>[
        MediaSelection(
          kind: MediaKind.video,
          source: ChunkedMediaSource(<List<int>>[
            List<int>.filled(8400, 1),
          ], length: 8400),
          filename: 'stream.mp4',
          byteCount: 8400,
        ),
        clip(),
      ];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');

      await tapKey(tester, LcKeys.mediaChoose('source_video'));

      expect(inspector.asked, isEmpty);
      expect(previewShape(tester, 'source_video'), clipTileShapeOnMain);
      expect(find.text('8.4 kB'), findsOneWidget);
      expectNoLengthOnScreen(tester);

      // The inspector was composed and answering: a clip with a file, chosen
      // in its place, gets its frame.
      await tapKey(tester, LcKeys.mediaReplace('source_video'));
      expect(inspector.asked, hasLength(1));
      expect(
        inPreview(
          'source_video',
          find.byKey(inspector.inspections.single.frameKey),
        ),
        findsOneWidget,
      );
    });
  });

  group('every inspection is released exactly once', () {
    testWidgets('when the clip is replaced', (tester) async {
      picker.answers = <MediaSelection?>[clip(), clip(name: 'beach.mp4')];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      final first = inspector.inspections.single;
      expect(
        inPreview('source_video', find.byKey(first.frameKey)),
        findsOneWidget,
      );

      inspector.duration = const Duration(seconds: 12);
      await tapKey(tester, LcKeys.mediaReplace('source_video'));

      expect(inspector.inspections, hasLength(2));
      final second = inspector.inspections[1];
      expect(first.disposeCount, 1);
      expect(second.disposeCount, 0);
      expect(find.byKey(first.frameKey), findsNothing);
      expect(
        inPreview('source_video', find.byKey(second.frameKey)),
        findsOneWidget,
      );
      expect(find.text('beach.mp4'), findsOneWidget);
      expect(find.text('0:12 · 8.4 kB'), findsOneWidget);
    });

    testWidgets('when the clip is replaced while it is still being opened', (
      tester,
    ) async {
      final held = Completer<void>();
      inspector.gate = held;
      picker.answers = <MediaSelection?>[clip(), clip(name: 'beach.mp4')];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      expect(inspector.asked, hasLength(1));
      expect(inspector.inspections, isEmpty);

      // The first answer is decided now — seven seconds — and held.
      inspector.duration = const Duration(seconds: 12);
      await tapKey(tester, LcKeys.mediaReplace('source_video'));
      final second = inspector.inspections.single;

      held.complete();
      await tester.pumpAndSettle();

      final first = inspector.inspections[1];
      expect(first.clip.path, inspector.asked.first.path);
      expect(first.disposeCount, 1);
      expect(find.byKey(first.frameKey), findsNothing);
      expect(second.disposeCount, 0);
      expect(
        inPreview('source_video', find.byKey(second.frameKey)),
        findsOneWidget,
      );
      // The replaced clip's length did not land on the one chosen after it.
      expect(find.text('0:12 · 8.4 kB'), findsOneWidget);
      expect(videoField().selection!.duration, const Duration(seconds: 12));
    });

    testWidgets(
      'a replaced clip answering before the panel has redrawn lends no length',
      (tester) async {
        // The one interleaving in which the old preview is still mounted when
        // its answer lands: the controller already holds the new clip, and no
        // frame has been drawn since. Only the controller can tell the two
        // apart then.
        final heldFirst = Completer<void>();
        inspector.gate = heldFirst;
        final second = clip(name: 'beach.mp4');
        picker.answers = <MediaSelection?>[clip(), second];
        await start(tester, <Map<String, Object?>>[videoDetail()]);
        await openWorkflow(tester, 'example_video');
        await tapKey(tester, LcKeys.mediaChoose('source_video'));
        expect(inspector.asked, hasLength(1));

        final heldSecond = Completer<void>();
        inspector.gate = heldSecond;
        inspector.duration = const Duration(seconds: 12);
        unawaited(videoField().choose());
        for (var i = 0; i < 20; i++) {
          if (identical(videoField().selection!.source, second.source)) break;
          await Future<void>.microtask(() {});
        }
        expect(
          identical(videoField().selection!.source, second.source),
          isTrue,
        );
        expect(inspector.asked, hasLength(1), reason: 'no frame drawn yet');

        heldFirst.complete();
        for (var i = 0; i < 20; i++) {
          await Future<void>.microtask(() {});
        }
        expect(
          inspector.inspections,
          hasLength(1),
          reason: 'the first answered',
        );

        expect(videoField().selection!.duration, isNull);

        await tester.pumpAndSettle();
        heldSecond.complete();
        await tester.pumpAndSettle();

        expect(inspector.inspections, hasLength(2));
        expect(inspector.inspections[0].disposeCount, 1);
        expect(inspector.inspections[1].disposeCount, 0);
        expect(find.text('0:12 · 8.4 kB'), findsOneWidget);
      },
    );

    testWidgets('when the clip is removed', (tester) async {
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      final inspection = inspector.inspections.single;
      expect(
        inPreview('source_video', find.byKey(inspection.frameKey)),
        findsOneWidget,
      );

      await tapKey(tester, LcKeys.mediaRemove('source_video'));

      expect(inspection.disposeCount, 1);
      expect(find.byKey(LcKeys.mediaChoose('source_video')), findsOneWidget);
      expect(videoField().selection, isNull);
    });

    testWidgets('when another workflow is opened, and on coming back', (
      tester,
    ) async {
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[
        videoDetail(),
        img2imgDetail(),
      ]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      final first = inspector.inspections.single;
      expect(
        inPreview('source_video', find.byKey(first.frameKey)),
        findsOneWidget,
      );

      await openWorkflow(tester, 'example_img2img');

      expect(find.byKey(LcKeys.mediaPreview('source_video')), findsNothing);
      expect(first.disposeCount, 1);

      await openWorkflow(tester, 'example_video');

      // The form kept the choice and its length; the frame is drawn afresh
      // from an inspection of its own.
      expect(inspector.inspections, hasLength(2));
      final second = inspector.inspections[1];
      expect(first.disposeCount, 1);
      expect(second.disposeCount, 0);
      expect(
        inPreview('source_video', find.byKey(second.frameKey)),
        findsOneWidget,
      );
      expect(find.text('0:07 · 8.4 kB'), findsOneWidget);
    });

    testWidgets('when the shell itself goes', (tester) async {
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      final inspection = inspector.inspections.single;

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expectEachDisposedOnce(<FakeClipInspection>[inspection]);
    });

    testWidgets('when the shell goes while a clip is still being opened', (
      tester,
    ) async {
      final held = Completer<void>();
      inspector.gate = held;
      picker.answers = <MediaSelection?>[clip()];
      await start(tester, <Map<String, Object?>>[videoDetail()]);
      await openWorkflow(tester, 'example_video');
      await tapKey(tester, LcKeys.mediaChoose('source_video'));
      expect(inspector.inspections, isEmpty);

      await tester.pumpWidget(const SizedBox());
      held.complete();
      await tester.pumpAndSettle();

      expectEachDisposedOnce(inspector.inspections);
      expect(inspector.inspections, hasLength(1));
    });
  });
}
