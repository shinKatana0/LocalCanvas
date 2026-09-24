/// What the app tells the gateway about the language on screen (T-0142).
///
/// Over a real HTTP server on loopback, so what is asserted is the header that
/// actually crossed the socket rather than the map the client meant to build.
/// `T-0143` is the card that makes the gateway answer it; nothing here depends
/// on that having happened.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/generation/jobs_api.dart';
import 'package:localcanvas/l10n/locale_controller.dart';
import 'package:localcanvas/media/media_api.dart';
import 'package:localcanvas/l10n/locale_store.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:flutter/widgets.dart' show Locale;

import 'support/fake_gateway.dart';
import 'support/fakes.dart';
import 'support/media_fakes.dart';

void main() {
  late FakeGateway server;

  setUp(() async {
    server = await FakeGateway.start();
  });

  tearDown(() async => server.stop());

  /// The header of the last request the server saw.
  String? lastLanguage() => server.requests.last.acceptLanguage;

  /// Every language header the server saw, in order.
  List<String?> languages() =>
      server.requests.map((r) => r.acceptLanguage).toList();

  /// A live controller over a fake store, so the tag really is the app's own
  /// resolved locale rather than a constant a test typed in.
  LocaleController controllerOn(String phone) {
    final controller = LocaleController(
      store: InMemoryLocaleStore(),
      systemLocales: <Locale>[Locale(phone)],
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('every request carries the active locale', () {
    test('the handshake does', () async {
      final language = controllerOn('ru');
      final client = GatewayClient(language: () => language.languageTag);
      addTearDown(client.dispose);

      await client.handshake(server.endpoint);

      expect(lastLanguage(), 'ru');
    });

    test('the registry does, both the list and a detail', () async {
      final language = controllerOn('ru');
      final api = HttpWorkflowsApi(language: () => language.languageTag);
      addTearDown(api.dispose);
      server.serveJson('/api/v1/workflows', <String, Object?>{
        'workflows': <Object?>[],
      });
      server.serveJson('/api/v1/workflows/w', <String, Object?>{
        'id': 'w',
        'name': 'W',
        'inputs': <Object?>[],
      });

      await api.list(server.endpoint);
      await api.detail(server.endpoint, 'w');

      expect(languages(), <String>['ru', 'ru']);
    });

    test('a job submission does, alongside its content type', () async {
      final language = controllerOn('ru');
      final api = HttpJobsApi(language: () => language.languageTag);
      addTearDown(api.dispose);
      server.serveJson('/api/v1/jobs', <String, Object?>{
        'job_id': 'j',
        'state': 'queued',
      }, status: 201);

      await api.submit(
        server.endpoint,
        workflowId: 'w',
        inputs: const <String, Object?>{},
      );

      expect(lastLanguage(), 'ru');
      // The submission's own `Content-Type` is still there: the language went
      // beside it rather than over it.
      expect(server.requests.last.contentType, contains('application/json'));
    });

    test('a media upload does, alongside its multipart envelope', () async {
      // The fourth client, and the one the card's own scope nearly missed
      // (T-0148): it builds its request by hand and lower-cases its header
      // names, so the search for `'Accept': 'application/json'` that produced
      // the original list of three did not find it.
      final language = controllerOn('ru');
      final api = HttpMediaApi(language: () => language.languageTag);
      addTearDown(api.dispose);
      server.serveJson(kMediaPath, <String, Object?>{
        'media_id': 'm-1',
        'kind': 'image',
        'bytes': 2048,
      });

      await api.upload(server.endpoint, tempSelection(bytes: 2048));

      expect(lastLanguage(), 'ru');
      // Beside the envelope rather than over it: the multipart boundary and
      // the `Accept` this request already sent are both still there.
      expect(
        server.requests.last.contentType,
        startsWith('multipart/form-data'),
      );
      expect(server.requests.last.accept, 'application/json');
    });

    test('and a snapshot does', () async {
      final language = controllerOn('ru');
      final api = HttpJobsApi(language: () => language.languageTag);
      addTearDown(api.dispose);
      server.serveJson('/api/v1/jobs/j', <String, Object?>{
        'job_id': 'j',
        'state': 'completed',
      });

      await api.snapshot(server.endpoint, 'j');

      expect(lastLanguage(), 'ru');
    });
  });

  group('it is the language, not a constant', () {
    test('an English phone sends en and a Russian phone sends ru', () async {
      // The same client shape over two different phones. A client that had
      // been given a constant passes one of these and fails the other.
      for (final phone in <String>['en', 'ru']) {
        final language = controllerOn(phone);
        final client = GatewayClient(language: () => language.languageTag);
        addTearDown(client.dispose);
        await client.handshake(server.endpoint);
        expect(lastLanguage(), phone, reason: 'a $phone phone');
      }
    });

    test('it follows a choice made after the client was composed', () async {
      // The failure this catches is a client that captured the tag at
      // composition time. It is composed once, at launch, and the language can
      // change at any moment after that.
      final language = LocaleController(
        store: InMemoryLocaleStore(),
        systemLocales: <Locale>[const Locale('en')],
      );
      addTearDown(language.dispose);
      final client = GatewayClient(language: () => language.languageTag);
      addTearDown(client.dispose);

      await client.handshake(server.endpoint);
      await language.choose(LocaleChoice.of(const Locale('ru')));
      await client.handshake(server.endpoint);
      await language.choose(LocaleChoice.of(const Locale('en')));
      await client.handshake(server.endpoint);

      expect(languages(), <String>['en', 'ru', 'en']);
    });

    test('the header is a bare tag: no region, no q-value, no list', () async {
      // The seam with T-0143, settled on both sides. A phone in Belarus asks
      // for `ru`, not `ru-BY`, so neither half has to parse the other's
      // generality.
      final language = LocaleController(
        store: InMemoryLocaleStore(),
        systemLocales: <Locale>[const Locale('ru', 'BY')],
      );
      addTearDown(language.dispose);
      final client = GatewayClient(language: () => language.languageTag);
      addTearDown(client.dispose);

      await client.handshake(server.endpoint);

      final header = lastLanguage()!;
      expect(header, 'ru');
      expect(header, isNot(contains(',')));
      expect(header, isNot(contains(';')));
      expect(header, isNot(contains('-')));
      expect(header, isNot(contains('q=')));
    });

    test('a phone in a language this build does not have still asks for one '
        'it does', () async {
      // The header says what the app is *drawing*, not what the phone wants.
      // A gateway told `ja` would answer in a language nothing on this screen
      // is written in.
      final language = LocaleController(
        store: InMemoryLocaleStore(),
        systemLocales: <Locale>[const Locale('ja')],
      );
      addTearDown(language.dispose);
      final client = GatewayClient(language: () => language.languageTag);
      addTearDown(client.dispose);

      await client.handshake(server.endpoint);

      expect(lastLanguage(), 'en');
    });
  });
}
