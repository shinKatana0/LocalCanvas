/// Appearance: which of the two brightnesses this device shows.
///
/// It sits in the controls column beside [ProfileBar] for the reason that
/// widget's own docstring gives for being there — it is not about the chosen
/// workflow. A theme is not about the chosen workflow either; it is about the
/// phone. There is no Settings screen to put it in, and building the container
/// before there is more than one thing to put in it would be building for a
/// hypothetical future.
///
/// Three answers and no more (`docs/ui-ux.md`, "Which of the two a person
/// gets"): light, dark, and follow the system. **Follow the system is one of
/// the three rather than the absence of the other two** — a person who chose it
/// deliberately, after trying dark, chose something, and the control has to be
/// able to show them that.
///
/// **Why a `Wrap` of choice chips and not a `SegmentedButton`.** The segmented
/// control was the first thing built here and it was wrong, for a reason that
/// only measurement shows: in this app's `labelLarge` (15dp, w600) the three
/// segments want 433.8dp at the ordinary text size, and the widths this app
/// actually has to draw into are 240–348dp. A segmented button given less than
/// it wants does not shrink gracefully — it wraps every label onto two lines at
/// 240dp and onto six at a 2.0 text scale, and hiding the overflow behind a
/// horizontal scroll (which is what this file did first) left **System** with
/// zero visible pixels at every width but one. The invisible option was the
/// default, and the two-pane layout was the worst case rather than the best.
///
/// A `Wrap` has none of that failure mode: no label ever wraps — a chip label
/// carries `maxLines: 1` and `softWrap: false`, so it cannot — and when a row
/// runs out of width the third chip simply takes the next line. It is also
/// what the rest of this app already does — eight `Wrap`s in `lib/ui/`, one of
/// them in [ProfileBar] immediately below this block, whose comment says the
/// same thing: "a narrow pane must not clip one".
///
/// What a chip *can* still do to a label it has no room for is fade the end of
/// it out (`TextOverflow.fade`) inside a control that is otherwise the right
/// size, which is a word lost without anything looking wrong. That is what the
/// padding below is for, and why the tests measure every label against the
/// width its style needs rather than against the chip that holds it.
///
/// Material 3 has both components for a single choice out of a small set, so
/// this is a change of component and not a departure from the foundation
/// `docs/ui-ux.md` names. Two things the segmented control gave for free are
/// therefore restored by hand: the check mark on the chosen chip
/// ([ChoiceChip.showCheckmark], so selection is not carried by colour alone),
/// and `isInMutuallyExclusiveGroup` in the semantics — put *inside* the label,
/// which is inside the chip's own merge boundary, so it lands on the chip's
/// node rather than on a node above it.
///
/// The sentence under the title says the one thing a person cannot see from the
/// chips: this choice stays on this phone. It is the same courtesy
/// [ProfileBar]'s sentence pays about the file it hands over, and it is true
/// for the same reason — nothing writes the theme into the portable profile.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../keys.dart';

/// How far a choice chip's label follows the phone's text-size setting
/// (T-0142).
///
/// **Measured, and it is a trade this control has to make.** A chip label
/// cannot wrap and a single word cannot be broken, so the only three answers to
/// a label too wide for its chip are: fade the end of it out, shorten the word,
/// or stop scaling it. The first is the defect T-0132 was fixed for twice; the
/// second is not available, because "Системное" and "Системный" are what those
/// two things are called in Russian.
///
/// **The number is empirical and the derivation is the matrix, not arithmetic
/// here.** `theme_choice_test.dart` draws every label of both controls at every
/// width this app uses, at every text scale a phone offers, in every locale,
/// and measures each against what its style needs. Raise this constant and run
/// it: **1.4 passes all thirty; 1.45 fails**, and the failure it prints is
///
///     Expected: a value greater than or equal to <196.14999389648438>
///       Actual: <190.42857142857142>
///     "Системное" is drawn in 190.42857142857142dp of the
///     196.64999389648438dp it needs at 840.0dp/2.0/ru — it is truncated
///
/// Two figures there, and they are not one number rounded twice: **196.65dp**
/// is what the label needs, and **196.15dp** is the matcher's bound, which is
/// that minus the half-pixel of slack the assertion allows. It is drawn in
/// 190.43dp and is short by either. Both are quoted, because quoting one leaves
/// the reader who saw the other thinking this docstring invented a number.
///
/// So 1.4 is the largest step the measurement permits, and on an accessibility
/// cap the largest defensible number is the right one.
///
/// **An earlier version of this comment derived 1.3 as `184 / 135.9`, and that
/// was circular.** The 184dp was the label slot measured on a chip *already
/// drawn under the 1.3 cap*, so it was the slot at 1.3 rather than the slot at
/// the cap being derived — and the slot is not a constant, because the check
/// mark and the padding scale with the label too. Arithmetic from one
/// observation cannot settle this; raising the cap until something breaks can.
///
/// It costs a person at a 2.0 text size six words drawn at 1.4 instead. It buys
/// them all six words, and 1.4 is still well above the default. Everything else
/// on the screen scales without limit.
const double kChoiceChipMaxTextScale = 1.4;

class AppearanceBar extends StatelessWidget {
  const AppearanceBar({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  /// The three, in the order they are offered. Light first because it is the
  /// lighter of the two brightnesses and the list reads as a scale; follow the
  /// system last because it is the one that is not a brightness.
  ///
  /// The labels are looked up rather than written down (T-0142): "Системное"
  /// is half again as long as "System", and this control's whole layout
  /// lesson was learned at the width where "System" only just fitted. What
  /// keeps that lesson honest now is the per-locale layout matrix in
  /// `theme_choice_test.dart`, which walks these very options.
  ///
  /// The Russian three agree with "Оформление", the heading directly above
  /// them, and the language control's three agree with "Язык" for the same
  /// reason. They are not the same ending because those two words are not the
  /// same gender.
  static List<(ThemeMode, String, Key)> optionsIn(L l) =>
      <(ThemeMode, String, Key)>[
        (ThemeMode.light, l.appearanceLight, LcKeys.appearanceLight),
        (ThemeMode.dark, l.appearanceDark, LcKeys.appearanceDark),
        (ThemeMode.system, l.appearanceSystem, LcKeys.appearanceSystem),
      ];

  /// Which of the three is chosen right now.
  final ThemeMode mode;

  /// The user chose another one.
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Container(
      key: LcKeys.appearance,
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l.appearanceTitle, style: text.titleSmall),
          const SizedBox(height: 2),
          Text(
            l.appearanceNote,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          const SizedBox(height: LcSpace.xs),
          // The one place in this app where the phone's text size stops being
          // honoured in full, and only for these labels — see
          // [kChoiceChipMaxTextScale] for the measurement behind the cap.
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: kChoiceChipMaxTextScale,
            child: Wrap(
            spacing: LcSpace.xs,
            runSpacing: LcSpace.xs,
            children: <Widget>[
              for (final (value, label, key) in optionsIn(l))
                ChoiceChip(
                  key: key,
                  selected: value == mode,
                  // Inside the chip's merge boundary on purpose — see the
                  // library comment.
                  label: Semantics(
                    inMutuallyExclusiveGroup: true,
                    child: Text(label),
                  ),
                  labelStyle: text.labelLarge,
                  // Half of Material's default 8dp, and measured rather than
                  // chosen: at the narrowest pane this app has — the two-pane
                  // controls column at 840dp, 240dp inside this block — the
                  // *selected* "System" chip wants 242.6dp at a 2.0 text
                  // scale, because the check mark scales with the text. Two
                  // and a half pixels over, and the chip cuts the one word a
                  // person needs to read to get back to following their
                  // phone: its label carries `maxLines: 1`, `softWrap: false`
                  // and `TextOverflow.fade`, so the end of it simply fades
                  // out. This brings the chip to 234.6dp and leaves the word
                  // whole, with 9dp of air either side of it at the ordinary
                  // scale.
                  //
                  // **This one line is the whole of the fix.** Every other
                  // lever was measured and none of them moves the width: the
                  // chip's `labelPadding` is already `LcSpace.xxs`, so
                  // setting it changes nothing (242.6dp with and without);
                  // its icon theme does nothing; and its visual density and
                  // tap target size do fit, by taking the touch target down
                  // to 40dp and 32dp, which is not a trade this control can
                  // make.
                  padding: const EdgeInsets.all(LcSpace.xxs),
                  backgroundColor: palette.surfaceRaised,
                  selectedColor: palette.accentQuiet,
                  checkmarkColor: palette.textPrimary,
                  side: BorderSide(color: palette.outline),
                  // A choice is never un-chosen. Tapping the chip that is
                  // already on asks for nothing, exactly as the three
                  // exclusive segments behaved.
                  onSelected: (chosen) {
                    if (chosen) onChanged(value);
                  },
                ),
            ],
            ),
          ),
        ],
      ),
    );
  }
}
