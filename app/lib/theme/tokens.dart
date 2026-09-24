/// The whole design system: one file of tokens (`docs/ui-ux.md`).
///
/// Spacing, radii, motion, typography and a palette. Light and dark are two
/// values of the same tokens — nothing else in the app names a raw colour or a
/// raw pixel gap. This is deliberately not a design-system project: there is no
/// component library here, no variant matrix and no token pipeline.
library;

import 'package:flutter/material.dart';

/// Vertical and horizontal rhythm. Whitespace is generous by contract, so the
/// scale starts coarse and has no values below 4.
abstract final class LcSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// ~16–20dp where it matters; smaller radii only on small controls.
abstract final class LcRadius {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 20;
  static const double pill = 999;
}

/// Motion. The intro total ([intro] + [introExit]) is what the user perceives
/// and stays inside the 0.8–1.5s window `docs/ui-ux.md` sets.
abstract final class LcMotion {
  static const Duration intro = Duration(milliseconds: 1150);
  static const Duration introExit = Duration(milliseconds: 280);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 260);
}

/// Layout thresholds. Chosen on available width, never on device identity
/// (`docs/ui-ux.md`): a 700dp window is two panes whether it is a tablet, an
/// unfolded phone or a resized desktop window.
abstract final class LcLayout {
  /// At and above this width the shell shows two panes.
  static const double twoPaneWidth = 600;

  /// A single column never grows past this, so a wide screen does not stretch
  /// a compact layout across itself.
  static const double readableWidth = 560;

  /// The controls pane in the two-pane layout.
  ///
  /// [controlsPaneMin] is two things at once, and they were checked separately
  /// before they were allowed to stay one number:
  ///
  /// * the floor of the app's own **guess**, [defaultControlsShare] of the
  ///   window, which is what it has always been — unchanged by T-0176, so a
  ///   person who never drags gets the layout they always got, to the pixel;
  /// * the floor a person may **drag** to. That one was measured for T-0176
  ///   rather than assumed. Sweeping this pane a pixel at a time in both
  ///   locales at 1.0, 1.3 and 2.0, the narrowest width at which everything
  ///   the app itself writes into this column still reads whole is **319** —
  ///   bound by the *System* chips of the Appearance and Language blocks, in
  ///   **Russian at a 2.0 text scale**, which cannot wrap. So 320 clears the
  ///   floor by **one pixel**, and is kept for that reason rather than for
  ///   comfort.
  ///
  ///   Where the rest of the grid falls, so that the binding row is visibly
  ///   the binding one: the chips are cut at 318 and whole at 319 in Russian
  ///   at 2.0; cut at 305 and whole at 306 in Russian at 1.3; `5 settings` is
  ///   cut at 299 and whole at 300 in English at 2.0; and at 1.0 in either
  ///   language, and English at 1.3, nothing is cut anywhere down to 278.
  ///   Reading only the 1.3 row gives 310 and is wrong — at 2.0 the chips are
  ///   still cut at 310 and at 318.
  ///
  ///   **One pixel is not margin**, and the number is kept rather than raised
  ///   only because raising it would move the default on every window from
  ///   600dp to 888dp, which is where the clamp binds and where an unfolded
  ///   foldable sits at 841dp. Anything that makes these blocks wider — a longer
  ///   word in a third locale, a chip that grows by a pixel — lands on the
  ///   wrong side of it, and this comment is the warning that it will.
  ///
  /// **What the measurement also found, and what this number cannot fix.** At
  /// a 2.0 text scale the chosen workflow's block gives its name and summary
  /// whatever is left of the pane after a fixed 296dp, so they are cut at 320
  /// and are still only 34dp wide at 330 and 104dp at 400; the block needs
  /// 420dp — the widest this app's own default ever makes this pane — before
  /// they get a real share. That is a defect in the block and not a pane width
  /// (T-0188), it is reachable today on any window from 600dp to 900dp
  /// without anybody dragging anything, and no floor this card could set would
  /// repair it.
  ///
  /// [controlsPaneMax] caps the guess only: the app declining to give the
  /// controls more of a large screen than it has any reason to. A dragged pane
  /// is not held to it — on a tablet the guess is already sitting on it, so a
  /// ceiling there would let a person widen the picture and never the
  /// controls, which is half of what was asked for.
  ///
  /// **Every dp above is the widget-test toolkit's fixed-advance font** —
  /// 15.09dp per character, Latin and Cyrillic alike (T-0150) — and not the
  /// shipped face. What was measured is where a layout stops holding, at
  /// whatever size that font produces; against a real proportional face, which
  /// is narrower, the figures are conservative.
  static const double controlsPaneMin = 320;
  static const double controlsPaneMax = 420;

  /// The share of the window the controls pane takes when nobody has dragged
  /// it. The constant that used to sit inline in `connected_shell.dart`.
  static const double defaultControlsShare = 0.36;

  /// The narrowest a person may leave the creation area by dragging.
  ///
  /// The other half of "neither pane can be dragged into uselessness". The
  /// controls side already had a floor to reuse — [controlsPaneMin] — and this
  /// side had none, because until the divider could be moved nothing could
  /// make the creation area narrow.
  ///
  /// **Not a cliff found by sweeping, and the honest reason is that there is
  /// no cliff to find.** Swept from 200dp upwards in both locales at 1.0, 1.3
  /// and 2.0, idle and with a generation running, the creation area drew
  /// cleanly at every width tried — it holds one centred column and gives way
  /// gracefully. So this is not "where it breaks" but a promise made on other
  /// grounds: the creation area is never narrower than the **whole of the
  /// narrowest phone this project draws it on**, the single-column layout at
  /// 320dp that `advanced_header_test` and `row_yield_test` already sweep. A
  /// picture given less room than a small phone gives it is not something this
  /// app should offer, however gracefully it would cope.
  static const double draggedCreationMin = 320;

  /// How wide the invisible grab area over the divider is.
  ///
  /// The divider itself stays one pixel — it is a hairline by contract — and
  /// this is laid over it rather than taking room in the row, so that turning
  /// the handle on moved nothing on screen. A one-pixel target is unusable
  /// with a thumb; half of this reaches into the controls pane's own 24dp of
  /// padding, where there is nothing to press.
  static const double splitHandleTouchWidth = 24;

  /// How far one press of an arrow key, or one accessibility *increase*, moves
  /// the split. Coarse enough to be worth pressing, fine enough to land where
  /// the person means.
  static const double splitHandleStep = 16;
}

/// The semantic colours. Every colour the app draws comes from one of these
/// fields; there are two instances and no third.
@immutable
class LcPalette {
  const LcPalette({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.outline,
    required this.accent,
    required this.onAccent,
    required this.accentQuiet,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.success,
    required this.warning,
    required this.danger,
    required this.onDanger,
  });

  final Brightness brightness;

  /// The furthest-back surface: the window itself.
  final Color canvas;

  /// Cards and sheets sitting on the canvas.
  final Color surface;

  /// A surface that needs to read as lifted from [surface].
  final Color surfaceRaised;

  /// Hairlines. Borders are minimal by contract; this is a whisper, not a rule.
  final Color outline;

  /// The one accent. Action and state only — never decoration.
  final Color accent;
  final Color onAccent;

  /// The accent at container strength, for a tinted background behind it.
  final Color accentQuiet;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  final Color success;
  final Color warning;
  final Color danger;
  final Color onDanger;

  /// Dark first. Graphite neutrals, one soft indigo accent.
  static const LcPalette dark = LcPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF0E0F12),
    surface: Color(0xFF16181D),
    surfaceRaised: Color(0xFF1F222A),
    outline: Color(0xFF2C313B),
    accent: Color(0xFF8FA5F7),
    onAccent: Color(0xFF10132A),
    accentQuiet: Color(0xFF1C2136),
    textPrimary: Color(0xFFF2F3F6),
    textSecondary: Color(0xFFA9B0BE),
    textMuted: Color(0xFF8891A0),
    success: Color(0xFF6FC79B),
    warning: Color(0xFFE0B05C),
    danger: Color(0xFFEE8B84),
    onDanger: Color(0xFF2A100E),
  );

  /// The same tokens in daylight. Not an afterthought: every field is picked
  /// for this brightness, not lightened from the dark one.
  static const LcPalette light = LcPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    outline: Color(0xFFDBDEE5),
    accent: Color(0xFF3A4FBF),
    onAccent: Color(0xFFFFFFFF),
    accentQuiet: Color(0xFFE7EAFB),
    textPrimary: Color(0xFF14161B),
    textSecondary: Color(0xFF4C5361),
    textMuted: Color(0xFF666D7A),
    success: Color(0xFF1B6E48),
    warning: Color(0xFF7D5203),
    danger: Color(0xFFA92E26),
    onDanger: Color(0xFFFFFFFF),
  );
}
