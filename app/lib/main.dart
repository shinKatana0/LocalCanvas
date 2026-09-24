/// LocalCanvas — a local-first Android frontend for your own workflows.
///
/// Composition happens here and only here: the real HTTP client, the real
/// preference store, the real platform discovery, the real socket and the real
/// gallery are assembled once and handed to the session. Everything below this
/// file takes its collaborators as arguments, which is why the tests can run
/// the whole app against a local fake server and never touch a network.
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'connection/connection_controller.dart';
import 'connection/discovery.dart';
import 'connection/endpoint_store.dart';
import 'connection/gateway_client.dart';
import 'connection/nsd_discovery.dart';
import 'connection/reconnect_attempts_store.dart';
import 'generation/generation_controller.dart';
import 'generation/job_events.dart';
import 'generation/jobs_api.dart';
import 'generation/platform_clip_inspector.dart';
import 'generation/platform_clip_playback.dart';
import 'generation/platform_result_export.dart';
import 'generation/session_controller.dart';
import 'l10n/locale_controller.dart';
import 'l10n/locale_store.dart';
import 'media/gallery_picker.dart';
import 'media/media_api.dart';
import 'theme/pane_split_store.dart';
import 'theme/theme_mode_controller.dart';
import 'theme/theme_mode_store.dart';
import 'workflows/platform_profile_transport.dart';
import 'workflows/selected_workflow_store.dart';
import 'workflows/workflow_api.dart';
import 'workflows/workflow_draft_store.dart';
import 'workflows/workflow_settings_store.dart';
import 'workflows/workflow_setup_store.dart';
import 'workflows/workflows_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The one language controller, made here so that the three API clients and
  // the interface all read the same answer. Its `systemLocales` is filled in
  // by `app.dart`, which is where the binding's own view of the phone is.
  final language = LocaleController(store: PreferencesLocaleStore());
  runApp(
    LocalCanvasApp(
      appearance: ThemeModeController(store: PreferencesThemeModeStore()),
      language: language,
      split: PreferencesPaneSplitStore(),
      session: SessionController(
        connection: ConnectionController(
          client: GatewayClient(language: () => language.languageTag),
          store: PreferencesEndpointStore(),
          discovery: DiscoveryController(backend: const NsdDiscoveryBackend()),
        ),
        workflows: WorkflowsController(
          api: HttpWorkflowsApi(language: () => language.languageTag),
          mediaPicker: GalleryMediaPicker(),
          mediaApi: HttpMediaApi(language: () => language.languageTag),
          clipInspector: const PlatformClipInspector(),
          settings: PreferencesWorkflowSettingsStore(),
          drafts: PreferencesWorkflowDraftStore(),
          setups: PreferencesWorkflowSetupStore(),
          selection: PreferencesSelectedWorkflowStore(),
          profiles: const PlatformProfileTransport(),
        ),
        generation: GenerationController(
          api: HttpJobsApi(language: () => language.languageTag),
          // An optimization the app can do without: with this removed the
          // whole lifecycle still runs off `GET /api/v1/jobs/{job_id}`.
          events: const WebSocketJobEvents(),
          exporter: const PlatformResultExporter(),
          clipPlayback: const PlatformClipPlayback(),
        ),
        attemptsStore: PreferencesReconnectAttemptsStore(),
      ),
    ),
  );
}
