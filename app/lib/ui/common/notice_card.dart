/// A connection problem, rendered in the words the user reads.
///
/// Every expected error state names what happened and what can be done about
/// it (`docs/ui-ux.md`). There is no raw exception text and no status code to
/// show here because [ConnectionNotice] never carries any.
library;

import 'package:flutter/material.dart';

import '../../connection/connection_problem.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';

class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.notice, this.actions = const []});

  final ConnectionNotice notice;

  /// The decisions available. A bounded failure always ends with at least one.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final tone = switch (notice.problem) {
      ConnectionProblem.comfyUnavailable => palette.warning,
      _ => palette.danger,
    };

    return Container(
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: tone.withValues(alpha: 0.34)),
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
                  notice.isConnected
                      ? Icons.pause_circle_outline
                      : Icons.error_outline,
                  size: 20,
                  color: tone,
                ),
              ),
              const SizedBox(width: LcSpace.sm),
              Expanded(
                child: Text(notice.title(l), style: text.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: LcSpace.xs),
          Padding(
            padding: const EdgeInsets.only(left: 20 + LcSpace.sm),
            child: Text(
              notice.message(l),
              style: text.bodySmall?.copyWith(color: palette.textSecondary),
            ),
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: LcSpace.sm),
            Padding(
              padding: const EdgeInsets.only(left: 20 + LcSpace.sm - LcSpace.md),
              child: Wrap(
                spacing: LcSpace.xs,
                runSpacing: LcSpace.xxs,
                children: actions,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
