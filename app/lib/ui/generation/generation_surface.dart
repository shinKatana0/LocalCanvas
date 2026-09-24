/// What the creation area shows once Generate has been pressed
/// (`docs/ui-ux.md`, `docs/recovery.md`).
///
/// The whole file is one rule: **it draws what is known and nothing else.**
///
/// * A determinate bar exists only where [GenerationController.progress] does,
///   and its label is the gateway's two integers. There is no percentage and
///   no time estimate anywhere in this file — not even a formatted one — so
///   there is nowhere for a fabricated number to appear.
/// * [LifecycleState.interrupted] draws a warning and a decision. It has no
///   spinner, no bar and no "still generating"; the app does not know whether
///   the job survived, and the screen says exactly that.
/// * Cancel is built only when the gateway advertises it. Where it does not,
///   the button is absent rather than present and grey.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../generation/clip_playback.dart';
import '../../generation/generation_controller.dart';
import '../../generation/jobs_api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../keys.dart';
import 'result_viewer.dart';

/// The creation area for everything from Generate to a result.
class GenerationSurface extends StatelessWidget {
  const GenerationSurface({
    super.key,
    required this.generation,
    required this.onGenerateAgain,
    this.onSaveSetup,
  });

  final GenerationController generation;

  /// What Generate Again does. Supplied whole rather than read off
  /// [generation], because going again is not only a thing that happens to a
  /// job: it also varies the seed in the form the job came from, and this
  /// widget has no form and should not learn about one.
  final VoidCallback onGenerateAgain;

  /// Keeps what produced this result as a named setup, or `null` on a build
  /// that keeps none — in which case the affordance is absent rather than
  /// present and doing nothing.
  ///
  /// It belongs to a finished result and to nothing else on this surface: a
  /// generation that failed, was cancelled or was interrupted is not a thing
  /// anyone asked to be able to come back to.
  final VoidCallback? onSaveSetup;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Padding(
      key: LcKeys.generationSurface,
      // Generous vertical room: in one column this is the top of the screen,
      // and the whitespace is what keeps it from reading as a status bar.
      padding: const EdgeInsets.symmetric(
        horizontal: LcSpace.md,
        vertical: LcSpace.xl,
      ),
      child: switch (generation.state) {
        LifecycleState.uploading => _Waiting(
          title: l.generationUploadingTitle,
          message: l.generationUploadingMessage,
          generation: generation,
        ),
        LifecycleState.queued => _Waiting(
          title: l.generationQueuedTitle,
          message: l.generationQueuedMessage,
          generation: generation,
        ),
        LifecycleState.generating => _Waiting(
          title: l.generationGeneratingTitle,
          message: null,
          generation: generation,
        ),
        LifecycleState.interrupted => _Interrupted(
          generation: generation,
          onGenerateAgain: onGenerateAgain,
        ),
        LifecycleState.failed => _Outcome(
          tone: _Tone.danger,
          icon: Icons.error_outline,
          title: generation.problemTitle(l) ?? l.generationFailedTitle,
          message: generation.problemMessage(l),
          generation: generation,
          onGenerateAgain: onGenerateAgain,
        ),
        LifecycleState.cancelled => _Outcome(
          tone: _Tone.muted,
          icon: Icons.stop_circle_outlined,
          title: l.generationCancelledTitle,
          message: l.generationCancelledMessage,
          generation: generation,
          onGenerateAgain: onGenerateAgain,
        ),
        LifecycleState.completed => _Result(
          generation: generation,
          onSaveSetup: onSaveSetup,
          onGenerateAgain: onGenerateAgain,
        ),
        LifecycleState.disconnected ||
        LifecycleState.connecting ||
        LifecycleState.ready ||
        LifecycleState.reconnecting => const SizedBox.shrink(),
      },
    );
  }
}

/// Something is moving, and the screen says how much is known about it.
class _Waiting extends StatelessWidget {
  const _Waiting({
    required this.title,
    required this.message,
    required this.generation,
  });

  final String title;
  final String? message;
  final GenerationController generation;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final progress = generation.progress;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          key: LcKeys.generationStatus,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title, style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: LcSpace.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(LcRadius.pill),
              child: LinearProgressIndicator(
                key: LcKeys.generationProgress,
                // The gateway's fraction, or none at all. `null` is what makes
                // Material draw the indeterminate sweep, and it is the only
                // other option this widget has.
                value: progress?.fraction,
                minHeight: 6,
                backgroundColor: palette.surfaceRaised,
              ),
            ),
            const SizedBox(height: LcSpace.xs),
            Text(
              // Two integers the gateway sent, or a sentence that claims
              // nothing. Never a percentage, never an estimate.
              progress?.label(l) ?? message ?? l.generationTakesAWhile,
              key: LcKeys.generationProgressLabel,
              style: text.bodySmall?.copyWith(color: palette.textMuted),
              textAlign: TextAlign.center,
            ),
            if (generation.canCancel || generation.isCancelling) ...<Widget>[
              const SizedBox(height: LcSpace.md),
              Center(
                child: TextButton(
                  key: LcKeys.cancelGeneration,
                  onPressed: generation.isCancelling ? null : generation.cancel,
                  child: Text(
                    generation.isCancelling
                        ? l.generationStopping
                        : l.generationCancel,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Contact was lost while a job was in flight.
///
/// There is no progress indicator in this widget, by construction: the app
/// does not know whether the generation survived, and drawing motion would
/// assert that it did.
///
/// Three things can be true here and the panel says which one is:
///
/// * the gateway answered 404 — the job is gone, and that is an answer;
/// * a check is running — the bounded reconnect, or the snapshot request;
/// * the check has run out — the app has stopped looking and still does not
///   know.
///
/// The third used to be drawn with the second's words, which left "Checking
/// whether the generation survived." on screen after the app had stopped
/// checking. The sentence now comes from
/// [GenerationController.isCheckingSurvival], which is computed at draw time
/// and cannot go stale.
class _Interrupted extends StatelessWidget {
  const _Interrupted({required this.generation, required this.onGenerateAgain});

  final GenerationController generation;
  final VoidCallback onGenerateAgain;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final lost = generation.recovery == JobRecovery.lost;
    return _Outcome(
      key: LcKeys.generationInterrupted,
      tone: _Tone.warning,
      icon: Icons.cloud_off_outlined,
      title: lost ? stateUnrecoverableMessage(l) : connectionLostTitle(l),
      message: lost
          ? l.generationLostMessage
          : generation.isCheckingSurvival
          ? checkingSurvivalMessage(l)
          : survivalUnknownMessage(l),
      generation: generation,
      onGenerateAgain: onGenerateAgain,
    );
  }
}

enum _Tone { danger, warning, muted }

/// An outcome the user is looking at, plus the way out of it.
class _Outcome extends StatelessWidget {
  const _Outcome({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    required this.message,
    required this.generation,
    required this.onGenerateAgain,
  });

  final _Tone tone;
  final IconData icon;
  final String title;
  final String? message;
  final GenerationController generation;
  final VoidCallback onGenerateAgain;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final colour = switch (tone) {
      _Tone.danger => palette.danger,
      _Tone.warning => palette.warning,
      _Tone.muted => palette.textMuted,
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          key: LcKeys.generationStatus,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 32, color: colour),
            const SizedBox(height: LcSpace.sm),
            Text(title, style: text.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...<Widget>[
              const SizedBox(height: LcSpace.xs),
              Text(
                message!,
                style: text.bodyMedium?.copyWith(color: palette.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: LcSpace.lg),
            FilledButton(
              key: LcKeys.generateAgain,
              onPressed: onGenerateAgain,
              child: Text(L.of(context).generateAgain),
            ),
          ],
        ),
      ),
    );
  }
}

/// The result. The media is the hero and the controls sit under it
/// (`docs/ui-ux.md`).
class _Result extends StatelessWidget {
  const _Result({
    required this.generation,
    required this.onGenerateAgain,
    this.onSaveSetup,
  });

  final GenerationController generation;
  final VoidCallback onGenerateAgain;
  final VoidCallback? onSaveSetup;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    // This widget is drawn both inside a scrolling column, where the height is
    // unbounded, and inside a pane, where it is not. The media takes what
    // there is, minus the room the controls under it need.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
      key: LcKeys.resultSurface,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Media(
          generation: generation,
          maxHeight: constraints.maxHeight.isFinite
              ? (constraints.maxHeight - 132).clamp(220.0, 560.0)
              : 560.0,
        ),
        // The way back to a result from earlier in this session (T-0178), and
        // only where there is one: with a single result there is nothing to
        // step between, so the row is absent rather than present with two dead
        // arrows. It sits directly under the picture because it is about which
        // picture this is, not about what to do with it.
        if (generation.resultHistory.length > 1) _History(generation: generation),
        const SizedBox(height: LcSpace.md),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: LcSpace.xs,
          runSpacing: LcSpace.xxs,
          children: <Widget>[
            if (generation.canExport) ...<Widget>[
              FilledButton.icon(
                key: LcKeys.resultSave,
                onPressed: generation.isExporting ? null : generation.saveResult,
                icon: const Icon(Icons.download_rounded, size: 20),
                label: Text(l.save),
              ),
              OutlinedButton.icon(
                key: LcKeys.resultShare,
                onPressed: generation.isExporting
                    ? null
                    : generation.shareResult,
                icon: const Icon(Icons.ios_share_rounded, size: 20),
                label: Text(l.share),
              ),
            ],
            TextButton(
              key: LcKeys.generateAgain,
              onPressed: onGenerateAgain,
              child: Text(l.generateAgain),
            ),
            // What produced this, kept under a name. The prompt it keeps is
            // the one still in the form — the user's own words — and never
            // the effective text this run was bound with (`docs/api.md`).
            if (onSaveSetup != null)
              TextButton(
                key: LcKeys.resultSaveSetup,
                onPressed: onSaveSetup,
                child: Text(l.generationSaveAsSetup),
              ),
          ],
        ),
        if (generation.exportSaved ||
            generation.exportFailure != null) ...<Widget>[
          const SizedBox(height: LcSpace.xs),
          Text(
            generation.exportFailure == null
                ? l.exportSavedToGallery
                : '${generation.exportFailure!.title(l)} '
                      '${generation.exportFailure!.message(l)}',
            key: LcKeys.resultNotice,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(
              color: generation.exportFailure != null
                  ? palette.danger
                  : palette.textSecondary,
            ),
          ),
        ],
      ],
      ),
    );
  }
}

/// One step back, and one forward, through the results of this session
/// (T-0178).
///
/// A pair of arrows and a position, not a strip of thumbnails: the folded screen
/// has very little room, and a thumbnail strip would mean fetching every picture
/// from the gateway to draw it — which is the opposite of the decision that
/// makes this feature cheap (the app keeps job ids, never images).
///
/// The position is a *label*, and the only thing in this feature that counts.
/// What a button actually acts on is the entry itself, resolved by job id and
/// index inside [GenerationController.showResult], so an eviction can move this
/// label without ever moving what a tap means.
class _History extends StatelessWidget {
  const _History({required this.generation});

  final GenerationController generation;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final history = generation.resultHistory;
    final at = generation.viewedPosition;
    return Padding(
      key: LcKeys.resultHistory,
      padding: const EdgeInsets.only(top: LcSpace.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            key: LcKeys.resultPrevious,
            onPressed: generation.canShowPreviousResult
                ? generation.showPreviousResult
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: l.resultPreviousResult,
          ),
          Text(
            // Counted from the oldest still kept, so the newest is the last
            // number — which is where a finished generation puts you.
            l.resultHistoryPosition((at ?? history.length - 1) + 1, history.length),
            key: LcKeys.resultHistoryPosition,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          IconButton(
            key: LcKeys.resultNext,
            onPressed: generation.canShowNextResult
                ? generation.showNextResult
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: l.resultNextResult,
          ),
        ],
      ),
    );
  }
}

/// The picture itself, or the honest reason there is not one on screen.
class _Media extends StatelessWidget {
  const _Media({required this.generation, required this.maxHeight});

  final GenerationController generation;

  /// The room the picture may take. It takes the width it is given and as much
  /// of this as its own shape asks for — never more, and never a fixed block
  /// of empty ground around a small picture.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    // What is on display: a result the user stepped back to, or — the ordinary
    // case, and the one that existed before T-0178 — the current job's own.
    final result = generation.displayedResult;
    final bytes = generation.resultBytes;

    final Widget child;
    if (result == null) {
      child = _Quiet(
        icon: Icons.check_circle_outline,
        title: l.generationFinishedTitle,
        message: l.generationNoOutput,
      );
    } else if (result.isVideo && generation.clipPlayback == null) {
      // "Preview where practical" (`docs/ui-ux.md`). A build with nothing to
      // play a clip with says what it has rather than showing a still it does
      // not — and the controller never fetched the clip to get here.
      child = _Quiet(
        icon: Icons.movie_creation_outlined,
        title: l.generationClipReadyTitle,
        message: l.generationClipReadyMessage,
      );
    } else if (result.isVideo && bytes != null) {
      // The clip, playing (T-0211). Keyed by the bytes, so a different clip —
      // a new job, a step through history — is a different player, and the
      // old one is disposed rather than reused.
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: _ClipView(
          key: ObjectKey(bytes),
          playback: generation.clipPlayback!,
          clip: bytes,
        ),
      );
    } else if (bytes != null) {
      // Full width, its own aspect, capped in height: the picture decides how
      // tall this is, which is what "the media is the hero" means in layout.
      //
      // A tap opens it almost full screen (T-0210). No expand icon drawn over
      // it — chrome on the picture competes with the picture — so the
      // affordance is announced to assistive technology instead.
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Semantics(
          button: true,
          label: l.resultOpenLarger,
          child: GestureDetector(
            key: LcKeys.resultOpenViewer,
            // The bytes on display now, captured at the tap: the viewer shows
            // what was tapped even if the surface moves on behind it.
            onTap: () => showResultViewer(context, bytes.bytes),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(LcRadius.md),
              child: Image.memory(
                bytes.bytes,
                key: LcKeys.resultPreview,
                width: double.infinity,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
      );
    } else if (generation.hasPreviewProblem) {
      child = Column(
        key: LcKeys.resultProblem,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.image_not_supported_outlined, size: 32, color: palette.textMuted),
          const SizedBox(height: LcSpace.sm),
          Text(
            result.isVideo
                ? l.generationClipFetchFailedTitle
                : l.generationPreviewFailedTitle,
            style: text.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: LcSpace.xxs),
          Text(
            generation.previewProblem(l)!,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: LcSpace.xs),
          TextButton(
            onPressed: generation.loadPreview,
            child: Text(l.tryAgain),
          ),
        ],
      );
    } else {
      child = const SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    // Everything that is not a picture is a short block of words, so it gets
    // a panel of its own rather than the room a picture would have taken.
    //
    // `Align` with a `heightFactor` is what makes that true rather than merely
    // intended: an aligned box with no factor expands to the largest height it
    // is allowed, which here is the whole of [maxHeight] — a 560dp panel around
    // two lines of text. With the factor it takes the child's height, and the
    // minimum below is what keeps it from reading as a strip.
    return Container(
      key: LcKeys.resultPlaceholder,
      constraints: BoxConstraints(minHeight: 220, maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.md),
        border: Border.all(color: palette.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Align(alignment: Alignment.center, heightFactor: 1, child: child),
    );
  }
}

/// A clip that plays: muted, looping, started by itself (T-0211).
///
/// **This widget owns the player.** It opens one for the clip it was built
/// with and disposes it when it goes — which, because the surface keys it by
/// the bytes, is whenever the clip on display changes. A player is never
/// handed on, so there is no second owner to forget one.
///
/// **The viewer shares it**, so the viewer's route is kept here and removed
/// before the player is released: a route left drawing a disposed player's
/// frame is the failure that sharing invites.
class _ClipView extends StatefulWidget {
  const _ClipView({super.key, required this.playback, required this.clip});

  final ClipPlayback playback;
  final ResultBytes clip;

  @override
  State<_ClipView> createState() => _ClipViewState();
}

class _ClipViewState extends State<_ClipView> {
  ClipPlayer? _player;
  bool _failed = false;
  Route<void>? _viewer;

  /// What was last drawn, so the player's frequent position updates do not
  /// rebuild the controls when nothing they show has changed.
  bool _drawnPlaying = false;
  bool _drawnMuted = true;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final ClipPlayer player;
    try {
      player = await widget.playback.open(widget.clip);
    } on ClipPlaybackFailure {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      // Gone while it opened: nobody will ever draw it.
      unawaited(player.dispose());
      return;
    }
    // Muted first, then playing, so not a frame of sound escapes: sound nobody
    // asked for is the surprise to avoid (T-0211).
    await player.setMuted(true);
    await player.play();
    if (!mounted) {
      unawaited(player.dispose());
      return;
    }
    player.addListener(_onPlayerChanged);
    setState(() {
      _player = player;
      _drawnPlaying = player.isPlaying;
      _drawnMuted = player.isMuted;
    });
  }

  void _onPlayerChanged() {
    final player = _player;
    if (player == null || !mounted) return;
    if (player.isPlaying == _drawnPlaying && player.isMuted == _drawnMuted) {
      return;
    }
    setState(() {
      _drawnPlaying = player.isPlaying;
      _drawnMuted = player.isMuted;
    });
  }

  void _togglePlaying() {
    final player = _player;
    if (player == null) return;
    unawaited(player.isPlaying ? player.pause() : player.play());
  }

  void _toggleSound() {
    final player = _player;
    if (player == null) return;
    unawaited(player.setMuted(!player.isMuted));
  }

  void _openLarger() {
    final player = _player;
    if (player == null) return;
    final route = clipViewerRoute(player);
    _viewer = route;
    unawaited(
      Navigator.of(context).push(route).whenComplete(() {
        if (identical(_viewer, route)) _viewer = null;
      }),
    );
  }

  @override
  void dispose() {
    final viewer = _viewer;
    if (viewer != null && viewer.isActive) {
      viewer.navigator?.removeRoute(viewer);
    }
    _viewer = null;
    final player = _player;
    _player = null;
    if (player != null) {
      player.removeListener(_onPlayerChanged);
      unawaited(player.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l = L.of(context);
    final player = _player;

    if (_failed) {
      return Container(
        key: LcKeys.resultClipProblem,
        constraints: const BoxConstraints(minHeight: 220),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(LcRadius.md),
          border: Border.all(color: palette.outline),
        ),
        child: Center(
          heightFactor: 1,
          child: _Quiet(
            icon: Icons.videocam_off_outlined,
            title: l.clipCannotPlayTitle,
            message: l.clipCannotPlayMessage,
          ),
        ),
      );
    }
    if (player == null) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final overlay = palette.canvas.withValues(alpha: 0.72);
    return Center(
      child: AspectRatio(
        key: LcKeys.resultClip,
        aspectRatio: player.aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(LcRadius.md),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Semantics(
                button: true,
                label: _drawnPlaying ? l.clipPause : l.clipPlay,
                child: GestureDetector(
                  key: LcKeys.resultClipPlayPause,
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlaying,
                  child: player.buildFrame(),
                ),
              ),
              if (!_drawnPlaying)
                IgnorePointer(
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: overlay,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(LcSpace.xs),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 36,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: LcSpace.xxs,
                bottom: LcSpace.xxs,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: overlay,
                    borderRadius: BorderRadius.circular(LcRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        key: LcKeys.resultClipSound,
                        onPressed: _toggleSound,
                        icon: Icon(
                          _drawnMuted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          size: 20,
                        ),
                        color: palette.textPrimary,
                        tooltip: _drawnMuted ? l.clipSoundOn : l.clipSoundOff,
                      ),
                      IconButton(
                        key: LcKeys.resultClipExpand,
                        onPressed: _openLarger,
                        icon: const Icon(Icons.fullscreen_rounded, size: 20),
                        color: palette.textPrimary,
                        tooltip: l.clipOpenLarger,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quiet extends StatelessWidget {
  const _Quiet({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(LcSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 34, color: palette.textMuted),
          const SizedBox(height: LcSpace.sm),
          Text(title, style: text.titleSmall, textAlign: TextAlign.center),
          const SizedBox(height: LcSpace.xxs),
          Text(
            message,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// The subtle, non-modal `Reconnecting…` (`docs/recovery.md`).
///
/// One line. It does not blank the screen, cover anything, or take a tap.
class ReconnectingBar extends StatelessWidget {
  const ReconnectingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Container(
      key: LcKeys.reconnecting,
      padding: const EdgeInsets.symmetric(
        horizontal: LcSpace.sm,
        vertical: LcSpace.xs,
      ),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(LcRadius.pill),
        border: Border.all(color: palette.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.textMuted,
            ),
          ),
          const SizedBox(width: LcSpace.xs),
          Text(
            L.of(context).reconnecting,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}
