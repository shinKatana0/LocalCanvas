/// What `GET /api/v1/info` says about a gateway (`docs/api.md`).
library;

import 'package:flutter/foundation.dart';

import '../generation/translation.dart';

/// The API version this build speaks. A gateway reporting anything else is
/// reported as incompatible, with both numbers named — never silently used.
const int kSupportedApiVersion = 1;

/// The one value of `service` that means "this is a LocalCanvas gateway".
const String kGatewayServiceName = 'localcanvas';

/// `comfy.status` from the handshake.
enum ComfyStatus {
  ready,
  starting,
  unavailable,

  /// A gateway that reported a status this build does not know. Treated as
  /// not-ready, because pretending it is ready is the dishonest option.
  unknown;

  static ComfyStatus parse(Object? value) => switch (value) {
    'ready' => ComfyStatus.ready,
    'starting' => ComfyStatus.starting,
    'unavailable' => ComfyStatus.unavailable,
    _ => ComfyStatus.unknown,
  };

  bool get isReady => this == ComfyStatus.ready;
}

/// What the gateway promises it can do. Absent keys are `false`: a capability
/// this build cannot see is one it must not offer a button for.
///
/// [translation] is the one entry that is not a word but a block, and the one
/// whose absence is **not** `false`. The other three are about endpoints this
/// build either has or lacks, so silence about one is a reason not to draw a
/// button; translation is about the *PC*, and a gateway older than the feature
/// has said nothing about it at all (`docs/api.md`).
@immutable
class GatewayCapabilities {
  const GatewayCapabilities({
    this.cancel = false,
    this.mediaUpload = false,
    this.events = false,
    this.translation = TranslationCapability.unknown,
  });

  final bool cancel;
  final bool mediaUpload;
  final bool events;

  /// What that PC can translate, or [TranslationCapability.unknown].
  final TranslationCapability translation;

  factory GatewayCapabilities.fromJson(Object? json) {
    if (json is! Map) return const GatewayCapabilities();
    bool flag(String key) => json[key] == true;
    return GatewayCapabilities(
      cancel: flag('cancel'),
      mediaUpload: flag('media_upload'),
      events: flag('events'),
      translation: TranslationCapability.fromJson(json['translation']),
    );
  }
}

/// A gateway that has identified itself.
@immutable
class GatewayIdentity {
  const GatewayIdentity({
    required this.apiVersion,
    required this.gatewayVersion,
    required this.displayName,
    required this.comfyStatus,
    required this.comfyDetail,
    required this.capabilities,
  });

  final int apiVersion;
  final String gatewayVersion;

  /// The server's own name for itself. What the user reads everywhere, and
  /// `null` for a gateway that gave no name.
  ///
  /// **Null rather than a stand-in** (T-0142). It used to fall back to the
  /// English words "LocalCanvas server" here, which put an English phrase into
  /// a Russian interface and could not be translated from a JSON parser with
  /// no `BuildContext`. Absence is the fact; what to draw instead of a name is
  /// the screen's decision, and every screen that shows one already has a
  /// localised answer for a server that has not named itself.
  final String? displayName;

  final ComfyStatus comfyStatus;

  /// A short human sentence when [comfyStatus] is not ready; never a trace.
  final String? comfyDetail;

  final GatewayCapabilities capabilities;

  /// Reads the handshake body.
  ///
  /// Returns `null` when the body is not a LocalCanvas identity at all — a
  /// wrong `service`, a missing `api_version`, or not an object. Refusing here
  /// is what stops an arbitrary HTTP service from being treated as a gateway.
  static GatewayIdentity? tryFromJson(Object? json) {
    if (json is! Map) return null;
    if (json['service'] != kGatewayServiceName) return null;
    final apiVersion = json['api_version'];
    if (apiVersion is! int) return null;

    final comfy = json['comfy'];
    final detail = comfy is Map ? comfy['detail'] : null;

    return GatewayIdentity(
      apiVersion: apiVersion,
      gatewayVersion: _string(json['gateway_version']) ?? 'unknown',
      displayName: _nonEmpty(_string(json['display_name'])),
      comfyStatus: ComfyStatus.parse(comfy is Map ? comfy['status'] : null),
      comfyDetail: _nonEmpty(_string(detail)),
      capabilities: GatewayCapabilities.fromJson(json['capabilities']),
    );
  }

  bool get isSupportedVersion => apiVersion == kSupportedApiVersion;

  static String? _string(Object? value) => value is String ? value : null;

  static String? _nonEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value.trim();
}
