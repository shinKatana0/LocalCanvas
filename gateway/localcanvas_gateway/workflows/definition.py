"""Parsing and validation of a single workflow definition.

One YAML definition plus the ComfyUI API-format JSON it points at go in; a
validated :class:`~localcanvas_gateway.workflows.model.WorkflowDefinition`, or a
list of diagnostics saying why there is none, comes out.

Nothing here reaches the network or ComfyUI: validation is a pure function of
two files, so a curator can run it offline
(``python -m localcanvas_gateway.workflows <registry root>``).

The rules implemented here are the validation list in
`docs/workflow-schema.md`.  Where that contract leaves a choice open this
module takes the strict option, because the failure it prevents -- a mistyped
key silently ignored, and a field that quietly does nothing at generation
time -- is far more expensive than a rejected definition with a diagnostic
that says what to fix:

* unknown keys are rejected at the definition, field, ``bind`` and option
  level (``presentation`` is free-form descriptive data and is checked, too,
  since its key set is enumerated in the contract);
* two fields may not bind to the same node input, and one field may not list
  the same target twice -- a repeated target is an authoring mistake, not a
  no-op to deduplicate silently;
* ``default: null`` is rejected -- omit the key instead;
* ``workflow`` must be a path relative to the definition file, so that a
  definition never carries an absolute machine-specific path.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import yaml

from .diagnostics import Diagnostic
from .model import (
    MEDIA_FIELD_TYPES,
    NUMERIC_FIELD_TYPES,
    Binding,
    DurationHint,
    FieldPair,
    FieldRole,
    FieldType,
    InputField,
    Presentation,
    Section,
    SelectOption,
    TranslationMode,
    WorkflowDefinition,
)

#: The charset `docs/workflow-schema.md` allows for a workflow id.
WORKFLOW_ID_PATTERN = re.compile(r"^[a-z0-9_-]+$")

DEFINITION_KEYS = frozenset(
    {"id", "name", "workflow", "presentation", "inputs", "translation"}
)
TRANSLATION_KEYS = frozenset({"mode"})
PRESENTATION_TEXT_KEYS = (
    "group",
    "category",
    "badge",
    "short_description",
    "how_to_use",
    "input_summary",
    "example_prompt",
)
PRESENTATION_LIST_KEYS = ("best_for", "not_ideal_for")
PRESENTATION_KEYS = frozenset(PRESENTATION_TEXT_KEYS) | frozenset(PRESENTATION_LIST_KEYS)
FIELD_KEYS = frozenset(
    {
        "id",
        "label",
        "type",
        "required",
        "section",
        "default",
        "help",
        "bind",
        "min",
        "max",
        "step",
        "options",
        "role",
        "pair",
        "duration",
        "translatable",
    }
)
BIND_KEYS = frozenset({"node", "input"})
OPTION_KEYS = frozenset({"value", "label"})
#: The whole of the ``duration`` block.  ``fps`` is required and is the only
#: key: a frame rate is declared here or the hint is not used at all.
DURATION_KEYS = frozenset({"fps"})

#: Which type-specific keys each field type may carry.
_TYPE_EXTRAS: Mapping[FieldType, frozenset] = {
    FieldType.STRING: frozenset({"translatable"}),
    FieldType.MULTILINE: frozenset({"translatable"}),
    FieldType.INTEGER: frozenset({"min", "max", "step", "role", "pair", "duration"}),
    FieldType.FLOAT: frozenset({"min", "max", "step"}),
    FieldType.BOOLEAN: frozenset(),
    FieldType.SELECT: frozenset({"options"}),
    FieldType.IMAGE: frozenset(),
    FieldType.VIDEO: frozenset(),
}
# ``translatable`` is here, and only on the two text types, because the
# alternative is a gateway deciding for itself that a value "looks like a
# sentence".  A select's identifier, a filename, a path and a number are not
# translatable, and the schema is where that is settled rather than in a
# heuristic at generation time (T-0040).
_TYPE_SPECIFIC_KEYS = (
    "min",
    "max",
    "step",
    "options",
    "role",
    "pair",
    "duration",
    "translatable",
)

#: The two types a ``translatable`` flag is meaningful on.
_TEXT_FIELD_TYPES = frozenset({FieldType.STRING, FieldType.MULTILINE})

_KIND_NAMES = {
    type(None): "null",
    bool: "a boolean",
    int: "an integer",
    float: "a float",
    str: "a string",
    list: "a list",
    dict: "a mapping",
}


def _kind(value: Any) -> str:
    return _KIND_NAMES.get(type(value), type(value).__name__)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _flatten(text: str) -> str:
    return " ".join(str(text).split())


def _quoted_list(values: Sequence[Any]) -> str:
    return ", ".join(repr(value) for value in values)


@dataclass(frozen=True)
class LoadedDefinition:
    """The outcome of loading one definition file."""

    source: Path
    workflow: Optional[WorkflowDefinition]
    diagnostics: Tuple[Diagnostic, ...]
    #: The id this definition *claims*, set as soon as it is readable -- even
    #: when validation then fails.  The registry resolves duplicate ids off
    #: this, so a broken claimant still counts as a claimant.
    workflow_id: Optional[str] = None


class _DefinitionParser:
    """Accumulates every problem in one definition rather than stopping at the first.

    A curator fixing their YAML should see all of it in one run.
    """

    def __init__(self, source: Path) -> None:
        self.source = source
        self.workflow_id: Optional[str] = None
        self.diagnostics: List[Diagnostic] = []

    # -- diagnostics -------------------------------------------------------

    def fail(self, message: str, field_id: Optional[str] = None) -> None:
        self.diagnostics.append(
            Diagnostic(
                source=self.source,
                message=message,
                workflow_id=self.workflow_id,
                field_id=field_id,
            )
        )

    def _result(self, workflow: Optional[WorkflowDefinition]) -> LoadedDefinition:
        return LoadedDefinition(
            source=self.source,
            workflow=None if self.diagnostics else workflow,
            diagnostics=tuple(self.diagnostics),
            workflow_id=self.workflow_id,
        )

    def _reject_unknown_keys(
        self,
        data: Mapping[str, Any],
        allowed: frozenset,
        where: str,
        field_id: Optional[str] = None,
    ) -> None:
        unknown = sorted(str(key) for key in data if key not in allowed)
        for key in unknown:
            self.fail(
                "{}: unknown key {!r}; allowed keys are {}".format(
                    where, key, _quoted_list(sorted(allowed))
                ),
                field_id=field_id,
            )

    # -- entry point -------------------------------------------------------

    def parse(self) -> LoadedDefinition:
        data = self._read_yaml()
        if data is None:
            return self._result(None)

        self._reject_unknown_keys(data, DEFINITION_KEYS, "definition")

        workflow_id = self._parse_workflow_id(data)
        name = self._parse_name(data)
        workflow_path, graph = self._parse_graph(data)
        presentation = self._parse_presentation(data)
        translation_mode = self._parse_translation(data)
        fields, bindings = self._parse_inputs(data, graph)

        if self.diagnostics or workflow_id is None or name is None or workflow_path is None:
            return self._result(None)

        return self._result(
            WorkflowDefinition(
                id=workflow_id,
                name=name,
                source=self.source,
                workflow_path=workflow_path,
                presentation=presentation,
                inputs=tuple(fields),
                bindings=dict(bindings),
                graph=graph if graph is not None else {},
                translation_mode=translation_mode,
            )
        )

    # -- top level ---------------------------------------------------------

    def _read_yaml(self) -> Optional[Dict[str, Any]]:
        try:
            text = self.source.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            self.fail("the definition file is not valid UTF-8 text")
            return None
        except OSError as exc:
            self.fail("cannot read the definition file: {}".format(exc.strerror or exc))
            return None

        try:
            duplicate = _duplicate_mapping_key(text)
            if duplicate is not None:
                key, line = duplicate
                self.fail(
                    "duplicate key {!r} on line {}: YAML keeps only the last one, so one of "
                    "the two is silently doing nothing".format(key, line)
                )
                return None
            data = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            self.fail("YAML parse error: {}".format(_flatten(exc)))
            return None

        if data is None:
            self.fail("the definition file is empty")
            return None
        if not isinstance(data, dict):
            self.fail(
                "the definition must be a mapping at the top level, found {}".format(_kind(data))
            )
            return None
        return data

    def _parse_workflow_id(self, data: Mapping[str, Any]) -> Optional[str]:
        if "id" not in data:
            self.fail("'id' is required")
            return None
        raw = data["id"]
        if not isinstance(raw, str):
            self.fail(
                "'id' must be a string, found {}; quote it if it looks like a number".format(
                    _kind(raw)
                )
            )
            return None
        if not raw:
            self.fail("'id' must not be empty")
            return None
        self.workflow_id = raw
        if not WORKFLOW_ID_PATTERN.match(raw):
            self.fail(
                "'id' {!r} is not allowed; use lowercase letters, digits, '_' and '-' only".format(
                    raw
                )
            )
            return None
        return raw

    def _parse_name(self, data: Mapping[str, Any]) -> Optional[str]:
        if "name" not in data:
            self.fail("'name' is required")
            return None
        raw = data["name"]
        if not isinstance(raw, str) or not raw.strip():
            self.fail("'name' must be a non-empty string, found {}".format(_kind(raw)))
            return None
        return raw

    def _parse_graph(
        self, data: Mapping[str, Any]
    ) -> Tuple[Optional[Path], Optional[Dict[str, Any]]]:
        if "workflow" not in data:
            self.fail("'workflow' is required: the API-format JSON this definition describes")
            return None, None
        raw = data["workflow"]
        if not isinstance(raw, str) or not raw.strip():
            self.fail("'workflow' must be a non-empty string, found {}".format(_kind(raw)))
            return None, None
        # Rootedness is judged in both flavours, because the same string means
        # different things per platform: PureWindowsPath("/x.json") is not
        # "absolute" (it has no drive) yet it is certainly not relative, and a
        # drive-relative "C:x.json" is not absolute either.
        windows_form = PureWindowsPath(raw)
        if windows_form.drive or windows_form.root or PurePosixPath(raw).root:
            self.fail(
                "'workflow' must be a path relative to the definition file; {!r} is rooted "
                "outside it".format(raw)
            )
            return None, None

        path = self.source.parent / raw
        if not path.exists():
            self.fail("workflow JSON not found: {}".format(path))
            return path, None
        if not path.is_file():
            self.fail("'workflow' does not point at a file: {}".format(path))
            return path, None

        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            self.fail("workflow JSON is not valid UTF-8 text: {}".format(path))
            return path, None
        except OSError as exc:
            self.fail(
                "cannot read the workflow JSON {}: {}".format(path, exc.strerror or exc)
            )
            return path, None

        try:
            graph = json.loads(text)
        except json.JSONDecodeError as exc:
            self.fail(
                "workflow JSON {} is not valid JSON: {} (line {}, column {})".format(
                    path.name, exc.msg, exc.lineno, exc.colno
                )
            )
            return path, None

        problem = _graph_structure_problem(graph)
        if problem is not None:
            self.fail("workflow JSON {} is not ComfyUI API format: {}".format(path.name, problem))
            return path, None
        return path, graph

    def _parse_presentation(self, data: Mapping[str, Any]) -> Presentation:
        raw = data.get("presentation")
        if raw is None:
            return Presentation()
        if not isinstance(raw, dict):
            self.fail("'presentation' must be a mapping, found {}".format(_kind(raw)))
            return Presentation()

        self._reject_unknown_keys(raw, PRESENTATION_KEYS, "presentation")

        values: Dict[str, Any] = {}
        for key in PRESENTATION_TEXT_KEYS:
            if key not in raw:
                continue
            value = raw[key]
            if not isinstance(value, str):
                self.fail(
                    "presentation.{} must be a string, found {}".format(key, _kind(value))
                )
                continue
            values[key] = value.strip()
        for key in PRESENTATION_LIST_KEYS:
            if key not in raw:
                continue
            value = raw[key]
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                self.fail("presentation.{} must be a list of strings".format(key))
                continue
            values[key] = tuple(item.strip() for item in value)
        return Presentation(**values)

    def _parse_translation(self, data: Mapping[str, Any]) -> TranslationMode:
        """The optional ``translation: {mode: auto|off}`` block.

        Absent means ``auto``: the workflow has no opinion and the gateway's
        configuration decides.  There is no ``on`` -- a workflow cannot switch
        on a stage the machine has not been configured for (T-0040).
        """

        raw = data.get("translation")
        if raw is None:
            return TranslationMode.AUTO
        if not isinstance(raw, dict):
            self.fail("'translation' must be a mapping, found {}".format(_kind(raw)))
            return TranslationMode.AUTO

        self._reject_unknown_keys(raw, TRANSLATION_KEYS, "translation")
        if "mode" not in raw:
            self.fail("translation.mode is required when 'translation' is present")
            return TranslationMode.AUTO

        mode = raw["mode"]
        # YAML reads a bare `off` as the boolean False -- so the most natural
        # way to write this setting arrives here as a bool, and refusing it
        # would be refusing the documented spelling.  `on`/`true` has no
        # meaning: a workflow cannot switch on a stage the machine has not been
        # configured for, and saying so is more useful than a type error.
        if isinstance(mode, bool):
            if mode is False:
                return TranslationMode.OFF
            self.fail(
                "translation.mode must be 'auto' or 'off'; there is no 'on' -- a workflow "
                "cannot switch on translation the gateway is not configured for "
                "(YAML reads a bare 'on' or 'yes' as true)"
            )
            return TranslationMode.AUTO

        try:
            return TranslationMode(mode)
        except ValueError:
            self.fail("translation.mode must be 'auto' or 'off', found {!r}".format(mode))
            return TranslationMode.AUTO

    # -- fields ------------------------------------------------------------

    def _parse_inputs(
        self, data: Mapping[str, Any], graph: Optional[Mapping[str, Any]]
    ) -> Tuple[List[InputField], Dict[str, Tuple[Binding, ...]]]:
        fields: List[InputField] = []
        bindings: Dict[str, Tuple[Binding, ...]] = {}

        if "inputs" not in data:
            self.fail("'inputs' is required; use an empty list for a workflow with no fields")
            return fields, bindings
        raw_inputs = data["inputs"]
        if raw_inputs is None:
            raw_inputs = []
        if not isinstance(raw_inputs, list):
            self.fail("'inputs' must be a list, found {}".format(_kind(raw_inputs)))
            return fields, bindings

        seen_targets: Dict[Tuple[str, str], str] = {}
        for index, raw_field in enumerate(raw_inputs):
            parsed = self._parse_field(raw_field, index, graph)
            if parsed is None:
                continue
            field, field_bindings = parsed
            if field.id in bindings:
                self.fail("duplicate field id {!r}".format(field.id), field_id=field.id)
                continue
            if field_bindings is not None:
                # Every target is checked before the field is rejected, so a
                # curator who wired two of them into another field's inputs
                # sees both, not the first one only.
                taken = False
                for binding in field_bindings:
                    target = (binding.node, binding.input)
                    if target in seen_targets:
                        self.fail(
                            "binds to node {!r} input {!r}, which field {!r} already binds to; "
                            "one node input cannot be driven by two fields".format(
                                binding.node, binding.input, seen_targets[target]
                            ),
                            field_id=field.id,
                        )
                        taken = True
                if taken:
                    continue
                for binding in field_bindings:
                    seen_targets[(binding.node, binding.input)] = field.id
                bindings[field.id] = field_bindings
            fields.append(field)
        return fields, bindings

    def _parse_field(
        self, raw: Any, index: int, graph: Optional[Mapping[str, Any]]
    ) -> Optional[Tuple[InputField, Optional[Tuple[Binding, ...]]]]:
        if not isinstance(raw, dict):
            self.fail("inputs[{}] must be a mapping, found {}".format(index, _kind(raw)))
            return None

        field_id = raw.get("id")
        if not isinstance(field_id, str) or not field_id.strip():
            self.fail("inputs[{}]: 'id' must be a non-empty string".format(index))
            return None

        self._reject_unknown_keys(raw, FIELD_KEYS, "field", field_id=field_id)

        label = raw.get("label")
        if not isinstance(label, str) or not label.strip():
            self.fail("'label' must be a non-empty string", field_id=field_id)
            label = None

        field_type = self._parse_type(raw, field_id)
        if field_type is None:
            return None

        required = self._parse_flag(raw, "required", field_id, default=False)
        section = self._parse_section(raw, field_id)
        help_text = self._parse_help(raw, field_id)

        self._reject_wrong_type_keys(raw, field_type, field_id)

        options = self._parse_options(raw, field_type, field_id)
        bounds = self._parse_bounds(raw, field_type, field_id)
        default, has_default = self._parse_default(
            raw, field_type, field_id, required, bounds, options
        )
        role, pair = self._parse_hints(raw, field_type, field_id)
        duration = self._parse_duration(raw, field_type, field_id)
        translatable = (
            self._parse_flag(raw, "translatable", field_id, default=False)
            if field_type in _TEXT_FIELD_TYPES
            else False
        )
        field_bindings = self._parse_bind(raw, field_id, graph)

        if label is None:
            return None

        return (
            InputField(
                id=field_id,
                label=label,
                type=field_type,
                required=required,
                section=section,
                default=default,
                has_default=has_default,
                help=help_text,
                min=bounds.get("min"),
                max=bounds.get("max"),
                step=bounds.get("step"),
                options=options,
                role=role,
                pair=pair,
                duration=duration,
                translatable=translatable,
            ),
            field_bindings,
        )

    def _parse_type(self, raw: Mapping[str, Any], field_id: str) -> Optional[FieldType]:
        value = raw.get("type")
        if value is None:
            self.fail("'type' is required", field_id=field_id)
            return None
        if not isinstance(value, str):
            self.fail("'type' must be a string, found {}".format(_kind(value)), field_id=field_id)
            return None
        try:
            return FieldType(value)
        except ValueError:
            self.fail(
                "unknown field type {!r}; the v0.1 types are {}".format(
                    value, _quoted_list([item.value for item in FieldType])
                ),
                field_id=field_id,
            )
            return None

    def _parse_flag(
        self, raw: Mapping[str, Any], key: str, field_id: str, default: bool
    ) -> bool:
        if key not in raw:
            return default
        value = raw[key]
        if not isinstance(value, bool):
            self.fail(
                "{!r} must be a boolean, found {}".format(key, _kind(value)), field_id=field_id
            )
            return default
        return value

    def _parse_section(self, raw: Mapping[str, Any], field_id: str) -> Section:
        if "section" not in raw:
            return Section.MAIN
        value = raw["section"]
        try:
            return Section(value)
        except ValueError:
            self.fail(
                "'section' must be 'main' or 'advanced', found {!r}".format(value),
                field_id=field_id,
            )
            return Section.MAIN

    def _parse_help(self, raw: Mapping[str, Any], field_id: str) -> Optional[str]:
        if "help" not in raw:
            return None
        value = raw["help"]
        if not isinstance(value, str):
            self.fail("'help' must be a string, found {}".format(_kind(value)), field_id=field_id)
            return None
        return value.strip()

    def _reject_wrong_type_keys(
        self, raw: Mapping[str, Any], field_type: FieldType, field_id: str
    ) -> None:
        allowed = _TYPE_EXTRAS[field_type]
        for key in _TYPE_SPECIFIC_KEYS:
            if key in raw and key not in allowed:
                self.fail(
                    "{!r} is not valid for a field of type {!r}".format(key, field_type.value),
                    field_id=field_id,
                )
        if "default" in raw and field_type in MEDIA_FIELD_TYPES:
            self.fail(
                "a media field cannot declare a 'default': its value is an uploaded media "
                "reference, not a path",
                field_id=field_id,
            )

    def _parse_options(
        self, raw: Mapping[str, Any], field_type: FieldType, field_id: str
    ) -> Tuple[SelectOption, ...]:
        if field_type is not FieldType.SELECT:
            return ()
        value = raw.get("options")
        if not isinstance(value, list) or not value:
            self.fail(
                "a 'select' field requires a non-empty 'options' list of {value, label} entries",
                field_id=field_id,
            )
            return ()

        options: List[SelectOption] = []
        seen: List[Any] = []
        for index, entry in enumerate(value):
            if not isinstance(entry, dict):
                self.fail(
                    "options[{}] must be a mapping with a 'value', found {}".format(
                        index, _kind(entry)
                    ),
                    field_id=field_id,
                )
                continue
            self._reject_unknown_keys(entry, OPTION_KEYS, "options[{}]".format(index), field_id)
            if "value" not in entry:
                self.fail("options[{}] has no 'value'".format(index), field_id=field_id)
                continue
            option_value = entry["value"]
            if isinstance(option_value, bool) or not isinstance(option_value, (str, int, float)):
                self.fail(
                    "options[{}].value must be a string or a number, found {}".format(
                        index, _kind(option_value)
                    ),
                    field_id=field_id,
                )
                continue
            if isinstance(option_value, str) and not option_value:
                self.fail("options[{}].value must not be empty".format(index), field_id=field_id)
                continue
            if option_value in seen:
                self.fail(
                    "duplicate option value {!r}".format(option_value), field_id=field_id
                )
                continue
            seen.append(option_value)
            label = entry.get("label", option_value)
            if not isinstance(label, str) or not label.strip():
                if "label" in entry:
                    self.fail(
                        "options[{}].label must be a non-empty string".format(index),
                        field_id=field_id,
                    )
                    continue
                label = str(option_value)
            options.append(SelectOption(value=option_value, label=label))
        return tuple(options)

    def _parse_bounds(
        self, raw: Mapping[str, Any], field_type: FieldType, field_id: str
    ) -> Dict[str, Any]:
        bounds: Dict[str, Any] = {}
        if field_type not in NUMERIC_FIELD_TYPES:
            return bounds

        wants_int = field_type is FieldType.INTEGER
        for key in ("min", "max", "step"):
            if key not in raw:
                continue
            value = raw[key]
            if wants_int and not _is_int(value):
                self.fail(
                    "{!r} must be an integer on an 'integer' field, found {}".format(
                        key, _kind(value)
                    ),
                    field_id=field_id,
                )
                continue
            if not wants_int and not _is_number(value):
                self.fail(
                    "{!r} must be a number on a 'float' field, found {}".format(key, _kind(value)),
                    field_id=field_id,
                )
                continue
            bounds[key] = value

        if "step" in bounds and bounds["step"] <= 0:
            self.fail("'step' must be greater than 0, found {}".format(bounds["step"]), field_id)
            bounds.pop("step")
        if "min" in bounds and "max" in bounds and bounds["min"] > bounds["max"]:
            self.fail(
                "'min' ({}) is greater than 'max' ({})".format(bounds["min"], bounds["max"]),
                field_id=field_id,
            )
            bounds.pop("min")
            bounds.pop("max")
        return bounds

    def _parse_default(
        self,
        raw: Mapping[str, Any],
        field_type: FieldType,
        field_id: str,
        required: bool,
        bounds: Mapping[str, Any],
        options: Sequence[SelectOption],
    ) -> Tuple[Any, bool]:
        if "default" not in raw or field_type in MEDIA_FIELD_TYPES:
            return None, False
        value = raw["default"]

        if value is None:
            self.fail(
                "'default' must not be null; omit the key when there is no default",
                field_id=field_id,
            )
            return None, False
        if required and isinstance(value, str) and not value.strip():
            self.fail(
                "a required field cannot declare an empty 'default'; drop the key or make the "
                "field optional",
                field_id=field_id,
            )
            return None, False

        if field_type in (FieldType.STRING, FieldType.MULTILINE):
            if not isinstance(value, str):
                self.fail(
                    "'default' must be a string on a {!r} field, found {}".format(
                        field_type.value, _kind(value)
                    ),
                    field_id=field_id,
                )
                return None, False
            return value, True

        if field_type is FieldType.BOOLEAN:
            if not isinstance(value, bool):
                self.fail(
                    "'default' must be a boolean, found {}".format(_kind(value)), field_id=field_id
                )
                return None, False
            return value, True

        if field_type is FieldType.SELECT:
            if not options:
                return None, False
            if isinstance(value, bool) or not isinstance(value, (str, int, float)):
                # `True in [1]` is true in Python; an option value is never a
                # boolean, so reject the type before testing membership.
                self.fail(
                    "'default' must be a string or a number on a 'select' field, found "
                    "{}".format(_kind(value)),
                    field_id=field_id,
                )
                return None, False
            allowed = [option.value for option in options]
            if value not in allowed:
                self.fail(
                    "'default' {!r} is not one of the options ({})".format(
                        value, _quoted_list(allowed)
                    ),
                    field_id=field_id,
                )
                return None, False
            return value, True

        # integer / float
        if field_type is FieldType.INTEGER and not _is_int(value):
            self.fail(
                "'default' must be an integer, found {}".format(_kind(value)), field_id=field_id
            )
            return None, False
        if field_type is FieldType.FLOAT and not _is_number(value):
            self.fail(
                "'default' must be a number, found {}".format(_kind(value)), field_id=field_id
            )
            return None, False
        if "min" in bounds and value < bounds["min"]:
            self.fail(
                "'default' {} is below 'min' {}".format(value, bounds["min"]), field_id=field_id
            )
            return None, False
        if "max" in bounds and value > bounds["max"]:
            self.fail(
                "'default' {} is above 'max' {}".format(value, bounds["max"]), field_id=field_id
            )
            return None, False
        return value, True

    def _parse_hints(
        self, raw: Mapping[str, Any], field_type: FieldType, field_id: str
    ) -> Tuple[Optional[FieldRole], Optional[FieldPair]]:
        role: Optional[FieldRole] = None
        pair: Optional[FieldPair] = None
        if "role" in raw and field_type is FieldType.INTEGER:
            try:
                role = FieldRole(raw["role"])
            except ValueError:
                self.fail(
                    "unknown 'role' {!r}; the only v0.1 role is 'seed'".format(raw["role"]),
                    field_id=field_id,
                )
        if "pair" in raw and field_type is FieldType.INTEGER:
            try:
                pair = FieldPair(raw["pair"])
            except ValueError:
                self.fail(
                    "'pair' must be 'width' or 'height', found {!r}".format(raw["pair"]),
                    field_id=field_id,
                )
        return role, pair

    def _parse_duration(
        self, raw: Mapping[str, Any], field_type: FieldType, field_id: str
    ) -> Optional[DurationHint]:
        """``duration: {fps: N}`` -- a frame count that may be *shown* as a time.

        Declared, never inferred.  Nothing here looks at the field's id, its
        label, its range or the graph: a frame rate that was not written down
        is a frame rate this loader does not have, and the field then stays the
        plain integer it always was.

        A ``duration`` on a non-integer field has already been refused by
        :meth:`_reject_wrong_type_keys`, which is why this returns early rather
        than raising a second diagnostic about the same key.
        """

        if "duration" not in raw or field_type is not FieldType.INTEGER:
            return None
        block = raw["duration"]
        if not isinstance(block, dict):
            self.fail(
                "'duration' must be a mapping declaring an 'fps', found {}".format(_kind(block)),
                field_id=field_id,
            )
            return None
        self._reject_unknown_keys(block, DURATION_KEYS, "duration", field_id)
        if "fps" not in block:
            self.fail(
                "'duration' requires an 'fps'; the frame rate is declared, never inferred",
                field_id=field_id,
            )
            return None
        fps = block["fps"]
        if not _is_number(fps):
            self.fail(
                "'duration.fps' must be a number, found {}".format(_kind(fps)),
                field_id=field_id,
            )
            return None
        if not math.isfinite(fps):
            self.fail(
                "'duration.fps' must be a finite number, found {}".format(fps),
                field_id=field_id,
            )
            return None
        if fps <= 0:
            self.fail(
                "'duration.fps' must be greater than 0, found {}".format(fps),
                field_id=field_id,
            )
            return None
        return DurationHint(fps=fps)

    def _parse_bind(
        self, raw: Mapping[str, Any], field_id: str, graph: Optional[Mapping[str, Any]]
    ) -> Optional[Tuple[Binding, ...]]:
        """The field's targets, in the order the author wrote them.

        ``bind:`` is either one mapping -- the shape every definition written
        before T-0045 uses -- or a list of them.  A single mapping is exactly
        a one-element list; nothing downstream can tell which spelling was
        used.  ``None`` means the block was rejected, and a diagnostic saying
        why has already been raised.
        """

        if "bind" not in raw:
            self.fail(
                "'bind' is required: every field maps onto at least one node input",
                field_id=field_id,
            )
            return None
        bind = raw["bind"]

        if isinstance(bind, dict):
            entries: Sequence[Any] = [bind]
            wheres = ["bind"]
        elif isinstance(bind, list):
            if not bind:
                # A field that binds to nothing cannot do anything, and saying
                # so at load beats a mystery at generation time.
                self.fail(
                    "'bind' is an empty list; a field must name at least one node input",
                    field_id=field_id,
                )
                return None
            entries = bind
            wheres = ["bind[{}]".format(index) for index in range(len(bind))]
        else:
            self.fail(
                "'bind' must be a mapping or a list of mappings, found {}".format(_kind(bind)),
                field_id=field_id,
            )
            return None

        bindings: List[Binding] = []
        # Every target is parsed even after one fails, so a curator sees all of
        # a bad `bind:` block in one run rather than one entry per rerun.
        rejected = False
        for where, entry in zip(wheres, entries):
            binding = self._parse_bind_target(entry, where, field_id, graph)
            if binding is None:
                rejected = True
                continue
            bindings.append(binding)
        if rejected:
            return None

        seen: Dict[Tuple[str, str], str] = {}
        for where, binding in zip(wheres, bindings):
            target = (binding.node, binding.input)
            if target in seen:
                self.fail(
                    "{} binds to node {!r} input {!r}, which {} already binds to; "
                    "a field may not name the same target twice".format(
                        where, binding.node, binding.input, seen[target]
                    ),
                    field_id=field_id,
                )
                return None
            seen[target] = where

        return tuple(bindings)

    def _parse_bind_target(
        self,
        bind: Any,
        where: str,
        field_id: str,
        graph: Optional[Mapping[str, Any]],
    ) -> Optional[Binding]:
        """One ``{node, input}`` entry.  ``where`` names it in a diagnostic."""

        if not isinstance(bind, dict):
            self.fail(
                "{} must be a mapping, found {}".format(where, _kind(bind)), field_id=field_id
            )
            return None

        self._reject_unknown_keys(bind, BIND_KEYS, where, field_id=field_id)

        if "node" not in bind:
            self.fail("{}.node is required".format(where), field_id=field_id)
            return None
        raw_node = bind["node"]
        # ComfyUI's API format keys nodes as JSON strings; a YAML author will
        # sometimes write `node: 76`.  Both name the same node.
        if _is_int(raw_node):
            node = str(raw_node)
        elif isinstance(raw_node, str) and raw_node.strip():
            node = raw_node
        else:
            self.fail(
                "{}.node must be a node id (a string, or an integer that names one), "
                "found {}".format(where, _kind(raw_node)),
                field_id=field_id,
            )
            return None

        if "input" not in bind:
            self.fail("{}.input is required".format(where), field_id=field_id)
            return None
        raw_input = bind["input"]
        if not isinstance(raw_input, str) or not raw_input.strip():
            self.fail(
                "{}.input must be a non-empty string, found {}".format(where, _kind(raw_input)),
                field_id=field_id,
            )
            return None

        binding = Binding(node=node, input=raw_input)
        if graph is None:
            # The JSON could not be loaded; that failure is already reported and
            # re-reporting every field against it would bury it.
            return binding
        problem = _binding_problem(binding, graph, where)
        if problem is not None:
            self.fail(problem, field_id=field_id)
            return None
        return binding


def _duplicate_mapping_key(text: str) -> Optional[Tuple[str, int]]:
    """The first key declared twice inside one mapping, with its 1-based line.

    ``yaml.safe_load`` is last-wins on a duplicate key: ``name: A`` followed by
    ``name: B`` silently yields ``B``, and a curator who duplicated a key by
    accident sees one of their two lines quietly do nothing.  Composing the
    node graph runs no constructors -- it is as safe as ``safe_load`` -- and is
    the only way to see the second key at all.
    """

    def walk(node: Any) -> Optional[Tuple[str, int]]:
        if isinstance(node, yaml.MappingNode):
            seen = set()
            for key_node, value_node in node.value:
                if isinstance(key_node, yaml.ScalarNode):
                    if key_node.value in seen:
                        return key_node.value, key_node.start_mark.line + 1
                    seen.add(key_node.value)
                found = walk(value_node)
                if found is not None:
                    return found
        elif isinstance(node, yaml.SequenceNode):
            for item in node.value:
                found = walk(item)
                if found is not None:
                    return found
        return None

    return walk(yaml.compose(text, Loader=yaml.SafeLoader))


def _graph_structure_problem(graph: Any) -> Optional[str]:
    """Why ``graph`` is not a ComfyUI API-format prompt, or ``None`` if it is.

    The API format is a flat object of node id -> node, where each node is an
    object (normally ``class_type`` plus ``inputs``).  A UI-format export -- the
    one with ``nodes`` and ``links`` arrays -- fails here, which is the common
    curator mistake this message has to name.
    """

    if not isinstance(graph, dict):
        return (
            "the top level must be an object mapping node ids to nodes, found {}; "
            "export the workflow in API format, not the UI format".format(_kind(graph))
        )
    for node_id, node in graph.items():
        if not isinstance(node, dict):
            return "node {!r} is {}, expected an object".format(str(node_id), _kind(node))
    return None


def _binding_problem(
    binding: Binding, graph: Mapping[str, Any], where: str = "bind"
) -> Optional[str]:
    """Why ``binding`` cannot be written into ``graph``, or ``None`` if it can.

    ``where`` is how the entry is spelled in the definition -- ``bind`` for the
    single-mapping form, ``bind[2]`` for the third entry of a list -- so a
    diagnostic says which target of a multi-target field failed.
    """

    node = graph.get(binding.node)
    if node is None:
        return "{}.node {!r} is not present in the workflow JSON".format(where, binding.node)
    inputs = node.get("inputs") if isinstance(node, dict) else None
    if not isinstance(inputs, dict):
        return "{}: node {!r} has no 'inputs' object to bind into".format(where, binding.node)
    if binding.input not in inputs:
        return "{}.input {!r} is not present on node {!r} (its inputs are {})".format(
            where, binding.input, binding.node, _quoted_list(sorted(inputs)) or "none"
        )
    current = inputs[binding.input]
    if isinstance(current, (list, dict)):
        return (
            "{}.input {!r} on node {!r} is wired to another node's output and cannot be "
            "driven by a user field".format(where, binding.input, binding.node)
        )
    return None


def load_definition(source: Path) -> LoadedDefinition:
    """Parse and validate one workflow definition file."""

    return _DefinitionParser(Path(source)).parse()


__all__ = [
    "WORKFLOW_ID_PATTERN",
    "LoadedDefinition",
    "load_definition",
]
