"""Writing user values into a copy of a workflow graph.

The loaded API-format JSON is **never** mutated: binding deep-copies it first,
so two concurrent jobs against one workflow cannot see each other's values, and
a second binding of the same workflow starts from the same clean graph as the
first.

Media fields are a seam, not an implementation.  ``image`` and ``video`` hold an
uploaded media reference; turning that reference into the value a ComfyUI loader
input expects is LCM-006's job.  This module asks a
:class:`MediaValueResolver` for it and refuses to guess when none is supplied.
"""

from __future__ import annotations

from typing import Any, Mapping, Optional, Protocol

from .errors import BindingError
from .model import InputField, WorkflowDefinition


class MediaValueResolver(Protocol):
    """Turns an uploaded media reference into the value ComfyUI expects.

    Implemented by the media store (LCM-006).  The app never learns what the
    resolved value is.
    """

    def resolve(self, field: InputField, value: Any) -> Any:  # pragma: no cover - protocol
        ...


def bind_values(
    workflow: WorkflowDefinition,
    values: Mapping[str, Any],
    *,
    media_resolver: Optional[MediaValueResolver] = None,
) -> dict:
    """Return a deep copy of ``workflow``'s graph with ``values`` written into it.

    ``values`` maps field id -> value and is expected to have been validated
    against the field schema already.  What is still checked here is what would
    otherwise fail silently: a field id that does not exist in this workflow, a
    required field with no value, and a media field with no resolver.

    Values are written at ``graph[node]["inputs"][input]``, in field
    declaration order.  Fields absent from ``values`` are left alone -- the
    graph's own value stands.

    A field may name several targets, and then the one value is written into
    every one of them, in the order the definition listed them.  Nothing is
    transformed between targets: one logical input, one value, several places
    in the graph that need it.
    """

    fields = workflow.fields_by_id

    unknown = sorted(str(key) for key in values if key not in fields)
    if unknown:
        raise BindingError(
            "workflow {!r} has no field {}".format(
                workflow.id, ", ".join(repr(name) for name in unknown)
            )
        )

    missing = [item.id for item in workflow.inputs if item.required and item.id not in values]
    if missing:
        raise BindingError(
            "workflow {!r} is missing a value for required field {}".format(
                workflow.id, ", ".join(repr(name) for name in missing)
            )
        )

    graph = workflow.graph_copy()

    for field in workflow.inputs:
        if field.id not in values:
            continue
        value = values[field.id]

        if field.is_media:
            if media_resolver is None:
                raise BindingError(
                    "field {!r} of workflow {!r} is a {} input; binding it needs a media value "
                    "resolver".format(field.id, workflow.id, field.type.value)
                )
            value = media_resolver.resolve(field, value)

        # The media resolver, when there is one, is asked once per field: every
        # target of a media field gets the same resolved value.
        targets = workflow.bindings_for(field.id)
        if not targets:  # pragma: no cover - a validated workflow always has one
            raise BindingError(
                "field {!r} of workflow {!r} has no binding".format(field.id, workflow.id)
            )
        for target in targets:
            graph[target.node]["inputs"][target.input] = value

    return graph


__all__ = ["MediaValueResolver", "bind_values"]
