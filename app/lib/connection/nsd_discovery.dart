/// The platform half of discovery: Android's own DNS-SD stack, through `nsd`.
///
/// Why the platform stack and not a pure-Dart mDNS implementation: on Android,
/// multicast frames not addressed to the device are filtered out unless a
/// `WifiManager.MulticastLock` is held (below Android 13 T-extension 7; see the
/// next paragraph). WHERE in the stack that filtering happens is not
/// established here — an earlier version of this line said "the Wi-Fi chip",
/// which nobody measured, and a software lock switching it off argues against
/// it (T-0168). A pure-Dart package has no platform channel and cannot take
/// that lock, so on a device that filters it reads an empty network. Which
/// devices those are has not been surveyed; the app is tested on one.
///
/// **The lock is the app's to hold, not the system's.** An earlier version of
/// this docstring said `NsdManager` "is the OS service that owns the lock and
/// the radio". That is wrong below Android 13 T-extension 7, and this app's
/// `minSdkVersion` is 24: the platform's own `NsdManager` reference says that
/// before that extension "Apps must manually acquire a
/// `WifiManager.MulticastLock` to receive mDNS packets, even when the app is
/// in the foreground", and only "starting from T extensions 7" does "the
/// system automatically manage multicast reception for apps in the
/// foreground". The `nsd_android` plugin does take that lock for us — and
/// refuses to start a discovery at all unless the app declares
/// `CHANGE_WIFI_MULTICAST_STATE`, which is why the manifest declares it.
///
/// Everything here is platform-facing and therefore thin: the decisions live
/// in `discovery.dart`, which is what the tests drive. The one decision that
/// has to live here is reading the plugin's own error, because the plugin's
/// error type is the one thing on this side of the seam that
/// `discovery.dart` deliberately does not know about.
library;

import 'dart:async';
import 'dart:convert';

import 'package:nsd/nsd.dart' as nsd;

import 'discovery.dart';
import 'endpoint.dart';

class NsdDiscoveryBackend implements DiscoveryBackend {
  const NsdDiscoveryBackend();

  @override
  Future<DiscoverySession> start() async {
    // IPv4 lookup only, deliberately: a v0.1 gateway is advertised on a LAN
    // the phone reaches over IPv4, and asking for both families costs a
    // resolve per service for addresses nothing here would prefer. This is a
    // choice about discovery, not about addressing — `Endpoint.fromHostPort`
    // brackets an IPv6 literal correctly, and is tested for it, so a server
    // reached any other way works over IPv6 today.
    final nsd.Discovery discovery;
    try {
      discovery = await nsd.startDiscovery(
        kServiceType,
        ipLookupType: nsd.IpLookupType.v4,
      );
    } on nsd.NsdError catch (error) {
      throw describeNsdFailure(error);
    }
    return _NsdSession(discovery);
  }
}

class _NsdSession implements DiscoverySession {
  _NsdSession(this._discovery) {
    _discovery.addServiceListener(_onService);
  }

  final nsd.Discovery _discovery;
  final StreamController<DiscoveredServer> _found =
      StreamController<DiscoveredServer>.broadcast();

  @override
  Stream<DiscoveredServer> get found => _found.stream;

  void _onService(nsd.Service service, nsd.ServiceStatus status) {
    if (status != nsd.ServiceStatus.found) return;
    final server = serverFromAdvertisement(service);
    if (server != null && !_found.isClosed) _found.add(server);
  }

  @override
  Future<void> stop() async {
    _discovery.removeServiceListener(_onService);
    await _found.close();
    await nsd.stopDiscovery(_discovery);
  }
}

/// Turns the plugin's own error into the reason the rest of the app carries.
///
/// Both halves are kept and neither is rewritten. The [nsd.ErrorCause] is the
/// part the app could one day reason about; the message is the part that
/// actually names things — `securityIssue` on its own does not say *which*
/// permission, and `internalError` says nothing at all, so a summary that
/// dropped the message would leave the next bug report as blind as the one
/// that produced this code.
///
/// Public because it is a decision, and a decision deserves a test.
DiscoveryFailure describeNsdFailure(nsd.NsdError error) =>
    DiscoveryFailure(reason: error.message, cause: error.cause.name);

/// Turns one advertisement into a candidate, or into nothing.
///
/// The TXT records are `docs/connection.md`'s four keys; the address comes from
/// the resolved service. A record we cannot turn into an endpoint is dropped
/// rather than guessed at.
///
/// Public because it is the only part of this file with a decision in it, and
/// a decision deserves a test.
DiscoveredServer? serverFromAdvertisement(nsd.Service service) {
  final Map<String, Object?> txt = service.txt ?? const <String, Object?>{};
  final addresses = service.addresses;
  final host = (addresses != null && addresses.isNotEmpty)
      ? addresses.first.address
      : service.host;
  final port = service.port ?? int.tryParse(_text(txt['port']) ?? '');
  if (host == null || host.isEmpty || port == null) return null;

  final endpoint = Endpoint.fromHostPort(host, port);
  if (endpoint == null) return null;

  return DiscoveredServer(
    id: service.name ?? endpoint.canonical,
    displayName: _text(txt['name'])?.trim().isNotEmpty == true
        ? _text(txt['name'])!.trim()
        : (service.name ?? endpoint.display),
    endpoint: endpoint,
    gatewayVersion: _text(txt['version']),
    apiVersion: int.tryParse(_text(txt['api']) ?? ''),
  );
}

String? _text(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is List<int>) {
    try {
      return utf8.decode(value);
    } on FormatException {
      return null;
    }
  }
  return null;
}
