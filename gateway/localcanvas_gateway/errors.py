"""The one error shape the app ever sees (`docs/api.md` -- "Errors").

    {"error": {"code": "...", "message": "...", "field": null}}

Three properties this module exists to guarantee:

* ``message`` is written for the person holding the phone.  It says what
  happened in their terms and, where there is one, the thing they can do.
* ``field`` attributes a validation failure to a form field, so the app can put
  the message next to the input that caused it rather than in a toast.
* **a stack trace is never the user-facing surface.**  Detail is logged on the
  PC, where the person who can act on it is sitting.

``code`` is a stable machine-readable token.  The app may branch on it; it is
never shown as-is.
"""

from __future__ import annotations

from typing import Any, Dict, Optional


class ApiError(Exception):
    """An error with a status code, a stable ``code``, and a human message."""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        field: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.field = field

    def to_payload(self) -> Dict[str, Any]:
        return error_payload(self.code, self.message, self.field)


def error_payload(code: str, message: str, field: Optional[str] = None) -> Dict[str, Any]:
    """The documented envelope.  ``field`` is always present, ``null`` when unused."""

    return {"error": {"code": code, "message": message, "field": field}}


class ValidationFailure(ApiError):
    """A submitted value the workflow's own field schema rejects.

    Always carries the field it belongs to: a submission error the app cannot
    place next to an input is an error the user cannot fix.
    """

    def __init__(self, field: str, message: str, code: str = "invalid_input") -> None:
        super().__init__(status_code=400, code=code, message=message, field=field)


__all__ = ["ApiError", "ValidationFailure", "error_payload"]
