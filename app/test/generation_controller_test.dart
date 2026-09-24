/// The lifecycle, and every way it is tempted to lie (`docs/recovery.md`).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_events.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/generation/result_export.dart';

import 'support/l10n.dart';
import 'support/generation_fakes.dart';

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42:7801')!;

  /// Every state this controller passed through, so a test can assert what it
  /// never showed as well as what it ended on.
  List<LifecycleState> watch(GenerationController controller) {
    final seen = <LifecycleState>[controller.state];
    controller.addListener(() {
      if (seen.isEmpty || seen.last != controller.state) {
        seen.add(controller.state);
      }
    });
    return seen;
  }

  GenerationController controllerWith({
    required ScriptedJobsApi api,
    JobEventSource? events,
    ResultExporter? exporter,
    bool cancel = false,
    bool eventsAdvertised = false,
    Duration pollInterval = const Duration(milliseconds: 5),
    int snapshotFailureBudget = GenerationController.kSnapshotFailureBudget,
  }) {
    final controller = GenerationController(
      api: api,
      events: events,
      exporter: exporter,
      pollInterval: pollInterval,
      snapshotFailureBudget: snapshotFailureBudget,
    );
    addTearDown(controller.dispose);
    controller.attach(
      endpoint: endpoint,
      capabilities: GatewayCapabilities(
        cancel: cancel,
        events: eventsAdvertised,
      ),
    );
    return controller;
  }

  Future<void> waitFor(bool Function() condition, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  group('submitting', () {
    test('records the job id as soon as the response arrives', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.queued));
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'example_workflow',
        inputs: const <String, Object?>{'prompt': 'a rainy alley at night'},
      );

      // The one thing that makes recovery possible, present before anything
      // else can go wrong.
      expect(controller.jobId, 'j-8f21');
      expect(controller.workflowId, 'example_workflow');
      expect(api.submittedWorkflows, <String>['example_workflow']);
      expect(api.submittedInputs.single, <String, Object?>{
        'prompt': 'a rainy alley at night',
      });
    });

    test('a submit that never lands creates no job to recover', () async {
      final api = ScriptedJobsApi()
        ..submitFailure = const JobFailure.unreachable();
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );

      expect(controller.state, LifecycleState.failed);
      expect(controller.jobId, isNull);
      expect(controller.problemTitle(en), "The server didn't answer.");
    });
  });

  group('with sockets disabled entirely', () {
    test('the snapshot alone carries a job from queued to a result', () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<JobSnapshot?>[
        snapshotOf(JobState.queued),
        snapshotOf(
          JobState.running,
          progress: const JobProgress(step: 7, total: 24),
        ),
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      ]);
      // No event source at all — the socket half of this app removed.
      final controller = controllerWith(api: api, events: null);
      final seen = watch(controller);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.completed,
        'the snapshot to carry the job to completion',
      );
      await waitFor(
        () => controller.resultBytes != null,
        'the result bytes to arrive',
      );

      expect(seen, contains(LifecycleState.queued));
      expect(seen, contains(LifecycleState.generating));
      expect(controller.results.single.index, 0);
      expect(api.snapshotCalls, greaterThan(0));
      expect(controller.hasResult, isTrue);
    });

    test('a gateway that advertises events this build cannot open still works',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<JobSnapshot?>[
        snapshotOf(JobState.running),
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      ]);
      final events = FakeJobEventSource(failToConnect: true);
      final controller = controllerWith(
        api: api,
        events: events,
        eventsAdvertised: true,
      );

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.completed,
        'the snapshot to take over from the socket that would not open',
      );

      expect(events.connects, 1);
      expect(api.snapshotCalls, greaterThan(0));
    });
  });

  group('with the socket', () {
    test('the deltas drive the state, and the snapshot is not asked',
        () async {
      final api = ScriptedJobsApi();
      final events = FakeJobEventSource();
      final controller = controllerWith(
        api: api,
        events: events,
        eventsAdvertised: true,
      );

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => events.opened.isNotEmpty, 'the socket to open');

      events.latest.emit(const JobStateEvent(JobState.running));
      await pumpEventQueue();
      expect(controller.state, LifecycleState.generating);

      events.latest.emit(
        const JobProgressEvent(JobProgress(step: 7, total: 24)),
      );
      await pumpEventQueue();
      expect(controller.progress, const JobProgress(step: 7, total: 24));

      events.latest.emit(
        const JobResultsEvent(<JobResultRef>[imageResult]),
      );
      events.latest.emit(const JobStateEvent(JobState.completed));
      await waitFor(
        () => controller.state == LifecycleState.completed,
        'the completed delta',
      );

      // The optimization did its job, so the poll never had to.
      expect(api.snapshotCalls, 0);
    });

    test('losing the socket goes back to the snapshot, not to replayed events',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final events = FakeJobEventSource();
      final controller = controllerWith(
        api: api,
        events: events,
        eventsAdvertised: true,
      );

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => events.opened.isNotEmpty, 'the socket to open');
      events.latest.emit(const JobStateEvent(JobState.running));
      await pumpEventQueue();
      expect(controller.state, LifecycleState.generating);

      // The socket drops while the job is still going.
      events.latest.drop();

      await waitFor(
        () => controller.state == LifecycleState.completed,
        'the snapshot to take over',
      );
      expect(api.snapshotCalls, greaterThan(0));
      expect(controller.hasResult, isTrue);
    });
  });

  group('progress', () {
    test('a gateway that reports none leaves it indeterminate', () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<JobSnapshot?>[
        snapshotOf(JobState.queued),
        snapshotOf(JobState.running),
      ]);
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to start running',
      );

      // Several polls later there is still nothing to draw, because the
      // gateway still has not said anything.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(controller.progress, isNull);
    });

    test('a gateway that stops reporting stops the bar reporting too',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<JobSnapshot?>[
        snapshotOf(
          JobState.running,
          progress: const JobProgress(step: 7, total: 24),
        ),
        snapshotOf(JobState.running),
      ]);
      final controller = controllerWith(api: api);

      // Every value the controller exposes, in order, recorded as it is
      // exposed (T-0227). The 7/24 exists only between two polls 5 ms apart,
      // and a test that samples for it can arrive after it has gone; a
      // listener cannot, because every change is announced.
      const reported = JobProgress(step: 7, total: 24);
      final history = <JobProgress?>[];
      controller.addListener(() => history.add(controller.progress));

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      // Waiting on the record, not on the moment: once the 7/24 and a `null`
      // after it are in the history they stay there.
      await waitFor(() {
        final at = history.indexOf(reported);
        return at >= 0 && history.skip(at + 1).contains(null);
      }, 'the reported progress, and none after it');

      expect(history, contains(reported));
      // The next snapshot carries no progress, so neither does the app: the
      // last number is not frozen on screen as though it were current.
      expect(history, containsAllInOrder(<JobProgress?>[reported, null]));
      expect(controller.progress, isNull);
    });

    test('a finished job carries no progress at all', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          progress: const JobProgress(step: 24, total: 24),
          results: const <JobResultRef>[imageResult],
        ),
      );
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.completed,
        'completion',
      );

      expect(controller.progress, isNull);
    });
  });

  group('cancellation', () {
    test('is absent unless the gateway advertises it', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api, cancel: false);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );

      expect(controller.canCancel, isFalse);
      await controller.cancel();
      expect(api.cancels, 0);
    });

    test('is offered while there is something to cancel, and not after',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<JobSnapshot?>[
        snapshotOf(JobState.running),
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      ]);
      final controller = controllerWith(api: api, cancel: true);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canCancel, 'cancel to be offered');

      await waitFor(
        () => controller.state == LifecycleState.completed,
        'completion',
      );
      expect(controller.canCancel, isFalse);
    });

    test('a job that finished first is completed, with its result', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      api.cancelReply = snapshotOf(
        JobState.completed,
        results: const <JobResultRef>[imageResult],
      );
      final controller = controllerWith(api: api, cancel: true);
      final seen = watch(controller);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canCancel, 'cancel to be offered');
      await controller.cancel();

      expect(controller.state, LifecycleState.completed);
      expect(controller.results.single.index, 0);
      // A cancel request is not a cancelled outcome.
      expect(seen, isNot(contains(LifecycleState.cancelled)));
    });

    test('the result comes out of the cancel reply itself', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      api.cancelReply = snapshotOf(
        JobState.completed,
        results: const <JobResultRef>[imageResult],
      );
      final controller = controllerWith(api: api, cancel: true);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canCancel, 'cancel to be offered');
      final asked = api.snapshotCalls;
      await controller.cancel();

      // `docs/api.md`: the cancel reply is the full snapshot, so the outputs
      // are already in hand and nothing goes back to ask for them.
      expect(controller.state, LifecycleState.completed);
      expect(controller.results, isNotEmpty);
      expect(api.snapshotCalls, asked);
    });

    test('a cancelled reply is cancelled, and shows no result', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      api.cancelReply = snapshotOf(JobState.cancelled);
      final controller = controllerWith(api: api, cancel: true);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canCancel, 'cancel to be offered');
      await controller.cancel();

      expect(controller.state, LifecycleState.cancelled);
      expect(controller.hasResult, isFalse);
    });

    test('a cancel that never lands asserts nothing about the job', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      api.cancelFailure = const JobFailure.unreachable();
      final controller = controllerWith(api: api, cancel: true);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canCancel, 'cancel to be offered');
      await controller.cancel();

      // The request failed. The job is whatever it was.
      expect(controller.state, LifecycleState.generating);
      expect(controller.isCancelling, isFalse);
    });
  });

  group('losing contact', () {
    test('a job in flight becomes interrupted, which is not progress',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );

      controller.connectionLost();

      expect(controller.state, LifecycleState.interrupted);
      expect(controller.state.isProgressing, isFalse);
      expect(controller.recovery, JobRecovery.unknown);
      // No sentence is stored for it. What the screen says is composed from
      // `isCheckingSurvival` at draw time, and nothing is checking yet.
      expect(controller.problemMessage(en), isNull);
      expect(controller.isCheckingSurvival, isFalse);
    });

    test('the claim to be checking lasts exactly as long as the check',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );
      controller.connectionLost();

      // The bounded reconnect starts: now something really is looking.
      controller.beginReconnect();
      expect(controller.state, LifecycleState.interrupted);
      expect(controller.isCheckingSurvival, isTrue);

      // It runs out. `docs/recovery.md`: every waiting state has a bound and
      // an exit — so the claim ends with the attempts, and does not sit on
      // screen describing something the app has stopped doing.
      controller.endReconnect(connected: false);
      expect(controller.state, LifecycleState.interrupted);
      expect(controller.isCheckingSurvival, isFalse);

      // And the user's Reconnect makes it true again rather than leaving a
      // stale sentence in place.
      controller.beginReconnect();
      expect(controller.isCheckingSurvival, isTrue);
    });

    test('with no job interrupted, nothing claims to be checking one', () async {
      // `isCheckingSurvival` is public and its sentence is about *this* job, so
      // it has to be false wherever there is no interrupted job to have
      // survived anything — not merely wherever the interrupted panel happens
      // not to be built. A reconnect over an idle app, and a reconnect with a
      // finished result on screen, are both that case.
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final controller = controllerWith(api: api);
      expect(controller.state, LifecycleState.ready);

      controller.beginReconnect();
      expect(controller.state, LifecycleState.reconnecting);
      expect(controller.isCheckingSurvival, isFalse);
      controller.endReconnect(connected: true);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.completed,
        'the job to finish',
      );

      // Reconnecting with a result on display: still nothing whose survival is
      // in question, so still no claim to be finding out.
      controller.beginReconnect();
      expect(controller.state, LifecycleState.completed);
      expect(controller.isCheckingSurvival, isFalse);
    });

    test('an interrupted job survives the reconnect it is waiting on',
        () async {
      // `endReconnect` used to rewrite only a `reconnecting` state, which is
      // how the interrupted one kept its stale message. It must still not
      // rewrite the state itself: an unanswered job is not a disconnected app.
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );
      controller.connectionLost();
      controller.beginReconnect();
      controller.endReconnect(connected: false);

      expect(controller.state, LifecycleState.interrupted);
      expect(controller.recovery, JobRecovery.unknown);
      expect(controller.jobId, isNotNull);
    });

    test('a job the gateway has lost is not something to keep checking',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );
      controller.connectionLost();
      api.snapshots
        ..clear()
        ..add(null);
      await controller.recoverJob();
      expect(controller.recovery, JobRecovery.lost);

      // A 404 is an answer. Even mid-reconnect there is nothing left to find
      // out, so the checking sentence must not come back over the top of it.
      controller.beginReconnect();
      expect(controller.isCheckingSurvival, isFalse);
      expect(controller.problemMessage(en), stateUnrecoverableMessage(en));
    });

    test('a result already shown is not discarded by losing the gateway',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.hasResult, 'the result');

      controller.connectionLost();

      expect(controller.state, LifecycleState.completed);
      expect(controller.hasResult, isTrue);
    });

    test('the snapshot failing is bounded, and then the waiting ends',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      var lost = 0;
      final controller = controllerWith(api: api)..onContactLost = () => lost++;

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );

      // The gateway goes away.
      api.snapshotFailure = const JobFailure.unreachable();
      await waitFor(
        () => controller.state == LifecycleState.interrupted,
        'the bounded snapshot failures to end the wait',
      );

      final calls = api.snapshotCalls;
      expect(lost, 1);
      // The loop stopped. It does not keep asking a gateway that is gone.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(api.snapshotCalls, calls);
    });
  });

  group('job recovery', () {
    Future<GenerationController> interrupted(ScriptedJobsApi api) async {
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );
      controller.connectionLost();
      api.snapshots.clear();
      return controller;
    }

    test('running resumes following it', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      api.snapshots.addAll(<JobSnapshot?>[
        snapshotOf(JobState.running),
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      ]);

      await controller.recoverJob();

      expect(controller.state, LifecycleState.generating);
      await waitFor(
        () => controller.state == LifecycleState.completed,
        'the resumed job to finish',
      );
    });

    test('completed while we were away shows the result', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );

      await controller.recoverJob();

      expect(controller.state, LifecycleState.completed);
      await waitFor(() => controller.resultBytes != null, 'the bytes');
    });

    test('failed while we were away shows the error', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      api.snapshots.add(
        snapshotOf(
          JobState.failed,
          error: 'A model this workflow needs is missing.',
        ),
      );

      await controller.recoverJob();

      expect(controller.state, LifecycleState.failed);
      expect(
        controller.problemMessage(en),
        'A model this workflow needs is missing.',
      );
    });

    test('cancelled while we were away shows it as cancelled', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      api.snapshots.add(snapshotOf(JobState.cancelled));

      await controller.recoverJob();

      expect(controller.state, LifecycleState.cancelled);
    });

    test('a 404 is reported as state that could not be recovered', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      final seen = watch(controller);
      // The gateway is up and answering — it simply does not have the job.
      api.snapshots.add(null);

      await controller.recoverJob();

      expect(controller.state, LifecycleState.interrupted);
      expect(controller.recovery, JobRecovery.lost);
      expect(controller.problemMessage(en), stateUnrecoverableMessage(en));
      expect(controller.problemMessage(en), 'Generation state could not be recovered.');
      // No resumption was ever claimed.
      expect(seen, isNot(contains(LifecycleState.generating)));
      expect(controller.state.isProgressing, isFalse);
    });

    test('a snapshot that cannot be fetched claims nothing either', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      final seen = watch(controller);
      api.snapshotFailure = const JobFailure.unreachable();

      await controller.recoverJob();

      expect(controller.state, LifecycleState.interrupted);
      expect(controller.recovery, JobRecovery.unknown);
      expect(seen, isNot(contains(LifecycleState.generating)));
      // The one request that could have answered has been made and failed.
      // Nothing is checking any more, so nothing may say that it is.
      expect(controller.isCheckingSurvival, isFalse);
      expect(controller.problemMessage(en), isNull);
    });

    test('a recovered job gets the whole failure budget back', () async {
      // The budget counts consecutive failures, so a poll loop that spent it
      // before the connection came back must not leave the next single failure
      // declaring contact lost all over again.
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );

      // The gateway goes away and the budget is spent.
      api.snapshotFailure = const JobFailure.unreachable();
      await waitFor(
        () => controller.state == LifecycleState.interrupted,
        'the budget to run out',
      );

      // It comes back once — the recovery reads a running job — and then goes
      // away again for good. Scripted as a sequence rather than a switch, so
      // the successful read is the recovery's and every call after it fails;
      // a poll that succeeded in between would reset the counter by itself and
      // hide the very thing this test is about.
      api.snapshotFailure = null;
      api.snapshots
        ..clear()
        ..addAll(<Object?>[
          snapshotOf(JobState.running),
          const JobFailure.unreachable(),
        ]);

      final base = api.snapshotCalls;
      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);

      await waitFor(
        () => controller.state == LifecycleState.interrupted,
        'the budget to run out a second time',
      );

      // One successful read for the recovery, then the whole budget again.
      // Without the reset it is one failure, because the first one inherits a
      // counter the previous loss of contact had already filled.
      expect(
        api.snapshotCalls - base,
        greaterThanOrEqualTo(1 + controller.snapshotFailureBudget),
      );
    });

    test('a reachable gateway alone never resumes anything', () async {
      // The whole honesty rule in one assertion: recovery is driven by the
      // snapshot and by nothing else, so a controller that never asks — or
      // asks and is told nothing — stays interrupted.
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      final asked = api.snapshotCalls;

      controller.attach(
        endpoint: endpoint,
        capabilities: const GatewayCapabilities(events: true),
      );

      expect(controller.state, LifecycleState.interrupted);
      expect(api.snapshotCalls, asked);
    });

    test('Generate Again leaves the interrupted job behind', () async {
      final api = ScriptedJobsApi();
      final controller = await interrupted(api);
      api.snapshots.add(null);
      await controller.recoverJob();

      controller.generateAgain();

      expect(controller.state, LifecycleState.ready);
      expect(controller.jobId, isNull);
      expect(controller.recovery, JobRecovery.none);
    });

    test('a 404 while the job is being followed is the same answer', () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<JobSnapshot?>[snapshotOf(JobState.running), null]);
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.recovery == JobRecovery.lost,
        'the gateway to say it no longer has the job',
      );

      expect(controller.state, LifecycleState.interrupted);
      expect(controller.problemMessage(en), stateUnrecoverableMessage(en));
    });
  });

  group('a reply asked for before contact was lost (T-0202)', () {
    // Under load, `a snapshot that cannot be fetched claims nothing either`
    // once recorded [interrupted, generating, interrupted]: a reply that was on
    // the wire when contact was lost landed after it and put `generating` back.
    //
    // These build that order on purpose instead of waiting for a machine to be
    // slow. A poll interval that never ticks inside a test leaves only the
    // requests the controller makes at once, and a gate in the fake holds one
    // reply: its answer is settled when the request is made and handed back
    // when the test says — asked before the interruption, answered after it,
    // which is the order a real reply in flight takes.
    const never = Duration(hours: 1);

    test('a snapshot that lands after the interruption brings nothing back',
        () async {
      final api = ScriptedJobsApi();
      final controller = controllerWith(api: api, pollInterval: never);
      final reply = Completer<void>();
      api.snapshotGate = reply;
      api.snapshots.add(
        snapshotOf(
          JobState.running,
          progress: const JobProgress(step: 3, total: 24),
        ),
      );

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );

      // Following began with one snapshot request, asked while the job was
      // queued, and its answer is still on the wire.
      expect(controller.state, LifecycleState.queued);
      expect(api.snapshotCalls, 1);
      expect(api.snapshotGate, isNull, reason: 'the poll took the gate');

      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);
      final seen = watch(controller);

      // The gateway's answer — running, at step 3 — arrives now.
      reply.complete();
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.unknown);
      expect(controller.progress, isNull);

      // Recovery is still the way out. The same answer, asked for after the
      // interruption, is proof, and it resumes the job.
      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);
      expect(controller.progress, const JobProgress(step: 3, total: 24));
      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.generating,
      ]);
    });

    test('a submit reply that lands after it keeps the id and claims nothing',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api, pollInterval: never);
      final reply = Completer<void>();
      api.submitGate = reply;

      final submitting = controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.uploading);
      expect(api.submitGate, isNull, reason: 'the submit took the gate');

      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);
      expect(controller.jobId, isNull);
      final seen = watch(controller);

      reply.complete();
      await submitting;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      // Nothing began following a job the app has said it cannot see.
      expect(api.snapshotCalls, 0);
      // The id is kept all the same: `docs/recovery.md` records it the moment
      // the submit response arrives, because it is the one thing recovery can
      // ask about.
      expect(controller.jobId, 'j-8f21');

      await controller.recoverJob();
      expect(api.snapshotCalls, greaterThanOrEqualTo(1));
      expect(controller.state, LifecycleState.generating);
    });

    test('a cancel reply that lands after it ends the request, claims nothing',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(
        api: api,
        cancel: true,
        pollInterval: never,
      );
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );
      expect(controller.canCancel, isTrue);

      final reply = Completer<void>();
      api.cancelGate = reply;
      // A job too far along to stop reports the state it reached (`docs/api.md`).
      api.cancelReply = snapshotOf(JobState.running);
      final cancelling = controller.cancel();
      expect(controller.isCancelling, isTrue);
      expect(api.cancelGate, isNull, reason: 'the cancel took the gate');

      controller.connectionLost();
      final seen = watch(controller);

      reply.complete();
      await cancelling;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      // The request has had its answer, so it is no longer outstanding —
      // otherwise the job recovered below could never be cancelled again.
      expect(controller.isCancelling, isFalse);

      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);
      expect(controller.canCancel, isTrue);
    });

    test('a recovery whose own request fails disowns the poll behind it',
        () async {
      // recoverJob() is not only called over an interrupted job. The recovery
      // panel stays up, with Reconnect pressable, over a job started after the
      // automatic reconnect ran out — so it can be called while a poll is on
      // the wire, and its failure path marks the job interrupted too
      // (session_reconnect_test.dart walks that path through the session).
      final api = ScriptedJobsApi();
      final controller = controllerWith(api: api, pollInterval: never);
      final reply = Completer<void>();
      api.snapshotGate = reply;
      api.snapshots.addAll(<Object?>[
        // The poll following the new job, held on the wire.
        snapshotOf(JobState.running),
        // Recovery's own request, which does not come back.
        const JobFailure.unreachable(),
      ]);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.queued);
      expect(api.snapshotGate, isNull, reason: 'the poll took the gate');

      await controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(controller.state, LifecycleState.interrupted);
      expect(controller.recovery, JobRecovery.unknown);
      final seen = watch(controller);

      reply.complete();
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);

      // And a recovery asked for after that one is still the way out.
      api.snapshots
        ..clear()
        ..add(snapshotOf(JobState.running));
      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);
    });

    test('a 404 interrupts too, and a cancel reply behind it claims nothing',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api, cancel: true);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );

      final reply = Completer<void>();
      api.cancelGate = reply;
      api.cancelReply = snapshotOf(JobState.running);
      final cancelling = controller.cancel();
      expect(api.cancelGate, isNull, reason: 'the cancel took the gate');

      // The gateway restarts, and the poll's next answer is that it has no
      // such job.
      api.snapshots
        ..clear()
        ..add(null);
      await waitFor(
        () => controller.recovery == JobRecovery.lost,
        'the poll to be told the job is gone',
      );
      final seen = watch(controller);

      reply.complete();
      await cancelling;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.lost);
      expect(controller.problemMessage(en), stateUnrecoverableMessage(en));
    });

    test('a snapshot failure that lands after it spends no budget', () async {
      final api = ScriptedJobsApi();
      var lost = 0;
      // One failure is the whole budget, so this one would end the wait on
      // its own if it were allowed to count.
      final controller = controllerWith(
        api: api,
        pollInterval: never,
        snapshotFailureBudget: 1,
      )..onContactLost = () => lost++;
      final reply = Completer<void>();
      api.snapshotGate = reply;
      api.snapshots.add(const JobFailure.unreachable());

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.queued);
      expect(api.snapshotGate, isNull, reason: 'the poll took the gate');

      controller.connectionLost();
      final seen = watch(controller);

      reply.complete();
      await pumpEventQueue();

      // Still the interrupted job, not a disconnected app, and no second
      // reconnect started for a contact that was already over.
      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.unknown);
      expect(lost, 0);

      // The same budget does count a failure asked for after recovery.
      api.snapshots
        ..clear()
        ..addAll(<Object?>[
          snapshotOf(JobState.running),
          const JobFailure.unreachable(),
        ]);
      await controller.recoverJob();
      await pumpEventQueue();
      expect(lost, 1);
      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.generating,
        LifecycleState.interrupted,
      ]);
    });

    test('a socket event still on its way when contact is lost never lands',
        () async {
      final api = ScriptedJobsApi();
      final events = FakeJobEventSource();
      final controller = controllerWith(
        api: api,
        events: events,
        eventsAdvertised: true,
        pollInterval: never,
      );
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await pumpEventQueue();
      final socket = events.opened.single;

      // The socket is live and can carry the job to generating in this run.
      socket.emit(const JobStateEvent(JobState.running));
      await pumpEventQueue();
      expect(controller.state, LifecycleState.generating);

      // Two more frames, delivered as a real socket's are: later, not inside
      // `emit`. Neither has reached the controller yet.
      socket
        ..emit(const JobProgressEvent(JobProgress(step: 5, total: 24)))
        ..emit(const JobStateEvent(JobState.running));
      expect(controller.progress, isNull, reason: 'still on its way');

      controller.connectionLost();
      final seen = watch(controller);
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.progress, isNull);
      expect(socket.closed, isTrue);
    });

    test('a socket that finishes opening after it is closed, not followed',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final events = FakeJobEventSource();
      final controller = controllerWith(
        api: api,
        events: events,
        eventsAdvertised: true,
        pollInterval: never,
      );
      final handshake = Completer<void>();
      events.connectGate = handshake;

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(events.connects, 1);
      expect(events.connectGate, isNull, reason: 'the handshake is on the wire');

      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);

      // The reconnect's recovery reads a running job and opens its own socket.
      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);
      await pumpEventQueue();
      expect(events.connects, 2);
      final recovered = events.opened.single;

      // Only then does the handshake asked for before contact was lost finish.
      handshake.complete();
      await pumpEventQueue();
      expect(events.opened, hasLength(2));
      final stale = events.opened.last;

      // The recovery's socket is the one carrying the job.
      recovered.emit(const JobProgressEvent(JobProgress(step: 9, total: 24)));
      await pumpEventQueue();
      expect(controller.progress, const JobProgress(step: 9, total: 24));

      // Contact goes a second time. Whatever socket is still open speaks.
      controller.connectionLost();
      final seen = watch(controller);
      for (final socket in events.opened) {
        if (!socket.closed) socket.emit(const JobStateEvent(JobState.running));
      }
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      // And no socket is left open for a later frame to speak through.
      expect(stale.closed, isTrue);
      expect(recovered.closed, isTrue);
    });
  });

  group('a failure asked for before contact was lost (T-0228)', () {
    // T-0202 disowned the late ANSWERS that would move an interrupted job back
    // to a progressing state. These are the late replies of the same class that
    // do not: a failure, and one success that lands where nothing is left to
    // disown it into.
    //
    // The order is the real transport's. `HttpJobsApi` turns a request that
    // does not come back into `JobFailure.unreachable` when its timeout fires,
    // and `WebSocketJobEventSource` does the same to a handshake after its own
    // five seconds — so the failure is thrown at the END of a wait that began
    // before contact was declared lost. The gate holds exactly that wait: the
    // fake decides the outcome when the request is made and throws it when the
    // test releases the gate, after `connectionLost()`.
    const never = Duration(hours: 1);

    test('a submit failure that lands after the interruption is disowned',
        () async {
      final api = ScriptedJobsApi()
        ..submitFailure = const JobFailure.unreachable();
      final controller = controllerWith(api: api, pollInterval: never);
      final reply = Completer<void>();
      api.submitGate = reply;

      final submitting = controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.uploading);
      expect(api.submitGate, isNull, reason: 'the submit took the gate');

      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);
      final seen = watch(controller);

      reply.complete();
      await submitting;
      await pumpEventQueue();

      // A timeout does not prove the gateway created nothing, so `failed`
      // would claim more than is known. The job stays what it was declared.
      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.unknown);
      expect(controller.problemTitle(en), isNull);
      expect(controller.problemMessage(en), isNull);

      // Recovery is still the way out: with no id there is nothing to ask
      // about, and the app is ready again.
      await controller.recoverJob();
      expect(controller.state, LifecycleState.ready);

      // And the same failure, asked for and answered inside one contact, is
      // still reported — so the silence above is the guard, not a controller
      // that cannot say it.
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.failed);
      expect(controller.problemTitle(en), "The server didn't answer.");
    });

    test('a cancel failure that lands after the interruption writes nothing',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(
        api: api,
        cancel: true,
        pollInterval: never,
      );
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );

      final reply = Completer<void>();
      api.cancelGate = reply;
      api.cancelFailure = const JobFailure.unreachable();
      final cancelling = controller.cancel();
      expect(controller.isCancelling, isTrue);
      expect(api.cancelGate, isNull, reason: 'the cancel took the gate');

      controller.connectionLost();
      expect(controller.problemMessage(en), isNull);
      final seen = watch(controller);

      reply.complete();
      await cancelling;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.unknown);
      // No sentence written onto the interrupted job, which `connectionLost()`
      // left without one on purpose.
      expect(controller.problemTitle(en), isNull);
      expect(controller.problemMessage(en), isNull);
      // Answered all the same, so no longer outstanding.
      expect(controller.isCancelling, isFalse);

      // Recovery is still the way out.
      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);
      expect(controller.problemMessage(en), isNull);

      // And a cancel failure inside one contact still says so: the sentence
      // the guard withholds above is one this controller does write.
      await controller.cancel();
      expect(controller.state, LifecycleState.generating);
      expect(controller.problemMessage(en), isNotNull);
    });

    test('a handshake that fails after recovery opened a socket starts no poll',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final events = FakeJobEventSource();
      final controller = controllerWith(
        api: api,
        events: events,
        eventsAdvertised: true,
        pollInterval: never,
      );
      // The first handshake will not open, and does not say so until later.
      final handshake = Completer<void>();
      events
        ..failToConnect = true
        ..connectGate = handshake;

      // A submit answering `running` has the controller follow the job at once.
      api.submission = const JobSubmission(
        jobId: 'j-8f21',
        state: JobState.running,
      );
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.generating);
      expect(events.connects, 1);
      expect(events.connectGate, isNull, reason: 'the handshake is on the wire');

      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);

      // The reconnect's recovery reads a running job and opens a socket that
      // does open.
      events.failToConnect = false;
      await controller.recoverJob();
      expect(controller.state, LifecycleState.generating);
      await pumpEventQueue();
      expect(events.connects, 2);
      final live = events.opened.single;
      final asked = api.snapshotCalls;
      expect(asked, 1, reason: "only the recovery's own read");

      // Only now does the handshake asked for before contact was lost fail.
      handshake.complete();
      await pumpEventQueue();

      // One follower for one job: the live socket, and no poll beside it.
      expect(api.snapshotCalls, asked);
      expect(live.closed, isFalse);
      live.emit(const JobProgressEvent(JobProgress(step: 9, total: 24)));
      await pumpEventQueue();
      expect(controller.progress, const JobProgress(step: 9, total: 24));

      // The poll was there to be seen: losing the live socket starts one, and
      // it asks at once. Had the stale failure already started it, this would
      // find its timer running and ask nothing.
      live.drop();
      await pumpEventQueue();
      expect(api.snapshotCalls, asked + 1);
    });

    test('a submit that lands after recovery found no job is adopted, '
        'interrupted', () async {
      final api = ScriptedJobsApi();
      final controller = controllerWith(api: api, pollInterval: never);
      final reply = Completer<void>();
      api.submitGate = reply;

      final submitting = controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.uploading);
      expect(api.submitGate, isNull, reason: 'the submit took the gate');

      // Contact is lost during the upload, and the reconnect's recovery runs
      // before the reply lands: with no id there is nothing to ask about, so it
      // goes back to ready.
      controller.connectionLost();
      controller.beginReconnect();
      await controller.recoverJob();
      controller.endReconnect(connected: true);
      expect(controller.state, LifecycleState.ready);
      expect(controller.jobId, isNull);
      final seen = watch(controller);

      reply.complete();
      await submitting;
      await pumpEventQueue();

      // The gateway did create the job. Dropping it would orphan a generation
      // nobody can see; following it would put a progressing state back on a
      // reply from a contact that is over. It is recorded, and it is
      // interrupted: the recovery panel is what the user sees.
      expect(controller.jobId, 'j-8f21');
      expect(seen, <LifecycleState>[
        LifecycleState.ready,
        LifecycleState.interrupted,
      ]);
      expect(controller.recovery, JobRecovery.unknown);
      expect(controller.problemMessage(en), isNull);
      // Nothing follows it until recovery asks.
      expect(api.snapshotCalls, 0);

      // The user's recovery reads the real state.
      api.snapshots.add(snapshotOf(JobState.running));
      await controller.recoverJob();
      // Recovery's own read, and the poll it resumes following with.
      expect(api.snapshotCalls, greaterThanOrEqualTo(1));
      expect(controller.state, LifecycleState.generating);
      expect(seen, <LifecycleState>[
        LifecycleState.ready,
        LifecycleState.interrupted,
        LifecycleState.generating,
      ]);
    });

    group('but never over a newer job the user has started since', () {
      // The adoption above writes an id and a state. What keeps it off a job
      // started after recovery went back to ready is the job token alone —
      // every path that starts a job moves it — so these hold that token to
      // the one rule it protects: an old reply never replaces a newer job's id
      // or its state.
      //
      // Submission A is asked for, contact is lost during its upload, and the
      // reconnect's recovery (SessionController.reconnect()'s order) finds no
      // id and goes back to ready. Only then is the newer job B started, and
      // only after that does A's reply come back.
      const older = 'j-8f21';
      const newer = 'j-newer';

      Future<({GenerationController controller, Completer<void> reply,
          Future<void> submitting})> olderOnTheWire(ScriptedJobsApi api) async {
        final controller = controllerWith(api: api, pollInterval: never);
        final reply = Completer<void>();
        api.submitGate = reply;
        final submitting = controller.submit(
          workflowId: 'w',
          inputs: const <String, Object?>{},
        );
        expect(api.submitGate, isNull, reason: 'submission A took the gate');

        controller.connectionLost();
        controller.beginReconnect();
        await controller.recoverJob();
        controller.endReconnect(connected: true);
        expect(controller.state, LifecycleState.ready);
        expect(controller.jobId, isNull);

        // Every submission from here on is B's: the fake reads its answer
        // when the request is made, so A still answers with its own id.
        api.submission = const JobSubmission(
          jobId: newer,
          state: JobState.queued,
        );
        return (controller: controller, reply: reply, submitting: submitting);
      }

      test('a newer job that is queued keeps its id and its state', () async {
        final api = ScriptedJobsApi();
        final on = await olderOnTheWire(api);
        final controller = on.controller;
        api.snapshots.add(snapshotOf(JobState.queued, jobId: newer));

        await controller.submit(
          workflowId: 'w',
          inputs: const <String, Object?>{},
        );
        expect(controller.state, LifecycleState.queued);
        expect(controller.jobId, newer);
        final seen = watch(controller);

        on.reply.complete();
        await on.submitting;
        await pumpEventQueue();

        expect(seen, <LifecycleState>[LifecycleState.queued]);
        expect(controller.jobId, newer);
        expect(controller.recovery, JobRecovery.none);
      });

      test('a newer job that has completed keeps its id and its result',
          () async {
        final api = ScriptedJobsApi();
        final on = await olderOnTheWire(api);
        final controller = on.controller;
        api.snapshots.add(
          snapshotOf(
            JobState.completed,
            jobId: newer,
            results: const <JobResultRef>[imageResult],
          ),
        );

        await controller.submit(
          workflowId: 'w',
          inputs: const <String, Object?>{},
        );
        await waitFor(() => controller.hasResult, 'the newer job to finish');
        expect(controller.jobId, newer);
        final seen = watch(controller);

        on.reply.complete();
        await on.submitting;
        await pumpEventQueue();

        // A finished result is not replaced by the recovery panel for a job
        // the user has already moved past.
        expect(seen, <LifecycleState>[LifecycleState.completed]);
        expect(controller.jobId, newer);
        expect(controller.hasResult, isTrue);
        expect(controller.recovery, JobRecovery.none);
      });

      test('a newer job still uploading gets its own id when its reply lands',
          () async {
        final api = ScriptedJobsApi();
        final on = await olderOnTheWire(api);
        final controller = on.controller;
        api.snapshots.add(snapshotOf(JobState.queued, jobId: newer));
        final newerReply = Completer<void>();
        api.submitGate = newerReply;

        final submittingNewer = controller.submit(
          workflowId: 'w',
          inputs: const <String, Object?>{},
        );
        expect(api.submitGate, isNull, reason: 'submission B took the gate');
        expect(controller.state, LifecycleState.uploading);
        final seen = watch(controller);

        // A's reply lands first, while B is still on the wire.
        on.reply.complete();
        await on.submitting;
        await pumpEventQueue();

        expect(seen, <LifecycleState>[LifecycleState.uploading]);
        expect(controller.jobId, isNull);

        newerReply.complete();
        await submittingNewer;
        await pumpEventQueue();

        expect(seen, <LifecycleState>[
          LifecycleState.uploading,
          LifecycleState.queued,
        ]);
        expect(controller.jobId, newer);
        expect(controller.jobId, isNot(older));
      });
    });
  });

  group('a recovery reply that outlives what it recovered (T-0233)', () {
    // recoverJob() is not only asked over an interrupted job: the recovery
    // panel's Reconnect stays pressable over a job started after the automatic
    // reconnect ran out (T-0202). Its snapshot reply is disowned when contact
    // has been lost again since it was asked, or when the job reached an
    // outcome by another path while it was out. A recovery asked over an
    // interrupted job is asked on the contact current at that moment, so its
    // reply is still believed — that is what recovery is.
    //
    // The same gate as T-0202's: the answer is settled when the request is
    // made and handed back when the test releases it, after whatever happened
    // in between. A failure is thrown at the end of that wait, which is where
    // `HttpJobsApi` throws a timeout.
    const never = Duration(hours: 1);

    /// A job being followed by the snapshot, at generating, with one poll
    /// answered and no other request on the wire.
    Future<GenerationController> running(
      ScriptedJobsApi api, {
      bool cancel = false,
    }) async {
      final controller = controllerWith(
        api: api,
        cancel: cancel,
        pollInterval: never,
      );
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await pumpEventQueue();
      expect(controller.state, LifecycleState.generating);
      expect(api.snapshotCalls, 1);
      return controller;
    }

    test('contact lost while it was out: its "running" brings nothing back',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = await running(api);

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');
      expect(controller.recovery, JobRecovery.checking);

      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);
      final seen = watch(controller);

      // The gateway's answer, asked before contact was lost — running — lands.
      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.unknown);
      expect(api.snapshotCalls, 2, reason: 'nothing began following it');

      // The state machine does go there: the same answer, asked for over the
      // interrupted job, is proof and resumes it.
      await controller.recoverJob();
      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.generating,
      ]);
    });

    test('a 404 while it was out: its "running" brings nothing back', () async {
      final api = ScriptedJobsApi();
      final controller = controllerWith(api: api, pollInterval: never);
      final poll = Completer<void>();
      api.snapshotGate = poll;
      api.snapshots.addAll(<Object?>[
        // The poll following the job: the gateway no longer has it.
        null,
        // Recovery's own request, asked a moment earlier than that answer
        // came back: running.
        snapshotOf(JobState.running),
      ]);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(controller.state, LifecycleState.queued);
      expect(api.snapshotGate, isNull, reason: 'the poll took the gate');

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');

      poll.complete();
      await pumpEventQueue();
      expect(controller.state, LifecycleState.interrupted);
      expect(controller.recovery, JobRecovery.lost);
      final seen = watch(controller);

      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.interrupted]);
      expect(controller.recovery, JobRecovery.lost);
      expect(api.snapshotCalls, 2, reason: 'nothing began following it');
    });

    test('a 404 while it was out: a late failure does not unsay it', () async {
      final api = ScriptedJobsApi();
      final controller = controllerWith(api: api, pollInterval: never);
      final poll = Completer<void>();
      api.snapshotGate = poll;
      api.snapshots.addAll(<Object?>[
        null,
        // Recovery's own request, which does not come back.
        const JobFailure.unreachable(),
      ]);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(api.snapshotGate, isNull, reason: 'the poll took the gate');

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');

      poll.complete();
      await pumpEventQueue();
      expect(controller.recovery, JobRecovery.lost);
      expect(controller.problemMessage(en), stateUnrecoverableMessage(en));

      // The recovery's timeout fires after the gateway said it has no job.
      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(controller.state, LifecycleState.interrupted);
      expect(controller.recovery, JobRecovery.lost);
      expect(controller.problemMessage(en), stateUnrecoverableMessage(en));
    });

    test('a cancel completed the job while it was out: "running" is disowned',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = await running(api, cancel: true);

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');

      // The job finished before the interrupt landed, and the cancel reply
      // says so, with its result (`docs/api.md`).
      api.cancelReply = snapshotOf(
        JobState.completed,
        results: const <JobResultRef>[imageResult],
      );
      await controller.cancel();
      expect(controller.state, LifecycleState.completed);
      final seen = watch(controller);

      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.completed]);
      expect(controller.hasResult, isTrue);
      expect(controller.recovery, JobRecovery.none);
      expect(api.snapshotCalls, 2, reason: 'nothing began following it');
    });

    test('a cancel completed the job while it was out: a late failure is '
        'disowned', () async {
      final api = ScriptedJobsApi();
      api.snapshots.addAll(<Object?>[
        snapshotOf(JobState.running),
        // Recovery's own request, which does not come back.
        const JobFailure.unreachable(),
      ]);
      final controller = await running(api, cancel: true);

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');

      api.cancelReply = snapshotOf(
        JobState.completed,
        results: const <JobResultRef>[imageResult],
      );
      await controller.cancel();
      expect(controller.state, LifecycleState.completed);
      final seen = watch(controller);

      // The recovery's timeout fires now, after the job has finished.
      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[LifecycleState.completed]);
      expect(controller.hasResult, isTrue);
      expect(controller.recovery, JobRecovery.none);
    });

    test('over an interrupted job, a second recovery that found the outcome '
        'is not overwritten by the first', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = await running(api);
      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);
      api.snapshots
        ..clear()
        ..addAll(<Object?>[
          // The first recovery's answer, held on the wire.
          snapshotOf(JobState.running),
          // The second's, which comes back at once: the job has finished.
          snapshotOf(
            JobState.completed,
            results: const <JobResultRef>[imageResult],
          ),
        ]);
      final seen = watch(controller);

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final first = controller.recoverJob();
      expect(api.snapshotGate, isNull, reason: 'the first took the gate');

      await controller.recoverJob();
      expect(controller.state, LifecycleState.completed);

      reply.complete();
      await first;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.completed,
      ]);
      expect(controller.hasResult, isTrue);
    });

    test('a recovery asked over an interrupted job is believed when it lands',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = await running(api);
      controller.connectionLost();
      api.snapshots
        ..clear()
        ..add(
          snapshotOf(
            JobState.completed,
            results: const <JobResultRef>[imageResult],
          ),
        );
      final seen = watch(controller);

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');
      expect(controller.recovery, JobRecovery.checking);

      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.completed,
      ]);
      expect(controller.hasResult, isTrue);
    });

    test('contact lost over an interrupted job: its recovery\'s "running" '
        'brings nothing back (T-0234)', () async {
      // Reconnect pressed, and then Choose another server while its recovery
      // is still on the wire: the session turns that into connectionLost()
      // over a job that is interrupted, not running.
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = await running(api);
      controller.connectionLost();
      expect(controller.state, LifecycleState.interrupted);
      final seen = watch(controller);

      final reply = Completer<void>();
      api.snapshotGate = reply;
      final recovering = controller.recoverJob();
      expect(api.snapshotCalls, 2);
      expect(api.snapshotGate, isNull, reason: 'recovery took the gate');

      controller.connectionLost();
      expect(controller.state, LifecycleState.disconnected);

      reply.complete();
      await recovering;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.disconnected,
      ]);
      expect(api.snapshotCalls, 2, reason: 'nothing began following it');

      // The state machine does go there: a reconnect asked after the loss —
      // SessionController.reconnect()'s order — recovers the same job.
      controller.beginReconnect();
      await controller.recoverJob();
      controller.endReconnect(connected: true);
      expect(seen, <LifecycleState>[
        LifecycleState.interrupted,
        LifecycleState.disconnected,
        LifecycleState.reconnecting,
        LifecycleState.generating,
      ]);
      expect(api.snapshotCalls, greaterThan(3), reason: 'it is followed');
    });

    test('contact lost with no job disowns nothing asked after it (T-0234)',
        () async {
      final api = ScriptedJobsApi();
      final controller = controllerWith(
        api: api,
        cancel: true,
        pollInterval: never,
      );
      expect(controller.state, LifecycleState.ready);
      final seen = watch(controller);

      // Nothing was on the wire, so this ends a contact nobody asked on.
      controller.connectionLost();
      controller.beginReconnect();
      controller.endReconnect(connected: true);
      expect(controller.state, LifecycleState.ready);

      // Every reply below is asked after that loss and held on the wire, so
      // each is the kind of reply the loss would disown if it reached forward.
      final submitted = Completer<void>();
      api.submitGate = submitted;
      api.submission = const JobSubmission(
        jobId: 'j-8f21',
        state: JobState.queued,
      );
      final submitting = controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      expect(api.submitGate, isNull, reason: 'the submit took the gate');

      final polled = Completer<void>();
      api.snapshotGate = polled;
      api.snapshots.add(snapshotOf(JobState.running));
      submitted.complete();
      await submitting;
      expect(controller.state, LifecycleState.queued);
      expect(api.snapshotGate, isNull, reason: 'the poll took the gate');

      polled.complete();
      await pumpEventQueue();
      expect(controller.state, LifecycleState.generating);

      final cancelled = Completer<void>();
      api.cancelGate = cancelled;
      api.cancelReply = snapshotOf(JobState.cancelled);
      final cancelling = controller.cancel();
      expect(api.cancelGate, isNull, reason: 'the cancel took the gate');
      cancelled.complete();
      await cancelling;
      await pumpEventQueue();

      expect(seen, <LifecycleState>[
        LifecycleState.ready,
        LifecycleState.disconnected,
        LifecycleState.reconnecting,
        LifecycleState.ready,
        LifecycleState.uploading,
        LifecycleState.queued,
        LifecycleState.generating,
        LifecycleState.cancelled,
      ]);
      expect(controller.isCancelling, isFalse);
    });
  });

  group('reconnect states', () {
    test('an idle app reconnecting says so, and comes back to ready', () {
      final controller = controllerWith(api: ScriptedJobsApi());

      controller.beginReconnect();
      expect(controller.state, LifecycleState.reconnecting);
      expect(controller.isReconnecting, isTrue);

      controller.endReconnect(connected: true);
      expect(controller.state, LifecycleState.ready);
      expect(controller.isReconnecting, isFalse);
    });

    test('a failed reconnect with nothing in flight is disconnected', () {
      final controller = controllerWith(api: ScriptedJobsApi());

      controller.beginReconnect();
      controller.endReconnect(connected: false);

      expect(controller.state, LifecycleState.disconnected);
    });

    test('reconnecting over an interrupted job does not overwrite it',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(snapshotOf(JobState.running));
      final controller = controllerWith(api: api);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(
        () => controller.state == LifecycleState.generating,
        'the job to run',
      );
      controller.connectionLost();

      controller.beginReconnect();

      // Both are true at once and both are said: the fate is unknown, and a
      // reconnect is under way.
      expect(controller.state, LifecycleState.interrupted);
      expect(controller.isReconnecting, isTrue);
    });
  });

  group('the result', () {
    test('Save and Share hand the exporter the bytes and a name', () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final exporter = RecordingResultExporter();
      final controller = controllerWith(api: api, exporter: exporter);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canExport, 'the result');

      await controller.saveResult();
      expect(exporter.saved.single.bytes, tinyPng);
      expect(exporter.saved.single.filename, 'localcanvas-0.png');
      expect(controller.exportSaved, isTrue);

      await controller.shareResult();
      expect(exporter.shared.single.mediaType, 'image/png');
      // Share hands the file to another app and never learns what it did with
      // it, so it claims nothing afterwards.
      expect(controller.exportSaved, isFalse);
    });

    test('a gallery that refuses says so, in words with an action in them',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final exporter = RecordingResultExporter()
        ..saveFailure = const ExportFailure.accessDenied();
      final controller = controllerWith(api: api, exporter: exporter);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.canExport, 'the result');
      await controller.saveResult();

      expect(controller.exportFailure, isNotNull);
      expect(controller.exportSaved, isFalse);
    });

    test('no exporter means no Save and no Share, rather than dead buttons',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.hasResult, 'the result');

      expect(controller.canExport, isFalse);
    });

    test('a video result is not fetched into memory to be looked at',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[videoResult],
        ),
      );
      final controller = controllerWith(api: api);

      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.hasResult, 'the result');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // A clip is downloaded when the user asks to keep it, not to draw a
      // preview this app cannot draw.
      expect(controller.resultBytes, isNull);
      expect(controller.primaryResult!.isVideo, isTrue);
    });

    test('moving to another server takes the job and the result with it',
        () async {
      final api = ScriptedJobsApi();
      api.snapshots.add(
        snapshotOf(
          JobState.completed,
          results: const <JobResultRef>[imageResult],
        ),
      );
      final controller = controllerWith(api: api);
      await controller.submit(
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );
      await waitFor(() => controller.hasResult, 'the result');

      controller.attach(
        endpoint: Endpoint.tryParse('192.0.2.99:7801')!,
        capabilities: const GatewayCapabilities(),
      );

      // No other gateway knows this job id, and the picture came from the one
      // we left.
      expect(controller.jobId, isNull);
      expect(controller.hasResult, isFalse);
      expect(controller.state, LifecycleState.ready);
    });
  });
}
