/// The four conditions and the four sentences (`docs/connection.md` §4,
/// `docs/recovery.md`).
///
/// Collapsing any two of these into one message is a defect: they have
/// different fixes, and the user is the one who has to apply them. No raw
/// exception text, no HTTP status codes, no internals.
///
/// **A notice carries facts, not prose (T-0142).** It holds the problem and the
/// handful of values the sentence needs — the address, the server's name, the
/// two version numbers — and turns into words only where there is a
/// `BuildContext` to say which language to use. A notice built on a background
/// isolate, stored, and rendered an hour later after the user changed the
/// language still reads in the language on screen, because there is no sentence
/// in it until something draws it.
library;

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import 'gateway_identity.dart';

enum ConnectionProblem {
  /// Nothing answered at all.
  unreachable,

  /// Something answered, and it was not a LocalCanvas gateway.
  notLocalCanvas,

  /// A gateway, speaking a version this build does not.
  incompatibleVersion,

  /// A healthy gateway whose image generator is not up.
  comfyUnavailable,
}

/// A problem in the facts the sentence is built from, plus the one thing the
/// user can do.
@immutable
class ConnectionNotice {
  const ConnectionNotice({
    required this.problem,
    this.address,
    this.serverName,
    this.serverApiVersion,
    this.clientApiVersion = kSupportedApiVersion,
    this.detail,
  });

  final ConnectionProblem problem;

  /// The address the user is looking at, or `null` where there is not one to
  /// name.
  final String? address;

  /// The gateway's own name, once it has given one.
  final String? serverName;

  /// The API version the server reported, and the one this build speaks. An
  /// incompatible version names both, per `docs/api.md`.
  final int? serverApiVersion;
  final int clientApiVersion;

  /// The gateway's own short reason, passed through in whatever words it used.
  /// It is the server's to write; T-0143 is what makes it arrive translated.
  final String? detail;

  /// Whether the app is nonetheless connected. Only ComfyUI being down leaves
  /// a working gateway on the other end.
  bool get isConnected => problem == ConnectionProblem.comfyUnavailable;

  /// One sentence naming what happened.
  String title(L l) => switch (problem) {
    ConnectionProblem.unreachable => l.problemUnreachableTitle,
    ConnectionProblem.notLocalCanvas => l.problemNotLocalCanvasTitle,
    ConnectionProblem.incompatibleVersion => l.problemIncompatibleTitle,
    ConnectionProblem.comfyUnavailable => l.problemComfyTitle,
  };

  /// One or two sentences naming what to do about it.
  ///
  /// Each case has a sentence for "we can name the address" and one for "we
  /// cannot", rather than one sentence with a stand-in phrase dropped into the
  /// slot. A phrase that reads as a noun in English — *that address* — reads as
  /// nothing at all in a language that inflects, and the version case is
  /// worse: no language can take *an unknown version* where a number goes.
  String message(L l) {
    final where = address;
    switch (problem) {
      case ConnectionProblem.unreachable:
        return where == null
            ? l.problemUnreachableAnywhere
            : l.problemUnreachableAt(where);
      case ConnectionProblem.notLocalCanvas:
        return where == null
            ? l.problemNotLocalCanvasAnywhere
            : l.problemNotLocalCanvasAt(where);
      case ConnectionProblem.incompatibleVersion:
        final reported = serverApiVersion;
        if (reported == null) {
          return where == null
              ? l.problemIncompatibleUnknownAnywhere(clientApiVersion)
              : l.problemIncompatibleUnknownAt(where, clientApiVersion);
        }
        return where == null
            ? l.problemIncompatibleAnywhere(reported, clientApiVersion)
            : l.problemIncompatibleAt(where, reported, clientApiVersion);
      case ConnectionProblem.comfyUnavailable:
        final who = serverName ?? l.problemServerFallbackName;
        final because = detail?.trim();
        return because == null || because.isEmpty
            ? l.problemComfy(who)
            : l.problemComfyWithDetail(who, because);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionNotice &&
      other.problem == problem &&
      other.address == address &&
      other.serverName == serverName &&
      other.serverApiVersion == serverApiVersion &&
      other.clientApiVersion == clientApiVersion &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(
    problem,
    address,
    serverName,
    serverApiVersion,
    clientApiVersion,
    detail,
  );
}

/// Builds the notice for a problem.
///
/// [address] is the address the user is looking at, [serverName] the gateway's
/// own name once it has given one, and [serverApiVersion] the version it
/// reported — an incompatible version names both, per `docs/api.md`.
ConnectionNotice describeProblem(
  ConnectionProblem problem, {
  String? address,
  String? serverName,
  int? serverApiVersion,
  String? detail,
  int clientApiVersion = kSupportedApiVersion,
}) => ConnectionNotice(
  problem: problem,
  address: address,
  serverName: serverName,
  serverApiVersion: serverApiVersion,
  detail: detail,
  clientApiVersion: clientApiVersion,
);
