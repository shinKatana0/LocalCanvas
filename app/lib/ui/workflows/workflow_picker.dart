/// Choosing a workflow (`docs/ui-ux.md`).
///
/// Human-readable cards, never a bare dropdown: the display name, the badge,
/// the category and the short description the curator wrote, plus the one
/// affordance that opens the full explanation.
///
/// The sections come from [groupWorkflows] and nothing else. There is no list
/// of known group names in this file, no `switch` on a group, a category or a
/// badge, and no colour keyed to one — so a registry that invents a group
/// tomorrow gets a section, and a badge nobody has seen looks like every other
/// badge instead of like a bug.
///
/// **Narrowing to one kind (T-0177).** A catalogue of forty-four in one scroll
/// means reaching `Edit` by scrolling past thirty things nobody asked for, so
/// the picker can be narrowed to a single group and back. Four things about
/// that, each of which is a decision and not an implementation detail:
///
/// * **the vocabulary is the catalogue's, not this file's.** The options are
///   the groups [groupWorkflows] found, in the registry's own order — the same
///   strings that are already on screen as the section headings. Nothing here
///   knows the word `Create`, and a gateway serving different groups gets
///   those. The one exception is the bar's first option, `All`, which is the
///   app's own word for "do not narrow at all" and is therefore the one string
///   in the bar that is translated;
/// * **`All` is the default and it is never more than one tap away.** Somebody
///   who does not touch the bar sees exactly the list this screen drew before
///   the bar existed: same sections, same order, same count;
/// * **a workflow that declared no group is an option like any other.** It is
///   offered under [L.workflowGroupOther] — the app's existing word for that
///   bucket, and already the heading over it — because giving the same thing
///   two names in one screen is how something becomes unreachable. It is keyed
///   apart from a registry group genuinely named "Other", the same way the
///   heading is;
/// * **the bar yields instead of overflowing.** See [_FilterBar].
///
/// **Refreshing the list (T-0017).** Given the [WorkflowsController] behind
/// it, the picker draws that controller's list rather than the one it was
/// opened with, and offers Refresh — so a workflow imported on the PC while the
/// picker is open appears in it. The refresh is
/// [WorkflowsController.refresh], which never leaves the ready phase: the
/// cards stay on screen and stay tappable while it runs, the button is
/// unavailable until it ends, and a refresh that failed says so above the list
/// it did not replace.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/workflow_api.dart';
import '../../workflows/workflow_models.dart';
import '../../workflows/workflows_controller.dart';
import '../keys.dart';
import 'workflow_help_sheet.dart';

/// Shows the picker and returns the chosen workflow's id, or `null` if the
/// user came back without choosing.
Future<String?> chooseWorkflow(
  BuildContext context, {
  required List<WorkflowSummary> workflows,
  required String? selectedId,
  required Future<WorkflowDetail?> Function(String id) detailLoader,
  WorkflowsController? registry,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => WorkflowPickerScreen(
        workflows: workflows,
        selectedId: selectedId,
        detailLoader: detailLoader,
        registry: registry,
      ),
    ),
  );
}

class WorkflowPickerScreen extends StatefulWidget {
  const WorkflowPickerScreen({
    super.key,
    required this.workflows,
    required this.selectedId,
    required this.detailLoader,
    this.registry,
  });

  /// The list and the chosen workflow the picker was opened with. Read only
  /// when there is no [registry]: with one, the registry's own current answer
  /// is drawn instead, so a refresh is seen.
  final List<WorkflowSummary> workflows;
  final String? selectedId;

  /// Supplies the field schema the help sheet uses for its Defaults section.
  final Future<WorkflowDetail?> Function(String id) detailLoader;

  /// The registry behind this picker, or `null` for a picker over a fixed
  /// list — which offers no Refresh, rather than one that could not change
  /// what is on screen.
  final WorkflowsController? registry;

  @override
  State<WorkflowPickerScreen> createState() => _WorkflowPickerScreenState();
}

class _WorkflowPickerScreenState extends State<WorkflowPickerScreen> {
  /// Why the last Refresh pressed on this screen did not arrive, or `null`.
  ///
  /// Held by the screen and not by the controller, so it is said on the one
  /// screen that asked and gone when that screen is: a refresh the app made on
  /// its own, coming back to the foreground, fails silently, and a picker
  /// opened later does not greet anybody with an old failure.
  WorkflowsFailure? _refreshFailure;

  /// [WorkflowsController.listArrivals] when that failure came back.
  ///
  /// The failure is said only while no list has arrived since. A later refresh
  /// that worked — the app's own quiet one on coming back, or a reconnect's
  /// reload — re-read the very list the failure was about, and a card saying
  /// the server did not answer over a list it has just answered with would be
  /// a sentence that is no longer true.
  int _failedAtArrival = 0;

  Future<void> _refresh(WorkflowsController registry) async {
    setState(() => _refreshFailure = null);
    final failure = await registry.refresh();
    if (!mounted) return;
    setState(() {
      _refreshFailure = failure;
      _failedAtArrival = registry.listArrivals;
    });
  }

  @override
  Widget build(BuildContext context) {
    final registry = widget.registry;
    if (registry == null) {
      return _screen(context, widget.workflows, widget.selectedId, null);
    }
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) => _screen(
        context,
        registry.workflows,
        registry.selectedId,
        registry,
      ),
    );
  }

  /// Which one kind the list is narrowed to, or `null` while it is showing
  /// everything.
  ///
  /// It starts `null`, which is what makes `All` the default rather than a
  /// thing to choose, and it lives here rather than in `WorkflowsController`
  /// because narrowing is about looking, not about what is chosen: it has no
  /// bearing on the generation the shell is holding, and a person who came
  /// back to compare two workflows starts from everything again. Nothing
  /// outside this screen can observe it.
  _GroupChoice? _narrowedTo;

  Widget _screen(
    BuildContext context,
    List<WorkflowSummary> workflows,
    String? selectedId,
    WorkflowsController? registry,
  ) {
    final groups = groupWorkflows(workflows);
    // A catalogue that changed under the filter may no longer have the group
    // it was narrowed to — a gateway republishing, a refresh, or a reconnect
    // to another PC. Holding a choice nothing answers would show an empty list
    // with no option selected and no way back but the app bar, so the
    // narrowing goes rather than the workflows. Checked here, on every build,
    // because a refreshed list reaches this screen through the registry and
    // never through a new widget.
    final narrowed = _narrowedTo;
    if (narrowed != null &&
        !groups.any((group) => group.name == narrowed.name)) {
      _narrowedTo = null;
    }
    final choice = _narrowedTo;
    final l = L.of(context);
    final refreshFailure =
        registry == null || registry.listArrivals != _failedAtArrival
        ? null
        : _refreshFailure;
    // What the list is, after the narrowing. Everything below is built from
    // this and never from `groups`, so the filter cannot end up describing one
    // list while the screen draws another.
    final shownGroups = choice == null
        ? groups
        : <WorkflowGroup>[
            for (final group in groups)
              if (group.name == choice.name) group,
          ];
    // Counted from the very list the cards are built from, rather than from
    // the registry beside it. That is the whole rule about this number: it
    // describes what is on screen, so a grouping that dropped a workflow —
    // or the narrowing above — moves the count with it instead of leaving a
    // figure that quietly disagrees with the list under it.
    final shown = <WorkflowSummary>[
      for (final group in shownGroups) ...group.workflows,
    ];
    return Scaffold(
      key: LcKeys.workflowPicker,
      appBar: AppBar(
        title: Text(l.workflowPickerTitle),
        actions: <Widget>[
          if (registry != null)
            IconButton(
              key: LcKeys.workflowsRefresh,
              tooltip: l.workflowsRefresh,
              icon: const Icon(Icons.refresh_rounded),
              // Unavailable while one is running — whoever started it — and
              // while the registry is anywhere but ready, where a reconnect's
              // own re-read is already asking.
              onPressed:
                  registry.isRefreshing || registry.phase != RegistryPhase.ready
                  ? null
                  : () => _refresh(registry),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: LcLayout.readableWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                LcSpace.md,
                LcSpace.xs,
                LcSpace.md,
                LcSpace.xl,
              ),
              children: <Widget>[
                // Above the list, and never instead of it: what the last
                // refresh could not read is said, and the list it did not
                // replace stays below, whole and tappable.
                if (refreshFailure != null && registry != null)
                  Padding(
                    padding: const EdgeInsets.only(top: LcSpace.xs),
                    child: WorkflowsRefreshFailure(
                      failure: refreshFailure,
                      onRetry:
                          registry.isRefreshing ||
                              registry.phase != RegistryPhase.ready
                          ? null
                          : () => _refresh(registry),
                    ),
                  ),
                // One kind at a time, or all of them. Absent on a catalogue
                // that has only one group to speak of — an affordance whose
                // every answer shows the same list is noise, and on a folded
                // phone it is noise in the place the first card wants.
                if (groups.length > 1)
                  _FilterBar(
                    groups: groups,
                    chosen: choice,
                    onChanged: (next) => setState(() => _narrowedTo = next),
                  ),
                // How many there are, before the first of them. On a large
                // catalogue it is the only way to tell at a glance that the
                // whole of what the PC publishes is here — and, once narrowed,
                // how much of it this kind is.
                Padding(
                  padding: const EdgeInsets.only(
                    top: LcSpace.xs,
                    left: LcSpace.xxs,
                  ),
                  child: Text(
                    l.workflowCount(shown.length),
                    key: LcKeys.workflowCount,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.palette.textMuted,
                    ),
                  ),
                ),
                for (final group in shownGroups) ...<Widget>[
                  // A section needs a heading to be a section. A workflow that
                  // declared no group has no name to show, so it gets the
                  // app's own word for that -- without one it becomes a run of
                  // cards under whichever heading happens to precede it, and
                  // reads as belonging to a group it never claimed. When it is
                  // the only section there is nothing to be confused with, and
                  // a heading over the whole list would be noise — which is
                  // read off what is *shown*, so narrowing to it leaves the
                  // list as bare as a one-group catalogue does, with the
                  // chosen option in the bar above saying which kind these
                  // are.
                  if (group.name != null)
                    _GroupHeading(name: group.name!)
                  else if (shownGroups.length > 1)
                    _GroupHeading(
                      name: L.of(context).workflowGroupOther,
                      key: LcKeys.ungroupedWorkflows,
                    ),
                  for (final workflow in group.workflows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: LcSpace.sm),
                      child: WorkflowCard(
                        workflow: workflow,
                        selected: workflow.id == selectedId,
                        onChoose: () =>
                            Navigator.of(context).pop(workflow.id),
                        detailLoader: widget.detailLoader,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A Refresh that did not arrive, in the words the registry's own failure
/// already has — the ones the shell says when the first list does not arrive —
/// and with the Try again `docs/recovery.md` promises any action that finds
/// the gateway gone.
///
/// Public so the empty workflow list says a failed Refresh with this very card
/// rather than a copy of it (T-0235).
class WorkflowsRefreshFailure extends StatelessWidget {
  const WorkflowsRefreshFailure({
    super.key,
    required this.failure,
    required this.onRetry,
  });

  final WorkflowsFailure failure;

  /// `null` while a refresh is already running.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Container(
      key: LcKeys.workflowsRefreshFailed,
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
              Expanded(child: Text(failure.title(l), style: text.titleSmall)),
            ],
          ),
          const SizedBox(height: LcSpace.xs),
          Text(
            failure.message(l),
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          const SizedBox(height: LcSpace.xxs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: LcKeys.workflowsRefreshRetry,
              onPressed: onRetry,
              child: Text(l.tryAgain),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one kind the picker is narrowed to.
///
/// A type and not a bare `String?`, because `null` is a legitimate group —
/// the bucket of workflows that declared none, which [groupWorkflows] keys by
/// `null` — and `null` would also be the obvious spelling of "not narrowed at
/// all". Two meanings on one value is exactly how the nameless bucket becomes
/// unreachable. Here the *absence* of a [_GroupChoice] is "everything", and a
/// [_GroupChoice] whose [name] is `null` is the nameless group, chosen on
/// purpose.
@immutable
class _GroupChoice {
  const _GroupChoice(this.name);

  /// The group's own name, as the registry wrote it, or `null` for the
  /// workflows that declared none.
  final String? name;
}

/// Show me one kind at a time (T-0177).
///
/// **A `Wrap` of choice chips, and the judgement behind it.** The number of
/// options is not this app's to bound — it is one per group the connected
/// gateway serves, plus `All` — and the narrowest screen this app draws on is
/// a folded phone at an accessibility text size. That pair is exactly the
/// condition T-0153 and T-0158 were filed for, so the question is not whether
/// the options fit but what happens when they do not:
///
/// * **they take another line.** A `Wrap` has no flex to overflow: a chip that
///   does not fit the line starts the next one. Twenty groups is twenty chips
///   in however many rows the width needs, with no `RenderFlex` overflow, no
///   clipping, and nothing painted outside the bar;
/// * **more rows than the screen has room for scroll with the list**, because
///   the bar is a child of the picker's own `ListView` rather than a header
///   pinned over it. A pinned bar would have to clip or scroll *itself* on a
///   folded phone, and taking a fixed slice off the top of a 320dp screen is
///   what this app already refuses to do to the list of cards;
/// * **`All` is first**, so the way back to everything is the option nearest
///   the start of the bar in both reading directions, and it is on the first
///   row at every width;
/// * **a long group name wraps rather than fading out.** A chip's default
///   label style is `maxLines: 1, softWrap: false, TextOverflow.fade`, which
///   loses the end of a word inside a control that looks perfectly fine — the
///   defect T-0132 was fixed for. Group names are the curator's prose and can
///   be any length, so the label here overrides all three: it wraps, up to the
///   two lines the card's own input summary gets, and ellipsises visibly after
///   that rather than fading.
///
/// **The text size is not capped here.** The choice chips in the shell clamp
/// it (`kChoiceChipMaxTextScale`), because their labels are fixed app words
/// that must not be cut. These labels can give instead — they wrap — so the
/// phone's setting is honoured in full, which is this app's default everywhere
/// else.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.groups,
    required this.chosen,
    required this.onChanged,
  });

  /// Every group in the catalogue, in the registry's own order — the same
  /// list, from the same call, that builds the sections below.
  final List<WorkflowGroup> groups;

  /// The group the list is narrowed to, or `null` while it is showing
  /// everything.
  final _GroupChoice? chosen;

  /// The user chose another one. `null` is `All`.
  final ValueChanged<_GroupChoice?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: LcSpace.xs, bottom: LcSpace.xxs),
      child: Wrap(
        key: LcKeys.workflowFilter,
        spacing: LcSpace.xs,
        runSpacing: LcSpace.xs,
        children: <Widget>[
          // The app's own word, and the default. It is an option like the
          // others rather than the absence of one, for the reason the shell's
          // appearance chips give about following the system: a person who
          // came back to everything chose something, and the control has to
          // be able to show them that.
          _option(
            context,
            key: LcKeys.workflowFilterAll,
            label: l.workflowFilterAll,
            selected: chosen == null,
            onSelect: () => onChanged(null),
          ),
          for (final group in groups)
            _option(
              context,
              // Keyed apart when the group has no name of its own, so a
              // registry that really does serve a group called "Other" and
              // the app's word for having none stay two different options —
              // the same split [LcKeys.ungroupedWorkflows] makes for the
              // heading.
              key: group.name == null
                  ? LcKeys.workflowFilterUngrouped
                  : LcKeys.workflowFilterGroup(group.name!),
              label: group.name ?? l.workflowGroupOther,
              selected: chosen != null && chosen!.name == group.name,
              onSelect: () => onChanged(_GroupChoice(group.name)),
            ),
        ],
      ),
    );
  }

  Widget _option(
    BuildContext context, {
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelect,
  }) {
    return ChoiceChip(
      key: key,
      selected: selected,
      // The bool is ignored on purpose: these options do not toggle off.
      // Tapping the chosen one again leaves it chosen, and the way to see
      // everything again is `All`, which is always on screen.
      onSelected: (_) => onSelect(),
      // So the chosen option is not carried by colour alone.
      showCheckmark: true,
      label: Semantics(
        // Inside the chip's own merge boundary, so it lands on the chip's
        // node rather than on a node above it.
        inMutuallyExclusiveGroup: true,
        child: Text(
          label,
          // See the class comment: a group name is the curator's prose, and a
          // chip would otherwise fade the end of it away silently.
          softWrap: true,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      labelStyle: Theme.of(context).textTheme.labelLarge,
    );
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      // A named section is found by its name; the nameless one is found by
      // the key its caller gave it, so a registry that really does declare a
      // group called "Other" cannot collide with it.
      key: key == null ? LcKeys.workflowGroup(name) : null,
      padding: const EdgeInsets.only(
        top: LcSpace.md,
        bottom: LcSpace.xs,
        left: LcSpace.xxs,
      ),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: palette.textMuted,
          letterSpacing: 0.9,
        ),
      ),
    );
  }
}

/// One workflow, as a person reads it.
class WorkflowCard extends StatelessWidget {
  const WorkflowCard({
    super.key,
    required this.workflow,
    required this.selected,
    required this.onChoose,
    required this.detailLoader,
  });

  final WorkflowSummary workflow;
  final bool selected;
  final VoidCallback onChoose;
  final Future<WorkflowDetail?> Function(String id) detailLoader;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final presentation = workflow.presentation;
    final description = presentation.shortDescription;
    final summary = workflow.inputSummary;

    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(LcRadius.lg),
      child: InkWell(
        key: LcKeys.workflowCard(workflow.id),
        onTap: onChoose,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(LcSpace.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LcRadius.lg),
            border: Border.all(
              color: selected ? palette.accent : palette.outline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              NameWithBadge(
                name: workflow.name,
                nameStyle: text.titleSmall,
                badge: presentation.badge,
              ),
              if (presentation.category != null) ...<Widget>[
                const SizedBox(height: LcSpace.xxs),
                Text(
                  presentation.category!,
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ],
              if (description != null) ...<Widget>[
                const SizedBox(height: LcSpace.xs),
                Text(
                  description,
                  style: text.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: LcSpace.xs),
              // The button is what gives (T-0154). Written as
              // `Row([Expanded(summary) | Spacer, TextButton])` this line had
              // give in only one of its two children: the button was not
              // flexible and its label alone is wider than the card at a
              // raised text scale, so the `Expanded` shrinking to nothing was
              // still not enough and `RenderFlex` overflowed — 36px at
              // 320dp/1.3 and 183px at 320dp/2.0, to the pixel in both
              // locales, because `What this does` and «Что это делает» are
              // each 14 characters.
              //
              // A `Wrap` instead of a `Row`, so there is no flex left in this
              // line to overflow, and the yield is ordered:
              //
              //  1. summary at the left, button at the far right, on one
              //     line, **while both fit** — `spaceBetween` leaves the free
              //     space where the `Expanded` summary used to push it, and
              //     where the `Spacer` put it on a workflow that declares no
              //     summary at all;
              //  2. the button drops onto its own line under the summary. It
              //     is the button that moves, because the summary is what
              //     the person is reading and the button is what they act on
              //     once they have;
              //  3. its label takes as many lines as its words need rather
              //     than being cut, and the summary may take two lines rather
              //     than ellipsising after one.
              //
              // **Step 2 is reached more often than the overflow was**, and
              // that is the fix and not a side effect of it. The four
              // combinations above are where `main` *overflowed*; at fourteen
              // more the row fitted only because the `Expanded` was squeezing
              // the summary and ellipsising it — at 412dp and a 1.0 text
              // scale it was given 118.6dp for a string that wanted 147.4dp,
              // on an ordinary phone at the default text size. Those fourteen
              // now put the button on its own line and show the summary
              // whole. A row that fits by cutting its own text was never
              // fitting.
              //
              // The two texts are capped differently on purpose, by what
              // wrote them. `What this does` is the app's own word for the
              // affordance, so it is never capped and never cut: a plain
              // `Text` wraps to whatever it needs. The input summary is the
              // curator's prose and could be a paragraph, so it keeps a cap —
              // two lines, where it used to get one, with the ellipsis a
              // person can see.
              //
              // The cap is in lines and not in dp, and it is not an ellipsis
              // with no cap: `TextOverflow.ellipsis` on a `Text` with no
              // `maxLines` lays the whole string on a single line and cuts it
              // there (T-0153 found this on the header), which is the
              // opposite of what is wanted here.
              //
              // `SizedBox(width: double.infinity)` is what makes step 1 the
              // same as it was: inside a `Column` with `start` alignment a
              // `Wrap` shrinks to its content, and `spaceBetween` with no
              // free space would sit the button against the summary.
              //
              // Nothing here is sized against a measurement and there is no
              // width break-point: the `Wrap` offers every child the card's
              // width, whatever that is, and reports no overflow at any of
              // them.
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  key: LcKeys.workflowCardSummary(workflow.id),
                  spacing: LcSpace.xs,
                  runSpacing: LcSpace.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  // With the summary absent there is one child and nothing to
                  // space it against, so it is aligned where the `Spacer`
                  // used to leave it.
                  alignment: summary == null
                      ? WrapAlignment.end
                      : WrapAlignment.spaceBetween,
                  children: <Widget>[
                    if (summary != null)
                      Text(
                        summary,
                        style: text.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    TextButton(
                      key: LcKeys.workflowCardHelp(workflow.id),
                      onPressed: () => showWorkflowHelp(
                        context,
                        workflow: workflow,
                        detail: detailLoader(workflow.id),
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(
                          horizontal: LcSpace.xs,
                        ),
                      ),
                      child: Text(L.of(context).workflowWhatThisDoes),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The short type marker, drawn the same way whatever it says.
///
/// One style for every value: the badge is a string from the registry, so
/// giving `TXT2IMG` a colour of its own would be exactly the branch on data
/// this app is not allowed to have.
/// The least room a workflow's name is left beside its badge, in the name's
/// own em (T-0188, T-0216).
///
/// Six, and measured rather than chosen for looks: at 841dp and a 1.0 scale an
/// ordinary name in the chosen-workflow block is offered 6.7 em, which is not
/// the defect and must not be restyled, while every sliver measured at a 2.0
/// scale was 2.3 em or less.
const double kMinNameEms = 6;

/// Whether a badge reading [badge] fits beside a name set in [nameStyle], on
/// a row [rowWidth] wide of which [reserved] is already taken by fixed parts,
/// while leaving the name [kMinNameEms].
///
/// One rule for every place a workflow's name and badge share a line: the
/// picker's cards, the help sheet's title and the chosen-workflow block. The
/// three drew the same `Row([Expanded(name), badge])`, so they had the same
/// defect, and a fix in one of them was only ever going to be a third of one.
bool badgeFitsBeside(
  BuildContext context, {
  required double rowWidth,
  required String badge,
  required TextStyle? nameStyle,
  double reserved = 0,
}) {
  final em = MediaQuery.textScalerOf(context).scale(nameStyle?.fontSize ?? 14);
  return rowWidth -
          reserved -
          LcSpace.xs -
          WorkflowBadge.widthOf(context, badge) >=
      kMinNameEms * em;
}

/// A workflow's name with its badge beside it, or under it where beside would
/// leave the name less than [kMinNameEms] (T-0216).
class NameWithBadge extends StatelessWidget {
  const NameWithBadge({
    super.key,
    required this.name,
    required this.nameStyle,
    required this.badge,
    this.badgeTopInset = 0,
  });

  final String name;
  final TextStyle? nameStyle;
  final String? badge;

  /// A nudge down for a badge beside a name in a taller face.
  final double badgeTopInset;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    final title = Text(name, style: nameStyle);
    if (badge == null) return title;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (badgeFitsBeside(
          context,
          rowWidth: constraints.maxWidth,
          badge: badge,
          nameStyle: nameStyle,
        )) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: title),
              const SizedBox(width: LcSpace.xs),
              Padding(
                padding: EdgeInsets.only(top: badgeTopInset),
                child: WorkflowBadge(text: badge),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            title,
            const SizedBox(height: LcSpace.xxs),
            WorkflowBadge(text: badge),
          ],
        );
      },
    );
  }
}

class WorkflowBadge extends StatelessWidget {
  const WorkflowBadge({super.key, required this.text});

  final String text;

  static const EdgeInsets _padding = EdgeInsets.symmetric(
    horizontal: LcSpace.xs,
    vertical: LcSpace.xxs / 2,
  );

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.labelSmall?.copyWith(
        color: context.palette.accent,
        letterSpacing: 0.6,
      );

  /// How wide a badge reading [text] draws on one line, here — the same
  /// style, padding and text scale [build] uses, so a layout deciding where a
  /// badge goes asks the badge rather than restating it (T-0188).
  static double widthOf(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + _padding.horizontal;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: _padding,
      decoration: BoxDecoration(
        color: palette.accentQuiet,
        borderRadius: BorderRadius.circular(LcRadius.pill),
      ),
      child: Text(text, style: _style(context)),
    );
  }
}
