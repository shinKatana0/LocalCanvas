/// What the two ends of the draggable split are for: at the narrowest either
/// pane can be dragged to, the app's own layout still holds (T-0176).
///
/// **The numbers in `LcLayout` were measured, and this file is what keeps the
/// measurement true.** The controls pane was swept a pixel at a time in both
/// locales at 1.0, 1.3 and 2.0, with a workflow chosen, and every paragraph
/// re-measured by an independent `TextPainter`. The narrowest width at which
/// everything the app itself writes into that column reads whole is **319**,
/// bound by the *System* chips of the Appearance and Language blocks **in
/// Russian at a 2.0 text scale** — they are chips, so they cannot wrap.
/// `LcLayout.controlsPaneMin` clears that by **one pixel** and was left where
/// it was.
///
/// The whole grid, because the binding row is only visible against the others:
///
/// ```
/// en @ 1.0, en @ 1.3, ru @ 1.0   nothing cut anywhere down to 278
/// en @ 2.0                       300   "5 settings"
/// ru @ 1.3                       306   Системное / Системный
/// ru @ 2.0                       319   Системное / Системный   <- binding
/// ```
///
/// **An earlier version of this file said 310 at 1.3, and that is how the
/// mistake is made**: the 1.3 row is read and the 2.0 row is not, when at 2.0
/// those same chips are still cut at 310 and at 318. The sweep that produced
/// it stepped 10dp at a time and printed only the first two faults of each
/// combination, so the chips were never in the output at the widths that
/// mattered. A grid coarser than the answer, and a truncated list — either
/// alone would have been enough to get it wrong.
///
/// The tests below were right while the prose was wrong, which is the only
/// reason this was a correction and not a defect: lowering
/// `LcLayout.controlsPaneMin` to 300 kills the ru@1.3 case *and* the ru@2.0
/// case, because both draw the pane at the floor and ask these blocks.
///
/// **Every dp here is the widget-test toolkit's fixed-advance font** — 15.09dp
/// per character, Latin and Cyrillic alike (T-0150) — and not the shipped
/// face. Nothing is designed against those numbers: what is asserted is that
/// named blocks read whole and that nothing is drawn outside its pane, at
/// whatever size this font happens to produce.
///
/// ## What is asserted, and what deliberately is not
///
/// Not "nothing on this screen is cut off". At the floor several things still
/// are, and none of them is something a pane width decides:
///
/// * **content that is as long as somebody else made it** — the server's own
///   name out of its handshake, and a choice value out of the workflow file.
///   Text like that is ellipsised by design at every width;
/// * **the range hint under a numeric field**, whose length comes from the
///   curator's declared minimum and maximum. It is cut at 332dp at a 1.3 text
///   scale and at 472dp at 2.0 — wider than this pane ever gets — so it is a
///   defect of that line and not of this split (T-0190). A minimum chosen so
///   that the example workflow's seed range fits would be designing this
///   layout against `config/examples` instead of against the app;
/// * **the chosen workflow's name and summary at a 2.0 text scale.** Their
///   block hands them whatever is left of the pane after a fixed 296dp, so
///   they are cut at 320, 34dp wide at 330 and 104dp at 400, and only get a
///   real share at 420 — which is the widest the app's own default ever makes
///   this pane. No floor this card could set repairs that, and it is reachable
///   today without dragging anything, on every window from 600dp to 900dp.
///   Filed as T-0188.
///
/// So what is asserted is the part a split *can* be held to: the blocks the
/// app writes itself and lays out itself read whole at the floor, and neither
/// pane draws outside itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// How far outside its pane a box may be drawn before it counts as spilling.
///
/// Not zero, and the reason is measured: at a 2.0 text scale two `RenderStack`s
/// inside the form are drawn from x = -3.0 at **every** pane width from 280dp
/// to 560dp alike. A three-pixel overhang that no amount of width removes is
/// not something a pane minimum can fix, and treating it as one would make
/// this file assert a width that does not exist. A real overflow is nothing
/// like it: the ones T-0153 fixed ran from 15 to 431 pixels, and the test
/// below shows this tolerance on both sides of itself.
const double kOverhang = 4;

/// Every laid-out box under [root] drawn more than [kOverhang] past its left or
/// right edge.
///
/// Horizontal only. Both panes scroll vertically, so a box below the fold is
/// content waiting to be scrolled to and not content that does not fit; asking
/// about it would turn this into a test of where a scroll happens to be.
List<String> spillsIn(RenderBox root) {
  final Rect bounds = root.localToGlobal(Offset.zero) & root.size;
  final found = <String>[];
  void visit(RenderObject child) {
    if (child is RenderBox && !identical(child, root) && child.hasSize) {
      final Rect rect = child.localToGlobal(Offset.zero) & child.size;
      if (rect.left < bounds.left - kOverhang ||
          rect.right > bounds.right + kOverhang) {
        found.add(
          '${child.runtimeType} '
          '${rect.left.toStringAsFixed(1)}..${rect.right.toStringAsFixed(1)} '
          'outside ${bounds.left.toStringAsFixed(1)}'
          '..${bounds.right.toStringAsFixed(1)}',
        );
      }
    }
    child.visitChildren(visit);
  }

  visit(root);
  return found;
}

/// Whether [paragraph] had to drop any of its text to fit the box it was
/// given — an ellipsis, or a line it had no room for.
///
/// Measured **independently of the widget's own settings**: the very span and
/// scaler it was laid out with are handed to a fresh `TextPainter` that has no
/// ellipsis and no line limit, and offered the same width the paragraph was
/// offered. If the unrestricted painter then needs more room than the
/// paragraph occupies, what is on screen is not the whole text.
///
/// The offered width and not the settled one: a text that fits exactly ends up
/// as wide as it needs, and laying it out again at precisely that width is a
/// knife-edge a rounding error falls off.
bool _truncated(RenderParagraph paragraph) {
  final offered = paragraph.constraints.maxWidth;
  if (!offered.isFinite) return false;
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
  )..layout(maxWidth: offered);
  final lines = painter.computeLineMetrics();
  final fits =
      painter.height <= paragraph.size.height + 0.5 &&
      lines.every((line) => line.width <= offered + 0.5);
  painter.dispose();
  return !fits;
}

/// The texts of every paragraph under [root] that is not drawn whole, verbatim
/// and in tree order — so a failure names the sentence a person cannot read
/// rather than a count of them.
List<String> cutIn(RenderObject root) {
  final found = <String>[];
  void visit(RenderObject child) {
    if (child is RenderParagraph && child.hasSize && _truncated(child)) {
      found.add(child.text.toPlainText());
    }
    child.visitChildren(visit);
  }

  visit(root);
  return found;
}

void main() {
  /// A window wide enough that both floors can be reached in it by dragging,
  /// and wide enough that neither is reached by accident.
  const double window = 1400;

  /// A share below anything the clamp allows, so the controls pane lands *on*
  /// its floor and no test has to restate the arithmetic that gets it there.
  const double belowTheFloor = 0.05;

  /// The same from the other side: the creation area lands on its floor.
  const double aboveTheCeiling = 0.99;

  /// The blocks the app writes and lays out itself, which is exactly the set a
  /// pane minimum is answerable for. Named by key rather than found by type,
  /// so a failure says which block and never "something on the screen".
  const Map<String, Key> appsOwnBlocks = <String, Key>{
    'the Appearance block': LcKeys.appearance,
    'the Language block': LcKeys.language,
    'the Advanced header': LcKeys.advancedToggle,
    'Generate': LcKeys.generate,
  };

  /// Every framework error raised during [step], as first lines.
  Future<List<String>> collecting(Future<void> Function() step) async {
    final caught = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) =>
        caught.add(details.exceptionAsString().split('\n').first);
    try {
      await step();
    } finally {
      FlutterError.onError = previous;
    }
    return caught;
  }

  /// The shell at its busiest: a workflow chosen, Advanced open, and the
  /// Appearance and Language blocks drawn — the state the sweep measured,
  /// because a controls column with nothing in it has no minimum.
  Future<List<String>> openTheForm(
    WidgetTester tester, {
    required String tag,
    required double scale,
    required double width,
    double? share,
    bool openAdvanced = true,
  }) async {
    tester.view.physicalSize = Size(width, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      ),
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
    final appearance = testAppearance();
    addTearDown(appearance.dispose);
    final language = testLanguage();
    addTearDown(language.dispose);

    return collecting(() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(tag),
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: workflows),
            appearance: appearance,
            language: language,
            split: share == null ? null : InMemoryPaneSplitStore(share),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      if (openAdvanced) {
        await tester.ensureVisible(find.byKey(LcKeys.advancedToggle));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(LcKeys.advancedToggle));
        await tester.pumpAndSettle();
      }
    });
  }

  group('the detectors catch what they look for', () {
    // Without this group every assertion below could be passing because the
    // detectors never fire at all — which is how T-0153 lived on eleven
    // combinations while the suite was green.
    testWidgets('a cut-off label is seen, and a whole one is not', (
      tester,
    ) async {
      Widget label(double width, String text) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: width,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      );

      await tester.pumpWidget(label(400, 'short'));
      expect(cutIn(tester.renderObject(find.byType(Text))), isEmpty);

      await tester.pumpWidget(label(40, 'a sentence with nowhere to be drawn'));
      expect(
        cutIn(tester.renderObject(find.byType(Text))),
        <String>['a sentence with nowhere to be drawn'],
      );
    });

    testWidgets('a box drawn well past its parent is seen, and the measured '
        '3dp overhang is not', (tester) async {
      // Both halves matter. The first is the guard; the second is why
      // [kOverhang] is not zero, stated as a test rather than as a hope.
      Widget stack(double left) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 100,
            height: 20,
            child: Stack(
              key: const Key('probe'),
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned(
                  left: left,
                  top: 0,
                  child: const SizedBox(width: 40, height: 10),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(stack(-3));
      expect(
        spillsIn(tester.renderObject(find.byKey(const Key('probe')))),
        isEmpty,
        reason: 'the measured 3dp overhang must not read as an overflow',
      );

      await tester.pumpWidget(stack(200));
      expect(
        tester.takeException(),
        isNull,
        reason: 'the framework said nothing — which is why this check exists',
      );
      expect(
        spillsIn(tester.renderObject(find.byKey(const Key('probe')))),
        hasLength(1),
      );
    });

    testWidgets('the error collector is live', (tester) async {
      // A row that really does overflow, so that "no framework error" in the
      // assertions below is a fact about the screen rather than about a
      // handler that was never installed.
      final caught = await collecting(() async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 100,
                child: Row(
                  children: const <Widget>[
                    SizedBox(width: 100, height: 10),
                    SizedBox(width: 100, height: 10),
                  ],
                ),
              ),
            ),
          ),
        );
      });
      expect(caught, hasLength(1));
      expect(caught.single, contains('overflowed'));
    });

    // The half a toy widget cannot buy: the *System* chips, on the real
    // Appearance and Language blocks, cut at a width narrower than the floor
    // and whole at a width wider than it.
    //
    // Reached through the single-column layout, because that one has no clamp
    // to argue with — a window is any width it likes, and this column is the
    // same column the two-pane layout draws. Its 16dp of padding either side
    // against the pane's 24dp is why 280 and 320 here are not 300 and 340
    // there; what is being shown is that the detector can fail, on this
    // screen, on this block, in the locale and at the text scale the
    // measurement said binds.
    //
    // Two tests and not one with two widths: building this shell twice in a
    // single test leaves the first tree animating and `pumpAndSettle` never
    // returns. Measured, and it cost an afternoon of the sweep that produced
    // the numbers above.
    List<String> chipsCutIn(WidgetTester tester) => <String>[
      for (final block in <Key>[LcKeys.appearance, LcKeys.language])
        ...cutIn(tester.renderObject(find.byKey(block))),
    ];

    testWidgets('and it fires on this very screen, on the very block the '
        'floor was measured against', (tester) async {
      await openTheForm(
        tester,
        tag: 'ru',
        scale: 1.3,
        width: 280,
        openAdvanced: false,
      );
      expect(
        find.byKey(LcKeys.shellCompact),
        findsOneWidget,
        reason: 'this proof is about the single column',
      );
      expect(
        chipsCutIn(tester),
        <String>['Системное', 'Системный'],
        reason: 'the chips must be cut here, or every assertion in this file '
            'is about a detector that never fires',
      );
    });

    testWidgets('and it goes quiet again once the column is wide enough', (
      tester,
    ) async {
      await openTheForm(
        tester,
        tag: 'ru',
        scale: 1.3,
        width: 320,
        openAdvanced: false,
      );
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(chipsCutIn(tester), isEmpty);
    });
  });

  for (final tag in <String>['en', 'ru']) {
    for (final scale in <double>[1.0, 1.3, 2.0]) {
      group('$tag at $scale', () {
        testWidgets('the controls pane holds at the narrowest it can be '
            'dragged to', (tester) async {
          final errors = await openTheForm(
            tester,
            tag: tag,
            scale: scale,
            width: window,
            share: belowTheFloor,
          );

          // The pane really is on its floor. Without this the assertions
          // below would be about whatever width the app felt like.
          expect(
            tester.getSize(find.byKey(LcKeys.controlsPane)).width,
            LcLayout.controlsPaneMin,
          );
          for (final block in appsOwnBlocks.entries) {
            expect(
              cutIn(tester.renderObject(find.byKey(block.value))),
              isEmpty,
              reason: block.key,
            );
          }
          expect(
            spillsIn(tester.renderObject(find.byKey(LcKeys.controlsPane))),
            isEmpty,
          );
          expect(errors, isEmpty);
        });

        testWidgets('the creation area holds at the narrowest it can be '
            'dragged to', (tester) async {
          final errors = await openTheForm(
            tester,
            tag: tag,
            scale: scale,
            width: window,
            share: aboveTheCeiling,
          );

          expect(
            tester.getSize(find.byKey(LcKeys.contentPane)).width,
            LcLayout.draggedCreationMin,
          );
          // The whole pane this time, and not a named list: everything in the
          // creation area is the app's own, and the sweep found it clean at
          // every width down to 200dp.
          expect(
            cutIn(tester.renderObject(find.byKey(LcKeys.contentPane))),
            isEmpty,
          );
          expect(
            spillsIn(tester.renderObject(find.byKey(LcKeys.contentPane))),
            isEmpty,
          );
          expect(errors, isEmpty);
        });
      });
    }
  }
}
