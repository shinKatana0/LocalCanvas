/// The chosen workflow's name gets room to be read (T-0188).
///
/// The header of the chosen-workflow block put the name and summary in a row
/// beside the badge and the disclosure arrow, and handed the text whatever the
/// badge left. At a 2.0 text scale in the two-pane layout that was a sliver:
/// T-0176 measured under 24dp at a foldable's own
/// 841dp width, with nobody dragging anything.
///
/// **What is measured is the width the name is OFFERED**, not whether it is
/// cut off. A name wrapped one letter to a line is not truncated — every
/// glyph is drawn — and the "drawn whole" detector the pane sweep uses would
/// call it fine. The failure is the column it is given.
///
/// **The readable minimum is spelled out here, not read from the widget**: the
/// name is offered at least six of its own font's em — six characters of a
/// fixed-advance face, and roughly twice that in a proportional one. Six rather
/// than more because at 841dp and a 1.0 scale an ordinary name is offered 6.7
/// em today, and that layout is not the defect. A test that asked the layout
/// what its minimum was would agree with any minimum.
///
/// And **T-0150**: every dp in this file is the test toolkit's fixed-advance
/// font. What these assertions establish is where the layout holds, never a
/// size in the shipped typeface.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// Six em: the readable minimum this card holds the name to.
const double kReadableEms = 6;

/// Strings nobody has used, chosen to break things in two different ways: a
/// name of many ordinary words that must wrap, and a single unbroken token —
/// the shape a curator's file name or an id pasted as a name takes — that
/// cannot wrap at a space at all.
const String kLongName =
    'A curator wrote this workflow name for a very particular pipeline and '
    'kept on writing well past any length a picker card was designed around';
const String kUnbrokenName =
    'curator_pipeline_refiner_pass_two_with_detail_upscale_v12';
const String kLongSummary =
    'Prompt, a reference picture, a mask, a second reference, and a strength '
    'for each of them, in that order';
const String kLongBadge = 'IMG2IMG+INPAINT+UPSCALE';

void main() {
  /// Every framework error raised during [step], whole — so a test can say
  /// which widget raised it.
  Future<List<String>> collecting(Future<void> Function() step) async {
    final caught = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => caught.add(details.toString());
    try {
      await step();
    } finally {
      FlutterError.onError = previous;
    }
    return caught;
  }

  /// The shell, two panes or one depending on [width], with one workflow
  /// chosen whose name, badge and summary the test decides.
  Future<List<String>> chooseIt(
    WidgetTester tester, {
    required double width,
    required double scale,
    String tag = 'en',
    String name = 'Example Text to Image',
    String? badge = 'TXT2IMG',
    String summary = 'Prompt only',
  }) async {
    tester.view.physicalSize = Size(width, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    // The summary lives in two places in a registry entry and the top-level
    // one wins (`WorkflowSummary.inputSummary`), so both are set.
    final detail = txt2imgDetail()
      ..['name'] = name
      ..['input_summary'] = summary;
    final presentation = Map<String, Object?>.of(
      detail['presentation']! as Map<String, Object?>,
    )..['input_summary'] = summary;
    if (badge == null) {
      presentation.remove('badge');
    } else {
      presentation['badge'] = badge;
    }
    detail['presentation'] = presentation;

    final workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[detail]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(detail)!,
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

    return collecting(() async {
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
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
    });
  }

  Finder inBlock(Finder what) =>
      find.descendant(of: find.byKey(LcKeys.selectedWorkflow), matching: what);

  RenderParagraph paragraph(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(inBlock(find.text(text)));

  /// The width the name was offered, and the six em it is owed.
  (double, double) offeredAndOwed(WidgetTester tester, String name) {
    final p = paragraph(tester, name);
    final em = p.textScaler.scale(p.text.style!.fontSize!);
    return (p.constraints.maxWidth, kReadableEms * em);
  }

  /// Every box under the block that reaches past its left or right edge.
  List<String> spills(WidgetTester tester) {
    final root = tester.renderObject<RenderBox>(
      find.byKey(LcKeys.selectedWorkflow),
    );
    final bounds = root.localToGlobal(Offset.zero) & root.size;
    final found = <String>[];
    void visit(RenderObject child) {
      if (child is RenderBox && child.hasSize) {
        final rect = child.localToGlobal(Offset.zero) & child.size;
        if (rect.left < bounds.left - 0.5 || rect.right > bounds.right + 0.5) {
          found.add('${child.runtimeType} $rect outside $bounds');
        }
      }
      child.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  group('the name is offered a readable width', () {
    // A foldable's inner width, the widths T-0176 measured, and two phones.
    for (final width in <double>[841, 900, 917, 1100, 360, 412]) {
      for (final tag in <String>['en', 'ru']) {
        for (final scale in <double>[1.0, 1.3, 2.0]) {
          testWidgets('${width}dp, $tag, x$scale', (tester) async {
            final errors = await chooseIt(
              tester,
              width: width,
              scale: scale,
              tag: tag,
            );
            final (offered, owed) = offeredAndOwed(
              tester,
              'Example Text to Image',
            );
            expect(
              offered,
              greaterThanOrEqualTo(owed),
              reason: 'the name was offered ${offered}dp, owed ${owed}dp',
            );
            expect(errors, isEmpty);
            expect(spills(tester), isEmpty);
            // The badge is still on screen, wherever it went.
            expect(inBlock(find.text('TXT2IMG')), findsOneWidget);
          });
        }
      }
    }
  });

  group('names, badges and summaries nobody has written yet', () {
    for (final (label, name) in <(String, String)>[
      ('a long name of ordinary words', kLongName),
      ('a long name with no space in it', kUnbrokenName),
    ]) {
      for (final width in <double>[841, 360]) {
        for (final scale in <double>[1.0, 2.0]) {
          testWidgets('$label, a long badge and summary, ${width}dp x$scale', (
            tester,
          ) async {
            final errors = await chooseIt(
              tester,
              width: width,
              scale: scale,
              name: name,
              badge: kLongBadge,
              summary: kLongSummary,
            );
            final (offered, owed) = offeredAndOwed(tester, name);
            expect(offered, greaterThanOrEqualTo(owed));
            // Everywhere: the picker's card row overflowed here until T-0216.
            expect(errors, isEmpty);
            expect(spills(tester), isEmpty);
            expect(inBlock(find.text(kLongBadge)), findsOneWidget);
            expect(inBlock(find.text(kLongSummary)), findsOneWidget);
          });
        }
      }
    }
  });

  group('an ordinary name at an ordinary width is laid out as before', () {
    // Pinned against the layout BEFORE T-0188 — this group was run against the
    // unchanged widget first and passed there. The badge sits beside the name,
    // on its first line, right of it, and the name is offered everything the
    // badge and the arrow leave.
    for (final width in <double>[1100, 412]) {
      testWidgets('${width}dp at x1.0', (tester) async {
        await chooseIt(tester, width: width, scale: 1.0);
        final name = tester.getRect(
          inBlock(find.text('Example Text to Image')),
        );
        final badge = tester.getRect(inBlock(find.text('TXT2IMG')));
        final arrow = tester.getRect(inBlock(find.byIcon(Icons.expand_more)));
        final summary = tester.getRect(inBlock(find.text('Prompt only')));

        expect(badge.left, greaterThan(name.right));
        expect(badge.top, lessThan(summary.top));
        expect(arrow.left, greaterThan(badge.right));

        final offered = paragraph(
          tester,
          'Example Text to Image',
        ).constraints.maxWidth;
        final badgeBox = tester.getRect(
          find
              .ancestor(
                of: inBlock(find.text('TXT2IMG')),
                matching: find.byType(Container),
              )
              .first,
        );
        // Card padding 16 each side, an 8dp gap before the badge and another
        // before the 24dp arrow: what the row gave the text before this card.
        final block = tester.getRect(find.byKey(LcKeys.selectedWorkflow));
        final expected = block.width - 2 - 16 * 2 - 8 - badgeBox.width - 8 - 24;
        expect(offered, closeTo(expected, 0.5));
      });
    }
  });

  testWidgets('the measurement can see a sliver', (tester) async {
    // The control. Without it "offered at least six em" could be passing
    // because the paragraph it measures is never the one on screen.
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Container(
            key: LcKeys.selectedWorkflow,
            child: const Row(
              children: <Widget>[
                SizedBox(width: 380),
                Expanded(child: Text('Example Text to Image')),
              ],
            ),
          ),
        ),
      ),
    );
    final (offered, owed) = offeredAndOwed(tester, 'Example Text to Image');
    expect(offered, lessThan(owed));
  });
}
