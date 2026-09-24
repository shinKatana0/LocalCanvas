/// The four job endpoints (`docs/api.md`).
///
/// Submit, snapshot, cancel, and the result bytes. Every URL is resolved
/// through [Endpoint.resolvePath], so a path-mounted gateway keeps working
/// (`docs/transport-boundary.md` §3); nothing here concatenates one.
///
/// Two answers are singled out because the honesty of the whole card rests on
/// them:
///
/// * **404 from the snapshot is not an error.** It is the gateway saying it no
///   longer has the job, so [JobsApi.snapshot] returns `null` rather than
///   throwing — a caller cannot mistake it for "the request failed, assume it
///   is still running".
/// * **The cancel reply is a state, not a promise.** Whatever it says the job
///   reached is what the client shows, including `completed`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../connection/endpoint.dart';
import '../l10n/accept_language.dart';
import '../l10n/app_localizations.dart';
import '../l10n/gateway_errors.dart';
import 'job_models.dart';

/// The jobs collection, relative to the base endpoint.
const String kJobsPath = '/api/v1/jobs';

/// Short and bounded, like every other request in this app: one that hangs is
/// a screen that never resolves (`docs/recovery.md`).
const Duration kJobsTimeout = Duration(seconds: 8);

/// Fetching the bytes of a result is a transfer, not a JSON round trip, so it
/// gets the same kind of backstop the media upload does: long enough for a
/// clip, short enough that a dead socket eventually gives up.
const Duration kResultTimeout = Duration(minutes: 5);

/// The three ways something about a job can fail.
enum JobFailureKind {
  /// Nothing answered, or the answer never arrived.
  unreachable,

  /// Something answered with a body this app cannot read.
  unreadable,

  /// The gateway said no, and said which of its codes it was.
  refused,
}

/// Why something about a job did not work.
///
/// Same discipline as `WorkflowsFailure` and `MediaFailure`: a status code, a
/// socket error and a malformed body are three things to a programmer and one
/// thing to a person — plus what to do next. No exception text ever reaches
/// the screen (`docs/ui-ux.md`), and since T-0142 no English sentence does
/// either: this carries the kind and the gateway's `code`, and the widget
/// that draws it decides the words.
@immutable
class JobFailure implements Exception {
  const JobFailure(this.kind, {this.code, this.serverMessage});

  const JobFailure.unreachable()
    : kind = JobFailureKind.unreachable,
      code = null,
      serverMessage = null;

  const JobFailure.unreadable()
    : kind = JobFailureKind.unreadable,
      code = null,
      serverMessage = null;

  /// The gateway said no. [code] is the token `docs/api.md` promises a client
  /// may branch on; [serverMessage] is what it wrote, kept for the codes this
  /// app has no sentence of its own for.
  const JobFailure.refused({this.code, this.serverMessage})
    : kind = JobFailureKind.refused;

  final JobFailureKind kind;
  final String? code;
  final String? serverMessage;

  String title(L l) => switch (kind) {
    JobFailureKind.unreachable => l.serverDidntAnswerTitle,
    JobFailureKind.unreadable => l.serverUnreadableTitle,
    JobFailureKind.refused => l.serverRefusedTitle,
  };

  String message(L l) => switch (kind) {
    JobFailureKind.unreachable => l.serverUnreachableMessage,
    JobFailureKind.unreadable => l.serverUnreadableMessage,
    JobFailureKind.refused => refusalSentence(
      l,
      code: code,
      serverMessage: serverMessage,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is JobFailure &&
      other.kind == kind &&
      other.code == code &&
      other.serverMessage == serverMessage;

  @override
  int get hashCode => Object.hash(kind, code, serverMessage);

  @override
  String toString() => 'JobFailure(${kind.name}, code: $code)';
}

/// The bytes of one result, in memory, with what is needed to name a file.
///
/// In memory and in this session only: there is no gallery and no history
/// here, and nothing is written to disk until the user asks for Save or Share
/// (`docs/ui-ux.md`).
@immutable
class ResultBytes {
  const ResultBytes({
    required this.bytes,
    required this.mediaType,
    required this.filename,
  });

  final Uint8List bytes;

  /// The `Content-Type` the gateway sent, or the one it declared in the
  /// snapshot when the response did not say.
  final String mediaType;

  /// A name for the file the user saves or shares. Ours, not the gateway's
  /// path: no directory component ever crosses (`docs/api.md`).
  final String filename;

  bool get isVideo => mediaType.startsWith('video/');
}

/// The jobs half of the gateway API.
///
/// An interface so a widget test can drive a lifecycle from a script, while
/// the transport itself is exercised against a real `dart:io` server.
abstract interface class JobsApi {
  /// `POST /api/v1/jobs`. The returned `job_id` is what makes recovery
  /// possible, so a caller records it before doing anything else.
  ///
  /// [translate] false is the per-submission override (`docs/api.md`): it asks
  /// the gateway to leave this submission's text alone. There is deliberately
  /// no way to ask for the opposite — true sends no override at all, which is
  /// the request every client made before the key existed, and leaves the
  /// decision where it already was, with the PC and the workflow.
  Future<JobSubmission> submit(
    Endpoint endpoint, {
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  });

  /// `GET /api/v1/jobs/{job_id}`.
  ///
  /// **`null` means the gateway answered 404** — it does not have this job.
  /// That is the honest signal that job state is gone (`docs/recovery.md`),
  /// and it is deliberately not an exception, so that "the request failed" and
  /// "the job is gone" cannot be handled by the same `catch`.
  Future<JobSnapshot?> snapshot(Endpoint endpoint, String jobId);

  /// `POST /api/v1/jobs/{job_id}/cancel` — returns the state the job actually
  /// reached, which may well be `completed`.
  Future<JobSnapshot> cancel(Endpoint endpoint, String jobId);

  /// `GET /api/v1/jobs/{job_id}/result/{index}` — the output bytes.
  Future<ResultBytes> fetchResult(Endpoint endpoint, JobResultRef result);
}

class HttpJobsApi implements JobsApi {
  HttpJobsApi({
    required this.language,
    http.Client? httpClient,
    this.timeout = kJobsTimeout,
    this.resultTimeout = kResultTimeout,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The language on screen, asked for per request (T-0142).
  final LanguageTagSource language;

  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;
  final Duration resultTimeout;

  @override
  Future<JobSubmission> submit(
    Endpoint endpoint, {
    required String workflowId,
    required Map<String, Object?> inputs,
    bool translate = true,
  }) async {
    final response = await _send(
      () => _http.post(
        endpoint.resolvePath(kJobsPath),
        headers: <String, String>{
          ...jsonHeaders(language),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, Object?>{
          'workflow_id': workflowId,
          'inputs': inputs,
          // Sent only to switch the stage off. The key is absent otherwise,
          // so a gateway that never heard of it sees the request it expects.
          if (!translate) 'translation': const <String, Object?>{'mode': 'off'},
        }),
      ),
      timeout,
    );
    final body = _decode(response);
    _throwIfRefused(response.statusCode, body, accept: _isCreated);
    final submission = JobSubmission.tryFromJson(body);
    if (submission == null) throw const JobFailure.unreadable();
    return submission;
  }

  @override
  Future<JobSnapshot?> snapshot(Endpoint endpoint, String jobId) async {
    final response = await _send(
      () => _http.get(
        _jobUri(endpoint, jobId),
        headers: jsonHeaders(language),
      ),
      timeout,
    );
    // The one status this app reads as information rather than as a failure.
    if (response.statusCode == HttpStatus.notFound) return null;
    final body = _decode(response);
    _throwIfRefused(response.statusCode, body);
    final snapshot = JobSnapshot.tryFromJson(body, fallbackJobId: jobId);
    if (snapshot == null) throw const JobFailure.unreadable();
    return snapshot;
  }

  @override
  Future<JobSnapshot> cancel(Endpoint endpoint, String jobId) async {
    final response = await _send(
      () => _http.post(
        _jobUri(endpoint, jobId, '/cancel'),
        headers: jsonHeaders(language),
      ),
      timeout,
    );
    final body = _decode(response);
    _throwIfRefused(response.statusCode, body);
    final snapshot = JobSnapshot.tryFromJson(body, fallbackJobId: jobId);
    if (snapshot == null) throw const JobFailure.unreadable();
    return snapshot;
  }

  @override
  Future<ResultBytes> fetchResult(
    Endpoint endpoint,
    JobResultRef result,
  ) async {
    final response = await _send(
      () => _http.get(endpoint.resolvePath(result.path)),
      resultTimeout,
    );
    if (response.statusCode != HttpStatus.ok) {
      // The body of a failed result fetch may not be JSON at all; whatever it
      // is, the user gets a sentence rather than a number.
      Object? body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        body = null;
      }
      _throwIfRefused(response.statusCode, body);
      throw const JobFailure.unreadable();
    }
    final declared = response.headers['content-type'];
    final mediaType = _mediaTypeOf(declared) ?? result.mediaType;
    return ResultBytes(
      bytes: response.bodyBytes,
      mediaType: mediaType,
      filename: resultFilename(result, mediaType: mediaType),
    );
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }

  Uri _jobUri(Endpoint endpoint, String jobId, [String suffix = '']) =>
      endpoint.resolvePath('$kJobsPath/${Uri.encodeComponent(jobId)}$suffix');

  Future<http.Response> _send(
    Future<http.Response> Function() request,
    Duration limit,
  ) async {
    try {
      return await request().timeout(limit);
    } on TimeoutException {
      throw const JobFailure.unreachable();
    } on SocketException {
      throw const JobFailure.unreachable();
    } on HttpException {
      throw const JobFailure.unreachable();
    } on http.ClientException {
      throw const JobFailure.unreachable();
    } catch (_) {
      // Whatever else the socket, the resolver or the TLS stack throws: the
      // request did not come back. An escaping exception would leave the app
      // generating forever, which `docs/recovery.md` forbids.
      throw const JobFailure.unreachable();
    }
  }

  static bool _isCreated(int status) =>
      status == HttpStatus.created || status == HttpStatus.ok;

  static Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  /// Turns a non-2xx into the gateway's own sentence where it gave one.
  static void _throwIfRefused(
    int status,
    Object? body, {
    bool Function(int status)? accept,
  }) {
    final ok = accept == null ? status >= 200 && status < 300 : accept(status);
    if (ok) return;
    final error = body is Map ? body['error'] : null;
    final message = JobSnapshot.readErrorMessage(error);
    final code = JobSnapshot.readErrorCode(error);
    throw message == null && code == null
        ? const JobFailure.unreadable()
        : JobFailure.refused(code: code, serverMessage: message);
  }

  static String? _mediaTypeOf(String? header) {
    if (header == null) return null;
    final value = header.split(';').first.trim();
    return value.isEmpty ? null : value;
  }
}

/// The name a saved or shared result carries.
///
/// Built here rather than taken from the gateway's `path`: that path is a URL
/// on someone else's machine, and no directory component of anything ever
/// crosses to the phone (`docs/api.md`).
String resultFilename(JobResultRef result, {String? mediaType}) {
  final type = mediaType ?? result.mediaType;
  return 'localcanvas-${result.index}${_extensionFor(type)}';
}

String _extensionFor(String mediaType) => switch (mediaType) {
  'image/png' => '.png',
  'image/jpeg' => '.jpg',
  'image/webp' => '.webp',
  'image/gif' => '.gif',
  'video/mp4' => '.mp4',
  'video/webm' => '.webm',
  'video/quicktime' => '.mov',
  // A type this build does not know keeps a neutral extension rather than a
  // guessed one; the bytes are still the bytes.
  _ => '.bin',
};
