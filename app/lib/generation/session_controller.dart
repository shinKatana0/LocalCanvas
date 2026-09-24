/// The connected session: one connection, one registry, one generation, and
/// the bounded reconnect that ties them together (`docs/recovery.md`).
///
/// It exists because reconnect is not any one of those three objects' job. The
/// contract names six steps in an order, and the order spans all of them:
///
/// 1. retry the endpoint;
/// 2. verify LocalCanvas identity;
/// 3. verify API compatibility;
/// 4. verify ComfyUI readiness;
/// 5. refresh the workflow registry;
/// 6. restore editable UI state.
///
/// Steps 1–3 are one HTTP request — the handshake — and which of them a
/// failure stopped at is read off the outcome, so [lastSteps] records what
/// actually happened rather than a hopeful script.
///
/// Two rules are enforced here rather than described:
///
/// * **Nothing retries forever.** [attempts] is a small, bounded number, and
///   running out of it produces [failure] — a screen with two real decisions
///   on it, not a spinner.
/// * **Reconnecting never blanks the screen.** The connection stays in its
///   connected phase throughout, so a displayed result stays displayed; the
///   indicator is a line, and the recovery choices are a panel.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_problem.dart';
import '../connection/gateway_client.dart';
import '../connection/reconnect_attempts_store.dart';
import '../workflows/workflows_controller.dart';
import 'generation_controller.dart';

/// The six steps of a successful reconnect, in the contract's order.
enum ReconnectStep {
  retryEndpoint,
  verifyIdentity,
  verifyApiVersion,
  verifyComfyReadiness,
  refreshRegistry,
  restoreState,
}

class SessionController extends ChangeNotifier {
  SessionController({
    required this.connection,
    required this.workflows,
    required this.generation,
    this._attempts = kReconnectAttempts,
    this.backoff = kReconnectBackoff,
    ReconnectAttemptsStore? attemptsStore,
  }) : _attemptsStore = attemptsStore {
    connection.addListener(_onConnectionChanged);
    // Losing the gateway mid-job is what starts a reconnect; the generation
    // controller notices it and never reaches into the connection itself.
    generation.onContactLost = _onContactLost;
    _onConnectionChanged();
    final store = attemptsStore;
    if (store != null) unawaited(_restoreAttempts(store));
  }

  /// A handful of attempts over a few seconds, exactly as `docs/recovery.md`
  /// puts it — and then a decision for the user. The count a device uses until
  /// its owner chooses another (T-0212).
  static const int kReconnectAttempts = 3;

  /// The gap before the second attempt; the third waits twice as long. Short,
  /// because the whole sequence has to stay inside a few seconds.
  static const Duration kReconnectBackoff = Duration(milliseconds: 400);

  final ConnectionController connection;
  final WorkflowsController workflows;
  final GenerationController generation;
  final Duration backoff;

  int _attempts;
  final ReconnectAttemptsStore? _attemptsStore;

  /// Whether the user's own choice has landed. A remembered count arriving
  /// after it must not overwrite what was just chosen.
  bool _attemptsChosen = false;

  bool _running = false;

  /// Which reconnect is the current one (T-0243). A run holds the value it
  /// started with; Choose another server moves it on, and a run whose value is
  /// no longer current stops at its next step having done nothing more.
  int _reconnectToken = 0;

  int _attemptsMade = 0;
  ConnectionNotice? _failure;
  final List<ReconnectStep> _steps = <ReconnectStep>[];

  /// The connection phase the generation was last told about, so that arriving
  /// at a gateway can be told apart from staying at one (T-0238).
  ConnectionPhase? _attachedPhase;

  bool _disposed = false;

  /// A bounded reconnect is running.
  bool get isReconnecting => _running;

  /// How many endpoint attempts the next reconnect will make. Always inside
  /// [kMinReconnectAttempts]..[kMaxReconnectAttempts] once it has been chosen
  /// or restored; a test may construct a session with any count it likes.
  int get attempts => _attempts;

  /// Whether this build can remember a chosen count. Without a store there is
  /// nothing to choose with, and the server block draws no stepper.
  bool get canChooseAttempts => _attemptsStore != null;

  /// The person chose a count (`docs/recovery.md`). It applies from the next
  /// reconnect; one already running keeps the count it started with.
  ///
  /// A count outside the bound is refused, not clamped — the stepper cannot
  /// produce one, so arriving here with one is a defect to hear about.
  Future<void> chooseAttempts(int count) async {
    final store = _attemptsStore;
    if (store == null) return;
    if (!isAllowedReconnectAttempts(count)) {
      throw RangeError.range(
        count,
        kMinReconnectAttempts,
        kMaxReconnectAttempts,
        'count',
      );
    }
    _attemptsChosen = true;
    if (count == _attempts) return;
    _attempts = count;
    _notify();
    try {
      await store.save(count);
    } catch (_) {
      // Not remembered, but still in force for this run of the app. Nothing on
      // screen could act on the failure, and the number shown is the number
      // used.
    }
  }

  Future<void> _restoreAttempts(ReconnectAttemptsStore store) async {
    final int? stored;
    try {
      stored = await store.load();
    } catch (_) {
      return;
    }
    if (_disposed || _attemptsChosen || stored == null) return;
    if (!isAllowedReconnectAttempts(stored) || stored == _attempts) return;
    _attempts = stored;
    _notify();
  }

  /// How many endpoint attempts the last reconnect used. Never more than the
  /// [attempts] it started with.
  int get attemptsMade => _attemptsMade;

  /// Why the last reconnect gave up, in the words the user reads. Non-null is
  /// the explicit recovery surface: Reconnect, and Choose another server.
  ConnectionNotice? get failure => _failure;

  /// The steps the last reconnect actually performed, in order.
  List<ReconnectStep> get lastSteps => List<ReconnectStep>.unmodifiable(_steps);

  /// Runs the bounded reconnect.
  ///
  /// Returns whether the app is talking to the gateway again. ComfyUI being
  /// down does not make it false: the gateway answered, which is a different
  /// condition with a different message (`docs/recovery.md`).
  ///
  /// **Choose another server ends it** (T-0243). The person asked to leave, so
  /// after every wait in here — the backoff, the handshake, the registry, the
  /// job — a run that choice ended stops where it is: no further request, no
  /// [failure] for the server they left, and nothing about [isReconnecting] or
  /// the generation, which [chooseAnotherServer] has already settled. What such
  /// a run returns is only whether the connection is at a gateway now; it did
  /// not take it there.
  Future<bool> reconnect() async {
    if (_running) return false;
    _running = true;
    final token = ++_reconnectToken;
    // Read once. A count chosen while this runs is for the next reconnect, not
    // a change to how long this one lasts.
    final budget = _attempts;
    _failure = null;
    _attemptsMade = 0;
    _steps.clear();
    generation.beginReconnect();
    _notify();

    ConnectionNotice? notice;
    var reached = false;

    for (var attempt = 0; attempt < budget && !reached; attempt++) {
      if (attempt > 0 && backoff > Duration.zero) {
        await Future<void>.delayed(backoff * attempt);
        if (_disposed) return false;
        if (token != _reconnectToken) return connection.isConnected;
      }
      _attemptsMade++;
      _steps.add(ReconnectStep.retryEndpoint);
      final outcome = await connection.probe();
      if (_disposed) return false;
      if (token != _reconnectToken) return connection.isConnected;

      if (outcome is HandshakeSucceeded) {
        // One request answered all three questions: something was there, it
        // said it was LocalCanvas, and it speaks this version.
        _steps.add(ReconnectStep.verifyIdentity);
        _steps.add(ReconnectStep.verifyApiVersion);
        reached = true;
        break;
      }
      if (outcome is! HandshakeFailed) {
        // No endpoint to probe at all. There is nothing to retry.
        break;
      }
      notice = outcome.notice;
      switch (outcome.problem) {
        case ConnectionProblem.notLocalCanvas:
          // Something answered and it was not us: identity is what failed.
          _steps.add(ReconnectStep.verifyIdentity);
        case ConnectionProblem.incompatibleVersion:
          _steps.add(ReconnectStep.verifyIdentity);
          _steps.add(ReconnectStep.verifyApiVersion);
        case ConnectionProblem.unreachable:
        case ConnectionProblem.comfyUnavailable:
          break;
      }
      // A wrong service or a wrong version is a settled fact about the other
      // end; asking the same address again cannot change it. Only "nothing
      // answered" is worth another attempt, and only inside the bound.
      if (!outcome.isWorthRetrying) break;
    }

    if (!reached) {
      _failure =
          notice ??
          describeProblem(
            ConnectionProblem.unreachable,
            address: connection.endpoint?.display,
          );
      _running = false;
      generation.endReconnect(connected: false);
      _notify();
      return false;
    }

    // The gateway is back. Whether it can generate is a separate question, and
    // the connection's own notice already carries the answer.
    _steps.add(ReconnectStep.verifyComfyReadiness);

    _steps.add(ReconnectStep.refreshRegistry);
    await workflows.reload();
    if (_disposed) return false;
    if (token != _reconnectToken) return connection.isConnected;

    // Last: the editable state. The registry refresh above already re-checked
    // every chosen picture and clip and dropped the ones whose permission has
    // lapsed; what is left is the job that may have been in flight.
    _steps.add(ReconnectStep.restoreState);
    await generation.recoverJob();
    if (_disposed) return false;
    if (token != _reconnectToken) return connection.isConnected;

    _running = false;
    generation.endReconnect(connected: true);
    _notify();
    return true;
  }

  /// Gives up on this server and goes back to choosing one.
  ///
  /// A bounded reconnect still running is ended here, at once, rather than
  /// when its next step comes back — which may be never (T-0243). Losing
  /// contact with the next server can then start a reconnect of its own, and
  /// the generation is left exactly as this choice leaves it when no reconnect
  /// runs: [GenerationController.endReconnect] takes back the reconnect's
  /// mark, and the connection leaving moves the lifecycle where it always goes.
  Future<void> chooseAnotherServer() async {
    _failure = null;
    if (_running) {
      _reconnectToken++;
      _running = false;
      generation.endReconnect(connected: false);
    }
    _notify();
    await connection.chooseAnotherServer();
  }

  /// Clears the recovery panel without reconnecting — used when the user takes
  /// another route out of it.
  void dismissFailure() {
    if (_failure == null) return;
    _failure = null;
    _notify();
  }

  void _onContactLost() {
    if (_running) return;
    unawaited(reconnect());
  }

  void _onConnectionChanged() {
    final phase = connection.phase;
    // Whether this notification is the connection *arriving* at a gateway,
    // rather than one more notification from a connection that never left —
    // a reconnect's probe notifies twice without leaving, and its own last
    // step is what asks about the job there.
    final arriving =
        phase == ConnectionPhase.connected &&
        _attachedPhase != ConnectionPhase.connected;
    switch (phase) {
      case ConnectionPhase.idle:
        break;
      case ConnectionPhase.connecting:
        generation.markConnecting();
      case ConnectionPhase.needsServer:
        generation.connectionLost();
      case ConnectionPhase.connected:
        final endpoint = connection.endpoint;
        final identity = connection.identity;
        // Not attached, so not arrived: the next notification that can attach
        // is the arrival.
        if (endpoint == null || identity == null) return;
        generation.attach(
          endpoint: endpoint,
          capabilities: identity.capabilities,
        );
        _attachedPhase = phase;
        // Arriving is a reconnect by another road — Choose another server and
        // back, or the connect screen's own retry — so it ends the way the
        // bounded reconnect does: by asking what became of the job (T-0238).
        //
        // The session owns the trigger because only the session sees the
        // connection arrive; the generation owns every decision after it.
        // `attach` has already cleared a job that belongs to a different
        // endpoint (compared as an [Endpoint], never by name), and
        // `recoverJob` leaves a finished one alone, so what reaches the gateway
        // is exactly a job this server issued whose fate is not yet known.
        if (arriving) unawaited(generation.recoverJob());
        return;
    }
    _attachedPhase = phase;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    connection.removeListener(_onConnectionChanged);
    generation.onContactLost = null;
    super.dispose();
  }
}
