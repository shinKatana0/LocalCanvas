/// Language: which of the shipped locales this device shows.
///
/// It sits immediately beside [AppearanceBar] for the reason that widget's own
/// docstring gives for being where it is — it is not about the chosen
/// workflow. A language is not about the chosen workflow either; it is about
/// the phone the eyes are in front of. There is still no Settings screen to
/// put either in, and building the container before there is more than a
/// screenful to put in it would be building for a hypothetical future.
///
/// **Follow the phone is one of the answers rather than the absence of the
/// others**, exactly as it is for the theme: a person who deliberately chose
/// it, after trying English, chose something, and the control has to be able
/// to show them that.
///
/// **The languages name themselves.** English is offered as *English* and
/// Russian as *Русский* in both locales, because the person most in need of
/// this control is the one who cannot read the interface they are looking at,
/// and "Russian" is no help to them. Only *System* is translated, because it
/// is a sentence about the phone rather than the name of a language.
///
/// **Nothing here counts to two.** The chips come from
/// [kSupportedLocales], which the generator builds from the `.arb` files in
/// `lib/l10n/`, and their keys are computed from the language tag. A third
/// locale is a third file and a third row in the layout matrix; not a line in
/// this widget.
///
/// **The layout is [AppearanceBar]'s, deliberately, down to the padding.**
/// That card spent three rounds learning that a `SegmentedButton` does not fit
/// the 240dp two-pane controls column and that a `Wrap` of `ChoiceChip`s does,
/// and that a chip given less room than its label needs fades the end of the
/// label out inside a control that still looks the right size. Every one of
/// those findings applies here word for word, and the words in this control
/// are longer than the ones in that one.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/app_locales.dart';
import '../../l10n/locale_store.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../keys.dart';
import 'appearance_bar.dart';

class LanguageBar extends StatelessWidget {
  const LanguageBar({
    super.key,
    required this.choice,
    required this.onChanged,
  });

  /// The answers, in the order they are offered: every shipped locale under
  /// its own name, then "follow the phone" last — the one that is not a
  /// language, in the position [AppearanceBar] puts its own such answer.
  static List<(LocaleChoice, String, Key)> optionsIn(L l) =>
      <(LocaleChoice, String, Key)>[
        for (final locale in kSupportedLocales)
          (
            LocaleChoice.of(locale),
            localeAutonym(locale),
            LcKeys.languageOption(locale.languageCode),
          ),
        (LocaleChoice.system, l.languageSystem, LcKeys.languageSystem),
      ];

  /// Which answer is chosen right now. [LocaleChoice.unset] — a device that has
  /// said nothing — draws the same chip as [LocaleChoice.system], because that
  /// is exactly what such a device is doing.
  final LocaleChoice choice;

  /// The user chose another one.
  final ValueChanged<LocaleChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    // A device that has said nothing is following its phone, and the chip that
    // says so is the one to light up. Anything else would leave a first run
    // with three chips and none of them on.
    final selected = choice.isSet ? choice : LocaleChoice.system;
    return Container(
      key: LcKeys.language,
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l.languageTitle, style: text.titleSmall),
          const SizedBox(height: 2),
          Text(
            l.languageNote,
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
                  selected: value == selected,
                  // Inside the chip's merge boundary on purpose, so the
                  // "one of a set" flag lands on the chip's own semantics node
                  // rather than on one above it — `AppearanceBar` learned this
                  // and the reason is written there.
                  label: Semantics(
                    inMutuallyExclusiveGroup: true,
                    child: Text(label),
                  ),
                  labelStyle: text.labelLarge,
                  // Half of Material's default, and taken from
                  // `AppearanceBar` rather than chosen again: that value was
                  // measured against the narrowest pane this app draws, and
                  // the labels here are longer than the ones it was measured
                  // with.
                  padding: const EdgeInsets.all(LcSpace.xxs),
                  backgroundColor: palette.surfaceRaised,
                  selectedColor: palette.accentQuiet,
                  checkmarkColor: palette.textPrimary,
                  side: BorderSide(color: palette.outline),
                  // A choice is never un-chosen. Tapping the chip that is
                  // already on asks for nothing.
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
