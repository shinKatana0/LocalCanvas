/// Rows and numeric controls are decided from the field, and `role`/`pair` are
/// hints a renderer may ignore (`docs/workflow-schema.md`).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/field_layout.dart';
import 'package:localcanvas/workflows/workflow_models.dart';

import 'support/workflow_payloads.dart';

void main() {
  WorkflowDetail detail(Map<String, Object?> body) =>
      WorkflowDetail.tryFromJson(body)!;

  group('rows', () {
    test('a hinted pair shares a line', () {
      final rows = planFormRows(detail(txt2imgDetail()).mainFields);

      expect(rows, hasLength(2));
      expect(rows.first, isA<SingleFieldRow>());
      final paired = rows[1] as PairedFieldRow;
      expect(paired.first.id, 'width');
      expect(paired.second.id, 'height');
    });

    test('height declared before width still comes out width-first', () {
      final body = txt2imgDetail();
      final inputs = body['inputs']! as List<Object?>;
      final width = inputs[2];
      final height = inputs[3];
      inputs[2] = height;
      inputs[3] = width;

      final rows = planFormRows(detail(body).mainFields);
      final paired = rows[1] as PairedFieldRow;
      expect(paired.first.id, 'width');
      expect(paired.second.id, 'height');
    });

    test('a hint with no partner is a row like any other', () {
      final body = txt2imgDetail();
      final inputs = body['inputs']! as List<Object?>;
      inputs.removeAt(3); // the height half

      final rows = planFormRows(detail(body).mainFields);
      expect(rows.every((row) => row is SingleFieldRow), isTrue);
      expect(
        rows.map((row) => row.fields.single.id),
        <String>['prompt', 'width'],
      );
    });

    test('a renderer ignoring the hints still gets every field, in order', () {
      final hinted = detail(txt2imgDetail()).inputs;
      final plain = detail(withoutHints(txt2imgDetail())).inputs;

      final hintedOrder = <String>[
        for (final row in planFormRows(hinted))
          for (final field in row.fields) field.id,
      ];
      final plainRows = planFormRows(plain);

      expect(plainRows.every((row) => row is SingleFieldRow), isTrue);
      expect(
        <String>[
          for (final row in plainRows)
            for (final field in row.fields) field.id,
        ],
        hintedOrder,
      );
    });
  });

  group('numeric controls', () {
    WorkflowField fieldOf(Map<String, Object?> body, String id) =>
        detail(body).inputs.firstWhere((field) => field.id == id);

    test('a bounded range gets a slider with the declared divisions', () {
      final width = fieldOf(txt2imgDetail(), 'width');
      expect(numericControlFor(width), NumericControl.slider);
      expect(sliderDivisionsFor(width), (2048 - 256) ~/ 64);

      final guidance = fieldOf(txt2imgDetail(), 'guidance');
      expect(numericControlFor(guidance), NumericControl.slider);
      expect(sliderDivisionsFor(guidance), (20 - 1) ~/ 0.5);

      final steps = fieldOf(txt2imgDetail(), 'steps');
      expect(numericControlFor(steps), NumericControl.slider);
      // No step declared: an integer moves one at a time.
      expect(sliderDivisionsFor(steps), 49);
    });

    test('a seed gets an entry because of its range, not because of its role',
        () {
      final hinted = fieldOf(txt2imgDetail(), 'seed');
      final plain = fieldOf(withoutHints(txt2imgDetail()), 'seed');

      expect(hinted.role, FieldRole.seed);
      expect(plain.role, isNull);
      expect(numericControlFor(hinted), NumericControl.entry);
      expect(
        numericControlFor(plain),
        NumericControl.entry,
        reason: 'the range decides the control; the hint only adds Random',
      );
    });

    test('an unbounded number gets an entry', () {
      final field = fieldOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{'id': 'scale', 'label': 'Scale', 'type': 'float'},
        ],
      }, 'scale');
      expect(numericControlFor(field), NumericControl.entry);
      expect(sliderDivisionsFor(field), isNull);
    });

    test('a range too fine to address by thumb gets an entry', () {
      final field = fieldOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{
            'id': 'fine',
            'label': 'Fine',
            'type': 'float',
            'min': 0,
            'max': 100,
            'step': 0.001,
          },
        ],
      }, 'fine');
      expect(numericControlFor(field), NumericControl.entry);
    });

    test('ticks are drawn only while they still read as ticks', () {
      final strength = fieldOf(img2imgDetail(), 'strength');
      expect(sliderDivisionsFor(strength), 20);
      expect(sliderTicksFor(strength), 20);

      final steps = fieldOf(txt2imgDetail(), 'steps');
      expect(sliderDivisionsFor(steps), 49);
      expect(
        sliderTicksFor(steps),
        isNull,
        reason: 'fifty ticks is a dotted line, not a scale',
      );
    });

    test('a value is snapped to the step whether or not ticks are drawn', () {
      final width = fieldOf(txt2imgDetail(), 'width');
      // 256..2048 by 64: the grid is offset from zero by the minimum.
      expect(snapToStep(width, 790), 768);
      expect(snapToStep(width, 812), 832);
      expect(snapToStep(width, 768), 768);
      expect(snapToStep(width, 10), 256);
      expect(snapToStep(width, 99999), 2048);

      final steps = fieldOf(txt2imgDetail(), 'steps');
      expect(snapToStep(steps, 23.7), 24);

      final strength = fieldOf(img2imgDetail(), 'strength');
      expect(snapToStep(strength, 0.37), closeTo(0.35, 1e-9));
    });

    test('a nonsensical range is an entry rather than a crash', () {
      final field = fieldOf(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'inputs': <Object?>[
          <String, Object?>{
            'id': 'odd',
            'label': 'Odd',
            'type': 'integer',
            'min': 10,
            'max': 10,
            'step': 0,
          },
        ],
      }, 'odd');
      expect(numericControlFor(field), NumericControl.entry);
      expect(sliderDivisionsFor(field), isNull);
    });
  });

  group('groups', () {
    List<String> headingsOf(List<FieldGroup> groups) =>
        <String>[for (final group in groups) group.heading];

    List<String> idsOf(List<FieldGroup> groups) => <String>[
      for (final group in groups)
        for (final field in group.fields) field.id,
    ];

    test('a field is placed by its hints and its type, never by its name', () {
      final txt2img = detail(txt2imgDetail());
      WorkflowField byId(String id) =>
          txt2img.inputs.firstWhere((field) => field.id == id);

      expect(groupKindFor(byId('width')), FieldGroupKind.size);
      expect(groupKindFor(byId('height')), FieldGroupKind.size);
      expect(groupKindFor(byId('seed')), FieldGroupKind.seed);
      expect(groupKindFor(byId('negative_prompt')), FieldGroupKind.text);
      expect(groupKindFor(byId('steps')), FieldGroupKind.numbers);
      expect(groupKindFor(byId('guidance')), FieldGroupKind.numbers);
      expect(groupKindFor(byId('sampler')), FieldGroupKind.choices);
      expect(
        groupKindFor(detail(img2imgDetail()).inputs.first),
        FieldGroupKind.media,
      );

      // The same field under a different name is placed identically: the id
      // is not an input to this decision.
      final body = txt2imgDetail();
      for (final field in body['inputs']! as List<Object?>) {
        final map = field as Map<String, Object?>;
        map['id'] = 'x_${map['id']}';
      }
      expect(
        headingsOf(planFieldGroups(detail(body).advancedFields)),
        headingsOf(planFieldGroups(txt2img.advancedFields)),
      );
    });

    test('a hinted pair still shares its row inside its group', () {
      final body = txt2imgDetail();
      // Width and height, moved under Advanced.
      for (final field in body['inputs']! as List<Object?>) {
        final map = field as Map<String, Object?>;
        if (map['pair'] != null) map['section'] = 'advanced';
      }
      final groups = planFieldGroups(detail(body).advancedFields);
      final size = groups.firstWhere(
        (group) => group.kind == FieldGroupKind.size,
      );
      final paired = size.rows.single as PairedFieldRow;
      expect(paired.first.id, 'width');
      expect(paired.second.id, 'height');
    });

    test('the catch-all comes last, whatever order it was declared in', () {
      final groups = planFieldGroups(detail(oddAdvancedDetail()).advancedFields);

      // `region` and `palette` are declared first and still end up last,
      // because a field the app could not place must not push aside the ones
      // it could.
      expect(headingsOf(groups), <String>['Text', 'Size', 'Other']);
      expect(groups.last.kind, FieldGroupKind.other);
      expect(
        groups.last.fields.map((field) => field.id),
        <String>['region', 'palette'],
      );
    });

    test('every field comes out exactly once, in declaration order', () {
      for (final body in <Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
        videoDetail(),
        allTypesDetail(),
        oddAdvancedDetail(),
        withoutHints(txt2imgDetail()),
        withoutHints(oddAdvancedDetail()),
      ]) {
        final advanced = detail(body).advancedFields;
        final grouped = idsOf(planFieldGroups(advanced));
        expect(
          grouped..sort(),
          advanced.map((field) => field.id).toList()..sort(),
          reason: '${body['id']} lost or invented a field',
        );
        for (final group in planFieldGroups(advanced)) {
          final ids = group.fields.map((field) => field.id).toList();
          final declared = advanced
              .map((field) => field.id)
              .where(ids.contains)
              .toList();
          expect(
            ids,
            declared,
            reason: '${body['id']} reordered ${group.heading}',
          );
        }
      }
    });

    test('a schema with no hints at all still places every field', () {
      final plain = detail(withoutHints(txt2imgDetail())).advancedFields;
      final groups = planFieldGroups(plain);

      // No `pair` and no `role` left: the seed is an ordinary number and sits
      // with the other numbers. Nothing is dropped for want of a hint.
      expect(groups.any((group) => group.kind == FieldGroupKind.size), isFalse);
      expect(groups.any((group) => group.kind == FieldGroupKind.seed), isFalse);
      expect(headingsOf(groups), <String>['Text', 'Numbers', 'Choices']);
      expect(
        groups[1].fields.map((field) => field.id),
        <String>['steps', 'guidance', 'seed'],
      );
      expect(idsOf(groups)..sort(), plain.map((field) => field.id).toList()..sort());
    });
  });

  group('the grouping never learns a field id', () {
    /// Ids a curator plausibly writes. None of them may appear as a string
    /// this library compares against — the app understands field types and
    /// presentation, never names.
    const List<String> vocabulary = <String>[
      'prompt',
      'negative_prompt',
      'seed',
      'noise_seed',
      'steps',
      'cfg',
      'cfg_scale',
      'guidance',
      'denoise',
      'sampler',
      'sampler_name',
      'scheduler',
      'width',
      'height',
      'strength',
      'batch_size',
      'frames',
      'fps',
      'checkpoint',
      'lora',
      'clip_skip',
    ];

    /// The source with its comments removed, so prose about a `pair: width`
    /// is not mistaken for code that matches one.
    String code(String source) => source
        .split('\n')
        .map((line) {
          final slashes = line.indexOf('//');
          return slashes < 0 ? line : line.substring(0, slashes);
        })
        .join('\n');

    /// Every single-quoted string literal in [source].
    List<String> literalsIn(String source) => <String>[
      for (final match in RegExp("'([^'\\\\\n]*)'").allMatches(code(source)))
        match.group(1)!,
    ];

    /// The literals that name a field rather than a heading.
    List<String> namesIn(String source) {
      final headings = <String>{
        for (final kind in FieldGroupKind.values) kind.heading,
      };
      return <String>[
        for (final literal in literalsIn(source))
          if (!headings.contains(literal) &&
              vocabulary.contains(literal.toLowerCase()))
            literal,
      ];
    }

    bool readsAnId(String source) => RegExp(r'\.id\b').hasMatch(code(source));

    test('the two checks below catch what they are looking for', () {
      // Otherwise the assertions on the real file could pass because the
      // detector never fires at all.
      const offending = '''
const _seedIds = <String>{'seed', 'noise_seed'};
FieldGroupKind kindOf(WorkflowField field) =>
    _seedIds.contains(field.id) ? FieldGroupKind.seed : FieldGroupKind.other;
''';
      expect(readsAnId(offending), isTrue);
      expect(namesIn(offending), <String>['seed', 'noise_seed']);

      // A heading is not a name, and a comment is not code.
      expect(namesIn("const heading = 'Seed';"), isEmpty);
      expect(readsAnId('// nothing here reads field.id'), isFalse);
      expect(namesIn("// a pair is 'width' and 'height'"), isEmpty);
    });

    test('field_layout.dart matches no field id and reads none', () {
      final file = File('lib/workflows/field_layout.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'cwd is ${Directory.current.path}',
      );
      final source = file.readAsStringSync();

      expect(
        namesIn(source),
        isEmpty,
        reason: 'grouping must not name a field a curator chose',
      );
      expect(
        readsAnId(source),
        isFalse,
        reason: 'grouping must not read a field id at all',
      );
      // And the file really is the one holding the grouping, so neither
      // assertion above is about an empty file.
      expect(source, contains('planFieldGroups'));
    });
  });
}
