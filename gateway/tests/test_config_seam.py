"""``python -m localcanvas_gateway config`` -- the seam the scripts consume.

`docs/runtime.md`, "The configuration seam": there is one definition of what
``runtime.yaml`` means and it lives here; `scripts/*.ps1` never parse YAML and
never re-validate it.  They run this command and read one JSON document.

That makes the document's *shape* a contract with another component, and the
component has **no fallback reader** -- so these tests pin the two properties it
depends on and cannot check for itself:

* stdout is one JSON document and nothing else, so ``ConvertFrom-Json`` is safe;
* every documented key is always present, ``null`` rather than missing, so a
  consumer that applies no defaults of its own always has an answer.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from localcanvas_gateway.__main__ import main
from localcanvas_gateway.config import CONFIG_DOCUMENT_VERSION

#: Every key the document promises, at every level.  Written out rather than
#: derived from the code, so that renaming a key in the loader breaks a test
#: instead of quietly breaking a script in someone else's tree.
EXPECTED_SHAPE = {
    "config_version": None,
    "source": None,
    "repo_root": None,
    "runtime": {"manage_comfy"},
    "comfy": {"host", "port", "base_url", "root", "launcher", "extra_args"},
    "workflows": {"registry"},
    "gateway": {"host", "port"},
    "startup": {"comfy_timeout_seconds", "gateway_timeout_seconds"},
    "identity": {"display_name"},
    "media": {
        "max_image_megabytes",
        "max_video_megabytes",
        "max_store_megabytes",
        "ttl_seconds",
    },
    "prompt_translation": {
        "enabled",
        "target",
        "sources",
        "preserve_quoted_literals",
    },
}

LAUNCHER_KEYS = {"executable", "script", "executable_path", "script_path"}


def write_config(tmp_path: Path, data: dict) -> Path:
    directory = tmp_path / "config" / "local"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "runtime.yaml"
    path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    return path


def managed(root: str = "C:/Program Files/My ComfyUI") -> dict:
    return {
        "runtime": {"manage_comfy": True},
        "comfy": {
            "root": root,
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
        "startup": {"comfy_timeout_seconds": 90, "gateway_timeout_seconds": 20},
        "identity": {"display_name": "My Generation PC"},
    }


def external() -> dict:
    return {
        "runtime": {"manage_comfy": False},
        "comfy": {"host": "127.0.0.1", "port": 8188},
        "workflows": {"registry": "workflows/examples"},
        "gateway": {"host": "0.0.0.0", "port": 7801},
        "identity": {"display_name": "My Generation PC"},
    }


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    code = main(argv, out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def document(path: Path) -> dict:
    code, out, err = run(["config", "--config", str(path)])
    assert code == 0, err
    return json.loads(out)


# -- the document is parseable, and is the only thing on stdout ------------


def test_stdout_is_one_json_document_and_nothing_else(tmp_path: Path) -> None:
    """A banner line on stdout would make this unparseable for its only consumer."""

    code, out, err = run(["config", "--config", str(write_config(tmp_path, managed()))])

    assert code == 0
    assert err == ""
    parsed = json.loads(out)  # raises if anything else was printed
    assert parsed["config_version"] == CONFIG_DOCUMENT_VERSION


def test_every_documented_key_is_present(tmp_path: Path) -> None:
    doc = document(write_config(tmp_path, managed()))

    assert set(doc) == set(EXPECTED_SHAPE)
    for key, expected in EXPECTED_SHAPE.items():
        if expected is not None:
            assert set(doc[key]) == expected, key


def test_optional_values_are_null_rather_than_missing(tmp_path: Path) -> None:
    """External mode has no ComfyUI root and no launcher -- and still has the keys.

    A consumer that applies no defaults of its own must be able to read a key
    and get an answer, not discover a section is absent.
    """

    doc = document(write_config(tmp_path, external()))

    assert set(doc) == set(EXPECTED_SHAPE)
    assert doc["comfy"]["root"] is None
    assert doc["comfy"]["launcher"] is None
    assert doc["comfy"]["extra_args"] == []
    assert doc["runtime"]["manage_comfy"] is False


def test_defaults_arrive_already_applied(tmp_path: Path) -> None:
    """The scripts apply no defaults, so an omitted section arrives filled in."""

    doc = document(write_config(tmp_path, external()))

    assert doc["startup"]["comfy_timeout_seconds"] > 0
    assert doc["startup"]["gateway_timeout_seconds"] > 0


# -- everything arrives decided -------------------------------------------


def test_the_registry_path_is_absolute(tmp_path: Path) -> None:
    doc = document(write_config(tmp_path, managed()))

    assert Path(doc["workflows"]["registry"]).is_absolute()
    assert doc["workflows"]["registry"] == str(tmp_path / "workflows" / "examples")


def test_the_paths_the_document_reports_are_absolute(tmp_path: Path) -> None:
    """A consumer may run from a different directory than the producer did.

    Run with a relative ``--config``, exactly as someone standing in the repo
    root would, and the document still says where the file actually is.
    """

    path = write_config(tmp_path, managed())
    relative = os.path.relpath(path, tmp_path)

    cwd = os.getcwd()
    os.chdir(tmp_path)
    try:
        code, out, err = run(["config", "--config", relative])
    finally:
        os.chdir(cwd)

    assert code == 0, err
    doc = json.loads(out)
    assert Path(doc["source"]).is_absolute()
    assert Path(doc["source"]).name == "runtime.yaml"
    assert Path(doc["repo_root"]).is_absolute()
    assert Path(doc["workflows"]["registry"]).is_absolute()
    assert Path(doc["comfy"]["root"]).is_absolute()
    assert Path(doc["comfy"]["launcher"]["executable_path"]).is_absolute()
    assert Path(doc["comfy"]["launcher"]["script_path"]).is_absolute()


def test_a_relative_comfy_root_is_refused_rather_than_resolved(tmp_path: Path) -> None:
    """There is nothing it could be relative to, and guessing is forbidden.

    ``workflows.registry`` has a documented base (the repository root);
    ``comfy.root`` has none.  Passing it on relative would make the answer
    depend on the reader's working directory -- in a document whose consumer
    normalises nothing and has no fallback.
    """

    data = managed(root="vendor/ComfyUI")
    path = write_config(tmp_path, data)

    code, out, err = run(["config", "--config", str(path)])

    assert code != 0
    assert out == ""
    assert str(path) in err
    assert "comfy.root" in err
    assert "absolute" in err
    assert "vendor/ComfyUI" in err  # the value it objected to


@pytest.mark.parametrize(
    "root",
    [
        "C:/ComfyUI",  # a Windows path, absolute even when read on POSIX
        "C:\\ComfyUI",
        "/srv/comfy",  # a POSIX path, absolute even when read on Windows
        "\\\\nas\\comfy",
    ],
)
def test_an_absolute_root_written_for_either_platform_is_accepted(
    tmp_path: Path, root: str
) -> None:
    """Rejecting a path for being written for the machine it names would be
    this loader having an opinion about the user's operating system."""

    doc = document(write_config(tmp_path, managed(root=root)))

    assert doc["comfy"]["root"] is not None


def test_the_comfy_base_url_is_composed_here_not_there(tmp_path: Path) -> None:
    """One definition of the endpoint the scripts probe, on this side."""

    doc = document(write_config(tmp_path, managed()))

    assert doc["comfy"]["base_url"] == "http://127.0.0.1:8188"


def test_the_launcher_is_resolved_against_the_comfy_root(tmp_path: Path) -> None:
    doc = document(write_config(tmp_path, managed()))
    launcher = doc["comfy"]["launcher"]

    assert set(launcher) == LAUNCHER_KEYS
    assert launcher["executable"] == "python_embeded/python.exe"
    assert launcher["executable_path"] == str(
        Path("C:/Program Files/My ComfyUI") / "python_embeded/python.exe"
    )
    assert launcher["script_path"] == str(
        Path("C:/Program Files/My ComfyUI") / "ComfyUI/main.py"
    )


def test_an_absolute_launcher_path_is_left_alone(tmp_path: Path) -> None:
    data = managed()
    data["comfy"]["launcher"]["executable"] = "C:/Python310/python.exe"
    doc = document(write_config(tmp_path, data))

    assert doc["comfy"]["launcher"]["executable_path"] == str(Path("C:/Python310/python.exe"))


def test_a_path_with_spaces_survives_the_document(tmp_path: Path) -> None:
    """The whole point of the seam: the scripts quote what they are given."""

    doc = document(write_config(tmp_path, managed(root="D:/Program Files/My ComfyUI")))

    assert " " in doc["comfy"]["root"]
    assert " " in doc["comfy"]["launcher"]["executable_path"]


def test_extra_args_arrive_as_a_list_not_a_command_line(tmp_path: Path) -> None:
    """A joined string would have to be re-split, and splitting breaks paths."""

    data = managed()
    data["comfy"]["extra_args"] = ["--highvram", "--extra-model-paths-config", "my paths.yaml"]
    doc = document(write_config(tmp_path, data))

    assert doc["comfy"]["extra_args"] == [
        "--highvram",
        "--extra-model-paths-config",
        "my paths.yaml",
    ]


# -- failure --------------------------------------------------------------


def test_a_bad_configuration_fails_loudly_and_writes_no_document(
    tmp_path: Path,
) -> None:
    data = managed()
    del data["comfy"]["port"]
    path = write_config(tmp_path, data)

    code, out, err = run(["config", "--config", str(path)])

    assert code != 0
    assert out == ""  # nothing half-written for a parser to choke on
    assert "comfy.port" in err
    assert "Traceback" not in err


def test_a_missing_configuration_file_fails_the_same_way(tmp_path: Path) -> None:
    code, out, err = run(["config", "--config", str(tmp_path / "nope.yaml")])

    assert code != 0
    assert out == ""
    assert "[FAIL] Configuration could not be loaded" in err


def test_the_config_flag_is_required() -> None:
    with pytest.raises(SystemExit):
        run(["config"])


# -- the seam as the scripts actually invoke it ---------------------------


def test_it_works_as_a_subprocess_without_pythonpath(tmp_path: Path) -> None:
    """How `scripts/*.ps1` really call it: a separate process, parsed from stdout."""

    path = write_config(tmp_path, managed())
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)

    result = subprocess.run(
        [sys.executable, "-m", "localcanvas_gateway", "config", "--config", str(path)],
        cwd=str(tmp_path),
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    doc = json.loads(result.stdout)
    assert doc["identity"]["display_name"] == "My Generation PC"
    # Against the *installed* copy's own constant, not this session's.  Without
    # PYTHONPATH the answer comes from whatever is installed in the interpreter
    # -- which has no necessary relationship to this branch -- so comparing it
    # with the imported constant compares two installations and fails every
    # branch that changes the document's shape before someone reinstalls
    # (the T-0037 hazard `test_packaging.py` was written about).  What this
    # test is actually for is that the seam answers as a subprocess, and that
    # the document it prints agrees with the code that printed it.
    installed = subprocess.run(
        [
            sys.executable,
            "-c",
            "import localcanvas_gateway.config as c; print(c.CONFIG_DOCUMENT_VERSION)",
        ],
        cwd=str(tmp_path),
        env=env,
        capture_output=True,
        text=True,
    )
    assert installed.returncode == 0, installed.stderr
    assert doc["config_version"] == int(installed.stdout.strip())
