/// The launch sequence, the bounds on it, and the one rule about what gets
/// remembered — driven against a local fake HTTP server.
library;

import 'support/l10n.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/discovery.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:localcanvas/connection/gateway_client.dart';

import 'support/fake_gateway.dart';
import 'support/fakes.dart';

void main() {
  late CountingGatewayClient client;
  late InMemoryEndpointStore store;
  late ConnectionController controller;

  ConnectionController build({RememberedServer? remembered}) {
    client = CountingGatewayClient(
      GatewayClient(language: () => 'en', timeout: const Duration(seconds: 2)),
    );
    store = InMemoryEndpointStore(remembered);
    controller = ConnectionController(
      client: client,
      store: store,
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  RememberedServer remembering(Endpoint endpoint, [String name = 'Studio PC']) =>
      RememberedServer(
        endpoint: endpoint,
        displayName: name,
        lastSuccess: DateTime.utc(2026),
      );

  group('launch', () {
    test('the budget is two attempts, and that is a contract not a detail', () {
      // docs/connection.md §1: try it, then one short bounded retry, then fall
      // through. Pinned on its own so that raising the budget fails here at
      // once, rather than only by exhausting a test timeout — a suite that
      // takes a minute to notice an unbounded loop is a suite that will one
      // day be told the timeout was the problem.
      expect(ConnectionController.kLaunchAttempts, 2);
    });

    test('with nothing remembered it goes straight to choosing a server', () async {
      final controller = build();

      await controller.start();

      expect(controller.phase, ConnectionPhase.needsServer);
      expect(controller.notice, isNull);
      expect(client.handshakes, 0);
    });

    test('with nothing remembered it starts looking on the network', () async {
      final backend = FakeDiscoveryBackend();
      final controller = ConnectionController(
        client: ScriptedGatewayClient((_) => throw StateError('unused')),
        store: InMemoryEndpointStore(),
        discovery: DiscoveryController(
          backend: backend,
          window: const Duration(milliseconds: 20),
        ),
        retryDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(backend.starts, 1);
    });

    test('a remembered server that answers connects immediately', () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.stop);
      final controller = build(remembered: remembering(gateway.endpoint));

      await controller.start();

      expect(controller.phase, ConnectionPhase.connected);
      expect(controller.identity?.displayName, 'Studio PC');
      expect(client.handshakes, 1);
    });

    test('an unreachable remembered server is tried a bounded number of times',
        () async {
      final controller = build(remembered: remembering(await deadEndpoint()));

      await controller.start();

      // The attempt plus the one short retry docs/connection.md §1 describes,
      // and then a screen with a decision on it — never a loop. The number is
      // written out rather than read from the constant: comparing the code to
      // itself would pass for any budget, including an unbounded one.
      expect(client.handshakes, 2);
      expect(controller.phase, ConnectionPhase.needsServer);
      expect(controller.notice?.problem, ConnectionProblem.unreachable);
    });

    test('a remembered address that is not a gateway is not retried', () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.stop);
      gateway.body = jsonEncode(<String, Object?>{'service': 'router'});
      final controller = build(remembered: remembering(gateway.endpoint));

      await controller.start();

      // Retrying a settled answer is the loop this bound exists to prevent.
      expect(client.handshakes, 1);
      expect(controller.notice?.problem, ConnectionProblem.notLocalCanvas);
    });

    test('after a failed launch, discovery is running', () async {
      final backend = FakeDiscoveryBackend();
      final controller = ConnectionController(
        client: ScriptedGatewayClient(
          (endpoint) => HandshakeFailed(
            describeProblem(ConnectionProblem.unreachable, address: 'x'),
          ),
        ),
        store: InMemoryEndpointStore(
          remembering(Endpoint.tryParse('192.0.2.42')!),
        ),
        discovery: DiscoveryController(
          backend: backend,
          window: const Duration(milliseconds: 20),
        ),
        retryDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(backend.starts, 1);
    });
  });

  group('only a successful handshake is remembered', () {
    test('a successful connection is written down', () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.stop);
      final controller = build();

      await controller.connectTo(gateway.endpoint);

      expect(store.stored?.endpoint, gateway.endpoint);
      expect(store.stored?.displayName, 'Studio PC');
      expect(store.writes, 1);
    });

    test('a typo never displaces a server that works', () async {
      final working = await FakeGateway.start();
      addTearDown(working.stop);
      final controller = build(remembered: remembering(working.endpoint));
      await controller.start();
      final writesAfterLaunch = store.writes;

      final typo = await deadEndpoint();
      final connected = await controller.connectTo(typo);

      expect(connected, isFalse);
      expect(store.stored?.endpoint, working.endpoint);
      expect(store.writes, writesAfterLaunch);
    });

    test('a server that answers with the wrong service is not remembered',
        () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.stop);
      gateway.body = jsonEncode(<String, Object?>{'service': 'router'});
      final controller = build();

      await controller.connectTo(gateway.endpoint);

      expect(store.stored, isNull);
      expect(store.writes, 0);
    });

    test('a gateway on an unsupported version is not remembered', () async {
      final gateway = await FakeGateway.start(
        info: <String, Object?>{...FakeGateway.healthyInfo, 'api_version': 7},
      );
      addTearDown(gateway.stop);
      final controller = build();

      await controller.connectTo(gateway.endpoint);

      expect(store.stored, isNull);
      expect(controller.notice?.problem, ConnectionProblem.incompatibleVersion);
      expect(controller.notice?.message(en), contains('7'));
    });
  });

  group('pairing code', () {
    test('a valid code verifies, saves and connects', () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.stop);
      final controller = build();

      final outcome = await controller.connectToPairingPayload(
        gateway.pairingPayload,
      );

      expect(outcome, PairingOutcome.connected);
      expect(controller.phase, ConnectionPhase.connected);
      expect(store.stored?.endpoint, gateway.endpoint);
    });

    test('a code that parses but fails the handshake saves nothing', () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.stop);
      gateway.body = jsonEncode(<String, Object?>{'service': 'router'});
      final controller = build();

      final outcome = await controller.connectToPairingPayload(
        gateway.pairingPayload,
      );

      expect(outcome, PairingOutcome.handshakeFailed);
      expect(controller.phase, ConnectionPhase.needsServer);
      expect(controller.notice?.problem, ConnectionProblem.notLocalCanvas);
      expect(store.stored, isNull);
    });

    test('some other barcode is reported as not a pairing code', () async {
      final controller = build();

      final outcome = await controller.connectToPairingPayload(
        'https://example.com/coupon',
      );

      expect(outcome, PairingOutcome.notAPairingCode);
      expect(client.handshakes, 0);
      expect(store.stored, isNull);
    });
  });

  group('a gateway whose generator is down', () {
    Future<ConnectionController> connectedToStalledGateway() async {
      final gateway = await FakeGateway.start(
        info: <String, Object?>{
          ...FakeGateway.healthyInfo,
          'comfy': <String, Object?>{'status': 'unavailable', 'detail': null},
        },
      );
      addTearDown(gateway.stop);
      final controller = build();
      await controller.connectTo(gateway.endpoint);
      return controller;
    }

    test('is connected, and says so distinctly', () async {
      final controller = await connectedToStalledGateway();

      expect(controller.phase, ConnectionPhase.connected);
      expect(controller.isComfyReady, isFalse);
      expect(controller.notice?.problem, ConnectionProblem.comfyUnavailable);
      expect(controller.notice?.title(en), "Connected, but ComfyUI isn't running.");
    });

    test('is remembered — the gateway itself did answer', () async {
      final controller = await connectedToStalledGateway();

      expect(store.stored?.endpoint, controller.endpoint);
    });
  });

  test('a ready gateway leaves no notice behind', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    final controller = build();

    await controller.connectTo(gateway.endpoint);

    expect(controller.notice, isNull);
    expect(controller.isComfyReady, isTrue);
  });

  test('an unforeseen transport error still ends in a screen with an exit',
      () async {
    // The failure mode this guards is not a wrong message but a stuck one: an
    // exception escaping the handshake leaves `isBusy` true and the phase at
    // `connecting` for ever, which is the state docs/recovery.md forbids.
    final controller = ConnectionController(
      client: GatewayClient(
        language: () => 'en',
        httpClient: ThrowingHttpClient(StateError('nobody predicted this')),
      ),
      store: InMemoryEndpointStore(),
      discovery: silentDiscovery(),
      retryDelay: Duration.zero,
    );
    addTearDown(controller.dispose);

    final connected = await controller.connectTo(
      Endpoint.tryParse('192.0.2.42')!,
    );

    expect(connected, isFalse);
    expect(controller.phase, ConnectionPhase.needsServer);
    expect(controller.isBusy, isFalse);
    expect(controller.notice?.problem, ConnectionProblem.unreachable);
  });

  test('retry is one more attempt, not a resumed loop', () async {
    final controller = build(remembered: remembering(await deadEndpoint()));
    await controller.start();
    final afterLaunch = client.handshakes;

    await controller.retry();

    expect(client.handshakes, afterLaunch + 1);
    expect(controller.phase, ConnectionPhase.needsServer);
  });

  test('choosing another server keeps what already works remembered', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    final controller = build();
    await controller.connectTo(gateway.endpoint);

    await controller.chooseAnotherServer();

    expect(controller.phase, ConnectionPhase.needsServer);
    expect(store.stored?.endpoint, gateway.endpoint);
  });

  test('forgetting is explicit and empties the store', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    final controller = build();
    await controller.connectTo(gateway.endpoint);

    await controller.forgetRemembered();

    expect(store.stored, isNull);
    expect(controller.remembered, isNull);
  });
}
