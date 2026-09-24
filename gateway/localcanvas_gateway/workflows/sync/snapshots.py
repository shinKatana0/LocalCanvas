"""Remembering a conversion, so an unchanged workflow is converted once.

Converting is not free -- a browser, ComfyUI's whole frontend, and about twenty
seconds before the first workflow -- so a run that re-converted sixty-six
unchanged files every time would be a run nobody would want to make a habit of.
This module is the memory: one small JSON document per conversion, under the
gitignored folder the sources configuration already names for imported graphs.

**What a snapshot is keyed on is the whole design.**  Two things decide whether
a remembered conversion still means anything:

* the **source content hash** -- edit the workflow and the conversion of the
  old bytes says nothing about the new ones;
* the **ComfyUI/frontend identity** -- the same canvas converts differently
  against a different build, because what a node's inputs *are* comes from the
  node definitions installed at the time.  Install, update or remove a custom
  node and the identity moves with it
  (:class:`~localcanvas_gateway.workflows.sync.bridge.ComfyIdentity`).

Both are in the file name **and** in the document, and both are checked on the
way in.  The name alone would be enough to find the file; it is checked again
from the content because a file can be copied, and a snapshot that is trusted
because of what it is called is a snapshot that can be made to lie by renaming
it.  The stored graph is re-hashed for the same reason: a half-written or
hand-edited snapshot is a miss, never a silently wrong import.

Nothing here decides anything about a workflow.  It reads and writes.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple

from .bridge import ComfyIdentity, api_bytes
from .config import OutputPaths

#: The shape version of the document below, for the reason the inventory has
#: one: a snapshot written by a later LocalCanvas must be ignored rather than
#: half-read by an earlier one.
SNAPSHOT_VERSION = 1

#: Where the snapshots live, under the folder ``output.imported_api`` already
#: names.  A folder of its own so that the content-addressed graphs a
#: definition points at stay exactly what they were -- this is a cache, those
#: are the artefacts, and mixing them would make "delete the cache" dangerous.
CACHE_DIRECTORY_NAME = "converted"


def cache_directory(output: OutputPaths) -> Path:
    return output.imported_api / CACHE_DIRECTORY_NAME


def _short(digest: str) -> str:
    return digest.split(":")[-1][:16]


def snapshot_path(
    output: OutputPaths, *, source_hash: str, identity_digest: str
) -> Path:
    """Where the conversion of these bytes by that ComfyUI would be kept.

    Both halves are in the name, so a changed source and a changed ComfyUI each
    look for a different file and neither can find the other's.
    """

    return cache_directory(output) / "{}.{}.json".format(
        _short(source_hash), _short(identity_digest)
    )


@dataclass(frozen=True)
class Snapshot:
    """One remembered conversion, with the provenance that makes it checkable."""

    document: Mapping[str, Any]
    source_hash: str
    api_hash: str
    identity: Mapping[str, Any]
    converted_at: str
    source_path: str


def snapshot_document(
    *,
    document: Mapping[str, Any],
    source_hash: str,
    source_path: str,
    source_relative: str,
    identity: ComfyIdentity,
    converted_at: str,
) -> Dict[str, Any]:
    """The provenance record, in the order a person reads it.

    Every question somebody asks of an imported graph months later is answered
    here: which file it came from, what those bytes were, which ComfyUI
    converted them, and when.  The API graph is last because it is the long
    part, and ``sort_keys`` is off for the same reason the definitions are
    written in reading order.
    """

    raw = api_bytes(document)
    return {
        "snapshot_version": SNAPSHOT_VERSION,
        "converted_at": converted_at,
        "source_path": source_path,
        "source_relative": source_relative,
        "source_content_hash": source_hash,
        "api_content_hash": "sha256:" + hashlib.sha256(raw).hexdigest(),
        "comfy": identity.to_document(),
        "api": document,
    }


def write_snapshot(path: Path, document: Mapping[str, Any]) -> Optional[str]:
    """Put one snapshot on disk atomically, or say why not.

    A cache that cannot be written is not a failure of the run: the conversion
    happened, the definition is written, and the only cost is converting again
    next time.  So this reports and the caller carries on.
    """

    text = json.dumps(document, indent=2, ensure_ascii=False, sort_keys=False)
    data = text.encode("utf-8")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".{}.tmp".format(os.getpid()))
        with open(str(temporary), "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        _replace(str(temporary), str(path))
    except OSError as exc:
        return (
            "the converted copy of this workflow could not be cached ({}); it "
            "will be converted again next time.".format(exc.strerror or exc)
        )
    return None


#: Bound here rather than reached through ``os.`` so a test can substitute it,
#: the way ``definitions.py`` and ``inventory.py`` already do.
_replace = os.replace


def read_snapshot(
    path: Path, *, source_hash: str, identity_digest: str
) -> Tuple[Optional[Snapshot], Optional[str]]:
    """The snapshot at ``path`` if it is still true, or why it is not.

    A miss is never an error the user has to act on -- the workflow is simply
    converted again -- so the second half of the answer exists for the report
    and for the tests, not for a warning.
    """

    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None, "no conversion of these bytes by this ComfyUI is remembered."
    except OSError as exc:
        return None, "the remembered conversion could not be read ({}).".format(
            exc.strerror or exc
        )
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        return None, "the remembered conversion is not readable JSON ({}).".format(exc)
    if not isinstance(document, dict):
        return None, "the remembered conversion is not a JSON object."
    if document.get("snapshot_version") != SNAPSHOT_VERSION:
        return None, (
            "the remembered conversion was written in a format this LocalCanvas "
            "does not read (version {!r}).".format(document.get("snapshot_version"))
        )
    if document.get("source_content_hash") != source_hash:
        return None, (
            "the remembered conversion is of different bytes than the file now "
            "on disk."
        )
    comfy = document.get("comfy")
    if not isinstance(comfy, dict) or comfy.get("digest") != identity_digest:
        return None, (
            "the remembered conversion was produced by a different ComfyUI or a "
            "different frontend."
        )
    graph = document.get("api")
    if not isinstance(graph, dict):
        return None, "the remembered conversion carries no graph."
    recomputed = "sha256:" + hashlib.sha256(api_bytes(graph)).hexdigest()
    if recomputed != document.get("api_content_hash"):
        return None, (
            "the remembered conversion does not match its own recorded hash, so "
            "it was not trusted."
        )
    return (
        Snapshot(
            document=graph,
            source_hash=source_hash,
            api_hash=recomputed,
            identity=comfy,
            converted_at=str(document.get("converted_at") or ""),
            source_path=str(document.get("source_path") or ""),
        ),
        None,
    )


__all__ = [
    "CACHE_DIRECTORY_NAME",
    "SNAPSHOT_VERSION",
    "Snapshot",
    "cache_directory",
    "read_snapshot",
    "snapshot_document",
    "snapshot_path",
    "write_snapshot",
]
