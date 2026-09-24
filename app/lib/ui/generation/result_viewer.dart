/// The result picture, almost full screen (T-0210) — and a clip, the same way
/// (T-0211).
///
/// Opened by a tap on the preview and closed three ways — the close button,
/// system Back, and a tap — each of which pops this route and nothing else, so
/// the preview underneath is exactly what it was: nothing under it changed.
///
/// Three decisions are easy to undo by accident:
///
/// * **A picture is handed bytes, never a result.** The viewer shows the
///   picture that was tapped. Were it to read the controller, a job finishing behind it, or
///   a step through history, would swap the picture under the person looking
///   at it.
/// * **The ground is dark in both themes.** A picture of any tone reads against
///   near-black, and a light ground behind a light picture has no edge.
/// * **A tap undoes a zoom before it closes.** Pinching in and then tapping to
///   see the whole picture again is the ordinary gesture; closing on that tap
///   would throw the person out mid-look.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../generation/clip_playback.dart';
import '../../theme/tokens.dart';
import '../keys.dart';

/// Pushes the viewer over whatever is on screen.
Future<void> showResultViewer(BuildContext context, Uint8List bytes) =>
    Navigator.of(context).push<void>(
      _viewerRoute(
        Image.memory(
          bytes,
          key: LcKeys.resultViewerImage,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      ),
    );

/// The viewer over a playing clip — the **same** player the surface draws, so
/// one decoder and not two.
///
/// Returned rather than pushed, because sharing the player has a consequence
/// the picture's viewer does not: when the surface lets go of this player (a
/// new job, a step through history) the frame this route draws stops existing.
/// Its opener therefore keeps the route and takes it away first.
Route<void> clipViewerRoute(ClipPlayer player) => _viewerRoute(
  Center(
    child: AspectRatio(
      key: LcKeys.resultViewerClip,
      aspectRatio: player.aspectRatio,
      child: player.buildFrame(),
    ),
  ),
);

Route<void> _viewerRoute(Widget media) => PageRouteBuilder<void>(
  opaque: false,
  barrierDismissible: false,
  transitionDuration: LcMotion.normal,
  reverseTransitionDuration: LcMotion.quick,
  pageBuilder: (context, _, _) => ResultViewer(media: media),
  transitionsBuilder: (context, animation, _, child) =>
      FadeTransition(opacity: animation, child: child),
);

class ResultViewer extends StatefulWidget {
  const ResultViewer({super.key, required this.media});

  /// The picture or the clip, laid out to fill the viewer and contained
  /// inside it by its own fit.
  final Widget media;

  /// The ground. Not a palette colour: it is the same in both themes, on
  /// purpose (see the library comment).
  static const Color ground = Color(0xF2000000);

  /// How far a pinch may enlarge the picture.
  static const double maxScale = 6;

  @override
  State<ResultViewer> createState() => _ResultViewerState();
}

class _ResultViewerState extends State<ResultViewer> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _onTap() {
    if (_transform.value != Matrix4.identity()) {
      _transform.value = Matrix4.identity();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final materialL = MaterialLocalizations.of(context);
    return Material(
      key: LcKeys.resultViewer,
      color: ResultViewer.ground,
      child: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onTap,
                child: Padding(
                  // "Almost" full screen: a margin that leaves the picture's
                  // edge visible, and room for the close button above it.
                  padding: const EdgeInsets.fromLTRB(
                    LcSpace.sm,
                    LcSpace.xxl,
                    LcSpace.sm,
                    LcSpace.sm,
                  ),
                  child: InteractiveViewer(
                    transformationController: _transform,
                    maxScale: ResultViewer.maxScale,
                    // The whole box, with the picture contained inside it. An
                    // image given no size lays out at its own pixel size, so a
                    // small picture would stay small here — the one thing this
                    // viewer exists not to do.
                    child: SizedBox.expand(child: widget.media),
                  ),
                ),
              ),
            ),
            Positioned(
              top: LcSpace.xxs,
              right: LcSpace.xxs,
              child: IconButton(
                key: LcKeys.resultViewerClose,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
                color: Colors.white,
                tooltip: materialL.closeButtonTooltip,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
