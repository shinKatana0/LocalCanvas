/// Coming back to the server that owns a job recovers the job (T-0238).
///
/// `docs/recovery.md`: on reconnect with a job in flight, the client asks
/// `GET /api/v1/jobs/{job_id}` and believes only the answer. The bounded
/// reconnect always did. A person who pressed **Choose another server**, looked
/// at the list and connected to the *same* server again reached that gateway by
/// another road — and nothing on that road asked about the job the gateway was
/// still running.
///
/// Every test here goes through the session and a real [ConnectionController],
/// because the road is the point: a test that called `recoverJob()` itself
/// would prove the recovery, which was never broken, and say nothing about
/// whether anything takes it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';

/// One app: a connection, a session over it, and a scripted gateway whose
/// handshake answers are the test's to change.
class _App {
  _App({
    required this.connection,
    required this.session,
    required this.generation,
    required this.jobs,
  });

  final ConnectionController connection;
  final SessionController session;
  final GenerationController generation;
  final ScriptedJobsApi jobs;

  /// What the gateway calls itself. Both servers answer with the same name
  /// unless a test changes it, so nothing here can tell them apart by name.
  String gatewayName = 'Studio PC';

  /// Whether the handshake is answered at all.
  bool reachable = true;
}

void main() {
  final home = Endpoint.tryParse('192.0.2.42:7801')!;
  final elsewhere = Endpoint.tryParse('192.0.2.77:7801')!;

  /// The poll never ticks inside a test: the only snapshot requests are the
  /// ones made at once — recovery's, and the first poll of a job it resumes
  /// following. So every request counted below is one somebody decided to make.
  const never = Duration(hours: 1);

  Future<_App> connectedApp() async {
    late final _App app;
    final client = ScriptedGatewayClient(
      (e) => app.reachable
          ? HandshakeSucceeded(e, testIdentity(displayName: app.gatewayName))
          : HandshakeFailed(
              describeProblem(
                ConnectionProblem.unreachable,
                address: e.display,
              ),
            ),
    );
    final connection = ConnectionController(
      client: client,
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    final workflows = WorkflowsController(api: ScriptedWorkflowsApi());
    addTearDown(workflows.dispose);
    final jobs = ScriptedJobsApi();
    final generation = GenerationController(api: jobs, pollInterval: never);
    addTearDown(generation.dispose);
    final session = testSession(
      connection: connection,
      workflows: workflows,
      generation: generation,
      attempts: 1,
    );
    addTearDown(session.dispose);
    app = _App(
      connection: connection,
      session: session,
      generation: generation,
      jobs: jobs,
    );
    // The session is there before the first connection, as it is in the app,
    // so arriving at a gateway for the first time takes the same road as
    // coming back to one.
    expect(await connection.connectTo(home), isTrue);
    expect(generation.state, LifecycleState.ready);
    return app;
  }

  /// A job the gateway is running, and the app following it.
  Future<_App> generatingApp() async {
    final app = await connectedApp();
    app.jobs.snapshots.add(snapshotOf(JobState.running));
    await app.generation.submit(
      workflowId: 'w',
      inputs: const <String, Object?>{},
    );
    await pumpEventQueue();
    expect(app.generation.state, LifecycleState.generating);
    expect(app.generation.jobId, 'j-8f21');
    return app;
  }

  /// Every state the controller passes through from now on.
  List<LifecycleState> watch(GenerationController controller) {
    final seen = <LifecycleState>[controller.state];
    controller.addListener(() {
      if (seen.last != controller.state) seen.add(controller.state);
    });
    return seen;
  }

  /// What the gateway answers about the job from now on.
  void gatewaySays(_App app, List<Object?> answers) {
    app.jobs.snapshots
      ..clear()
      ..addAll(answers);
  }

  /// The roads back after Choose another server, each exactly as the app takes
  /// it. None of them hands the connection the [Endpoint] the job was started
  /// on: the connect screen has no "Try again" there (no notice), so the way
  /// back is a typed address, a scanned code or a discovered server — and each
  /// of those builds a new one. A test that came back through the very object
  /// it left with would let "same server" quietly mean "same instance".
  Future<void> typeHomeAddress(_App app) async {
    expect(
      await app.connection.connectTo(Endpoint.tryParse('192.0.2.42:7801')!),
      isTrue,
    );
  }

  Future<void> scanHomeCode(_App app) async {
    expect(
      await app.connection.connectToPairingPayload(
        'localcanvas://connect?endpoint=http://192.0.2.42:7801',
      ),
      PairingOutcome.connected,
    );
  }

  Future<void> pickDiscoveredHome(_App app) async {
    expect(
      await app.connection.connectTo(
        Endpoint.fromHostPort('192.0.2.42', 7801)!,
      ),
      isTrue,
    );
  }

  /// Holds the fixture to what the roads above promise: the endpoint the
  /// connection arrived at is the server [left] names, and not [left] itself.
  void cameBackThroughANewEndpoint(_App app, Endpoint left) {
    final arrived = app.connection.endpoint;
    expect(arrived, left);
    expect(identical(arrived, left), isFalse);
  }

  final completedWithResult = snapshotOf(
    JobState.completed,
    results: const <JobResultRef>[imageResult],
  );

  group('Choose another server, then the same server again', () {
    test('a job still generating is followed again, to its result', () async {
      final app = await generatingApp();
      final seen = watch(app.generation);

      await app.session.chooseAnotherServer();
      expect(app.connection.phase, ConnectionPhase.needsServer);
      expect(app.generation.state, LifecycleState.interrupted);

      gatewaySays(app, <Object?>[
        snapshotOf(JobState.running),
        completedWithResult,
      ]);
      final asked = app.jobs.snapshotCalls;
      // Renamed while the person was away: the server is the address, not
      // what it calls itself.
      app.gatewayName = 'Studio PC (upstairs)';

      final left = app.generation.endpoint!;
      await scanHomeCode(app);
      cameBackThroughANewEndpoint(app, left);
      await pumpEventQueue();

      expect(seen, <LifecycleState>[
        LifecycleState.generating,
        LifecycleState.interrupted,
        LifecycleState.generating,
        LifecycleState.completed,
      ]);
      // Recovery's snapshot, then the first poll of the job it resumed.
      expect(app.jobs.snapshotCalls - asked, 2);
      expect(app.generation.jobId, 'j-8f21');
      expect(app.generation.primaryResult?.path, imageResult.path);
      expect(app.generation.recovery, JobRecovery.none);
    });

    test('from the recovery panel, after the automatic reconnect ran out '
        '(the path the review measured)', () async {
      final app = await generatingApp();
      app.reachable = false;
      gatewaySays(app, <Object?>[const JobFailure.unreachable()]);
      app.generation.connectionLost();
      expect(await app.session.reconnect(), isFalse);
      expect(app.session.failure, isNotNull);
      expect(app.generation.state, LifecycleState.interrupted);
      final seen = watch(app.generation);

      await app.session.chooseAnotherServer();
      app.reachable = true;
      gatewaySays(app, <Object?>[
        snapshotOf(JobState.running),
        completedWithResult,
      ]);
      final asked = app.jobs.snapshotCalls;

      final left = app.generation.endpoint!;
      await typeHomeAddress(app);
      cameBackThroughANewEndpoint(app, left);
      await pumpEventQueue();

      // Leaving over an interrupted job makes it disconnected (T-0234), so the
      // road back arrives at ready — which is exactly where it used to stop,
      // with the job id still held and nobody asking about it.
      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.disconnected,
        LifecycleState.connecting,
        LifecycleState.ready,
        LifecycleState.generating,
        LifecycleState.completed,
      ]);
      expect(app.jobs.snapshotCalls - asked, 2);
      expect(app.generation.primaryResult?.path, imageResult.path);
    });

    test('a recovery still on the wire when the person left is not what '
        'answers: the return asks again', () async {
      final app = await generatingApp();
      app.reachable = false;
      gatewaySays(app, <Object?>[const JobFailure.unreachable()]);
      app.generation.connectionLost();
      expect(await app.session.reconnect(), isFalse);

      // Reconnect is pressed and its recovery is held on the wire.
      app.reachable = true;
      final held = Completer<void>();
      app.jobs.snapshotGate = held;
      gatewaySays(app, <Object?>[snapshotOf(JobState.running)]);
      final asked = app.jobs.snapshotCalls;
      final reconnecting = app.session.reconnect();
      await pumpEventQueue();
      expect(app.jobs.snapshotGate, isNull, reason: 'recovery took the gate');

      await app.session.chooseAnotherServer();
      final left = app.generation.endpoint!;
      await pickDiscoveredHome(app);
      cameBackThroughANewEndpoint(app, left);
      await pumpEventQueue();

      // Asked on the return, and believed: the held one belongs to a contact
      // that is over.
      expect(app.generation.state, LifecycleState.generating);
      final seen = watch(app.generation);

      held.complete();
      expect(await reconnecting, isTrue);
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.generating]);
      // The held recovery, the return's recovery, and the first poll after it.
      expect(app.jobs.snapshotCalls - asked, 3);
    });

    test('a job the gateway no longer has ends in "could not be recovered"',
        () async {
      final app = await generatingApp();
      await app.session.chooseAnotherServer();
      gatewaySays(app, <Object?>[null]);
      final asked = app.jobs.snapshotCalls;

      final left = app.generation.endpoint!;
      await typeHomeAddress(app);
      cameBackThroughANewEndpoint(app, left);
      await pumpEventQueue();

      expect(app.jobs.snapshotCalls - asked, 1);
      expect(app.generation.state, LifecycleState.interrupted);
      expect(app.generation.recovery, JobRecovery.lost);
      expect(app.generation.isCheckingSurvival, isFalse);
      expect(
        app.generation.problemMessage(en),
        stateUnrecoverableMessage(en),
      );
    });
  });

  group('what the return leaves alone', () {
    test('another server clears the job and never asks about it', () async {
      final app = await generatingApp();
      await app.session.chooseAnotherServer();
      // Anything this gateway were asked, it would answer as though it had
      // the job — so a request made here would show as a job, not a 404.
      gatewaySays(app, <Object?>[snapshotOf(JobState.running)]);
      final asked = app.jobs.snapshotCalls;
      final seen = watch(app.generation);

      // Same name, different address: a different server.
      expect(await app.connection.connectTo(elsewhere), isTrue);
      await pumpEventQueue();

      expect(app.jobs.snapshotCalls, asked);
      expect(app.generation.jobId, isNull);
      expect(app.generation.results, isEmpty);
      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.ready,
      ]);

      // And the job is gone for good: going home again has nothing to ask.
      await app.session.chooseAnotherServer();
      await scanHomeCode(app);
      cameBackThroughANewEndpoint(app, home);
      await pumpEventQueue();
      expect(app.jobs.snapshotCalls, asked);
      expect(app.generation.state, LifecycleState.ready);
    });

    test('a finished result on screen: no request, and nothing changes',
        () async {
      final app = await connectedApp();
      app.jobs.snapshots.add(completedWithResult);
      await app.generation.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await pumpEventQueue();
      expect(app.generation.state, LifecycleState.completed);
      final bytes = app.generation.resultBytes;
      expect(bytes, isNotNull);

      await app.session.chooseAnotherServer();
      final asked = app.jobs.snapshotCalls;
      final fetched = app.jobs.resultFetches;
      var notified = 0;
      app.generation.addListener(() => notified++);

      final left = app.generation.endpoint!;
      await pickDiscoveredHome(app);
      cameBackThroughANewEndpoint(app, left);
      await pumpEventQueue();

      expect(app.jobs.snapshotCalls, asked);
      expect(app.jobs.resultFetches, fetched);
      expect(app.generation.state, LifecycleState.completed);
      expect(app.generation.recovery, JobRecovery.none);
      expect(identical(app.generation.resultBytes, bytes), isTrue);
      expect(app.generation.primaryResult?.path, imageResult.path);
      // Attaching announces itself once; a recovery would have announced
      // `checking` on top of it.
      expect(notified, 1);
    });

    test('staying connected is not arriving: a bounded reconnect asks once',
        () async {
      final app = await generatingApp();
      app.generation.connectionLost();
      // A 404, deliberately. A job that finishes is an outcome, and recovery
      // never asks twice about an outcome — so a completed answer would hide an
      // extra recovery fired by the probe. A lost job is asked about every time.
      gatewaySays(app, <Object?>[null]);
      final asked = app.jobs.snapshotCalls;

      // The probe notifies while the connection stays connected. Only step 6
      // of the reconnect asks about the job.
      expect(await app.session.reconnect(), isTrue);
      await pumpEventQueue();

      expect(app.jobs.snapshotCalls - asked, 1);
      expect(app.generation.recovery, JobRecovery.lost);
    });
  });
}
