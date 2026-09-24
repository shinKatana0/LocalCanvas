/// The two workflow endpoints, against a real server on loopback.
///
/// A real `dart:io` server rather than a stubbed HTTP client: the URL the
/// client builds is the URL the server is asked for, so a path joined wrongly
/// fails here instead of passing against a mock that never checked.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_models.dart';

import 'support/l10n.dart';
import 'support/fake_gateway.dart';
import 'support/workflow_payloads.dart';

void main() {
  late HttpWorkflowsApi api;

  setUp(() {
    api = HttpWorkflowsApi(
      language: () => 'en',
      timeout: const Duration(seconds: 3),
    );
    addTearDown(api.dispose);
  });

  Future<FakeGateway> gateway({String basePath = ''}) async {
    final server = await FakeGateway.start(basePath: basePath);
    addTearDown(server.stop);
    return server;
  }

  test('the list comes back in the order the gateway published it', () async {
    final server = await gateway();
    server.serveJson('/api/v1/workflows', examplesRegistry());

    final workflows = await api.list(server.endpoint);

    expect(workflows.map((w) => w.id), <String>[
      'example_txt2img',
      'example_img2img',
      'example_video',
    ]);
    expect(server.requestedPaths, <String>['/api/v1/workflows']);
  });

  test('one workflow comes back with its field schema', () async {
    final server = await gateway();
    server.serveJson('/api/v1/workflows/example_txt2img', txt2imgDetail());

    final detail = await api.detail(server.endpoint, 'example_txt2img');

    expect(detail.name, 'Example Text to Image');
    expect(detail.inputs, hasLength(8));
    expect(detail.mainFields.first.id, 'prompt');
  });

  test('a gateway behind a path prefix keeps its prefix', () async {
    final server = await gateway(basePath: '/localcanvas');
    server.serveJson('/api/v1/workflows', examplesRegistry());
    server.serveJson('/api/v1/workflows/example_video', videoDetail());

    await api.list(server.endpoint);
    await api.detail(server.endpoint, 'example_video');

    expect(server.requestedPaths, <String>[
      '/localcanvas/api/v1/workflows',
      '/localcanvas/api/v1/workflows/example_video',
    ]);
  });

  test('an id with awkward characters is still asked for as one path segment',
      () async {
    final server = await gateway();
    server.serveJson('/api/v1/workflows/a%20b', txt2imgDetail());

    await expectLater(
      api.detail(server.endpoint, 'a b'),
      completes,
    );
    expect(server.requestedPaths.single, '/api/v1/workflows/a%20b');
  });

  test("a refusal keeps the gateway's code and its words, and renders the "
      "app's own sentence for a code it knows", () async {
    // T-0142 changed what a person is shown here and not what is kept: the
    // failure still carries the gateway's sentence — an unknown code falls
    // back to it — but a code this app has a sentence for is rendered in the
    // language on screen instead.
    final server = await gateway();
    server.serveJson(
      '/api/v1/workflows/gone',
      <String, Object?>{
        'error': <String, Object?>{
          'code': 'workflow_not_found',
          'message': 'That workflow is no longer available.',
          'field': null,
        },
      },
      status: 404,
    );

    await expectLater(
      api.detail(server.endpoint, 'gone'),
      throwsA(
        isA<WorkflowsFailure>()
            .having((f) => f.code, 'code', 'workflow_not_found')
            .having(
              (f) => f.serverMessage,
              'serverMessage',
              'That workflow is no longer available.',
            )
            .having(
              (f) => f.message(en),
              'message',
              'That workflow is no longer on this server.',
            ),
      ),
    );
  });

  test("a code this app has no sentence for falls back to the gateway's own "
      'words rather than swallowing them', () async {
    final server = await gateway();
    server.serveJson(
      '/api/v1/workflows/broken',
      <String, Object?>{
        'error': <String, Object?>{
          'code': 'workflow_unusable',
          'message': 'That workflow cannot be turned into a graph.',
          'field': null,
        },
      },
      status: 500,
    );

    await expectLater(
      api.detail(server.endpoint, 'broken'),
      throwsA(
        isA<WorkflowsFailure>().having(
          (f) => f.message(en),
          'message',
          'That workflow cannot be turned into a graph.',
        ),
      ),
    );
  });

  test('a refusal with no message of its own does not show a status code',
      () async {
    final server = await gateway();
    server.serveJson('/api/v1/workflows', <String, Object?>{}, status: 500);

    try {
      await api.list(server.endpoint);
      fail('a 500 must not come back as a registry');
    } on WorkflowsFailure catch (failure) {
      expect('${failure.title(en)} ${failure.message(en)}', isNot(contains('500')));
      expect(failure.title(en), isNotEmpty);
      expect(failure.message(en), isNotEmpty);
    }
  });

  test('an answer that is not JSON is unreadable, not a crash', () async {
    final server = await gateway();
    server.serveRaw('/api/v1/workflows', '<html>hello</html>');

    await expectLater(
      api.list(server.endpoint),
      throwsA(isA<WorkflowsFailure>()),
    );
  });

  test('JSON of the wrong shape is unreadable too', () async {
    final server = await gateway();
    server.serveJson('/api/v1/workflows', <String, Object?>{'items': <Object?>[]});

    await expectLater(
      api.list(server.endpoint),
      throwsA(isA<WorkflowsFailure>()),
    );
  });

  test('an empty registry is an answer, not a failure', () async {
    final server = await gateway();
    server.serveJson('/api/v1/workflows', <String, Object?>{
      'workflows': <Object?>[],
    });

    expect(await api.list(server.endpoint), isEmpty);
  });

  test('nothing listening is reported as nothing answering', () async {
    final endpoint = await deadEndpoint();

    try {
      await api.list(endpoint);
      fail('a closed port must not come back as a registry');
    } on WorkflowsFailure catch (failure) {
      expect(failure.title(en), "The server didn't answer.");
      // No exception text, no address, no internals (`docs/ui-ux.md`).
      expect(failure.message(en), isNot(contains('SocketException')));
    }
  });

  test('a detail body missing its inputs is a workflow with no fields',
      () async {
    final server = await gateway();
    final body = Map<String, Object?>.from(txt2imgDetail())..remove('inputs');
    server.serveJson('/api/v1/workflows/example_txt2img', body);

    final detail = await api.detail(server.endpoint, 'example_txt2img');
    expect(detail, isA<WorkflowDetail>());
    expect(detail.inputs, isEmpty);
  });
}
