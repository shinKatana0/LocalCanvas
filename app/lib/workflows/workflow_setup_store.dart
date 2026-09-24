/// Saved setups: the named things a user asked to be able to come back to.
///
/// The third store beside `workflow_settings_store.dart` and
/// `workflow_draft_store.dart`, and deliberately not a widening of either.
/// The three answer three different questions — "what do I always want?",
/// "what was I in the middle of?", and "give me back that thing I had
/// working" — and only the third one is named, deliberate, and allowed to
/// exist several times over for one workflow.
///
/// The policy, because a store is only as good as the rule about what may go
/// into it:
///
/// * **A setup holds exactly what a draft holds**: the prose a person typed
///   plus the safe tuning `isSafeToKeep` admits, which together are
///   [isDraftable]. That function is reused, never restated: a third rule
///   about what may be persisted would drift from the first two, and the one
///   that drifted would be the one nobody read.
/// * **The text kept is the ORIGINAL — what the user typed.** Never the
///   effective text a translated submission was bound with. `docs/api.md`
///   makes the original canonical and names a saved setup as one of the
///   things that store it. A setup that kept the effective text would hand
///   the user back what the machine made of their words, under a name they
///   chose for their own.
/// * **No media reference is ever written**, for the reason the draft store
///   gives at length: a `media_id` names a file in the gateway's temporary
///   store, which outlives neither the gateway nor the picture's permission
///   on the device. Applying a setup brings back the prose and the settings;
///   the media field asks for the picture again.
/// * **Nothing structural is ever written.** No workflow definition, no node
///   id — the app has never received one (`docs/workflow-schema.md`: the
///   registry view carries no such thing) — no backend or model path, no
///   address and nothing to authenticate with. The values are scalars keyed
///   by the field's own logical id, and the writing side cannot express
///   anything else: a value that is not a number, a switch, a choice or a
///   piece of text is dropped rather than coerced into one.
/// * **There is no list of field ids in this file and there must never be
///   one**. A curator names their own fields, and a store
///   that recognised one by its name would keep the wrong thing — or nothing
///   at all — for the next user.
///
/// What differs from the two stores beside it is identity and multiplicity:
///
/// * **The id is minted once and never derived from the name.** Renaming
///   rewrites one field of one document and touches no key, so a setup keeps
///   its identity through any number of renames, and two setups may carry the
///   same name without being able to collide.
/// * **One document per setup, and no index.** The key is
///   `localcanvas.setup.<id>`, the value is a small JSON object naming the
///   workflow it belongs to, the name the user gave it and the values. The
///   list for one workflow is a scan of that namespace, exactly as the two
///   stores beside it scan theirs — an index would be a second copy of the
///   truth, and the first thing to go wrong with one is that it lists a setup
///   that was deleted or misses one that was written.
/// * **A setup whose workflow is not installed is left exactly where it is.**
///   Nothing here deletes, repairs or rewrites a document because the workflow
///   it names is absent: [load] simply does not return it. The workflow may
///   come back with the next sync.
///
/// The namespace sits beside the ones the defaults, the draft and the
/// remembered endpoint already use, and cannot be read as any of them: a
/// setup id is minted here and never contains a dot, so nothing after the
/// prefix can be mistaken for a workflow followed by a field.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One saved setup: a name a user chose, an identity that does not depend on
/// it, and the values it brings back.
@immutable
class WorkflowSetup {
  const WorkflowSetup({
    required this.id,
    required this.workflowId,
    required this.name,
    this.values = const <String, Object?>{},
  });

  /// Minted when the setup is created and never rewritten. Not derived from
  /// the name, not derived from the values, and not a position in a list.
  final String id;

  /// The workflow this setup belongs to, by the id the registry publishes.
  final String workflowId;

  /// What the user called it. Free text, and not unique: two setups may share
  /// a name, and telling them apart is [id]'s job.
  final String name;

  /// What it brings back, by logical field id.
  final Map<String, Object?> values;

  /// The same setup under another name. Same [id], same [values] — which is
  /// the whole of what "renaming does not change identity" means.
  WorkflowSetup withName(String name) =>
      WorkflowSetup(id: id, workflowId: workflowId, name: name, values: values);

  @override
  bool operator ==(Object other) =>
      other is WorkflowSetup &&
      other.id == id &&
      other.workflowId == workflowId &&
      other.name == name &&
      mapEquals(other.values, values);

  @override
  int get hashCode => Object.hash(
    id,
    workflowId,
    name,
    Object.hashAllUnordered(<Object?>[
      for (final entry in values.entries) Object.hash(entry.key, entry.value),
    ]),
  );

  @override
  String toString() => 'WorkflowSetup($id, $workflowId, $name, $values)';
}

/// The seam. A flat collection of setups, read by workflow and written one at
/// a time.
///
/// There is no folder, no tag, no order the user maintains and no search
/// — those are the four things a store like this grows first and none of
/// them is in v0.1.
abstract class WorkflowSetupStore {
  /// Every setup saved for [workflowId], in a stable order.
  ///
  /// Stable so that the list does not shuffle itself between two launches —
  /// by name, and by id where two share one. That is an order, not an
  /// ordering interface: nothing lets the user rearrange it.
  ///
  /// A setup belonging to a workflow this server does not publish is simply
  /// not asked for here, and stays where it is.
  Future<List<WorkflowSetup>> load(String workflowId);

  /// Saves [values] under [name] as a new setup for [workflowId], and answers
  /// with it — id included, because the caller cannot compute one.
  ///
  /// Always a new setup. Nothing here overwrites an existing one, however
  /// familiar the name looks: a setup is created only when the user asks, and
  /// two of them may legitimately be called the same thing.
  Future<WorkflowSetup> create({
    required String workflowId,
    required String name,
    required Map<String, Object?> values,
  });

  /// Gives the setup [setupId] a new name, and changes nothing else.
  ///
  /// A setup that is no longer there is not an error: it was deleted, and
  /// there is nothing to rename.
  Future<void> rename(String setupId, String name);

  /// Forgets exactly one setup. Every other one, including one that shares
  /// its name, is untouched.
  Future<void> delete(String setupId);

  /// Every setup on this device, whatever workflow it belongs to, in the same
  /// stable order [load] uses.
  ///
  /// What a portable profile is made of. It asks no server anything: a setup
  /// belonging to a workflow this phone has never seen is in here exactly like
  /// any other, because it is a thing the user made and not a thing a registry
  /// published.
  Future<List<WorkflowSetup>> loadEverything();

  /// Writes [setup] under **its own id**, replacing whatever document that id
  /// held.
  ///
  /// The one operation [create] cannot express, and the reason it exists is
  /// import: a setup that came from another device carries the identity it was
  /// minted with, so importing the same profile twice leaves one setup rather
  /// than two. Every setup this device has and the profile does not name is
  /// outside this call entirely and survives it untouched.
  ///
  /// Answers whether it was written. `false` is an identity this store cannot
  /// key on, which is something only a hand-edited document produces — and the
  /// caller counts what was written rather than what it offered.
  Future<bool> adopt(WorkflowSetup setup);
}

/// The on-device implementation.
class PreferencesWorkflowSetupStore implements WorkflowSetupStore {
  PreferencesWorkflowSetupStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  static const String _prefix = 'localcanvas.setup.';

  /// The three members of one stored document. They are the shape of this
  /// file's own storage and nothing a curator ever chose — which is why
  /// naming them here is not the forbidden field-name vocabulary.
  static const String _workflowKey = 'workflow';
  static const String _nameKey = 'name';
  static const String _valuesKey = 'values';

  final SharedPreferencesAsync _prefs;

  @override
  Future<List<WorkflowSetup>> load(String workflowId) async {
    final stored = await _prefs.getAll();
    final setups = <WorkflowSetup>[];
    for (final entry in stored.entries) {
      if (!entry.key.startsWith(_prefix)) continue;
      final id = entry.key.substring(_prefix.length);
      if (id.isEmpty) continue;
      final setup = _read(id, entry.value);
      // Not this workflow's, or not something this build can read. Either
      // way it stays exactly where it is: deleting what we do not recognise
      // is how a user loses a setup to a version they installed for an hour.
      if (setup == null || setup.workflowId != workflowId) continue;
      setups.add(setup);
    }
    setups.sort(_stableOrder);
    return setups;
  }

  @override
  Future<WorkflowSetup> create({
    required String workflowId,
    required String name,
    required Map<String, Object?> values,
  }) async {
    final taken = <String>{
      for (final key in (await _prefs.getAll()).keys)
        if (key.startsWith(_prefix)) key,
    };
    // A minted id twice over is not a thing that happens; a setup silently
    // replacing another one would be, so the loop is here anyway. It cannot
    // run forever: each candidate differs from the last, and there are
    // finitely many keys to avoid.
    final base = _mintId();
    var id = base;
    var suffix = 0;
    while (taken.contains(_keyFor(id))) {
      id = '$base-${suffix++}';
    }
    final setup = WorkflowSetup(
      id: id,
      workflowId: workflowId,
      name: name,
      values: _writable(values),
    );
    await _prefs.setString(_keyFor(id), jsonEncode(_documentOf(setup)));
    return setup;
  }

  @override
  Future<void> rename(String setupId, String name) async {
    final key = _keyFor(setupId);
    final stored = await _prefs.getString(key);
    if (stored == null) return;
    final setup = _read(setupId, stored);
    if (setup == null) return;
    // The same key, the same id, the same values: one field of the document
    // is rewritten and identity is not among them.
    await _prefs.setString(key, jsonEncode(_documentOf(setup.withName(name))));
  }

  @override
  Future<void> delete(String setupId) => _prefs.remove(_keyFor(setupId));

  @override
  Future<List<WorkflowSetup>> loadEverything() async {
    final stored = await _prefs.getAll();
    final setups = <WorkflowSetup>[];
    for (final entry in stored.entries) {
      if (!entry.key.startsWith(_prefix)) continue;
      final id = entry.key.substring(_prefix.length);
      if (id.isEmpty) continue;
      final setup = _read(id, entry.value);
      // Not something this build can read. It stays exactly where it is and
      // is not carried into a profile either: a document nobody here
      // understands is not one to copy onto another device.
      if (setup == null) continue;
      setups.add(setup);
    }
    setups.sort(_stableOrder);
    return setups;
  }

  @override
  Future<bool> adopt(WorkflowSetup setup) async {
    // A setup id is minted here and has never contained a dot; a document that
    // arrived from somewhere else is not trusted to honour that, because an id
    // with one in it would write a key another namespace could read as its
    // own. The same goes for the workflow it names, which is a key elsewhere.
    if (!_isUsableId(setup.id) || !_isUsableId(setup.workflowId)) return false;
    await _prefs.setString(
      _keyFor(setup.id),
      // Through the same document builder and the same filter as [create], so
      // an imported setup cannot hold anything a locally made one could not.
      jsonEncode(
        _documentOf(
          WorkflowSetup(
            id: setup.id,
            workflowId: setup.workflowId,
            name: setup.name,
            values: _writable(setup.values),
          ),
        ),
      ),
    );
    return true;
  }

  /// Whether an id may be used to build a key. An empty one names nothing, and
  /// one with a dot in it would land in the middle of a namespace split on
  /// dots.
  static bool _isUsableId(String id) => id.isNotEmpty && !id.contains('.');

  String _keyFor(String setupId) => '$_prefix$setupId';

  Map<String, Object?> _documentOf(WorkflowSetup setup) => <String, Object?>{
    _workflowKey: setup.workflowId,
    _nameKey: setup.name,
    _valuesKey: setup.values,
  };

  /// One stored document, or `null` when it is not one.
  WorkflowSetup? _read(String id, Object? stored) {
    if (stored is! String) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final workflowId = decoded[_workflowKey];
    final name = decoded[_nameKey];
    if (workflowId is! String || workflowId.isEmpty || name is! String) {
      return null;
    }
    final values = decoded[_valuesKey];
    return WorkflowSetup(
      id: id,
      workflowId: workflowId,
      name: name,
      // Filtered on the way out as well as on the way in. A document written
      // by hand cannot hand a form something a form cannot hold.
      values: values is Map
          ? _writable(<String, Object?>{
              for (final entry in values.entries)
                if (entry.key is String) entry.key as String: entry.value,
            })
          : const <String, Object?>{},
    );
  }

  /// The values as this store is willing to hold them.
  ///
  /// A number, a switch, a choice, a piece of text — and nothing else, ever
  /// coerced. That second half is the point: a reference to an uploaded file
  /// arrives as a map, and written down as text it would become an id naming
  /// a file that is very likely gone by the time anyone reads it back. It is
  /// dropped instead, here, where the layer above cannot overrule it.
  static Map<String, Object?> _writable(Map<String, Object?> values) {
    final kept = <String, Object?>{};
    for (final entry in values.entries) {
      if (entry.key.isEmpty) continue;
      switch (entry.value) {
        case final bool value:
          kept[entry.key] = value;
        case final int value:
          kept[entry.key] = value;
        case final double value:
          kept[entry.key] = value;
        case final String value:
          kept[entry.key] = value;
        default:
          continue;
      }
    }
    return kept;
  }

  /// By name, then by id. Not an order the user maintains — an order that
  /// does not change on its own between two launches.
  static int _stableOrder(WorkflowSetup a, WorkflowSetup b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }

  /// A fresh identity: when it was made, and enough noise that two made in
  /// the same microsecond are still two.
  ///
  /// Nothing about the name is in here, which is the whole requirement, and
  /// nothing about the workflow either. Base 36 keeps it short and free of
  /// the dot the namespaces around it are split on.
  static String _mintId() {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final noise = _noise.nextInt(1 << 30).toRadixString(36);
    return '$stamp-$noise';
  }

  static final Random _noise = Random();
}
