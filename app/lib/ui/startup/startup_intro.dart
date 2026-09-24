/// The branded launch (`docs/ui-ux.md`).
///
/// Mark → formation → wordmark → out, in [LcMotion.intro], from Flutter's own
/// animation primitives. No external asset, no animation framework, no
/// architecture.
///
/// **It gates nothing.** This widget is painted over an app that is already
/// built and already working; it holds no future, blocks no call and is not
/// what starts the connection. When it ends it simply removes itself, and
/// whatever the app had reached by then is what the user sees underneath —
/// which is how the intro turns into `Connecting…` rather than delaying it.
library;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../common/brand.dart';

class StartupIntro extends StatefulWidget {
  const StartupIntro({super.key, required this.onFinished});

  /// Called once, when the sequence has played out.
  final VoidCallback onFinished;

  @override
  State<StartupIntro> createState() => _StartupIntroState();
}

class _StartupIntroState extends State<StartupIntro>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LcMotion.intro,
  )..addStatusListener(_onStatus);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onFinished();
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.canvas,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final formation = Curves.easeOutCubic.transform(
              (t / 0.9).clamp(0.0, 1.0),
            );
            final rise = Curves.easeOutCubic.transform(
              ((t - 0.45) / 0.4).clamp(0.0, 1.0),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Opacity(
                  opacity: (t / 0.14).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.94 + 0.06 * formation,
                    child: CanvasMark(size: 84, progress: formation),
                  ),
                ),
                const SizedBox(height: LcSpace.lg),
                Opacity(
                  opacity: rise,
                  child: Transform.translate(
                    offset: Offset(0, 10 * (1 - rise)),
                    child: const Wordmark(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
