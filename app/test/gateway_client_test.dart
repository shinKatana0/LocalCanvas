/// The handshake, against a local fake HTTP server — never a real gateway.
library;

import 'support/l10n.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_problem.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';

import 'support/fake_gateway.dart';
import 'support/fakes.dart';

void main() {
  late GatewayClient client;

  setUp(() => client = GatewayClient(language: () => 'en', timeout: const Duration(seconds: 2)));
  tearDown(() => client.dispose());

  test('a healthy gateway identifies itself', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);

    final outcome = await client.handshake(gateway.endpoint);

    expect(outcome, isA<HandshakeSucceeded>());
    final identity = (outcome as HandshakeSucceeded).identity;
    expect(identity.displayName, 'Studio PC');
    expect(identity.apiVersion, 1);
    expect(identity.gatewayVersion, '0.1.0');
    expect(identity.comfyStatus, ComfyStatus.ready);
  });

  test('the handshake goes to /api/v1/info', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);

    await client.handshake(gateway.endpoint);

    expect(gateway.requestedPaths, <String>['/api/v1/info']);
  });

  test('a path-mounted gateway keeps its prefix', () async {
    // docs/transport-boundary.md §3: the client appends to the configured
    // endpoint rather than treating the path as root-absolute.
    final gateway = await FakeGateway.start(basePath: '/localcanvas');
    addTearDown(gateway.stop);

    final outcome = await client.handshake(gateway.endpoint);

    expect(outcome, isA<HandshakeSucceeded>());
    expect(gateway.requestedPaths, <String>['/localcanvas/api/v1/info']);
  });

  test('another service on the same port is not a gateway', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    gateway.body = jsonEncode(<String, Object?>{
      'service': 'something-else',
      'api_version': 1,
    });

    final outcome = await client.handshake(gateway.endpoint);

    expect(outcome, isA<HandshakeFailed>());
    expect(
      (outcome as HandshakeFailed).problem,
      ConnectionProblem.notLocalCanvas,
    );
  });

  test('a response with no service field is not a gateway', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    gateway.body = jsonEncode(<String, Object?>{'hello': 'world'});

    final outcome = await client.handshake(gateway.endpoint);

    expect(
      (outcome as HandshakeFailed).problem,
      ConnectionProblem.notLocalCanvas,
    );
  });

  test('a page of HTML is not a gateway', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    gateway
      ..contentType = 'text/html'
      ..body = '<html><body>router admin</body></html>';

    final outcome = await client.handshake(gateway.endpoint);

    expect(
      (outcome as HandshakeFailed).problem,
      ConnectionProblem.notLocalCanvas,
    );
  });

  test('a server that answers with an error is not a gateway', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.stop);
    gateway.statusCode = 503;

    final outcome = await client.handshake(gateway.endpoint);

    expect(
      (outcome as HandshakeFailed).problem,
      ConnectionProblem.notLocalCanvas,
    );
  });

  test('a gateway on another api_version is incompatible, both named', () async {
    final gateway = await FakeGateway.start(
      info: <String, Object?>{
        ...FakeGateway.healthyInfo,
        'api_version': 7,
      },
    );
    addTearDown(gateway.stop);

    final outcome = await client.handshake(gateway.endpoint);

    expect(outcome, isA<HandshakeFailed>());
    final failure = outcome as HandshakeFailed;
    expect(failure.problem, ConnectionProblem.incompatibleVersion);
    expect(failure.serverApiVersion, 7);
    // Both versions are in the words the user reads, per docs/api.md.
    expect(failure.notice.message(en), contains('7'));
    expect(failure.notice.message(en), contains('$kSupportedApiVersion'));
  });

  test('a wrong version is not retried — it is a settled fact', () async {
    final gateway = await FakeGateway.start(
      info: <String, Object?>{...FakeGateway.healthyInfo, 'api_version': 7},
    );
    addTearDown(gateway.stop);

    final outcome = await client.handshake(gateway.endpoint) as HandshakeFailed;

    expect(outcome.isWorthRetrying, isFalse);
  });

  test('nothing listening reads as unreachable, and is worth retrying', () async {
    final endpoint = await deadEndpoint();

    final outcome = await client.handshake(endpoint);

    expect(outcome, isA<HandshakeFailed>());
    final failure = outcome as HandshakeFailed;
    expect(failure.problem, ConnectionProblem.unreachable);
    expect(failure.isWorthRetrying, isTrue);
  });

  test('an exception this code cannot name is still an answer', () async {
    // docs/recovery.md: every waiting state has a bound and an exit. An
    // exception escaping the handshake would leave the app in `Connecting…`
    // with neither. CertificateException is a sibling of HandshakeException
    // rather than a subtype, so catching by name alone is not enough.
    for (final error in <Object>[
      const CertificateException('self-signed'),
      const TlsException('handshake in the wrong order'),
      const FileSystemException('the platform surprised us'),
      StateError('something nobody predicted'),
    ]) {
      final failing = GatewayClient(language: () => 'en', httpClient: ThrowingHttpClient(error));
      addTearDown(failing.dispose);

      final outcome = await failing.handshake(
        Endpoint.tryParse('192.0.2.42')!,
      );

      expect(
        (outcome as HandshakeFailed).problem,
        ConnectionProblem.unreachable,
        reason: '$error escaped the handshake',
      );
    }
  });

  test('a gateway whose generator is down still identifies itself', () async {
    final gateway = await FakeGateway.start(
      info: <String, Object?>{
        ...FakeGateway.healthyInfo,
        'comfy': <String, Object?>{
          'status': 'unavailable',
          'detail': 'It is not answering on its port.',
        },
      },
    );
    addTearDown(gateway.stop);

    final outcome = await client.handshake(gateway.endpoint);

    // A healthy gateway with a down backend is a *successful* handshake; the
    // difference is carried in comfy.status, not in a connection failure.
    expect(outcome, isA<HandshakeSucceeded>());
    final identity = (outcome as HandshakeSucceeded).identity;
    expect(identity.comfyStatus, ComfyStatus.unavailable);
    expect(identity.comfyDetail, 'It is not answering on its port.');
  });

  test('capabilities the gateway does not claim are false', () async {
    final gateway = await FakeGateway.start(
      info: <String, Object?>{
        ...FakeGateway.healthyInfo,
        'capabilities': <String, Object?>{'cancel': true},
      },
    );
    addTearDown(gateway.stop);

    final identity =
        (await client.handshake(gateway.endpoint) as HandshakeSucceeded).identity;

    expect(identity.capabilities.cancel, isTrue);
    expect(identity.capabilities.mediaUpload, isFalse);
    expect(identity.capabilities.events, isFalse);
  });
}
