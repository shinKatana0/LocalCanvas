/// The workflow's own explanation of itself (`docs/ui-ux.md`).
///
/// The bar this is built to: *a user returning after months understands the
/// workflow without opening external documentation or inspecting a node
/// graph.* So the sheet says what it does, when to choose it, what it needs,
/// how to use it, what its defaults are, an example prompt, and what it is not
/// for — each one only when the registry actually supplied it.
///
/// Absent means absent. A workflow that declared no `not_ideal_for` gets no
/// heading for it and no "N/A": an empty heading is a promise the curator did
/// not make.
///
/// The sheet is one of two places that account is given. [WorkflowHelpBody]
/// holds everything below the title and is rendered inline by the chosen
/// workflow's block as well (T-0144) — a sheet while you are browsing cards,
/// a disclosure once you have chosen. Both read the same widget, in the same
/// order, so neither can drift into a second version of the same workflow.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/workflow_form.dart';
import '../../workflows/workflow_models.dart';
import '../common/label_value_row.dart';
import '../keys.dart';
import 'workflow_picker.dart';

/// Opens the details surface for one workflow.
///
/// [detail] supplies the field schema behind the Defaults section. The sheet
/// opens immediately and fills that section in when it arrives, because a
/// description the registry already sent should not wait on a second request.
Future<void> showWorkflowHelp(
  BuildContext context, {
  required WorkflowSummary workflow,
  Future<WorkflowDetail?>? detail,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: LcLayout.readableWidth),
    builder: (_) => WorkflowHelpSheet(workflow: workflow, detail: detail),
  );
}

class WorkflowHelpSheet extends StatelessWidget {
  const WorkflowHelpSheet({super.key, required this.workflow, this.detail});

  final WorkflowSummary workflow;
  final Future<WorkflowDetail?>? detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final presentation = workflow.presentation;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.86,
        ),
        child: SingleChildScrollView(
          key: LcKeys.workflowHelpSheet,
          padding: const EdgeInsets.fromLTRB(
            LcSpace.lg,
            0,
            LcSpace.lg,
            LcSpace.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              NameWithBadge(
                name: workflow.name,
                nameStyle: text.titleLarge,
                badge: presentation.badge,
                badgeTopInset: LcSpace.xxs,
              ),
              WorkflowHelpBody(workflow: workflow, detail: detail),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything this file says about a workflow **below** its name and badge.
///
/// One widget, two surfaces (T-0144). A card in the picker opens the sheet
/// above; the chosen workflow's block opens the same body inline, so a person
/// who reads one and then the other is not shown two accounts of the same
/// workflow. The order lives here and nowhere else — there is no second copy
/// of it to drift.
///
/// The name and badge are deliberately not part of it: the sheet draws them as
/// its title, and the block already has both on the header the disclosure
/// hangs off, one line above.
class WorkflowHelpBody extends StatelessWidget {
  const WorkflowHelpBody({super.key, required this.workflow, this.detail});

  final WorkflowSummary workflow;

  /// The field schema behind the Defaults section, or `null` to draw no
  /// Defaults section at all — which is what a caller that has not asked for
  /// one passes.
  final Future<WorkflowDetail?>? detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final presentation = workflow.presentation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (presentation.category != null) ...<Widget>[
          const SizedBox(height: LcSpace.xxs),
          Text(
            presentation.category!,
            style: text.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ],
        if (presentation.shortDescription != null) ...<Widget>[
          const SizedBox(height: LcSpace.md),
          Text(
            presentation.shortDescription!,
            style: text.bodyLarge?.copyWith(color: palette.textSecondary),
          ),
        ],
        if (workflow.inputSummary != null)
          _Section(
            title: l.helpWhatItNeeds,
            child: Text(workflow.inputSummary!, style: text.bodyMedium),
          ),
        if (presentation.bestFor.isNotEmpty)
          _Section(
            title: l.helpBestFor,
            child: _Bullets(items: presentation.bestFor),
          ),
        if (presentation.howToUse != null)
          _Section(
            title: l.helpHowToUse,
            child: Text(presentation.howToUse!, style: text.bodyMedium),
          ),
        if (detail != null) _DefaultsSection(detail: detail!),
        if (presentation.examplePrompt != null)
          _Section(
            title: l.helpExamplePrompt,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(LcSpace.sm),
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                borderRadius: BorderRadius.circular(LcRadius.md),
              ),
              child: Text(
                presentation.examplePrompt!,
                style: text.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: palette.textSecondary,
                ),
              ),
            ),
          ),
        if (presentation.notIdealFor.isNotEmpty)
          _Section(
            title: l.helpNotIdealFor,
            child: _Bullets(items: presentation.notIdealFor),
          ),
      ],
    );
  }
}

/// The defaults a workflow arrives with, read off its own field schema.
///
/// Shown only once the schema is known and only when it actually carries
/// defaults — the section is absent otherwise, like every other one here.
class _DefaultsSection extends StatelessWidget {
  const _DefaultsSection({required this.detail});

  final Future<WorkflowDetail?> detail;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WorkflowDetail?>(
      future: detail,
      builder: (context, snapshot) {
        // Only what *this* future answered. `FutureBuilder` keeps the previous
        // snapshot's data when it is handed a new future, so without this the
        // block would draw one workflow's defaults under another workflow's
        // description for a frame after Change (T-0144). The section is absent
        // while a schema is on its way, which is exactly what it already did
        // before the first one arrived.
        final loaded = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (loaded == null) return const SizedBox.shrink();
        final l = L.of(context);
        final entries = describeDefaults(l, loaded);
        if (entries.isEmpty) return const SizedBox.shrink();
        final palette = context.palette;
        final text = Theme.of(context).textTheme;
        return _Section(
          key: LcKeys.workflowHelpDefaults,
          title: l.helpDefaults,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: LcSpace.xxs),
                  child: LabelValueRow(
                    labelWidth: 132,
                    label: Text(
                      entry.label,
                      style: text.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                    ),
                    value: Text(entry.value, style: text.bodySmall),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// One "Steps — 20" line of the Defaults section.
@immutable
class DefaultEntry {
  const DefaultEntry({required this.label, required this.value});

  final String label;
  final String value;
}

/// The defaults worth telling a user about, in declaration order.
///
/// A field with no declared default has nothing to report, and neither does a
/// media field or one whose default is an empty string — "Avoid: " reads as a
/// bug rather than as information.
List<DefaultEntry> describeDefaults(L l, WorkflowDetail detail) {
  final entries = <DefaultEntry>[];
  for (final field in detail.inputs) {
    if (!field.hasDefault) continue;
    final value = _describeDefault(l, field);
    if (value == null) continue;
    entries.add(DefaultEntry(label: field.label, value: value));
  }
  return entries;
}

String? _describeDefault(L l, WorkflowField field) {
  final value = field.defaultValue;
  switch (field.type) {
    case FieldType.boolean:
      return value == true ? l.on : l.off;
    case FieldType.integer:
    case FieldType.float:
      return value is num ? formatNumber(field, value) : null;
    case FieldType.select:
      for (final option in field.options) {
        if (option.value == value) return option.label;
      }
      return value == null ? null : '$value';
    case FieldType.string:
    case FieldType.multiline:
      final text = value is String ? value.trim() : '';
      return text.isEmpty ? null : text;
    case FieldType.image:
    case FieldType.video:
    case FieldType.unsupported:
      return null;
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: LcSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: palette.textMuted,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: LcSpace.xs),
          child,
        ],
      ),
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: LcSpace.xxs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: LcSpace.xs),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.textMuted,
                    ),
                  ),
                ),
                Expanded(child: Text(item, style: text.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
