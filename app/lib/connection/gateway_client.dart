/// The identity handshake (`docs/api.md`, `docs/connection.md`).
///
/// Every connection path ends here. The client refuses to treat an arbitrary
/// HTTP service as a gateway, and every attempt is bounded by a timeout — a
/// request that hangs is a request that would otherwise hold a screen forever.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../l10n/accept_language.dart';
import 'connection_problem.dart';
import 'endpoint.dart';
import 'gateway_identity.dart';

/// The handshake path, relative to the base endpoint. It is resolved against
/// the endpoint rather than concatenated, so a path-mounted gateway works.
const String kInfoPath = '/api/v1/info';

/// The outcome of one handshake.
sealed class HandshakeOutcome {
  const HandshakeOutcome();
}

/// The gateway identified itself and speaks a version this build supports.
/// ComfyUI may still be down — that is [GatewayIdentity.comfyStatus] to read,
/// not a failure to connect.
final class HandshakeSucceeded extends HandshakeOutcome {
  const HandshakeSucceeded(this.endpoint, this.identity);

  final Endpoint endpoint;
  final GatewayIdentity identity;
}

/// The handshake did not produce a usable gateway.
final class HandshakeFailed extends HandshakeOutcome {
  const HandshakeFailed(this.notice, {this.serverApiVersion});

  final ConnectionNotice notice;
  final int? serverApiVersion;

  ConnectionProblem get problem => notice.problem;

  /// Whether trying the very same address again could plausibly help. A
  /// wrong-version or wrong-service answer is a settled fact about the other
  /// end; retrying it is a loop with no exit.
  bool get isWorthRetrying => problem == ConnectionProblem.unreachable;
}

class GatewayClient {
  GatewayClient({
    required this.language,
    http.Client? httpClient,
    this.timeout = kHandshakeTimeout,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The language on screen, asked for at the moment a request is built rather
  /// than captured when this client was composed. Required, so a composition
  /// that forgot to tell the gateway which language a person reads does not
  /// compile (T-0142).
  final LanguageTagSource language;

  /// Short and bounded: `docs/connection.md` asks for a few seconds, not a
  /// spinner forever.
  static const Duration kHandshakeTimeout = Duration(seconds: 4);

  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;

  /// Asks an endpoint who it is.
  Future<HandshakeOutcome> handshake(Endpoint endpoint) async {
    final http.Response response;
    try {
      response = await _http
          .get(
            endpoint.resolvePath(kInfoPath),
            headers: jsonHeaders(language),
          )
          .timeout(timeout);
    } on TimeoutException {
      return _unreachable(endpoint);
    } on SocketException {
      return _unreachable(endpoint);
    } on HttpException {
      return _unreachable(endpoint);
    } on http.ClientException {
      return _unreachable(endpoint);
    } on HandshakeException {
      // A TLS failure is a failure to reach the server, not a wrong server.
      return _unreachable(endpoint);
    } catch (_) {
      // Everything else the socket, the DNS resolver or the TLS stack can
      // throw — `CertificateException` is a sibling of `HandshakeException`
      // rather than a subtype, and platforms add their own. Whatever it was,
      // the request did not reach a gateway, and an escaping exception would
      // leave the app in `Connecting…` with no way out, which
      // `docs/recovery.md` forbids. Every waiting state has an exit.
      return _unreachable(endpoint);
    }

    if (response.statusCode != 200) return _notLocalCanvas(endpoint);

    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return _notLocalCanvas(endpoint);
    }

    final identity = GatewayIdentity.tryFromJson(body);
    if (identity == null) return _notLocalCanvas(endpoint);

    if (!identity.isSupportedVersion) {
      return HandshakeFailed(
        describeProblem(
          ConnectionProblem.incompatibleVersion,
          address: endpoint.display,
          serverName: identity.displayName,
          serverApiVersion: identity.apiVersion,
        ),
        serverApiVersion: identity.apiVersion,
      );
    }

    return HandshakeSucceeded(endpoint, identity);
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }

  static HandshakeFailed _unreachable(Endpoint endpoint) => HandshakeFailed(
    describeProblem(ConnectionProblem.unreachable, address: endpoint.display),
  );

  static HandshakeFailed _notLocalCanvas(Endpoint endpoint) => HandshakeFailed(
    describeProblem(ConnectionProblem.notLocalCanvas, address: endpoint.display),
  );
}
