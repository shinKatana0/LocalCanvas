/// One token set, two complete themes (`docs/ui-ux.md`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/tokens.dart';

import 'support/l10n.dart';

/// WCAG contrast ratio. Small text needs 4.5:1, large text and non-text 3:1.
double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Every colour token, by name. A pair that is equal across the two palettes
/// is a light value someone forgot to pick.
Map<String, Color> tokensOf(LcPalette p) => <String, Color>{
  'canvas': p.canvas,
  'surface': p.surface,
  'surfaceRaised': p.surfaceRaised,
  'outline': p.outline,
  'accent': p.accent,
  'onAccent': p.onAccent,
  'accentQuiet': p.accentQuiet,
  'textPrimary': p.textPrimary,
  'textSecondary': p.textSecondary,
  'textMuted': p.textMuted,
  'success': p.success,
  'warning': p.warning,
  'danger': p.danger,
  'onDanger': p.onDanger,
};

void main() {
  test('the light theme is picked, not inherited from the dark one', () {
    final dark = tokensOf(LcPalette.dark);
    final light = tokensOf(LcPalette.light);

    expect(light.keys, dark.keys);
    for (final name in dark.keys) {
      expect(
        light[name],
        isNot(dark[name]),
        reason: '$name has the same value in both themes',
      );
    }
  });

  for (final entry in <String, LcPalette>{
    'dark': LcPalette.dark,
    'light': LcPalette.light,
  }.entries) {
    final name = entry.key;
    final p = entry.value;

    group('the $name theme', () {
      test('reads: body text on every surface it sits on', () {
        for (final surface in <Color>[p.canvas, p.surface, p.surfaceRaised]) {
          expect(contrast(p.textPrimary, surface), greaterThanOrEqualTo(4.5));
          expect(contrast(p.textSecondary, surface), greaterThanOrEqualTo(4.5));
          expect(contrast(p.textMuted, surface), greaterThanOrEqualTo(4.5));
        }
      });

      test('reads: the accent, and what is written on it', () {
        expect(contrast(p.accent, p.canvas), greaterThanOrEqualTo(3));
        expect(contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));
      });

      test('reads: the state colours', () {
        for (final tone in <Color>[p.success, p.warning, p.danger]) {
          expect(contrast(tone, p.surface), greaterThanOrEqualTo(3));
        }
        expect(contrast(p.onDanger, p.danger), greaterThanOrEqualTo(4.5));
      });

      test('one accent, used for action and state — not several', () {
        // Semantic tones are allowed to differ from the accent; what is not
        // allowed is a second brand colour pretending to be one.
        expect(p.accent, isNot(p.success));
        expect(p.accent, isNot(p.warning));
        expect(p.accent, isNot(p.danger));
      });
    });
  }

  test('both ThemeData objects are built from the same tokens', () {
    final pairs = <ThemeData, LcPalette>{
      lcDarkTheme(): LcPalette.dark,
      lcLightTheme(): LcPalette.light,
    };
    pairs.forEach((theme, palette) {
      expect(theme.brightness, palette.brightness);
      expect(theme.colorScheme.primary, palette.accent);
      expect(theme.colorScheme.onPrimary, palette.onAccent);
      expect(theme.colorScheme.surface, palette.surface);
      expect(theme.colorScheme.onSurface, palette.textPrimary);
      expect(theme.colorScheme.error, palette.danger);
      expect(theme.colorScheme.outline, palette.outline);
      expect(theme.scaffoldBackgroundColor, palette.canvas);
      expect(theme.extension<LcTheme>()?.palette, palette);
      expect(theme.useMaterial3, isTrue);
    });
  });

  testWidgets('the palette reaches a widget through the theme', (tester) async {
    late LcPalette seen;
    await tester.pumpWidget(
      MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
        theme: lcDarkTheme(),
        home: Builder(
          builder: (context) {
            seen = context.palette;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen, LcPalette.dark);
  });

  test('the layout thresholds are ordered so a pane can never be wider than '
      'the window that holds it', () {
    expect(LcLayout.controlsPaneMin, lessThan(LcLayout.controlsPaneMax));
    expect(LcLayout.controlsPaneMax, lessThan(LcLayout.twoPaneWidth));
  });

  /// The border a button actually draws, read off the [Material] the button
  /// builds rather than off the style it was handed -- a `side` the framework
  /// resolved but never applied would pass the second check and fail the user.
  BorderSide drawnBorder(WidgetTester tester) {
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Material),
          )
          .first,
    );
    return (material.shape! as RoundedRectangleBorder).side;
  }

  Future<void> pumpButton(
    WidgetTester tester,
    ThemeData theme, {
    required bool enabled,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: theme,
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: enabled ? () {} : null,
            child: const Text('Generate'),
          ),
        ),
      ),
    ),
  );

  group('a disabled filled button is findable on its own background', () {
    // T-0018. `light.surfaceRaised` is white on a near-white canvas, and the
    // app follows the system theme, so a disabled Generate is the first thing
    // a light-mode user sees. Either the fill separates it from the canvas or
    // a border does -- one of the two, in both themes.
    for (final (name, theme, palette) in <(String, ThemeData, LcPalette)>[
      ('light', lcLightTheme(), LcPalette.light),
      ('dark', lcDarkTheme(), LcPalette.dark),
    ]) {
      testWidgets(name, (tester) async {
        await pumpButton(tester, theme, enabled: false);
        final border = drawnBorder(tester);

        final style = theme.filledButtonTheme.style!;
        final fill = style.backgroundColor!.resolve(
          <WidgetState>{WidgetState.disabled},
        )!;

        // The bar is the app's own hairline, not a number invented here: a
        // surface this design separates from the canvas is separated at least
        // as much as `outline` is, which is exactly how the workflow card and
        // the text fields already read.
        final hairline = contrast(palette.outline, palette.canvas);
        final fillSeparates = contrast(fill, palette.canvas) >= hairline;
        final borderSeparates =
            border.style == BorderStyle.solid &&
            border.width > 0 &&
            contrast(border.color, palette.canvas) >= hairline;

        expect(
          fillSeparates || borderSeparates,
          isTrue,
          reason:
              'in the $name theme a disabled filled button is a '
              '${fill.toARGB32().toRadixString(16)} shape on a '
              '${palette.canvas.toARGB32().toRadixString(16)} canvas, and '
              'neither its fill nor its edge reaches the hairline every other '
              'surface on that screen is drawn with',
        );
      });
    }

    testWidgets('and an enabled one is not outlined', (tester) async {
      await pumpButton(tester, lcLightTheme(), enabled: true);
      // The accent button carries its own weight; a border on it would be
      // decoration, which the contract does not allow.
      expect(drawnBorder(tester).style, BorderStyle.none);
    });
  });
}
