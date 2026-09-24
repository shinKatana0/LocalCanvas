/// The two lines this card taught to give (T-0154, which absorbed T-0155).
///
/// Both were the same defect — **a row with a child that cannot give** — and
/// both had been overflowing while the whole suite was green, because no
/// guard had ever been pointed at them.
///
/// * **the picker card's bottom line**, `ui/workflows/workflow_picker.dart`:
///   `Row([Expanded(summary) | Spacer, TextButton])`. The button was not
///   flexible and its label alone is wider than the card at a raised text
///   scale, so the `Expanded` shrinking to nothing was still not enough —
///   36px over at 320/1.3, 183px at 320/2.0, 143px at 360/2.0, 91px at
///   412/2.0, **identical to the pixel in both locales** because
///   `What this does` and «Что это делает» are each 14 characters;
/// * **the field label line**, `ui/workflows/field_controls.dart`, in
///   `_FieldFrame`: `Row([Flexible(label), SizedBox, Text(Required), Spacer,
///   ?trailing])`. This one *looked* correct — the label really was wrapped
///   in a `Flexible`, and a design note read that and called the widget the
///   reference shape. `l.fieldRequired` beside it was a bare `Text`, so the
///   label collapsing to nothing was still not enough: 37px over at
///   ru 320/2.0 and 53px at ru 840/2.0, clean at all fifteen combinations in
///   English. **One `Flexible` in a `Row` proves nothing about the row.**
///
/// Three things about how this file measures, each of them a mistake this
/// class of defect has already cost the project:
///
/// * **errors are recorded per step, not asked for at the end.**
///   `tester.takeException()` after a sequence of taps answers with *an*
///   error, and on T-0153 that misattributed one overflow to three different
///   widgets in turn. `FlutterError.onError` is installed and drained around
///   each step, and each step is asserted while its own screen is still up;
/// * **attribution never depends on the error's text.** Each line carries a
///   key of its own — `LcKeys.workflowCardSummary`, `LcKeys.fieldLabelRow` —
///   and what is asserted is the render tree under that key. An overflow
///   somewhere else on the same screen cannot be mistaken for this one, and
///   this one cannot hide behind another;
/// * **the check does not know which layout widget draws the line.** A
///   `RenderFlex` says `OVERFLOWING` about itself, but a `RenderWrap` says
///   nothing at all, so asking only for overflowing flexes would go quiet the
///   moment the fix changed the widget — the guard would certify the property
///   by the very mechanism that provides it. So both are asked: no flex under
///   the key reports an overflow, **and** no box under the key is painted
///   outside it, whatever kind of box it is.
///
/// **Every dp named here is the widget-test toolkit's fixed-advance font** —
/// 15.09dp per character, Latin and Cyrillic alike (T-0150) — not the shipped
/// face. Nothing below is designed against those numbers; they are in the
/// test names so a reader can see which combinations this card repaired. The
/// overflow was a fact about the layout; the magnitudes are facts about the
/// harness.
library;

import 'dart:convert' show LineSplitter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/ui/workflows/workflow_picker.dart';
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
/// past the framework's tolerance — the same condition that draws the
/// yellow-and-black banner, read off the render objects under one key instead
/// of off the whole screen.
List<RenderFlex> _overflowing(RenderObject root) => <RenderFlex>[
  for (final flex in _flexesUnder(root))
    if (flex.toStringShort().contains('OVERFLOWING')) flex,
];

/// Every laid-out box under [root] painted outside [root]'s own rectangle.
///
/// This is the check that does not care what draws the line. A `RenderFlex`
/// announces its own overflow; a `RenderWrap` does not announce anything, and
/// neither does a `Stack` or a hand-rolled `CustomMultiChildLayout`. Geometry
/// is what a person actually sees, so geometry is what is asked.
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

/// Whether [paragraph] had to drop any of its text to fit the box it was
/// given — an ellipsis, or a line it had no room for.
///
/// Measured **independently of the widget's own settings**: the very span and
/// scaler it was laid out with are handed to a fresh `TextPainter` that has no
/// ellipsis and no line limit, and is offered the same width the paragraph was
/// offered. If the unrestricted painter then needs more room than the
/// paragraph occupies, what is on screen is not the whole text.
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

/// Anything between [finder] and [stopAt] that would keep a person from
/// seeing what [finder] found.
///
/// "The marker is still visible" is not the same claim as "the marker is
/// still in the tree with a size and a colour": a widget wrapped in an
/// `Opacity(0)` satisfies every geometric and stylistic check and is not on
/// screen. Making the requirement invisible instead of flexible is one of the
/// ways this fix could have been faked, so it is asked about directly.
List<String> _hiding(Finder finder, Key stopAt) {
  final hidden = <String>[];
  finder.evaluate().single.visitAncestorElements((ancestor) {
    final Widget widget = ancestor.widget;
    switch (widget) {
      case Opacity(:final opacity) when opacity <= 0.01:
        hidden.add('Opacity($opacity)');
      case AnimatedOpacity(:final opacity) when opacity <= 0.01:
        hidden.add('AnimatedOpacity($opacity)');
      case FadeTransition(:final opacity) when opacity.value <= 0.01:
        hidden.add('FadeTransition(${opacity.value})');
      case Offstage(offstage: true):
        hidden.add('Offstage');
      case Visibility(visible: false):
        hidden.add('Visibility(false)');
      case SizedBox(:final width, :final height)
          when width == 0 || height == 0:
        hidden.add('SizedBox($width, $height)');
      default:
        break;
    }
    return widget.key != stopAt;
  });
  return hidden;
}

/// The first line of each collected error — what an assertion prints when it
/// fails, without the several hundred lines of diagnostics behind it.
List<String> _summaries(List<String> errors) => <String>[
  for (final error in errors) const LineSplitter().convert(error).first,
];

void main() {
  /// The widths this app draws its controls column at, in both postures, and
  /// every text scale a phone offers. The same fifteen `theme_choice_test`
  /// and `advanced_header_test` use; the locale doubles it to thirty.
  const List<double> widths = <double>[320, 360, 412, 840, 1100];
  const List<double> scales = <double>[1.0, 1.3, 2.0];

  /// What the picker card's bottom line overflowed by on `main`, keyed
  /// without the locale because it was identical in both.
  const Map<String, int> summaryLineOnMain = <String, int>{
    '320/1.3': 36,
    '320/2.0': 183,
    '360/2.0': 143,
    '412/2.0': 91,
  };

  /// What the `prompt` field's label line overflowed by on `main`. Russian
  /// only: «Обязательное» is twelve characters where `Required` is eight.
  const Map<String, int> labelLineOnMain = <String, int>{
    'ru 320/2.0': 37,
    'ru 840/2.0': 53,
  };

  String combination(double width, double scale) =>
      '${width.toInt()}/$scale';
  String key(String tag, double width, double scale) =>
      '$tag ${combination(width, scale)}';

  /// One framework error, as the whole diagnostic text it arrived with.
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
  /// file ever runs while `FlutterError.onError` is overridden — a failing one
  /// inside that window does not report as a failure at all.
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

  /// Everything this file asks of one line, at one combination.
  ///
  /// The line is found by its own key, so what is asserted is *this* line and
  /// never "the screen": an overflow belonging to some other widget cannot
  /// satisfy it and cannot fail it.
  void lineIsWhole(
    WidgetTester tester,
    Key lineKey,
    String id,
    String what,
  ) {
    final finder = find.byKey(lineKey);
    expect(
      finder,
      findsOneWidget,
      reason: '$what is not on screen at $id, so nothing was measured',
    );
    final RenderBox line = tester.renderObject(finder);
    expect(
      line.size.width,
      greaterThan(0),
      reason: '$what has no width at $id',
    );
    expect(
      <String>[for (final flex in _overflowing(line)) flex.toStringShort()],
      isEmpty,
      reason: '$what overflowed at $id',
    );
    expect(
      <String>[
        for (final box in _spilling(line))
          '${box.toStringShort()} ${box.localToGlobal(Offset.zero) & box.size} '
              'outside ${line.localToGlobal(Offset.zero) & line.size}',
      ],
      isEmpty,
      reason: '$what was drawn past its own edge at $id',
    );
  }

  /// The paragraph that says [text], somewhere under [lineKey].
  RenderParagraph paragraphOn(
    WidgetTester tester,
    Key lineKey,
    String text,
    String id,
    String what,
  ) {
    final finder = find.descendant(
      of: find.byKey(lineKey),
      matching: find.text(text),
    );
    expect(
      finder,
      findsOneWidget,
      reason: '"$text" is not on $what at $id',
    );
    return tester.renderObject<RenderParagraph>(finder);
  }

  /// Builds the shell for one combination and hands back the two things a
  /// step needs: the tester's screen, and what that step reported.
  Future<void> shellAt(
    WidgetTester tester,
    String tag,
    double width,
    double scale, {
    required Future<void> Function(List<String> errors) atLaunch,
    required Future<void> Function(List<String> errors) atPicker,
    required Future<void> Function(List<String> errors) atChoose,
    required Future<void> Function(List<String> errors) atAdvanced,
    bool stopAfterPicker = false,
    // Tall enough that every step's target is inside the viewport and can be
    // tapped. It is not a property of the app and nothing is asserted about
    // it — a form that is 4000dp long at a 2.0 text scale is simply longer
    // than the default surface, and a tap that lands outside the viewport
    // does nothing and takes the rest of the sequence with it.
    double height = 3000,
  }) async {
    tester.view.physicalSize = Size(width, height);
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

    await atLaunch(
      await collecting(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(tag),
            localizationsDelegates: testDelegates,
            supportedLocales: testLocales,
            theme: lcDarkTheme(),
            home: ConnectedShell(
              session: testSession(
                connection: connection,
                workflows: workflows,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }),
    );
    await atPicker(
      await collecting(() async {
        await tester.tap(find.byKey(LcKeys.chooseWorkflow));
        await tester.pumpAndSettle();
      }),
    );
    // A step that opened something of its own — the help sheet — leaves a
    // screen the next tap cannot be made on, so a caller that did that says
    // so rather than letting the sequence fail somewhere further down with a
    // finder that found nothing.
    if (stopAfterPicker) return;
    await atChoose(
      await collecting(() async {
        await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
        await tester.pumpAndSettle();
      }),
    );
    await atAdvanced(
      await collecting(() async {
        await tester.tap(find.byKey(LcKeys.advancedToggle));
        await tester.pumpAndSettle();
      }),
    );
  }

  Key summaryLine() => LcKeys.workflowCardSummary('example_txt2img');
  Key labelLine(String field) => LcKeys.fieldLabelRow(field);

  group('the detectors this file measures with catch what they look for', () {
    // Otherwise every assertion below could be passing because the detector
    // never fires — which is exactly how both of these lines went on
    // overflowing while the suite was green.
    testWidgets('an overflowing Row is seen, and a fitting one is not', (
      tester,
    ) async {
      Widget row(double width) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: width,
            child: Row(
              children: const <Widget>[
                SizedBox(width: 100, height: 10),
                SizedBox(width: 100, height: 10),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(row(300));
      expect(_overflowing(tester.renderObject(find.byType(Row))), isEmpty);
      expect(
        _spilling(tester.renderObject(find.byType(Row))),
        isEmpty,
        reason: 'nothing was outside a row that fits',
      );

      await tester.pumpWidget(row(150));
      expect(tester.takeException(), isNotNull, reason: 'it really overflowed');
      final seen = _overflowing(tester.renderObject(find.byType(Row)));
      expect(seen, hasLength(1));
      expect(seen.single.toStringShort(), contains('OVERFLOWING'));
      // The other detector sees the same defect, from the other side: what
      // the flex complains about is a child painted past its edge.
      expect(
        _spilling(tester.renderObject(find.byType(Row))),
        isNotEmpty,
        reason: 'a row 50dp over its width had nothing outside it',
      );
    });

    testWidgets('a box drawn past a parent that never complains is seen too', (
      tester,
    ) async {
      // The check that does not depend on the layout widget knowing it is in
      // trouble. A `RenderStack` with `Clip.none` reports nothing at all,
      // however far its child is placed outside it — and neither does a
      // `RenderWrap`, which is what draws both of the lines this file is
      // about. A detector that only asked flexes would go quiet the moment
      // the fix stopped using one.
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
        _spilling(tester.renderObject(find.byKey(const Key('probe')))),
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
        _spilling(tester.renderObject(find.byKey(const Key('probe')))),
        isNotEmpty,
        reason: 'a child 140dp past its parent was called contained',
      );
    });

    testWidgets('a label that is present and invisible is seen as invisible', (
      tester,
    ) async {
      Widget wrapped(Widget Function(Widget) around) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            key: const Key('line'),
            width: 200,
            height: 40,
            child: around(const Text('Required')),
          ),
        ),
      );

      await tester.pumpWidget(wrapped((child) => child));
      expect(_hiding(find.text('Required'), const Key('line')), isEmpty);

      await tester.pumpWidget(
        wrapped((child) => Opacity(opacity: 0, child: child)),
      );
      expect(
        find.text('Required'),
        findsOneWidget,
        reason: 'it is still in the tree — that is the whole point',
      );
      expect(
        tester.renderObject<RenderParagraph>(find.text('Required')).size.width,
        greaterThan(0),
        reason: 'and it still has a size, and a colour, and is not cut',
      );
      expect(
        _hiding(find.text('Required'), const Key('line')),
        <String>['Opacity(0.0)'],
        reason: 'a word behind a zero opacity was called visible',
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

  group('neither line can overflow, at any width, scale or locale', () {
    for (final tag in <String>['en', 'ru']) {
      for (final width in widths) {
        for (final scale in scales) {
          final id = key(tag, width, scale);
          final card = summaryLineOnMain[combination(width, scale)];
          final label = labelLineOnMain[id];
          final was = <String>[
            if (card != null) 'the card line by ${card}px',
            if (label != null) 'the label line by ${label}px',
          ];
          final what = was.isEmpty
              ? 'both fitted on main'
              : 'on main ${was.join(' and ')} ran over';
          testWidgets('at ${width.toInt()}dp, text scale $scale, in $tag — '
              '$what', (tester) async {
            final l = bundles[tag]!;
            await shellAt(
              tester,
              tag,
              width,
              scale,
              atLaunch: (errors) async {
                expect(
                  _summaries(errors),
                  isEmpty,
                  reason: 'launching reported an error at $id',
                );
              },
              atPicker: (errors) async {
                // The premises first: the locale really reached the tree, the
                // line really is on screen, and it really is carrying both of
                // the things that used to run past its edge. Without these,
                // "nothing overflowed" would also be true of a blank screen.
                expect(
                  Localizations.localeOf(
                    tester.element(find.byKey(LcKeys.workflowPicker)),
                  ),
                  Locale(tag),
                );
                final summary = paragraphOn(
                  tester,
                  summaryLine(),
                  'Prompt only',
                  id,
                  'the card line',
                );
                final button = paragraphOn(
                  tester,
                  summaryLine(),
                  l.workflowWhatThisDoes,
                  id,
                  'the card line',
                );

                lineIsWhole(tester, summaryLine(), id, 'the card line');
                expect(
                  _truncated(summary),
                  isFalse,
                  reason: 'the input summary is cut off at $id',
                );
                expect(
                  _truncated(button),
                  isFalse,
                  reason: '"${l.workflowWhatThisDoes}" is cut off at $id',
                );
                // And it is still something a thumb can hit.
                expect(
                  tester
                      .getRect(
                        find.byKey(
                          LcKeys.workflowCardHelp('example_txt2img'),
                        ),
                      )
                      .height,
                  greaterThanOrEqualTo(48),
                  reason: 'the help affordance is under a tap target at $id',
                );
                expect(
                  _summaries(errors),
                  isEmpty,
                  reason: 'opening the picker reported an error at $id',
                );
              },
              atChoose: (errors) async {
                final name = paragraphOn(
                  tester,
                  labelLine('prompt'),
                  'Prompt',
                  id,
                  "the prompt field's label line",
                );
                final required = paragraphOn(
                  tester,
                  labelLine('prompt'),
                  l.fieldRequired,
                  id,
                  "the prompt field's label line",
                );

                lineIsWhole(
                  tester,
                  labelLine('prompt'),
                  id,
                  "the prompt field's label line",
                );
                expect(
                  _truncated(name),
                  isFalse,
                  reason: 'the field name is cut off at $id',
                );
                // The marker yields by moving, never by vanishing: it is the
                // only thing on screen that says the field cannot be left
                // empty.
                expect(
                  _truncated(required),
                  isFalse,
                  reason: '"${l.fieldRequired}" is cut off at $id',
                );
                expect(
                  required.size.width,
                  greaterThan(0),
                  reason: '"${l.fieldRequired}" has no width at $id',
                );
                expect(
                  required.size.height,
                  greaterThan(0),
                  reason: '"${l.fieldRequired}" has no height at $id',
                );
                expect(
                  required.text.style?.color?.a ?? 0,
                  greaterThan(0),
                  reason: '"${l.fieldRequired}" is drawn in nothing at $id',
                );
                expect(
                  _hiding(
                    find.descendant(
                      of: find.byKey(labelLine('prompt')),
                      matching: find.text(l.fieldRequired),
                    ),
                    labelLine('prompt'),
                  ),
                  isEmpty,
                  reason: '"${l.fieldRequired}" is on the line at $id and '
                      'still cannot be seen',
                );
                expect(
                  _summaries(errors),
                  isEmpty,
                  reason: 'choosing the workflow reported an error at $id',
                );
              },
              atAdvanced: (errors) async {
                // The seed field's label line is the one that carries a
                // `trailing`, so opening Advanced is the only step where the
                // third child of this line is on screen at all.
                paragraphOn(
                  tester,
                  labelLine('seed'),
                  'Seed',
                  id,
                  "the seed field's label line",
                );
                expect(
                  find.descendant(
                    of: find.byKey(labelLine('seed')),
                    matching: find.byKey(LcKeys.fieldRandom('seed')),
                  ),
                  findsOneWidget,
                  reason: 'this step is meant to measure a line that has a '
                      'trailing affordance on it, and at $id it has none',
                );
                lineIsWhole(
                  tester,
                  labelLine('seed'),
                  id,
                  "the seed field's label line",
                );
                lineIsWhole(
                  tester,
                  labelLine('prompt'),
                  id,
                  "the prompt field's label line, with Advanced open",
                );
                expect(
                  _summaries(errors),
                  isEmpty,
                  reason: 'opening Advanced reported an error at $id',
                );
              },
            );
          });
        }
      }
    }
  });

  group('what each line does when it runs out of width', () {
    testWidgets('while both fit, the summary is left and the button is hard '
        'right — where the Expanded summary used to push it', (tester) async {
      // 1100dp at a 1.0 text scale: the widest supported pane, and one of the
      // eight combinations where `main` neither overflowed nor squeezed the
      // summary. Those eight are the ones whose shape is genuinely unchanged,
      // and this is the test that says so.
      //
      // It is eight and not twenty-two. Of the combinations that did not
      // overflow on `main`, fourteen were only fitting because the `Expanded`
      // was ellipsising the summary, and at those the button now moves onto a
      // line of its own so that the whole summary can be read. That is the
      // fix working, not a regression, and it is measured by the two tests
      // below rather than asserted here.
      const id = 'en 1100/1.0';
      await shellAt(
        tester,
        'en',
        1100,
        1.0,
        atLaunch: (_) async {},
        atPicker: (_) async {
          final summary = paragraphOn(
            tester,
            summaryLine(),
            'Prompt only',
            id,
            'the card line',
          );
          final summaryRect =
              summary.localToGlobal(Offset.zero) & summary.size;
          final button = tester.getRect(
            find.byKey(LcKeys.workflowCardHelp('example_txt2img')),
          );
          expect(
            button.left,
            greaterThan(summaryRect.right),
            reason: 'side by side',
          );
          expect(
            button.top,
            lessThan(summaryRect.bottom),
            reason: 'on one line',
          );
          // Measured against the badge at the top of the same card, not
          // against the line's own rectangle. A line that had quietly shrunk
          // to the width of its own contents would put the button flush with
          // *its* right edge and nowhere near the card's, and an assertion
          // that used the line as its own ruler would call that correct.
          final badge = tester.getRect(
            find.descendant(
              of: find.byKey(LcKeys.workflowCard('example_txt2img')),
              matching: find.byType(WorkflowBadge),
            ),
          );
          expect(
            badge.right - button.right,
            lessThan(0.5),
            reason: 'the button is no longer flush with the right edge of '
                'the card, where the Expanded summary used to push it',
          );
        },
        atChoose: (_) async {},
        atAdvanced: (_) async {},
      );
    });

    for (final tag in <String>['en', 'ru']) {
      testWidgets('past that the button drops under the summary, and the '
          'summary is not cut, in $tag', (tester) async {
        // 320dp at a 2.0 text scale: 183px over on `main`, in both locales.
        final id = '$tag 320/2.0';
        await shellAt(
          tester,
          tag,
          320,
          2.0,
          atLaunch: (_) async {},
          atPicker: (_) async {
            final summary = paragraphOn(
              tester,
              summaryLine(),
              'Prompt only',
              id,
              'the card line',
            );
            final summaryRect =
                summary.localToGlobal(Offset.zero) & summary.size;
            final button = tester.getRect(
              find.byKey(LcKeys.workflowCardHelp('example_txt2img')),
            );
            expect(
              button.top,
              greaterThanOrEqualTo(summaryRect.bottom),
              reason: 'in $tag the button did not move under the summary',
            );
            expect(
              _truncated(summary),
              isFalse,
              reason: 'in $tag the summary was cut instead',
            );
          },
          atChoose: (_) async {},
          atAdvanced: (_) async {},
        );
      });
    }

    testWidgets('the requirement drops under the field name rather than '
        'squeezing it', (tester) async {
      // ru 320/2.0: 37px over on `main`. «Обязательное» on its own is wider
      // than the pane at that scale, so the only shape that keeps both words
      // whole is a second line.
      await shellAt(
        tester,
        'ru',
        320,
        2.0,
        atLaunch: (_) async {},
        atPicker: (_) async {},
        atChoose: (_) async {
          final name = paragraphOn(
            tester,
            labelLine('prompt'),
            'Prompt',
            'ru 320/2.0',
            'the label line',
          );
          final required = paragraphOn(
            tester,
            labelLine('prompt'),
            ru.fieldRequired,
            'ru 320/2.0',
            'the label line',
          );
          final nameRect = name.localToGlobal(Offset.zero) & name.size;
          final requiredRect =
              required.localToGlobal(Offset.zero) & required.size;
          expect(
            requiredRect.top,
            greaterThanOrEqualTo(nameRect.bottom),
            reason: 'the requirement did not move under the name',
          );
          expect(requiredRect.left, nameRect.left, reason: 'it did not line up');
          expect(_truncated(name), isFalse);
          expect(_truncated(required), isFalse);
        },
        atAdvanced: (_) async {},
      );
    });

    testWidgets('while they fit, the name and the requirement stay side by '
        'side and the trailing affordance stays hard right', (tester) async {
      // en 412/1.0: an ordinary phone, where this line fitted on `main`.
      await shellAt(
        tester,
        'en',
        412,
        1.0,
        atLaunch: (_) async {},
        atPicker: (_) async {},
        atChoose: (_) async {
          final name = paragraphOn(
            tester,
            labelLine('prompt'),
            'Prompt',
            'en 412/1.0',
            'the label line',
          );
          final required = paragraphOn(
            tester,
            labelLine('prompt'),
            en.fieldRequired,
            'en 412/1.0',
            'the label line',
          );
          final nameRect = name.localToGlobal(Offset.zero) & name.size;
          final requiredRect =
              required.localToGlobal(Offset.zero) & required.size;
          final line = tester.getRect(find.byKey(labelLine('prompt')));
          expect(requiredRect.left, greaterThan(nameRect.right));
          expect(requiredRect.top, lessThan(nameRect.bottom));
          // And they are read *together*: the free space on this line falls
          // between the pair of them and whatever is at the far end, never
          // between the field's name and the word that says it cannot be
          // left empty. Written as a comparison of the two gaps rather than
          // against the spacing token, so it is a claim about what a person
          // sees and not a restatement of the layout's own constant.
          expect(
            requiredRect.left - nameRect.right,
            lessThan(line.right - requiredRect.right),
            reason: 'the requirement was pushed away from the name it '
                'belongs to',
          );
        },
        atAdvanced: (_) async {
          // Measured against the field's own row and not against the label
          // line, for the reason given on the picker card above: a line that
          // had shrunk to its contents would satisfy an assertion that used
          // itself as the ruler.
          //
          // And this pins a **new** property rather than preserving an old
          // one. The `Spacer` on `main` did not hold the trailing at the
          // edge: it is an `Expanded` with flex 1, and the `Flexible` label
          // beside it had flex 1 too, so the two of them split the free
          // space and the trailing sat short of the edge by an amount that
          // varied with the field's name — 55.3dp short here at en 412/1.0,
          // and 39.3dp at en 1100/1.0. Flush at 0.0 is what this card made
          // true, not what it kept.
          final row = tester.getRect(find.byKey(LcKeys.fieldRow('seed')));
          final random = tester.getRect(find.byKey(LcKeys.fieldRandom('seed')));
          expect(
            row.right - random.right,
            lessThan(0.5),
            reason: 'the trailing affordance is not hard against the right '
                'edge of the field',
          );
        },
      );
    });
  });

  group('outside the matrix entirely', () {
    // "No width may overflow them" is not "no supported width". These two are
    // absurd on purpose: 100dp is narrower than any phone ever shipped, and
    // 2000dp is wider than the widest posture this app is drawn in. Only the
    // two lines are asserted — at 100dp other widgets on the same screen have
    // troubles of their own, and this card did not undertake to fix them.
    for (final width in <double>[100, 2000]) {
      for (final tag in <String>['en', 'ru']) {
        testWidgets('at ${width.toInt()}dp and a 2.0 text scale, in $tag, '
            'both lines still hold their content', (tester) async {
          await shellAt(
            tester,
            tag,
            width,
            2.0,
            height: 12000,
            atLaunch: (_) async {},
            atPicker: (_) async {
              lineIsWhole(
                tester,
                summaryLine(),
                '$tag ${width.toInt()}/2.0',
                'the card line',
              );
            },
            atChoose: (_) async {
              lineIsWhole(
                tester,
                labelLine('prompt'),
                '$tag ${width.toInt()}/2.0',
                "the prompt field's label line",
              );
              expect(
                find.descendant(
                  of: find.byKey(labelLine('prompt')),
                  matching: find.text(bundles[tag]!.fieldRequired),
                ),
                findsOneWidget,
                reason: 'the requirement vanished at ${width.toInt()}dp '
                    'instead of yielding',
              );
            },
            atAdvanced: (_) async {
              lineIsWhole(
                tester,
                labelLine('seed'),
                '$tag ${width.toInt()}/2.0',
                "the seed field's label line",
              );
            },
          );
        });
      }
    }
  });

  group('the help affordance is still the affordance it was', () {
    testWidgets('at the worst combination it is still 48dp and still opens '
        'the sheet', (tester) async {
      // 320dp at a 2.0 text scale, where the line was 183px over on `main`
      // and the button is now on a line of its own. A shape where the button
      // survived the layout but stopped answering a tap would satisfy every
      // geometric assertion in this file and be broken for a person, so it is
      // tapped where it actually is.
      await shellAt(
        tester,
        'ru',
        320,
        2.0,
        atLaunch: (_) async {},
        atPicker: (_) async {
          final help = find.byKey(LcKeys.workflowCardHelp('example_txt2img'));
          final rect = tester.getRect(help);
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(find.byKey(LcKeys.workflowHelpSheet), findsNothing);

          await tester.tapAt(rect.center);
          await tester.pumpAndSettle();
          expect(
            find.byKey(LcKeys.workflowHelpSheet),
            findsOneWidget,
            reason: 'the help sheet did not open from where the button is',
          );
        },
        atChoose: (_) async {},
        atAdvanced: (_) async {},
        stopAfterPicker: true,
      );
    });
  });
}
