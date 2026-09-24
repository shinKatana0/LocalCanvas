/// The portable profile: what a user can carry from one phone to another, as
/// one small, versioned, human-readable JSON document.
///
/// This file is the **document** and nothing else — no storage, no file, no
/// share sheet. It knows how to write what the two stores hold and how to read
/// a document back, and it is where the promise about what a profile contains
/// is kept, because a promise about content belongs where the content is
/// serialised.
///
/// What it carries, and it is a short list on purpose:
///
/// * **My defaults**, per workflow, keyed by the workflow's own id and the
///   field's own logical id — the same two names the settings store already
///   keys by, so nothing has to be translated between the two and nothing can
///   be lost in the translation.
/// * **The durable translation answer**, written only when it is `off`. Its
///   absence is `auto`, which is the same representation both stores use: an
///   honest absence, never a key that is always there and usually empty.
/// * **Saved setups**, each with the identity it was minted with, so importing
///   the same profile twice leaves one setup rather than two.
///
/// What it never carries, and this is the half worth writing down:
///
/// * **Nothing about a server.** No endpoint, no address, no port, no name a
///   machine calls itself, nothing to authenticate with. The profile is built
///   from the two stores and neither of them has ever been given one — the
///   remembered endpoint lives in its own namespace and is not read here
///   (`docs/privacy-security.md`).
/// * **Nothing about a file.** No path, no reference to an uploaded picture or
///   clip. Those cannot arrive: a media reference is not a value either store
///   will hold, and a value that is not a number, a switch, a choice or a
///   piece of text is dropped rather than coerced.
/// * **Nothing structural.** No workflow definition, no graph, no id out of
///   one — the app has never received such a thing (`docs/workflow-schema.md`)
///   and cannot write down what it has never seen.
/// * **Nothing from a generation.** No current draft, no job, no result, no
///   history, and nothing a translator produced. The draft is a separate store
///   and is not read here; what a user is in the middle of belongs to the
///   phone they are in the middle of it on.
/// * **No list of field ids.** A curator names their own fields, and this file
///   names none of them.
///
/// **Versioning.** [kProfileVersion] is the *major* version and the whole of
/// the compatibility rule: a document that declares a higher one is refused,
/// by name and by number, rather than half-imported. Growth within a version
/// is additive — a later build may write keys this one has never heard of, and
/// this one ignores them and imports the rest, which is what makes a newer
/// minor version readable here. Removing or re-meaning a key is what costs a
/// major version, and adding favourites, if they are ever built, would cost
/// one too: they are absent from this document because the feature does not
/// exist in this build, and an always-empty key would be a promise nothing
/// keeps.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import 'workflow_settings_store.dart';
import 'workflow_setup_store.dart';

/// What every LocalCanvas profile says it is. A document that does not say
/// this is not one, however well-formed its JSON.
const String kProfileFormat = 'localcanvas.profile';

/// The major version this build writes and the highest it reads.
const int kProfileVersion = 1;

/// The name the exported document is offered under.
///
/// A name, never a path (`docs/ui-ux.md` says the same about a shared result),
/// and the same one every time: it carries no date, no device name and nothing
/// else about whoever exported it.
const String kProfileFilename = 'localcanvas-profile.json';

/// One workflow's entry in a profile: what the user saved for it.
///
/// [WorkflowDefaults] is reused rather than restated. The profile and the
/// store hold the same thing, and a second class describing it would be a
/// second answer to what "My defaults" means.
typedef ProfileEntry = WorkflowDefaults;

/// The three ways a profile can refuse to be read, written or handed over.
enum ProfileFailureKind {
  notAProfile,
  fromANewerVersion,
  failed,
}

/// Why a profile could not be read, written or handed over.
///
/// Every one of them names what to do next where there is something to do, and
/// none of them shows an exception (`docs/ui-ux.md`). Since T-0142 none of them
/// holds a sentence either: the dialog that draws it decides the language.
@immutable
class ProfileFailure implements Exception {
  const ProfileFailure(this.kind, {this.found, this.supported});

  /// The file opened and was not a profile: not JSON at all, or JSON that says
  /// it is something else.
  const ProfileFailure.notAProfile()
    : kind = ProfileFailureKind.notAProfile,
      found = null,
      supported = null;

  /// The file is a profile from a newer LocalCanvas. Refused whole: a
  /// half-import is the one outcome worth avoiding here, because nothing in
  /// this app can tell the user which half arrived.
  const ProfileFailure.fromANewerVersion({
    required int this.found,
    int this.supported = kProfileVersion,
  }) : kind = ProfileFailureKind.fromANewerVersion;

  /// The share sheet or the file chooser did not work.
  const ProfileFailure.failed()
    : kind = ProfileFailureKind.failed,
      found = null,
      supported = null;

  final ProfileFailureKind kind;

  /// The two version numbers a refused newer profile names, and `null` for the
  /// two failures that name none.
  final int? found;
  final int? supported;

  String title(L l) => switch (kind) {
    ProfileFailureKind.notAProfile => l.profileNotAProfileTitle,
    ProfileFailureKind.fromANewerVersion => l.profileNewerTitle,
    ProfileFailureKind.failed => l.didntWorkTitle,
  };

  String message(L l) => switch (kind) {
    ProfileFailureKind.notAProfile => l.profileNotAProfileMessage,
    ProfileFailureKind.fromANewerVersion => l.profileNewerMessage(
      found ?? 0,
      supported ?? kProfileVersion,
    ),
    ProfileFailureKind.failed => l.tryAgainMessage,
  };

  @override
  bool operator ==(Object other) =>
      other is ProfileFailure &&
      other.kind == kind &&
      other.found == found &&
      other.supported == supported;

  @override
  int get hashCode => Object.hash(kind, found, supported);

  @override
  String toString() => 'ProfileFailure(${kind.name})';
}

/// A whole profile: every workflow the user has saved something for, and every
/// setup they have made.
@immutable
class WorkflowProfile {
  const WorkflowProfile({
    this.workflows = const <String, ProfileEntry>{},
    this.setups = const <WorkflowSetup>[],
  });

  /// By workflow id. A workflow this phone does not have is in here like any
  /// other: the profile describes what a user saved, not what a server
  /// publishes.
  final Map<String, ProfileEntry> workflows;

  /// Every setup, each carrying the workflow it belongs to.
  final List<WorkflowSetup> setups;

  bool get isEmpty => workflows.isEmpty && setups.isEmpty;

  @override
  String toString() => 'WorkflowProfile(${workflows.length}, ${setups.length})';
}

/// Every name this document is written with.
///
/// They are the shape of this document and nothing a curator ever chose, which
/// is why naming them here is not the forbidden field-name vocabulary.
const String _formatKey = 'format';
const String _versionKey = 'version';
const String _workflowsKey = 'workflows';
const String _defaultsKey = 'defaults';
const String _translationKey = 'translation';
const String _setupsKey = 'setups';
const String _idKey = 'id';
const String _workflowKey = 'workflow';
const String _nameKey = 'name';
const String _valuesKey = 'values';

/// The one word the translation key ever carries. There is no `on` and no
/// `auto` to write, because a client cannot switch a stage on and an absence
/// already says everything `auto` would (`docs/api.md`).
const String _translationOff = 'off';

/// [profile] as the text that leaves the app.
///
/// Indented, because a profile is a small document a person may open and read,
/// and being able to see what left your phone is most of what makes this
/// feature honest.
String encodeProfile(WorkflowProfile profile) {
  final document = <String, Object?>{
    _formatKey: kProfileFormat,
    _versionKey: kProfileVersion,
    _workflowsKey: <String, Object?>{
      for (final entry in profile.workflows.entries)
        entry.key: <String, Object?>{
          _defaultsKey: entry.value.values,
          // Written only when there is something to say. `auto` is the absence
          // of this key and never the string 'auto'.
          if (!entry.value.translatePrompt) _translationKey: _translationOff,
        },
    },
    _setupsKey: <Object?>[
      for (final setup in profile.setups)
        <String, Object?>{
          _idKey: setup.id,
          _workflowKey: setup.workflowId,
          _nameKey: setup.name,
          _valuesKey: setup.values,
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

/// [text] as a profile, or a [ProfileFailure] describing why it is not one.
///
/// Two refusals and no third. A document that is not a profile is refused, and
/// a profile from a newer major version is refused **whole** — nothing about
/// it is applied, because a partial import is a state nobody could describe to
/// the user afterwards. Everything else is tolerated: a key this build has
/// never heard of is passed over, a value of the wrong kind is passed over,
/// and what is left still imports.
WorkflowProfile decodeProfile(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const ProfileFailure.notAProfile();
  }
  if (decoded is! Map) throw const ProfileFailure.notAProfile();
  if (decoded[_formatKey] != kProfileFormat) {
    throw const ProfileFailure.notAProfile();
  }
  final version = decoded[_versionKey];
  if (version is! int) throw const ProfileFailure.notAProfile();
  if (version > kProfileVersion) {
    throw ProfileFailure.fromANewerVersion(found: version);
  }
  return WorkflowProfile(
    workflows: _workflowsIn(decoded[_workflowsKey]),
    setups: _setupsIn(decoded[_setupsKey]),
  );
}

Map<String, ProfileEntry> _workflowsIn(Object? written) {
  if (written is! Map) return const <String, ProfileEntry>{};
  final workflows = <String, ProfileEntry>{};
  for (final entry in written.entries) {
    final workflowId = entry.key;
    final body = entry.value;
    if (workflowId is! String || workflowId.isEmpty || body is! Map) continue;
    workflows[workflowId] = ProfileEntry(
      values: _scalarsIn(body[_defaultsKey]),
      // Anything that is not the one word this key has reads as the absence of
      // an override, which is what a workflow nobody has said anything about
      // comes back as.
      translatePrompt: body[_translationKey] != _translationOff,
    );
  }
  return workflows;
}

List<WorkflowSetup> _setupsIn(Object? written) {
  if (written is! List) return const <WorkflowSetup>[];
  final setups = <WorkflowSetup>[];
  for (final entry in written) {
    if (entry is! Map) continue;
    final id = entry[_idKey];
    final workflowId = entry[_workflowKey];
    final name = entry[_nameKey];
    // An entry with no identity, no workflow or no name is not a setup this
    // app could show, so it is passed over rather than repaired into one.
    if (id is! String || id.isEmpty) continue;
    if (workflowId is! String || workflowId.isEmpty) continue;
    if (name is! String) continue;
    setups.add(
      WorkflowSetup(
        id: id,
        workflowId: workflowId,
        name: name,
        values: _scalarsIn(entry[_valuesKey]),
      ),
    );
  }
  return setups;
}

/// The values a form could actually hold: a number, a switch, a choice, a
/// piece of text.
///
/// Filtered on the way in as well as on the way out, exactly as the setup
/// store filters its own documents. A profile is a file a person can edit, so
/// it is the one input in this app that arrives from a text editor — and a
/// nested object written into it by hand must not be able to reach a field.
Map<String, Object?> _scalarsIn(Object? written) {
  if (written is! Map) return const <String, Object?>{};
  final values = <String, Object?>{};
  for (final entry in written.entries) {
    final key = entry.key;
    if (key is! String || key.isEmpty) continue;
    switch (entry.value) {
      case final bool value:
        values[key] = value;
      case final int value:
        values[key] = value;
      case final double value:
        values[key] = value;
      case final String value:
        values[key] = value;
      default:
        continue;
    }
  }
  return values;
}
