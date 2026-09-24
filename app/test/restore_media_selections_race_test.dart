/// A restore does not race the hand-over (T-0313).
///
/// [WorkflowFormController.restoreMediaSelections] awaits inside its loop, so
/// every await in it is a window another writer to the form's media map can
/// run in. There are exactly two such writers — `_handOver`, which a form
/// built for a changed schema calls on the form it replaces, and `dispose`,
/// which clears the map — and both were reached while a restore was suspended
/// on GitHub Actions run 35443397005, throwing
/// `Concurrent modification during iteration: _Map len:0`.
///
/// The gap is held open here by a source whose `isAvailable()` the test
/// controls, so the writer lands **inside** it every run rather than when a
/// scheduler happens to oblige.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/media/media_api.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';

import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

/// A [GatedMediaSource.holdFromCall] no run reaches: the source answers at
/// once, and is there to be counted rather than held.
const int unheld = 1 << 30;

/// A source whose availability check the test opens and closes by hand.
///
/// `MediaFieldController.restoreSelection` awaits exactly this call, so a gate
/// on it is a gate on the restore's own await — the point the failure needs
/// something else to run at.
class GatedMediaSource implements MediaSource {
  GatedMediaSource({this.exists = true, this.holdFromCall = 1});

  /// What the check answers once it is let go. `false` is the lapsed
  /// permission `docs/recovery.md` describes.
  final bool exists;

  /// The first call that is held. Calls before it answer straight away, which
  /// is how a test can let an earlier restore run to completion and hold only
  /// the one it is about.
  final int holdFromCall;

  /// Every call to [isAvailable], counted — so a controller that was *not*
  /// checked is an assertion and not an assumption.
  int asked = 0;

  /// Completes when a held call has suspended. Awaiting it puts the test
  /// inside the restore's await gap, deterministically.
  final Completer<void> suspended = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  /// Lets the held check answer.
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<bool> isAvailable() async {
    asked++;
    if (asked < holdFromCall) return exists;
    if (!suspended.isCompleted) suspended.complete();
    await _gate.future;
    return exists;
  }

  @override
  Future<int?> byteLength() async => 4;

  @override
  Stream<List<int>> openRead() async* {
    yield const <int>[1, 2, 3, 4];
  }

  @override
  File? get previewFile => null;
}

/// img2img with a second picture field, so the loop has an iteration left to
/// take after the one that was suspended.
Map<String, Object?> twoPictureDetail() {
  final body = img2imgDetail();
  return <String, Object?>{
    ...body,
    'inputs': <Object?>[
      ...body['inputs']! as List<Object?>,
      <String, Object?>{
        'id': 'mask_image',
        'label': 'Mask',
        'type': 'image',
        'required': false,
        'section': 'main',
      },
    ],
  };
}

/// The same, with the second field retyped to a clip — the one case
/// `_handOver` refuses, so the old form keeps that controller.
Map<String, Object?> maskAsClipDetail() {
  final body = twoPictureDetail();
  return <String, Object?>{
    ...body,
    'inputs': <Object?>[
      for (final raw in body['inputs']! as List<Object?>)
        if ((raw! as Map<String, Object?>)['id'] == 'mask_image')
          <String, Object?>{...raw as Map<String, Object?>, 'type': 'video'}
        else
          raw,
    ],
  };
}

/// A PC serving one workflow whose schema the test edits between requests.
class EditableSinglePc implements WorkflowsApi {
  Map<String, Object?> body = twoPictureDetail();

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async =>
      WorkflowSummary.listFromJson(registryOf(<Map<String, Object?>>[body]));

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) async =>
      WorkflowDetail.tryFromJson(body)!;
}

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;
  late ScriptedMediaPicker picker;

  setUp(() {
    picker = ScriptedMediaPicker();
  });

  /// An upload that never lands, so the field keeps its selection and is not
  /// `ready` — the state `restoreSelection` actually re-checks.
  Future<UploadedMedia> refusedUpload(
    MediaSelection selection,
    MediaProgress onProgress,
  ) async => throw const MediaFailure.unreachable();

  WorkflowFormController formOf(
    Map<String, Object?> body, {
    WorkflowFormController? takingMediaFrom,
  }) => WorkflowFormController(
    WorkflowDetail.tryFromJson(body)!,
    picker: picker,
    uploader: refusedUpload,
    takingMediaFrom: takingMediaFrom,
  );

  /// Puts [source] into [fieldId] as a chosen file the upload refused.
  Future<void> chooseInto(
    WorkflowFormController form,
    String fieldId,
    GatedMediaSource source,
  ) async {
    picker.answers = <MediaSelection?>[
      MediaSelection(
        kind: MediaKind.image,
        source: source,
        filename: 'picture.jpg',
        byteCount: 4,
      ),
    ];
    final media = form.media(fieldId)!;
    await media.choose();
    expect(media.phase, MediaPhase.failed, reason: 'chosen, and not ready');
    expect(media.selection, isNotNull);
  }

  group('the hand-over lands inside the restore', () {
    test('a form that gave every controller away finishes its restore, and '
        'checks none of them again', () async {
      final old = formOf(twoPictureDetail());
      final first = GatedMediaSource();
      final second = GatedMediaSource(holdFromCall: unheld);
      await chooseInto(old, 'source_image', first);
      await chooseInto(old, 'mask_image', second);
      final handed = old.media('mask_image');

      final restoring = old.restoreMediaSelections();
      await first.suspended.future;
      expect(first.asked, 1, reason: 'suspended on the first field');
      expect(second.asked, 0, reason: 'the loop has not got there yet');

      // The mutation: the replacement form takes both controllers out of
      // `old`'s map while the loop above is suspended.
      final replacement = formOf(twoPictureDetail(), takingMediaFrom: old);
      addTearDown(replacement.dispose);
      expect(old.media('source_image'), isNull, reason: 'given away');
      expect(old.media('mask_image'), isNull, reason: 'given away');

      first.release();
      await restoring;

      expect(
        second.asked,
        0,
        reason: 'a controller it no longer owns is not its to check',
      );
      expect(identical(replacement.media('mask_image'), handed), isTrue);
      old.dispose();
    });

    test('a controller the hand-over refused is still restored by the form '
        'that kept it', () async {
      final old = formOf(twoPictureDetail());
      final first = GatedMediaSource();
      final second = GatedMediaSource(holdFromCall: unheld);
      await chooseInto(old, 'source_image', first);
      await chooseInto(old, 'mask_image', second);
      final kept = old.media('mask_image');

      final restoring = old.restoreMediaSelections();
      await first.suspended.future;

      // `mask_image` is a clip in the new schema, so `_handOver` refuses it
      // and it stays here — while `source_image` leaves.
      final replacement = formOf(maskAsClipDetail(), takingMediaFrom: old);
      addTearDown(replacement.dispose);
      expect(old.media('source_image'), isNull, reason: 'given away');
      expect(identical(old.media('mask_image'), kept), isTrue, reason: 'kept');

      first.release();
      await restoring;

      expect(second.asked, 1, reason: 'still ours, so still checked');
      old.dispose();
    });

    test('a file that is gone still empties the field, in the form that now '
        'owns the controller', () async {
      final old = formOf(twoPictureDetail());
      final vanished = GatedMediaSource(exists: false);
      await chooseInto(old, 'source_image', vanished);

      final replacement = formOf(twoPictureDetail(), takingMediaFrom: old);
      addTearDown(replacement.dispose);
      old.dispose();

      vanished.release();
      await replacement.restoreMediaSelections();

      final media = replacement.media('source_image')!;
      expect(media.selection, isNull);
      expect(media.phase, MediaPhase.empty);
      expect(
        replacement.validate().issueFor('source_image')?.kind,
        FieldIssueKind.missing,
        reason: 'the requirement is showing again (docs/recovery.md)',
      );
    });
  });

  group('the dispose lands inside the restore', () {
    test('a form disposed while a restore is suspended finishes it, and '
        'checks nothing further', () async {
      final form = formOf(twoPictureDetail());
      final first = GatedMediaSource();
      final second = GatedMediaSource(holdFromCall: unheld);
      await chooseInto(form, 'source_image', first);
      await chooseInto(form, 'mask_image', second);

      final restoring = form.restoreMediaSelections();
      await first.suspended.future;

      // The mutation the CI runner hit: the test's own tearDown disposed the
      // controller while this restore was still out on `File.exists`, and
      // dispose clears the map the loop is walking.
      form.dispose();

      first.release();
      await restoring;

      expect(second.asked, 0, reason: 'a disposed form checks nothing');
    });
  });

  group('through the controller, as the runner hit it', () {
    test('a schema swap whose restore is still out when the app is torn '
        'down does not throw', () async {
      final pc = EditableSinglePc();
      final uploads = ScriptedMediaApi()
        ..failure = const MediaFailure.unreachable();
      final controller = WorkflowsController(
        api: pc,
        mediaPicker: picker,
        mediaApi: uploads,
      );
      await controller.load(endpoint);
      await controller.select('example_img2img');

      final form = controller.form!;
      // The first check belongs to the refresh's own restore of this form;
      // the second is the replacement form's, inside `_replaceForm`.
      final source = GatedMediaSource(holdFromCall: 2);
      picker.answers = <MediaSelection?>[
        MediaSelection(
          kind: MediaKind.image,
          source: source,
          filename: 'picture.jpg',
          byteCount: 4,
        ),
      ];
      final media = form.media('source_image')!;
      // The upload is refused, so the field keeps its selection and is not
      // `ready` — which is all `restoreSelection` asks before it checks.
      await media.choose();
      expect(media.selection, isNotNull);
      expect(media.phase, MediaPhase.failed);

      pc.body = maskAsClipDetail();
      await controller.refresh();
      await source.suspended.future;
      expect(source.asked, 2, reason: 'the new form is restoring it');
      expect(identical(controller.form, form), isFalse, reason: 'swapped');

      // Exactly what the failing test's tearDown did.
      controller.dispose();
      source.release();
      await pumpEventQueue();
    });
  });
}
