/// My defaults: the safe tuning a user asked this device to remember, per
/// workflow.
///
/// The policy, because a store is only as good as the rule about what may go
/// into it:
///
/// * **Only a safe scalar is ever written** — a number, a switch, a choice.
///   Which fields those are is decided from the field's declared **type**, and
///   from nothing else. There is no list of field ids anywhere in this file
///   and there must never be one: a curator names their own fields, and a
///   store that recognised `steps` by its name would quietly keep nothing at
///   all for the next user, whose field is called something else.
/// * **No prompt and no media reference is ever written.** `string` and
///   `multiline` are prose; `image` and `video` are a reference to a file on
///   one server, and a reference kept past its upload is a broken promise.
///   [isSafeToKeep] is the whole of that rule, and the one call site that
///   writes obeys it — this file, like `endpoint_store.dart`, stores what it
///   is given.
/// * **The key is the workflow's id and the field's own logical id.** Never a
///   node id: the app has never seen one (`docs/workflow-schema.md` — the
///   registry view carries no graph), and re-numbering a graph must not lose
///   what the user tuned. Never a position in the form either, because a
///   curator may reorder the fields.
/// * **One thing beside the fields, and it is not one.** Whether this
///   workflow's submissions may be translated is the user's durable answer to
///   a question about the *stage*, not a value in the form (`docs/api.md`:
///   remembering the choice is the client's job). It travels beside the
///   values rather than inside them, exactly as it already does in the draft,
///   so a workflow that happened to declare a field of that name could not
///   collide with it — and [isSafeToKeep] is untouched by it, because it is
///   field-type driven by design and an override is not a field.
///
/// Keys are namespaced under `localcanvas.defaults.` the way the remembered
/// endpoint is namespaced under `localcanvas.endpoint`. A workflow id carries
/// no dot (`docs/workflow-schema.md`: `[a-z0-9_-]`), so the segment after that
/// prefix is the whole workflow id and everything after the next dot is the
/// field's own id — two workflows cannot collide on one key. The durable
/// translation answer is kept at `localcanvas.defaults.<workflow_id>`
/// **exactly**, with no dot after it, which is the shape the draft store
/// already uses for the same answer: no field key can equal it, because every
/// field key has a dot and a non-empty id after the workflow, so the scan that
/// reads the fields cannot see it.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workflow_models.dart';

/// Whether a field's value may be kept as one of My defaults.
///
/// Type-driven, and deliberately exhaustive: a field type added to the schema
/// later fails to compile here rather than defaulting into the store.
bool isSafeToKeep(WorkflowField field) => switch (field.type) {
  // Tuning: a number, a switch, a choice. This is the whole of what is kept.
  FieldType.integer ||
  FieldType.float ||
  FieldType.boolean ||
  FieldType.select => true,
  // Prose. What the user writes belongs to the moment they wrote it.
  FieldType.string || FieldType.multiline => false,
  // A reference to an uploaded file, which outlives neither the server nor
  // the picture's permission on the device.
  FieldType.image || FieldType.video => false,
  // Something this build cannot even show. It has no value to keep.
  FieldType.unsupported => false,
};

/// One workflow's saved defaults: the values, and the durable answer that
/// travels beside them.
///
/// The pair the profile carries and the pair a workflow is opened with. It is
/// deliberately not a map with one extra key in it: a curator names their own
/// fields, and a key reserved inside the values would be a field id this app
/// had claimed for itself.
@immutable
class WorkflowDefaults {
  const WorkflowDefaults({
    this.values = const <String, Object?>{},
    this.translatePrompt = true,
  });

  /// What was saved, by logical field id.
  final Map<String, Object?> values;

  /// Whether this workflow's submissions may be translated.
  ///
  /// `true` is the **absence** of an override rather than a claim that
  /// anything will be translated — the same representation the draft uses, so
  /// the two stores cannot drift into disagreeing about what "nothing was
  /// said" looks like (`workflow_draft_store.dart`). Only `false` is ever
  /// written down.
  final bool translatePrompt;

  /// Nothing was saved and nothing was said.
  bool get isEmpty => values.isEmpty && translatePrompt;

  @override
  bool operator ==(Object other) =>
      other is WorkflowDefaults &&
      other.translatePrompt == translatePrompt &&
      mapEquals(other.values, values);

  @override
  int get hashCode => Object.hash(
    translatePrompt,
    Object.hashAllUnordered(<Object?>[
      for (final entry in values.entries) Object.hash(entry.key, entry.value),
    ]),
  );

  @override
  String toString() =>
      'WorkflowDefaults($values, translatePrompt: $translatePrompt)';
}

/// The seam. One workflow's saved defaults, read and written by logical field
/// id.
abstract class WorkflowSettingsStore {
  /// What was saved for [workflowId], by field id. Empty when nothing was.
  ///
  /// Everything that was ever written comes back, including a field the
  /// workflow no longer declares — deciding what is still legal needs the
  /// current schema, which this store does not have and does not want. The
  /// caller drops what it cannot use, and nothing is deleted merely for being
  /// unrecognised today: a workflow may come back.
  Future<Map<String, Object?>> load(String workflowId);

  /// Writes [values] for [workflowId] as the user's defaults.
  ///
  /// A **replacement**, over exactly [declaredFields]: one of those with no
  /// value in [values] is removed rather than left behind, so clearing a
  /// setting and saving unsets it instead of resurrecting what was there
  /// before. Anything stored under a field the workflow no longer declares is
  /// outside that set and survives untouched — the workflow may come back.
  Future<void> save(
    String workflowId,
    Map<String, Object?> values, {
    required Set<String> declaredFields,
  });

  /// Whether [workflowId]'s submissions may be translated, as this device
  /// remembers it. `true` for a workflow nobody has said anything about.
  ///
  /// Read on its own rather than folded into [load], because [load] answers
  /// with fields and this is not one — a caller that could not tell the two
  /// apart is exactly what the key shape prevents.
  Future<bool> loadTranslateOverride(String workflowId);

  /// Remembers the answer. `true` erases the override rather than writing one,
  /// so switching the stage back on leaves nothing behind that could switch it
  /// off again.
  Future<void> saveTranslateOverride(String workflowId, bool translatePrompt);

  /// Everything this device has saved, for every workflow — what a portable
  /// profile is made of.
  ///
  /// Keyed by workflow id, and a workflow appears here whether it is installed
  /// or not: this store has never known which workflows a server publishes,
  /// and the profile is not the place to start guessing.
  Future<Map<String, WorkflowDefaults>> loadEverything();

  /// Lays [defaults] over what [workflowId] already has.
  ///
  /// A **merge**, and the difference from [save] is the whole point: nothing
  /// is removed. A field this device has a default for and [defaults] says
  /// nothing about keeps it, because an imported profile describes what the
  /// other device had and never what this one should lose.
  ///
  /// The translation answer is the one thing [defaults] always describes,
  /// present or absent — `false` is the override and `true` is its absence —
  /// so it is written either way for the workflows a profile carries. A
  /// workflow a profile says nothing about is never passed here at all.
  ///
  /// Answers whether it was applied. `false` is a workflow id this store
  /// cannot key on, which is something only a hand-edited document produces —
  /// and the caller counts what was applied rather than what it offered, so
  /// the number a user is shown is a number of things that happened.
  Future<bool> mergeInto(String workflowId, WorkflowDefaults defaults);
}

/// The on-device implementation.
class PreferencesWorkflowSettingsStore implements WorkflowSettingsStore {
  PreferencesWorkflowSettingsStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  static const String _prefix = 'localcanvas.defaults.';

  final SharedPreferencesAsync _prefs;

  @override
  Future<Map<String, Object?>> load(String workflowId) async {
    final prefix = _keyPrefixFor(workflowId);
    final stored = await _prefs.getAll();
    final values = <String, Object?>{};
    for (final entry in stored.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final fieldId = entry.key.substring(prefix.length);
      if (fieldId.isEmpty) continue;
      values[fieldId] = entry.value;
    }
    return values;
  }

  @override
  Future<void> save(
    String workflowId,
    Map<String, Object?> values, {
    required Set<String> declaredFields,
  }) async {
    final prefix = _keyPrefixFor(workflowId);
    // Over the declared fields rather than over the values, which is what
    // makes this a replacement: a field the user cleared is one with no value
    // here, and it has to lose its stored default rather than keep it.
    for (final fieldId in declaredFields) {
      if (fieldId.isEmpty) continue;
      final key = '$prefix$fieldId';
      if (await _write(key, values[fieldId])) continue;
      // Nothing to keep for this one: it was cleared, or it is not a scalar
      // this store can write — which is never coerced into a string, because
      // a value nobody can read back is worse than none.
      await _prefs.remove(key);
    }
  }

  @override
  Future<bool> loadTranslateOverride(String workflowId) async {
    final stored = await _prefs.getAll();
    final override = stored[_overrideKeyFor(workflowId)];
    // Anything that is not a switched-off override reads as the absence of
    // one, which is what every workflow starts as.
    return override is bool ? override : true;
  }

  @override
  Future<void> saveTranslateOverride(
    String workflowId,
    bool translatePrompt,
  ) async {
    if (!_isUsableId(workflowId)) return;
    final key = _overrideKeyFor(workflowId);
    if (translatePrompt) {
      await _prefs.remove(key);
      return;
    }
    await _prefs.setBool(key, false);
  }

  @override
  Future<Map<String, WorkflowDefaults>> loadEverything() async {
    final stored = await _prefs.getAll();
    final values = <String, Map<String, Object?>>{};
    final overrides = <String, bool>{};
    for (final entry in stored.entries) {
      if (!entry.key.startsWith(_prefix)) continue;
      final rest = entry.key.substring(_prefix.length);
      final dot = rest.indexOf('.');
      if (dot < 0) {
        // No field segment at all. That is the durable translation answer and
        // the only thing this namespace holds which is not a field — the same
        // shape, and the same reading, as the draft's.
        if (rest.isNotEmpty && entry.value == false) overrides[rest] = false;
        continue;
      }
      final workflowId = rest.substring(0, dot);
      final fieldId = rest.substring(dot + 1);
      if (workflowId.isEmpty || fieldId.isEmpty) continue;
      (values[workflowId] ??= <String, Object?>{})[fieldId] = entry.value;
    }
    return <String, WorkflowDefaults>{
      for (final workflowId in <String>{...values.keys, ...overrides.keys})
        workflowId: WorkflowDefaults(
          values: values[workflowId] ?? const <String, Object?>{},
          translatePrompt: overrides[workflowId] ?? true,
        ),
    };
  }

  @override
  Future<bool> mergeInto(String workflowId, WorkflowDefaults defaults) async {
    if (!_isUsableId(workflowId)) return false;
    final prefix = _keyPrefixFor(workflowId);
    for (final entry in defaults.values.entries) {
      if (entry.key.isEmpty) continue;
      // Written when it is something this store can hold, and passed over
      // when it is not — never removed. A merge that deleted what it could
      // not read would let a hand-edited document destroy what is here.
      await _write('$prefix${entry.key}', entry.value);
    }
    await saveTranslateOverride(workflowId, defaults.translatePrompt);
    return true;
  }

  /// Writes one scalar, and says whether there was one to write.
  ///
  /// The one place the storable types are enumerated, so [save] and
  /// [mergeInto] cannot come to disagree about what a value is. A value that
  /// is not one of them is never coerced into a string: an id naming an
  /// uploaded file arrives as a map, and written down as text it would be the
  /// one thing this store must not keep.
  Future<bool> _write(String key, Object? value) async {
    switch (value) {
      case final bool value:
        await _prefs.setBool(key, value);
      case final int value:
        await _prefs.setInt(key, value);
      case final double value:
        await _prefs.setDouble(key, value);
      case final String value:
        await _prefs.setString(key, value);
      default:
        return false;
    }
    return true;
  }

  /// Whether an id may be used to build a key.
  ///
  /// A workflow id has no dot (`docs/workflow-schema.md`), and a document that
  /// arrived from somewhere else is not trusted to honour that: one with a dot
  /// in it would write a key that reads back as another workflow's field.
  static bool _isUsableId(String workflowId) =>
      workflowId.isNotEmpty && !workflowId.contains('.');

  String _keyPrefixFor(String workflowId) => '$_prefix$workflowId.';

  String _overrideKeyFor(String workflowId) => '$_prefix$workflowId';
}
