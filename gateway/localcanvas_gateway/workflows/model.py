"""The normalized, in-process model of a workflow definition.

`docs/workflow-schema.md` describes two things at once, and this module keeps
them apart deliberately:

* the **presentation view** -- id, name, presentation metadata and the field
  schema.  This is what the gateway may serve to the app (``docs/api.md``).
  It contains no node id, no node type and no binding.
* the **binding view** -- ``field id -> one or more (node, input) targets`` plus
  the API-format graph itself.  This stays gateway-side.  A LocalCanvas field is
  one *logical* user input, not one ComfyUI node input: a graph routinely
  carries the same concept in several places (one prompt feeding two
  conditioning nodes, one seed in ``seed`` and again in ``noise_seed``), and the
  user sets it once.

:class:`InputField` therefore carries no ``bind`` block at all: bindings live in
:attr:`WorkflowDefinition.bindings`, and the graph lives in
:attr:`WorkflowDefinition.graph`.  Leaking a node id into an API response takes
a deliberate mistake rather than a forgotten field filter.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field as dataclass_field
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple


class FieldType(str, Enum):
    """The eight v0.1 field types.  See `docs/workflow-schema.md`."""

    STRING = "string"
    MULTILINE = "multiline"
    INTEGER = "integer"
    FLOAT = "float"
    BOOLEAN = "boolean"
    SELECT = "select"
    IMAGE = "image"
    VIDEO = "video"


class Section(str, Enum):
    """Where a field is shown.  ``main`` is the default."""

    MAIN = "main"
    ADVANCED = "advanced"


class FieldRole(str, Enum):
    """Presentation hint: ``role: seed`` adds a Random affordance."""

    SEED = "seed"


class FieldPair(str, Enum):
    """Presentation hint: ``pair: width|height`` hints a paired layout."""

    WIDTH = "width"
    HEIGHT = "height"


@dataclass(frozen=True)
class DurationHint:
    """Presentation hint: an integer frame count that may be *shown* as a time.

    ``duration: {fps: 24}`` says "this field counts frames, and the workflow
    runs them at 24 per second".  It is **declared, never inferred**: nothing
    in this package reads a frame rate out of the graph, and no field name,
    label or value range switches it on.  A workflow that does not declare it
    renders exactly as it did before the hint existed.

    It changes no value.  The frame count is what is validated, bound and sent
    to ComfyUI; the duration exists only in a renderer's presentation of that
    number, which is why a renderer that ignores this hint still produces a
    correct form.
    """

    #: Frames per second, as the curator wrote it.  Always greater than zero;
    #: the loader refuses anything else.
    fps: float

    def to_view(self) -> Dict[str, Any]:
        return {"fps": self.fps}


class TranslationMode(str, Enum):
    """A workflow's own answer to prompt translation (`docs/api.md`).

    ``auto`` -- the default -- means "whatever the gateway is configured to do".
    ``off`` means this workflow's text is never translated, whatever the
    gateway's configuration says, which is how a curator protects a workflow
    whose prompt is not natural language at all.  There is no ``on``: a
    workflow cannot switch on a stage the machine has not been configured for.
    """

    AUTO = "auto"
    OFF = "off"


#: Media fields hold an uploaded media reference, never a path string.
MEDIA_FIELD_TYPES = frozenset({FieldType.IMAGE, FieldType.VIDEO})
#: Fields that accept ``min`` / ``max`` / ``step``.
NUMERIC_FIELD_TYPES = frozenset({FieldType.INTEGER, FieldType.FLOAT})


@dataclass(frozen=True)
class SelectOption:
    """One entry of a ``select`` field's ``options`` list."""

    value: Any
    label: str


@dataclass(frozen=True)
class Binding:
    """One place a field's value is written in the API-format graph.

    A field may have several of these; each one is a single ``(node, input)``
    target.

    ``node`` is always a string: ComfyUI's API format keys nodes as JSON
    strings, and a YAML author will sometimes write ``node: 76``.  Both are
    normalized here so that they resolve to the same node.
    """

    node: str
    input: str


@dataclass(frozen=True)
class Presentation:
    """Free-form descriptive metadata shown in the app's picker and help.

    ``group``, ``category`` and ``badge`` are *data, not an enumeration in
    code*: nothing in this package branches on their values.
    """

    group: Optional[str] = None
    category: Optional[str] = None
    badge: Optional[str] = None
    short_description: Optional[str] = None
    best_for: Tuple[str, ...] = ()
    how_to_use: Optional[str] = None
    input_summary: Optional[str] = None
    example_prompt: Optional[str] = None
    not_ideal_for: Tuple[str, ...] = ()

    def to_view(self) -> Dict[str, Any]:
        """Presentation metadata as plain data, omitting what was not supplied."""

        view: Dict[str, Any] = {}
        for key in (
            "group",
            "category",
            "badge",
            "short_description",
            "how_to_use",
            "input_summary",
            "example_prompt",
        ):
            value = getattr(self, key)
            if value is not None:
                view[key] = value
        for key in ("best_for", "not_ideal_for"):
            value = getattr(self, key)
            if value:
                view[key] = list(value)
        return view


@dataclass(frozen=True)
class InputField:
    """One user-facing field.  Carries no binding -- that is the other view."""

    id: str
    label: str
    type: FieldType
    required: bool = False
    section: Section = Section.MAIN
    default: Any = None
    has_default: bool = False
    help: Optional[str] = None
    min: Optional[float] = None
    max: Optional[float] = None
    step: Optional[float] = None
    options: Tuple[SelectOption, ...] = ()
    role: Optional[FieldRole] = None
    pair: Optional[FieldPair] = None
    #: ``duration: {fps: N}`` -- this integer is a frame count a renderer may
    #: also show as a time.  Presentation only: see :class:`DurationHint`.
    duration: Optional[DurationHint] = None
    #: ``translatable: true`` -- this field holds natural language the gateway
    #: may translate before binding (`docs/workflow-schema.md`).  Gateway-side
    #: only, and deliberately absent from :meth:`to_view`: the app is told what
    #: was translated in the submission's answer, and needs no second, static
    #: description of which fields might be.
    translatable: bool = False

    @property
    def is_media(self) -> bool:
        return self.type in MEDIA_FIELD_TYPES

    def to_view(self) -> Dict[str, Any]:
        """The field as the app receives it: schema only, never a graph."""

        view: Dict[str, Any] = {
            "id": self.id,
            "label": self.label,
            "type": self.type.value,
            "required": self.required,
            "section": self.section.value,
        }
        if self.has_default:
            view["default"] = self.default
        if self.help is not None:
            view["help"] = self.help
        for key in ("min", "max", "step"):
            value = getattr(self, key)
            if value is not None:
                view[key] = value
        if self.options:
            view["options"] = [
                {"value": option.value, "label": option.label} for option in self.options
            ]
        if self.role is not None:
            view["role"] = self.role.value
        if self.pair is not None:
            view["pair"] = self.pair.value
        if self.duration is not None:
            view["duration"] = self.duration.to_view()
        return view


@dataclass(frozen=True)
class WorkflowDefinition:
    """One validated workflow: presentation view plus binding view."""

    id: str
    name: str
    source: Path
    workflow_path: Path
    presentation: Presentation = dataclass_field(default_factory=Presentation)
    inputs: Tuple[InputField, ...] = ()
    #: Field id -> the targets that field's value is written into, in the order
    #: the author wrote them.  A single ``bind:`` mapping is a one-element
    #: tuple; there is no separate "one target" shape to get wrong.
    bindings: Mapping[str, Tuple[Binding, ...]] = dataclass_field(default_factory=dict)
    graph: Mapping[str, Any] = dataclass_field(default_factory=dict, repr=False)
    #: This workflow's own translation setting.  Binding view, not presentation
    #: view: it decides what the gateway does, and the app never reads it.
    translation_mode: TranslationMode = TranslationMode.AUTO

    # -- presentation view -------------------------------------------------

    @property
    def fields_by_id(self) -> Dict[str, InputField]:
        return {item.id: item for item in self.inputs}

    def field(self, field_id: str) -> Optional[InputField]:
        return self.fields_by_id.get(field_id)

    @property
    def required_media(self) -> Tuple[str, ...]:
        """Media kinds this workflow cannot run without, in declaration order."""

        kinds: List[str] = []
        for item in self.inputs:
            if item.is_media and item.required and item.type.value not in kinds:
                kinds.append(item.type.value)
        return tuple(kinds)

    def summary_view(self) -> Dict[str, Any]:
        """The picker-level view: what a list of workflows shows."""

        return {
            "id": self.id,
            "name": self.name,
            "presentation": self.presentation.to_view(),
            "required_media": list(self.required_media),
        }

    def detail_view(self) -> Dict[str, Any]:
        """The picker-level view plus the full field schema.  Still no graph."""

        view = self.summary_view()
        view["inputs"] = [item.to_view() for item in self.inputs]
        return view

    # -- binding view ------------------------------------------------------

    def bindings_for(self, field_id: str) -> Tuple[Binding, ...]:
        """Every target this field writes into, in the author's order.

        Empty for a field this workflow does not have.  There is deliberately
        no singular ``binding()`` accessor: one that returned the first of
        several targets would silently drop the rest, which is exactly the bug
        a multi-target binding exists to remove.
        """

        return tuple(self.bindings.get(field_id, ()))

    def graph_copy(self) -> Dict[str, Any]:
        """A deep copy of the loaded API-format JSON.

        The loaded source is never handed out: two concurrent jobs against one
        workflow must not be able to see each other's values.
        """

        return copy.deepcopy(dict(self.graph))


__all__ = [
    "FieldType",
    "Section",
    "FieldRole",
    "FieldPair",
    "DurationHint",
    "MEDIA_FIELD_TYPES",
    "NUMERIC_FIELD_TYPES",
    "SelectOption",
    "Binding",
    "Presentation",
    "InputField",
    "TranslationMode",
    "WorkflowDefinition",
]
