/// The event stream, against a real WebSocket on loopback (`docs/api.md`).
///
/// Half of this file is about the URL. `Endpoint.webSocketUri` produces a
/// `Uri` whose `.port` is **0** whenever the endpoint sits on its scheme's own
/// port, because Dart registers no default port for `ws`/`wss`.
///
/// Writing that 0 back out through a `Uri` erases it, so a reassembly that
/// round-trips is harmless. Interpolated into a **string** it survives, and the
/// socket goes nowhere. The difference is a property of `Uri`, not of the text,
/// which is why the last group here pins the string `WebSocketJobEvents.connect`
/// actually opens rather than the `Uri` one step upstream of it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/generation/job_events.dart';
import 'package:localcanvas/generation/job_models.dart';

void main() {
  group('the target URL', () {
    test('is derived from the endpoint, scheme and all', () {
      final endpoint = Endpoint.tryParse('http://192.0.2.42:7801')!;

      expect(
        jobEventsUri(endpoint, 'j-8f21').toString(),
        'ws://192.0.2.42:7801/api/v1/jobs/j-8f21/events',
      );
      expect(
        jobEventsUri(
          Endpoint.tryParse('https://generation.example.com')!,
          'j-8f21',
        ).toString(),
        'wss://generation.example.com/api/v1/jobs/j-8f21/events',
      );
    });

    test('a gateway on port 80 is addressed correctly, and .port lies', () {
      final endpoint = Endpoint.tryParse('http://gateway.example.com:80')!;
      final target = jobEventsUri(endpoint, 'j-1');

      // What goes on the wire. `ws` with no port written means 80, which is
      // the port this endpoint is on.
      expect(
        target.toString(),
        'ws://gateway.example.com/api/v1/jobs/j-1/events',
      );
      expect(target.toString(), isNot(contains(':0')));

      // And the trap itself, pinned so that a rewrite of the derivation that
      // reads this getter is caught here rather than on a device.
      expect(target.port, 0);
      expect(endpoint.port, 80);
    });

    test('an https gateway on 443 is the same trap', () {
      final endpoint = Endpoint.tryParse('https://example.com:443')!;
      final target = jobEventsUri(endpoint, 'j-1');

      expect(target.toString(), 'wss://example.com/api/v1/jobs/j-1/events');
      expect(target.toString(), isNot(contains(':0')));
      expect(target.port, 0);
      expect(endpoint.port, 443);
    });

    test('a path-mounted gateway keeps its prefix', () {
      final endpoint = Endpoint.tryParse('http://host:7801/localcanvas')!;

      expect(
        jobEventsUri(endpoint, 'j-1').toString(),
        'ws://host:7801/localcanvas/api/v1/jobs/j-1/events',
      );
    });

    test('a job id with awkward characters is encoded', () {
      final endpoint = Endpoint.tryParse('http://host:7801')!;

      expect(
        jobEventsUri(endpoint, 'j/8f 21').toString(),
        'ws://host:7801/api/v1/jobs/j%2F8f%2021/events',
      );
    });
  });

  group('reading a message', () {
    test('the four shapes the contract sends', () {
      expect(
        parseJobEvent(<String, Object?>{'type': 'state', 'state': 'running'}),
        isA<JobStateEvent>().having(
          (e) => e.state,
          'state',
          JobState.running,
        ),
      );
      expect(
        parseJobEvent(<String, Object?>{
          'type': 'progress',
          'step': 7,
          'total': 24,
        }),
        isA<JobProgressEvent>().having(
          (e) => e.progress,
          'progress',
          const JobProgress(step: 7, total: 24),
        ),
      );
      expect(
        parseJobEvent(<String, Object?>{
          'type': 'result',
          'results': <Object?>[
            <String, Object?>{
              'index': 0,
              'kind': 'image',
              'media_type': 'image/png',
              'path': '/api/v1/jobs/j-1/result/0',
            },
          ],
        }),
        isA<JobResultsEvent>().having((e) => e.results, 'results', hasLength(1)),
      );
      expect(
        parseJobEvent(<String, Object?>{
          'type': 'error',
          'message': 'A model this workflow needs is missing.',
        }),
        isA<JobErrorEvent>().having(
          (e) => e.message,
          'message',
          'A model this workflow needs is missing.',
        ),
      );
    });

    test('a progress delta without real numbers is not an event', () {
      // The same rule as the snapshot's, in the place a socket could smuggle
      // a percentage past it.
      expect(
        parseJobEvent(<String, Object?>{'type': 'progress', 'percent': 42}),
        isNull,
      );
      expect(
        parseJobEvent(<String, Object?>{
          'type': 'progress',
          'step': 3,
          'total': 0,
        }),
        isNull,
      );
    });

    test('anything else is dropped rather than guessed at', () {
      expect(parseJobEvent(null), isNull);
      expect(parseJobEvent('running'), isNull);
      expect(parseJobEvent(<String, Object?>{'type': 'heartbeat'}), isNull);
      expect(
        parseJobEvent(<String, Object?>{'type': 'state', 'state': 'thinking'}),
        isNull,
      );
      expect(parseJobEvent(<String, Object?>{'type': 'error'}), isNull);
    });
  });

  group('a real socket', () {
    late HttpServer server;
    late List<String> frames;

    setUp(() async {
      frames = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        for (final frame in frames) {
          socket.add(frame);
        }
        await socket.close();
      });
      addTearDown(() => server.close(force: true));
    });

    Endpoint endpoint() =>
        Endpoint.tryParse('http://127.0.0.1:${server.port}')!;

    test('carries the deltas, in order, and ends when the socket does',
        () async {
      frames = <String>[
        jsonEncode(<String, Object?>{'type': 'state', 'state': 'running'}),
        jsonEncode(<String, Object?>{
          'type': 'progress',
          'step': 7,
          'total': 24,
        }),
        jsonEncode(<String, Object?>{'type': 'state', 'state': 'completed'}),
      ];

      final subscription = await const WebSocketJobEvents().connect(
        endpoint(),
        'j-8f21',
      );
      addTearDown(subscription.close);

      final events = await subscription.events.toList();

      expect(events, hasLength(3));
      expect((events[0] as JobStateEvent).state, JobState.running);
      expect((events[1] as JobProgressEvent).progress.step, 7);
      expect((events[2] as JobStateEvent).state, JobState.completed);
    });

    test('an unreadable frame is skipped, not turned into a state', () async {
      frames = <String>[
        'not json at all',
        jsonEncode(<String, Object?>{'type': 'weather', 'state': 'sunny'}),
        jsonEncode(<String, Object?>{'type': 'state', 'state': 'completed'}),
      ];

      final subscription = await const WebSocketJobEvents().connect(
        endpoint(),
        'j-8f21',
      );
      addTearDown(subscription.close);

      final events = await subscription.events.toList();

      expect(events, hasLength(1));
      expect((events.single as JobStateEvent).state, JobState.completed);
    });

    test('the socket is opened at the path the contract names', () async {
      final paths = <String>[];
      final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => listener.close(force: true));
      listener.listen((request) async {
        paths.add(request.uri.path);
        final socket = await WebSocketTransformer.upgrade(request);
        await socket.close();
      });

      final subscription = await const WebSocketJobEvents().connect(
        Endpoint.tryParse('http://127.0.0.1:${listener.port}/lc')!,
        'j-8f21',
      );
      await subscription.events.toList();
      await subscription.close();

      expect(paths, <String>['/lc/api/v1/jobs/j-8f21/events']);
    });

    test('a socket nothing is listening on fails rather than hangs', () async {
      final dead = await deadWebSocketEndpoint();

      await expectLater(
        const WebSocketJobEvents().connect(dead, 'j-1'),
        throwsA(anything),
      );
    });
  });

  group('the URL the socket is actually opened with', () {
    /// Records what `connect` hands the connector, and refuses to open
    /// anything — the endpoints that matter here are ones nothing can be bound
    /// on, and the URL is the whole assertion.
    Future<String> opened(Endpoint endpoint, String jobId) async {
      String? url;
      final events = WebSocketJobEvents(
        connector: (String value) async {
          url = value;
          throw const SocketException('not opening anything');
        },
      );
      await expectLater(events.connect(endpoint, jobId), throwsA(anything));
      expect(url, isNotNull, reason: 'connect never called the connector');
      return url!;
    }

    test('an endpoint on port 80 is opened with no port at all', () async {
      // The assertion the derived-`Uri` tests above cannot make: this is the
      // string, and a `:0` interpolated into one does not normalize away.
      final url = await opened(
        Endpoint.tryParse('http://gateway.example.com:80')!,
        'j-1',
      );

      expect(url, 'ws://gateway.example.com/api/v1/jobs/j-1/events');
      expect(url, isNot(contains(':0')));
    });

    test('an https endpoint on 443 is the same', () async {
      final url = await opened(Endpoint.tryParse('https://example.com:443')!, 'j-1');

      expect(url, 'wss://example.com/api/v1/jobs/j-1/events');
      expect(url, isNot(contains(':0')));
    });

    test('an endpoint on its own port keeps it, prefix and all', () async {
      final url = await opened(
        Endpoint.tryParse('http://192.0.2.42:7801/localcanvas')!,
        'j-8f21',
      );

      expect(url, 'ws://192.0.2.42:7801/localcanvas/api/v1/jobs/j-8f21/events');
    });

    test('the connector is what opens the real socket', () async {
      // The seam is not a fiction: with no connector given, the same call
      // reaches a real server and comes back with a real stream.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(jsonEncode(<String, Object?>{
          'type': 'state',
          'state': 'completed',
        }));
        await socket.close();
      });

      final subscription = await const WebSocketJobEvents().connect(
        Endpoint.tryParse('http://127.0.0.1:${server.port}')!,
        'j-1',
      );
      addTearDown(subscription.close);

      final events = await subscription.events.toList();
      expect((events.single as JobStateEvent).state, JobState.completed);
    });
  });
}

/// A port that was bound and released: the connection is refused at once.
Future<Endpoint> deadWebSocketEndpoint() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return Endpoint.tryParse('http://127.0.0.1:$port')!;
}
