/// How many automatic attempts a lost connection gets, chosen by the person
/// (`docs/recovery.md`, T-0212).
///
/// Three things are asserted, and each against the thing that could get it
/// wrong rather than against the object that reports it:
///
/// * **the number of probes** is counted on the gateway client — the requests
///   that actually went out — never on [SessionController.attemptsMade], which
///   is the session describing itself;
/// * **the bound** is asserted at both ends of the stepper, in the store, and in
///   the session, since each could let an out-of-range count through alone;
/// * **what survives a relaunch** goes through the real preferences store and
///   is read back both through a second store and around it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/reconnect_attempts_store.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Endpoint.tryParse('192.0.2.42:7801')!;

  HandshakeOutcome unreachable(Endpoint e) => HandshakeFailed(
    describeProblem(ConnectionProblem.unreachable, address: e.display),
  );

  /// A connected session whose gateway then stops answering. [onProbe] runs
  /// inside every handshake after the first connection, before it answers.
  Future<(SessionController, ScriptedGatewayClient)> deadGateway({
    ReconnectAttemptsStore? store,
    void Function(int probe)? onProbe,
  }) async {
    var connecting = true;
    var probes = 0;
    final client = ScriptedGatewayClient((e) {
      if (connecting) return HandshakeSucceeded(e, testIdentity());
      onProbe?.call(++probes);
      return unreachable(e);
    });
    final connection = ConnectionController(
      client: client,
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(endpoint);
    connecting = false;
    final workflows = emptyRegistry();
    addTearDown(workflows.dispose);
    final session = testSession(
      connection: connection,
      workflows: workflows,
      attemptsStore: store,
    );
    addTearDown(session.dispose);
    // Let a restore from the store land before the test acts.
    await pumpEventQueue();
    return (session, client);
  }

  /// The probes one reconnect sent, counted on the client.
  Future<int> probesOf(
    SessionController session,
    ScriptedGatewayClient client,
  ) async {
    final before = client.handshakes;
    expect(await session.reconnect(), isFalse);
    return client.handshakes - before;
  }

  group('the reconnect makes exactly the chosen number of attempts', () {
    test('three, with nothing chosen and nothing stored', () async {
      final (session, client) = await deadGateway(
        store: InMemoryReconnectAttemptsStore(),
      );
      expect(session.attempts, 3);
      expect(await probesOf(session, client), 3);
    });

    for (final count in <int>[1, 6, 10]) {
      test('$count, once chosen', () async {
        final store = InMemoryReconnectAttemptsStore();
        final (session, client) = await deadGateway(store: store);

        await session.chooseAttempts(count);

        expect(await probesOf(session, client), count);
        expect(store.written, <int>[count]);
      });
    }

    test('the count a previous launch chose, restored', () async {
      final (session, client) = await deadGateway(
        store: InMemoryReconnectAttemptsStore(7),
      );
      expect(session.attempts, 7);
      expect(await probesOf(session, client), 7);
    });

    test('a count chosen during a reconnect waits for the next one', () async {
      late SessionController live;
      final (session, client) = await deadGateway(
        store: InMemoryReconnectAttemptsStore(),
        onProbe: (probe) {
          // Inside the first probe of the first reconnect.
          if (probe == 1) live.chooseAttempts(8);
        },
      );
      live = session;

      expect(await probesOf(session, client), 3);
      expect(session.attempts, 8);
      expect(await probesOf(session, client), 8);
    });

    test('a remembered count arriving late does not undo a choice', () async {
      final store = InMemoryReconnectAttemptsStore(9)
        ..loadGate = Completer<void>();
      final (session, client) = await deadGateway(store: store);

      await session.chooseAttempts(2);
      store.loadGate!.complete();
      await pumpEventQueue();

      expect(session.attempts, 2);
      expect(await probesOf(session, client), 2);
    });
  });

  group('the bound', () {
    test('is 1 to 10, as the contract says', () {
      // Spelled out rather than read from the constants: a test that asked
      // the file what its bound is would agree with any bound.
      expect(kMinReconnectAttempts, 1);
      expect(kMaxReconnectAttempts, 10);
    });

    for (final count in <int>[0, -1, 11, 1000]) {
      test('the session refuses $count and keeps what it had', () async {
        final store = InMemoryReconnectAttemptsStore();
        final (session, client) = await deadGateway(store: store);

        await expectLater(session.chooseAttempts(count), throwsArgumentError);

        expect(session.attempts, 3);
        expect(store.written, isEmpty);
        expect(await probesOf(session, client), 3);
      });

      test('a stored $count is not used, and not clamped', () async {
        final (session, client) = await deadGateway(
          store: InMemoryReconnectAttemptsStore(count),
        );
        expect(session.attempts, 3);
        expect(await probesOf(session, client), 3);
      });
    }

    test('a build with no store offers no choice and keeps three', () async {
      final (session, client) = await deadGateway();
      expect(session.canChooseAttempts, isFalse);
      await session.chooseAttempts(9);
      expect(session.attempts, 3);
      expect(await probesOf(session, client), 3);
    });
  });

  group('the real store', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    const key = 'localcanvas.reconnect_attempts';

    test('owns the key it says it does, outside the profile', () {
      expect(PreferencesReconnectAttemptsStore.key, key);
      expect(key.startsWith('localcanvas.defaults.'), isFalse);
      expect(key.startsWith('localcanvas.setup.'), isFalse);
    });

    for (final count in <int>[1, 4, 10]) {
      test('$count survives the trip', () async {
        await PreferencesReconnectAttemptsStore().save(count);
        expect(await SharedPreferencesAsync().getInt(key), count);
        expect(await PreferencesReconnectAttemptsStore().load(), count);
      });
    }

    test('nothing stored reads as nothing said', () async {
      expect(await PreferencesReconnectAttemptsStore().load(), isNull);
    });

    for (final count in <int>[0, 11, -3]) {
      test('a stored $count reads as nothing said', () async {
        await SharedPreferencesAsync().setInt(key, count);
        expect(await PreferencesReconnectAttemptsStore().load(), isNull);
      });

      test('saving $count is refused and writes nothing', () async {
        expect(
          () => PreferencesReconnectAttemptsStore().save(count),
          throwsArgumentError,
        );
        expect(await SharedPreferencesAsync().getAll(), isEmpty);
      });
    }

    test('something that is not a number reads as nothing said', () async {
      await SharedPreferencesAsync().setString(key, 'five');
      // The value is really there, under this key, and really not a number.
      expect(await SharedPreferencesAsync().getString(key), 'five');
      // And reading it as a number really does fail in this implementation,
      // which is what the store's catch is for.
      await expectLater(
        SharedPreferencesAsync().getInt(key),
        throwsA(isA<TypeError>()),
      );
      expect(await PreferencesReconnectAttemptsStore().load(), isNull);
    });
  });

  group('the server block', () {
    Future<(SessionController, InMemoryReconnectAttemptsStore?)> pumpShell(
      WidgetTester tester, {
      required bool withStore,
      int? stored,
      double width = 400,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = withStore ? InMemoryReconnectAttemptsStore(stored) : null;
      final (session, _) = await tester.runAsync(
        () => deadGateway(store: store),
      ) as (SessionController, ScriptedGatewayClient);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: ConnectedShell(session: session),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
      await tester.pumpAndSettle();
      return (session, store);
    }

    String shown(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(LcKeys.reconnectAttemptsValue)).data!;

    bool enabled(WidgetTester tester, Key key) =>
        tester.widget<IconButton>(find.byKey(key)).onPressed != null;

    testWidgets('shows the count and changes it both ways', (tester) async {
      final (session, store) = await pumpShell(tester, withStore: true);

      expect(find.byKey(LcKeys.reconnectAttempts), findsOneWidget);
      expect(shown(tester), '3');

      await tester.tap(find.byKey(LcKeys.reconnectAttemptsMore));
      await tester.pumpAndSettle();
      expect(shown(tester), '4');
      expect(session.attempts, 4);

      // A frame between taps, as a finger has: each button acts on the count
      // it was drawn with.
      await tester.tap(find.byKey(LcKeys.reconnectAttemptsFewer));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.reconnectAttemptsFewer));
      await tester.pumpAndSettle();
      expect(shown(tester), '2');
      expect(session.attempts, 2);
      expect(store!.written, <int>[4, 3, 2]);
    });

    testWidgets('+ is disabled at ten, and ten is reachable', (tester) async {
      final (session, _) = await pumpShell(
        tester,
        withStore: true,
        stored: 9,
      );
      expect(enabled(tester, LcKeys.reconnectAttemptsMore), isTrue);

      await tester.tap(find.byKey(LcKeys.reconnectAttemptsMore));
      await tester.pumpAndSettle();

      expect(shown(tester), '10');
      expect(enabled(tester, LcKeys.reconnectAttemptsMore), isFalse);
      expect(enabled(tester, LcKeys.reconnectAttemptsFewer), isTrue);
      await tester.tap(find.byKey(LcKeys.reconnectAttemptsMore));
      await tester.pumpAndSettle();
      expect(session.attempts, 10);
    });

    testWidgets('− is disabled at one, and one is reachable', (tester) async {
      final (session, _) = await pumpShell(
        tester,
        withStore: true,
        stored: 2,
      );
      expect(enabled(tester, LcKeys.reconnectAttemptsFewer), isTrue);

      await tester.tap(find.byKey(LcKeys.reconnectAttemptsFewer));
      await tester.pumpAndSettle();

      expect(shown(tester), '1');
      expect(enabled(tester, LcKeys.reconnectAttemptsFewer), isFalse);
      expect(enabled(tester, LcKeys.reconnectAttemptsMore), isTrue);
      await tester.tap(find.byKey(LcKeys.reconnectAttemptsFewer));
      await tester.pumpAndSettle();
      expect(session.attempts, 1);
    });

    testWidgets('is absent on a build that cannot remember a choice', (
      tester,
    ) async {
      await pumpShell(tester, withStore: false);
      // The block is open, so an absent row is not a closed disclosure.
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);
      expect(find.byKey(LcKeys.reconnectAttempts), findsNothing);
    });

    // A `Wrap` reports no overflow, so "no exception" would be a guard that
    // cannot fail here. The assertion is geometric: every part of the row lies
    // inside the server block it belongs to.
    for (final (width, scale) in <(double, double)>[
      (320, 1),
      (320, 2),
      (280, 2),
    ]) {
      testWidgets('fits the block at ${width}dp and text scale $scale', (
        tester,
      ) async {
        await pumpShell(
          tester,
          withStore: true,
          stored: 10,
          width: width,
          textScale: scale,
        );
        final block = tester.getRect(find.byKey(LcKeys.serverDetails));
        for (final key in <Key>[
          LcKeys.reconnectAttemptsFewer,
          LcKeys.reconnectAttemptsValue,
          LcKeys.reconnectAttemptsMore,
        ]) {
          final part = tester.getRect(find.byKey(key));
          expect(
            part.left >= block.left - 0.5 && part.right <= block.right + 0.5,
            isTrue,
            reason: '$key at $part is outside the block at $block',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
