/// Coming back to the workflow the app was closed on (T-0179).
///
/// The user force-exits, relaunches, and the server reconnects while the
/// form is empty. The server was already remembered and so was the draft — the
/// typed prompt included — so the only thing missing was *which* workflow.
///
/// **The stores here are the real ones over the package's own in-memory
/// platform.** Calling [main]'s `opened` twice in one test is the app being
/// launched twice on one device: new controllers, the same preference file. That
/// matters most for the two claims a fake could fabricate — that the memory
/// belongs to the server it was made against, and that the restored prompt
/// comes out of the draft machinery that was already there rather than out of
/// anything this card wrote.
///
/// Four shapes, and all four are driven: no memory at all, a memory the gateway
/// still serves, a memory for a workflow it has stopped serving, and a memory
/// made against a different gateway.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/profile_transport.dart';
import 'package:localcanvas/workflows/selected_workflow_store.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

/// A registry whose two requests hang until the test lets them through.
///
/// The screen must not wait on either, and a delay measured in milliseconds
/// cannot tell "did not wait" from "waited briefly" — so both are held open
/// instead of slowed down.
class HangingWorkflowsApi implements WorkflowsApi {
  HangingWorkflowsApi({this.summaries = const <WorkflowSummary>[], this.details = const <String, WorkflowDetail>{}});

  List<WorkflowSummary> summaries;
  Map<String, WorkflowDetail> details;

  final Completer<void> listGate = Completer<void>();
  final Completer<void> detailGate = Completer<void>();

  /// Whether the gate is held at all. A test about the detail wants the list
  /// to arrive normally.
  bool holdList = true;
  bool holdDetail = true;

  int listCalls = 0;
  final List<String> detailCalls = <String>[];

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async {
    listCalls++;
    if (holdList) await listGate.future;
    return summaries;
  }

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) async {
    detailCalls.add(workflowId);
    if (holdDetail) await detailGate.future;
    return details[workflowId]!;
  }
}

/// The share sheet, recorded rather than performed — enough of it for the one
/// export the profile test below makes.
class RecordingTransport implements ProfileTransport {
  final List<ProfileDocument> sent = <ProfileDocument>[];

  String get sentText => sent.single.text;

  @override
  Future<void> send(ProfileDocument document) async => sent.add(document);

  @override
  Future<String?> receive({String? typeLabel}) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The key the memory lives under, spelled out rather than read off the
  /// class: a constant asked for its own value agrees with any answer it gives.
  const String memoryKey = 'localcanvas.selected_workflow';

  final studio = Endpoint.tryParse('192.0.2.42')!;
  final laptop = Endpoint.tryParse('192.0.2.77')!;

  /// A second gateway on the same PC — the case a host-only comparison would
  /// get wrong, and the reason this file drives two different "other servers".
  final secondGateway = Endpoint.tryParse('192.0.2.42:7802')!;

  late ScriptedWorkflowsApi registry;

  /// The controllers this test has built and not yet closed.
  ///
  /// A test that relaunches the app closes the first one itself, with
  /// [closeApp], and the rest are closed here — so nothing is ever disposed
  /// twice, which `ChangeNotifier` reports as a failure of its own and would
  /// otherwise mask the assertion that mattered.
  final List<WorkflowsController> openApps = <WorkflowsController>[];

  void closeApp(WorkflowsController controller) {
    openApps.remove(controller);
    controller.dispose();
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    for (final controller in openApps.toList(growable: false)) {
      controller.dispose();
    }
    openApps.clear();
  });

  /// Everything the preferences hold, read around the app rather than through
  /// it — so an assertion about a key cannot be satisfied by the same code that
  /// wrote it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  /// Just the drafts, which is the part of that file this card must not touch.
  Future<Map<String, Object?>> drafts() async {
    final all = await preferences();
    return <String, Object?>{
      for (final entry in all.entries)
        if (entry.key.startsWith('localcanvas.draft.')) entry.key: entry.value,
    };
  }

  WorkflowsController controllerFor(
    List<Map<String, Object?>> details, {
    SelectedWorkflowStore? selection,
    ProfileTransport? profiles,
  }) {
    registry = ScriptedWorkflowsApi(
      summaries: WorkflowSummary.listFromJson(registryOf(details)),
      details: <String, WorkflowDetail>{
        for (final body in details)
          body['id']! as String: WorkflowDetail.tryFromJson(body)!,
      },
    );
    final controller = WorkflowsController(
      api: registry,
      settings: PreferencesWorkflowSettingsStore(),
      drafts: PreferencesWorkflowDraftStore(),
      setups: PreferencesWorkflowSetupStore(),
      selection: selection ?? PreferencesSelectedWorkflowStore(),
      profiles: profiles,
      draftDebounce: Duration.zero,
    );
    openApps.add(controller);
    return controller;
  }

  /// The app opened on [endpoint] over the real stores.
  Future<WorkflowsController> opened(
    List<Map<String, Object?>> details, {
    Endpoint? endpoint,
    SelectedWorkflowStore? selection,
    ProfileTransport? profiles,
  }) async {
    final controller = controllerFor(
      details,
      selection: selection,
      profiles: profiles,
    );
    await controller.load(endpoint ?? studio);
    return controller;
  }

  group('a launch with nothing to come back to', () {
    test('the store is asked, finds nothing, and nothing is opened', () async {
      // The read is asserted as well as the absence. Without it this test
      // passes for a build that never looks at the store at all, which is the
      // build the card is about.
      final store = InMemorySelectedWorkflowStore();
      final controller = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ], selection: store);

      expect(store.reads, <Endpoint>[studio]);
      expect(controller.selectedId, isNull);
      expect(controller.form, isNull);
      // Not "gone", either. Nobody was ever on anything, so there is nothing
      // to report and no sentence to show.
      expect(controller.missingSelection, isNull);
      expect(controller.phase, RegistryPhase.ready);
      // And no workflow was opened on a guess — not the first in the list, not
      // the only one there is.
      expect(registry.detailCalls, isEmpty);
      expect((await preferences()).containsKey(memoryKey), isFalse);
    });

    test('a build that keeps no selection behaves as it always did', () async {
      // `selection` is optional for the reason the other three stores are: a
      // build handed nowhere to remember simply does not.
      final controller = WorkflowsController(api: ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
      ));
      addTearDown(controller.dispose);

      await controller.load(studio);

      expect(controller.selectedId, isNull);
      expect(controller.phase, RegistryPhase.ready);
      // Choosing one writes nowhere and throws nothing.
      await controller.select('example_txt2img');
      expect(controller.selectedId, 'example_txt2img');
      expect((await preferences()).containsKey(memoryKey), isFalse);
    });
  });

  group('a launch that comes back to where it was', () {
    test('the workflow is chosen again and the typed prompt is back with it',
        () async {
      // Launch one: choose a workflow, type into it, and let the app leave the
      // foreground, which is where `app.dart` calls `flushDrafts`.
      final first = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await first.select('example_txt2img');
      first.form!
        ..setEntry('prompt', 'a quiet courtyard at dawn')
        ..setEntry('width', '1024');
      await first.flushDrafts();
      closeApp(first);

      // What is on the device between the two launches, verbatim. The memory
      // this card adds, and the draft that was already being written.
      final between = await preferences();
      expect(
        between[memoryKey],
        '{"endpoint":"http://192.0.2.42:7801","workflow":"example_txt2img"}',
      );
      expect(
        between['localcanvas.draft.example_txt2img.prompt'],
        'a quiet courtyard at dawn',
      );
      expect(between['localcanvas.draft.example_txt2img.width'], 1024);

      // Launch two.
      final second = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);

      expect(second.selectedId, 'example_txt2img');
      expect(second.selectedSummary?.name, 'Example Text to Image');
      expect(second.selectedDetail, isNotNull);
      expect(second.missingSelection, isNull);
      // And the words themselves. This is the line that shows the existing
      // draft machinery is doing the work: nothing in this card writes or reads
      // a field value, it only decides which form is on screen.
      expect(second.form!.entry('prompt'), 'a quiet courtyard at dawn');
      expect(second.form!.entry('width'), '1024');
      // One request, for the one workflow. Not the whole catalogue, and not the
      // other one the registry carries.
      expect(registry.detailCalls, <String>['example_txt2img']);
    });

    test('restoring changes nothing the user typed', () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await first.select('example_txt2img');
      first.form!
        ..setEntry('prompt', 'a quiet courtyard at dawn')
        ..setEntry('negative_prompt', 'no people')
        ..setEntry('width', '1024');
      await first.flushDrafts();
      closeApp(first);

      final before = await drafts();
      // The positive control: there genuinely was a draft there to damage.
      expect(before, isNotEmpty);
      expect(before['localcanvas.draft.example_txt2img.prompt'],
          'a quiet courtyard at dawn');

      final second = await opened(<Map<String, Object?>>[txt2imgDetail()]);

      // Every draft key, with every value, exactly as it was. A restoration
      // that wrote an empty form back over the draft, or cleared one field, or
      // added a key of its own, fails here.
      expect(await drafts(), before);
      expect(second.form!.entry('prompt'), 'a quiet courtyard at dawn');
      expect(second.form!.entry('negative_prompt'), 'no people');
    });

    test('restoring starts no generation', () async {
      final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await first.select('example_txt2img');
      first.form!.setEntry('prompt', 'a quiet courtyard at dawn');
      await first.flushDrafts();
      closeApp(first);

      final second = await opened(<Map<String, Object?>>[txt2imgDetail()]);

      // The form is ready — this is a workflow that could be submitted, which
      // is what makes the absence below mean something.
      expect(second.form!.validate().isReady, isTrue);
      expect(second.requestedGeneration, isNull);
    });

    test('choosing a different workflow replaces the memory rather than '
        'joining it', () async {
      final controller = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await controller.select('example_txt2img');
      await controller.select('example_img2img');

      expect(
        (await preferences())[memoryKey],
        '{"endpoint":"http://192.0.2.42:7801","workflow":"example_img2img"}',
      );
    });

    test('choosing nothing is remembered as nothing', () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await controller.select('example_txt2img');
      controller.form!.setEntry('prompt', 'a quiet courtyard at dawn');
      await controller.flushDrafts();
      expect((await preferences()).containsKey(memoryKey), isTrue);

      controller.clearSelection();
      // Written without waiting, the way the draft is.
      await pumpEventQueue();

      expect((await preferences()).containsKey(memoryKey), isFalse);
      // And one thing only was forgotten: what was typed is still there, so
      // choosing that workflow again still brings it back.
      expect(await drafts(), isNotEmpty);
    });

    testWidgets('the app opens on the workflow it was closed on, with the '
        'words still in it', (tester) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Launch one, through the controller.
      final first = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await first.select('example_txt2img');
      first.form!.setEntry('prompt', 'a quiet courtyard at dawn');
      await first.flushDrafts();
      closeApp(first);

      // Launch two, through the screen.
      final jobs = ScriptedJobsApi(
        submission: const JobSubmission(
          jobId: 'j-inert',
          state: JobState.completed,
        ),
      );
      final shell = controllerFor(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
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
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(
              connection: connection,
              workflows: shell,
              jobs: jobs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The chosen workflow's own block, not the Choose a workflow button.
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.chooseWorkflow), findsNothing);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.text('Example Text to Image'), findsWidgets);
      // And the prompt, on screen, exactly as it was typed.
      expect(find.text('a quiet courtyard at dawn'), findsOneWidget);
      // Nothing was submitted. Opening a form is not asking for a picture.
      expect(jobs.submits, 0);
      expect(jobs.submittedWorkflows, isEmpty);
    });

    testWidgets('somebody who has never chosen anything still gets the empty '
        'state', (tester) async {
      // The twin of the test above, over the same helper and the same
      // registry, differing in one thing: this device was never told anything.
      // Read as a pair, neither can pass for the other.
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final shell = controllerFor(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
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
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: shell),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflow), findsNothing);
      expect(find.byKey(LcKeys.workflowForm), findsNothing);
      expect(shell.selectedId, isNull);
    });
  });

  group('a workflow the gateway no longer serves', () {
    test('restoring it reaches the state a mid-session disappearance reaches',
        () async {
      // (a) The path that already existed: the workflow goes away while the
      // app is running, because the user edits their own catalogue.
      final live = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await live.select('example_txt2img');
      registry.summaries = WorkflowSummary.listFromJson(
        registryOf(<Map<String, Object?>>[img2imgDetail()]),
      );
      await live.reload();

      expect(live.selectedId, isNull);
      expect(live.missingSelection, 'Example Text to Image');
      expect(live.phase, RegistryPhase.ready);
      expect(live.detailFailure, isNull);
      expect(live.form, isNull);
      closeApp(live);

      // (b) The same device, relaunched — and the workflow is already gone
      // before the app opens. The memory is put back by hand because (a) has
      // just forgotten it, which is asserted at the end.
      await PreferencesSelectedWorkflowStore().remember(
        studio,
        'example_txt2img',
      );
      final relaunched = await opened(<Map<String, Object?>>[img2imgDetail()]);

      // The same four facts (a) reached.
      expect(relaunched.selectedId, isNull);
      expect(relaunched.phase, RegistryPhase.ready);
      expect(relaunched.detailFailure, isNull);
      expect(relaunched.form, isNull);
      // Reported, never silently substituted (`docs/recovery.md`) — and named
      // by the most this launch honestly knows it as. Mid-session the old list
      // still held the summary, so the sentence carries the curator's name; a
      // launch never saw a summary for it, so it carries the id. Both name the
      // workflow the user chose; neither is another workflow put quietly in its
      // place.
      expect(relaunched.missingSelection, 'example_txt2img');
      // Nothing was opened. The detail request is never made for an id the list
      // did not vouch for — which is also what stops a restored id reaching a
      // gateway that would answer with somebody else's workflow.
      expect(registry.detailCalls, isEmpty);
      // And it is not tried again on the next launch.
      expect((await preferences()).containsKey(memoryKey), isFalse);
    });

    test('the gone workflow keeps its draft, so it comes back if it does',
        () async {
      final first = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await first.select('example_txt2img');
      first.form!.setEntry('prompt', 'a quiet courtyard at dawn');
      await first.flushDrafts();
      closeApp(first);
      final before = await drafts();
      expect(before, isNotEmpty);

      // It opens on a gateway that has stopped serving it…
      final without = await opened(<Map<String, Object?>>[img2imgDetail()]);
      expect(without.missingSelection, 'example_txt2img');
      expect(await drafts(), before);
      closeApp(without);

      // …and the workflow coming back brings the words with it, through the
      // ordinary route: the user chooses it.
      final again = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
      ]);
      await again.select('example_txt2img');
      expect(again.form!.entry('prompt'), 'a quiet courtyard at dawn');
    });

    testWidgets('the screen says so and offers the list, rather than breaking',
        (tester) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await PreferencesSelectedWorkflowStore().remember(
        studio,
        'example_txt2img',
      );
      final shell = controllerFor(<Map<String, Object?>>[img2imgDetail()]);
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
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: shell),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The workflow is named, by the one name this launch has for it.
      expect(find.textContaining('example_txt2img'), findsOneWidget);
      // And the way forward is the ordinary one.
      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflow), findsNothing);
      expect(find.byKey(LcKeys.workflowForm), findsNothing);
    });
  });

  group('a memory made against another server', () {
    /// Both other gateways are driven, because they fail differently: a
    /// different host is what a careless comparison gets right by accident, and
    /// a second gateway on the same PC is what it gets wrong.
    for (final (label, other) in <(String, Endpoint)>[
      ('another machine', laptop),
      ('a second gateway on the same machine', secondGateway),
    ]) {
      test('a selection made on one gateway is not applied on $label, and is '
          'still there for the one it was made on', () async {
        // Launch one, on the studio PC.
        final first = await opened(<Map<String, Object?>>[txt2imgDetail()]);
        await first.select('example_txt2img');
        closeApp(first);
        expect(
          (await preferences())[memoryKey],
          '{"endpoint":"http://192.0.2.42:7801",'
              '"workflow":"example_txt2img"}',
        );

        // Launch two, paired with a different gateway that serves a workflow of
        // exactly the same id. This is the case that is worse than the id being
        // absent: a curator names their own workflows, so the same word on two
        // machines is two different graphs.
        final elsewhere = await opened(<Map<String, Object?>>[
          txt2imgDetail(),
        ], endpoint: other);

        expect(elsewhere.selectedId, isNull);
        // Not "gone", either. It was never this server's to lose, so there is
        // nothing to report about it.
        expect(elsewhere.missingSelection, isNull);
        expect(elsewhere.phase, RegistryPhase.ready);
        // And the id never reached this gateway at all.
        expect(registry.detailCalls, isEmpty);
        closeApp(elsewhere);

        // Back to the first gateway. This is what makes the nulls above a fact
        // about the server rather than about a file the second launch wiped —
        // and it is the other direction the card asks for.
        final home = await opened(<Map<String, Object?>>[txt2imgDetail()]);
        expect(home.selectedId, 'example_txt2img');
        expect(registry.detailCalls, <String>['example_txt2img']);
      });
    }

    test('changing server inside one session keeps the first server\'s place',
        () async {
      // The same controller, pointed somewhere else and then back. Nothing is
      // erased on the way, because a memory naming one server is already
      // ignored while the app is on another.
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await controller.select('example_txt2img');

      await controller.load(laptop);
      expect(controller.selectedId, isNull);
      expect(
        (await preferences())[memoryKey],
        '{"endpoint":"http://192.0.2.42:7801","workflow":"example_txt2img"}',
      );

      await controller.load(studio);
      expect(controller.selectedId, 'example_txt2img');
    });

    testWidgets('the app opens on the empty state when it is talking to '
        'another gateway', (tester) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Remembered against the studio PC, and this launch is paired with the
      // laptop — which publishes a workflow of exactly the same id.
      await PreferencesSelectedWorkflowStore().remember(
        studio,
        'example_txt2img',
      );
      final shell = controllerFor(<Map<String, Object?>>[txt2imgDetail()]);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(laptop);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: shell),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);
      expect(find.byKey(LcKeys.selectedWorkflow), findsNothing);
      expect(shell.selectedId, isNull);
      expect(shell.missingSelection, isNull);
    });
  });

  group('nothing on screen waits for any of it', () {
    /// The shell over whatever api and store the test hands it, pumped exactly
    /// once — the first frame, and nothing after it.
    Future<WorkflowsController> firstFrame(
      WidgetTester tester, {
      required WorkflowsApi api,
      required SelectedWorkflowStore selection,
    }) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workflows = WorkflowsController(
        api: api,
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
        setups: PreferencesWorkflowSetupStore(),
        selection: selection,
        draftDebounce: Duration.zero,
      );
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
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: workflows),
          ),
        ),
      );
      return workflows;
    }

    testWidgets('the first frame is drawn while the registry request and the '
        'preference read are both still outstanding', (tester) async {
      final api = HangingWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      );
      final store = PendingSelectedWorkflowStore();

      await firstFrame(tester, api: api, selection: store);

      // Both are genuinely in flight — without this the frame below would be a
      // frame drawn after everything had already answered.
      expect(api.listCalls, 1);
      expect(store.completer.isCompleted, isFalse);
      // And the screen is there: the server block, and the quiet spinner the
      // app has always shown while the list is on its way.
      expect(tester.takeException(), isNull);
      expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsLoading), findsOneWidget);

      // Let everything through so the test ends on a settled tree.
      api.listGate.complete();
      api.detailGate.complete();
      store.completer.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('a preference file that never answers costs the selection and '
        'not the registry', (tester) async {
      // The guard on the one ordering decision inside `_fetch`: the list is
      // published *before* the remembered id is waited for. Move that one
      // notify below the await and this test hangs on a spinner, which is the
      // first thing `docs/ui-ux.md` lists under "Never".
      final api = HangingWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      )..holdList = false;
      final store = PendingSelectedWorkflowStore();

      final workflows = await firstFrame(
        tester,
        api: api,
        selection: store,
      );
      await tester.pumpAndSettle();

      // The file has still said nothing.
      expect(store.completer.isCompleted, isFalse);
      // The registry is on screen and usable anyway.
      expect(find.byKey(LcKeys.workflowsLoading), findsNothing);
      expect(find.byKey(LcKeys.chooseWorkflow), findsOneWidget);
      expect(workflows.phase, RegistryPhase.ready);

      // And when it finally answers, the selection arrives.
      store.completer.complete('example_txt2img');
      api.detailGate.complete();
      await tester.pumpAndSettle();

      expect(workflows.selectedId, 'example_txt2img');
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
    });

    testWidgets('the restored workflow\'s schema is fetched after the screen '
        'is up, not in front of it', (tester) async {
      final api = HangingWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      )..holdList = false;
      final workflows = await firstFrame(
        tester,
        api: api,
        selection: InMemorySelectedWorkflowStore('example_txt2img'),
      );
      // Pumped rather than settled, deliberately: while the schema is in
      // flight the form's place is held by a progress indicator, which
      // animates, so there is nothing for `pumpAndSettle` to settle. Five
      // frames is more than the awaits between the list arriving and the
      // schema being asked for.
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The schema is still on its way…
      expect(api.detailCalls, <String>['example_txt2img']);
      expect(api.detailGate.isCompleted, isFalse);
      expect(workflows.selectedDetail, isNull);
      // …and the chosen workflow is already named on a drawn screen, with the
      // form's own progress where the fields will be.
      expect(tester.takeException(), isNull);
      expect(find.byKey(LcKeys.selectedWorkflow), findsOneWidget);
      expect(find.text('Example Text to Image'), findsWidgets);
      expect(find.byKey(LcKeys.workflowForm), findsNothing);

      api.detailGate.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
    });

    test('a store that throws does not stop the launch', () async {
      // `selected_workflow_store.dart` answers rather than throwing for every
      // shape it can actually meet, so this is about a store that throws
      // anyway: a platform channel that refuses. A launch must not fail because
      // a preference file would not open.
      final store = InMemorySelectedWorkflowStore('example_txt2img')
        ..loadFailure = StateError('the preference file will not open');

      final controller = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
      ], selection: store);

      expect(store.reads, <Endpoint>[studio]);
      expect(controller.phase, RegistryPhase.ready);
      expect(controller.selectedId, isNull);
      expect(controller.workflows.map((w) => w.id), <String>['example_txt2img']);
    });

    test('a registry that never arrived vouches for nothing', () async {
      // A list that failed cannot say whether the remembered workflow is this
      // server's, and opening one no registry confirmed is exactly what the
      // per-server scoping exists to prevent. So the failure is shown and the
      // memory is kept for next time.
      final store = InMemorySelectedWorkflowStore('example_txt2img');
      final controller = controllerFor(
        <Map<String, Object?>>[txt2imgDetail()],
        selection: store,
      );
      registry.listFailure = const WorkflowsFailure.unreachable();

      await controller.load(studio);

      expect(controller.phase, RegistryPhase.failed);
      expect(controller.selectedId, isNull);
      expect(controller.missingSelection, isNull);
      expect(registry.detailCalls, isEmpty);
      expect(store.stored, 'example_txt2img');
      expect(store.forgets, 0);
    });
  });

  group('it is not part of who the user is', () {
    test('which workflow was open is not in the file handed to somebody else',
        () async {
      final transport = RecordingTransport();
      final controller = await opened(
        <Map<String, Object?>>[txt2imgDetail()],
        profiles: transport,
      );
      // A device with something to export, so an empty document cannot pass
      // for a clean one.
      await controller.select('example_txt2img');
      controller.form!
        ..setEntry('width', '512')
        ..setEntry('prompt', 'a quiet courtyard at dawn');
      await controller.saveMyDefaults();
      await controller.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Warm rework',
      );

      // The memory genuinely existed, and genuinely sits in the preference file
      // the export is built from. Without these three lines the absence below
      // would be a fact about an empty device.
      expect(controller.selectedId, 'example_txt2img');
      expect(
        await PreferencesSelectedWorkflowStore().load(studio),
        'example_txt2img',
      );
      expect(
        (await preferences())[memoryKey],
        '{"endpoint":"http://192.0.2.42:7801","workflow":"example_txt2img"}',
      );

      await controller.exportProfile();

      final text = transport.sentText;
      final document = jsonDecode(text) as Map<String, Object?>;
      // The document carries what a profile is for.
      final defaults =
          ((document['workflows']! as Map<String, Object?>)['example_txt2img']!
                  as Map<String, Object?>)['defaults']!
              as Map<String, Object?>;
      expect(defaults['width'], 512);
      expect((document['setups']! as List<Object?>).length, 1);
      // And its shape is exactly what it was: no fifth key appeared.
      expect(document.keys.toList(), <String>[
        'format',
        'version',
        'workflows',
        'setups',
      ]);

      // The search, over the serialised text, because that is what leaves the
      // phone. The workflow's *id* is deliberately not on this list: a profile
      // names the workflows it carries defaults for, and always did. What must
      // not be in there is the fact that this phone had one open, and the
      // server it had it open against.
      const List<String> forbidden = <String>[
        'selected_workflow',
        'selected',
        'endpoint',
        '192.0.2.42',
        '7801',
      ];
      for (final needle in forbidden) {
        expect(
          text,
          isNot(contains(needle)),
          reason: 'the exported document names $needle',
        );
      }

      // The positive control. The same search over the same document with the
      // memory injected finds every one of those words — so the absences above
      // are facts about the document and not about a search that could not see
      // anything if it were there.
      final injected = jsonEncode(<String, Object?>{
        ...document,
        'selected_workflow': <String, Object?>{
          'endpoint': studio.canonical,
          'workflow': 'example_txt2img',
        },
      });
      for (final needle in forbidden) {
        expect(
          injected,
          contains(needle),
          reason: 'the search cannot see $needle even when it is there',
        );
      }
    });
  });
}
