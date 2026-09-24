/// The content area, before there is anything to put in it.
///
/// A finished state, not a placeholder: the mark, a sentence that says
/// truthfully where workflows come from, and one real action. What fills this
/// area is the workflow picker, which is a separate card; until then this is
/// what a connected user sees, and it has to look like the app rather than
/// like a gap in it.
///
/// **Refresh (T-0235).** The picker's Refresh cannot be reached from here — a
/// list with nothing in it offers no picker — so a workflow imported on the PC
/// while this is on screen needs a way in of its own. Given the
/// [WorkflowsController], this offers the same [WorkflowsController.refresh]
/// the picker does, unavailable while one runs exactly as the picker's is, and
/// says a failure with the picker's own card ([WorkflowsRefreshFailure]). A
/// list that arrives with something in it needs nothing from here: the shell
/// draws the creation controls in this one's place.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/workflow_api.dart';
import '../../workflows/workflows_controller.dart';
import '../common/brand.dart';
import '../keys.dart';
import '../workflows/workflow_picker.dart';

class WorkflowsEmptyState extends StatefulWidget {
  const WorkflowsEmptyState({
    super.key,
    required this.serverName,
    this.onChooseAnotherServer,
    this.registry,
  });

  final String serverName;
  final VoidCallback? onChooseAnotherServer;

  /// The registry to refresh, or `null` for a caller with none — which offers
  /// no Refresh rather than one that could change nothing.
  final WorkflowsController? registry;

  @override
  State<WorkflowsEmptyState> createState() => _WorkflowsEmptyStateState();
}

class _WorkflowsEmptyStateState extends State<WorkflowsEmptyState> {
  /// Why the last Refresh pressed here did not arrive, or `null`. Held by this
  /// screen for the picker's reason: said where it was asked for, and gone
  /// with it.
  WorkflowsFailure? _refreshFailure;

  /// [WorkflowsController.listArrivals] when that failure came back. The card
  /// is said only while no list has arrived since, by the picker's rule.
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
    if (registry == null) return _body(context, null);
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) => _body(context, registry),
    );
  }

  Widget _body(BuildContext context, WorkflowsController? registry) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final refreshFailure =
        registry == null || registry.listArrivals != _failedAtArrival
        ? null
        : _refreshFailure;
    // The picker's own condition, so the two Refreshes cannot disagree about
    // when one may be started.
    final VoidCallback? onRefresh =
        registry == null ||
            registry.isRefreshing ||
            registry.phase != RegistryPhase.ready
        ? null
        : () => _refresh(registry);
    return Center(
      key: LcKeys.workflowsEmptyState,
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
                l.workflowsEmptyTitle,
                style: text.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: LcSpace.xs),
              Text(
                l.workflowsEmptyBody(widget.serverName),
                style: text.bodyMedium?.copyWith(color: palette.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (refreshFailure != null && registry != null) ...<Widget>[
                const SizedBox(height: LcSpace.md),
                WorkflowsRefreshFailure(
                  failure: refreshFailure,
                  onRetry: onRefresh,
                ),
              ],
              if (registry != null ||
                  widget.onChooseAnotherServer != null) ...<Widget>[
                const SizedBox(height: LcSpace.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: LcSpace.xs,
                  runSpacing: LcSpace.xxs,
                  children: <Widget>[
                    if (registry != null)
                      TextButton.icon(
                        key: LcKeys.workflowsRefresh,
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        label: Text(l.workflowsRefresh),
                      ),
                    if (widget.onChooseAnotherServer != null)
                      TextButton(
                        onPressed: widget.onChooseAnotherServer,
                        child: Text(l.chooseAnotherServer),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
