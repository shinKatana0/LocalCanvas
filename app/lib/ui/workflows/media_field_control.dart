/// The control for an image or a video field (`docs/ui-ux.md`: media is a
/// first-class input).
///
/// Four states, each of them a fact rather than a decoration: nothing chosen,
/// going, on the server, and did not go. What the panel never contains is a
/// path — the only text it takes from a selection is
/// [MediaSelection.displayName], which is a filename or a plain sentence. A
/// content URI is not a name and does not appear here even when the filename
/// could not be read.
///
/// The progress bar is determinate only while [MediaFieldController.progress]
/// is a number, and that number comes from bytes actually handed to the
/// socket. When the length is unknown, and in the stretch after the last byte
/// has gone while the gateway is still thinking, the bar is indeterminate and
/// says so. Nothing here animates a percentage the app does not have.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../media/clip_inspector.dart';
import '../../media/media_field_controller.dart';
import '../../media/media_selection.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../workflows/workflow_models.dart';
import '../keys.dart';

class MediaFieldControl extends StatelessWidget {
  const MediaFieldControl({
    super.key,
    required this.field,
    required this.media,
  });

  final WorkflowField field;
  final MediaFieldController media;

  bool get _isVideo => media.kind == MediaKind.video;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: LcKeys.field(field.id),
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(LcRadius.md),
        border: Border.all(color: palette.outline),
      ),
      child: media.selection == null ? _empty(context) : _chosen(context),
    );
  }

  /// Nothing chosen: what the workflow needs, and the one thing to do about
  /// it.
  Widget _empty(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final failure = media.failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              _isVideo ? Icons.movie_outlined : Icons.image_outlined,
              size: 22,
              color: palette.textMuted,
            ),
            const SizedBox(width: LcSpace.sm),
            Expanded(
              child: Text(
                _isVideo ? l.mediaNeedsClip : l.mediaNeedsPicture,
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
        if (!media.canChoose) ...<Widget>[
          const SizedBox(height: LcSpace.xxs),
          Text(
            l.mediaCannotChoose,
            style: text.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ] else ...<Widget>[
          if (failure != null) ...<Widget>[
            const SizedBox(height: LcSpace.xs),
            _Problem(failure: failure),
          ],
          const SizedBox(height: LcSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: LcKeys.mediaChoose(field.id),
              onPressed: media.isPicking ? null : media.choose,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(
                _isVideo ? l.mediaChooseClip : l.mediaChoosePicture,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Something chosen: what it is, how far it has gone, and how to change it.
  Widget _chosen(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final selection = media.selection!;
    final detail = selection.detailLine(l);
    final failure = media.failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _previewOf(selection),
            const SizedBox(width: LcSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    selection.displayName(l),
                    style: text.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: text.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                  ],
                  if (media.phase == MediaPhase.ready) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      l.mediaReadyToUse,
                      style: text.bodySmall?.copyWith(color: palette.success),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (media.phase == MediaPhase.uploading) ...<Widget>[
          const SizedBox(height: LcSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(LcRadius.pill),
            child: LinearProgressIndicator(
              key: LcKeys.mediaProgress(field.id),
              // `null` draws the indeterminate bar. It is used only where the
              // app genuinely has no number, never to make a wait look busy.
              value: media.progress,
              minHeight: 4,
              backgroundColor: palette.outline,
            ),
          ),
          const SizedBox(height: LcSpace.xxs),
          Text(
            media.progressLabel(l),
            style: text.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ],
        if (failure != null && media.phase == MediaPhase.failed) ...<Widget>[
          const SizedBox(height: LcSpace.xs),
          _Problem(failure: failure),
        ],
        const SizedBox(height: LcSpace.xs),
        Wrap(
          spacing: LcSpace.xs,
          children: <Widget>[
            if (media.phase == MediaPhase.failed)
              TextButton(
                key: LcKeys.mediaRetry(field.id),
                onPressed: media.retry,
                style: _compact,
                child: Text(l.tryAgain),
              ),
            TextButton(
              key: LcKeys.mediaReplace(field.id),
              onPressed: media.isPicking ? null : media.choose,
              style: _compact,
              child: Text(l.replace),
            ),
            TextButton(
              key: LcKeys.mediaRemove(field.id),
              onPressed: media.remove,
              style: _compact,
              child: Text(l.remove),
            ),
          ],
        ),
      ],
    );
  }

  /// The thumbnail for [selection].
  ///
  /// A clip gets a frame only where all three are true: it is a clip, this
  /// build has an inspector, and the source has a local file to open. Anything
  /// else — a picture above all — is the preview exactly as it was before
  /// clips had frames, and no inspector is asked about it.
  ///
  /// The clip's preview is keyed by the **identity** of its source. A new
  /// choice is a new source, so its preview starts over and the old one's
  /// inspection is released; the copies the controller makes of the same
  /// choice — with the gateway's byte count, with the measured length — keep
  /// the source, so they redraw the frame they have instead of opening the
  /// clip again.
  Widget _previewOf(MediaSelection selection) {
    final inspector = media.inspector;
    final file = selection.source.previewFile;
    if (selection.kind != MediaKind.video ||
        inspector == null ||
        file == null) {
      return _Preview(fieldId: field.id, selection: selection);
    }
    return _ClipPreview(
      key: ObjectKey(selection.source),
      fieldId: field.id,
      selection: selection,
      inspector: inspector,
      file: file,
      media: media,
    );
  }

  static final ButtonStyle _compact = TextButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: LcSpace.xs),
  );
}

/// A clip's thumbnail, with the inspection that draws its frame (T-0022).
///
/// **This widget owns the inspection**, as `_ClipView` owns a result's player:
/// it opens one for the clip it was built with and disposes it when it goes —
/// on a replace (a new source, so a new key), a remove, a different workflow
/// on screen, or the shell itself going. An inspection is never handed on, so
/// there is no second owner to forget one.
///
/// Until a frame arrives, and for good if none does — a decode that fails, an
/// inspector that throws anything at all, or one still going at
/// [kClipInspectionBound] — this draws the marked tile and
/// nothing else, identical to a build with no inspector. A result that arrives
/// after the bound, or after this widget has gone, is released unseen.
class _ClipPreview extends StatefulWidget {
  const _ClipPreview({
    super.key,
    required this.fieldId,
    required this.selection,
    required this.inspector,
    required this.file,
    required this.media,
  });

  final String fieldId;
  final MediaSelection selection;
  final ClipInspector inspector;
  final File file;
  final MediaFieldController media;

  @override
  State<_ClipPreview> createState() => _ClipPreviewState();
}

class _ClipPreviewState extends State<_ClipPreview> {
  ClipInspection? _inspection;
  Timer? _bound;
  bool _givenUp = false;

  @override
  void initState() {
    super.initState();
    unawaited(_inspect());
  }

  Future<void> _inspect() async {
    _bound = Timer(kClipInspectionBound, () => _givenUp = true);
    // The source this preview was keyed by. `widget` may be a later copy of
    // the same choice by the time the answer comes; its source is the same
    // object, which is what the controller checks.
    final source = widget.selection.source;
    final ClipInspection inspection;
    try {
      inspection = await widget.inspector.inspect(widget.file);
    } catch (_) {
      // `ClipInspectionFailure` is the contract, but whatever an inspector
      // throws ends the same way: the tile stays, no length, and nothing is
      // left unhandled — this future is never awaited, so an error let go of
      // here would reach nobody who could deal with it (T-0231).
      _bound?.cancel();
      return;
    }
    _bound?.cancel();
    if (!mounted || _givenUp) {
      // Nobody will ever draw it.
      unawaited(inspection.dispose());
      return;
    }
    setState(() => _inspection = inspection);
    final duration = inspection.duration;
    if (duration != null) widget.media.adoptClipDuration(source, duration);
  }

  @override
  Widget build(BuildContext context) => _Preview(
    fieldId: widget.fieldId,
    selection: widget.selection,
    frame: _inspection?.buildFrame(),
  );

  @override
  void dispose() {
    _bound?.cancel();
    final inspection = _inspection;
    _inspection = null;
    if (inspection != null) unawaited(inspection.dispose());
    super.dispose();
  }
}

/// A thumbnail of what was chosen.
///
/// A picture is shown as itself. A clip is shown as its [frame] when one was
/// drawn for it (`_ClipPreview`), and as a marked tile otherwise: a tile that
/// says "this is a clip" is honest; a blank grey square pretending to be a
/// still would not be.
class _Preview extends StatelessWidget {
  const _Preview({required this.fieldId, required this.selection, this.frame});

  static const double _size = 64;

  final String fieldId;
  final MediaSelection selection;

  /// A clip's still frame, or `null` for the tile alone.
  final Widget? frame;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final file = selection.source.previewFile;
    final showsImage = selection.kind == MediaKind.image && file != null;
    final frame = selection.kind == MediaKind.video ? this.frame : null;
    return ClipRRect(
      key: LcKeys.mediaPreview(fieldId),
      borderRadius: BorderRadius.circular(LcRadius.sm),
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // Underneath always, so the frame or two before a photo has been
            // decoded is a marked tile rather than a hole — and so a file
            // that cannot be decoded at all needs no special case.
            _tile(palette),
            if (showsImage)
              Image.file(
                file,
                fit: BoxFit.cover,
                // Decoded at the size it is drawn at, not at the size the
                // camera wrote it.
                cacheWidth: (_size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (context, _, _) => const SizedBox.shrink(),
              ),
            // Over the tile for the same reason a picture is: whatever the
            // frame has not drawn yet is the tile, never a hole.
            ?frame,
          ],
        ),
      ),
    );
  }

  Widget _tile(LcPalette palette) => ColoredBox(
    color: palette.surface,
    child: Center(
      child: Icon(
        selection.kind == MediaKind.video
            ? Icons.movie_outlined
            : Icons.image_outlined,
        color: palette.textMuted,
      ),
    ),
  );
}

/// A failure, in the words the user reads. No status code, no exception text.
class _Problem extends StatelessWidget {
  const _Problem({required this.failure});

  final MediaFailure failure;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          failure.title(l),
          style: text.bodySmall?.copyWith(color: palette.warning),
        ),
        Text(
          failure.message(l),
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
      ],
    );
  }
}
