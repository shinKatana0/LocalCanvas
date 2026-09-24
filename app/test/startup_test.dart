/// The startup experience, and the one property that matters about it: it
/// gates nothing (`docs/ui-ux.md`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/app.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/common/brand.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/startup/startup_intro.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;
  RememberedServer remembered() => RememberedServer(
    endpoint: endpoint,
    displayName: 'Studio PC',
    lastSuccess: DateTime.utc(2026),
  );

  test('the whole intro fits the window docs/ui-ux.md sets', () {
    final total = LcMotion.intro + LcMotion.introExit;
    expect(total.inMilliseconds, greaterThanOrEqualTo(800));
    expect(total.inMilliseconds, lessThanOrEqualTo(1500));
  });

  testWidgets('connection work finishes while the intro is still on screen',
      (tester) async {
    final client = ScriptedGatewayClient(
      (e) => HandshakeSucceeded(e, testIdentity()),
    );
    final controller = ConnectionController(
      client: client,
      store: InMemoryEndpointStore(remembered()),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );

    await tester.pumpWidget(LocalCanvasApp(
      appearance: testAppearance(),
      language: testLanguage(),
      session: testSession(
        connection: controller,
        workflows: emptyRegistry(),
      ),
    ));
    await tester.pump();
    // A quarter of the way into the intro, well before it ends.
    await tester.pump(LcMotion.intro ~/ 4);

    // The intro is still playing…
    expect(find.byKey(LcKeys.intro), findsOneWidget);
    // …and the app is already connected behind it. If readiness were gated on
    // the animation — start() called from its completion — this would still
    // be `idle`.
    expect(controller.phase, ConnectionPhase.connected);
    expect(client.handshakes, 1);

    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('the intro removes itself and reveals what is underneath',
      (tester) async {
    final controller = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(e, testIdentity()),
      ),
      store: InMemoryEndpointStore(remembered()),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(LocalCanvasApp(
      appearance: testAppearance(),
      language: testLanguage(),
      session: testSession(
        connection: controller,
        workflows: emptyRegistry(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(LcKeys.intro), findsNothing);
    expect(find.byKey(LcKeys.shellCompact), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('an intro that outruns the connection turns into Connecting…',
      (tester) async {
    final client = PendingGatewayClient();
    final controller = ConnectionController(
      client: client,
      store: InMemoryEndpointStore(remembered()),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );

    await tester.pumpWidget(LocalCanvasApp(
      appearance: testAppearance(),
      language: testLanguage(),
      session: testSession(
        connection: controller,
        workflows: emptyRegistry(),
      ),
    ));
    await tester.pump();
    // Frame past the end of the intro, then past its exit, then one more for
    // the removal. Bounded: an intro held open would still be here after this.
    await tester.pump(LcMotion.intro + const Duration(milliseconds: 20));
    await tester.pump(LcMotion.introExit + const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(LcKeys.intro), findsNothing);
    expect(find.byKey(LcKeys.connecting), findsOneWidget);
    // Polished, and continuous with the intro: the same mark and wordmark.
    expect(
      find.descendant(
        of: find.byKey(LcKeys.connecting),
        matching: find.byType(CanvasMark),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(LcKeys.connecting),
        matching: find.byType(Wordmark),
      ),
      findsOneWidget,
    );
    // Named, because the app knows whose door it is knocking on.
    expect(find.text('Connecting to Studio PC…'), findsOneWidget);

    client.completer.complete(HandshakeSucceeded(endpoint, testIdentity()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('the intro is painted in the theme, in both brightnesses',
      (tester) async {
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      final controller = ConnectionController(
        client: PendingGatewayClient(),
        store: InMemoryEndpointStore(remembered()),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );

      await tester.pumpWidget(LocalCanvasApp(
      appearance: testAppearance(),
      language: testLanguage(),
      session: testSession(
        connection: controller,
        workflows: emptyRegistry(),
      ),
    ));
      await tester.pump();
      await tester.pump(LcMotion.intro ~/ 2);

      final background = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(StartupIntro),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(
        background.color,
        brightness == Brightness.dark
            ? LcPalette.dark.canvas
            : LcPalette.light.canvas,
        reason: 'the intro must use the app\'s own surface, not a fixed colour',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });

  testWidgets('the mark forms rather than appearing finished', (tester) async {
    final controller = ConnectionController(
      client: PendingGatewayClient(),
      store: InMemoryEndpointStore(remembered()),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );

    await tester.pumpWidget(LocalCanvasApp(
      appearance: testAppearance(),
      language: testLanguage(),
      session: testSession(
        connection: controller,
        workflows: emptyRegistry(),
      ),
    ));
    await tester.pump();
    await tester.pump(LcMotion.intro ~/ 5);

    final inIntro = find.descendant(
      of: find.byType(StartupIntro),
      matching: find.byType(CanvasMark),
    );
    final early = tester.widget<CanvasMark>(inIntro).progress;
    await tester.pump(LcMotion.intro ~/ 2);
    final later = tester.widget<CanvasMark>(inIntro).progress;

    expect(early, greaterThan(0));
    expect(early, lessThan(1));
    expect(later, greaterThan(early));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
