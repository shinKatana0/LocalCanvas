/// What the intro dissolves into when connection work is still in flight.
///
/// Deliberately the same composition as the intro's last frame — mark, then
/// wordmark, centred — so the crossfade reads as one continuous moment rather
/// than as a screen change. The only additions are the line that says what is
/// happening and a bounded indeterminate bar.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../common/brand.dart';

class ConnectingView extends StatelessWidget {
  const ConnectingView({super.key, this.serverName});

  /// The remembered server's own name, when there is one to name.
  final String? serverName;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: palette.canvas,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CanvasMark(size: 84),
            const SizedBox(height: LcSpace.lg),
            const Wordmark(),
            const SizedBox(height: LcSpace.xl),
            SizedBox(
              width: 132,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(LcRadius.pill),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: palette.outline,
                  color: palette.accent,
                ),
              ),
            ),
            const SizedBox(height: LcSpace.md),
            Text(
              serverName == null
                  ? L.of(context).connecting
                  : L.of(context).connectingTo(serverName!),
              style: text.bodyMedium?.copyWith(color: palette.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
