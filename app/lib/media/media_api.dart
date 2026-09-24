/// `POST /api/v1/media` — one file, its kind, and a media id back
/// (`docs/api.md`).
///
/// The whole reason this is hand-rolled rather than `http.MultipartRequest` is
/// the progress rule. `docs/ui-ux.md` and `docs/recovery.md` forbid a fake
/// animation, and the contract says progress "is a client-side property of the
/// request body stream". So the body here **is** a stream, and the count comes
/// from it: every chunk the HTTP client pulls out of the file is counted as it
/// is handed over, and nothing is reported that did not happen.
///
/// The other half of the same rule is the honest unknown. A source that cannot
/// say how long it is produces a request with no `Content-Length` — chunked,
/// as HTTP allows — and a `null` total, which the interface renders as an
/// indeterminate bar. `MultipartRequest` cannot express that at all: it
/// demands a length per part, so the only way to use it would have been to
/// read the whole clip into memory first, which is both a lie about progress
/// and a way to run a phone out of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../connection/endpoint.dart';
import '../l10n/accept_language.dart';
import 'media_selection.dart';

/// The media endpoint, relative to the base endpoint.
const String kMediaPath = '/api/v1/media';

/// A backstop, not a deadline for the transfer itself.
///
/// An upload is as long as the file and the Wi-Fi make it, and a clip is not a
/// JSON document; cutting one off at a handful of seconds would be the bug the
/// card's own criteria call out on the gateway side. What this bounds is a
/// socket that has stopped moving and will never fail on its own, so that a
/// waiting state always has an exit (`docs/recovery.md`).
const Duration kMediaUploadTimeout = Duration(minutes: 10);

/// Called as bytes reach the transport. [totalBytes] is `null` when the length
/// is not knowable — the honest indeterminate case, never a guess.
typedef MediaProgress = void Function(int sentBytes, int? totalBytes);

/// The gateway's answer: `{ media_id, kind, filename, bytes, expires_at }`.
@immutable
class UploadedMedia {
  const UploadedMedia({
    required this.mediaId,
    this.filename,
    this.byteCount,
    this.expiresAt,
  });

  final String mediaId;

  /// Echoed back by the gateway. Kept because it is a name; a reference would
  /// not be kept, and the gateway does not send one.
  final String? filename;
  final int? byteCount;
  final DateTime? expiresAt;

  static UploadedMedia? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['media_id'];
    if (id is! String || id.trim().isEmpty) return null;
    final bytes = json['bytes'];
    final expires = json['expires_at'];
    return UploadedMedia(
      mediaId: id.trim(),
      filename: humanFilename(json['filename'] is String
          ? json['filename'] as String
          : null),
      byteCount: bytes is int ? bytes : (bytes is num ? bytes.toInt() : null),
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
    );
  }
}

/// Sending one file to the gateway.
///
/// An interface so a widget test can drive the upload states from a script,
/// while the transport itself is exercised against a real `dart:io` server.
abstract interface class MediaApi {
  Future<UploadedMedia> upload(
    Endpoint endpoint,
    MediaSelection selection, {
    MediaProgress? onProgress,
  });
}

class HttpMediaApi implements MediaApi {
  HttpMediaApi({
    required this.language,
    http.Client? httpClient,
    this.timeout = kMediaUploadTimeout,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The language on screen, asked for at the moment a request is built.
  ///
  /// **This is the fourth client, and it was nearly the one that got away**
  /// (T-0148, folded into T-0142). The other three carry
  /// `headers: {'Accept': 'application/json'}` as a literal map, and the
  /// upload does not: it builds its envelope by hand and lower-cases its
  /// header names, so a search for that literal — the search the card's own
  /// scope was drawn from — found three of four. It sends the same two
  /// headers as the rest now, out of the same one function.
  final LanguageTagSource language;

  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;

  @override
  Future<UploadedMedia> upload(
    Endpoint endpoint,
    MediaSelection selection, {
    MediaProgress? onProgress,
  }) async {
    if (!await selection.source.isAvailable()) {
      throw const MediaFailure.gone();
    }
    final int? length = selection.byteCount ?? await selection.source.byteLength();

    final request = _MediaUploadRequest(
      url: endpoint.resolvePath(kMediaPath),
      kind: selection.kind.wireName,
      filename: selection.filename,
      bytes: selection.source.openRead(),
      byteLength: length,
      onProgress: onProgress,
      language: language,
    );

    final http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw const MediaFailure.unreachable();
    } on SocketException {
      throw const MediaFailure.unreachable();
    } on HttpException {
      throw const MediaFailure.unreachable();
    } on http.ClientException {
      throw const MediaFailure.unreachable();
    } on FileSystemException {
      // The file went away between the check above and the read.
      throw const MediaFailure.gone();
    } catch (_) {
      // Whatever else the socket, the resolver or the TLS stack throws. An
      // escaping exception would leave a field stuck on "Uploading…" with no
      // way out, which `docs/recovery.md` forbids.
      throw const MediaFailure.unreachable();
    }

    final List<int> body;
    try {
      body = await streamed.stream.toBytes().timeout(timeout);
    } catch (_) {
      throw const MediaFailure.unreachable();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw streamed.statusCode >= 200 && streamed.statusCode < 300
          ? const MediaFailure.unreadable()
          : const MediaFailure.unreachable();
    }

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      // `docs/api.md`: a non-2xx carries an end-user readable message. When it
      // does not, this app supplies its own rather than showing a number.
      final error = decoded is Map ? decoded['error'] : null;
      final code = error is Map ? error['code'] : null;
      final message = error is Map ? error['message'] : null;
      final codeText = code is String && code.trim().isNotEmpty
          ? code.trim()
          : null;
      final messageText = message is String && message.trim().isNotEmpty
          ? message.trim()
          : null;
      throw codeText == null && messageText == null
          ? const MediaFailure.unreadable()
          : MediaFailure.refused(code: codeText, serverMessage: messageText);
    }

    final uploaded = UploadedMedia.tryFromJson(decoded);
    if (uploaded == null) throw const MediaFailure.unreadable();
    return uploaded;
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }
}

/// A `multipart/form-data` body assembled by hand, so that the file part can
/// be a stream of unknown length and so that the count is taken from the
/// stream rather than from a timer.
class _MediaUploadRequest extends http.BaseRequest {
  _MediaUploadRequest({
    required Uri url,
    required this.kind,
    required this.filename,
    required this.bytes,
    required this.byteLength,
    required this.onProgress,
    required LanguageTagSource language,
  }) : boundary = _newBoundary(),
       super('POST', url) {
    headers['content-type'] = 'multipart/form-data; boundary=$boundary';
    // The same two the JSON requests carry, out of the same function so the
    // four clients cannot drift into announcing different things. Lower-cased
    // with the rest of this hand-built envelope; `dart:io` folds header names
    // anyway, and the file reads consistently this way.
    jsonHeaders(language).forEach((name, value) {
      headers[name.toLowerCase()] = value;
    });
    final envelope = _head.length + _tail.length;
    // Known length or nothing: a guessed `Content-Length` would be a lie the
    // socket itself would catch, and `null` is a legal request (chunked).
    if (byteLength != null) contentLength = envelope + byteLength!;
  }

  final String boundary;
  final String kind;
  final String? filename;
  final Stream<List<int>> bytes;
  final int? byteLength;
  final MediaProgress? onProgress;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body());
  }

  Stream<List<int>> _body() async* {
    yield utf8.encode(_head);
    var sent = 0;
    onProgress?.call(0, byteLength);
    await for (final chunk in bytes) {
      sent += chunk.length;
      // Counted at the moment the client takes the chunk. This is the only
      // place progress is ever produced.
      onProgress?.call(sent, byteLength);
      yield chunk;
    }
    yield utf8.encode(_tail);
  }

  String get _head =>
      '--$boundary\r\n'
      'content-disposition: form-data; name="kind"\r\n'
      '\r\n'
      '$kind\r\n'
      '--$boundary\r\n'
      'content-disposition: form-data; name="file"; '
      'filename="${_headerSafe(filename)}"\r\n'
      'content-type: application/octet-stream\r\n'
      '\r\n';

  String get _tail => '\r\n--$boundary--\r\n';

  /// The filename as a header may carry it.
  ///
  /// Quotes and line breaks would end the header early, and a non-ASCII name
  /// has no agreed encoding in this position, so a name that cannot be written
  /// plainly is replaced rather than mangled. Nothing about the app's own
  /// storage is disclosed here either: [filename] is already a name, never a
  /// path (`media_selection.dart`).
  static String _headerSafe(String? name) {
    if (name == null) return 'upload';
    final buffer = StringBuffer();
    for (final unit in name.runes) {
      if (unit < 0x20 || unit > 0x7E) continue;
      if (unit == 0x22 || unit == 0x5C) continue; // " and \
      buffer.writeCharCode(unit);
    }
    final cleaned = buffer.toString().trim();
    return cleaned.isEmpty ? 'upload' : cleaned;
  }

  static String _newBoundary() {
    const String alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = math.Random();
    final tail = List<String>.generate(
      24,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    return 'localcanvas-$tail';
  }
}
