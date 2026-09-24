/// The current draft: what a user was in the middle of, per workflow.
///
/// A second store beside `workflow_settings_store.dart`, and deliberately not
/// an extension of it. The two answer different questions — "what do I always
/// want?" against "what was I in the middle of?" — hold different contents and
/// have different lifetimes, and merging them would give one of the answers
/// the other one's rules.
///
/// The policy, because a store is only as good as the rule about what may go
/// into it:
///
/// * **The text kept is the ORIGINAL — what the user typed.** Never the
///   effective text a translated submission was bound with. `docs/api.md`
///   makes the original canonical: it is what the app displays, what a draft
///   stores and what Generate Again resubmits. A draft that saved the
///   effective text would replace what the user wrote with what the machine
///   made of it, silently, and leave the app no copy of their own words. This
///   is the single most important rule in this file.
/// * **No media reference is ever written, and that is not an oversight.** An
///   uploaded file is named by an id in the gateway's temporary store, which
///   has a lifetime of its own and does not survive the gateway restarting.
///   A reference persisted across the app being killed is one that will
///   usually be dead by the time it is read back, and a form silently holding
///   a dead id is worse than an empty field. So a draft brings the prose and
///   the settings back, the media field comes back empty, and the form's own
///   required-media issue asks for the picture again — which is the same
///   thing that happens after a reconnect when a selection's permission has
///   lapsed (`docs/recovery.md`). **Do not "fix" this by storing the id.**
/// * **Which values may be kept is decided from the field's declared type**,
///   and from nothing else. [isSafeToKeep] is reused rather than restated:
///   two rules about what may be persisted would drift, and the one that
///   drifted would be the one nobody read. A draft adds prose to what that
///   function admits, and adds nothing else — see [isDraftable].
/// * **One draft per workflow, overwritten.** Not a list, not a stack, no
///   undo, no prompt history. A save replaces what was there.
/// * **The key is the workflow's id and the field's own logical id.** Never a
///   position in the form and never anything read out of a definition the app
///   has never seen (`docs/workflow-schema.md`: the registry view carries no
///   such thing) — there is no list of field ids in this file and there must
///   never be one, because a curator names their own fields.
///
/// Keys are namespaced under `localcanvas.draft.`, beside the namespaces the
/// defaults and the remembered endpoint already use. A workflow id has no dot
/// (`docs/workflow-schema.md`: `[a-z0-9_-]`), so `localcanvas.draft.<id>.` is
/// unambiguously one workflow's fields however many dots a curator put in a
/// field id — and the translation override, which is not a field and must not
/// be able to collide with one, is kept at `localcanvas.draft.<id>` exactly,
/// with no dot after it. No field key can equal that, because every field key
/// has a dot and a non-empty id after the workflow.
///
/// The frozen seed is the second such thing, and is kept the same way, at
/// `localcanvas.draft.<id>#seed-frozen`. A workflow id cannot contain a `#`
/// either, so that key is neither a field of this workflow — those all begin
/// `localcanvas.draft.<id>.` — nor anything belonging to a workflow whose id
/// merely starts the same way.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workflow_models.dart';
import 'workflow_settings_store.dart';

/// Whether a field holds prose — words a person wrote.
///
/// Type-driven and exhaustive, like [isSafeToKeep] beside it: a field type
/// added to the schema later fails to compile here rather than defaulting
/// into a store.
bool isProse(WorkflowField field) => switch (field.type) {
  // What the user writes. A draft is the one place it belongs, and it is kept
  // exactly as they typed it.
  FieldType.string || FieldType.multiline => true,
  // Tuning: a number, a switch, a choice. Not prose, and already decided.
  FieldType.integer ||
  FieldType.float ||
  FieldType.boolean ||
  FieldType.select => false,
  // A reference to an uploaded file, which outlives neither the server nor
  // the picture's permission on the device.
  FieldType.image || FieldType.video => false,
  // Something this build cannot even show. It has no value to keep.
  FieldType.unsupported => false,
};

/// Whether a field's current value belongs in a draft.
///
/// Exactly what [isSafeToKeep] admits, plus prose. Written as that sum rather
/// than as a second `switch`, so the two stores cannot drift on the half they
/// share: change what may be kept as a default and a draft changes with it.
bool isDraftable(WorkflowField field) => isSafeToKeep(field) || isProse(field);

/// One workflow's draft: the values, and the translation override.
///
/// The override is not a field and never becomes one — it is a choice about
/// what the gateway may do to the next submission (`docs/api.md`, T-0043), so
/// it travels beside the values instead of inside them, where a workflow that
/// happened to declare a field of the same name would collide with it.
@immutable
class WorkflowDraft {
  const WorkflowDraft({
    this.values = const <String, Object?>{},
    this.translatePrompt = true,
    this.freezeSeed = false,
  });

  /// What was in the form, by logical field id.
  final Map<String, Object?> values;

  /// Whether the next submission of this workflow may be translated.
  ///
  /// `true` is the absence of an override rather than a claim that anything
  /// will be translated, which is why it is also the value a workflow nobody
  /// has said anything about comes back with.
  final bool translatePrompt;

  /// Whether Generate Again reuses this workflow's seed instead of varying
  /// it.
  ///
  /// Not a field, for the same reason the override above is not one: it is a
  /// choice about what the next submission does, and a workflow that happened
  /// to declare a field called `freeze_seed` would collide with it. `false` is
  /// the absence of an answer and is what every workflow starts as, so it is
  /// stored as an absence too.
  final bool freezeSeed;

  /// Nothing was in the middle of anything.
  bool get isEmpty => values.isEmpty && translatePrompt && !freezeSeed;

  @override
  bool operator ==(Object other) =>
      other is WorkflowDraft &&
      other.translatePrompt == translatePrompt &&
      other.freezeSeed == freezeSeed &&
      mapEquals(other.values, values);

  @override
  int get hashCode => Object.hash(
    translatePrompt,
    freezeSeed,
    Object.hashAllUnordered(<Object?>[
      for (final entry in values.entries) Object.hash(entry.key, entry.value),
    ]),
  );

  @override
  String toString() =>
      'WorkflowDraft($values, translatePrompt: $translatePrompt, '
      'freezeSeed: $freezeSeed)';
}

/// The seam. One workflow's current draft, read and written whole.
abstract class WorkflowDraftStore {
  /// The draft kept for [workflowId], or an empty one when there is none.
  ///
  /// Everything that was ever written comes back, including a field the
  /// workflow no longer declares — deciding what is still legal needs the
  /// current schema, which this store does not have and does not want. The
  /// caller drops what it cannot use.
  Future<WorkflowDraft> load(String workflowId);

  /// Replaces [workflowId]'s draft with [draft].
  ///
  /// A **replacement**, over exactly [draftableFields]: one of those with no
  /// value in the draft is removed rather than left behind, so a prompt the
  /// user cleared stays cleared instead of coming back on the next launch.
  /// Anything stored under a field the workflow no longer declares is outside
  /// that set and survives untouched — the workflow may come back.
  ///
  /// This is the whole of the writing side. There is no second draft, no
  /// previous draft and nothing to undo to: one per workflow, overwritten.
  Future<void> save(
    String workflowId,
    WorkflowDraft draft, {
    required Set<String> draftableFields,
  });
}

/// The on-device implementation.
class PreferencesWorkflowDraftStore implements WorkflowDraftStore {
  PreferencesWorkflowDraftStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  static const String _prefix = 'localcanvas.draft.';

  final SharedPreferencesAsync _prefs;

  @override
  Future<WorkflowDraft> load(String workflowId) async {
    final prefix = _keyPrefixFor(workflowId);
    final stored = await _prefs.getAll();
    final values = <String, Object?>{};
    for (final entry in stored.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final fieldId = entry.key.substring(prefix.length);
      if (fieldId.isEmpty) continue;
      values[fieldId] = entry.value;
    }
    final override = stored[_overrideKeyFor(workflowId)];
    final frozen = stored[_freezeKeyFor(workflowId)];
    return WorkflowDraft(
      values: values,
      // Anything that is not a switched-off override reads as the absence of
      // one, which is what every workflow starts as.
      translatePrompt: override is bool ? override : true,
      // And the same rule for the seed: only a stored `true` freezes one.
      freezeSeed: frozen is bool && frozen,
    );
  }

  @override
  Future<void> save(
    String workflowId,
    WorkflowDraft draft, {
    required Set<String> draftableFields,
  }) async {
    final prefix = _keyPrefixFor(workflowId);
    // Over the fields a draft covers rather than over the values, which is
    // what makes this a replacement: a prompt the user emptied is one with no
    // value here, and it has to lose what was written for it.
    for (final fieldId in draftableFields) {
      if (fieldId.isEmpty) continue;
      final key = '$prefix$fieldId';
      switch (draft.values[fieldId]) {
        case final bool value:
          await _prefs.setBool(key, value);
        case final int value:
          await _prefs.setInt(key, value);
        case final double value:
          await _prefs.setDouble(key, value);
        case final String value:
          await _prefs.setString(key, value);
        default:
          // Nothing to keep for this one: it was cleared, or it is not a
          // scalar this store can write — which is never coerced into a
          // string. That second case is how a reference to an uploaded file
          // would arrive, and coercing it would write down the one thing this
          // store must never write down.
          await _prefs.remove(key);
      }
    }
    final overrideKey = _overrideKeyFor(workflowId);
    if (draft.translatePrompt) {
      // The absence of an override is stored as an absence, so switching the
      // stage back on leaves nothing behind that could switch it off again.
      await _prefs.remove(overrideKey);
    } else {
      await _prefs.setBool(overrideKey, false);
    }
    final freezeKey = _freezeKeyFor(workflowId);
    if (draft.freezeSeed) {
      await _prefs.setBool(freezeKey, true);
    } else {
      // Unfreezing leaves nothing behind, exactly as switching translation
      // back on does: there is one representation of "nothing was said".
      await _prefs.remove(freezeKey);
    }
  }

  String _keyPrefixFor(String workflowId) => '$_prefix$workflowId.';

  String _overrideKeyFor(String workflowId) => '$_prefix$workflowId';

  String _freezeKeyFor(String workflowId) => '$_prefix$workflowId#seed-frozen';
}
