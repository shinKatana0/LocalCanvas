/// Which language a person gets, and who decides (T-0142).
///
/// **Nothing here touches `SharedPreferences`.** The language store is a fake
/// and is handed in, because composition happens in `main.dart` and only there
/// — which is the whole reason the app can be run end to end in a test at all.
/// What the real store writes into a real preference file is
/// `locale_store_test.dart`'s business.
///
/// The assertions are made on the locale `Localizations` actually resolved and
/// on the sentences the app is actually drawing, never on how it "looks".
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/app.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/l10n/app_locales.dart';
import 'package:localcanvas/l10n/app_localizations.dart';
import 'package:localcanvas/l10n/locale_controller.dart';
import 'package:localcanvas/l10n/locale_store.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';
import 'support/l10n.dart';

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;

  RememberedServer remembered() => RememberedServer(
    endpoint: endpoint,
    displayName: 'Studio PC',
    lastSuccess: DateTime.utc(2026),
  );

  /// The whole app, over fakes, on a device that already knows its server —
  /// so it settles into the connected shell.
  ///
  /// [systemLocales] is what the phone itself is set to, in the platform's own
  /// preference order. It is set on the binding's dispatcher, which is the one
  /// the app reads; nothing here reaches `PlatformDispatcher.instance`.
  Future<LocaleController> launch(
    WidgetTester tester, {
    LocaleStore? store,
    List<Locale>? systemLocales,
    GatewayClient? client,
    WorkflowsController? workflows,
    bool settle = true,
  }) async {
    if (systemLocales != null) {
      tester.platformDispatcher.localesTestValue = systemLocales;
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    }
    final connection = ConnectionController(
      client:
          client ??
          ScriptedGatewayClient((e) => HandshakeSucceeded(e, testIdentity())),
      store: InMemoryEndpointStore(remembered()),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    final appearance = testAppearance();
    addTearDown(appearance.dispose);
    final language = LocaleController(store: store ?? InMemoryLocaleStore());
    addTearDown(language.dispose);

    await tester.pumpWidget(
      LocalCanvasApp(
        appearance: appearance,
        language: language,
        session: testSession(
          connection: connection,
          workflows: workflows ?? emptyRegistry(),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
    return language;
  }

  /// The locale the interface is actually drawn in, resolved below
  /// `MaterialApp` where every screen reads it — not the one handed in.
  Locale drawnLocale(WidgetTester tester) =>
      Localizations.localeOf(tester.element(find.byType(RootView)));

  /// The bundle every widget under the app is reading from.
  L drawnBundle(WidgetTester tester) =>
      L.of(tester.element(find.byType(RootView)));

  /// A tall, narrow window: the controls column is long, and everything in it
  /// has to be on screen to be tapped.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> chooseLanguage(WidgetTester tester, Key option) async {
    await tester.ensureVisible(find.byKey(option));
    await tester.tap(find.byKey(option));
    await tester.pumpAndSettle();
  }

  group('the first run follows the system', () {
    // Each case on its own, and the resolved locale asserted verbatim rather
    // than "not English". The Japanese and French rows are the ones that catch
    // a resolver which answers with whatever the phone said.
    final Map<String, (List<Locale>, String)> cases =
        <String, (List<Locale>, String)>{
          'a Russian phone': (<Locale>[const Locale('ru')], 'ru'),
          'a Russian phone with a region': (
            <Locale>[const Locale('ru', 'BY')],
            'ru',
          ),
          'a Japanese phone': (<Locale>[const Locale('ja')], 'en'),
          'a French phone': (<Locale>[const Locale('fr', 'FR')], 'en'),
          'a phone that named no language at all': (<Locale>[], 'en'),
          'a phone that prefers Japanese and then Russian': (
            <Locale>[const Locale('ja'), const Locale('ru')],
            'ru',
          ),
          // The case Flutter's own resolution gets wrong: it falls back to a
          // *country* match when it cannot match a language, so this phone
          // resolves to `ru` under `basicLocaleListResolution`. Its owner does
          // not read Russian.
          'a Chinese phone in Russia': (
            <Locale>[const Locale('zh', 'RU')],
            'en',
          ),
        };

    cases.forEach((description, expectation) {
      final (locales, tag) = expectation;
      testWidgets('$description comes up in $tag', (tester) async {
        tallView(tester);
        final store = InMemoryLocaleStore();
        await launch(tester, store: store, systemLocales: locales);

        expect(drawnLocale(tester), Locale(tag));
        expect(drawnBundle(tester).localeName, tag);
        // And it did ask the store. Otherwise this would pass on a build that
        // never reads a stored choice at all, which is what the next group
        // catches.
        expect(store.reads, 1);
        expect(store.written, isEmpty);
      });
    });

    testWidgets('a Russian phone is shown Russian words, not a Russian locale '
        'over English text', (tester) async {
      // The locale is a fact about a widget; this is a fact about the screen.
      tallView(tester);
      await launch(tester, systemLocales: <Locale>[const Locale('ru')]);

      expect(find.text('Оформление'), findsOneWidget);
      expect(find.text('Язык'), findsOneWidget);
      expect(find.text('Пока нечем создавать'), findsOneWidget);
      expect(find.text('Выбрать другой сервер'), findsWidgets);
      expect(find.text('Appearance'), findsNothing);
      expect(find.text('Nothing to create with yet'), findsNothing);
    });

    testWidgets('and an English phone is shown English ones', (tester) async {
      tallView(tester);
      await launch(tester, systemLocales: <Locale>[const Locale('en', 'GB')]);

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Nothing to create with yet'), findsOneWidget);
      expect(find.text('Оформление'), findsNothing);
    });
  });

  group('the choice outranks the phone', () {
    testWidgets('a stored Russian comes up Russian on an English phone',
        (tester) async {
      tallView(tester);
      await launch(
        tester,
        store: InMemoryLocaleStore(LocaleChoice.of(const Locale('ru'))),
        systemLocales: <Locale>[const Locale('en')],
      );

      expect(drawnLocale(tester), const Locale('ru'));
      expect(find.text('Язык'), findsOneWidget);
    });

    testWidgets('a stored English comes up English on a Russian phone',
        (tester) async {
      tallView(tester);
      await launch(
        tester,
        store: InMemoryLocaleStore(LocaleChoice.of(const Locale('en'))),
        systemLocales: <Locale>[const Locale('ru')],
      );

      expect(drawnLocale(tester), const Locale('en'));
      expect(find.text('Language'), findsOneWidget);
    });

    testWidgets('a stored "follow the phone" comes up as the phone, having '
        'read it rather than assumed it', (tester) async {
      // Following the phone is also what an unread store does, so the choice
      // alone cannot tell this apart from a build that never read anything.
      // The read is what is asserted, and the value with it.
      tallView(tester);
      final store = InMemoryLocaleStore(LocaleChoice.system);
      final language = await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('ru')],
      );

      expect(store.reads, 1);
      expect(language.restored, isTrue);
      expect(language.choice, LocaleChoice.system);
      expect(drawnLocale(tester), const Locale('ru'));
    });

    testWidgets('a store that will not answer leaves the app on the phone\'s '
        'own language, and the app still starts', (tester) async {
      tallView(tester);
      final store = InMemoryLocaleStore(LocaleChoice.of(const Locale('en')))
        ..loadFailure = StateError('preferences unavailable');
      final language = await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('ru')],
      );

      expect(tester.takeException(), isNull);
      expect(language.restored, isTrue);
      expect(drawnLocale(tester), const Locale('ru'));
      // Started, not merely un-crashed: the cover is gone and the shell is
      // underneath it.
      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
    });
  });

  group('choosing', () {
    testWidgets('Russian, on an English phone', (tester) async {
      tallView(tester);
      final store = InMemoryLocaleStore();
      final language = await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('en')],
      );
      expect(find.text('Appearance'), findsOneWidget);

      await chooseLanguage(tester, LcKeys.languageOption('ru'));

      expect(drawnLocale(tester), const Locale('ru'));
      expect(language.choice, LocaleChoice.of(const Locale('ru')));
      expect(store.written, <LocaleChoice>[
        LocaleChoice.of(const Locale('ru')),
      ]);
      expect(store.stored, LocaleChoice.of(const Locale('ru')));
      // The screen, not just the controller.
      expect(find.text('Оформление'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
    });

    testWidgets('English, on a Russian phone', (tester) async {
      tallView(tester);
      final store = InMemoryLocaleStore();
      await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('ru')],
      );
      expect(find.text('Оформление'), findsOneWidget);

      await chooseLanguage(tester, LcKeys.languageOption('en'));

      expect(drawnLocale(tester), const Locale('en'));
      expect(store.stored, LocaleChoice.of(const Locale('en')));
      expect(find.text('Appearance'), findsOneWidget);
    });

    testWidgets('following the phone again, from somewhere else',
        (tester) async {
      // Starting from a chosen English on a Russian phone, so that landing on
      // Russian is a change this test caused rather than the value it started
      // with.
      tallView(tester);
      final store = InMemoryLocaleStore(LocaleChoice.of(const Locale('en')));
      await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('ru')],
      );
      expect(drawnLocale(tester), const Locale('en'));

      await chooseLanguage(tester, LcKeys.languageSystem);

      expect(drawnLocale(tester), const Locale('ru'));
      // Written down, not erased: a person who deliberately chose to follow
      // their phone chose something, and it has to survive the same way the
      // named languages do.
      expect(store.written, <LocaleChoice>[LocaleChoice.system]);
      expect(store.stored, LocaleChoice.system);
    });

    testWidgets('what was chosen is what comes back on the next launch',
        (tester) async {
      tallView(tester);
      final store = InMemoryLocaleStore();
      await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('en')],
      );
      await chooseLanguage(tester, LcKeys.languageOption('ru'));

      // The app again, over the same device: new controllers, same store.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('en')],
      );

      expect(drawnLocale(tester), const Locale('ru'));
      expect(find.text('Оформление'), findsOneWidget);
      expect(store.reads, 2);
    });

    testWidgets('a write that fails costs the next launch and not this one',
        (tester) async {
      tallView(tester);
      final store = InMemoryLocaleStore()
        ..saveFailure = StateError('preferences unavailable');
      await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('en')],
      );

      await chooseLanguage(tester, LcKeys.languageOption('ru'));

      expect(tester.takeException(), isNull);
      expect(drawnLocale(tester), const Locale('ru'));
    });

    testWidgets('the phone changing its own language while the app is open '
        'moves a follower and leaves a chooser alone', (tester) async {
      tallView(tester);
      final language = await launch(
        tester,
        systemLocales: <Locale>[const Locale('en')],
      );
      expect(drawnLocale(tester), const Locale('en'));

      // Following the phone: the app follows.
      tester.platformDispatcher.localesTestValue = <Locale>[
        const Locale('ru'),
      ];
      await tester.pumpAndSettle();
      expect(drawnLocale(tester), const Locale('ru'));
      // Still following, and still without having written anything down: a
      // device that has said nothing and one that chose to follow its phone
      // are the same outcome, reached the same way.
      expect(language.choice, LocaleChoice.system);

      // Having chosen: the phone no longer decides.
      await chooseLanguage(tester, LcKeys.languageOption('en'));
      tester.platformDispatcher.localesTestValue = <Locale>[
        const Locale('ru'),
      ];
      await tester.pumpAndSettle();
      expect(drawnLocale(tester), const Locale('en'));
    });
  });

  group('the first frame', () {
    /// One frame's worth of slack, three of which is how far past each stage
    /// of the intro the pumps below land.
    const Duration margin = Duration(milliseconds: 20);

    /// Past the animation *and* past its fade-out — so an app that did not
    /// wait for the stored language is fully on screen by now — but before the
    /// grace runs out, so this one is still covered.
    final Duration pastTheIntro =
        LcMotion.intro + LcMotion.introExit + margin * 3;

    /// Pumped in stages rather than in one jump: a single `pump` of the whole
    /// duration advances the clock once and rebuilds once, which is not enough
    /// for `AnimatedSwitcher` to both be told the intro finished *and* run its
    /// exit.
    Future<void> pumpPastTheIntro(WidgetTester tester) async {
      await tester.pump(LcMotion.intro + margin);
      await tester.pump(LcMotion.introExit + margin);
      await tester.pump(margin);
    }

    testWidgets('the app is never revealed in the language it is about to '
        'stop being', (tester) async {
      tallView(tester);
      final store = PendingLocaleStore();
      await launch(
        tester,
        store: store,
        systemLocales: <Locale>[const Locale('en')],
        settle: false,
      );
      await tester.pump();

      // The premise, asserted rather than assumed: the moment being pumped to
      // is genuinely past the whole intro and genuinely before the grace runs
      // out. If either stopped being true this would be measuring nothing.
      expect(pastTheIntro, greaterThan(LcMotion.intro + LcMotion.introExit));
      expect(pastTheIntro, lessThan(LcMotion.intro + kBrightnessGrace));

      await pumpPastTheIntro(tester);

      // An un-gated build is fully revealed by now. This one is not.
      expect(find.byKey(LcKeys.intro), findsOneWidget);
      expect(store.reads, 1);

      store.completer.complete(LocaleChoice.of(const Locale('ru')));
      await tester.pumpAndSettle();

      // Only now is the app on screen, and it is already Russian.
      expect(find.byKey(LcKeys.intro), findsNothing);
      expect(drawnLocale(tester), const Locale('ru'));
      expect(find.text('Оформление'), findsOneWidget);
    });

    testWidgets('a language read that never answers still ends in the '
        'contracted state, not in a splash with no end', (tester) async {
      // `docs/ui-ux.md` opens its startup section with the things that must
      // never happen, and a splash that does not end is the first of them.
      final store = PendingLocaleStore();
      final client = PendingGatewayClient();
      await launch(
        tester,
        store: store,
        client: client,
        systemLocales: <Locale>[const Locale('en')],
        settle: false,
      );
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
      // Following the phone — the honest answer for a device whose choice
      // could not be read — and showing exactly what `docs/ui-ux.md`
      // prescribes for a connection still in flight when the intro ends.
      expect(drawnLocale(tester), const Locale('en'));
      expect(find.byKey(LcKeys.connecting), findsOneWidget);
      expect(find.text('Connecting to Studio PC…'), findsOneWidget);

      // And an answer that arrives late is still honoured — in the open, which
      // is the price of the bound and is the right price.
      store.completer.complete(LocaleChoice.of(const Locale('ru')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(drawnLocale(tester), const Locale('ru'));
      expect(find.text('Подключение к Studio PC…'), findsOneWidget);

      client.completer.complete(HandshakeSucceeded(endpoint, testIdentity()));
      await tester.pumpAndSettle();
    });

    testWidgets('the cover waits for both stored choices, not for whichever '
        'answers first', (tester) async {
      // The theme store answers at once and the language store does not. A
      // build that lifted the cover on the first of the two would show the app
      // in the wrong language while it waited — the very defect the cover
      // exists to prevent, moved one store along.
      tallView(tester);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(remembered()),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      final appearance = testAppearance(ThemeMode.dark);
      addTearDown(appearance.dispose);
      final store = PendingLocaleStore();
      final language = LocaleController(store: store);
      addTearDown(language.dispose);

      await tester.pumpWidget(
        LocalCanvasApp(
          appearance: appearance,
          language: language,
          session: testSession(
            connection: connection,
            workflows: emptyRegistry(),
          ),
        ),
      );
      await tester.pump();
      expect(appearance.restored, isTrue);
      expect(language.restored, isFalse);

      await pumpPastTheIntro(tester);
      expect(find.byKey(LcKeys.intro), findsOneWidget);

      store.completer.complete(LocaleChoice.unset);
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.intro), findsNothing);
    });
  });

  group('the Russian form is no wider than the English one', () {
    // The form's own affordances are laid out by `Wrap` and `Flexible` and
    // were not at risk from this card — with one exception. "Random" is one
    // short word on a button that shares a row with the field's name and its
    // value, so a longer Russian label there is a real cost, and the field's
    // own name is curator content that does not change with the locale. The
    // Russian button is therefore the only thing on that row this card can
    // move, and this measures exactly that.
    //
    // **It is not an overflow test, deliberately.** That row already overflows
    // on `main` in English — 15dp at 320dp, 183dp at 320dp/2.0, measured while
    // writing this — so an assertion that it does not would be red for a
    // defect this card did not make (filed separately). What this card owes is
    // that it did not make it worse, and that is a comparison a test can make.
    Future<double> randomButtonWidth(
      WidgetTester tester,
      String tag,
      double width,
      double scale,
    ) async {
      tester.view.physicalSize = Size(width, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final workflows = WorkflowsController(
        api: ScriptedWorkflowsApi(
          summaries: WorkflowSummary.listFromJson(
            registryOf(<Map<String, Object?>>[txt2imgDetail()]),
          ),
          details: <String, WorkflowDetail>{
            'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
          },
        ),
      );
      addTearDown(workflows.dispose);

      await launch(
        tester,
        store: InMemoryLocaleStore(LocaleChoice.of(Locale(tag))),
        workflows: workflows,
      );
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();

      // The premise, asserted rather than assumed: this really is the locale
      // asked for, and the button under test really is on screen.
      expect(drawnLocale(tester), Locale(tag));
      expect(find.byKey(LcKeys.fieldRandom('seed')), findsOneWidget);
      // The pre-existing overflow is drained here rather than asserted on, so
      // the measurement below is the subject of this test and the defect it
      // sits on top of is somebody else's card.
      tester.takeException();
      final size = tester.getSize(find.byKey(LcKeys.fieldRandom('seed')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      return size.width;
    }

    for (final width in <double>[320, 412, 840]) {
      for (final scale in <double>[1.0, 2.0]) {
        testWidgets('Random costs no more in Russian at ${width}dp, text '
            'scale $scale', (tester) async {
          final english = await randomButtonWidth(tester, 'en', width, scale);
          final russian = await randomButtonWidth(tester, 'ru', width, scale);

          expect(english, greaterThan(0));
          expect(
            russian,
            lessThanOrEqualTo(english + 0.5),
            reason: 'the Russian Random button is ${russian}dp against '
                '${english}dp in English at ${width}dp/$scale — it makes the '
                'row this card did not widen wider',
          );
        });
      }
    }

    testWidgets('and it says what it does rather than what it means in the '
        'other sense', (tester) async {
      // The word itself, pinned: "Случайно" is an adverb whose ordinary sense
      // is *accidentally*, which is the opposite of a deliberate act on a
      // button a person presses on purpose.
      tallView(tester);
      await randomButtonWidth(tester, 'ru', 420, 1.0);
      expect(ru.fieldRandom, 'Наугад');
      expect(ru.fieldRandom, isNot('Случайно'));
    });
  });

  group('the control', () {
    testWidgets('it is in the controls column, beside the theme',
        (tester) async {
      tallView(tester);
      await launch(tester);

      expect(
        find.descendant(
          of: find.byKey(LcKeys.controlsPane),
          matching: find.byKey(LcKeys.language),
        ),
        findsOneWidget,
      );
      expect(find.byKey(LcKeys.appearance), findsOneWidget);
    });

    testWidgets('a shell that was given no language choice draws no block',
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
            appearance: testAppearance(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.language), findsNothing);
    });

    testWidgets('every shipped locale is offered, under its own name, in both '
        'locales', (tester) async {
      // The names are deliberately not translated: the person most in need of
      // this control is the one who cannot read the interface in front of
      // them, and "Russian" is no help to them.
      for (final phone in <String>['en', 'ru']) {
        tallView(tester);
        await launch(tester, systemLocales: <Locale>[Locale(phone)]);

        for (final locale in kSupportedLocales) {
          expect(
            find.byKey(LcKeys.languageOption(locale.languageCode)),
            findsOneWidget,
            reason: '${locale.languageCode} is not offered on a $phone phone',
          );
        }
        expect(find.text('English'), findsOneWidget);
        expect(find.text('Русский'), findsOneWidget);
        // And "follow the phone" is translated, because it is a sentence about
        // the phone rather than the name of a language.
        expect(
          find.text(phone == 'ru' ? 'Системный' : 'System'),
          findsWidgets,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });

    testWidgets('a device that has said nothing shows the phone chip as the '
        'chosen one, rather than none of the three', (tester) async {
      tallView(tester);
      final handle = tester.ensureSemantics();
      await launch(tester, systemLocales: <Locale>[const Locale('en')]);

      expect(
        tester.getSemantics(find.byKey(LcKeys.languageSystem)),
        matchesSemantics(
          label: 'System',
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
      for (final locale in kSupportedLocales) {
        expect(
          tester.getSemantics(
            find.byKey(LcKeys.languageOption(locale.languageCode)),
          ),
          matchesSemantics(
            label: localeAutonym(locale),
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
      await launch(tester, systemLocales: <Locale>[const Locale('en')]);

      await chooseLanguage(tester, LcKeys.languageOption('ru'));

      expect(
        tester.getSemantics(find.byKey(LcKeys.languageOption('ru'))),
        matchesSemantics(
          label: 'Русский',
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
        tester.getSemantics(find.byKey(LcKeys.languageSystem)),
        matchesSemantics(
          label: 'Системный',
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
  });

  group('a language change disturbs nothing', () {
    testWidgets('the server disclosure stays open across one', (tester) async {
      // The disclosure lives above the layout branch in the shell's own
      // `State`, so a rebuild that discarded it would come back closed.
      tallView(tester);
      await launch(tester, systemLocales: <Locale>[const Locale('en')]);

      await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);

      await chooseLanguage(tester, LcKeys.languageOption('ru'));

      // The language really did change — otherwise everything below is a claim
      // about nothing.
      expect(drawnLocale(tester), const Locale('ru'));
      expect(find.text('Адрес'), findsOneWidget);
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);
    });
  });
}
