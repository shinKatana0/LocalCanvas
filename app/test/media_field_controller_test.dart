/// One media field's life: chosen, going, arrived — and the two ways it can
/// end up empty again.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';

import 'support/l10n.dart';
import 'support/media_fakes.dart';

/// A real file whose `isAvailable` answer is held until the test lets it go.
///
/// The answer itself is the file's own: [FileMediaSource.isAvailable] is asked
/// once the gate opens, so a file deleted before the release answers false.
class HeldAvailabilitySource implements MediaSource {
  HeldAvailabilitySource(this.file);

  final FileMediaSource file;

  /// Taken by the next check, which waits on it.
  Completer<void>? gate;

  int asked = 0;
  final List<bool> answers = <bool>[];

  @override
  Future<bool> isAvailable() async {
    asked++;
    final pending = gate;
    gate = null;
    if (pending != null) await pending.future;
    final answer = await file.isAvailable();
    answers.add(answer);
    return answer;
  }

  @override
  Future<int?> byteLength() => file.byteLength();

  @override
  Stream<List<int>> openRead() => file.openRead();

  @override
  File? get previewFile => file.previewFile;
}

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;

  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;

  MediaFieldController fieldOf({
    MediaKind kind = MediaKind.image,
    bool withPicker = true,
  }) {
    final controller = MediaFieldController(
      kind: kind,
      picker: withPicker ? picker : null,
      uploader: withPicker
          ? (selection, onProgress) =>
                uploads.upload(endpoint, selection, onProgress: onProgress)
          : null,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
  });

  group('choosing', () {
    test('a chosen file is uploaded there and then, not at Generate',
        () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      final field = fieldOf();

      await field.choose();

      expect(picker.asked, <MediaKind>[MediaKind.image]);
      expect(uploads.calls, 1);
      expect(field.phase, MediaPhase.ready);
      expect(field.mediaId, 'm-3f9c1a-1');
      expect(field.selection?.displayName(en), 'IMG_0142.jpg');
    });

    test('a clip asks the picker for a clip', () async {
      picker.answers = <MediaSelection?>[
        tempSelection(kind: MediaKind.video, name: 'clip.mp4'),
      ];
      await fieldOf(kind: MediaKind.video).choose();

      expect(picker.asked, <MediaKind>[MediaKind.video]);
    });

    test('backing out of the picker is a decision, not a failure', () async {
      picker.answers = <MediaSelection?>[null];
      final field = fieldOf();

      await field.choose();

      expect(field.phase, MediaPhase.empty);
      expect(field.selection, isNull);
      expect(field.failure, isNull);
      expect(uploads.calls, 0);
    });

    test('a picker that refuses says what to do, and the field stays empty',
        () async {
      picker.failure = const MediaFailure.notAllowed();
      final field = fieldOf();

      await field.choose();

      expect(field.phase, MediaPhase.empty);
      expect(field.selection, isNull);
      expect(field.failure?.title(en), 'That file could not be opened.');
      expect(uploads.calls, 0);
    });

    test('a second tap while the picker is open opens nothing', () async {
      picker
        ..answers = <MediaSelection?>[tempSelection()]
        ..gate = Completer<void>();
      final field = fieldOf();

      final first = field.choose();
      expect(field.isPicking, isTrue);
      await field.choose();
      picker.gate!.complete();
      await first;

      expect(picker.calls, 1);
    });

    test('a build with no picker behind it does not offer one', () async {
      final field = fieldOf(withPicker: false);

      expect(field.canChoose, isFalse);
      await field.choose();

      expect(picker.calls, 0);
      expect(field.phase, MediaPhase.empty);
    });
  });

  group('progress, and only real progress', () {
    test('a known length is a fraction of bytes actually sent', () async {
      picker.answers = <MediaSelection?>[tempSelection(bytes: 1000)];
      uploads.manual = true;
      final field = fieldOf();

      final pending = field.choose();
      await pumpEventQueue();

      expect(field.phase, MediaPhase.uploading);
      expect(field.progress, 0.0);

      uploads.report(250, 1000);
      expect(field.progress, 0.25);
      expect(field.progressLabel(en), 'Uploading… 250 bytes of 1.0 kB');

      uploads.report(1000, 1000);
      expect(
        field.progress,
        isNull,
        reason: 'every byte is gone and the server has not answered; how long '
            'that takes is not something the app knows',
      );
      expect(field.progressLabel(en), 'Finishing…');

      uploads.finish();
      await pending;
      expect(field.phase, MediaPhase.ready);
    });

    test('an unknown length is indeterminate and never becomes a number',
        () async {
      picker.answers = <MediaSelection?>[
        tempSelection(bytes: 1000, knownSize: false),
      ];
      uploads.manual = true;
      final field = fieldOf();

      final pending = field.choose();
      await pumpEventQueue();

      expect(field.totalBytes, isNull);
      expect(field.progress, isNull);
      expect(field.progressLabel(en), 'Uploading…');

      uploads.report(700, null);
      expect(field.progress, isNull);
      expect(field.sentBytes, 700);
      expect(field.progressLabel(en), 'Uploading…');

      uploads.finish();
      await pending;
    });

    test('nothing is reported once the upload is over', () async {
      picker.answers = <MediaSelection?>[tempSelection(bytes: 1000)];
      final field = fieldOf();
      await field.choose();

      expect(field.phase, MediaPhase.ready);
      expect(field.progress, isNull);
    });
  });

  group('replace, remove and retry', () {
    test('the id is kept, so nothing is uploaded twice', () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final field = fieldOf();
      await field.choose();

      final id = field.mediaId;
      // Whatever else happens, reading the field's state does not re-send it.
      expect(field.mediaId, id);
      expect(field.mediaId, id);
      expect(uploads.calls, 1);
    });

    test('replacing sends the new file and forgets the old id', () async {
      picker.answers = <MediaSelection?>[
        tempSelection(name: 'first.jpg'),
        tempSelection(name: 'second.jpg'),
      ];
      final field = fieldOf();
      await field.choose();
      final first = field.mediaId;

      await field.choose();

      expect(uploads.calls, 2);
      expect(field.selection?.displayName(en), 'second.jpg');
      expect(field.mediaId, isNot(first));
    });

    test('a reply from a replaced upload is dropped, not written back',
        () async {
      picker.answers = <MediaSelection?>[
        tempSelection(name: 'first.jpg'),
        tempSelection(name: 'second.jpg'),
      ];
      uploads.manual = true;
      final field = fieldOf();

      final first = field.choose();
      await pumpEventQueue();
      // The user changes their mind before the first one lands.
      uploads.manual = false;
      await field.choose();
      expect(field.selection?.displayName(en), 'second.jpg');
      final settled = field.mediaId;

      uploads.finish();
      await first;

      // The held reply carries its own id, so both of these can fail: the
      // stale upload would write its own id and its own selection back.
      expect(field.mediaId, settled);
      expect(field.selection?.displayName(en), 'second.jpg');
    });

    test('remove puts the field back to empty', () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final field = fieldOf();
      await field.choose();

      field.remove();

      expect(field.phase, MediaPhase.empty);
      expect(field.selection, isNull);
      expect(field.mediaId, isNull);
    });

    test('a failed upload says why and can be tried again with the same file',
        () async {
      picker.answers = <MediaSelection?>[tempSelection(name: 'holiday.jpg')];
      uploads.failure = const MediaFailure.unreachable();
      final field = fieldOf();
      await field.choose();

      expect(field.phase, MediaPhase.failed);
      expect(field.failure?.title(en), "The server didn't take the upload.");
      expect(field.selection?.displayName(en), 'holiday.jpg');

      uploads.failure = null;
      await field.retry();

      expect(picker.calls, 1, reason: 'retrying is not a second choice');
      expect(uploads.calls, 2);
      expect(field.phase, MediaPhase.ready);
      expect(field.mediaId, isNotNull);
    });

    test('retry does nothing when there is nothing to retry', () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final field = fieldOf();
      await field.choose();

      await field.retry();

      expect(uploads.calls, 1);
    });
  });

  group('a selection that has lapsed', () {
    test('a file that is gone is dropped on restore, not at upload', () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      uploads.failure = const MediaFailure.unreachable();
      final field = fieldOf();
      await field.choose();
      expect(field.selection, isNotNull);

      // What a lapsed Android permission looks like from here: the bytes are
      // no longer readable.
      File((selection.source as FileMediaSource).path).deleteSync();
      await field.restoreSelection();

      expect(field.phase, MediaPhase.empty);
      expect(field.selection, isNull);
      expect(field.failure, isNull);
    });

    test('a file that is still there survives restore untouched', () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      uploads.failure = const MediaFailure.unreachable();
      final field = fieldOf();
      await field.choose();

      await field.restoreSelection();

      expect(field.phase, MediaPhase.failed);
      expect(field.selection, isNotNull);
    });

    test('an already uploaded file does not need its local copy any more',
        () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      final field = fieldOf();
      await field.choose();
      expect(field.phase, MediaPhase.ready);

      File((selection.source as FileMediaSource).path).deleteSync();
      await field.restoreSelection();

      expect(field.phase, MediaPhase.ready);
      expect(field.mediaId, isNotNull);
    });
  });

  // T-0237. The re-check awaits the file system, and a person can choose a new
  // picture while it does. The answer is held open here, by a source that asks
  // the real file only once the test lets it — so the file's own `exists` is
  // what answers, just late.
  //
  // The order released is the order a phone produces: `File.exists` is a local
  // call and answers in milliseconds, while an upload over Wi-Fi takes seconds,
  // so the new picture is still uploading when the old answer lands.
  group('a re-check that answers after something else was chosen', () {
    test('a picture chosen while the check was out is not removed', () async {
      final gone = tempSelection(name: 'gone.jpg');
      final held = HeldAvailabilitySource(gone.source as FileMediaSource);
      final first = MediaSelection(
        kind: gone.kind,
        source: held,
        filename: gone.filename,
        byteCount: gone.byteCount,
      );
      final next = tempSelection(name: 'next.jpg');
      picker.answers = <MediaSelection?>[first, next];
      uploads.failure = const MediaFailure.unreachable();
      final field = fieldOf();
      await field.choose();
      expect(field.phase, MediaPhase.failed, reason: 'so it is re-checked');
      File(held.file.path).deleteSync();

      final gate = held.gate = Completer<void>();
      final restoring = field.restoreSelection();
      await pumpEventQueue();
      expect(held.asked, 1, reason: 'the check is out');

      uploads
        ..failure = null
        ..manual = true;
      final choosing = field.choose();
      await pumpEventQueue();
      expect(identical(field.selection, next), isTrue);
      expect(field.phase, MediaPhase.uploading);

      gate.complete();
      await restoring;
      expect(held.answers, <bool>[false], reason: 'the old file really is gone');

      expect(identical(field.selection, next), isTrue);
      expect(field.phase, MediaPhase.uploading);

      uploads.finish();
      await choosing;
      expect(field.phase, MediaPhase.ready);
      expect(field.mediaId, 'm-3f9c1a-2');
      expect(field.selection?.displayName(en), 'next.jpg');
    });

    test('a vanished file nothing replaced is still dropped when the late '
        'answer comes', () async {
      final gone = tempSelection(name: 'gone.jpg');
      final held = HeldAvailabilitySource(gone.source as FileMediaSource);
      picker.answers = <MediaSelection?>[
        MediaSelection(
          kind: gone.kind,
          source: held,
          filename: gone.filename,
          byteCount: gone.byteCount,
        ),
      ];
      uploads.failure = const MediaFailure.unreachable();
      final field = fieldOf();
      await field.choose();
      File(held.file.path).deleteSync();

      final gate = held.gate = Completer<void>();
      final restoring = field.restoreSelection();
      await pumpEventQueue();
      expect(field.selection, isNotNull, reason: 'nothing acted yet');

      gate.complete();
      await restoring;

      expect(held.answers, <bool>[false]);
      expect(field.phase, MediaPhase.empty);
      expect(field.selection, isNull);
    });
  });

  test('the size the gateway counted replaces the one the picker guessed',
      () async {
    picker.answers = <MediaSelection?>[tempSelection(bytes: 2048)];
    uploads.reportedByteCount = 2481923;
    final field = fieldOf();

    await field.choose();

    expect(field.selection?.byteCount, 2481923);
  });
}
