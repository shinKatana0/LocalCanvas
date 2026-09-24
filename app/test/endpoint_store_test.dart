/// The remembered endpoint, through the real store.
///
/// `PreferencesEndpointStore` writes `Endpoint.canonical` and reads it back
/// with `Endpoint.tryParse`, so a canonical form that does not round-trip is a
/// server the app connects to today and cannot find tomorrow. The platform is
/// the package's own in-memory implementation; everything above it is the code
/// that ships.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/endpoint_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesEndpointStore store;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = PreferencesEndpointStore();
  });

  Future<void> remember(Endpoint endpoint, {String name = 'Studio PC'}) =>
      store.remember(
        RememberedServer(
          endpoint: endpoint,
          displayName: name,
          lastSuccess: DateTime.utc(2026, 9, 2, 19, 41),
        ),
      );

  test('nothing is remembered to begin with', () async {
    expect(await store.load(), isNull);
  });

  test('a remembered server comes back whole', () async {
    final endpoint = Endpoint.tryParse('192.0.2.42')!;
    await remember(endpoint);

    final loaded = await store.load();

    expect(loaded?.endpoint, endpoint);
    expect(loaded?.displayName, 'Studio PC');
    expect(loaded?.lastSuccess, DateTime.utc(2026, 9, 2, 19, 41));
  });

  group('every address survives being written down and read back', () {
    const addresses = <String>[
      '192.0.2.42',
      'http://192.0.2.42:80',
      'http://192.0.2.42:443',
      'https://generation.example.com',
      'https://generation.example.com:443',
      'https://generation.example.com:8443',
      'https://generation.example.com/localcanvas',
      'http://example.com:80/localcanvas',
      'http://[2001:db8::42]:80',
      'studio-pc.local',
    ];

    for (final address in addresses) {
      test(address, () async {
        final endpoint = Endpoint.tryParse(address)!;
        await remember(endpoint);

        final loaded = await store.load();

        expect(loaded?.endpoint, endpoint);
        expect(loaded?.endpoint.port, endpoint.port);
        expect(loaded?.endpoint.scheme, endpoint.scheme);
        expect(loaded?.endpoint.pathPrefix, endpoint.pathPrefix);
      });
    }
  });

  test('a gateway on port 80 is still on port 80 after a restart', () async {
    // The reverse-proxied deployment `docs/transport-boundary.md` exists to
    // keep possible. Losing the port here would send the next launch to 7801
    // and report an address the user never entered as unreachable.
    await remember(Endpoint.tryParse('http://192.0.2.42:80')!);

    expect((await store.load())?.endpoint.port, 80);
  });

  test('forgetting empties it', () async {
    await remember(Endpoint.tryParse('192.0.2.42')!);
    await store.forget();

    expect(await store.load(), isNull);
  });

  test('an unreadable stored value is dropped rather than carried forward',
      () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(<String, Object>{
      'localcanvas.endpoint': 'not an address',
      'localcanvas.endpoint.display_name': 'Studio PC',
    });
    store = PreferencesEndpointStore();

    expect(await store.load(), isNull);
    // And it does not come back on the next launch either.
    expect(await store.load(), isNull);
  });
}
