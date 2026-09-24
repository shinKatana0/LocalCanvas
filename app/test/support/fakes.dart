/// Test doubles for the collaborators the app is handed at composition time.
library;

import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:http/http.dart' as http;
import 'package:localcanvas/connection/discovery.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/connection/reconnect_attempts_store.dart';
import 'package:localcanvas/l10n/accept_language.dart';
import 'package:localcanvas/l10n/locale_controller.dart';
import 'package:localcanvas/l10n/locale_store.dart';
import 'package:localcanvas/theme/pane_split_store.dart';
import 'package:localcanvas/theme/theme_mode_controller.dart';
import 'package:localcanvas/theme/theme_mode_store.dart';
import 'package:localcanvas/workflows/selected_workflow_store.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

/// What a real store would hold, without a platform channel.
class InMemoryEndpointStore implements EndpointStore {
  InMemoryEndpointStore([this.stored]);

  RememberedServer? stored;
  int writes = 0;

  @override
  Future<RememberedServer?> load() async => stored;

  @override
  Future<void> remember(RememberedServer server) async {
    writes++;
    stored = server;
  }

  @override
  Future<void> forget() async => stored = null;
}

/// The remembered brightness, without a platform channel.
///
/// It records what was written as well as what it holds, because "the choice
/// survives a relaunch" is two claims — the value went in, and the value came
/// back — and a store that only held would let a test prove the second while
/// the first never happened.
class InMemoryThemeModeStore implements ThemeModeStore {
  InMemoryThemeModeStore([this.stored]);

  /// What a previous launch left behind. `null` is a device that has never
  /// been told anything: a first run, or one whose app data was cleared.
  ThemeMode? stored;

  /// Every value [save] was given, in order.
  final List<ThemeMode> written = <ThemeMode>[];
  int reads = 0;

  /// What [load] throws instead of answering. A preference file that will not
  /// open, or a platform channel that refuses.
  Object? loadFailure;

  /// What [save] throws instead of writing.
  Object? saveFailure;

  @override
  Future<ThemeMode?> load() async {
    reads++;
    final failure = loadFailure;
    if (failure != null) throw failure;
    return stored;
  }

  @override
  Future<void> save(ThemeMode mode) async {
    written.add(mode);
    final failure = saveFailure;
    if (failure != null) throw failure;
    stored = mode;
  }
}

/// The split between the two panes, in memory, and recorded both ways for the
/// reason its neighbour above is: "the split survives a relaunch" is two
/// claims, and a store that only held would let a test prove the second while
/// the first never happened.
class InMemoryPaneSplitStore implements PaneSplitStore {
  InMemoryPaneSplitStore([this.stored]);

  /// What a previous launch left behind. `null` is a device nobody has ever
  /// dragged.
  double? stored;

  /// Every share [save] was given, in order.
  final List<double> written = <double>[];
  int reads = 0;

  /// What [load] throws instead of answering.
  Object? loadFailure;

  /// What [save] throws instead of writing.
  Object? saveFailure;

  @override
  Future<double?> load() async {
    reads++;
    final failure = loadFailure;
    if (failure != null) throw failure;
    return stored;
  }

  @override
  Future<void> save(double share) async {
    written.add(share);
    final failure = saveFailure;
    if (failure != null) throw failure;
    stored = share;
  }
}

/// The chosen number of reconnect attempts, in memory, recorded both ways for
/// the reason its neighbours are: "the count survives a relaunch" is two
/// claims.
///
/// It deliberately enforces no bound. Refusing an out-of-range value is the
/// real store's job and the session's, and a fake that refused would let a
/// test of either pass on the fake's behalf.
class InMemoryReconnectAttemptsStore implements ReconnectAttemptsStore {
  InMemoryReconnectAttemptsStore([this.stored]);

  /// What a previous launch left behind.
  int? stored;

  /// Every count [save] was given, in order.
  final List<int> written = <int>[];

  /// Completes [load]; left null, [load] answers at once.
  Completer<void>? loadGate;

  /// Reads what was stored at the moment it is asked, as a launch reads the
  /// file, and answers once [loadGate] opens. Reading after the gate instead
  /// would hand back whatever a later [save] wrote, and a "late restore must
  /// not undo a choice" test would pass without a late restore ever arriving
  /// — which is exactly what an earlier version of this fake did (T-0212, M8).
  @override
  Future<int?> load() async {
    final value = stored;
    final gate = loadGate;
    if (gate != null) await gate.future;
    return value;
  }

  @override
  Future<void> save(int count) async {
    written.add(count);
    stored = count;
  }
}

/// Which workflow was open, in memory, and recorded both ways for the reason
/// its neighbours above are: "the workflow survives a relaunch" is two claims.
///
/// **It is deliberately not scoped to the server.** [load] answers with
/// whatever it holds, for any endpoint it is asked about — so a test that
/// claims another server's memory is ignored cannot be satisfied by this class.
/// That rule belongs to `selected_workflow_store.dart`, and a fake that
/// enforced it would be certifying itself. Every test about the scoping drives
/// the real store over a real preference file.
class InMemorySelectedWorkflowStore implements SelectedWorkflowStore {
  InMemorySelectedWorkflowStore([this.stored]);

  /// What a previous launch left behind. `null` is a device that has never
  /// chosen anything.
  String? stored;

  /// Every pair [remember] was given, in order. Recorded before the first
  /// `await`, so a test never has to guess whether the write has landed.
  final List<(Endpoint, String)> written = <(Endpoint, String)>[];

  /// Every endpoint [load] was asked about, in order. Without this a build
  /// that never reads the store is indistinguishable from one that reads it
  /// and finds nothing.
  final List<Endpoint> reads = <Endpoint>[];

  int forgets = 0;

  /// What [load] throws instead of answering — a preference file that will not
  /// open, or a platform channel that refuses.
  Object? loadFailure;

  /// What [remember] and [forget] throw instead of writing.
  Object? saveFailure;

  @override
  Future<String?> load(Endpoint endpoint) async {
    reads.add(endpoint);
    final failure = loadFailure;
    if (failure != null) throw failure;
    return stored;
  }

  @override
  Future<void> remember(Endpoint endpoint, String workflowId) async {
    written.add((endpoint, workflowId));
    final failure = saveFailure;
    if (failure != null) throw failure;
    stored = workflowId;
  }

  @override
  Future<void> forget() async {
    forgets++;
    final failure = saveFailure;
    if (failure != null) throw failure;
    stored = null;
  }
}

/// A remembered-workflow store whose read never finishes until the test lets
/// it — the slow preference file, held still so that the window between the
/// registry arriving and the answer can be looked at instead of raced against.
class PendingSelectedWorkflowStore implements SelectedWorkflowStore {
  final Completer<String?> completer = Completer<String?>();
  final List<(Endpoint, String)> written = <(Endpoint, String)>[];
  final List<Endpoint> reads = <Endpoint>[];
  int forgets = 0;

  @override
  Future<String?> load(Endpoint endpoint) {
    reads.add(endpoint);
    return completer.future;
  }

  @override
  Future<void> remember(Endpoint endpoint, String workflowId) async =>
      written.add((endpoint, workflowId));

  @override
  Future<void> forget() async => forgets++;
}

/// A store whose read never finishes until the test lets it — the slow phone,
/// held still so that the window between launch and the answer can be looked
/// at instead of raced against.
class PendingThemeModeStore implements ThemeModeStore {
  final Completer<ThemeMode?> completer = Completer<ThemeMode?>();
  final List<ThemeMode> written = <ThemeMode>[];
  int reads = 0;

  @override
  Future<ThemeMode?> load() {
    reads++;
    return completer.future;
  }

  @override
  Future<void> save(ThemeMode mode) async => written.add(mode);
}

/// A theme choice over a store that holds [stored] — nothing, by default,
/// which is what a first run has.
ThemeModeController testAppearance([ThemeMode? stored]) =>
    ThemeModeController(store: InMemoryThemeModeStore(stored));

/// The language store, in memory. Nothing here touches `SharedPreferences`,
/// for the reason the theme store's twin gives: composition happens in
/// `main.dart` and only there, which is what lets the whole app run in a test.
class InMemoryLocaleStore implements LocaleStore {
  InMemoryLocaleStore([this.stored = LocaleChoice.unset]);

  LocaleChoice stored;

  /// Every choice handed to [save], in order — including one that equals what
  /// was already there, so a test can tell "written again" from "not written".
  final List<LocaleChoice> written = <LocaleChoice>[];

  /// How many times the app asked. A build that never reads the store is
  /// indistinguishable from one that reads it and finds nothing, unless this
  /// is asserted.
  int reads = 0;

  Object? loadFailure;
  Object? saveFailure;

  @override
  Future<LocaleChoice> load() async {
    reads++;
    final failure = loadFailure;
    if (failure != null) throw failure;
    return stored;
  }

  @override
  Future<void> save(LocaleChoice choice) async {
    written.add(choice);
    final failure = saveFailure;
    if (failure != null) throw failure;
    stored = choice;
  }
}

/// A language store whose read never finishes until the test lets it.
class PendingLocaleStore implements LocaleStore {
  final Completer<LocaleChoice> completer = Completer<LocaleChoice>();
  final List<LocaleChoice> written = <LocaleChoice>[];
  int reads = 0;

  @override
  Future<LocaleChoice> load() {
    reads++;
    return completer.future;
  }

  @override
  Future<void> save(LocaleChoice choice) async => written.add(choice);
}

/// A language choice over a store that holds [stored] — nothing, by default,
/// which is what a first run has.
LocaleController testLanguage([LocaleChoice stored = LocaleChoice.unset]) =>
    LocaleController(store: InMemoryLocaleStore(stored));

/// Wraps a real client and counts the handshakes, so a test can assert that
/// an attempt sequence is bounded rather than trust that it is.
class CountingGatewayClient implements GatewayClient {
  CountingGatewayClient(this.inner);

  final GatewayClient inner;
  int handshakes = 0;
  final List<Endpoint> attempted = <Endpoint>[];

  @override
  Duration get timeout => inner.timeout;

  @override
  LanguageTagSource get language => inner.language;

  @override
  Future<HandshakeOutcome> handshake(Endpoint endpoint) {
    handshakes++;
    attempted.add(endpoint);
    return inner.handshake(endpoint);
  }

  @override
  void dispose() => inner.dispose();
}

/// A client that answers from a script instead of from a socket. For widget
/// tests, where a real request cannot run inside the fake clock.
class ScriptedGatewayClient implements GatewayClient {
  ScriptedGatewayClient(this._answer);

  final HandshakeOutcome Function(Endpoint endpoint) _answer;
  int handshakes = 0;
  final List<Endpoint> attempted = <Endpoint>[];

  @override
  Duration get timeout => const Duration(seconds: 4);

  @override
  LanguageTagSource get language => () => kFallbackLanguageTag;

  @override
  Future<HandshakeOutcome> handshake(Endpoint endpoint) async {
    handshakes++;
    attempted.add(endpoint);
    return _answer(endpoint);
  }

  @override
  void dispose() {}
}

/// A client whose handshake never finishes until the test lets it.
class PendingGatewayClient implements GatewayClient {
  final Completer<HandshakeOutcome> completer = Completer<HandshakeOutcome>();
  int handshakes = 0;

  @override
  Duration get timeout => const Duration(seconds: 4);

  @override
  LanguageTagSource get language => () => kFallbackLanguageTag;

  @override
  Future<HandshakeOutcome> handshake(Endpoint endpoint) {
    handshakes++;
    return completer.future;
  }

  @override
  void dispose() {}
}

/// A discovery backend driven by the test rather than by a network.
class FakeDiscoveryBackend implements DiscoveryBackend {
  FakeDiscoveryBackend({
    this.failsToStart = false,
    this.startError,
    this.stopError,
  });

  /// What [DiscoverySession.stop] throws, when the test cares that it can.
  ///
  /// It can: on Android `stopDiscovery` carries the same multicast-lock gate
  /// as `startDiscovery` and refuses the same way, so a session that refuses
  /// to stop is the ordinary consequence of the permission this app spent
  /// T-0163 declaring — not an invented failure.
  Object? stopError;

  /// Stands for a device or network that cannot discover at all.
  bool failsToStart;

  /// What [start] throws, when the test cares *which* failure it is.
  ///
  /// A real backend refuses for a reason, and the reason is the thing under
  /// test: a plugin that names a missing permission, a plugin that names
  /// nothing, a throw from somewhere nobody enumerated.
  Object? startError;

  int starts = 0;
  int stops = 0;
  final StreamController<DiscoveredServer> _controller =
      StreamController<DiscoveredServer>.broadcast();

  /// Announce a server, as the platform would.
  void announce(DiscoveredServer server) => _controller.add(server);

  void fail(Object error) => _controller.addError(error);

  @override
  Future<DiscoverySession> start() async {
    starts++;
    final error = startError;
    if (error != null) throw error;
    if (failsToStart) throw StateError('discovery unavailable');
    return _FakeSession(this);
  }
}

class _FakeSession implements DiscoverySession {
  _FakeSession(this._backend);

  final FakeDiscoveryBackend _backend;

  @override
  Stream<DiscoveredServer> get found => _backend._controller.stream;

  @override
  Future<void> stop() async {
    _backend.stops++;
    final error = _backend.stopError;
    if (error != null) throw error;
  }
}

/// An HTTP client whose every request fails with whatever it was given.
///
/// Stands for the exception types this code cannot enumerate: TLS errors that
/// are siblings rather than subtypes of the ones caught by name, and whatever
/// a platform adds next. What matters is that none of them escapes.
class ThrowingHttpClient extends http.BaseClient {
  ThrowingHttpClient(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future<http.StreamedResponse>.error(error);
}

/// A gateway identity, as `/api/v1/info` would have described it.
GatewayIdentity testIdentity({
  String displayName = 'Studio PC',
  int apiVersion = kSupportedApiVersion,
  ComfyStatus comfyStatus = ComfyStatus.ready,
  String? comfyDetail,
  GatewayCapabilities capabilities = const GatewayCapabilities(),
}) => GatewayIdentity(
  apiVersion: apiVersion,
  gatewayVersion: '0.1.0',
  displayName: displayName,
  comfyStatus: comfyStatus,
  comfyDetail: comfyDetail,
  capabilities: capabilities,
);

/// A registry answered from a script instead of a socket. For widget tests;
/// the transport itself is exercised against a real server in
/// `workflow_api_test.dart`.
class ScriptedWorkflowsApi implements WorkflowsApi {
  ScriptedWorkflowsApi({
    this.summaries = const <WorkflowSummary>[],
    this.details = const <String, WorkflowDetail>{},
    this.listFailure,
    this.detailFailure,
  });

  List<WorkflowSummary> summaries;
  Map<String, WorkflowDetail> details;
  WorkflowsFailure? listFailure;
  WorkflowsFailure? detailFailure;

  int listCalls = 0;
  final List<String> detailCalls = <String>[];

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async {
    listCalls++;
    final failure = listFailure;
    if (failure != null) throw failure;
    return summaries;
  }

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) async {
    detailCalls.add(workflowId);
    final failure = detailFailure;
    if (failure != null) throw failure;
    final detail = details[workflowId];
    if (detail == null) {
      throw const WorkflowsFailure.refused(
        code: 'workflow_not_found',
        serverMessage: 'That workflow is no longer available.',
      );
    }
    return detail;
  }
}

/// A registry with nothing in it: what a server publishing no workflows says.
WorkflowsController emptyRegistry() =>
    WorkflowsController(api: ScriptedWorkflowsApi());

/// A backend that never announces anything: the common real-world outcome.
DiscoveryController silentDiscovery() => DiscoveryController(
  backend: FakeDiscoveryBackend(),
  window: const Duration(milliseconds: 20),
);
