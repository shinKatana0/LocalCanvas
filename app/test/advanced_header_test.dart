/// The Advanced section's header row, at every width, scale and locale the
/// app supports (T-0153).
///
/// The row draws the word *Advanced* beside a count of what is behind it, and
/// a chevron at the far end. Written as `Row([Text, SizedBox, Text, Spacer,
/// Icon])` neither `Text` was flexible, so the two of them plus the chevron
/// ran past the pane and `RenderFlex` reported an overflow — **at eleven of
/// the fifteen width × text-scale combinations in English, and fourteen of
/// fifteen in Russian**, the worst by 431px. The figures on each test name
/// below are that overflow, as it stood on `main`.
///
/// Two things about how this is measured, both of them mistakes this defect
/// has already cost the project once:
///
/// * **errors are recorded per step, not asked for at the end.**
///   `tester.takeException()` after a sequence of taps answers with *an*
///   error, and a sequence gives it several chances to be about something
///   else. That is exactly how this defect came to be filed against the seed
///   row, two hundred lines away in `field_controls.dart`, when the header
///   was already overflowing before Advanced had ever been opened. So
///   `FlutterError.onError` is installed here and drained at each step, and
///   the assertions are made against the step that draws the header;
///
/// * **the header's own render objects are asked directly.** A `RenderFlex`
///   knows whether it overflowed and says so in `toStringShort`. Asking it is
///   not the same as asking whether *anything on the screen* overflowed, and
///   telling one widget's overflow from another's is what this file was
///   written to be able to do.
///
///   When it was written this screen carried two other overflows, belonging
///   to other cards: the picker card's bottom row (T-0154) and
///   `_FieldFrame`'s label row (T-0155). Neither was drained — each was named
///   in a map of allowed exceptions, by step, size and creator, written to
///   fail on the day its defect was fixed. **That day was T-0154, which
///   shipped both rows, so both maps are gone**: every step of every
///   combination is now asserted silent, and an overflow appearing anywhere
///   on the way to this row is a failure here.
///
/// **Every dp here is the widget-test toolkit's fixed-advance font** — 15.09dp
/// per character, Latin and Cyrillic alike (T-0150) — and not the shipped
/// face. Nothing below is designed against those numbers: the assertions are
/// that the row does not overflow and that neither label is cut off, at
/// whatever size this font happens to produce. The numbers are in the test
/// names so a reader can see which combinations this card repaired.
library;

import 'dart:convert' show LineSplitter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/l10n/app_localizations.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// Every `RenderFlex` at or below [root], in tree order.
List<RenderFlex> _flexesUnder(RenderObject root) {
  final found = <RenderFlex>[];
  void visit(RenderObject node) {
    if (node is RenderFlex) found.add(node);
    node.visitChildren(visit);
  }

  visit(root);
  return found;
}

/// The ones of those that are reporting an overflow.
///
/// `RenderFlex.toStringShort` appends `OVERFLOWING` while its own overflow is
/// past the framework's tolerance. That is the same condition that produces
/// the yellow-and-black banner and the console error, read off the one render
/// object under test instead of off the whole screen.
List<RenderFlex> _overflowing(RenderObject root) => <RenderFlex>[
  for (final flex in _flexesUnder(root))
    if (flex.toStringShort().contains('OVERFLOWING')) flex,
];

/// Every laid-out box under [root] painted outside [root]'s own rectangle.
///
/// The half of the check that does not care what draws the row, added by
/// T-0154. Asking only for overflowing flexes has a blind spot that this very
/// card opened: a `RenderFlex` announces its own overflow, and a `RenderWrap`
/// announces nothing at all however far its child runs past it — so the
/// moment T-0153 replaced this header's `Row([Text, Text, Icon])` with
/// `Row([Expanded(Wrap), Icon])`, everything inside that `Wrap` stopped being
/// watched by `_overflowing`. A guard that goes quiet because the fix changed
/// the widget is a guard that certifies the property by the mechanism that
/// provides it.
///
/// Geometry is what a person sees, so geometry is what is asked.
List<RenderBox> _spilling(RenderBox root) {
  final Rect bounds = root.localToGlobal(Offset.zero) & root.size;
  final spilled = <RenderBox>[];
  void visit(RenderObject node) {
    if (node is RenderBox && !identical(node, root) && node.hasSize) {
      final Rect rect = node.localToGlobal(Offset.zero) & node.size;
      if (rect.left < bounds.left - 0.5 ||
          rect.right > bounds.right + 0.5 ||
          rect.top < bounds.top - 0.5 ||
          rect.bottom > bounds.bottom + 0.5) {
        spilled.add(node);
      }
    }
    node.visitChildren(visit);
  }

  visit(root);
  return spilled;
}

/// What [_spilling] found, as the lines an assertion should print.
List<String> _spills(WidgetTester tester, Finder of) {
  final RenderBox root = tester.renderObject(of);
  return <String>[
    for (final box in _spilling(root))
      '${box.toStringShort()} ${box.localToGlobal(Offset.zero) & box.size} '
          'outside ${root.localToGlobal(Offset.zero) & root.size}',
  ];
}

/// The first line of each collected error — what an assertion prints when it
/// fails, without the several hundred lines of diagnostics behind it.
///
/// **What this can and cannot answer** (T-0154). The framework raises an
/// overflow from `paint`, so a row that is over its width and is simply not
/// repainted raises nothing. Draining errors per step therefore answers "did
/// anything newly repaint past its edge during this step" and never "is
/// anything past its edge now" — measured on the very screen below, where one
/// render object is `OVERFLOWING` at the choose step and at the advanced step
/// alike while the advanced step reports no error at all. It is kept here as
/// a check that each step was *quiet*, and every claim about this row's own
/// geometry is made by walking its render objects instead.
List<String> _summaries(List<String> errors) => <String>[
  for (final error in errors) const LineSplitter().convert(error).first,
];

/// Whether [paragraph] had to drop any of its text to fit the box it was
/// given — an ellipsis, or a line it had no room for.
///
/// Measured **independently of the widget's own settings**: the very span and
/// scaler it was laid out with are handed to a fresh `TextPainter` that has no
/// ellipsis and no line limit, and is offered the same width the paragraph was
/// offered. If the unrestricted painter then needs more room than the
/// paragraph occupies, what is on screen is not the whole text.
///
/// The offered width, not the width the paragraph settled on: a text that fits
/// exactly ends up as wide as it needs, and laying it out again at precisely
/// that width is a knife-edge a rounding error falls off.
bool _truncated(RenderParagraph paragraph) {
  final offered = paragraph.constraints.maxWidth;
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

/// What each step of reaching the form reported: the error text of every
/// framework error that arrived while that step was running, and nothing from
/// any other step.
typedef Steps = ({
  List<String> atLaunch,
  List<String> atPicker,
  List<String> atChoose,
});

void main() {
  /// The widths this app draws its controls column at, in both postures, and
  /// every text scale a phone offers. The same fifteen `theme_choice_test`
  /// uses; the locale doubles it to thirty.
  const List<double> widths = <double>[320, 360, 412, 840, 1100];
  const List<double> scales = <double>[1.0, 1.3, 2.0];

  /// What the header row overflowed by on `main`, before this card, in the
  /// harness font. A combination absent from this map fitted.
  ///
  /// These are the header's own numbers, taken with `FlutterError.onError`
  /// per step. Two of the four figures on the original card — 183px at
  /// 320/2.0 and 91px at 412/2.0 — are **not** in it, because they were the
  /// picker's overflow (T-0154) and not this row's; the header's own figures
  /// at those two combinations are 265px and 173px.
  const Map<String, int> overflowedOnMain = <String, int>{
    'en 320/1.0': 15,
    'en 320/1.3': 90,
    'en 320/2.0': 265,
    'en 360/1.3': 50,
    'en 360/2.0': 225,
    'en 412/2.0': 173,
    'en 840/1.0': 31,
    'en 840/1.3': 106,
    'en 840/2.0': 281,
    'en 1100/1.3': 30,
    'en 1100/2.0': 205,
    'ru 320/1.0': 90,
    'ru 320/1.3': 188,
    'ru 320/2.0': 415,
    'ru 360/1.0': 50,
    'ru 360/1.3': 148,
    'ru 360/2.0': 375,
    'ru 412/1.3': 96,
    'ru 412/2.0': 323,
    'ru 840/1.0': 106,
    'ru 840/1.3': 204,
    'ru 840/2.0': 431,
    'ru 1100/1.0': 30,
    'ru 1100/1.3': 128,
    'ru 1100/2.0': 355,
  };

  String key(String tag, double width, double scale) =>
      '$tag ${width.toInt()}/$scale';

  /// The advanced fields of the fixture, counted from the schema rather than
  /// from the widget that is under test.
  final int advancedCount = WorkflowDetail.tryFromJson(
    txt2imgDetail(),
  )!.advancedFields.length;

  /// One framework error, as the whole diagnostic text it arrived with — so
  /// that an overflow belonging to another card can be told apart by the key
  /// in its creator chain rather than by where it happened to appear.
  String describe(FlutterErrorDetails details) {
    final buffer = StringBuffer(details.exceptionAsString());
    final collect = details.informationCollector;
    if (collect != null) {
      for (final node in collect()) {
        buffer.writeln(node.toStringDeep());
      }
    }
    final exception = details.exception;
    if (exception is FlutterError) {
      for (final node in exception.diagnostics) {
        buffer.writeln(node.toStringDeep());
      }
    }
    return buffer.toString();
  }

  /// Runs one step with framework errors collected instead of failing the
  /// test, and answers with exactly what that step reported.
  ///
  /// The handler is put back **before this returns**, so no `expect` in this
  /// file ever runs while `FlutterError.onError` is overridden — a failing
  /// one inside that window does not report as a failure at all, it reports
  /// as `_pendingExceptionDetails != null` from somewhere inside the binding.
  Future<List<String>> collecting(Future<void> Function() step) async {
    final caught = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => caught.add(describe(details));
    try {
      await step();
    } finally {
      FlutterError.onError = previous;
    }
    return caught;
  }

  /// Build the shell, choose the fixture workflow, and stop there — the
  /// header is drawn the moment a workflow is chosen, with Advanced closed.
  Future<Steps> openTheForm(
    WidgetTester tester,
    String tag,
    double width,
    double scale,
  ) async {
    tester.view.physicalSize = Size(width, 3000);
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

    final atLaunch = await collecting(() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(tag),
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: workflows),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
    final atPicker = await collecting(() async {
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
    });
    final atChoose = await collecting(() async {
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
    });
    return (atLaunch: atLaunch, atPicker: atPicker, atChoose: atChoose);
  }

  Finder header() => find.byKey(LcKeys.advancedToggle);

  /// The header's two labels, found by the words they are supposed to say.
  (RenderParagraph, RenderParagraph) labelsOf(WidgetTester tester, L l) {
    final title = find.descendant(
      of: header(),
      matching: find.text(l.formAdvanced),
    );
    final count = find.descendant(
      of: header(),
      matching: find.text(l.formAdvancedCount(advancedCount)),
    );
    expect(title, findsOneWidget, reason: 'the title is not on the header');
    expect(count, findsOneWidget, reason: 'the count is not on the header');
    return (
      tester.renderObject<RenderParagraph>(title),
      tester.renderObject<RenderParagraph>(count),
    );
  }

  group('the detectors this file measures with catch what they look for', () {
    // Otherwise every assertion below could be passing because the detector
    // never fires at all — the failure mode that let this defect live on
    // eleven combinations while the suite was green.
    testWidgets('an overflowing Row is seen, and a fitting one is not', (
      tester,
    ) async {
      Widget row(double width) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: width,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 100, height: 10),
                const SizedBox(width: 100, height: 10),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(row(300));
      expect(_overflowing(tester.renderObject(find.byType(Row))), isEmpty);

      await tester.pumpWidget(row(150));
      expect(tester.takeException(), isNotNull, reason: 'it really overflowed');
      final seen = _overflowing(tester.renderObject(find.byType(Row)));
      expect(seen, hasLength(1));
      expect(seen.single.toStringShort(), contains('OVERFLOWING'));
    });

    testWidgets('a box drawn past a parent that never complains is seen', (
      tester,
    ) async {
      // The detector added by T-0154, and the reason it had to be: the thing
      // it watches is a `Wrap`, and a `RenderWrap` reports nothing about
      // itself however far its child runs past it. A `Stack` with
      // `Clip.none` is the same silence, in miniature.
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

      await tester.pumpWidget(stack(10));
      expect(tester.takeException(), isNull);
      expect(
        _spills(tester, find.byKey(const Key('probe'))),
        isEmpty,
        reason: 'a child well inside its parent was called outside',
      );

      await tester.pumpWidget(stack(200));
      expect(
        tester.takeException(),
        isNull,
        reason: 'the framework said nothing — which is why this check exists',
      );
      expect(
        _spills(tester, find.byKey(const Key('probe'))),
        isNotEmpty,
        reason: 'a child 140dp past its parent was called contained',
      );
    });

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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      );

      await tester.pumpWidget(label(400, 'short'));
      expect(_truncated(tester.renderObject(find.byType(Text))), isFalse);

      // Three lines' worth of words into a box that allows two.
      await tester.pumpWidget(
        label(60, 'alpha bravo charlie delta echo foxtrot golf'),
      );
      expect(
        _truncated(tester.renderObject(find.byType(Text))),
        isTrue,
        reason: 'the text was ellipsised and the detector said it was whole',
      );
    });
  });

  group('the header row cannot overflow', () {
    for (final tag in <String>['en', 'ru']) {
      for (final width in widths) {
        for (final scale in scales) {
          final id = key(tag, width, scale);
          final before = overflowedOnMain[id];
          final was = before == null
              ? 'fitted on main'
              : 'overflowed by ${before}px on main';
          testWidgets('at ${width.toInt()}dp, text scale $scale, in $tag — '
              '$was', (tester) async {
            final steps = await openTheForm(tester, tag, width, scale);
            final l = L.of(tester.element(header()));

            // The header is drawn by the step that chooses a workflow, so
            // that is the step its overflow has to be absent from. The other
            // two steps are asserted as well rather than ignored: launching
            // draws no form at all, and the picker — which used to report
            // T-0154's overflow at four of these combinations — draws no
            // form either. Both must be silent.
            expect(steps.atLaunch, isEmpty, reason: 'before any workflow');
            expect(
              _summaries(steps.atPicker),
              isEmpty,
              reason: 'opening the picker reported an error at $id',
            );

            // The premises, asserted before anything is asserted absent: the
            // locale really reached the tree, the header really is on screen,
            // and it really is saying both of the things that overflowed.
            // Without these, "no overflow" would also be true of a blank
            // screen.
            expect(
              Localizations.localeOf(tester.element(header())),
              Locale(tag),
            );
            expect(header(), findsOneWidget);
            expect(advancedCount, 5, reason: 'the fixture lost its fields');
            final (title, count) = labelsOf(tester, l);
            expect(find.byKey(LcKeys.advancedSection), findsNothing,
                reason: 'the header is drawn with Advanced still closed');

            // 1. Nothing under the header is over its width — asked twice,
            //    because one question alone has a blind spot (T-0154). No
            //    flex under the header reports an overflow, AND no box under
            //    it is painted outside it: the `Wrap` this row is built from
            //    would never report anything of its own.
            final flexes = _flexesUnder(tester.renderObject(header()));
            expect(flexes, isNotEmpty, reason: 'nothing was inspected');
            expect(
              <String>[
                for (final flex in _overflowing(tester.renderObject(header())))
                  flex.toStringShort(),
              ],
              isEmpty,
              reason: 'the header row overflowed at $id',
            );
            expect(
              _spills(tester, header()),
              isEmpty,
              reason: 'something on the header was drawn past its edge at $id',
            );

            // 2. Both labels are drawn whole — the yield is visible, never a
            //    word quietly cut away.
            expect(
              _truncated(title),
              isFalse,
              reason: '"${l.formAdvanced}" is cut off at $id',
            );
            expect(
              _truncated(count),
              isFalse,
              reason: '"${l.formAdvancedCount(advancedCount)}" is cut off '
                  'at $id',
            );

            // 3. Both are inside the tap target rather than spilling out of
            //    it, which is the thing an overflow actually does to a person.
            final box = tester.getRect(header());
            for (final rect in <Rect>[
              title.localToGlobal(Offset.zero) & title.size,
              count.localToGlobal(Offset.zero) & count.size,
            ]) {
              expect(box.contains(rect.topLeft), isTrue, reason: id);
              expect(
                box.contains(rect.bottomRight - const Offset(0.01, 0.01)),
                isTrue,
                reason: 'a label runs outside the header at $id',
              );
            }

            // 4. It is still one tap target of a size a thumb can hit.
            expect(
              box.height,
              greaterThanOrEqualTo(48),
              reason: 'the header shrank below a tap target at $id',
            );

            // 5. And what the step that drew the header reported: nothing at
            //    all. Two Russian combinations used to be allowed one error
            //    each here, `_FieldFrame`'s label row (T-0155); T-0154 taught
            //    that row to give, so the allowance is gone rather than
            //    satisfied and every combination is asserted silent.
            expect(
              _summaries(steps.atChoose),
              isEmpty,
              reason: 'choosing the workflow reported an error at $id',
            );
          });
        }
      }
    }
  });

  group('what the row does when it runs out of width', () {
    /// Where each label ended up, in the header's own coordinates.
    Future<(Rect, Rect)> layout(
      WidgetTester tester,
      String tag,
      double width,
      double scale,
    ) async {
      await openTheForm(tester, tag, width, scale);
      final l = L.of(tester.element(header()));
      final (title, count) = labelsOf(tester, l);
      final origin = tester.getRect(header()).topLeft;
      return (
        (title.localToGlobal(Offset.zero) - origin) & title.size,
        (count.localToGlobal(Offset.zero) - origin) & count.size,
      );
    }

    testWidgets('while both fit, they sit on one line and the row is 48dp', (
      tester,
    ) async {
      // 412dp at a 1.0 text scale: an ordinary phone, and one of the four
      // English combinations that fitted on `main`. The shape there is
      // unchanged by this card, which is the point of measuring it.
      final (title, count) = await layout(tester, 'en', 412, 1.0);

      expect(count.left, greaterThan(title.right), reason: 'side by side');
      expect(count.top, lessThan(title.bottom), reason: 'on the same line');
      expect(tester.getRect(header()).height, 48);
    });

    // 320dp at a 1.0 text scale — the combination this card was filed on, at
    // 15px over in English and 90px over in Russian. Both labels are whole;
    // what moved is the count, onto its own line under the title.
    //
    // One locale per test, deliberately: two whole shells inside a single
    // `testWidgets` do not settle, and the failure that produces is a
    // `pumpAndSettle timed out` ten minutes later rather than an answer.
    for (final tag in <String>['en', 'ru']) {
      testWidgets('the count is what gives first: it drops under the title, '
          'in $tag', (tester) async {
        final (title, count) = await layout(tester, tag, 320, 1.0);
        expect(
          count.top,
          greaterThanOrEqualTo(title.bottom),
          reason: 'in $tag the count did not move under the title',
        );
        expect(count.left, title.left, reason: 'in $tag it did not line up');
        final l = L.of(tester.element(header()));
        final (titleParagraph, countParagraph) = labelsOf(tester, l);
        expect(_truncated(titleParagraph), isFalse, reason: tag);
        expect(_truncated(countParagraph), isFalse, reason: tag);
      });
    }

    testWidgets('and past that each label takes a second line of its own', (
      tester,
    ) async {
      // The worst combination on the board: 320dp at a 2.0 text scale in
      // Russian, 415px over on `main`. «Дополнительно» is one word wider than
      // the whole pane at that scale, so the only thing left to give is the
      // label itself — and it takes a second line rather than being cut.
      await openTheForm(tester, 'ru', 320, 2.0);
      final l = L.of(tester.element(header()));
      final (title, count) = labelsOf(tester, l);

      expect(title.size.height, greaterThan(count.size.height / 2));
      expect(
        title.size.height,
        greaterThan(36),
        reason: '«${l.formAdvanced}» stayed on one line, so it was cut',
      );
      expect(_truncated(title), isFalse);
      expect(_truncated(count), isFalse);
      expect(
        _overflowing(tester.renderObject(header())),
        isEmpty,
        reason: 'the worst combination on the board still overflows',
      );
      expect(
        _spills(tester, header()),
        isEmpty,
        reason: 'the worst combination on the board draws past its edge',
      );
    });
  });

  group('it is still the disclosure it was', () {
    testWidgets('every line of it is one tap target, and it opens and shuts', (
      tester,
    ) async {
      // 360dp at a 1.3 text scale, in Russian: two lines, because the count
      // has dropped under the title. A shape where only the first line
      // answered a tap would satisfy every assertion above and be broken for
      // a person, so each label is tapped where it actually is rather than in
      // the middle of the row.
      await openTheForm(tester, 'ru', 360, 1.3);
      final l = L.of(tester.element(header()));
      final (title, count) = labelsOf(tester, l);
      expect(
        (count.localToGlobal(Offset.zero) & count.size).top,
        greaterThanOrEqualTo((title.localToGlobal(Offset.zero) & title.size).bottom),
        reason: 'this test needs a header of more than one line to mean much',
      );
      expect(find.byKey(LcKeys.advancedSection), findsNothing);

      final opening = await collecting(() async {
        await tester.tapAt(count.localToGlobal(count.size.center(Offset.zero)));
        await tester.pumpAndSettle();
      });
      expect(
        find.byKey(LcKeys.advancedSection),
        findsOneWidget,
        reason: 'the count line is not part of the tap target',
      );
      expect(
        _summaries(opening),
        isEmpty,
        reason: 'opening Advanced overflowed something',
      );

      await tester.tapAt(title.localToGlobal(title.size.center(Offset.zero)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(LcKeys.advancedSection),
        findsNothing,
        reason: 'the title line is not part of the tap target',
      );

      // And the ordinary way, on the row itself, which is what every other
      // test in this suite taps.
      await tester.tap(header());
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      expect(find.byKey(LcKeys.field('seed')), findsOneWidget);
      expect(_overflowing(tester.renderObject(header())), isEmpty);
      expect(_spills(tester, header()), isEmpty);
    });

    testWidgets('opened, it survives the fold, and does not overflow after it',
        (tester) async {
      // T-0144 pinned that the open/closed state outlives a rebuild. This
      // card changed the header's geometry, so it is worth proving that the
      // state and the layout both come through the same fold — and a fold is
      // the one moment this row is laid out at a width it was not built at.
      await openTheForm(tester, 'ru', 360, 1.3);
      await tester.tap(header());
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);

      final folding = await collecting(() async {
        tester.view.physicalSize = const Size(1000, 3000);
        await tester.pumpAndSettle();
      });

      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(
        find.byKey(LcKeys.advancedSection),
        findsOneWidget,
        reason: 'the fold shut Advanced',
      );
      expect(
        _summaries(folding),
        isEmpty,
        reason: 'the fold overflowed something',
      );
      expect(_overflowing(tester.renderObject(header())), isEmpty);
      expect(_spills(tester, header()), isEmpty);
      final l = L.of(tester.element(header()));
      final (title, count) = labelsOf(tester, l);
      expect(_truncated(title), isFalse);
      expect(_truncated(count), isFalse);
    });
  });
}
