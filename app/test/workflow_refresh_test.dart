/// New workflows appear without reconnecting (T-0017).
///
/// The user imports a workflow on the PC while the phone is connected. Two
/// ways for it to reach the phone, and both are driven here:
///
/// * **Refresh in the picker** — a person asking;
/// * **coming back to the app** — once, quietly, only when connected, only when
///   no reconnect is running and only when the list is older than the bound.
///
/// What neither may do is the one thing reusing `reload()` would have done:
/// pass through `RegistryPhase.loading`, which the shell draws as a spinner in
/// place of the chosen workflow and its form. So every test that refreshes
/// with a form on screen asserts the typed words are still there, and the ones
/// that hold the request open assert the form is on screen *while* it runs.
///
/// Requests are counted on the fake rather than inferred from what the screen
/// shows, so "asked nothing" cannot be passed by a request whose answer
/// happened to change nothing.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/app.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/session_controller.dart';
import 'package:localcanvas/l10n/accept_language.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/ui/workflows/workflow_picker.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

/// A gateway whose list the test changes between requests, and can hold open.
///
/// What a request answers is read **when the request is made**, not when it is
/// let through — so a held request carries the list the PC had at that moment,
/// which is what makes "an older answer arriving late" expressible at all.
class ReReadableRegistry implements WorkflowsApi {
  ReReadableRegistry({required this.summaries, required this.details});

  List<WorkflowSummary> summaries;
  final Map<String, WorkflowDetail> details;

  /// The next list request fails with this, while it is set.
  WorkflowsFailure? listFailure;

  /// Holds the *next* list request until completed. Taken by that request, so
  /// the one after it answers at once.
  Completer<void>? hold;

  int listCalls = 0;

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async {
    listCalls++;
    final answer = summaries;
    final failure = listFailure;
    final gate = hold;
    hold = null;
    if (gate != null) await gate.future;
    if (failure != null) throw failure;
    return answer;
  }

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) async {
    final detail = details[workflowId];
    if (detail == null) {
      throw const WorkflowsFailure.refused(code: 'workflow_not_found');
    }
    return detail;
  }
}

/// A gateway that says yes — and, while [hold] is set, says it only when the
/// test lets it. That is a reconnect in progress, for as long as the test
/// needs one.
class HoldableGatewayClient implements GatewayClient {
  Completer<void>? hold;
  int handshakes = 0;

  @override
  Duration get timeout => const Duration(seconds: 4);

  @override
  LanguageTagSource get language => () => kFallbackLanguageTag;

  @override
  Future<HandshakeOutcome> handshake(Endpoint endpoint) async {
    handshakes++;
    final gate = hold;
    if (gate != null) await gate.future;
    return HandshakeSucceeded(endpoint, testIdentity());
  }

  @override
  void dispose() {}
}

void main() {
  final studio = Endpoint.tryParse('192.0.2.42')!;

  /// What the user typed, and what must still be there afterwards.
  const typed = 'a lighthouse the PC has only just heard of';

  const txt2img = 'example_txt2img';
  const img2img = 'example_img2img';
  const importedId = 'imported_on_the_pc';

  Map<String, Object?> imported() => renamed(
    txt2imgDetail(),
    id: importedId,
    name: 'Imported On The PC',
  );

  List<WorkflowSummary> listOf(List<Map<String, Object?>> details) =>
      WorkflowSummary.listFromJson(registryOf(details));

  /// A PC serving txt2img and img2img, that *knows* the imported workflow's
  /// schema but does not list it until a test says it was imported.
  ReReadableRegistry pc() => ReReadableRegistry(
    summaries: listOf(<Map<String, Object?>>[txt2imgDetail(), img2imgDetail()]),
    details: <String, WorkflowDetail>{
      for (final body in <Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
        imported(),
      ])
        body['id']! as String: WorkflowDetail.tryFromJson(body)!,
    },
  );

  void importOn(ReReadableRegistry api) => api.summaries = listOf(
    <Map<String, Object?>>[txt2imgDetail(), img2imgDetail(), imported()],
  );

  void removeChosenOn(ReReadableRegistry api) =>
      api.summaries = listOf(<Map<String, Object?>>[img2imgDetail()]);

  Object? promptIn(WorkflowsController controller, String workflowId) {
    // Read out of the controller's own form, not off the screen, so a test that
    // also finds the words on screen has checked both.
    final selected = controller.selectedId;
    if (selected == workflowId) {
      return controller.form!.currentDraft().values['prompt'];
    }
    fail('$workflowId is not the chosen workflow (chosen: $selected)');
  }

  group('the controller: a refresh that never leaves ready', () {
    late ReReadableRegistry api;
    late WorkflowsController controller;

    setUp(() async {
      api = pc();
      controller = WorkflowsController(api: api);
      await controller.load(studio);
      await controller.select(txt2img);
      controller.form!.setEntry('prompt', typed);
    });

    tearDown(() => controller.dispose());

    test('brings the new workflow, and keeps the chosen one, its form and its '
        'words', () async {
      final form = controller.form;
      importOn(api);
      final phases = <RegistryPhase>[];
      controller.addListener(() => phases.add(controller.phase));

      final failure = await controller.refresh();

      expect(failure, isNull);
      expect(api.listCalls, 2);
      expect(
        controller.workflows.map((w) => w.id),
        <String>[txt2img, img2img, importedId],
      );
      expect(controller.selectedId, txt2img);
      expect(identical(controller.form, form), isTrue);
      expect(promptIn(controller, txt2img), typed);
      expect(controller.missingSelection, isNull);
      // Every notification it made was made in ready — the spinner the shell
      // draws for loading was never asked for.
      expect(phases, isNotEmpty);
      expect(phases, everyElement(RegistryPhase.ready));
    });

    test('says it is running while it runs, and a second one is not started',
        () async {
      importOn(api);
      final gate = api.hold = Completer<void>();

      final pending = controller.refresh();
      expect(controller.isRefreshing, isTrue);
      expect(controller.phase, RegistryPhase.ready);
      expect(controller.workflows, hasLength(2), reason: 'the old list stays');
      expect(controller.form, isNotNull);

      expect(await controller.refresh(), isNull);
      expect(api.listCalls, 2, reason: 'one refresh request, not two');

      // The gate was taken by the request it held, so it is completed through
      // the test's own reference to it.
      gate.complete();
      await pending;
      expect(controller.isRefreshing, isFalse);
      expect(controller.workflows, hasLength(3));
    });

    test('a chosen workflow the PC stopped serving is reported, and its words '
        'are kept for when it comes back', () async {
      removeChosenOn(api);

      await controller.refresh();

      expect(controller.missingSelection, 'Example Text to Image');
      expect(controller.selectedId, isNull);
      expect(controller.phase, RegistryPhase.ready);

      // Served again, and chosen again: the same words, because the form was
      // kept rather than disposed.
      importOn(api);
      await controller.refresh();
      await controller.select(txt2img);
      expect(promptIn(controller, txt2img), typed);
    });

    test('a failure is returned, and changes nothing', () async {
      api.listFailure = const WorkflowsFailure.unreachable();

      final failure = await controller.refresh();

      expect(failure, const WorkflowsFailure.unreachable());
      expect(controller.phase, RegistryPhase.ready);
      expect(controller.failure, isNull, reason: 'not the registry failure');
      expect(controller.workflows, hasLength(2));
      expect(controller.selectedId, txt2img);
      expect(promptIn(controller, txt2img), typed);
      expect(controller.isRefreshing, isFalse);
    });

    test('an answer overtaken by a reload is dropped when it arrives', () async {
      // The refresh asks while the PC serves three...
      importOn(api);
      final gate = api.hold = Completer<void>();
      final pending = controller.refresh();
      // ...and a reconnect's reload asks after the PC went back to two.
      api.summaries = listOf(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await controller.reload();
      expect(controller.workflows, hasLength(2));
      expect(controller.isRefreshing, isFalse);

      gate.complete();
      await pending;

      expect(controller.workflows, hasLength(2), reason: 'the newer answer');
      expect(controller.isRefreshing, isFalse);
    });

    test('a registry that is not ready is not refreshed', () async {
      api.listFailure = const WorkflowsFailure.unreachable();
      await controller.reload();
      expect(controller.phase, RegistryPhase.failed);
      final before = api.listCalls;

      expect(await controller.refresh(), isNull);

      expect(api.listCalls, before);
      expect(controller.phase, RegistryPhase.failed);
    });
  });

  group('the controller: the bound on a return', () {
    late ReReadableRegistry api;
    late WorkflowsController controller;
    late DateTime now;

    setUp(() async {
      api = pc();
      now = DateTime(2026, 9, 16, 12);
      controller = WorkflowsController(api: api, clock: () => now);
    });

    tearDown(() => controller.dispose());

    test('the bound is a minute', () {
      expect(kRegistryStaleAfter, const Duration(minutes: 1));
      expect(controller.registryStaleAfter, kRegistryStaleAfter);
    });

    test('a list that never arrived is not refreshed', () async {
      now = now.add(const Duration(hours: 1));
      await controller.refreshIfStale();
      expect(api.listCalls, 0);
    });

    test('younger than the bound asks nothing; at the bound asks once',
        () async {
      await controller.load(studio);
      expect(api.listCalls, 1);

      now = now.add(const Duration(seconds: 59));
      await controller.refreshIfStale();
      expect(api.listCalls, 1);

      now = now.add(const Duration(seconds: 1));
      await controller.refreshIfStale();
      expect(api.listCalls, 2);

      // Counted from that answer now, not from the launch.
      now = now.add(const Duration(seconds: 30));
      await controller.refreshIfStale();
      expect(api.listCalls, 2);
    });

    test('a failed one is silent, and does not count as a load', () async {
      await controller.load(studio);
      now = now.add(const Duration(minutes: 2));
      api.listFailure = const WorkflowsFailure.unreachable();

      await controller.refreshIfStale();

      expect(api.listCalls, 2);
      expect(controller.phase, RegistryPhase.ready);
      expect(controller.failure, isNull);
      expect(controller.workflows, hasLength(2));

      // The last *successful* load is still two minutes old.
      api.listFailure = null;
      await controller.refreshIfStale();
      expect(api.listCalls, 3);
    });
  });

  // Adapted from the second review's scratch group "listArrivals and the picker
  // failure card (r2)" (T-0017, 2026-09-16), onto this file's own gateway fake.
  group('what counts as a list arriving', () {
    test('a failed, refused or overtaken-before-its-answer request leaves the '
        'count; every list that arrives grows it by one', () async {
      final api = pc();
      final controller = WorkflowsController(api: api);
      addTearDown(controller.dispose);
      expect(controller.listArrivals, 0);

      api.listFailure = const WorkflowsFailure.unreachable();
      await controller.load(studio);
      expect(controller.phase, RegistryPhase.failed);
      expect(controller.listArrivals, 0, reason: 'a failed load');

      api.listFailure = null;
      await controller.reload();
      expect(controller.listArrivals, 1, reason: 'a reload that arrived');

      api.listFailure = const WorkflowsFailure.unreachable();
      expect(await controller.refresh(), isNotNull);
      expect(controller.listArrivals, 1, reason: 'a failed refresh');

      // A refresh that will answer with a list, held...
      api.listFailure = null;
      final gate = api.hold = Completer<void>();
      final overtaken = controller.refresh();
      expect(await controller.refresh(), isNull);
      expect(controller.listArrivals, 1, reason: 'a refused refresh');

      // ...overtaken by a reload that fails...
      api.listFailure = const WorkflowsFailure.unreachable();
      await controller.reload();
      expect(controller.phase, RegistryPhase.failed);
      expect(controller.listArrivals, 1, reason: 'a failed reload');

      // ...and let through afterwards: its list is dropped, and not counted.
      api.listFailure = null;
      gate.complete();
      expect(await overtaken, isNull);
      expect(controller.listArrivals, 1, reason: 'an overtaken refresh');

      expect(await controller.refresh(), isNull);
      expect(controller.listArrivals, 1, reason: 'refused: phase is failed');

      await controller.reload();
      expect(controller.listArrivals, 2);
      expect(await controller.refresh(), isNull);
      expect(controller.listArrivals, 3);
    });
  });

  // Adapted from the independent review's scratch group of the same name
  // (T-0017 review, 2026-09-16). A refresh re-checks chosen media exactly as
  // the reconnect's reload does (`MediaFieldController.restoreSelection`):
  // an uploaded or uploading choice is left alone, and one that never uploaded
  // is kept while its file is there and dropped when it is gone. Both
  // directions are driven, so neither "the re-check never runs" nor "a refresh
  // throws the pictures away" can pass.
  group('chosen media on a refresh', () {
    late ReReadableRegistry api;
    late WorkflowsController controller;
    late ScriptedMediaPicker picker;
    late ScriptedMediaApi uploads;

    setUp(() async {
      api = pc();
      picker = ScriptedMediaPicker();
      uploads = ScriptedMediaApi();
      controller = WorkflowsController(
        api: api,
        mediaPicker: picker,
        mediaApi: uploads,
      );
      await controller.load(studio);
      await controller.select(img2img);
    });

    tearDown(() => controller.dispose());

    MediaFieldController sourceImage() =>
        controller.form!.media('source_image')!;

    test('an uploaded picture is kept, even once its file is gone', () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      final media = sourceImage();
      await media.choose();
      expect(media.phase, MediaPhase.ready);
      final uploaded = media.mediaId;
      expect(uploaded, isNotNull);
      File((selection.source as FileMediaSource).path).deleteSync();

      expect(await controller.refresh(), isNull);

      expect(media.phase, MediaPhase.ready);
      expect(media.mediaId, uploaded);
      expect(media.selection, isNotNull);
    });

    test('a picture still uploading is left to finish, uploaded once',
        () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      uploads.manual = true;
      final media = sourceImage();
      final choosing = media.choose();
      await pumpEventQueue();
      expect(media.phase, MediaPhase.uploading);

      expect(await controller.refresh(), isNull);

      expect(media.phase, MediaPhase.uploading);
      expect(identical(media.selection, selection), isTrue);
      uploads.finish();
      await choosing;
      expect(media.phase, MediaPhase.ready);
      expect(media.mediaId, isNotNull);
      expect(uploads.calls, 1);
    });

    test('a picture that never uploaded is kept while its file is there',
        () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      uploads.failure = const MediaFailure.unreachable();
      final media = sourceImage();
      await media.choose();
      expect(media.phase, MediaPhase.failed);

      expect(await controller.refresh(), isNull);

      expect(identical(media.selection, selection), isTrue);
      expect(media.phase, isNot(MediaPhase.empty));
    });

    test('...and dropped once its file is gone: the re-check runs', () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      uploads.failure = const MediaFailure.unreachable();
      final media = sourceImage();
      await media.choose();
      expect(media.selection, isNotNull);
      File((selection.source as FileMediaSource).path).deleteSync();

      expect(await controller.refresh(), isNull);

      expect(media.phase, MediaPhase.empty);
      expect(media.selection, isNull);
    });
  });

  group('Refresh in the picker', () {
    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<(ReReadableRegistry, WorkflowsController)> shell(
      WidgetTester tester,
    ) async {
      tallView(tester);
      final api = pc();
      final workflows = WorkflowsController(api: api);
      addTearDown(workflows.dispose);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(studio);
      final session = testSession(connection: connection, workflows: workflows);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(session: session),
        ),
      );
      await tester.pumpAndSettle();
      return (api, workflows);
    }

    /// Chooses txt2img, types into it, and opens the picker over it.
    Future<void> typeThenOpenPicker(WidgetTester tester) async {
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard(txt2img)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(LcKeys.field('prompt')), typed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.changeWorkflow));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.workflowPicker), findsOneWidget);
    }

    IconButton refreshButton(WidgetTester tester) =>
        tester.widget<IconButton>(find.byKey(LcKeys.workflowsRefresh));

    testWidgets('shows a workflow imported on the PC, and the form keeps the '
        'chosen workflow and its words', (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      importOn(api);

      expect(find.byKey(LcKeys.workflowCard(importedId)), findsNothing);
      expect(refreshButton(tester).tooltip, en.workflowsRefresh);
      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowCard(importedId)), findsOneWidget);
      expect(find.text(en.workflowCount(3)), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(workflows.selectedId, txt2img);
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.text(typed), findsOneWidget);
      expect(promptIn(workflows, txt2img), typed);
    });

    testWidgets('a chosen workflow removed on the PC is reported as missing',
        (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      removeChosenOn(api);

      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowCard(txt2img)), findsNothing);
      expect(workflows.missingSelection, 'Example Text to Image');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.missingWorkflow), findsOneWidget);
      expect(
        find.text(en.missingWorkflowTitle('Example Text to Image')),
        findsOneWidget,
      );
    });

    testWidgets('is unavailable while it runs, and the list stays on screen',
        (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      importOn(api);
      final gate = api.hold = Completer<void>();
      expect(refreshButton(tester).onPressed, isNotNull);

      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pump();

      expect(workflows.isRefreshing, isTrue);
      expect(refreshButton(tester).onPressed, isNull);
      expect(find.byKey(LcKeys.workflowCard(txt2img)), findsOneWidget);
      expect(find.byKey(LcKeys.workflowCard(img2img)), findsOneWidget);
      expect(find.text(en.workflowCount(2)), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(refreshButton(tester).onPressed, isNotNull);
      expect(find.byKey(LcKeys.workflowCard(importedId)), findsOneWidget);
    });

    testWidgets('a failure is said above the list it kept, and that list can '
        'still be chosen from', (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      api.listFailure = const WorkflowsFailure.unreachable();

      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsOneWidget);
      expect(find.text(en.serverDidntAnswerTitle), findsOneWidget);
      expect(find.text(en.serverUnreachableMessage), findsOneWidget);
      expect(find.byKey(LcKeys.workflowCard(txt2img)), findsOneWidget);
      expect(find.byKey(LcKeys.workflowCard(img2img)), findsOneWidget);
      expect(refreshButton(tester).onPressed, isNotNull);

      await tester.tap(find.byKey(LcKeys.workflowCard(img2img)));
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowPicker), findsNothing);
      expect(workflows.selectedId, img2img);
    });

    testWidgets('Try again asks again, and a success takes the failure away',
        (tester) async {
      final (api, _) = await shell(tester);
      await typeThenOpenPicker(tester);
      api.listFailure = const WorkflowsFailure.unreachable();
      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsOneWidget);
      final before = api.listCalls;

      api.listFailure = null;
      importOn(api);
      await tester.tap(find.byKey(LcKeys.workflowsRefreshRetry));
      await tester.pumpAndSettle();

      expect(api.listCalls, before + 1);
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsNothing);
      expect(find.byKey(LcKeys.workflowCard(importedId)), findsOneWidget);
    });

    /// Presses Refresh against a PC that does not answer, and checks the card.
    Future<void> failOnce(WidgetTester tester, ReReadableRegistry api) async {
      api.listFailure = const WorkflowsFailure.unreachable();
      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsOneWidget);
    }

    testWidgets('the failure goes when the app\'s own quiet refresh reads the '
        'list, and not before', (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      await failOnce(tester, api);

      // A quiet refresh that fails too changes nothing: the card is still true.
      unawaited(workflows.refresh());
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsOneWidget);

      // The same refresh coming back to the app makes, and this time it works.
      api.listFailure = null;
      importOn(api);
      unawaited(workflows.refresh());
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsNothing);
      expect(find.byKey(LcKeys.workflowCard(importedId)), findsOneWidget);
    });

    testWidgets('the failure goes when a reconnect\'s reload reads the list',
        (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      await failOnce(tester, api);

      api.listFailure = null;
      importOn(api);
      unawaited(workflows.reload());
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowPicker), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsNothing);
      expect(find.byKey(LcKeys.workflowCard(importedId)), findsOneWidget);
    });

    testWidgets('a reconnect\'s reload that FAILS leaves the failure card',
        (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      await failOnce(tester, api);

      // Still not answering: the card is still true.
      unawaited(workflows.reload());
      await tester.pumpAndSettle();

      expect(workflows.phase, RegistryPhase.failed);
      expect(find.byKey(LcKeys.workflowPicker), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsOneWidget);
    });

    testWidgets('the card comes back each time a pressed Refresh fails again, '
        'however it was cleared', (tester) async {
      final (api, workflows) = await shell(tester);
      await typeThenOpenPicker(tester);
      final card = find.byKey(LcKeys.workflowsRefreshFailed);
      await failOnce(tester, api);

      // Cleared by the quiet refresh...
      api.listFailure = null;
      unawaited(workflows.refresh());
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      // ...and back when the next press fails.
      await failOnce(tester, api);

      // Cleared by a reconnect's reload...
      api.listFailure = null;
      unawaited(workflows.reload());
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      // ...and back again.
      await failOnce(tester, api);
      expect(card, findsOneWidget);
    });

    testWidgets('the card is hidden while the next press runs, and back if it '
        'fails too', (tester) async {
      final (api, _) = await shell(tester);
      await typeThenOpenPicker(tester);
      final card = find.byKey(LcKeys.workflowsRefreshFailed);
      await failOnce(tester, api);

      final gate = api.hold = Completer<void>();
      await tester.tap(find.byKey(LcKeys.workflowsRefresh));
      await tester.pump();
      expect(card, findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
    });

    testWidgets('a picker over a fixed list offers no Refresh', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: WorkflowPickerScreen(
            workflows: listOf(<Map<String, Object?>>[txt2imgDetail()]),
            selectedId: null,
            detailLoader: (_) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowCard(txt2img)), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsRefresh), findsNothing);
    });
  });

  group('coming back to the app', () {
    /// The whole app, so the lifecycle callback is the real one.
    Future<
      (
        ReReadableRegistry,
        WorkflowsController,
        ConnectionController,
        SessionController,
        HoldableGatewayClient,
        void Function(Duration),
      )
    >
    launch(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var now = DateTime(2026, 9, 16, 12);
      final api = pc();
      final workflows = WorkflowsController(api: api, clock: () => now);
      addTearDown(workflows.dispose);
      final client = HoldableGatewayClient();
      final connection = ConnectionController(
        client: client,
        store: InMemoryEndpointStore(
          RememberedServer(
            endpoint: studio,
            displayName: 'Studio PC',
            lastSuccess: DateTime.utc(2026),
          ),
        ),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      final session = testSession(connection: connection, workflows: workflows);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        LocalCanvasApp(
          session: session,
          appearance: testAppearance(),
          language: testLanguage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(connection.phase, ConnectionPhase.connected);

      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard(txt2img)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(LcKeys.field('prompt')), typed);
      await tester.pumpAndSettle();

      return (
        api,
        workflows,
        connection,
        session,
        client,
        (Duration by) => now = now.add(by),
      );
    }

    /// Away and back, through the states Android actually passes through —
    /// **one at a time**, with the request count checked after each.
    ///
    /// Every state before [AppLifecycleState.resumed] must ask nothing: the
    /// list worth reading is the one the PC has when the person *comes back*,
    /// and a re-read fired on the way out (at `paused`, say) would read it
    /// before anything was imported and leave nothing to read it on return.
    /// Fired in one burst, that mistake and the right answer produce the same
    /// count at the end. The caller checks what `resumed` did.
    Future<void> leaveAndReturn(
      WidgetTester tester,
      ReReadableRegistry api,
    ) async {
      final before = api.listCalls;
      for (final state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(api.listCalls, before, reason: '$state must ask nothing');
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('after the bound: the list is read once, with the form on '
        'screen the whole time', (tester) async {
      final (api, workflows, _, _, _, advance) = await launch(tester);
      final before = api.listCalls;
      importOn(api);
      final gate = api.hold = Completer<void>();
      advance(const Duration(minutes: 1, seconds: 1));

      await leaveAndReturn(tester, api);
      await tester.pump();

      expect(api.listCalls, before + 1);
      // While it is still waiting on the PC: nothing blanked.
      expect(workflows.isRefreshing, isTrue);
      expect(find.byKey(LcKeys.workflowsLoading), findsNothing);
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.text(typed), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(api.listCalls, before + 1, reason: 'once, not on a timer');
      expect(workflows.workflows.map((w) => w.id), contains(importedId));
      expect(workflows.selectedId, txt2img);
      expect(find.text(typed), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('before the bound: nothing is asked', (tester) async {
      final (api, _, _, _, _, advance) = await launch(tester);
      final before = api.listCalls;
      advance(const Duration(seconds: 59));

      await leaveAndReturn(tester, api);
      await tester.pumpAndSettle();

      expect(api.listCalls, before);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a failed one says nothing and replaces nothing',
        (tester) async {
      final (api, workflows, _, _, _, advance) = await launch(tester);
      final before = api.listCalls;
      api.listFailure = const WorkflowsFailure.unreachable();
      advance(const Duration(minutes: 5));

      await leaveAndReturn(tester, api);
      await tester.pumpAndSettle();

      expect(api.listCalls, before + 1);
      expect(workflows.phase, RegistryPhase.ready);
      expect(find.byKey(LcKeys.workflowsFailed), findsNothing);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.text(typed), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('not connected: nothing is asked', (tester) async {
      final (api, workflows, connection, _, _, advance) = await launch(tester);
      unawaited(connection.chooseAnotherServer());
      await tester.pumpAndSettle();
      expect(connection.phase, ConnectionPhase.needsServer);
      // The registry still has a server and a ready list, so the refresh
      // itself would ask — this is the connection check and nothing else.
      expect(workflows.phase, RegistryPhase.ready);
      final before = api.listCalls;
      advance(const Duration(minutes: 5));

      await leaveAndReturn(tester, api);
      await tester.pumpAndSettle();

      expect(api.listCalls, before);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('while a reconnect runs: nothing is asked beside it',
        (tester) async {
      final (api, workflows, _, session, client, advance) = await launch(
        tester,
      );
      final gate = client.hold = Completer<void>();
      unawaited(session.reconnect());
      await tester.pump();
      expect(session.isReconnecting, isTrue);
      expect(workflows.phase, RegistryPhase.ready);
      final before = api.listCalls;
      advance(const Duration(minutes: 5));

      await leaveAndReturn(tester, api);
      await tester.pump();

      expect(api.listCalls, before);

      client.hold = null;
      gate.complete();
      await tester.pumpAndSettle();
      expect(session.isReconnecting, isFalse);
      // The reconnect's own re-read, and only that.
      expect(api.listCalls, before + 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
