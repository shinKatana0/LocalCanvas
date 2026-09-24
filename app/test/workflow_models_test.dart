/// The registry as data (`docs/api.md`, `docs/workflow-schema.md`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/workflow_models.dart';

import 'support/workflow_payloads.dart';

void main() {
  group('parsing', () {
    test('a summary carries what the picker card shows', () {
      final workflows = WorkflowSummary.listFromJson(examplesRegistry());

      expect(workflows.map((w) => w.id), <String>[
        'example_txt2img',
        'example_img2img',
        'example_video',
      ]);
      final first = workflows.first;
      expect(first.name, 'Example Text to Image');
      expect(first.presentation.group, 'Create');
      expect(first.presentation.category, 'Example');
      expect(first.presentation.badge, 'TXT2IMG');
      expect(first.presentation.shortDescription, startsWith('A prompt-only'));
      expect(first.inputSummary, 'Prompt only');
      expect(first.requiredMedia, isEmpty);
      expect(workflows[1].requiredMedia, <String>['image']);
      expect(workflows[2].requiredMedia, <String>['video']);
    });

    test('the detail view carries the whole field schema', () {
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;

      expect(detail.inputs.map((f) => f.id), <String>[
        'prompt',
        'negative_prompt',
        'width',
        'height',
        'steps',
        'guidance',
        'sampler',
        'seed',
      ]);
      expect(detail.mainFields.map((f) => f.id), <String>[
        'prompt',
        'width',
        'height',
      ]);
      expect(detail.advancedFields.map((f) => f.id), <String>[
        'negative_prompt',
        'steps',
        'guidance',
        'sampler',
        'seed',
      ]);

      final prompt = detail.inputs.first;
      expect(prompt.type, FieldType.multiline);
      expect(prompt.required, isTrue);
      expect(prompt.section, FieldSection.main);
      expect(prompt.help, 'What you want to see.');

      final width = detail.inputs[2];
      expect(width.type, FieldType.integer);
      expect(width.min, 256);
      expect(width.max, 2048);
      expect(width.step, 64);
      expect(width.pair, FieldPair.width);
      expect(width.hasDefault, isTrue);
      expect(width.defaultValue, 768);

      final sampler = detail.inputs[6];
      expect(sampler.type, FieldType.select);
      expect(sampler.options.map((o) => o.value), <String>[
        'euler',
        'euler_ancestral',
        'dpmpp_2m',
      ]);
      expect(sampler.options[2].label, 'DPM++ 2M');

      expect(detail.inputs.last.role, FieldRole.seed);
    });

    test('a declared default of "" is a default, not an absent one', () {
      final detail = WorkflowDetail.tryFromJson(txt2imgDetail())!;
      final negative = detail.inputs[1];
      expect(negative.hasDefault, isTrue);
      expect(negative.defaultValue, '');

      final prompt = detail.inputs.first;
      expect(prompt.hasDefault, isFalse);
    });

    test('a field type this build has never heard of is honest, not dropped',
        () {
      final body = txt2imgDetail();
      (body['inputs']! as List).add(<String, Object?>{
        'id': 'mask',
        'label': 'Mask',
        'type': 'mask',
        'required': true,
        'section': 'main',
      });

      final detail = WorkflowDetail.tryFromJson(body)!;
      final mask = detail.inputs.last;
      expect(mask.id, 'mask');
      expect(mask.type, FieldType.unsupported);
    });

    test('an unknown role or pair is ignored, and the field survives it', () {
      final detail = WorkflowDetail.tryFromJson(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{
            'id': 'depth',
            'label': 'Depth',
            'type': 'integer',
            'role': 'lucky_number',
            'pair': 'depth',
          },
        ],
      })!;

      final field = detail.inputs.single;
      expect(field.role, isNull);
      expect(field.pair, isNull);
      expect(field.type, FieldType.integer);
    });

    test('presentation entries the registry omitted stay omitted', () {
      final summary = WorkflowSummary.tryFromJson(<String, Object?>{
        'id': 'bare',
        'name': 'Bare',
        'presentation': <String, Object?>{},
      })!;

      final presentation = summary.presentation;
      expect(presentation.group, isNull);
      expect(presentation.category, isNull);
      expect(presentation.badge, isNull);
      expect(presentation.shortDescription, isNull);
      expect(presentation.howToUse, isNull);
      expect(presentation.examplePrompt, isNull);
      expect(presentation.bestFor, isEmpty);
      expect(presentation.notIdealFor, isEmpty);
      expect(summary.inputSummary, isNull);
    });

    test('input_summary is taken from presentation when the top level omits it',
        () {
      final summary = WorkflowSummary.tryFromJson(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'presentation': <String, Object?>{'input_summary': 'Prompt only'},
      })!;
      expect(summary.inputSummary, 'Prompt only');
    });

    test('an entry with no usable id is skipped rather than half-built', () {
      final workflows = WorkflowSummary.listFromJson(<String, Object?>{
        'workflows': <Object?>[
          <String, Object?>{'name': 'No id'},
          <String, Object?>{'id': '', 'name': 'Empty id'},
          <String, Object?>{'id': 'good', 'name': 'Good'},
          'not even an object',
        ],
      });
      expect(workflows.map((w) => w.id), <String>['good']);
    });

    test('a bind block in a payload has nowhere to land', () {
      // The gateway does not send one. If a future one did -- or a proxy added
      // it -- nothing in the app would carry it, because every model is built
      // from a named list of keys.
      final body = txt2imgDetail();
      (body['inputs']! as List<Object?>).add(<String, Object?>{
        'id': 'leaky',
        'label': 'Leaky',
        'type': 'integer',
        'bind': <String, Object?>{'node': '76', 'input': 'text'},
        'node': '76',
        'class_type': 'KSampler',
      });

      final detail = WorkflowDetail.tryFromJson(body)!;
      final leaky = detail.inputs.last;
      expect(leaky.id, 'leaky');
      expect(leaky.label, 'Leaky');
      // Everything the model can say about the field, said in full.
      expect(
        <Object?>[
          leaky.type,
          leaky.required,
          leaky.section,
          leaky.hasDefault,
          leaky.defaultValue,
          leaky.help,
          leaky.min,
          leaky.max,
          leaky.step,
          leaky.options,
          leaky.role,
          leaky.pair,
        ],
        <Object?>[
          FieldType.integer,
          false,
          FieldSection.main,
          false,
          null,
          null,
          null,
          null,
          null,
          isEmpty,
          null,
          null,
        ],
      );
    });
  });

  group('grouping', () {
    List<WorkflowSummary> summariesOf(Map<String, Object?> registry) =>
        WorkflowSummary.listFromJson(registry);

    test('sections come out in order of first appearance', () {
      final groups = groupWorkflows(summariesOf(examplesRegistry()));
      expect(groups.map((g) => g.name), <String?>['Create', 'Edit', 'Video']);
      expect(groups.first.workflows.single.id, 'example_txt2img');
    });

    test('a group the examples never use gets a section of its own', () {
      // Nothing in the app knows this word, which is the point.
      final registry = registryOf(<Map<String, Object?>>[
        txt2imgDetail(),
        renamed(
          txt2imgDetail(),
          id: 'sculpting_one',
          name: 'Sculpting One',
          group: 'Sculpting',
        ),
        renamed(
          txt2imgDetail(),
          id: 'sculpting_two',
          name: 'Sculpting Two',
          group: 'Sculpting',
        ),
      ]);

      final groups = groupWorkflows(summariesOf(registry));
      expect(groups.map((g) => g.name), <String?>['Create', 'Sculpting']);
      expect(
        groups.last.workflows.map((w) => w.id),
        <String>['sculpting_one', 'sculpting_two'],
      );
    });

    test('a workflow with no group is its own nameless section', () {
      final registry = registryOf(<Map<String, Object?>>[
        renamed(txt2imgDetail(), id: 'loose', name: 'Loose', group: null),
        txt2imgDetail(),
      ]);

      final groups = groupWorkflows(summariesOf(registry));
      expect(groups.map((g) => g.name), <String?>[null, 'Create']);
      expect(groups.first.workflows.single.id, 'loose');
    });

    test('every workflow that went in comes out, exactly once', () {
      final registry = registryOf(<Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
        videoDetail(),
        renamed(txt2imgDetail(), id: 'odd', name: 'Odd', group: 'Sculpting'),
        renamed(txt2imgDetail(), id: 'loose', name: 'Loose', group: null),
      ]);
      final workflows = summariesOf(registry);

      final grouped = <String>[
        for (final group in groupWorkflows(workflows))
          for (final workflow in group.workflows) workflow.id,
      ];
      expect(grouped, hasLength(workflows.length));
      expect(grouped.toSet(), workflows.map((w) => w.id).toSet());
    });
  });
}
