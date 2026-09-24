/// A gateway made of `dart:io`, for the connection tests.
///
/// It is a real HTTP server on loopback, so the client under test does real
/// requests, real timeouts and real socket failures — and it is not a
/// LocalCanvas gateway, so nothing here can quietly satisfy an assertion the
/// production code was supposed to satisfy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:localcanvas/connection/endpoint.dart';

class FakeGateway {
  FakeGateway._(this._server, this._basePath);

  final HttpServer _server;
  final String _basePath;

  /// Every path this server was asked for, in order.
  final List<String> requestedPaths = <String>[];

  /// Every request in full — method, headers and the body as it arrived.
  /// A POST is read to the end here, so a test can assert what actually
  /// crossed the socket rather than what the client meant to send.
  final List<RecordedRequest> requests = <RecordedRequest>[];

  /// What to answer with. Change it between requests to script a sequence.
  int statusCode = 200;
  String contentType = 'application/json';
  String body = '';

  /// Answers for particular paths, which take precedence over [body]. The key
  /// is the full path including any base path this server is mounted behind,
  /// which is what makes a wrongly joined URL fail rather than pass.
  final Map<String, _Answer> _routes = <String, _Answer>{};

  /// Scripted sequences, consulted before [_routes].
  final Map<String, List<_Answer>> _sequences = <String, List<_Answer>>{};

  /// The full path of a reference on this server, prefix included.
  String pathOf(String reference) => '$_basePath$reference';

  /// Serves [body] as JSON at [reference], relative to the base endpoint.
  void serveJson(String reference, Object? body, {int status = 200}) {
    _routes[pathOf(reference)] = _Answer(status, jsonEncode(body));
  }

  /// Serves text that is not JSON at all, for the unreadable-answer case.
  void serveRaw(String reference, String body, {int status = 200}) {
    _routes[pathOf(reference)] = _Answer(status, body);
  }

  /// Serves bytes with a content type of their own — a generated picture, as
  /// `GET /api/v1/jobs/{id}/result/{index}` returns one.
  void serveBytes(
    String reference,
    List<int> bytes, {
    int status = 200,
    String contentType = 'application/octet-stream',
  }) {
    _routes[pathOf(reference)] = _Answer(
      status,
      '',
      bytes: bytes,
      contentType: contentType,
    );
  }

  /// Serves a sequence: each request to [reference] takes the next answer, and
  /// the last one repeats. How a job that changes state is scripted.
  void serveJsonSequence(String reference, List<Object?> bodies) {
    _sequences[pathOf(reference)] = bodies
        .map((body) => _Answer(200, jsonEncode(body)))
        .toList();
  }

  /// A path that answers with a status and no useful body — 404, in practice.
  void serveStatus(String reference, int status) {
    _routes[pathOf(reference)] = _Answer(status, '{}');
  }

  static const Map<String, Object?> healthyInfo = <String, Object?>{
    'service': 'localcanvas',
    'api_version': 1,
    'gateway_version': '0.1.0',
    'display_name': 'Studio PC',
    'comfy': <String, Object?>{'status': 'ready', 'detail': null},
    'capabilities': <String, Object?>{
      'cancel': false,
      'media_upload': false,
      'events': false,
    },
  };

  /// Starts a server. [basePath] mounts it behind a path prefix, which is how
  /// the resolution rule in `docs/transport-boundary.md` §3 gets exercised.
  static Future<FakeGateway> start({
    Map<String, Object?> info = healthyInfo,
    String basePath = '',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeGateway._(server, basePath)..body = jsonEncode(info);
    server.listen((request) async {
      fake.requestedPaths.add(request.uri.path);
      final body = <int>[];
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      fake.requests.add(
        RecordedRequest(
          method: request.method,
          path: request.uri.path,
          contentType: request.headers.contentType?.toString(),
          contentLength: request.contentLength,
          accept: request.headers.value('accept'),
          acceptLanguage: request.headers.value('accept-language'),
          body: body,
        ),
      );
      final sequence = fake._sequences[request.uri.path];
      final _Answer? routed;
      if (sequence != null && sequence.isNotEmpty) {
        routed = sequence.length == 1 ? sequence.first : sequence.removeAt(0);
      } else {
        routed = fake._routes[request.uri.path];
      }
      request.response.statusCode = routed?.status ?? fake.statusCode;
      request.response.headers.contentType = ContentType.parse(
        routed?.contentType ?? fake.contentType,
      );
      if (routed?.bytes != null) {
        request.response.add(routed!.bytes!);
      } else {
        request.response.write(routed?.body ?? fake.body);
      }
      await request.response.close();
    });
    return fake;
  }

  int get port => _server.port;

  /// The endpoint an app would be given for this server.
  Endpoint get endpoint =>
      Endpoint.tryParse('http://127.0.0.1:$port$_basePath')!;

  /// The pairing code this server would show.
  String get pairingPayload =>
      'localcanvas://connect?endpoint=${endpoint.canonical}';

  Future<void> stop() => _server.close(force: true);
}

/// One request as the server saw it.
class RecordedRequest {
  const RecordedRequest({
    required this.method,
    required this.path,
    required this.contentType,
    required this.contentLength,
    required this.body,
    this.accept,
    this.acceptLanguage,
  });

  final String method;
  final String path;
  final String? contentType;

  /// What the client said it could read back, as it arrived on the wire. The
  /// media upload sets this one by hand, so it is worth being able to see that
  /// the language header went *beside* it rather than over it.
  final String? accept;

  /// What the client told the gateway about the language on screen, as it
  /// arrived on the wire (T-0142). `null` when the header was absent, which
  /// is the state a test has to be able to tell from `en`.
  final String? acceptLanguage;

  /// `-1` when the client sent the body chunked, which is what an upload of
  /// unknown length does.
  final int contentLength;
  final List<int> body;

  /// The body as text, for asserting on the multipart envelope. The file part
  /// is binary, so malformed sequences are allowed rather than fatal.
  String get bodyText => utf8.decode(body, allowMalformed: true);
}

class _Answer {
  const _Answer(this.status, this.body, {this.bytes, this.contentType});

  final int status;
  final String body;

  /// Set instead of [body] when the answer is not text.
  final List<int>? bytes;

  /// Overrides the server's own content type for this one answer.
  final String? contentType;
}

/// An address nothing is listening on: a port that was bound and released.
///
/// A closed port refuses the connection immediately, which is the "nothing
/// answered" case without a test that waits out a timeout.
Future<Endpoint> deadEndpoint() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return Endpoint.tryParse('http://127.0.0.1:$port')!;
}
