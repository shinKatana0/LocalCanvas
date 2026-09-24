/// The shell adapts on width, and the state it holds does not notice
/// (`docs/ui-ux.md`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/theme/tokens.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';

import 'support/l10n.dart';
import 'support/fakes.dart';
import 'support/generation_fakes.dart';

void main() {
  late ScriptedGatewayClient client;

  Future<ConnectionController> connected({
    ComfyStatus comfyStatus = ComfyStatus.ready,
  }) async {
    client = ScriptedGatewayClient(
      (e) => HandshakeSucceeded(e, testIdentity(comfyStatus: comfyStatus)),
    );
    final controller = ConnectionController(
      client: client,
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.connectTo(Endpoint.tryParse('192.0.2.42')!);
    return controller;
  }

  Widget shell(ConnectionController controller) => MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
    theme: lcDarkTheme(),
    home: ConnectedShell(
      session: testSession(
        connection: controller,
        workflows: emptyRegistry(),
      ),
    ),
  );

  void resize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
  }

  testWidgets('a narrow window is a single column', (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(400, 800));

    await tester.pumpWidget(shell(await connected()));
    await tester.pumpAndSettle();

    expect(find.byKey(LcKeys.shellCompact), findsOneWidget);
    expect(find.byKey(LcKeys.shellExpanded), findsNothing);
    expect(find.byKey(LcKeys.contentPane), findsOneWidget);
  });

  testWidgets('a wide window is two panes', (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(1000, 800));

    await tester.pumpWidget(shell(await connected()));
    await tester.pumpAndSettle();

    expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
    expect(find.byKey(LcKeys.shellCompact), findsNothing);

    final controls = tester.getSize(find.byKey(LcKeys.controlsPane)).width;
    final content = tester.getSize(find.byKey(LcKeys.contentPane)).width;
    expect(controls, lessThanOrEqualTo(LcLayout.controlsPaneMax));
    expect(controls, greaterThanOrEqualTo(LcLayout.controlsPaneMin));
    // Controls left, the generation area right — and the right one is the
    // larger of the two.
    expect(content, greaterThan(controls));
  });

  testWidgets('the two-pane threshold is a width, not a device', (tester) async {
    addTearDown(tester.view.reset);
    // One pixel either side of the threshold decides it, and nothing else can.
    resize(tester, const Size(LcLayout.twoPaneWidth - 1, 800));
    await tester.pumpWidget(shell(await connected()));
    await tester.pumpAndSettle();
    expect(find.byKey(LcKeys.shellCompact), findsOneWidget);

    resize(tester, const Size(LcLayout.twoPaneWidth, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
  });

  testWidgets('a wide window does not simply stretch the narrow one',
      (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(1400, 900));

    await tester.pumpWidget(shell(await connected()));
    await tester.pumpAndSettle();

    final content = tester.getSize(find.byKey(LcKeys.workflowsEmptyState)).width;
    expect(content, lessThanOrEqualTo(LcLayout.readableWidth));
  });

  testWidgets('state survives a size change', (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(400, 800));
    final controller = await connected();

    await tester.pumpWidget(shell(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(LcKeys.serverDetails), findsOneWidget);

    // The fold.
    resize(tester, const Size(1000, 800));
    await tester.pumpAndSettle();

    expect(find.byKey(LcKeys.shellExpanded), findsOneWidget);
    // A fold is a configuration change, not a restart: what was open is open,
    // and nothing reconnected.
    expect(find.byKey(LcKeys.serverDetails), findsOneWidget);
    expect(client.handshakes, 1);
    expect(controller.identity?.displayName, 'Studio PC');
  });

  testWidgets('the connected server is named from its own handshake',
      (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(400, 800));

    await tester.pumpWidget(shell(await connected()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
    await tester.pumpAndSettle();

    expect(find.text('Studio PC'), findsOneWidget);
    expect(find.text('http://192.0.2.42:7801'), findsOneWidget);
    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.textContaining('1 (this app speaks 1)'), findsOneWidget);
  });

  testWidgets('a connected server whose generator is down says so distinctly',
      (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(400, 800));

    await tester.pumpWidget(
      shell(await connected(comfyStatus: ComfyStatus.unavailable)),
    );
    await tester.pumpAndSettle();

    expect(find.text("Connected, but ComfyUI isn't running."), findsOneWidget);
    expect(find.text('Check again'), findsWidgets);
  });

  testWidgets('the content area is a finished empty state, not a placeholder',
      (tester) async {
    addTearDown(tester.view.reset);
    resize(tester, const Size(400, 800));

    await tester.pumpWidget(shell(await connected()));
    await tester.pumpAndSettle();

    expect(find.byKey(LcKeys.workflowsEmptyState), findsOneWidget);
    expect(find.text('Nothing to create with yet'), findsOneWidget);
    expect(find.text('Choose another server'), findsOneWidget);
    // Nothing that reads as unfinished work.
    expect(find.textContaining('TODO'), findsNothing);
    expect(find.textContaining('placeholder'), findsNothing);
  });
}
