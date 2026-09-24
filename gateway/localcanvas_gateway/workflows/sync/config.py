"""Reading ``config/local/workflow-sources.yaml``.

This is the *curator's* configuration -- where the user's own ComfyUI workflow
files live and where LocalCanvas may write what it derives from them.  It is a
second file, deliberately: ``runtime.yaml`` is what the gateway needs to serve,
and this is what a one-off command needs to read a folder.  They have different
lifetimes and different audiences, and merging them would make every gateway
start validate paths nothing at run time ever touches.

The rules it is written to are the ones ``localcanvas_gateway/config.py``
already established for ``runtime.yaml``, because a user should not have to
learn two dialects:

* **nothing is guessed.**  No source folder is searched for, defaulted or
  inferred; the only folders ever read are the ones written here.
* **a wrong value fails with a message a person can act on** -- the file, the
  dotted key, what was expected and what was actually there.
* **an unknown key is rejected, not ignored**, and the message lists the keys
  that are accepted at that level.
* **paths containing spaces are ordinary**; nothing here splits on whitespace.

Relative *output* paths resolve against the repository root, so the shipped
example works unedited.  *Source* paths must be absolute: a source folder lives
outside the repository, and there is nothing a relative one could be measured
from -- the same rule, and the same reasoning, as ``comfy.root``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence, Tuple, Union

import yaml

from .errors import SyncConfigError

#: Where the user is told to put their copy, and what to copy it from.  Written
#: with forward slashes because they are what the messages and the README show.
CONFIG_RELATIVE_PATH = "config/local/workflow-sources.yaml"
EXAMPLE_RELATIVE_PATH = "config/examples/workflow-sources.example.yaml"

#: ``<repo>/config/local/workflow-sources.yaml`` -> ``parents[2]`` is ``<repo>``.
#: A rule, not a search: nothing walks the filesystem looking for a repository.
_REPO_ROOT_DEPTH = 2

_TOP_LEVEL_KEYS = ("sources", "output", "sync")
_SOURCE_KEYS = ("path", "recursive")
_OUTPUT_KEYS = ("definitions", "imported_api", "inventory")
_SYNC_KEYS = ("detect_duplicates", "detect_removed", "preserve_manual_metadata")


@dataclass(frozen=True)
class SourceRoot:
    """One folder of the user's own workflow files.

    ``declared`` is the path exactly as the user wrote it, kept so that a
    message about this root names the line they would have to edit.  ``path``
    is that value normalised -- absolute and with the separators of this
    machine -- but *not* resolved: resolving reads the filesystem, and loading
    a configuration file does not.
    """

    declared: str
    path: Path
    recursive: bool


@dataclass(frozen=True)
class OutputPaths:
    """Everything the sync is allowed to write, and the only such places."""

    definitions: Path
    imported_api: Path
    inventory: Path

    def as_tuple(self) -> Tuple[Tuple[str, Path], ...]:
        return (
            ("output.definitions", self.definitions),
            ("output.imported_api", self.imported_api),
            ("output.inventory", self.inventory),
        )


@dataclass(frozen=True)
class SyncOptions:
    """The three switches over how a run compares with the last one."""

    detect_duplicates: bool = True
    detect_removed: bool = True
    preserve_manual_metadata: bool = True


@dataclass(frozen=True)
class SourcesConfig:
    """One parsed, validated ``workflow-sources.yaml``."""

    source: Path
    repo_root: Path
    sources: Tuple[SourceRoot, ...]
    output: OutputPaths
    sync: SyncOptions


def load_sources_config(
    path: Union[str, Path],
    *,
    repo_root: Optional[Union[str, Path]] = None,
) -> SourcesConfig:
    """Read ``path`` and return a validated :class:`SourcesConfig`.

    Raises :class:`SyncConfigError` -- and nothing else -- for every way the
    file can be wrong, including not being there.  The absence message is the
    first thing a new user meets when they get this wrong, so it names the
    example to copy and the command that copies it.
    """

    source = Path(path)
    text = _read(source)
    data = _parse(source, text)
    root = Path(repo_root) if repo_root is not None else _derive_repo_root(source)

    _reject_unknown(source, data, _TOP_LEVEL_KEYS, "")

    return SourcesConfig(
        source=source,
        repo_root=root,
        sources=_sources(source, data),
        output=_output(source, data, root),
        sync=_sync(source, data),
    )


# --------------------------------------------------------------------------
# Reading and parsing
# --------------------------------------------------------------------------


def _read(source: Path) -> str:
    try:
        return source.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SyncConfigError(
            "{source}: no workflow sources configuration here.\n"
            "Copy {example} to {target} and edit the source path to the folder "
            "that holds your ComfyUI workflow files:\n"
            "    Copy-Item {example} {target}".format(
                source=source,
                example=EXAMPLE_RELATIVE_PATH,
                target=CONFIG_RELATIVE_PATH,
            )
        ) from None
    except IsADirectoryError:
        raise SyncConfigError(
            "{}: this is a directory; the workflow sources configuration is a "
            "single YAML file.".format(source)
        ) from None
    except UnicodeDecodeError as exc:
        raise SyncConfigError(
            "{}: not readable as UTF-8 text ({}).".format(source, exc.reason)
        ) from None
    except OSError as exc:
        raise SyncConfigError(
            "{}: could not be read ({}).".format(source, exc.strerror or exc)
        ) from None


def _parse(source: Path, text: str) -> Mapping[str, Any]:
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise SyncConfigError(
            "{}: not valid YAML ({}).".format(source, _flatten(str(exc)))
        ) from exc
    if data is None:
        raise SyncConfigError(
            "{}: the file is empty; expected the sections {}.".format(
                source, _listed(_TOP_LEVEL_KEYS)
            )
        )
    if not isinstance(data, Mapping):
        raise SyncConfigError(
            "{}: expected a mapping of configuration sections at the top level, "
            "got {}.".format(source, _kind(data))
        )
    return data


def _derive_repo_root(source: Path) -> Path:
    resolved = source.resolve()
    parents = resolved.parents
    if len(parents) > _REPO_ROOT_DEPTH:
        return parents[_REPO_ROOT_DEPTH]
    return resolved.parent


# --------------------------------------------------------------------------
# The sections
# --------------------------------------------------------------------------


def _sources(source: Path, data: Mapping[str, Any]) -> Tuple[SourceRoot, ...]:
    if "sources" not in data or data["sources"] is None:
        raise _fail(
            source,
            "sources",
            "required section is missing; expected a list of folders to read, "
            "each with a 'path'.",
        )
    raw = data["sources"]
    if not isinstance(raw, Sequence) or isinstance(raw, (str, bytes)):
        raise _fail(
            source, "sources", "expected a list of source folders, got {}.".format(_kind(raw))
        )
    if len(raw) == 0:
        raise _fail(
            source,
            "sources",
            "the list is empty; LocalCanvas reads only the folders named here, "
            "so an empty list means there is nothing to read.",
        )

    roots = []
    for index, item in enumerate(raw):
        key = "sources[{}]".format(index)
        if not isinstance(item, Mapping):
            raise _fail(
                source, key, "expected a mapping with a 'path', got {}.".format(_kind(item))
            )
        _reject_unknown(source, item, _SOURCE_KEYS, key)
        declared = _text(source, item, key + ".path", "path")
        if not _is_absolute(declared):
            raise _fail(
                source,
                key + ".path",
                "expected an ABSOLUTE path, got {}. There is nothing a relative "
                "path could be measured from here: a workflow folder lives "
                "outside this repository, and LocalCanvas never searches the "
                "machine for one.".format(_shown(declared)),
            )
        roots.append(
            SourceRoot(
                declared=declared,
                path=Path(os.path.normpath(os.path.abspath(declared))),
                recursive=_bool(source, item, key + ".recursive", "recursive", True),
            )
        )
    return tuple(roots)


def _output(source: Path, data: Mapping[str, Any], repo_root: Path) -> OutputPaths:
    section = _section(source, data, "output", _OUTPUT_KEYS)
    values = {}
    for name in _OUTPUT_KEYS:
        declared = _text(source, section, "output." + name, name)
        values[name] = _resolve(repo_root, declared)
    return OutputPaths(**values)


def _sync(source: Path, data: Mapping[str, Any]) -> SyncOptions:
    if "sync" not in data or data["sync"] is None:
        return SyncOptions()
    section = _section(source, data, "sync", _SYNC_KEYS)
    return SyncOptions(
        detect_duplicates=_bool(
            source, section, "sync.detect_duplicates", "detect_duplicates", True
        ),
        detect_removed=_bool(source, section, "sync.detect_removed", "detect_removed", True),
        preserve_manual_metadata=_bool(
            source,
            section,
            "sync.preserve_manual_metadata",
            "preserve_manual_metadata",
            True,
        ),
    )


# --------------------------------------------------------------------------
# Value helpers.  Every error names file, key and expectation.
# --------------------------------------------------------------------------


def _fail(source: Path, key: str, expectation: str) -> SyncConfigError:
    return SyncConfigError("{}: {}: {}".format(source, key, expectation))


def _reject_unknown(
    source: Path, mapping: Mapping[str, Any], allowed: Sequence[str], prefix: str
) -> None:
    unknown = sorted(str(key) for key in mapping if str(key) not in allowed)
    if not unknown:
        return
    where = prefix if prefix else "(top level)"
    raise SyncConfigError(
        "{}: {}: unknown key{} {}. Accepted here: {}.".format(
            source,
            where,
            "" if len(unknown) == 1 else "s",
            ", ".join(repr(name) for name in unknown),
            _listed(allowed),
        )
    )


def _section(
    source: Path, data: Mapping[str, Any], name: str, allowed: Sequence[str]
) -> Mapping[str, Any]:
    if name not in data or data[name] is None:
        raise _fail(
            source,
            name,
            "required section is missing; expected a mapping with {}.".format(_listed(allowed)),
        )
    value = data[name]
    if not isinstance(value, Mapping):
        raise _fail(source, name, "expected a mapping of settings, got {}.".format(_kind(value)))
    _reject_unknown(source, value, allowed, name)
    return value


def _text(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> str:
    if name not in mapping or mapping[name] is None:
        raise _fail(source, key, "required setting is missing.")
    value = mapping[name]
    if not isinstance(value, str) or not value.strip():
        raise _fail(source, key, "expected a non-empty string, got {}.".format(_shown(value)))
    return value


def _bool(
    source: Path, mapping: Mapping[str, Any], key: str, name: str, fallback: bool
) -> bool:
    if name not in mapping or mapping[name] is None:
        return fallback
    value = mapping[name]
    if not isinstance(value, bool):
        raise _fail(source, key, "expected true or false, got {}.".format(_shown(value)))
    return value


def _is_absolute(value: str) -> bool:
    """Is this an absolute path -- in the spelling of the machine reading it?

    ``ntpath`` calls ``/workflows`` absolute, and on Windows it is not: it names
    a folder on whatever drive happens to be current.  A drive letter or a UNC
    share is what makes a Windows path absolute, so the check is both, and the
    POSIX branch is plain ``os.path.isabs``.
    """

    if os.name != "nt":
        return os.path.isabs(value)
    drive, tail = os.path.splitdrive(value)
    return bool(drive) and tail.startswith(("\\", "/"))


def _resolve(repo_root: Path, value: str) -> Path:
    candidate = Path(value)
    if candidate.is_absolute() or _is_absolute(value):
        return Path(os.path.normpath(os.path.abspath(value)))
    return Path(os.path.normpath(os.path.join(str(repo_root), value)))


def _listed(names: Sequence[str]) -> str:
    return ", ".join(repr(name) for name in names)


def _kind(value: Any) -> str:
    if value is None:
        return "nothing"
    if isinstance(value, bool):
        return "a true/false value"
    if isinstance(value, str):
        return "a string"
    if isinstance(value, Mapping):
        return "a mapping"
    if isinstance(value, Sequence):
        return "a list"
    return "a {}".format(type(value).__name__)


def _shown(value: Any) -> str:
    text = repr(value)
    return text if len(text) <= 80 else text[:77] + "..."


def _flatten(message: str) -> str:
    return " ".join(message.split())


__all__ = [
    "CONFIG_RELATIVE_PATH",
    "EXAMPLE_RELATIVE_PATH",
    "OutputPaths",
    "SourceRoot",
    "SourcesConfig",
    "SyncOptions",
    "load_sources_config",
]
