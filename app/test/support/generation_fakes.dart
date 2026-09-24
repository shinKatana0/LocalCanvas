/// Test doubles for the generation half of the app.
///
/// The scripts here answer *only* what a test put in them: an empty snapshot
/// queue throws rather than quietly returning `null`, because a `null` from
/// [JobsApi.snapshot] means "the gateway answered 404" and a fixture that
/// produced one by accident would let a recovery test pass without the code
/// doing anything.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/reconnect_attempts_store.dart';
import 'package:localcanvas/generation/clip_playback.dart';
import 'package:localcanvas/generation/generation_controller.dart';
import 'package:localcanvas/generation/job_events.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/generation/result_export.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

/// A jobs API answered from a script instead of a socket.
class ScriptedJobsApi implements JobsApi {
  ScriptedJobsApi({
    this.submission = const JobSubmission(
      jobId: 'j-8f21',
      state: JobState.queued,
    ),
  });

  /// What `POST /api/v1/jobs` answers.
  JobSubmission submission;
  JobFailure? submitFailure;

  /// The answers `GET /api/v1/jobs/{id}` gives, in order. A [JobSnapshot] is
  /// an answer, a `null` entry is a 404, and a [JobFailure] entry is a request
  /// that does not come back at all. The last entry repeats once the queue is
  /// down to it.
  ///
  /// The three are in one queue on purpose: a test about a counter of
  /// *consecutive* failures has to place a success and a failure in an exact
  /// order, and a global switch cannot do that without racing the poll timer.
  final List<Object?> snapshots = <Object?>[];

  /// When set, the snapshot request fails instead of answering.
  JobFailure? snapshotFailure;

  JobSnapshot? cancelReply;
  JobFailure? cancelFailure;

  /// Hold one reply on the wire (T-0202).
  ///
  /// The next request of that kind takes its gate: the answer is decided at
  /// the moment the request is made — what the gateway would have said then —
  /// and handed back only once the test completes the gate. That is the order a
  /// real HTTP reply takes when it is already on its way as contact is declared
  /// lost: asked before, answered after. A gate is taken by exactly one request
  /// and the field goes back to `null`, so a test can see that a request is in
  /// flight, and every later request is answered at once.
  Completer<void>? submitGate;
  Completer<void>? snapshotGate;
  Completer<void>? cancelGate;

  ResultBytes? resultBytes;
  JobFailure? resultFailure;

  int submits = 0;
  int snapshotCalls = 0;
  int cancels = 0;
  int resultFetches = 0;
  final List<String> submittedWorkflows = <String>[];
  final List<Map<String, Object?>> submittedInputs = <Map<String, Object?>>[];

  /// What each submission said about translation. `true` is the absence of an
  /// override, which is what every caller that says nothing sends.
  final List<bool> submittedTranslate = <bool>[];

  @override
  Future<JobSubmission> submit(
    Endpoint endpoint, {
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  }) async {
    submits++;
    submittedWorkflows.add(workflowId);
    submittedInputs.add(inputs);
    submittedTranslate.add(translate);
    final failure = submitFailure;
    final reply = submission;
    final gate = submitGate;
    submitGate = null;
    if (gate != null) await gate.future;
    if (failure != null) throw failure;
    return reply;
  }

  @override
  Future<JobSnapshot?> snapshot(Endpoint endpoint, String jobId) async {
    snapshotCalls++;
    final gate = snapshotGate;
    snapshotGate = null;
    final failure = snapshotFailure;
    if (failure != null) {
      if (gate != null) await gate.future;
      throw failure;
    }
    if (snapshots.isEmpty) {
      // Not a 404 — a test that forgot to say what the gateway answers.
      throw StateError('ScriptedJobsApi has no snapshot to give');
    }
    final next = snapshots.length == 1
        ? snapshots.first
        : snapshots.removeAt(0);
    if (gate != null) await gate.future;
    if (next is JobFailure) throw next;
    return next as JobSnapshot?;
  }

  @override
  Future<JobSnapshot> cancel(Endpoint endpoint, String jobId) async {
    cancels++;
    final gate = cancelGate;
    cancelGate = null;
    final failure = cancelFailure;
    final reply = cancelReply;
    if (gate != null) await gate.future;
    if (failure != null) throw failure;
    if (reply == null) throw StateError('ScriptedJobsApi has no cancel reply');
    return reply;
  }

  @override
  Future<ResultBytes> fetchResult(
    Endpoint endpoint,
    JobResultRef result,
  ) async {
    resultFetches++;
    final failure = resultFailure;
    if (failure != null) throw failure;
    return resultBytes ??
        ResultBytes(
          bytes: tinyPng,
          mediaType: 'image/png',
          filename: resultFilename(result, mediaType: 'image/png'),
        );
  }
}

/// A snapshot, spelled out.
JobSnapshot snapshotOf(
  JobState state, {
  String jobId = 'j-8f21',
  JobProgress? progress,
  List<JobResultRef> results = const <JobResultRef>[],
  String? error,
}) => JobSnapshot(
  jobId: jobId,
  state: state,
  progress: progress,
  results: results,
  errorMessage: error,
);

/// One image output, as the gateway would describe it.
const JobResultRef imageResult = JobResultRef(
  index: 0,
  kind: 'image',
  mediaType: 'image/png',
  path: '/api/v1/jobs/j-8f21/result/0',
);

/// One video output.
const JobResultRef videoResult = JobResultRef(
  index: 0,
  kind: 'video',
  mediaType: 'video/mp4',
  path: '/api/v1/jobs/j-8f21/result/0',
);

/// An event stream the test pushes into, instead of a socket.
class FakeJobEventSource implements JobEventSource {
  FakeJobEventSource({this.failToConnect = false});

  /// Stands for a gateway that advertises events and then will not accept the
  /// socket — the case that has to fall back to the snapshot.
  bool failToConnect;

  int connects = 0;
  final List<FakeJobEventSubscription> opened = <FakeJobEventSubscription>[];

  /// Hold one handshake on the wire (T-0202): the next [connect] takes it,
  /// settles at once whether it will open — [failToConnect] as it stood when it
  /// was asked — and finishes only once the test completes the gate. A socket
  /// handshake started before contact was lost and finishing after it is that
  /// order.
  Completer<void>? connectGate;

  FakeJobEventSubscription get latest => opened.last;

  @override
  Future<JobEventSubscription> connect(Endpoint endpoint, String jobId) async {
    connects++;
    final refuse = failToConnect;
    final gate = connectGate;
    connectGate = null;
    if (gate != null) await gate.future;
    if (refuse) throw const SocketRefused();
    final subscription = FakeJobEventSubscription();
    opened.add(subscription);
    return subscription;
  }
}

/// What a socket that will not open throws. Its type does not matter to the
/// controller, which is the point.
class SocketRefused implements Exception {
  const SocketRefused();
}

class FakeJobEventSubscription implements JobEventSubscription {
  final StreamController<JobEvent> _controller =
      StreamController<JobEvent>.broadcast();

  bool closed = false;

  void emit(JobEvent event) => _controller.add(event);

  /// The socket dropping, as the app sees it.
  void drop() => _controller.close();

  @override
  Stream<JobEvent> get events => _controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

/// Save and Share, recorded rather than performed.
class RecordingResultExporter implements ResultExporter {
  final List<ResultFile> saved = <ResultFile>[];
  final List<ResultFile> shared = <ResultFile>[];

  ExportFailure? saveFailure;
  ExportFailure? shareFailure;

  @override
  Future<void> save(ResultFile file) async {
    final failure = saveFailure;
    if (failure != null) throw failure;
    saved.add(file);
  }

  @override
  Future<void> share(ResultFile file) async {
    final failure = shareFailure;
    if (failure != null) throw failure;
    shared.add(file);
  }
}

/// Clip playback, recorded rather than decoded (T-0211).
///
/// Every clip it was asked to open, every player it made, and whether each of
/// those was disposed — the three facts the surface is responsible for. A test
/// sets [failure] to make this device unable to play.
class RecordingClipPlayback implements ClipPlayback {
  final List<ResultBytes> opened = <ResultBytes>[];
  final List<FakeClipPlayer> players = <FakeClipPlayer>[];

  /// Thrown by [open] instead of making a player.
  ClipPlaybackFailure? failure;

  /// When set, [open] waits for it — so a test can decide what happens on
  /// screen before a player arrives.
  Completer<void>? gate;

  @override
  Future<ClipPlayer> open(ResultBytes clip) async {
    opened.add(clip);
    final pending = gate;
    if (pending != null) await pending.future;
    final refused = failure;
    if (refused != null) throw refused;
    // Neither playing nor muted: the surface is what must make it both, so a
    // fake that arrived that way would certify the surface on its own behalf.
    final player = FakeClipPlayer(clip);
    players.add(player);
    return player;
  }
}

/// A player with no decoder: its state, a frame that is only a keyed box, and
/// a record of being disposed.
class FakeClipPlayer extends ChangeNotifier implements ClipPlayer {
  FakeClipPlayer(this.clip);

  final ResultBytes clip;
  bool playing = false;
  bool muted = false;
  bool disposed = false;

  static const Key frameKey = Key('test.fake-clip-frame');

  @override
  double get aspectRatio => 16 / 9;

  @override
  bool get isPlaying => playing;

  @override
  bool get isMuted => muted;

  void _use() {
    if (disposed) throw StateError('FakeClipPlayer used after dispose');
  }

  @override
  Future<void> play() async {
    _use();
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _use();
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool value) async {
    _use();
    muted = value;
    notifyListeners();
  }

  @override
  Widget buildFrame() {
    _use();
    return const ColoredBox(key: frameKey, color: Color(0xFF203040));
  }

  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    // Recorded, and deliberately not ChangeNotifier's own dispose: a second
    // dispose is a defect to observe as a count, not an assertion to trip.
    disposeCount++;
    disposed = true;
  }

  int disposeCount = 0;
}

/// A session wired from whatever a test hands it.
///
/// The default jobs API answers a submit with a finished job carrying no
/// output. That is the one answer that starts nothing — no socket, no poll
/// timer — so a test that is about the form and not about the lifecycle can
/// press Generate without inheriting a clock.
SessionController testSession({
  required ConnectionController connection,
  required WorkflowsController workflows,
  GenerationController? generation,
  JobsApi? jobs,
  int attempts = SessionController.kReconnectAttempts,
  ReconnectAttemptsStore? attemptsStore,
}) => SessionController(
  connection: connection,
  workflows: workflows,
  generation:
      generation ??
      GenerationController(
        api:
            jobs ??
            ScriptedJobsApi(
              submission: const JobSubmission(
                jobId: 'j-inert',
                state: JobState.completed,
              ),
            ),
      ),
  attempts: attempts,
  backoff: Duration.zero,
  attemptsStore: attemptsStore,
);

/// A real, decodable 1×1 PNG — small enough to inline, valid enough that
/// `Image.memory` decodes it instead of raising.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);
