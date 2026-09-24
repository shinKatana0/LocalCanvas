/// The picker and the help sheet (`docs/ui-ux.md`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/workflows/workflow_picker.dart';
import 'package:localcanvas/workflows/workflow_models.dart';

import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

void main() {
  List<WorkflowSummary> summariesOf(Map<String, Object?> registry) =>
      WorkflowSummary.listFromJson(registry);

  /// Tall enough that every card in these fixtures is laid out, so a finder
  /// that comes up empty means the card is missing rather than merely
  /// off-screen.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Only what the sheet itself draws. The card underneath repeats some of the
  /// same words, and asserting across both would pass on the wrong one.
  Finder inSheet(Finder matching) => find.descendant(
    of: find.byKey(LcKeys.workflowHelpSheet),
    matching: matching,
  );

  Future<String?> pumpPicker(
    WidgetTester tester,
    List<WorkflowSummary> workflows, {
    Map<String, WorkflowDetail> details = const <String, WorkflowDetail>{},
  }) async {
    String? chosen;
    var popped = false;
    await tester.pumpWidget(
      MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
        theme: lcDarkTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  chosen = await chooseWorkflow(
                    context,
                    workflows: workflows,
                    selectedId: null,
                    detailLoader: (id) async => details[id],
                  );
                  popped = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(popped, isFalse);
    return chosen;
  }

  group('the picker', () {
    testWidgets('shows cards, not a dropdown', (tester) async {
      tallView(tester);
      await pumpPicker(tester, summariesOf(examplesRegistry()));

      expect(find.byKey(LcKeys.workflowPicker), findsOneWidget);
      expect(find.text('Example Text to Image'), findsOneWidget);
      expect(find.text('TXT2IMG'), findsOneWidget);
      expect(find.text('Example'), findsNWidgets(3));
      expect(
        find.textContaining('A prompt-only example'),
        findsOneWidget,
      );
      expect(find.text('Prompt only'), findsOneWidget);

      // Not a bare technical dropdown, in any of its Material spellings.
      expect(find.byType(DropdownButton<Object?>), findsNothing);
      expect(find.byType(DropdownMenu<Object?>), findsNothing);
      for (final id in <String>[
        'example_txt2img',
        'example_img2img',
        'example_video',
      ]) {
        expect(find.byKey(LcKeys.workflowCard(id)), findsOneWidget);
      }
    });

    testWidgets('groups come from the registry, in its own order',
        (tester) async {
      tallView(tester);
      await pumpPicker(tester, summariesOf(examplesRegistry()));

      expect(find.byKey(LcKeys.workflowGroup('Create')), findsOneWidget);
      expect(find.byKey(LcKeys.workflowGroup('Edit')), findsOneWidget);
      expect(find.byKey(LcKeys.workflowGroup('Video')), findsOneWidget);

      final createY =
          tester.getTopLeft(find.byKey(LcKeys.workflowGroup('Create'))).dy;
      final videoY =
          tester.getTopLeft(find.byKey(LcKeys.workflowGroup('Video'))).dy;
      expect(createY, lessThan(videoY));
    });

    testWidgets('a group the examples never use renders as its own section',
        (tester) async {
      tallView(tester);
      // "Sculpting" appears nowhere in the app, the schema or the examples.
      final registry = registryOf(<Map<String, Object?>>[
        txt2imgDetail(),
        renamed(
          txt2imgDetail(),
          id: 'sculpting_one',
          name: 'Sculpting One',
          group: 'Sculpting',
        ),
      ]);

      await pumpPicker(tester, summariesOf(registry));

      expect(find.byKey(LcKeys.workflowGroup('Sculpting')), findsOneWidget);
      // Asked of the heading rather than of the screen: since T-0177 the
      // filter above offers the same name as an option, so a bare
      // `find.text` would be counting two different things at once.
      expect(
        find.descendant(
          of: find.byKey(LcKeys.workflowGroup('Sculpting')),
          matching: find.text('Sculpting'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(LcKeys.workflowCard('sculpting_one')),
        findsOneWidget,
        reason: 'an unfamiliar group must not swallow its workflows',
      );
      // And it is drawn like any other section, under its own heading.
      final heading =
          tester.getTopLeft(find.byKey(LcKeys.workflowGroup('Sculpting'))).dy;
      final card =
          tester.getTopLeft(find.byKey(LcKeys.workflowCard('sculpting_one'))).dy;
      expect(heading, lessThan(card));
    });

    testWidgets('a badge nobody has seen is drawn like every other badge',
        (tester) async {
      tallView(tester);
      // Every badge the examples use, plus one they do not. Two values would
      // let a branch on the third go unnoticed: keyed to the missing one, it
      // paints both of the others alike and the assertion below still holds.
      final odd = txt2imgDetail();
      (odd['presentation']! as Map<String, Object?>)['badge'] = 'SCULPT';
      final registry = registryOf(<Map<String, Object?>>[
        odd,
        renamed(txt2imgDetail(), id: 'plain', name: 'Plain'),
        img2imgDetail(),
        videoDetail(),
      ]);

      await pumpPicker(tester, summariesOf(registry));

      final badges = tester
          .widgetList<WorkflowBadge>(find.byType(WorkflowBadge))
          .toList();
      expect(badges.map((b) => b.text), <String>[
        'SCULPT',
        'TXT2IMG',
        'IMG2IMG',
        'VIDEO',
      ]);
      final styles = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(WorkflowBadge),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .toSet();
      expect(
        styles,
        hasLength(1),
        reason: 'a badge value must not choose its own colour',
      );
    });

    testWidgets('a workflow with no group still gets a card', (tester) async {
      tallView(tester);
      final registry = registryOf(<Map<String, Object?>>[
        renamed(txt2imgDetail(), id: 'loose', name: 'Loose', group: null),
      ]);

      await pumpPicker(tester, summariesOf(registry));

      expect(find.byKey(LcKeys.workflowCard('loose')), findsOneWidget);
      expect(find.text('Loose'), findsOneWidget);
      // The only section there is: a heading over the whole list would say
      // nothing, and there is no other heading to be mistaken for.
      expect(find.byKey(LcKeys.ungroupedWorkflows), findsNothing);
    });

    testWidgets('an ungrouped workflow does not read as part of the section '
        'above it', (tester) async {
      tallView(tester);
      final registry = registryOf(<Map<String, Object?>>[
        renamed(
          txt2imgDetail(),
          id: 'sculpting_one',
          name: 'Sculpting One',
          group: 'Sculpting',
        ),
        renamed(txt2imgDetail(), id: 'loose', name: 'Loose', group: null),
      ]);

      await pumpPicker(tester, summariesOf(registry));

      final heading = find.byKey(LcKeys.ungroupedWorkflows);
      expect(heading, findsOneWidget);
      final sculpting =
          tester.getTopLeft(find.byKey(LcKeys.workflowCard('sculpting_one'))).dy;
      final loose =
          tester.getTopLeft(find.byKey(LcKeys.workflowCard('loose'))).dy;
      final between = tester.getTopLeft(heading).dy;
      expect(
        between,
        greaterThan(sculpting),
        reason: 'the ungrouped card must be separated from the section above',
      );
      expect(between, lessThan(loose));
    });

    testWidgets('a group genuinely named Other is not the nameless one',
        (tester) async {
      tallView(tester);
      final registry = registryOf(<Map<String, Object?>>[
        renamed(txt2imgDetail(), id: 'named', name: 'Named', group: 'Other'),
        renamed(txt2imgDetail(), id: 'loose', name: 'Loose', group: null),
      ]);

      await pumpPicker(tester, summariesOf(registry));

      // Two headings reading "Other", found by two different keys: the
      // registry's own group, and the app's word for having none.
      expect(find.byKey(LcKeys.workflowGroup('Other')), findsOneWidget);
      expect(find.byKey(LcKeys.ungroupedWorkflows), findsOneWidget);
      // Each heading says it, asked under its own key. A bare
      // `find.text('Other')` would now also be counting the two filter
      // options above (T-0177), which are the same pair of things and are
      // asserted as such in `workflow_filter_test.dart`.
      for (final heading in <Key>[
        LcKeys.workflowGroup('Other'),
        LcKeys.ungroupedWorkflows,
      ]) {
        expect(
          find.descendant(of: find.byKey(heading), matching: find.text('Other')),
          findsOneWidget,
          reason: '$heading',
        );
      }
    });

    testWidgets('choosing a card returns its id', (tester) async {
      tallView(tester);
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => chosen = await chooseWorkflow(
                    context,
                    workflows: summariesOf(examplesRegistry()),
                    selectedId: null,
                    detailLoader: (_) async => null,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(LcKeys.workflowCard('example_video')));
      await tester.pumpAndSettle();

      expect(chosen, 'example_video');
    });
  });

  group('the help sheet', () {
    testWidgets('explains the workflow in the curator\'s own words',
        (tester) async {
      tallView(tester);
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      await pumpPicker(
        tester,
        summariesOf(examplesRegistry()),
        details: <String, WorkflowDetail>{'example_txt2img': detail},
      );

      await tester.tap(find.byKey(LcKeys.workflowCardHelp('example_txt2img')));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowHelpSheet), findsOneWidget);
      // What it does, when to choose it, what it needs, how to use it,
      // its defaults, an example prompt, and what it is not for.
      expect(inSheet(find.textContaining('A prompt-only example')),
          findsOneWidget);
      expect(inSheet(find.text('Best for')), findsOneWidget);
      expect(
        inSheet(find.text('Starting your own prompt-only workflow')),
        findsOneWidget,
      );
      expect(inSheet(find.text('What it needs')), findsOneWidget);
      expect(inSheet(find.text('How to use it')), findsOneWidget);
      expect(inSheet(find.textContaining('Describe what you want')),
          findsOneWidget);
      expect(inSheet(find.text('Defaults')), findsOneWidget);
      expect(inSheet(find.text('Example prompt')), findsOneWidget);
      expect(inSheet(find.textContaining('A rainy alley at night')),
          findsOneWidget);
      expect(inSheet(find.text('Not ideal for')), findsOneWidget);
      expect(
        inSheet(find.text('Anything that starts from an existing image or video')),
        findsOneWidget,
      );
    });

    testWidgets('the defaults it lists are the ones the schema declares',
        (tester) async {
      tallView(tester);
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      await pumpPicker(
        tester,
        summariesOf(examplesRegistry()),
        details: <String, WorkflowDetail>{'example_txt2img': detail},
      );

      await tester.tap(find.byKey(LcKeys.workflowCardHelp('example_txt2img')));
      await tester.pumpAndSettle();

      final defaults = find.byKey(LcKeys.workflowHelpDefaults);
      expect(defaults, findsOneWidget);
      expect(
        find.descendant(of: defaults, matching: find.text('Steps')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: defaults, matching: find.text('20')),
        findsOneWidget,
      );
      // A select shows the option's label, not its machine value.
      expect(
        find.descendant(of: defaults, matching: find.text('Euler')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: defaults, matching: find.text('euler')),
        findsNothing,
      );
      // A required field has no default, so it is not in the list.
      expect(
        find.descendant(of: defaults, matching: find.text('Prompt')),
        findsNothing,
      );
      // And a default of "" says nothing rather than "Avoid: ".
      expect(
        find.descendant(of: defaults, matching: find.text('Avoid')),
        findsNothing,
      );
    });

    testWidgets('a section the registry did not fill in is simply absent',
        (tester) async {
      tallView(tester);
      final sparse = <String, Object?>{
        'id': 'sparse',
        'name': 'Sparse',
        'presentation': <String, Object?>{
          'short_description': 'All it says about itself.',
        },
        'required_media': <Object?>[],
        'inputs': <Object?>[],
      };

      await pumpPicker(tester, summariesOf(registryOf(<Map<String, Object?>>[
        sparse,
      ])), details: <String, WorkflowDetail>{
        'sparse': WorkflowDetail.tryFromJson(sparse)!,
      });

      await tester.tap(find.byKey(LcKeys.workflowCardHelp('sparse')));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('All it says about itself.')), findsOneWidget);
      for (final heading in <String>[
        'What it needs',
        'Best for',
        'How to use it',
        'Defaults',
        'Example prompt',
        'Not ideal for',
      ]) {
        expect(find.text(heading), findsNothing, reason: heading);
      }
      expect(find.textContaining('N/A'), findsNothing);
      expect(find.byKey(LcKeys.workflowHelpDefaults), findsNothing);
    });

    testWidgets('a schema that never arrives costs the sheet nothing',
        (tester) async {
      tallView(tester);
      await pumpPicker(tester, summariesOf(examplesRegistry()));

      await tester.tap(find.byKey(LcKeys.workflowCardHelp('example_txt2img')));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowHelpSheet), findsOneWidget);
      expect(inSheet(find.textContaining('A prompt-only example')),
          findsOneWidget);
      expect(find.byKey(LcKeys.workflowHelpDefaults), findsNothing);
    });
  });

  group('how many there are (T-0121)', () {
    /// A catalogue of [count] workflows, all distinct, in one group -- so the
    /// number below is never the number of anything else on screen.
    List<WorkflowSummary> catalogueOf(int count) => summariesOf(
      registryOf(<Map<String, Object?>>[
        for (var index = 0; index < count; index++)
          renamed(
            txt2imgDetail(),
            id: 'example_$index',
            name: 'Example $index',
            group: 'Create',
          ),
      ]),
    );

    /// The picker over one list, pumped directly, so a second pump can hand
    /// it another one.
    Future<void> pumpList(
      WidgetTester tester,
      List<WorkflowSummary> workflows,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: WorkflowPickerScreen(
            workflows: workflows,
            selectedId: null,
            detailLoader: (_) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Tall enough that every card of these fixtures is laid out, so counting
    /// the rendered cards counts the list rather than the viewport.
    void hugeView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 8000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('the count is shown, and it is the number of cards drawn',
        (tester) async {
      hugeView(tester);
      await pumpList(tester, catalogueOf(7));

      expect(find.byKey(LcKeys.workflowCount), findsOneWidget);
      expect(find.text('7 workflows'), findsOneWidget);
      // The number against the thing it describes, counted independently of
      // it: the cards on screen.
      expect(find.byType(WorkflowCard), findsNWidgets(7));
      expect(
        tester.widget<Text>(find.byKey(LcKeys.workflowCount)).data,
        '${tester.widgetList(find.byType(WorkflowCard)).length} workflows',
      );
    });

    testWidgets('a different catalogue is a different number', (tester) async {
      // The mutation this kills is a count that is written down once -- hard
      // coded, or computed and kept -- and then goes on being shown over a
      // list that has changed under it.
      hugeView(tester);
      await pumpList(tester, catalogueOf(3));
      expect(find.text('3 workflows'), findsOneWidget);

      await pumpList(tester, catalogueOf(7));

      expect(find.text('7 workflows'), findsOneWidget);
      expect(find.text('3 workflows'), findsNothing);
      expect(find.byType(WorkflowCard), findsNWidgets(7));
    });

    testWidgets('one workflow is one workflow', (tester) async {
      hugeView(tester);
      await pumpList(tester, catalogueOf(1));

      expect(find.text('1 workflow'), findsOneWidget);
      expect(find.text('1 workflows'), findsNothing);
      expect(find.byType(WorkflowCard), findsOneWidget);
    });

    testWidgets('the count is above the list, not somewhere in it',
        (tester) async {
      // "In the upper part", which is what makes it readable at a glance: it
      // sits over the first card rather than after any of them.
      hugeView(tester);
      await pumpList(tester, catalogueOf(4));

      final count = tester.getRect(find.byKey(LcKeys.workflowCount));
      for (final card in find.byType(WorkflowCard).evaluate()) {
        expect(
          count.bottom,
          lessThanOrEqualTo(tester.getRect(find.byWidget(card.widget)).top),
        );
      }
    });
  });
}
