/// mDNS / DNS-SD discovery (`docs/connection.md` §2).
///
/// One of four ways to obtain an endpoint, and never a dependency of the API
/// layer (`docs/transport-boundary.md` §5): deleting this file would leave a
/// fully working app driven by QR and manual entry, which is exactly the
/// situation on any deployment that is not a flat LAN.
///
/// Discovery is expected to be unreliable — some Android networks, routers and
/// VPN configurations suppress multicast. That is a normal outcome, so the
/// scan is bounded, its failure is a state the UI can render, and nothing here
/// retries forever.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'endpoint.dart';

/// The service type the gateway advertises.
const String kServiceType = '_localcanvas._tcp';

/// A gateway seen on the network. A candidate, not a connection: the identity
/// handshake still runs before this endpoint is accepted or persisted.
@immutable
class DiscoveredServer {
  const DiscoveredServer({
    required this.id,
    required this.displayName,
    required this.endpoint,
    this.gatewayVersion,
    this.apiVersion,
  });

  /// Stable within a scan, so re-announcements do not duplicate a row.
  final String id;

  /// The `name` TXT record — the operator's own name for the machine.
  final String displayName;

  final Endpoint endpoint;
  final String? gatewayVersion;
  final int? apiVersion;
}

/// A running scan.
abstract class DiscoverySession {
  /// Servers as they appear. Never closes on its own; [stop] ends it.
  Stream<DiscoveredServer> get found;

  Future<void> stop();
}

/// Starts scans. The seam that keeps the platform out of the tests.
abstract class DiscoveryBackend {
  /// Throws when the platform will not scan at all — no mDNS support, a
  /// permission refused, multicast blocked outright.
  Future<DiscoverySession> start();
}

enum DiscoveryStatus {
  /// Not scanning, and has not scanned yet.
  idle,

  /// Scanning; the list may still grow.
  scanning,

  /// The bounded scan window closed. Whatever was found is all there is.
  finished,

  /// This device or network cannot discover at all.
  unavailable,
}

/// Where a scan stopped.
///
/// Two code paths, two different stories: a scan that never started at all is
/// a different problem from one that started and then broke, and a report that
/// does not say which sends the next reader looking in the wrong half.
enum DiscoveryFailureStage {
  /// [DiscoveryBackend.start] threw; no scan ever ran.
  start,

  /// A scan was running and the stream carried an error.
  scan,

  /// Releasing the platform resources of a scan threw.
  ///
  /// Kept apart from the other two because it means something different to the
  /// person reading it: the scan that just ran is unaffected, and the app is
  /// not unavailable. Nothing downstream of "stop the scan" can act on this, so
  /// it is recorded and stepped over rather than shown — but it is recorded,
  /// because a stop that throws is how [DiscoveryStatus.scanning] used to get
  /// stuck.
  stop,
}

/// Why a scan failed, in the words of whatever refused it.
///
/// The point of this class is that it is *not* a summary. `docs/connection.md`
/// says discovery is expected to be unreliable, and that is exactly why the
/// reason has to survive: when failure is an expected outcome, an unlabelled
/// failure teaches nobody anything, and a missing permission looks the same as
/// a router that drops multicast for as long as nobody writes the reason down.
@immutable
class DiscoveryFailure implements Exception {
  const DiscoveryFailure({
    required this.reason,
    this.cause,
    this.stage = DiscoveryFailureStage.start,
  });

  /// What the platform said, verbatim. Never localized and never shortened —
  /// a translated error message is one nobody can search for.
  final String reason;

  /// The backend's own classification, when it had one; `null` for a throw
  /// nothing classified. Kept apart from [reason] because the two fail
  /// differently: a backend may name a cause with an empty message, or carry a
  /// useful message under a cause as vague as `internalError`.
  final String? cause;

  final DiscoveryFailureStage stage;

  /// Everything known about the failure, on one line, for a screen or a log.
  String get summary => cause == null ? reason : '$cause: $reason';

  /// The same failure, attributed to where it actually surfaced.
  DiscoveryFailure at(DiscoveryFailureStage stage) =>
      DiscoveryFailure(reason: reason, cause: cause, stage: stage);

  /// Whatever was thrown, as something that can be read.
  ///
  /// A backend that knows its platform describes its own failures (see
  /// `nsd_discovery.dart`); anything else — a bug in a backend, an error type
  /// nobody enumerated — still arrives here and still has a `toString()`. An
  /// unknown throw is handled, not dropped and not allowed to escape.
  factory DiscoveryFailure.from(Object error, DiscoveryFailureStage stage) =>
      error is DiscoveryFailure
      ? error.at(stage)
      : DiscoveryFailure(reason: error.toString(), stage: stage);

  @override
  String toString() => 'DiscoveryFailure(${stage.name}): $summary';
}

/// Drives one bounded scan and holds its result.
///
/// The window is a hard bound, not a heuristic: when it closes the scan stops
/// and the UI shows whatever it has, with QR and manual entry beside it. There
/// is no automatic rescan — a rescan is a decision, and it belongs to the user.
class DiscoveryController extends ChangeNotifier {
  DiscoveryController({
    required this.backend,
    this.window = kScanWindow,
  });

  /// Long enough for a gateway on the same subnet to answer, short enough that
  /// a network which is never going to answer says so.
  static const Duration kScanWindow = Duration(seconds: 6);

  final DiscoveryBackend backend;
  final Duration window;

  DiscoveryStatus _status = DiscoveryStatus.idle;
  DiscoveryFailure? _failure;
  final List<DiscoveredServer> _servers = <DiscoveredServer>[];
  DiscoverySession? _session;
  StreamSubscription<DiscoveredServer>? _subscription;
  Timer? _windowTimer;
  bool _disposed = false;

  DiscoveryStatus get status => _status;

  /// Why the last scan failed, or `null` if the last one did not.
  ///
  /// Set whenever [status] is [DiscoveryStatus.unavailable], and cleared the
  /// moment a new scan starts — a stale reason under a fresh scan is worse
  /// than none.
  DiscoveryFailure? get failure => _failure;

  List<DiscoveredServer> get servers => List.unmodifiable(_servers);
  bool get isScanning => _status == DiscoveryStatus.scanning;

  /// Starts (or restarts) the bounded scan.
  Future<void> scan() async {
    if (_disposed) return;
    await _teardown();
    if (_disposed) return;
    _servers.clear();
    _failure = null;
    _status = DiscoveryStatus.scanning;
    _notify();

    final DiscoverySession session;
    try {
      session = await backend.start();
    } catch (error) {
      // Not a bug and not a dead end: the UI keeps QR and manual entry. But
      // the reason is not the app's to throw away — it is the only thing that
      // makes the next report of this diagnosable, so it is kept and shown.
      if (_disposed) return;
      _fail(DiscoveryFailure.from(error, DiscoveryFailureStage.start));
      return;
    }
    if (_disposed) {
      await session.stop();
      return;
    }

    _session = session;
    _subscription = session.found.listen(
      _add,
      onError: (Object error) {
        // A failure that arrives *after* a scan started is a different path
        // from the one above, and used to discard its reason just as silently.
        if (_disposed) return;
        _fail(DiscoveryFailure.from(error, DiscoveryFailureStage.scan));
      },
    );
    _windowTimer = Timer(window, _closeWindow);
  }

  /// Stops scanning now and keeps what was found.
  Future<void> stop() async {
    await _teardown();
    if (_disposed) return;
    if (_status == DiscoveryStatus.scanning) {
      _status = DiscoveryStatus.finished;
      _notify();
    }
  }

  void _add(DiscoveredServer server) {
    if (_disposed) return;
    final at = _servers.indexWhere((existing) => existing.id == server.id);
    if (at >= 0) {
      _servers[at] = server;
    } else {
      _servers.add(server);
    }
    _notify();
  }

  /// Records a failure where a person can read it: on the object the screen
  /// renders, and in the log.
  ///
  /// Both, deliberately. The screen is what the one developer holding the
  /// phone can quote back without a cable; the log is what survives the card
  /// being scrolled past, and is where a second failure in the same session
  /// shows up as a second line.
  void _fail(DiscoveryFailure failure) {
    _failure = failure;
    _status = DiscoveryStatus.unavailable;
    _note(failure);
    _notify();
  }

  /// Writes a failure down without claiming anything about the scan.
  ///
  /// The only place a discovery failure reaches the log, so the three stages
  /// cannot come to describe themselves differently. [_fail] adds the screen
  /// and the status on top; a teardown failure gets this and nothing else.
  void _note(DiscoveryFailure failure) {
    // One line, one tag to grep logcat for, and no sentence: nothing here is
    // addressed to a user, so nothing here is translated.
    debugPrint(
      '[localcanvas:discovery] ${failure.stage.name}: ${failure.summary}',
    );
  }

  void _closeWindow() {
    if (_disposed) return;
    _status = DiscoveryStatus.finished;
    _notify();
    unawaited(_teardown());
  }

  /// A scan can outlive the object that started it — the app moved on, the
  /// screen went away. Announcing a result to a disposed notifier is an error
  /// in Flutter, so the check lives in one place rather than at each call.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Releases the platform resources of the current scan.
  ///
  /// The fields are cleared *before* the awaits, not after: a second scan
  /// started while this one is unwinding must not end up waiting on the same
  /// subscription — that is a scan that never starts and a screen that stays
  /// on its last answer.
  ///
  /// **This never throws, and that is the whole of it.** Both awaits can fail:
  /// on Android `stopDiscovery` carries the same multicast-lock gate as
  /// `startDiscovery` and refuses the same way (`nsd_discovery.dart`). Before
  /// this was caught it cost two things at once — every ordinary window close
  /// leaked the error to the zone through `unawaited`, and the next [scan]
  /// rejected here *before* it had cleared the servers or moved the status, so
  /// the screen stayed on `scanning` and Search again did nothing at all.
  ///
  /// The failure is recorded and stepped over. It is not shown: the scan that
  /// just ran is unaffected, and nothing a person could do about it is
  /// different. Silence is what this card exists to remove, so it is logged
  /// with the same tag and the same shape as the two failures that are shown.
  Future<void> _teardown() async {
    _windowTimer?.cancel();
    _windowTimer = null;
    final subscription = _subscription;
    final session = _session;
    _subscription = null;
    _session = null;
    // Separately, so that a subscription that refuses to cancel cannot stop the
    // session being asked to stop. Releasing one resource is not conditional on
    // releasing the other.
    await _release(subscription?.cancel);
    await _release(session?.stop);
  }

  /// Runs one release step and swallows nothing but the exception.
  Future<void> _release(Future<void> Function()? step) async {
    if (step == null) return;
    try {
      await step();
    } catch (error) {
      _note(DiscoveryFailure.from(error, DiscoveryFailureStage.stop));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }
}
