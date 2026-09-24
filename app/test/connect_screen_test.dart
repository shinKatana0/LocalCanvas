/// Choosing a server: four ways in, and none of them a dead end
/// (`docs/connection.md`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/discovery.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/connect/connect_screen.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';

import 'support/l10n.dart';
import 'support/fakes.dart';
import 'support/generation_fakes.dart';

void main() {
  late FakeDiscoveryBackend backend;
  late DiscoveryController discovery;
  late ScriptedGatewayClient client;
  late InMemoryEndpointStore store;

  ConnectionController build({
    HandshakeOutcome Function(Endpoint)? answer,
    bool discoveryFails = false,
    Object? discoveryError,
  }) {
    backend = FakeDiscoveryBackend(
      failsToStart: discoveryFails,
      startError: discoveryError,
    );
    discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 30),
    );
    client = ScriptedGatewayClient(
      answer ?? (e) => HandshakeSucceeded(e, testIdentity()),
    );
    store = InMemoryEndpointStore();
    final controller = ConnectionController(
      client: client,
      store: store,
      discovery: discovery,
      retryDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Widget harness(ConnectionController controller, {Locale? locale}) =>
      MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
    locale: locale,
    theme: lcDarkTheme(),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => controller.isConnected
          ? ConnectedShell(
              session: testSession(
                connection: controller,
                workflows: emptyRegistry(),
              ),
            )
          : ConnectScreen(controller: controller),
    ),
  );

  DiscoveredServer server(String id, String name) => DiscoveredServer(
    id: id,
    displayName: name,
    endpoint: Endpoint.tryParse('192.0.2.42:7801')!,
    gatewayVersion: '0.1.0',
    apiVersion: 1,
  );

  setUp(() {
    // A phone-sized window, so the screen is tested at the size it ships at.
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('manual entry is reachable from every state', () {
    testWidgets('while the search is running', (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump();

      expect(discovery.status, DiscoveryStatus.scanning);
      expect(find.byKey(LcKeys.enterAddress), findsOneWidget);
      expect(find.byKey(LcKeys.scanPairingCode), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 60));
    });

    testWidgets('when the search found nothing', (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byKey(LcKeys.discoveryEmpty), findsOneWidget);
      expect(find.byKey(LcKeys.enterAddress), findsOneWidget);
      expect(find.byKey(LcKeys.scanPairingCode), findsOneWidget);
    });

    testWidgets('when the device cannot search at all', (tester) async {
      phone(tester);
      final controller = build(discoveryFails: true);
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump(const Duration(milliseconds: 60));

      // Degraded, not dead-ended.
      expect(find.byKey(LcKeys.discoveryUnavailable), findsOneWidget);
      expect(find.byKey(LcKeys.enterAddress), findsOneWidget);
      expect(find.byKey(LcKeys.scanPairingCode), findsOneWidget);
    });

    testWidgets('when a connection has just failed', (tester) async {
      phone(tester);
      final controller = build(
        answer: (e) => HandshakeFailed(
          describeProblem(ConnectionProblem.unreachable, address: e.display),
        ),
      );
      await controller.connectTo(Endpoint.tryParse('192.0.2.42')!);
      await tester.pumpWidget(harness(controller));
      await tester.pump();

      expect(find.text("The LocalCanvas server can't be reached."),
          findsOneWidget);
      expect(find.byKey(LcKeys.retryConnection), findsOneWidget);
      expect(find.byKey(LcKeys.enterAddress), findsOneWidget);
    });
  });

  group('discovered servers', () {
    testWidgets('are listed by display name', (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump();

      backend.announce(server('a', 'Studio PC'));
      await tester.pump();

      expect(find.text('Studio PC'), findsOneWidget);
      expect(find.text('http://192.0.2.42:7801'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 60));
    });

    testWidgets('are still verified by the handshake before use',
        (tester) async {
      phone(tester);
      final controller = build(
        answer: (e) => HandshakeFailed(
          describeProblem(ConnectionProblem.notLocalCanvas, address: e.display),
        ),
      );
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump();
      backend.announce(server('a', 'Studio PC'));
      await tester.pump();

      await tester.tap(find.byKey(LcKeys.discoveredServer('a')));
      await tester.pumpAndSettle();

      // A candidate, not a connection: it failed the handshake, so it is not
      // connected and nothing was written down.
      expect(controller.isConnected, isFalse);
      expect(store.stored, isNull);
      expect(find.text("That address isn't a LocalCanvas server."),
          findsOneWidget);
    });

    testWidgets('connect when they identify themselves', (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump();
      backend.announce(server('a', 'Studio PC'));
      await tester.pump();

      await tester.tap(find.byKey(LcKeys.discoveredServer('a')));
      await tester.pumpAndSettle();

      expect(controller.isConnected, isTrue);
      expect(store.stored?.displayName, 'Studio PC');
    });
  });

  group('manual entry', () {
    Future<void> openAndType(WidgetTester tester, String value) async {
      await tester.tap(find.byKey(LcKeys.enterAddress));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(LcKeys.addressField), value);
      await tester.tap(find.byKey(LcKeys.addressSubmit));
      await tester.pumpAndSettle();
    }

    testWidgets('refuses input it cannot read, and says so', (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump(const Duration(milliseconds: 60));

      await openAndType(tester, 'not an address');

      expect(find.byKey(LcKeys.addressField), findsOneWidget);
      expect(find.textContaining("doesn't look like an address"), findsOneWidget);
      expect(client.handshakes, 0);
    });

    testWidgets('accepts a public HTTPS endpoint', (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump(const Duration(milliseconds: 60));

      await openAndType(tester, 'https://generation.example.com');

      // docs/transport-boundary.md §4: the UI may say v0.1 targets local
      // deployments; it must not enforce that by refusing input.
      expect(client.attempted.single.canonical, 'https://generation.example.com');
      expect(controller.isConnected, isTrue);
    });

    testWidgets('accepts a bare LAN address and fills in the defaults',
        (tester) async {
      phone(tester);
      final controller = build();
      await controller.start();
      await tester.pumpWidget(harness(controller));
      await tester.pump(const Duration(milliseconds: 60));

      await openAndType(tester, '192.0.2.42');

      expect(client.attempted.single.canonical, 'http://192.0.2.42:7801');
    });
  });

  testWidgets('a failed attempt offers a decision, not a spinner',
      (tester) async {
    phone(tester);
    final controller = build(
      answer: (e) => HandshakeFailed(
        describeProblem(ConnectionProblem.unreachable, address: e.display),
      ),
    );
    await controller.connectTo(Endpoint.tryParse('192.0.2.42')!);
    await tester.pumpWidget(harness(controller));
    await tester.pump();

    await tester.tap(find.byKey(LcKeys.retryConnection));
    await tester.pumpAndSettle();

    // Exactly one more attempt, and the screen still has every way forward.
    expect(client.handshakes, 2);
    expect(find.byKey(LcKeys.retryConnection), findsOneWidget);
    expect(find.byKey(LcKeys.enterAddress), findsOneWidget);
    expect(find.byKey(LcKeys.scanPairingCode), findsOneWidget);
  });

  group('when the search fails, the screen says why', () {
    /// What `nsd_discovery.dart` hands up when the Android plugin refuses for
    /// want of the multicast permission. The words are the platform's.
    const missingPermission = DiscoveryFailure(
      reason: 'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
      cause: 'securityIssue',
    );

    /// Every string the screen is currently drawing.
    List<String> drawn(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();

    Future<ConnectionController> failed(
      WidgetTester tester, {
      Locale? locale,
    }) async {
      phone(tester);
      final controller = build(discoveryError: missingPermission);
      await controller.start();
      await tester.pumpWidget(harness(controller, locale: locale));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(LcKeys.discoveryUnavailable), findsOneWidget);
      return controller;
    }

    testWidgets('the reason is on the card, in the platform\'s own words',
        (tester) async {
      await failed(tester);

      expect(
        find.text(
          'securityIssue: Missing required permission '
          'CHANGE_WIFI_MULTICAST_STATE',
        ),
        findsOneWidget,
      );
      expect(find.byKey(LcKeys.discoveryFailureReason), findsOneWidget);
    });

    testWidgets('the reason is not translated away', (tester) async {
      await failed(tester, locale: const Locale('ru'));

      // Two different things on one card: the sentence is the app's and is
      // translated, the reason is the platform's and is not.
      expect(find.text('В этот раз поиск не сработал.'), findsOneWidget);
      expect(
        find.text(
          'securityIssue: Missing required permission '
          'CHANGE_WIFI_MULTICAST_STATE',
        ),
        findsOneWidget,
      );
      expect(find.text('Что сообщила система'), findsOneWidget);
    });

    testWidgets('the screen claims nothing about the device, in en',
        (tester) async {
      await failed(tester);

      final strings = drawn(tester);
      // The screen was read, and this is what it says: without this line the
      // assertion below would pass on a blank screen.
      expect(strings, contains("Searching didn't work this time."));
      expect(
        strings,
        contains('The pairing code and the address below always work.'),
      );
      expect(
        strings.where((s) => s.toLowerCase().contains('device')),
        isEmpty,
        reason: 'the app has not established anything about this device',
      );
    });

    testWidgets('the screen claims nothing about the device, in ru',
        (tester) async {
      await failed(tester, locale: const Locale('ru'));

      final strings = drawn(tester);
      expect(strings, contains('В этот раз поиск не сработал.'));
      expect(
        strings,
        contains('Код подключения и адрес ниже работают всегда.'),
      );
      expect(
        strings.where((s) => s.toLowerCase().contains('устройств')),
        isEmpty,
        reason: 'the app has not established anything about this device',
      );
    });

    testWidgets('the two ways in that always work stay out of the scroll',
        (tester) async {
      await failed(tester);

      // The card that failed is inside the list and can be scrolled past; the
      // pairing code and the typed address are not, and must never become
      // something a user has to scroll to find.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byKey(LcKeys.discoveryUnavailable),
        ),
        findsOneWidget,
        reason: 'the finder works: the failed card really is in the list',
      );
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byKey(LcKeys.scanPairingCode),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byKey(LcKeys.enterAddress),
        ),
        findsNothing,
      );
    });

    testWidgets('manual entry still connects while discovery is down',
        (tester) async {
      final controller = await failed(tester);

      await tester.tap(find.byKey(LcKeys.enterAddress));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(LcKeys.addressField), '192.0.2.42');
      await tester.tap(find.byKey(LcKeys.addressSubmit));
      await tester.pumpAndSettle();

      expect(client.attempted.single.canonical, 'http://192.0.2.42:7801');
      expect(controller.isConnected, isTrue);
    });

    testWidgets('the pairing scanner still opens while discovery is down',
        (tester) async {
      await failed(tester);

      await tester.tap(find.byKey(LcKeys.scanPairingCode));
      await tester.pumpAndSettle();

      // The scanner screen came up: on a test host there is no camera, so it
      // offers its own way out, which is the thing that proves it is there.
      expect(find.byKey(LcKeys.scannerFallback), findsOneWidget);
    });
  });

  testWidgets('the search can be run again on request', (tester) async {
    phone(tester);
    final controller = build();
    await controller.start();
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 60));
    expect(backend.starts, 1);

    await tester.tap(find.byKey(LcKeys.searchAgain));
    await tester.pumpAndSettle();

    expect(backend.starts, 2);
  });
}
