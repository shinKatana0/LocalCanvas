/// The registry the app is looking at, and the workflow it has chosen.
///
/// Flutter's own [ChangeNotifier], like the connection controller: there is one
/// of these and one screen behind it.
///
/// It also owns one [WorkflowFormController] per workflow, and keeps it. That
/// is what makes a prompt survive a trip to the picker and back — and a change
/// of mind, since coming back to a workflow finds the values that were left in
/// it. Nothing here is rebuilt by a layout change, because nothing here lives
/// in a widget.
///
/// Holding them is enough for everything that happens inside one run of the
/// app — navigation, a fold, a reconnect. It is not enough for the process
/// being killed, which is what the draft store answers: this controller writes
/// one draft per workflow as the user works, debounced, and lays it back over
/// the form the next time that workflow is opened.
///
/// Saved setups are the third store it reaches, and the only one nothing here
/// writes on its own: they are created, applied, renamed and deleted when the
/// user says so, and never otherwise (`workflow_setup_store.dart`).
///
/// The portable profile is not a fourth store and is not a fourth layer. It is
/// two operations over the first and the third — write out what they hold,
/// merge back what a document says — and it is here rather than in a
/// controller of its own because this is where those two stores already are
/// (`profile_exchange.dart`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/endpoint.dart';
import '../media/clip_inspector.dart';
import '../media/media_api.dart';
import '../media/media_picker.dart';
import '../media/media_selection.dart';
import 'profile_exchange.dart';
import 'profile_transport.dart';
import 'selected_workflow_store.dart';
import 'workflow_api.dart';
import 'workflow_draft_store.dart';
import 'workflow_form.dart';
import 'workflow_models.dart';
import 'workflow_profile.dart';
import 'workflow_settings_store.dart';
import 'workflow_setup_store.dart';

/// How long the draft autosave waits after the last change before it writes.
///
/// Two seconds, and the number is a compromise between two costs:
///
/// * a write per keystroke is battery and flash for nothing, and every
///   interval shorter than about a second is one — a slow typist leaves
///   gaps of half a second inside a word, and a dragged slider produces a
///   value per pixel;
/// * work lost to the app dying with the last change unwritten. That cost is
///   mostly paid by [WorkflowsController.flushDrafts], which writes when the
///   app leaves the foreground, so the interval only has to bound what a
///   crash violent enough to skip that callback can take: a couple of
///   seconds of typing.
///
/// Two seconds is longer than any gap inside continuous typing and shorter
/// than any pause that means the user has moved on.
const Duration kDraftDebounce = Duration(seconds: 2);

/// How the autosave's wait is scheduled.
///
/// Real time in the app, and a clock the test moves by hand in a test — a
/// debounce proved with a real delay is a test that either sleeps or lies.
typedef DraftTimerFactory =
    Timer Function(Duration delay, void Function() onFire);

/// How old the registry has to be before coming back to the app re-reads it
/// (T-0017).
///
/// A minute. Coming back from a glance at a notification is not a reason to
/// ask the PC anything, and every such glance would be a request; coming back
/// from having imported a workflow on the PC takes longer than that, and is
/// exactly the case this exists for. It is a bound on *one* request per
/// return, never a period: nothing re-reads the list while the app stays in
/// front (`docs/recovery.md`: no idle heartbeat in v0.1).
const Duration kRegistryStaleAfter = Duration(minutes: 1);

/// What "now" is, for the bound above. The real clock in the app, and one the
/// test sets by hand in a test — a bound of a minute proved by waiting a minute
/// is a test nobody runs.
typedef RegistryClock = DateTime Function();

enum RegistryPhase {
  /// No endpoint has been given yet.
  idle,

  /// The list is on its way.
  loading,

  /// The list arrived. It may still be empty — that is an answer, not a
  /// failure.
  ready,

  /// The list did not arrive. [WorkflowsController.failure] says why.
  failed,
}

class WorkflowsController extends ChangeNotifier {
  WorkflowsController({
    required this.api,
    this.mediaPicker,
    this.mediaApi,
    this.clipInspector,
    this.settings,
    this.drafts,
    this.setups,
    this.selection,
    this.profiles,
    this.draftDebounce = kDraftDebounce,
    DraftTimerFactory draftTimerFactory = Timer.new,
    this.registryStaleAfter = kRegistryStaleAfter,
    RegistryClock clock = DateTime.now,
  }) : _newDraftTimer = draftTimerFactory,
       _now = clock;

  /// How old the list must be before [refreshIfStale] asks again.
  final Duration registryStaleAfter;

  final RegistryClock _now;

  /// When the list last arrived, or `null` while it never has.
  DateTime? _loadedAt;

  /// A [refresh] is waiting on the gateway.
  bool _refreshing = false;

  int _listArrivals = 0;

  /// How many times a list has arrived and been put on screen — by [load],
  /// [reload] or [refresh] — since this controller was made. It only ever
  /// grows, and it grows at the moment a list replaces the one on screen.
  ///
  /// So a failure and a refusal leave it where it was, and so does a request
  /// overtaken *before its answer arrived*, because that answer is dropped
  /// unapplied. A request overtaken *after* its list was applied has already
  /// counted — a refresh whose list is on screen while it re-checks the chosen
  /// media, and a reload then starts. That count is not taken back, because
  /// the list really was put on screen (measured in review: 1, then 2 when the
  /// refresh applied, then 3 when the reload arrived).
  ///
  /// It exists so that something said about an earlier request can tell
  /// whether the list has been read again since (the picker's refresh failure).
  int get listArrivals => _listArrivals;

  /// Which request for the list is the current one. A refresh overtaken by a
  /// fetch — a reconnect, a change of server — must not lay its older answer
  /// over the newer one.
  int _listToken = 0;

  final WorkflowsApi api;

  /// Where the user's own defaults are kept, or `null` on a build that keeps
  /// none. Absent means the three affordances are absent too — a Save that
  /// wrote nowhere would be a button that lies (`WorkflowFormController`'s
  /// media fields make the same choice about a picker that is not there).
  final WorkflowSettingsStore? settings;

  /// Where the current draft is kept, or `null` on a build that keeps none —
  /// which is the app exactly as it behaved before there was one.
  ///
  /// Nothing about it is a button: a draft is written automatically and read
  /// automatically, there is no "save draft" and no "discard draft", and one
  /// workflow has one of them (`workflow_draft_store.dart`).
  final WorkflowDraftStore? drafts;

  /// Where saved setups are kept, or `null` on a build that keeps none — in
  /// which case the interface offers none of the four operations rather than
  /// a Save that would write nowhere.
  ///
  /// Unlike the draft, nothing here is automatic: a setup is created only
  /// when the user asks for one, and applied only when the user picks one. A
  /// workflow being opened reads its setups so they can be listed, and lays
  /// none of them over the form (`workflow_setup_store.dart`).
  final WorkflowSetupStore? setups;

  /// Where *which* workflow was open is kept, or `null` on a build that keeps
  /// none — which is the app exactly as it behaved before there was one: every
  /// launch begins having chosen nothing.
  ///
  /// The smallest of the stores and the only one that holds a single value.
  /// Nothing about it is a button either: it is written when the user chooses a
  /// workflow, erased when they choose none, and read once per launch
  /// (`selected_workflow_store.dart`). It is **scoped to the server** — see that
  /// file for why a workflow id is meaningless without the gateway it was read
  /// from.
  final SelectedWorkflowStore? selection;

  /// How a profile leaves this device and comes back to it, or `null` on a
  /// build with no way to do either — in which case [canExchangeProfile] is
  /// false and the interface offers nothing about profiles at all, rather than
  /// an Export that would produce a document with nowhere to go.
  final ProfileTransport? profiles;

  /// How long the autosave waits after the last change. [kDraftDebounce] in
  /// the app; a test shortens it only to say what it expects, since the clock
  /// itself is the seam.
  final Duration draftDebounce;

  final DraftTimerFactory _newDraftTimer;

  Timer? _draftTimer;

  /// The workflows whose form has changed since the last write.
  final Set<String> _unsavedDrafts = <String>{};

  /// The listener each watched form carries, kept so it can be taken off
  /// before the form is disposed.
  final Map<String, VoidCallback> _draftWatchers = <String, VoidCallback>{};

  /// How a picture or a clip is chosen, and where it is sent. Both or
  /// neither: a picker with nowhere to upload to would open a chooser and
  /// then fail, which is worse than saying up front that this build cannot
  /// take media (`WorkflowFormController.canChoose`).
  final MediaPicker? mediaPicker;
  final MediaApi? mediaApi;

  /// What draws a chosen clip's frame and learns its length, or `null` on a
  /// build with none — the marked tile, as before (T-0022). Handed on to every
  /// media field; nothing here uses it.
  final ClipInspector? clipInspector;

  Endpoint? _endpoint;
  RegistryPhase _phase = RegistryPhase.idle;
  List<WorkflowSummary> _workflows = const <WorkflowSummary>[];
  WorkflowsFailure? _failure;

  String? _selectedId;
  bool _detailLoading = false;
  WorkflowsFailure? _detailFailure;
  int _selectionToken = 0;

  /// The name of a workflow that was chosen and is no longer in the registry.
  String? _missingSelection;

  final Map<String, WorkflowDetail> _details = <String, WorkflowDetail>{};

  /// The cached schemas a list has arrived since (T-0236). Stale, not deleted:
  /// the form built from one stays usable, and the schema is asked for again —
  /// at once for the chosen workflow, and the next time it is chosen for any
  /// other. An answer that arrived takes the mark off; a failure leaves it on.
  final Set<String> _staleDetails = <String>{};
  final Map<String, WorkflowFormController> _forms =
      <String, WorkflowFormController>{};

  /// Whether a profile could be exported or imported right now.
  ///
  /// All three or none: a document is built from My defaults and Saved setups,
  /// and handed over by the transport, so a build missing any one of them
  /// cannot honour either affordance.
  bool get canExchangeProfile =>
      profiles != null && settings != null && setups != null;

  /// The setups read for each workflow that has been opened, in the order the
  /// store gave them.
  final Map<String, List<WorkflowSetup>> _setups =
      <String, List<WorkflowSetup>>{};

  bool _disposed = false;

  RegistryPhase get phase => _phase;
  List<WorkflowSummary> get workflows => _workflows;
  WorkflowsFailure? get failure => _failure;

  /// The picker's sections, straight from the data (`docs/ui-ux.md`).
  List<WorkflowGroup> get groups => groupWorkflows(_workflows);

  ValidatedForm? _requestedGeneration;

  /// The input map the user last asked to generate with.
  ///
  /// This is where the form's output stops in this build. `POST /api/v1/jobs`
  /// and everything after it is T-0007, and this is the seam it attaches to —
  /// so the map is real and complete here, not assembled later from the
  /// widgets.
  ValidatedForm? get requestedGeneration => _requestedGeneration;

  void requestGeneration(ValidatedForm validated) {
    if (!validated.isReady) return;
    _requestedGeneration = validated;
    _notify();
  }

  String? get selectedId => _selectedId;

  WorkflowSummary? get selectedSummary {
    final id = _selectedId;
    if (id == null) return null;
    for (final workflow in _workflows) {
      if (workflow.id == id) return workflow;
    }
    return null;
  }

  WorkflowDetail? get selectedDetail =>
      _selectedId == null ? null : _details[_selectedId];

  WorkflowFormController? get form =>
      _selectedId == null ? null : _forms[_selectedId];

  /// A detail request is in flight for the current selection.
  bool get isLoadingDetail => _detailLoading;

  /// The workflow that was chosen and is not in the refreshed registry any
  /// more, by name. Non-null is a sentence the interface must show: the app
  /// never quietly picks a different workflow (`docs/recovery.md`).
  String? get missingSelection => _missingSelection;

  /// Acknowledges that report, once the user has read it.
  void clearMissingSelection() {
    if (_missingSelection == null) return;
    _missingSelection = null;
    _notify();
  }

  /// Why the chosen workflow could not be opened.
  WorkflowsFailure? get detailFailure => _detailFailure;

  /// Fetches the registry from [endpoint].
  ///
  /// Changing endpoint clears everything: a form belongs to the server whose
  /// workflow it was built from, and carrying one across would be a value
  /// entered for a workflow that may not exist here.
  ///
  /// This is also the launch that comes back to the workflow the user was on,
  /// and **nothing here is in front of the first frame**: the caller does not
  /// await this (`ui/shell/connected_shell.dart`), the preference read is
  /// started beside the registry request rather than before it, and the
  /// restored workflow's field schema is fetched last of all — after the screen
  /// has already drawn the list and the chosen workflow's own block.
  Future<void> load(Endpoint endpoint) async {
    if (_endpoint != endpoint) {
      _endpoint = endpoint;
      _clearSelectionState();
      _workflows = const <WorkflowSummary>[];
    }
    // Begun now, joined inside [_fetch]: neither the file nor the network waits
    // on the other, and a preference file that never answers costs the registry
    // nothing it was not already spending.
    final restored = await _fetch(endpoint, restoring: _rememberedSelection());
    // The one request deliberately *not* made until the list had vouched for
    // the id. A workflow the gateway no longer serves never reaches this line:
    // [_fetch]'s own check cleared it, by the same branch a mid-session
    // disappearance goes through.
    if (restored != null) await select(restored);
  }

  /// Asks the same endpoint again, at the user's request.
  ///
  /// Restores nothing. A refresh and a reconnect both happen in a session that
  /// has already had its one chance to come back to where it was, and a second
  /// attempt would be a selection appearing under the user's hands because a
  /// list was re-read.
  Future<void> reload() async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    await _fetch(endpoint);
  }

  /// Whether a [refresh] is waiting on the gateway. The picker's Refresh is
  /// unavailable while it is.
  ///
  /// It covers the list request and the re-check of chosen media that follows
  /// the answer, and nothing after: the chosen workflow's schema, re-read once
  /// the new list is on screen (T-0236), is not waited for here.
  bool get isRefreshing => _refreshing;

  /// Reads the list again **without leaving [RegistryPhase.ready]** (T-0017).
  ///
  /// This is the difference from [reload], and the whole reason it is a second
  /// method: [reload] passes through [RegistryPhase.loading], which the shell
  /// draws as a spinner *in place of* the chosen workflow and its form. That is
  /// the reconnect's business and stays so. A person pressing Refresh, or
  /// coming back to the app, is in the middle of a form, so here the phase, the
  /// list on screen and the form under it all stay exactly where they are while
  /// the request runs, and only [isRefreshing] says that one is.
  ///
  /// What an answer does is what [reload]'s answer does, by the same code: the
  /// list is replaced, a chosen workflow the list no longer carries is reported
  /// by [missingSelection] and its form kept, and the chosen media are
  /// re-checked. The chosen workflow, every draft and every setup are
  /// untouched.
  ///
  /// Every field schema already fetched is marked stale (T-0236). The chosen
  /// workflow's is asked for again straight away — once the new list has been
  /// applied and announced, and without this waiting for it, so a list never
  /// waits on a schema — with its form left on screen while that runs; any
  /// other is asked for again the
  /// next time it is chosen. A schema that comes back the same keeps its form,
  /// the very object. One that changed gets a new form, built the way a
  /// workflow is opened — the curator's defaults, then My defaults — with what
  /// the old form holds laid over them by the rules a setup is applied with, so
  /// what still fits is kept and what does not (a field gone, a kind changed, a
  /// number now out of range, an option removed) is dropped; the translation
  /// switch comes with it, and the old form is disposed. A schema that could
  /// not be read again keeps the old form and says nothing.
  ///
  /// A failure changes nothing either: the list already shown is kept and
  /// stays usable, and the failure is *returned* rather than stored, so the one
  /// screen that asked is the one that says it. `null` is an answer that
  /// arrived, a refresh that was not started (no server, a list that is not
  /// [RegistryPhase.ready], one already running) and one overtaken by a newer
  /// request.
  Future<WorkflowsFailure?> refresh() async {
    final endpoint = _endpoint;
    if (endpoint == null || _phase != RegistryPhase.ready || _refreshing) {
      return null;
    }
    final token = ++_listToken;
    bool current() =>
        !_disposed && token == _listToken && _endpoint == endpoint;
    _refreshing = true;
    _notify();
    WorkflowsFailure? failed;
    try {
      final workflows = await api.list(endpoint);
      if (!current()) return null;
      final chosenName = selectedSummary?.name ?? _selectedId;
      _workflows = workflows;
      _loadedAt = _now();
      _listArrivals++;
      _staleDetails.addAll(_details.keys);
      _dropMissingSelection(chosenName);
      await _restoreMediaSelections();
      if (!current()) return null;
    } on WorkflowsFailure catch (failure) {
      if (!current()) return null;
      failed = failure;
    }
    _refreshing = false;
    _notify();
    if (failed == null) _rereadSelectedBehind(endpoint, current);
    return failed;
  }

  /// [refresh], if the list is older than [registryStaleAfter] — what coming
  /// back to the foreground asks for (`app.dart`).
  ///
  /// Quiet by construction: the failure [refresh] returns is dropped here, so a
  /// return to the app that could not reach the PC says nothing and replaces
  /// nothing. A list that never arrived is not refreshed at all — the failed
  /// registry has its own Try again, and a loading one is already asking.
  Future<void> refreshIfStale() async {
    final loadedAt = _loadedAt;
    if (loadedAt == null) return;
    if (_now().difference(loadedAt) < registryStaleAfter) return;
    await refresh();
  }

  /// What [restoring] offered and the registry confirmed, or `null` — which is
  /// every other case, including a list that never arrived.
  Future<String?> _fetch(
    Endpoint endpoint, {
    Future<String?>? restoring,
  }) async {
    _phase = RegistryPhase.loading;
    _failure = null;
    // Overtakes a refresh still in flight: its answer is older than this one's
    // will be, and it is dropped when it arrives.
    final token = ++_listToken;
    bool current() =>
        !_disposed && token == _listToken && _endpoint == endpoint;
    _refreshing = false;
    _notify();

    String? restored;
    try {
      final workflows = await api.list(endpoint);
      if (_disposed || _endpoint != endpoint) return null;
      // The name is read before the new list replaces the old one, because
      // afterwards there is nothing left to read it from.
      var chosenName = selectedSummary?.name ?? _selectedId;
      _workflows = workflows;
      _phase = RegistryPhase.ready;
      _loadedAt = _now();
      _listArrivals++;
      _staleDetails.addAll(_details.keys);
      // The launch's remembered workflow is adopted *here*, above the check
      // below, and that placement is the whole design: a remembered workflow
      // the gateway no longer serves is then reported and cleared by the very
      // branch a mid-session disappearance goes through, rather than by a
      // second rule about restoration that could disagree with it.
      if (restoring != null && _selectedId == null) {
        // **The registry is published before the file is waited for.** A
        // preference read that never answers then costs a restored selection
        // and nothing else — never the list, and never a screen with no end,
        // which is the first thing `docs/ui-ux.md` lists under "Never". It
        // costs nothing in the ordinary case either: the read was started
        // beside the request that just came back, so it has almost always
        // already completed, and awaiting a completed future yields to the
        // microtask queue rather than to the frame — both updates land in the
        // same frame and there is nothing to see.
        _notify();
        restored = await restoring;
        if (_disposed || _endpoint != endpoint) return null;
        if (_selectedId != null) {
          // Somebody chose a workflow while the file was being read. Theirs
          // wins — a tap must never be undone by an answer that arrives late.
          restored = null;
        } else if (restored != null) {
          _selectedId = restored;
          // Named for the same reason the line above names it: this launch
          // never saw a summary for this workflow, so its id is the most the
          // app honestly knows to call it by if it turns out to be gone.
          chosenName = selectedSummary?.name ?? restored;
        }
      }
      if (_dropMissingSelection(chosenName)) restored = null;
      // Reaching the registry again is the restore point `docs/recovery.md`
      // describes, and a chosen file is only restored *while still valid*: one
      // whose permission has lapsed is dropped here, so the field shows its
      // requirement again instead of failing at upload later on.
      await _restoreMediaSelections();
      if (_disposed || _endpoint != endpoint) return null;
    } on WorkflowsFailure catch (failure) {
      if (_disposed || _endpoint != endpoint) return null;
      _failure = failure;
      _phase = RegistryPhase.failed;
      // A list that did not arrive vouches for nothing, so nothing is
      // restored: opening a workflow no registry confirmed is exactly the
      // "somebody else's workflow" this store is scoped to prevent. The memory
      // is kept — the user retries, or the next launch tries again.
      restored = null;
    }
    _notify();
    if (_phase == RegistryPhase.ready) _rereadSelectedBehind(endpoint, current);
    return restored;
  }

  /// Asks for the chosen workflow's schema again once a list is on screen
  /// (T-0236), and says so only if its form was replaced.
  ///
  /// Deliberately not awaited, by either caller. A reconnect awaits [reload]
  /// before it recovers the job that may be in flight
  /// (`session_controller.dart`), and that recovery must not wait on a form;
  /// and a list [refresh] read must reach the screen the moment it arrives,
  /// not after a schema that may take the whole request timeout to answer.
  ///
  /// [current] is the list request's own token, so the re-read belongs to the
  /// list that started it: a change of server, or a newer list asked for
  /// meanwhile — whose own re-read follows it — leaves its answer unwritten.
  void _rereadSelectedBehind(Endpoint endpoint, bool Function() current) {
    unawaited(
      _refetchSelectedIfStale(endpoint, current).then((swapped) {
        if (swapped && current()) _notify();
      }),
    );
  }

  /// Asks for the chosen workflow's schema again if a list arrived since it was
  /// read, and answers whether its form was replaced.
  Future<bool> _refetchSelectedIfStale(
    Endpoint endpoint,
    bool Function() current,
  ) async {
    final id = _selectedId;
    if (id == null || !_staleDetails.contains(id)) return false;
    return _refetchStale(id, endpoint, current);
  }

  /// Reads [workflowId]'s schema again and reconciles the form with it.
  /// Answers whether the form was replaced.
  ///
  /// Nothing is drawn in the old one's place while this runs, and a failure
  /// changes nothing and says nothing: the form on screen was built from a
  /// schema the server did serve, and the mark stays, so choosing the workflow
  /// again asks again. [current] is the request's token — an answer that
  /// arrives after the server changed, or after a newer list was asked for,
  /// writes nothing.
  Future<bool> _refetchStale(
    String workflowId,
    Endpoint endpoint,
    bool Function() current,
  ) async {
    final WorkflowDetail fresh;
    try {
      fresh = await api.detail(endpoint, workflowId);
    } on WorkflowsFailure {
      return false;
    }
    if (!current()) return false;
    final cached = _details[workflowId];
    final old = _forms[workflowId];
    if (cached == null || old == null) return false;
    // Compared by value over everything the parser kept
    // (`WorkflowDetail.==`). The same schema keeps the form, object and all.
    if (fresh == cached) {
      _staleDetails.remove(workflowId);
      return false;
    }
    return _replaceForm(fresh, old, current);
  }

  /// Builds the form for a changed schema and puts it where [old] was.
  ///
  /// `_remember`'s layering, in its order: the curator's defaults (the new
  /// form is born with them), then My defaults and the saved translation
  /// answer, then — in the draft's place — what [old] holds now, through
  /// [WorkflowFormController.adoptDraft], which admits values by the rules a
  /// setup is applied with and drops what the new schema cannot honour. The
  /// switch in force beside the prompt is carried as it stands, and so is
  /// whether Advanced was open.
  ///
  /// [old] is read after the last store read, so nothing typed while those ran
  /// is lost, and it stays in place until the swap: nothing else is shown in
  /// the meantime. The autosave follows the new form from the swap on, the old
  /// one is disposed, and the setups are not touched.
  ///
  /// **Chosen media move with the form.** Where the new schema still declares
  /// the same field id with the same media kind, the old form's controller is
  /// handed to the new one — the object, so a picture still uploading keeps
  /// uploading and lands in the new form — and the old form's dispose leaves
  /// it alone. A media field the schema declares no longer, or declares as the
  /// other kind, keeps its controller in the old form and is disposed with it;
  /// there is no way to cancel an upload (`MediaApi.upload` takes none), so
  /// one in flight is abandoned: the request runs out and its answer is
  /// dropped by the disposed controller, as when the server changes. A handed
  /// choice is then checked again where it now lives, by the path a restore
  /// uses, and one whose file is gone is dropped. A media field declares
  /// nothing else a choice could stop fitting (`docs/workflow-schema.md`).
  Future<bool> _replaceForm(
    WorkflowDetail detail,
    WorkflowFormController old,
    bool Function() current,
  ) async {
    final id = detail.id;
    bool stillOld() => current() && identical(_forms[id], old);
    // Every store is read before the form is built, so a replacement that is
    // overtaken meanwhile has taken nothing from the old form.
    var stored = const <String, Object?>{};
    var translate = true;
    final store = settings;
    if (store != null) {
      stored = await store.load(id);
      if (!stillOld()) return false;
      translate = await store.loadTranslateOverride(id);
      if (!stillOld()) return false;
    }
    final form = WorkflowFormController(
      detail,
      picker: mediaPicker,
      uploader: mediaApi == null ? null : _upload,
      inspector: clipInspector,
      takingMediaFrom: old,
    );
    if (stored.isNotEmpty) form.adoptMyDefaults(stored);
    if (!translate) form.adoptTranslateDefault(translate);
    form.adoptDraft(old.currentDraft());
    form.translatePrompt = old.translatePrompt;
    form.advancedOpen = old.advancedOpen;

    final watcher = _draftWatchers.remove(id);
    if (watcher != null) old.removeListener(watcher);
    _details[id] = detail;
    _forms[id] = form;
    _staleDetails.remove(id);
    if (drafts != null) _watchForDraft(id, form);
    old.dispose();
    await form.restoreMediaSelections();
    return true;
  }

  /// Reports and clears a selection the list just read no longer carries, and
  /// answers whether it did. [chosenName] is read by the caller *before* the
  /// new list replaced the old one, because afterwards there is nothing left to
  /// read it from.
  ///
  /// One branch for the fetch and for the refresh, so the two cannot come to
  /// disagree about what a vanished workflow looks like.
  bool _dropMissingSelection(String? chosenName) {
    // A selection whose workflow the server no longer publishes is gone —
    // and is *said* to be gone. `docs/recovery.md`: a workflow missing from
    // a refreshed registry is reported, never silently substituted, and the
    // prompt typed into it survives, so the form is kept rather than
    // disposed.
    if (_selectedId == null || selectedSummary != null) return false;
    _missingSelection = chosenName;
    _selectedId = null;
    _detailLoading = false;
    _detailFailure = null;
    _selectionToken++;
    // Nothing is open now, so nothing is remembered. Without this the next
    // launch would restore the same absent workflow and report it gone
    // again, every time.
    _forgetSelection();
    return true;
  }

  /// The workflow this launch should come back to, or `null`.
  ///
  /// Returns a future rather than awaiting one, so the read runs beside the
  /// registry request. `null` for a build that keeps no selection and for a
  /// session that has already chosen something — neither has anything to read.
  ///
  /// **It never throws.** `selected_workflow_store.dart` already answers
  /// `null` for everything it can meet — an empty file, unreadable contents,
  /// another server's memory — and this catch is for an implementation that
  /// throws anyway: a platform channel that refuses, or a store some other
  /// composition handed over. A launch must not fail because a preference file
  /// would not open; the cost of one that will not is the launch every build
  /// before this one had.
  Future<String?>? _rememberedSelection() {
    final store = selection;
    if (store == null || _selectedId != null) return null;
    final endpoint = _endpoint;
    if (endpoint == null) return null;
    return store.load(endpoint).onError<Object>((_, _) => null);
  }

  /// Writes down what is open, against the server it is open on.
  ///
  /// Not awaited, for the reason the draft's own write is not: a preference
  /// file is not something a tap waits on. And not fatal — a device that
  /// cannot write simply forgets, which is what it did before this store
  /// existed.
  void _rememberSelection(String workflowId) {
    final store = selection;
    final endpoint = _endpoint;
    if (store == null || endpoint == null) return;
    unawaited(
      store.remember(endpoint, workflowId).onError<Object>((_, _) {}),
    );
  }

  /// Forgets it, on the same terms.
  void _forgetSelection() {
    final store = selection;
    if (store == null) return;
    unawaited(store.forget().onError<Object>((_, _) {}));
  }

  /// Chooses a workflow and makes sure its field schema is loaded.
  ///
  /// Choosing one already chosen changes nothing at all — in particular it
  /// does not reset the form, which is what returning from the picker without
  /// changing your mind must feel like.
  ///
  /// A schema a list has arrived since (T-0236) is the one exception, chosen or
  /// not: its form is shown at once, as it is, and the schema is asked for
  /// again behind it — the same reconciliation [refresh] gives the chosen
  /// workflow.
  Future<void> select(String workflowId) async {
    final stale = _staleDetails.contains(workflowId);
    if (_selectedId == workflowId &&
        _details.containsKey(workflowId) &&
        !stale) {
      return;
    }
    final endpoint = _endpoint;
    _selectedId = workflowId;
    _detailFailure = null;
    _missingSelection = null;
    // Written here rather than after the schema arrives, because what is being
    // remembered is the choice and not the request: a process killed while the
    // detail was still in flight was still a process on this workflow.
    _rememberSelection(workflowId);
    if (_details.containsKey(workflowId) || endpoint == null) {
      _detailLoading = false;
      _notify();
      if (stale && endpoint != null) {
        final listToken = _listToken;
        final swapped = await _refetchStale(
          workflowId,
          endpoint,
          () => !_disposed && listToken == _listToken && _endpoint == endpoint,
        );
        if (swapped) _notify();
      }
      return;
    }
    final token = ++_selectionToken;
    _detailLoading = true;
    _notify();
    try {
      final detail = await api.detail(endpoint, workflowId);
      if (_disposed || token != _selectionToken) return;
      await _remember(detail);
      if (_disposed || token != _selectionToken) return;
    } on WorkflowsFailure catch (failure) {
      if (_disposed || token != _selectionToken) return;
      _detailFailure = failure;
    }
    if (_disposed || token != _selectionToken) return;
    _detailLoading = false;
    _notify();
  }

  /// Tries the failed detail request again.
  Future<void> retrySelected() async {
    final id = _selectedId;
    if (id == null) return;
    _details.remove(id);
    _staleDetails.remove(id);
    _selectedId = null;
    await select(id);
  }

  /// Goes back to having chosen nothing. The forms stay.
  ///
  /// And so does every draft. What is forgotten is one thing only — *which*
  /// workflow was open — so the next launch opens on nothing, and a workflow
  /// chosen again still comes back with what was typed into it.
  void clearSelection() {
    if (_selectedId == null) return;
    _forgetSelection();
    _selectedId = null;
    _detailLoading = false;
    _detailFailure = null;
    _selectionToken++;
    _notify();
  }

  /// The field schema for a workflow, fetched if it is not already known.
  ///
  /// The help sheet uses this to show the defaults a workflow actually
  /// carries. It returns `null` rather than throwing: a sheet that cannot show
  /// one optional section is not an error worth a dialog.
  Future<WorkflowDetail?> detailFor(String workflowId) async {
    final cached = _details[workflowId];
    if (cached != null) return cached;
    final endpoint = _endpoint;
    if (endpoint == null) return null;
    try {
      final detail = await api.detail(endpoint, workflowId);
      if (_disposed) return detail;
      await _remember(detail);
      if (_disposed) return detail;
      _notify();
      return detail;
    } on WorkflowsFailure {
      return null;
    }
  }

  /// Keeps the schema, and builds the form for it if there is not one yet.
  ///
  /// This is where the layering `docs/ui-ux.md`'s form stands on happens, in
  /// its one order: the curator's defaults seed the form, the user's own —
  /// read from [settings] by workflow id and logical field id — are laid over
  /// them, and the current draft is laid over that. A workflow with nothing
  /// saved and nothing drafted gets exactly the form it got before either
  /// store existed.
  ///
  /// The autosave starts watching only once all three layers are in place. A
  /// listener attached earlier would see the form being built, take the
  /// curator's own defaults for something the user did, and write them down
  /// as a draft — which would then mask the curator's next change to them for
  /// a workflow nobody had even touched.
  Future<void> _remember(WorkflowDetail detail) async {
    _details[detail.id] = detail;
    final existing = _forms[detail.id];
    if (existing != null) return;
    final form = WorkflowFormController(
      detail,
      picker: mediaPicker,
      uploader: mediaApi == null ? null : _upload,
      inspector: clipInspector,
    );
    _forms[detail.id] = form;
    final store = settings;
    if (store != null) {
      final stored = await store.load(detail.id);
      // The endpoint may have changed while that was in flight, and changing
      // it disposes every form. Writing into the old one would throw, and
      // would be laying one server's defaults over another server's workflow.
      if (_disposed || !identical(_forms[detail.id], form)) return;
      if (stored.isNotEmpty) form.adoptMyDefaults(stored);
      final translate = await store.loadTranslateOverride(detail.id);
      if (_disposed || !identical(_forms[detail.id], form)) return;
      // Read beside the values and applied beside them. A workflow the user
      // asked this device to stop translating opens that way again on the next
      // launch — that is what a saved default *is*, and it is not a stale
      // hidden state: the switch beside the prompt shows it, and either reset
      // moves it somewhere the same switch shows.
      if (!translate) form.adoptTranslateDefault(translate);
    }
    final draftStore = drafts;
    if (draftStore != null) {
      final draft = await draftStore.load(detail.id);
      if (_disposed || !identical(_forms[detail.id], form)) return;
      if (!draft.isEmpty) form.adoptDraft(draft);
      _watchForDraft(detail.id, form);
    }
    final setupStore = setups;
    if (setupStore != null) {
      final saved = await setupStore.load(detail.id);
      if (_disposed || !identical(_forms[detail.id], form)) return;
      // Read so they can be listed, and laid over nothing. A setup is the one
      // of the three that is not a layer: the form a workflow opens with is
      // the same form it opened with before this card existed, however many
      // setups are saved for it.
      _setups[detail.id] = saved;
    }
  }

  /// The setups saved for [workflowId], in the store's own stable order.
  ///
  /// Empty for a workflow nobody has saved one for, and empty on a build that
  /// keeps none — the caller cannot tell those apart and does not need to,
  /// because [setups] being `null` is what removes the affordances.
  List<WorkflowSetup> setupsFor(String workflowId) =>
      _setups[workflowId] ?? const <WorkflowSetup>[];

  /// Whether a setup could be saved for [workflowId] right now.
  ///
  /// False on a build that keeps none, and false where this session has no
  /// form for that workflow — a result recovered into a session that never
  /// opened it is the case (`docs/recovery.md`). There is nothing to read the
  /// user's own words out of then, and an affordance that asked for a name
  /// and saved nothing would be worse than one that is not there.
  bool canSaveSetupFor(String workflowId) =>
      setups != null && _forms.containsKey(workflowId);

  /// Saves what is in [workflowId]'s form as a new setup called [name].
  ///
  /// The values come from the form — the **original** prose the user typed
  /// and the settings they are looking at — and never from a job payload,
  /// which carries the effective text of a translated submission and the
  /// values as they were bound (`docs/api.md`). That is also what makes this
  /// the right method for "save this result as a setup": the result's
  /// workflow is named here, and its form is where the user's own words are.
  Future<WorkflowSetup?> saveSetup({
    required String workflowId,
    required String name,
  }) async {
    final store = setups;
    final form = _forms[workflowId];
    if (store == null || form == null) return null;
    final setup = await store.create(
      workflowId: workflowId,
      name: name,
      // One rule about what may be persisted, shared with the draft.
      values: form.draftableValues(),
    );
    await _refreshSetups(workflowId);
    return setup;
  }

  /// Puts a new seed in [workflowId]'s form — what Generate Again asks for.
  ///
  /// Named for the workflow the generation was submitted for, never for
  /// whichever one is selected now: the button belongs to a result, and the
  /// form it varies has to be the one that produced it.
  ///
  /// Everything else in that form is left untouched, and a workflow that
  /// declared no seed, or whose seed the user froze, is left untouched
  /// entirely ([WorkflowFormController.varySeed]).
  void varySeedFor(String workflowId) => _forms[workflowId]?.varySeed();

  /// Puts [setup] back into its own workflow's form.
  ///
  /// Only into its own: the setup names the workflow it belongs to, so a
  /// setup can never be applied to a form it was not saved from. What the
  /// workflow can no longer honour is dropped by the form
  /// ([WorkflowFormController.adoptSetup]) rather than loaded into a field
  /// that could not validate.
  void applySetup(WorkflowSetup setup) {
    _forms[setup.workflowId]?.adoptSetup(setup);
  }

  /// Gives [setup] another name. Nothing else about it changes — not its id,
  /// not its values, and not whether applying it still works.
  Future<void> renameSetup(WorkflowSetup setup, String name) async {
    final store = setups;
    if (store == null) return;
    await store.rename(setup.id, name);
    await _refreshSetups(setup.workflowId);
  }

  /// Forgets exactly [setup], and nothing that happens to share its name.
  Future<void> deleteSetup(WorkflowSetup setup) async {
    final store = setups;
    if (store == null) return;
    await store.delete(setup.id);
    await _refreshSetups(setup.workflowId);
  }

  /// Re-reads one workflow's setups from the store after a change to them.
  ///
  /// Read back rather than patched in memory: the store decides the order and
  /// what a document holds, and a list assembled here would be a second
  /// answer to that.
  Future<void> _refreshSetups(String workflowId) async {
    final store = setups;
    if (store == null) return;
    final saved = await store.load(workflowId);
    if (_disposed) return;
    _setups[workflowId] = saved;
    _notify();
  }

  /// Follows one form from now on, so that what the user does to it is kept.
  void _watchForDraft(String workflowId, WorkflowFormController form) {
    void onChanged() => _draftChanged(workflowId);
    _draftWatchers[workflowId] = onChanged;
    form.addListener(onChanged);
  }

  /// One change in one form: the write is put off until the changes stop.
  ///
  /// Deliberately not a write. Typing notifies once per keystroke and a
  /// dragged slider once per pixel, and a store called that often is battery
  /// and flash spent on a value that is about to be replaced.
  void _draftChanged(String workflowId) {
    if (_disposed || drafts == null) return;
    _unsavedDrafts.add(workflowId);
    _draftTimer?.cancel();
    _draftTimer = _newDraftTimer(draftDebounce, () {
      _draftTimer = null;
      unawaited(flushDrafts());
    });
  }

  /// Writes every draft that is waiting, now.
  ///
  /// Called when the app leaves the foreground (`app.dart`), which is the last
  /// moment Android promises before it may kill the process, and when the
  /// endpoint changes and the forms are about to go. Every form it needs is
  /// read before the first `await` for exactly that second reason: the caller
  /// may be about to dispose them.
  Future<void> flushDrafts() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    final store = drafts;
    if (store == null || _unsavedDrafts.isEmpty) return;
    final pending = <String, WorkflowDraft>{};
    final scopes = <String, Set<String>>{};
    for (final workflowId in _unsavedDrafts) {
      final form = _forms[workflowId];
      if (form == null) continue;
      pending[workflowId] = form.currentDraft();
      scopes[workflowId] = form.draftableFieldIds;
    }
    _unsavedDrafts.clear();
    for (final entry in pending.entries) {
      await store.save(
        entry.key,
        entry.value,
        draftableFields: scopes[entry.key]!,
      );
    }
  }

  /// Keeps the chosen workflow's current settings as the user's defaults.
  ///
  /// What "safe" means is `isSafeToKeep`, and nothing here overrules it: no
  /// prompt and no media reference leaves this method.
  Future<void> saveMyDefaults() async {
    final store = settings;
    final workflowId = _selectedId;
    final form = this.form;
    if (store == null || workflowId == null || form == null) return;
    final values = form.keepableValues();
    form.adoptMyDefaults(values);
    // Over every field that could carry a default, not only the ones that do:
    // a setting the user cleared has to lose its stored value here rather
    // than come back on the next launch.
    await store.save(
      workflowId,
      values,
      declaredFields: form.keepableFieldIds,
    );
    // And the one thing that travels beside them. It is written the same way
    // a cleared field is: switching translation back on erases the override
    // rather than writing a second kind of "on", so there is one
    // representation of "nothing was said" across both stores.
    form.noteTranslateDefault(form.translatePrompt);
    await store.saveTranslateOverride(workflowId, form.translatePrompt);
  }

  /// Everything this device has saved, as one portable document.
  ///
  /// Nothing here asks the gateway anything. The document is built from two
  /// local stores and handed to the system; no request is made, and the
  /// registry, the current job and the endpoint are not read at all.
  ///
  /// Answers `false` on a build that cannot do it, and throws a
  /// [ProfileFailure] when the hand-over itself failed.
  Future<bool> exportProfile() async {
    final transport = profiles;
    final exchange = _exchange;
    if (transport == null || exchange == null) return false;
    final profile = await exchange.export();
    await transport.send(
      ProfileDocument(
        text: encodeProfile(profile),
        filename: kProfileFilename,
      ),
    );
    return true;
  }

  /// Asks the user for a profile and lays it over what this device has.
  ///
  /// `null` is "no document" — the build cannot import, or the user chose
  /// nothing, and neither is worth a sentence afterwards. A document that is
  /// not a profile, or is from a newer major version, throws a
  /// [ProfileFailure] and changes nothing at all.
  ///
  /// A **merge**, and never a replacement: `profile_exchange.dart` owns that
  /// rule. What it changes here is only what the open forms are allowed to
  /// know — the imported defaults are *recorded* rather than laid over a form
  /// the user is looking at, and the setups list is re-read so the new ones
  /// can be seen. The values themselves arrive by the ordinary route: the user
  /// pressing "Reset settings to my defaults", or the workflow being opened
  /// again.
  Future<ProfileImportReport?> importProfile({String? typeLabel}) async {
    final transport = profiles;
    final exchange = _exchange;
    if (transport == null || exchange == null) return null;
    final text = await transport.receive(typeLabel: typeLabel);
    if (text == null) return null;
    final profile = decodeProfile(text);
    final report = await exchange.merge(profile);
    if (_disposed) return report;
    await _rereadStores();
    return report;
  }

  /// The two stores this controller was given, as the one thing that reads and
  /// writes both of them whole. `null` on a build without both.
  ProfileExchange? get _exchange {
    final settingsStore = settings;
    final setupStore = setups;
    if (settingsStore == null || setupStore == null) return null;
    return ProfileExchange(settings: settingsStore, setups: setupStore);
  }

  /// Reads My defaults and the setups again for every workflow this session
  /// has open, after something outside the form changed them.
  ///
  /// Recorded, not applied. A form the user is looking at keeps every value
  /// that is in it — an import is not a reason to rewrite the number under
  /// somebody's finger — and what changes is that there is now something to go
  /// back to, which the interface shows as the way back appearing.
  Future<void> _rereadStores() async {
    final settingsStore = settings;
    if (settingsStore != null) {
      for (final entry in _forms.entries.toList(growable: false)) {
        final stored = await settingsStore.load(entry.key);
        final translate = await settingsStore.loadTranslateOverride(entry.key);
        if (_disposed || !identical(_forms[entry.key], entry.value)) return;
        entry.value.noteMyDefaults(stored);
        entry.value.noteTranslateDefault(translate);
      }
    }
    for (final workflowId in _setups.keys.toList(growable: false)) {
      await _refreshSetups(workflowId);
    }
    _notify();
  }

  /// Sends one file to the server this controller is pointed at.
  ///
  /// The endpoint is read at the moment of the upload rather than captured
  /// when the form was built, because a form outlives a reconnect and the
  /// address may have been re-entered in between.
  Future<UploadedMedia> _upload(
    MediaSelection selection,
    MediaProgress onProgress,
  ) {
    final endpoint = _endpoint;
    final api = mediaApi;
    if (endpoint == null || api == null) {
      throw const MediaFailure.unreachable();
    }
    return api.upload(endpoint, selection, onProgress: onProgress);
  }

  Future<void> _restoreMediaSelections() async {
    for (final form in _forms.values.toList(growable: false)) {
      await form.restoreMediaSelections();
    }
  }

  /// Everything a change of server takes with it.
  ///
  /// **It does not forget which workflow was open, and that is deliberate.**
  /// What is written down is the pair *(server, workflow)*, and a memory that
  /// names server A is already ignored while the app is pointed at server B
  /// (`selected_workflow_store.dart`) — so erasing it here would buy nothing
  /// and would cost the user their place on A the moment they glanced at B.
  void _clearSelectionState() {
    _selectedId = null;
    _detailLoading = false;
    _detailFailure = null;
    _missingSelection = null;
    _selectionToken++;
    _details.clear();
    _staleDetails.clear();
    // The forms belong to the server they were built from, and so does this
    // list of what is saved for them. Nothing is deleted by clearing it: the
    // store is untouched and the next workflow that is opened reads its own
    // setups again.
    _setups.clear();
    // Before the forms go: what the user typed into them belongs to the
    // workflow, not to the server it was reached through, and a change of
    // address is no reason to lose the last two seconds of it.
    unawaited(flushDrafts());
    _stopWatchingDrafts();
    for (final form in _forms.values) {
      form.dispose();
    }
    _forms.clear();
  }

  void _stopWatchingDrafts() {
    for (final entry in _draftWatchers.entries) {
      _forms[entry.key]?.removeListener(entry.value);
    }
    _draftWatchers.clear();
    _unsavedDrafts.clear();
    _draftTimer?.cancel();
    _draftTimer = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Nothing is flushed here, deliberately. This runs when the app itself is
    // being torn down, by which point the lifecycle callback has already
    // written (`app.dart`), and a write started here would land after the
    // object that owns it is gone.
    _stopWatchingDrafts();
    for (final form in _forms.values) {
      form.dispose();
    }
    _forms.clear();
    super.dispose();
  }
}
