/// A scan that will not stop must not take the next scan down with it.
///
/// T-0164. Two things went wrong at once and they are different failures:
///
///   * every **ordinary** window close ran `unawaited(_teardown())`, so a
///     `stop()` that threw leaked the error to the zone — on the success path,
///     every single scan;
///   * the next `scan()` awaited `_teardown()` **first**, so the same throw
///     aborted it *before* the servers were cleared and the status moved. The
///     screen stayed on `scanning` and Search again did nothing at all.
///
/// The second is what a person sees. The first is what a developer would have
/// had to explain it with, and it was being thrown away.
///
/// It is reachable rather than theoretical: on Android `stopDiscovery` carries
/// the same multicast-lock gate as `startDiscovery` and refuses the same way
/// (`nsd_discovery.dart`), which is the permission T-0163 exists to declare.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/discovery.dart';
import 'package:localcanvas/connection/endpoint.dart';

import 'support/fakes.dart';

void main() {
  const window = Duration(milliseconds: 40);

  DiscoveredServer server(String id) => DiscoveredServer(
    id: id,
    displayName: 'Studio PC',
    endpoint: Endpoint.fromHostPort('192.0.2.42', 7801)!,
    gatewayVersion: '0.1.0',
    apiVersion: 1,
  );

  /// Everything `debugPrint` wrote while [body] ran.
  Future<List<String>> printed(Future<void> Function() body) async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      await body();
    } finally {
      debugPrint = previous;
    }
    return lines;
  }

  group('a session that refuses to stop', () {
    test('does not take the next scan down with it', () async {
      final backend = FakeDiscoveryBackend();
      final discovery = DiscoveryController(backend: backend, window: window);
      addTearDown(discovery.dispose);

      await discovery.scan();
      backend.announce(server('a'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(discovery.servers, hasLength(1));

      // From here the platform will not let go.
      backend.stopError = StateError('stopDiscovery rejected');

      // This is Search again. Before T-0164 it rejected here, inside the
      // teardown at the top of scan(), and nothing below it ran.
      await discovery.scan();

      expect(
        discovery.status,
        DiscoveryStatus.scanning,
        reason: 'the second scan must actually start',
      );
      expect(
        discovery.servers,
        isEmpty,
        reason: 'the previous scan\'s servers must be cleared, and were not '
            'when the teardown threw before reaching the clear',
      );
      expect(backend.starts, 2, reason: 'the backend was asked a second time');
    });

    test('lets the scan finish, so the status leaves scanning', () async {
      final backend = FakeDiscoveryBackend(
        stopError: StateError('stopDiscovery rejected'),
      );
      final discovery = DiscoveryController(backend: backend, window: window);
      addTearDown(discovery.dispose);

      await discovery.scan();
      await Future<void>.delayed(window + const Duration(milliseconds: 20));

      expect(discovery.status, DiscoveryStatus.finished);
    });

    test('leaks nothing to the zone when the window closes normally', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final backend = FakeDiscoveryBackend(
          stopError: StateError('stopDiscovery rejected'),
        );
        final discovery = DiscoveryController(backend: backend, window: window);
        addTearDown(discovery.dispose);

        await discovery.scan();
        // The ordinary path: the window timer fires and closes the scan.
        await Future<void>.delayed(window + const Duration(milliseconds: 20));
      }, (Object error, StackTrace stack) => errors.add(error));

      expect(
        errors,
        isEmpty,
        reason: 'unawaited(_teardown()) in _closeWindow leaked this on every '
            'successful scan',
      );
    });

    test('leaks nothing to the zone from stop()', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final backend = FakeDiscoveryBackend(
          stopError: StateError('stopDiscovery rejected'),
        );
        final discovery = DiscoveryController(backend: backend, window: window);
        addTearDown(discovery.dispose);

        await discovery.scan();
        await discovery.stop();
        expect(discovery.status, DiscoveryStatus.finished);
      }, (Object error, StackTrace stack) => errors.add(error));

      expect(errors, isEmpty);
    });

    test('writes the reason down, naming the stage it came from', () async {
      final lines = await printed(() async {
        final backend = FakeDiscoveryBackend(
          stopError: StateError('stopDiscovery rejected'),
        );
        final discovery = DiscoveryController(backend: backend, window: window);
        addTearDown(discovery.dispose);
        await discovery.scan();
        await discovery.stop();
      });

      expect(lines, <String>[
        '[localcanvas:discovery] stop: Bad state: stopDiscovery rejected',
      ]);
    });

    test('says nothing about the scan itself — it is not unavailable', () async {
      final backend = FakeDiscoveryBackend(
        stopError: StateError('stopDiscovery rejected'),
      );
      final discovery = DiscoveryController(backend: backend, window: window);
      addTearDown(discovery.dispose);

      await discovery.scan();
      backend.announce(server('a'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await discovery.stop();

      expect(discovery.status, DiscoveryStatus.finished);
      expect(
        discovery.failure,
        isNull,
        reason: 'a stop that threw says nothing about whether the scan worked, '
            'and the scan found a server',
      );
      expect(discovery.servers, hasLength(1));
    });

    test('a cause carried by the throw survives into the line', () async {
      final lines = await printed(() async {
        final backend = FakeDiscoveryBackend(
          stopError: const DiscoveryFailure(
            reason: 'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
            cause: 'securityIssue',
          ),
        );
        final discovery = DiscoveryController(backend: backend, window: window);
        addTearDown(discovery.dispose);
        await discovery.scan();
        await discovery.stop();
      });

      expect(lines, <String>[
        '[localcanvas:discovery] stop: securityIssue: '
            'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
      ]);
    });
  });

  group('the release steps are independent', () {
    test('a session is still asked to stop after a cancel that threw', () async {
      final backend = _CancelRefusingBackend();
      final discovery = DiscoveryController(backend: backend, window: window);
      addTearDown(discovery.dispose);

      await discovery.scan();
      await discovery.stop();

      expect(
        backend.stops,
        1,
        reason: 'releasing one resource is not conditional on releasing the '
            'other',
      );
    });
  });

  group('the ordinary path is untouched', () {
    test('a stop that succeeds behaves exactly as before', () async {
      final backend = FakeDiscoveryBackend();
      final discovery = DiscoveryController(backend: backend, window: window);
      addTearDown(discovery.dispose);

      final lines = await printed(() async {
        await discovery.scan();
        backend.announce(server('a'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await discovery.stop();
      });

      expect(discovery.status, DiscoveryStatus.finished);
      expect(discovery.servers, hasLength(1));
      expect(discovery.failure, isNull);
      expect(backend.stops, 1);
      expect(lines, isEmpty, reason: 'nothing failed, so nothing is written');
    });

    test('a start failure still reaches the screen', () async {
      final backend = FakeDiscoveryBackend(failsToStart: true);
      final discovery = DiscoveryController(backend: backend, window: window);
      addTearDown(discovery.dispose);

      await discovery.scan();

      expect(discovery.status, DiscoveryStatus.unavailable);
      expect(discovery.failure, isNotNull);
      expect(discovery.failure!.stage, DiscoveryFailureStage.start);
    });
  });
}

/// A backend whose subscription refuses to cancel.
///
/// The first release step throwing must not stop the second being taken: a
/// stream this app cannot detach from says nothing about whether the platform
/// can release the radio.
class _CancelRefusingBackend implements DiscoveryBackend {
  int stops = 0;

  @override
  Future<DiscoverySession> start() async => _CancelRefusingSession(this);
}

class _CancelRefusingSession implements DiscoverySession {
  _CancelRefusingSession(this._backend);

  final _CancelRefusingBackend _backend;

  @override
  Stream<DiscoveredServer> get found => _RefusingStream();

  @override
  Future<void> stop() async => _backend.stops++;
}

class _RefusingStream extends Stream<DiscoveredServer> {
  @override
  StreamSubscription<DiscoveredServer> listen(
    void Function(DiscoveredServer)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _RefusingSubscription();
}

class _RefusingSubscription implements StreamSubscription<DiscoveredServer> {
  @override
  Future<void> cancel() async => throw StateError('cancel rejected');

  @override
  void onData(void Function(DiscoveredServer)? handleData) {}
  @override
  void onError(Function? handleError) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void pause([Future<void>? resumeSignal]) {}
  @override
  void resume() {}
  @override
  bool get isPaused => false;
  @override
  Future<E> asFuture<E>([E? futureValue]) => Completer<E>().future;
}
