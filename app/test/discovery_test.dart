/// Discovery is bounded, degrades honestly, and is never a dependency.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/discovery.dart';
import 'package:localcanvas/connection/endpoint.dart';

import 'support/fakes.dart';

void main() {
  DiscoveredServer server(String id, String name, int port) => DiscoveredServer(
    id: id,
    displayName: name,
    endpoint: Endpoint.fromHostPort('192.0.2.42', port)!,
    gatewayVersion: '0.1.0',
    apiVersion: 1,
  );

  test('the advertised service type is the one the gateway registers', () {
    expect(kServiceType, '_localcanvas._tcp');
  });

  test('servers are listed by their display name', () async {
    final backend = FakeDiscoveryBackend();
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 40),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();
    backend.announce(server('a', 'Studio PC', 7801));
    backend.announce(server('b', 'Attic Box', 7802));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(
      discovery.servers.map((s) => s.displayName),
      <String>['Studio PC', 'Attic Box'],
    );
  });

  test('a re-announced server does not appear twice', () async {
    final backend = FakeDiscoveryBackend();
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 40),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();
    backend.announce(server('a', 'Studio PC', 7801));
    backend.announce(server('a', 'Studio PC renamed', 7801));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(discovery.servers, hasLength(1));
    expect(discovery.servers.single.displayName, 'Studio PC renamed');
  });

  test('the scan window closes on its own and stops the session', () async {
    final backend = FakeDiscoveryBackend();
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 30),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();
    expect(discovery.status, DiscoveryStatus.scanning);

    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Bounded: the search ends by itself, and the platform resource with it.
    expect(discovery.status, DiscoveryStatus.finished);
    expect(backend.stops, 1);
  });

  test('a device that cannot search says so instead of scanning forever',
      () async {
    final backend = FakeDiscoveryBackend(failsToStart: true);
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 30),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();

    expect(discovery.status, DiscoveryStatus.unavailable);
    expect(discovery.servers, isEmpty);
  });

  test('a failure mid-scan is reported, not swallowed', () async {
    final backend = FakeDiscoveryBackend();
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 200),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();
    backend.fail(StateError('multicast blocked'));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(discovery.status, DiscoveryStatus.unavailable);
  });

  test('searching again clears what the last scan found', () async {
    final backend = FakeDiscoveryBackend();
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 30),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();
    backend.announce(server('a', 'Studio PC', 7801));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    await discovery.scan();

    expect(discovery.status, DiscoveryStatus.scanning);
    expect(discovery.servers, isEmpty);
    expect(backend.starts, 2);
  });

  test('nothing rescans on its own — a second search is a decision', () async {
    final backend = FakeDiscoveryBackend();
    final discovery = DiscoveryController(
      backend: backend,
      window: const Duration(milliseconds: 20),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(backend.starts, 1);
    expect(discovery.status, DiscoveryStatus.finished);
  });

  group('a scan that fails says why', () {
    /// What the `nsd_android` plugin throws when the app has not declared
    /// `CHANGE_WIFI_MULTICAST_STATE`: it creates no multicast lock, and every
    /// `startDiscovery` refuses. `nsd_discovery.dart` turns that into this.
    const missingPermission = DiscoveryFailure(
      reason: 'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
      cause: 'securityIssue',
    );

    test('a scan that never started carries the reason it did not', () async {
      final backend = FakeDiscoveryBackend(startError: missingPermission);
      final discovery = DiscoveryController(
        backend: backend,
        window: const Duration(milliseconds: 30),
      );
      addTearDown(discovery.dispose);

      await discovery.scan();

      expect(discovery.status, DiscoveryStatus.unavailable);
      expect(
        discovery.failure?.summary,
        'securityIssue: Missing required permission '
            'CHANGE_WIFI_MULTICAST_STATE',
      );
      expect(discovery.failure?.stage, DiscoveryFailureStage.start);
    });

    test('a failure arriving after the scan started carries it too', () async {
      final backend = FakeDiscoveryBackend();
      final discovery = DiscoveryController(
        backend: backend,
        window: const Duration(milliseconds: 200),
      );
      addTearDown(discovery.dispose);

      // A different code path entirely: this scan *started*, then broke.
      await discovery.scan();
      expect(discovery.status, DiscoveryStatus.scanning);
      backend.fail(
        const DiscoveryFailure(
          reason: 'Operation already active',
          cause: 'alreadyActive',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(discovery.status, DiscoveryStatus.unavailable);
      expect(
        discovery.failure?.summary,
        'alreadyActive: Operation already active',
      );
      expect(discovery.failure?.stage, DiscoveryFailureStage.scan);
    });

    test('a throw nobody classified is still readable, not a crash', () async {
      final backend = FakeDiscoveryBackend(
        startError: StateError('mDNS socket refused'),
      );
      final discovery = DiscoveryController(
        backend: backend,
        window: const Duration(milliseconds: 30),
      );
      addTearDown(discovery.dispose);

      await discovery.scan();

      // No cause to report, so none is invented — and the words survive.
      expect(discovery.status, DiscoveryStatus.unavailable);
      expect(discovery.failure?.cause, isNull);
      expect(discovery.failure?.summary, 'Bad state: mDNS socket refused');
    });

    test('an unclassified failure mid-scan is readable as well', () async {
      final backend = FakeDiscoveryBackend();
      final discovery = DiscoveryController(
        backend: backend,
        window: const Duration(milliseconds: 200),
      );
      addTearDown(discovery.dispose);

      await discovery.scan();
      backend.fail(StateError('multicast blocked'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(discovery.failure?.cause, isNull);
      expect(discovery.failure?.summary, 'Bad state: multicast blocked');
      expect(discovery.failure?.stage, DiscoveryFailureStage.scan);
    });

    test('the reason reaches the log, naming the path it came from', () async {
      final lines = <String>[];
      final realDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = realDebugPrint);

      final backend = FakeDiscoveryBackend(startError: missingPermission);
      final discovery = DiscoveryController(
        backend: backend,
        window: const Duration(milliseconds: 200),
      );
      addTearDown(discovery.dispose);

      await discovery.scan();

      expect(lines, <String>[
        '[localcanvas:discovery] start: securityIssue: '
            'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
      ]);

      // The same session, the other path: a second failure is a second line,
      // and the line says which of the two paths produced it.
      backend.startError = null;
      await discovery.scan();
      backend.fail(const DiscoveryFailure(reason: 'link went down'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(lines.last, '[localcanvas:discovery] scan: link went down');
    });

    test('searching again clears the last reason', () async {
      final backend = FakeDiscoveryBackend(startError: missingPermission);
      final discovery = DiscoveryController(
        backend: backend,
        window: const Duration(milliseconds: 200),
      );
      addTearDown(discovery.dispose);

      await discovery.scan();
      // There was something to clear: without this, the assertion below would
      // pass just as well on an app that never recorded a reason at all.
      expect(discovery.failure, isNotNull);

      backend.startError = null;
      await discovery.scan();

      expect(discovery.status, DiscoveryStatus.scanning);
      expect(discovery.failure, isNull);
    });
  });
}
