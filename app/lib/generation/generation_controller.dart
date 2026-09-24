/// One generation, from Generate to a result — and everything that goes wrong
/// on the way (`docs/recovery.md`).
///
/// Flutter's own [ChangeNotifier], like every other piece of state in this app.
///
/// Four rules are enforced here rather than described:
///
/// * **`interrupted` is not progress.** It means contact was lost while a job
///   was in flight and its fate is unknown. [LifecycleState.isProgressing] is
///   false for it, and the interface has no branch that draws it as a running
///   generation.
/// * **No resumption without proof.** The only thing that can put this
///   controller back into [LifecycleState.generating] is a snapshot from
///   `GET /api/v1/jobs/{job_id}` that says `running`. A reachable gateway is
///   not proof, and neither is a timer. A 404 is an answer: the state is gone.
/// * **Progress is the gateway's or it is absent.** [progress] is only ever
///   assigned from a [JobProgress] that was parsed off the wire.
/// * **The socket is an optimization.** Everything works with [events] null or
///   `capabilities.events` false; then the snapshot poll does all of it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/endpoint.dart';
import '../connection/gateway_identity.dart';
import '../l10n/app_localizations.dart';
import 'clip_playback.dart';
import 'job_events.dart';
import 'job_models.dart';
import 'jobs_api.dart';
import 'result_export.dart';
import 'translation.dart';

/// The eleven client states (`docs/recovery.md`).
///
/// Five of them are the server's own, read straight off a snapshot. The other
/// six are connection-flavoured and belong to the client alone.
enum LifecycleState {
  /// No server.
  disconnected,

  /// A first connection attempt is in flight.
  connecting,

  /// Connected, nothing generating.
  ready,

  /// This generation's inputs are still going to the server.
  ///
  /// The bytes of a picture or a clip are uploaded when they are chosen, and
  /// that stretch is drawn at the field itself (`MediaFieldController`); this
  /// is the same client state for the submission that follows.
  uploading,

  /// The gateway has the job and has not started it.
  queued,

  /// The server's `running`. The one place the two vocabularies meet.
  generating,

  completed,
  failed,
  cancelled,

  /// A bounded reconnect is running with nothing in flight.
  reconnecting,

  /// Contact was lost while a job was in flight and its fate is unknown.
  ///
  /// **Never rendered as though generation were progressing.**
  interrupted;

  /// Whether something is actually moving forward. `interrupted` is not.
  bool get isProgressing =>
      this == LifecycleState.uploading ||
      this == LifecycleState.queued ||
      this == LifecycleState.generating;

  /// Whether this is an outcome the user is looking at.
  bool get isOutcome =>
      this == LifecycleState.completed ||
      this == LifecycleState.failed ||
      this == LifecycleState.cancelled;
}

/// What is known about a job whose contact was lost.
enum JobRecovery {
  /// Nothing to recover.
  none,

  /// The snapshot is being asked right now.
  checking,

  /// Contact is still lost, so there is still no answer.
  unknown,

  /// The gateway answered 404: it does not have this job any more.
  lost,
}

/// The sentence for a connection lost mid-generation (`docs/recovery.md`),
/// quoted from the contract word for word.
///
/// The screen draws it as its two halves — [connectionLostTitle] over
/// [checkingSurvivalMessage] — so that the heading is not also the first half
/// of the paragraph under it. `generation_view_test.dart` holds the two halves
/// to this string, so the contract's wording cannot drift out of the app one
/// half at a time.
///
/// **The contract is quoted in English and the app is not always in English**
/// (T-0142). So these are functions of the localisations rather than constants:
/// the `.arb` files hold each half, the English bundle holds the contract's own
/// words unchanged, and this file keeps naming the pieces so the two halves
/// cannot drift apart.
String connectionLostMessage(L l) =>
    '${l.connectionLostTitle} ${l.checkingSurvival}';

/// The first half: the fact, and it stays true either way.
String connectionLostTitle(L l) => l.connectionLostTitle;

/// The second half — drawn **only while a check is actually running**, which
/// is what [GenerationController.isCheckingSurvival] decides.
String checkingSurvivalMessage(L l) => l.checkingSurvival;

/// What replaces it when the bounded reconnect has run out (`docs/recovery.md`:
/// "Every waiting state has a bound and an exit").
///
/// The app has stopped looking, so it stops saying that it is looking. The two
/// decisions named here are on the screen at the same moment, as the buttons of
/// the recovery panel.
String survivalUnknownMessage(L l) => l.survivalUnknown;

/// The sentence for a job the gateway no longer has. Quoted from the contract
/// word for word, because the contract quotes it word for word.
String stateUnrecoverableMessage(L l) => l.stateUnrecoverable;

/// One result this session has shown, addressed the way the gateway addresses
/// it (`docs/api.md`): the **job id**, plus the **index within that job**.
///
/// **Never a position in a list** (T-0178). The history evicts from the front,
/// so a position means a different picture ten generations later, while a job id
/// and an index mean the same bytes for as long as the gateway can serve them.
/// T-0175's review established that the result widget has to be keyed on
/// something that changes per run; this is that same rule one level up, and a
/// history keyed on position would put back exactly what that card ruled out.
///
/// It holds **no bytes**. The gateway serves every result of its current run at
/// `/api/v1/jobs/{job_id}/result/{index}`, so what the app has to keep is the
/// address, and a phone never carries a second copy of a picture.
@immutable
class ResultHistoryEntry {
  const ResultHistoryEntry({required this.jobId, required this.result});

  /// The job the gateway made this for.
  final String jobId;

  /// One output of that job, exactly as the snapshot described it.
  final JobResultRef result;

  /// Whether these two name the same result — the whole of identity, spelled
  /// out rather than left to `==` on a field nobody looks at.
  bool sameAs(ResultHistoryEntry other) =>
      jobId == other.jobId && result.index == other.result.index;

  @override
  String toString() => 'ResultHistoryEntry($jobId#${result.index})';
}

class GenerationController extends ChangeNotifier {
  GenerationController({
    required this.api,
    this.events,
    this.exporter,
    this.clipPlayback,
    this.pollInterval = kPollInterval,
    this.snapshotFailureBudget = kSnapshotFailureBudget,
  });

  /// How often the snapshot is asked when no socket is carrying deltas.
  static const Duration kPollInterval = Duration(milliseconds: 1200);

  /// How many snapshot requests in a row may fail before the app stops
  /// pretending it is still following the job. Bounded, like everything else
  /// that waits (`docs/recovery.md`).
  static const int kSnapshotFailureBudget = 3;

  /// How many results stay reachable behind the one on screen (T-0178).
  ///
  /// **Ten, and the number is a decision rather than "all of them".** What was
  /// asked for is three — "i generated again and again and can see all three
  /// result" — and this is a pair of arrows under a picture, not a grid: nobody
  /// pages back through dozens with two taps, and anybody who wanted to would
  /// be asking for a different feature. Ten leaves a session's worth of
  /// iteration reachable and still reads as a list you step through.
  ///
  /// The cost of raising it is not memory — an entry is a job id and an integer,
  /// so the whole history is a few hundred bytes and no picture is ever held —
  /// it is that the gateway is the only place those bytes live. They survive
  /// for as long as that **process** runs and vanish on its restart, which is
  /// also why this history is session-only and is written nowhere.
  static const int kResultHistoryLimit = 10;

  final JobsApi api;

  /// The event stream, when this build has one. `null` is a legitimate
  /// configuration — the whole lifecycle runs off the snapshot without it.
  final JobEventSource? events;

  /// Save and Share. `null` leaves both affordances absent rather than inert.
  final ResultExporter? exporter;

  /// Plays a clip result (T-0211). `null` draws the "your clip is ready" panel,
  /// and — the reason it lives on this controller rather than only on the
  /// surface — means a clip is never fetched just to be looked at.
  final ClipPlayback? clipPlayback;

  final Duration pollInterval;
  final int snapshotFailureBudget;

  /// Called when contact with the gateway is lost while this controller was
  /// following a job, so that the session can start its bounded reconnect.
  /// Set by the session; nothing here reaches back into the connection.
  VoidCallback? onContactLost;

  Endpoint? _endpoint;
  GatewayCapabilities _capabilities = const GatewayCapabilities();

  LifecycleState _state = LifecycleState.disconnected;
  JobRecovery _recovery = JobRecovery.none;
  bool _reconnecting = false;

  String? _jobId;
  String? _workflowId;
  TranslationReport _translation = TranslationReport.none;
  JobProgress? _progress;
  List<JobResultRef> _results = const <JobResultRef>[];
  /// What went wrong, in one of the three shapes it can arrive in: a failure
  /// this app has a sentence for, the gateway's own words about a job, or the
  /// contracted "state could not be recovered".
  JobFailure? _problemFailure;
  String? _problemServerMessage;
  bool _problemUnrecoverable = false;

  bool _cancelRequested = false;

  ResultBytes? _bytes;
  bool _previewLoading = false;
  JobFailure? _previewFailure;

  /// The results this run of the app has shown, oldest first, capped at
  /// [kResultHistoryLimit].
  ///
  /// **Session-only and device-only.** Nothing here is written to the portable
  /// profile, to preferences, or anywhere else: the ids are only answerable by
  /// the gateway process that issued them, so a history that outlived the app
  /// would hold addresses nobody can serve.
  final List<ResultHistoryEntry> _history = <ResultHistoryEntry>[];

  /// The past result the user chose to go back to, or `null` for the current
  /// job's own — which is what a finished generation always shows.
  ResultHistoryEntry? _viewing;

  /// Result fetches carry their own token, separate from the job's.
  ///
  /// Stepping back through the history changes what is on display without
  /// touching the job, so the job's token cannot invalidate the fetch that is
  /// already in flight — and a reply that arrives after the user has moved on
  /// would paint the previous picture over the current one. That is the defect
  /// `generate_again_result_test.dart` guards at the job level, and this is the
  /// same guard one step in.
  int _previewToken = 0;

  bool _exportBusy = false;
  bool _exportSaved = false;
  ExportFailure? _exportFailure;

  Timer? _pollTimer;
  bool _polling = false;
  /// Snapshot requests that failed **in a row**. Any request that comes
  /// back — including a 404, which is an answer — puts it back to zero,
  /// so the budget below always measures the current loss of contact and
  /// never a total carried over from an earlier one.
  int _snapshotFailures = 0;
  JobEventSubscription? _subscription;
  StreamSubscription<JobEvent>? _listener;

  /// Every job carries the token it started with, so a reply that arrives
  /// after the user pressed Generate Again belongs to nobody and is dropped.
  int _token = 0;

  /// Which stretch of contact a request was asked on (T-0202).
  ///
  /// Losing contact ends one, job or no job (T-0234), and so does marking a job
  /// interrupted for any other reason. A reply that was asked for before that
  /// moment and lands after it describes a contact that is over, so it may not
  /// move this controller anywhere — least of all back to a progressing state
  /// the app has just said it cannot see. Only recovery leaves
  /// [LifecycleState.interrupted], and it asks again rather than believing
  /// something already on the wire.
  ///
  /// Not [_token], for the same kind of reason [_previewToken] is not: the job
  /// is not over. A submit reply that lands late still carries the id recovery
  /// will ask about (`docs/recovery.md` records it the moment it arrives), and
  /// a cancel that has had its answer is no longer outstanding. Invalidating
  /// the job would drop both.
  int _contactToken = 0;

  bool _disposed = false;

  LifecycleState get state => _state;

  /// What is known about an interrupted job's fate.
  JobRecovery get recovery => _recovery;

  /// A bounded reconnect is running. Drawn as a subtle indicator that does not
  /// replace whatever is on screen (`docs/recovery.md`).
  bool get isReconnecting => _reconnecting;

  /// Whether the app is, right now, finding out what became of an interrupted
  /// job: the bounded reconnect is running, or the snapshot request is in
  /// flight.
  ///
  /// This is **derived, never stored**, and that is the whole point. The
  /// "Checking whether the generation survived." sentence is drawn from this
  /// and from nothing else, so it cannot outlive the check it describes — the
  /// defect it replaces was a stored message that stayed on screen after the
  /// three attempts had run out and the app had stopped looking.
  ///
  /// `lost` is excluded because a 404 is an answer: there is nothing left to
  /// check, and the screen says so in different words.
  bool get isCheckingSurvival =>
      _state == LifecycleState.interrupted &&
      _recovery != JobRecovery.lost &&
      (_reconnecting || _recovery == JobRecovery.checking);

  /// The id the gateway gave this generation, recorded the moment the submit
  /// response arrived. It is the only thing that makes recovery possible.
  String? get jobId => _jobId;

  String? get workflowId => _workflowId;

  /// What the gateway did to the text of the generation on screen
  /// (`docs/api.md`).
  ///
  /// It is held *beside* the job, not written back into anything: the form
  /// keeps the user's own words, and this is a record of what was sent for one
  /// run. It is cleared with the job, so an indicator can never outlive the
  /// generation it describes.
  TranslationReport get translation => _translation;

  /// Real progress, or `null` for honestly indeterminate. Never a guess.
  JobProgress? get progress => _progress;

  List<JobResultRef> get results => _results;

  /// The first result — the one the surface makes the hero.
  JobResultRef? get primaryResult =>
      _results.isEmpty ? null : _results.first;

  bool get hasResult =>
      _state == LifecycleState.completed && _results.isNotEmpty;

  // --------------------------------------------------- the way back (T-0178)

  /// Every result this run has shown, oldest first. A copy, so nothing outside
  /// can evict from it.
  List<ResultHistoryEntry> get resultHistory =>
      List<ResultHistoryEntry>.unmodifiable(_history);

  /// The past result the user stepped back to, or `null` when what is on screen
  /// is the current job's own.
  ResultHistoryEntry? get viewedResult => _viewing;

  /// The result whose bytes are on display.
  ///
  /// `null` for the chosen entry is not a gap: it is the ordinary case, where
  /// the current job's [primaryResult] is what is drawn, unchanged from before
  /// this history existed.
  JobResultRef? get displayedResult => _viewing?.result ?? primaryResult;

  /// Where the result on display sits in [resultHistory], counting from the
  /// oldest kept. `null` when there is no history to be anywhere in.
  int? get viewedPosition {
    if (_history.isEmpty) return null;
    final chosen = _viewing;
    if (chosen == null) return _history.length - 1;
    final at = _history.indexWhere((entry) => entry.sameAs(chosen));
    return at < 0 ? null : at;
  }

  bool get canShowPreviousResult => (viewedPosition ?? 0) > 0;

  bool get canShowNextResult {
    final at = viewedPosition;
    return at != null && at < _history.length - 1;
  }

  /// One step back towards the oldest result still kept.
  void showPreviousResult() {
    final at = viewedPosition;
    if (at == null || at <= 0) return;
    showResult(_history[at - 1]);
  }

  /// One step forward towards the newest.
  void showNextResult() {
    final at = viewedPosition;
    if (at == null || at >= _history.length - 1) return;
    showResult(_history[at + 1]);
  }

  /// Puts one remembered result on screen.
  ///
  /// The entry is found **by identity** — job id and index — and not by where it
  /// happens to sit. An entry that has fallen off the end of the history is
  /// gone, and this does nothing rather than quietly showing whatever now
  /// occupies the place it used to have.
  void showResult(ResultHistoryEntry entry) {
    final at = _history.indexWhere((held) => held.sameAs(entry));
    if (at < 0) return;
    if (at == viewedPosition) return;
    _viewing = _history[at];
    // A different picture, so what is in [_bytes] is not this one's, and the
    // fetch that put it there must not be allowed to answer into this one.
    _previewToken++;
    _bytes = null;
    _previewLoading = false;
    _previewFailure = null;
    _notify();
    _maybeLoadPreview();
  }

  /// Remembers the result now on screen, if it is not already the newest kept.
  ///
  /// Called wherever a job can become [LifecycleState.completed] with an
  /// output. It deliberately does **not** touch what is being looked at, and
  /// that is not an omission: every new run arrives through [submit], and the
  /// [_clearJob] there is the one place that puts the display back on the
  /// current job. So "a generation that finishes is what you are shown" holds
  /// even for somebody who was three results back when they pressed Generate,
  /// and it holds in one place rather than two that could disagree.
  ///
  /// Recording it here a second time would be a line no test could ever kill.
  void _recordResult() {
    if (!hasResult) return;
    final jobId = _jobId;
    final result = primaryResult;
    if (jobId == null || result == null) return;
    final entry = ResultHistoryEntry(jobId: jobId, result: result);
    if (_history.isNotEmpty && _history.last.sameAs(entry)) return;
    _history.add(entry);
    // Bounded, from the front: the oldest is what a person stops wanting first.
    while (_history.length > kResultHistoryLimit) {
      _history.removeAt(0);
    }
  }

  /// The title and sentence of whatever went wrong, in the language on screen.
  ///
  /// Both take the localisations rather than answering from a stored sentence:
  /// a problem recorded before the user changed the language would otherwise
  /// still be on screen in the old one (T-0142).
  ///
  /// The title is `null` where the app has no title of its own — the gateway's
  /// account of a failed job is a message and not a heading, exactly as it was
  /// before.
  String? problemTitle(L l) => _problemFailure?.title(l);

  String? problemMessage(L l) {
    final failure = _problemFailure;
    if (failure != null) return failure.message(l);
    if (_problemServerMessage != null) return _problemServerMessage;
    return _problemUnrecoverable ? stateUnrecoverableMessage(l) : null;
  }

  /// A cancel has been asked for and not yet answered. A request, never an
  /// outcome (`docs/recovery.md`).
  bool get isCancelling => _cancelRequested;

  /// Cancel is offered only where the gateway advertises it, and only while
  /// there is something to cancel. Where it is unsupported the affordance is
  /// absent rather than present and inert.
  bool get canCancel =>
      _capabilities.cancel &&
      _jobId != null &&
      !_cancelRequested &&
      (_state == LifecycleState.queued || _state == LifecycleState.generating);

  /// The bytes of the result on display, once they are here.
  ResultBytes? get resultBytes => _bytes;
  bool get isLoadingPreview => _previewLoading;

  /// Whether the preview could not be fetched. The sentence is [previewProblem].
  bool get hasPreviewProblem => _previewFailure != null;

  /// Why the preview could not be fetched, in one sentence.
  String? previewProblem(L l) => _previewFailure?.message(l);

  /// Whether Save and Share can be offered at all.
  bool get canExport => exporter != null && hasResult;
  bool get isExporting => _exportBusy;

  /// Whether the last export was a save that worked, and so has a short
  /// confirmation to draw. Cleared once read.
  ///
  /// A flag rather than a sentence, for the reason every other one of these
  /// became a flag: the words belong to whichever language is on screen when
  /// they are drawn, not to the moment the save finished (T-0142).
  bool get exportSaved => _exportSaved;
  ExportFailure? get exportFailure => _exportFailure;

  /// The server this controller is talking to, once there is one.
  Endpoint? get endpoint => _endpoint;

  GatewayCapabilities get capabilities => _capabilities;

  // ---------------------------------------------------------------- session

  /// The connection reached a gateway.
  ///
  /// A different endpoint clears the job and the result: they belong to the
  /// server that produced them, and no other server knows the id.
  void attach({
    required Endpoint endpoint,
    required GatewayCapabilities capabilities,
  }) {
    final moved = _endpoint != null && _endpoint != endpoint;
    _endpoint = endpoint;
    _capabilities = capabilities;
    if (moved) {
      _stopFollowing();
      _clearJob();
      // Including a result that was on screen: it came from the server we
      // just left, and this one has never heard of it.
      //
      // And including every result kept behind it. A job id is only meaningful
      // to the gateway that issued it, so carrying the history across a move
      // would leave addresses this server would answer for something else or
      // not at all (T-0178).
      _history.clear();
      _state = LifecycleState.ready;
    }
    if (_state == LifecycleState.disconnected ||
        _state == LifecycleState.connecting ||
        _state == LifecycleState.reconnecting) {
      _state = LifecycleState.ready;
    }
    _notify();
  }

  /// The first connection attempt is in flight.
  void markConnecting() {
    if (_state == LifecycleState.disconnected) {
      _state = LifecycleState.connecting;
      _notify();
    }
  }

  /// Contact with the gateway is gone.
  ///
  /// A job in flight becomes [LifecycleState.interrupted] — we do not know its
  /// fate, and we say so. Anything else simply becomes disconnected; a result
  /// already on screen stays on screen.
  void connectionLost() {
    _stopFollowing();
    // Stopping the poll timer and the socket stops what has not been asked
    // yet. What has — a snapshot, a submit, a cancel, a handshake, a recovery —
    // is disowned here, whether or not a job was running (T-0234): a recovery
    // asked over an interrupted job is still on the wire when the user leaves
    // for another server, and its "running" may not start following a job on
    // the one they left. A request asked after this line reads the new token,
    // so nothing asked later is disowned by it.
    _contactToken++;
    if (_state.isProgressing) {
      _state = LifecycleState.interrupted;
      _recovery = JobRecovery.unknown;
      // Deliberately no stored sentence. What the panel says about an
      // interrupted job is composed from [isCheckingSurvival] at draw time,
      // because a sentence written down here is a sentence that keeps being
      // true after the situation it described has ended.
      _clearProblem();
    } else if (!_state.isOutcome) {
      _state = LifecycleState.disconnected;
    }
    _notify();
  }

  /// A bounded reconnect has started. It never blanks the screen: a shown
  /// result stays, and an interrupted job stays interrupted.
  void beginReconnect() {
    _reconnecting = true;
    if (_state == LifecycleState.disconnected ||
        _state == LifecycleState.ready) {
      _state = LifecycleState.reconnecting;
    }
    _notify();
  }

  /// The reconnect finished, one way or the other.
  void endReconnect({required bool connected}) {
    _reconnecting = false;
    if (_state == LifecycleState.reconnecting) {
      _state = connected
          ? LifecycleState.ready
          : LifecycleState.disconnected;
    }
    _notify();
  }

  // ------------------------------------------------------------- generation

  /// `POST /api/v1/jobs` with the map the form produced.
  ///
  /// [translate] false carries the submission's own translation override
  /// (`docs/api.md`). It is passed straight through and kept nowhere: the
  /// choice belongs to the form the submission came from, and this controller
  /// holds one job, not a preference.
  ///
  /// **A submission while one is progressing is refused**, because this
  /// controller holds one job and starting a second would abandon the first
  /// with no way to get back to it. The refusal changes nothing and says
  /// nothing, and that is deliberate: the interface makes Generate unavailable
  /// for exactly [LifecycleState.isProgressing], so there is no tap for this
  /// line to answer (T-0182). It is the last line of defence behind that, not
  /// the place the user is told anything — a sentence recorded here would be a
  /// sentence about a tap that cannot happen.
  Future<void> submit({
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  }) async {
    final endpoint = _endpoint;
    if (endpoint == null || _state.isProgressing) return;

    _stopFollowing();
    // Clearing is what invalidates the previous job's token, so this one is
    // read afterwards — read first, it would be stale before the first await.
    _clearJob();
    final token = _token;
    final contact = _contactToken;
    _workflowId = workflowId;
    _state = LifecycleState.uploading;
    _notify();

    final JobSubmission submission;
    try {
      submission = await api.submit(
        endpoint,
        workflowId: workflowId,
        inputs: inputs,
        translate: translate,
      );
    } on JobFailure catch (failure) {
      // A failure about a contact that is over is disowned too (T-0228). Most
      // often it is a timeout, and a timeout does not prove the gateway
      // created nothing — so `failed` would claim more than is known, and the
      // interrupted job stays what it was declared.
      if (_disposed || token != _token || contact != _contactToken) return;
      // Nothing was created, so there is no id and nothing to recover. The
      // attempt failed, and the gateway's own sentence says why.
      _state = LifecycleState.failed;
      _clearProblem();
      _problemFailure = failure;
      _notify();
      return;
    }
    if (_disposed || token != _token) return;

    // Recorded before anything else can go wrong. This is the line
    // `docs/recovery.md` calls the only thing that makes recovery possible.
    _jobId = submission.jobId;
    // Recorded, never applied: what the gateway bound for this run is shown on
    // request and is not written back into the form the submission came from.
    _translation = submission.translation;
    if (contact != _contactToken) {
      // Contact was lost while this was on the wire. The id is kept for the
      // recovery that will ask about it; the state it reports is not taken.
      //
      // The job is adopted as interrupted rather than disowned (T-0228). The
      // gateway really has it, and a recovery that already ran while the id
      // was still missing has moved this controller to `ready`, where nothing
      // would ever ask about it again: a generation the user cannot see.
      // Interrupted shows the recovery panel, and the user's recovery reads
      // the real state. Over a job still interrupted this changes nothing.
      //
      // Nothing else is reset, because nothing else can be set: until this
      // line the job had no id, so no poll, cancel or handshake was ever asked
      // for it, and `connectionLost()` already cleared the problem.
      _state = LifecycleState.interrupted;
      _recovery = JobRecovery.unknown;
      _notify();
      return;
    }
    _applyServerState(submission.state);
    _notify();
    _follow();
  }

  /// `POST /api/v1/jobs/{job_id}/cancel`.
  ///
  /// The state shown afterwards is whatever the gateway says the job actually
  /// reached — a job that finished first is completed, with its result.
  Future<void> cancel() async {
    final endpoint = _endpoint;
    final jobId = _jobId;
    if (endpoint == null || jobId == null || !canCancel) return;

    final token = _token;
    final contact = _contactToken;
    _cancelRequested = true;
    _notify();

    final JobSnapshot snapshot;
    try {
      snapshot = await api.cancel(endpoint, jobId);
    } on JobFailure catch (failure) {
      if (_disposed || token != _token) return;
      _cancelRequested = false;
      if (contact != _contactToken) {
        // Answered, so no longer outstanding — but about a contact that is
        // over, and `connectionLost()` left the interrupted job without a
        // sentence on purpose (T-0228).
        _notify();
        return;
      }
      // The request did not land. The job is whatever it was; nothing about
      // its state is asserted here.
      _clearProblem();
      _problemFailure = failure;
      _notify();
      return;
    }
    if (_disposed || token != _token) return;
    _cancelRequested = false;
    if (contact != _contactToken) {
      // Answered, so no longer outstanding — but about a contact that is over.
      _notify();
      return;
    }
    // The reply is the full snapshot, not a bare state (`docs/api.md`), so a
    // job that finished before the interrupt landed hands back its results in
    // this same call and there is no follow-up request to make.
    _apply(snapshot);
  }

  /// Back to the form with everything still in it. The inputs live in the
  /// workflow form and are never touched from here.
  void generateAgain() {
    _stopFollowing();
    _clearJob();
    if (_endpoint != null) _state = LifecycleState.ready;
    _notify();
  }

  /// Job recovery (`docs/recovery.md`): ask the gateway what became of the
  /// job, and believe only the answer.
  ///
  /// Called as the last step of a successful reconnect, and whenever the
  /// connection arrives at a gateway after [attach] (T-0238) — the road back to
  /// the same server through the connect screen is a reconnect too. Every path
  /// out of here either has a snapshot behind it or says that it does not.
  Future<void> recoverJob() async {
    final endpoint = _endpoint;
    final jobId = _jobId;
    if (endpoint == null) return;
    if (jobId == null) {
      if (_state == LifecycleState.interrupted ||
          _state == LifecycleState.disconnected) {
        _state = LifecycleState.ready;
        _recovery = JobRecovery.none;
        _notify();
      }
      return;
    }
    // A job that already finished keeps the outcome it finished with; there is
    // nothing to recover and its result stays on screen.
    if (_state.isOutcome) return;

    final token = _token;
    // The contact this recovery is asked on (T-0233). Over an interrupted job
    // that is the contact current now, so the reply is believed: that is how a
    // job leaves interrupted.
    final contact = _contactToken;
    _recovery = JobRecovery.checking;
    _notify();

    final JobSnapshot? snapshot;
    try {
      snapshot = await api.snapshot(endpoint, jobId);
    } on JobFailure {
      if (_disposed || token != _token) return;
      if (_outlived(contact)) return;
      // Still no proof of anything. Staying interrupted is the honest answer,
      // and the check is over: `unknown` is what stops the panel claiming one
      // is still running.
      //
      // And this marks a job interrupted like any other place does. Recovery is
      // not only asked over an interrupted job: the recovery panel's Reconnect
      // stays pressable over a job started after the automatic reconnect ran
      // out, whose poll can be on the wire right now (T-0202).
      _contactToken++;
      _state = LifecycleState.interrupted;
      _recovery = JobRecovery.unknown;
      _clearProblem();
      _notify();
      return;
    }
    if (_disposed || token != _token) return;
    if (_outlived(contact)) return;

    // The request came back, whatever it said, so whatever contact was lost
    // has been found again. Without this the budget a poll loop already spent
    // is still spent, and the first failure after a successful reconnect would
    // declare contact lost instead of the third.
    _snapshotFailures = 0;

    if (snapshot == null) {
      _onJobGone();
      return;
    }
    _apply(snapshot);
    if (_state.isProgressing) _follow();
  }

  /// Whether a recovery reply, asked on [contact], describes a job that has
  /// moved on without it (T-0233) — answer and failure alike.
  ///
  /// Contact lost since it was asked: whatever the reply says is about a
  /// contact that is over, and whoever ended it has already said what is known
  /// ([connectionLost], a 404, another recovery's failure).
  ///
  /// An outcome reached by another path while it was out — a cancel reply, the
  /// socket, a second recovery: recovery never starts over an outcome, so one
  /// found here arrived after the ask, and a late "running" or a late failure
  /// may not overwrite what the job actually finished as.
  ///
  /// Nothing is reset when it is disowned. Every path above that leaves the job
  /// interrupted has already moved [recovery] off `checking`, and the one that
  /// does not — contact lost over an interrupted job, which becomes
  /// disconnected (T-0234) — is not interrupted, so no check is claimed for it;
  /// the next recovery sets [recovery] again.
  bool _outlived(int contact) =>
      contact != _contactToken || _state.isOutcome;

  // ------------------------------------------------------------ the result

  /// Puts the result in the device's gallery.
  Future<void> saveResult() => _export(save: true);

  /// Hands the result to Android's share sheet.
  Future<void> shareResult() => _export(save: false);

  /// Clears the one-line confirmation once the interface has shown it.
  void clearExportNotice() {
    if (!_exportSaved && _exportFailure == null) return;
    _exportSaved = false;
    _exportFailure = null;
    _notify();
  }

  /// Fetches the result on display so it can be shown, and nothing else.
  ///
  /// A picture always. A clip only when this build has a [clipPlayback] to play
  /// it with (T-0211): without one, pulling a video into memory would be a
  /// download with no purpose, and Save and Share fetch it when the user asks.
  void _maybeLoadPreview() {
    if (!hasResult) return;
    final result = displayedResult;
    if (result == null) return;
    final playable = result.isVideo && clipPlayback != null;
    if (!result.isImage && !playable) return;
    unawaited(loadPreview());
  }

  /// Fetches the bytes of the result on display, if they are not here yet.
  ///
  /// "On display" is [displayedResult] — the past result the user stepped back
  /// to, or the current job's own. A result the gateway can no longer serve
  /// leaves [previewProblem] rather than a blank the surface would draw as
  /// though it were a picture.
  Future<void> loadPreview() async {
    final endpoint = _endpoint;
    final result = displayedResult;
    if (endpoint == null || result == null) return;
    if (_bytes != null || _previewLoading) return;
    final token = _previewToken;
    _previewLoading = true;
    _previewFailure = null;
    _notify();
    try {
      final bytes = await api.fetchResult(endpoint, result);
      if (_disposed || token != _previewToken) return;
      _bytes = bytes;
    } on JobFailure catch (failure) {
      if (_disposed || token != _previewToken) return;
      _previewFailure = failure;
    }
    if (_disposed || token != _previewToken) return;
    _previewLoading = false;
    _notify();
  }

  Future<void> _export({required bool save}) async {
    final exporter = this.exporter;
    if (exporter == null || _exportBusy || !hasResult) return;
    final token = _token;
    _exportBusy = true;
    _exportSaved = false;
    _exportFailure = null;
    _notify();

    if (_bytes == null) await loadPreview();
    if (_disposed || token != _token) return;
    final bytes = _bytes;
    if (bytes == null) {
      _exportBusy = false;
      _exportFailure = const ExportFailure.failed();
      _notify();
      return;
    }

    final file = ResultFile(
      bytes: bytes.bytes,
      filename: bytes.filename,
      mediaType: bytes.mediaType,
    );
    try {
      if (save) {
        await exporter.save(file);
      } else {
        await exporter.share(file);
      }
      if (_disposed || token != _token) return;
      // Share hands off to another app and never claims what it did with the
      // file; only Save has an outcome worth confirming.
      if (save) _exportSaved = true;
    } on ExportFailure catch (failure) {
      if (_disposed || token != _token) return;
      _exportFailure = failure;
    }
    if (_disposed || token != _token) return;
    _exportBusy = false;
    _notify();
  }

  // ------------------------------------------------------------- following

  /// Follows the job: the socket where there is one, the snapshot otherwise.
  void _follow() {
    _stopFollowing();
    final endpoint = _endpoint;
    final jobId = _jobId;
    if (endpoint == null || jobId == null || !_state.isProgressing) return;

    final source = events;
    if (!_capabilities.events || source == null) {
      _startPolling();
      return;
    }

    final token = _token;
    final contact = _contactToken;
    source
        .connect(endpoint, jobId)
        .then((subscription) {
          // A handshake asked for before contact was lost can finish after a
          // recovery has opened a socket of its own. Taking it would leave
          // that one listening with nothing left to close it.
          if (_disposed ||
              token != _token ||
              contact != _contactToken ||
              !_state.isProgressing) {
            unawaited(subscription.close());
            return;
          }
          _subscription = subscription;
          _listener = subscription.events.listen(
            (event) {
              if (token != _token) return;
              _applyEvent(event);
            },
            onError: (Object _) => _socketLost(token),
            onDone: () => _socketLost(token),
            cancelOnError: true,
          );
        })
        .catchError((Object _) {
          // A socket that will not open is not a failure the user hears
          // about. It only means the snapshot does the work.
          //
          // Unless it was asked for before contact was lost (T-0228): by the
          // time it fails, a recovery may have opened a socket of its own, and
          // a poll started here would be a second follower beside it.
          if (_disposed || token != _token || contact != _contactToken) return;
          _startPolling();
        });
  }

  void _socketLost(int token) {
    if (_disposed || token != _token) return;
    _closeSocket();
    if (!_state.isProgressing) return;
    // Truth is re-established from the snapshot, never from replayed events.
    _startPolling();
  }

  void _startPolling() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(_pollOnce()));
    unawaited(_pollOnce());
  }

  Future<void> _pollOnce() async {
    final endpoint = _endpoint;
    final jobId = _jobId;
    if (endpoint == null || jobId == null || _polling) return;
    if (!_state.isProgressing) return;
    final token = _token;
    final contact = _contactToken;
    _polling = true;
    try {
      final snapshot = await api.snapshot(endpoint, jobId);
      // Asked before the job was marked interrupted, answered after: neither
      // an answer nor a failure about a contact that is over counts (T-0202).
      if (_disposed || token != _token || contact != _contactToken) return;
      _snapshotFailures = 0;
      if (snapshot == null) {
        _onJobGone();
        return;
      }
      _apply(snapshot);
    } on JobFailure {
      if (_disposed || token != _token || contact != _contactToken) return;
      _snapshotFailures++;
      if (_snapshotFailures >= snapshotFailureBudget) _onContactLost();
    } finally {
      _polling = false;
    }
  }

  /// The gateway answered 404. It does not have this job, and no amount of
  /// asking again will change that.
  void _onJobGone() {
    _stopFollowing();
    // Interrupted is interrupted: a cancel reply still on the wire must not
    // report a job the gateway has just said it does not have.
    _contactToken++;
    _state = LifecycleState.interrupted;
    _recovery = JobRecovery.lost;
    _clearProblem();
    _problemUnrecoverable = true;
    _notify();
  }

  /// The snapshot stopped answering. Bounded, so this is where the waiting
  /// ends rather than a loop that never does.
  void _onContactLost() {
    connectionLost();
    onContactLost?.call();
  }

  void _applyEvent(JobEvent event) {
    switch (event) {
      case JobStateEvent(:final state):
        _applyServerState(state);
        if (!_state.isProgressing) _stopFollowing();
        if (_state == LifecycleState.completed && _results.isEmpty) {
          // Completed with no outputs seen yet: the snapshot has them.
          unawaited(_refreshOnce());
        }
        _recordResult();
        _maybeLoadPreview();
      case JobProgressEvent(:final progress):
        _progress = progress;
      case JobResultsEvent(:final results):
        if (results.isNotEmpty) _results = results;
        _recordResult();
        _maybeLoadPreview();
      case JobErrorEvent(:final message):
        _clearProblem();
        _problemServerMessage = message;
    }
    _notify();
  }

  /// One snapshot outside the poll loop, for the case where an event told us
  /// something is finished but not what came out of it.
  ///
  /// The gateway sends the result delta before the `state` that commits it, so
  /// this should not be needed. It stays because the alternative is asserting
  /// "finished, with no output" on the strength of a socket, and the snapshot
  /// is the source of truth about that (`docs/api.md`).
  Future<void> _refreshOnce() async {
    final endpoint = _endpoint;
    final jobId = _jobId;
    if (endpoint == null || jobId == null) return;
    final token = _token;
    try {
      final snapshot = await api.snapshot(endpoint, jobId);
      if (_disposed || token != _token) return;
      _snapshotFailures = 0;
      if (snapshot == null) return;
      _apply(snapshot);
    } on JobFailure {
      // The outcome is already known; only the outputs are missing, and the
      // surface says so rather than inventing one.
    }
  }

  void _apply(JobSnapshot snapshot) {
    // Straight off the wire, including its absence: a gateway that stopped
    // reporting progress makes the bar indeterminate again rather than
    // freezing it at the last number.
    _progress = snapshot.progress;
    if (snapshot.results.isNotEmpty) _results = snapshot.results;
    if (snapshot.errorMessage != null) {
      _clearProblem();
      _problemServerMessage = snapshot.errorMessage;
    }
    _applyServerState(snapshot.state);
    if (!_state.isProgressing) _stopFollowing();
    _recordResult();
    _maybeLoadPreview();
    _notify();
  }

  void _applyServerState(JobState state) {
    _recovery = JobRecovery.none;
    switch (state) {
      case JobState.queued:
        _state = LifecycleState.queued;
      case JobState.running:
        _state = LifecycleState.generating;
      case JobState.completed:
        _state = LifecycleState.completed;
        _progress = null;
      case JobState.failed:
        _state = LifecycleState.failed;
        _progress = null;
      case JobState.cancelled:
        _state = LifecycleState.cancelled;
        _progress = null;
    }
  }

  void _clearJob() {
    _token++;
    // And the fetch of whatever was on display: the picture goes with the job,
    // so a download still in flight for it belongs to nobody.
    _previewToken++;
    // The *history* is not cleared — that is the whole of T-0178 — but what is
    // being looked at is. This is the one line that makes a finished generation
    // what the user is shown: a person who was three results back when they
    // pressed Generate is brought forward to the run they just started.
    _viewing = null;
    _jobId = null;
    _workflowId = null;
    _translation = TranslationReport.none;
    _progress = null;
    _results = const <JobResultRef>[];
    _clearProblem();
    _recovery = JobRecovery.none;
    _cancelRequested = false;
    _bytes = null;
    _previewLoading = false;
    _previewFailure = null;
    _exportBusy = false;
    _exportSaved = false;
    _exportFailure = null;
    _snapshotFailures = 0;
  }

  void _stopFollowing() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _closeSocket();
  }

  void _closeSocket() {
    _listener?.cancel();
    _listener = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.close());
  }

  /// Forgets whatever went wrong, all three shapes of it at once.
  ///
  /// One place, so that a new problem can never be recorded on top of the
  /// remains of an older one of a different shape — a stored gateway sentence
  /// left standing under a fresh [JobFailure], say.
  void _clearProblem() {
    _problemFailure = null;
    _problemServerMessage = null;
    _problemUnrecoverable = false;
  }

  void _notify() {
    _forgetAViewNoLongerKept();
    if (!_disposed) notifyListeners();
  }

  /// What is being looked at has to be in the history it is labelled against
  /// (T-0204).
  ///
  /// A [_viewing] whose entry [_history] no longer holds leaves
  /// [viewedPosition] nothing to count, so the history row labels the newest
  /// — while [displayedResult] and the bytes fetched for it go on drawing the
  /// evicted one: one result shown, another claimed. Today it cannot happen:
  /// the only eviction is in [_recordResult], and every way there passes
  /// [_clearJob] first. This keeps that true where the disagreement would be
  /// seen rather than by that ordering — checked before every notification, so
  /// no listener reads the two apart, and an eviction added anywhere later
  /// needs to know nothing about it. The newest is then what is shown, and
  /// what is labelled.
  void _forgetAViewNoLongerKept() {
    final chosen = _viewing;
    if (_disposed || chosen == null) return;
    if (_history.any((held) => held.sameAs(chosen))) return;
    _viewing = null;
    // A different picture, for the reason [showResult] gives.
    _previewToken++;
    _bytes = null;
    _previewLoading = false;
    _previewFailure = null;
    _maybeLoadPreview();
  }

  /// Takes the oldest result out of the history the way a second eviction
  /// site would — without passing through [_clearJob] — so a test can reach
  /// the state [_forgetAViewNoLongerKept] defends. Nothing in the app calls it.
  @visibleForTesting
  void debugEvictOldestResult() {
    if (_history.isEmpty) return;
    _history.removeAt(0);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopFollowing();
    super.dispose();
  }
}
