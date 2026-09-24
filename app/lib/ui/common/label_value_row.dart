/// A label in a column of its own beside its value — or above it, when that
/// column would take the row (T-0159).
///
/// Three rows in this app drew a label in a fixed-dp column and the value in
/// whatever was left: the server block's details, its reconnect-attempts row,
/// and the help sheet's Defaults. None of them can overflow — the column is
/// narrower than any pane — but at a raised text scale the label wraps to a
/// word per line inside its column while the value beside it keeps the rest of
/// the row, which reads badly rather than breaking.
///
/// **The rule.** The column's share of the row is measured at the reader's own
/// text scale: [labelWidth] is the column at scale 1.0, and it grows with the
/// scale because its label does. While that grown column stays within
/// [maxLabelShare] of the row, the row is drawn exactly as it always was — a
/// [labelWidth] column and an `Expanded` value. Past it, the label goes above
/// the value and both get the whole width.
///
/// Nothing is capped: the text scale is the reader's (T-0149's cap was for
/// chips that cannot wrap; these can).
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class LabelValueRow extends StatelessWidget {
  const LabelValueRow({
    super.key,
    required this.label,
    required this.value,
    required this.labelWidth,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  /// The label, already styled.
  final Widget label;
  final Widget value;

  /// The label column's width at a 1.0 text scale — what the row has always
  /// used.
  final double labelWidth;

  final CrossAxisAlignment crossAxisAlignment;

  /// The most of the row the grown label column may take before the label
  /// moves above the value.
  static const double maxLabelShare = 0.45;

  /// Whether a [labelWidth] column, grown to [textScale], still fits beside
  /// its value on a row [rowWidth] wide.
  static bool fitsBeside({
    required double rowWidth,
    required double labelWidth,
    required double textScale,
  }) => labelWidth * textScale <= rowWidth * maxLabelShare;

  @override
  Widget build(BuildContext context) {
    // The scale the reader chose, read the way a paragraph reads it: what a
    // 14dp font becomes, over 14.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (fitsBeside(
          rowWidth: constraints.maxWidth,
          labelWidth: labelWidth,
          textScale: scale,
        )) {
          return Row(
            crossAxisAlignment: crossAxisAlignment,
            children: <Widget>[
              SizedBox(width: labelWidth, child: label),
              Expanded(child: value),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            label,
            const SizedBox(height: LcSpace.xxs / 2),
            value,
          ],
        );
      },
    );
  }
}
