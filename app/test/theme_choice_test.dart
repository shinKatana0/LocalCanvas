/// Which of the two brightnesses a person gets, and who decides
/// (`docs/ui-ux.md`, "Which of the two a person gets").
///
/// **Nothing here touches `SharedPreferences`.** The theme store is a fake and
/// is handed in, because composition happens in `main.dart` and only there —
/// which is the whole reason the app can be run end to end in a test at all.
/// The assertions are made on the resolved `MaterialApp.themeMode` and on the
/// theme the app is actually painted in, never on how it "looks".
library;

import 'support/l10n.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/app.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/l10n/locale_store.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/theme_mode_controller.dart';
import 'package:localcanvas/theme/theme_mode_store.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/l10n/app_localizations.dart';
import 'package:localcanvas/ui/shell/appearance_bar.dart';
import 'package:localcanvas/ui/shell/language_bar.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/ui/shell/profile_bar.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;

  RememberedServer remembered() => RememberedServer(
    endpoint: endpoint,
    displayName: 'Studio PC',
    lastSuccess: DateTime.utc(2026),
  );

  /// A registry with real workflows in it, over a script rather than a socket
  /// and with no store of any kind behind it.
  WorkflowsController registryOfDetails(List<Map<String, Object?>> details) {
    final controller = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(registryOf(details)),
        details: <String, WorkflowDetail>{
          for (final body in details)
            body['id']! as String: WorkflowDetail.tryFromJson(body)!,
        },
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// The whole app, over fakes, on a device that already knows its server —
  /// so it settles into the connected shell.
  Future<ThemeModeController> launch(
    WidgetTester tester, {
    required ThemeModeStore store,
    WorkflowsController? workflows,
    GatewayClient? client,
    bool settle = true,
    LocaleChoice language = LocaleChoice.unset,
  }) async {
    final connection = ConnectionController(
      client:
          client ??
          ScriptedGatewayClient((e) => HandshakeSucceeded(e, testIdentity())),
      store: InMemoryEndpointStore(remembered()),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    final appearance = ThemeModeController(store: store);
    addTearDown(appearance.dispose);
    final locale = testLanguage(language);
    addTearDown(locale.dispose);

    await tester.pumpWidget(
      LocalCanvasApp(
        appearance: appearance,
        language: locale,
        session: testSession(
          connection: connection,
          workflows: workflows ?? emptyRegistry(),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
    return appearance;
  }

  /// What the app hands `MaterialApp`, read back off the widget itself.
  ThemeMode themeModeOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  /// The theme the app is actually painted in, resolved below `MaterialApp`
  /// where every screen reads it. Settle before asking: a theme change is
  /// animated, and half-way through one is not an answer.
  ThemeData paintedTheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(RootView)));

  /// A tall, narrow window: the controls column is long once a workflow is
  /// chosen, and everything in it has to be on screen to be tapped.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> chooseAppearance(WidgetTester tester, Key option) async {
    await tester.ensureVisible(find.byKey(option));
    await tester.tap(find.byKey(option));
    await tester.pumpAndSettle();
  }

  group('what the app comes up as', () {
    testWidgets('a device that has said nothing follows the system',
        (tester) async {
      final store = InMemoryThemeModeStore();
      final appearance = await launch(tester, store: store);

      expect(themeModeOf(tester), ThemeMode.system);
      expect(appearance.mode, ThemeMode.system);
      // And it did ask. Otherwise this test would pass on a build that never
      // reads the store at all, which is the same build the next three catch.
      expect(store.reads, 1);
      expect(store.written, isEmpty);
    });

    testWidgets('a relaunch over a stored dark comes up dark', (tester) async {
      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.dark));

      expect(themeModeOf(tester), ThemeMode.dark);
    });

    testWidgets('a relaunch over a stored light comes up light',
        (tester) async {
      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.light));

      expect(themeModeOf(tester), ThemeMode.light);
    });

    testWidgets('a relaunch over a stored system comes up system, having read '
        'it rather than assumed it', (tester) async {
      // `system` is also the starting value, so the mode alone cannot tell
      // this apart from a build that never read anything. The read is what is
      // asserted, and the value with it.
      final store = InMemoryThemeModeStore(ThemeMode.system);
      final appearance = await launch(tester, store: store);

      expect(store.reads, 1);
      expect(appearance.restored, isTrue);
      expect(themeModeOf(tester), ThemeMode.system);
    });

    testWidgets('a store that will not answer leaves the app in system, and '
        'the app still starts', (tester) async {
      // A phone with cleared app data, a preference file that will not open,
      // a platform channel that refuses.
      tallView(tester);
      final store = InMemoryThemeModeStore(ThemeMode.dark)
        ..loadFailure = StateError('preferences unavailable');
      final appearance = await launch(tester, store: store);

      expect(tester.takeException(), isNull);
      expect(themeModeOf(tester), ThemeMode.system);
      expect(appearance.restored, isTrue);
      // Started, not merely un-crashed: the cover is gone and the shell is
      // underneath it.
      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
    });
  });

  group('choosing', () {
    testWidgets('light', (tester) async {
      tallView(tester);
      final store = InMemoryThemeModeStore();
      await launch(tester, store: store);

      await chooseAppearance(tester, LcKeys.appearanceLight);

      expect(themeModeOf(tester), ThemeMode.light);
      expect(store.written, <ThemeMode>[ThemeMode.light]);
      expect(store.stored, ThemeMode.light);
    });

    testWidgets('dark', (tester) async {
      tallView(tester);
      final store = InMemoryThemeModeStore();
      await launch(tester, store: store);

      await chooseAppearance(tester, LcKeys.appearanceDark);

      expect(themeModeOf(tester), ThemeMode.dark);
      expect(store.written, <ThemeMode>[ThemeMode.dark]);
      expect(store.stored, ThemeMode.dark);
    });

    testWidgets('system, from somewhere else', (tester) async {
      tallView(tester);
      // Starting from dark, so that landing on system is a change this test
      // caused rather than the value it started with.
      final store = InMemoryThemeModeStore(ThemeMode.dark);
      await launch(tester, store: store);
      expect(themeModeOf(tester), ThemeMode.dark);

      await chooseAppearance(tester, LcKeys.appearanceSystem);

      expect(themeModeOf(tester), ThemeMode.system);
      // Written down, not erased: a person who deliberately chose to follow
      // the system chose something, and it has to survive the same way the
      // other two do.
      expect(store.written, <ThemeMode>[ThemeMode.system]);
      expect(store.stored, ThemeMode.system);
    });

    testWidgets('what was chosen is what comes back on the next launch',
        (tester) async {
      tallView(tester);
      final store = InMemoryThemeModeStore();
      await launch(tester, store: store);
      await chooseAppearance(tester, LcKeys.appearanceDark);

      // The app again, over the same device: new controllers, same store.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await launch(tester, store: store);

      expect(themeModeOf(tester), ThemeMode.dark);
      expect(store.reads, 2);
    });

    testWidgets('a write that fails costs the next launch and not this one',
        (tester) async {
      tallView(tester);
      final store = InMemoryThemeModeStore()
        ..saveFailure = StateError('preferences unavailable');
      await launch(tester, store: store);

      await chooseAppearance(tester, LcKeys.appearanceDark);

      expect(tester.takeException(), isNull);
      expect(themeModeOf(tester), ThemeMode.dark);
    });
  });

  group('what system means', () {
    testWidgets('it is the platform brightness, both ways round',
        (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.system));
      expect(themeModeOf(tester), ThemeMode.system);
      expect(paintedTheme(tester).brightness, Brightness.dark);
      expect(
        paintedTheme(tester).extension<LcTheme>()!.palette,
        LcPalette.dark,
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(themeModeOf(tester), ThemeMode.system);
      expect(paintedTheme(tester).brightness, Brightness.light);
      expect(
        paintedTheme(tester).extension<LcTheme>()!.palette,
        LcPalette.light,
      );
    });

    testWidgets('a choice outranks the platform', (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;

      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.dark));

      expect(themeModeOf(tester), ThemeMode.dark);
      expect(paintedTheme(tester).brightness, Brightness.dark);
    });
  });

  group('the first frame', () {
    /// One frame's worth of slack, three of which is how far past each stage
    /// of the intro the pumps below land.
    const Duration margin = Duration(milliseconds: 20);

    /// Where the pumps below leave the clock: past the animation *and* past
    /// its fade-out, so an app that did not wait for the stored brightness is
    /// fully on screen by now — but before the grace runs out, so this one is
    /// still covered. The whole first-frame mechanism lives in that gap.
    final Duration pastTheIntro =
        LcMotion.intro + LcMotion.introExit + margin * 3;

    /// Pumped in stages rather than in one jump, and this is not a style
    /// choice: a single `pump` of the whole duration advances the clock once
    /// and rebuilds once, which is not enough for `AnimatedSwitcher` to both
    /// be told the intro finished *and* run its exit. A test that jumped
    /// would find the intro still on screen for a frame-scheduling reason and
    /// call it proof of the cover — which is exactly what it did, until the
    /// mutant that removes the waiting survived and said so.
    Future<void> pumpPastTheIntro(WidgetTester tester) async {
      await tester.pump(LcMotion.intro + margin);
      await tester.pump(LcMotion.introExit + margin);
      await tester.pump(margin);
    }

    testWidgets('the app is never revealed in the brightness it is about to '
        'stop being', (tester) async {
      // The mechanism, stated as a test rather than as a duration: the intro
      // is a cover that is already there, and it does not lift until the
      // stored answer has arrived. The store here never answers until this
      // test lets it, so the window can be looked at instead of raced.
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;

      final store = PendingThemeModeStore();
      await launch(tester, store: store, settle: false);
      await tester.pump();

      // The premise this test rests on, asserted rather than assumed: the
      // moment being pumped to is genuinely past the whole intro, and
      // genuinely before the grace runs out. If either stopped being true the
      // test below would be measuring nothing.
      expect(pastTheIntro, greaterThan(LcMotion.intro + LcMotion.introExit));
      expect(pastTheIntro, lessThan(LcMotion.intro + kBrightnessGrace));

      await pumpPastTheIntro(tester);

      // An un-gated build is fully revealed by now. This one is not.
      expect(find.byKey(LcKeys.intro), findsOneWidget);
      expect(themeModeOf(tester), ThemeMode.system);
      // And nothing was gated *on* it: the connection ran to completion under
      // the cover, which is what `docs/ui-ux.md` requires of anything painted
      // over this app.
      expect(store.reads, 1);

      store.completer.complete(ThemeMode.dark);
      await tester.pumpAndSettle();

      // Only now is the app on screen, and it is already dark.
      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(themeModeOf(tester), ThemeMode.dark);
      expect(paintedTheme(tester).brightness, Brightness.dark);
    });

    test('the grace is bounded at both ends', () {
      // The floor is what the two tests around this one rest on: below
      // `introExit` the deadline lands inside the cover's own fade-out, where
      // a bounded build and an unbounded one draw the same picture and no test
      // can tell them apart.
      expect(kBrightnessGrace, greaterThan(LcMotion.introExit));

      // The ceiling is a sentence `app.dart` already writes down — that the
      // pathological case ends in under two seconds. That is a claim about the
      // whole cover rather than about the grace on its own, so it is asserted
      // about the whole cover; a grace of a minute satisfies neither.
      expect(kBrightnessGrace, lessThan(const Duration(seconds: 2)));
      expect(
        LcMotion.intro + kBrightnessGrace + LcMotion.introExit,
        lessThan(const Duration(seconds: 2)),
      );
    });

    testWidgets('a read that never answers still ends in the contracted '
        'state, not in a splash with no end', (tester) async {
      // The bound. `docs/ui-ux.md` opens its startup section with the things
      // that must never happen, and a splash that does not end is the first of
      // them. Before this bound existed the intro here stayed up forever.
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;

      final store = PendingThemeModeStore();
      final client = PendingGatewayClient();
      await launch(tester, store: store, client: client, settle: false);
      await tester.pump();

      // Still covered inside the grace…
      await pumpPastTheIntro(tester);
      expect(find.byKey(LcKeys.intro), findsOneWidget);

      // …and off, on its own, once the grace runs out. Nothing completes the
      // read: it is still outstanding when this ends.
      await tester.pump(kBrightnessGrace);
      await tester.pump(LcMotion.introExit + margin);
      await tester.pump(margin);

      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(store.completer.isCompleted, isFalse);
      // In system mode — the honest answer for a device whose choice could not
      // be read — and showing exactly what `docs/ui-ux.md` prescribes for a
      // connection still in flight when the intro ends.
      expect(themeModeOf(tester), ThemeMode.system);
      expect(find.byKey(LcKeys.connecting), findsOneWidget);
      expect(find.text('Connecting to Studio PC…'), findsOneWidget);

      // And an answer that arrives late is still honoured — in the open, which
      // is the price of the bound and is the right price.
      //
      // Pumped frame by frame rather than settled: `ConnectingView` animates
      // for as long as it is on screen, so `pumpAndSettle` would never return
      // while it is (the pre-existing startup test does the same).
      store.completer.complete(ThemeMode.dark);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(themeModeOf(tester), ThemeMode.dark);
      expect(paintedTheme(tester).brightness, Brightness.dark);

      client.completer.complete(HandshakeSucceeded(endpoint, testIdentity()));
      await tester.pumpAndSettle();
    });

    testWidgets('the cover lifts for a device that has nothing to say',
        (tester) async {
      // The other half of the guard above. Without this one, a build that
      // simply never removed the intro would pass it.
      tallView(tester);
      final store = PendingThemeModeStore();
      await launch(tester, store: store, settle: false);
      await tester.pump();
      await tester.pump(LcMotion.intro + const Duration(milliseconds: 20));
      expect(find.byKey(LcKeys.intro), findsOneWidget);

      store.completer.complete(null);
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(themeModeOf(tester), ThemeMode.system);
    });

    testWidgets('the cover is not held a moment longer than the animation '
        'when the answer is already in', (tester) async {
      // A store that answers at once must change nothing about the intro: the
      // read is allowed to hold the cover, never to extend it.
      await launch(
        tester,
        store: InMemoryThemeModeStore(ThemeMode.dark),
        settle: false,
      );
      await tester.pump();
      await tester.pump(LcMotion.intro + const Duration(milliseconds: 20));
      await tester.pump(LcMotion.introExit + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(themeModeOf(tester), ThemeMode.dark);
    });
  });

  group('the control', () {
    testWidgets('says which of the three is selected, and only one of them',
        (tester) async {
      tallView(tester);
      final handle = tester.ensureSemantics();

      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.dark));
      await tester.ensureVisible(find.byKey(LcKeys.appearance));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.byKey(LcKeys.appearanceDark)),
        matchesSemantics(
          label: 'Dark',
          isSelected: true,
          hasSelectedState: true,
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      for (final other in <(Key, String)>[
        (LcKeys.appearanceLight, 'Light'),
        (LcKeys.appearanceSystem, 'System'),
      ]) {
        expect(
          tester.getSemantics(find.byKey(other.$1)),
          matchesSemantics(
            label: other.$2,
            isSelected: false,
            hasSelectedState: true,
            isButton: true,
            isEnabled: true,
            hasEnabledState: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
            isInMutuallyExclusiveGroup: true,
          ),
        );
      }
      handle.dispose();
    });

    testWidgets('the selected one moves with the choice', (tester) async {
      tallView(tester);
      final handle = tester.ensureSemantics();

      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.dark));
      await chooseAppearance(tester, LcKeys.appearanceLight);

      expect(
        tester.getSemantics(find.byKey(LcKeys.appearanceLight)),
        matchesSemantics(
          label: 'Light',
          isSelected: true,
          hasSelectedState: true,
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(LcKeys.appearanceDark)),
        matchesSemantics(
          label: 'Dark',
          isSelected: false,
          hasSelectedState: true,
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('it is in the controls column, beside the profile',
        (tester) async {
      tallView(tester);
      await launch(tester, store: InMemoryThemeModeStore());

      expect(
        find.descendant(
          of: find.byKey(LcKeys.controlsPane),
          matching: find.byKey(LcKeys.appearance),
        ),
        findsOneWidget,
      );
      expect(find.text('Appearance'), findsOneWidget);
    });

    // Every width this app draws the controls column at, in both postures, at
    // every text scale a phone offers, **in every locale it ships**. The
    // first version of this control was a `SegmentedButton` behind a
    // horizontal scroll: it passed a test that proved each option could be
    // *scrolled to*, while **System** — the default — had zero visible pixels
    // at every one of these widths but one.
    //
    // So this asserts the thing that was actually wrong, and it asserts it
    // **before any scrolling of any kind**: each option is fully inside its
    // block, at its full size, as drawn.
    //
    // **The locale is the dimension T-0142 added, and it is not decoration.**
    // The narrowest case fitted with 5.4dp to spare against the English word
    // "System"; the Russian is "Системное", half again as long. Every
    // assertion below was written against English labels, so without this
    // dimension the guard this control earned would have been worth nothing
    // the moment a second locale existed. The language control below the
    // theme control is measured in the same pass, because its labels are
    // longer still.
    for (final width in <double>[320, 360, 412, 840, 1100]) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        for (final tag in <String>['en', 'ru']) {
          testWidgets('every option is visible without scrolling at ${width}dp,'
              ' text scale $scale, in $tag', (tester) async {
          tester.view.physicalSize = Size(width, 3000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(
            tester.platformDispatcher.clearTextScaleFactorTestValue,
          );

          await launch(
            tester,
            store: InMemoryThemeModeStore(),
            language: LocaleChoice.of(Locale(tag)),
          );
          // The locale really did reach the tree. Without this the whole `ru`
          // half of the matrix could be measuring English labels twice.
          expect(
            Localizations.localeOf(tester.element(find.byKey(LcKeys.appearance))),
            Locale(tag),
          );

          expect(tester.takeException(), isNull);
          // Both postures are genuinely exercised: folded is one column,
          // unfolded is two panes, and the loop above crosses the threshold.
          expect(
            find.byKey(
              width >= LcLayout.twoPaneWidth
                  ? LcKeys.shellExpanded
                  : LcKeys.shellCompact,
            ),
            findsOneWidget,
          );

          final l = L.of(tester.element(find.byKey(LcKeys.appearance)));

          // The baseline for "drawn whole" comes from the **style**, never
          // from one of the chips: taken from a sibling it agrees with any
          // regression that hits all three labels equally, and passes while
          // every label on screen is ruined. Read fresh from the tree under
          // test — a `Theme.of` or a scaler carried over from an earlier
          // `pumpWidget` is stale, and a stale lookup is how a measurement of
          // this very layout went wrong once already.
          final context = tester.element(find.byKey(LcKeys.appearance));
          final style = Theme.of(context).textTheme.labelLarge!;
          expect(
            MediaQuery.textScalerOf(context).scale(10),
            closeTo(10 * scale, 0.001),
            reason: 'the $scale text scale did not reach the block',
          );

          // Both controls, in one pass: the theme's three answers and the
          // language's. Each option is measured against the block it belongs
          // to, so a chip that ran past its own card fails even if it happens
          // to sit inside the other one.
          final options = <(Key, String, Key)>[
            for (final (_, label, key) in AppearanceBar.optionsIn(l))
              (key, label, LcKeys.appearance),
            for (final (_, label, key) in LanguageBar.optionsIn(l))
              (key, label, LcKeys.language),
          ];
          expect(options.length, greaterThanOrEqualTo(6));

          for (final (option, label, blockKey) in options) {
            final block = tester.getRect(find.byKey(blockKey));
            expect(block.width, greaterThan(0));
            // Deliberately no `ensureVisible` anywhere above this line.
            final rect = tester.getRect(find.byKey(option));
            expect(
              rect.left,
              greaterThanOrEqualTo(block.left - 0.5),
              reason: '$label starts outside the block at ${width}dp/$scale',
            );
            expect(
              rect.right,
              lessThanOrEqualTo(block.right + 0.5),
              reason: '$label runs past the block at ${width}dp/$scale',
            );
            // And it is a control, not a sliver of one. The clipped segment
            // this replaces measured 4.8dp wide, under Material's minimum.
            expect(
              rect.width,
              greaterThanOrEqualTo(48),
              reason: '$label is ${rect.width}dp wide at ${width}dp/$scale',
            );
            expect(rect.height, greaterThanOrEqualTo(48));

            // …and the word inside it is all there. This is the assertion
            // the three above cannot make: a chip label carries `maxLines: 1`,
            // `softWrap: false` and `TextOverflow.fade`, so it can never wrap
            // and the way a label is lost here is that its end **fades out** —
            // "System" trailing away to nothing inside a chip that is still
            // 48dp wide and still fully inside the block. Measured against
            // what the style needs, so a chip squeezed to any width fails
            // rather than reporting whatever it managed to draw.
            // Measured with the scaler the label is *actually drawn with*,
            // read from inside the chip rather than from the block above it.
            // These two rows are the one place in this app that caps the
            // phone's text size ([kChoiceChipMaxTextScale]), because a chip
            // label cannot wrap and "Системное" cannot be shortened — and a
            // painter fed the uncapped scale would report a width nothing
            // here ever tried to draw.
            final labelFinder = find.descendant(
              of: find.byKey(option),
              matching: find.text(label),
            );
            final scaler = MediaQuery.textScalerOf(
              tester.element(labelFinder),
            );
            // The cap is a fact this loop asserts rather than assumes: below
            // it the phone's own size is honoured in full, above it the label
            // stops growing. Without this line the whole measurement could be
            // satisfied by a build that ignored text scaling entirely.
            expect(
              scaler.scale(10),
              closeTo(10 * (scale < kChoiceChipMaxTextScale
                  ? scale
                  : kChoiceChipMaxTextScale), 0.001),
              reason: '"$label" was drawn at the wrong text scale',
            );

            final painter = TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
            )..layout();
            final drawn = tester.getSize(labelFinder);
            expect(
              drawn.width,
              greaterThanOrEqualTo(painter.width - 0.5),
              reason:
                  '"$label" is drawn in ${drawn.width}dp of the '
                  '${painter.width}dp it needs at ${width}dp/$scale/$tag — it '
                  'is truncated',
            );
            expect(
              drawn.height,
              lessThanOrEqualTo(painter.height + 0.5),
              reason: '"$label" is drawn over more than one line at '
                  '${width}dp/$scale/$tag',
            );
          }

          // Nothing anywhere in the shell overflowed while drawing it, in this
          // locale at this size. A `RenderFlex` that ran out of room is
          // reported to the test rather than merely painted, so this is the
          // app-wide half of "no label is clipped".
          expect(tester.takeException(), isNull);
          });
        }
      }
    }

    test('no horizontal scroll view survives anywhere in lib/ui', () {
      // The mechanism this control used to hide its overflow behind, and the
      // only one of its kind this app ever had. Every other narrow-width
      // problem here is solved with a `Wrap` or an ellipsis, and one of those
      // `Wrap`s is in `ProfileBar`, immediately below this block.
      final root = Directory('lib/ui');
      expect(root.existsSync(), isTrue, reason: 'cwd ${Directory.current.path}');
      final files = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      // Anchored to a symbol that must exist, so a scan that silently found
      // nothing — a moved directory, a changed suffix — fails here instead of
      // passing empty.
      final bar = files.singleWhere(
        (f) => f.path.endsWith('appearance_bar.dart'),
        orElse: () => throw StateError('appearance_bar.dart was not scanned'),
      );
      expect(bar.readAsStringSync(), contains('class AppearanceBar'));
      expect(files.length, greaterThan(10));

      for (final file in files) {
        expect(
          file.readAsStringSync(),
          isNot(contains('scrollDirection: Axis.horizontal')),
          reason: '${file.path} scrolls sideways',
        );
      }
    });

    testWidgets('the chosen chip carries a check mark, so selection is not '
        'colour alone', (tester) async {
      // The sibling of this property — `isInMutuallyExclusiveGroup` — has two
      // guards; this had none, and turning the mark off passed the whole
      // suite. Asserted by measurement rather than by reading the parameter
      // back: what matters is that something is drawn, not that a flag is set.
      tallView(tester);
      await launch(tester, store: InMemoryThemeModeStore(ThemeMode.dark));

      double widthOf(Key key) => tester.getSize(find.byKey(key)).width;
      final darkChosen = widthOf(LcKeys.appearanceDark);
      final lightNotChosen = widthOf(LcKeys.appearanceLight);

      await chooseAppearance(tester, LcKeys.appearanceLight);

      final darkNotChosen = widthOf(LcKeys.appearanceDark);
      final lightChosen = widthOf(LcKeys.appearanceLight);

      // The same chip, the same label, the same text scale. The only thing
      // that changed is which one is chosen, so what it grew by is the mark.
      expect(
        darkChosen - darkNotChosen,
        greaterThanOrEqualTo(12),
        reason: 'the chosen chip is no wider than the unchosen one — nothing '
            'but colour tells them apart',
      );
      // And it belongs to the choice rather than to one chip.
      expect(
        lightChosen - lightNotChosen,
        closeTo(darkChosen - darkNotChosen, 0.5),
      );
    });

    testWidgets('a shell that was given no theme choice draws no block',
        (tester) async {
      tallView(tester);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);

      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(
              connection: connection,
              workflows: emptyRegistry(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.appearance), findsNothing);
      expect(find.byType(AppearanceBar), findsNothing);
    });

    testWidgets('and the same shell, given one, draws it', (tester) async {
      // Otherwise the absence above could pass on a build where the control
      // was never wired at all.
      tallView(tester);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);
      final appearance = testAppearance();
      addTearDown(appearance.dispose);

      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(
              connection: connection,
              workflows: emptyRegistry(),
            ),
            appearance: appearance,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.appearance), findsOneWidget);
    });
  });

  group('the profile sentence', () {
    testWidgets('is byte for byte what it was', (tester) async {
      // Decision 3 of this card: a screen preference is neither a workflow
      // setting nor a setup, so the theme is not in the exported document and
      // this sentence stays true without being reworded. Pinned verbatim,
      // because "still roughly says that" is not what was promised.
      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: Scaffold(
            body: ProfileBar(onExport: () {}, onImport: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Your saved settings and setups, as one file you can move to '
          'another phone. Nothing about this server, and nothing you have '
          'generated, is in it.',
        ),
        findsOneWidget,
      );
    });
  });

  group('a theme change disturbs nothing', () {
    testWidgets('a half-filled form survives it, Advanced and all',
        (tester) async {
      tallView(tester);
      final workflows = registryOfDetails(<Map<String, Object?>>[
        txt2imgDetail(),
      ]);
      await launch(
        tester,
        store: InMemoryThemeModeStore(),
        workflows: workflows,
      );

      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();

      // The shell's own disclosure, opened as well: the form's state lives in
      // the registry controller, and this one lives in the shell's `State` —
      // so a rebuild that discarded the second would leave the first standing
      // and look like a pass.
      await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);

      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a rainy alley at night',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      // Two advanced fields the user types into. `steps` is a slider at this
      // range and is left alone: what is being proved is that filled-in state
      // survives, not that every control type can be driven from a test.
      await tester.enterText(find.byKey(LcKeys.field('seed')), '4242');
      await tester.enterText(
        find.byKey(LcKeys.field('negative_prompt')),
        'no people',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);

      await chooseAppearance(tester, LcKeys.appearanceDark);

      // The theme really did change — otherwise everything below is a claim
      // about nothing.
      expect(themeModeOf(tester), ThemeMode.dark);
      expect(paintedTheme(tester).brightness, Brightness.dark);

      // …and not one thing the user had done was thrown away.
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);
      expect(find.text('a rainy alley at night'), findsOneWidget);
      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
      expect(find.text('4242'), findsOneWidget);
      expect(find.text('no people'), findsOneWidget);
      // The values as the app would submit them, not merely as drawn.
      final inputs = workflows.form!.validate().inputs;
      expect(inputs['prompt'], 'a rainy alley at night');
      expect(inputs['seed'], 4242);
      expect(inputs['negative_prompt'], 'no people');
    });

    testWidgets('Advanced left closed stays closed across one', (tester) async {
      // The other position of the same switch: a disclosure that sprang open
      // on a theme change would be as wrong as one that snapped shut.
      tallView(tester);
      final workflows = registryOfDetails(<Map<String, Object?>>[
        txt2imgDetail(),
      ]);
      await launch(
        tester,
        store: InMemoryThemeModeStore(),
        workflows: workflows,
      );

      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.advancedSection), findsNothing);

      await chooseAppearance(tester, LcKeys.appearanceLight);

      expect(themeModeOf(tester), ThemeMode.light);
      expect(find.byKey(LcKeys.advancedSection), findsNothing);
    });
  });
}
