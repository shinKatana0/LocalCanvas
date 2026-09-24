"""Configuration loading (`docs/runtime.md`).

Two properties are load-bearing and are asserted rather than assumed:

* an error names **the file, the key and what was expected** -- a configuration
  message that does not is a message the user cannot act on;
* **no ComfyUI location is ever invented.**  Absent means absent: there is no
  default, no fallback, and nothing in this package looks for one.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Any, Dict

import pytest
import yaml

from localcanvas_gateway.config import ConfigError, MediaConfig, load_config
from localcanvas_gateway.media import (
    DEFAULT_MAX_IMAGE_MEGABYTES,
    DEFAULT_MAX_STORE_MEGABYTES,
    DEFAULT_MAX_VIDEO_MEGABYTES,
    DEFAULT_TTL_SECONDS,
)

from conftest import REPO_ROOT

#: The shipped example, which is also the contract's own documentation.
EXAMPLE_CONFIG = REPO_ROOT / "config" / "examples" / "runtime.example.yaml"


def base() -> Dict[str, Any]:
    """A complete, valid configuration, to be broken one key at a time."""

    return {
        "runtime": {"manage_comfy": True},
        "comfy": {
            "root": "C:/Program Files/Some ComfyUI",
            "host": "127.0.0.1",
            "port": 8188,
            "launcher": {
                "executable": "python_embeded/python.exe",
                "script": "ComfyUI/main.py",
            },
            "extra_args": ["--highvram"],
        },
        "workflows": {"registry": "workflows/examples"},
        "gateway": {"host": "0.0.0.0", "port": 7801},
        "startup": {"comfy_timeout_seconds": 120, "gateway_timeout_seconds": 30},
        "identity": {"display_name": "My Generation PC"},
        "media": {
            "max_image_megabytes": 8,
            "max_video_megabytes": 32,
            "max_store_megabytes": 64,
            "ttl_seconds": 900,
        },
    }


def write(tmp_path: Path, data: Any, *, name: str = "runtime.yaml") -> Path:
    """Write a config where a real one lives, so the repo root is derivable."""

    directory = tmp_path / "config" / "local"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    if isinstance(data, str):
        path.write_text(data, encoding="utf-8")
    else:
        path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    return path


def load_broken(tmp_path: Path, mutate) -> str:
    """Apply ``mutate`` to a valid config, load it, and return the message."""

    data = base()
    mutate(data)
    path = write(tmp_path, data)
    with pytest.raises(ConfigError) as raised:
        load_config(path)
    return str(raised.value)


# -- the happy path --------------------------------------------------------


def test_loads_every_documented_field(tmp_path: Path) -> None:
    path = write(tmp_path, base())
    config = load_config(path)

    assert config.manage_comfy is True
    assert config.comfy.host == "127.0.0.1"
    assert config.comfy.port == 8188
    assert config.comfy.root == Path("C:/Program Files/Some ComfyUI")
    assert config.comfy.launcher.executable == "python_embeded/python.exe"
    assert config.comfy.launcher.script == "ComfyUI/main.py"
    assert config.comfy.extra_args == ("--highvram",)
    assert config.gateway.host == "0.0.0.0"
    assert config.gateway.port == 7801
    assert config.identity.display_name == "My Generation PC"
    assert config.startup.comfy_timeout_seconds == 120
    assert config.startup.gateway_timeout_seconds == 30
    assert config.media.max_image_megabytes == 8
    assert config.media.max_video_megabytes == 32
    assert config.media.max_store_megabytes == 64
    assert config.media.ttl_seconds == 900


def test_the_shipped_example_is_loadable() -> None:
    """The public template must parse, or it teaches a broken shape."""

    config = load_config(EXAMPLE_CONFIG)

    assert config.repo_root == REPO_ROOT
    assert config.workflows_registry == REPO_ROOT / "workflows" / "examples"
    assert config.gateway.port == 7801


def test_loading_configuration_does_not_pull_in_the_workflow_registry() -> None:
    """Configuration reads a YAML file; it has no business loading a registry.

    ``config.py`` imports ``media.py`` for the store's default limits, and
    ``media.py`` names ``InputField`` in its annotations -- so an unguarded
    import there quietly makes every configuration read drag the workflow
    registry in behind it. Asked in a subprocess because this session imported
    everything long ago and ``sys.modules`` here would answer about the suite,
    not about the layering.
    """

    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import sys, localcanvas_gateway.config; "
            "print('localcanvas_gateway.workflows' in sys.modules)",
        ],
        cwd=str(Path(__file__).resolve().parents[1]),
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "False", (
        "importing localcanvas_gateway.config pulled in the workflow registry"
    )


def test_the_example_shows_the_media_values_it_calls_defaults() -> None:
    """It says "the values shown are the defaults", so they have to be.

    An example whose numbers have drifted from the code is worse than no
    example: it is documentation that is confidently wrong, and the only reader
    who finds out is the one who copied it expecting no change.
    """

    config = load_config(EXAMPLE_CONFIG)

    assert config.media == MediaConfig()


def test_comfy_base_url_is_derived_from_host_and_port(tmp_path: Path) -> None:
    data = base()
    data["comfy"]["host"] = "127.0.0.1"
    data["comfy"]["port"] = 9999
    config = load_config(write(tmp_path, data))

    assert config.comfy.base_url == "http://127.0.0.1:9999"


def test_startup_section_is_optional(tmp_path: Path) -> None:
    data = base()
    del data["startup"]
    config = load_config(write(tmp_path, data))

    assert config.startup.comfy_timeout_seconds > 0
    assert config.startup.gateway_timeout_seconds > 0


# -- media ------------------------------------------------------------------
#
# The store's limits are configuration, not constants: an unrelated user must
# never edit source to run LocalCanvas, and a video ceiling is
# exactly the kind of thing somebody hits.


def test_media_section_is_optional_and_absent_means_the_defaults(
    tmp_path: Path,
) -> None:
    """Absent is the shipped policy -- never "no limit"."""

    data = base()
    del data["media"]
    config = load_config(write(tmp_path, data))

    assert config.media == MediaConfig()
    assert config.media.max_image_megabytes == DEFAULT_MAX_IMAGE_MEGABYTES
    assert config.media.max_video_megabytes == DEFAULT_MAX_VIDEO_MEGABYTES
    assert config.media.max_store_megabytes == DEFAULT_MAX_STORE_MEGABYTES
    assert config.media.ttl_seconds == DEFAULT_TTL_SECONDS


def test_one_media_key_may_be_set_without_restating_the_others(
    tmp_path: Path,
) -> None:
    """Raising the video ceiling must not mean retyping the whole section."""

    data = base()
    data["media"] = {"max_video_megabytes": 4096}
    config = load_config(write(tmp_path, data))

    assert config.media.max_video_megabytes == 4096
    assert config.media.max_image_megabytes == DEFAULT_MAX_IMAGE_MEGABYTES


def test_the_media_limits_reach_the_store_in_bytes(tmp_path: Path) -> None:
    """The one multiplication, in the one place that does it."""

    config = load_config(write(tmp_path, base()))

    assert config.media.max_upload_bytes == {
        "image": 8 * 1024 * 1024,
        "video": 32 * 1024 * 1024,
    }
    assert config.media.max_store_bytes == 64 * 1024 * 1024


@pytest.mark.parametrize(
    "key", ["max_image_megabytes", "max_video_megabytes", "max_store_megabytes"]
)
@pytest.mark.parametrize("value", [0, -1, 1.5, "64", True, "sixty-four"])
def test_a_media_size_that_is_not_a_positive_whole_number_is_refused(
    tmp_path: Path, key: str, value: Any
) -> None:
    """Zero is not "no limit": an unbounded write is not something a typo turns on."""

    message = load_broken(tmp_path, lambda data: data["media"].__setitem__(key, value))

    assert "media.{}".format(key) in message
    assert "greater than 0" in message


def test_a_media_ttl_of_zero_is_refused(tmp_path: Path) -> None:
    message = load_broken(
        tmp_path, lambda data: data["media"].__setitem__("ttl_seconds", 0)
    )

    assert "media.ttl_seconds" in message
    assert "greater than 0" in message


def test_a_misspelled_media_key_is_refused_with_the_accepted_ones(
    tmp_path: Path,
) -> None:
    message = load_broken(
        tmp_path, lambda data: data["media"].__setitem__("max_video_mb", 4096)
    )

    assert "'max_video_mb'" in message
    assert "max_video_megabytes" in message


# -- paths -----------------------------------------------------------------


def test_a_registry_path_with_spaces_survives_intact(tmp_path: Path) -> None:
    data = base()
    data["workflows"]["registry"] = "my workflows/example set"
    config = load_config(write(tmp_path, data))

    assert config.workflows_registry == tmp_path / "my workflows" / "example set"
    assert " " in str(config.workflows_registry)


def test_a_comfy_root_with_spaces_survives_intact(tmp_path: Path) -> None:
    data = base()
    data["comfy"]["root"] = "D:/Program Files/My ComfyUI Build"
    config = load_config(write(tmp_path, data))

    assert config.comfy.root == Path("D:/Program Files/My ComfyUI Build")


def test_a_relative_registry_resolves_against_the_repository_root(tmp_path: Path) -> None:
    config = load_config(write(tmp_path, base()))

    assert config.repo_root == tmp_path
    assert config.workflows_registry == tmp_path / "workflows" / "examples"


def test_an_absolute_registry_is_left_alone(tmp_path: Path) -> None:
    elsewhere = tmp_path / "somewhere else" / "flows"
    data = base()
    data["workflows"]["registry"] = str(elsewhere)
    config = load_config(write(tmp_path, data))

    assert config.workflows_registry == elsewhere


# -- no guessing -----------------------------------------------------------


def test_managed_mode_demands_a_comfy_root_and_invents_none(tmp_path: Path) -> None:
    message = load_broken(tmp_path, lambda data: data["comfy"].pop("root"))

    assert "comfy.root" in message
    assert "required" in message


def test_external_mode_leaves_comfy_root_unset_rather_than_guessing(
    tmp_path: Path,
) -> None:
    """Absent is absent.  Nothing fills it in, and nothing searches for one."""

    data = base()
    data["runtime"]["manage_comfy"] = False
    data["comfy"].pop("root")
    data["comfy"].pop("launcher")
    config = load_config(write(tmp_path, data))

    assert config.comfy.root is None
    assert config.comfy.launcher is None


def test_a_relative_comfy_root_is_refused_rather_than_resolved(tmp_path: Path) -> None:
    """Resolving it would be guessing at a ComfyUI location, which is forbidden.

    ``workflows.registry`` has a documented base to be relative to; this has
    none, so the only honest answers are "absolute" or "no".
    """

    message = load_broken(
        tmp_path, lambda data: data["comfy"].__setitem__("root", "vendor/ComfyUI")
    )

    assert "comfy.root" in message
    assert "absolute" in message
    assert "vendor/ComfyUI" in message
    assert "never guesses" in message


def test_a_relative_root_is_refused_in_external_mode_too(tmp_path: Path) -> None:
    def mutate(data):
        data["runtime"]["manage_comfy"] = False
        data["comfy"]["root"] = "vendor/ComfyUI"

    assert "comfy.root" in load_broken(tmp_path, mutate)


def test_managed_mode_demands_a_launcher(tmp_path: Path) -> None:
    message = load_broken(tmp_path, lambda data: data["comfy"].pop("launcher"))

    assert "comfy.launcher" in message
    assert "manage_comfy" in message


# -- errors name file, key and expectation ---------------------------------


def test_a_missing_file_names_the_file_and_the_way_out(tmp_path: Path) -> None:
    missing = tmp_path / "config" / "local" / "runtime.yaml"
    with pytest.raises(ConfigError) as raised:
        load_config(missing)

    message = str(raised.value)
    assert str(missing) in message
    assert "runtime.example.yaml" in message


def test_a_missing_section_names_the_file_the_key_and_the_keys_expected(
    tmp_path: Path,
) -> None:
    data = base()
    del data["identity"]
    path = write(tmp_path, data)
    with pytest.raises(ConfigError) as raised:
        load_config(path)

    message = str(raised.value)
    assert str(path) in message
    assert "identity" in message
    assert "display_name" in message


def test_a_missing_key_names_the_file_and_the_dotted_key(tmp_path: Path) -> None:
    data = base()
    del data["gateway"]["port"]
    path = write(tmp_path, data)
    with pytest.raises(ConfigError) as raised:
        load_config(path)

    message = str(raised.value)
    assert str(path) in message
    assert "gateway.port" in message
    assert "required" in message


def test_a_wrong_type_names_the_key_the_expectation_and_the_value(
    tmp_path: Path,
) -> None:
    message = load_broken(tmp_path, lambda data: data["comfy"].__setitem__("port", "eight"))

    assert "comfy.port" in message
    assert "1 to 65535" in message
    assert "eight" in message


@pytest.mark.parametrize("port", [0, 65536, -1])
def test_a_port_outside_the_legal_range_is_refused(tmp_path: Path, port: int) -> None:
    message = load_broken(tmp_path, lambda data: data["gateway"].__setitem__("port", port))

    assert "gateway.port" in message


def test_true_is_not_a_port(tmp_path: Path) -> None:
    """Python's bool is an int; a configuration file's ``true`` is not a number."""

    message = load_broken(tmp_path, lambda data: data["comfy"].__setitem__("port", True))

    assert "comfy.port" in message


def test_manage_comfy_must_be_a_boolean(tmp_path: Path) -> None:
    message = load_broken(
        tmp_path, lambda data: data["runtime"].__setitem__("manage_comfy", "yes")
    )

    assert "runtime.manage_comfy" in message
    assert "true or false" in message


def test_extra_args_must_be_a_list_not_a_command_line(tmp_path: Path) -> None:
    """A single string would have to be split, and splitting breaks paths."""

    message = load_broken(
        tmp_path, lambda data: data["comfy"].__setitem__("extra_args", "--highvram --lowvram")
    )

    assert "comfy.extra_args" in message
    assert "list" in message


def test_an_extra_arg_that_is_not_a_string_names_its_position(tmp_path: Path) -> None:
    message = load_broken(
        tmp_path, lambda data: data["comfy"].__setitem__("extra_args", ["--ok", 7])
    )

    assert "comfy.extra_args[1]" in message


def test_a_timeout_of_zero_is_refused(tmp_path: Path) -> None:
    message = load_broken(
        tmp_path, lambda data: data["startup"].__setitem__("comfy_timeout_seconds", 0)
    )

    assert "startup.comfy_timeout_seconds" in message
    assert "greater than 0" in message


# -- typos are errors, not comments ----------------------------------------


def test_an_unknown_top_level_key_is_refused_with_the_accepted_ones(
    tmp_path: Path,
) -> None:
    data = base()
    data["gatewy"] = {"port": 7801}
    path = write(tmp_path, data)
    with pytest.raises(ConfigError) as raised:
        load_config(path)

    message = str(raised.value)
    assert "gatewy" in message
    assert "'gateway'" in message


def test_an_unknown_key_inside_a_section_is_refused(tmp_path: Path) -> None:
    message = load_broken(
        tmp_path, lambda data: data["runtime"].__setitem__("manage_comfu", True)
    )

    assert "runtime" in message
    assert "manage_comfu" in message
    assert "manage_comfy" in message


def test_an_unknown_launcher_key_is_refused(tmp_path: Path) -> None:
    message = load_broken(
        tmp_path, lambda data: data["comfy"]["launcher"].__setitem__("args", [])
    )

    assert "comfy.launcher" in message
    assert "args" in message


# -- unreadable files ------------------------------------------------------


def test_broken_yaml_says_so_without_a_traceback(tmp_path: Path) -> None:
    path = write(tmp_path, "runtime:\n  manage_comfy: true\n comfy:\n")
    with pytest.raises(ConfigError) as raised:
        load_config(path)

    message = str(raised.value)
    assert str(path) in message
    assert "not valid YAML" in message
    assert "Traceback" not in message


def test_an_empty_file_is_a_configuration_error(tmp_path: Path) -> None:
    path = write(tmp_path, "")
    with pytest.raises(ConfigError) as raised:
        load_config(path)

    assert "empty" in str(raised.value)


def test_a_non_mapping_document_is_a_configuration_error(tmp_path: Path) -> None:
    path = write(tmp_path, "- one\n- two\n")
    with pytest.raises(ConfigError) as raised:
        load_config(path)

    assert "top level" in str(raised.value)


def test_an_explicit_repo_root_overrides_the_derived_one(tmp_path: Path) -> None:
    elsewhere = tmp_path / "other root"
    config = load_config(write(tmp_path, base()), repo_root=elsewhere)

    assert config.workflows_registry == elsewhere / "workflows" / "examples"


def test_loading_does_not_mutate_the_file(tmp_path: Path) -> None:
    """Loading is a read.  A loader that rewrites configuration is a surprise."""

    path = write(tmp_path, base())
    before = path.read_bytes()
    load_config(path)

    assert path.read_bytes() == before
