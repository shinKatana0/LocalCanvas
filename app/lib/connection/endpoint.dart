/// The base endpoint — the app's entire connection state (`docs/connection.md`).
///
/// Every request URL in the app is derived from one of these. Nothing
/// reconstructs a host from anything else, nothing assumes RFC1918, nothing
/// assumes `http` over `https`, and nothing hardcodes `ws://`
/// (`docs/transport-boundary.md` §1 and §2).
library;

import 'package:flutter/foundation.dart';

/// The port a LocalCanvas gateway uses when the address does not say.
const int kDefaultGatewayPort = 7801;

/// Hosts we can express. An endpoint is refused only for being unexpressible
/// by this client -- unparseable text, a scheme that is not `http`/`https`, or
/// an address carrying credentials v0.1 cannot honour and must not silently
/// drop -- and never for being public, non-RFC1918 or HTTPS
/// (`docs/transport-boundary.md` §4).
final RegExp _hostPattern = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9._\-]*[A-Za-z0-9])?$');
final RegExp _schemePrefix = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');

@immutable
class Endpoint {
  const Endpoint._(this.uri);

  /// The normalized endpoint: scheme, host, port and any path prefix it
  /// carries. Never a query, never a fragment, never credentials.
  final Uri uri;

  String get scheme => uri.scheme;
  String get host => uri.host;
  int get port => uri.port;

  /// The path prefix the endpoint sits behind, `''` when it sits at the root.
  String get pathPrefix => uri.path;

  /// `ws` or `wss`, derived from the endpoint's own scheme. No socket is opened
  /// in this build; the derivation lives with the endpoint because that is the
  /// only place that can get it right (`docs/transport-boundary.md` §2).
  String get webSocketScheme => scheme == 'https' ? 'wss' : 'ws';

  /// Reads an address the way a person types or pastes one.
  ///
  /// Accepts `host`, `host:port`, `http://…`, `https://…` and bracketed IPv6.
  /// Applies the default scheme `http` and the default port
  /// [kDefaultGatewayPort] only where they are absent — and, for an explicit
  /// `https` address with no port, lets the scheme imply its own port, which is
  /// what `docs/connection.md` shows for `https://generation.example.com`.
  ///
  /// "Absent" is decided on the text the user gave, not on [Uri.hasPort]:
  /// `Uri.parse` normalizes a scheme-default port out of existence, so
  /// `http://host:80` arrives here indistinguishable from `http://host`. A
  /// port the user typed is never absent, and replacing an explicit `:80` with
  /// 7801 would connect somewhere else without saying so — and would leave a
  /// gateway behind a proxy on port 80 with no address that can reach it.
  ///
  /// Returns `null` only when the input cannot be read as an address. Being
  /// public, routable or HTTPS is never a reason.
  static Endpoint? tryParse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    final hadScheme = _schemePrefix.hasMatch(raw);
    final withScheme = hadScheme ? raw : 'http://$raw';
    final Uri parsed;
    try {
      parsed = Uri.parse(withScheme);
    } on FormatException {
      return null;
    }

    final scheme = parsed.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;

    final host = parsed.host;
    if (host.isEmpty) return null;
    // A bracketed literal survives Uri.parse as a bare IPv6 host; anything
    // else has to look like a hostname or an IPv4 address.
    if (!host.contains(':') && !_hostPattern.hasMatch(host)) return null;

    // v0.1 has no authentication, so an address carrying credentials is not
    // something this app can honour — and silently dropping them would connect
    // to somewhere the user did not ask for.
    if (parsed.userInfo.isNotEmpty) return null;

    // `parsed.port` is the scheme's own default when no port survived
    // parsing, which is exactly what an explicitly typed `:80` or `:443`
    // means; only a genuinely absent port falls through to the default.
    final int port = (parsed.hasPort || _carriesExplicitPort(withScheme))
        ? parsed.port
        : (scheme == 'https' ? 443 : kDefaultGatewayPort);
    if (port < 1 || port > 65535) return null;

    return Endpoint._(
      Uri(scheme: scheme, host: host, port: port, path: _trimPath(parsed.path)),
    );
  }

  /// The endpoint a discovered or scanned `host` + `port` names. Bracketing is
  /// this function's job so no caller has to know an address family.
  static Endpoint? fromHostPort(String host, int port, {String scheme = 'http'}) {
    final literal = host.contains(':') ? '[$host]' : host;
    return tryParse('$scheme://$literal:$port');
  }

  /// Resolves a path the gateway returned against this endpoint, **preserving
  /// the endpoint's own path prefix** (`docs/transport-boundary.md` §3).
  ///
  /// Root-absolute joining would drop that prefix and break the moment the
  /// gateway sits behind a path-mounted proxy.
  Uri resolvePath(String reference) {
    final queryAt = reference.indexOf('?');
    final rawPath = queryAt < 0 ? reference : reference.substring(0, queryAt);
    final query = queryAt < 0 ? null : reference.substring(queryAt + 1);
    final relative = rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
    final prefix = pathPrefix;
    return uri.replace(
      path: prefix.isEmpty ? '/$relative' : '$prefix/$relative',
      query: query,
    );
  }

  /// The WebSocket URL for a path, scheme derived from this endpoint.
  Uri webSocketUri(String reference) =>
      resolvePath(reference).replace(scheme: webSocketScheme);

  /// The canonical text form — what is stored, shown, and read back.
  ///
  /// The port is written out unless leaving it off would be read back as the
  /// very same port. Only `https` on 443 qualifies: `http://host:80` written
  /// as `http://host` would come back as `http://host:7801`, which is how a
  /// remembered gateway on port 80 would be lost across a restart.
  String get canonical {
    if (scheme == 'https' && port == 443) return uri.toString();
    final authority = host.contains(':') ? '[$host]' : host;
    return '$scheme://$authority:$port$pathPrefix';
  }

  /// What a person should see: the address without the machinery.
  String get display => canonical;

  @override
  String toString() => canonical;

  @override
  bool operator ==(Object other) =>
      other is Endpoint && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  /// Whether the address as written carries its own `:port`.
  ///
  /// Asked of the text rather than of the parsed [Uri], because the parse is
  /// precisely what loses this: a port equal to the scheme's default is
  /// dropped, and `hasPort` then says "absent" about something the user typed.
  static bool _carriesExplicitPort(String address) {
    final schemeEnd = address.indexOf('://');
    final start = schemeEnd < 0 ? 0 : schemeEnd + 3;
    var end = address.length;
    for (final delimiter in const <String>['/', '?', '#']) {
      final at = address.indexOf(delimiter, start);
      if (at >= 0 && at < end) end = at;
    }
    final authority = address.substring(start, end);
    final userInfo = authority.lastIndexOf('@');
    final hostAndPort = userInfo < 0
        ? authority
        : authority.substring(userInfo + 1);
    // Colons inside a bracketed IPv6 literal are the address, not a port.
    final bracketEnd = hostAndPort.lastIndexOf(']');
    final colon = hostAndPort.indexOf(':', bracketEnd < 0 ? 0 : bracketEnd + 1);
    if (colon < 0) return false;
    final digits = hostAndPort.substring(colon + 1);
    return digits.isNotEmpty && int.tryParse(digits) != null;
  }

  static String _trimPath(String path) {
    var value = _stripTrailingSlashes(path);
    // A pasted `…/api/v1` is the address bar of someone who checked the
    // gateway in a browser first. Take it off rather than refusing it.
    if (value.toLowerCase().endsWith('/api/v1')) {
      value = value.substring(0, value.length - '/api/v1'.length);
      value = _stripTrailingSlashes(value);
    }
    return value;
  }

  static String _stripTrailingSlashes(String value) {
    var end = value.length;
    while (end > 0 && value.codeUnitAt(end - 1) == 0x2F) {
      end--;
    }
    return value.substring(0, end);
  }
}
