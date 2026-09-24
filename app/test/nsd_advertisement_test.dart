/// Reading one mDNS advertisement. The platform is not involved: an
/// `nsd.Service` is a plain object, and the mapping is where the decisions are.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/nsd_discovery.dart';
import 'package:nsd/nsd.dart' as nsd;

void main() {
  Uint8List txt(String value) => Uint8List.fromList(utf8.encode(value));

  nsd.Service advertisement({
    String? name = 'studio-pc',
    String? host = 'studio-pc.local',
    int? port = 7801,
    List<InternetAddress>? addresses,
    Map<String, Uint8List?>? records,
  }) => nsd.Service(
    name: name,
    type: '_localcanvas._tcp',
    host: host,
    port: port,
    addresses: addresses,
    txt: records ??
        <String, Uint8List?>{
          'name': txt('Studio PC'),
          'port': txt('7801'),
          'version': txt('0.1.0'),
          'api': txt('1'),
        },
  );

  test('the display name comes from the TXT record the gateway sets', () {
    final server = serverFromAdvertisement(advertisement());

    expect(server?.displayName, 'Studio PC');
    expect(server?.gatewayVersion, '0.1.0');
    expect(server?.apiVersion, 1);
  });

  test('a resolved address is preferred over the mDNS hostname', () {
    final server = serverFromAdvertisement(
      advertisement(addresses: <InternetAddress>[
        InternetAddress('192.0.2.42'),
      ]),
    );

    expect(server?.endpoint.canonical, 'http://192.0.2.42:7801');
  });

  test('an IPv6 address is bracketed, not guessed at', () {
    final server = serverFromAdvertisement(
      advertisement(addresses: <InternetAddress>[
        InternetAddress('fe80::1', type: InternetAddressType.IPv6),
      ]),
    );

    expect(server?.endpoint.canonical, 'http://[fe80::1]:7801');
  });

  test('a non-default port is honoured', () {
    final server = serverFromAdvertisement(advertisement(port: 9001));

    expect(server?.endpoint.port, 9001);
  });

  test('an advertisement with no name falls back to the service name', () {
    final server = serverFromAdvertisement(
      advertisement(records: <String, Uint8List?>{'port': txt('7801')}),
    );

    expect(server?.displayName, 'studio-pc');
  });

  test('an advertisement we cannot address is dropped, not guessed at', () {
    expect(
      serverFromAdvertisement(advertisement(host: null, port: null)),
      isNull,
    );
    expect(serverFromAdvertisement(advertisement(host: '')), isNull);
  });
}
