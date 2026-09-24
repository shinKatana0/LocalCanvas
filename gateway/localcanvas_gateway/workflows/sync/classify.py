"""What a file *is*, decided from its content and never from its name.

A ComfyUI user has two kinds of workflow JSON on disk and no reliable way to
tell them apart by looking at the file name -- ``portrait_api.json`` is a name,
not a promise.  So nothing here consults the extension or the stem:

* **API format** -- the executable shape ComfyUI's ``/prompt`` endpoint takes:
  a flat object of node id -> node, each node carrying a ``class_type`` and
  (normally) an ``inputs`` object.  This is the one LocalCanvas can work with
  (`docs/workflow-schema.md`).
* **UI format** -- what the editor saves: an object with a ``nodes`` array.  It
  describes a canvas, not an execution, and it cannot be run.  **No converter
  is written here.**  Converting one to the other means resolving every link
  and every widget order against the node definitions of the exact ComfyUI
  build that saved it; a wrong guess produces a graph that runs and generates
  the wrong picture.  **That is still true and this module is unchanged by
  T-0084**: what that card added is `bridge.py`, which does not convert
  anything either -- it asks the user's own ComfyUI to, in ComfyUI's own
  frontend.  So the reason below stays exactly what this module can honestly
  say from bytes alone, and the engine replaces it with the bridge's own answer
  when there was a ComfyUI to ask.
* **anything else** -- valid JSON of some other shape (a settings file, a
  fragment, a half-finished export) is *ambiguous*, and a person has to look at
  it.  Content that is not JSON at all, or is not a JSON object, is *invalid*.

The nine states a workflow can be in are here too, because seven of them are
decided by this file and the other two by comparison with the inventory; one
enum, one place to read them all.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from enum import Enum
from typing import Any, Mapping, Optional

#: What a user has to do about a UI-format export.  One sentence, actionable,
#: naming the menu path in ComfyUI's own words.  Written in ASCII: it travels
#: through a JSON document into PowerShell and out to a Windows console, and a
#: box-drawing arrow is the kind of character that arrives as a question mark.
EXPORT_INSTRUCTION = (
    "This is a ComfyUI editor (UI format) workflow. It describes a canvas, not "
    "an execution, so it cannot be run as it stands. Open it in ComfyUI and use "
    "Workflow -> Export (API) to save the API-format copy next to it, then run "
    "the sync again. LocalCanvas does not convert one into the other: that "
    "needs the node definitions of the exact ComfyUI build that saved it, and a "
    "wrong guess would run and produce the wrong result."
)


class WorkflowFormat(str, Enum):
    """What the bytes are, before anything is asked of them."""

    API = "api"
    UI = "ui"
    AMBIGUOUS = "ambiguous"
    INVALID = "invalid"


class WorkflowState(str, Enum):
    """The one thing a run says about one workflow.

    Exactly one applies, and they are ranked: a file that cannot be read is
    never also "new", and a duplicate of an invalid file is reported as the
    invalid file it is rather than hidden behind an alias.  The order below is
    that ranking.
    """

    #: The file is not usable at all -- not JSON, or not a JSON object.
    INVALID = "INVALID"
    #: It is the editor's format; it has to be exported again from ComfyUI.
    NEEDS_API_EXPORT = "NEEDS_API_EXPORT"
    #: Valid JSON, but neither format; a person has to look at it.
    NEEDS_REVIEW = "NEEDS_REVIEW"
    #: API format, but it carries something LocalCanvas cannot bind into.
    UNSUPPORTED_INPUT = "UNSUPPORTED_INPUT"
    #: The same content as another file in this run; that one is canonical.
    EXACT_DUPLICATE = "EXACT_DUPLICATE"
    #: Importable, and not in the inventory before this run.
    NEW = "NEW"
    #: Importable, known before, and its content is different now.
    CHANGED = "CHANGED"
    #: Importable, known before, same content.
    UNCHANGED = "UNCHANGED"
    #: In the inventory, and no source file carries it any more.  Nothing is
    #: deleted because of this: the entry stands until the user acts.
    REMOVED_FROM_SOURCE = "REMOVED_FROM_SOURCE"


#: The states that mean "look at this".  Everything else is a normal outcome.
ATTENTION_STATES = (
    WorkflowState.INVALID,
    WorkflowState.NEEDS_API_EXPORT,
    WorkflowState.NEEDS_REVIEW,
    WorkflowState.UNSUPPORTED_INPUT,
    WorkflowState.REMOVED_FROM_SOURCE,
)


@dataclass(frozen=True)
class Classification:
    """What one file's bytes turned out to be."""

    format: WorkflowFormat
    #: Why it is not importable, in a sentence a user can act on.  ``None``
    #: exactly when the file is an importable API-format graph.
    reason: Optional[str]
    content_hash: str
    #: The hash of the same document with its keys sorted and its whitespace
    #: normalised, so that two files that differ only in formatting are seen to
    #: be the same workflow.  ``None`` when the content is not JSON.
    canonical_hash: Optional[str]
    document: Optional[Mapping[str, Any]]

    @property
    def importable(self) -> bool:
        return self.format is WorkflowFormat.API and self.reason is None

    @property
    def state(self) -> Optional[WorkflowState]:
        """The state this classification alone decides, or ``None``.

        ``None`` means the bytes are fine and the state is a question about
        history -- new, changed, unchanged or a duplicate -- which this module
        cannot answer.
        """

        if self.format is WorkflowFormat.INVALID:
            return WorkflowState.INVALID
        if self.format is WorkflowFormat.UI:
            return WorkflowState.NEEDS_API_EXPORT
        if self.format is WorkflowFormat.AMBIGUOUS:
            return WorkflowState.NEEDS_REVIEW
        if self.reason is not None:
            return WorkflowState.UNSUPPORTED_INPUT
        return None


def content_hash(raw: bytes) -> str:
    """The identity of a workflow: what is in it, never where it is.

    Prefixed with the algorithm so that an inventory written today can still be
    read after the algorithm changes -- an unprefixed hex string would silently
    compare unequal and every workflow would look changed at once.
    """

    return "sha256:" + hashlib.sha256(raw).hexdigest()


def classify(raw: bytes) -> Classification:
    """Decide what ``raw`` is.  Reads the bytes, and nothing else."""

    digest = content_hash(raw)
    if not raw.strip():
        return Classification(
            format=WorkflowFormat.INVALID,
            reason="the file is empty.",
            content_hash=digest,
            canonical_hash=None,
            document=None,
        )
    try:
        document = json.loads(raw.decode("utf-8-sig"))
    except UnicodeDecodeError as exc:
        return Classification(
            format=WorkflowFormat.INVALID,
            reason="the file is not UTF-8 text ({}).".format(exc.reason),
            content_hash=digest,
            canonical_hash=None,
            document=None,
        )
    except json.JSONDecodeError as exc:
        return Classification(
            format=WorkflowFormat.INVALID,
            reason="the file is not valid JSON: {} (line {}, column {}).".format(
                exc.msg, exc.lineno, exc.colno
            ),
            content_hash=digest,
            canonical_hash=None,
            document=None,
        )

    if not isinstance(document, dict):
        return Classification(
            format=WorkflowFormat.INVALID,
            reason=(
                "the top level of this file is {}; a ComfyUI workflow is a JSON "
                "object.".format(_kind(document))
            ),
            content_hash=digest,
            canonical_hash=None,
            document=None,
        )

    canonical = _canonical_hash(document)

    if _looks_like_ui(document):
        return Classification(
            format=WorkflowFormat.UI,
            reason=EXPORT_INSTRUCTION,
            content_hash=digest,
            canonical_hash=canonical,
            document=document,
        )

    api_problem = _api_shape_problem(document)
    if api_problem is not None:
        return Classification(
            format=WorkflowFormat.AMBIGUOUS,
            reason=(
                "this is valid JSON but not a workflow LocalCanvas recognises: "
                "{} Open it and check what it is; if it is a workflow, export it "
                "from ComfyUI with Workflow -> Export (API).".format(api_problem)
            ),
            content_hash=digest,
            canonical_hash=canonical,
            document=document,
        )

    unsupported = _unsupported_input_problem(document)
    return Classification(
        format=WorkflowFormat.API,
        reason=unsupported,
        content_hash=digest,
        canonical_hash=canonical,
        document=document,
    )


# --------------------------------------------------------------------------
# The three shape questions
# --------------------------------------------------------------------------


def _looks_like_ui(document: Mapping[str, Any]) -> bool:
    """The editor's save format: a canvas with a list of nodes on it.

    ``nodes`` as a list is the marker.  The API format keys its nodes by id at
    the top level and has no ``nodes`` key at all, so the two cannot both
    match.
    """

    return isinstance(document.get("nodes"), list)


def _api_shape_problem(document: Mapping[str, Any]) -> Optional[str]:
    """Why this is not an API-format graph, or ``None`` when it is.

    The shape (`docs/workflow-schema.md`) is node id -> node, and every node
    carries a ``class_type`` naming the ComfyUI node to run.  One entry without
    it is enough to make the document something else: a settings file, a
    fragment, or an export that went wrong.
    """

    if not document:
        return "it is an empty JSON object, with no nodes in it."
    for node_id, node in document.items():
        if not isinstance(node, dict):
            return "the entry {!r} is {}, and an API-format node is an object.".format(
                str(node_id), _kind(node)
            )
        if not isinstance(node.get("class_type"), str) or not node["class_type"].strip():
            return (
                "the entry {!r} carries no 'class_type', which every node in an "
                "API-format export has.".format(str(node_id))
            )
    return None


def _unsupported_input_problem(document: Mapping[str, Any]) -> Optional[str]:
    """Why an API-format graph cannot be bound into, or ``None``.

    LocalCanvas sets a value by writing ``prompt[node]["inputs"][input]``
    (`docs/workflow-schema.md`, "Binding").  A node whose ``inputs`` is present
    but is not an object has nowhere for that write to land, so the graph
    cannot carry a user-facing field however it is described later.

    This is deliberately the *whole* rule at this stage.  Which inputs are
    worth exposing, and whether their types can be presented, is the importer's
    question, not this one; answering it here would be a second, weaker copy of
    it.
    """

    for node_id, node in document.items():
        inputs = node.get("inputs")
        if inputs is None:
            continue
        if not isinstance(inputs, dict):
            return (
                "node {!r} ({}) has 'inputs' as {}, and LocalCanvas writes a "
                "value at inputs[<name>], which needs an object. Nothing in this "
                "graph could be bound to a control.".format(
                    str(node_id), node.get("class_type"), _kind(inputs)
                )
            )
    return None


def _canonical_hash(document: Any) -> Optional[str]:
    """The hash of the meaning rather than of the bytes.

    Two exports of the same graph can differ by an indent or by key order and
    be the same workflow; this is what notices.  ``sort_keys`` makes the order
    irrelevant, and ``ensure_ascii`` keeps the hashed text independent of how
    the original file happened to spell a non-ASCII character.
    """

    try:
        text = json.dumps(
            document, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
    except (TypeError, ValueError):
        return None
    return "sha256:" + hashlib.sha256(text.encode("ascii")).hexdigest()


def _kind(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "a true/false value"
    if isinstance(value, str):
        return "a string"
    if isinstance(value, (int, float)):
        return "a number"
    if isinstance(value, list):
        return "a list"
    if isinstance(value, dict):
        return "an object"
    return "a {}".format(type(value).__name__)


__all__ = [
    "ATTENTION_STATES",
    "Classification",
    "EXPORT_INSTRUCTION",
    "WorkflowFormat",
    "WorkflowState",
    "classify",
    "content_hash",
]
