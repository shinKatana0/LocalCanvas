"""Checking a submitted ``inputs`` map against one workflow's field schema.

`docs/api.md`: *"The gateway validates against the schema -- required, type,
range, select membership -- and rejects with a field-attributed error rather
than passing bad values into ComfyUI."*  Those four checks are exactly what is
implemented here, and nothing else:

* **required** -- a required field with no value is refused;
* **type** -- a value of the wrong kind is refused, and ``true`` is never a
  number even though Python's ``bool`` is an ``int``;
* **range** -- ``min`` / ``max`` are enforced;
* **select membership** -- a value outside ``options`` is refused.

``step`` is deliberately *not* enforced.  The contract lists it as a control
hint for the numeric widget, not as a constraint, and rejecting a legitimate
value because it is off an arbitrary grid would be inventing a rule the curator
did not write.

Every message is addressed to the person holding the phone and names the field
by its **label**, because that is the word they can see on their screen; the
machine-readable attribution is the field ``id`` carried alongside it.

This module is the gate in front of ComfyUI: it is called before anything is
bound or submitted, so a rejected submission never reaches the backend.
"""

from __future__ import annotations

from typing import Any, Dict, Mapping

from .errors import ValidationFailure
from .workflows import FieldType, InputField, WorkflowDefinition


def validate_inputs(
    workflow: WorkflowDefinition, inputs: Mapping[str, Any]
) -> Dict[str, Any]:
    """Return the validated values, or raise :class:`ValidationFailure`.

    The returned map contains only fields the submission actually supplied.  A
    field left out keeps whatever value the curator's own graph already has --
    that is the documented behaviour of an optional field, not an oversight.
    """

    fields = workflow.fields_by_id

    for name in sorted(str(key) for key in inputs):
        if name not in fields:
            raise ValidationFailure(
                field=name,
                code="unknown_field",
                message="This workflow has no {!r} setting.".format(name),
            )

    validated: Dict[str, Any] = {}
    for field in workflow.inputs:
        if field.id not in inputs:
            if field.required:
                raise ValidationFailure(
                    field=field.id,
                    code="missing_field",
                    message="{} is required.".format(field.label),
                )
            continue
        validated[field.id] = _check(field, inputs[field.id])
    return validated


def _check(field: InputField, value: Any) -> Any:
    if value is None:
        raise ValidationFailure(
            field=field.id,
            code="missing_field" if field.required else "invalid_input",
            message="{} needs a value.".format(field.label),
        )

    if field.type in (FieldType.STRING, FieldType.MULTILINE):
        return _check_text(field, value)
    if field.type is FieldType.INTEGER:
        return _check_number(field, value, whole=True)
    if field.type is FieldType.FLOAT:
        return _check_number(field, value, whole=False)
    if field.type is FieldType.BOOLEAN:
        return _check_boolean(field, value)
    if field.type is FieldType.SELECT:
        return _check_select(field, value)
    return _check_media(field, value)


def _check_text(field: InputField, value: Any) -> str:
    if not isinstance(value, str):
        raise ValidationFailure(
            field=field.id, message="{} must be text.".format(field.label)
        )
    if field.required and not value.strip():
        raise ValidationFailure(
            field=field.id,
            code="missing_field",
            message="{} is required.".format(field.label),
        )
    return value


def _check_number(field: InputField, value: Any, *, whole: bool) -> Any:
    # ``bool`` is a subclass of ``int`` in Python.  ``steps: true`` is a
    # mistake, not the number 1, and accepting it would write ``True`` into a
    # ComfyUI node input.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationFailure(
            field=field.id,
            message="{} must be a {}.".format(
                field.label, "whole number" if whole else "number"
            ),
        )
    if whole:
        if isinstance(value, float) and not value.is_integer():
            raise ValidationFailure(
                field=field.id,
                message="{} must be a whole number.".format(field.label),
            )
        value = int(value)
    else:
        value = float(value)

    if field.min is not None and value < field.min:
        raise ValidationFailure(
            field=field.id,
            code="out_of_range",
            message="{} must be at least {}.".format(field.label, _number(field.min, whole)),
        )
    if field.max is not None and value > field.max:
        raise ValidationFailure(
            field=field.id,
            code="out_of_range",
            message="{} must be at most {}.".format(field.label, _number(field.max, whole)),
        )
    return value


def _check_boolean(field: InputField, value: Any) -> bool:
    if not isinstance(value, bool):
        raise ValidationFailure(
            field=field.id, message="{} must be on or off.".format(field.label)
        )
    return value


def _check_select(field: InputField, value: Any) -> Any:
    allowed = [option.value for option in field.options]
    # ``True`` equals ``1`` in Python, so a boolean would match a numeric
    # option by accident.  Compare the type as well as the value.
    for candidate in allowed:
        if type(candidate) is type(value) and candidate == value:
            return value
    labels = [option.label for option in field.options]
    raise ValidationFailure(
        field=field.id,
        code="invalid_choice",
        message="{} must be one of: {}.".format(field.label, ", ".join(labels)),
    )


def _check_media(field: InputField, value: Any) -> Any:
    """A media field carries a reference, never a value (`docs/api.md`).

    What is checked here is the *shape* -- ``{"media_id": "m-..."}`` and nothing
    else -- and it is checked strictly: a bare string, an extra key, a path
    someone hoped would be honoured.  Whether that id still names a file the
    gateway holds is a question for the media store, asked at binding time
    through the resolver seam, because the answer changes with the clock and
    this function is not where a file is looked up.

    The reference is returned untouched.  Turning it into the value a ComfyUI
    loader input expects happens gateway-side, once, and the app never learns
    what that value is.
    """

    if isinstance(value, Mapping) and set(value) == {"media_id"}:
        media_id = value["media_id"]
        if isinstance(media_id, str) and media_id.strip():
            return {"media_id": media_id}
    raise ValidationFailure(
        field=field.id,
        code="invalid_input",
        message="{} needs {} you send first. Choose it again.".format(
            field.label, "an image" if field.type is FieldType.IMAGE else "a video"
        ),
    )


def _number(value: float, whole: bool) -> str:
    if whole or float(value).is_integer():
        return str(int(value))
    return str(value)


__all__ = ["validate_inputs"]
