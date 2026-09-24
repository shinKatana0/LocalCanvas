/// `WS /api/v1/jobs/{job_id}/events` — the optimization, never the truth
/// (`docs/api.md`).
///
/// Everything this stream says, the snapshot can say too. Losing it is not an
/// error condition; it only means the app goes back to asking
/// `GET /api/v1/jobs/{job_id}`, which is where truth lives. Nothing here ever
/// replays events to reconstruct a state.
///
/// **The trap this file exists to avoid.** Dart's `Uri` has no default-port
/// entry for `ws`/`wss`, so `.port` on a derived socket URI returns **0** for
/// an endpoint on `http:80` or `https:443`. The URL is still right on the
/// wire; the getter is not.
///
/// The reason it is still right is worth stating precisely, because a vaguer
/// version of it is wrong. Writing that 0 back out **through a `Uri`** erases
/// it: 0 is what `Uri` treats as the default port for a scheme it does not
/// know, so `Uri.parse('ws://box:0/api')` prints `ws://box/api`. That is a
/// property of `Uri`, not of the text. Interpolated straight into a **string**
/// — `'ws://${uri.host}:${uri.port}$path'` — the `:0` survives, and a socket
/// opened on it goes nowhere.
///
/// So the port is never read off the derived URI here. The URL handed to the
/// connector is [Uri.toString] of the already-normalized `Uri` and nothing
/// else, and [connector] exists so a test can pin that exact string. If a port
/// is ever genuinely needed, it is [Endpoint.port] that has it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../connection/endpoint.dart';
import 'job_models.dart';

/// The events path for one job, relative to the base endpoint.
String jobEventsPath(String jobId) =>
    '/api/v1/jobs/${Uri.encodeComponent(jobId)}/events';

/// The socket URL for one job's events.
///
/// A whole function for one line, because it is the line the card warns about:
/// it is derived, never assembled, and a test pins the result for an endpoint
/// whose port is the scheme's own.
Uri jobEventsUri(Endpoint endpoint, String jobId) =>
    endpoint.webSocketUri(jobEventsPath(jobId));

/// One message from the stream. The four shapes in `docs/api.md`, and nothing
/// this app invented.
@immutable
sealed class JobEvent {
  const JobEvent();
}

final class JobStateEvent extends JobEvent {
  const JobStateEvent(this.state);

  final JobState state;
}

/// Real numbers only. There is no event that carries a percentage, so there is
/// nothing here for a fabricated one to arrive in.
final class JobProgressEvent extends JobEvent {
  const JobProgressEvent(this.progress);

  final JobProgress progress;
}

final class JobResultsEvent extends JobEvent {
  const JobResultsEvent(this.results);

  final List<JobResultRef> results;
}

final class JobErrorEvent extends JobEvent {
  const JobErrorEvent(this.message);

  /// Human-readable, no stack trace (`docs/api.md`).
  final String message;
}

/// Reads one message, or `null` for anything unreadable.
///
/// A message this build cannot understand is dropped rather than guessed at.
/// Dropping is safe precisely because the socket is not the source of truth:
/// the snapshot still knows.
JobEvent? parseJobEvent(Object? json) {
  if (json is! Map) return null;
  switch (json['type']) {
    case 'state':
      final state = JobState.tryParse(json['state']);
      return state == null ? null : JobStateEvent(state);
    case 'progress':
      // The delta carries `step` and `total` at the top level; the same two
      // integers the snapshot nests under `progress`, and the same rule about
      // what counts as progress at all.
      final progress = JobProgress.tryFromJson(json);
      return progress == null ? null : JobProgressEvent(progress);
    case 'result':
      final results = JobResultRef.listFrom(json['results']);
      return results.isEmpty ? null : JobResultsEvent(results);
    case 'error':
      final message = json['message'];
      return message is String && message.trim().isNotEmpty
          ? JobErrorEvent(message.trim())
          : null;
    default:
      return null;
  }
}

/// An open stream of events for one job.
abstract interface class JobEventSubscription {
  /// The events, in the order they arrived. The stream closing is the signal
  /// that the socket is gone — the caller then goes back to the snapshot.
  Stream<JobEvent> get events;

  Future<void> close();
}

/// How a stream is opened. An interface so a widget test can drive a lifecycle
/// without a socket, and so a build with no event support at all is simply a
/// `null` here rather than a special case everywhere.
abstract interface class JobEventSource {
  /// Opens the stream, or throws when it cannot be opened. A failure to
  /// connect is not an error the user hears about: it means the snapshot does
  /// the work instead.
  Future<JobEventSubscription> connect(Endpoint endpoint, String jobId);
}

/// Opens the socket. `dart:io`'s own [WebSocket.connect] in the app; in a test,
/// something that records the URL it was given.
typedef WebSocketConnector = Future<WebSocket> Function(String url);

/// The real socket, on `dart:io`.
class WebSocketJobEvents implements JobEventSource {
  const WebSocketJobEvents({
    this.timeout = const Duration(seconds: 5),
    this.connector,
  });

  final Duration timeout;

  /// How the socket is opened. `null` is [WebSocket.connect] — the only reason
  /// this exists is that the URL is the thing worth pinning, and a test cannot
  /// read it back off a socket that refused to open.
  final WebSocketConnector? connector;

  @override
  Future<JobEventSubscription> connect(Endpoint endpoint, String jobId) async {
    // The derived URI's own text, handed over whole. Nothing is interpolated
    // and `.port` is never consulted; see the library comment for why the
    // difference matters.
    final String url = jobEventsUri(endpoint, jobId).toString();
    final open = connector ?? WebSocket.connect;
    final socket = await open(url).timeout(timeout);
    return _WebSocketSubscription(socket);
  }
}

class _WebSocketSubscription implements JobEventSubscription {
  _WebSocketSubscription(this._socket);

  final WebSocket _socket;

  @override
  Stream<JobEvent> get events => _socket
      .map<JobEvent?>((Object? frame) {
        if (frame is! String) return null;
        try {
          return parseJobEvent(jsonDecode(frame));
        } on FormatException {
          return null;
        }
      })
      // A frame this build cannot read is dropped, not turned into a state.
      .where((JobEvent? event) => event != null)
      .cast<JobEvent>();

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {
      // Closing a socket that is already gone is not a failure worth telling
      // anyone about.
    }
  }
}
