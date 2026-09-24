/// Refresh on an empty workflow list (T-0235).
///
/// A server publishing nothing shows the empty state, and the picker — with the
/// Refresh T-0017 gave it — cannot be reached from there. So the empty state
/// offers the same `WorkflowsController.refresh()` itself.
///
/// Requests are counted on the fake, and the refresh is held open where a test
/// needs to look at the screen while it runs: "Refresh reads the list again
/// without leaving ready" is told apart from "Refresh reloads" by what is on
/// screen and which phase the registry is in *during* the request, not by the
/// answer, which is the same either way.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
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
import 'support/workflow_payloads.dart';

/// A PC whose published list the test changes, and whose next list request
/// the test can hold open. What a request answers is read when it is made.
class EmptyThenImporting implements WorkflowsApi {
  List<WorkflowSummary> summaries = const <WorkflowSummary>[];
  final Map<String, WorkflowDetail> details = <String, WorkflowDetail>{
    'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
  };

  WorkflowsFailure? listFailure;
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

  void importOnThePc() => summaries = WorkflowSummary.listFromJson(
    registryOf(<Map<String, Object?>>[txt2imgDetail()]),
  );
}

void main() {
  final studio = Endpoint.tryParse('192.0.2.42')!;

  test('an empty list that arrived is ready, so refresh() asks again', () async {
    // The precondition the empty state's Refresh stands on, measured rather
    // than assumed: refresh() is refused anywhere but ready.
    final api = EmptyThenImporting();
    final controller = WorkflowsController(api: api);
    addTearDown(controller.dispose);
    await controller.load(studio);
    expect(controller.phase, RegistryPhase.ready);
    expect(controller.workflows, isEmpty);

    api.importOnThePc();
    expect(await controller.refresh(), isNull);

    expect(api.listCalls, 2);
    expect(controller.workflows, hasLength(1));
  });

  group('Refresh on the empty workflow list', () {
    Future<(EmptyThenImporting, WorkflowsController)> shell(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = EmptyThenImporting();
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
      expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);
      expect(api.listCalls, 1);
      return (api, workflows);
    }

    Finder refresh() => find.descendant(
      of: find.byKey(LcKeys.workflowsEmptyState),
      matching: find.byKey(LcKeys.workflowsRefresh),
    );

    ButtonStyleButton refreshButton(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(refresh());

    testWidgets('sits beside Choose another server, in the picker\'s words',
        (tester) async {
      await shell(tester);

      expect(refresh(), findsOneWidget);
      expect(
        find.descendant(of: refresh(), matching: find.text(en.workflowsRefresh)),
        findsOneWidget,
      );
      expect(find.text(en.chooseAnotherServer), findsOneWidget);
    });

    testWidgets('asks the list again through refresh(), never leaving ready',
        (tester) async {
      final (api, workflows) = await shell(tester);
      final gate = api.hold = Completer<void>();

      await tester.tap(refresh());
      await tester.pump();

      expect(api.listCalls, 2, reason: 'one request, made by the tap');
      // What tells refresh() from reload(): the phase stays ready, the refresh
      // says it is running, and the empty state stays on screen meanwhile.
      expect(workflows.phase, RegistryPhase.ready);
      expect(workflows.isRefreshing, isTrue);
      expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsLoading), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(workflows.isRefreshing, isFalse);
      expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);
    });

    testWidgets('is unavailable while it runs, and available again after',
        (tester) async {
      final (api, _) = await shell(tester);
      expect(refreshButton(tester).onPressed, isNotNull);
      final gate = api.hold = Completer<void>();

      await tester.tap(refresh());
      await tester.pump();

      expect(refreshButton(tester).onPressed, isNull);
      // A second tap while it runs asks nothing.
      await tester.tap(refresh(), warnIfMissed: false);
      await tester.pump();
      expect(api.listCalls, 2);

      gate.complete();
      await tester.pumpAndSettle();
      expect(refreshButton(tester).onPressed, isNotNull);
    });

    testWidgets('a failure is said with the picker\'s own card, and Try again '
        'asks again', (tester) async {
      final (api, workflows) = await shell(tester);
      api.listFailure = const WorkflowsFailure.unreachable();

      await tester.tap(refresh());
      await tester.pumpAndSettle();

      expect(find.byType(WorkflowsRefreshFailure), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsOneWidget);
      expect(find.text(en.serverDidntAnswerTitle), findsOneWidget);
      expect(find.text(en.serverUnreachableMessage), findsOneWidget);
      expect(workflows.phase, RegistryPhase.ready);
      expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);

      api.listFailure = null;
      await tester.tap(find.byKey(LcKeys.workflowsRefreshRetry));
      await tester.pumpAndSettle();

      expect(api.listCalls, 3);
      expect(find.byKey(LcKeys.workflowsRefreshFailed), findsNothing);
      expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);
    });

    testWidgets('a failure card goes once a newer list arrives, whoever read '
        'it', (tester) async {
      final (api, workflows) = await shell(tester);
      final card = find.byKey(LcKeys.workflowsRefreshFailed);
      api.listFailure = const WorkflowsFailure.unreachable();
      await tester.tap(refresh());
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      final arrivals = workflows.listArrivals;

      // What coming back to the app does (refreshIfStale -> refresh): a list,
      // still empty, arrives without this screen asking for it.
      api.listFailure = null;
      unawaited(workflows.refresh());
      await tester.pumpAndSettle();

      expect(workflows.listArrivals, arrivals + 1);
      expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);
      expect(card, findsNothing);
    });

    testWidgets('a list that arrives with a workflow in it shows the creation '
        'controls', (tester) async {
      final (api, workflows) = await shell(tester);
      expect(find.byKey(LcKeys.chooseWorkflow), findsNothing);
      api.importOnThePc();

      await tester.tap(refresh());
      await tester.pumpAndSettle();

      expect(api.listCalls, 2);
      expect(workflows.workflows, hasLength(1));
      expect(find.byKey(LcKeys.workflowsEmptyState), findsNothing);
      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);

      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      expect(
        find.byKey(LcKeys.workflowCard('example_txt2img')),
        findsOneWidget,
      );
    });
  });
}
