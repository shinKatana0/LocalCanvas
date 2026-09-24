/// The form behind a workflow: the values a user has entered, what is still
/// missing, and the input map that comes out of it.
///
/// The map is keyed by field `id` and carries typed values, exactly as
/// `POST /api/v1/jobs` expects them (`docs/api.md`). Building it is where this
/// card stops; sending it is T-0007.
///
/// Two rules are enforced here rather than described:
///
/// * **Nothing is invented.** A field the user left alone and the registry
///   gave no default for is absent from the map, so the workflow keeps
///   whatever it already had. The app never guesses a value for a curator.
///   A value that arrives from My defaults is not a guess: the user chose it
///   here and asked for it to be kept (`workflow_settings_store.dart`). Nor is
///   one that arrives from the current draft — that is the value they left in
///   the field (`workflow_draft_store.dart`) — nor one from a saved setup,
///   which they named and asked for back (`workflow_setup_store.dart`).
/// * **`role` and `pair` are not consulted by validation or by the input
///   map.** They are hints; the map this form produces is identical with and
///   without them. `role: seed` decides exactly one thing here — which field
///   [WorkflowFormController.varySeed] writes a new number into when Generate
///   Again asks for one — and that is a value the user could equally have
///   typed themselves. Strip every hint from a schema and the form still
///   validates the same fields and sends the same map.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import '../media/clip_inspector.dart';
import '../media/media_field_controller.dart';
import '../media/media_picker.dart';
import '../media/media_selection.dart';
import 'workflow_draft_store.dart';
import 'workflow_models.dart';
import 'workflow_settings_store.dart';
import 'workflow_setup_store.dart';

/// Why one field is not ready.
enum FieldIssueKind {
  /// Required, and nothing has been entered.
  missing,

  /// Something was typed that is not a number of the declared kind.
  notANumber,

  /// A number outside the range the registry declared.
  outOfRange,

  /// A picture or a clip that has been chosen but is not on the gateway yet —
  /// still uploading, or an upload that did not finish. Distinct from
  /// [missing], because the user has already answered the question and the
  /// sentence they need is a different one.
  mediaNotReady,

  /// A required picture or clip on a build with no picker behind it. Said out
  /// loud rather than offered as a control that does nothing.
  notSelectableYet,

  /// A field type this version of the app does not know how to show.
  unsupportedType,
}

/// One field that is not ready, and everything needed to say why.
///
/// It carries facts, never a sentence (T-0142): the kind, the field's own
/// label, and — for the two kinds that need more — the declared range or the
/// upload failure. [message] turns them into words in the language on screen.
@immutable
class FieldIssue {
  const FieldIssue({
    required this.fieldId,
    required this.label,
    required this.kind,
    this.field,
    this.mediaFailure,
  });

  final String fieldId;
  final String label;
  final FieldIssueKind kind;

  /// The field itself, for the one kind whose sentence names its declared
  /// range. `null` everywhere else.
  final WorkflowField? field;

  /// Why the upload did not land, for [FieldIssueKind.mediaNotReady] after a
  /// failure. `null` while one is merely still going.
  final MediaFailure? mediaFailure;

  /// One sentence, in the user's words. No exception text, no status code.
  String message(L l) {
    switch (kind) {
      case FieldIssueKind.missing:
        return l.issueMissing(label);
      case FieldIssueKind.notANumber:
        return field?.type == FieldType.integer
            ? l.issueNotAWholeNumber(label)
            : l.issueNotANumber(label);
      case FieldIssueKind.outOfRange:
        return l.issueOutOfRange(label, describeRange(l, field!));
      case FieldIssueKind.mediaNotReady:
        final failure = mediaFailure;
        return failure == null
            ? l.issueMediaUploading(label)
            : l.issueMediaFailed(label, failure.message(l));
      case FieldIssueKind.notSelectableYet:
        return l.issueNotSelectableYet(label);
      case FieldIssueKind.unsupportedType:
        return l.issueUnsupportedType(label);
    }
  }
}

/// The form, resolved: what would be sent, and what stands in the way.
@immutable
class ValidatedForm {
  const ValidatedForm({required this.inputs, required this.issues});

  /// Field id to typed value, in the order the registry declared the fields.
  final Map<String, Object?> inputs;

  final List<FieldIssue> issues;

  /// Whether Generate can run.
  bool get isReady => issues.isEmpty;

  FieldIssue? issueFor(String fieldId) {
    for (final issue in issues) {
      if (issue.fieldId == fieldId) return issue;
    }
    return null;
  }

  /// Why Generate is unavailable, or `null` when it is available.
  ///
  /// Generate never simply greys out: `docs/ui-ux.md` asks it to say what is
  /// still needed, and this is that sentence.
  String? blockedReason(L l) {
    if (issues.isEmpty) return null;
    // A value that is wrong, or one that is on its way, is more urgent than a
    // value that is absent — and its own message is more specific than any
    // list of names could be.
    for (final issue in issues) {
      if (issue.kind == FieldIssueKind.notANumber ||
          issue.kind == FieldIssueKind.outOfRange ||
          issue.kind == FieldIssueKind.mediaNotReady) {
        return issue.message(l);
      }
    }
    final names = issues.map((issue) => issue.label).toList(growable: false);
    final sentences = <String>[l.generateNeeds(_join(l, names))];
    if (issues.any((i) => i.kind == FieldIssueKind.notSelectableYet)) {
      sentences.add(l.generateBlockedNotSelectable);
    }
    if (issues.any((i) => i.kind == FieldIssueKind.unsupportedType)) {
      sentences.add(l.generateBlockedUnsupported);
    }
    return sentences.join(' ');
  }

  static String _join(L l, List<String> names) {
    if (names.length == 1) return names.single;
    if (names.length == 2) return l.listAnd(names[0], names[1]);
    return l.listAnd(
      names.sublist(0, names.length - 1).join(l.listSeparator),
      names.last,
    );
  }
}

/// One workflow's form. Flutter's own [ChangeNotifier] and nothing else.
///
/// The shell keeps one of these per workflow, which is why a prompt survives
/// a fold, a trip to the picker, and a change of mind about which workflow to
/// run.
class WorkflowFormController extends ChangeNotifier {
  WorkflowFormController(
    this.detail, {
    MediaPicker? picker,
    MediaUploadRunner? uploader,
    ClipInspector? inspector,
    WorkflowFormController? takingMediaFrom,
  }) {
    final handed = <MediaFieldController>{};
    for (final field in detail.inputs) {
      if (!field.type.isMedia) continue;
      final kind = field.type == FieldType.video
          ? MediaKind.video
          : MediaKind.image;
      final taken = takingMediaFrom?._handOver(field.id, kind);
      final media =
          taken ??
          MediaFieldController(
            kind: kind,
            picker: picker,
            uploader: uploader,
            inspector: inspector,
          );
      if (taken != null) handed.add(taken);
      // One notifier out of the form, whatever moves inside it: a widget
      // listening to the form redraws when an upload advances, without
      // knowing that media has controllers of its own.
      media.addListener(notifyListeners);
      _media[field.id] = media;
    }
    _seedEveryField(keeping: handed);
  }

  final WorkflowDetail detail;

  /// One per media field, created for every one the schema declares. A field
  /// whose build has no picker still gets a controller — it simply answers
  /// `canChoose` false, which is how the "stated, not faked" panel is chosen
  /// over a control that could not honour a tap.
  final Map<String, MediaFieldController> _media =
      <String, MediaFieldController>{};

  /// The media state for one field, or `null` when the field is not media.
  MediaFieldController? media(String fieldId) => _media[fieldId];

  /// Gives [fieldId]'s media controller to a form built for a changed schema
  /// (T-0236), or `null` where this form has none of [kind] for that id.
  ///
  /// The controller itself moves, not a copy of its state: a picture still
  /// uploading keeps uploading and lands in the new form, because the upload
  /// was started by this very object. From here on it belongs to the taker —
  /// this form stops listening to it and will not dispose it. A field whose
  /// kind changed is not handed over, and goes when this form is disposed.
  MediaFieldController? _handOver(String fieldId, MediaKind kind) {
    final media = _media[fieldId];
    if (media == null || media.kind != kind) return null;
    _media.remove(fieldId);
    media.removeListener(notifyListeners);
    return media;
  }

  /// Re-checks every chosen file and drops the ones that are gone.
  ///
  /// Called when state is restored — after a reconnect, in particular
  /// (`docs/recovery.md`). A selection whose Android permission has lapsed
  /// leaves the field empty with its requirement showing, here, instead of
  /// becoming an upload failure after the user presses Generate.
  ///
  /// **It awaits inside the loop, so every step of it is a window** (T-0313).
  /// [_media] has exactly two writers that can run in one — [_handOver], which
  /// a form built for a changed schema calls on the form it replaces, and
  /// [dispose], which clears the map — and both were reached on a CI runner
  /// while a check was still out on `File.exists`, which threw
  /// `Concurrent modification during iteration`. On a phone that is a crash in
  /// the middle of a generation. Two things make the traversal safe by
  /// construction, and they answer two different questions:
  ///
  /// * the iteration is over a **snapshot**, so mutating the map underneath it
  ///   cannot throw whatever else changes;
  /// * each controller is re-checked against the map **after** the await that
  ///   precedes it, and one this form no longer holds is skipped.
  ///
  /// The second is the ownership answer, and it is deliberate rather than
  /// defensive. A controller handed to the replacement form belongs to that
  /// form: the object moved, this form has already stopped listening to it and
  /// will not dispose it. Going on to restore it would not merely be a
  /// harmless double check — [MediaFieldController.restoreSelection] can
  /// **remove** the selection, and by the time a stale loop resumes the
  /// current selection may be one the user made in the new form, against a
  /// schema this form never knew. The identity guard inside `restoreSelection`
  /// stops that answer being written over a *different* selection, but nothing
  /// stops this form deciding, on the new owner's behalf, that the file is
  /// gone. That decision belongs to whoever owns the controller now, and
  /// nothing is lost by declining it: the form that took the controller runs
  /// its own restore over it immediately (`workflows_controller.dart`,
  /// `_replaceForm`). The same guard covers [dispose] without a second rule —
  /// a disposed form holds nothing, so it checks nothing.
  Future<void> restoreMediaSelections() async {
    for (final entry in _media.entries.toList(growable: false)) {
      if (!identical(_media[entry.key], entry.value)) continue;
      await entry.value.restoreSelection();
    }
  }

  /// Raw entries. Text and numbers are held as the user's own text so that a
  /// half-typed number is still a half-typed number; everything else is held
  /// as its own type.
  final Map<String, Object?> _entries = <String, Object?>{};

  /// Whether the Advanced section is open. Held here so it survives a fold.
  bool _advancedOpen = false;

  bool get advancedOpen => _advancedOpen;

  set advancedOpen(bool value) {
    if (_advancedOpen == value) return;
    _advancedOpen = value;
    notifyListeners();
  }

  /// Every field the registry marked `role: seed`, in declaration order.
  ///
  /// Empty for a workflow that declared none — which is most of the reason
  /// this is a list and not an assumption: nothing below may require a
  /// workflow to have a seed, and a workflow with two of them must not have
  /// one of them silently left behind.
  List<WorkflowField> get seedFields => <WorkflowField>[
    for (final field in detail.inputs)
      if (field.role == FieldRole.seed) field,
  ];

  /// Whether this workflow has anything a seed could be varied in.
  bool get hasSeedField => seedFields.isNotEmpty;

  bool _freezeSeed = false;

  /// Whether Generate Again reuses the seed on screen instead of varying it.
  ///
  /// **Off by default**, and the whole of what it changes is one button's
  /// meaning. On, Generate Again reproduces the picture exactly, which is what
  /// this app did before there was a switch to say so.
  ///
  /// It belongs to the workflow rather than to one field: a workflow that
  /// declares two seeds has one answer to "reproduce this exactly", not two.
  /// It travels with the current draft, beside the translation override and
  /// for the same reason — it is a choice about the next submission and not a
  /// value any field could hold ([currentDraft]).
  bool get freezeSeed => _freezeSeed;

  set freezeSeed(bool value) {
    if (_freezeSeed == value) return;
    _freezeSeed = value;
    notifyListeners();
  }

  /// Puts a new random number in every seed field — what Generate Again does.
  ///
  /// Three things it deliberately does **not** do:
  ///
  /// * it changes nothing else. Every other value in the form is left exactly
  ///   as the user left it, so Generate Again resubmits their work and varies
  ///   one number in it;
  /// * it does nothing at all while [freezeSeed] is on, and nothing at all for
  ///   a workflow that declared no seed — that workflow behaves exactly as it
  ///   did before this existed;
  /// * it never varies anything on its own. The first Generate uses whatever
  ///   the field holds, curated default or typed number, because nothing calls
  ///   this before a generation has been asked for a second time.
  ///
  /// The new number lands **in the field**, which is what keeps the result
  /// reproducible: the seed on screen is the seed that will be sent, and
  /// someone who likes what comes back can read it and freeze it.
  void varySeed() {
    if (_freezeSeed) return;
    for (final field in seedFields) {
      final current = int.tryParse(text(field.id).trim());
      setNumber(field, randomSeedValue(field, avoid: current));
    }
  }

  bool _translatePrompt = true;

  /// Whether this workflow's next submission may be translated
  /// (`docs/api.md`). The user's choice for this workflow, in this session.
  ///
  /// **True is not a promise that anything will be translated.** It is the
  /// absence of an override: what happens is still the PC's decision and the
  /// workflow's, and turning this off is the only thing a client can say about
  /// the stage at all — there is no way to switch it on from here.
  ///
  /// It is still not a **field**: [keepableValues] never carries it and
  /// [draftableValues] never carries it, because a workflow that happened to
  /// declare a field of that name would collide with it. It travels beside
  /// the values — in the draft as [currentDraft], and durably in My defaults
  /// as [durableTranslatePrompt] — which is what `docs/api.md` means by
  /// "remembering the choice is the client's job".
  ///
  /// A remembered "off" is still only the user's refusal of a stage; whether
  /// that stage exists at all remains the PC's answer, read from the handshake
  /// and never from here, so nothing restored into this flag can turn into a
  /// claim that the app can translate.
  bool get translatePrompt => _translatePrompt;

  set translatePrompt(bool value) {
    if (_translatePrompt == value) return;
    _translatePrompt = value;
    notifyListeners();
  }

  bool _durableTranslate = true;

  /// What My defaults say about translating this workflow — the durable
  /// answer, as opposed to [translatePrompt], which is what is in force right
  /// now.
  ///
  /// `true` is the absence of a saved override, which is what every workflow
  /// starts as. The two are separate because the two resets have to be able to
  /// disagree with each other: one goes back to this, the other goes back to
  /// the workflow's own policy and leaves this exactly where it is.
  bool get durableTranslatePrompt => _durableTranslate;

  /// The user's own defaults for this workflow, already checked against the
  /// schema and held in the form's own notation — so that laying them over the
  /// curator's is a copy, not a second round of parsing.
  ///
  /// Only fields [isSafeToKeep] accepts can be in here, whatever the store
  /// happens to hold: a prompt or a media reference someone wrote into the
  /// preferences by hand still never reaches a field.
  Map<String, Object?> _myDefaults = const <String, Object?>{};

  /// Whether anything the user saved still applies to this workflow.
  ///
  /// False for a workflow that was never saved, and false for one whose saved
  /// values the schema has since outgrown — there is nothing to go back to in
  /// either case, and an affordance offering it would do nothing.
  ///
  /// A saved refusal to translate counts, on its own and with no values beside
  /// it. It is one of My defaults like any other, and the way back to it has
  /// to be on screen for the same reason every other one's is: after a reset
  /// to the workflow's own policy, "Reset settings to my defaults" is the
  /// visible undo.
  bool get hasMyDefaults => _myDefaults.isNotEmpty || !_durableTranslate;

  /// Every field as the registry declared it, prose and media included.
  ///
  /// The state a form is born in, and nothing a user can press. The two resets
  /// below are a different operation on purpose: they are about settings, and
  /// deliberately do not share this one's name.
  void _seedEveryField({Set<MediaFieldController> keeping = const {}}) {
    _entries.clear();
    for (final field in detail.inputs) {
      _entries[field.id] = _seed(field);
    }
    for (final media in _media.values) {
      // A controller handed over from the form this one replaces carries the
      // user's choice, which is not the registry's to seed.
      if (keeping.contains(media)) continue;
      media.remove();
    }
    notifyListeners();
  }

  /// Puts the settings — and only the settings — back to what the registry
  /// declared.
  ///
  /// "Settings" is exactly the set [isSafeToKeep] admits, which is the set My
  /// defaults is made of: the button writes back what its own row is about. A
  /// prompt being typed and a picture already uploaded are not settings and
  /// are not touched by either reset. Losing them would be the work of the
  /// last ten minutes, gone one tap from Generate, with nothing to undo it —
  /// and a user who wants an empty prompt has a text field and a keyboard.
  ///
  /// What the user saved is untouched by this too, and
  /// [resetSettingsToMyDefaults] brings it back.
  ///
  /// The translation policy comes back with it, and the same way: what is in
  /// force returns to the **workflow's own**, which from a client is the
  /// absence of an override (`docs/api.md` — there is no `on` to send, so
  /// asking for nothing is exactly "whatever this PC and this workflow already
  /// decided"). The durable answer in My defaults is not erased, because no
  /// other saved default is erased here either; [durableTranslatePrompt] still
  /// holds it and [resetSettingsToMyDefaults] still brings it back. Nothing is
  /// hidden by that: what is in force is what the switch beside the prompt
  /// shows, so the policy this leaves behind is on screen the moment this
  /// returns.
  void resetSettingsToWorkflowDefaults() {
    for (final field in detail.inputs) {
      if (!isSafeToKeep(field)) continue;
      _entries[field.id] = _seed(field);
    }
    _translatePrompt = true;
    notifyListeners();
  }

  /// The curator's settings with the user's own laid over them. Prose and
  /// media are left alone here as well, so the two buttons are a symmetric
  /// pair a user can predict.
  ///
  /// The saved translation answer is one of the user's own and comes back with
  /// them.
  void resetSettingsToMyDefaults() {
    resetSettingsToWorkflowDefaults();
    _entries.addAll(_myDefaults);
    _translatePrompt = _durableTranslate;
    notifyListeners();
  }

  /// Takes [stored] as the user's defaults and lays them over the form.
  ///
  /// Everything the workflow can no longer honour is dropped here rather than
  /// loaded into a form that could not validate: a field it no longer
  /// declares, a value of the wrong kind, a number outside a range that has
  /// since changed, an option that is gone. A field with nothing stored for it
  /// keeps exactly what the registry declared.
  ///
  /// Only the fields it has values for are touched — a prompt being typed and
  /// a picture already chosen stay where they are.
  void adoptMyDefaults(Map<String, Object?> stored) {
    noteMyDefaults(stored);
    _entries.addAll(_myDefaults);
    notifyListeners();
  }

  /// Takes [stored] as the user's defaults and lays them over **nothing**.
  ///
  /// The same checks and the same result as [adoptMyDefaults], minus the one
  /// thing that touches the form. It exists for the moment an import lands
  /// while a workflow is open: what the user is looking at is theirs, and
  /// rewriting the number in front of them because a file arrived would be the
  /// app changing their work without being asked. What it does change is that
  /// there is now something to go back **to** — [hasMyDefaults] says so, and
  /// [resetSettingsToMyDefaults] brings it in when the user asks.
  void noteMyDefaults(Map<String, Object?> stored) {
    final adopted = <String, Object?>{};
    for (final field in detail.inputs) {
      if (!stored.containsKey(field.id)) continue;
      final entry = _entryFor(field, stored[field.id]);
      if (entry == null) continue;
      adopted[field.id] = entry;
    }
    _myDefaults = adopted;
    notifyListeners();
  }

  /// Takes the durable answer about translation as one of My defaults, and
  /// puts it in force.
  ///
  /// Called where [adoptMyDefaults] is: opening a workflow applies what the
  /// user asked this device to remember, and this is one of the things they
  /// asked it to remember. It is not a bug that it comes back — a saved
  /// default that did not come back on the next launch would be the bug.
  void adoptTranslateDefault(bool translatePrompt) {
    _durableTranslate = translatePrompt;
    _translatePrompt = translatePrompt;
    notifyListeners();
  }

  /// Records the durable answer without putting it in force, for the same
  /// reason [noteMyDefaults] exists.
  void noteTranslateDefault(bool translatePrompt) {
    if (_durableTranslate == translatePrompt) return;
    _durableTranslate = translatePrompt;
    notifyListeners();
  }

  /// Takes [draft] as what the user was in the middle of and lays it over the
  /// form.
  ///
  /// The last of the three layers `docs/ui-ux.md`'s form stands on: the
  /// curator's defaults, then the user's own, then this. A field the draft has
  /// no value for keeps whatever the layer beneath gave it, which is why this
  /// touches only the fields it has values for.
  ///
  /// It is checked exactly as [adoptMyDefaults] is, through the same
  /// [_entryFor]: a value of the wrong kind, a number outside a range that has
  /// since changed, an option that is gone and a field the workflow no longer
  /// declares are all dropped in favour of the layer beneath, rather than
  /// loaded into a form that could not validate. Prose has neither a range nor
  /// options, so for prose that check is the kind and nothing else — and an
  /// empty string is a value, not a missing one: the user emptied the field.
  ///
  /// A draft is not one of My defaults and does not become one: [hasMyDefaults]
  /// is untouched here, and [resetSettingsToMyDefaults] still goes back to what
  /// was saved rather than to what was being typed.
  /// The draft's translation answer is laid over the durable one the same
  /// way its values are laid over the saved ones — and, like them, only where
  /// it has something to say. A draft carries a **refusal and never a
  /// permission**: `off` is stored and `auto` is its absence, in this store
  /// and in My defaults alike, so a draft that says nothing leaves the durable
  /// answer standing instead of quietly switching the stage back on for a
  /// workflow the user had switched it off for.
  void adoptDraft(WorkflowDraft draft) {
    _adoptDraftable(draft.values);
    if (!draft.translatePrompt) _translatePrompt = false;
    // Nothing beneath a draft has an opinion about freezing, so this is the
    // whole answer rather than an override laid over one: what the user left
    // frozen opens frozen, and navigating away and back does not quietly
    // unfreeze it.
    _freezeSeed = draft.freezeSeed;
    notifyListeners();
  }

  /// Puts a saved setup back into the form.
  ///
  /// The same operation as [adoptDraft] over the same content — a setup and a
  /// draft hold exactly what [isDraftable] admits — so it goes through the
  /// same checks, written once in [_adoptDraftable] rather than twice: a
  /// value of the wrong kind, a number outside a range the curator has since
  /// changed, an option that is gone and a field the workflow no longer
  /// declares are all skipped in favour of what the form already had, instead
  /// of being loaded into a form that could not validate. A field the setup
  /// says nothing about keeps what it has, which is how a field added since
  /// the setup was saved arrives at the current default.
  ///
  /// What it does **not** carry is the translation override: that is a choice
  /// about what the gateway may do to the next submission (`docs/api.md`),
  /// travelling with the session and the draft, and not one of the things a
  /// user names and comes back to.
  void adoptSetup(WorkflowSetup setup) {
    _adoptDraftable(setup.values);
    notifyListeners();
  }

  /// Whether [adoptSetup] would take away prose the user has written.
  ///
  /// The question asked before a setup replaces text nobody can get back —
  /// there is no undo anywhere in this app — and it is answered **here**,
  /// beside the method that does the replacing and through the same
  /// [_draftableEntry], so that "what a setup would replace" and "what a
  /// setup does replace" cannot become two different sentences. A widget that
  /// held its own copy of the admission rules would drift from them the first
  /// time they changed.
  ///
  /// True when at least one prose field holds text the setup would write
  /// something **different** over. Text is measured the way the rest of this
  /// form measures it, so whitespace alone is not text worth protecting —
  /// `validate()` already calls it missing.
  ///
  /// Three consequences, and not one of them is a special case:
  ///
  /// * applying onto a form whose prose is empty has nothing to lose, so it
  ///   asks nothing — the common flow stays one tap;
  /// * a setup whose prose is already what is on screen would replace nothing,
  ///   so it asks nothing either;
  /// * a setup saved while the prompt was empty carries `''`, which is a value
  ///   and not a missing one, so applying it over typed prose **does** ask.
  ///   That falls out of the one rule above rather than out of a branch
  ///   written for it.
  bool setupWouldReplaceProse(WorkflowSetup setup) {
    for (final field in detail.inputs) {
      if (!isProse(field)) continue;
      if (!setup.values.containsKey(field.id)) continue;
      final entry = _draftableEntry(field, setup.values[field.id]);
      // Nothing this workflow can hold, so nothing would be written and
      // nothing is at risk.
      if (entry == null) continue;
      final current = text(field.id);
      if (current.trim().isEmpty) continue;
      if (entry == current) continue;
      return true;
    }
    return false;
  }

  /// Lays [values] over the form, keeping only what this workflow can still
  /// hold.
  void _adoptDraftable(Map<String, Object?> values) {
    for (final field in detail.inputs) {
      if (!values.containsKey(field.id)) continue;
      final entry = _draftableEntry(field, values[field.id]);
      if (entry == null) continue;
      _entries[field.id] = entry;
    }
  }

  /// What [value] would put in [field], or `null` where this workflow cannot
  /// hold it.
  ///
  /// The admission rules themselves, written once: prose has neither a range
  /// nor options, so for prose the check is the kind and nothing else — and an
  /// empty string is a value, not a missing one. Everything else goes through
  /// [_entryFor], which drops a value of the wrong kind, a number outside a
  /// range the curator has since changed, and an option that is gone.
  ///
  /// [_adoptDraftable] writes what this admits; [setupWouldReplaceProse] asks
  /// it what would be written. One function, so there is one answer.
  Object? _draftableEntry(WorkflowField field, Object? value) => isProse(field)
      ? (value is String ? value : null)
      : _entryFor(field, value);

  /// The fields a draft covers, whether or not one has a value right now. The
  /// scope of a draft save: what is on screen is written for every one of
  /// them, so a prompt the user emptied is emptied in the draft too instead of
  /// coming back on the next launch.
  ///
  /// Media is not in here, and that is the first of the two things that keep a
  /// reference to an uploaded file out of the store — the second being that
  /// the store cannot write one (`workflow_draft_store.dart`).
  Set<String> get draftableFieldIds => <String>{
    for (final field in detail.inputs)
      if (isDraftable(field)) field.id,
  };

  /// What is in the form right now, as a draft: [draftableValues] plus the
  /// one thing a draft carries that a setup does not — the user's answer
  /// about translating this workflow's next submission.
  WorkflowDraft currentDraft() => WorkflowDraft(
    values: draftableValues(),
    translatePrompt: _translatePrompt,
    freezeSeed: _freezeSeed,
  );

  /// What is in the form right now, of everything [isDraftable] admits.
  ///
  /// The content of a draft and the content of a saved setup, built once:
  /// they hold the same thing and must not be able to disagree about what
  /// that is.
  ///
  /// Prose is taken as the user's own text, character for character — this is
  /// the **original** and there is no other candidate: the effective text of a
  /// translated submission is held beside the generation that produced it and
  /// is never written back into a form (`docs/api.md`,
  /// `generation/translation.dart`).
  ///
  /// Everything else is taken from the validated input map, so a half-typed
  /// number is not written down as a value nobody could generate with — the
  /// same rule [keepableValues] follows, for the same reason. A media field
  /// is in neither branch, which is the first of the two things that keep a
  /// reference to an uploaded file out of a store.
  Map<String, Object?> draftableValues() {
    final validated = validate();
    return <String, Object?>{
      for (final field in detail.inputs)
        if (isProse(field))
          field.id: text(field.id)
        else if (isSafeToKeep(field) && validated.inputs.containsKey(field.id))
          field.id: validated.inputs[field.id],
    };
  }

  /// The fields whose values may be kept, whether or not one is set right
  /// now. The scope of a save: what is on screen is written for every one of
  /// them, so clearing a value unsets the default rather than leaving the old
  /// one behind.
  Set<String> get keepableFieldIds => <String>{
    for (final field in detail.inputs)
      if (isSafeToKeep(field)) field.id,
  };

  /// What is in the form right now and may be kept as My defaults.
  ///
  /// Built from the validated input map, so a half-typed number is not saved
  /// as a default nobody could generate with, and filtered by
  /// [isSafeToKeep] — which is the one rule about what may be persisted.
  Map<String, Object?> keepableValues() {
    final validated = validate();
    return <String, Object?>{
      for (final field in detail.inputs)
        if (isSafeToKeep(field) && validated.inputs.containsKey(field.id))
          field.id: validated.inputs[field.id],
    };
  }

  /// One stored value as this form would hold it, or `null` when the field
  /// cannot take it.
  Object? _entryFor(WorkflowField field, Object? value) {
    if (!isSafeToKeep(field)) return null;
    switch (field.type) {
      case FieldType.integer:
        if (value is! int) return null;
        return _rangeIssue(field, value) == null
            ? formatNumber(field, value)
            : null;
      case FieldType.float:
        if (value is! num || !value.toDouble().isFinite) return null;
        return _rangeIssue(field, value) == null
            ? formatNumber(field, value)
            : null;
      case FieldType.boolean:
        return value is bool ? value : null;
      case FieldType.select:
        for (final option in field.options) {
          if (option.value == value) return option.value;
        }
        return null;
      case FieldType.string:
      case FieldType.multiline:
      case FieldType.image:
      case FieldType.video:
      case FieldType.unsupported:
        return null;
    }
  }

  @override
  void dispose() {
    for (final media in _media.values) {
      media.removeListener(notifyListeners);
      media.dispose();
    }
    _media.clear();
    super.dispose();
  }

  /// The current entry for a field: [String] for text and numbers, [bool] for
  /// a switch, the option's own value for a selector, `null` for a field this
  /// build cannot fill.
  Object? entry(String fieldId) => _entries[fieldId];

  String text(String fieldId) {
    final value = _entries[fieldId];
    return value is String ? value : '';
  }

  bool flag(String fieldId) => _entries[fieldId] == true;

  void setEntry(String fieldId, Object? value) {
    if (_entries[fieldId] == value) return;
    _entries[fieldId] = value;
    notifyListeners();
  }

  /// Writes a number into a numeric field, in the field's own notation.
  void setNumber(WorkflowField field, num value) =>
      setEntry(field.id, formatNumber(field, value));

  /// Validates every field and builds the input map.
  ValidatedForm validate() {
    final inputs = <String, Object?>{};
    final issues = <FieldIssue>[];
    for (final field in detail.inputs) {
      _validateField(field, inputs, issues);
    }
    return ValidatedForm(inputs: inputs, issues: issues);
  }

  void _validateField(
    WorkflowField field,
    Map<String, Object?> inputs,
    List<FieldIssue> issues,
  ) {
    switch (field.type) {
      case FieldType.string:
      case FieldType.multiline:
        final value = text(field.id);
        if (value.trim().isEmpty) {
          if (field.required) {
            issues.add(_missing(field));
          } else if (field.hasDefault) {
            // The registry said what an empty one means; keep saying it.
            inputs[field.id] = value;
          }
          return;
        }
        inputs[field.id] = value;

      case FieldType.integer:
      case FieldType.float:
        final raw = text(field.id).trim();
        if (raw.isEmpty) {
          if (field.required) issues.add(_missing(field));
          return;
        }
        final num? parsed = field.type == FieldType.integer
            ? int.tryParse(raw)
            : double.tryParse(raw);
        if (parsed == null || (parsed is double && !parsed.isFinite)) {
          issues.add(
            FieldIssue(
              fieldId: field.id,
              label: field.label,
              kind: FieldIssueKind.notANumber,
              field: field,
            ),
          );
          return;
        }
        final range = _rangeIssue(field, parsed);
        if (range != null) {
          issues.add(range);
          return;
        }
        inputs[field.id] = parsed;

      case FieldType.boolean:
        inputs[field.id] = flag(field.id);

      case FieldType.select:
        final value = _entries[field.id];
        if (value == null) {
          if (field.required) issues.add(_missing(field));
          return;
        }
        inputs[field.id] = value;

      case FieldType.image:
      case FieldType.video:
        final media = _media[field.id];
        if (media == null || !media.canChoose) {
          // No picker behind this build. An optional media field is simply
          // left out; a required one is the honest reason Generate is
          // unavailable, rather than a control that pretends to work.
          if (!field.required) return;
          issues.add(
            FieldIssue(
              fieldId: field.id,
              label: field.label,
              kind: FieldIssueKind.notSelectableYet,
              field: field,
            ),
          );
          return;
        }
        switch (media.phase) {
          case MediaPhase.ready:
            // The one shape `POST /api/v1/jobs` takes for a media field
            // (`docs/api.md`). What the gateway turns it into is the gateway's
            // business and the app never learns it.
            inputs[field.id] = <String, Object?>{'media_id': media.mediaId};
          case MediaPhase.empty:
            // Nothing chosen. An optional field is left out entirely rather
            // than sent as null, so the workflow keeps whatever it had.
            if (field.required) issues.add(_missing(field));
          case MediaPhase.uploading:
            // Chosen, and still going. Blocking even an optional field is the
            // point: silently dropping a picture the user chose would run the
            // workflow without it and never say so.
            issues.add(
              FieldIssue(
                fieldId: field.id,
                label: field.label,
                kind: FieldIssueKind.mediaNotReady,
                field: field,
              ),
            );
          case MediaPhase.failed:
            issues.add(
              FieldIssue(
                fieldId: field.id,
                label: field.label,
                kind: FieldIssueKind.mediaNotReady,
                field: field,
                // The upload's own failure, carried rather than rendered:
                // what it reads as is decided where it is drawn, and a
                // refusal the gateway gave a code for reads in the language
                // on screen (T-0142). `null` never reaches here — this is
                // the failed branch — but the fallback is the ordinary
                // "still going" sentence rather than an invented one.
                mediaFailure: media.failure,
              ),
            );
        }

      case FieldType.unsupported:
        if (!field.required) return;
        issues.add(
          FieldIssue(
            fieldId: field.id,
            label: field.label,
            kind: FieldIssueKind.unsupportedType,
            field: field,
          ),
        );
    }
  }

  FieldIssue _missing(WorkflowField field) => FieldIssue(
    fieldId: field.id,
    label: field.label,
    kind: FieldIssueKind.missing,
    field: field,
  );

  FieldIssue? _rangeIssue(WorkflowField field, num value) {
    final min = field.min;
    final max = field.max;
    if (min != null && value < min) return _outOfRange(field);
    if (max != null && value > max) return _outOfRange(field);
    return null;
  }

  FieldIssue _outOfRange(WorkflowField field) => FieldIssue(
    fieldId: field.id,
    label: field.label,
    kind: FieldIssueKind.outOfRange,
    field: field,
  );

  Object? _seed(WorkflowField field) {
    switch (field.type) {
      case FieldType.string:
      case FieldType.multiline:
        final value = field.defaultValue;
        return value is String ? value : '';
      case FieldType.integer:
      case FieldType.float:
        final value = field.defaultValue;
        return value is num ? formatNumber(field, value) : '';
      case FieldType.boolean:
        return field.defaultValue == true;
      case FieldType.select:
        final value = field.defaultValue;
        for (final option in field.options) {
          if (option.value == value) return option.value;
        }
        return null;
      case FieldType.image:
      case FieldType.video:
      case FieldType.unsupported:
        return null;
    }
  }
}

/// The one thing a user can do to keep a piece of text out of a translator's
/// reach (`docs/api.md`: double-quoted literals are copied through with their
/// quote characters, in any language).
///
/// The quotes in it are the plain `"` the gateway actually parses, not the
/// typographic pair — the hint would otherwise name a character that does
/// nothing. **That holds in every locale**, which is why the Russian sentence
/// keeps `"` rather than the guillemets Russian typography would otherwise
/// call for: a hint that told a Russian user to type «...» would be telling
/// them to do something the gateway does not honour (T-0142).

/// The field the quote hint is attached to, or `null` for a workflow with no
/// text field at all.
///
/// **One hint per form.** A workflow with three text inputs gets it once,
/// rather than three times, which would turn a hint into a banner.
///
/// Which one is decided from the schema and nothing else. The app cannot know
/// which fields the curator marked translatable — that is a gateway-side
/// decision, deliberately absent from the field schema the app receives
/// (`docs/workflow-schema.md`) — and it must not start guessing from a field
/// id either, because `prompt` is a name a curator happens to use and not
/// something this app is entitled to rely on. So: the first `multiline` field,
/// which is the prose control of every workflow that has one, and a plain
/// `string` only where there is no multiline at all. Main before advanced, so
/// the hint is not hidden behind a collapsed section while a visible text
/// field goes without it.
String? quoteHintFieldId(WorkflowDetail detail) {
  final ordered = <WorkflowField>[
    ...detail.mainFields,
    ...detail.advancedFields,
  ];
  for (final field in ordered) {
    if (field.type == FieldType.multiline) return field.id;
  }
  for (final field in ordered) {
    if (field.type == FieldType.string) return field.id;
  }
  return null;
}

/// A fresh value for a seed field, inside whatever range it declared.
///
/// The ceiling keeps the number inside what a 32-bit seed input accepts even
/// where a definition declares no maximum.
///
/// [avoid] is the value the field holds now, and the result is never equal to
/// it wherever the range has room for another number. That is not a
/// statistical nicety: a Generate Again that happened to roll the seed it
/// already had would produce the same picture and read as a broken button,
/// and a test could not tell that case from the button doing nothing. The
/// Random affordance beside a seed passes none, and keeps the plain draw it
/// has always made.
int randomSeedValue(WorkflowField field, {int? avoid, math.Random? random}) {
  const int ceiling = 4294967295;
  final min = (field.min ?? 0).round();
  final max = math.min((field.max ?? ceiling).round(), ceiling);
  if (max <= min) return min;
  final span = max - min;
  // `nextInt` is bounded at 2^32; the span above never exceeds it.
  final drawn =
      min +
      (random ?? math.Random()).nextInt(
        span >= 0x100000000 ? 0xFFFFFFFF : span + 1,
      );
  if (drawn != avoid) return drawn;
  // Stepped rather than drawn again: a range of two numbers would go on
  // landing on the same one, and a retry loop has no bound that is both short
  // and certain.
  return drawn < max ? drawn + 1 : min;
}

/// A number in the notation its field uses: whole for an integer, and no more
/// decimals than the declared `step` can distinguish.
///
/// Sliders produce values like `0.35000000000000003`, and a curator's default
/// of `0.125` must survive being shown. Rounding to the step's own precision
/// handles the first without damaging the second, and a field with no step is
/// shown at the shortest precision that still reads back as the same number.
String formatNumber(WorkflowField field, num value) {
  if (field.type == FieldType.integer) return value.round().toString();
  final asDouble = value.toDouble();
  final step = field.step;
  if (step != null && step > 0) {
    return _trimZeros(asDouble.toStringAsFixed(_decimalsOf(step)));
  }
  return _trimZeros(_shortestExact(asDouble));
}

String _trimZeros(String text) {
  if (!text.contains('.')) return text;
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && text.codeUnitAt(end - 1) == 0x2E) end--;
  return text.substring(0, end);
}

int _decimalsOf(double step) {
  final text = _shortestExact(step);
  final dot = text.indexOf('.');
  return dot < 0 ? 0 : text.length - dot - 1;
}

/// The fewest decimals that still parse back to exactly [value].
String _shortestExact(double value) {
  if (!value.isFinite) return '0';
  for (var digits = 0; digits <= 8; digits++) {
    final text = value.toStringAsFixed(digits);
    if (double.parse(text) == value) return text;
  }
  return value.toString();
}

/// The declared range as a phrase, for a hint under a control and for the
/// sentence a value outside it produces.
String describeRange(L l, WorkflowField field) {
  final min = field.min;
  final max = field.max;
  if (min != null && max != null) {
    return l.rangeBetween(formatNumber(field, min), formatNumber(field, max));
  }
  if (min != null) return l.rangeAtLeast(formatNumber(field, min));
  if (max != null) return l.rangeAtMost(formatNumber(field, max));
  return l.rangeAnyNumber;
}
