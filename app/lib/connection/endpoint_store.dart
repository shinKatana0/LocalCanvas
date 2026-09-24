/// The remembered endpoint (`docs/connection.md` §1).
///
/// Only an endpoint that completed the identity handshake is ever written
/// here, so a typo the user never connected to can never displace a working
/// server. Enforcing that is the caller's job; this file only stores what it
/// is given, and nothing calls [EndpointStore.remember] except the code path
/// that has a successful handshake in hand.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'endpoint.dart';

@immutable
class RememberedServer {
  const RememberedServer({
    required this.endpoint,
    required this.displayName,
    required this.lastSuccess,
  });

  final Endpoint endpoint;

  /// The name the server gave for itself the last time it answered.
  final String displayName;
  final DateTime lastSuccess;
}

abstract class EndpointStore {
  /// The last endpoint that successfully identified itself, if any.
  Future<RememberedServer?> load();

  /// Records a *successful* handshake. Never called for an attempt.
  Future<void> remember(RememberedServer server);

  /// Forgets it. The user chose another server, or asked to start over.
  Future<void> forget();
}

/// The on-device implementation.
class PreferencesEndpointStore implements EndpointStore {
  PreferencesEndpointStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  static const String _endpointKey = 'localcanvas.endpoint';
  static const String _nameKey = 'localcanvas.endpoint.display_name';
  static const String _whenKey = 'localcanvas.endpoint.last_success';

  final SharedPreferencesAsync _prefs;

  @override
  Future<RememberedServer?> load() async {
    final stored = await _prefs.getString(_endpointKey);
    if (stored == null) return null;
    final endpoint = Endpoint.tryParse(stored);
    if (endpoint == null) {
      // Something unreadable is in there; do not carry it forward.
      await forget();
      return null;
    }
    final when = await _prefs.getString(_whenKey);
    return RememberedServer(
      endpoint: endpoint,
      displayName: await _prefs.getString(_nameKey) ?? endpoint.display,
      lastSuccess:
          (when == null ? null : DateTime.tryParse(when)) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  @override
  Future<void> remember(RememberedServer server) async {
    await _prefs.setString(_endpointKey, server.endpoint.canonical);
    await _prefs.setString(_nameKey, server.displayName);
    await _prefs.setString(_whenKey, server.lastSuccess.toUtc().toIso8601String());
  }

  @override
  Future<void> forget() async {
    await _prefs.remove(_endpointKey);
    await _prefs.remove(_nameKey);
    await _prefs.remove(_whenKey);
  }
}
