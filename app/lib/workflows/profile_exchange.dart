/// Building a profile out of the stores, and merging one back into them.
///
/// Not a fourth store: it owns nothing, keeps nothing and has no namespace of
/// its own. It is the one place that reads My defaults and Saved setups
/// *whole* — which is exactly the operation a profile is — and the one place
/// that writes an imported one back.
///
/// Two rules, and they are the two the card is about:
///
/// * **The draft is not here.** `workflow_draft_store.dart` is not imported by
///   this file and never should be: what a user is in the middle of belongs to
///   the phone they are in the middle of it on, and a temporary translation
///   override is part of that. The durable answer, the one this file does
///   carry, lives in My defaults (`workflow_settings_store.dart`).
/// * **Merge is the only way in.** Nothing here removes anything. A workflow,
///   a field or a setup this device has and the profile does not name comes
///   through an import exactly as it was — which is what makes importing a
///   profile a safe thing to try. There is no replace mode, and adding one
///   would be a different, destructive promise needing a different word than
///   "import".
///
/// A workflow the phone does not have is not a special case anywhere in here.
/// Neither store has ever known which workflows a server publishes, so an
/// entry for an absent workflow is written like any other and simply lies
/// dormant: it comes to life the first time that workflow is opened, by the
/// same layering that applies every other saved value.
library;

import 'package:flutter/foundation.dart';

import 'workflow_profile.dart';
import 'workflow_settings_store.dart';
import 'workflow_setup_store.dart';

/// What an import changed, for the sentence the interface shows afterwards.
///
/// Counted from what was actually written rather than from what the document
/// happened to contain, so a workflow the store refused to key on is not
/// reported as imported.
@immutable
class ProfileImportReport {
  const ProfileImportReport({required this.workflows, required this.setups});

  /// How many workflows had something laid over them.
  final int workflows;

  /// How many setups were written — added, or replaced where this device
  /// already had one under the same identity.
  final int setups;

  bool get isEmpty => workflows == 0 && setups == 0;

  @override
  String toString() => 'ProfileImportReport($workflows, $setups)';
}

/// Reads and writes the whole of what a user has saved.
class ProfileExchange {
  const ProfileExchange({required this.settings, required this.setups});

  final WorkflowSettingsStore settings;
  final WorkflowSetupStore setups;

  /// Everything this device has saved, as one document.
  ///
  /// Read from the two stores and from nothing else. There is no third source
  /// to forget to exclude, which is the point: the endpoint, the draft, the
  /// media and the job are not "filtered out" here — they were never asked
  /// for.
  Future<WorkflowProfile> export() async {
    final defaults = await settings.loadEverything();
    final saved = await setups.loadEverything();
    return WorkflowProfile(
      workflows: <String, ProfileEntry>{
        for (final entry in defaults.entries)
          // A workflow whose entry says nothing at all is left out. It would
          // be an empty object naming a workflow and asserting nothing about
          // it, and importing it would change nothing on the other device.
          if (!entry.value.isEmpty) entry.key: entry.value,
      },
      setups: saved,
    );
  }

  /// Lays [profile] over what this device already has.
  Future<ProfileImportReport> merge(WorkflowProfile profile) async {
    var workflows = 0;
    for (final entry in profile.workflows.entries) {
      if (await settings.mergeInto(entry.key, entry.value)) workflows++;
    }
    var written = 0;
    for (final setup in profile.setups) {
      if (await setups.adopt(setup)) written++;
    }
    return ProfileImportReport(workflows: workflows, setups: written);
  }
}
