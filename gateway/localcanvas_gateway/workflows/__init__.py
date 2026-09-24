"""The LocalCanvas workflow registry.

A workflow is two files (`docs/workflow-schema.md`): a ComfyUI **API-format**
JSON exported by the user, and a YAML definition that describes it to humans and
maps user-facing fields onto node inputs.  Adding a workflow is adding those two
files -- never a source change.

This package does three things and nothing else:

* **load** -- discover YAML definitions under a configurable registry root and
  parse each definition together with the JSON it points at
  (:func:`load_registry`);
* **validate** -- reject a bad definition at load time, with a diagnostic naming
  the file, the workflow, the field and the actual problem
  (:class:`Diagnostic`), also runnable offline via
  ``python -m localcanvas_gateway.workflows <root>``;
* **bind** -- write a validated map of field id -> value into a deep copy of the
  workflow graph (:func:`bind_values`).

It does not speak HTTP, does not contact ComfyUI, and does not resolve uploaded
media.

Typical use::

    from localcanvas_gateway.workflows import bind_values, load_registry

    registry = load_registry(config["workflows"]["registry"])
    for diagnostic in registry.diagnostics:
        log.warning("workflow rejected: %s", diagnostic)

    workflow = registry.get("example_txt2img")
    prompt = bind_values(workflow, {"prompt": "a rainy alley at night"})
"""

from .binding import MediaValueResolver, bind_values
from .definition import LoadedDefinition, load_definition
from .diagnostics import Diagnostic
from .errors import BindingError, RegistryError, WorkflowRegistryError
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
from .registry import Registry, load_registry

__all__ = [
    "Binding",
    "BindingError",
    "Diagnostic",
    "DurationHint",
    "FieldPair",
    "FieldRole",
    "FieldType",
    "InputField",
    "LoadedDefinition",
    "MEDIA_FIELD_TYPES",
    "MediaValueResolver",
    "NUMERIC_FIELD_TYPES",
    "Presentation",
    "Registry",
    "RegistryError",
    "Section",
    "SelectOption",
    "TranslationMode",
    "WorkflowDefinition",
    "WorkflowRegistryError",
    "bind_values",
    "load_definition",
    "load_registry",
]
