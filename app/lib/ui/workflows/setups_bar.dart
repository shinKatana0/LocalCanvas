/// Saved setups, in the form they belong to.
///
/// A flat list of named things and one affordance that makes another. No
/// folders, no tags, no order the user maintains, no search and no sharing
/// — a setup is a name and what it brings back, and this is
/// the whole interface to it.
///
/// Three deliberate choices about the four operations:
///
/// * **Applying asks only when it would take words away.** Picking a setup by
///   the name you gave it is already the deliberate act, so the common flow —
///   applying onto a form with no prose in it, or prose the setup would leave
///   as it is — costs one tap and no question. What it may not do is empty or
///   overwrite a prompt somebody is in the middle of writing without being
///   told to: that text is unrecoverable, and Use example protects the same
///   text in the same form for the same reason. The form decides which case
///   this is ([WorkflowFormController.setupWouldReplaceProse]) — the rules
///   about what a setup writes live beside the code that writes it, and this
///   widget keeps no copy of them.
/// * **Deleting does.** There is no undo anywhere in this app, and a setup is
///   something a person made on purpose, so the only protection it can have
///   is being asked about once.
/// * **Renaming reuses the dialog Save already needed.** One place asks for a
///   name, for both, which is why renaming exists at all: it cost a title and
///   a starting value, not a screen.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/workflow_form.dart';
import '../../workflows/workflow_setup_store.dart';
import '../keys.dart';

/// What can be done about setups, or `null` where nothing can.
///
/// One object rather than five parameters on the form, so that "this build
/// keeps no setups" is one condition in one place — the same shape
/// `onSaveDefaults` uses for My defaults.
@immutable
class SetupActions {
  const SetupActions({
    required this.setups,
    required this.onSave,
    required this.onApply,
    required this.onRename,
    required this.onDelete,
  });

  /// This workflow's setups, in the order the store gave them.
  final List<WorkflowSetup> setups;

  /// Keep what is in the form under a name the user has just given.
  final void Function(String name) onSave;

  /// Put one back into the form.
  final void Function(WorkflowSetup setup) onApply;

  /// Give one another name. Identity is not involved.
  final void Function(WorkflowSetup setup, String name) onRename;

  /// Forget exactly one.
  final void Function(WorkflowSetup setup) onDelete;
}

/// The list, and the way to add to it.
class SetupsBar extends StatelessWidget {
  const SetupsBar({
    super.key,
    required this.actions,
    required this.form,
    required this.savesProse,
  });

  final SetupActions actions;

  /// The form these setups go back into — asked, before one is applied,
  /// whether applying it would take away prose the user has written. The
  /// widget asks the question and shows a dialog; it does not answer it.
  final WorkflowFormController form;

  /// Whether this workflow has a field a person writes in, which decides
  /// which of two labels the Save affordance carries.
  ///
  /// Read from the field types and from nothing else: the label says what
  /// will be kept, and on a workflow of nothing but numbers it would be
  /// promising a prompt that does not exist.
  final bool savesProse;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Nothing saved yet: no heading, no list, no empty state. A workflow
        // with no setups shows the form it always showed, plus one button.
        if (actions.setups.isNotEmpty)
          Padding(
            key: LcKeys.setups,
            padding: const EdgeInsets.only(top: LcSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(
                    left: LcSpace.xs,
                    bottom: LcSpace.xxs,
                  ),
                  child: Text(
                    l.setupsHeading,
                    style: text.labelSmall?.copyWith(
                      color: palette.textMuted,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                for (final setup in actions.setups)
                  _SetupRow(setup: setup, actions: actions, form: form),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: LcKeys.saveSetup,
            onPressed: () => _save(context),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: LcSpace.xs),
            ),
            child: Text(
              savesProse ? l.setupSaveWithProse : l.setupSaveSettingsOnly,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _save(BuildContext context) async {
    final l = L.of(context);
    final name = await askForSetupName(
      context,
      title: l.setupNameTitle,
      action: l.save,
    );
    if (name == null) return;
    actions.onSave(name);
  }
}

/// One setup: its name, which applies it, and the two things to do to it.
class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.setup,
    required this.actions,
    required this.form,
  });

  final WorkflowSetup setup;
  final SetupActions actions;
  final WorkflowFormController form;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      key: LcKeys.setup(setup.id),
      children: <Widget>[
        Expanded(
          child: TextButton(
            key: LcKeys.applySetup(setup.id),
            onPressed: () => _apply(context),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: LcSpace.xs),
            ),
            child: Text(
              setup.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        IconButton(
          key: LcKeys.renameSetup(setup.id),
          onPressed: () => _rename(context),
          tooltip: L.of(context).setupRenameTooltip,
          iconSize: 20,
          color: palette.textMuted,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          key: LcKeys.deleteSetup(setup.id),
          onPressed: () => _delete(context),
          tooltip: L.of(context).setupDeleteTooltip,
          iconSize: 20,
          color: palette.textMuted,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  /// Puts the setup back — asking first, and only where the form says there
  /// is something written to lose.
  ///
  /// The question is the same one Use example asks about the same text, in
  /// the same words: one app, one question about replacing what a person
  /// wrote. Its body names the **setup**, because a setup can rewrite several
  /// fields at once and the name is what the user tapped.
  Future<void> _apply(BuildContext context) async {
    if (form.setupWouldReplaceProse(setup)) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: LcKeys.applySetupConfirm,
          title: Text(L.of(context).replaceWrittenTextTitle),
          content: Text(L.of(context).setupApplyBody(setup.name)),
          actions: <Widget>[
            TextButton(
              key: LcKeys.applySetupKeep,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(L.of(context).keepWrittenText),
            ),
            FilledButton(
              key: LcKeys.applySetupReplace,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(L.of(context).replace),
            ),
          ],
        ),
      );
      // Anything but a deliberate yes — Keep mine, a tap outside, the back
      // gesture — leaves what the user wrote where it is. `showDialog` answers
      // with three values and treating it as two is how this class of bug gets
      // written.
      if (replace != true) return;
    }
    actions.onApply(setup);
  }

  Future<void> _rename(BuildContext context) async {
    final l = L.of(context);
    final name = await askForSetupName(
      context,
      title: l.setupRenameTitle,
      action: l.rename,
      initial: setup.name,
    );
    if (name == null) return;
    actions.onRename(setup, name);
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: LcKeys.deleteSetupConfirm,
        title: Text(L.of(context).setupForgetTitle),
        content: Text(L.of(context).setupForgetBody(setup.name)),
        actions: <Widget>[
          TextButton(
            key: LcKeys.deleteSetupKeep,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.of(context).setupKeepIt),
          ),
          FilledButton(
            key: LcKeys.deleteSetupAccept,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.of(context).delete),
          ),
        ],
      ),
    );
    // Anything but a deliberate yes — Keep it, a tap outside, the back
    // gesture — leaves the setup where it is.
    if (confirmed != true) return;
    actions.onDelete(setup);
  }
}

/// Asks for a name, and answers with it — or with `null` where the user
/// changed their mind.
///
/// The one dialog behind Save, behind Rename, and behind keeping a result:
/// three affordances that need exactly the same thing from the user, and one
/// place that asks for it.
Future<String?> askForSetupName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _SetupNameDialog(title: title, action: action, initial: initial),
);

class _SetupNameDialog extends StatefulWidget {
  const _SetupNameDialog({
    required this.title,
    required this.action,
    required this.initial,
  });

  final String title;
  final String action;
  final String initial;

  @override
  State<_SetupNameDialog> createState() => _SetupNameDialogState();
}

class _SetupNameDialogState extends State<_SetupNameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Whether there is a name to answer with. A setup called nothing at all
  /// would be a row the user cannot tell from another row.
  bool get _isNamed => _name.text.trim().isNotEmpty;

  void _submit() {
    if (!_isNamed) return;
    Navigator.of(context).pop(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: LcKeys.setupName,
      title: Text(widget.title),
      content: TextField(
        key: LcKeys.setupNameField,
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: L.of(context).setupNameLabel),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          key: LcKeys.setupNameCancel,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L.of(context).cancel),
        ),
        FilledButton(
          key: LcKeys.setupNameConfirm,
          onPressed: _isNamed ? _submit : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
