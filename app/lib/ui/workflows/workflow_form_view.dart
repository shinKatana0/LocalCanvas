/// The form for the chosen workflow (`docs/ui-ux.md`).
///
/// Main fields are visible, Advanced is collapsed behind an affordance that
/// says how many settings are behind it, and Generate says what it is waiting
/// for instead of being mysteriously grey.
///
/// The rows come from [planFormRows], which honours `pair` and does nothing
/// else with a hint. Remove every `pair` and `role` from the schema and this
/// widget renders the same fields with the same controls, one per line.
library;

import 'package:flutter/material.dart';

import '../../generation/translation.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/field_layout.dart';
import '../../workflows/workflow_draft_store.dart';
import '../../workflows/workflow_form.dart';
import '../../workflows/workflow_models.dart';
import '../keys.dart';
import 'field_controls.dart';
import 'setups_bar.dart';
import 'workflow_help_sheet.dart';
import 'workflow_picker.dart';

/// The chosen workflow, with the two things to do about it: change it, or read
/// what it is.
///
/// It explains itself **in place** (T-0144). The whole header is the tap
/// target and the account of the workflow opens beneath it, which is exactly
/// what the server block above it does — the two are drawn with the same
/// surface, radius and outline, so a person reads them as the same kind of
/// thing and is entitled to have them behave the same way. There is no "What
/// this does" button here any more, because the block now does that itself.
///
/// The body is [WorkflowHelpBody], the same widget the picker's sheet renders.
/// A card you have not chosen yet still opens a sheet; the one you have chosen
/// opens here. One implementation, two moments.
///
/// [open] and [onToggle] come from above for the reason written on
/// `_ServerDetailsOpen`'s twin in `connected_shell.dart`: a fold rebuilds the
/// shell, and a disclosure that kept its own state inside the layout branch
/// would shut itself every time the phone was unfolded.
class SelectedWorkflowCard extends StatelessWidget {
  const SelectedWorkflowCard({
    super.key,
    required this.workflow,
    required this.onChange,
    required this.open,
    required this.onToggle,
    this.detail,
  });

  final WorkflowSummary workflow;
  final VoidCallback onChange;

  /// Whether the account of this workflow is showing.
  final bool open;
  final VoidCallback onToggle;

  /// The field schema behind the Defaults section of the body, or `null` for
  /// no Defaults section.
  ///
  /// The caller hands over one future and keeps handing over the same one, so
  /// that a rebuild of this card — and there is one on every keystroke in the
  /// form below it — never starts a second request.
  final Future<WorkflowDetail?>? detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final presentation = workflow.presentation;
    final badge = presentation.badge;
    return Container(
      key: LcKeys.selectedWorkflow,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: LcKeys.selectedWorkflowToggle,
            onTap: onToggle,
            borderRadius: BorderRadius.circular(LcRadius.lg),
            child: Padding(
              padding: const EdgeInsets.all(LcSpace.md),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Whether the badge fits beside the name and still leaves
                  // the name [kMinNameEms] (T-0188). Decided on the width this
                  // row actually has, not on the window, because the pane is
                  // draggable and the text scale is the reader's. The arrow and
                  // its gap are this block's own fixed parts; the badge's gap
                  // is the shared rule's.
                  final arrow = IconTheme.of(context).size ?? 24;
                  final beside =
                      badge == null ||
                      badgeFitsBeside(
                        context,
                        rowWidth: constraints.maxWidth,
                        badge: badge,
                        nameStyle: text.titleSmall,
                        reserved: LcSpace.xs + arrow,
                      );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(workflow.name, style: text.titleSmall),
                            if (workflow.inputSummary != null) ...<Widget>[
                              const SizedBox(height: 2),
                              Text(
                                workflow.inputSummary!,
                                style: text.bodySmall?.copyWith(
                                  color: palette.textMuted,
                                ),
                              ),
                            ],
                            // Under the summary, where it has the column's
                            // whole width and wraps rather than spills.
                            if (badge != null && !beside) ...<Widget>[
                              const SizedBox(height: LcSpace.xxs),
                              WorkflowBadge(text: badge),
                            ],
                          ],
                        ),
                      ),
                      if (badge != null && beside) ...<Widget>[
                        const SizedBox(width: LcSpace.xs),
                        WorkflowBadge(text: badge),
                      ],
                      const SizedBox(width: LcSpace.xs),
                      Icon(
                        open ? Icons.expand_less : Icons.expand_more,
                        color: palette.textMuted,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          if (open)
            Padding(
              key: LcKeys.selectedWorkflowDetails,
              padding: const EdgeInsets.fromLTRB(
                LcSpace.md,
                0,
                LcSpace.md,
                LcSpace.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Divider(color: palette.outline, height: LcSpace.md),
                  WorkflowHelpBody(workflow: workflow, detail: detail),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LcSpace.sm,
              0,
              LcSpace.sm,
              LcSpace.xs,
            ),
            child: Wrap(
              spacing: LcSpace.xs,
              children: <Widget>[
                TextButton(
                  key: LcKeys.changeWorkflow,
                  onPressed: onChange,
                  style: _compact,
                  child: Text(L.of(context).change),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static final ButtonStyle _compact = TextButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: LcSpace.xs),
  );
}

/// The fields, the Advanced section, and Generate.
class WorkflowFormView extends StatelessWidget {
  const WorkflowFormView({
    super.key,
    required this.detail,
    required this.form,
    required this.onGenerate,
    this.onSaveDefaults,
    this.setups,
    this.translation = TranslationReport.none,
    this.capability = TranslationCapability.unknown,
    this.generationInFlight = false,
  });

  final WorkflowDetail detail;
  final WorkflowFormController form;

  /// Receives the validated input map. Wiring it to `POST /api/v1/jobs` is
  /// T-0007; this card ends at a map that is ready to send.
  final ValueChanged<ValidatedForm> onGenerate;

  /// Keeps the current safe values as the user's own defaults for this
  /// workflow, or `null` on a build that keeps none — in which case the whole
  /// row is absent rather than offering a Save that would write nowhere.
  final VoidCallback? onSaveDefaults;

  /// The saved setups of this workflow and what may be done with them, or
  /// `null` on a build that keeps none — in which case nothing about setups
  /// is drawn at all.
  ///
  /// A workflow that simply has none yet is not that case: it draws the one
  /// affordance that makes the first one, and no list.
  final SetupActions? setups;

  /// What the gateway did to the text of the generation on screen
  /// (`docs/api.md`). [TranslationReport.none] — the ordinary case, and the
  /// default — draws nothing anywhere in this form.
  ///
  /// It reaches the fields as a thing to *show*. The controls are still built
  /// from [form], which is the single copy of what the user typed, so nothing
  /// on this path can put an effective text where an original belongs.
  final TranslationReport translation;

  /// What the server said it *can* translate, read from the handshake before
  /// anything is submitted (`docs/api.md`).
  /// [TranslationCapability.unknown] — a gateway older than the feature, and
  /// the default — renders this form exactly as it rendered before the
  /// capability existed.
  final TranslationCapability capability;

  /// Whether a generation is progressing right now — uploading, queued or
  /// running (`docs/recovery.md`).
  ///
  /// It reaches this form as a plain fact, decided by whoever holds the job:
  /// the form has no generation and should not learn about one, exactly as it
  /// has no seed logic behind Generate Again.
  ///
  /// **Everything that is not progress leaves Generate available**, and that is
  /// the whole reason this is one bool rather than a state machine.
  /// `interrupted` is not progress, a bounded reconnect is not progress, and a
  /// recovery that ends without an answer is not progress either — a button
  /// held unavailable because the app is unsure is worse than the silence
  /// T-0182 was about.
  ///
  /// Defaults to false, so every caller that has no job renders exactly the
  /// form it rendered before this existed.
  final bool generationInFlight;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final validation = form.validate();
        final advanced = detail.advancedFields;
        // One rule about which field is the workflow's prose field, used by
        // the quote hint and by Use example alike. Two rules that could
        // disagree would put the example in one field and the hint under
        // another the first time a workflow declared two text inputs.
        final hintField = quoteHintFieldId(detail);
        final example = detail.presentation.examplePrompt;
        return Column(
          key: LcKeys.workflowForm,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ..._rows(detail.mainFields, validation, hintField, example),
            if (advanced.isNotEmpty)
              _AdvancedSection(
                open: form.advancedOpen,
                count: advanced.length,
                onToggle: () => form.advancedOpen = !form.advancedOpen,
                children: <Widget>[
                  for (final group in planFieldGroups(advanced)) ...<Widget>[
                    _GroupHeading(heading: group.heading),
                    ..._rowWidgets(group.rows, validation, hintField, example),
                  ],
                ],
              ),
            if (onSaveDefaults != null) ...<Widget>[
              const SizedBox(height: LcSpace.xs),
              _DefaultsBar(form: form, onSave: onSaveDefaults!),
            ],
            if (setups != null)
              SetupsBar(
                actions: setups!,
                // The form itself, because applying a setup asks before it
                // takes away prose somebody wrote — and the form is what
                // knows whether it would.
                form: form,
                // Decided from the field types, never from a field's name.
                savesProse: detail.inputs.any(isProse),
              ),
            const SizedBox(height: LcSpace.xs),
            _GenerateBar(
              validation: validation,
              onGenerate: () => onGenerate(validation),
              generationInFlight: generationInFlight,
            ),
          ],
        );
      },
    );
  }

  List<Widget> _rows(
    List<WorkflowField> fields,
    ValidatedForm validation,
    String? hintField,
    String? example,
  ) => _rowWidgets(planFormRows(fields), validation, hintField, example);

  List<Widget> _rowWidgets(
    List<FormRow> rows,
    ValidatedForm validation,
    String? hintField,
    String? example,
  ) {
    return <Widget>[
      for (final row in rows)
        switch (row) {
          SingleFieldRow(:final field) => FieldControl(
            field: field,
            form: form,
            validation: validation,
            translation: translation.appliedFor(field.id),
            // The same one field the quote hint and Use example go to: what
            // the gateway will do to prose belongs beside the prose, and one
            // rule decides which field that is.
            capability: field.id == hintField
                ? capability
                : TranslationCapability.unknown,
            showQuoteHint: field.id == hintField,
            // The example goes to the field the hint goes to, and to no
            // other. A workflow that declares none passes `null` here and
            // draws no affordance anywhere.
            exampleText: field.id == hintField ? example : null,
          ),
          // Together on one line, and still two independent controls with two
          // independent entries in the input map.
          //
          // A pair is `width`/`height` — numbers, never prose — so neither the
          // hint nor an indicator is passed here.
          PairedFieldRow(:final first, :final second) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: FieldControl(
                  field: first,
                  form: form,
                  validation: validation,
                ),
              ),
              const SizedBox(width: LcSpace.sm),
              Expanded(
                child: FieldControl(
                  field: second,
                  form: form,
                  validation: validation,
                ),
              ),
            ],
          ),
        },
    ];
  }
}

/// My defaults: keep these settings, go back to them, or go back to the ones
/// the workflow was published with.
///
/// Every label says **settings**, because that is exactly what all three
/// touch: the numbers, the switches and the choices `isSafeToKeep` admits. A
/// prompt and a chosen picture are not settings and no button here disturbs
/// one — someone reading only the label can predict what survives, which is
/// the whole point of saying the word.
///
/// The two resets are inverses of each other and both act on the form alone.
/// "Reset settings to workflow defaults" does **not** forget what was saved —
/// which is why "Reset settings to my defaults" is still on screen afterwards,
/// offering the way back. Forgetting them would be a different, destructive
/// promise, and it would need a different word than "reset".
class _DefaultsBar extends StatelessWidget {
  const _DefaultsBar({required this.form, required this.onSave});

  final WorkflowFormController form;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Wrap(
      spacing: LcSpace.xs,
      children: <Widget>[
        TextButton(
          key: LcKeys.saveMyDefaults,
          onPressed: onSave,
          style: _compact,
          child: Text(l.saveMyDefaults),
        ),
        // Nothing saved yet, nothing to go back to.
        if (form.hasMyDefaults)
          TextButton(
            key: LcKeys.resetToMyDefaults,
            onPressed: form.resetSettingsToMyDefaults,
            style: _compact,
            child: Text(l.resetToMyDefaults),
          ),
        TextButton(
          key: LcKeys.resetToWorkflowDefaults,
          onPressed: form.resetSettingsToWorkflowDefaults,
          style: _compact,
          child: Text(l.resetToWorkflowDefaults),
        ),
      ],
    );
  }

  static final ButtonStyle _compact = TextButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: LcSpace.xs),
  );
}

/// One group heading inside Advanced.
///
/// Deliberately small: a word and some space, in the idiom the rest of the
/// form already uses. Not a card, not an expander, and nothing that keeps
/// state of its own — the grouping is there to break a flat run into readable
/// pieces, not to become a second navigation layer.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.heading});

  final String heading;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      key: LcKeys.advancedGroup(heading),
      padding: const EdgeInsets.only(bottom: LcSpace.xs),
      child: Text(
        heading,
        style: text.labelSmall?.copyWith(
          color: palette.textMuted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Advanced settings, collapsed behind an affordance that says what is inside.
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.open,
    required this.count,
    required this.onToggle,
    required this.children,
  });

  final bool open;
  final int count;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: LcKeys.advancedToggle,
            onTap: onToggle,
            borderRadius: BorderRadius.circular(LcRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: LcSpace.sm,
                horizontal: LcSpace.xs,
              ),
              // The two labels give, the chevron does not (T-0153). Written
              // as `Row([Text, SizedBox, Text, Spacer, Icon])` this row had
              // no give at all: neither `Text` was flexible, so the pair of
              // them plus the chevron ran past the pane at eleven of the
              // fifteen width x text-scale combinations in English and
              // fourteen in Russian — «Дополнительно» is thirteen characters
              // where `Advanced` is eight.
              //
              // The yield is ordered, and the count is what gives first:
              //
              //  1. side by side, on one line, while both fit;
              //  2. the count drops onto its own line under the title — a
              //     `Wrap`, so what moves is the whole label and not its
              //     words, and the title never moves;
              //  3. a label that is still too wide takes a second line of its
              //     own, because `Wrap` hands each child the pane's width and
              //     `maxLines: 2` lets a `Text` given a width use it;
              //  4. past that, an ellipsis — the one truncation a person can
              //     actually see. Nothing here is ever clipped into nothing.
              //
              // `maxLines` is what makes step 3 happen at all: a `Text` with
              // an ellipsis and no `maxLines` is laid out on a single line,
              // so the count was ellipsised where it could have wrapped.
              //
              // There is no width at which this overflows, and none of the
              // above is sized against a measurement: `Expanded` takes
              // whatever is left over after the chevron — down to nothing —
              // and a `Wrap` reports no overflow of its own at any width.
              //
              // The whole row stays one tap target, and its height stays at
              // or above 48dp for the chevron alone: a 24dp icon between two
              // `LcSpace.sm` paddings is 48 before a word is drawn.
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Wrap(
                      spacing: LcSpace.xs,
                      runSpacing: LcSpace.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          L.of(context).formAdvanced,
                          style: text.labelLarge,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          L.of(context).formAdvancedCount(count),
                          style: text.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
        ),
        if (open)
          Padding(
            key: LcKeys.advancedSection,
            padding: const EdgeInsets.only(top: LcSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
      ],
    );
  }
}

/// Generate, and the reason it is not available.
///
/// `docs/ui-ux.md`: it communicates why rather than failing silently. The
/// sentence is present whenever the button is not — naming the field where a
/// field is what is missing, and naming the running generation where that is
/// what is in the way. There is no state in which the button is off and the
/// screen says nothing.
///
/// **A generation already in flight is one of those reasons** (T-0182). The
/// submission is refused while one is progressing — the controller holds one
/// job — and a primary action that takes the tap and then drops it leaves the
/// user looking at the previous picture with nothing to tell them why. So the
/// refusal is said *before* the tap, by the button not being there to press.
class _GenerateBar extends StatelessWidget {
  const _GenerateBar({
    required this.validation,
    required this.onGenerate,
    required this.generationInFlight,
  });

  final ValidatedForm validation;
  final VoidCallback onGenerate;

  /// Whether a generation is progressing right now, which is the one thing
  /// outside the form that can make Generate unavailable.
  final bool generationInFlight;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    // The job wins where both are true: a field the user can fix is worth
    // naming, and so is the one thing they cannot, but only one sentence fits
    // under a button and the running job is the reason that will clear itself.
    final reason = generationInFlight
        ? l.generateBlockedBusy
        : validation.blockedReason(l);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton(
          key: LcKeys.generate,
          onPressed: validation.isReady && !generationInFlight
              ? onGenerate
              : null,
          child: Text(L.of(context).generate),
        ),
        if (reason != null)
          Padding(
            key: LcKeys.generateReason,
            padding: const EdgeInsets.only(top: LcSpace.xs),
            child: Text(
              reason,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: palette.textSecondary),
            ),
          ),
      ],
    );
  }
}
