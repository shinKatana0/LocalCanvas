/// The form's output: a validated input map keyed by field id, and an honest
/// account of what stands between it and Generate (`docs/api.md`).
library;

import 'support/l10n.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';

import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

void main() {
  final endpoint = Endpoint.tryParse('192.0.2.42')!;
  late ScriptedMediaPicker picker;
  late ScriptedMediaApi uploads;

  setUp(() {
    picker = ScriptedMediaPicker();
    uploads = ScriptedMediaApi();
  });

  /// A form with no picker behind it: the build that can render a media field
  /// but not fill one.
  WorkflowFormController formOf(Map<String, Object?> body) {
    final controller = WorkflowFormController(
      WorkflowDetail.tryFromJson(body)!,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// A form wired to a picker and an upload, as the app assembles it.
  WorkflowFormController mediaFormOf(Map<String, Object?> body) {
    final controller = WorkflowFormController(
      WorkflowDetail.tryFromJson(body)!,
      picker: picker,
      uploader: (selection, onProgress) =>
          uploads.upload(endpoint, selection, onProgress: onProgress),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('defaults', () {
    test('every field starts at what the registry declared', () {
      final form = formOf(txt2imgDetail());

      expect(form.text('prompt'), '');
      expect(form.text('negative_prompt'), '');
      expect(form.text('width'), '768');
      expect(form.text('steps'), '20');
      expect(form.text('guidance'), '6');
      expect(form.entry('sampler'), 'euler');
      expect(form.text('seed'), '0');
    });

    test('a float default keeps its own precision', () {
      final form = formOf(img2imgDetail());
      expect(form.text('strength'), '0.55');
    });

    test('a boolean with no declared default is off, not null', () {
      final form = formOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{'id': 'loop', 'label': 'Loop', 'type': 'boolean'},
        ],
      });
      expect(form.flag('loop'), isFalse);
      expect(form.validate().inputs, <String, Object?>{'loop': false});
    });

    test('a select default that names no option leaves the field unchosen', () {
      final form = formOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{
            'id': 'sampler',
            'label': 'Sampler',
            'type': 'select',
            'required': true,
            'default': 'not_an_option',
            'options': <Object?>[
              <String, Object?>{'value': 'euler', 'label': 'Euler'},
            ],
          },
        ],
      });
      expect(form.entry('sampler'), isNull);
      expect(form.validate().issueFor('sampler')?.kind, FieldIssueKind.missing);
    });
  });

  group('the input map', () {
    test('a filled prompt-only workflow comes out keyed by field id', () {
      final form = formOf(txt2imgDetail())
        ..setEntry('prompt', 'a rainy alley at night');

      final validated = form.validate();
      expect(validated.isReady, isTrue);
      expect(validated.blockedReason(en), isNull);
      expect(validated.inputs, <String, Object?>{
        'prompt': 'a rainy alley at night',
        'negative_prompt': '',
        'width': 768,
        'height': 768,
        'steps': 20,
        'guidance': 6.0,
        'sampler': 'euler',
        'seed': 0,
      });
      expect(validated.inputs['width'], isA<int>());
      expect(validated.inputs['guidance'], isA<double>());
    });

    test('nothing in the map is a node, a type or a binding', () {
      final form = formOf(txt2imgDetail())..setEntry('prompt', 'x');
      final validated = form.validate();

      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      expect(
        validated.inputs.keys.toSet(),
        isNot(contains('bind')),
      );
      expect(
        validated.inputs.keys,
        everyElement(isIn(detail.inputs.map((f) => f.id))),
      );
    });

    test('an optional field the user emptied is left out entirely', () {
      final form = formOf(txt2imgDetail())
        ..setEntry('prompt', 'x')
        ..setEntry('steps', '');

      final inputs = form.validate().inputs;
      expect(inputs.containsKey('steps'), isFalse);
      expect(form.validate().isReady, isTrue);
    });

    test('an optional field with no default and no value is left out', () {
      final form = formOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{'id': 'note', 'label': 'Note', 'type': 'string'},
        ],
      });
      expect(form.validate().inputs, isEmpty);
      expect(form.validate().isReady, isTrue);
    });

    test('an optional media field is absent rather than null', () {
      final form = formOf(allTypesDetail())..setEntry('prompt', 'x');
      final inputs = form.validate().inputs;
      expect(inputs.containsKey('source_image'), isFalse);
      expect(inputs.containsKey('source_clip'), isFalse);
      expect(form.validate().isReady, isTrue);
    });
  });

  group('what stands in the way', () {
    test('a required field left empty is named, and Generate says so', () {
      final validated = formOf(txt2imgDetail()).validate();

      expect(validated.isReady, isFalse);
      expect(validated.issues.single.kind, FieldIssueKind.missing);
      expect(validated.blockedReason(en), 'Generate needs Prompt.');
    });

    test('two missing fields are named together', () {
      final validated = formOf(img2imgDetail()).validate();

      expect(
        validated.issues.map((i) => i.fieldId),
        <String>['source_image', 'prompt'],
      );
      expect(
        validated.blockedReason(en),
        startsWith('Generate needs Source image and Prompt.'),
      );
    });

    test('whitespace is not an answer to a required field', () {
      final form = formOf(txt2imgDetail())..setEntry('prompt', '   \n ');
      expect(form.validate().isReady, isFalse);
    });

    test('a build with no picker says so rather than offering a dead control',
        () {
      final form = formOf(img2imgDetail())..setEntry('prompt', 'x');
      final validated = form.validate();

      expect(
        validated.issueFor('source_image')?.kind,
        FieldIssueKind.notSelectableYet,
      );
      expect(
        validated.blockedReason(en),
        contains('Choosing a picture or a clip is not available on this '
            'device.'),
      );
      // And the map never invents a value for it.
      expect(validated.inputs.containsKey('source_image'), isFalse);
    });

    test('a number that is not one is reported as itself', () {
      final form = formOf(txt2imgDetail())
        ..setEntry('prompt', 'x')
        ..setEntry('steps', '12.5');

      final validated = form.validate();
      expect(validated.issueFor('steps')?.kind, FieldIssueKind.notANumber);
      expect(validated.blockedReason(en), 'Steps has to be a whole number.');
    });

    test('a number outside the declared range names the range', () {
      final form = formOf(txt2imgDetail())
        ..setEntry('prompt', 'x')
        ..setEntry('steps', '900');

      final validated = form.validate();
      expect(validated.issueFor('steps')?.kind, FieldIssueKind.outOfRange);
      expect(validated.blockedReason(en), 'Steps has to be between 1 and 50.');
    });

    test('a wrong value is reported before a merely absent one', () {
      final form = formOf(txt2imgDetail())..setEntry('steps', '900');
      // Prompt is missing too, and the specific problem is the useful one.
      expect(form.validate().blockedReason(en), 'Steps has to be between 1 and 50.');
    });

    test('a required field of an unknown type is said out loud', () {
      final body = txt2imgDetail();
      (body['inputs']! as List<Object?>).add(<String, Object?>{
        'id': 'mask',
        'label': 'Mask',
        'type': 'mask',
        'required': true,
        'section': 'main',
      });

      final form = formOf(body)..setEntry('prompt', 'x');
      final validated = form.validate();
      expect(
        validated.issueFor('mask')?.kind,
        FieldIssueKind.unsupportedType,
      );
      expect(
        validated.blockedReason(en),
        contains('cannot show yet'),
      );
      expect(validated.inputs.containsKey('mask'), isFalse);
    });

    test('three missing fields read as a sentence, not a list dump', () {
      final form = formOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          for (final label in <String>['One', 'Two', 'Three'])
            <String, Object?>{
              'id': label.toLowerCase(),
              'label': label,
              'type': 'string',
              'required': true,
            },
        ],
      });
      expect(form.validate().blockedReason(en), 'Generate needs One, Two and Three.');
    });
  });

  group('hints are hints', () {
    test('the same values validate identically without role and pair', () {
      final hinted = formOf(txt2imgDetail())..setEntry('prompt', 'a cat');
      final plain = formOf(withoutHints(txt2imgDetail()))
        ..setEntry('prompt', 'a cat');

      expect(plain.detail.inputs.every((f) => f.role == null), isTrue);
      expect(plain.detail.inputs.every((f) => f.pair == null), isTrue);
      expect(plain.validate().inputs, hinted.validate().inputs);
      expect(plain.validate().isReady, hinted.validate().isReady);
    });

    test('a hint-free seed is still an editable, valid number', () {
      final plain = formOf(withoutHints(txt2imgDetail()))
        ..setEntry('prompt', 'a cat')
        ..setEntry('seed', '123456');

      final validated = plain.validate();
      expect(validated.isReady, isTrue);
      expect(validated.inputs['seed'], 123456);
    });
  });

  group('numbers on the way in and out', () {
    test('a slider value is written at the step\'s own precision', () {
      final form = formOf(img2imgDetail());
      final strength = form.detail.inputs.firstWhere((f) => f.id == 'strength');

      form.setNumber(strength, 0.35000000000000003);
      expect(form.text('strength'), '0.35');
      form.setNumber(strength, 1.0);
      expect(form.text('strength'), '1');
    });

    test('a default finer than the step survives being shown', () {
      final form = formOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{
            'id': 'fine',
            'label': 'Fine',
            'type': 'float',
            'default': 0.125,
          },
        ],
      });
      expect(form.text('fine'), '0.125');
      expect(form.validate().inputs['fine'], 0.125);
    });
  });

  test('what may be kept as a default is the settings and nothing else', () {
    // The form's own half of the rule, tested where it is written rather than
    // through the store — which scopes a save to the same set, so between them
    // it takes two independent mistakes for a prompt to be written down.
    final form = mediaFormOf(allTypesDetail())
      ..setEntry('prompt', 'a lighthouse in a storm')
      ..setEntry('title', 'Seascapes');

    expect(form.keepableFieldIds, <String>{
      'steps',
      'strength',
      'loop',
      'sampler',
      'seed',
    });
    expect(form.keepableValues(), <String, Object?>{
      'steps': 20,
      'strength': 0.55,
      'loop': true,
      'sampler': 'euler',
      'seed': 0,
    });
    // The fixture really does carry the prose and the media this excludes.
    expect(form.validate().inputs.containsKey('prompt'), isTrue);
    expect(form.detail.inputs.any((f) => f.type.isMedia), isTrue);
  });

  test('resetting the settings restores the numbers and leaves the prose', () {
    final form = formOf(txt2imgDetail())
      ..setEntry('prompt', 'something')
      ..setEntry('steps', '44');
    form.resetSettingsToWorkflowDefaults();

    expect(form.text('steps'), '20');
    expect(
      form.text('prompt'),
      'something',
      reason: 'a prompt is not a setting; no button in the defaults row may '
          'take one',
    );
  });

  group('media in the input map', () {
    test('a chosen picture reaches the map as its media_id, and nothing else',
        () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final form = mediaFormOf(img2imgDetail())..setEntry('prompt', 'a cat');
      await form.media('source_image')!.choose();

      final validated = form.validate();

      expect(validated.isReady, isTrue);
      expect(validated.blockedReason(en), isNull);
      expect(
        validated.inputs['source_image'],
        <String, Object?>{'media_id': 'm-3f9c1a-1'},
      );
      // Nothing about the file on this phone travels with it.
      expect(validated.inputs['source_image'].toString(), isNot(contains('/')));
    });

    test('the file goes once, however often the map is built', () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final form = mediaFormOf(img2imgDetail())..setEntry('prompt', 'a cat');
      await form.media('source_image')!.choose();

      for (var i = 0; i < 5; i++) {
        expect(form.validate().isReady, isTrue);
      }

      expect(
        uploads.calls,
        1,
        reason: 'a retried submit re-sends the job, never the picture',
      );
    });

    test('a required picture with nothing in it blocks Generate by name', () {
      final form = mediaFormOf(img2imgDetail())..setEntry('prompt', 'a cat');
      final validated = form.validate();

      expect(validated.isReady, isFalse);
      expect(validated.issueFor('source_image')?.kind, FieldIssueKind.missing);
      expect(validated.blockedReason(en), 'Generate needs Source image.');
      expect(validated.inputs.containsKey('source_image'), isFalse);
    });

    test('a picture still going blocks, and says that rather than "missing"',
        () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      uploads.manual = true;
      final form = mediaFormOf(img2imgDetail())..setEntry('prompt', 'a cat');
      final pending = form.media('source_image')!.choose();
      await pumpEventQueue();

      final validated = form.validate();
      expect(validated.isReady, isFalse);
      expect(
        validated.issueFor('source_image')?.kind,
        FieldIssueKind.mediaNotReady,
      );
      expect(validated.blockedReason(en), 'Source image is still uploading.');

      uploads.finish();
      await pending;
      expect(form.validate().isReady, isTrue);
    });

    test('a picture that did not arrive blocks with what to do about it',
        () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      uploads.failure = const MediaFailure.unreachable();
      final form = mediaFormOf(img2imgDetail())..setEntry('prompt', 'a cat');
      await form.media('source_image')!.choose();

      final validated = form.validate();
      expect(validated.isReady, isFalse);
      expect(
        validated.issueFor('source_image')?.kind,
        FieldIssueKind.mediaNotReady,
      );
      expect(
        validated.blockedReason(en),
        startsWith('Source image did not reach the server.'),
      );
    });

    test('an optional picture still going is waited for, never dropped',
        () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      uploads.manual = true;
      final form = mediaFormOf(allTypesDetail())..setEntry('prompt', 'a cat');
      final pending = form.media('source_image')!.choose();
      await pumpEventQueue();

      expect(
        form.validate().isReady,
        isFalse,
        reason: 'silently running the workflow without a picture the user '
            'chose would be worse than making them wait',
      );

      uploads.finish();
      await pending;
      expect(form.validate().inputs.containsKey('source_image'), isTrue);
    });

    test('an optional media field nobody touched is still absent', () {
      final form = mediaFormOf(allTypesDetail())..setEntry('prompt', 'a cat');
      final validated = form.validate();

      expect(validated.isReady, isTrue);
      expect(validated.inputs.containsKey('source_image'), isFalse);
      expect(validated.inputs.containsKey('source_clip'), isFalse);
    });

    test('a lapsed permission empties the field on restore, with its reason',
        () async {
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      uploads.failure = const MediaFailure.unreachable();
      final form = mediaFormOf(img2imgDetail())..setEntry('prompt', 'a cat');
      final media = form.media('source_image')!;
      await media.choose();
      expect(media.selection, isNotNull);

      File((selection.source as FileMediaSource).path).deleteSync();
      await form.restoreMediaSelections();

      expect(media.phase, MediaPhase.empty);
      final validated = form.validate();
      expect(
        validated.issueFor('source_image')?.kind,
        FieldIssueKind.missing,
        reason: 'the requirement is visible again, rather than an upload '
            'failure the user meets after pressing Generate',
      );
      expect(validated.blockedReason(en), 'Generate needs Source image.');
    });

    test('resetting the settings leaves a chosen picture where it is',
        () async {
      picker.answers = <MediaSelection?>[tempSelection()];
      final form = mediaFormOf(img2imgDetail())
        ..setEntry('prompt', 'a cat')
        ..setEntry('strength', '0.9');
      await form.media('source_image')!.choose();
      expect(form.media('source_image')!.phase, MediaPhase.ready);

      form.resetSettingsToWorkflowDefaults();

      // The uploaded picture is not a setting either. It survives, and so
      // does the map entry that would have been sent with it.
      expect(form.media('source_image')!.phase, MediaPhase.ready);
      expect(form.validate().inputs.containsKey('source_image'), isTrue);
      expect(form.text('prompt'), 'a cat');
      // And the setting really was reset, so this is not a test of a method
      // that did nothing at all.
      expect(form.text('strength'), '0.55');
    });

    test('a non-media field has no media state at all', () {
      final form = mediaFormOf(img2imgDetail());
      expect(form.media('prompt'), isNull);
      expect(form.media('source_image'), isNotNull);
    });
  });

  /// The one rule behind the question a setup asks before it is applied.
  ///
  /// Every test here checks the answer **and** what applying really does, so
  /// none of them can pass on a predicate that agrees with itself: the
  /// question is only worth anything while it describes the replacement.
  group('what applying a setup would take away', () {
    /// A setup for the example workflow, carrying exactly [values] and
    /// nothing else.
    WorkflowSetup setupOf(Map<String, Object?> values) => WorkflowSetup(
      id: 's-1',
      workflowId: 'example_txt2img',
      name: 'Night alley',
      values: values,
    );

    const String written = 'a half-written prompt I care about';

    test('an empty field has nothing to lose, and whitespace is empty', () {
      final form = formOf(txt2imgDetail());
      final setup = setupOf(<String, Object?>{'prompt': 'a rainy alley'});

      expect(form.setupWouldReplaceProse(setup), isFalse);
      form.setEntry('prompt', '   ');
      expect(
        form.setupWouldReplaceProse(setup),
        isFalse,
        reason: 'whitespace alone is what an empty field looks like here',
      );
      // And it applies, which is the half of "asks nothing" that matters.
      form.adoptSetup(setup);
      expect(form.text('prompt'), 'a rainy alley');
    });

    test('the same setup over written text is a loss', () {
      // The state of the world that makes the answers above mean something:
      // this predicate does say yes, and about the same setup.
      final form = formOf(txt2imgDetail());
      final setup = setupOf(<String, Object?>{'prompt': 'a rainy alley'});
      form.setEntry('prompt', written);

      expect(form.setupWouldReplaceProse(setup), isTrue);
      form.adoptSetup(setup);
      expect(form.text('prompt'), 'a rainy alley', reason: 'and it would');
    });

    test('the same words are not a loss, and one character apart is', () {
      final form = formOf(txt2imgDetail());
      form.setEntry('prompt', 'a rainy alley');

      expect(
        form.setupWouldReplaceProse(
          setupOf(<String, Object?>{'prompt': 'a rainy alley'}),
        ),
        isFalse,
      );
      expect(
        form.setupWouldReplaceProse(
          setupOf(<String, Object?>{'prompt': 'a rainy alleyway'}),
        ),
        isTrue,
      );
    });

    test('a setup saved while the prompt was empty would empty a written one',
        () {
      // T-0051's review probe, at the level the rule lives on: a setup
      // made from a form holding only `steps = 44` carries `prompt: ''` — a
      // value, not a missing one.
      final form = formOf(txt2imgDetail());
      final setup = setupOf(<String, Object?>{'prompt': '', 'steps': 44});
      form.setEntry('prompt', written);

      expect(
        form.setupWouldReplaceProse(setup),
        isTrue,
        reason: 'an empty string is different from text somebody typed',
      );
      // Which is exactly what it would do, and why it is asked about.
      form.adoptSetup(setup);
      expect(form.text('prompt'), '');
      expect(form.text('steps'), '44');
    });

    test('a value this workflow cannot hold is never written, so it is not a '
        'loss', () {
      final form = formOf(txt2imgDetail());
      // A number is not something a person typed, so `_adoptDraftable` skips
      // it — and a question about text that would survive anyway is a
      // question with one answer.
      final setup = setupOf(<String, Object?>{'prompt': 44});
      form.setEntry('prompt', written);

      expect(form.setupWouldReplaceProse(setup), isFalse);
      form.adoptSetup(setup);
      expect(form.text('prompt'), written, reason: 'it really was skipped');
    });

    test('a field the setup says nothing about is not a loss', () {
      final form = formOf(txt2imgDetail());
      final setup = setupOf(<String, Object?>{'steps': 44});
      form.setEntry('prompt', written);

      expect(form.setupWouldReplaceProse(setup), isFalse);
      form.adoptSetup(setup);
      expect(form.text('prompt'), written);
      expect(form.text('steps'), '44');
    });

    test('a prose value of null is the same as saying nothing about the field',
        () {
      // Not a curiosity: it is why the `containsKey` guard in the rule cannot
      // be caught changing anything. For prose, an absent key and a `null`
      // both fail `is String`, so both are a non-value — and a stored
      // document can carry either. Pinned here, so the equivalence is a
      // checked fact rather than an argument somebody made once.
      final form = formOf(txt2imgDetail());
      form.setEntry('prompt', written);

      for (final setup in <WorkflowSetup>[
        setupOf(<String, Object?>{'prompt': null, 'steps': 44}),
        setupOf(<String, Object?>{'steps': 44}),
      ]) {
        expect(form.setupWouldReplaceProse(setup), isFalse);
        form.adoptSetup(setup);
        expect(form.text('prompt'), written);
        expect(form.text('steps'), '44');
      }
    });

    test('settings alone never raise the question, however many differ', () {
      final form = formOf(txt2imgDetail());
      final setup = setupOf(<String, Object?>{
        'steps': 44,
        'guidance': 9.5,
        'sampler': 'dpmpp_2m',
        'width': 1024,
      });
      form.setEntry('prompt', written);

      expect(form.setupWouldReplaceProse(setup), isFalse);
      form.adoptSetup(setup);
      expect(form.text('prompt'), written);
      expect(form.text('steps'), '44');
      expect(form.text('guidance'), '9.5');
      expect(form.entry('sampler'), 'dpmpp_2m');
      expect(form.text('width'), '1024');
    });

    test('every prose field is asked about, not the one the schema shows '
        'first', () {
      final form = formOf(txt2imgDetail());
      form
        ..setEntry('prompt', 'a rainy alley')
        ..setEntry('negative_prompt', 'blurry');

      expect(
        form.setupWouldReplaceProse(
          setupOf(<String, Object?>{
            'prompt': 'a rainy alley',
            'negative_prompt': 'grainy',
          }),
        ),
        isTrue,
        reason: 'the second prose field is text somebody wrote too',
      );
      expect(
        form.setupWouldReplaceProse(
          setupOf(<String, Object?>{
            'prompt': 'a rainy alley',
            'negative_prompt': 'blurry',
          }),
        ),
        isFalse,
      );
    });
  });
}
