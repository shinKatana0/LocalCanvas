/// The one connection object the app has (`docs/connection.md`).
///
/// Flutter's own `ChangeNotifier` and nothing else: there is one of these and
/// one screen, and a state-management framework would be larger than the thing
/// it manages.
///
/// Two rules are enforced here rather than described:
///
/// * **Only a successful handshake is remembered.** [store] is written in
///   exactly one place, and that place holds a [HandshakeSucceeded].
/// * **Nothing retries forever.** Every attempt sequence is a counted loop
///   with a small bound; when it runs out the phase becomes
///   [ConnectionPhase.needsServer], which is a screen with decisions on it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'connection_problem.dart';
import 'discovery.dart';
import 'endpoint.dart';
import 'endpoint_store.dart';
import 'gateway_client.dart';
import 'gateway_identity.dart';
import 'pairing.dart';

enum ConnectionPhase {
  /// Nothing has been attempted yet.
  idle,

  /// An attempt is in flight. The intro plays over this; it does not cause it.
  connecting,

  /// The app needs the user to choose a server.
  needsServer,

  /// Handshake complete. ComfyUI may still be down — see [ConnectionController.notice].
  connected,
}

/// Why a scanned code did not connect, for the words the scanner shows.
enum PairingOutcome {
  connected,

  /// The camera read something that is not a LocalCanvas pairing code.
  notAPairingCode,

  /// A well-formed code whose server did not answer or did not identify.
  handshakeFailed,
}

class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this.client,
    required this.store,
    required this.discovery,
    this.retryDelay = kRetryDelay,
  });

  /// The remembered endpoint gets the attempt plus one short retry
  /// `docs/connection.md` §1 describes — the router-just-woke-up case — and
  /// then stops. Two is the whole budget.
  static const int kLaunchAttempts = 2;

  /// Breathing room between those two attempts. Not a backoff schedule: there
  /// is only ever one gap.
  static const Duration kRetryDelay = Duration(milliseconds: 600);

  final GatewayClient client;
  final EndpointStore store;
  final Duration retryDelay;

  /// Discovery is a sibling, not a dependency: the controller starts it and
  /// reads it, and every path through this class works with it removed.
  final DiscoveryController discovery;

  ConnectionPhase _phase = ConnectionPhase.idle;
  ConnectionNotice? _notice;
  Endpoint? _endpoint;
  GatewayIdentity? _identity;
  RememberedServer? _remembered;
  bool _busy = false;

  /// Which operation holds [isBusy] (T-0243). Every operation that makes a
  /// handshake takes the next value; [chooseAnotherServer] moves it on without
  /// taking one. An operation whose value is no longer current records nothing
  /// its reply says, and releases nothing when it ends.
  int _operation = 0;

  bool _disposed = false;

  ConnectionPhase get phase => _phase;

  /// The last thing that went wrong, in words. While [phase] is
  /// [ConnectionPhase.connected] this is either null or the ComfyUI notice.
  ConnectionNotice? get notice => _notice;

  /// The endpoint currently connected, or last attempted.
  Endpoint? get endpoint => _endpoint;

  /// The connected server's own account of itself.
  GatewayIdentity? get identity => _identity;

  /// What was remembered at launch, so the connect screen can offer it by name.
  RememberedServer? get remembered => _remembered;

  /// An attempt is in flight; actions that would start another are disabled.
  bool get isBusy => _busy;

  bool get isConnected => _phase == ConnectionPhase.connected;

  /// Whether the connected gateway can actually generate right now.
  bool get isComfyReady => _identity?.comfyStatus.isReady ?? false;

  /// The launch sequence: remembered endpoint first, bounded; then discovery.
  ///
  /// Called as the app starts, independently of the intro animation, which is
  /// why readiness is never gated on a frame count.
  Future<void> start() async {
    if (_busy) return;
    _remembered = await store.load();
    final remembered = _remembered;
    if (remembered == null) {
      _toNeedsServer(null);
      unawaited(discovery.scan());
      return;
    }

    _busy = true;
    final op = ++_operation;
    _endpoint = remembered.endpoint;
    _phase = ConnectionPhase.connecting;
    _notice = null;
    _notify();

    HandshakeFailed? lastFailure;
    for (var attempt = 0; attempt < kLaunchAttempts; attempt++) {
      final outcome = await client.handshake(remembered.endpoint);
      if (op != _operation) return;
      if (outcome is HandshakeSucceeded) {
        await _accept(outcome);
        if (_release(op)) _notify();
        return;
      }
      lastFailure = outcome as HandshakeFailed;
      // A wrong service or a wrong version is a settled fact about the other
      // end. Only "nothing answered" is worth one more try.
      if (!lastFailure.isWorthRetrying) break;
      if (attempt + 1 < kLaunchAttempts && retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
        if (op != _operation) return;
      }
    }

    _release(op);
    _toNeedsServer(lastFailure?.notice);
    unawaited(discovery.scan());
  }

  /// Connects to an endpoint the user chose — typed, scanned, or picked from
  /// the discovered list. One attempt: the user is right there and can ask
  /// again, which is a decision rather than a loop.
  Future<bool> connectTo(Endpoint endpoint) async {
    if (_busy) return false;
    _busy = true;
    final op = ++_operation;
    _endpoint = endpoint;
    _phase = ConnectionPhase.connecting;
    _notice = null;
    _notify();

    final outcome = await client.handshake(endpoint);
    // Choose another server was pressed while this was on the wire: the reply,
    // whatever it says, is about a choice the person has since taken back.
    if (op != _operation) return false;
    if (outcome is HandshakeSucceeded) {
      await _accept(outcome);
      if (_release(op)) _notify();
      return true;
    }

    _release(op);
    _toNeedsServer((outcome as HandshakeFailed).notice);
    return false;
  }

  /// Scan → parse → verify → save → connect. A code that parses but fails the
  /// handshake reports that and saves nothing.
  Future<PairingOutcome> connectToPairingPayload(String payload) async {
    final endpoint = parsePairingPayload(payload);
    if (endpoint == null) return PairingOutcome.notAPairingCode;
    final connected = await connectTo(endpoint);
    return connected ? PairingOutcome.connected : PairingOutcome.handshakeFailed;
  }

  /// The explicit recovery action: try the same address once more, because the
  /// user asked. This is the exit from a bounded failure, not a resumption of
  /// automatic retrying.
  Future<bool> retry() async {
    final endpoint = _endpoint ?? _remembered?.endpoint;
    if (endpoint == null) return false;
    return connectTo(endpoint);
  }

  /// Re-runs the handshake against the connected server, for the case where
  /// the gateway is up and ComfyUI was not.
  Future<void> refreshIdentity() async {
    final endpoint = _endpoint;
    if (endpoint == null || _busy) return;
    _busy = true;
    final op = ++_operation;
    _notify();
    final outcome = await client.handshake(endpoint);
    if (op != _operation) return;
    if (outcome is HandshakeSucceeded) {
      await _accept(outcome);
      if (_release(op)) _notify();
      return;
    }
    _release(op);
    _toNeedsServer((outcome as HandshakeFailed).notice);
  }

  /// One reconnect probe against the current endpoint.
  ///
  /// Unlike [refreshIdentity] this does **not** leave the connected shell when
  /// it fails: a bounded reconnect must not blank the screen or discard a
  /// displayed result (`docs/recovery.md`), so the outcome is handed back and
  /// the caller decides what a failure means. Success is accepted exactly as
  /// any other handshake is, which is what re-verifies identity, API version
  /// and ComfyUI readiness in one call.
  ///
  /// Returns `null` when there is no endpoint to probe.
  ///
  /// A probe [chooseAnotherServer] overtook hands its outcome back unrecorded:
  /// the session's reconnect it belongs to has been ended too, and reads
  /// nothing from it.
  Future<HandshakeOutcome?> probe() async {
    final endpoint = _endpoint;
    if (endpoint == null) return null;
    _busy = true;
    final op = ++_operation;
    _notify();
    final outcome = await client.handshake(endpoint);
    if (outcome is HandshakeSucceeded && op == _operation) {
      await _accept(outcome);
    }
    if (_release(op)) _notify();
    return outcome;
  }

  /// Leaves the connected server and goes back to choosing one. What was
  /// remembered stays remembered — the user is looking around, not evicting a
  /// server that works.
  ///
  /// It also ends whatever handshake is still on the wire (T-0243). An answer
  /// arriving after this is about the server the person left and records
  /// nothing — no endpoint, identity, phase or remembered server — and the busy
  /// state that handshake held is released here, so connecting somewhere else
  /// straight away is not refused.
  Future<void> chooseAnotherServer() async {
    _operation++;
    _busy = false;
    _identity = null;
    _toNeedsServer(null);
    await discovery.scan();
  }

  /// Ends operation [op]'s busy state and says whether it did. An operation
  /// that has been overtaken releases nothing: the busy state may by now belong
  /// to a newer one, which ends it itself.
  bool _release(int op) {
    if (op != _operation) return false;
    _busy = false;
    return true;
  }

  /// Forgets the remembered server outright, at the user's request.
  Future<void> forgetRemembered() async {
    await store.forget();
    _remembered = null;
    _notify();
  }

  /// The single place a successful handshake is recorded — and therefore the
  /// single place the remembered endpoint can ever change.
  Future<void> _accept(HandshakeSucceeded outcome) async {
    _endpoint = outcome.endpoint;
    _identity = outcome.identity;
    _phase = ConnectionPhase.connected;
    _notice = outcome.identity.comfyStatus.isReady
        ? null
        : describeProblem(
            ConnectionProblem.comfyUnavailable,
            address: outcome.endpoint.display,
            serverName: outcome.identity.displayName,
            detail: outcome.identity.comfyDetail,
          );
    final server = RememberedServer(
      endpoint: outcome.endpoint,
      // A gateway that gave no name is remembered by its address, which is
      // what the store already does for a device that remembers no name at
      // all — and, unlike a stand-in phrase, an address is the same in every
      // language.
      displayName: outcome.identity.displayName ?? outcome.endpoint.display,
      lastSuccess: DateTime.now().toUtc(),
    );
    _remembered = server;
    await store.remember(server);
  }

  /// The launch sequence can outlive the object that started it. Announcing a
  /// result to a disposed notifier is an error in Flutter, so every
  /// notification goes through here.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _toNeedsServer(ConnectionNotice? notice) {
    _phase = ConnectionPhase.needsServer;
    _notice = notice;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    discovery.dispose();
    client.dispose();
    super.dispose();
  }
}
