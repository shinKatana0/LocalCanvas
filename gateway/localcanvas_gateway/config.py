"""Loading and validating ``config/local/runtime.yaml`` (`docs/runtime.md`).

Three rules shape this module, and all three come from the contract:

* **No ComfyUI location is ever guessed, defaulted or searched for.**  There is
  no fallback root, no "usual place", no probing of the machine.  A missing
  ``comfy.root`` in managed mode is an error naming the key, never a hint.
* **A wrong value fails with a message a person can act on** -- the file, the
  dotted key, what was expected and what was actually there.  A traceback is
  not a configuration error message.
* **Paths containing spaces are ordinary.**  Nothing here splits a value on
  whitespace or builds a command line by concatenation; a path is a path.

An unknown key is rejected rather than ignored, for the same reason the workflow
registry rejects one: ``manage_comfu: true`` that is silently dropped turns into
a mode nobody chose, discovered much later.  The message lists the keys that
*are* accepted at that level.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field as dataclass_field
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple, Union

import yaml

from .media import (
    DEFAULT_MAX_IMAGE_MEGABYTES,
    DEFAULT_MAX_STORE_MEGABYTES,
    DEFAULT_MAX_VIDEO_MEGABYTES,
    DEFAULT_TTL_SECONDS,
    MEGABYTE,
)

# The languages prompt translation can recognise, imported rather than
# repeated: the detector decides what is supported, and a second list here
# would be a second answer that drifts (`translation/detect.py`).
from .translation.detect import SUPPORTED_SOURCES as SUPPORTED_TRANSLATION_SOURCES

#: A language code as a person writes one in configuration.
_LANGUAGE_CODE = re.compile(r"^[a-z]{2,3}$")


class ConfigError(Exception):
    """Configuration is missing, unreadable, or does not satisfy the contract."""


#: Where the registry root is resolved from when the path is relative
#: (`docs/runtime.md`: "Relative paths are resolved from the repository root").
#: ``<repo>/config/local/runtime.yaml`` -> ``parents[2]`` is ``<repo>``.
_REPO_ROOT_DEPTH = 2


@dataclass(frozen=True)
class ComfyLauncher:
    """How to start ComfyUI.  Only meaningful in managed mode.

    Both values are kept exactly as the user wrote them.  Resolving them against
    ``comfy.root`` -- the documented rule, "relative to `root` unless you give an
    absolute path" -- is :meth:`ComfyConfig.launcher_paths`, so that the rule
    lives in one place and the scripts are handed the answer rather than the
    rule (`docs/runtime.md`, "The configuration seam").
    """

    executable: str
    script: str


@dataclass(frozen=True)
class ComfyConfig:
    """Where ComfyUI is, and -- in managed mode -- how to start it."""

    host: str
    port: int
    root: Optional[Path] = None
    launcher: Optional[ComfyLauncher] = None
    extra_args: Tuple[str, ...] = ()

    @property
    def base_url(self) -> str:
        """The origin the gateway talks to.  Always derived, never hardcoded."""

        return "http://{}:{}".format(_host_for_url(self.host), self.port)

    def launcher_paths(self) -> Optional[Tuple[Path, Path]]:
        """``(executable, script)`` as absolute paths, or ``None``.

        A relative launcher path is relative to ``comfy.root``; an absolute one
        stands.  ``None`` when there is no launcher, or no root to resolve it
        against -- never a guessed location.
        """

        if self.launcher is None or self.root is None:
            return None
        return (
            _under(self.root, self.launcher.executable),
            _under(self.root, self.launcher.script),
        )


@dataclass(frozen=True)
class GatewayConfig:
    """The one LAN-facing surface (`docs/privacy-security.md`)."""

    host: str
    port: int


@dataclass(frozen=True)
class StartupConfig:
    """Readiness budgets.  A timeout bounds a probe; it is never a sleep."""

    comfy_timeout_seconds: float = 120.0
    gateway_timeout_seconds: float = 30.0


@dataclass(frozen=True)
class MediaConfig:
    """What the temporary media store will accept and how long it keeps it.

    Written in megabytes and seconds because a person edits this file: a
    ceiling of ``1073741824`` is a number nobody checks.  The store itself
    works in bytes, and :attr:`max_upload_bytes` / :attr:`max_store_bytes` are
    where the one multiplication happens.

    The defaults are :mod:`localcanvas_gateway.media`'s own -- imported rather
    than repeated, so raising a limit is one edit and the two halves cannot
    drift.
    """

    max_image_megabytes: int = DEFAULT_MAX_IMAGE_MEGABYTES
    max_video_megabytes: int = DEFAULT_MAX_VIDEO_MEGABYTES
    max_store_megabytes: int = DEFAULT_MAX_STORE_MEGABYTES
    ttl_seconds: float = DEFAULT_TTL_SECONDS

    @property
    def max_upload_bytes(self) -> Dict[str, int]:
        """The per-kind ceiling, keyed the way the store expects it."""

        return {
            "image": self.max_image_megabytes * MEGABYTE,
            "video": self.max_video_megabytes * MEGABYTE,
        }

    @property
    def max_store_bytes(self) -> int:
        return self.max_store_megabytes * MEGABYTE


@dataclass(frozen=True)
class PromptTranslationConfig:
    """Local prompt translation before binding (`docs/api.md`, T-0040).

    **Absent means off.**  The backend is an optional install of about a
    gigabyte, so a gateway whose configuration says nothing about translation
    is a gateway that does not translate -- rather than one that fails a
    generation because a package the user never asked for is not there.

    ``sources`` are the languages the gateway may detect and translate *from*;
    they are validated against the ones detection can actually recognise, since
    a language it cannot recognise is one it could only guess at.  These four
    keys are the whole of the setting: it is a feature switch, not a policy
    framework.
    """

    enabled: bool = False
    target: str = "en"
    sources: Tuple[str, ...] = ("ru", "ja")
    preserve_quoted_literals: bool = True


@dataclass(frozen=True)
class IdentityConfig:
    """What this machine calls itself in discovery and in the app."""

    display_name: str


@dataclass(frozen=True)
class RuntimeConfig:
    """One parsed, validated ``runtime.yaml``."""

    source: Path
    repo_root: Path
    manage_comfy: bool
    comfy: ComfyConfig
    workflows_registry: Path
    gateway: GatewayConfig
    identity: IdentityConfig
    startup: StartupConfig = dataclass_field(default_factory=StartupConfig)
    media: MediaConfig = dataclass_field(default_factory=MediaConfig)
    prompt_translation: PromptTranslationConfig = dataclass_field(
        default_factory=PromptTranslationConfig
    )


# --------------------------------------------------------------------------
# Accepted keys.  Listed once, used both for validation and for the message a
# rejected key produces.
# --------------------------------------------------------------------------

_TOP_LEVEL_KEYS = (
    "runtime",
    "comfy",
    "workflows",
    "gateway",
    "startup",
    "identity",
    "media",
    "prompt_translation",
)
_RUNTIME_KEYS = ("manage_comfy",)
_COMFY_KEYS = ("root", "host", "port", "launcher", "extra_args")
_LAUNCHER_KEYS = ("executable", "script")
_WORKFLOWS_KEYS = ("registry",)
_GATEWAY_KEYS = ("host", "port")
_STARTUP_KEYS = ("comfy_timeout_seconds", "gateway_timeout_seconds")
_IDENTITY_KEYS = ("display_name",)
_MEDIA_KEYS = (
    "max_image_megabytes",
    "max_video_megabytes",
    "max_store_megabytes",
    "ttl_seconds",
)
_PROMPT_TRANSLATION_KEYS = ("enabled", "target", "sources", "preserve_quoted_literals")


def load_config(
    path: Union[str, Path],
    *,
    repo_root: Optional[Union[str, Path]] = None,
) -> RuntimeConfig:
    """Read ``path`` and return a validated :class:`RuntimeConfig`.

    ``repo_root`` is what a relative ``workflows.registry`` resolves against.
    When it is not given it is derived from the config file's own location --
    ``<repo>/config/local/runtime.yaml`` puts the root two directories above
    the file's directory.  That is a rule, not a search: nothing walks the
    filesystem looking for a repository.
    """

    source = Path(path)
    text = _read(source)
    data = _parse(source, text)
    root = Path(repo_root) if repo_root is not None else _derive_repo_root(source)

    _reject_unknown(source, data, _TOP_LEVEL_KEYS, "")

    runtime_section = _section(source, data, "runtime", _RUNTIME_KEYS)
    manage_comfy = _bool(source, runtime_section, "runtime.manage_comfy", "manage_comfy")

    comfy = _comfy(
        source, _section(source, data, "comfy", _COMFY_KEYS), manage_comfy=manage_comfy
    )

    workflows_section = _section(source, data, "workflows", _WORKFLOWS_KEYS)
    registry = _resolve(
        root, _path_value(source, workflows_section, "workflows.registry", "registry")
    )

    gateway_section = _section(source, data, "gateway", _GATEWAY_KEYS)
    gateway = GatewayConfig(
        host=_host(source, gateway_section, "gateway.host", "host"),
        port=_port(source, gateway_section, "gateway.port", "port"),
    )

    identity_section = _section(source, data, "identity", _IDENTITY_KEYS)
    identity = IdentityConfig(
        display_name=_text(source, identity_section, "identity.display_name", "display_name")
    )

    return RuntimeConfig(
        source=source,
        repo_root=root,
        manage_comfy=manage_comfy,
        comfy=comfy,
        workflows_registry=registry,
        gateway=gateway,
        identity=identity,
        startup=_startup(source, data),
        media=_media(source, data),
        prompt_translation=_prompt_translation(source, data),
    )


# --------------------------------------------------------------------------
# The configuration seam (`docs/runtime.md`)
# --------------------------------------------------------------------------

#: Bumped when the document below changes shape.  Its consumer is a PowerShell
#: script elsewhere in this tree with no fallback reader, so "we changed the
#: key names" has to be something it can detect rather than trip over.
#:
#: 2 -- added the ``media`` section (LCM-006).  Purely additive: every key the
#: scripts read is where it was, and they read none of the new ones, so an
#: older script keeps working.  Bumped anyway, because the number's job is to
#: describe the shape and a version that only moves on breakage cannot be used
#: to tell which shape you have.
#:
#: 3 -- added the ``prompt_translation`` section (T-0040).  Additive in the same
#: way: no existing key moved, and no script reads the new one.
CONFIG_DOCUMENT_VERSION = 3


def config_document(config: RuntimeConfig) -> Dict[str, Any]:
    """The whole configuration as one JSON-ready document.

    This is the only thing `scripts/*.ps1` know about `runtime.yaml`
    (`docs/runtime.md`, "The configuration seam"): they never parse YAML, apply
    a default or check a type.  Two rules follow from that, and both are
    deliberate:

    * **Every key is always present.**  An optional value is ``null``, never
      missing.  A consumer with no fallback must be able to read a key and get
      an answer, rather than discover that a section it expected is absent.
    * **Everything arrives decided.**  Paths are absolute, the launcher is
      already resolved against ``comfy.root``, and ``comfy.base_url`` is
      composed here -- so that there is one definition of each, on this side.
    """

    launcher: Optional[Dict[str, Any]] = None
    if config.comfy.launcher is not None:
        resolved = config.comfy.launcher_paths()
        launcher = {
            "executable": config.comfy.launcher.executable,
            "script": config.comfy.launcher.script,
            "executable_path": _as_text(resolved[0]) if resolved else None,
            "script_path": _as_text(resolved[1]) if resolved else None,
        }

    return {
        "config_version": CONFIG_DOCUMENT_VERSION,
        # Absolute, unlike the error messages, which echo the path the user
        # typed so they recognise it.  A consumer of this document may have a
        # different working directory than the process that produced it.
        "source": _as_text(Path(config.source).resolve()),
        "repo_root": _as_text(config.repo_root),
        "runtime": {"manage_comfy": config.manage_comfy},
        "comfy": {
            "host": config.comfy.host,
            "port": config.comfy.port,
            "base_url": config.comfy.base_url,
            "root": _as_text(config.comfy.root),
            "launcher": launcher,
            "extra_args": list(config.comfy.extra_args),
        },
        "workflows": {"registry": _as_text(config.workflows_registry)},
        "gateway": {"host": config.gateway.host, "port": config.gateway.port},
        "startup": {
            "comfy_timeout_seconds": config.startup.comfy_timeout_seconds,
            "gateway_timeout_seconds": config.startup.gateway_timeout_seconds,
        },
        "identity": {"display_name": config.identity.display_name},
        # No script reads these today.  They are here for the same reason every
        # other section is: the document is the one description of what
        # `runtime.yaml` means, and a typed field the user can set that the
        # document does not mention is a second, private definition.
        "media": {
            "max_image_megabytes": config.media.max_image_megabytes,
            "max_video_megabytes": config.media.max_video_megabytes,
            "max_store_megabytes": config.media.max_store_megabytes,
            "ttl_seconds": config.media.ttl_seconds,
        },
        "prompt_translation": {
            "enabled": config.prompt_translation.enabled,
            "target": config.prompt_translation.target,
            "sources": list(config.prompt_translation.sources),
            "preserve_quoted_literals": config.prompt_translation.preserve_quoted_literals,
        },
    }


def _as_text(path: Optional[Path]) -> Optional[str]:
    return None if path is None else str(path)


# --------------------------------------------------------------------------
# Reading
# --------------------------------------------------------------------------


def _read(source: Path) -> str:
    if not source.exists():
        raise ConfigError(
            "{}: configuration file not found. Copy "
            "config/examples/runtime.example.yaml to config/local/runtime.yaml "
            "and edit it for this machine.".format(source)
        )
    if source.is_dir():
        raise ConfigError("{}: configuration path is a directory, not a file.".format(source))
    try:
        return source.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(
            "{}: configuration file cannot be read ({}).".format(source, exc.strerror or exc)
        ) from exc


def _parse(source: Path, text: str) -> Mapping[str, Any]:
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ConfigError("{}: not valid YAML ({}).".format(source, _flatten(str(exc)))) from exc
    if data is None:
        raise ConfigError(
            "{}: the configuration file is empty; expected the sections {}.".format(
                source, _listed(_TOP_LEVEL_KEYS)
            )
        )
    if not isinstance(data, Mapping):
        raise ConfigError(
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
# Section and value helpers.  Every error names file, key and expectation.
# --------------------------------------------------------------------------


def _fail(source: Path, key: str, expectation: str) -> ConfigError:
    return ConfigError("{}: {}: {}".format(source, key, expectation))


def _reject_unknown(
    source: Path, mapping: Mapping[str, Any], allowed: Sequence[str], prefix: str
) -> None:
    unknown = sorted(str(key) for key in mapping if str(key) not in allowed)
    if not unknown:
        return
    where = prefix if prefix else "(top level)"
    raise ConfigError(
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
    if name not in data:
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


def _required(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> Any:
    if name not in mapping or mapping[name] is None:
        raise _fail(source, key, "required setting is missing.")
    return mapping[name]


def _bool(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> bool:
    value = _required(source, mapping, key, name)
    if not isinstance(value, bool):
        raise _fail(source, key, "expected true or false, got {}.".format(_shown(value)))
    return value


def _text(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> str:
    value = _required(source, mapping, key, name)
    if not isinstance(value, str) or not value.strip():
        raise _fail(source, key, "expected a non-empty string, got {}.".format(_shown(value)))
    return value


def _host(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> str:
    value = _text(source, mapping, key, name)
    if any(character.isspace() for character in value):
        raise _fail(
            source, key, "expected a host name or IP address, got {}.".format(_shown(value))
        )
    return value


def _port(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> int:
    value = _required(source, mapping, key, name)
    expectation = "expected a TCP port number from 1 to 65535, got {}.".format(_shown(value))
    if isinstance(value, bool) or not isinstance(value, int):
        raise _fail(source, key, expectation)
    if not 1 <= value <= 65535:
        raise _fail(source, key, expectation)
    return value


def _seconds(
    source: Path, mapping: Mapping[str, Any], key: str, name: str, fallback: float
) -> float:
    if name not in mapping or mapping[name] is None:
        return fallback
    value = mapping[name]
    expectation = "expected a number of seconds greater than 0, got {}.".format(_shown(value))
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise _fail(source, key, expectation)
    if value <= 0:
        raise _fail(source, key, expectation)
    return float(value)


def _path_value(source: Path, mapping: Mapping[str, Any], key: str, name: str) -> str:
    """A filesystem path exactly as written.  Never split, globbed or guessed."""

    value = _required(source, mapping, key, name)
    if not isinstance(value, str) or not value.strip():
        raise _fail(
            source, key, "expected a filesystem path as a string, got {}.".format(_shown(value))
        )
    return value


def _absolute_path(
    source: Path, mapping: Mapping[str, Any], key: str, name: str
) -> Path:
    """A configured path that must already say where it is.

    ``workflows.registry`` has a documented base to be relative to -- the
    repository root -- and ``comfy.root`` has none.  There are only two ways to
    accept a relative one, and both are wrong: resolve it against a directory
    nobody named (that is guessing at a ComfyUI location, which
    `docs/runtime.md` forbids outright), or pass it on relative, which makes the
    answer depend on whoever's working directory happens to read it -- and the
    configuration seam exists precisely so that consumers do no normalising of
    their own.  So it is refused, and the message says what to write instead.
    """

    value = _path_value(source, mapping, key, name)
    if not _looks_absolute(value):
        raise _fail(
            source,
            key,
            "expected an absolute path, got {}. There is nothing this could be "
            "relative to: LocalCanvas never guesses or searches for a ComfyUI "
            "location, so write the full path.".format(_shown(value)),
        )
    return Path(value)


def _looks_absolute(value: str) -> bool:
    """Absolute on either platform's rules, not merely on this one's.

    ``PurePath`` applies the running platform's: on Windows ``/srv/comfy`` has
    no drive and reads as relative, on POSIX ``C:/ComfyUI`` reads as relative.
    A path written for the machine it names is still absolute, and rejecting it
    for being written elsewhere would be this loader having an opinion about
    which operating system the user is on.
    """

    return PureWindowsPath(value).is_absolute() or PurePosixPath(value).is_absolute()


def _under(root: Path, value: str) -> Path:
    """``value`` resolved against ``root`` unless it is already absolute."""

    candidate = Path(value)
    return candidate if candidate.is_absolute() else root / candidate


def _resolve(repo_root: Path, value: str) -> Path:
    """Absolute paths stand; a relative one is joined to the repository root.

    ``Path`` joining preserves spaces and does not care about them; this is the
    only place a configured path is combined with anything.
    """

    candidate = Path(value)
    if candidate.is_absolute():
        return candidate
    return repo_root / candidate


def _launcher(source: Path, raw: Any) -> ComfyLauncher:
    if not isinstance(raw, Mapping):
        raise _fail(
            source, "comfy.launcher", "expected a mapping of settings, got {}.".format(_kind(raw))
        )
    _reject_unknown(source, raw, _LAUNCHER_KEYS, "comfy.launcher")
    return ComfyLauncher(
        executable=_path_value(source, raw, "comfy.launcher.executable", "executable"),
        script=_path_value(source, raw, "comfy.launcher.script", "script"),
    )


def _comfy(source: Path, mapping: Mapping[str, Any], *, manage_comfy: bool) -> ComfyConfig:
    host = _host(source, mapping, "comfy.host", "host")
    port = _port(source, mapping, "comfy.port", "port")
    extra_args = _extra_args(source, mapping)

    root: Optional[Path] = None
    launcher: Optional[ComfyLauncher] = None
    has_launcher = mapping.get("launcher") is not None
    has_root = mapping.get("root") is not None

    if manage_comfy:
        # Managed mode is the only mode that needs to know where ComfyUI is, and
        # it is told: there is no default and no search (`docs/runtime.md`).
        root = _absolute_path(source, mapping, "comfy.root", "root")
        if not has_launcher:
            raise _fail(
                source,
                "comfy.launcher",
                "required when runtime.manage_comfy is true; expected a mapping with {}.".format(
                    _listed(_LAUNCHER_KEYS)
                ),
            )
        launcher = _launcher(source, mapping["launcher"])
    else:
        # External mode never launches ComfyUI, so neither key is required --
        # but a value that is present is still validated and kept.  Switching
        # manage_comfy back on must not mean retyping the launcher.
        if has_root:
            root = _absolute_path(source, mapping, "comfy.root", "root")
        if has_launcher:
            launcher = _launcher(source, mapping["launcher"])

    return ComfyConfig(host=host, port=port, root=root, launcher=launcher, extra_args=extra_args)


def _extra_args(source: Path, mapping: Mapping[str, Any]) -> Tuple[str, ...]:
    """Pass-through ComfyUI arguments.  Not parsed, not interpreted, not split."""

    if mapping.get("extra_args") is None:
        return ()
    value = mapping["extra_args"]
    if isinstance(value, str) or not isinstance(value, Iterable):
        raise _fail(
            source,
            "comfy.extra_args",
            "expected a list of command-line arguments, one per item, got {}.".format(_kind(value)),
        )
    items = list(value)
    for index, item in enumerate(items):
        if not isinstance(item, str):
            raise _fail(
                source,
                "comfy.extra_args[{}]".format(index),
                "expected a string argument, got {}.".format(_shown(item)),
            )
    return tuple(items)


def _startup(source: Path, data: Mapping[str, Any]) -> StartupConfig:
    if data.get("startup") is None:
        return StartupConfig()
    raw = data["startup"]
    if not isinstance(raw, Mapping):
        raise _fail(source, "startup", "expected a mapping of settings, got {}.".format(_kind(raw)))
    _reject_unknown(source, raw, _STARTUP_KEYS, "startup")
    defaults = StartupConfig()
    return StartupConfig(
        comfy_timeout_seconds=_seconds(
            source,
            raw,
            "startup.comfy_timeout_seconds",
            "comfy_timeout_seconds",
            defaults.comfy_timeout_seconds,
        ),
        gateway_timeout_seconds=_seconds(
            source,
            raw,
            "startup.gateway_timeout_seconds",
            "gateway_timeout_seconds",
            defaults.gateway_timeout_seconds,
        ),
    )


def _media(source: Path, data: Mapping[str, Any]) -> MediaConfig:
    """The ``media:`` section.  Absent means the defaults, not "no limits"."""

    defaults = MediaConfig()
    if data.get("media") is None:
        return defaults
    raw = data["media"]
    if not isinstance(raw, Mapping):
        raise _fail(source, "media", "expected a mapping of settings, got {}.".format(_kind(raw)))
    _reject_unknown(source, raw, _MEDIA_KEYS, "media")
    return MediaConfig(
        max_image_megabytes=_megabytes(
            source, raw, "media.max_image_megabytes", "max_image_megabytes",
            defaults.max_image_megabytes,
        ),
        max_video_megabytes=_megabytes(
            source, raw, "media.max_video_megabytes", "max_video_megabytes",
            defaults.max_video_megabytes,
        ),
        max_store_megabytes=_megabytes(
            source, raw, "media.max_store_megabytes", "max_store_megabytes",
            defaults.max_store_megabytes,
        ),
        ttl_seconds=_seconds(
            source, raw, "media.ttl_seconds", "ttl_seconds", defaults.ttl_seconds
        ),
    )


def _prompt_translation(source: Path, data: Mapping[str, Any]) -> PromptTranslationConfig:
    """The ``prompt_translation:`` section.  Absent means off, not "defaults on"."""

    defaults = PromptTranslationConfig()
    if data.get("prompt_translation") is None:
        return defaults
    raw = data["prompt_translation"]
    if not isinstance(raw, Mapping):
        raise _fail(
            source,
            "prompt_translation",
            "expected a mapping of settings, got {}.".format(_kind(raw)),
        )
    _reject_unknown(source, raw, _PROMPT_TRANSLATION_KEYS, "prompt_translation")

    enabled = _optional_bool(
        source, raw, "prompt_translation.enabled", "enabled", defaults.enabled
    )
    preserve = _optional_bool(
        source,
        raw,
        "prompt_translation.preserve_quoted_literals",
        "preserve_quoted_literals",
        defaults.preserve_quoted_literals,
    )
    target = defaults.target
    if raw.get("target") is not None:
        target = _language_code(source, raw["target"], "prompt_translation.target")

    sources = defaults.sources
    if raw.get("sources") is not None:
        sources = _translation_sources(source, raw["sources"])

    if target in sources:
        raise _fail(
            source,
            "prompt_translation.sources",
            "{!r} is also the target language, so translating it means nothing. "
            "Remove it.".format(target),
        )
    return PromptTranslationConfig(
        enabled=enabled,
        target=target,
        sources=sources,
        preserve_quoted_literals=preserve,
    )


def _optional_bool(
    source: Path, mapping: Mapping[str, Any], key: str, name: str, fallback: bool
) -> bool:
    if name not in mapping or mapping[name] is None:
        return fallback
    value = mapping[name]
    if not isinstance(value, bool):
        raise _fail(source, key, "expected true or false, got {}.".format(_shown(value)))
    return value


def _language_code(source: Path, value: Any, key: str) -> str:
    """A short language code as a person writes it: ``en``, ``ru``, ``ja``."""

    if not isinstance(value, str) or not _LANGUAGE_CODE.match(value):
        raise _fail(
            source,
            key,
            "expected a two- or three-letter language code such as 'en', got {}.".format(
                _shown(value)
            ),
        )
    return value


def _translation_sources(source: Path, value: Any) -> Tuple[str, ...]:
    """The languages the gateway may translate *from*.

    Restricted to the ones detection can actually recognise: accepting a code
    the detector knows nothing about would mean either never translating it --
    a setting that silently does nothing -- or guessing, which is worse.
    """

    if isinstance(value, str) or not isinstance(value, Iterable):
        raise _fail(
            source,
            "prompt_translation.sources",
            "expected a list of language codes, one per item, got {}.".format(_kind(value)),
        )
    codes: List[str] = []
    for index, item in enumerate(value):
        code = _language_code(source, item, "prompt_translation.sources[{}]".format(index))
        if code not in SUPPORTED_TRANSLATION_SOURCES:
            raise _fail(
                source,
                "prompt_translation.sources[{}]".format(index),
                "{!r} cannot be detected by this gateway. Supported: {}.".format(
                    code, _listed(SUPPORTED_TRANSLATION_SOURCES)
                ),
            )
        if code in codes:
            raise _fail(
                source,
                "prompt_translation.sources[{}]".format(index),
                "{!r} is listed twice.".format(code),
            )
        codes.append(code)
    if not codes:
        raise _fail(
            source,
            "prompt_translation.sources",
            "expected at least one language code; to switch translation off, set "
            "prompt_translation.enabled to false.",
        )
    return tuple(codes)


def _megabytes(
    source: Path, mapping: Mapping[str, Any], key: str, name: str, fallback: int
) -> int:
    """A whole number of megabytes, greater than zero.

    Not a float: half a megabyte is not a limit anybody means, and accepting one
    would put a fractional byte count into the store.  ``0`` is refused rather
    than read as "no limit" -- an unbounded write to someone's disk is not
    something a typo should be able to turn on.
    """

    if name not in mapping or mapping[name] is None:
        return fallback
    value = mapping[name]
    expectation = "expected a whole number of megabytes greater than 0, got {}.".format(
        _shown(value)
    )
    if isinstance(value, bool) or not isinstance(value, int):
        raise _fail(source, key, expectation)
    if value <= 0:
        raise _fail(source, key, expectation)
    return value


# --------------------------------------------------------------------------
# Formatting
# --------------------------------------------------------------------------


def _host_for_url(host: str) -> str:
    """Bracket an IPv6 literal; leave everything else alone."""

    if ":" in host and not host.startswith("["):
        return "[{}]".format(host)
    return host


def _listed(names: Sequence[str]) -> str:
    return ", ".join(repr(name) for name in names)


def _kind(value: Any) -> str:
    if isinstance(value, Mapping):
        return "a mapping"
    if isinstance(value, str):
        return "a string"
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, (list, tuple)):
        return "a list"
    if isinstance(value, (int, float)):
        return "a number"
    if value is None:
        return "nothing"
    return type(value).__name__


def _shown(value: Any) -> str:
    return "{} ({})".format(repr(value), _kind(value))


def _flatten(text: str) -> str:
    return " ".join(text.split())


__all__ = [
    "CONFIG_DOCUMENT_VERSION",
    "ComfyConfig",
    "ComfyLauncher",
    "ConfigError",
    "GatewayConfig",
    "IdentityConfig",
    "MediaConfig",
    "PromptTranslationConfig",
    "RuntimeConfig",
    "StartupConfig",
    "config_document",
    "load_config",
]
