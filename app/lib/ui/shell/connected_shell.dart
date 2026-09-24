/// The connected shell, adaptive on available width (`docs/ui-ux.md`).
///
/// One column when the window is narrow, two panes when it is wide — decided
/// by [BoxConstraints.maxWidth] alone. Nothing here asks what device this is,
/// whether it folds, or which way it is held, because none of those questions
/// has a reliable answer and width is the thing that actually changes.
///
/// Everything that is state lives above the layout branch — the disclosure in
/// this widget's [State], the chosen workflow and every value typed into its
/// form in [WorkflowsController], the job and its result in
/// [GenerationController]. That is what makes a fold a configuration change
/// rather than a restart: the two layouts are two ways of drawing the same
/// state, and the state does not know which one is on screen.
///
/// Two arrangements the contracts ask for are decided here rather than inside
/// a child widget:
///
/// * **The media is the hero.** Once there is something to show, the creation
///   area comes first in the narrow layout and the controls recede behind it.
/// * **Reconnecting never blanks anything.** The indicator is a line above the
///   layout and the recovery choices are a panel inside it; the result on
///   display is untouched by either.
///
/// **The split between the two panes is the user's, and only on the wide
/// layout** (T-0176). What used to be a constant is now a share of the window
/// that the divider can be dragged to, remembered on the device by
/// [PaneSplitStore]. Three things about it are deliberate and are easy to undo
/// by accident:
///
/// * a device that has never been dragged draws exactly the proportion it drew
///   before any of this existed — [LcLayout.defaultControlsShare] of the
///   window, clamped between [LcLayout.controlsPaneMin] and
///   [LcLayout.controlsPaneMax], which is the expression that used to sit
///   inline here;
/// * the remembered share is read by [_expanded] and by nothing else. The
///   narrow layout is one column and has no split, so there is nothing there
///   for it to mean;
/// * a pane the user *chose* is bounded by what leaves both sides usable —
///   [LcLayout.controlsPaneMin] on one side and [LcLayout.draggedCreationMin]
///   on the other — and not by [LcLayout.controlsPaneMax], which is a cap on
///   the app's own guess. On a tablet the guess is already at that cap, so
///   holding a decision to it would mean the picture could be widened and the
///   controls never could.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyUpEvent, LogicalKeyboardKey;

import '../../connection/connection_controller.dart';
import '../../connection/gateway_identity.dart';
import '../../connection/reconnect_attempts_store.dart';
import '../../generation/generation_controller.dart';
import '../../generation/session_controller.dart';
import '../../generation/translation.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/locale_controller.dart';
import '../../theme/pane_split_store.dart';
import '../common/label_value_row.dart';
import '../../theme/theme.dart';
import '../../theme/theme_mode_controller.dart';
import '../../theme/tokens.dart';
import '../../workflows/profile_exchange.dart';
import '../../workflows/workflow_form.dart';
import '../../workflows/workflow_models.dart';
import '../../workflows/workflow_profile.dart';
import '../../workflows/workflow_setup_store.dart';
import '../../workflows/workflows_controller.dart';
import '../common/brand.dart';
import '../common/notice_card.dart';
import '../generation/generation_surface.dart';
import '../keys.dart';
import '../workflows/setups_bar.dart';
import '../workflows/workflow_form_view.dart';
import '../workflows/workflow_picker.dart';
import 'appearance_bar.dart';
import 'language_bar.dart';
import 'profile_bar.dart';
import 'workflows_empty_state.dart';

class ConnectedShell extends StatefulWidget {
  const ConnectedShell({
    super.key,
    required this.session,
    this.appearance,
    this.language,
    this.split,
  });

  /// The connection, the registry and the generation, plus the reconnect that
  /// spans all three.
  final SessionController session;

  /// Which of the two brightnesses this device shows, if this build was given
  /// a say in it.
  ///
  /// Optional for the same reason the profile actions are absent on a build
  /// with no transport: a shell that was handed no theme choice draws no
  /// Appearance block, rather than drawing a dead one. The app always hands it
  /// one — `app.dart` cannot be built without it.
  final ThemeModeController? appearance;

  /// Which language this device shows, if this build was given a say in it.
  ///
  /// Optional for exactly the reason [appearance] is: a shell handed no
  /// language choice draws no Language block rather than a dead one. The app
  /// always hands it one — `app.dart` cannot be built without it.
  final LocaleController? language;

  /// Where the split the user dragged is remembered, if this build was given
  /// somewhere to remember it.
  ///
  /// Optional for the reason [appearance] and [language] are, and the absence
  /// means one specific thing: the divider still drags, because dragging is
  /// layout and not memory — it is only that the choice is gone at the next
  /// launch. Every test that does not care about persistence therefore builds
  /// this shell exactly as it always did.
  final PaneSplitStore? split;

  @override
  State<ConnectedShell> createState() => _ConnectedShellState();
}

class _ConnectedShellState extends State<ConnectedShell> {
  /// Held here, above the layout branch, so a resize cannot discard it.
  bool _serverDetailsOpen = false;

  /// The chosen workflow's disclosure, held here for exactly the same reason
  /// (T-0144). The two blocks look alike and now behave alike, which includes
  /// surviving a fold and a theme change: both of those rebuild this widget,
  /// and a `bool` living inside [SelectedWorkflowCard] would be rebuilt with
  /// it and come back closed.
  bool _workflowDetailsOpen = false;

  /// The one request the disclosure's Defaults section reads, made once per
  /// workflow and then handed out unchanged.
  ///
  /// A fresh `detailFor` future per build would restart the request on every
  /// keystroke in the form below the block and flicker the section between
  /// empty and filled. Keyed by workflow id so that choosing another one asks
  /// again — and kept here rather than in the card for the same reason the
  /// flag above is.
  Future<WorkflowDetail?>? _workflowDetails;
  String? _workflowDetailsId;

  /// The schema [_workflowDetails] answers with, once the controller holds
  /// one. A schema the PC changed replaces it there (T-0236), and a different
  /// object here is how the section learns to ask again.
  WorkflowDetail? _workflowDetailsFrom;

  /// The one column's scroll position, so that pressing Generate can bring
  /// the creation area back to where the user is looking.
  ///
  /// Attached by [_compact] and by nothing else. The two-pane layout has no
  /// scroll of its own to give this controller, so on a wide window it has no
  /// client at all and [_revealGeneration] is a no-op — which is the point:
  /// there the status is already on screen beside the form, and moving
  /// anything would only throw away the position of a controls pane the user
  /// is still reading.
  final ScrollController _compactScroll = ScrollController();

  /// The share of the window the user dragged the controls pane to, or `null`
  /// for a device nobody has ever dragged.
  ///
  /// Held here, above the layout branch, for the same reason the two
  /// disclosures above are: a fold rebuilds this widget's tree and anything
  /// living inside [_expanded] would come back as whatever the app guessed.
  /// `null` is not a default value dressed up as an absence — it is what makes
  /// "nobody has chosen" and "somebody chose 36%" behave differently the day
  /// the guess changes.
  double? _controlsShare;

  SessionController get _session => widget.session;
  ThemeModeController? get _appearance => widget.appearance;
  LocaleController? get _language => widget.language;
  ConnectionController get _controller => _session.connection;
  WorkflowsController get _workflows => _session.workflows;
  GenerationController get _generation => _session.generation;

  @override
  void initState() {
    super.initState();
    final endpoint = _controller.endpoint;
    if (endpoint != null) _workflows.load(endpoint);
    final split = widget.split;
    if (split != null) unawaited(_restoreSplit(split));
  }

  /// Reads the remembered split, unawaited and never in front of anything.
  ///
  /// **Nothing here throws, and nothing waits for it.** A preference file that
  /// will not open is a device that has never been dragged, which is a layout
  /// the app already knows how to draw. And a read that lands *after* the user
  /// has already dragged this session is discarded rather than applied: the
  /// pane must not jump out from under a finger because a file finally
  /// answered.
  Future<void> _restoreSplit(PaneSplitStore store) async {
    final double? stored;
    try {
      stored = await store.load();
    } catch (_) {
      return;
    }
    if (stored == null || !mounted || _controlsShare != null) return;
    setState(() => _controlsShare = stored);
  }

  @override
  void dispose() {
    _compactScroll.dispose();
    super.dispose();
  }

  /// Whether the creation area has something of its own to draw. Idle states
  /// leave it to the quiet placeholder.
  bool get _showsGeneration => switch (_generation.state) {
    LifecycleState.disconnected ||
    LifecycleState.connecting ||
    LifecycleState.ready ||
    LifecycleState.reconnecting => false,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable?>[
            _workflows,
            _generation,
            _session,
            // Belt and braces, and named as such. An earlier version of this
            // line claimed `MaterialApp` caches the page it was given, so the
            // rebuild could not arrive from above; that was measured and it is
            // not true on this Flutter version — removing this one entry
            // changes no test, because the rebuild does arrive from above. It
            // is kept because it costs nothing and makes this widget redraw on
            // a theme change by its own arrangement rather than by an
            // ancestor's. Nothing currently proves it necessary.
            widget.appearance,
            // The language, for the same reason and with the same standing.
            widget.language,
          ]),
          builder: (context, _) => Column(
            children: <Widget>[
              if (_session.isReconnecting || _generation.isReconnecting)
                const Padding(
                  padding: EdgeInsets.only(top: LcSpace.xs),
                  child: ReconnectingBar(),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final twoPane =
                        constraints.maxWidth >= LcLayout.twoPaneWidth;
                    return twoPane
                        ? _expanded(constraints.maxWidth)
                        : _compact();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One column. When there is something in the creation area it goes first —
  /// the media is the hero, and a result the user has to scroll past the form
  /// to find is not one (`docs/ui-ux.md`).
  Widget _compact() {
    final controls = SliverPadding(
      padding: const EdgeInsets.fromLTRB(LcSpace.md, LcSpace.md, LcSpace.md, 0),
      sliver: SliverToBoxAdapter(
        child: KeyedSubtree(key: LcKeys.controlsPane, child: _controlsColumn()),
      ),
    );
    if (_showsGeneration) {
      return CustomScrollView(
        key: LcKeys.shellCompact,
        controller: _compactScroll,
        slivers: <Widget>[
          SliverToBoxAdapter(child: _content()),
          controls,
          const SliverToBoxAdapter(child: SizedBox(height: LcSpace.lg)),
        ],
      );
    }
    return CustomScrollView(
      key: LcKeys.shellCompact,
      controller: _compactScroll,
      slivers: <Widget>[
        controls,
        SliverFillRemaining(hasScrollBody: false, child: _content()),
      ],
    );
  }

  /// How wide the controls pane is in a window of [width].
  ///
  /// Two expressions, and which one applies is decided by whether anybody has
  /// ever dragged this divider — never by which of them gives the nicer
  /// number:
  ///
  /// * nobody has: the app's own guess, which is the expression this method
  ///   replaced, character for character;
  /// * somebody has: their share of *this* window, held to what leaves both
  ///   sides usable. The cap on the guess does not apply to a decision.
  double _controlsPaneWidth(double width) {
    final chosen = _controlsShare;
    if (chosen == null) {
      return (width * LcLayout.defaultControlsShare).clamp(
        LcLayout.controlsPaneMin,
        LcLayout.controlsPaneMax,
      );
    }
    final (double narrowest, double widest) = _splitRange(width);
    return (chosen * width).clamp(narrowest, widest);
  }

  /// The narrowest and widest the controls pane may be dragged to, in a window
  /// of [width].
  ///
  /// The far end is stated as *what the creation area keeps*, because that is
  /// the thing being protected. On a window with no room to negotiate — the
  /// two-pane layout starts at [LcLayout.twoPaneWidth], which is less than the
  /// two minimums and the divider together — the two ends meet, and
  /// [_expanded] draws no handle at all rather than one that cannot move.
  ///
  /// The near end is [LcLayout.controlsPaneMin] — the same number the guess is
  /// floored at, kept after being measured again for this card rather than
  /// inherited. The far end is **not** [LcLayout.controlsPaneMax]: that one
  /// caps a guess, and a tablet's guess is already sitting on it.
  (double, double) _splitRange(double width) => (
    LcLayout.controlsPaneMin,
    math.max(
      LcLayout.controlsPaneMin,
      width - LcLayout.draggedCreationMin - _dividerWidth,
    ),
  );

  /// The divider moved by [dx].
  ///
  /// Derived from where the pane *is* rather than accumulated from where the
  /// drag started, so that pushing past either end and coming back does not
  /// have to pay back the distance first.
  void _moveSplit(double dx, double width) {
    final (double narrowest, double widest) = _splitRange(width);
    final moved = (_controlsPaneWidth(width) + dx).clamp(narrowest, widest);
    setState(() => _controlsShare = moved / width);
  }

  /// The gesture ended: write the share down.
  ///
  /// Written at the end of a drag and not on every frame of it — a preference
  /// file is not something to put between a finger and a layout, and the value
  /// that matters is the one the finger was lifted on. As with the theme, a
  /// write that could not happen costs this choice its next launch and nothing
  /// else.
  void _rememberSplit() {
    final share = _controlsShare;
    final store = widget.split;
    if (share == null || store == null) return;
    unawaited(() async {
      try {
        await store.save(share);
      } catch (_) {}
    }());
  }

  Widget _expanded(double width) {
    final paneWidth = _controlsPaneWidth(width);
    final (double narrowest, double widest) = _splitRange(width);
    return Stack(
      key: LcKeys.shellExpanded,
      fit: StackFit.expand,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              key: LcKeys.controlsPane,
              width: paneWidth,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(LcSpace.lg),
                child: _controlsColumn(),
              ),
            ),
            VerticalDivider(
              width: _dividerWidth,
              color: context.palette.outline,
            ),
            Expanded(child: _content()),
          ],
        ),
        // Laid *over* the divider rather than taking room beside it, so that
        // giving this app a grab area moved nothing on screen: the row above
        // is the row that was always there, down to the pixel. The handle
        // passes pointers through to whatever is under it, so the strip it
        // covers is not a strip where taps stop working.
        if (widest > narrowest)
          Positioned(
            top: 0,
            bottom: 0,
            left:
                paneWidth +
                _dividerWidth / 2 -
                LcLayout.splitHandleTouchWidth / 2,
            width: LcLayout.splitHandleTouchWidth,
            child: _SplitHandle(
              key: LcKeys.splitHandle,
              onMove: (dx) => _moveSplit(dx, width),
              onSettled: _rememberSplit,
            ),
          ),
      ],
    );
  }

  /// The controls side: who we are talking to, what is wrong with it if
  /// anything is, and the creation controls.
  ///
  /// It recedes once a result is on screen — dimmed, not removed, so it is
  /// still readable and still usable.
  Widget _controlsColumn() {
    final l = L.of(context);
    final notice = _controller.notice;
    final recovery = _session.failure;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ServerHeader(
          identity: _controller.identity,
          address: _controller.endpoint?.display ?? '',
          open: _serverDetailsOpen,
          busy: _controller.isBusy,
          onToggle: () =>
              setState(() => _serverDetailsOpen = !_serverDetailsOpen),
          onRecheck: _controller.refreshIdentity,
          onChooseAnother: _session.chooseAnotherServer,
          attempts: _session.attempts,
          // Absent on a build that cannot remember a choice, rather than a
          // stepper whose number would be forgotten at the next launch.
          onAttemptsChanged: _session.canChooseAttempts
              ? (count) => unawaited(_session.chooseAttempts(count))
              : null,
        ),
        if (recovery != null) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          // The bounded reconnect ran out. Two real decisions, and nothing on
          // screen was thrown away to show them (`docs/recovery.md`).
          KeyedSubtree(
            key: LcKeys.recoveryPanel,
            child: NoticeCard(
              notice: recovery,
              actions: <Widget>[
                FilledButton(
                  key: LcKeys.reconnectNow,
                  onPressed: _session.isReconnecting ? null : _session.reconnect,
                  child: Text(l.reconnect),
                ),
                TextButton(
                  key: LcKeys.chooseAnotherServer,
                  onPressed: _session.chooseAnotherServer,
                  child: Text(l.chooseAnotherServer),
                ),
              ],
            ),
          ),
        ] else if (notice != null) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          NoticeCard(
            notice: notice,
            actions: <Widget>[
              TextButton(
                onPressed: _controller.isBusy
                    ? null
                    : _controller.refreshIdentity,
                child: Text(l.checkAgain),
              ),
            ],
          ),
        ],
        if (_workflows.missingSelection != null) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          _MissingWorkflowPanel(
            name: _workflows.missingSelection!,
            onDismiss: _workflows.clearMissingSelection,
          ),
        ],
        ..._creationControls(),
        // Last, and outside the workflow: a profile is everything this device
        // has saved, not anything about the one workflow above it. Absent
        // whole on a build that cannot export or import one, which is the same
        // choice the defaults row and the setups list already make.
        if (_workflows.canExchangeProfile) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          ProfileBar(onExport: _exportProfile, onImport: _importProfile),
        ],
        // Last, and further outside the workflow than the profile is: the
        // profile is at least about what this app has saved, and this is about
        // the phone. Nothing above it is disturbed by changing it — the values
        // in the form live in the registry controller, Advanced's disclosure
        // lives in the form, and the two block disclosures live in this
        // widget's own `State`, so a theme change repaints the shell without
        // touching a word of what is in it or shutting anything that was open.
        if (_appearance case final appearance?) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          AppearanceBar(
            mode: appearance.mode,
            onChanged: (mode) => unawaited(appearance.choose(mode)),
          ),
        ],
        // Beside the theme, and last for the same reason it is last: this is
        // about the phone rather than about the workflow above it, and
        // changing it disturbs nothing on screen — every piece of state lives
        // above the layout branch, so a language change repaints the shell
        // without shutting a disclosure or losing a word of the form.
        if (_language case final language?) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          LanguageBar(
            choice: language.choice,
            onChanged: (choice) => unawaited(language.choose(choice)),
          ),
        ],
      ],
    );
    if (!_generation.hasResult) return column;
    return AnimatedOpacity(
      duration: LcMotion.normal,
      // Receding, not disappearing: everything stays readable and every
      // control still takes a tap.
      opacity: 0.62,
      child: column,
    );
  }

  List<Widget> _creationControls() {
    final l = L.of(context);
    switch (_workflows.phase) {
      case RegistryPhase.idle:
      case RegistryPhase.loading:
        return <Widget>[
          const SizedBox(height: LcSpace.lg),
          const Center(
            key: LcKeys.workflowsLoading,
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ];
      case RegistryPhase.failed:
        return <Widget>[
          const SizedBox(height: LcSpace.md),
          _FailurePanel(
            key: LcKeys.workflowsFailed,
            title: _workflows.failure?.title(l) ?? '',
            message: _workflows.failure?.message(l) ?? '',
            actionKey: LcKeys.workflowsRetry,
            actionLabel: l.tryAgain,
            onAction: _workflows.reload,
          ),
        ];
      case RegistryPhase.ready:
        if (_workflows.workflows.isEmpty) return const <Widget>[];
        final summary = _workflows.selectedSummary;
        if (summary == null) {
          return <Widget>[
            const SizedBox(height: LcSpace.md),
            FilledButton.icon(
              key: LcKeys.chooseWorkflow,
              onPressed: _openPicker,
              icon: const Icon(Icons.grid_view_rounded, size: 20),
              label: Text(l.chooseAWorkflow),
            ),
          ];
        }
        return <Widget>[
          const SizedBox(height: LcSpace.md),
          SelectedWorkflowCard(
            workflow: summary,
            onChange: _openPicker,
            open: _workflowDetailsOpen,
            onToggle: () =>
                setState(() => _workflowDetailsOpen = !_workflowDetailsOpen),
            // Asked for only once the disclosure is actually open, so a
            // closed block starts no request at all.
            detail: _workflowDetailsOpen ? _detailOf(summary.id) : null,
          ),
          const SizedBox(height: LcSpace.md),
          ..._formOrProgress(),
        ];
    }
  }

  /// The schema request behind the open disclosure, made at most once per
  /// workflow.
  ///
  /// Memoisation only: it starts nothing that was not going to be started, and
  /// it changes no state the build depends on, so calling it from `build` is
  /// safe. `detailFor` answers from its own cache when it can.
  ///
  /// Once the controller holds this workflow's schema, the memo follows that
  /// object: when a changed schema replaces it (T-0236) the section is handed
  /// the one now held, rather than the one it was first given.
  Future<WorkflowDetail?> _detailOf(String workflowId) {
    final held = _workflows.selectedDetail;
    final current = held != null && held.id == workflowId ? held : null;
    if (_workflowDetailsId != workflowId || _workflowDetails == null) {
      _workflowDetailsId = workflowId;
      _workflowDetailsFrom = current;
      _workflowDetails = _workflows.detailFor(workflowId);
    } else if (current != null && !identical(current, _workflowDetailsFrom)) {
      final replaced = _workflowDetailsFrom != null;
      _workflowDetailsFrom = current;
      // The first schema to arrive is the one the request already answers
      // with; only a replacement needs a new future.
      if (replaced) {
        _workflowDetails = Future<WorkflowDetail?>.value(current);
      }
    }
    return _workflowDetails!;
  }

  List<Widget> _formOrProgress() {
    final l = L.of(context);
    final detail = _workflows.selectedDetail;
    if (detail != null) {
      return <Widget>[
        WorkflowFormView(
          detail: detail,
          form: _workflows.form!,
          onGenerate: _onGenerate,
          // Absent on a build with nowhere to keep them, so the row of
          // affordances is absent too rather than doing nothing.
          onSaveDefaults: _workflows.settings == null ? null : _saveDefaults,
          // The same choice for setups, and made once: no store, no list, no
          // Save, nothing about setups anywhere in the form.
          setups: _workflows.setups == null
              ? null
              : SetupActions(
                  setups: _workflows.setupsFor(detail.id),
                  onSave: (name) => _saveSetup(detail.id, name),
                  onApply: _workflows.applySetup,
                  onRename: _renameSetup,
                  onDelete: _deleteSetup,
                ),
          // What the gateway did to the last submission's text, handed to the
          // form to *show*. The form's own values are untouched by it — the
          // prompt on screen is the one the user typed, before and after a
          // translated run.
          //
          // Only to the workflow it was actually about. `fields` is keyed by
          // field id, and `prompt` is the id half the registry uses, so
          // without this a translated run under one workflow would hang its
          // indicator on another workflow's prompt — over text that was never
          // sent anywhere.
          translation: _generation.workflowId == _workflows.selectedId
              ? _generation.translation
              : TranslationReport.none,
          // What the server said it can translate, straight from the
          // handshake. Unknown until one has been read, which is also what a
          // gateway older than the capability leaves it as.
          capability: _generation.capabilities.translation,
          // Generate is unavailable while a generation is progressing, because
          // the submission would be refused and the refusal would be silent
          // (T-0182). The predicate is the controller's own
          // [LifecycleState.isProgressing] rather than a second rule invented
          // here, so the button and the guard cannot come to disagree.
          //
          // It is deliberately *only* that predicate. `interrupted`, a
          // disconnect and a recovery that ended without an answer are all not
          // progress, so all three leave a screen the user can generate from
          // again (`docs/recovery.md`), and the subtle `Reconnecting…` above
          // this layout takes nothing away either.
          generationInFlight: _generation.state.isProgressing,
        ),
      ];
    }
    final failure = _workflows.detailFailure;
    if (failure != null) {
      return <Widget>[
        _FailurePanel(
          key: LcKeys.workflowsFailed,
          title: failure.title(l),
          message: failure.message(l),
          actionKey: LcKeys.workflowsRetry,
          actionLabel: l.tryAgain,
          onAction: _workflows.retrySelected,
        ),
      ];
    }
    return const <Widget>[
      Center(
        key: LcKeys.workflowsLoading,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    ];
  }

  Future<void> _openPicker() async {
    final chosen = await chooseWorkflow(
      context,
      workflows: _workflows.workflows,
      selectedId: _workflows.selectedId,
      detailLoader: _workflows.detailFor,
      // So the picker can offer Refresh and show what it brings (T-0017).
      registry: _workflows,
    );
    // Coming back without choosing leaves everything exactly as it was — that
    // is the whole reason the form does not live in this widget.
    if (chosen == null) return;
    await _workflows.select(chosen);
  }

  /// Keeps the chosen workflow's settings, and says so.
  ///
  /// The sentence names what was kept and where: "my defaults" is per
  /// workflow and lives on this device only, and a Save with no acknowledgement
  /// is a Save the user has to take on faith.
  Future<void> _saveDefaults() async {
    final name = _workflows.selectedSummary?.name;
    await _workflows.saveMyDefaults();
    if (!mounted || name == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.of(context).defaultsSavedFor(name))),
    );
  }

  /// Keeps what is in one workflow's form as a setup, and says so.
  ///
  /// The sentence names it, for the same reason the defaults one does: a Save
  /// with no acknowledgement is a Save the user has to take on faith.
  Future<void> _saveSetup(String workflowId, String name) async {
    final setup = await _workflows.saveSetup(
      workflowId: workflowId,
      name: name,
    );
    if (!mounted || setup == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.of(context).setupSavedAs(setup.name))),
    );
  }

  /// Writes the profile and hands it to the system.
  ///
  /// Nothing is said when it works: the share sheet is the acknowledgement,
  /// and the user is looking at whatever they chose to send it to. A failure
  /// is said out loud, because that is the case where nothing visible
  /// happened.
  Future<void> _exportProfile() async {
    try {
      await _workflows.exportProfile();
    } on ProfileFailure catch (failure) {
      if (!mounted) return;
      await showProfileProblem(context, failure);
    }
  }

  /// Asks for a profile and merges it, then says exactly what arrived.
  ///
  /// The sentence counts what was written rather than what the file contained,
  /// and says where the values went: an import does not reach into the form
  /// the user is looking at (`workflows_controller.dart`), so telling them the
  /// numbers changed on screen would be wrong.
  Future<void> _importProfile() async {
    final ProfileImportReport? report;
    try {
      report = await _workflows.importProfile(
        typeLabel: L.of(context).profileFileTypeLabel,
      );
    } on ProfileFailure catch (failure) {
      if (!mounted) return;
      await showProfileProblem(context, failure);
      return;
    }
    // No document: this build cannot import, or the user chose nothing.
    // Changing your mind is not an event worth a sentence.
    if (!mounted || report == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_importedSentence(L.of(context), report))),
    );
  }

  /// What an import did, in words and in the singular where there was one.
  ///
  /// The counting is the `.arb` file's, not this method's: Russian needs three
  /// forms where English needs two, and a `count == 1 ? … : …` here would give
  /// every language the English answer (T-0142).
  static String _importedSentence(L l, ProfileImportReport report) {
    if (report.isEmpty) return l.profileImportedNothing;
    final parts = <String>[
      if (report.workflows > 0) l.profileImportedWorkflows(report.workflows),
      if (report.setups > 0) l.profileImportedSetups(report.setups),
    ];
    return l.profileImported(
      parts.length == 2 ? l.listAnd(parts[0], parts[1]) : parts.single,
    );
  }

  Future<void> _renameSetup(WorkflowSetup setup, String name) =>
      _workflows.renameSetup(setup, name);

  Future<void> _deleteSetup(WorkflowSetup setup) async {
    await _workflows.deleteSetup(setup);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.of(context).setupIsGone(setup.name))),
    );
  }

  /// Keeps what produced the result on screen.
  ///
  /// It reads the form of the workflow the **generation** was submitted for,
  /// not of whatever is selected now, and not the job's own payload: the job
  /// carries the effective text of a translated submission and the values as
  /// they were bound, and neither of those is what the user wrote or saw
  /// (`docs/api.md`).
  Future<void> _saveResultAsSetup(String workflowId) async {
    final name = await askForSetupName(
      context,
      title: L.of(context).setupNameTitle,
      action: L.of(context).save,
    );
    if (name == null || !mounted) return;
    await _saveSetup(workflowId, name);
  }

  void _onGenerate(ValidatedForm validated) {
    final workflowId = _workflows.selectedId;
    if (workflowId == null || !validated.isReady) return;
    _workflows.requestGeneration(validated);
    _generation.submit(
      workflowId: workflowId,
      inputs: validated.inputs,
      // The user's choice for this workflow, for this submission. It is read
      // here and kept nowhere: no store, no draft, no second copy that could
      // disagree with the switch on screen.
      translate: _workflows.form?.translatePrompt ?? true,
    );
    _revealGeneration();
  }

  /// Generate Again: back to the form, with a new seed in it.
  ///
  /// The seed is varied **here** and not inside the generation controller,
  /// which holds a job and never touches the values a job was made of. It is
  /// varied in the form of the workflow this result was submitted for — not
  /// of whatever happens to be selected now — and nothing else in that form is
  /// touched, so what goes back the second time is the user's own work with
  /// one number moved. A workflow with no seed, and a seed the user froze, are
  /// both left exactly as they are ([WorkflowsController.varySeedFor]).
  ///
  /// The new number goes into the field, where it is on screen and where the
  /// next Generate will read it from. That is what keeps a result anyone likes
  /// reproducible: the seed shown is the seed that was used.
  void _onGenerateAgain() {
    final workflowId = _generation.workflowId;
    if (workflowId != null) _workflows.varySeedFor(workflowId);
    _generation.generateAgain();
  }

  /// Brings the creation area into view, for the layout where it is not.
  ///
  /// On the folded phone the form is longer than the screen, so Generate is
  /// below the fold — it belongs at the end of the form it submits — while
  /// the status and the arriving picture are above it. Pressing it is the
  /// moment a person stops composing and starts watching, and without this
  /// every generation ends with them scrolling back up to find out whether
  /// anything happened at all.
  ///
  /// It moves the one column and nothing else. On two panes [_compactScroll]
  /// has no client, because the column it belongs to is not built, so the
  /// wide layout cannot be scrolled from here even by accident.
  void _revealGeneration() {
    if (!_compactScroll.hasClients) return;
    _compactScroll.animateTo(
      0,
      duration: LcMotion.normal,
      curve: Curves.easeOutCubic,
    );
  }

  Widget _content() {
    final unconstrained = _generation.hasResult;
    return Container(
      key: LcKeys.contentPane,
      alignment: Alignment.center,
      child: ConstrainedBox(
        // A single column never grows past a readable width, so a wide screen
        // does not simply stretch the compact layout across itself. A result
        // is the exception: the media is given the room it has.
        constraints: BoxConstraints(
          maxWidth: unconstrained ? double.infinity : LcLayout.readableWidth,
        ),
        child: _contentBody(),
      ),
    );
  }

  Widget _contentBody() {
    if (_showsGeneration) {
      final generated = _generation.workflowId;
      return GenerationSurface(
        generation: _generation,
        onGenerateAgain: _onGenerateAgain,
        // Absent on a build that keeps no setups, and absent while there is
        // no form to read the user's own words out of — which is what a
        // result restored after a reconnect into a session that has not
        // opened that workflow looks like.
        onSaveSetup: generated == null || !_workflows.canSaveSetupFor(generated)
            ? null
            : () => _saveResultAsSetup(generated),
      );
    }
    if (_workflows.phase == RegistryPhase.ready &&
        _workflows.workflows.isEmpty) {
      return WorkflowsEmptyState(
        serverName:
            _controller.identity?.displayName ?? L.of(context).thisServer,
        onChooseAnotherServer: _session.chooseAnotherServer,
        // The picker's Refresh is out of reach from an empty list (T-0235).
        registry: _workflows,
      );
    }
    final summary = _workflows.selectedSummary;
    return _CreationIdle(
      workflowName: summary?.name,
      onChoose: _workflows.phase == RegistryPhase.ready && summary == null
          ? _openPicker
          : null,
    );
  }
}

/// How much room the hairline between the panes takes. One pixel, because a
/// border is a whisper by contract — named so that the arithmetic that has to
/// account for it and the widget that draws it cannot drift apart.
const double _dividerWidth = 1;

/// The grab area over that hairline: what actually moves the split.
///
/// It draws nothing of its own until it is focused. The divider is the visible
/// thing and it is unchanged; this is the part a thumb can hit, and making it
/// visible would be adding the second piece of chrome this card was asked not
/// to add.
///
/// **It lets pointers through.** `HitTestBehavior.translucent` means a press
/// inside this strip reaches both this handle and whatever is beneath it, so
/// covering 12dp of each pane does not create a band where nothing responds:
/// a press that turns into a sideways drag moves the split, and a press that
/// stays put is a tap on whatever was underneath. Without it the [Stack] would
/// stop at the topmost child that was hit and the strip would swallow taps.
///
/// **It is operable without a pointer at all.** It takes keyboard focus, says
/// so by drawing a short accent line over the divider, and answers the two
/// arrow keys; a screen reader is given the same two moves as *increase* and
/// *decrease*, where increase is the controls side growing. That is the whole
/// of its interface — there is no value to read out, because a share of a
/// window is not a number anybody wants spoken.
class _SplitHandle extends StatefulWidget {
  const _SplitHandle({
    super.key,
    required this.onMove,
    required this.onSettled,
  });

  /// Move the split by this many pixels; positive widens the controls side.
  final void Function(double dx) onMove;

  /// The move is over and may be written down.
  final VoidCallback onSettled;

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _focused = false;

  /// One discrete move: the same pair of calls a drag makes, because a step is
  /// a drag that is over as soon as it started. Anything that moves the split
  /// and does not also settle it would change the layout and forget it.
  void _step(double dx) {
    widget.onMove(dx);
    widget.onSettled();
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _step(-LcLayout.splitHandleStep);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _step(LcLayout.splitHandleStep);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      container: true,
      label: L.of(context).splitHandleLabel,
      onIncrease: () => _step(LcLayout.splitHandleStep),
      onDecrease: () => _step(-LcLayout.splitHandleStep),
      child: Focus(
        // `Focus` is left to own the focus object rather than being handed
        // one this class holds, which is why the drag below reaches it
        // through the context instead of through a field. That is idiomatic
        // and it is also the only shape available here: `portable_profile_
        // _test.dart` forbids the four letters of a graph's vocabulary
        // anywhere in this file's code, and Flutter's type for a focus object
        // is spelled with one of them. Filed as its own card; a comment is
        // stripped before that scan, so this explanation is allowed to say so.
        onKeyEvent: (_, event) => _onKey(event),
        onFocusChange: (has) {
          if (mounted) setState(() => _focused = has);
        },
        child: Builder(
          builder: (context) => MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            // Not opaque, which is not the default and is the whole of the
            // pass-through. `HitTestBehavior.translucent` on the detector
            // below is necessary and was measured not to be sufficient: a
            // `MouseRegion` answers the hit test on its own behalf, so an
            // opaque one makes this strip win and the `Stack` never reaches
            // the panes underneath. The test that presses inside the strip
            // and expects the creation area in the same hit path is what
            // found that.
            opaque: false,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (_) => Focus.of(context).requestFocus(),
              onHorizontalDragUpdate: (details) =>
                  widget.onMove(details.delta.dx),
              onHorizontalDragEnd: (_) => widget.onSettled(),
              child: Center(
                child: AnimatedContainer(
                  duration: LcMotion.quick,
                  width: _focused ? 3 : 0,
                  color: palette.accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The creation area before there is anything in it.
///
/// Deliberately quiet: generated media is the hero here (`docs/ui-ux.md`), and
/// this is the space it will occupy. It says what will appear rather than
/// pretending something already has.
class _CreationIdle extends StatelessWidget {
  const _CreationIdle({required this.workflowName, this.onChoose});

  final String? workflowName;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final chosen = workflowName != null;
    return Center(
      key: LcKeys.creationIdle,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(LcSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(LcSpace.lg),
                decoration: BoxDecoration(
                  color: palette.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.outline),
                ),
                child: CanvasMark(size: 44, color: palette.textMuted),
              ),
              const SizedBox(height: LcSpace.lg),
              Text(
                chosen
                    ? l.creationIdleChosenTitle
                    : l.creationIdleUnchosenTitle,
                style: text.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: LcSpace.xs),
              Text(
                chosen
                    ? l.creationIdleChosenBody(workflowName!)
                    : l.creationIdleUnchosenBody,
                style: text.bodyMedium?.copyWith(color: palette.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (onChoose != null) ...<Widget>[
                const SizedBox(height: LcSpace.lg),
                TextButton(onPressed: onChoose, child: Text(l.chooseAWorkflow)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The workflow that was chosen is not in the refreshed registry any more.
///
/// Said out loud, with the prompt left alone. The app never quietly runs a
/// different workflow than the one the user chose (`docs/recovery.md`).
class _MissingWorkflowPanel extends StatelessWidget {
  const _MissingWorkflowPanel({required this.name, required this.onDismiss});

  final String name;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Container(
      key: LcKeys.missingWorkflow,
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.warning.withValues(alpha: 0.34)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l.missingWorkflowTitle(name), style: text.titleSmall),
          const SizedBox(height: LcSpace.xxs),
          Text(
            l.missingWorkflowBody,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onDismiss, child: Text(l.ok)),
          ),
        ],
      ),
    );
  }
}

/// Something the app asked the server for and did not get, in words plus one
/// decision. No status code, no exception text (`docs/ui-ux.md`).
class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    super.key,
    required this.title,
    required this.message,
    required this.actionKey,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String message;
  final Key actionKey;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.warning.withValues(alpha: 0.34)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.cloud_off_outlined,
                  size: 20,
                  color: palette.warning,
                ),
              ),
              const SizedBox(width: LcSpace.sm),
              Expanded(child: Text(title, style: text.titleSmall)),
            ],
          ),
          const SizedBox(height: LcSpace.xs),
          Text(
            message,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          const SizedBox(height: LcSpace.xxs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: actionKey,
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// The connected server, by its own name, with its real identity behind a
/// disclosure rather than on the surface.
class _ServerHeader extends StatelessWidget {
  const _ServerHeader({
    required this.identity,
    required this.address,
    required this.open,
    required this.busy,
    required this.onToggle,
    required this.onRecheck,
    required this.onChooseAnother,
    required this.attempts,
    required this.onAttemptsChanged,
  });

  final GatewayIdentity? identity;
  final String address;
  final bool open;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onRecheck;
  final VoidCallback onChooseAnother;

  /// How many automatic attempts the next reconnect makes.
  final int attempts;

  /// Chooses another count, or `null` where this build cannot remember one.
  final ValueChanged<int>? onAttemptsChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final ready = identity?.comfyStatus.isReady ?? false;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: LcKeys.serverDetailsToggle,
            onTap: onToggle,
            borderRadius: BorderRadius.circular(LcRadius.lg),
            child: Padding(
              padding: const EdgeInsets.all(LcSpace.md),
              child: Row(
                children: <Widget>[
                  const CanvasMark(size: 28),
                  const SizedBox(width: LcSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          identity?.displayName ?? l.serverConnected,
                          style: text.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: <Widget>[
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ready ? palette.success : palette.warning,
                              ),
                            ),
                            const SizedBox(width: LcSpace.xxs + 2),
                            Flexible(
                              child: Text(
                                ready ? l.serverReady : l.serverNotReady,
                                style: text.bodySmall
                                    ?.copyWith(color: palette.textMuted),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    color: palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              key: LcKeys.serverDetails,
              padding: const EdgeInsets.fromLTRB(
                LcSpace.md,
                0,
                LcSpace.md,
                LcSpace.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Divider(color: palette.outline, height: LcSpace.md),
                  _DetailRow(label: l.serverDetailAddress, value: address),
                  _DetailRow(
                    label: l.serverDetailServerVersion,
                    value: identity?.gatewayVersion ?? l.valueNone,
                  ),
                  _DetailRow(
                    label: l.serverDetailApiVersion,
                    value: identity == null
                        ? l.valueNone
                        : l.serverApiVersionValue(
                            '${identity!.apiVersion}',
                            '$kSupportedApiVersion',
                          ),
                  ),
                  _DetailRow(
                    label: l.serverDetailGenerator,
                    value: _comfyLabel(l, identity?.comfyStatus),
                  ),
                  if (onAttemptsChanged case final onChanged?)
                    _AttemptsRow(
                      label: l.serverDetailReconnectAttempts,
                      attempts: attempts,
                      onChanged: onChanged,
                    ),
                  const SizedBox(height: LcSpace.xxs),
                  // Wrapped rather than laid out in a row: these labels are
                  // sentences, and a narrow pane must not clip one.
                  Wrap(
                    spacing: LcSpace.xs,
                    children: <Widget>[
                      TextButton(
                        onPressed: busy ? null : onRecheck,
                        child: Text(l.checkAgain),
                      ),
                      TextButton(
                        onPressed: busy ? null : onChooseAnother,
                        child: Text(l.chooseAnotherServer),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _comfyLabel(L l, ComfyStatus? status) => switch (status) {
    ComfyStatus.ready => l.generatorRunning,
    ComfyStatus.starting => l.generatorStarting,
    ComfyStatus.unavailable => l.generatorNotRunning,
    ComfyStatus.unknown => l.generatorUnknown,
    null => l.valueNone,
  };
}

/// The number of automatic reconnect attempts, and − / + to change it
/// (`docs/recovery.md`, T-0212).
///
/// A stepper rather than a field or a slider: ten whole numbers, and no way to
/// type one that is not allowed. The bound is read from the store's file, the
/// same constants the session refuses by, and each button is disabled — not
/// hidden — at its end, so the limit is visible rather than discovered.
///
/// Laid out as [_DetailRow] is, with the value side able to wrap: the label is
/// a fixed column and the buttons are fixed sizes, so on a narrow pane at a
/// large text scale a `Row` here would have nothing that can give.
class _AttemptsRow extends StatelessWidget {
  const _AttemptsRow({
    required this.label,
    required this.attempts,
    required this.onChanged,
  });

  final String label;
  final int attempts;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Padding(
      key: LcKeys.reconnectAttempts,
      padding: const EdgeInsets.symmetric(vertical: LcSpace.xxs),
      child: LabelValueRow(
        labelWidth: 116,
        crossAxisAlignment: CrossAxisAlignment.center,
        label: Text(
          label,
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
        value: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                IconButton(
                  key: LcKeys.reconnectAttemptsFewer,
                  onPressed: attempts > kMinReconnectAttempts
                      ? () => onChanged(attempts - 1)
                      : null,
                  icon: const Icon(Icons.remove_rounded, size: 20),
                  tooltip: l.reconnectAttemptsFewer,
                ),
                Text(
                  '$attempts',
                  key: LcKeys.reconnectAttemptsValue,
                  style: text.bodyMedium,
                ),
                IconButton(
                  key: LcKeys.reconnectAttemptsMore,
                  onPressed: attempts < kMaxReconnectAttempts
                      ? () => onChanged(attempts + 1)
                      : null,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  tooltip: l.reconnectAttemptsMore,
                ),
              ],
            ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LcSpace.xxs),
      child: LabelValueRow(
        labelWidth: 116,
        label: Text(
          label,
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
        value: Text(value, style: text.bodySmall),
      ),
    );
  }
}
