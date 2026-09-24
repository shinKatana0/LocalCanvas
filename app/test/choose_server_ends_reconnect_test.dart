/// Choose another server ends the automatic reconnect that was running
/// (T-0243).
///
/// `docs/recovery.md`: the bounded reconnect's way out is **Choose another
/// server**. The button is there while the attempts run, and a person who
/// presses it has asked to leave — so nothing that reconnect already started may
/// bring them back: not the handshake still on the wire, not the attempt after
/// the backoff, not the registry reload or the job recovery that follow a
/// handshake that answered.
///
/// Every race here is held with a gate and released in the order a real
/// transport would release it: the request left before the choice, and its
/// reply lands after it. Each absence ("no request was made") is paired with a
/// run that is not superseded, where the same counter does move.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/l10n/accept_language.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';

/// A gateway whose handshake the test can hold on the wire.
///
/// A held handshake is answered with whatever the test completes it with, at
/// the moment it completes it: the request is out, and what comes back is the
/// reply that lands later. Every handshake not held is answered at once by
/// [answer].
class _HeldGatewayClient implements GatewayClient {
  _HeldGatewayClient(this.answer);

  final HandshakeOutcome Function(Endpoint endpoint) answer;

  /// Taken by the next handshake, and only by that one.
  Completer<HandshakeOutcome>? _hold;

  int handshakes = 0;
  final List<Endpoint> attempted = <Endpoint>[];

  /// Holds the next handshake; the test completes it to deliver the reply.
  Completer<HandshakeOutcome> holdNext() {
    final hold = Completer<HandshakeOutcome>();
    _hold = hold;
    return hold;
  }

  /// Whether a [holdNext] is still waiting for a handshake to take it.
  bool get holdPending => _hold != null;

  @override
  Duration get timeout => const Duration(seconds: 4);

  @override
  LanguageTagSource get language => () => kFallbackLanguageTag;

  @override
  Future<HandshakeOutcome> handshake(Endpoint endpoint) {
    handshakes++;
    attempted.add(endpoint);
    final hold = _hold;
    _hold = null;
    if (hold != null) return hold.future;
    return Future<HandshakeOutcome>.value(answer(endpoint));
  }

  @override
  void dispose() {}
}

/// A registry whose list request the test can hold, and which counts them.
class _HeldWorkflowsApi implements WorkflowsApi {
  int listCalls = 0;

  /// Taken by the next list request, and only by that one.
  Completer<void>? listGate;

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async {
    listCalls++;
    final gate = listGate;
    listGate = null;
    if (gate != null) await gate.future;
    return const <WorkflowSummary>[];
  }

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) =>
      throw StateError('no workflow is opened in these tests');
}

class _App {
  _App({
    required this.client,
    required this.store,
    required this.connection,
    required this.registry,
    required this.workflows,
    required this.jobs,
    required this.generation,
    required this.session,
  });

  final _HeldGatewayClient client;
  final InMemoryEndpointStore store;
  final ConnectionController connection;
  final _HeldWorkflowsApi registry;
  final WorkflowsController workflows;
  final ScriptedJobsApi jobs;
  final GenerationController generation;
  final SessionController session;

  /// Whether a handshake that is not held finds anything there.
  bool reachable = true;
}

void main() {
  final home = Endpoint.tryParse('192.0.2.42:7801')!;
  final elsewhere = Endpoint.tryParse('192.0.2.77:7801')!;

  /// The poll never ticks unless a test asks it to: the only snapshot requests
  /// are the ones somebody decided to make.
  const never = Duration(hours: 1);

  /// Each server calls itself something different, so the identity the
  /// connection holds says which one answered.
  HandshakeOutcome succeeded(Endpoint e) => HandshakeSucceeded(
    e,
    testIdentity(displayName: e == home ? 'Studio PC' : 'Attic PC'),
  );

  HandshakeOutcome unreachable(Endpoint e) => HandshakeFailed(
    describeProblem(ConnectionProblem.unreachable, address: e.display),
  );

  /// A settled answer: something is there and it is not LocalCanvas. Not worth
  /// a second try, so the launch sequence stops at the first one.
  HandshakeOutcome notLocalCanvas(Endpoint e) => HandshakeFailed(
    describeProblem(ConnectionProblem.notLocalCanvas, address: e.display),
  );

  Future<_App> connectedApp({
    int attempts = 1,
    Duration backoff = Duration.zero,
    Duration pollInterval = never,
  }) async {
    late final _App app;
    final client = _HeldGatewayClient(
      (e) => app.reachable ? succeeded(e) : unreachable(e),
    );
    final store = InMemoryEndpointStore();
    final connection = ConnectionController(
      client: client,
      store: store,
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    final registry = _HeldWorkflowsApi();
    final workflows = WorkflowsController(api: registry);
    addTearDown(workflows.dispose);
    final jobs = ScriptedJobsApi();
    final generation = GenerationController(
      api: jobs,
      pollInterval: pollInterval,
    );
    addTearDown(generation.dispose);
    final session = SessionController(
      connection: connection,
      workflows: workflows,
      generation: generation,
      attempts: attempts,
      backoff: backoff,
    );
    addTearDown(session.dispose);
    app = _App(
      client: client,
      store: store,
      connection: connection,
      registry: registry,
      workflows: workflows,
      jobs: jobs,
      generation: generation,
      session: session,
    );
    expect(await connection.connectTo(home), isTrue);
    await workflows.load(home);
    return app;
  }

  /// What the gateway answers about a job from now on.
  void gatewaySays(_App app, List<Object?> answers) {
    app.jobs.snapshots
      ..clear()
      ..addAll(answers);
  }

  /// A job the gateway is running, and the app following it.
  Future<void> generating(_App app) async {
    gatewaySays(app, <Object?>[snapshotOf(JobState.running)]);
    await app.generation.submit(
      workflowId: 'w',
      inputs: const <String, Object?>{},
    );
    await pumpEventQueue();
    expect(app.generation.state, LifecycleState.generating);
  }

  /// Contact lost over a job the app was following. From here, recovery would
  /// ask about the job — a 404, so a recovery that runs follows nothing and
  /// every snapshot request counted afterwards is one recovery made.
  Future<void> lostContactOverAJob(_App app) async {
    await generating(app);
    app.generation.connectionLost();
    expect(app.generation.state, LifecycleState.interrupted);
    gatewaySays(app, <Object?>[null]);
  }

  /// The bounded reconnect, started as a lost contact starts it
  /// (`GenerationController` declares the contact lost, and the session's
  /// callback calls [SessionController.reconnect]), with its handshake out.
  Future<(Completer<HandshakeOutcome>, Future<bool>)> reconnectHeldAtHandshake(
    _App app,
  ) async {
    final held = app.client.holdNext();
    final reconnecting = app.session.reconnect();
    await pumpEventQueue();
    expect(app.client.holdPending, isFalse, reason: 'the probe took the hold');
    expect(app.session.isReconnecting, isTrue);
    expect(app.connection.isBusy, isTrue);
    return (held, reconnecting);
  }

  /// Waits for [condition], failing with [what] if it never comes.
  Future<void> eventually(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail(what);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('the handshake on the wire when Choose another server is pressed', () {
    test('not pressed: the handshake that answers goes on to the registry and '
        'the job (the counters count)', () async {
      final app = await connectedApp();
      await lostContactOverAJob(app);
      final (held, reconnecting) = await reconnectHeldAtHandshake(app);
      final listed = app.registry.listCalls;
      final asked = app.jobs.snapshotCalls;

      held.complete(succeeded(home));
      expect(await reconnecting, isTrue);
      await pumpEventQueue();

      expect(app.registry.listCalls - listed, 1);
      expect(app.jobs.snapshotCalls - asked, 1);
      expect(app.connection.phase, ConnectionPhase.connected);
    });

    test('pressed: its success lands and records nothing — the app stays '
        'choosing a server', () async {
      final app = await connectedApp();
      await lostContactOverAJob(app);
      final (held, reconnecting) = await reconnectHeldAtHandshake(app);
      final remembered = app.connection.remembered;
      expect(remembered, isNotNull);
      final writes = app.store.writes;
      final listed = app.registry.listCalls;
      final asked = app.jobs.snapshotCalls;
      final handshakes = app.client.handshakes;

      await app.session.chooseAnotherServer();
      expect(app.connection.phase, ConnectionPhase.needsServer);

      held.complete(succeeded(home));
      final reconnected = await reconnecting;
      await pumpEventQueue();

      expect(app.connection.phase, ConnectionPhase.needsServer);
      expect(app.connection.identity, isNull);
      expect(identical(app.connection.endpoint, home), isTrue);
      expect(identical(app.connection.remembered, remembered), isTrue);
      expect(app.store.writes, writes);
      expect(app.connection.isBusy, isFalse);
      expect(app.registry.listCalls, listed);
      expect(app.jobs.snapshotCalls, asked);
      expect(app.client.handshakes, handshakes);
      expect(app.session.failure, isNull);
      expect(app.session.isReconnecting, isFalse);
      expect(app.generation.isReconnecting, isFalse);
      expect(app.generation.state, LifecycleState.disconnected);
      // The run reports where the app is: not at a gateway.
      expect(reconnected, isFalse);
    });

    test('pressed, and the handshake fails: no recovery panel for the server '
        'the person left', () async {
      final app = await connectedApp(attempts: 1);
      await lostContactOverAJob(app);
      final (held, reconnecting) = await reconnectHeldAtHandshake(app);

      await app.session.chooseAnotherServer();
      held.complete(unreachable(home));
      await reconnecting;
      await pumpEventQueue();

      expect(app.session.failure, isNull);
      expect(app.connection.phase, ConnectionPhase.needsServer);
      expect(app.connection.notice, isNull);
    });

    test('pressed, and the handshake fails with attempts left: no further '
        'attempt is made', () async {
      final app = await connectedApp(attempts: 3);
      await lostContactOverAJob(app);
      final (held, reconnecting) = await reconnectHeldAtHandshake(app);
      final handshakes = app.client.handshakes;

      await app.session.chooseAnotherServer();
      held.complete(unreachable(home));
      await reconnecting;
      await pumpEventQueue();

      expect(app.client.handshakes, handshakes);
      expect(app.connection.phase, ConnectionPhase.needsServer);
      expect(app.session.failure, isNull);
    });
  });

  group('the backoff between attempts when Choose another server is pressed',
      () {
    const gap = Duration(milliseconds: 150);

    test('not pressed: the attempts after the gap are made (the counter '
        'counts)', () async {
      final app = await connectedApp(attempts: 3, backoff: gap);
      await lostContactOverAJob(app);
      app.reachable = false;
      final before = app.client.handshakes;

      expect(await app.session.reconnect(), isFalse);

      expect(app.client.handshakes - before, 3);
      expect(app.session.failure, isNotNull);
    });

    test('pressed: no further attempt, even to a gateway that is back', () async {
      final app = await connectedApp(attempts: 3, backoff: gap);
      await lostContactOverAJob(app);
      app.reachable = false;
      final before = app.client.handshakes;
      final asked = app.jobs.snapshotCalls;
      final reconnecting = app.session.reconnect();
      await pumpEventQueue();
      expect(app.client.handshakes - before, 1);
      expect(app.session.isReconnecting, isTrue);
      expect(app.connection.isBusy, isFalse, reason: 'in the gap');

      // The gateway comes back while the person is choosing: an attempt made
      // now would answer, and take them back to the server they left.
      app.reachable = true;
      await app.session.chooseAnotherServer();

      await Future<void>.delayed(gap * 4);
      await reconnecting;

      expect(app.client.handshakes - before, 1);
      expect(app.session.isReconnecting, isFalse);
      expect(app.connection.phase, ConnectionPhase.needsServer);
      expect(app.jobs.snapshotCalls, asked);
      expect(app.session.failure, isNull);
      expect(app.generation.isReconnecting, isFalse);
    });
  });

  group('the steps after a handshake that answered', () {
    test('not pressed: the registry reload is followed by the job recovery '
        '(the counter counts)', () async {
      final app = await connectedApp();
      await lostContactOverAJob(app);
      final reload = Completer<void>();
      app.registry.listGate = reload;
      final asked = app.jobs.snapshotCalls;
      final reconnecting = app.session.reconnect();
      await pumpEventQueue();
      expect(app.registry.listGate, isNull, reason: 'the reload took the gate');

      reload.complete();
      expect(await reconnecting, isTrue);

      expect(app.jobs.snapshotCalls - asked, 1);
    });

    test('pressed while the registry reload is out: no job recovery is asked',
        () async {
      final app = await connectedApp();
      await lostContactOverAJob(app);
      final reload = Completer<void>();
      app.registry.listGate = reload;
      final asked = app.jobs.snapshotCalls;
      final reconnecting = app.session.reconnect();
      await pumpEventQueue();
      expect(app.registry.listGate, isNull, reason: 'the reload took the gate');

      await app.session.chooseAnotherServer();
      reload.complete();
      await reconnecting;
      await pumpEventQueue();

      expect(app.jobs.snapshotCalls, asked);
      expect(app.connection.phase, ConnectionPhase.needsServer);
      expect(app.session.failure, isNull);
      expect(app.generation.isReconnecting, isFalse);
    });

    test('pressed while the job recovery is out: its end does not end the '
        'reconnect running on the next server', () async {
      final app = await connectedApp(
        pollInterval: const Duration(milliseconds: 5),
      );
      await generating(app);
      app.generation.connectionLost();
      final recovery = Completer<void>();
      app.jobs.snapshotGate = recovery;
      gatewaySays(app, <Object?>[snapshotOf(JobState.running)]);
      final leftBehind = app.session.reconnect();
      await pumpEventQueue();
      expect(app.jobs.snapshotGate, isNull, reason: 'recovery took the gate');

      await app.session.chooseAnotherServer();
      expect(await app.connection.connectTo(elsewhere), isTrue);
      await app.workflows.load(elsewhere);

      // A job on the new server, and contact with it lost by the poll itself:
      // the road that starts a reconnect in the app.
      await generating(app);
      final probe = app.client.holdNext();
      app.jobs.snapshotFailure = const JobFailure.unreachable();
      // Waited for by its handshake, not by `isReconnecting`: the reconnect
      // left behind would satisfy that by itself.
      await eventually(
        () => !app.client.holdPending,
        'losing the new server started no reconnect',
      );
      expect(app.session.isReconnecting, isTrue);
      expect(app.client.attempted.last, elsewhere);
      expect(app.generation.isReconnecting, isTrue);

      // The recovery that belonged to the server the person left answers now.
      recovery.complete();
      await leftBehind;
      await pumpEventQueue();

      expect(app.session.isReconnecting, isTrue);
      expect(app.generation.isReconnecting, isTrue);
      expect(app.connection.isBusy, isTrue);
      expect(app.connection.endpoint, elsewhere);

      // And the new one ends as its own: not superseded, so it shows its panel.
      probe.complete(unreachable(elsewhere));
      await eventually(
        () => !app.session.isReconnecting,
        'the new reconnect never ended',
      );
      expect(app.session.failure, isNotNull);
      expect(app.connection.endpoint, elsewhere);
    });
  });

  group('connecting to another server straight after the choice', () {
    test('succeeds, and the old handshake answering afterwards does not take '
        'the app back', () async {
      final app = await connectedApp();
      await lostContactOverAJob(app);
      final (held, reconnecting) = await reconnectHeldAtHandshake(app);

      await app.session.chooseAnotherServer();
      expect(app.connection.isBusy, isFalse);
      // The new server answers first; the old request, sent to a gateway that
      // had gone quiet, answers near its timeout.
      expect(await app.connection.connectTo(elsewhere), isTrue);
      expect(app.connection.identity?.displayName, 'Attic PC');
      final writes = app.store.writes;

      held.complete(succeeded(home));
      await reconnecting;
      await pumpEventQueue();

      expect(app.connection.phase, ConnectionPhase.connected);
      expect(app.connection.endpoint, elsewhere);
      expect(app.connection.identity?.displayName, 'Attic PC');
      expect(app.connection.remembered?.endpoint, elsewhere);
      expect(app.store.writes, writes);
      expect(app.connection.isBusy, isFalse);
      expect(app.generation.endpoint, elsewhere);
    });

    test('the old handshake ending does not release the new one\'s busy state',
        () async {
      final app = await connectedApp();
      await lostContactOverAJob(app);
      final (held, reconnecting) = await reconnectHeldAtHandshake(app);

      await app.session.chooseAnotherServer();
      final next = app.client.holdNext();
      final connecting = app.connection.connectTo(elsewhere);
      await pumpEventQueue();
      expect(app.client.holdPending, isFalse, reason: 'the connect was made');
      expect(app.connection.isBusy, isTrue);

      // The old reply lands while the new request is still out.
      held.complete(succeeded(home));
      await reconnecting;
      await pumpEventQueue();

      expect(app.connection.isBusy, isTrue);
      expect(app.connection.phase, ConnectionPhase.connecting);
      expect(app.connection.endpoint, elsewhere);

      next.complete(succeeded(elsewhere));
      expect(await connecting, isTrue);
      expect(app.connection.isBusy, isFalse);
      expect(app.connection.phase, ConnectionPhase.connected);
      expect(app.connection.endpoint, elsewhere);
    });
  });

  group('the connection on its own: every handshake the choice overtakes', () {
    final rememberedHome = RememberedServer(
      endpoint: home,
      displayName: 'Studio PC',
      lastSuccess: DateTime.utc(2026, 9, 1),
    );

    (ConnectionController, _HeldGatewayClient, InMemoryEndpointStore)
    lonelyConnection({
      RememberedServer? remembered,
      Duration retryDelay = Duration.zero,
      bool reachable = true,
    }) {
      final client = _HeldGatewayClient(
        (e) => reachable ? succeeded(e) : unreachable(e),
      );
      final store = InMemoryEndpointStore(remembered);
      final connection = ConnectionController(
        client: client,
        store: store,
        discovery: silentDiscovery(),
        retryDelay: retryDelay,
      );
      addTearDown(connection.dispose);
      return (connection, client, store);
    }

    void recordedNothing(
      ConnectionController connection,
      InMemoryEndpointStore store,
      RememberedServer? remembered,
    ) {
      expect(connection.phase, ConnectionPhase.needsServer);
      expect(connection.identity, isNull);
      expect(connection.notice, isNull);
      expect(identical(connection.remembered, remembered), isTrue);
      expect(store.writes, 0);
      expect(connection.isBusy, isFalse);
    }

    test('a connect answering after the choice', () async {
      final (connection, client, store) = lonelyConnection();
      final held = client.holdNext();
      final connecting = connection.connectTo(home);
      await pumpEventQueue();
      expect(connection.isBusy, isTrue);

      await connection.chooseAnotherServer();
      held.complete(succeeded(home));
      final connected = await connecting;
      await pumpEventQueue();

      recordedNothing(connection, store, null);
      expect(connected, isFalse);
    });

    test('the launch attempt answering after the choice', () async {
      final (connection, client, store) = lonelyConnection(
        remembered: rememberedHome,
      );
      final held = client.holdNext();
      final starting = connection.start();
      await pumpEventQueue();
      expect(connection.isBusy, isTrue);

      await connection.chooseAnotherServer();
      held.complete(succeeded(home));
      await starting;
      await pumpEventQueue();

      recordedNothing(connection, store, rememberedHome);
      expect(client.handshakes, 1);
    });

    test('the launch retry after the choice is not made', () async {
      const gap = Duration(milliseconds: 150);
      final (connection, client, store) = lonelyConnection(
        remembered: rememberedHome,
        retryDelay: gap,
        reachable: false,
      );
      final starting = connection.start();
      await pumpEventQueue();
      expect(client.handshakes, 1);

      await connection.chooseAnotherServer();
      await Future<void>.delayed(gap * 4);
      await starting;

      expect(client.handshakes, 1);
      recordedNothing(connection, store, rememberedHome);
    });

    test('Check again answering after the choice, success or failure',
        () async {
      for (final answer in <HandshakeOutcome Function(Endpoint)>[
        succeeded,
        unreachable,
      ]) {
        final (connection, client, store) = lonelyConnection();
        expect(await connection.connectTo(home), isTrue);
        final writes = store.writes;
        final remembered = connection.remembered;
        final held = client.holdNext();
        final checking = connection.refreshIdentity();
        await pumpEventQueue();
        expect(connection.isBusy, isTrue);

        await connection.chooseAnotherServer();
        held.complete(answer(home));
        await checking;
        await pumpEventQueue();

        expect(connection.phase, ConnectionPhase.needsServer);
        expect(connection.identity, isNull);
        expect(connection.notice, isNull);
        expect(identical(connection.remembered, remembered), isTrue);
        expect(store.writes, writes);
        expect(connection.isBusy, isFalse);
      }
    });

    // A late FAILURE, not only a late success (T-0247): an overtaken
    // handshake's failure is as much about the server the person left as its
    // success is.

    test('a connect failing after the choice, while a newer connect is still '
        'out: the newer one stays connecting, with no notice about the old '
        'server', () async {
      // Not overtaken, the very same failure is recorded — so the absence
      // asserted below is one that could have been seen.
      final (control, controlClient, _) = lonelyConnection();
      final controlHeld = controlClient.holdNext();
      final controlConnecting = control.connectTo(home);
      await pumpEventQueue();
      expect(control.isBusy, isTrue);
      controlHeld.complete(unreachable(home));
      expect(await controlConnecting, isFalse);
      expect(control.phase, ConnectionPhase.needsServer);
      expect(control.notice?.problem, ConnectionProblem.unreachable);
      expect(control.notice?.address, home.display);
      expect(control.isBusy, isFalse);

      final (connection, client, store) = lonelyConnection();
      final old = client.holdNext();
      final leftBehind = connection.connectTo(home);
      await pumpEventQueue();
      expect(connection.isBusy, isTrue);

      await connection.chooseAnotherServer();
      final next = client.holdNext();
      final connecting = connection.connectTo(elsewhere);
      await pumpEventQueue();
      expect(client.holdPending, isFalse, reason: 'the new connect was made');
      expect(connection.phase, ConnectionPhase.connecting);
      expect(connection.isBusy, isTrue);
      var notifications = 0;
      connection.addListener(() => notifications++);

      // Release order: the old request left first, to a gateway that had gone
      // quiet, and its failure lands near its timeout — while the new request,
      // sent after the choice, is still out.
      old.complete(unreachable(home));
      expect(await leftBehind, isFalse);
      await pumpEventQueue();

      expect(connection.phase, ConnectionPhase.connecting);
      expect(connection.notice, isNull);
      expect(connection.endpoint, elsewhere);
      expect(connection.isBusy, isTrue);
      expect(connection.identity, isNull);
      expect(store.writes, 0);
      expect(notifications, 0);

      // And the new connect still ends as its own.
      next.complete(succeeded(elsewhere));
      expect(await connecting, isTrue);
      expect(connection.phase, ConnectionPhase.connected);
      expect(connection.endpoint, elsewhere);
      expect(connection.notice, isNull);
      expect(connection.isBusy, isFalse);
    });

    test('the launch attempt failing after the choice: no notice about the old '
        'server on the connect screen', () async {
      // Not overtaken, the same settled failure is recorded on the connect
      // screen, after exactly one attempt.
      final (control, controlClient, _) = lonelyConnection(
        remembered: rememberedHome,
      );
      final controlHeld = controlClient.holdNext();
      final controlStarting = control.start();
      await pumpEventQueue();
      expect(control.isBusy, isTrue);
      controlHeld.complete(notLocalCanvas(home));
      await controlStarting;
      await pumpEventQueue();
      expect(control.phase, ConnectionPhase.needsServer);
      expect(control.notice?.problem, ConnectionProblem.notLocalCanvas);
      expect(control.notice?.address, home.display);
      expect(control.isBusy, isFalse);
      expect(controlClient.handshakes, 1);

      final (connection, client, store) = lonelyConnection(
        remembered: rememberedHome,
      );
      final held = client.holdNext();
      final starting = connection.start();
      await pumpEventQueue();
      expect(connection.isBusy, isTrue);

      // Release order: the launch request left before the choice; its answer
      // lands after it.
      await connection.chooseAnotherServer();
      held.complete(notLocalCanvas(home));
      await starting;
      await pumpEventQueue();

      recordedNothing(connection, store, rememberedHome);
      expect(identical(connection.endpoint, home), isTrue);
      expect(client.handshakes, 1);
    });
  });

  group('what the ended reconnect leaves the generation in', () {
    /// Everything about the generation a screen can read.
    Object describe(GenerationController g) => (
      state: g.state,
      recovery: g.recovery,
      reconnecting: g.isReconnecting,
      checking: g.isCheckingSurvival,
      jobId: g.jobId,
      problem: g.problemMessage(en),
      endpoint: g.endpoint,
      hasResult: g.hasResult,
    );

    test('a job interrupted: exactly what Choose another server leaves when '
        'no reconnect runs', () async {
      final plain = await connectedApp();
      await lostContactOverAJob(plain);
      await plain.session.chooseAnotherServer();

      final ended = await connectedApp();
      await lostContactOverAJob(ended);
      await reconnectHeldAtHandshake(ended);
      await ended.session.chooseAnotherServer();

      expect(describe(ended.generation), describe(plain.generation));
      expect(plain.generation.state, LifecycleState.disconnected);
      expect(plain.generation.isReconnecting, isFalse);

      // And both come back the same way: the job is asked about once.
      final plainAsked = plain.jobs.snapshotCalls;
      final endedAsked = ended.jobs.snapshotCalls;
      for (final app in <_App>[plain, ended]) {
        expect(
          await app.connection.connectTo(
            Endpoint.tryParse('192.0.2.42:7801')!,
          ),
          isTrue,
        );
      }
      await pumpEventQueue();
      expect(plain.jobs.snapshotCalls - plainAsked, 1);
      expect(ended.jobs.snapshotCalls - endedAsked, 1);
      expect(describe(ended.generation), describe(plain.generation));
    });

    test('nothing in flight: exactly what Choose another server leaves when no '
        'reconnect runs', () async {
      final plain = await connectedApp();
      expect(plain.generation.state, LifecycleState.ready);
      await plain.session.chooseAnotherServer();

      final ended = await connectedApp();
      await reconnectHeldAtHandshake(ended);
      await ended.session.chooseAnotherServer();

      expect(describe(ended.generation), describe(plain.generation));
      expect(plain.generation.state, LifecycleState.disconnected);
    });
  });

  group('Check again still on the wire when a reconnect probe overtakes it', () {
    // Pinned as the behaviour is now (T-0247). T-0243 is the change that made
    // it so: every probe takes an operation of its own, which overtakes a Check
    // again already out. Before T-0243 the probe succeeding and Check again's
    // failure landing afterwards threw the app back to the connect screen,
    // straight after the reconnect had succeeded; now the app stays connected.
    test('the probe succeeds, then Check again\'s failure lands: the app stays '
        'connected', () async {
      // Not overtaken, the very same failure throws the app out to the connect
      // screen with its notice — so what is asserted absent below could have
      // been seen.
      final plain = await connectedApp();
      final plainHeld = plain.client.holdNext();
      final plainChecking = plain.connection.refreshIdentity();
      await pumpEventQueue();
      expect(plain.connection.isBusy, isTrue);
      plainHeld.complete(unreachable(home));
      await plainChecking;
      await pumpEventQueue();
      expect(plain.connection.phase, ConnectionPhase.needsServer);
      expect(plain.connection.notice?.problem, ConnectionProblem.unreachable);

      const gap = Duration(milliseconds: 150);
      final app = await connectedApp(attempts: 3, backoff: gap);
      await lostContactOverAJob(app);
      app.reachable = false;
      final before = app.client.handshakes;
      final reconnecting = app.session.reconnect();
      await pumpEventQueue();
      expect(app.client.handshakes - before, 1);
      expect(app.session.isReconnecting, isTrue);
      expect(
        app.connection.isBusy,
        isFalse,
        reason: 'in the gap, where the header\'s Check again is enabled',
      );

      // Check again, pressed in the gap: its request goes out to a gateway
      // that is still down, and hangs there.
      final check = app.client.holdNext();
      final checking = app.connection.refreshIdentity();
      await pumpEventQueue();
      expect(app.client.holdPending, isFalse, reason: 'Check again was sent');
      expect(app.connection.isBusy, isTrue);

      // Release order: the gateway comes back, the reconnect's next attempt
      // leaves after the gap and is answered at once; Check again's request,
      // sent earlier, fails later, near its timeout.
      app.reachable = true;
      expect(await reconnecting, isTrue);
      expect(
        app.client.handshakes - before,
        3,
        reason: 'probe, Check again, probe',
      );
      expect(app.connection.phase, ConnectionPhase.connected);

      check.complete(unreachable(home));
      await checking;
      await pumpEventQueue();

      expect(app.connection.phase, ConnectionPhase.connected);
      expect(app.connection.notice, isNull);
      expect(app.connection.endpoint, home);
      expect(app.connection.identity?.displayName, 'Studio PC');
      expect(app.connection.isBusy, isFalse);
      expect(app.session.failure, isNull);
      expect(app.session.isReconnecting, isFalse);
    });
  });
}
