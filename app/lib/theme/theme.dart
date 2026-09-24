/// Material 3 wired to the tokens in `tokens.dart`.
///
/// Material 3 is the accessibility and component foundation — semantics,
/// contrast, touch targets, text scaling. The look on top of it is built here,
/// and both brightnesses are produced by the same function from the same
/// token set, so a colour can never exist in one theme and be missing from the
/// other.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Carries the semantic palette through the widget tree so a widget can reach
/// a token Material's [ColorScheme] has no slot for (`textMuted`, `canvas`).
@immutable
class LcTheme extends ThemeExtension<LcTheme> {
  const LcTheme(this.palette);

  final LcPalette palette;

  @override
  LcTheme copyWith({LcPalette? palette}) => LcTheme(palette ?? this.palette);

  /// The palette is a discrete pair, not a continuum: half-way between the
  /// dark and the light theme is not a theme this app has. Snapping keeps
  /// an animated theme change legible instead of muddy.
  @override
  LcTheme lerp(covariant LcTheme? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

extension LcThemeAccess on BuildContext {
  /// The semantic palette for the current theme.
  LcPalette get palette => Theme.of(this).extension<LcTheme>()!.palette;
}

/// The dark theme. This is the one the product is designed in.
ThemeData lcDarkTheme() => _themeFrom(LcPalette.dark);

/// The light theme, complete rather than derived at runtime.
ThemeData lcLightTheme() => _themeFrom(LcPalette.light);

ThemeData _themeFrom(LcPalette p) {
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentQuiet,
    onPrimaryContainer: p.textPrimary,
    secondary: p.accent,
    onSecondary: p.onAccent,
    secondaryContainer: p.accentQuiet,
    onSecondaryContainer: p.textPrimary,
    tertiary: p.success,
    onTertiary: p.onAccent,
    tertiaryContainer: p.surfaceRaised,
    onTertiaryContainer: p.textPrimary,
    error: p.danger,
    onError: p.onDanger,
    errorContainer: p.surfaceRaised,
    onErrorContainer: p.danger,
    surface: p.surface,
    onSurface: p.textPrimary,
    surfaceContainerLowest: p.canvas,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceRaised,
    surfaceContainerHighest: p.surfaceRaised,
    onSurfaceVariant: p.textSecondary,
    outline: p.outline,
    outlineVariant: p.outline,
    inverseSurface: p.textPrimary,
    onInverseSurface: p.canvas,
    inversePrimary: p.accentQuiet,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    surfaceTint: p.accent,
  );

  final text = _textTheme(p);

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    textTheme: text,
    extensions: <ThemeExtension<dynamic>>[LcTheme(p)],
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: p.outline, space: 1, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: p.canvas,
      foregroundColor: p.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleMedium,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LcRadius.lg),
        side: BorderSide(color: p.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.surfaceRaised,
        disabledForegroundColor: p.textMuted,
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: LcSpace.lg),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LcRadius.md),
        ),
      ).copyWith(
        // A disabled filled button carries a hairline; an enabled one does
        // not (T-0018). In the light theme `surfaceRaised` is white on a
        // near-white canvas, so the disabled fill alone leaves the control
        // findable only by its grey label -- and because the app follows the
        // system theme, that is the first thing a light-mode user sees, since
        // Generate is disabled until the form is filled in.
        //
        // The border goes on the one control that is wrong rather than on the
        // token: changing `surfaceRaised` would silently move every other
        // raised surface in the app. It also makes the button read the way
        // every other white surface on that screen already reads -- the
        // workflow card and the text fields carry this same hairline.
        side: WidgetStateProperty.resolveWith<BorderSide?>(
          (states) => states.contains(WidgetState.disabled)
              ? BorderSide(color: p.outline)
              : null,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: LcSpace.md),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LcRadius.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.textPrimary,
        side: BorderSide(color: p.outline),
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: LcSpace.lg),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LcRadius.md),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceRaised,
      hintStyle: text.bodyMedium?.copyWith(color: p.textMuted),
      labelStyle: text.labelMedium?.copyWith(color: p.textSecondary),
      errorStyle: text.bodySmall?.copyWith(color: p.danger),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LcSpace.md,
        vertical: LcSpace.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
        borderSide: BorderSide(color: p.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
        borderSide: BorderSide(color: p.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
        borderSide: BorderSide(color: p.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
        borderSide: BorderSide(color: p.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
        borderSide: BorderSide(color: p.danger, width: 2),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(LcRadius.lg)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.outline,
      circularTrackColor: p.outline,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.textSecondary,
      textColor: p.textPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surfaceRaised,
      contentTextStyle: text.bodyMedium,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LcRadius.md),
      ),
    ),
  );
}

/// Hierarchy carried by size and weight rather than by rules and boxes.
TextTheme _textTheme(LcPalette p) => TextTheme(
  displaySmall: TextStyle(
    fontSize: 34,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.8,
    color: p.textPrimary,
  ),
  headlineSmall: TextStyle(
    fontSize: 26,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    color: p.textPrimary,
  ),
  titleLarge: TextStyle(
    fontSize: 21,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: p.textPrimary,
  ),
  titleMedium: TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: p.textPrimary,
  ),
  titleSmall: TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: p.textPrimary,
  ),
  bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: p.textPrimary),
  bodyMedium: TextStyle(fontSize: 15, height: 1.5, color: p.textSecondary),
  bodySmall: TextStyle(fontSize: 13, height: 1.45, color: p.textSecondary),
  labelLarge: TextStyle(
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    color: p.textPrimary,
  ),
  labelMedium: TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: p.textSecondary,
  ),
  labelSmall: TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: p.textMuted,
  ),
);
