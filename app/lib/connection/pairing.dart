/// The local QR pairing payload (`docs/connection.md` §3).
///
///     localcanvas://connect?endpoint=http://192.0.2.42:7801
///
/// Connection information only. No secret is carried here and none is read:
/// v0.1 has no authentication, and a future authenticated pairing must get its
/// own security design rather than smuggle a credential through this link.
library;

import 'endpoint.dart';

const String kPairingScheme = 'localcanvas';
const String kPairingAction = 'connect';
const String kPairingEndpointParameter = 'endpoint';

/// Reads a scanned code. Returns `null` for anything that is not a LocalCanvas
/// pairing link carrying a readable endpoint — the camera sees every barcode in
/// front of it, and most of them are not ours.
Endpoint? parsePairingPayload(String payload) {
  final raw = payload.trim();
  if (raw.isEmpty) return null;

  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.scheme.toLowerCase() != kPairingScheme) return null;

  // `localcanvas://connect?…` puts `connect` in the authority; a writer that
  // emits `localcanvas:connect?…` puts it in the path. Both name the action.
  final action = uri.host.isNotEmpty
      ? uri.host
      : uri.path.replaceAll('/', '');
  if (action.toLowerCase() != kPairingAction) return null;

  final endpoint = uri.queryParameters[kPairingEndpointParameter];
  if (endpoint == null) return null;

  return Endpoint.tryParse(endpoint);
}
