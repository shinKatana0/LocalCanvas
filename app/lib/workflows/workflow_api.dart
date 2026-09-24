/// The two workflow endpoints (`docs/api.md`).
///
/// Both are GETs against the base endpoint, resolved through
/// [Endpoint.resolvePath] so a path-mounted gateway keeps working
/// (`docs/transport-boundary.md` §3). Nothing here concatenates a URL.
///
/// Failures leave this file as *kinds*, never as sentences (T-0142). A status
/// code, a socket error and a malformed body are three different things to a
/// programmer and one thing to a user — "the server did not give me the list"
/// — so each becomes one of three kinds, and the screen turns the kind into
/// the words that say what to do about it, in the language on screen. None of
/// them carries exception text (`docs/ui-ux.md`).
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
import 'workflow_models.dart';

/// The registry list, relative to the base endpoint.
const String kWorkflowsPath = '/api/v1/workflows';

/// Short and bounded, like the handshake: a request that hangs is a screen
/// that never resolves.
const Duration kWorkflowsTimeout = Duration(seconds: 6);

/// The three ways the app can end up with no workflows to show.
enum WorkflowsFailureKind {
  /// Nothing answered, or the answer never arrived.
  unreachable,

  /// Something answered with a body this app cannot read as a registry.
  unreadable,

  /// The gateway said no, and said which of its codes it was.
  refused,
}

/// Why the app has no workflows to show.
@immutable
class WorkflowsFailure implements Exception {
  const WorkflowsFailure(this.kind, {this.code, this.serverMessage});

  const WorkflowsFailure.unreachable()
    : kind = WorkflowsFailureKind.unreachable,
      code = null,
      serverMessage = null;

  const WorkflowsFailure.unreadable()
    : kind = WorkflowsFailureKind.unreadable,
      code = null,
      serverMessage = null;

  /// The gateway said no. [code] is the token `docs/api.md` promises a client
  /// may branch on; [serverMessage] is what it wrote, kept for the codes this
  /// app has no sentence of its own for.
  const WorkflowsFailure.refused({this.code, this.serverMessage})
    : kind = WorkflowsFailureKind.refused;

  final WorkflowsFailureKind kind;
  final String? code;
  final String? serverMessage;

  String title(L l) => switch (kind) {
    WorkflowsFailureKind.unreachable => l.serverDidntAnswerTitle,
    WorkflowsFailureKind.unreadable => l.serverUnreadableTitle,
    WorkflowsFailureKind.refused => l.serverRefusedTitle,
  };

  String message(L l) => switch (kind) {
    WorkflowsFailureKind.unreachable => l.serverUnreachableMessage,
    WorkflowsFailureKind.unreadable => l.serverUnreadableMessage,
    WorkflowsFailureKind.refused => refusalSentence(
      l,
      code: code,
      serverMessage: serverMessage,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is WorkflowsFailure &&
      other.kind == kind &&
      other.code == code &&
      other.serverMessage == serverMessage;

  @override
  int get hashCode => Object.hash(kind, code, serverMessage);

  @override
  String toString() => 'WorkflowsFailure(${kind.name}, code: $code)';
}

/// The workflow registry, as the app can ask for it.
///
/// An interface so that a widget test can answer from a script instead of a
/// socket, while the transport itself is exercised against a real server.
abstract interface class WorkflowsApi {
  /// Every workflow the gateway publishes, in the order it publishes them.
  Future<List<WorkflowSummary>> list(Endpoint endpoint);

  /// One workflow with its field schema.
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId);
}

class HttpWorkflowsApi implements WorkflowsApi {
  HttpWorkflowsApi({
    required this.language,
    http.Client? httpClient,
    this.timeout = kWorkflowsTimeout,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The language on screen, asked for per request (T-0142).
  final LanguageTagSource language;

  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async {
    final body = await _get(endpoint.resolvePath(kWorkflowsPath));
    if (body is! Map || body['workflows'] is! List) {
      throw const WorkflowsFailure.unreadable();
    }
    return WorkflowSummary.listFromJson(body);
  }

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) async {
    final body = await _get(
      endpoint.resolvePath('$kWorkflowsPath/${Uri.encodeComponent(workflowId)}'),
    );
    final detail = WorkflowDetail.tryFromJson(body);
    if (detail == null) throw const WorkflowsFailure.unreadable();
    return detail;
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }

  Future<Object?> _get(Uri url) async {
    final http.Response response;
    try {
      response = await _http
          .get(url, headers: jsonHeaders(language))
          .timeout(timeout);
    } on TimeoutException {
      throw const WorkflowsFailure.unreachable();
    } on SocketException {
      throw const WorkflowsFailure.unreachable();
    } on HttpException {
      throw const WorkflowsFailure.unreachable();
    } on http.ClientException {
      throw const WorkflowsFailure.unreachable();
    } catch (_) {
      // Whatever else the socket, the resolver or the TLS stack throws: the
      // request did not come back, and an escaping exception would leave a
      // screen loading forever, which `docs/recovery.md` forbids.
      throw const WorkflowsFailure.unreachable();
    }

    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw response.statusCode == 200
          ? const WorkflowsFailure.unreadable()
          : const WorkflowsFailure.unreachable();
    }

    if (response.statusCode != 200) {
      // `docs/api.md`: a non-2xx carries an end-user readable message. When it
      // does not, this app supplies its own rather than showing a number.
      final error = body is Map ? body['error'] : null;
      final code = error is Map ? error['code'] : null;
      final message = error is Map ? error['message'] : null;
      final codeText = code is String && code.trim().isNotEmpty
          ? code.trim()
          : null;
      final messageText = message is String && message.trim().isNotEmpty
          ? message.trim()
          : null;
      throw codeText == null && messageText == null
          ? const WorkflowsFailure.unreadable()
          : WorkflowsFailure.refused(
              code: codeText,
              serverMessage: messageText,
            );
    }
    return body;
  }
}
