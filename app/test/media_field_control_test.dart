/// The media control on screen: the four states it has, and the two things it
/// is never allowed to do — show a reference, or animate progress it does not
/// have (`docs/ui-ux.md`).
library;

import 'support/l10n.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  late ScriptedWorkflowsApi registry;
  late WorkflowsController workflows;
  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;

  setUp(() {
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
  });

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<Widget> shellFor(
    List<Map<String, Object?>> details, {
    Locale? locale,
  }) async {
    registry = ScriptedWorkflowsApi(
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
    );
    addTearDown(workflows.dispose);
    final connection = ConnectionController(
      client: ScriptedGatewayClient((e) => HandshakeSucceeded(e, testIdentity())),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(Endpoint.tryParse('192.0.2.42')!);
    return MaterialApp(
      locale: locale,
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: lcDarkTheme(),
      home: ConnectedShell(
        session: testSession(connection: connection, workflows: workflows),
      ),
    );
  }

  Future<void> choose(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard(id)));
    await tester.pumpAndSettle();
  }

  /// Every string the interface is currently drawing.
  List<String> visibleText(WidgetTester tester) => <String>[
    for (final widget in tester.allWidgets)
      if (widget is Text && widget.data != null) widget.data!,
  ];

  /// The rule that costs the most when it is broken: no reference, anywhere,
  /// in any state.
  void expectNoReferenceOnScreen(WidgetTester tester, MediaSelection selection) {
    final path = (selection.source as FileMediaSource).path;
    for (final text in visibleText(tester)) {
      expect(text, isNot(contains(path)));
      expect(text, isNot(contains('://')));
      expect(text, isNot(contains(Platform.pathSeparator)));
      expect(text, isNot(contains(Directory.systemTemp.path)));
    }
  }

  group('an empty media field', () {
    testWidgets('says what the workflow needs and offers the one thing to do',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      expect(
        find.text('This workflow works from a picture you choose.'),
        findsOneWidget,
      );
      expect(find.byKey(LcKeys.mediaChoose('source_image')), findsOneWidget);
      expect(find.text('Choose picture'), findsOneWidget);
      // Required, and Generate says which field it is waiting for.
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed,
        isNull,
      );
      expect(find.text('Generate needs Source image.'), findsOneWidget);
    });

    testWidgets('a clip field asks for a clip, in its own words',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        videoDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_video');

      expect(
        find.text('This workflow works from a clip you choose.'),
        findsOneWidget,
      );
      expect(find.text('Choose clip'), findsOneWidget);
    });

    testWidgets('a picker that refuses says what to do about it',
        (tester) async {
      tallView(tester);
      picker.failure = const MediaFailure.notAllowed();
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();

      expect(find.text('That file could not be opened.'), findsOneWidget);
      expect(find.byKey(LcKeys.mediaChoose('source_image')), findsOneWidget);
      expect(uploads.calls, 0);
    });
  });

  group('a chosen picture', () {
    testWidgets('is shown by name and size, and unblocks Generate',
        (tester) async {
      tallView(tester);
      final selection = tempSelection(bytes: 2481923);
      picker.answers = <MediaSelection?>[selection];
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();

      expect(find.text('IMG_0142.jpg'), findsOneWidget);
      expect(find.text('2.5 MB'), findsOneWidget);
      expect(find.text('Ready to use'), findsOneWidget);
      expect(find.byKey(LcKeys.mediaPreview('source_image')), findsOneWidget);
      expectNoReferenceOnScreen(tester, selection);

      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed,
        isNotNull,
      );
      expect(find.byKey(LcKeys.generateReason), findsNothing);

      await tester.tap(find.byKey(LcKeys.generate));
      await tester.pumpAndSettle();
      expect(
        workflows.requestedGeneration?.inputs['source_image'],
        <String, Object?>{'media_id': 'm-3f9c1a-1'},
      );
    });

    testWidgets('with no readable name reads as a sentence, never as a path',
        (tester) async {
      tallView(tester);
      final selection = tempSelection(named: false, bytes: 2481923);
      picker.answers = <MediaSelection?>[selection];
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();

      expect(find.text('Chosen picture'), findsOneWidget);
      expectNoReferenceOnScreen(tester, selection);
    });

    testWidgets('can be replaced and removed', (tester) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[
        tempSelection(name: 'first.jpg'),
        tempSelection(name: 'second.jpg'),
      ];
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();
      expect(find.text('first.jpg'), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.mediaReplace('source_image')));
      await tester.pumpAndSettle();
      expect(find.text('second.jpg'), findsOneWidget);
      expect(find.text('first.jpg'), findsNothing);

      await tester.tap(find.byKey(LcKeys.mediaRemove('source_image')));
      await tester.pumpAndSettle();
      expect(find.text('second.jpg'), findsNothing);
      expect(find.byKey(LcKeys.mediaChoose('source_image')), findsOneWidget);
      expect(
        find.text('This workflow works from a picture you choose.'),
        findsOneWidget,
      );
    });

    testWidgets('is previewed as itself, over a tile that is never a hole',
        (tester) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[tempSelection(contents: realPng)];
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();

      final preview = find.byKey(LcKeys.mediaPreview('source_image'));
      expect(
        find.descendant(of: preview, matching: find.byType(Image)),
        findsOneWidget,
      );
      // And the marked tile is underneath it. A photo is decoded a frame or
      // two after the panel is drawn, so an Image on its own leaves a blank
      // square in the meantime — and leaves a file that cannot be decoded
      // blank for good.
      expect(
        find.descendant(of: preview, matching: find.byType(Icon)),
        findsOneWidget,
        reason: 'the tile has to be behind the picture, not instead of it',
      );
    });

    testWidgets('a clip shows its length and size, and no still frame',
        (tester) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[
        tempSelection(
          kind: MediaKind.video,
          name: 'holiday.mp4',
          bytes: 8400000,
          duration: const Duration(seconds: 7),
        ),
      ];
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        videoDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_video');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_video')));
      await tester.pumpAndSettle();

      expect(find.text('holiday.mp4'), findsOneWidget);
      expect(find.text('0:07 · 8.4 MB'), findsOneWidget);
      // A marked tile, not a fabricated thumbnail.
      expect(
        find.descendant(
          of: find.byKey(LcKeys.mediaPreview('source_video')),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
    });
  });

  group('progress on screen is the bytes and nothing else', () {
    testWidgets('a known length draws the fraction that actually went',
        (tester) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[tempSelection(bytes: 1000)];
      uploads.manual = true;
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pump();
      await tester.pump();

      final bar = find.byKey(LcKeys.mediaProgress('source_image'));
      expect(bar, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(bar).value, 0.0);

      uploads.report(250, 1000);
      await tester.pump();
      expect(tester.widget<LinearProgressIndicator>(bar).value, 0.25);
      expect(find.text('Uploading… 250 bytes of 1.0 kB'), findsOneWidget);

      // Generate is off, and says the reason it is off is the upload.
      expect(
        tester.widget<FilledButton>(find.byKey(LcKeys.generate)).onPressed,
        isNull,
      );
      expect(find.text('Source image is still uploading.'), findsOneWidget);

      uploads.report(1000, 1000);
      await tester.pump();
      expect(
        tester.widget<LinearProgressIndicator>(bar).value,
        isNull,
        reason: 'the bytes are gone and the wait is now the server; a full '
            'determinate bar would be claiming to know what is left',
      );
      expect(find.text('Finishing…'), findsOneWidget);

      uploads.finish();
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.mediaProgress('source_image')), findsNothing);
      expect(find.text('Ready to use'), findsOneWidget);
    });

    testWidgets('an unknown length is an indeterminate bar, not a fake one',
        (tester) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[
        tempSelection(bytes: 1000, knownSize: false),
      ];
      uploads.manual = true;
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pump();
      await tester.pump();

      final bar = find.byKey(LcKeys.mediaProgress('source_image'));
      expect(tester.widget<LinearProgressIndicator>(bar).value, isNull);
      expect(find.text('Uploading…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(LcKeys.field('source_image')),
          matching: find.textContaining(' of '),
        ),
        findsNothing,
      );

      uploads.report(700, null);
      await tester.pump();
      expect(tester.widget<LinearProgressIndicator>(bar).value, isNull);

      uploads.finish();
      await tester.pumpAndSettle();
    });
  });

  group('when it goes wrong', () {
    testWidgets('a failed upload says why, and Try again re-sends it',
        (tester) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[tempSelection(name: 'holiday.jpg')];
      uploads.failure = const MediaFailure.unreachable();
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();

      expect(find.text("The server didn't take the upload."), findsOneWidget);
      expect(find.text('holiday.jpg'), findsOneWidget);
      expect(find.byKey(LcKeys.mediaRetry('source_image')), findsOneWidget);

      uploads.failure = null;
      await tester.tap(find.byKey(LcKeys.mediaRetry('source_image')));
      await tester.pumpAndSettle();

      expect(uploads.calls, 2);
      expect(picker.calls, 1, reason: 'Try again is not Choose again');
      expect(find.text('Ready to use'), findsOneWidget);
    });

    testWidgets('a lapsed permission empties the field when state is restored',
        (tester) async {
      tallView(tester);
      final selection = tempSelection(name: 'holiday.jpg');
      picker.answers = <MediaSelection?>[selection];
      uploads.failure = const MediaFailure.unreachable();
      await tester.pumpWidget(await shellFor(<Map<String, Object?>>[
        img2imgDetail(),
      ]));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'a cat');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();
      expect(find.text('holiday.jpg'), findsOneWidget);

      // Android takes the permission back while the app is away.
      File((selection.source as FileMediaSource).path).deleteSync();
      // Coming back to the gateway is where state is restored
      // (`docs/recovery.md`).
      // Real file I/O does not resolve inside the test's fake clock, so the
      // restore runs on the real one.
      await tester.runAsync(workflows.reload);
      await tester.pumpAndSettle();

      expect(find.text('holiday.jpg'), findsNothing);
      expect(find.byKey(LcKeys.mediaChoose('source_image')), findsOneWidget);
      expect(find.text('Generate needs Source image.'), findsOneWidget);
      // The prompt is not collateral damage.
      expect(
        tester.widget<TextField>(find.byKey(LcKeys.field('prompt')))
            .controller
            ?.text,
        'a cat',
      );
    });
  });

  group('a photo the server refuses by its format (T-0127)', () {
    /// What the gateway sends with the refusal. It is English whatever the
    /// app's language, so it must never be what a person reads when the app
    /// has a sentence of its own.
    const heicWords = 'That photo is in HEIC/HEIF format, which LocalCanvas '
        'cannot use yet. Choose a JPEG or PNG, or turn off high-efficiency '
        '(HEIC) photos in the camera settings.';
    const genericWords = 'That file format cannot be used as an image.';

    /// Written out rather than read off the bundle, so a Russian bundle that
    /// kept the English, or a mapping that fell back to the generic sentence,
    /// cannot agree with itself here.
    const heicSentence = <String, String>{
      'en': 'That photo is in HEIC format, which LocalCanvas cannot use yet. '
          'Choose a JPEG or PNG, or turn off high-efficiency (HEIC) photos in '
          'the camera settings.',
      'ru': 'Это фото в формате HEIC, который LocalCanvas пока не '
          'поддерживает. Выберите JPEG или PNG либо отключите в настройках '
          'камеры высокоэффективный формат фото (HEIC).',
    };
    const genericSentence = <String, String>{
      'en': 'This server does not accept that kind of file.',
      'ru': 'Этот сервер не принимает файлы такого вида.',
    };
    const refusedTitle = <String, String>{
      'en': 'The server could not take that file.',
      'ru': 'Сервер не смог принять этот файл.',
    };

    Future<void> refuse(
      WidgetTester tester, {
      required String tag,
      required String code,
      required String serverWords,
    }) async {
      tallView(tester);
      picker.answers = <MediaSelection?>[tempSelection(name: 'IMG_0142.heic')];
      uploads.failure = MediaFailure.refused(
        code: code,
        serverMessage: serverWords,
      );
      await tester.pumpWidget(await shellFor(
        <Map<String, Object?>>[img2imgDetail()],
        locale: Locale(tag),
      ));
      await tester.pumpAndSettle();
      await choose(tester, 'example_img2img');
      await tester.tap(find.byKey(LcKeys.mediaChoose('source_image')));
      await tester.pumpAndSettle();
    }

    for (final tag in <String>['en', 'ru']) {
      testWidgets('unsupported_image_heic says what to do instead, in $tag',
          (tester) async {
        await refuse(
          tester,
          tag: tag,
          code: 'unsupported_image_heic',
          serverWords: heicWords,
        );

        expect(find.text(refusedTitle[tag]!), findsOneWidget);
        expect(find.text(heicSentence[tag]!), findsOneWidget);
        expect(find.text(genericSentence[tag]!), findsNothing);
        expect(find.text(heicWords), findsNothing);
        expect(find.byKey(LcKeys.mediaRetry('source_image')), findsOneWidget);
      });

      testWidgets(
          'an older gateway\'s unsupported_media_type keeps its own sentence, '
          'in $tag', (tester) async {
        await refuse(
          tester,
          tag: tag,
          code: 'unsupported_media_type',
          serverWords: genericWords,
        );

        expect(find.text(refusedTitle[tag]!), findsOneWidget);
        expect(find.text(genericSentence[tag]!), findsOneWidget);
        expect(find.text(heicSentence[tag]!), findsNothing);
        expect(find.text(genericWords), findsNothing);
      });
    }
  });
}
