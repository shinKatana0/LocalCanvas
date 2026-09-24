/// The Android clip inspector gives up without waiting for a release that may
/// never come (T-0231).
///
/// `VideoPlayerController.dispose` (video_player 2.14.0) first waits for the
/// platform player to have been *created*. Under `flutter test` there is no
/// platform: `VideoPlayerPlatform.instance` is the package's placeholder,
/// whose `init` throws inside `initialize` after the controller has started
/// waiting for creation and before creation can complete. So a real
/// controller here is exactly a player whose creation never completes, and
/// its `dispose` never returns — which the first test establishes rather than
/// assumes.
///
/// That `dispose` is asked for at all is shown separately, through the
/// inspector's `open` seam: a controller whose `initialize` throws and which
/// records the calls made on it.
///
/// What this file cannot show: that a player created *late* is released once
/// it is. That is video_player's own ordering, and seeing it needs a fake
/// `VideoPlayerPlatform` (a dev dependency this app does not have) or a device
/// (T-0232).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/generation/platform_clip_inspector.dart';
import 'package:localcanvas/media/clip_inspector.dart';
import 'package:video_player/video_player.dart';

import 'support/media_fakes.dart';

/// Well inside [kClipInspectionBound]: an answer later than this is not the
/// prompt one under test, and a future that never completes is reported as
/// such instead of hanging the suite.
const Duration _patience = Duration(seconds: 1);

const String _neverReturned = 'never returned';

Future<Object?> _settled(Future<Object?> future) => future
    .then<Object?>((value) => value, onError: (Object error) => error)
    .timeout(_patience, onTimeout: () => _neverReturned);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'premise: here, a controller whose creation failed never disposes',
    () async {
      final controller = VideoPlayerController.file(
        writeTempMedia('holiday.mp4', bytes: 8400),
      );

      final initialized = await _settled(
        controller.initialize().then<Object?>((_) => 'initialized'),
      );
      expect(initialized, isA<UnimplementedError>());

      final disposed = await _settled(
        controller.dispose().then<Object?>((_) => 'disposed'),
      );
      expect(disposed, _neverReturned);
    },
  );

  test(
    'a player that is never created is a failure at once, not a hang',
    () async {
      final clip = writeTempMedia('holiday.mp4', bytes: 8400);
      final watch = Stopwatch()..start();

      final outcome = await _settled(
        const PlatformClipInspector()
            .inspect(clip)
            .then<Object?>((_) => 'opened'),
      );

      expect(outcome, isA<ClipInspectionFailure>());
      expect(watch.elapsed, lessThan(_patience));
    },
  );

  test('a controller that fails to open is asked to release', () async {
    final clip = writeTempMedia('holiday.mp4', bytes: 8400);
    final opened = <_RecordingController>[];
    final inspector = PlatformClipInspector(
      open: (file) {
        final controller = _RecordingController(file);
        opened.add(controller);
        return controller;
      },
    );

    final outcome = await _settled(
      inspector.inspect(clip).then<Object?>((_) => 'opened'),
    );
    // The release is started, not awaited: let it run.
    await Future<void>.delayed(Duration.zero);

    expect(outcome, isA<ClipInspectionFailure>());
    final controller = opened.single;
    expect(controller.dataSource, Uri.file(clip.absolute.path).toString());
    expect(controller.calls, <String>['initialize', 'dispose']);
  });
}

/// A real `VideoPlayerController` for [clip] that cannot be opened, and that
/// records what it was asked to do. Its `dispose` is the controller's own
/// once recorded: with no `initialize` of the package's, there is no creation
/// to wait for, so it returns.
class _RecordingController extends VideoPlayerController {
  _RecordingController(super.file) : super.file();

  final List<String> calls = <String>[];

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    throw StateError('this clip cannot be opened');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await super.dispose();
  }
}
