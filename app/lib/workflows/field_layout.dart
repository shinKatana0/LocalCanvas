/// How a list of fields becomes a list of rows, which numeric control a
/// numeric field gets, and what a number reads as beside itself.
///
/// Every decision here is made from the field's own type, range and declared
/// hints. `role`, `pair` and `duration` are hints
/// (`docs/workflow-schema.md`): [planFormRows] uses `pair` only to put two
/// fields on one line, [numericControlFor] reads none of them, and
/// [durationReadingFor] answers `null` for every field that did not declare a
/// frame rate. Strip all three from a schema and every field still gets a
/// complete, correct control — the layout just stops being clever.
///
/// Nothing in this library reads a field's id or its label, and
/// `field_duration_test.dart` and `field_layout_test.dart` hold that by
/// reading this file: a name is a curator's choice and never an input to a
/// decision made here.
library;

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import 'workflow_models.dart';

/// One line of the form.
@immutable
sealed class FormRow {
  const FormRow();

  /// The fields on this line, in order.
  List<WorkflowField> get fields;
}

/// A field on a line of its own — what every field gets without a hint.
@immutable
final class SingleFieldRow extends FormRow {
  const SingleFieldRow(this.field);

  final WorkflowField field;

  @override
  List<WorkflowField> get fields => <WorkflowField>[field];
}

/// Two fields laid out together, because the registry hinted that they belong
/// together. Purely visual: each field still has its own control and its own
/// entry in the input map.
@immutable
final class PairedFieldRow extends FormRow {
  const PairedFieldRow(this.first, this.second);

  final WorkflowField first;
  final WorkflowField second;

  @override
  List<WorkflowField> get fields => <WorkflowField>[first, second];
}

/// Arranges fields into rows, honouring the `pair` hint where it is present.
///
/// A `pair: width` is joined with the first later `pair: height` that is not
/// already spoken for, and vice versa. Everything else — including a hint with
/// no partner — is a row of its own. No field is ever dropped: the fields of
/// the returned rows are the fields that came in, in the same order.
List<FormRow> planFormRows(List<WorkflowField> fields) {
  final rows = <FormRow>[];
  final consumed = <int>{};
  for (var index = 0; index < fields.length; index++) {
    if (consumed.contains(index)) continue;
    final field = fields[index];
    final pair = field.pair;
    if (pair == null) {
      rows.add(SingleFieldRow(field));
      continue;
    }
    final wanted = pair == FieldPair.width ? FieldPair.height : FieldPair.width;
    final partner = _findPartner(fields, consumed, index + 1, wanted);
    if (partner == null) {
      rows.add(SingleFieldRow(field));
      continue;
    }
    consumed.add(partner);
    // Width on the left whichever order the registry declared them in.
    rows.add(
      pair == FieldPair.width
          ? PairedFieldRow(field, fields[partner])
          : PairedFieldRow(fields[partner], field),
    );
  }
  return rows;
}

int? _findPartner(
  List<WorkflowField> fields,
  Set<int> consumed,
  int from,
  FieldPair wanted,
) {
  for (var index = from; index < fields.length; index++) {
    if (consumed.contains(index)) continue;
    if (fields[index].pair == wanted) return index;
  }
  return null;
}

/// The two shapes a numeric field can take.
enum NumericControl {
  /// A bounded range small enough to move through by hand.
  slider,

  /// Everything else: an unbounded value, or a range no thumb can address.
  entry,
}

/// The largest number of discrete positions worth putting under a thumb.
///
/// A seed is the field this exists for: 0 to 4294967295 is a legal integer
/// range and an unusable slider. The rule reads the range, not the `role`, so
/// it comes out right for a schema that never declared one.
const int kMaxSliderDivisions = 240;

/// Which control a numeric field gets, decided from its own declared range.
NumericControl numericControlFor(WorkflowField field) {
  final min = field.min;
  final max = field.max;
  if (min == null || max == null || max <= min) return NumericControl.entry;
  final span = max - min;
  final step = field.step ?? (field.type == FieldType.integer ? 1.0 : null);
  if (step == null) {
    // A continuous float range, which a slider handles well until it is
    // absurdly wide.
    return span > 1e6 ? NumericControl.entry : NumericControl.slider;
  }
  if (step <= 0) return NumericControl.entry;
  return span / step > kMaxSliderDivisions
      ? NumericControl.entry
      : NumericControl.slider;
}

/// The duration a number reads as, in seconds, or `null` when the field
/// declared no frame rate.
///
/// One direction only, and that is the point. The value in play is always the
/// frame count — snapped by [snapToStep], bounded by `min` and `max`, and sent
/// to the workflow exactly as it stands. A duration is computed *from* it and
/// is never turned back into one, so no reading this function produces can
/// name a frame count the field does not allow. The mistake it exists instead
/// of is `seconds * fps`, which lands off the step grid the moment the step
/// does not divide the range evenly.
double? durationSecondsFor(WorkflowField field, num value) {
  final declared = field.duration;
  if (declared == null || field.type != FieldType.integer) return null;
  final seconds = value / declared.fps;
  return seconds.isFinite ? seconds : null;
}

/// The decimals a duration reading is shown to.
///
/// Two is enough to tell neighbouring frames apart at any ordinary rate — a
/// single frame at 24 per second is 0.042 s, and 0.01 s of resolution keeps
/// two of them distinct — and few enough that the reading stays a reading.
const int kDurationDecimals = 2;

/// The duration reading shown beside a frame count, or `null` for a field that
/// declared no rate.
///
/// The number is **rounded in the label only**. The frame count itself is
/// never rounded, never re-derived from the label, and stays on screen beside
/// this text, so what will be sent is visible rather than implied. A reading
/// that is not exact says so with a `≈` instead of quietly presenting a
/// rounded number as the truth, and the rate is named so the conversion is
/// visible rather than something the user has to take on trust.
String? durationReadingFor(L l, WorkflowField field, num value) {
  final seconds = durationSecondsFor(field, value);
  if (seconds == null) return null;
  final shown = _trimTrailingZeros(seconds.toStringAsFixed(kDurationDecimals));
  final approximate = double.parse(shown) != seconds.toDouble();
  final rate = _trimTrailingZeros(field.duration!.fps.toStringAsFixed(3));
  // Both numbers keep the digits and the decimal point the rest of this app
  // writes, in every locale: the frame count beside them is a value the
  // workflow receives, and two number conventions on one line would be worse
  // than one that is not the reader's own (T-0142).
  return approximate
      ? l.durationReadingApproximate(shown, rate)
      : l.durationReading(shown, rate);
}

String _trimTrailingZeros(String text) {
  if (!text.contains('.')) return text;
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && text.codeUnitAt(end - 1) == 0x2E) end--;
  return text.substring(0, end);
}

/// The number of slider divisions for a field, or `null` for a continuous one.
int? sliderDivisionsFor(WorkflowField field) {
  final min = field.min;
  final max = field.max;
  if (min == null || max == null || max <= min) return null;
  final step = field.step ?? (field.type == FieldType.integer ? 1.0 : null);
  if (step == null || step <= 0) return null;
  final divisions = ((max - min) / step).round();
  return divisions > 0 ? divisions : null;
}

/// The most tick marks that still read as tick marks rather than as a dotted
/// line across the track.
const int kMaxSliderTicks = 24;

/// The divisions to hand a [Slider], which is a smaller question than how many
/// steps the field has: past [kMaxSliderTicks] Material's tick marks stop
/// telling the user anything and turn the track into noise. The value is still
/// snapped by [snapToStep], so the step is honoured either way.
int? sliderTicksFor(WorkflowField field) {
  final divisions = sliderDivisionsFor(field);
  if (divisions == null || divisions > kMaxSliderTicks) return null;
  return divisions;
}

/// The nearest value on the field's own step grid, inside its declared range.
///
/// This is what honours `step` for a slider whose ticks are not drawn, and it
/// is also what keeps an integer field integral.
double snapToStep(WorkflowField field, double value) {
  final min = field.min;
  final max = field.max;
  final step = field.step ?? (field.type == FieldType.integer ? 1.0 : null);
  double snapped;
  if (step == null || step <= 0 || min == null) {
    snapped = field.type == FieldType.integer ? value.roundToDouble() : value;
  } else {
    snapped = min + ((value - min) / step).round() * step;
  }
  if (min != null && snapped < min) snapped = min;
  if (max != null && snapped > max) snapped = max;
  return snapped;
}

/// The lightweight groups Advanced controls are gathered into
/// (`docs/ui-ux.md`).
///
/// Every one of them is decided from what the schema already states — the
/// `pair` hint, the `role` hint, and the field's own type. A declared
/// `duration` deliberately changes nothing here: it says how a number may be
/// *read*, not what the number is for, so a field carrying one sits exactly
/// where it sat without one. **No name is ever consulted.** Matching field ids against a list of ids a curator "usually"
/// writes is forbidden: the app would then understand one
/// vocabulary and silently mis-place every workflow written in another.
/// Nothing in this library reads a field's id, and `field_layout_test.dart`
/// holds that by reading this file.
///
/// [other] is the catch-all. A field this build cannot place is never dropped,
/// never hidden and never reordered — it lands there, last, in the order the
/// registry declared it.
enum FieldGroupKind {
  size('Size'),
  seed('Seed'),
  text('Text'),
  numbers('Numbers'),
  choices('Choices'),
  media('Media'),
  other('Other');

  const FieldGroupKind(this.heading);

  /// The words above the group. A heading and nothing more: no code branches
  /// on this string, exactly as nothing branches on a registry's group name.
  final String heading;
}

/// One heading and the rows under it.
@immutable
final class FieldGroup {
  const FieldGroup({required this.kind, required this.rows});

  final FieldGroupKind kind;
  final List<FormRow> rows;

  String get heading => kind.heading;

  /// The fields under this heading, in the order they are drawn.
  List<WorkflowField> get fields => <WorkflowField>[
    for (final row in rows) ...row.fields,
  ];
}

/// Which group a field belongs to, from its hints and its type.
///
/// The order of the tests is the order of specificity: a declared `pair` says
/// two fields belong together, a declared `role` says what one field is for,
/// and the type is what is left when the registry hinted nothing.
FieldGroupKind groupKindFor(WorkflowField field) {
  if (field.pair != null) return FieldGroupKind.size;
  if (field.role == FieldRole.seed) return FieldGroupKind.seed;
  switch (field.type) {
    case FieldType.string:
    case FieldType.multiline:
      return FieldGroupKind.text;
    case FieldType.integer:
    case FieldType.float:
      return FieldGroupKind.numbers;
    case FieldType.boolean:
    case FieldType.select:
      return FieldGroupKind.choices;
    case FieldType.image:
    case FieldType.video:
      return FieldGroupKind.media;
    case FieldType.unsupported:
      return FieldGroupKind.other;
  }
}

/// Gathers fields into groups, and each group into rows.
///
/// Presentation only: the fields that go in are the fields that come out, and
/// no value, no binding and no validation knows this function exists.
///
/// A group appears where its first field was declared, so the shape of the
/// section follows the registry rather than a ranking of this app's own — with
/// one exception, [FieldGroupKind.other], which is always last, because a
/// field the app could not place has no business pushing the ones it could
/// down the screen. Inside a group the declaration order is kept, and
/// [planFormRows] then joins a hinted pair exactly as it does anywhere else.
List<FieldGroup> planFieldGroups(List<WorkflowField> fields) {
  final order = <FieldGroupKind>[];
  final buckets = <FieldGroupKind, List<WorkflowField>>{};
  for (final field in fields) {
    final kind = groupKindFor(field);
    buckets.putIfAbsent(kind, () {
      order.add(kind);
      return <WorkflowField>[];
    }).add(field);
  }
  if (order.remove(FieldGroupKind.other)) order.add(FieldGroupKind.other);
  return <FieldGroup>[
    for (final kind in order)
      FieldGroup(kind: kind, rows: planFormRows(buckets[kind]!)),
  ];
}
