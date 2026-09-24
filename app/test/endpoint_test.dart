import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';

void main() {
  group('normalization — every form docs/connection.md lists', () {
    test('a bare host gets the default scheme and the default port', () {
      expect(
        Endpoint.tryParse('192.0.2.42')?.canonical,
        'http://192.0.2.42:7801',
      );
    });

    test('a host with a port gets only the default scheme', () {
      expect(
        Endpoint.tryParse('192.0.2.42:7801')?.canonical,
        'http://192.0.2.42:7801',
      );
    });

    test('a complete http address is left alone', () {
      expect(
        Endpoint.tryParse('http://192.0.2.42:7801')?.canonical,
        'http://192.0.2.42:7801',
      );
    });

    test('a hostname works as well as an address', () {
      expect(
        Endpoint.tryParse('studio-pc.local')?.canonical,
        'http://studio-pc.local:7801',
      );
    });

    test('an explicit http address with no port still gets 7801', () {
      expect(
        Endpoint.tryParse('http://192.0.2.42')?.canonical,
        'http://192.0.2.42:7801',
      );
    });

    test('trailing slashes are trimmed', () {
      expect(
        Endpoint.tryParse('http://192.0.2.42:7801///')?.canonical,
        'http://192.0.2.42:7801',
      );
    });

    test('a pasted /api/v1 suffix is trimmed', () {
      expect(
        Endpoint.tryParse('http://192.0.2.42:7801/api/v1')?.canonical,
        'http://192.0.2.42:7801',
      );
      expect(
        Endpoint.tryParse('http://192.0.2.42:7801/api/v1/')?.canonical,
        'http://192.0.2.42:7801',
      );
    });

    test('a real path prefix is kept — it is not an accident', () {
      expect(
        Endpoint.tryParse('https://example.com/localcanvas/')?.canonical,
        'https://example.com/localcanvas',
      );
    });

    test('an IPv6 literal in brackets is accepted', () {
      final endpoint = Endpoint.tryParse('[fe80::1]');
      expect(endpoint?.canonical, 'http://[fe80::1]:7801');
      expect(endpoint?.host, 'fe80::1');
    });

    test('an IPv6 literal with a port is accepted', () {
      expect(
        Endpoint.tryParse('http://[2001:db8::42]:7801')?.canonical,
        'http://[2001:db8::42]:7801',
      );
    });

    group('a port the user typed is not an absent port', () {
      // Uri.parse normalizes a scheme-default port out of existence, so
      // `hasPort` says "absent" about a `:80` that was written down. Treating
      // it as absent substitutes 7801 and connects somewhere the user never
      // named — and leaves a gateway behind a proxy on port 80 unreachable by
      // any address that can be typed, scanned or remembered.
      test('an explicit :80 on http survives', () {
        final endpoint = Endpoint.tryParse('http://192.0.2.42:80');
        expect(endpoint?.port, 80);
        expect(endpoint?.canonical, 'http://192.0.2.42:80');
      });

      test('an explicit :80 survives without a scheme too', () {
        expect(Endpoint.tryParse('192.0.2.42:80')?.port, 80);
      });

      test('an explicit :443 on https survives', () {
        final endpoint = Endpoint.tryParse('https://generation.example.com:443');
        expect(endpoint?.port, 443);
        // Writing it back out is optional here: left off, it is read back as
        // 443 either way, which is what makes it safe to elide.
        expect(endpoint?.canonical, 'https://generation.example.com');
      });

      test('an explicit :443 on http is not mistaken for a default', () {
        final endpoint = Endpoint.tryParse('http://192.0.2.42:443');
        expect(endpoint?.port, 443);
        expect(endpoint?.canonical, 'http://192.0.2.42:443');
      });

      test('an explicit :80 on https survives', () {
        final endpoint = Endpoint.tryParse('https://generation.example.com:80');
        expect(endpoint?.port, 80);
        expect(endpoint?.canonical, 'https://generation.example.com:80');
      });

      test('a port on a bracketed IPv6 literal is still read as a port', () {
        expect(Endpoint.tryParse('http://[fe80::1]:80')?.port, 80);
        expect(Endpoint.tryParse('http://[fe80::1]')?.port, kDefaultGatewayPort);
      });

      test('a port survives a path prefix', () {
        final endpoint = Endpoint.tryParse('http://example.com:80/localcanvas');
        expect(endpoint?.port, 80);
        expect(endpoint?.canonical, 'http://example.com:80/localcanvas');
      });

      test('an endpoint on port 80 is not the same as one on 7801', () {
        expect(
          Endpoint.tryParse('http://192.0.2.42:80'),
          isNot(Endpoint.tryParse('http://192.0.2.42')),
        );
      });

      test('a request to a port-80 endpoint goes to port 80', () {
        expect(
          Endpoint.tryParse('http://192.0.2.42:80')!
              .resolvePath('/api/v1/info')
              .port,
          80,
        );
      });
    });

    group('canonical is what gets stored, so it must read back the same', () {
      // `EndpointStore` persists `canonical` and reloads it through
      // `tryParse`. Any address whose canonical form parses to something else
      // is a server silently swapped, or lost, across a restart.
      const addresses = <String>[
        '192.0.2.42',
        '192.0.2.42:7801',
        'http://192.0.2.42:80',
        'http://192.0.2.42:443',
        'https://generation.example.com',
        'https://generation.example.com:443',
        'https://generation.example.com:80',
        'https://generation.example.com:8443',
        'https://generation.example.com/localcanvas',
        'http://example.com:80/localcanvas',
        '[fe80::1]',
        'http://[2001:db8::42]:80',
        'studio-pc.local',
      ];

      for (final address in addresses) {
        test('$address round-trips through its canonical form', () {
          final once = Endpoint.tryParse(address);
          expect(once, isNotNull, reason: '$address should be readable');
          final twice = Endpoint.tryParse(once!.canonical);
          expect(twice, isNotNull, reason: once.canonical);
          expect(twice, once);
          expect(twice!.port, once.port);
          expect(twice.canonical, once.canonical);
        });
      }
    });

    test('surrounding whitespace is not the user\'s problem', () {
      expect(
        Endpoint.tryParse('  192.0.2.42  ')?.canonical,
        'http://192.0.2.42:7801',
      );
    });
  });

  group('rejection is for input this client cannot express', () {
    // docs/transport-boundary.md §4: never for being public, non-RFC1918 or
    // HTTPS. This is the rule most easily lost by being helpful about "local"
    // addresses, so it is asserted directly. The three things that ARE refused
    // -- unparseable text, a foreign scheme, embedded credentials -- are
    // asserted in the group below.
    test('a public HTTPS endpoint is ACCEPTED, port implied by the scheme', () {
      final endpoint = Endpoint.tryParse('https://generation.example.com');
      expect(endpoint, isNotNull);
      expect(endpoint!.canonical, 'https://generation.example.com');
      expect(endpoint.port, 443);
      expect(endpoint.scheme, 'https');
    });

    test('a public HTTP host on a routable address is ACCEPTED', () {
      expect(
        Endpoint.tryParse('203.0.113.7')?.canonical,
        'http://203.0.113.7:7801',
      );
    });

    test('a public HTTPS endpoint with an explicit port is ACCEPTED', () {
      expect(
        Endpoint.tryParse('https://generation.example.com:8443')?.canonical,
        'https://generation.example.com:8443',
      );
    });

    test('empty and blank input is refused', () {
      expect(Endpoint.tryParse(''), isNull);
      expect(Endpoint.tryParse('    '), isNull);
    });

    test('a scheme with no host is refused', () {
      expect(Endpoint.tryParse('http://'), isNull);
    });

    test('a scheme this app cannot speak is refused', () {
      expect(Endpoint.tryParse('ftp://192.0.2.42'), isNull);
      expect(Endpoint.tryParse('localcanvas://connect'), isNull);
    });

    test('text that is not an address is refused', () {
      expect(Endpoint.tryParse('not an address'), isNull);
      expect(Endpoint.tryParse('http://host name/'), isNull);
      expect(Endpoint.tryParse(':::'), isNull);
    });

    test('an out-of-range port is refused', () {
      expect(Endpoint.tryParse('192.0.2.42:99999'), isNull);
      expect(Endpoint.tryParse('192.0.2.42:0'), isNull);
    });

    test('credentials in the address are refused rather than dropped', () {
      expect(Endpoint.tryParse('http://someone@192.0.2.42:7801'), isNull);
    });
  });

  group('derived URLs', () {
    test('the WebSocket scheme comes from the endpoint, never hardcoded', () {
      expect(Endpoint.tryParse('192.0.2.42')!.webSocketScheme, 'ws');
      expect(
        Endpoint.tryParse('https://generation.example.com')!.webSocketScheme,
        'wss',
      );
    });

    test('an https endpoint produces a wss URL', () {
      expect(
        Endpoint.tryParse('https://generation.example.com')!
            .webSocketUri('/api/v1/events')
            .toString(),
        'wss://generation.example.com/api/v1/events',
      );
    });

    test('an http endpoint produces a ws URL that keeps the port', () {
      expect(
        Endpoint.tryParse('192.0.2.42')!
            .webSocketUri('/api/v1/events')
            .toString(),
        'ws://192.0.2.42:7801/api/v1/events',
      );
    });

    test('a returned path resolves against a root endpoint', () {
      expect(
        Endpoint.tryParse('http://192.0.2.42:7801')!
            .resolvePath('/api/v1/jobs/j-8f21/result/0')
            .toString(),
        'http://192.0.2.42:7801/api/v1/jobs/j-8f21/result/0',
      );
    });

    test('a returned path preserves the endpoint\'s own path prefix', () {
      // The worked example in docs/transport-boundary.md §3. Root-absolute
      // joining would silently drop /localcanvas.
      expect(
        Endpoint.tryParse('https://generation.example.com/localcanvas')!
            .resolvePath('/api/v1/jobs/j-8f21/result/0')
            .toString(),
        'https://generation.example.com/localcanvas/api/v1/jobs/j-8f21/result/0',
      );
    });

    test('a WebSocket URL preserves the path prefix too', () {
      expect(
        Endpoint.tryParse('https://generation.example.com/localcanvas')!
            .webSocketUri('/api/v1/events')
            .toString(),
        'wss://generation.example.com/localcanvas/api/v1/events',
      );
    });
  });

  group('fromHostPort', () {
    test('brackets an IPv6 address so no caller has to know one', () {
      expect(
        Endpoint.fromHostPort('fe80::1', 7801)?.canonical,
        'http://[fe80::1]:7801',
      );
    });

    test('leaves an IPv4 address alone', () {
      expect(
        Endpoint.fromHostPort('192.0.2.42', 7801)?.canonical,
        'http://192.0.2.42:7801',
      );
    });
  });

  test('equal endpoints compare equal', () {
    expect(
      Endpoint.tryParse('192.0.2.42'),
      Endpoint.tryParse('http://192.0.2.42:7801/'),
    );
  });
}
