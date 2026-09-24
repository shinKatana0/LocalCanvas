/// Show me one kind at a time: the picker's filter (T-0177).
///
/// What this file has to be careful about, and why each care is here:
///
/// * **the list is read by id, never counted.** "Two workflows shown" is true
///   of the right two and of the wrong two, so every assertion about what a
///   narrowing did names the ids, in order, as a whole list — a leak from
///   another group is then a failure that prints which workflow leaked;
/// * **an absence is only worth asserting after the thing was there.** Every
///   test that says a card is gone first shows the same card on the same
///   screen under `All`, so a finder that could never find it — a wrong key, a
///   card off the bottom of the viewport — fails loudly instead of passing as
///   proof;
/// * **the vocabulary is proved on a catalogue this app has never heard of.**
///   `Kilning`, `Weaving` and `Sculpting` appear nowhere in the app, the
///   schema or the examples, so a filter that offered `Create`/`Edit` from a
///   list of its own would have nothing to say about them;
/// * **the view is tall enough that a card that is not found is missing.** The
///   picker's `ListView` builds what the viewport reaches, so a short surface
///   would make "absent" and "further down" the same answer.
///
/// **Every dp of text named here is the widget-test toolkit's fixed-advance
/// font** — 15.09dp per character, Latin and Cyrillic alike (T-0150) — not the
/// shipped face. The 320dp viewport and the 36dp check-mark square are not
/// font-derived; whether thirteen options need a second line at 320dp and a
/// 2.0 scale, or a group name needs a second line inside its option, is. So
/// nothing below is designed against those numbers: each test that needs the
/// text to run out of room first asserts that it did, at whatever size this
/// font happens to produce. The wrapping is a fact about the layout; the
/// magnitudes are facts about the harness.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  /// A catalogue of `(id, group)` pairs, in that order, all otherwise alike.
  List<WorkflowSummary> catalogue(List<(String, String?)> entries) =>
      summariesOf(
        registryOf(<Map<String, Object?>>[
          for (final (id, group) in entries)
            renamed(
              txt2imgDetail(),
              id: id,
              name: 'Workflow $id',
              group: group,
            ),
        ]),
      );

  /// Tall and wide enough that every card of these fixtures is laid out, so a
  /// card that is not found is a card that is not there.
  void roomForEverything(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPicker(
    WidgetTester tester,
    List<WorkflowSummary> workflows, {
    String locale = 'en',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
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

  /// Every workflow card on screen, by id, in the order they are drawn.
  ///
  /// Read off the cards themselves rather than off the fixture, so a card
  /// drawn for a workflow that should have been filtered out is in this list.
  List<String> shownIds(WidgetTester tester) => <String>[
    for (final card in tester.widgetList<WorkflowCard>(
      find.byType(WorkflowCard),
    ))
      card.workflow.id,
  ];

  /// The filter's options, in the order it offers them, as a person reads
  /// them.
  List<String> optionLabels(WidgetTester tester) => <String>[
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(LcKeys.workflowFilter),
        matching: find.byType(Text),
      ),
    ))
      text.data!,
  ];

  /// The words an option is labelled with.
  ///
  /// The label is read through the shape the picker builds it in —
  /// `Semantics(child: Text(words))` — and a label of any other shape is a
  /// failure that says so, rather than a cast error that reads as a fault in
  /// the harness.
  String labelOf(ChoiceChip chip) {
    final Widget label = chip.label;
    final Widget? child = label is Semantics ? label.child : null;
    if (child is! Text || child.data == null) {
      fail(
        'expected the option ${chip.key} to be labelled '
        'Semantics(child: Text(<its words>)), but its label is '
        '${label.runtimeType}'
        '${label is Semantics ? '(child: ${child.runtimeType})' : ''}',
      );
    }
    return child.data!;
  }

  /// Which options are showing as chosen. More than one would be a filter
  /// saying two things at once.
  List<String> chosenLabels(WidgetTester tester) => <String>[
    for (final chip in tester.widgetList<ChoiceChip>(
      find.descendant(
        of: find.byKey(LcKeys.workflowFilter),
        matching: find.byType(ChoiceChip),
      ),
    ))
      if (chip.selected) labelOf(chip),
  ];

  Future<void> tapOption(WidgetTester tester, Key option) async {
    expect(find.byKey(option), findsOneWidget, reason: '$option');
    await tester.tap(find.byKey(option));
    await tester.pumpAndSettle();
  }

  /// What the three shipped examples are, drawn in full: the ids in the
  /// registry's order, the sections over them, and the count above both.
  ///
  /// This is `main`'s picker, written out rather than derived, because it is
  /// the thing the filter's default must not change.
  const List<String> exampleIds = <String>[
    'example_txt2img',
    'example_img2img',
    'example_video',
  ];
  const List<String> exampleGroups = <String>['Create', 'Edit', 'Video'];

  group('what All is', () {
    testWidgets('the picker opens on All, and it is the list it drew before '
        'the filter existed', (tester) async {
      roomForEverything(tester);
      await pumpPicker(tester, summariesOf(examplesRegistry()));

      expect(find.byKey(LcKeys.workflowFilter), findsOneWidget);
      expect(chosenLabels(tester), <String>['All']);
      // Every card, by id, in the registry's order.
      expect(shownIds(tester), exampleIds);
      // Every section, in the registry's order, each above its own card.
      for (var i = 0; i < exampleGroups.length; i++) {
        final heading = find.byKey(LcKeys.workflowGroup(exampleGroups[i]));
        expect(heading, findsOneWidget, reason: exampleGroups[i]);
        expect(
          tester.getTopLeft(heading).dy,
          lessThan(
            tester.getTopLeft(find.byKey(LcKeys.workflowCard(exampleIds[i]))).dy,
          ),
          reason: exampleGroups[i],
        );
      }
      expect(find.text('3 workflows'), findsOneWidget);
    });

    testWidgets('and coming back to it is one tap, onto the same list',
        (tester) async {
      roomForEverything(tester);
      await pumpPicker(tester, summariesOf(examplesRegistry()));
      final opened = shownIds(tester);

      await tapOption(tester, LcKeys.workflowFilterGroup('Edit'));
      expect(shownIds(tester), <String>['example_img2img']);
      expect(chosenLabels(tester), <String>['Edit']);

      await tapOption(tester, LcKeys.workflowFilterAll);

      expect(shownIds(tester), opened);
      expect(shownIds(tester), exampleIds);
      expect(chosenLabels(tester), <String>['All']);
      expect(find.text('3 workflows'), findsOneWidget);
    });

    testWidgets('All is the first option, so it is on the first row at any '
        'width', (tester) async {
      // A way back to everything that has scrolled or wrapped out of sight is
      // not one tap. It is first, and the options after it are the
      // catalogue's, in the catalogue's order.
      tester.view.physicalSize = const Size(320, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('a', 'Kilning'),
          ('b', 'Weaving'),
          ('c', 'Sculpting'),
        ]),
      );

      expect(optionLabels(tester), <String>[
        'All',
        'Kilning',
        'Weaving',
        'Sculpting',
      ]);
      final all = tester.getRect(find.byKey(LcKeys.workflowFilterAll));
      for (final name in <String>['Kilning', 'Weaving', 'Sculpting']) {
        final other = tester.getRect(find.byKey(LcKeys.workflowFilterGroup(name)));
        expect(
          all.top,
          lessThanOrEqualTo(other.top),
          reason: '$name is offered before All',
        );
      }
    });
  });

  group('where the options come from', () {
    testWidgets('they are the catalogue\'s groups, not a list this app keeps',
        (tester) async {
      // Nothing below appears in the app, the schema or the examples. A
      // filter that offered Create/Edit/Enhance from a list of its own would
      // have nothing to say about this catalogue.
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('a', 'Kilning'),
          ('b', 'Weaving'),
          ('c', 'Sculpting'),
          ('d', 'Kilning'),
        ]),
      );

      expect(optionLabels(tester), <String>[
        'All',
        'Kilning',
        'Weaving',
        'Sculpting',
      ]);
      for (final absent in <String>['Create', 'Edit', 'Enhance', 'Video']) {
        expect(
          find.byKey(LcKeys.workflowFilterGroup(absent)),
          findsNothing,
          reason: '$absent is not in this catalogue',
        );
      }
    });

    testWidgets('a different catalogue is a different set of options',
        (tester) async {
      // The mutation this kills is a set of options computed once and kept
      // while the workflows under it change.
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('a', 'Kilning'), ('b', 'Weaving')]),
      );
      expect(optionLabels(tester), <String>['All', 'Kilning', 'Weaving']);

      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('c', 'Glazing'), ('d', 'Throwing')]),
      );

      expect(optionLabels(tester), <String>['All', 'Glazing', 'Throwing']);
      expect(shownIds(tester), <String>['c', 'd']);
    });

    testWidgets('a group the catalogue no longer has does not take the list '
        'with it', (tester) async {
      // A gateway republishing, or a reconnect to another PC, while the
      // picker is narrowed. Holding the vanished choice would leave an empty
      // list under a bar with nothing chosen in it.
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('a', 'Kilning'), ('b', 'Weaving')]),
      );
      await tapOption(tester, LcKeys.workflowFilterGroup('Kilning'));
      expect(shownIds(tester), <String>['a']);

      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('c', 'Glazing'), ('d', 'Throwing')]),
      );

      expect(chosenLabels(tester), <String>['All']);
      expect(shownIds(tester), <String>['c', 'd']);
    });
  });

  group('narrowing to one kind', () {
    /// Two kinds, and more than one workflow in each, so a filter that kept
    /// the first of a group or the first group of the list is visible here.
    List<WorkflowSummary> twoKinds() => catalogue(<(String, String?)>[
      ('kiln_one', 'Kilning'),
      ('weave_one', 'Weaving'),
      ('kiln_two', 'Kilning'),
      ('weave_two', 'Weaving'),
      ('weave_three', 'Weaving'),
    ]);

    testWidgets('shows every workflow of that kind and none of another',
        (tester) async {
      roomForEverything(tester);
      await pumpPicker(tester, twoKinds());
      // Everything this test is about to say is gone was on screen first.
      expect(shownIds(tester), <String>[
        'kiln_one',
        'kiln_two',
        'weave_one',
        'weave_two',
        'weave_three',
      ]);

      await tapOption(tester, LcKeys.workflowFilterGroup('Weaving'));

      expect(shownIds(tester), <String>[
        'weave_one',
        'weave_two',
        'weave_three',
      ]);
      for (final gone in <String>['kiln_one', 'kiln_two']) {
        expect(
          find.byKey(LcKeys.workflowCard(gone)),
          findsNothing,
          reason: gone,
        );
      }
      expect(find.byKey(LcKeys.workflowGroup('Kilning')), findsNothing);
    });

    testWidgets('the count is the narrowed list, not the catalogue',
        (tester) async {
      roomForEverything(tester);
      await pumpPicker(tester, twoKinds());
      expect(find.text('5 workflows'), findsOneWidget);

      await tapOption(tester, LcKeys.workflowFilterGroup('Kilning'));

      expect(find.text('2 workflows'), findsOneWidget);
      expect(find.text('5 workflows'), findsNothing);
      expect(shownIds(tester), <String>['kiln_one', 'kiln_two']);
    });

    testWidgets('and a card in it can still be chosen', (tester) async {
      roomForEverything(tester);
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
                    workflows: twoKinds(),
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

      await tapOption(tester, LcKeys.workflowFilterGroup('Weaving'));
      await tester.tap(find.byKey(LcKeys.workflowCard('weave_two')));
      await tester.pumpAndSettle();

      expect(chosen, 'weave_two');
    });
  });

  group('the workflows that declared no group', () {
    testWidgets('are an option of their own, under the app\'s word for them',
        (tester) async {
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('kiln_one', 'Kilning'),
          ('loose', null),
          ('kiln_two', 'Kilning'),
        ]),
      );
      // Reachable under All to begin with — which is what makes the absence
      // asserted below mean anything.
      expect(shownIds(tester), <String>['kiln_one', 'kiln_two', 'loose']);
      expect(optionLabels(tester), <String>['All', 'Kilning', 'Other']);

      await tapOption(tester, LcKeys.workflowFilterUngrouped);

      expect(shownIds(tester), <String>['loose']);
      expect(chosenLabels(tester), <String>['Other']);
      for (final gone in <String>['kiln_one', 'kiln_two']) {
        expect(find.byKey(LcKeys.workflowCard(gone)), findsNothing,
            reason: gone);
      }
    });

    testWidgets('narrowed to, they are as bare as a one-group catalogue: the '
        'Other heading is read off what is shown', (tester) async {
      // The picker decides whether the nameless section gets a heading from
      // the sections it is *drawing*, not from the catalogue behind the
      // filter. Under All there are two sections, so the heading is there —
      // which is what makes its absence below a fact about the narrowing and
      // not about a key that never matched.
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('kiln_one', 'Kilning'),
          ('loose', null),
        ]),
      );
      expect(find.byKey(LcKeys.ungroupedWorkflows), findsOneWidget);

      await tapOption(tester, LcKeys.workflowFilterUngrouped);

      expect(shownIds(tester), <String>['loose']);
      expect(
        find.byKey(LcKeys.ungroupedWorkflows),
        findsNothing,
        reason: 'one section is shown, so a heading over it is noise — the '
            'chosen option in the bar already says which kind these are',
      );
    });

    testWidgets('and do not leak into a named kind', (tester) async {
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('kiln_one', 'Kilning'),
          ('loose', null),
        ]),
      );
      expect(find.byKey(LcKeys.workflowCard('loose')), findsOneWidget);

      await tapOption(tester, LcKeys.workflowFilterGroup('Kilning'));

      expect(shownIds(tester), <String>['kiln_one']);
      expect(find.byKey(LcKeys.workflowCard('loose')), findsNothing);
    });

    testWidgets('a catalogue that really does serve a group called Other '
        'keeps two separate options', (tester) async {
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('named', 'Other'), ('loose', null)]),
      );

      // Two options reading "Other", found by two different keys: the
      // registry's own group, and the app's word for having none.
      expect(optionLabels(tester), <String>['All', 'Other', 'Other']);
      expect(find.byKey(LcKeys.workflowFilterGroup('Other')), findsOneWidget);
      expect(find.byKey(LcKeys.workflowFilterUngrouped), findsOneWidget);

      await tapOption(tester, LcKeys.workflowFilterGroup('Other'));
      expect(shownIds(tester), <String>['named']);

      await tapOption(tester, LcKeys.workflowFilterUngrouped);
      expect(shownIds(tester), <String>['loose']);
    });
  });

  group('catalogues with nothing to narrow', () {
    testWidgets('one kind is offered no filter — and two kinds are',
        (tester) async {
      // The second half is what makes the first half a guard: without it,
      // a filter that never appeared at all would pass this test.
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('a', 'Kilning'),
          ('b', 'Kilning'),
          ('c', 'Kilning'),
        ]),
      );

      expect(find.byKey(LcKeys.workflowFilter), findsNothing);
      expect(shownIds(tester), <String>['a', 'b', 'c']);
      expect(find.text('3 workflows'), findsOneWidget);

      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[
          ('a', 'Kilning'),
          ('b', 'Kilning'),
          ('c', 'Weaving'),
        ]),
      );

      expect(find.byKey(LcKeys.workflowFilter), findsOneWidget);
      expect(optionLabels(tester), <String>['All', 'Kilning', 'Weaving']);
    });

    testWidgets('a catalogue with no groups at all is offered none either',
        (tester) async {
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('a', null), ('b', null)]),
      );

      expect(find.byKey(LcKeys.workflowFilter), findsNothing);
      expect(shownIds(tester), <String>['a', 'b']);
      // And the heading stays absent too: one section, nothing to tell it
      // apart from.
      expect(find.byKey(LcKeys.ungroupedWorkflows), findsNothing);
    });

    testWidgets('an empty catalogue is exactly what it was', (tester) async {
      roomForEverything(tester);
      await pumpPicker(tester, const <WorkflowSummary>[]);

      expect(find.byKey(LcKeys.workflowPicker), findsOneWidget);
      expect(find.byKey(LcKeys.workflowFilter), findsNothing);
      expect(find.byType(WorkflowCard), findsNothing);
      // The one line the screen has always drawn over an empty list, and no
      // second empty state beside it.
      expect(find.text('0 workflows'), findsOneWidget);
      expect(find.byKey(LcKeys.ungroupedWorkflows), findsNothing);
    });
  });

  group('whose words these are', () {
    testWidgets('All is the app\'s and is translated; the groups are the '
        'gateway\'s and are not', (tester) async {
      roomForEverything(tester);
      final workflows = catalogue(<(String, String?)>[
        ('a', 'Create'),
        ('b', 'Edit'),
        ('c', null),
      ]);

      await pumpPicker(tester, workflows, locale: 'ru');

      // The two app words, in Russian; the two curator words, untouched.
      expect(optionLabels(tester), <String>[
        'Все',
        'Create',
        'Edit',
        'Прочее',
      ]);
      expect(chosenLabels(tester), <String>['Все']);

      await pumpPicker(tester, workflows);

      expect(optionLabels(tester), <String>['All', 'Create', 'Edit', 'Other']);
    });

    testWidgets('and the Russian filter narrows the same way', (tester) async {
      roomForEverything(tester);
      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('a', 'Create'), ('b', 'Edit')]),
        locale: 'ru',
      );
      expect(shownIds(tester), <String>['a', 'b']);

      await tapOption(tester, LcKeys.workflowFilterGroup('Edit'));
      expect(shownIds(tester), <String>['b']);

      await tapOption(tester, LcKeys.workflowFilterAll);
      expect(shownIds(tester), <String>['a', 'b']);
    });
  });

  group('more options than fit', () {
    /// Every line of text under [root] laid out outside [root]'s own
    /// rectangle.
    ///
    /// **Geometry, not an overflow report**, for the reason T-0154's file
    /// gives: a `RenderFlex` announces its own overflow and a `RenderWrap`
    /// announces nothing at all, so a guard that asked only for overflowing
    /// flexes would go quiet the moment the layout changed — it would be
    /// certifying this bar by the very mechanism that keeps it whole.
    ///
    /// **Text and not every box**, which is a narrowing with a reason and not
    /// a convenience. A Material chip lays its check mark out to the *left* of
    /// itself while it is not the chosen one — a 36dp square at x = -11 that
    /// is never painted — so a walk over every render box reports twelve
    /// spills on a bar that is perfectly intact. What a person can actually
    /// lose is a word, so words are what is asked about; the chips themselves
    /// are checked whole, by their own rectangles, where this helper is used.
    List<RenderParagraph> spillingText(RenderBox root) {
      final Rect bounds = root.localToGlobal(Offset.zero) & root.size;
      final spilled = <RenderParagraph>[];
      void visit(RenderObject node) {
        if (node is RenderParagraph && node.hasSize) {
          final Rect rect = node.localToGlobal(Offset.zero) & node.size;
          if (rect.left < bounds.left - 0.5 ||
              rect.right > bounds.right + 0.5 ||
              rect.top < bounds.top - 0.5 ||
              rect.bottom > bounds.bottom + 0.5) {
            spilled.add(node);
          }
        }
        node.visitChildren(visit);
      }

      visit(root);
      return spilled;
    }

    /// Every `RenderFlex` under [root] that is reporting an overflow —
    /// `toStringShort` appends `OVERFLOWING` while its own overflow is past
    /// the framework's tolerance, which is the same condition that draws the
    /// yellow-and-black banner.
    List<String> overflowing(RenderObject root) {
      final found = <String>[];
      void visit(RenderObject node) {
        if (node is RenderFlex && node.toStringShort().contains('OVERFLOWING')) {
          found.add(node.toStringShort());
        }
        node.visitChildren(visit);
      }

      visit(root);
      return found;
    }

    /// Whether [inner] lies within [outer], edges included.
    ///
    /// `Rect.contains` is exclusive on the right and the bottom, so a chip
    /// flush with the bottom of the bar — which the last row always is — would
    /// read as being outside it.
    bool within(Rect outer, Rect inner) =>
        inner.left >= outer.left - 0.5 &&
        inner.right <= outer.right + 0.5 &&
        inner.top >= outer.top - 0.5 &&
        inner.bottom <= outer.bottom + 0.5;

    /// Every option's rectangle, by key, so a chip can be checked whole.
    Map<String, Rect> optionRects(WidgetTester tester, List<String> groups) =>
        <String, Rect>{
          'All': tester.getRect(find.byKey(LcKeys.workflowFilterAll)),
          for (final name in groups)
            name: tester.getRect(find.byKey(LcKeys.workflowFilterGroup(name))),
        };

    /// Twelve kinds — a catalogue no narrower than a real catalogue, with
    /// far more groups than a folded phone can put on one line.
    List<WorkflowSummary> twelveKinds() => catalogue(<(String, String?)>[
      for (var i = 0; i < 12; i++) ('w$i', 'Kind $i'),
    ]);

    testWidgets('take another line instead of overflowing, at 320dp and a 2.0 '
        'text scale', (tester) async {
      tester.view.physicalSize = const Size(320, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpPicker(tester, twelveKinds());

      // Every option is there — nothing was dropped to make it fit.
      expect(optionLabels(tester), <String>[
        'All',
        for (var i = 0; i < 12; i++) 'Kind $i',
      ]);
      final barFinder = find.byKey(LcKeys.workflowFilter);
      final bar = tester.renderObject<RenderBox>(barFinder);
      final Rect barRect = tester.getRect(barFinder);
      // The bar is inside the screen it was drawn on.
      expect(barRect.left, greaterThanOrEqualTo(0));
      expect(barRect.right, lessThanOrEqualTo(320));
      // Every option is inside the bar, whole.
      final rects = optionRects(tester, <String>[
        for (var i = 0; i < 12; i++) 'Kind $i',
      ]);
      rects.forEach((name, rect) {
        expect(
          within(barRect, rect),
          isTrue,
          reason: '$name is drawn at $rect, outside the bar at $barRect',
        );
      });
      expect(
        spillingText(bar).map((p) => p.text.toPlainText()).toList(),
        isEmpty,
        reason: 'a label is laid out outside the filter bar',
      );
      expect(overflowing(bar), isEmpty);
      // It really did run out of room — otherwise nothing above was tested.
      final rows = rects.values.map((rect) => rect.top).toSet();
      expect(
        rows.length,
        greaterThan(1),
        reason: 'thirteen options fitted on one line, so nothing wrapped',
      );
    });

    testWidgets('and an option on the last row still narrows the list',
        (tester) async {
      // Wrapping that put an option somewhere unusable would satisfy every
      // geometric check above.
      tester.view.physicalSize = const Size(320, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPicker(tester, twelveKinds());
      // Twelve in the list, the first of them at the top of the scroll — and
      // the twelfth so far below it that this is the whole point of the
      // exercise. What is asserted before the tap is therefore the list's
      // length and its beginning; the cards past the viewport are not laid
      // out, and claiming anything about them from here would be claiming it
      // about the viewport.
      expect(find.text('12 workflows'), findsOneWidget);
      expect(shownIds(tester).first, 'w0');

      await tapOption(tester, LcKeys.workflowFilterGroup('Kind 11'));

      expect(shownIds(tester), <String>['w11']);
      expect(find.text('1 workflow'), findsOneWidget);
      expect(chosenLabels(tester), <String>['Kind 11']);
    });

    testWidgets('a group name wider than the option wraps rather than fading '
        'a word away', (tester) async {
      // A chip's own label style is `maxLines: 1, softWrap: false,
      // TextOverflow.fade`, and a group name is the curator's prose of
      // whatever length they wrote. The mutation this kills is the label
      // built as a plain `Text`, which looks perfectly fine and is missing
      // its end.
      const String long = 'Kilning and glazing pots';
      tester.view.physicalSize = const Size(320, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpPicker(
        tester,
        catalogue(<(String, String?)>[('a', long), ('b', 'Weaving')]),
      );

      final option = find.byKey(LcKeys.workflowFilterGroup(long));
      expect(option, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: option, matching: find.byType(Text)),
      );
      // Measured independently of the widget's own settings: the very span
      // and scaler it was laid out with, handed to a painter that has no line
      // limit and no ellipsis, offered the same width.
      final painter = TextPainter(
        text: paragraph.text,
        textDirection: paragraph.textDirection,
        textScaler: paragraph.textScaler,
      )..layout(maxWidth: paragraph.constraints.maxWidth);
      final lines = painter.computeLineMetrics();
      addTearDown(painter.dispose);
      // The name really is wider than the option — otherwise nothing below
      // is being tested.
      expect(
        lines.length,
        greaterThan(1),
        reason: 'the name fitted on one line at 320dp, so it never wrapped',
      );
      // And what is on screen is the whole of it.
      expect(
        painter.height,
        lessThanOrEqualTo(paragraph.size.height + 0.5),
        reason: 'the label is drawn shorter than its text needs — its end is '
            'faded or cut',
      );
      for (final line in lines) {
        expect(
          line.width,
          lessThanOrEqualTo(paragraph.constraints.maxWidth + 0.5),
        );
      }
      final bar = tester.renderObject<RenderBox>(
        find.byKey(LcKeys.workflowFilter),
      );
      expect(spillingText(bar), isEmpty);
      expect(
        within(
          tester.getRect(find.byKey(LcKeys.workflowFilter)),
          tester.getRect(option),
        ),
        isTrue,
      );
      // And it is still an option: it narrows.
      await tapOption(tester, LcKeys.workflowFilterGroup(long));
      expect(shownIds(tester), <String>['a']);
    });
  });
}
