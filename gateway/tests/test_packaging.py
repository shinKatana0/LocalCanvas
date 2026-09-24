"""Packaging is measured on an artifact built from *this* checkout.

Until T-0038 every subprocess here ran ``sys.executable``, i.e. the interpreter
pytest itself runs on, with ``PYTHONPATH`` removed and from a directory outside
the repository.  That did prove the package was *installed* rather than merely
importable -- but the only installation left to answer was the one in the
project's ``.venv``, which has no necessary relationship to the branch.  Both
directions were observed on T-0037: a correct branch failing because ``.venv``
still held pre-fix code, and -- the dangerous mirror -- a broken branch passing
because a healthy older artifact answered instead.

So the subject under test is built here: :func:`isolated_install` builds a wheel
from ``<repo>/gateway``, creates a venv of its own and installs the wheel into
it.  Every packaging assertion below runs *that* venv's interpreter.  Because
``python -m venv`` bases the child on the *base* interpreter, the project
``.venv``'s ``site-packages`` is not on the child's path at all, so the false
green is closed structurally and not merely asserted -- and the assertions are
there as well, in both flavours the design requires:

* **location** -- the imported module's resolved path is inside the isolated
  venv, and inside neither the pytest interpreter's environment nor the source
  tree (``import succeeded`` is not provenance);
* **content** -- a fingerprint over the package's ``.py`` files matches the one
  computed over ``<repo>/gateway/localcanvas_gateway``, which is what makes a
  source change observable.

Nothing here writes to the project ``.venv``, and a build or install failure is
a loud failure naming its cause -- never a skip and never a fallback to
``sys.executable``.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import pytest

from conftest import EXAMPLES_ROOT

#: ``<repo>`` -- located from this file, never from ``cwd`` and never from an
#: environment variable, both of which say where pytest was launched rather
#: than which tree this test file belongs to.
REPO_ROOT = Path(__file__).resolve().parents[2]
GATEWAY_ROOT = REPO_ROOT / "gateway"
PACKAGE_SOURCE = GATEWAY_ROOT / "localcanvas_gateway"

#: How long any one build/install step may take before it is called a failure.
STEP_TIMEOUT_SECONDS = 900


class PackagingEnvironmentError(Exception):
    """A build or install step failed; the message names what and why."""


def child_env(**overrides: str) -> Dict[str, str]:
    """The environment for a child process, with every import shortcut removed.

    ``PYTHONPATH`` is the one that matters most: the suite is routinely run with
    the checkout's ``gateway/`` on it so that the *source* tree is what the
    in-process tests import.  Inheriting that here would put the source tree on
    the isolated interpreter's path and quietly re-create the very confusion
    this module exists to remove -- the artifact would import, and it would not
    be the artifact answering.
    """

    env = dict(os.environ)
    for name in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "VIRTUAL_ENV"):
        env.pop(name, None)
    env.update(overrides)
    return env


def _must_run(argv: Sequence[str], *, what: str) -> subprocess.CompletedProcess:
    """Run one build/install step, or raise with everything needed to debug it."""

    printable = " ".join(str(part) for part in argv)
    try:
        result = subprocess.run(
            [str(part) for part in argv],
            env=child_env(),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=STEP_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:  # pragma: no cover - a wedged step
        raise PackagingEnvironmentError(
            "{} did not finish within {}s.\n  command: {}".format(
                what, STEP_TIMEOUT_SECONDS, printable
            )
        ) from exc
    except OSError as exc:  # pragma: no cover - depends on the machine
        raise PackagingEnvironmentError(
            "{} could not be started: {}\n  command: {}".format(what, exc, printable)
        ) from exc

    if result.returncode != 0:
        raise PackagingEnvironmentError(
            "{} failed with exit code {}.\n"
            "  command: {}\n"
            "  stdout:\n{}\n"
            "  stderr:\n{}".format(
                what, result.returncode, printable, result.stdout, result.stderr
            )
        )
    return result


def fingerprint(package_dir: Path) -> Tuple[str, List[str]]:
    """One hash over every ``.py`` file of a package, plus the names it covered.

    Relative path and file bytes, in sorted order, each length-prefixed so that
    moving bytes across a file boundary cannot leave the digest unchanged.  The
    file list comes back with it because an empty package would otherwise
    fingerprint exactly like another empty one, and two such hashes comparing
    equal would say nothing at all.
    """

    package_dir = package_dir.resolve()
    if not package_dir.is_dir():
        raise PackagingEnvironmentError(
            "no package directory to fingerprint at {}".format(package_dir)
        )

    names = sorted(
        path.relative_to(package_dir).as_posix()
        for path in package_dir.rglob("*.py")
        if path.is_file()
    )
    if not names:
        raise PackagingEnvironmentError(
            "{} holds no .py files; a fingerprint of nothing proves nothing".format(
                package_dir
            )
        )

    digest = hashlib.sha256()
    for name in names:
        data = (package_dir / name).read_bytes()
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(len(data)).encode("ascii"))
        digest.update(b"\0")
        digest.update(data)
    return digest.hexdigest(), names


def is_inside(child: Path, parent: Path) -> bool:
    """Containment by path components, never by ``startswith`` (T-0032).

    ``C:\\path\\to\\localcanvas-old`` starts with ``C:\\path\\to\\localcanvas`` and is a
    different directory; ``parents`` cannot make that mistake.
    """

    child = Path(child).resolve()
    parent = Path(parent).resolve()
    return child == parent or parent in child.parents


class IsolatedInstall:
    """A venv this suite created, holding a wheel built from this checkout."""

    def __init__(self, root: Path, venv_dir: Path, python: Path, wheel: Path) -> None:
        self.root = root
        self.venv_dir = venv_dir
        self.python = python
        self.wheel = wheel

    def run(
        self,
        args: Sequence[str],
        cwd: Path,
        *,
        env: Dict[str, str] = None,
        encoding: str = "utf-8",
    ) -> subprocess.CompletedProcess:
        """Run the isolated interpreter -- the only interpreter used below."""

        return subprocess.run(
            [str(self.python), *[str(part) for part in args]],
            cwd=str(cwd),
            env=child_env() if env is None else env,
            capture_output=True,
            text=True,
            encoding=encoding,
            errors="replace",
        )

    def evaluate(self, source: str) -> str:
        """Run a snippet in the isolated interpreter and return its stdout."""

        result = self.run(["-c", source], self.venv_dir)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()


def _build_isolated_install(root: Path) -> IsolatedInstall:
    if not (GATEWAY_ROOT / "pyproject.toml").is_file():
        raise PackagingEnvironmentError(
            "expected the repository layout <repo>/gateway/pyproject.toml, but "
            "{} does not exist; this file located <repo> as {} from its own "
            "__file__".format(GATEWAY_ROOT / "pyproject.toml", REPO_ROOT)
        )
    if not (PACKAGE_SOURCE / "__init__.py").is_file():
        raise PackagingEnvironmentError(
            "expected the package source at {}, which does not exist".format(
                PACKAGE_SOURCE
            )
        )

    wheelhouse = root / "wheelhouse"
    _must_run(
        [
            sys.executable,
            "-m",
            "pip",
            "wheel",
            "--no-deps",
            "--disable-pip-version-check",
            "--wheel-dir",
            wheelhouse,
            GATEWAY_ROOT,
        ],
        what="building a wheel from {}".format(GATEWAY_ROOT),
    )

    wheels = sorted(wheelhouse.glob("*.whl"))
    if len(wheels) != 1:
        raise PackagingEnvironmentError(
            "expected exactly one wheel in {}, found {}".format(
                wheelhouse, [wheel.name for wheel in wheels]
            )
        )
    wheel = wheels[0]
    if not wheel.name.startswith("localcanvas_gateway-"):
        raise PackagingEnvironmentError(
            "the wheel built from {} is named {!r}, which is not this "
            "package".format(GATEWAY_ROOT, wheel.name)
        )

    venv_dir = root / "venv"
    _must_run(
        [sys.executable, "-m", "venv", venv_dir],
        what="creating an isolated venv at {}".format(venv_dir),
    )

    python = venv_dir / ("Scripts" if os.name == "nt" else "bin") / (
        "python.exe" if os.name == "nt" else "python"
    )
    if not python.is_file():
        raise PackagingEnvironmentError(
            "the venv created at {} has no interpreter at {}".format(venv_dir, python)
        )

    _must_run(
        [python, "-m", "pip", "install", "--disable-pip-version-check", wheel],
        what="installing {} into {}".format(wheel.name, venv_dir),
    )
    return IsolatedInstall(root=root, venv_dir=venv_dir, python=python, wheel=wheel)


@pytest.fixture(scope="session")
def isolated_install(tmp_path_factory) -> IsolatedInstall:
    """Build this checkout, install it into a venv of our own, hand it over.

    Session-scoped: the whole cost (a wheel build, a venv, one install) is paid
    once for the run.  A failure at any step is reported as a failure of every
    test that asked for the environment, naming the step and its output -- there
    is deliberately no skip and no fallback to ``sys.executable``, because a
    packaging suite that quietly measures another interpreter is exactly the
    defect this module was written to remove.
    """

    root = tmp_path_factory.mktemp("isolated_packaging")
    try:
        install = _build_isolated_install(root)
    except PackagingEnvironmentError as exc:
        pytest.fail(str(exc), pytrace=False)

    try:
        yield install
    finally:
        # Ours, and nowhere near the repository: pytest handed it to us under
        # its own basetemp.  Checked before removing anything -- a delete
        # that has retargeted is not recoverable.
        if root.is_dir() and not is_inside(root, REPO_ROOT):
            shutil.rmtree(root, ignore_errors=True)


# ==========================================================================
# Provenance: which artifact is answering, and where did it come from?
# ==========================================================================


def test_the_isolated_interpreter_imports_the_package_it_was_given(
    isolated_install: IsolatedInstall,
) -> None:
    """Location provenance: inside our venv, and inside nothing else.

    Three claims, and the second and third are the ones with teeth.  The
    pytest interpreter's own environment (``sys.prefix``) is the project
    ``.venv`` in the documented setup, i.e. the stale copy that used to answer
    for the branch.  The source tree is where a leaked ``PYTHONPATH`` would
    resolve -- and this suite is normally run with exactly that variable set.
    """

    printed = isolated_install.evaluate(
        "import localcanvas_gateway, pathlib;"
        "print(pathlib.Path(localcanvas_gateway.__file__).resolve())"
    )
    module = Path(printed)

    assert is_inside(module, isolated_install.venv_dir), (
        "the package answered from {}, which is outside the isolated venv "
        "{}".format(module, isolated_install.venv_dir)
    )
    pytest_environment = Path(sys.prefix)
    assert not is_inside(module, pytest_environment), (
        "the package answered from {}, which is inside the interpreter running "
        "pytest ({}) -- that is the installation this module must not "
        "measure".format(module, pytest_environment)
    )
    assert not is_inside(module, GATEWAY_ROOT), (
        "the package answered from the source tree at {}; the isolated "
        "interpreter has picked up a path entry it should not have".format(module)
    )


def test_the_project_venv_is_not_on_the_isolated_interpreters_path(
    isolated_install: IsolatedInstall,
) -> None:
    """The false green is closed structurally, not by the assertion above.

    ``python -m venv`` bases the child on the *base* interpreter, so nothing of
    the environment pytest runs in is reachable from it.  That is what makes it
    impossible for an older healthy ``.venv`` installation to answer for a
    broken branch -- an assertion someone could later delete would not.
    """

    printed = isolated_install.evaluate(
        "import sys;"
        "print(sys.base_prefix);"
        "print('\\n'.join(p for p in sys.path if p))"
    )
    lines = printed.splitlines()
    base_prefix, path_entries = Path(lines[0]), [Path(line) for line in lines[1:]]

    pytest_environment = Path(sys.prefix)
    assert not is_inside(base_prefix, pytest_environment), (
        "the isolated venv is based on {}, which is inside the interpreter "
        "running pytest".format(base_prefix)
    )
    leaked = [entry for entry in path_entries if is_inside(entry, pytest_environment)]
    assert leaked == [], (
        "the isolated interpreter can see {} inside the pytest interpreter's "
        "environment {}".format(leaked, pytest_environment)
    )
    leaked_source = [entry for entry in path_entries if is_inside(entry, GATEWAY_ROOT)]
    assert leaked_source == [], (
        "the isolated interpreter can see the source tree at {}".format(leaked_source)
    )


def test_the_installed_package_is_byte_for_byte_this_checkout(
    isolated_install: IsolatedInstall,
) -> None:
    """Content provenance: the artifact carries this tree's bytes and no other.

    This is the assertion that makes a source change observable.  It says
    nothing about whether the source is *correct* -- the behaviours below say
    that -- but it is what lets those behaviours be read as statements about
    the branch instead of about whatever was installed last.
    """

    printed = isolated_install.evaluate(
        "import localcanvas_gateway, pathlib;"
        "print(pathlib.Path(localcanvas_gateway.__file__).resolve().parent)"
    )
    installed_dir = Path(printed)

    source_digest, source_names = fingerprint(PACKAGE_SOURCE)
    installed_digest, installed_names = fingerprint(installed_dir)

    # A fingerprint over an empty tree would match another empty tree, so the
    # coverage is asserted before the equality is trusted (T-0182).
    assert len(source_names) >= 10, source_names
    assert installed_names == source_names, {
        "only in the checkout": sorted(set(source_names) - set(installed_names)),
        "only in the installed copy": sorted(set(installed_names) - set(source_names)),
    }
    assert installed_digest == source_digest, (
        "the installed package at {} does not carry the bytes of {}: the "
        "artifact under test was built from some other tree".format(
            installed_dir, PACKAGE_SOURCE
        )
    )


def test_the_fingerprint_notices_a_one_byte_source_change(tmp_path: Path) -> None:
    """The detector above is proved against the mistake it guards (T-0130).

    A copy of the package is edited in the test's own temporary directory --
    never the working tree -- and the fingerprint has to
    move.  Without this, ``installed == source`` could be a comparison of two
    constants and nobody would know.
    """

    copy_root = tmp_path / "localcanvas_gateway"
    shutil.copytree(PACKAGE_SOURCE, copy_root)

    untouched_digest, untouched_names = fingerprint(copy_root)
    original_digest, original_names = fingerprint(PACKAGE_SOURCE)
    assert untouched_names == original_names
    assert untouched_digest == original_digest, (
        "a verbatim copy already fingerprints differently, so an inequality "
        "below would prove nothing"
    )

    edited = copy_root / "__init__.py"
    edited.write_bytes(edited.read_bytes() + b"\n# one byte of drift\n")

    changed_digest, _ = fingerprint(copy_root)
    assert changed_digest != untouched_digest

    # And a file appearing or disappearing is caught by the name list, which is
    # why the test above compares both.
    (copy_root / "extra_module.py").write_text("x = 1\n", encoding="utf-8")
    _, grown_names = fingerprint(copy_root)
    assert "extra_module.py" in grown_names
    assert grown_names != original_names


def test_a_child_process_never_inherits_the_suites_import_shortcuts(
    monkeypatch,
) -> None:
    """The trick this module is defended against is the one it is run with.

    The gateway suite is routinely launched with ``PYTHONPATH`` pointing at the
    checkout's ``gateway/`` -- that is how a worktree with no ``.venv`` puts its
    own source under test.  Inheriting it into the isolated interpreter would
    put the source tree on that interpreter's path, and every assertion below
    would then be about the source tree again, importing successfully and
    proving nothing.
    """

    monkeypatch.setenv("PYTHONPATH", str(GATEWAY_ROOT))
    monkeypatch.setenv("VIRTUAL_ENV", str(Path(sys.prefix)))
    monkeypatch.setenv("PYTHONHOME", str(Path(sys.prefix)))

    env = child_env()

    assert "PYTHONPATH" not in env
    assert "VIRTUAL_ENV" not in env
    assert "PYTHONHOME" not in env
    # Everything else is still inherited: the child needs PATH and friends.
    assert "PATH" in env or "Path" in env


def test_a_failed_build_step_is_a_loud_failure_naming_the_cause() -> None:
    """No skip, no fallback: a step that fails says what failed and why.

    A packaging suite that answers a broken build with a skip reports green on
    a machine where nothing was ever built, which is the same false green in a
    different costume.
    """

    with pytest.raises(PackagingEnvironmentError) as failure:
        _must_run(
            [
                sys.executable,
                "-c",
                "import sys; print('no wheel for you', file=sys.stderr); sys.exit(7)",
            ],
            what="a build step that fails",
        )

    message = str(failure.value)
    assert "a build step that fails" in message
    assert "exit code 7" in message
    assert "no wheel for you" in message


# ==========================================================================
# The environment-readiness check -- a claim about the machine, not the branch
# ==========================================================================


def test_the_pytest_interpreter_has_the_gateway_installed_for_the_curator() -> None:
    """``docs/runtime.md``'s curator command works in the environment we run in.

    A curator runs

        .venv\\Scripts\\python.exe -m localcanvas_gateway.workflows <root>

    to check their definitions, and that only works once the gateway has been
    installed into ``.venv``.  This test is about *that* preparation and about
    nothing else: if it fails, the machine was not set up the way
    ``docs/runtime.md`` describes.

    It says nothing whatever about the branch, and must never again be read as
    if it did.  It used to end with ``installed == __version__``, where both
    values came from the same installed copy -- a comparison of the
    installation with itself, in a project whose version is ``0.1.0`` and does
    not move.  Everything above is where provenance is established.
    """

    from importlib.metadata import PackageNotFoundError, version

    try:
        version("localcanvas-gateway")
    except PackageNotFoundError:  # pragma: no cover - depends on the environment
        pytest.fail(
            "localcanvas-gateway is not installed into the interpreter running "
            "pytest ({}); the documented curator command would not work here. "
            "Run: python -m pip install ./gateway".format(sys.executable),
            pytrace=False,
        )


# ==========================================================================
# The packaged behaviours, every one of them on the isolated interpreter
# ==========================================================================


def test_the_offline_validator_runs_without_pythonpath(
    isolated_install: IsolatedInstall, tmp_path: Path
) -> None:
    result = isolated_install.run(
        ["-m", "localcanvas_gateway.workflows", str(EXAMPLES_ROOT)], tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert "example_txt2img" in result.stdout


def test_a_registry_path_with_spaces_works_on_the_command_line(
    isolated_install: IsolatedInstall, tmp_path: Path
) -> None:
    """Quoting is the caller's job; nothing in the package splits a path."""

    spaced = tmp_path / "my workflow folder"
    spaced.mkdir()
    result = isolated_install.run(
        ["-m", "localcanvas_gateway.workflows", str(spaced)], tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert str(spaced) in result.stdout


def test_the_gateway_module_is_runnable_without_pythonpath(
    isolated_install: IsolatedInstall, tmp_path: Path
) -> None:
    result = isolated_install.run(["-m", "localcanvas_gateway", "--help"], tmp_path)

    assert result.returncode == 0, result.stderr
    assert "--config" in result.stdout


def test_the_gateway_module_reports_a_missing_config_and_stops(
    isolated_install: IsolatedInstall, tmp_path: Path
) -> None:
    result = isolated_install.run(
        ["-m", "localcanvas_gateway", "--config", str(tmp_path / "runtime.yaml")],
        tmp_path,
    )

    assert result.returncode == 2
    assert "[FAIL]" in result.stderr
    assert "Traceback" not in result.stderr


@pytest.mark.parametrize("io_encoding", ["utf-8", "cp1251", None])
def test_the_qr_subcommand_runs_as_an_installed_module(
    isolated_install: IsolatedInstall, tmp_path: Path, io_encoding
) -> None:
    """``capture_output`` is a pipe, which is the redirected case (T-0037).

    The child's stdout encoding is set here rather than inherited: this test
    used to pass or fail according to whether the shell that launched pytest
    happened to export ``PYTHONIOENCODING``, and a suite whose colour depends
    on its launcher is not reporting on the code.  ``None`` is the case with
    the variable absent from the child's environment altogether.
    """

    env = child_env()
    env.pop("PYTHONUTF8", None)
    env.pop("PYTHONIOENCODING", None)
    if io_encoding is not None:
        env["PYTHONIOENCODING"] = io_encoding

    result = isolated_install.run(
        ["-m", "localcanvas_gateway", "qr", "--endpoint", "http://198.51.100.3:7801"],
        tmp_path,
        env=env,
        encoding=io_encoding or "utf-8",
    )

    assert result.returncode == 0, result.stderr
    assert "localcanvas://connect?endpoint=http://198.51.100.3:7801" in result.stdout


# ==========================================================================
# The translation extra stays out of a plain install (T-0040)
# ==========================================================================


def test_a_plain_install_does_not_pull_the_translation_extra(
    isolated_install: IsolatedInstall,
) -> None:
    """``pip install <wheel>`` must not cost anyone a gigabyte.

    The isolated venv is built exactly as an unrelated user's would be -- the
    wheel and its base dependencies, no extras -- so this environment *is* the
    measurement.  Two things that break separately are asserted separately: the
    extra is not there, and the gateway imports perfectly well without it.
    """

    printed = isolated_install.evaluate(
        "import importlib.util as u;"
        "from localcanvas_gateway.translation.service import TranslationService;"
        "print(u.find_spec('argostranslate') is None, u.find_spec('torch') is None,"
        " bool(TranslationService))"
    )

    assert printed == "True True True"


def test_the_wheel_declares_translation_as_an_extra_and_not_a_requirement(
    isolated_install: IsolatedInstall,
) -> None:
    """Metadata, not intent: what pip would install for a plain install.

    A base ``Requires-Dist`` with no marker is what every user pays for; the
    extra's own line carries ``extra == "translation"`` and is opt-in.
    """

    printed = isolated_install.evaluate(
        "from importlib.metadata import metadata;"
        "m = metadata('localcanvas-gateway');"
        "print('|'.join(m.get_all('Requires-Dist') or []));"
        "print('|'.join(m.get_all('Provides-Extra') or []))"
    )
    requirements, extras = printed.splitlines()

    assert "translation" in extras.split("|")
    unconditional = [line for line in requirements.split("|") if "extra ==" not in line]
    assert not any("argostranslate" in line for line in unconditional), unconditional
    assert any(
        "argostranslate" in line and 'extra == "translation"' in line
        for line in requirements.split("|")
    ), requirements

