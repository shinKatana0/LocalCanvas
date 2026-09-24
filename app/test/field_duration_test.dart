/// `duration: {fps: N}` — a frame count the form may also read as a time
/// (`docs/workflow-schema.md`).
///
/// Two rules are what this file holds in place:
///
/// * **declared, never inferred** — no field id, no label and no value range
///   switches the reading on;
/// * **the frame count is the value** — a duration is derived from it, never
///   turned back into one, so no reading here can name a frame count `min`,
///   `max` and `step` disallow.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/workflows/field_layout.dart';
import 'package:localcanvas/workflows/workflow_models.dart';

import 'support/l10n.dart';
import 'support/workflow_payloads.dart';

void main() {
  WorkflowDetail detail(Map<String, Object?> body) =>
      WorkflowDetail.tryFromJson(body)!;

  WorkflowField fieldOf(Map<String, Object?> body, String id) =>
      detail(body).inputs.firstWhere((field) => field.id == id);

  WorkflowField length(Map<String, Object?> body) => fieldOf(body, 'length');

  /// The shipped video example's frame count, with a rate declared onto it.
  /// Its grid — 8..128 in steps of 8 — *does* contain whole seconds at 24 fps,
  /// which is the contrast that shows the rule is about the declared grid and
  /// not about this app disliking round numbers.
  WorkflowField framesOnEights() => fieldOf(
    withDuration(videoDetail(), 'frames', <String, Object?>{'fps': 24}),
    'frames',
  );

  group('parsing', () {
    test('a declared rate is carried onto the field', () {
      final field = length(videoLengthDetail());

      expect(field.duration, const FieldDuration(fps: 24));
      // And the bounds it lives beside are untouched: they bind the frames.
      expect((field.min, field.max, field.step), (25.0, 121.0, 4.0));
    });

    test('a field that declares nothing carries nothing', () {
      for (final body in <Map<String, Object?>>[
        txt2imgDetail(),
        img2imgDetail(),
        videoDetail(),
        allTypesDetail(),
        oddAdvancedDetail(),
      ]) {
        for (final field in detail(body).inputs) {
          expect(
            field.duration,
            isNull,
            reason: '${body['id']}.${field.id} invented a frame rate',
          );
        }
      }
    });

    test('a hint this build cannot read means "a plain integer", not an error',
        () {
      for (final broken in <Object?>[
        null,
        24,
        'fps: 24',
        <String, Object?>{},
        <String, Object?>{'fps': 0},
        <String, Object?>{'fps': -24},
        <String, Object?>{'fps': '24'},
        <String, Object?>{'fps': true},
        <String, Object?>{'fps': double.nan},
        <String, Object?>{'fps': double.infinity},
        <String, Object?>{'frame_rate': 24},
      ]) {
        final field = length(
          withDuration(videoLengthDetail(), 'length', broken),
        );
        expect(field.duration, isNull, reason: '$broken');
        // Still a complete integer control: nothing else was dropped with it.
        expect(field.type, FieldType.integer);
        expect((field.min, field.max, field.step), (25.0, 121.0, 4.0));
        expect(durationReadingFor(en, field, 25), isNull);
      }
    });

    test('a fractional rate survives being declared', () {
      final field = length(
        withDuration(videoLengthDetail(), 'length', <String, Object?>{
          'fps': 23.976,
        }),
      );

      expect(field.duration!.fps, closeTo(23.976, 1e-9));
    });
  });

  group('declared, never inferred', () {
    test('a field named like a frame count is still a plain integer', () {
      // `frames` in the shipped video example is exactly the field a
      // name-matching app would claim, and it declares no rate.
      final frames = fieldOf(videoDetail(), 'frames');
      expect(frames.type, FieldType.integer);
      expect(frames.duration, isNull);
      expect(durationSecondsFor(frames, 48), isNull);
      expect(durationReadingFor(en, frames, 48), isNull);
    });

    test('renaming a field changes nothing about its reading', () {
      final body = videoLengthDetail();
      for (final field in body['inputs']! as List<Object?>) {
        final map = field as Map<String, Object?>;
        map['id'] = 'x_${map['id']}';
        map['label'] = 'Something Else';
      }
      final renamedField = fieldOf(body, 'x_length');

      expect(
        durationReadingFor(en, renamedField, 25),
        durationReadingFor(en, length(videoLengthDetail()), 25),
      );
    });

    test('a separate frame-rate field is not consulted and is not touched', () {
      // The workflow exposes `fps` as an ordinary integer. It is neither the
      // source of the reading nor changed by it: this card presents one field,
      // it does not couple two.
      final rate = fieldOf(videoLengthDetail(), 'fps');
      expect(rate.duration, isNull);
      expect(durationReadingFor(en, rate, 24), isNull);

      final body = withDuration(videoLengthDetail(), 'length', <String, Object?>{
        'fps': 8,
      });
      // The reading follows the *declared* rate, not the other field's value.
      expect(durationReadingFor(en, length(body), 24), '3 s at 8 fps');
    });
  });

  group('the reading', () {
    test('an exact duration is stated plainly', () {
      final field = framesOnEights();

      expect(durationSecondsFor(field, 48), 2.0);
      expect(durationReadingFor(en, field, 48), '2 s at 24 fps');
      expect(durationReadingFor(en, field, 96), '4 s at 24 fps');
    });

    test('a rounded one says that it is rounded', () {
      final field = length(videoLengthDetail());

      expect(durationSecondsFor(field, 25), closeTo(25 / 24, 1e-12));
      expect(durationReadingFor(en, field, 25), '≈ 1.04 s at 24 fps');
      expect(durationReadingFor(en, field, 29), '≈ 1.21 s at 24 fps');
      // 33/24 is 1.375 exactly, and two decimals cannot say so.
      expect(durationReadingFor(en, field, 33), '≈ 1.38 s at 24 fps');
    });

    test('a fractional rate is named as it was declared', () {
      final field = length(
        withDuration(videoLengthDetail(), 'length', <String, Object?>{
          'fps': 23.976,
        }),
      );

      expect(durationReadingFor(en, field, 25), '≈ 1.04 s at 23.976 fps');
    });

    test('a non-integer field never gets a reading', () {
      // The gateway refuses `duration` off an integer; a payload that carried
      // one anyway is rendered as the plain float it is.
      final guidance = fieldOf(
        withDuration(txt2imgDetail(), 'guidance', <String, Object?>{'fps': 24}),
        'guidance',
      );

      expect(guidance.duration, const FieldDuration(fps: 24));
      expect(durationSecondsFor(guidance, 6), isNull);
      expect(durationReadingFor(en, guidance, 6), isNull);
    });
  });

  group('min/max/step still bind', () {
    /// Every frame count the control can actually reach, found through the
    /// same [snapToStep] the slider and the entry use.
    List<int> reachableFrames(WorkflowField field) {
      final seen = <int>{};
      for (var raw = -50.0; raw <= 200.0; raw += 0.25) {
        seen.add(snapToStep(field, raw).round());
      }
      return seen.toList()..sort();
    }

    /// The seconds a reading states, read back out of the text the user sees.
    double secondsIn(String reading) =>
        double.parse(RegExp(r'([0-9.]+) s at').firstMatch(reading)!.group(1)!);

    test('the reachable frame counts are the declared grid', () {
      final field = length(videoLengthDetail());

      expect(
        reachableFrames(field),
        <int>[for (var n = 25; n <= 121; n += 4) n],
      );
    });

    test('every offered reading names a legal frame count, exactly', () {
      final field = length(videoLengthDetail());
      final legal = reachableFrames(field).toSet();

      for (final frames in legal) {
        final reading = durationReadingFor(en, field, frames)!;
        // The label is rounded; the frame count it identifies is not. Reading
        // the seconds back off the screen still lands on the very frame the
        // form holds — which is the whole claim the `≈` makes.
        final recovered = (secondsIn(reading) * 24).round();
        expect(
          recovered,
          frames,
          reason: '$reading does not identify $frames frames',
        );
        expect(legal.contains(recovered), isTrue);
      }
    });

    test('a whole second that is off the grid is never offered', () {
      Set<double> offeredOn(WorkflowField field) => <double>{
        for (final frames in reachableFrames(field))
          secondsIn(durationReadingFor(en, field, frames)!),
      };

      // 25..121 by 4 is every n congruent to 1 modulo 4, and a whole second at
      // 24 fps is a multiple of 24. The two never meet: *no* whole second is
      // offerable here, 1 s (24 frames) least of all. An implementation that
      // offered whole seconds and multiplied back would send 24 — a frame
      // count this field forbids.
      final awkward = offeredOn(length(videoLengthDetail()));
      expect(awkward.contains(1.0), isFalse);
      expect(
        awkward.any((seconds) => seconds == seconds.roundToDouble()),
        isFalse,
      );

      // And the rule really is the grid, not a dislike of round numbers: on
      // 8..128 by 8, 2 s is 48 frames and is offered.
      final tidy = offeredOn(framesOnEights());
      expect(tidy.contains(2.0), isTrue);
      expect(tidy.contains(4.0), isTrue);
    });

    test('a value outside the range is clamped before it is read', () {
      final field = length(videoLengthDetail());

      expect(snapToStep(field, 1000), 121);
      expect(durationReadingFor(en, field, snapToStep(field, 1000)),
          '≈ 5.04 s at 24 fps');
      expect(snapToStep(field, -1000), 25);
    });
  });

  group('grouping and controls are untouched', () {
    test('a declared rate changes neither the group nor the control', () {
      final hinted = length(videoLengthDetail());
      final plain = length(withoutDuration(videoLengthDetail()));

      expect(groupKindFor(hinted), groupKindFor(plain));
      expect(groupKindFor(hinted), FieldGroupKind.numbers);
      expect(numericControlFor(hinted), numericControlFor(plain));
      expect(sliderDivisionsFor(hinted), sliderDivisionsFor(plain));
      expect(sliderTicksFor(hinted), sliderTicksFor(plain));
      for (var raw = 20.0; raw <= 130.0; raw += 1) {
        expect(snapToStep(hinted, raw), snapToStep(plain, raw));
      }
    });

    test('the rows are the rows the same schema had without the hint', () {
      final hinted = planFormRows(detail(videoLengthDetail()).mainFields);
      final plain = planFormRows(
        detail(withoutDuration(videoLengthDetail())).mainFields,
      );

      expect(
        <String>[for (final row in hinted) for (final f in row.fields) f.id],
        <String>[for (final row in plain) for (final f in row.fields) f.id],
      );
    });
  });

  group('the reading never learns a field name', () {
    /// Names a curator plausibly gives a frame count, plus the two words the
    /// hint itself uses. None of them may be a string this library compares
    /// against: the app understands declared hints, never names.
    const List<String> vocabulary = <String>[
      'frames',
      'num_frames',
      'video_frames',
      'frame_count',
      'length',
      'video_length',
      'duration',
      'fps',
      'frame_rate',
      'framerate',
      'seconds',
      'batch_size',
    ];

    /// A group heading is a word on the screen, not a name this library
    /// matched — the same exemption `field_layout_test.dart` makes.
    final Set<String> headings = <String>{
      for (final kind in FieldGroupKind.values) kind.heading,
    };

    /// The source with its comments removed, so prose about `fps` is not
    /// mistaken for code that matches it.
    String code(String source) => source
        .split('\n')
        .map((line) {
          final slashes = line.indexOf('//');
          return slashes < 0 ? line : line.substring(0, slashes);
        })
        .join('\n');

    List<String> namesIn(String source) => <String>[
      for (final match in RegExp("'([^'\\\\\n]*)'").allMatches(code(source)))
        if (!headings.contains(match.group(1)!) &&
            vocabulary.contains(match.group(1)!.toLowerCase()))
          match.group(1)!,
    ];

    bool readsAnId(String source) =>
        RegExp(r'\.(id|label)\b').hasMatch(code(source));

    test('the two checks below catch what they are looking for', () {
      // Otherwise the assertions on the real file could pass because the
      // detector never fires at all.
      const offending = '''
const _frameIds = <String>{'frames', 'video_length'};
double? secondsOf(WorkflowField field) =>
    _frameIds.contains(field.id) ? field.min! / 24 : null;
''';
      expect(readsAnId(offending), isTrue);
      expect(namesIn(offending), <String>['frames', 'video_length']);

      const byLabel = '''
bool looksLikeFrames(WorkflowField field) =>
    field.label.toLowerCase().contains('frames');
''';
      expect(readsAnId(byLabel), isTrue);
      expect(namesIn(byLabel), <String>['frames']);

      // A comment is not code, and an interpolated sentence is not a match.
      expect(readsAnId('// nothing here reads field.id'), isFalse);
      expect(namesIn("// a frame rate is 'fps'"), isEmpty);
      expect(namesIn(r"return '$shown s at $rate fps';"), isEmpty);
    });

    test('field_layout.dart matches no field name and reads none', () {
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
        reason: 'a duration must not be inferred from a name',
      );
      expect(
        readsAnId(source),
        isFalse,
        reason: 'the reading must not read a field id or label at all',
      );
      // And the file really is the one holding the reading, so neither
      // assertion above is about a file that does nothing.
      expect(source, contains('durationReadingFor'));
      expect(source, contains('durationSecondsFor'));
    });
  });
}
