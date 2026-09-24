/// The four job endpoints against a real server on loopback (`docs/api.md`).
///
/// `dart:io` on the other end, the real transport in between: a wrongly joined
/// URL fails here rather than passing, and a 404 is a real 404 rather than a
/// mocked one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/generation/job_models.dart';
import 'package:localcanvas/generation/jobs_api.dart';

import 'support/l10n.dart';
import 'support/fake_gateway.dart';
import 'support/generation_fakes.dart';

void main() {
  late FakeGateway server;
  late HttpJobsApi api;

  Future<void> startServer({String basePath = ''}) async {
    server = await FakeGateway.start(basePath: basePath);
    addTearDown(server.stop);
    api = HttpJobsApi(language: () => 'en');
    addTearDown(api.dispose);
  }

  group('submit', () {
    test('sends the workflow and the input map, and brings back an id',
        () async {
      await startServer();
      server.serveJson(kJobsPath, <String, Object?>{
        'job_id': 'j-8f21',
        'state': 'queued',
        'created_at': '2026-09-02T19:41:00Z',
      }, status: 201);

      final submission = await api.submit(
        server.endpoint,
        workflowId: 'example_workflow',
        inputs: <String, Object?>{
          'prompt': 'a rainy alley at night',
          'steps': 24,
          'source_image': <String, Object?>{'media_id': 'm-3f9c1a'},
        },
      );

      expect(submission.jobId, 'j-8f21');
      expect(submission.state, JobState.queued);

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/jobs');
      expect(request.bodyText, contains('"workflow_id":"example_workflow"'));
      expect(request.bodyText, contains('"prompt":"a rainy alley at night"'));
      expect(request.bodyText, contains('"media_id":"m-3f9c1a"'));
    });

    test('says nothing about translation unless it is switching it off',
        () async {
      // The request every client made before the override existed, and the
      // one a gateway older than it has to keep understanding.
      await startServer();
      server.serveJson(kJobsPath, <String, Object?>{
        'job_id': 'j-8f21',
        'state': 'queued',
      }, status: 201);

      await api.submit(
        server.endpoint,
        workflowId: 'w',
        inputs: const <String, Object?>{'prompt': 'a cat'},
      );

      expect(server.requests.single.bodyText, isNot(contains('translation')));
    });

    test('switching translation off sends the one word that can (`off`)',
        () async {
      await startServer();
      server.serveJson(kJobsPath, <String, Object?>{
        'job_id': 'j-8f21',
        'state': 'queued',
      }, status: 201);

      await api.submit(
        server.endpoint,
        workflowId: 'w',
        inputs: const <String, Object?>{'prompt': 'кот в шляпе'},
        translate: false,
      );

      final body = server.requests.single.bodyText;
      expect(body, contains('"translation":{"mode":"off"}'));
      // The text itself is sent exactly as typed either way: the override is
      // about the gateway's stage, never about the user's words.
      expect(body, contains('кот в шляпе'));
    });

    test('a path-mounted gateway is resolved, not concatenated', () async {
      await startServer(basePath: '/localcanvas');
      server.serveJson(kJobsPath, <String, Object?>{
        'job_id': 'j-1',
        'state': 'queued',
      }, status: 201);

      await api.submit(
        server.endpoint,
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );

      expect(server.requestedPaths, <String>['/localcanvas/api/v1/jobs']);
    });

    test("a refusal arrives as this app's own sentence for the gateway's code, "
        'never a number', () async {
      await startServer();
      server.serveJson(kJobsPath, <String, Object?>{
        'error': <String, Object?>{
          'code': 'workflow_not_found',
          'message': 'That workflow is no longer available.',
          'field': null,
        },
      }, status: 404);

      await expectLater(
        api.submit(
          server.endpoint,
          workflowId: 'gone',
          inputs: const <String, Object?>{},
        ),
        throwsA(
          isA<JobFailure>()
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

    test('nothing listening is a sentence, not an escaping exception',
        () async {
      final dead = await deadEndpoint();
      final client = HttpJobsApi(language: () => 'en');
      addTearDown(client.dispose);

      await expectLater(
        client.submit(dead, workflowId: 'w', inputs: const <String, Object?>{}),
        throwsA(isA<JobFailure>()),
      );
    });
  });

  group('the snapshot', () {
    test('reads state, real progress and results', () async {
      await startServer();
      server.serveJson('$kJobsPath/j-8f21', <String, Object?>{
        'job_id': 'j-8f21',
        'workflow_id': 'example_workflow',
        'state': 'running',
        'progress': <String, Object?>{'step': 7, 'total': 24},
        'results': <Object?>[],
        'error': null,
      });

      final snapshot = await api.snapshot(server.endpoint, 'j-8f21');

      expect(snapshot!.state, JobState.running);
      expect(snapshot.progress, const JobProgress(step: 7, total: 24));
      expect(snapshot.results, isEmpty);
      expect(server.requestedPaths, <String>['/api/v1/jobs/j-8f21']);
    });

    test('a 404 is null — the gateway does not have this job', () async {
      await startServer();
      server.serveStatus('$kJobsPath/j-gone', 404);

      expect(await api.snapshot(server.endpoint, 'j-gone'), isNull);
    });

    test('a job id with awkward characters is encoded into the path',
        () async {
      await startServer();
      server.serveJson('$kJobsPath/j%2F8f%2021', <String, Object?>{
        'state': 'queued',
      });

      final snapshot = await api.snapshot(server.endpoint, 'j/8f 21');

      expect(snapshot!.jobId, 'j/8f 21');
      expect(server.requestedPaths.single, '/api/v1/jobs/j%2F8f%2021');
    });
  });

  group('cancel', () {
    test('reports the state the job actually reached', () async {
      await startServer();
      server.serveJson('$kJobsPath/j-8f21/cancel', <String, Object?>{
        'job_id': 'j-8f21',
        'state': 'completed',
        'results': <Object?>[
          <String, Object?>{
            'index': 0,
            'kind': 'image',
            'media_type': 'image/png',
            'path': '/api/v1/jobs/j-8f21/result/0',
          },
        ],
      });

      final snapshot = await api.cancel(server.endpoint, 'j-8f21');

      // A cancel request is not a cancelled outcome.
      expect(snapshot.state, JobState.completed);
      expect(snapshot.results.single.index, 0);
      expect(server.requests.single.method, 'POST');
      expect(server.requestedPaths.single, '/api/v1/jobs/j-8f21/cancel');
    });

    test('a reply that names only the state still names the job', () async {
      await startServer();
      server.serveJson('$kJobsPath/j-8f21/cancel', <String, Object?>{
        'state': 'cancelled',
      });

      final snapshot = await api.cancel(server.endpoint, 'j-8f21');

      expect(snapshot.jobId, 'j-8f21');
      expect(snapshot.state, JobState.cancelled);
    });
  });

  group('the result bytes', () {
    test('come back with the type the server declared, under a name of ours',
        () async {
      await startServer();
      server.serveBytes(
        '/api/v1/jobs/j-8f21/result/0',
        tinyPng,
        contentType: 'image/png',
      );

      final bytes = await api.fetchResult(server.endpoint, imageResult);

      expect(bytes.bytes, tinyPng);
      expect(bytes.mediaType, 'image/png');
      // A name, never a path: nothing of the gateway's own layout crosses.
      expect(bytes.filename, 'localcanvas-0.png');
      expect(bytes.filename, isNot(contains('/')));
    });

    test('the reference is resolved against a path-mounted endpoint',
        () async {
      await startServer(basePath: '/lc');
      server.serveBytes(
        '/api/v1/jobs/j-8f21/result/0',
        tinyPng,
        contentType: 'image/png',
      );

      await api.fetchResult(server.endpoint, imageResult);

      expect(server.requestedPaths, <String>['/lc/api/v1/jobs/j-8f21/result/0']);
    });

    test('a result that is gone is a sentence, not bytes', () async {
      await startServer();
      server.serveJson('/api/v1/jobs/j-8f21/result/0', <String, Object?>{
        'error': <String, Object?>{'message': 'That result has expired.'},
      }, status: 410);

      await expectLater(
        api.fetchResult(server.endpoint, imageResult),
        throwsA(
          isA<JobFailure>().having(
            (f) => f.message(en),
            'message',
            'That result has expired.',
          ),
        ),
      );
    });
  });
}
