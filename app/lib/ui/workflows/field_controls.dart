/// One control per field type (`docs/ui-ux.md`, `docs/workflow-schema.md`).
///
/// Natural controls, not a property grid: a switch is a switch, a bounded
/// number is a slider, an unbounded one is an entry, and a choice is a set of
/// choices. The branch below is on the field's **type**, which is the schema's
/// own closed list — never on a group, a category or a badge, which are data.
///
/// `role`, `pair` and `duration` add to a control and never define one. A
/// `role: seed` integer is the same numeric control every other integer gets,
/// with a Random button beside it and a Freeze seed switch under it; a
/// `duration` integer is that same control with a line under it saying what
/// its frame count reads as. Take the hints away and every field is still
/// complete, which is the difference between a schema and a schema only this
/// app can read.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../generation/translation.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/field_layout.dart';
import '../../workflows/workflow_form.dart';
import '../../workflows/workflow_models.dart';
import '../keys.dart';
import 'media_field_control.dart';

/// Builds the control for one field.
class FieldControl extends StatelessWidget {
  const FieldControl({
    super.key,
    required this.field,
    required this.form,
    required this.validation,
    this.translation,
    this.capability = TranslationCapability.unknown,
    this.showQuoteHint = false,
    this.exampleText,
  });

  final WorkflowField field;
  final WorkflowFormController form;

  /// The current validation, so a field can show what is wrong with its own
  /// value. A required field that is simply empty is *not* wrong — see
  /// [_FieldFrame].
  final ValidatedForm validation;

  /// What the gateway did to this field's text on the last submission, or
  /// `null` — which is the ordinary case and draws nothing at all.
  ///
  /// It is read here and never written back: the control below is still built
  /// from [WorkflowFormController], which holds the user's own words.
  final FieldTranslation? translation;

  /// What the server said it can translate, read before anything is
  /// submitted. [TranslationCapability.unknown] — a gateway older than the
  /// feature, and the default — draws nothing, exactly as this form did
  /// before the capability existed.
  final TranslationCapability capability;

  /// Whether this is the one field carrying the quote hint.
  final bool showQuoteHint;

  /// The workflow's example prompt, on the one field it would fill, or `null`
  /// everywhere else — which includes every field of a workflow that declares
  /// no example. There is then no affordance at all, rather than a dead one.
  final String? exampleText;

  @override
  Widget build(BuildContext context) {
    final issue = validation.issueFor(field.id);
    final example = exampleText;
    final useExample = example == null
        ? null
        : _UseExampleButton(field: field, form: form, example: example);
    switch (field.type) {
      case FieldType.boolean:
        return _FieldFrame(
          field: field,
          issue: issue,
          showLabel: false,
          child: _BooleanControl(field: field, form: form),
        );
      case FieldType.string:
        return _FieldFrame(
          field: field,
          issue: issue,
          // Prose is the only thing the gateway may translate and the only
          // thing quotes protect (`docs/workflow-schema.md`), so both belong
          // to the two text branches and to nothing else.
          translation: translation,
          capability: capability,
          form: form,
          showQuoteHint: showQuoteHint,
          action: useExample,
          child: _TextEntry(
            fieldId: field.id,
            value: form.text(field.id),
            lines: 1,
            onChanged: (value) => form.setEntry(field.id, value),
          ),
        );
      case FieldType.multiline:
        return _FieldFrame(
          field: field,
          issue: issue,
          translation: translation,
          capability: capability,
          form: form,
          showQuoteHint: showQuoteHint,
          action: useExample,
          child: _TextEntry(
            fieldId: field.id,
            value: form.text(field.id),
            // Five, not four (T-0144). This is the field a person spends the
            // most time in, and one more line is what "slightly bigger" was
            // asked for. `_TextEntry` turns it into minLines 5 / maxLines 7.
            lines: 5,
            onChanged: (value) => form.setEntry(field.id, value),
          ),
        );
      case FieldType.integer:
      case FieldType.float:
        return _NumericField(field: field, form: form, issue: issue);
      case FieldType.select:
        return _FieldFrame(
          field: field,
          issue: issue,
          child: _SelectControl(field: field, form: form),
        );
      case FieldType.image:
      case FieldType.video:
        final media = form.media(field.id);
        return _FieldFrame(
          field: field,
          issue: issue,
          child: media == null
              ? const _UnsupportedPlaceholder()
              : MediaFieldControl(field: field, media: media),
        );
      case FieldType.unsupported:
        return _FieldFrame(
          field: field,
          issue: issue,
          child: const _UnsupportedPlaceholder(),
        );
    }
  }
}

/// The label, the requirement and the help around a control.
///
/// A required field carries a quiet "Required" beside its label from the
/// moment it appears. That is the non-punitive form of the requirement
/// `docs/ui-ux.md` asks for: it is a fact about the field, stated before the
/// user does anything, and it never turns red for being untouched. Only a
/// value that is actually wrong — a number that is not one, or one outside the
/// declared range — is shown as a problem.
class _FieldFrame extends StatelessWidget {
  const _FieldFrame({
    required this.field,
    required this.child,
    this.issue,
    this.trailing,
    this.action,
    this.reading,
    this.showLabel = true,
    this.translation,
    this.capability = TranslationCapability.unknown,
    this.form,
    this.showQuoteHint = false,
  });

  final WorkflowField field;
  final Widget child;
  final FieldIssue? issue;

  /// A small affordance beside the label, where the label and it fit together
  /// — a Random beside a seed.
  final Widget? trailing;

  /// A small affordance under the control, for one that does not fit beside a
  /// label: on a narrow pane a label, a "Required" and a two-word button
  /// together are wider than the pane, and the one that has to give way is
  /// the button rather than the field's own name.
  final Widget? action;

  /// A second way of reading the value directly under the control — a frame
  /// count's duration, and nothing else so far. It is placed *under* the
  /// control rather than in place of anything, so the value the workflow will
  /// actually receive stays on screen beside it.
  final Widget? reading;
  final bool showLabel;
  final FieldTranslation? translation;

  /// What the server says about translation, and the form the override is
  /// held in. Both are passed only on the two prose branches, so no other
  /// control can grow a translation affordance by accident.
  final TranslationCapability capability;
  final WorkflowFormController? form;
  final bool showQuoteHint;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final issue = this.issue;
    final showsProblem =
        issue != null &&
        (issue.kind == FieldIssueKind.notANumber ||
            issue.kind == FieldIssueKind.outOfRange);

    return Padding(
      key: LcKeys.fieldRow(field.id),
      padding: const EdgeInsets.only(bottom: LcSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showLabel)
            Padding(
              padding: const EdgeInsets.only(bottom: LcSpace.xs),
              // The requirement gives too (T-0154, absorbing T-0155). This
              // line *looked* correct — `field.label` was already wrapped in
              // a `Flexible`, and a design note read that and called the widget the
              // reference shape. It was wrong: `l.fieldRequired` beside it
              // was a bare `Text`, so the label collapsing to nothing was
              // still not enough to save the row. «Обязательное» is twelve
              // characters where `Required` is eight, and the row overflowed
              // in Russian by 37px at 320dp/2.0 and 53px at 840dp/2.0, clean
              // at all fifteen combinations in English — which is why every
              // guard the app had passed.
              //
              // **One `Flexible` in a `Row` proves nothing about the row.**
              //
              // So there is no `Row` here any more, and nothing on this line
              // is inflexible:
              //
              //  1. the name and the requirement at the left, `trailing`
              //     pushed hard against the right edge by the free space
              //     `spaceBetween` puts between them.
              //
              //     This is a **new** property, not a preserved one, and it
              //     is worth being exact about because the old code looks as
              //     though it had it. `Spacer` is `Expanded` with a
              //     `SizedBox.shrink` in it, so on `main` the `Flexible`
              //     label and the `Spacer` both carried flex 1 and *split*
              //     the free space: whatever the label did not use, the
              //     `Spacer` gave back only half of. The trailing therefore
              //     sat short of the edge by a distance that varied with the
              //     length of the field's name — measured on the seed row,
              //     55.3dp short at 412dp/1.0, 39.3dp at 1100dp/1.0, 9.3dp
              //     at 320dp/1.0 and 1.3dp at 840dp/1.0. It is flush at 0.0
              //     now, everywhere it fits, which is what the `Spacer` was
              //     always meant to do and never did;
              //  2. the requirement drops onto its own line under the name,
              //     still legible, because a marker that says a field cannot
              //     be left empty is worth a line;
              //  3. the name itself takes a second line before it is cut;
              //  4. `trailing` takes a line of its own rather than pushing
              //     the row past the pane.
              //
              // The requirement yields by moving, never by disappearing and
              // never by being clipped: it is the only thing on screen that
              // says the field is not optional.
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  key: LcKeys.fieldLabelRow(field.id),
                  spacing: LcSpace.xs,
                  runSpacing: LcSpace.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: <Widget>[
                    // The name and the requirement are one group, so the free
                    // space falls between the group and `trailing` and not
                    // between the two words a person reads together.
                    Wrap(
                      spacing: LcSpace.xs,
                      runSpacing: LcSpace.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          field.label,
                          style: text.labelLarge,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // Uncapped, where the field's name is capped at two
                        // lines: the name is the curator's prose and could be
                        // a paragraph, and this is the app's own word for the
                        // one thing a person has to know about the field. It
                        // is never shortened and never cut — it moves.
                        if (field.required)
                          Text(
                            l.fieldRequired,
                            style: text.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                          ),
                      ],
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ),
          child,
          ?reading,
          if (action != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: LcSpace.xxs),
                child: action,
              ),
            ),
          if (showsProblem)
            Padding(
              padding: const EdgeInsets.only(top: LcSpace.xxs),
              child: Text(
                issue.message(l),
                style: text.bodySmall?.copyWith(color: palette.warning),
              ),
            )
          else if (field.help != null)
            Padding(
              padding: const EdgeInsets.only(top: LcSpace.xxs),
              child: Text(
                field.help!,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ),
          if (showQuoteHint)
            Padding(
              key: LcKeys.quoteHint,
              padding: const EdgeInsets.only(top: LcSpace.xxs),
              child: Text(
                l.quoteHint,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ),
          if (form != null && _TranslationNotice.saysAnything(capability))
            Padding(
              padding: const EdgeInsets.only(top: LcSpace.xxs),
              child: _TranslationNotice(
                fieldId: field.id,
                capability: capability,
                form: form!,
              ),
            ),
          if (translation != null)
            Padding(
              padding: const EdgeInsets.only(top: LcSpace.xs),
              child: _TranslationNote(translation: translation!),
            ),
        ],
      ),
    );
  }
}

/// Use example: the workflow's own `example_prompt`, one tap away
/// (`docs/workflow-schema.md`, `docs/ui-ux.md`).
///
/// It writes the example into the field exactly as the registry wrote it, and
/// stops being an example at that moment: the text is the user's from then on,
/// editable like anything else they typed.
///
/// **It never replaces typed text silently.** A half-written prompt lost to a
/// mis-tap is the failure this control exists to avoid, so a field that
/// already holds something is a question first and a replacement second — and
/// the answer that costs nothing (keeping what is there) is the one a stray
/// tap outside the dialog gives.
class _UseExampleButton extends StatelessWidget {
  const _UseExampleButton({
    required this.field,
    required this.form,
    required this.example,
  });

  final WorkflowField field;
  final WorkflowFormController form;
  final String example;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: LcKeys.useExample,
      onPressed: () => _fill(context),
      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
      label: Text(L.of(context).useExample),
      style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
    );
  }

  Future<void> _fill(BuildContext context) async {
    // Whitespace alone is what an empty field looks like everywhere else in
    // this form — `validate()` calls it missing — so it is not something to
    // protect either.
    if (form.text(field.id).trim().isEmpty) {
      form.setEntry(field.id, example);
      return;
    }
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: LcKeys.useExampleConfirm,
        title: Text(L.of(context).replaceWrittenTextTitle),
        content: Text(L.of(context).useExampleConfirmBody(field.label)),
        actions: <Widget>[
          TextButton(
            key: LcKeys.useExampleKeep,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.of(context).keepWrittenText),
          ),
          FilledButton(
            key: LcKeys.useExampleReplace,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.of(context).useExample),
          ),
        ],
      ),
    );
    // Anything but a deliberate yes — Keep mine, a tap outside, the back
    // gesture — leaves what the user wrote where it is.
    if (replace != true) return;
    form.setEntry(field.id, example);
  }
}

/// `RU → EN`, and the two texts behind it.
///
/// Small, and closed. `docs/ui-ux.md` gives the space to the work, and the
/// requirement this implements is explicit that the two prompts are never both
/// on screen at once — so this is a disclosure, not a second pane, and it
/// starts shut every time the field is built.
///
/// It says what happened to one run. It is not an editor and it writes
/// nothing: the effective text is here to be read, and the field above still
/// holds the user's own words, character for character.
/// What the server will do with this text, said **before** it is submitted,
/// and the one switch that changes it (`docs/api.md`, T-0043).
///
/// It is one line, in the same muted voice as the quote hint above it, and it
/// exists only where it has something true to say:
///
/// * a gateway older than the capability says nothing, so neither does this —
///   the form renders exactly as it did before;
/// * a PC with the stage switched off says nothing either. A permanent line
///   about an optional stage nobody asked for is noise, and it would be under
///   every prompt of every workflow for most users;
/// * a PC that is set up to translate and cannot says what will actually
///   happen — the attempt **fails**, it does not quietly go through as typed
///   — and offers the switch, because switching it off is the difference
///   between a refused submission and a generation;
/// * a PC that really translates gets the sentence and the switch.
///
/// So the switch is on screen wherever the stage will be attempted, and only
/// there. It can only turn translation *off*, for the next submission of this
/// workflow, and it writes nothing to disk. The prompt itself is never touched
/// by anything here.
class _TranslationNotice extends StatelessWidget {
  const _TranslationNotice({
    required this.fieldId,
    required this.capability,
    required this.form,
  });

  final String fieldId;
  final TranslationCapability capability;
  final WorkflowFormController form;

  /// Whether this notice has anything true to say about [capability].
  ///
  /// The same predicate the override uses, and deliberately one predicate: the
  /// two cannot drift into a form where the sentence says the stage will run
  /// and the switch that stops it is missing.
  static bool saysAnything(TranslationCapability capability) =>
      capability.isEnabled;

  @override
  Widget build(BuildContext context) {
    // Built only where [saysAnything] said there was something to say, which
    // is the same predicate as [TranslationCapability.canOverride] — so the
    // sentence and the switch appear together or not at all, and there is no
    // state where the form says the stage will run and hides the one control
    // that stops it.
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            key: LcKeys.translationNotice(fieldId),
            _sentenceIn(L.of(context)),
            style: text.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ),
        const SizedBox(width: LcSpace.xs),
        Switch(
          key: LcKeys.translationOverride(fieldId),
          value: form.translatePrompt,
          activeThumbColor: palette.onAccent,
          activeTrackColor: palette.accent,
          onChanged: (next) => form.translatePrompt = next,
        ),
      ],
    );
  }

  String _sentenceIn(L l) {
    // Read first, because it is the one answer that is true in every state
    // this notice appears in: the stage was going to be attempted and this
    // submission has switched it off.
    if (!form.translatePrompt) {
      return l.translationSentAsTyped;
    }
    if (capability.isSwitchedOnButUnusable) {
      // Not "sent as typed": the gateway attempts the stage and refuses the
      // submission (`docs/api.md`). Saying otherwise would be wrong about the
      // next thing that happens to the user. The two missing steps are two
      // sentences because two different commands fix them, and both are for
      // the person at the PC — the command itself lives in the gateway, which
      // names it in the failure, and is not restated here.
      return capability.support == TranslationSupport.noLanguages
          ? l.translationNoLanguages
          : l.translationNotInstalled;
    }
    final from = capability.sourceLabels.join(l.translationOrSeparator);
    final to = capability.targetLabel;
    if (from.isEmpty || to == null) {
      // Nothing nameable came back. The fact still holds, and half a language
      // pair says nothing a person can act on — the same rule the indicator
      // under a finished generation follows.
      return l.translationGeneric;
    }
    return l.translationPair(from, to);
  }
}

class _TranslationNote extends StatefulWidget {
  const _TranslationNote({required this.translation});

  final FieldTranslation translation;

  @override
  State<_TranslationNote> createState() => _TranslationNoteState();
}

class _TranslationNoteState extends State<_TranslationNote> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final translation = widget.translation;
    // Non-null by construction: `TranslationReport.appliedFor` refuses a pair
    // it cannot name, so there is no path here with half a label.
    final pair = translation.pairLabel!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: LcKeys.translation(translation.fieldId),
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(LcRadius.pill),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: LcSpace.xxs,
                horizontal: LcSpace.xxs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LcSpace.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceRaised,
                      borderRadius: BorderRadius.circular(LcRadius.pill),
                      border: Border.all(color: palette.outline),
                    ),
                    child: Text(
                      pair,
                      style: text.labelSmall?.copyWith(
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: LcSpace.xs),
                  Flexible(
                    child: Text(
                      L.of(context).translationApplied,
                      style: text.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Container(
            key: LcKeys.translationDetail(translation.fieldId),
            width: double.infinity,
            margin: const EdgeInsets.only(top: LcSpace.xxs),
            padding: const EdgeInsets.all(LcSpace.sm),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(LcRadius.md),
              border: Border.all(color: palette.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _TranslationText(
                  label: L.of(context).translationOriginal,
                  value: translation.original,
                ),
                const SizedBox(height: LcSpace.sm),
                _TranslationText(
                  label: L.of(context).translationSentToWorkflow,
                  value: translation.effective,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TranslationText extends StatelessWidget {
  const _TranslationText({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: text.labelSmall?.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: text.bodySmall?.copyWith(color: palette.textSecondary),
        ),
      ],
    );
  }
}

class _BooleanControl extends StatelessWidget {
  const _BooleanControl({required this.field, required this.form});

  final WorkflowField field;
  final WorkflowFormController form;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final value = form.flag(field.id);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(field.label, style: text.labelLarge),
        ),
        Switch(
          key: LcKeys.field(field.id),
          value: value,
          activeThumbColor: palette.onAccent,
          activeTrackColor: palette.accent,
          onChanged: (next) => form.setEntry(field.id, next),
        ),
      ],
    );
  }
}

class _SelectControl extends StatelessWidget {
  const _SelectControl({required this.field, required this.form});

  /// Above this many choices a row of chips stops being a row and becomes a
  /// wall, and a menu is the kinder control.
  static const int kChipLimit = 4;

  final WorkflowField field;
  final WorkflowFormController form;

  @override
  Widget build(BuildContext context) {
    final value = form.entry(field.id);
    if (field.options.length > kChipLimit) {
      return DropdownButtonFormField<Object?>(
        key: LcKeys.field(field.id),
        initialValue: value,
        isExpanded: true,
        items: <DropdownMenuItem<Object?>>[
          for (final option in field.options)
            DropdownMenuItem<Object?>(
              value: option.value,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (next) => form.setEntry(field.id, next),
      );
    }
    return Wrap(
      key: LcKeys.field(field.id),
      spacing: LcSpace.xs,
      runSpacing: LcSpace.xs,
      children: <Widget>[
        for (final option in field.options)
          ChoiceChip(
            label: Text(option.label),
            selected: option.value == value,
            onSelected: (_) => form.setEntry(field.id, option.value),
          ),
      ],
    );
  }
}

/// An integer or a float: a slider when the declared range can be addressed by
/// a thumb, an entry when it cannot.
///
/// Which one it is comes from [numericControlFor], which reads `min`, `max`
/// and `step` and nothing else. A seed gets an entry because 0 to 4294967295
/// is unusable as a slider, not because it said `role: seed`.
///
/// A field whose workflow declared a frame rate also gets a duration under the
/// control ([durationReadingFor]). It is a reading and never an input: the
/// value moves in frames, on the field's own step grid, so no duration this
/// control shows can name a frame count `min`, `max` and `step` disallow.
class _NumericField extends StatelessWidget {
  const _NumericField({
    required this.field,
    required this.form,
    required this.issue,
  });

  final WorkflowField field;
  final WorkflowFormController form;
  final FieldIssue? issue;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final control = numericControlFor(field);
    final isSeed = field.role == FieldRole.seed;
    final random = isSeed
        ? TextButton.icon(
            key: LcKeys.fieldRandom(field.id),
            onPressed: () => form.setNumber(field, randomSeedValue(field)),
            icon: const Icon(Icons.casino_outlined, size: 18),
            label: Text(l.fieldRandom),
            style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
          )
        : null;
    final freeze = isSeed ? _FreezeSeed(field: field, form: form) : null;

    if (control == NumericControl.slider) {
      final min = field.min!;
      final max = field.max!;
      final current = (_currentValue() ?? min).clamp(min, max).toDouble();
      return _FieldFrame(
        field: field,
        issue: issue,
        action: freeze,
        reading: _duration(context, current),
        // A Wrap and not a Row (T-0159): the value and a Random button whose
        // label grows with the text scale, neither of which can give. Where
        // both do not fit on one line the button takes the next.
        trailing: Wrap(
          spacing: LcSpace.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              formatNumber(field, current),
              style: text.labelLarge?.copyWith(color: palette.textSecondary),
            ),
            ?random,
          ],
        ),
        child: Slider(
          key: LcKeys.field(field.id),
          value: current,
          min: min,
          max: max,
          divisions: sliderTicksFor(field),
          label: formatNumber(field, current),
          // The step is honoured by the value, not by the tick marks: a field
          // with fifty of them would otherwise draw a dotted line rather than
          // a track.
          onChanged: (next) => form.setNumber(field, snapToStep(field, next)),
        ),
      );
    }

    final typed = _currentValue();
    return _FieldFrame(
      field: field,
      issue: issue,
      trailing: random,
      action: freeze,
      // Only for a value that is actually a number: half a typed number reads
      // as no duration at all rather than as a wrong one.
      reading: typed == null ? null : _duration(context, typed),
      child: _TextEntry(
        fieldId: field.id,
        value: form.text(field.id),
        lines: 1,
        keyboardType: TextInputType.numberWithOptions(
          decimal: field.type == FieldType.float,
          signed: (field.min ?? 0) < 0,
        ),
        formatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(
            field.type == FieldType.float
                ? RegExp(r'[0-9.\-]')
                : RegExp(r'[0-9\-]'),
          ),
        ],
        hint: field.min != null || field.max != null
            ? describeRange(l, field)
            : null,
        onChanged: (value) => form.setEntry(field.id, value),
      ),
    );
  }

  /// The duration line, or `null` for every field that declared no rate.
  Widget? _duration(BuildContext context, num value) {
    final reading = durationReadingFor(L.of(context), field, value);
    if (reading == null) return null;
    final palette = context.palette;
    return Padding(
      key: LcKeys.fieldDuration(field.id),
      padding: const EdgeInsets.only(top: LcSpace.xxs),
      child: Text(
        reading,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: palette.textSecondary),
      ),
    );
  }

  double? _currentValue() => double.tryParse(form.text(field.id).trim());
}

/// Freeze seed: what Generate Again does with the number above it.
///
/// **Off by default**, and it says which of the two things is going to happen
/// rather than leaving the user to infer it from the word "freeze". That
/// sentence is the discoverable half of the whole feature: the seed lives
/// under Advanced, and before this switch existed a person who pressed
/// Generate Again and got a different picture had nothing on screen telling
/// them why — or, with it on, why not.
class _FreezeSeed extends StatelessWidget {
  const _FreezeSeed({required this.field, required this.form});

  final WorkflowField field;
  final WorkflowFormController form;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Switch(
              key: LcKeys.freezeSeed(field.id),
              value: form.freezeSeed,
              activeThumbColor: palette.onAccent,
              activeTrackColor: palette.accent,
              onChanged: (next) => form.freezeSeed = next,
            ),
            const SizedBox(width: LcSpace.xs),
            Flexible(
              child: Text(L.of(context).freezeSeed, style: text.bodyMedium),
            ),
          ],
        ),
        Text(
          form.freezeSeed
              ? L.of(context).freezeSeedOn
              : L.of(context).freezeSeedOff,
          key: LcKeys.freezeSeedNote(field.id),
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
      ],
    );
  }
}

/// A field type this build has never heard of. Said out loud rather than
/// dropped: a workflow silently running without one of its inputs would be
/// worse than a workflow that says it cannot run here.
class _UnsupportedPlaceholder extends StatelessWidget {
  const _UnsupportedPlaceholder();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(LcRadius.md),
        border: Border.all(color: palette.outline),
      ),
      child: Text(
        L.of(context).unsupportedInput,
        style: text.bodySmall?.copyWith(color: palette.textMuted),
      ),
    );
  }
}

/// A text field whose text is owned by the form, not by the widget.
///
/// The form is the single copy of the value, so a Random press or a reset
/// reaches the visible text; the cursor is put back at the end rather than
/// jumping home, which is what a naive re-assignment does.
class _TextEntry extends StatefulWidget {
  const _TextEntry({
    required this.fieldId,
    required this.value,
    required this.lines,
    required this.onChanged,
    this.keyboardType,
    this.formatters,
    this.hint,
  });

  final String fieldId;
  final String value;
  final int lines;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? formatters;
  final String? hint;

  @override
  State<_TextEntry> createState() => _TextEntryState();
}

class _TextEntryState extends State<_TextEntry> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant _TextEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: LcKeys.field(widget.fieldId),
      controller: _controller,
      onChanged: widget.onChanged,
      keyboardType:
          widget.keyboardType ??
          (widget.lines > 1 ? TextInputType.multiline : TextInputType.text),
      textInputAction: widget.lines > 1
          ? TextInputAction.newline
          : TextInputAction.done,
      inputFormatters: widget.formatters,
      minLines: widget.lines > 1 ? widget.lines : 1,
      maxLines: widget.lines > 1 ? widget.lines + 2 : 1,
      // Up to six lines, not one (T-0190): the hint is the curator's range, and
      // a seed's 0..4294967295 is twenty-four characters before the sentence
      // around it. Cut to one line it was cut at every pane width the app
      // draws; three were measured not enough at 841dp and a 2.0 scale, where
      // the ten digits alone are wider than the field and break mid-number.
      // Six holds that range at every width and scale the sweep draws. A
      // curator range longer still can be cut, and that is a stated limit,
      // not an oversight: an unbounded hint would grow an empty one-line
      // field without end.
      decoration: InputDecoration(hintText: widget.hint, hintMaxLines: 6),
    );
  }
}
