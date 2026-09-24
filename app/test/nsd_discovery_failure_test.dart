/// What the app learns when Android's DNS-SD stack refuses to start.
///
/// The platform channel is faked; everything above it is real. That matters:
/// the error is built by the `nsd` package's own conversion from a
/// `PlatformException`, travels the same path as it would on the phone, and
/// arrives at `NsdDiscoveryBackend.start` as the `NsdError` the plugin would
/// actually throw. A test that constructed an `NsdError` by hand would prove
/// the translation function and nothing about the code that calls it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/discovery.dart';
import 'package:localcanvas/connection/nsd_discovery.dart';
import 'package:nsd/nsd.dart' as nsd;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The channel the `nsd` plugin talks to the Android side over.
  const channel = MethodChannel('com.haberey/nsd');

  /// Answers `startDiscovery` the way the native plugin does when it refuses.
  ///
  /// `nsd_android` fails with a `code` that is the `ErrorCause` name and a
  /// `message` that is the only place the detail lives.
  void refuseWith(String code, String message) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'startDiscovery') {
        throw PlatformException(code: code, message: message);
      }
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a refusal the plugin classified keeps both halves', () async {
    // Exactly what `nsd_android` throws when the app never declared
    // CHANGE_WIFI_MULTICAST_STATE: it builds no multicast lock at attach time
    // and then refuses every discovery.
    refuseWith(
      'securityIssue',
      'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
    );

    Object? thrown;
    try {
      await const NsdDiscoveryBackend().start();
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<DiscoveryFailure>());
    final failure = thrown! as DiscoveryFailure;
    expect(failure.cause, 'securityIssue');
    expect(
      failure.reason,
      'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
    );
    expect(
      failure.summary,
      'securityIssue: Missing required permission '
          'CHANGE_WIFI_MULTICAST_STATE',
    );
  });

  test('a refusal with a different cause reads as that cause', () async {
    // Nothing here is written for one permission: the cause is whatever the
    // platform said it was.
    refuseWith('maxLimit', 'Maximum outstanding requests reached');

    Object? thrown;
    try {
      await const NsdDiscoveryBackend().start();
    } catch (error) {
      thrown = error;
    }

    expect(
      (thrown! as DiscoveryFailure).summary,
      'maxLimit: Maximum outstanding requests reached',
    );
  });

  test('a cause the plugin does not name still arrives as a reason', () async {
    // `nsd` maps an unrecognised code to `internalError` and keeps the
    // message. The app repeats what it was told rather than improving it.
    refuseWith('somethingNobodyEnumerated', 'the radio is asleep');

    Object? thrown;
    try {
      await const NsdDiscoveryBackend().start();
    } catch (error) {
      thrown = error;
    }

    expect(
      (thrown! as DiscoveryFailure).summary,
      'internalError: the radio is asleep',
    );
  });

  test('the reason is the message, not the error object printed', () async {
    // The failure a reader sees must not be an `NsdError.toString()` that has
    // leaked through untranslated — that is what "reported as an unknown
    // failure" looks like from the screen.
    refuseWith(
      'securityIssue',
      'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
    );

    Object? thrown;
    try {
      await const NsdDiscoveryBackend().start();
    } catch (error) {
      thrown = error;
    }

    final untranslated = nsd.NsdError(
      nsd.ErrorCause.securityIssue,
      'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
    ).toString();
    expect(
      untranslated,
      'NsdError (message: "Missing required permission '
          'CHANGE_WIFI_MULTICAST_STATE", cause: securityIssue)',
      reason: 'the shape this test is guarding against has changed',
    );
    expect((thrown! as DiscoveryFailure).summary, isNot(untranslated));
  });

  test('a failure at start is not a failure that started', () async {
    // The whole path, not just the translation: a controller driven by the
    // real backend lands on `unavailable` with the platform's words on it.
    refuseWith(
      'securityIssue',
      'Missing required permission CHANGE_WIFI_MULTICAST_STATE',
    );

    final discovery = DiscoveryController(
      backend: const NsdDiscoveryBackend(),
      window: const Duration(milliseconds: 30),
    );
    addTearDown(discovery.dispose);

    await discovery.scan();

    expect(discovery.status, DiscoveryStatus.unavailable);
    expect(discovery.failure?.stage, DiscoveryFailureStage.start);
    expect(
      discovery.failure?.summary,
      'securityIssue: Missing required permission '
          'CHANGE_WIFI_MULTICAST_STATE',
    );
  });
}
