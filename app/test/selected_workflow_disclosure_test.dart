/// The chosen workflow's block behaves the way it looks (T-0144).
///
/// It is drawn with the same surface, radius and outline as the server block
/// above it, so it expands in place like that one does: the header is the tap
/// target, the account of the workflow opens beneath it, and the "What this
/// does" button that used to open a sheet from here is gone.
///
/// Three separate claims are made below and each is checked on its own:
///
/// * the disclosure says **exactly** what the sheet says, in the sheet's
///   order — checked by harvesting both and comparing them, so a curated
///   subset cannot pass;
/// * a card in the **picker** still opens the sheet — the disclosure replaced
///   it for the chosen block only;
/// * the open/closed state survives a **theme change** and a **fold**, which
///   is a claim about where it lives, not about how it is drawn.
///
/// The prompt's height is asserted as the two numbers `TextField` is actually
/// given, and the folded layout is measured rather than reasoned about.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/app.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/theme_mode_controller.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/l10n.dart';
import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/workflow_payloads.dart';

/// A workflow whose description and whose one default are both unique to it,
/// so a frame that mixed two workflows up says which two.
Map<String, Object?> named(String id, String name, String setting, int value) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'presentation': <String, Object?>{
        'group': 'Create',
        'short_description': '$name explains itself.',
      },
      'required_media': <Object?>[],
      'inputs': <Object?>[
        <String, Object?>{
          'id': 'prompt',
          'label': 'Prompt',
          'type': 'multiline',
          'required': true,
          'section': 'main',
        },
        <String, Object?>{
          'id': '${id}_setting',
          'label': setting,
          'type': 'integer',
          'required': false,
          'section': 'advanced',
          'default': value,
          'min': 1,
          'max': 100,
        },
      ],
    };

/// One prose field and one one-line field, so the height of the first can be
/// stated against the second in the same form.
Map<String, Object?> twoTexts() => <String, Object?>{
  'id': 'two_texts',
  'name': 'Two Texts',
  // A description as well, so the picker card is tall enough that its centre
  // is the card and not the help button along its bottom edge.
  'presentation': <String, Object?>{
    'group': 'Create',
    'short_description': 'One prose field and one line.',
  },
  'required_media': <Object?>[],
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'note',
      'label': 'Note',
      'type': 'string',
      'required': false,
      'section': 'main',
    },
  ],
};

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;

  /// The words of the workflow the fixture publishes, written out here rather
  /// than read back off `txt2imgDetail()`. A test that compared the screen
  /// with the same map the screen was built from would confirm the fixture and
  /// say nothing about the app.
  const shortDescription =
      'A prompt-only example showing the smallest complete workflow '
      'definition.';
  const howToUse =
      'Describe what you want in the Prompt field. Everything else has a '
      'default that works, and lives under Advanced.';
  const examplePrompt =
      'A rainy alley at night, cinematic lighting, wet asphalt reflections';
  const notIdealFor = 'Anything that starts from an existing image or video';

  void view(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Tall and narrow: the whole controls column is laid out and tappable, so a
  /// test about state is never really a test about scrolling.
  void tallView(WidgetTester tester) => view(tester, const Size(420, 2400));

  WorkflowsController registry([List<Map<String, Object?>>? details]) {
    final bodies = details ?? <Map<String, Object?>>[txt2imgDetail()];
    final controller = WorkflowsController(
      api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(registryOf(bodies)),
        details: <String, WorkflowDetail>{
          for (final body in bodies)
            body['id']! as String: WorkflowDetail.tryFromJson(body)!,
        },
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<ConnectionController> connected() async {
    final controller = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(e, testIdentity()),
      ),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.connectTo(endpoint);
    return controller;
  }

  /// The shell alone, over fakes.
  Future<Widget> shell({WorkflowsController? workflows}) async {
    final session = testSession(
      connection: await connected(),
      workflows: workflows ?? registry(),
    );
    addTearDown(session.dispose);
    return MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      theme: lcDarkTheme(),
      home: ConnectedShell(session: session),
    );
  }

  /// The whole app, so that a theme change goes through the same path a person
  /// takes: `MaterialApp` rebuilds everything below it.
  Future<ThemeModeController> launch(WidgetTester tester) async {
    final connection = ConnectionController(
      client: ScriptedGatewayClient(
        (e) => HandshakeSucceeded(e, testIdentity()),
      ),
      store: InMemoryEndpointStore(
        RememberedServer(
          endpoint: endpoint,
          displayName: 'Studio PC',
          lastSuccess: DateTime.utc(2026),
        ),
      ),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(connection.dispose);
    final appearance = ThemeModeController(store: InMemoryThemeModeStore());
    addTearDown(appearance.dispose);
    final session = testSession(
      connection: connection,
      workflows: registry(),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      LocalCanvasApp(
        appearance: appearance,
        language: testLanguage(),
        session: session,
      ),
    );
    await tester.pumpAndSettle();
    return appearance;
  }

  /// The theme the app is actually painted in, resolved below `MaterialApp`.
  ThemeData paintedTheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(RootView)));

  Future<void> choose(WidgetTester tester, {String id = 'example_txt2img'}) async {
    await tester.tap(find.byKey(LcKeys.chooseWorkflow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.workflowCard(id)));
    await tester.pumpAndSettle();
  }

  Future<void> openDisclosure(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(LcKeys.selectedWorkflowToggle));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.selectedWorkflowToggle));
    await tester.pumpAndSettle();
  }

  /// Every word drawn under [root], in the order it is drawn.
  List<String> textsIn(WidgetTester tester, Finder root) => tester
      .widgetList<Text>(find.descendant(of: root, matching: find.byType(Text)))
      .map((widget) => widget.data ?? '')
      .toList();

  group('the block that looks like a disclosure is one', () {
    testWidgets('closed on first build, and the header is the tap target',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);

      // Closed, exactly as the server block is on first build.
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
      expect(find.byKey(LcKeys.serverDetails), findsNothing);
      // …and the words behind it really are absent, not merely unkeyed.
      expect(find.text(shortDescription), findsNothing);
      expect(find.text(howToUse), findsNothing);
      // The affordance the sheet used to hang off is gone from this block.
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(LcKeys.selectedWorkflow),
          matching: find.text('What this does'),
        ),
        findsNothing,
      );
      // Change stays: it is the other thing there is to do about a chosen
      // workflow, and this card did not touch it.
      expect(find.byKey(LcKeys.changeWorkflow), findsOneWidget);

      // The closed state above is a claim about the block, not about a
      // missing fixture: one tap and the whole account is there.
      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
      expect(find.text(shortDescription), findsOneWidget);
      expect(find.text(howToUse), findsOneWidget);
    });

    testWidgets('a second tap shuts it again', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);

      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
      expect(find.text(shortDescription), findsNothing);
    });

    testWidgets('it opens nothing modal — the body is inside the block',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);
      await openDisclosure(tester);

      // No sheet was pushed, and the body really is a descendant of the block
      // rather than a layer over it.
      expect(find.byKey(LcKeys.workflowHelpSheet), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(LcKeys.selectedWorkflow),
          matching: find.byKey(LcKeys.selectedWorkflowDetails),
        ),
        findsOneWidget,
      );
    });
  });

  group('one account of a workflow, two places to read it', () {
    testWidgets('the disclosure says what the sheet says, in the same order',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();

      // The sheet first, from a picker card — the surface this content has
      // always had.
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCardHelp('example_txt2img')));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.workflowHelpSheet), findsOneWidget);
      final sheet = textsIn(tester, find.byKey(LcKeys.workflowHelpSheet));

      // The sheet's own title is the name and the badge, and those two are the
      // only thing the block leaves out — because its header, one line above
      // the disclosure, already carries both. Pinned, so that the offset used
      // below is a stated fact rather than a convenient number.
      expect(sheet.take(2).toList(), <String>[
        'Example Text to Image',
        'TXT2IMG',
      ]);

      // Out of the sheet, into the block.
      await tester.tapAt(const Offset(210, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      await openDisclosure(tester);

      final disclosure = textsIn(
        tester,
        find.byKey(LcKeys.selectedWorkflowDetails),
      );
      // Word for word, section for section, order for order. A disclosure
      // showing a different subset — or the same subset rearranged — fails
      // here, however plausible the subset.
      expect(disclosure, sheet.sublist(2));

      // And the fixture is not empty: the comparison above would hold between
      // two blank lists.
      expect(disclosure.length, greaterThan(8));
      expect(disclosure, contains(shortDescription));
      expect(disclosure, contains(howToUse));
      expect(disclosure, contains(examplePrompt));
      expect(disclosure, contains(notIdealFor));
      // Headings, in the sheet's order, with the Defaults section the schema
      // supplies sitting where the sheet puts it.
      expect(
        disclosure.where(<String>{
          'What it needs',
          'Best for',
          'How to use it',
          'Defaults',
          'Example prompt',
          'Not ideal for',
        }.contains).toList(),
        <String>[
          'What it needs',
          'Best for',
          'How to use it',
          'Defaults',
          'Example prompt',
          'Not ideal for',
        ],
      );
    });

    testWidgets('a card in the picker still opens the sheet', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      expect(
        find.byKey(LcKeys.workflowCardHelp('example_txt2img')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(LcKeys.workflowCardHelp('example_txt2img')));
      await tester.pumpAndSettle();

      // Still a sheet, still with the workflow's account in it. Browsing a
      // list you have not chosen from is a different moment from working with
      // the one you did, and this card changed only the second.
      //
      // Scoped to the sheet: the card underneath it draws the short
      // description too, so an unscoped `findsOneWidget` would be asking a
      // different question than the one this test is about.
      expect(find.byKey(LcKeys.workflowHelpSheet), findsOneWidget);
      final sheet = textsIn(tester, find.byKey(LcKeys.workflowHelpSheet));
      expect(sheet, contains(shortDescription));
      expect(sheet, contains(howToUse));
      expect(sheet, contains(examplePrompt));
    });
  });

  group('the body is about the workflow whose header it hangs off', () {
    /// The one future the Defaults section is reading, right now.
    Future<WorkflowDetail?>? futureOf(WidgetTester tester) {
      final finder = find.descendant(
        of: find.byKey(LcKeys.selectedWorkflowDetails),
        matching: find.byType(FutureBuilder<WorkflowDetail?>),
      );
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<FutureBuilder<WorkflowDetail?>>(finder).future;
    }

    testWidgets('changing workflow never draws one workflow\'s defaults under '
        'another workflow\'s description, not even for one frame',
        (tester) async {
      // `FutureBuilder` keeps the previous snapshot's data when it is handed a
      // new future, so the frame after Change is where the two would meet.
      tallView(tester);
      await tester.pumpWidget(
        await shell(
          workflows: registry(<Map<String, Object?>>[
            named('alpha_flow', 'Alpha Flow', 'Alpha steps', 11),
            named('beta_flow', 'Beta Flow', 'Beta steps', 22),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, id: 'alpha_flow');
      await openDisclosure(tester);

      // The first workflow's own defaults really are on screen, so the
      // assertion below has something it could go wrong with.
      expect(
        textsIn(tester, find.byKey(LcKeys.selectedWorkflowDetails)),
        containsAll(<String>['Alpha Flow explains itself.', 'Alpha steps']),
      );

      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('beta_flow')));

      // Frame by frame, not settled: a stale frame is invisible to
      // `pumpAndSettle`, which is why it survived the first review.
      var sawBeta = false;
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final body = textsIn(
          tester,
          find.byKey(LcKeys.selectedWorkflowDetails),
        );
        if (body.contains('Beta Flow explains itself.')) {
          sawBeta = true;
          expect(
            body,
            isNot(contains('Alpha steps')),
            reason:
                'frame $frame drew Beta Flow\'s description beside Alpha '
                'Flow\'s defaults',
          );
        }
      }
      // …and the loop above looked at the frames it was written for.
      expect(sawBeta, isTrue);

      await tester.pumpAndSettle();
      final settled = textsIn(
        tester,
        find.byKey(LcKeys.selectedWorkflowDetails),
      );
      expect(
        settled,
        containsAll(<String>['Beta Flow explains itself.', 'Beta steps']),
      );
      expect(settled, isNot(contains('Alpha steps')));
    });

    testWidgets('a rebuild of the block does not restart the schema request',
        (tester) async {
      // The claim written on `_detailOf` in `connected_shell.dart`, as an
      // assertion. Handing the body `_workflows.detailFor(id)` straight from
      // `build` instead reads identically and passed every other test in this
      // suite: a new `Future` object on every keystroke, a `FutureBuilder`
      // that resubscribes each time, and the Defaults section blinking.
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);
      await openDisclosure(tester);

      final first = futureOf(tester);
      expect(first, isNotNull);

      await tester.enterText(
        find.byKey(LcKeys.field('prompt')),
        'a rainy alley at night',
      );
      await tester.pumpAndSettle();
      // The keystroke really did rebuild this block — otherwise the identity
      // below is a claim about a widget nothing happened to.
      expect(find.text('a rainy alley at night'), findsOneWidget);
      expect(futureOf(tester), same(first));

      // Shut and reopened is still the same request, not a second one.
      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
      await openDisclosure(tester);
      expect(futureOf(tester), same(first));
    });

    testWidgets('but another workflow gets its own request', (tester) async {
      // The other half of the same decision: memoised, and keyed on the
      // workflow. One future kept forever would pass the test above.
      tallView(tester);
      await tester.pumpWidget(
        await shell(
          workflows: registry(<Map<String, Object?>>[
            named('alpha_flow', 'Alpha Flow', 'Alpha steps', 11),
            named('beta_flow', 'Beta Flow', 'Beta steps', 22),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, id: 'alpha_flow');
      await openDisclosure(tester);
      final alpha = futureOf(tester);
      expect(alpha, isNotNull);

      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('beta_flow')));
      await tester.pumpAndSettle();

      expect(futureOf(tester), isNot(same(alpha)));
      expect(
        textsIn(tester, find.byKey(LcKeys.selectedWorkflowDetails)),
        contains('Beta steps'),
      );
    });
  });

  group('the disclosure survives what rebuilds the shell', () {
    testWidgets('open stays open across a theme change', (tester) async {
      tallView(tester);
      await launch(tester);
      await choose(tester);
      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
      final before = paintedTheme(tester).brightness;

      await tester.ensureVisible(find.byKey(LcKeys.appearanceDark));
      await tester.tap(find.byKey(LcKeys.appearanceDark));
      await tester.pumpAndSettle();

      // The theme really changed — otherwise the assertion below is a claim
      // about nothing at all. The harness comes up following a system that
      // says light, so Dark is the option that moves it.
      expect(before, Brightness.light);
      expect(paintedTheme(tester).brightness, Brightness.dark);

      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
      expect(find.text(shortDescription), findsOneWidget);
    });

    testWidgets('closed stays closed across a theme change', (tester) async {
      // The other position of the same switch. A disclosure that sprang open
      // on a theme change would be as wrong as one that snapped shut, and a
      // state that was simply rebuilt to its default would pass a test that
      // only ever checked the open case.
      tallView(tester);
      await launch(tester);
      await choose(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
      expect(paintedTheme(tester).brightness, Brightness.light);

      await tester.ensureVisible(find.byKey(LcKeys.appearanceDark));
      await tester.tap(find.byKey(LcKeys.appearanceDark));
      await tester.pumpAndSettle();

      expect(paintedTheme(tester).brightness, Brightness.dark);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
      expect(find.text(shortDescription), findsNothing);
    });

    testWidgets('open stays open across a fold', (tester) async {
      view(tester, const Size(420, 2400));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);
      await openDisclosure(tester);
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);

      // The fold: one window, then the other, decided by width alone.
      view(tester, const Size(1100, 2400));
      await tester.pumpAndSettle();

      // The layout really did change branch.
      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(find.byKey(LcKeys.shellCompact), findsNothing);
      // And the block came out of it exactly as the person left it.
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
      expect(find.text(shortDescription), findsOneWidget);

      // Back again, because a fold happens in both directions.
      view(tester, const Size(420, 2400));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
    });

    testWidgets('closed stays closed across a fold', (tester) async {
      view(tester, const Size(420, 2400));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);

      view(tester, const Size(1100, 2400));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
    });

    testWidgets('the two blocks keep their own positions independently',
        (tester) async {
      // Both disclosures live in the same `State`. One flag standing in for
      // both would pass every test above.
      view(tester, const Size(420, 2400));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);

      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);
      expect(find.byKey(LcKeys.serverDetails), findsNothing);

      await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);

      await openDisclosure(tester);
      expect(find.byKey(LcKeys.selectedWorkflowDetails), findsNothing);
      expect(find.byKey(LcKeys.serverDetails), findsOneWidget);
    });
  });

  group('the prompt', () {
    testWidgets('is five lines tall and grows to seven', (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);

      final field = tester.widget<TextField>(
        find.byKey(LcKeys.field('prompt')),
      );
      expect(field.minLines, 5);
      expect(field.maxLines, 7);
    });

    testWidgets('and a one-line field beside it is still one line',
        (tester) async {
      // So that the two numbers above are a fact about `multiline` and not
      // about every text entry in the app.
      tallView(tester);
      await tester.pumpWidget(
        await shell(workflows: registry(<Map<String, Object?>>[twoTexts()])),
      );
      await tester.pumpAndSettle();
      await choose(tester, id: 'two_texts');

      final prose = tester.widget<TextField>(
        find.byKey(LcKeys.field('prompt')),
      );
      expect(prose.minLines, 5);
      expect(prose.maxLines, 7);

      final line = tester.widget<TextField>(find.byKey(LcKeys.field('note')));
      expect(line.minLines, 1);
      expect(line.maxLines, 1);
    });
  });

  group('what the taller prompt costs, measured', () {
    /// Whether a widget is somewhere a person can see it: laid out at all, and
    /// wholly inside the window.
    bool inView(WidgetTester tester, Finder finder) {
      if (finder.evaluate().isEmpty) return false;
      final rect = tester.getRect(finder);
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      return rect.height > 0 && rect.top >= 0 && rect.bottom <= screen.height;
    }

    /// The scroll view inside [key]. `.first` is the outer one: a text field
    /// carries a scrollable of its own further down the tree.
    Finder scrollableIn(Key key) => find
        .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
        .first;

    ScrollPosition positionIn(WidgetTester tester, Key key) =>
        tester.state<ScrollableState>(scrollableIn(key)).position;

    Future<void> openAdvanced(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.advancedToggle));
      await tester.pumpAndSettle();
      // A run taken with Advanced shut is not the case this group is about,
      // and it looks exactly like one.
      expect(find.byKey(LcKeys.advancedSection), findsOneWidget);
    }

    // Everything this card added, all at once: five prompt lines, Advanced
    // open, and the new disclosure open too.
    for (final size in <Size>[Size(400, 700), Size(360, 640)]) {
      testWidgets(
        'folded ${size.width.toInt()}x${size.height.toInt()}: Generate is '
        'still reachable with Advanced and the disclosure both open',
        (tester) async {
          view(tester, size);
          await tester.pumpWidget(await shell());
          await tester.pumpAndSettle();
          await choose(tester);
          expect(find.byKey(LcKeys.shellCompact), findsOneWidget);

          await openDisclosure(tester);
          await openAdvanced(tester);
          expect(find.byKey(LcKeys.selectedWorkflowDetails), findsOneWidget);

          // The form is now far longer than the screen — which is the whole
          // reason this is worth checking rather than assuming.
          final position = positionIn(tester, LcKeys.shellCompact);
          expect(position.maxScrollExtent, greaterThan(size.height));

          await tester.scrollUntilVisible(
            find.byKey(LcKeys.generate),
            120,
            scrollable: scrollableIn(LcKeys.shellCompact),
          );
          await tester.pumpAndSettle();

          // Reachable, and wholly on screen once reached — not half under the
          // bottom edge.
          expect(inView(tester, find.byKey(LcKeys.generate)), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('unfolded: Generate is still reachable in the controls pane',
        (tester) async {
      view(tester, const Size(1024, 800));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);
      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);

      await openDisclosure(tester);
      await openAdvanced(tester);

      await tester.scrollUntilVisible(
        find.byKey(LcKeys.generate),
        120,
        scrollable: scrollableIn(LcKeys.controlsPane),
      );
      await tester.pumpAndSettle();
      expect(inView(tester, find.byKey(LcKeys.generate)), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('at the two-pane threshold itself, where the pane is narrowest',
        (tester) async {
      // 600 dp is where the layout branches, and the controls pane is at its
      // 320 dp minimum from here up for a while. A workflow with no Advanced
      // section, for the reason `generate_reveals_status_test.dart` records:
      // the test font draws every glyph as a square and makes the Advanced
      // toggle's two labels overflow a pane they fit on a device.
      view(tester, const Size(LcLayout.twoPaneWidth, 640));
      await tester.pumpWidget(
        await shell(workflows: registry(<Map<String, Object?>>[twoTexts()])),
      );
      await tester.pumpAndSettle();
      await choose(tester, id: 'two_texts');
      expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);

      await openDisclosure(tester);
      await tester.scrollUntilVisible(
        find.byKey(LcKeys.generate),
        120,
        scrollable: scrollableIn(LcKeys.controlsPane),
      );
      await tester.pumpAndSettle();
      expect(inView(tester, find.byKey(LcKeys.generate)), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the disclosure body has no scroll of its own, and needs none',
        (tester) async {
      // The judgement this card left open. The block sits inside the one
      // column's scroll on a folded screen and inside the controls pane's on
      // an unfolded one, so a scroll inside the body would be a second scroll
      // inside the first: the outer one would stop moving under a finger that
      // happened to land on the body, which is worse on a small screen than
      // the long page it would be shortening.
      view(tester, const Size(400, 640));
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);
      await openDisclosure(tester);

      // Structural: nothing scrollable between the body and the words in it.
      expect(
        find.descendant(
          of: find.byKey(LcKeys.selectedWorkflowDetails),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );

      // And it does not need one. The last thing the body says is off the
      // bottom of this short screen to begin with…
      expect(inView(tester, find.text(notIdealFor)), isFalse);
      final before = positionIn(tester, LcKeys.shellCompact).pixels;
      // …and the one scroll that is there carries it into view.
      await tester.scrollUntilVisible(
        find.text(notIdealFor),
        120,
        scrollable: scrollableIn(LcKeys.shellCompact),
      );
      await tester.pumpAndSettle();
      expect(inView(tester, find.text(notIdealFor)), isTrue);
      expect(
        positionIn(tester, LcKeys.shellCompact).pixels,
        greaterThan(before),
        reason:
            'the outer scroll is what moved, so it is what is doing the work '
            'a nested one would have taken over',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
