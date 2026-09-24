/// `POST /api/v1/media` against a real server on loopback (`docs/api.md`).
///
/// The server is `dart:io`, the file is a real file, and the bytes are read by
/// the real transport — which is the only way the claim this card turns on can
/// be checked at all. "Progress is real byte progress" is not a property of a
/// widget; it is a property of the request body, and it is asserted here by
/// comparing what the client said it had sent with what the socket actually
/// received.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/media/media_api.dart';
import 'package:localcanvas/media/media_selection.dart';

import 'support/fake_gateway.dart';
import 'support/l10n.dart';
import 'support/media_fakes.dart';

void main() {
  late FakeGateway server;
  late HttpMediaApi api;

  Future<void> startServer({String basePath = ''}) async {
    server = await FakeGateway.start(basePath: basePath);
    addTearDown(server.stop);
    api = HttpMediaApi(language: () => 'en');
    addTearDown(api.dispose);
    server.serveJson(kMediaPath, <String, Object?>{
      'media_id': 'm-3f9c1a',
      'kind': 'image',
      'filename': 'IMG_0142.jpg',
      'bytes': 2048,
      'expires_at': '2026-09-02T19:41:00Z',
    });
  }

  group('the upload itself', () {
    test('one file and its kind reach the media path, and an id comes back',
        () async {
      await startServer();
      final selection = tempSelection(bytes: 2048);

      final uploaded = await api.upload(server.endpoint, selection);

      expect(uploaded.mediaId, 'm-3f9c1a');
      expect(uploaded.byteCount, 2048);
      expect(server.requestedPaths, <String>['/api/v1/media']);

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.contentType, startsWith('multipart/form-data'));
      expect(request.bodyText, contains('name="kind"'));
      expect(request.bodyText, contains('image'));
      expect(request.bodyText, contains('filename="IMG_0142.jpg"'));
      // Every byte of the file crossed, envelope aside.
      expect(request.body.length, greaterThan(2048));
    });

    test('a path-mounted gateway is resolved, not concatenated', () async {
      await startServer(basePath: '/localcanvas');

      await api.upload(server.endpoint, tempSelection());

      expect(server.requestedPaths, <String>['/localcanvas/api/v1/media']);
    });

    test('a filename that is only a reference is not put on the wire either',
        () async {
      await startServer();
      // `humanFilename` refuses a URI, so the selection carries no name; the
      // request must then carry a placeholder rather than the reference.
      expect(
        humanFilename('content://media/external/images/media/1024'),
        isNull,
      );
      final selection = tempSelection(named: false);
      expect(selection.filename, isNull);

      await api.upload(server.endpoint, selection);

      final body = server.requests.single.bodyText;
      expect(body, contains('filename="upload"'));
      expect(body, isNot(contains('content://')));
    });

    test('a name that cannot be written into a header is cleaned, not sent',
        () async {
      await startServer();
      // A quote is legal in an Android filename and would end the header
      // early; a newline would end the whole part; non-ASCII has no agreed
      // encoding in this position.
      final selection = tempSelection(
        filename: 'he said "hi"\ncaf\u00e9.jpg',
      );

      await api.upload(server.endpoint, selection);

      final body = server.requests.single.bodyText;
      expect(body, contains('filename="he said hicaf.jpg"'));
      expect(body, isNot(contains('"hi"')));
      expect(body, isNot(contains('caf\u00e9')));
      // The part header is still one line, ending at its closing quote.
      expect(
        body,
        contains('filename="he said hicaf.jpg"\r\ncontent-type:'),
      );
    });

    test('a name with nothing writable left in it becomes a placeholder',
        () async {
      await startServer();

      await api.upload(
        server.endpoint,
        tempSelection(filename: '\u65e5\u672c\u8a9e'),
      );

      expect(server.requests.single.bodyText, contains('filename="upload"'));
    });
  });

  group('progress is the body stream, not a timer', () {
    test('what the client reports is what the socket received', () async {
      await startServer();
      final selection = tempSelection(bytes: 40000);
      final reported = <int>[];
      int? lastTotal = -1;

      await api.upload(
        server.endpoint,
        selection,
        onProgress: (sent, total) {
          reported.add(sent);
          lastTotal = total;
        },
      );

      expect(reported, isNotEmpty);
      expect(lastTotal, 40000, reason: 'a known length is reported as itself');
      expect(reported.first, 0, reason: 'nothing has gone before it goes');
      expect(reported.last, 40000);
      // Never backwards, and never past the file.
      for (var i = 1; i < reported.length; i++) {
        expect(reported[i], greaterThanOrEqualTo(reported[i - 1]));
      }
      expect(reported.every((sent) => sent <= 40000), isTrue);
      // And the count is the file, not an estimate of it: the server got the
      // envelope plus exactly that many bytes.
      expect(server.requests.single.body.length, greaterThan(40000));
    });

    test('a source of unknown length is indeterminate, never a guess',
        () async {
      await startServer();
      final selection = MediaSelection(
        kind: MediaKind.video,
        source: ChunkedMediaSource(<List<int>>[List<int>.filled(1500, 7)]),
        filename: 'clip.mp4',
      );
      final totals = <int?>[];

      final uploaded = await api.upload(
        server.endpoint,
        selection,
        onProgress: (sent, total) => totals.add(total),
      );

      expect(uploaded.mediaId, isNotEmpty);
      expect(totals, isNotEmpty);
      expect(
        totals.every((total) => total == null),
        isTrue,
        reason: 'no length is known, so none is invented',
      );
      // The request went out chunked rather than with a made-up length.
      expect(server.requests.single.contentLength, -1);
      expect(server.requests.single.body.length, greaterThan(1500));
    });

    test('the count lands on the chunks, which a fabricated ramp cannot do',
        () async {
      await startServer();
      final chunks = <List<int>>[
        List<int>.filled(7, 1),
        List<int>.filled(1000, 2),
        List<int>.filled(33, 3),
      ];
      final selection = MediaSelection(
        kind: MediaKind.image,
        source: ChunkedMediaSource(chunks, length: 1040),
        filename: 'IMG_0142.jpg',
      );
      final reported = <int>[];

      await api.upload(
        server.endpoint,
        selection,
        onProgress: (sent, total) => reported.add(sent),
      );

      expect(reported, <int>[0, 7, 1007, 1040]);
    });

    test('a known length is declared exactly once the body is counted',
        () async {
      await startServer();
      await api.upload(server.endpoint, tempSelection(bytes: 4096));

      final request = server.requests.single;
      expect(request.contentLength, request.body.length);
    });
  });

  group('when it does not work', () {
    test('a file that is gone is refused before anything is sent', () async {
      await startServer();
      final selection = tempSelection();
      File((selection.source as FileMediaSource).path).deleteSync();

      await expectLater(
        api.upload(server.endpoint, selection),
        throwsA(isA<MediaFailure>().having(
          (f) => f.title(en),
          'title',
          'That file is no longer available.',
        )),
      );
      expect(server.requests, isEmpty);
    });

    test("a gateway that refuses says so in its own words", () async {
      await startServer();
      server.serveJson(
        kMediaPath,
        <String, Object?>{
          'error': <String, Object?>{
            'code': 'media_too_large',
            'message': 'That clip is larger than this server accepts.',
            'field': null,
          },
        },
        status: 413,
      );

      await expectLater(
        api.upload(server.endpoint, tempSelection()),
        throwsA(isA<MediaFailure>().having(
          (f) => f.message(en),
          'message',
          'That clip is larger than this server accepts.',
        )),
      );
    });

    test('an answer without a media id is unreadable, not a success',
        () async {
      await startServer();
      server.serveJson(kMediaPath, <String, Object?>{'kind': 'image'});

      await expectLater(
        api.upload(server.endpoint, tempSelection()),
        throwsA(isA<MediaFailure>().having(
          (f) => f.title(en),
          'title',
          "The server's answer could not be read.",
        )),
      );
    });

    test('a body that is not JSON at all is unreadable', () async {
      await startServer();
      server.serveRaw(kMediaPath, '<html>nope</html>');

      await expectLater(
        api.upload(server.endpoint, tempSelection()),
        throwsA(isA<MediaFailure>()),
      );
    });

    test('nothing listening is reported as the server not taking it',
        () async {
      final api = HttpMediaApi(language: () => 'en');
      addTearDown(api.dispose);

      await expectLater(
        api.upload(await deadEndpoint(), tempSelection()),
        throwsA(isA<MediaFailure>().having(
          (f) => f.title(en),
          'title',
          "The server didn't take the upload.",
        )),
      );
    });

    test('no failure message carries exception text or a status code',
        () async {
      const failures = <MediaFailure>[
        MediaFailure.notAllowed(),
        MediaFailure.gone(),
        MediaFailure.unreachable(),
        MediaFailure.unreadable(),
        MediaFailure.refused(
          code: 'file_too_large',
          serverMessage: 'That clip is larger than this server accepts.',
        ),
      ];
      for (final failure in failures) {
        final text = '${failure.title(en)} ${failure.message(en)}';
        expect(text, isNot(matches(RegExp(r'\b[45]\d\d\b'))));
        expect(text, isNot(contains('Exception')));
        expect(text, isNot(contains('SocketException')));
        expect(text, isNot(contains('://')));
      }
    });
  });
}
