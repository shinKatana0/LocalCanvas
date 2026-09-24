/// Widget keys the tests drive the interface by.
///
/// They live here rather than as string literals scattered through the tests,
/// so a renamed key breaks compilation instead of quietly making a test find
/// nothing and pass.
library;

import 'package:flutter/widgets.dart';

abstract final class LcKeys {
  static const Key intro = Key('lc.intro');
  static const Key connecting = Key('lc.connecting');
  static const Key connectScreen = Key('lc.connect');

  static const Key scanPairingCode = Key('lc.connect.scan');
  static const Key enterAddress = Key('lc.connect.manual');
  static const Key addressField = Key('lc.connect.manual.field');
  static const Key addressSubmit = Key('lc.connect.manual.submit');
  static const Key retryConnection = Key('lc.connect.retry');
  static const Key searchAgain = Key('lc.connect.search-again');
  static const Key discoveryEmpty = Key('lc.connect.discovery.empty');
  static const Key discoveryUnavailable = Key('lc.connect.discovery.unavailable');
  static const Key discoveryFailureReason =
      Key('lc.connect.discovery.reason');
  static const Key scannerFallback = Key('lc.scan.manual');

  static const Key shellCompact = Key('lc.shell.compact');
  static const Key shellExpanded = Key('lc.shell.expanded');
  static const Key controlsPane = Key('lc.shell.controls');
  static const Key contentPane = Key('lc.shell.content');

  /// The grab area over the divider between the two panes. Present only on the
  /// wide layout, because that is the only one with a split to move.
  static const Key splitHandle = Key('lc.shell.split');
  static const Key serverDetailsToggle = Key('lc.shell.server-details.toggle');
  static const Key serverDetails = Key('lc.shell.server-details');

  /// How many automatic reconnect attempts this device makes (T-0212): the
  /// row, the number, and the two buttons that change it.
  static const Key reconnectAttempts = Key('lc.shell.reconnect-attempts');

  /// The product's name on the connect screen, in the box that lets it scale
  /// down rather than overflow (T-0158).
  static const Key connectWordmark = Key('lc.connect.wordmark');
  static const Key reconnectAttemptsValue = Key(
    'lc.shell.reconnect-attempts.value',
  );
  static const Key reconnectAttemptsFewer = Key(
    'lc.shell.reconnect-attempts.fewer',
  );
  static const Key reconnectAttemptsMore = Key(
    'lc.shell.reconnect-attempts.more',
  );
  static const Key workflowsEmptyState = Key('lc.shell.workflows.empty');

  static const Key workflowsLoading = Key('lc.workflows.loading');
  static const Key workflowsFailed = Key('lc.workflows.failed');
  static const Key workflowsRetry = Key('lc.workflows.retry');
  static const Key chooseWorkflow = Key('lc.workflows.choose');
  static const Key workflowPicker = Key('lc.workflows.picker');

  /// The picker's Refresh, and what it says when the list could not be read
  /// again — with its Try again (T-0017). The list already shown stays under
  /// the second one.
  static const Key workflowsRefresh = Key('lc.workflows.refresh');
  static const Key workflowsRefreshFailed = Key('lc.workflows.refresh.failed');
  static const Key workflowsRefreshRetry = Key('lc.workflows.refresh.retry');

  /// How many workflows the picker is showing. One line, above the list it
  /// counts.
  static const Key workflowCount = Key('lc.workflows.count');
  static const Key ungroupedWorkflows = Key('lc.workflows.group.ungrouped');

  /// The picker's one-kind-at-a-time filter, and its two fixed options
  /// (T-0177). Everything else in it is one option per group the gateway
  /// served, keyed by [workflowFilterGroup].
  ///
  /// `All` is the app's own word and the default; the ungrouped option is the
  /// app's word for a workflow that declared no group, and is keyed
  /// separately for the reason [ungroupedWorkflows] is — a registry may
  /// genuinely serve a group called "Other", and the two must not collide.
  static const Key workflowFilter = Key('lc.workflows.filter');
  static const Key workflowFilterAll = Key('lc.workflows.filter.all');
  static const Key workflowFilterUngrouped = Key(
    'lc.workflows.filter.ungrouped',
  );
  static const Key workflowHelpSheet = Key('lc.workflows.help');
  static const Key workflowHelpDefaults = Key('lc.workflows.help.defaults');
  static const Key selectedWorkflow = Key('lc.workflows.selected');
  static const Key changeWorkflow = Key('lc.workflows.change');

  /// The chosen workflow's own disclosure — the header that opens it and the
  /// body it opens — named after the pair the server block already uses
  /// (`serverDetailsToggle` / `serverDetails`), because it is the same
  /// affordance and a person reads the two blocks as the same kind of thing.
  static const Key selectedWorkflowToggle = Key(
    'lc.workflows.selected.toggle',
  );
  static const Key selectedWorkflowDetails = Key(
    'lc.workflows.selected.details',
  );
  static const Key workflowForm = Key('lc.form');
  static const Key advancedToggle = Key('lc.form.advanced.toggle');
  static const Key advancedSection = Key('lc.form.advanced');
  static const Key generate = Key('lc.form.generate');
  static const Key generateReason = Key('lc.form.generate.reason');

  /// The quote hint. One per form, which is why it is one key and not one per
  /// field.
  static const Key quoteHint = Key('lc.form.quote-hint');

  /// Use example, and the question it asks before it would overwrite
  /// something. One per form, for the same reason the quote hint is: both
  /// belong to the one prose field the schema points at.
  static const Key useExample = Key('lc.form.use-example');
  static const Key useExampleConfirm = Key('lc.form.use-example.confirm');
  static const Key useExampleReplace = Key('lc.form.use-example.replace');
  static const Key useExampleKeep = Key('lc.form.use-example.keep');

  /// My defaults: the three things a user can do about the settings in front
  /// of them. Absent as a group on a build that keeps no defaults at all, and
  /// "reset to mine" is absent until there are some.
  static const Key saveMyDefaults = Key('lc.form.defaults.save');
  static const Key resetToMyDefaults = Key('lc.form.defaults.mine');
  static const Key resetToWorkflowDefaults = Key('lc.form.defaults.workflow');

  /// Saved setups: the list, which exists only where there is at least one,
  /// and the affordance that makes the first one. Both absent as a group on a
  /// build that keeps no setups.
  static const Key setups = Key('lc.form.setups');
  static const Key saveSetup = Key('lc.form.setups.save');

  /// The one dialog that asks for a name — used by Save and by Rename alike,
  /// which is why Rename cost nothing.
  static const Key setupName = Key('lc.form.setups.name');
  static const Key setupNameField = Key('lc.form.setups.name.field');
  static const Key setupNameConfirm = Key('lc.form.setups.name.confirm');
  static const Key setupNameCancel = Key('lc.form.setups.name.cancel');

  /// The question asked before a setup is forgotten. There is no undo in this
  /// app, so the only protection a deliberately made thing has is being asked
  /// about.
  static const Key deleteSetupConfirm = Key('lc.form.setups.delete');
  static const Key deleteSetupAccept = Key('lc.form.setups.delete.accept');
  static const Key deleteSetupKeep = Key('lc.form.setups.delete.keep');

  /// The question asked before applying a setup would write over prose the
  /// user has written — the same protection Use example gives the same text,
  /// for the same reason. One per form rather than one per setup: only the
  /// row that was tapped ever puts it up.
  static const Key applySetupConfirm = Key('lc.form.setups.apply');
  static const Key applySetupReplace = Key('lc.form.setups.apply.replace');
  static const Key applySetupKeep = Key('lc.form.setups.apply.keep');

  /// The portable profile, which belongs to the device rather than to the
  /// chosen workflow — so it is in the controls column and not in the form.
  /// Absent as a group on a build that cannot export or import one.
  static const Key profileBar = Key('lc.profile');
  static const Key exportProfile = Key('lc.profile.export');
  static const Key importProfile = Key('lc.profile.import');
  static const Key profileProblem = Key('lc.profile.problem');
  static const Key profileProblemDismiss = Key('lc.profile.problem.ok');

  /// Appearance: which of the two brightnesses this device shows, and the
  /// three answers. It belongs to the phone rather than to the chosen
  /// workflow, so it is in the controls column beside the profile — and, like
  /// the profile, it is absent as a group on a build that was not given one.
  static const Key appearance = Key('lc.appearance');
  static const Key appearanceLight = Key('lc.appearance.light');
  static const Key appearanceDark = Key('lc.appearance.dark');
  static const Key appearanceSystem = Key('lc.appearance.system');

  /// Language: which of the shipped locales this device shows, plus "follow
  /// the phone". It sits beside Appearance for the same reason Appearance sits
  /// beside the profile, and is absent as a group on a build that was not
  /// given a language choice.
  ///
  /// **The per-locale keys are computed from the tag, not listed.** A third
  /// locale is a third `.arb` file and nothing else; a hand-written
  /// `languageJapanese` here would be one more place to remember (T-0142).
  static const Key language = Key('lc.language');
  static const Key languageSystem = Key('lc.language.system');
  static Key languageOption(String tag) => Key('lc.language.$tag');

  static const Key creationIdle = Key('lc.creation.idle');

  /// The generation surface and the pieces a test drives it by.
  static const Key generationSurface = Key('lc.generation');
  static const Key generationStatus = Key('lc.generation.status');
  static const Key generationProgress = Key('lc.generation.progress');
  static const Key generationProgressLabel = Key('lc.generation.progress.label');
  static const Key cancelGeneration = Key('lc.generation.cancel');
  static const Key generationInterrupted = Key('lc.generation.interrupted');
  static const Key generateAgain = Key('lc.generation.again');

  /// The result, and the things to do with it. The last of them keeps what
  /// produced it, and is absent on a build that keeps no setups.
  static const Key resultSaveSetup = Key('lc.result.setup');
  static const Key resultSurface = Key('lc.result');
  static const Key resultPreview = Key('lc.result.preview');

  /// The picture, almost full screen (T-0210): what a tap on the preview
  /// opens, the picture inside it, and the button that closes it.
  static const Key resultOpenViewer = Key('lc.result.open-viewer');
  static const Key resultViewer = Key('lc.result.viewer');
  static const Key resultViewerImage = Key('lc.result.viewer.image');
  static const Key resultViewerClose = Key('lc.result.viewer.close');

  /// A clip result that plays (T-0211): the frame, its three controls, the
  /// sentence when this phone cannot play it, and the clip in the viewer.
  static const Key resultClip = Key('lc.result.clip');
  static const Key resultClipPlayPause = Key('lc.result.clip.play-pause');
  static const Key resultClipSound = Key('lc.result.clip.sound');
  static const Key resultClipExpand = Key('lc.result.clip.expand');
  static const Key resultClipProblem = Key('lc.result.clip.problem');
  static const Key resultViewerClip = Key('lc.result.viewer.clip');
  static const Key resultProblem = Key('lc.result.problem');
  static const Key resultPlaceholder = Key('lc.result.placeholder');
  static const Key resultSave = Key('lc.result.save');
  static const Key resultShare = Key('lc.result.share');
  static const Key resultNotice = Key('lc.result.notice');

  /// The way back to a result from earlier in this session (T-0178). Absent
  /// whole until there is more than one to step between, rather than present
  /// with both arrows dead.
  static const Key resultHistory = Key('lc.result.history');
  static const Key resultPrevious = Key('lc.result.history.previous');
  static const Key resultNext = Key('lc.result.history.next');
  static const Key resultHistoryPosition = Key('lc.result.history.position');

  /// Reconnect: the subtle indicator, and the panel with the two decisions.
  static const Key reconnecting = Key('lc.reconnecting');
  static const Key recoveryPanel = Key('lc.recovery');
  static const Key reconnectNow = Key('lc.recovery.reconnect');
  static const Key chooseAnotherServer = Key('lc.recovery.choose-server');

  /// The workflow that was chosen and is no longer published.
  static const Key missingWorkflow = Key('lc.workflows.missing');

  /// One discovered server row.
  static Key discoveredServer(String id) => Key('lc.connect.server.$id');

  /// One workflow card in the picker.
  static Key workflowCard(String id) => Key('lc.workflows.card.$id');

  /// The help affordance on one picker card.
  static Key workflowCardHelp(String id) => Key('lc.workflows.card.$id.help');

  /// The bottom line of one picker card — the input summary beside the help
  /// affordance.
  ///
  /// It exists so an overflow can be attributed to *this* line by walking the
  /// render tree under it, rather than by reading an error's text or by
  /// finding the line by whichever layout widget currently draws it (T-0154).
  static Key workflowCardSummary(String id) =>
      Key('lc.workflows.card.$id.summary');

  /// One group heading in the picker. The name is whatever the registry said.
  static Key workflowGroup(String name) => Key('lc.workflows.group.$name');

  /// One group's option in the picker's filter. The name is whatever the
  /// registry said, the same way [workflowGroup] takes it.
  static Key workflowFilterGroup(String name) =>
      Key('lc.workflows.filter.group.$name');

  /// One group heading inside Advanced.
  static Key advancedGroup(String heading) =>
      Key('lc.form.advanced.group.$heading');

  /// One saved setup's row, and the three things to do with it. Keyed by the
  /// setup's id and never by its name: two setups may share a name, and a key
  /// that changed when a setup was renamed would say the opposite of what
  /// this store promises.
  static Key setup(String id) => Key('lc.form.setups.$id');
  static Key applySetup(String id) => Key('lc.form.setups.$id.apply');
  static Key renameSetup(String id) => Key('lc.form.setups.$id.rename');
  static Key deleteSetup(String id) => Key('lc.form.setups.$id.delete');

  /// The control for one field, and the row it sits in.
  static Key field(String id) => Key('lc.form.field.$id');
  static Key fieldRow(String id) => Key('lc.form.row.$id');

  /// The line above one field's control: its name, the requirement marker,
  /// and whatever small affordance sits at the far end of it.
  ///
  /// Keyed for the same reason [workflowCardSummary] is — so a test can ask
  /// *this* line whether anything on it ran past its edge, without knowing
  /// which layout widget draws it (T-0154).
  static Key fieldLabelRow(String id) => Key('lc.form.row.$id.label');

  /// The Random affordance a `role: seed` field offers.
  static Key fieldRandom(String id) => Key('lc.form.field.$id.random');

  /// Freeze seed, and the line under it that says what Generate Again will
  /// do. Both present only on a `role: seed` field.
  static Key freezeSeed(String id) => Key('lc.form.field.$id.freeze-seed');
  static Key freezeSeedNote(String id) =>
      Key('lc.form.field.$id.freeze-seed.note');

  /// The duration a `duration: {fps: N}` field's value reads as. Present only
  /// on a field whose workflow declared a rate, and only while the value is a
  /// number — never on any other field.
  static Key fieldDuration(String id) => Key('lc.form.field.$id.duration');

  /// The `RU → EN` indicator under one field, and the two texts behind it.
  /// The second exists only while the disclosure is open.
  static Key translation(String id) => Key('lc.form.field.$id.translation');
  static Key translationDetail(String id) =>
      Key('lc.form.field.$id.translation.detail');

  /// What the server said it will do with this field's text, *before* it is
  /// submitted, and the switch that turns it off for one generation. The
  /// switch is absent wherever turning it off would change nothing.
  static Key translationNotice(String id) =>
      Key('lc.form.field.$id.translation.notice');
  static Key translationOverride(String id) =>
      Key('lc.form.field.$id.translation.override');

  /// The affordances of one media field.
  static Key mediaChoose(String id) => Key('lc.form.field.$id.choose');
  static Key mediaReplace(String id) => Key('lc.form.field.$id.replace');
  static Key mediaRemove(String id) => Key('lc.form.field.$id.remove');
  static Key mediaRetry(String id) => Key('lc.form.field.$id.retry');
  static Key mediaPreview(String id) => Key('lc.form.field.$id.preview');
  static Key mediaProgress(String id) => Key('lc.form.field.$id.progress');
}
