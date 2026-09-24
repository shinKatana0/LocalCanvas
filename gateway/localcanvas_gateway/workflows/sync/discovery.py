"""Walking a configured source root, and never one step outside it.

A sync is no exception to reading only what the user names: **only the
configured roots are ever read.**  There is no machine scan, no walking up
from a root, and no following a path found inside a workflow file.  This
module is where that stops being a claim.

Two independent guards hold it, and each one alone is enough to stop a
particular escape.  They are separate on purpose -- either could be removed by
a later edit, and the tests fail one at a time when it is:

1. **A reparse point is never followed.**  Windows lets a directory be a
   symbolic link *or* a junction, and a junction is not a symlink:
   ``os.path.islink`` says False for one, so a walk that only skips symlinks
   walks straight through it.  Here every entry is checked for the
   ``FILE_ATTRIBUTE_REPARSE_POINT`` bit and skipped whatever kind it is.  This
   guard is what stops a junction *inside* the root -- which the second guard
   cannot see, because its target is contained -- from being descended into and
   reporting the same files twice.
2. **Containment is checked against the real path.**  Every candidate is
   resolved (``..`` collapsed, links followed) and must still lie inside the
   resolved root.  This guard is what stops a link *out* of the root, and it is
   the one that would still hold if the first were removed.

Ordering is decided here too, and it is not the filesystem's.  The filesystem
returns entries in whatever order it likes -- creation order on NTFS, hash
order elsewhere -- so two runs over the same tree could otherwise produce two
different documents.  Every result is sorted by its path relative to the root,
which is a property of the tree and not of the volume.
"""

from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path, PurePath
from typing import List, Tuple

from .errors import SyncSourceError

#: Discovery picks candidates by extension; **classification never does**
#: (`classify.py`).  Those are different questions: which files are worth
#: opening in a folder that also holds thumbnails and notes, versus what a file
#: actually is.  A ``.json`` named ``*_api.json`` that holds a UI export is
#: still reported as a UI export.
WORKFLOW_SUFFIXES = (".json",)


@dataclass(frozen=True)
class Candidate:
    """One source file that will be read, with where it came from."""

    root: Path
    path: Path
    relative: str
    size: int


@dataclass(frozen=True)
class SkippedEntry:
    """Something under a root that was deliberately not read, and why."""

    path: str
    reason: str


@dataclass(frozen=True)
class RootScan:
    """What one configured root yielded."""

    declared: str
    root: Path
    recursive: bool
    candidates: Tuple[Candidate, ...]
    skipped: Tuple[SkippedEntry, ...]


def is_contained(candidate, root) -> bool:
    """Is ``candidate`` the folder ``root`` itself, or something inside it?

    Both sides are resolved first, so ``..`` segments, symbolic links and
    junctions are all answered by the same comparison rather than by three
    special cases.  The comparison walks the resolved parents; it is never a
    ``startswith`` on the text, because that also accepts ``<root>-backup``.

    Anything that cannot be resolved answers False.  A path this cannot make
    sense of is not a path proved to be inside the root.
    """

    try:
        resolved_candidate = _real(candidate)
        resolved_root = _real(root)
    except (OSError, ValueError):
        return False
    if resolved_candidate == resolved_root:
        return True
    return resolved_root in resolved_candidate.parents


def resolve_root(declared: str, path) -> Path:
    """The real path of a configured root, or a fatal error saying why not.

    Resolved once, here, so that everything downstream compares like with like:
    a root reached through a link and a file reached through the same link must
    agree, or containment becomes a coin toss.
    """

    try:
        resolved = _resolved(path)
    except (OSError, ValueError) as exc:
        raise SyncSourceError(
            "sources: {}: this path could not be resolved ({}).".format(declared, exc)
        ) from exc
    if not resolved.exists():
        raise SyncSourceError(
            "sources: {}: this folder does not exist. LocalCanvas reads only the "
            "folders you name here and never searches the machine for another "
            "one, so there is nothing to fall back to.".format(declared)
        )
    if not resolved.is_dir():
        raise SyncSourceError(
            "sources: {}: this is a file, not a folder. A source is the folder "
            "that holds your workflow files.".format(declared)
        )
    try:
        with os.scandir(str(resolved)) as entries:
            next(iter(entries), None)
    except OSError as exc:
        raise SyncSourceError(
            "sources: {}: this folder could not be read ({}).".format(
                declared, exc.strerror or exc
            )
        ) from exc
    return resolved


def scan_root(declared: str, path, *, recursive: bool = True) -> RootScan:
    """Every workflow candidate under one root, in a deterministic order."""

    root = resolve_root(declared, path)
    candidates: List[Candidate] = []
    skipped: List[SkippedEntry] = []

    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            entries = _entries(str(directory))
        except OSError as exc:
            skipped.append(
                SkippedEntry(
                    path=str(directory),
                    reason="this folder could not be read ({})".format(exc.strerror or exc),
                )
            )
            continue
        for entry in entries:
            # Guard 1: a reparse point is never followed, whether it is a
            # symbolic link or a junction.
            reparse = _reparse_reason(entry)
            if reparse is not None:
                skipped.append(SkippedEntry(path=entry.path, reason=reparse))
                continue
            # Guard 2: whatever the entry claims to be, its real path has to be
            # inside this root.
            if not is_contained(entry.path, root):
                skipped.append(
                    SkippedEntry(
                        path=entry.path,
                        reason="it resolves outside the configured source folder",
                    )
                )
                continue
            try:
                is_directory = entry.is_dir(follow_symlinks=False)
                is_file = entry.is_file(follow_symlinks=False)
            except OSError as exc:
                skipped.append(
                    SkippedEntry(
                        path=entry.path,
                        reason="it could not be inspected ({})".format(exc.strerror or exc),
                    )
                )
                continue
            if is_directory:
                if recursive:
                    pending.append(Path(entry.path))
                continue
            if not is_file:
                continue
            if PurePath(entry.name).suffix.lower() not in WORKFLOW_SUFFIXES:
                continue
            try:
                size = entry.stat(follow_symlinks=False).st_size
            except OSError as exc:
                skipped.append(
                    SkippedEntry(
                        path=entry.path,
                        reason="its size could not be read ({})".format(exc.strerror or exc),
                    )
                )
                continue
            candidates.append(
                Candidate(
                    root=root,
                    path=Path(entry.path),
                    relative=_relative(root, Path(entry.path)),
                    size=size,
                )
            )

    return RootScan(
        declared=declared,
        root=root,
        recursive=recursive,
        # The filesystem's order is not an order (see the module docstring).
        candidates=tuple(sorted(candidates, key=lambda item: _sort_key(item.relative))),
        skipped=tuple(sorted(skipped, key=lambda item: (_sort_key(item.path), item.reason))),
    )


# --------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------


def _entries(directory: str):
    """One directory's entries, unsorted, exactly as the filesystem gave them.

    Its own function so that the sort above can be tested for what it is: a
    test replaces this with a version that reverses the list, and the results
    have to come out the same.  Sorting inside here would make that test pass
    without the walk sorting anything.
    """

    with os.scandir(directory) as scanner:
        return list(scanner)


def _reparse_reason(entry):
    """Why this entry must not be followed, or ``None`` when it may be.

    ``st_file_attributes`` is the Windows answer and covers junctions, which
    ``is_symlink`` does not; ``is_symlink`` is the answer everywhere else.  An
    entry that cannot be stat'd is treated as unfollowable: an entry we cannot
    identify is not an entry proved safe to walk into.
    """

    try:
        attributes = getattr(entry.stat(follow_symlinks=False), "st_file_attributes", 0)
    except OSError as exc:
        return "it could not be inspected ({})".format(exc.strerror or exc)
    if attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
        return (
            "it is a reparse point (a symbolic link, junction or mount point), "
            "and LocalCanvas never follows one out of a source folder"
        )
    try:
        if entry.is_symlink():
            return (
                "it is a symbolic link, and LocalCanvas never follows one out of "
                "a source folder"
            )
    except OSError as exc:
        return "it could not be inspected ({})".format(exc.strerror or exc)
    return None


def _resolved(value) -> Path:
    """The real path, in the spelling the filesystem reports.

    Kept apart from :func:`_real` because these two answer different
    questions. This one is what a message shows a user and what a relative path
    is measured against, so it must not be case-folded; ``_real`` is only ever
    compared, and on Windows a comparison that respects case would call
    ``C:/Workflows`` and ``c:/workflows`` two different folders.
    """

    return Path(os.path.realpath(os.path.abspath(str(value))))


def _real(value) -> Path:
    """The real path, folded for comparison. Never shown to anybody."""

    return Path(os.path.normcase(str(_resolved(value))))


def _relative(root: Path, path: Path) -> str:
    try:
        relative = os.path.relpath(str(path), str(root))
    except ValueError:
        relative = str(path)
    return PurePath(relative).as_posix()


def _sort_key(value: str) -> Tuple[str, str]:
    """Case-insensitive first, exact second: a total order on either platform.

    Two files whose names differ only in case can coexist on Linux and cannot
    on Windows, so the case-insensitive key alone is not a total order.  The
    exact spelling breaks the tie the same way everywhere.
    """

    return (value.casefold(), value)


__all__ = [
    "Candidate",
    "RootScan",
    "SkippedEntry",
    "WORKFLOW_SUFFIXES",
    "is_contained",
    "resolve_root",
    "scan_root",
]
