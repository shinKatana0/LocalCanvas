/// One media field's state: what was chosen, how far it has gone, and the
/// `media_id` that comes out the other end.
///
/// Flutter's own [ChangeNotifier], like every other piece of state in this app.
///
/// The order of operations is the contract's, not a convenience: the file is
/// uploaded **when it is chosen**, not when Generate is pressed. That is what
/// makes progress observable at all, and it is what makes a retried submit
/// cost nothing — the id is already here, so `POST /api/v1/jobs` can be sent
/// again without sending the picture again (`docs/api.md`).
///
/// Two states are deliberately separate. A field with nothing in it is
/// *empty*, and a required one blocks Generate with its requirement showing. A
/// field whose file is still going is *uploading*, and it blocks Generate too,
/// but for a different reason and with a different sentence. Neither is ever
/// rendered as ready.
library;

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import 'clip_inspector.dart';
import 'media_api.dart';
import 'media_picker.dart';
import 'media_selection.dart';

/// Where one media field is.
enum MediaPhase {
  /// Nothing chosen.
  empty,

  /// Chosen, and the bytes are on their way.
  uploading,

  /// Uploaded. [MediaFieldController.mediaId] is the value the job will carry.
  ready,

  /// Chosen, and the upload did not finish.
  failed,
}

/// Sends one file and reports its progress. The form is given one of these
/// rather than an endpoint, so nothing here has to know which server is
/// current — [WorkflowsController] does.
typedef MediaUploadRunner =
    Future<UploadedMedia> Function(
      MediaSelection selection,
      MediaProgress onProgress,
    );

class MediaFieldController extends ChangeNotifier {
  MediaFieldController({
    required this.kind,
    this.picker,
    this.uploader,
    this.inspector,
  });

  final MediaKind kind;
  final MediaPicker? picker;
  final MediaUploadRunner? uploader;

  /// What draws a chosen clip's frame and learns its length, or `null` on a
  /// build that has none — which is the marked tile and no length, exactly as
  /// before there was one (T-0022).
  ///
  /// Held here only so the panel can reach it. The inspection it produces is
  /// **not** held here: it is owned by the widget that draws it, the way a
  /// result's player is (`generation_surface.dart`), because a frame is a
  /// thing on screen and lives exactly as long as the screen shows it. What
  /// outlives the drawing is the length, and that is written into the
  /// selection by [adoptClipDuration].
  final ClipInspector? inspector;

  MediaSelection? _selection;
  MediaPhase _phase = MediaPhase.empty;
  int _sentBytes = 0;
  int? _totalBytes;
  String? _mediaId;
  MediaFailure? _failure;
  bool _picking = false;

  /// Every upload carries the token it started with; a reply that arrives
  /// after the user chose something else, or removed it, belongs to nobody and
  /// is dropped rather than written over the current state.
  int _token = 0;

  bool _disposed = false;

  MediaSelection? get selection => _selection;
  MediaPhase get phase => _phase;
  MediaFailure? get failure => _failure;

  /// The id `POST /api/v1/jobs` carries for this field, once there is one.
  String? get mediaId => _mediaId;

  /// Whether this build can open a picker at all. False leaves the field
  /// stated rather than faked, exactly as it was before this card.
  bool get canChoose => picker != null && uploader != null;

  /// The picker is open. Guards against a second tap opening a second one.
  bool get isPicking => _picking;

  int get sentBytes => _sentBytes;

  /// The length of the file, or `null` when the source could not say. A `null`
  /// is the honest indeterminate case and never becomes a guess.
  int? get totalBytes => _totalBytes;

  /// The fraction to draw, or `null` for an indeterminate bar.
  ///
  /// It is `null` in two real situations and in no invented one: when the
  /// length is unknown, and once every byte has been handed to the transport
  /// but the gateway has not answered yet. In that second stretch the app
  /// genuinely does not know how long is left, so the bar stops pretending to.
  double? get progress {
    if (_phase != MediaPhase.uploading) return null;
    final total = _totalBytes;
    if (total == null || total <= 0) return null;
    if (_sentBytes >= total) return null;
    return _sentBytes / total;
  }

  /// The sentence under the bar while the file is going.
  ///
  /// Built from the localisations rather than held as text: the two byte counts
  /// come from this controller and the frame around them from the language on
  /// screen (T-0142).
  String progressLabel(L l) {
    final total = _totalBytes;
    if (total == null || total <= 0) return l.mediaUploading;
    if (_sentBytes >= total) return l.mediaFinishing;
    return l.mediaUploadingProgress(
      formatByteCount(l, _sentBytes),
      formatByteCount(l, total),
    );
  }

  /// Records a length the [inspector] measured for the chosen clip.
  ///
  /// **This controller owns the selection**, so this is where the copy with a
  /// duration is made: it is the one writer of [selection], the one that
  /// already replaces it when the gateway counts the bytes, and the notifier
  /// the panel redraws from. The widget that measured the length only reports
  /// it.
  ///
  /// Ignored unless [source] is — by identity — the source of the clip chosen
  /// now: a length measured for a clip that has since been replaced or
  /// removed belongs to nobody. Ignored for a picture, which has no length,
  /// and where the selection already carries one, which came from the picker
  /// and is not second-guessed.
  void adoptClipDuration(MediaSource source, Duration duration) {
    final current = _selection;
    if (_disposed || current == null) return;
    if (!identical(current.source, source)) return;
    if (current.kind != MediaKind.video || current.duration != null) return;
    _selection = current.copyWith(duration: duration);
    _notify();
  }

  /// Opens the picker and, if something comes back, starts its upload.
  Future<void> choose() async {
    final picker = this.picker;
    if (picker == null || !canChoose || _picking) return;
    _picking = true;
    _notify();
    MediaSelection? picked;
    try {
      picked = await picker.pick(kind);
    } on MediaFailure catch (failure) {
      _picking = false;
      _failure = failure;
      // Nothing was chosen, so the field is still empty — it just also has
      // something to say about the attempt.
      _phase = _selection == null ? MediaPhase.empty : _phase;
      _notify();
      return;
    }
    _picking = false;
    if (picked == null) {
      // Backing out of the picker is a decision, not a failure.
      _notify();
      return;
    }
    await _accept(picked);
  }

  /// Sends the chosen file again after a failure. The same file: retrying is
  /// not a second choice.
  Future<void> retry() async {
    final selection = _selection;
    if (selection == null || _phase != MediaPhase.failed) return;
    await _accept(selection);
  }

  /// Puts the field back to empty.
  void remove() {
    if (_selection == null && _phase == MediaPhase.empty && _failure == null) {
      return;
    }
    _token++;
    _selection = null;
    _phase = MediaPhase.empty;
    _sentBytes = 0;
    _totalBytes = null;
    _mediaId = null;
    _failure = null;
    _notify();
  }

  /// Re-checks the chosen file and drops it if it is gone.
  ///
  /// `docs/recovery.md`: a selection survives a reconnect, a fold and a
  /// configuration change **while it is still valid**. An Android permission
  /// that has lapsed — or a cached copy the system swept away — must return
  /// the field to empty with its requirement visible here, rather than
  /// surfacing as an upload failure much later, when the user has already
  /// pressed Generate.
  ///
  /// A file that is already uploaded is not re-checked: its bytes are on the
  /// gateway and the local file has no further part to play.
  ///
  /// The answer is about the selection that was asked about, and is acted on
  /// only while that is still — by identity — the selection held (T-0237). A
  /// picture chosen while the check was out, or the field emptied by the user
  /// in the meantime, is not this answer's to remove. Identity rather than the
  /// upload token, because the two things that replace the object without a
  /// new choice both mean the old answer is out of date too: an upload that
  /// landed (a ready file is not re-checked at all) and a clip length that was
  /// measured (the file was readable a moment ago).
  Future<void> restoreSelection() async {
    final selection = _selection;
    if (selection == null) return;
    if (_phase == MediaPhase.ready && _mediaId != null) return;
    if (await selection.source.isAvailable()) return;
    if (_disposed || !identical(_selection, selection)) return;
    remove();
  }

  Future<void> _accept(MediaSelection selection) async {
    final uploader = this.uploader;
    if (uploader == null) return;
    final token = ++_token;
    _selection = selection;
    _failure = null;
    _mediaId = null;
    _sentBytes = 0;
    _totalBytes = selection.byteCount;
    _phase = MediaPhase.uploading;
    _notify();

    try {
      final uploaded = await uploader(selection, (sent, total) {
        if (token != _token || _disposed) return;
        _sentBytes = sent;
        _totalBytes = total;
        _notify();
      });
      if (token != _token || _disposed) return;
      _mediaId = uploaded.mediaId;
      _phase = MediaPhase.ready;
      // The gateway counted the bytes it actually stored; prefer that number
      // over the one the picker guessed at.
      //
      // Copied from the selection as it stands now, not as it stood when the
      // upload began: a clip's length may have been measured in between
      // ([adoptClipDuration]), and the token check above is what makes this
      // still the same clip.
      if (uploaded.byteCount != null) {
        _selection = _selection!.copyWith(byteCount: uploaded.byteCount);
      }
      _notify();
    } on MediaFailure catch (failure) {
      if (token != _token || _disposed) return;
      _failure = failure;
      _phase = MediaPhase.failed;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    super.dispose();
  }
}
