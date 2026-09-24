/// The workflow registry as the app receives it (`docs/api.md`,
/// `docs/workflow-schema.md`).
///
/// What is *not* here is the point of the file. There is no node id, no node
/// type and no `bind` block, because the gateway does not send them and this
/// parser has nowhere to put one: every model below is built from a named list
/// of keys, so an unexpected key in a payload is dropped rather than carried
/// into the interface. The app receives fields, never a graph.
///
/// `group`, `category` and `badge` are strings and stay strings. Nothing in
/// this app branches on their values — an unknown group is a group like any
/// other (`docs/workflow-schema.md`).
library;

import 'package:flutter/foundation.dart';

/// The eight v0.1 field types, plus the honest answer for a ninth.
///
/// The schema is extensible by design, so a definition may one day name a type
/// this build has never heard of. That is [unsupported]: the field is shown as
/// something this version cannot offer, rather than crashing the form or —
/// worse — being dropped so that a workflow silently runs without it.
enum FieldType {
  string,
  multiline,
  integer,
  float,
  boolean,
  select,
  image,
  video,
  unsupported;

  static const Map<String, FieldType> _byName = <String, FieldType>{
    'string': FieldType.string,
    'multiline': FieldType.multiline,
    'integer': FieldType.integer,
    'float': FieldType.float,
    'boolean': FieldType.boolean,
    'select': FieldType.select,
    'image': FieldType.image,
    'video': FieldType.video,
  };

  static FieldType parse(Object? value) =>
      _byName[value] ?? FieldType.unsupported;

  bool get isMedia => this == FieldType.image || this == FieldType.video;
  bool get isNumeric => this == FieldType.integer || this == FieldType.float;
  bool get isText => this == FieldType.string || this == FieldType.multiline;
}

/// Where a field is shown. `main` is the default, per the schema.
enum FieldSection {
  main,
  advanced;

  static FieldSection parse(Object? value) =>
      value == 'advanced' ? FieldSection.advanced : FieldSection.main;
}

/// Presentation hints. Every one of them is optional and every one is *only* a
/// hint: every control is complete without them, which is what makes this
/// schema renderable by something other than this app.
enum FieldRole {
  seed;

  static FieldRole? parse(Object? value) =>
      value == 'seed' ? FieldRole.seed : null;
}

enum FieldPair {
  width,
  height;

  static FieldPair? parse(Object? value) => switch (value) {
    'width' => FieldPair.width,
    'height' => FieldPair.height,
    _ => null,
  };
}

/// `duration: {fps: N}` — this integer counts frames, and the workflow plays
/// them at the declared rate (`docs/workflow-schema.md`).
///
/// **Declared, never inferred.** There is no other way to build one: nothing
/// in this app derives a frame rate from a field's id, its label, its range or
/// anything else. A payload that does not carry the block leaves [
/// WorkflowField.duration] null, and the field is the plain integer it has
/// always been.
///
/// It never changes a value. The frame count is what the form holds, what is
/// validated and what is submitted; a duration is a *reading* of that number
/// and is offered nowhere else.
@immutable
class FieldDuration {
  const FieldDuration({required this.fps});

  /// Frames per second. Always finite and greater than zero — [parse] is the
  /// only constructor a payload reaches, and it refuses anything else rather
  /// than carrying a rate that would divide into nonsense.
  final double fps;

  /// The hint, or `null` for anything this build cannot read as one.
  ///
  /// An unparseable hint is not an error: it means "render as a plain
  /// integer", which is what the field was before the block existed.
  static FieldDuration? parse(Object? value) {
    if (value is! Map) return null;
    final rate = value['fps'];
    if (rate is! num) return null;
    final fps = rate.toDouble();
    if (!fps.isFinite || fps <= 0) return null;
    return FieldDuration(fps: fps);
  }

  @override
  bool operator ==(Object other) =>
      other is FieldDuration && other.fps == fps;

  @override
  int get hashCode => fps.hashCode;

  @override
  String toString() => 'FieldDuration(fps: $fps)';
}

/// One entry of a `select` field's options.
@immutable
class SelectOption {
  const SelectOption({required this.value, required this.label});

  final Object? value;
  final String label;

  static SelectOption? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final value = json['value'];
    if (value == null) return null;
    final label = json['label'];
    return SelectOption(
      value: value,
      label: label is String && label.trim().isNotEmpty ? label.trim() : '$value',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SelectOption &&
      other.label == label &&
      jsonValueEquals(other.value, value);

  @override
  int get hashCode => label.hashCode;
}

/// One user-facing field of a workflow.
@immutable
class WorkflowField {
  const WorkflowField({
    required this.id,
    required this.label,
    required this.type,
    this.required = false,
    this.section = FieldSection.main,
    this.hasDefault = false,
    this.defaultValue,
    this.help,
    this.min,
    this.max,
    this.step,
    this.options = const <SelectOption>[],
    this.role,
    this.pair,
    this.duration,
  });

  final String id;
  final String label;
  final FieldType type;
  final bool required;
  final FieldSection section;

  /// `default` is optional and `null` is a legal default, so its presence is
  /// a separate fact from its value.
  final bool hasDefault;
  final Object? defaultValue;

  final String? help;
  final double? min;
  final double? max;
  final double? step;
  final List<SelectOption> options;
  final FieldRole? role;
  final FieldPair? pair;

  /// The declared frame rate this integer may also be read at, or `null` —
  /// which is every field of every workflow that did not say so.
  final FieldDuration? duration;

  static WorkflowField? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final label = json['label'];
    final options = json['options'];
    return WorkflowField(
      id: id,
      label: label is String && label.trim().isNotEmpty ? label.trim() : id,
      type: FieldType.parse(json['type']),
      required: json['required'] == true,
      section: FieldSection.parse(json['section']),
      hasDefault: json.containsKey('default'),
      defaultValue: json['default'],
      help: _nonEmpty(json['help']),
      min: _number(json['min']),
      max: _number(json['max']),
      step: _number(json['step']),
      options: options is List
          ? options
                .map(SelectOption.tryFromJson)
                .whereType<SelectOption>()
                .toList(growable: false)
          : const <SelectOption>[],
      role: FieldRole.parse(json['role']),
      pair: FieldPair.parse(json['pair']),
      duration: FieldDuration.parse(json['duration']),
    );
  }

  /// Every parsed property, compared by value — what "the same field" means
  /// when a re-read schema is laid beside the one a form was built from
  /// (T-0236). [defaultValue] is whatever JSON carried, so it is compared
  /// deeply.
  @override
  bool operator ==(Object other) =>
      other is WorkflowField &&
      other.id == id &&
      other.label == label &&
      other.type == type &&
      other.required == required &&
      other.section == section &&
      other.hasDefault == hasDefault &&
      jsonValueEquals(other.defaultValue, defaultValue) &&
      other.help == help &&
      other.min == min &&
      other.max == max &&
      other.step == step &&
      listEquals(other.options, options) &&
      other.role == role &&
      other.pair == pair &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(id, label, type, required, section);
}

/// The descriptive metadata behind the picker card and the help sheet.
///
/// Every entry is optional. A field the registry did not supply is absent
/// here and absent from the sheet — never an empty heading, never "N/A".
@immutable
class WorkflowPresentation {
  const WorkflowPresentation({
    this.group,
    this.category,
    this.badge,
    this.shortDescription,
    this.bestFor = const <String>[],
    this.howToUse,
    this.inputSummary,
    this.examplePrompt,
    this.notIdealFor = const <String>[],
  });

  final String? group;
  final String? category;
  final String? badge;
  final String? shortDescription;
  final List<String> bestFor;
  final String? howToUse;
  final String? inputSummary;
  final String? examplePrompt;
  final List<String> notIdealFor;

  static WorkflowPresentation fromJson(Object? json) {
    if (json is! Map) return const WorkflowPresentation();
    return WorkflowPresentation(
      group: _nonEmpty(json['group']),
      category: _nonEmpty(json['category']),
      badge: _nonEmpty(json['badge']),
      shortDescription: _nonEmpty(json['short_description']),
      bestFor: _stringList(json['best_for']),
      howToUse: _nonEmpty(json['how_to_use']),
      inputSummary: _nonEmpty(json['input_summary']),
      examplePrompt: _nonEmpty(json['example_prompt']),
      notIdealFor: _stringList(json['not_ideal_for']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkflowPresentation &&
      other.group == group &&
      other.category == category &&
      other.badge == badge &&
      other.shortDescription == shortDescription &&
      listEquals(other.bestFor, bestFor) &&
      other.howToUse == howToUse &&
      other.inputSummary == inputSummary &&
      other.examplePrompt == examplePrompt &&
      listEquals(other.notIdealFor, notIdealFor);

  @override
  int get hashCode => Object.hash(group, category, badge, shortDescription);
}

/// A workflow as the picker knows it: `GET /api/v1/workflows`.
@immutable
class WorkflowSummary {
  const WorkflowSummary({
    required this.id,
    required this.name,
    this.presentation = const WorkflowPresentation(),
    this.inputSummary,
    this.requiredMedia = const <String>[],
  });

  final String id;
  final String name;
  final WorkflowPresentation presentation;

  /// `docs/api.md` repeats this at the top level of a summary entry; the
  /// registry also writes it inside `presentation`. Either is the same
  /// sentence, and the top-level one wins when both are present.
  final String? inputSummary;

  /// The media kinds this workflow cannot run without, as declared.
  final List<String> requiredMedia;

  static WorkflowSummary? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'];
    final presentation = WorkflowPresentation.fromJson(json['presentation']);
    return WorkflowSummary(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : id,
      presentation: presentation,
      inputSummary:
          _nonEmpty(json['input_summary']) ?? presentation.inputSummary,
      requiredMedia: _stringList(json['required_media']),
    );
  }

  static List<WorkflowSummary> listFromJson(Object? json) {
    if (json is! Map) return const <WorkflowSummary>[];
    final items = json['workflows'];
    if (items is! List) return const <WorkflowSummary>[];
    return items
        .map(WorkflowSummary.tryFromJson)
        .whereType<WorkflowSummary>()
        .toList(growable: false);
  }

  @override
  bool operator ==(Object other) =>
      other is WorkflowSummary &&
      other.id == id &&
      other.name == name &&
      other.presentation == presentation &&
      other.inputSummary == inputSummary &&
      listEquals(other.requiredMedia, requiredMedia);

  @override
  int get hashCode => Object.hash(id, name);
}

/// One workflow with its field schema: `GET /api/v1/workflows/{id}`.
@immutable
class WorkflowDetail {
  const WorkflowDetail({
    required this.summary,
    this.inputs = const <WorkflowField>[],
  });

  final WorkflowSummary summary;
  final List<WorkflowField> inputs;

  String get id => summary.id;
  String get name => summary.name;
  WorkflowPresentation get presentation => summary.presentation;

  List<WorkflowField> get mainFields => inputs
      .where((field) => field.section == FieldSection.main)
      .toList(growable: false);

  List<WorkflowField> get advancedFields => inputs
      .where((field) => field.section == FieldSection.advanced)
      .toList(growable: false);

  static WorkflowDetail? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final summary = WorkflowSummary.tryFromJson(json);
    if (summary == null) return null;
    final inputs = json['inputs'];
    return WorkflowDetail(
      summary: summary,
      inputs: inputs is List
          ? inputs
                .map(WorkflowField.tryFromJson)
                .whereType<WorkflowField>()
                .toList(growable: false)
          : const <WorkflowField>[],
    );
  }

  /// Value equality over everything the parser kept (T-0236).
  ///
  /// This is how a re-read schema is told from the one a form was built from:
  /// equal means the form is kept as it is, object and all. It compares the
  /// parsed models rather than the JSON they came from, so a key this app
  /// drops — and so never shows — cannot make two schemas differ.
  @override
  bool operator ==(Object other) =>
      other is WorkflowDetail &&
      other.summary == summary &&
      listEquals(other.inputs, inputs);

  @override
  int get hashCode => summary.hashCode;
}

/// One section of the picker. The name is whatever the registry said, and
/// `null` is the honest name for a workflow that declared no group.
@immutable
class WorkflowGroup {
  const WorkflowGroup({required this.name, required this.workflows});

  final String? name;
  final List<WorkflowSummary> workflows;
}

/// Buckets workflows by their declared group, in order of first appearance.
///
/// Data in, sections out. There is no list of known group names for a group to
/// be absent from, so a group nobody anticipated is a section like every other
/// one — it cannot be dropped, and it cannot be coerced into someone else's.
List<WorkflowGroup> groupWorkflows(Iterable<WorkflowSummary> workflows) {
  final order = <String?>[];
  final buckets = <String?, List<WorkflowSummary>>{};
  for (final workflow in workflows) {
    final group = workflow.presentation.group;
    buckets.putIfAbsent(group, () {
      order.add(group);
      return <WorkflowSummary>[];
    }).add(workflow);
  }
  return <WorkflowGroup>[
    for (final name in order)
      WorkflowGroup(name: name, workflows: buckets[name]!),
  ];
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.map(_nonEmpty).whereType<String>().toList(growable: false);
}

double? _number(Object? value) => value is num ? value.toDouble() : null;

/// Whether two values decoded from JSON are the same value: scalars by `==`,
/// lists element by element in order, maps key by key. What a `default` or an
/// option's `value` can be, since the schema does not narrow either.
bool jsonValueEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonValueEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List || b is List || a is Map || b is Map) return false;
  return a == b;
}
