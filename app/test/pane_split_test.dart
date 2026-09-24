/// The split between the two panes is the user's, it is remembered on the
/// device, and it never leaves the phone (T-0176).
///
/// Four promises, and each group below is one of them:
///
/// * the divider moves, and neither pane can be moved into uselessness;
/// * a person who has never touched it gets the layout they always got, to the
///   pixel — which is why the expected widths here are written out as numbers
///   rather than recomputed from the constants the code uses. A test that says
///   `(width * LcLayout.defaultControlsShare).clamp(...)` agrees with any
///   default whatever, including the one somebody changes next week;
/// * the single column has no split, and a remembered one does not reach it;
/// * the width is device-local, like the theme (T-0132), and is absent from
///   the portable profile.
///
/// The widths this file draws at are widths, never devices (`docs/ui-ux.md`).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/l10n/app_localizations.dart';
import 'package:localcanvas/theme/pane_split_store.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/profile_transport.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_profile.dart';
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

/// The share sheet, recorded rather than performed.
class _RecordingTransport implements ProfileTransport {
  final List<ProfileDocument> sent = <ProfileDocument>[];
  String? incoming;

  String get sentText => sent.single.text;

  @override
  Future<void> send(ProfileDocument document) async => sent.add(document);

  @override
  Future<String?> receive({String? typeLabel}) async => incoming;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Endpoint.tryParse('192.0.2.42')!;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  /// Everything the preferences hold, read around the app rather than through
  /// it — so an assertion about a key cannot be satisfied by the same code
  /// that wrote it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  void sized(WidgetTester tester, double width, [double height = 2400]) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
  }

  /// The shell, connected, over whichever split store the test hands it.
  Future<Widget> shell({
    PaneSplitStore? split,
    WorkflowsController? workflows,
  }) async {
    final connection = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(e, testIdentity()),
      ),
      store: InMemoryEndpointStore(
        RememberedServer(
          endpoint: endpoint,
          displayName: 'Studio PC',
          lastSuccess: DateTime.utc(2026),
        ),
      ),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(endpoint);
    final registry = workflows ?? emptyRegistry();
    return MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: lcDarkTheme(),
      home: ConnectedShell(
        session: testSession(connection: connection, workflows: registry),
        split: split,
      ),
    );
  }

  double controlsWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(LcKeys.controlsPane)).width;
  double creationWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(LcKeys.contentPane)).width;

  group('the divider moves, and the panes move with it', () {
    testWidgets('dragging it right widens the controls and narrows the '
        'picture, by the same amount', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      final startedAt = controlsWidth(tester);
      final pictureWas = creationWidth(tester);
      expect(startedAt, 420, reason: 'the default at 1400 is the cap');

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(120, 0));
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), moreOrLessEquals(startedAt + 120));
      expect(creationWidth(tester), moreOrLessEquals(pictureWas - 120));
      // The window did not grow a gap: the two panes and the one-pixel
      // divider are still the whole of it.
      expect(
        controlsWidth(tester) + creationWidth(tester) + 1,
        moreOrLessEquals(1400),
      );
    });

    testWidgets('dragging it left narrows the controls and widens the picture',
        (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      final startedAt = controlsWidth(tester);
      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(-60, 0));
      await tester.pumpAndSettle();

      // `moreOrLessEquals` and not `equals`, here and wherever a width has
      // been through the stored share: the pane is a share of the window, so
      // 360 comes back as 359.99999999999994 and a test that insisted on the
      // integer would be asserting something about binary floating point
      // rather than about the layout.
      expect(controlsWidth(tester), moreOrLessEquals(startedAt - 60));
      expect(
        creationWidth(tester),
        moreOrLessEquals(1400 - (startedAt - 60) - 1),
      );
    });

    testWidgets('a dragged pane may be wider than the app would ever guess', (
      tester,
    ) async {
      // The half of the request that a ceiling of `controlsPaneMax` would
      // have refused: on a window this size the guess is already sitting on
      // that cap, so "make the options wider" has to mean past it or mean
      // nothing.
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), LcLayout.controlsPaneMax);

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), moreOrLessEquals(820));
      expect(controlsWidth(tester), greaterThan(LcLayout.controlsPaneMax));
    });
  });

  group('neither side can be dragged into uselessness', () {
    testWidgets('the controls pane stops at its floor, however far the drag '
        'goes', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(-5000, 0));
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), LcLayout.controlsPaneMin);
      // Said twice on purpose. The first line is the clamp; this one is the
      // property the clamp exists for, and it is the one that fails loudly if
      // the constant is ever set to something silly.
      expect(controlsWidth(tester), greaterThan(0));
      expect(find.byKey(LcKeys.controlsPane), findsOneWidget);
    });

    testWidgets('the creation area stops at its floor, however far the drag '
        'goes', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(5000, 0));
      await tester.pumpAndSettle();

      expect(creationWidth(tester), LcLayout.draggedCreationMin);
      expect(creationWidth(tester), greaterThan(0));
      expect(
        controlsWidth(tester),
        moreOrLessEquals(1400 - LcLayout.draggedCreationMin - 1),
      );
    });

    testWidgets('and the way back is still there at either end', (
      tester,
    ) async {
      // The review's question, asked as a test: can a person reach a layout
      // they cannot get back out of? The handle is over the divider, so
      // wherever the divider went the handle went too.
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(-5000, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.splitHandle), findsOneWidget);

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(5000, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.splitHandle), findsOneWidget);
      expect(creationWidth(tester), LcLayout.draggedCreationMin);

      // All the way back to where it started, in one gesture.
      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(-5000, 0));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), LcLayout.controlsPaneMin);
    });

    testWidgets('a window with no room to negotiate is drawn without a handle',
        (tester) async {
      // 600dp is where the two panes begin, and the two floors plus the
      // divider do not fit in it. An inert handle would be a control that
      // answers to nothing, so there is none.
      addTearDown(tester.view.reset);
      sized(tester, LcLayout.twoPaneWidth);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(find.byKey(LcKeys.splitHandle), findsNothing);
      expect(controlsWidth(tester), LcLayout.controlsPaneMin);
    });
  });

  group('a person who never drags gets what they always got', () {
    // Written out rather than computed. These are the widths `main` drew at
    // the moment this card was picked up, and the point of them is to
    // disagree with any change to the default — including one made by editing
    // the very constants a computed expectation would have read.
    const List<(double, double)> asItWas = <(double, double)>[
      (600, 320),
      (700, 320),
      (840, 320),
      (900, 324),
      (1000, 360),
      (1100, 396),
      (1200, 420),
      (1400, 420),
    ];

    for (final (window, pane) in asItWas) {
      testWidgets('a window of ${window.toInt()}dp draws a '
          '${pane.toInt()}dp controls pane', (tester) async {
        addTearDown(tester.view.reset);
        sized(tester, window);
        final store = InMemoryPaneSplitStore();
        await tester.pumpWidget(await shell(split: store));
        await tester.pumpAndSettle();

        expect(controlsWidth(tester), pane);
        // It did ask, and it wrote nothing. Without the first line this would
        // pass on a build that never reads the store; without the second, a
        // build that quietly wrote its own guess down would look the same as
        // a device that had never been dragged, forever after.
        expect(store.reads, 1);
        expect(store.written, isEmpty);
      });
    }

    testWidgets('a build handed no store at all still draws the same split', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      sized(tester, 1000);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), 360);
    });
  });

  group('the single column has no split to remember', () {
    testWidgets('a remembered width does not reach the narrow layout', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      // A share that is unmistakable if it ever leaks: seven tenths of the
      // window.
      final store = InMemoryPaneSplitStore(0.7);

      // First the wide layout, so that this share is *proved* to be a value
      // the app reads and acts on. An absence asserted over a number nothing
      // ever used would be a fact about a store nobody asked.
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(980));

      // Now the fold.
      sized(tester, 400);
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(find.byKey(LcKeys.shellExpanded), findsNothing);
      expect(find.byKey(LcKeys.splitHandle), findsNothing);
      // The column is the window less its own padding, and 0.7 of anything is
      // nowhere in that number.
      expect(controlsWidth(tester), 400 - LcSpace.md * 2);
    });

    testWidgets('and the narrow layout is the same width with no store at all',
        (tester) async {
      // The other half of the line above: the figure it asserts has to be the
      // one a device that never dragged gets, or "it did not leak" would be
      // satisfied by any number at all.
      addTearDown(tester.view.reset);
      sized(tester, 400);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), 400 - LcSpace.md * 2);
    });
  });

  group('a fold, an unfold and a rotation', () {
    testWidgets('a dragged split survives a fold and comes back on the unfold',
        (tester) async {
      addTearDown(tester.view.reset);
      final store = InMemoryPaneSplitStore();
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(570));

      sized(tester, 400);
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(controlsWidth(tester), 400 - LcSpace.md * 2);

      sized(tester, 1400);
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(controlsWidth(tester), moreOrLessEquals(570));
      // A fold is a configuration change and not a restart, so it did not go
      // back to the file to find that out.
      expect(store.reads, 1);
    });

    testWidgets('a rotation into a window too narrow for the chosen split '
        'still leaves both panes usable', (tester) async {
      addTearDown(tester.view.reset);
      // Dragged to seven tenths on a wide screen, then turned.
      sized(tester, 1400);
      await tester.pumpWidget(
        await shell(split: InMemoryPaneSplitStore(0.7)),
      );
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(980));

      sized(tester, 800);
      await tester.pumpAndSettle();

      expect(
        controlsWidth(tester),
        moreOrLessEquals(800 - LcLayout.draggedCreationMin - 1),
      );
      expect(creationWidth(tester), LcLayout.draggedCreationMin);
      expect(find.byKey(LcKeys.splitHandle), findsOneWidget);

      // And turning back does not hold the narrow window's compromise against
      // the wide one: the share is what was chosen, not what it was squeezed
      // into.
      sized(tester, 1400);
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(980));
    });
  });

  group('the width is written down, on this device', () {
    testWidgets('a drag is written once, when the finger comes off', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      final store = InMemoryPaneSplitStore();
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(LcKeys.splitHandle)),
      );
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();

      // Moved on screen already — a preference file is not on the path
      // between a finger and a layout.
      expect(controlsWidth(tester), moreOrLessEquals(540));
      expect(store.written, isEmpty);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(store.written, <double>[540 / 1400]);
    });

    testWidgets('and it comes back on the next launch', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      // The real store over the package's own in-memory platform: what is
      // being tested is that the value survives the app, so the thing it
      // survives into has to be the file and not a field.
      await tester.pumpWidget(
        await shell(split: PreferencesPaneSplitStore()),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(520));

      // On the device, read around the app.
      expect(
        (await preferences())[PreferencesPaneSplitStore.key],
        520 / 1400,
      );

      // The app again: a new tree, a new store object, the same preferences.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        await shell(split: PreferencesPaneSplitStore()),
      );
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), moreOrLessEquals(520));
    });

    testWidgets('a drag that ran past the end writes down where it stopped, '
        'not where the finger went', (tester) async {
      // The pane is held at its floor on screen either way, so this is the
      // only thing that can tell the two apart: what was *written*. A build
      // that clamped only when drawing would store a share of 3.87 for this
      // gesture, the store would refuse to read that back as a share of a
      // window — rightly — and the split a person chose would quietly become
      // the app's guess again at the next launch.
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      final store = InMemoryPaneSplitStore();
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(5000, 0));
      await tester.pumpAndSettle();

      expect(store.written.single, moreOrLessEquals(1079 / 1400));
      // And the store would give it back, which is the property that matters.
      expect(await store.load(), isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();
      expect(
        controlsWidth(tester),
        moreOrLessEquals(1400 - LcLayout.draggedCreationMin - 1),
      );
    });

    testWidgets('and the same going the other way', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      final store = InMemoryPaneSplitStore();
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(-5000, 0));
      await tester.pumpAndSettle();

      expect(
        store.written.single,
        moreOrLessEquals(LcLayout.controlsPaneMin / 1400),
      );
      expect(await store.load(), isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();
      expect(
        controlsWidth(tester),
        moreOrLessEquals(LcLayout.controlsPaneMin),
      );
    });

    testWidgets('a stored value that is not a share of a window is nothing '
        'said', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1000);
      // Hand-edited, or written by a build with a bug. Either way the layout
      // must come up usable rather than as one pane of nothing.
      await SharedPreferencesAsync().setDouble(
        PreferencesPaneSplitStore.key,
        0,
      );
      await tester.pumpWidget(
        await shell(split: PreferencesPaneSplitStore()),
      );
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), 360, reason: 'the default, not the zero');
    });

    testWidgets('a store that will not answer costs the split and nothing '
        'else', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1000);
      final store = InMemoryPaneSplitStore(0.8)
        ..loadFailure = Exception('the preference file will not open');
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), 360);
      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      // And it can still be dragged, and the write still fails silently.
      store.saveFailure = Exception('and it will not be written to either');
      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(400));
    });
  });

  group('and it never leaves the phone', () {
    /// A session with real stores, a real profile to export, and a split that
    /// genuinely sits in the preference file the export is built by scanning.
    Future<WorkflowsController> realSession(
      WidgetTester tester,
      _RecordingTransport transport,
    ) async {
      final controller = WorkflowsController(
        api: ScriptedWorkflowsApi(
          summaries: WorkflowSummary.listFromJson(
            registryOf(<Map<String, Object?>>[txt2imgDetail()]),
          ),
          details: <String, WorkflowDetail>{
            'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
          },
        ),
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
        setups: PreferencesWorkflowSetupStore(),
        profiles: transport,
        draftDebounce: Duration.zero,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        await shell(
          split: PreferencesPaneSplitStore(),
          workflows: controller,
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('the split a person dragged is not in the file they hand to '
        'somebody else', (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400, 3000);
      final transport = _RecordingTransport();
      final workflows = await realSession(tester, transport);

      // Something worth exporting, so an empty document cannot pass for a
      // clean one.
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      workflows.form!
        ..setEntry('width', '512')
        ..setEntry('prompt', 'a quiet courtyard at dawn');
      await workflows.saveMyDefaults();
      await workflows.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Warm rework',
      );

      // And the split, dragged for real.
      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(100, 0));
      await tester.pumpAndSettle();

      // It genuinely existed, and genuinely sits in the preference file the
      // export is built from. Without these three lines the absence below
      // would be a fact about an empty device.
      expect(controlsWidth(tester), moreOrLessEquals(520));
      expect(await PreferencesPaneSplitStore().load(), 520 / 1400);
      expect(
        (await preferences())[PreferencesPaneSplitStore.key],
        520 / 1400,
      );

      await workflows.exportProfile();
      final text = transport.sentText;
      final document = jsonDecode(text) as Map<String, Object?>;

      // The document carries what a profile is for...
      final defaults =
          ((document['workflows']! as Map<String, Object?>)['example_txt2img']!
                  as Map<String, Object?>)['defaults']!
              as Map<String, Object?>;
      expect(defaults['width'], 512);
      expect((document['setups']! as List<Object?>).length, 1);
      // ...and its shape is exactly what it was: no fifth key appeared.
      expect(document.keys.toList(), <String>[
        'format',
        'version',
        'workflows',
        'setups',
      ]);

      /// What this test looks for, as a function, so that the next line can
      /// prove it would find the thing if it were there.
      List<String> namesIn(String candidate) => <String>[
        for (final forbidden in <String>[
          PreferencesPaneSplitStore.key,
          'pane_split',
          'paneSplit',
          'split',
          'pane',
          'divider',
          '0.371',
        ])
          if (candidate.contains(forbidden)) forbidden,
      ];

      // Over the serialised text, because that is what leaves the phone.
      expect(namesIn(text), isEmpty, reason: text);
      // And the detector is not blind: the same text with the key added is
      // caught. Without this the line above would pass just as happily
      // against a predicate that always answered no.
      expect(namesIn('$text{"pane_split": 0.371}'), <String>[
        'pane_split',
        'split',
        'pane',
        '0.371',
      ]);
    });

    testWidgets('a profile that arrives from another phone does not move this '
        "phone's split", (tester) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400, 3000);
      final transport = _RecordingTransport();
      final workflows = await realSession(tester, transport);

      await tester.drag(find.byKey(LcKeys.splitHandle), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(520));

      // A document from a phone that was, for all this one knows, split
      // somewhere else entirely. There is nowhere in the format to say so,
      // which is the point.
      transport.incoming = encodeProfile(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_txt2img': ProfileEntry(
              values: <String, Object?>{'width': 1024},
            ),
          },
          setups: <WorkflowSetup>[],
        ),
      );
      await workflows.importProfile();
      await tester.pumpAndSettle();

      // The import really happened — otherwise "the split did not move" would
      // be a fact about a button that did nothing.
      expect(
        (await preferences())['localcanvas.defaults.example_txt2img.width'],
        1024,
      );
      // And the panes are where their owner left them, on screen and on the
      // device alike.
      expect(controlsWidth(tester), moreOrLessEquals(520));
      expect(await PreferencesPaneSplitStore().load(), 520 / 1400);
    });
  });

  group('the handle is operable without a pointer', () {
    /// The context below the handle's own `Focus`, which is what a keyboard
    /// would be given by traversal.
    void focusTheHandle(WidgetTester tester) {
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(LcKeys.splitHandle),
            matching: find.byType(MouseRegion),
          ),
        ),
      ).requestFocus();
    }

    testWidgets('it has a name, and it is the one in the bundle', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      final semantics = tester
          .getSemantics(find.byKey(LcKeys.splitHandle))
          .getSemanticsData();
      expect(
        semantics.label,
        L.of(tester.element(find.byKey(LcKeys.splitHandle))).splitHandleLabel,
      );
      // And the name is a sentence out of the bundle rather than a literal
      // somebody typed into the widget: it changes with the language.
      expect(semantics.label, isNotEmpty);
      // Not only a name: the two moves a screen reader can actually make.
      expect(semantics.hasAction(SemanticsAction.increase), isTrue);
      expect(semantics.hasAction(SemanticsAction.decrease), isTrue);
      handle.dispose();
    });

    testWidgets('the arrow keys move the split, and write it down', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      final store = InMemoryPaneSplitStore();
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();
      final startedAt = controlsWidth(tester);

      focusTheHandle(tester);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        controlsWidth(tester),
        moreOrLessEquals(startedAt + LcLayout.splitHandleStep),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        controlsWidth(tester),
        moreOrLessEquals(startedAt - LcLayout.splitHandleStep),
      );

      // A step that moved the layout and did not write it down would be a
      // choice that lasted until the next launch and no longer.
      expect(store.written, hasLength(3));
      expect(store.written.last, (startedAt - LcLayout.splitHandleStep) / 1400);
    });

    testWidgets('a key the handle has no business with is left alone', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      final store = InMemoryPaneSplitStore();
      await tester.pumpWidget(await shell(split: store));
      await tester.pumpAndSettle();
      final startedAt = controlsWidth(tester);

      focusTheHandle(tester);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), startedAt);
      expect(store.written, isEmpty);
    });

    testWidgets('and a press that lands on the strip still reaches what is '
        'under it', (tester) async {
      // The handle covers 12dp of each pane. If it swallowed presses there,
      // turning it on would have made a band of the screen stop working.
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      final Rect strip = tester.getRect(find.byKey(LcKeys.splitHandle));
      expect(strip.width, LcLayout.splitHandleTouchWidth);
      // A point inside the strip *and* inside the controls pane — six pixels
      // short of the divider, which is where a thumb aiming at the edge of the
      // form lands. The controls side and not the creation side because the
      // creation area centres a narrow column in a wide pane, so its own left
      // edge has nothing under it to reach and a probe there would prove
      // nothing either way.
      final Offset inBoth = Offset(strip.left + 6, strip.center.dy);
      expect(
        tester.getRect(find.byKey(LcKeys.controlsPane)).contains(inBoth),
        isTrue,
        reason: 'the probe must be over both, or it proves nothing',
      );

      final targets = tester
          .hitTestOnBinding(inBoth)
          .path
          .map((entry) => entry.target)
          .toList();
      // The controls pane is in the hit path at a point the strip covers,
      // which is only possible because the handle lets pointers through. An
      // opaque one stops the `Stack` at itself, and this very line is what
      // caught that while this card was being written — `MouseRegion` answers
      // a hit test on its own behalf and is opaque unless told otherwise.
      expect(
        targets.contains(tester.renderObject(find.byKey(LcKeys.controlsPane))),
        isTrue,
        reason: 'the strip swallowed the press instead of passing it through',
      );

      // And letting pointers through did not cost the handle the gesture: a
      // drag begun at that very point still moves the split. Both halves are
      // needed — passing everything through would be exactly as wrong as
      // swallowing everything.
      final before = controlsWidth(tester);
      final gesture = await tester.startGesture(inBoth);
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controlsWidth(tester), moreOrLessEquals(before + 40));
    });

    testWidgets('and a press well clear of the strip is not the divider\'s', (
      tester,
    ) async {
      // The other side of the same property: the grab area is a strip and not
      // the screen. Without this, "the drag works" would be satisfied by a
      // handle that had quietly swallowed the whole pane.
      addTearDown(tester.view.reset);
      sized(tester, 1400);
      await tester.pumpWidget(await shell(split: InMemoryPaneSplitStore()));
      await tester.pumpAndSettle();

      final Rect strip = tester.getRect(find.byKey(LcKeys.splitHandle));
      final before = controlsWidth(tester);
      final gesture = await tester.startGesture(
        Offset(strip.left - 40, strip.center.dy),
      );
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controlsWidth(tester), before);
    });
  });
}
