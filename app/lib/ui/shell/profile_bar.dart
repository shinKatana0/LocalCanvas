/// The portable profile: two affordances, and one sentence about what is in
/// the file.
///
/// It sits in the controls column rather than inside the form, because it is
/// the one thing on this screen that is not about the chosen workflow: a
/// profile is everything this device has saved, for every workflow at once.
///
/// The sentence is not decoration. A file that leaves the phone is the moment
/// a user is entitled to know what is in it, and `docs/privacy-security.md`
/// makes precision about that a rule rather than a courtesy — so the line says
/// what the document holds and, in the same breath, the one thing it does not.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/workflow_profile.dart';
import '../keys.dart';

class ProfileBar extends StatelessWidget {
  const ProfileBar({super.key, required this.onExport, required this.onImport});

  /// Writes the document and hands it to the system.
  final VoidCallback onExport;

  /// Asks for one and merges it. Never replaces: what this device has and the
  /// document does not mention survives it (`profile_exchange.dart`).
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Container(
      key: LcKeys.profileBar,
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l.profileTitle, style: text.titleSmall),
          const SizedBox(height: 2),
          Text(
            l.profileNote,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          const SizedBox(height: LcSpace.xxs),
          // Wrapped rather than laid out in a row: these labels are sentences,
          // and a narrow pane must not clip one.
          Wrap(
            spacing: LcSpace.xs,
            children: <Widget>[
              TextButton(
                key: LcKeys.exportProfile,
                onPressed: onExport,
                style: _compact,
                child: Text(l.profileExport),
              ),
              TextButton(
                key: LcKeys.importProfile,
                onPressed: onImport,
                style: _compact,
                child: Text(l.profileImport),
              ),
            ],
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

/// Says why a profile could not be read or handed over, and offers the one
/// thing there is to do about it.
///
/// A dialog rather than a passing line at the bottom of the screen: the
/// refusal that matters most names two version numbers, and a sentence a user
/// has to read before it slides away is not one they will read.
Future<void> showProfileProblem(
  BuildContext context,
  ProfileFailure failure,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    key: LcKeys.profileProblem,
    title: Text(failure.title(L.of(context))),
    content: Text(failure.message(L.of(context))),
    actions: <Widget>[
      FilledButton(
        key: LcKeys.profileProblemDismiss,
        onPressed: () => Navigator.of(context).pop(),
        child: Text(L.of(context).ok),
      ),
    ],
  ),
);
