"""Per-workflow diagnostics.

A diagnostic is read by a curator fixing their own YAML, so it always names
the source file, the workflow id where it is known, the field id where one
applies, and what is actually wrong.  "Validation failed" is not a diagnostic.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


@dataclass(frozen=True)
class Diagnostic:
    """One reason one workflow definition was rejected."""

    source: Path
    message: str
    workflow_id: Optional[str] = None
    field_id: Optional[str] = None

    def __str__(self) -> str:
        parts = [str(self.source)]
        if self.workflow_id:
            parts.append("workflow {!r}".format(self.workflow_id))
        if self.field_id:
            parts.append("field {!r}".format(self.field_id))
        parts.append(self.message)
        return ": ".join(parts)

    @property
    def sort_key(self) -> Tuple[str, str, str, str]:
        """Total order used to make registry output byte-identical between runs.

        Diagnostics are ordered by workflow id first, in the same plain Unicode
        codepoint order the registry uses for workflows themselves; a
        diagnostic raised before an id could be read sorts first.
        """

        return (
            self.workflow_id or "",
            str(self.source),
            self.field_id or "",
            self.message,
        )


__all__ = ["Diagnostic"]
