import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/pairing.dart';

void main() {
  test('the payload the gateway prints is read back exactly', () {
    // The literal form in docs/connection.md §3 and in the gateway's own
    // pairing output.
    final endpoint = parsePairingPayload(
      'localcanvas://connect?endpoint=http://192.0.2.42:7801',
    );
    expect(endpoint?.canonical, 'http://192.0.2.42:7801');
  });

  test('a percent-encoded endpoint is read too', () {
    final endpoint = parsePairingPayload(
      'localcanvas://connect?endpoint=http%3A%2F%2F192.0.2.42%3A7801',
    );
    expect(endpoint?.canonical, 'http://192.0.2.42:7801');
  });

  test('a gateway on port 80 is paired with on port 80', () {
    // A reverse-proxied gateway prints exactly this. Substituting 7801 here
    // would make its pairing code unusable and say nothing about why.
    final endpoint = parsePairingPayload(
      'localcanvas://connect?endpoint=http://192.0.2.42:80',
    );
    expect(endpoint?.port, 80);
    expect(endpoint?.canonical, 'http://192.0.2.42:80');
  });

  test('a gateway on the https default port pairs on 443', () {
    expect(
      parsePairingPayload(
        'localcanvas://connect?endpoint=https://generation.example.com:443',
      )?.port,
      443,
    );
  });

  test('an https endpoint in a pairing code is accepted', () {
    expect(
      parsePairingPayload(
        'localcanvas://connect?endpoint=https://generation.example.com',
      )?.canonical,
      'https://generation.example.com',
    );
  });

  test('surrounding whitespace from the scanner is tolerated', () {
    expect(
      parsePairingPayload(
        '  localcanvas://connect?endpoint=192.0.2.42\n',
      )?.canonical,
      'http://192.0.2.42:7801',
    );
  });

  group('anything else in front of the camera is not a pairing code', () {
    test('a plain URL', () {
      expect(parsePairingPayload('https://example.com/'), isNull);
    });

    test('our scheme with another action', () {
      expect(
        parsePairingPayload('localcanvas://pay?endpoint=192.0.2.42'),
        isNull,
      );
    });

    test('our link with no endpoint at all', () {
      expect(parsePairingPayload('localcanvas://connect'), isNull);
    });

    test('our link carrying something unreadable', () {
      expect(
        parsePairingPayload('localcanvas://connect?endpoint=ftp://x'),
        isNull,
      );
    });

    test('empty text', () {
      expect(parsePairingPayload(''), isNull);
    });
  });
}
