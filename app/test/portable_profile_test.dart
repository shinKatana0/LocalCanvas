/// The portable profile: what leaves the phone, what comes back, and the two
/// things this card had to settle to make either possible.
///
/// The stores here are the real ones over the package's own in-memory
/// platform, and the document is the one the app actually hands to the share
/// sheet — read out of a recording transport rather than assembled by the
/// test. That matters most for the privacy assertions: they are made over the
/// **serialised text**, in a state where a gateway endpoint really is
/// remembered and a picture really was uploaded, so the values genuinely
/// existed to leak.
library;

import 'support/graph_vocabulary.dart';
import 'support/l10n.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/connection/gateway_identity.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/l10n/locale_controller.dart';
import 'package:localcanvas/l10n/locale_store.dart';
import 'package:localcanvas/theme/theme_mode_controller.dart';
import 'package:localcanvas/theme/theme_mode_store.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/profile_exchange.dart';
import 'package:localcanvas/workflows/profile_transport.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_profile.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/media_fakes.dart';
import 'support/shell_before_profile.dart';
import 'support/workflow_payloads.dart';

/// The share sheet and the document picker, recorded rather than performed.
class RecordingProfileTransport implements ProfileTransport {
  RecordingProfileTransport({this.incoming});

  /// What the picker answers with. `null` is the user choosing nothing.
  String? incoming;

  final List<ProfileDocument> sent = <ProfileDocument>[];
  int receives = 0;

  ProfileFailure? sendFailure;
  ProfileFailure? receiveFailure;

  /// The document that went out, as text.
  String get sentText => sent.single.text;

  @override
  Future<void> send(ProfileDocument document) async {
    final failure = sendFailure;
    if (failure != null) throw failure;
    sent.add(document);
  }

  /// The label the screen asked the system picker to use, per call. It is a
  /// sentence a person reads, so which one arrived is worth recording.
  final List<String?> typeLabels = <String?>[];

  @override
  Future<String?> receive({String? typeLabel}) async {
    receives++;
    typeLabels.add(typeLabel);
    final failure = receiveFailure;
    if (failure != null) throw failure;
    return incoming;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpoint = Endpoint.tryParse('192.0.2.42')!;
  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;
  late RecordingProfileTransport transport;
  late ScriptedWorkflowsApi registry;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
    transport = RecordingProfileTransport();
  });

  /// Everything the preferences hold, read around the app rather than through
  /// it — so an assertion about a key cannot be satisfied by the same code
  /// that wrote it.
  Future<Map<String, Object?>> preferences() =>
      SharedPreferencesAsync().getAll();

  /// A registry, connected, with the real stores behind it. Calling this twice
  /// in one test is the app being opened twice on the same device: the
  /// controllers are new, the preferences are not.
  Future<WorkflowsController> opened(
    List<Map<String, Object?>> details, {
    bool keepsProfile = true,
    bool withMedia = false,
  }) async {
    registry = ScriptedWorkflowsApi(
      summaries: WorkflowSummary.listFromJson(registryOf(details)),
      details: <String, WorkflowDetail>{
        for (final body in details)
          body['id']! as String: WorkflowDetail.tryFromJson(body)!,
      },
    );
    final controller = WorkflowsController(
      api: registry,
      settings: PreferencesWorkflowSettingsStore(),
      drafts: PreferencesWorkflowDraftStore(),
      setups: PreferencesWorkflowSetupStore(),
      profiles: keepsProfile ? transport : null,
      mediaPicker: withMedia ? picker : null,
      mediaApi: withMedia ? uploads : null,
    );
    addTearDown(controller.dispose);
    await controller.load(endpoint);
    return controller;
  }

  Future<WorkflowFormController> formOf(
    WorkflowsController controller,
    String workflowId,
  ) async {
    await controller.select(workflowId);
    return controller.form!;
  }

  /// The document the app would hand to the share sheet, through the real
  /// path.
  Future<String> exported(WorkflowsController controller) async {
    expect(await controller.exportProfile(), isTrue);
    return transport.sentText;
  }

  /// The two stores, straight, for the tests that are about the document and
  /// not about the controller above it.
  ProfileExchange exchange() => ProfileExchange(
    settings: PreferencesWorkflowSettingsStore(),
    setups: PreferencesWorkflowSetupStore(),
  );

  group('the document', () {
    test('it says what it is and which version it is', () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(controller, 'example_txt2img')).setEntry('width', '512');
      await controller.saveMyDefaults();

      final document =
          jsonDecode(await exported(controller)) as Map<String, Object?>;

      expect(document['format'], 'localcanvas.profile');
      expect(document['version'], 1);
      final workflows = document['workflows']! as Map<String, Object?>;
      final entry = workflows['example_txt2img']! as Map<String, Object?>;
      // Keyed by the workflow's own id and the field's own logical id, which
      // is what makes the document portable at all.
      expect((entry['defaults']! as Map<String, Object?>)['width'], 512);
    });

    test('what it holds survives a round trip through the text', () {
      const profile = WorkflowProfile(
        workflows: <String, ProfileEntry>{
          'example_txt2img': ProfileEntry(
            values: <String, Object?>{'width': 512, 'guidance': 7.5},
          ),
          'example_video': ProfileEntry(
            values: <String, Object?>{'loop': true},
            translatePrompt: false,
          ),
        },
        setups: <WorkflowSetup>[
          WorkflowSetup(
            id: 'k7-1',
            workflowId: 'example_txt2img',
            name: 'Night shots',
            values: <String, Object?>{'prompt': 'a rainy alley'},
          ),
        ],
      );

      final read = decodeProfile(encodeProfile(profile));

      expect(read.workflows.keys, <String>['example_txt2img', 'example_video']);
      expect(
        read.workflows['example_txt2img']!.values,
        <String, Object?>{'width': 512, 'guidance': 7.5},
      );
      expect(read.workflows['example_video']!.translatePrompt, isFalse);
      expect(read.setups.single.id, 'k7-1');
      expect(read.setups.single.name, 'Night shots');
      expect(read.setups.single.values, <String, Object?>{
        'prompt': 'a rainy alley',
      });
    });

    test('a non-English prompt round-trips character for character', () {
      // Russian, Japanese, and text carrying a quoted literal — the three
      // things `docs/api.md` is careful about, and the ones a naive encoder
      // mangles.
      const russian = 'Дождливый переулок ночью, «мокрый асфальт»';
      const japanese = '雨の夜の路地、しっとりした石畳と反射';
      const quoted = 'A poster that says "Grand Hotel" in gold leaf';

      final profile = WorkflowProfile(
        setups: <WorkflowSetup>[
          for (final (index, text) in <String>[
            russian,
            japanese,
            quoted,
          ].indexed)
            WorkflowSetup(
              id: 'k-$index',
              workflowId: 'example_txt2img',
              name: 'Setup $index',
              values: <String, Object?>{'prompt': text},
            ),
        ],
      );

      final read = decodeProfile(encodeProfile(profile));

      expect(read.setups.map((s) => s.values['prompt']).toList(), <String>[
        russian,
        japanese,
        quoted,
      ]);
      // Character for character, and the codepoints prove it: an encoder that
      // normalised or re-escaped would still compare equal as "text" in some
      // languages and not here.
      expect(
        (read.setups.first.values['prompt']! as String).runes.toList(),
        russian.runes.toList(),
      );
    });

    test('the translation answer is written only when it is off', () async {
      final controller = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        videoDetail(),
      ]);
      (await formOf(controller, 'example_txt2img')).translatePrompt = false;
      await controller.saveMyDefaults();
      (await formOf(controller, 'example_video')).setEntry('frames', '48');
      await controller.saveMyDefaults();

      final text = await exported(controller);
      final workflows =
          (jsonDecode(text) as Map<String, Object?>)['workflows']!
              as Map<String, Object?>;

      // Verbatim, so a key-shape refactor is caught here rather than by a
      // count of keys that stays the same however they are spelled.
      expect(text, contains('"translation": "off"'));
      expect(
        (workflows['example_txt2img']! as Map<String, Object?>)['translation'],
        'off',
      );
      // An absence, never the word `auto`: there is no `auto` to write
      // (`docs/api.md`), and a key that is always there and usually empty
      // would be a promise nothing keeps.
      expect(
        (workflows['example_video']! as Map<String, Object?>).containsKey(
          'translation',
        ),
        isFalse,
      );
      expect(text, isNot(contains('auto')));
    });

    test('a future major version is refused, and both numbers are named', () {
      final document = jsonEncode(<String, Object?>{
        'format': kProfileFormat,
        'version': kProfileVersion + 1,
        'workflows': <String, Object?>{
          'example_txt2img': <String, Object?>{
            'defaults': <String, Object?>{'width': 512},
          },
        },
      });

      ProfileFailure? refused;
      try {
        decodeProfile(document);
      } on ProfileFailure catch (failure) {
        refused = failure;
      }

      expect(refused, isNotNull);
      expect(refused!.message(en), contains('version 2'));
      expect(refused.message(en), contains('version 1'));
      // And it says that nothing happened, because half an import is the
      // outcome this refusal exists to avoid.
      expect(refused.message(en), contains('Nothing was changed'));
    });

    test('an unknown optional field is tolerated, at every level', () {
      // What a newer minor version looks like from here: the same major
      // version with keys this build has never heard of.
      final document = jsonEncode(<String, Object?>{
        'format': kProfileFormat,
        'version': kProfileVersion,
        'exported_at': '2026-09-04T10:00:00Z',
        'favourites': <Object?>['example_txt2img'],
        'workflows': <String, Object?>{
          'example_txt2img': <String, Object?>{
            'defaults': <String, Object?>{'width': 512},
            'pinned': true,
          },
        },
        'setups': <Object?>[
          <String, Object?>{
            'id': 'k-9',
            'workflow': 'example_txt2img',
            'name': 'Kept',
            'values': <String, Object?>{'prompt': 'still here'},
            'colour': 'blue',
          },
        ],
      });

      final read = decodeProfile(document);

      expect(read.workflows['example_txt2img']!.values, <String, Object?>{
        'width': 512,
      });
      expect(read.setups.single.values['prompt'], 'still here');
    });

    test('a file that is not a profile is refused, whatever it is', () {
      for (final text in <String>[
        'not json at all',
        '[]',
        jsonEncode(<String, Object?>{'format': 'something.else', 'version': 1}),
        jsonEncode(<String, Object?>{'format': kProfileFormat}),
        jsonEncode(<String, Object?>{
          'format': kProfileFormat,
          'version': 'one',
        }),
      ]) {
        expect(
          () => decodeProfile(text),
          throwsA(isA<ProfileFailure>()),
          reason: text,
        );
      }
    });

    test('a hand-written value a form could not hold never reaches one', () {
      // The third of the three guards that keep a reference to an uploaded
      // file out of a form, and the only one that has an input a person can
      // type: a profile is a file, and a file can be edited.
      final document = jsonEncode(<String, Object?>{
        'format': kProfileFormat,
        'version': kProfileVersion,
        'workflows': <String, Object?>{
          'example_img2img': <String, Object?>{
            'defaults': <String, Object?>{
              'strength': 0.4,
              'source_image': <String, Object?>{'media_id': 'm-3f9c1a-1'},
            },
          },
        },
        'setups': <Object?>[
          <String, Object?>{
            'id': 'k-1',
            'workflow': 'example_img2img',
            'name': 'Handmade',
            'values': <String, Object?>{
              'prompt': 'kept',
              'source_image': <String, Object?>{'media_id': 'm-3f9c1a-2'},
            },
          },
        ],
      });

      final read = decodeProfile(document);

      expect(read.workflows['example_img2img']!.values, <String, Object?>{
        'strength': 0.4,
      });
      expect(read.setups.single.values, <String, Object?>{'prompt': 'kept'});
    });
  });

  group('where the durable override lives', () {
    test('the key is localcanvas.defaults.<workflow_id>, exactly', () async {
      final store = PreferencesWorkflowSettingsStore();

      await store.saveTranslateOverride('example_txt2img', false);

      // Verbatim. A count of keys would survive a rename of the namespace or
      // a stray field segment; this does not.
      expect(
        await preferences(),
        containsPair('localcanvas.defaults.example_txt2img', false),
      );
      expect(await store.loadTranslateOverride('example_txt2img'), isFalse);
    });

    test('switching it back on erases it rather than writing an on', () async {
      final store = PreferencesWorkflowSettingsStore();
      await store.saveTranslateOverride('example_txt2img', false);
      expect(
        (await preferences()).containsKey('localcanvas.defaults.example_txt2img'),
        isTrue,
      );

      await store.saveTranslateOverride('example_txt2img', true);

      expect(
        (await preferences()).containsKey('localcanvas.defaults.example_txt2img'),
        isFalse,
      );
      expect(await store.loadTranslateOverride('example_txt2img'), isTrue);
    });

    test('the field scan cannot see it, and the values are really there',
        () async {
      final store = PreferencesWorkflowSettingsStore();
      await store.save(
        'example_txt2img',
        <String, Object?>{'width': 512, 'height': 512},
        declaredFields: <String>{'width', 'height'},
      );
      await store.saveTranslateOverride('example_txt2img', false);

      // First: the thing whose absence is asserted below genuinely exists.
      // Without this the next expectation would pass over an empty store.
      final stored = await preferences();
      expect(stored['localcanvas.defaults.example_txt2img'], false);
      expect(stored['localcanvas.defaults.example_txt2img.width'], 512);

      final values = await store.load('example_txt2img');

      expect(values, <String, Object?>{'width': 512, 'height': 512});
      // Not under any spelling: the scan splits on the trailing dot, so the
      // override has no field id to come back as.
      expect(values.keys.where((key) => key.contains('translat')), isEmpty);
      expect(values.values.contains(false), isFalse);
    });

    test('a form never learns it as a field either', () async {
      final store = PreferencesWorkflowSettingsStore();
      await store.saveTranslateOverride('example_txt2img', false);

      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(controller, 'example_txt2img');

      expect(form.translatePrompt, isFalse);
      expect(form.keepableValues().values.contains(false), isFalse);
      expect(form.draftableValues().values.contains(false), isFalse);
      expect(form.validate().inputs.values.contains(false), isFalse);
    });

    test('the whole-device read separates the answer from the fields',
        () async {
      final store = PreferencesWorkflowSettingsStore();
      await store.save(
        'example_txt2img',
        <String, Object?>{'width': 512},
        declaredFields: <String>{'width'},
      );
      await store.saveTranslateOverride('example_txt2img', false);
      await store.saveTranslateOverride('example_video', false);

      final everything = await store.loadEverything();

      expect(everything['example_txt2img']!.values, <String, Object?>{
        'width': 512,
      });
      expect(everything['example_txt2img']!.translatePrompt, isFalse);
      // A workflow with nothing but an answer is still a workflow the profile
      // has something to say about.
      expect(everything['example_video']!.values, isEmpty);
      expect(everything['example_video']!.translatePrompt, isFalse);
    });
  });

  group('what the export must not contain', () {
    /// A session in which every one of the forbidden values genuinely exists:
    /// an endpoint is remembered, a picture is uploaded, a draft is being
    /// typed and a job has been submitted.
    ///
    /// Building it is most of this test. An absence asserted over a state
    /// where the value was never created proves nothing at all.
    Future<(WorkflowsController, WorkflowFormController)> aFullSession() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'localcanvas.endpoint': 'http://192.0.2.42:7801',
            'localcanvas.endpoint.display_name': 'Studio PC',
            'localcanvas.endpoint.last_success': '2026-09-04T09:00:00Z',
          });
      picker.answers = <MediaSelection?>[tempSelection()];
      final controller = await opened(<Map<String, Object?>>[
        img2imgDetail(),
      ], withMedia: true);
      final form = await formOf(controller, 'example_img2img');
      await form.media('source_image')!.choose();
      form
        ..setEntry('prompt', 'the words a setup keeps on purpose')
        ..setEntry('strength', '0.8')
        ..translatePrompt = false;
      await controller.saveMyDefaults();
      await controller.saveSetup(
        workflowId: 'example_img2img',
        name: 'Warm rework',
      );
      // And then the user carries on typing. This is the draft: it belongs to
      // the phone they are typing on, and it is the one piece of prose in this
      // session that must not be in the document.
      form.setEntry('prompt', 'the draft nobody exported');
      await controller.flushDrafts();
      return (controller, form);
    }

    test('no endpoint, no media, no draft and no job reach the document',
        () async {
      final (controller, form) = await aFullSession();
      final selection = uploads.uploaded.single;
      final mediaId = form.media('source_image')!.mediaId;
      final path = (selection.source as FileMediaSource).path;

      // Every value below really existed at the moment of the export. Each of
      // these four is what makes the corresponding absence mean something.
      expect(
        (await preferences())['localcanvas.endpoint'],
        'http://192.0.2.42:7801',
      );
      expect(mediaId, isNotNull);
      expect(selection.filename, 'IMG_0142.jpg');
      expect(path, isNotEmpty);
      expect(
        (await preferences())['localcanvas.draft.example_img2img.prompt'],
        'the draft nobody exported',
      );

      final text = await exported(controller);

      for (final forbidden in <String>[
        '192.0.2.42',
        '7801',
        'http://',
        'Studio PC',
        'localcanvas.endpoint',
        'last_success',
        mediaId!,
        'm-3f9c1a',
        'media_id',
        selection.filename!,
        path,
        'the draft nobody exported',
        'localcanvas.draft',
        // The app has never received one (`docs/workflow-schema.md`), so this
        // pins that nothing on this path invented one.
        'node',
        'class_type',
        'job',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
      // And it is not empty, so none of the above passed over a blank file.
      expect(text, contains('example_img2img'));
      expect(text, contains('Warm rework'));
      // The setup's own prose is there, which is what it is for — so the
      // absence of the draft above is a fact about the draft and not about
      // prose in general.
      expect(text, contains('the words a setup keeps on purpose'));
    });

    test('the current draft is absent even where the draft is the only thing '
        'that changed', () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(controller, 'example_txt2img');
      form
        ..setEntry('prompt', 'a half-finished thought')
        ..setEntry('width', '1024')
        ..translatePrompt = false;
      await controller.flushDrafts();

      // The draft is on disk — this is the state the assertion is about.
      final stored = await preferences();
      expect(stored['localcanvas.draft.example_txt2img.prompt'],
          'a half-finished thought');
      expect(stored['localcanvas.draft.example_txt2img.width'], 1024);
      expect(stored['localcanvas.draft.example_txt2img'], false);

      final text = await exported(controller);

      expect(text, isNot(contains('a half-finished thought')));
      expect(text, isNot(contains('1024')));
      // A draft-only override is a choice about the next submission and is not
      // a saved default, so it is not in the document either.
      expect(text, isNot(contains('"translation"')));
      expect(jsonDecode(text), containsPair('workflows', isEmpty));
    });

    test('neither export nor import asks the gateway anything', () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      (await formOf(controller, 'example_txt2img')).setEntry('width', '512');
      await controller.saveMyDefaults();
      final listCalls = registry.listCalls;
      final detailCalls = registry.detailCalls.length;

      await controller.exportProfile();
      transport.incoming = transport.sentText;
      await controller.importProfile();

      expect(registry.listCalls, listCalls);
      expect(registry.detailCalls.length, detailCalls);
      expect(uploads.calls, 0);
      expect(picker.calls, 0);
    });
  });

  group('a screen preference is not a setting', () {
    /// The theme choice is kept in the **real** store here, in the same
    /// preference file the profile is built by scanning.
    ///
    /// A fake would make both tests below unable to fail: the value would not
    /// be in the file the export reads from, and an absence asserted over a
    /// state where the value could never have been present is not a guard.
    /// This is the same reason the group above builds a session in which an
    /// endpoint really is remembered and a picture really was uploaded.
    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> press(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    /// The shell, with the profile actions, the Appearance block and the
    /// Language block all on screen, over the real stores.
    Future<(WorkflowsController, ThemeModeController, LocaleController)>
    shellWithAppearance(WidgetTester tester) async {
      registry = ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      );
      final workflows = WorkflowsController(
        api: registry,
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
        setups: PreferencesWorkflowSetupStore(),
        profiles: transport,
        draftDebounce: Duration.zero,
      );
      addTearDown(workflows.dispose);
      final appearance = ThemeModeController(
        store: PreferencesThemeModeStore(),
      );
      addTearDown(appearance.dispose);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);
      final language = LocaleController(store: PreferencesLocaleStore());
      addTearDown(language.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(
              connection: connection,
              workflows: workflows,
            ),
            appearance: appearance,
            language: language,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await appearance.restore();
      await language.restore();
      await tester.pumpAndSettle();
      return (workflows, appearance, language);
    }

    /// A workflow chosen, a default saved and a setup made -- so the document
    /// that goes out has something in it, and an empty one cannot pass for a
    /// clean one.
    Future<void> fillTheProfile(
      WidgetTester tester,
      WorkflowsController workflows,
    ) async {
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      workflows.form!
        ..setEntry('width', '512')
        ..setEntry('prompt', 'a quiet courtyard at dawn');
      await workflows.saveMyDefaults();
      await workflows.saveSetup(
        workflowId: 'example_txt2img',
        name: 'Warm rework',
      );
    }

    testWidgets('the theme a person chose is not in the file they hand to '
        'somebody else', (tester) async {
      tallView(tester);
      final (workflows, appearance, _) = await shellWithAppearance(tester);
      await fillTheProfile(tester, workflows);

      await press(tester, LcKeys.appearanceDark);

      // The choice genuinely existed, and genuinely sits in the preference
      // file the export is built from. Without these three lines the absence
      // below would be a fact about an empty device.
      expect(appearance.mode, ThemeMode.dark);
      expect(await PreferencesThemeModeStore().load(), ThemeMode.dark);
      expect((await preferences())['localcanvas.theme_mode'], 'dark');

      await press(tester, LcKeys.exportProfile);

      final text = transport.sentText;
      final document = jsonDecode(text) as Map<String, Object?>;
      // The document is not empty -- it carries what a profile is for.
      final defaults =
          ((document['workflows']! as Map<String, Object?>)['example_txt2img']!
                  as Map<String, Object?>)['defaults']!
              as Map<String, Object?>;
      expect(defaults['width'], 512);
      expect((document['setups']! as List<Object?>).length, 1);
      // And its shape is exactly what it was: no fifth key appeared.
      expect(document.keys.toList(), <String>[
        'format',
        'version',
        'workflows',
        'setups',
      ]);
      // Over the serialised text, because that is what leaves the phone.
      for (final forbidden in <String>[
        'theme',
        'Theme',
        'appearance',
        'Appearance',
        'brightness',
        'dark',
        'light',
        'system',
      ]) {
        expect(
          text,
          isNot(contains(forbidden)),
          reason: 'the exported document names $forbidden',
        );
      }
    });

    testWidgets('the language a person chose is not in the file they hand to '
        'somebody else', (tester) async {
      // The twin of the theme's own test above, and the same promise: a
      // preference about the phone the eyes are in front of has no business
      // in a document described to the user as their settings and setups.
      tallView(tester);
      final (workflows, _, language) = await shellWithAppearance(tester);
      await fillTheProfile(tester, workflows);

      await press(tester, LcKeys.languageOption('ru'));

      // The choice genuinely existed, and genuinely sits in the preference
      // file the export is built from. Without these three lines the absence
      // below would be a fact about an empty device.
      expect(language.choice, LocaleChoice.of(const Locale('ru')));
      expect(
        await PreferencesLocaleStore().load(),
        LocaleChoice.of(const Locale('ru')),
      );
      expect((await preferences())['localcanvas.locale'], 'ru');

      await press(tester, LcKeys.exportProfile);

      final text = transport.sentText;
      final document = jsonDecode(text) as Map<String, Object?>;
      // The document is not empty — it carries what a profile is for.
      final defaults =
          ((document['workflows']! as Map<String, Object?>)['example_txt2img']!
                  as Map<String, Object?>)['defaults']!
              as Map<String, Object?>;
      expect(defaults['width'], 512);
      expect((document['setups']! as List<Object?>).length, 1);
      // And its shape is exactly what it was: no fifth key appeared.
      expect(document.keys.toList(), <String>[
        'format',
        'version',
        'workflows',
        'setups',
      ]);
      // Over the serialised text, because that is what leaves the phone.
      for (final forbidden in <String>[
        'locale',
        'Locale',
        'language',
        'Language',
        '"ru"',
        '"en"',
      ]) {
        expect(
          text,
          isNot(contains(forbidden)),
          reason: 'the exported document names $forbidden',
        );
      }
    });

    testWidgets('a profile that arrives from another phone does not change '
        'the language', (tester) async {
      tallView(tester);
      final (_, _, language) = await shellWithAppearance(tester);
      await press(tester, LcKeys.languageOption('ru'));
      expect(language.choice, LocaleChoice.of(const Locale('ru')));

      // A document from a phone that was, for all this one knows, in English.
      // There is nowhere in the format to say so, which is the point.
      transport.incoming = encodeProfile(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_txt2img': ProfileEntry(
              values: <String, Object?>{'width': 1024},
            ),
          },
          setups: <WorkflowSetup>[],
        ),
      );

      await press(tester, LcKeys.importProfile);

      expect(language.choice, LocaleChoice.of(const Locale('ru')));
      // On the device as well as in the controller: an import that had reached
      // the preference file would cost the choice its next launch rather than
      // this one, and nothing on screen would say so.
      expect(
        await PreferencesLocaleStore().load(),
        LocaleChoice.of(const Locale('ru')),
      );
    });

    testWidgets('a profile that arrives from another phone does not repaint '
        'this one', (tester) async {
      tallView(tester);
      final (_, appearance, _) = await shellWithAppearance(tester);
      await press(tester, LcKeys.appearanceDark);
      expect(appearance.mode, ThemeMode.dark);

      // A document from a phone that was, for all this one knows, in light
      // mode. There is nowhere in the format to say so, which is the point.
      transport.incoming = encodeProfile(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_txt2img': ProfileEntry(
              values: <String, Object?>{'width': 1024},
            ),
          },
          setups: <WorkflowSetup>[
            WorkflowSetup(
              id: 'from-elsewhere',
              workflowId: 'example_txt2img',
              name: 'Someone else',
            ),
          ],
        ),
      );

      await press(tester, LcKeys.importProfile);

      // The import really happened -- otherwise "the theme did not change"
      // would be a fact about a button that did nothing.
      expect(
        find.textContaining('Imported settings for 1 workflow and 1 setup.'),
        findsOneWidget,
      );
      expect(
        (await preferences())['localcanvas.defaults.example_txt2img.width'],
        1024,
      );
      // And the phone is still the colour its owner chose.
      expect(appearance.mode, ThemeMode.dark);
      expect((await preferences())['localcanvas.theme_mode'], 'dark');
    });
  });

  group('merge is the only way in', () {
    test('a local setup and a local default the profile never mentions both '
        'survive', () async {
      // What this device has: a default and a setup for a workflow the
      // document below says nothing about.
      final settings = PreferencesWorkflowSettingsStore();
      final setups = PreferencesWorkflowSetupStore();
      await settings.save(
        'example_video',
        <String, Object?>{'frames': 48},
        declaredFields: <String>{'frames'},
      );
      await settings.saveTranslateOverride('example_video', false);
      final mine = await setups.create(
        workflowId: 'example_video',
        name: 'My own',
        values: <String, Object?>{'prompt': 'mine'},
      );
      // And, for the same workflow the document does mention, one field it
      // says nothing about.
      await settings.save(
        'example_txt2img',
        <String, Object?>{'height': 704},
        declaredFields: <String>{'height'},
      );

      await exchange().merge(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_txt2img': ProfileEntry(
              values: <String, Object?>{'width': 512},
            ),
          },
          setups: <WorkflowSetup>[
            WorkflowSetup(
              id: 'from-elsewhere',
              workflowId: 'example_txt2img',
              name: 'Theirs',
            ),
          ],
        ),
      );

      expect(await settings.load('example_video'), <String, Object?>{
        'frames': 48,
      });
      expect(await settings.loadTranslateOverride('example_video'), isFalse);
      expect(await setups.load('example_video'), <WorkflowSetup>[mine]);
      // The mentioned workflow gained a field and lost nothing.
      expect(await settings.load('example_txt2img'), <String, Object?>{
        'height': 704,
        'width': 512,
      });
    });

    test('a workflow the phone does not have is kept dormant, then wakes up',
        () async {
      await exchange().merge(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_video': ProfileEntry(
              values: <String, Object?>{'frames': 48},
              translatePrompt: false,
            ),
          },
          setups: <WorkflowSetup>[
            WorkflowSetup(
              id: 'dormant-1',
              workflowId: 'example_video',
              name: 'From the other phone',
              values: <String, Object?>{'prompt': 'waiting'},
            ),
          ],
        ),
      );

      // A registry that does not publish it. Nothing is deleted, nothing is
      // reported, and the document simply lies where it was written.
      final without = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      await without.select('example_txt2img');
      expect(
        (await preferences())['localcanvas.defaults.example_video.frames'],
        48,
      );

      // The workflow appears. Now it is an ordinary saved default.
      final with_ = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        videoDetail(),
      ]);
      final form = await formOf(with_, 'example_video');

      expect(form.text('frames'), '48');
      expect(form.translatePrompt, isFalse);
      expect(with_.setupsFor('example_video').single.name,
          'From the other phone');
    });

    test('importing the same profile twice leaves one setup, not two',
        () async {
      const profile = WorkflowProfile(
        setups: <WorkflowSetup>[
          WorkflowSetup(
            id: 'stable-id',
            workflowId: 'example_txt2img',
            name: 'Once',
            values: <String, Object?>{'prompt': 'once'},
          ),
        ],
      );

      await exchange().merge(profile);
      await exchange().merge(profile);

      final setups = await PreferencesWorkflowSetupStore().load(
        'example_txt2img',
      );
      // Counted around the merge, from the store, and never from the merge's
      // own report.
      expect(setups.length, 1);
      expect(setups.single.id, 'stable-id');
    });

    test('an imported setup cannot hold what a locally made one could not',
        () async {
      // `adopt` is a second way into the setup store, so it needs its own
      // proof: the filter that keeps a reference to an uploaded file out of a
      // document is on this path too, and not only on `create`.
      final setups = PreferencesWorkflowSetupStore();

      await setups.adopt(
        const WorkflowSetup(
          id: 'adopted-1',
          workflowId: 'example_img2img',
          name: 'Handmade',
          values: <String, Object?>{
            'prompt': 'kept',
            'source_image': <String, Object?>{'media_id': 'm-3f9c1a-1'},
          },
        ),
      );

      final written =
          (await preferences())['localcanvas.setup.adopted-1']! as String;
      expect(written, contains('kept'));
      expect(written, isNot(contains('media_id')));
      expect(written, isNot(contains('m-3f9c1a')));
      expect((await setups.load('example_img2img')).single.values,
          <String, Object?>{'prompt': 'kept'});
    });

    test('an id a namespace could not hold is refused, not written', () async {
      final report = await exchange().merge(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'not.a.workflow.id': ProfileEntry(
              values: <String, Object?>{'width': 512},
            ),
          },
          setups: <WorkflowSetup>[
            WorkflowSetup(
              id: 'has.a.dot',
              workflowId: 'example_txt2img',
              name: 'Nope',
            ),
          ],
        ),
      );

      expect(report.workflows, 0);
      expect(report.setups, 0);
      expect(
        (await preferences()).keys.where((k) => k.contains('not.a.workflow')),
        isEmpty,
      );
      expect(await PreferencesWorkflowSetupStore().load('example_txt2img'),
          isEmpty);
    });

    test('a profile the user chose not to pick changes nothing and says '
        'nothing', () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      transport.incoming = null;

      expect(await controller.importProfile(), isNull);

      expect(transport.receives, 1);
      expect(await preferences(), isEmpty);
    });
  });

  group('the layering, from one phone to another', () {
    test('a durable override is exported and restored; a draft one is not',
        () async {
      final first = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        videoDetail(),
      ]);
      // Saved for one workflow.
      (await formOf(first, 'example_txt2img')).translatePrompt = false;
      await first.saveMyDefaults();
      // Only ever in the form for the other one, which is a draft override.
      (await formOf(first, 'example_video')).translatePrompt = false;
      await first.flushDrafts();

      final text = await exported(first);
      final workflows =
          (jsonDecode(text) as Map<String, Object?>)['workflows']!
              as Map<String, Object?>;

      expect(
        (workflows['example_txt2img']! as Map<String, Object?>)['translation'],
        'off',
      );
      expect(workflows.containsKey('example_video'), isFalse);
      // And the draft override really was there to be exported, so the
      // absence above is about the export and not about the state.
      expect((await preferences())['localcanvas.draft.example_video'], false);

      // The other phone.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      transport.incoming = text;
      final second = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        videoDetail(),
      ]);
      final report = await second.importProfile();

      expect(report!.workflows, 1);
      final restored = await formOf(second, 'example_txt2img');
      expect(restored.translatePrompt, isFalse);
      expect((await formOf(second, 'example_video')).translatePrompt, isTrue);
    });

    test('a draft override supersedes My defaults without changing them',
        () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(controller, 'example_txt2img');
      // Saved: translation on, which is the absence of an override.
      await controller.saveMyDefaults();
      expect(await PreferencesWorkflowSettingsStore()
          .loadTranslateOverride('example_txt2img'), isTrue);

      // The session says otherwise, for this generation.
      form.translatePrompt = false;
      await controller.flushDrafts();

      expect(form.translatePrompt, isFalse);
      // Read from the store afterwards: the saved default is untouched.
      expect(await PreferencesWorkflowSettingsStore()
          .loadTranslateOverride('example_txt2img'), isTrue);
      expect(form.durableTranslatePrompt, isTrue);
      // And it is the draft that holds it.
      expect((await preferences())['localcanvas.draft.example_txt2img'], false);
    });

    test('a draft that says nothing leaves the durable answer standing',
        () async {
      // The trap this ordering avoids: a draft carries a refusal and never a
      // permission, so laying one over My defaults must not switch the stage
      // back on for a workflow the user switched it off for.
      //
      // The state is written through the two real stores, because that is
      // exactly what is on the device: a saved refusal, and a draft that says
      // nothing about translation at all.
      await PreferencesWorkflowSettingsStore()
          .saveTranslateOverride('example_txt2img', false);
      await PreferencesWorkflowDraftStore().save(
        'example_txt2img',
        const WorkflowDraft(values: <String, Object?>{'prompt': 'still typing'}),
        draftableFields: <String>{'prompt'},
      );
      final stored = await preferences();
      expect(stored['localcanvas.draft.example_txt2img.prompt'], 'still typing');
      expect(stored.containsKey('localcanvas.draft.example_txt2img'), isFalse);
      expect(stored['localcanvas.defaults.example_txt2img'], false);

      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final reopened = await formOf(next, 'example_txt2img');

      expect(reopened.text('prompt'), 'still typing');
      expect(reopened.translatePrompt, isFalse);
    });

    test('closing and reopening a workflow preserves the durable override',
        () async {
      final first = await opened(<Map<String, Object?>>[
        txt2imgDetail(),
        videoDetail(),
      ]);
      (await formOf(first, 'example_txt2img')).translatePrompt = false;
      await first.saveMyDefaults();

      // Away to another workflow and back, inside one session.
      await first.select('example_video');
      expect(first.form!.translatePrompt, isTrue);
      await first.select('example_txt2img');
      expect(first.form!.translatePrompt, isFalse);

      // And across a restart of the app.
      final next = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      expect((await formOf(next, 'example_txt2img')).translatePrompt, isFalse);
    });

    test('an import does not rewrite the form under the user, but does offer '
        'the way to it', () async {
      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final form = await formOf(controller, 'example_txt2img');
      form.setEntry('width', '640');
      expect(form.hasMyDefaults, isFalse);

      transport.incoming = encodeProfile(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_txt2img': ProfileEntry(
              values: <String, Object?>{'width': 512},
              translatePrompt: false,
            ),
          },
          setups: <WorkflowSetup>[
            WorkflowSetup(
              id: 'imported-1',
              workflowId: 'example_txt2img',
              name: 'From elsewhere',
            ),
          ],
        ),
      );
      await controller.importProfile();

      // What the user was looking at is still what they were looking at.
      expect(form.text('width'), '640');
      expect(form.translatePrompt, isTrue);
      // And now there is somewhere to go back to, and something to see.
      expect(form.hasMyDefaults, isTrue);
      expect(controller.setupsFor('example_txt2img').single.name,
          'From elsewhere');

      form.resetSettingsToMyDefaults();

      expect(form.text('width'), '512');
      expect(form.translatePrompt, isFalse);
    });
  });

  group('what the two resets do, on screen', () {
    /// A shell with the real stores, a PC that really translates, and one
    /// workflow.
    Future<Widget> shell({bool keepsProfile = false}) async {
      registry = ScriptedWorkflowsApi(
        summaries: WorkflowSummary.listFromJson(
          registryOf(<Map<String, Object?>>[txt2imgDetail()]),
        ),
        details: <String, WorkflowDetail>{
          'example_txt2img': WorkflowDetail.tryFromJson(txt2imgDetail())!,
        },
      );
      final workflows = WorkflowsController(
        api: registry,
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
        setups: PreferencesWorkflowSetupStore(),
        profiles: keepsProfile ? transport : null,
        // The real store, with the wait taken out: a `pumpAndSettle` then runs
        // the autosave instead of leaving its timer behind, and what is
        // written is written by the same code the app runs.
        draftDebounce: Duration.zero,
      );
      addTearDown(workflows.dispose);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(
            e,
            testIdentity(
              capabilities: GatewayCapabilities.fromJson(<String, Object?>{
                'translation': <String, Object?>{
                  'enabled': true,
                  'installed': true,
                  'pairs': <Object?>[
                    <String, Object?>{'source': 'ru', 'target': 'en'},
                  ],
                },
              }),
            ),
          ),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);
      return MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
        theme: lcDarkTheme(),
        home: ConnectedShell(
          session: testSession(connection: connection, workflows: workflows),
        ),
      );
    }

    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> choose(WidgetTester tester) async {
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
    }

    Future<void> press(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    bool switchIsOn(WidgetTester tester) => tester
        .widget<Switch>(find.byKey(LcKeys.translationOverride('prompt')))
        .value;

    String noticeText(WidgetTester tester) => tester
        .widget<Text>(find.byKey(LcKeys.translationNotice('prompt')))
        .data!;

    testWidgets('a reset to the workflow puts the policy back, and the screen '
        'says which policy is in force', (tester) async {
      await PreferencesWorkflowSettingsStore()
          .saveTranslateOverride('example_txt2img', false);
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);

      // What the saved default looks like on screen.
      expect(switchIsOn(tester), isFalse);
      expect(noticeText(tester),
          'This prompt is sent as typed, without translation.');

      await press(tester, LcKeys.resetToWorkflowDefaults);

      // The workflow's own policy is in force, and the screen shows it — not
      // a stale sentence, and not a switch that disagrees with the submission.
      expect(switchIsOn(tester), isTrue);
      expect(noticeText(tester),
          'A prompt in RU is translated to EN before generating.');
      // Nothing was erased: the way back is still on screen, exactly as it is
      // for every other saved default.
      expect(find.byKey(LcKeys.resetToMyDefaults), findsOneWidget);
      expect(
        (await preferences())['localcanvas.defaults.example_txt2img'],
        false,
      );

      await press(tester, LcKeys.resetToMyDefaults);

      expect(switchIsOn(tester), isFalse);
      expect(noticeText(tester),
          'This prompt is sent as typed, without translation.');
    });

    testWidgets('saving the settings saves the answer beside them',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell());
      await tester.pumpAndSettle();
      await choose(tester);

      await press(tester, LcKeys.translationOverride('prompt'));
      expect(switchIsOn(tester), isFalse);
      await press(tester, LcKeys.saveMyDefaults);

      expect(
        (await preferences())['localcanvas.defaults.example_txt2img'],
        false,
      );
      // And the way back appears, because there is now something saved.
      expect(find.byKey(LcKeys.resetToMyDefaults), findsOneWidget);
    });

    testWidgets('a refused profile is said out loud, with both versions',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell(keepsProfile: true));
      await tester.pumpAndSettle();
      transport.incoming = jsonEncode(<String, Object?>{
        'format': kProfileFormat,
        'version': kProfileVersion + 1,
      });

      await press(tester, LcKeys.importProfile);

      expect(find.byKey(LcKeys.profileProblem), findsOneWidget);
      expect(find.textContaining('version 2'), findsOneWidget);
      await tester.tap(find.byKey(LcKeys.profileProblemDismiss));
      await tester.pumpAndSettle();
      expect(find.byKey(LcKeys.profileProblem), findsNothing);
    });

    testWidgets('an import says what arrived and that nothing was removed',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell(keepsProfile: true));
      await tester.pumpAndSettle();
      transport.incoming = encodeProfile(
        const WorkflowProfile(
          workflows: <String, ProfileEntry>{
            'example_txt2img': ProfileEntry(
              values: <String, Object?>{'width': 512},
            ),
          },
          setups: <WorkflowSetup>[
            WorkflowSetup(
              id: 'a',
              workflowId: 'example_txt2img',
              name: 'One',
            ),
          ],
        ),
      );

      await press(tester, LcKeys.importProfile);

      expect(
        find.textContaining('Imported settings for 1 workflow and 1 setup.'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing of yours was removed'), findsOneWidget);
    });

    testWidgets('exporting hands the document over and says nothing',
        (tester) async {
      tallView(tester);
      await tester.pumpWidget(await shell(keepsProfile: true));
      await tester.pumpAndSettle();

      await press(tester, LcKeys.exportProfile);

      expect(transport.sent.single.filename, 'localcanvas-profile.json');
      expect(transport.sentText, contains('"format": "localcanvas.profile"'));
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('a build with no profile actions', () {
    testWidgets('renders exactly as it did before this feature existed',
        (tester) async {
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final details = <Map<String, Object?>>[txt2imgDetail()];
      final controller = WorkflowsController(
        api: ScriptedWorkflowsApi(
          summaries: WorkflowSummary.listFromJson(registryOf(details)),
          details: <String, WorkflowDetail>{
            'example_txt2img': WorkflowDetail.tryFromJson(details.single)!,
          },
        ),
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
        setups: PreferencesWorkflowSetupStore(),
      );
      addTearDown(controller.dispose);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);

      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard('example_txt2img')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.serverDetailsToggle));
      await tester.pumpAndSettle();

      // Against the photograph taken of the pre-change tree, not against this
      // change's own output (`support/shell_before_profile.dart`).
      expect(shellFingerprint(tester), kShellBeforeProfile);
      expect(controller.canExchangeProfile, isFalse);
      expect(find.byKey(LcKeys.profileBar), findsNothing);
    });

    testWidgets('and the same build with a transport does draw the profile',
        (tester) async {
      // Otherwise the pin above could pass on a build where the feature was
      // never wired at all.
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final controller = await opened(<Map<String, Object?>>[txt2imgDetail()]);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(endpoint);

      await tester.pumpWidget(
        MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(
            session: testSession(connection: connection, workflows: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.canExchangeProfile, isTrue);
      expect(find.byKey(LcKeys.profileBar), findsOneWidget);
      expect(find.byKey(LcKeys.exportProfile), findsOneWidget);
      expect(find.byKey(LcKeys.importProfile), findsOneWidget);
    });
  });

  group('the code this card wrote names no field and reads no graph', () {
    /// The names a curator gives their own fields. None of them may appear as
    /// a literal in the code that builds or reads a profile: what is carried
    /// is decided by what the stores hold, never by what a field is called.
    ///
    /// The scan below covers every file this card touched, not only the five
    /// it created. A guard that sees half of a change is how a regression gets
    /// in through the other half — and the half most likely to grow a field
    /// name later is the one that was already there.
    const List<String> vocabulary = <String>[
      'seed',
      'steps',
      'cfg',
      'cfg_scale',
      'guidance',
      'denoise',
      'sampler',
      'sampler_name',
      'scheduler',
      'width',
      'height',
      'strength',
      'batch_size',
      'frames',
      'fps',
      'checkpoint',
      'lora',
      'clip_skip',
    ];

    List<String> literalsIn(String source) => <String>[
      for (final match in RegExp(
        "'([^'\\\\\n]*)'",
      ).allMatches(withoutComments(source)))
        match.group(1)!,
    ];

    List<String> namesIn(String source) => <String>[
      for (final literal in literalsIn(source))
        if (vocabulary.contains(literal.toLowerCase())) literal,
    ];

    // `graphReadsIn` is the one scan, in `support/graph_vocabulary.dart`
    // (T-0264).

    test('the two checks below catch what they are looking for', () {
      // Proved against a deliberately offending source first: otherwise the
      // assertions on the real files could pass because the detectors never
      // fire at all.
      const offending = '''
const _carry = <String>{'steps', 'guidance', 'sampler'};
String keyFor(Map<String, Object?> field) =>
    'localcanvas.profile.\${field['node_id']}';
''';
      expect(namesIn(offending), <String>['steps', 'guidance', 'sampler']);
      expect(graphReadsIn(offending), <String>['node']);

      // A comment is not code, and the document's own names are not a
      // curator's.
      expect(namesIn("// a curator writes 'steps' and 'guidance'"), isEmpty);
      expect(graphReadsIn('/// never a node id'), isEmpty);
      expect(namesIn("const _defaultsKey = 'defaults';"), isEmpty);
      expect(graphReadsIn("const _formatKey = 'format';"), isEmpty);
    });

    test('the graph scan frees only what it names, and refuses every read '
        'shape', () {
      // The shared self-test: the four framework names and the tails of longer
      // words pass, and every read shape is refused by the word it reads.
      expectGraphScanHoldsItsShapes(graphReadsIn);
    });

    // The scan exists once (T-0264). This test finds a second copy BY NAME: a
    // definition of `graphReadsIn` anywhere under test/ but the helper, a
    // guarded file without the import, or one that no longer runs the shared
    // self-test.
    //
    // A stated limit, accepted in review: a second implementation kept under
    // ANOTHER name, which a file's guard then calls instead of the shared
    // scan, is not detected. Nothing here proves which function a guard
    // calls, so that is deliberate evasion rather than a copy kept by
    // accident, and reading every file for "some function that scans" is not
    // a check this test can make honestly.
    test('the graph scan exists once, and every file guarded by it imports '
        'it', () {
      // A definition of the scan, as opposed to a call of it: its parameter
      // list is followed by a body, or the name is assigned a function.
      final definition = RegExp(
        r'\bgraphReadsIn\s*(?:\([^)]*\)\s*(?:=>|\{)|=[^=])',
      );
      // Proved on sources first, so a clean answer below is not a detector
      // that never fires. The name is split so this file does not define it.
      const name = 'graph' 'ReadsIn';
      for (final defined in <String>[
        'List<String> $name(String source) => <String>[',
        'List<String> $name(String source) {',
        'final $name = (String source) => <String>[];',
      ]) {
        expect(definition.hasMatch(defined), isTrue, reason: defined);
      }
      for (final called in <String>[
        'expect($name(offending), <String>[\'node\']);',
        'expectGraphScanHoldsItsShapes($name);',
        'expect($name(source), isEmpty, reason: path);',
      ]) {
        expect(definition.hasMatch(called), isFalse, reason: called);
      }

      const home = 'test/support/graph_vocabulary.dart';
      final defining = <String>[
        for (final file in Directory('test').listSync(recursive: true))
          if (file is File &&
              file.path.endsWith('.dart') &&
              definition.hasMatch(file.readAsStringSync()))
            file.path.replaceAll('\\', '/'),
      ];
      expect(defining, <String>[home]);

      for (final path in <String>[
        'test/portable_profile_test.dart',
        'test/workflow_draft_store_test.dart',
        'test/workflow_settings_store_test.dart',
        'test/workflow_setup_store_test.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains("import 'support/graph_vocabulary.dart';"),
          reason: path,
        );
        // And the file runs the shared self-test against the scan it uses.
        expect(
          source,
          contains('expectGraphScanHoldsItsShapes(graphReadsIn);'),
          reason: path,
        );
      }
    });

    /// Every file this card wrote or added to, and one thing each of them has
    /// to contain.
    ///
    /// The anchor is not decoration: without it a path that stopped resolving
    /// to the code it names — a file renamed, a method moved elsewhere — would
    /// leave a scan that passes over the wrong text and says nothing.
    const Map<String, String> guarded = <String, String>{
      // Written by this card.
      'lib/workflows/workflow_profile.dart': 'String encodeProfile(',
      'lib/workflows/profile_exchange.dart': 'class ProfileExchange',
      'lib/workflows/profile_transport.dart':
          'abstract interface class ProfileTransport',
      'lib/workflows/platform_profile_transport.dart':
          'class PlatformProfileTransport',
      'lib/ui/shell/profile_bar.dart': 'class ProfileBar',
      // Added to by this card, and just as able to grow a field name.
      'lib/workflows/workflow_settings_store.dart': 'Future<bool> mergeInto(',
      'lib/workflows/workflow_setup_store.dart': 'Future<bool> adopt(',
      'lib/workflows/workflow_form.dart': 'void adoptTranslateDefault(',
      'lib/workflows/workflows_controller.dart':
          'Future<ProfileImportReport?> importProfile(',
      'lib/ui/shell/connected_shell.dart': 'Future<void> _importProfile(',
    };

    test('every file this card touched is clean, and is really the file', () {
      for (final entry in guarded.entries) {
        final path = entry.key;
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason: '$path — cwd is ${Directory.current.path}',
        );
        final source = file.readAsStringSync();
        // The file is the one this entry is about, so neither assertion below
        // is a scan of something that is not the code under guard.
        expect(source, contains(entry.value), reason: path);
        expect(namesIn(source), isEmpty, reason: path);
        expect(graphReadsIn(source), isEmpty, reason: path);
      }
    });
  });
}
