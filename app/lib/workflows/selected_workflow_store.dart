/// Which workflow this device had open, so a relaunch comes back to it.
///
/// **Device-local, on purpose.** Not in the portable profile, for the reason
/// `theme/theme_mode_store.dart` gives about the brightness and
/// `theme/pane_split_store.dart` about the divider: that document is described
/// to the user as their saved settings and setups, and "which workflow I had
/// open on this phone" is neither. So it lives in its own preference key here,
/// outside the `localcanvas.defaults.` and `localcanvas.setup.` namespaces the
/// profile is built by scanning, and `workflow_profile.dart` never learns that
/// it exists.
///
/// **It is scoped to the server, and that is the whole reason this file holds
/// two values rather than one.** `connection/endpoint_store.dart` remembers one
/// server. Pair the app with a different gateway and a workflow id from the
/// first may not exist there — or, worse, may exist and mean something else,
/// because a curator names their own workflows (`docs/workflow-schema.md`) and
/// nothing makes `upscale` on one machine the same graph as `upscale` on
/// another. So what is written down is the pair *(server, workflow)*, and
/// [SelectedWorkflowStore.load] answers `null` for any server but the one the
/// selection was made against. Opening somebody else's workflow because its id
/// collided is the failure this scoping exists to make impossible.
///
/// **One slot, one write.** The pair goes into a single key as one JSON object,
/// the way `workflow_setup_store.dart` writes a setup, rather than into a key
/// each. Two keys can be torn apart by a process that dies between them, and
/// the wreckage is exactly the defect above: one server's address sitting
/// beside another server's workflow id, which reads back as a valid memory and
/// is a lie. One value cannot be half-written.
///
/// **Nothing said is not an error.** [SelectedWorkflowStore.load] answers
/// `null` for a device nobody has told anything, for a file holding something
/// this build cannot read, and for a memory belonging to another server. All
/// three are the launch every build before this one had: the registry appears
/// and the user chooses. None of them is worth a sentence on screen.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../connection/endpoint.dart';

abstract class SelectedWorkflowStore {
  /// The workflow this device last had open against [endpoint].
  ///
  /// `null` when nothing is remembered, when what is remembered cannot be
  /// read, or when it was remembered against a different server — which the
  /// caller cannot tell apart and does not need to, because all three mean
  /// "choose nothing".
  Future<String?> load(Endpoint endpoint);

  /// Remembers [workflowId] as what is open against [endpoint], replacing
  /// whatever was there. Not a history: one slot, overwritten.
  Future<void> remember(Endpoint endpoint, String workflowId);

  /// Forgets it — nothing is open now.
  Future<void> forget();
}

/// The on-device implementation.
class PreferencesSelectedWorkflowStore implements SelectedWorkflowStore {
  PreferencesSelectedWorkflowStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  /// Namespaced the way the remembered endpoint and the remembered brightness
  /// are, and outside `localcanvas.defaults.` and `localcanvas.setup.` — the
  /// two prefixes the portable profile is built by scanning, which this must
  /// therefore never be inside.
  static const String key = 'localcanvas.selected_workflow';

  /// The two names inside the one stored object.
  static const String _endpointField = 'endpoint';
  static const String _workflowField = 'workflow';

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> load(Endpoint endpoint) async {
    final String? stored;
    try {
      stored = await _prefs.getString(key);
    } on Object {
      // A value of the wrong type — a hand-edited file, or a key a future
      // build used for something else. Nothing said.
      return null;
    }
    if (stored == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final storedEndpoint = decoded[_endpointField];
    final workflowId = decoded[_workflowField];
    if (storedEndpoint is! String || workflowId is! String) return null;
    if (workflowId.isEmpty) return null;
    // Compared as endpoints rather than as text, so the same server reached
    // through the same address is the same server however it was typed — that
    // normalisation is `Endpoint`'s job and is not restated here.
    final parsed = Endpoint.tryParse(storedEndpoint);
    if (parsed == null || parsed != endpoint) return null;
    return workflowId;
  }

  @override
  Future<void> remember(Endpoint endpoint, String workflowId) =>
      _prefs.setString(
        key,
        jsonEncode(<String, Object?>{
          _endpointField: endpoint.canonical,
          _workflowField: workflowId,
        }),
      );

  @override
  Future<void> forget() => _prefs.remove(key);
}
