/// The bounded reconnect and what it restores (`docs/recovery.md`).
///
/// The contract names six steps in an order, so the test asserts the order —
/// not that "a reconnect happened". It also asserts the two things a reconnect
/// must never do: retry forever, and take the screen away while it tries.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42:7801')!;

  /// A connected app, with the handshake answered by [answer] from then on.
  Future<(SessionController, ScriptedGatewayClient, ScriptedJobsApi)> session({
    required HandshakeOutcome Function(Endpoint endpoint) answer,
    ScriptedWorkflowsApi? registry,
    GenerationController? generation,
    int attempts = 3,
  }) async {
    var connecting = true;
    final client = ScriptedGatewayClient(
      (e) => connecting
          ? HandshakeSucceeded(e, testIdentity())
          : answer(e),
    );
    final connection = ConnectionController(
      client: client,
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    await connection.connectTo(endpoint);
    connecting = false;

    final workflows = WorkflowsController(
      api: registry ?? ScriptedWorkflowsApi(),
    );
    addTearDown(workflows.dispose);
    await workflows.load(endpoint);

    final api = ScriptedJobsApi();
    final controller = testSession(
      connection: connection,
      workflows: workflows,
      generation:
          generation ??
          GenerationController(
            api: api,
            pollInterval: const Duration(milliseconds: 5),
          ),
      attempts: attempts,
    );
    addTearDown(controller.dispose);
    return (controller, client, api);
  }

  HandshakeOutcome unreachable(Endpoint endpoint) => HandshakeFailed(
    describeProblem(ConnectionProblem.unreachable, address: endpoint.display),
  );

  group('a successful reconnect', () {
    test('performs the six steps, in the order the contract sets', () async {
      final (controller, client, _) = await session(
        answer: (e) => HandshakeSucceeded(e, testIdentity()),
        registry: ScriptedWorkflowsApi(),
      );
      final before = client.handshakes;

      expect(await controller.reconnect(), isTrue);

      expect(controller.lastSteps, <ReconnectStep>[
        ReconnectStep.retryEndpoint,
        ReconnectStep.verifyIdentity,
        ReconnectStep.verifyApiVersion,
        ReconnectStep.verifyComfyReadiness,
        ReconnectStep.refreshRegistry,
        ReconnectStep.restoreState,
      ]);
      expect(client.handshakes, before + 1);
      expect(controller.failure, isNull);
      expect(controller.isReconnecting, isFalse);
    });

    test('refreshes the registry as part of it', () async {
      final registry = ScriptedWorkflowsApi();
      final (controller, _, _) = await session(
        answer: (e) => HandshakeSucceeded(e, testIdentity()),
        registry: registry,
      );
      final before = registry.listCalls;

      await controller.reconnect();

      expect(registry.listCalls, before + 1);
    });

    test('ComfyUI being down is a message, not a failed reconnect', () async {
      final (controller, _, _) = await session(
        answer: (e) => HandshakeSucceeded(
          e,
          testIdentity(comfyStatus: ComfyStatus.unavailable),
        ),
      );

      expect(await controller.reconnect(), isTrue);

      // Two different conditions with two different fixes, and the one the
      // user is shown is the ComfyUI one.
      expect(controller.failure, isNull);
      expect(
        controller.connection.notice?.problem,
        ConnectionProblem.comfyUnavailable,
      );
      expect(controller.lastSteps, contains(ReconnectStep.verifyComfyReadiness));
    });

    test('recovers the job as the last step, from the snapshot', () async {
      final jobs = ScriptedJobsApi();
      jobs.snapshots.add(snapshotOf(JobState.running));
      final generation = GenerationController(
        api: jobs,
        pollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(generation.dispose);
      final (controller, _, _) = await session(
        answer: (e) => HandshakeSucceeded(e, testIdentity()),
        generation: generation,
      );

      await generation.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      generation.connectionLost();
      expect(generation.state, LifecycleState.interrupted);

      jobs.snapshots
        ..clear()
        ..add(
          snapshotOf(
            JobState.completed,
            results: const <JobResultRef>[imageResult],
          ),
        );

      await controller.reconnect();

      expect(controller.lastSteps.last, ReconnectStep.restoreState);
      expect(generation.state, LifecycleState.completed);
    });
  });

  group('a reconnect that fails', () {
    test('is bounded — a handful of attempts, then a decision', () async {
      final (controller, client, _) = await session(
        answer: unreachable,
        attempts: 3,
      );
      final before = client.handshakes;

      expect(await controller.reconnect(), isFalse);

      expect(client.handshakes - before, 3);
      expect(controller.attemptsMade, 3);
      expect(controller.failure, isNotNull);
      expect(
        controller.failure!.problem,
        ConnectionProblem.unreachable,
      );
    });

    test('does not send the app back to the connect screen', () async {
      final (controller, _, _) = await session(answer: unreachable);

      await controller.reconnect();

      // The shell stays up, so a displayed result stays displayed. Leaving is
      // a decision the user takes, from the panel.
      expect(controller.connection.phase, ConnectionPhase.connected);
    });

    test('stops at identity when something else answered', () async {
      final (controller, client, _) = await session(
        answer: (e) => HandshakeFailed(
          describeProblem(
            ConnectionProblem.notLocalCanvas,
            address: e.display,
          ),
        ),
      );
      final before = client.handshakes;

      expect(await controller.reconnect(), isFalse);

      expect(controller.lastSteps, <ReconnectStep>[
        ReconnectStep.retryEndpoint,
        ReconnectStep.verifyIdentity,
      ]);
      // A settled fact about the other end is not retried.
      expect(client.handshakes - before, 1);
    });

    test('stops at the version when the other end speaks a different one',
        () async {
      final (controller, client, _) = await session(
        answer: (e) => HandshakeFailed(
          describeProblem(
            ConnectionProblem.incompatibleVersion,
            address: e.display,
            serverApiVersion: 2,
          ),
          serverApiVersion: 2,
        ),
      );
      final before = client.handshakes;

      await controller.reconnect();

      expect(controller.lastSteps, <ReconnectStep>[
        ReconnectStep.retryEndpoint,
        ReconnectStep.verifyIdentity,
        ReconnectStep.verifyApiVersion,
      ]);
      expect(client.handshakes - before, 1);
      expect(controller.lastSteps, isNot(contains(ReconnectStep.refreshRegistry)));
    });

    test('the recovery panel goes away when Choose another server is taken',
        () async {
      final (controller, _, _) = await session(answer: unreachable);
      await controller.reconnect();
      expect(controller.failure, isNotNull);

      await controller.chooseAnotherServer();

      expect(controller.failure, isNull);
      expect(controller.connection.phase, ConnectionPhase.needsServer);
    });
  });

  group('losing the gateway mid-job', () {
    test('starts one bounded reconnect by itself', () async {
      final jobs = ScriptedJobsApi();
      jobs.snapshots.add(snapshotOf(JobState.running));
      final generation = GenerationController(
        api: jobs,
        pollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(generation.dispose);
      final (controller, client, _) = await session(
        answer: unreachable,
        generation: generation,
        attempts: 2,
      );

      await generation.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      final before = client.handshakes;
      jobs.snapshotFailure = const JobFailure.unreachable();

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.failure == null) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the lost gateway never produced a recovery decision');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // Bounded on both sides: the snapshot gave up, and the reconnect it
      // started gave up too, leaving a decision rather than a spinner.
      expect(client.handshakes - before, 2);
      expect(generation.state, LifecycleState.interrupted);
      expect(generation.state.isProgressing, isFalse);
    });

    test('Reconnect pressed over a new job cannot let an old poll say '
        'generating (T-0202)', () async {
      final jobs = ScriptedJobsApi();
      jobs.snapshots.add(snapshotOf(JobState.running));
      final generation = GenerationController(
        api: jobs,
        // Never ticks inside the test: only the requests made at once.
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(generation.dispose);
      var gone = true;
      final (controller, _, _) = await session(
        answer: (e) => gone
            ? unreachable(e)
            : HandshakeSucceeded(e, testIdentity()),
        generation: generation,
        attempts: 1,
      );

      // A job, contact lost, and the bounded reconnect runs out: the recovery
      // panel, with Reconnect on it.
      await generation.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      generation.connectionLost();
      expect(await controller.reconnect(), isFalse);
      expect(controller.failure, isNotNull);

      // The network comes back and the person starts another job. Generate is
      // offered under interrupted, and nothing takes the panel down, so
      // Reconnect is still there over a job whose first poll is on the wire.
      gone = false;
      final reply = Completer<void>();
      jobs.snapshotGate = reply;
      jobs.snapshots
        ..clear()
        ..addAll(<Object?>[
          snapshotOf(JobState.running),
          const JobFailure.unreachable(),
        ]);
      generation.generateAgain();
      await generation.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(generation.state.isProgressing, isTrue);
      expect(jobs.snapshotGate, isNull, reason: 'the poll took the gate');
      expect(controller.failure, isNotNull, reason: 'the panel is still up');

      // Reconnect is pressed. The gateway answers; recovery's request fails.
      expect(await controller.reconnect(), isTrue);
      expect(jobs.snapshotCalls, 3);
      expect(generation.state, LifecycleState.interrupted);
      final seen = <LifecycleState>[generation.state];
      generation.addListener(() {
        if (seen.last != generation.state) seen.add(generation.state);
      });

      reply.complete();
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
    });
  });

  group('what survives', () {
    test('a workflow that vanished is reported, and the prompt is not lost',
        () async {
      final registry = ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      );
      final workflows = WorkflowsController(api: registry);
      addTearDown(workflows.dispose);
      await workflows.load(endpoint);
      await workflows.select('example_txt2img');
      workflows.form!.setEntry('prompt', 'a rainy alley at night');

      // The server comes back publishing something else entirely.
      registry.summaries = const <WorkflowSummary>[];
      await workflows.reload();

      expect(workflows.missingSelection, isNotNull);
      expect(workflows.selectedId, isNull);

      // No silent substitution, and nothing typed was thrown away: the same
      // workflow returning finds the same words in it.
      registry.summaries = WorkflowSummary.listFromJson(
        registryOf(<Map<String, Object?>>[txt2imgDetail()]),
      );
      await workflows.reload();
      await workflows.select('example_txt2img');

      expect(workflows.form!.text('prompt'), 'a rainy alley at night');
    });
  });
}
