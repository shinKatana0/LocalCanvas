/// The rest of the "a row with a child that cannot give" class, fixed together
/// (T-0158, T-0159, T-0190, T-0216).
///
/// T-0188 fixed one instance — the chosen-workflow block. This file holds the
/// others the sweeps found, and it is written against the lesson that sweep
/// taught: **a `Wrap` announces nothing.** A fix that swaps a `Row` for a
/// `Wrap` silences `RenderFlex` without proving anything, so every assertion
/// below that could be answered by "no error was raised" is ALSO answered
/// geometrically — a rectangle inside another, or one box below another.
///
/// **T-0150**: every dp here is the test toolkit's fixed-advance font. What is
/// established is where a layout holds, never a size in the shipped face.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/common/label_value_row.dart';
import 'package:localcanvas/ui/connect/connect_screen.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// Six em, spelled out rather than read from `kMinNameEms`: a test that asked
/// the layout for its minimum would agree with any minimum.
const double kReadableEms = 6;

const String kLongName =
    'A curator wrote this workflow name for a very particular pipeline and '
    'kept on writing well past any length a picker card was designed around';
const String kLongBadge = 'IMG2IMG+INPAINT+UPSCALE';

void main() {
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

  void window(WidgetTester tester, double width, double scale) {
    tester.view.physicalSize = Size(width, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  bool inside(Rect inner, Rect outer) =>
      inner.left >= outer.left - 0.5 && inner.right <= outer.right + 0.5;

  /// The shell with one workflow, chosen, built from [detail].
  Future<List<String>> shellWith(
    WidgetTester tester,
    Map<String, Object?> detail, {
    String tag = 'en',
    bool choose = true,
  }) async {
    final workflows = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[detail]),
        ),
        details: <String, WorkflowDetail>{
          detail['id']! as String: WorkflowDetail.tryFromJson(detail)!,
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
      if (choose) {
        await tester.tap(
          find.byKey(LcKeys.workflowCard(detail['id']! as String)),
        );
        await tester.pumpAndSettle();
      }
    });
  }

  Map<String, Object?> detailNamed(String name, String badge) {
    final detail = txt2imgDetail()..['name'] = name;
    detail['presentation'] = Map<String, Object?>.of(
      detail['presentation']! as Map<String, Object?>,
    )..['badge'] = badge;
    return detail;
  }

  /// The width a paragraph was offered, and the six em it is owed.
  (double, double) offeredAndOwed(RenderParagraph p) {
    final em = p.textScaler.scale(p.text.style!.fontSize!);
    return (p.constraints.maxWidth, kReadableEms * em);
  }

  // ------------------------------------------------------------- T-0158
  group(
    'the connect screen names the product without overflowing (T-0158)',
    () {
      Future<List<String>> connect(WidgetTester tester, String tag) async {
        final controller = ConnectionController(
          client: ScriptedGatewayClient(
            (e) => HandshakeSucceeded(e, testIdentity()),
          ),
          store: InMemoryEndpointStore(),
          discovery: silentDiscovery(),
          retryDelay: Duration.zero,
        );
        addTearDown(controller.dispose);
        return collecting(() async {
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(tag),
              localizationsDelegates: testDelegates,
              supportedLocales: testLocales,
              theme: lcDarkTheme(),
              home: ConnectScreen(controller: controller),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
        });
      }

      for (final width in <double>[320, 360, 412]) {
        for (final scale in <double>[1.0, 1.3, 2.0]) {
          for (final tag in <String>['en', 'ru']) {
            testWidgets('${width}dp x$scale $tag', (tester) async {
              window(tester, width, scale);
              final errors = await connect(tester, tag);
              expect(errors, isEmpty);
              final box = tester.getRect(find.byKey(LcKeys.connectWordmark));
              expect(
                inside(box, Offset.zero & Size(width, 3000)),
                isTrue,
                reason: 'the name at $box',
              );
              // The whole name is drawn, scaled rather than cut: the child is
              // laid out at its own full width, whatever the box then does.
              final child = tester.renderObject<RenderBox>(
                find.descendant(
                  of: find.byKey(LcKeys.connectWordmark),
                  matching: find.byType(RichText),
                ),
              );
              expect(child.size.width, greaterThan(box.width - 0.5));
              // And what is PAINTED is inside the window too - read through the
              // box's own transform. Without this a box that stayed in bounds
              // while its child drew past it would pass: no error is raised
              // for that.
              final painted = tester.getRect(
                find.descendant(
                  of: find.byKey(LcKeys.connectWordmark),
                  matching: find.byType(RichText),
                ),
              );
              expect(
                inside(painted, Offset.zero & Size(width, 3000)),
                isTrue,
                reason: 'the name is painted at $painted',
              );
            });
          }
        }
      }

      testWidgets('at an ordinary scale the name is not shrunk at all', (
        tester,
      ) async {
        window(tester, 412, 1.0);
        await connect(tester, 'en');
        final box = tester.getRect(find.byKey(LcKeys.connectWordmark));
        final child = tester.renderObject<RenderBox>(
          find.descendant(
            of: find.byKey(LcKeys.connectWordmark),
            matching: find.byType(RichText),
          ),
        );
        expect(box.width, closeTo(child.size.width, 0.5));
      });
    },
  );

  // ------------------------------------------------ T-0216, T-0159 item 2
  group(
    'a workflow name keeps six em beside its badge everywhere (T-0216)',
    () {
      for (final width in <double>[360, 841]) {
        testWidgets('the picker card at ${width}dp x2.0', (tester) async {
          window(tester, width, 2.0);
          final errors = await shellWith(
            tester,
            detailNamed(kLongName, kLongBadge),
            choose: false,
          );
          expect(errors, isEmpty);
          final card = find.byKey(LcKeys.workflowCard('example_txt2img'));
          final name = tester.renderObject<RenderParagraph>(
            find.descendant(of: card, matching: find.text(kLongName)),
          );
          final (offered, owed) = offeredAndOwed(name);
          expect(offered, greaterThanOrEqualTo(owed));
          final badge = tester.getRect(
            find.descendant(of: card, matching: find.text(kLongBadge)),
          );
          expect(inside(badge, tester.getRect(card)), isTrue);
        });

        testWidgets('the help sheet at ${width}dp x2.0', (tester) async {
          window(tester, width, 2.0);
          final errors = await shellWith(
            tester,
            detailNamed(kLongName, kLongBadge),
            choose: false,
          );
          await tester.tap(
            find.byKey(LcKeys.workflowCardHelp('example_txt2img')),
          );
          errors.addAll(await collecting(tester.pumpAndSettle));
          expect(errors, isEmpty);
          final sheet = find.byKey(LcKeys.workflowHelpSheet);
          final name = tester.renderObject<RenderParagraph>(
            find.descendant(of: sheet, matching: find.text(kLongName)),
          );
          final (offered, owed) = offeredAndOwed(name);
          expect(offered, greaterThanOrEqualTo(owed));
        });
      }

      testWidgets(
        'an ordinary name at an ordinary width keeps its badge beside it',
        (tester) async {
          window(tester, 412, 1.0);
          await shellWith(tester, txt2imgDetail(), choose: false);
          final card = find.byKey(LcKeys.workflowCard('example_txt2img'));
          final name = tester.getRect(
            find.descendant(
              of: card,
              matching: find.text('Example Text to Image'),
            ),
          );
          final badge = tester.getRect(
            find.descendant(of: card, matching: find.text('TXT2IMG')),
          );
          expect(badge.left, greaterThan(name.right));
          expect(badge.top, lessThan(name.bottom));
        },
      );
    },
  );

  // -------------------------------------------------------- T-0159 item 1
  group('a seed slider\'s value and Random stay inside the field (T-0159)', () {
    Map<String, Object?> sliderSeed() {
      final detail = txt2imgDetail();
      final inputs = <Object?>[
        for (final input in detail['inputs']! as List<Object?>)
          if ((input! as Map<String, Object?>)['id'] == 'seed')
            Map<String, Object?>.of(input as Map<String, Object?>)
              ..['max'] = 100
              // The widest value this range can show. At 0 the old Row fitted and a
              // mutant putting it back survived; at 100 it overflowed by 37px at
              // 320dp x2.0 - measured with that mutant applied.
              ..['default'] = 100
              ..['section'] = 'main'
          else
            input,
      ];
      return detail..['inputs'] = inputs;
    }

    for (final width in <double>[320, 412]) {
      for (final tag in <String>['en', 'ru']) {
        testWidgets('${width}dp x2.0 $tag', (tester) async {
          window(tester, width, 2.0);
          final errors = await shellWith(tester, sliderSeed(), tag: tag);
          await tester.ensureVisible(find.byKey(LcKeys.fieldRandom('seed')));
          errors.addAll(await collecting(tester.pumpAndSettle));
          expect(errors, isEmpty);
          // It really is the slider branch, or this proves nothing about it.
          expect(find.byType(Slider), findsWidgets);
          final pane = tester.getRect(find.byKey(LcKeys.controlsPane));
          expect(
            inside(
              tester.getRect(find.byKey(LcKeys.fieldRandom('seed'))),
              pane,
            ),
            isTrue,
          );
          final label = tester.getRect(
            find.byKey(LcKeys.fieldLabelRow('seed')),
          );
          expect(inside(label, pane), isTrue);
        });
      }
    }
  });

  // -------------------------------------------------------- T-0159 item 3
  group('a label column moves above its value rather than taking the row', () {
    Widget row(double width) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: width,
          child: const LabelValueRow(
            labelWidth: 116,
            label: Text('Server version'),
            value: Text('0.1.1'),
          ),
        ),
      ),
    );

    testWidgets('beside, and exactly as before, where it fits', (tester) async {
      window(tester, 800, 1.0);
      await tester.pumpWidget(
        MediaQuery(data: const MediaQueryData(), child: row(400)),
      );
      final label = tester.getRect(find.text('Server version'));
      final value = tester.getRect(find.text('0.1.1'));
      expect(value.top, closeTo(label.top, 0.5));
      final labelBox = tester.getRect(
        find
            .ancestor(
              of: find.text('Server version'),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(labelBox.width, 116);
      expect(value.left, closeTo(labelBox.right, 0.5));
    });

    testWidgets('above, where the grown column would take the row', (
      tester,
    ) async {
      window(tester, 800, 2.0);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: row(300),
        ),
      );
      final label = tester.getRect(find.text('Server version'));
      final value = tester.getRect(find.text('0.1.1'));
      expect(value.top, greaterThanOrEqualTo(label.bottom - 0.5));
      // And the value is given the row, not a remainder.
      expect(value.left, closeTo(label.left, 0.5));
    });

    test('the rule itself, at its edge', () {
      expect(
        LabelValueRow.fitsBeside(rowWidth: 400, labelWidth: 116, textScale: 1),
        isTrue,
      );
      // 116 x 1.3 = 150.8 against 45% of 320 = 144.
      expect(
        LabelValueRow.fitsBeside(
          rowWidth: 320,
          labelWidth: 116,
          textScale: 1.3,
        ),
        isFalse,
      );
    });
  });

  // ------------------------------------------------------------- T-0190
  group('a numeric field\'s range hint is drawn whole (T-0190)', () {
    bool truncated(RenderParagraph p) {
      final offered = p.constraints.maxWidth;
      final painter = TextPainter(
        text: p.text,
        textDirection: p.textDirection,
        textScaler: p.textScaler,
      )..layout(maxWidth: offered);
      final fits = painter.height <= p.size.height + 0.5;
      painter.dispose();
      return !fits;
    }

    for (final (width, scale) in <(double, double)>[
      (412, 1.3),
      (320, 2.0),
      (412, 2.0),
      (841, 2.0),
    ]) {
      testWidgets('the seed\'s 0..4294967295 at ${width}dp x$scale', (
        tester,
      ) async {
        window(tester, width, scale);
        final detail = txt2imgDetail();
        detail['inputs'] = <Object?>[
          for (final input in detail['inputs']! as List<Object?>)
            if ((input! as Map<String, Object?>)['id'] == 'seed')
              Map<String, Object?>.of(input as Map<String, Object?>)
                ..['section'] = 'main'
            else
              input,
        ];
        await shellWith(tester, detail);
        await tester.ensureVisible(find.byKey(LcKeys.field('seed')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(LcKeys.field('seed')), '');
        await tester.pumpAndSettle();
        final hint = find.descendant(
          of: find.byKey(LcKeys.field('seed')),
          matching: find.textContaining('4294967295'),
        );
        expect(hint, findsOneWidget);
        expect(truncated(tester.renderObject<RenderParagraph>(hint)), isFalse);
      });
    }
  });
}
