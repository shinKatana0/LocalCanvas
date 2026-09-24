"""``python -m localcanvas_gateway`` -- the seam ``scripts/start.ps1`` launches.

The CLI's shape is a contract with another component, so the flags are asserted
rather than assumed, and so is the rule that a failure prints something a person
can act on instead of a traceback.
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

import pytest
import yaml

from localcanvas_gateway.__main__ import main
from localcanvas_gateway.translation import backend_missing
from localcanvas_gateway.translation.fake import FakeTranslator
from workflow_fixtures import EVERY_FIELD


class Recorder:
    """Stands in for uvicorn: records the call instead of blocking on a socket."""

    def __init__(self) -> None:
        self.calls = []

    def __call__(self, app, *, host: str, port: int) -> None:
        self.calls.append({"app": app, "host": host, "port": port})


def write_config(tmp_path: Path, registry_root: Path, **overrides) -> Path:
    data = {
        "runtime": {"manage_comfy": False},
        "comfy": {"host": "127.0.0.1", "port": 8188},
        "workflows": {"registry": str(registry_root)},
        "gateway": {"host": "127.0.0.1", "port": 7801},
        "identity": {"display_name": "Test Generation PC"},
    }
    for section, values in overrides.items():
        data.setdefault(section, {}).update(values)
    directory = tmp_path / "config" / "local"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "runtime.yaml"
    path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    return path


@pytest.fixture
def configured(tmp_path: Path, builder):
    builder.add("flow", EVERY_FIELD)
    return write_config(tmp_path, builder.root)


class Advertiser:
    """Stands in for zeroconf: records the registration instead of multicasting."""

    def __init__(self, fails: bool = False) -> None:
        self.calls = []
        self.fails = fails
        self.closed = 0

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        if self.fails:
            raise OSError("no multicast route on this network")
        advertiser = self

        class _Handle:
            def close(self) -> None:
                advertiser.closed += 1

        return _Handle()


class Utf8Buffer(io.StringIO):
    """A buffer that says what it can carry, the way a real stream does.

    ``io.StringIO`` inherits ``encoding = None`` from ``TextIOBase``, so it
    declares nothing -- which the QR renderer reads as "cannot draw blocks".
    """

    encoding = "utf-8"


def run(argv, serve=None, advertiser=None, out=None, translator=None):
    """Run the CLI against stand-ins for everything outside this process.

    ``translator`` is passed on exactly as ``serve`` and ``advertiser`` are:
    left out, the CLI builds the real backend, which is the production path.
    Given one, it states the PC under test -- and every test below that says
    something about the translation banner gives one, because otherwise the
    sentence it asserts is a sentence about whoever's machine is running it.
    """

    out, err = out if out is not None else io.StringIO(), io.StringIO()
    code = main(
        argv,
        out=out,
        err=err,
        serve=serve or Recorder(),
        advertiser=advertiser or Advertiser(),
        translator=translator,
    )
    return code, out.getvalue(), err.getvalue()


class PcWithoutTheExtra(FakeTranslator):
    """A PC where the optional translation extra is not installed.

    Built rather than assumed.  ``FakeTranslator`` reads a
    ``TranslationUnavailable`` as "there is no backend on this PC at all"
    (`translation/fake.py`), which is precisely the machine the warning below
    is addressed to -- and it is that machine whether or not the extra happens
    to be installed in the environment running the suite.

    It also counts the question, because "the banner says the right thing" and
    "the banner says the right thing *about the PC this test built*" are two
    different claims: a ``main()`` that ignored ``translator=`` and constructed
    the real backend would never ask this object anything.
    """

    def __init__(self) -> None:
        super().__init__(fails_with=backend_missing())
        self.asked = 0

    def installed(self) -> bool:
        self.asked += 1
        return super().installed()


# -- the startup contract --------------------------------------------------


def test_it_prints_the_interpreter_path_and_version_first(configured: Path) -> None:
    """`docs/runtime.md`: a version mismatch must be visible in the terminal."""

    code, out, _ = run(["--config", str(configured), "--no-mdns", "--no-qr"])

    first = out.splitlines()[0]
    assert code == 0
    assert sys.executable in first
    assert "Python {}.{}.{}".format(*sys.version_info[:3]) in first


def test_it_serves_on_the_configured_address(configured: Path) -> None:
    recorder = Recorder()
    run(["--config", str(configured), "--no-mdns", "--no-qr"], serve=recorder)

    assert recorder.calls[0]["host"] == "127.0.0.1"
    assert recorder.calls[0]["port"] == 7801


def test_host_and_port_flags_override_the_configuration(configured: Path) -> None:
    recorder = Recorder()
    run(
        ["--config", str(configured), "--host", "0.0.0.0", "--port", "7999",
         "--no-mdns", "--no-qr"],
        serve=recorder,
    )

    assert recorder.calls[0]["host"] == "0.0.0.0"
    assert recorder.calls[0]["port"] == 7999


def test_it_reports_what_the_registry_loaded(configured: Path) -> None:
    _, out, _ = run(["--config", str(configured), "--no-mdns", "--no-qr"])

    assert "Workflows: 1 loaded" in out


def test_it_says_what_this_pc_can_translate(configured: Path) -> None:
    """The stage is off unless configured, and the banner says which it is.

    One line, ASCII, beside the interpreter and the workflow count: the person
    at this PC finds out whether their prompts will be translated here, rather
    than from a failed generation.
    """

    _, out, _ = run(["--config", str(configured), "--no-mdns", "--no-qr"])

    assert "[ OK ] Translation: off" in out


def test_a_pc_configured_to_translate_with_nothing_installed_is_warned(
    tmp_path: Path, builder
) -> None:
    """The misconfiguration, named at startup instead of at the first prompt.

    This is what an unrelated user sees after switching the section on and
    stopping there -- and the PC it describes is built here, by handing the CLI
    a translator that answers as a machine with no backend.  It used to be the
    machine the test ran on, which made the test unrunnable on any PC that had
    followed the install instructions in ``pyproject.toml`` (T-0125).

    The sentence is asserted verbatim: it names the one of two setup steps that
    is missing, and the two are fixed by two different commands.
    """

    builder.add("flow", EVERY_FIELD)
    config = write_config(
        tmp_path, builder.root, prompt_translation={"enabled": True}
    )
    pc = PcWithoutTheExtra()

    _, out, _ = run(["--config", str(config), "--no-mdns", "--no-qr"], translator=pc)

    assert "[WARN] Translation: switched on, but not installed on this PC" in out
    # ...asked of the PC this test built, and of no other.
    assert pc.asked > 0
    assert pc.pair_walks == [], "a PC with no backend has nothing to walk"


def test_the_translator_the_cli_is_given_is_the_one_the_gateway_uses(
    tmp_path: Path, builder
) -> None:
    """The other side of the seam, and the reason the banner can be trusted.

    The PC here has the extra and one language model, which is a third machine
    again -- and the pairs in the banner are the pairs *this* translator was
    asked for.  A ``main()`` that ignored ``translator=`` would print whatever
    the machine running the suite has installed, which on a developer PC can
    look exactly like a pass.
    """

    builder.add("flow", EVERY_FIELD)
    config = write_config(
        tmp_path, builder.root, prompt_translation={"enabled": True, "sources": ["ru"]}
    )
    pc = FakeTranslator().teach("ru", "en", "ночной", "night")

    _, out, _ = run(["--config", str(config), "--no-mdns", "--no-qr"], translator=pc)

    assert "[ OK ] Translation: ru->en" in out
    # Walked once, at startup, and warmed -- against this object, not a backend
    # the CLI went and built for itself.
    assert pc.pair_walks == [(("ru",), "en")]
    assert pc.warm_ups == [("ru", "en")]


def test_a_rejected_workflow_is_named_but_does_not_stop_startup(
    tmp_path: Path, builder
) -> None:
    builder.add("good", EVERY_FIELD)
    builder.add("broken", "- id: prompt\n  label: Prompt\n  type: nonsense\n")
    config = write_config(tmp_path, builder.root)

    recorder = Recorder()
    code, out, _ = run(["--config", str(config), "--no-mdns", "--no-qr"], serve=recorder)

    assert code == 0
    assert "1 rejected" in out
    assert "broken" in out
    assert recorder.calls  # it still served


# -- failures are readable -------------------------------------------------


def test_a_missing_configuration_file_fails_without_a_traceback(
    tmp_path: Path,
) -> None:
    recorder = Recorder()
    code, out, err = run(
        ["--config", str(tmp_path / "nowhere" / "runtime.yaml")], serve=recorder
    )

    assert code == 2
    assert err.startswith("[FAIL] Configuration could not be loaded")
    assert "Traceback" not in err and "Traceback" not in out
    assert recorder.calls == []  # nothing was served


def test_an_unusable_registry_root_fails_before_serving(tmp_path: Path) -> None:
    config = write_config(tmp_path, tmp_path / "no such folder")

    recorder = Recorder()
    code, _, err = run(["--config", str(config)], serve=recorder)

    assert code == 2
    assert "[FAIL] The workflow registry could not be read" in err
    assert "workflows.registry" in err
    assert recorder.calls == []


def test_the_config_flag_is_required() -> None:
    with pytest.raises(SystemExit):
        run([])


# -- pairing and discovery are opt-out, not compulsory ---------------------


def test_the_qr_is_printed_at_startup(configured: Path) -> None:
    _, out, _ = run(["--config", str(configured), "--no-mdns"])

    assert "QR pairing:" in out
    assert "localcanvas://connect?endpoint=" in out


def test_no_qr_suppresses_it(configured: Path) -> None:
    _, out, _ = run(["--config", str(configured), "--no-mdns", "--no-qr"])

    assert "QR pairing" not in out


def test_no_mdns_suppresses_the_advertisement(configured: Path) -> None:
    _, out, _ = run(["--config", str(configured), "--no-mdns", "--no-qr"])

    assert "mDNS" not in out


def test_mdns_advertises_the_configured_name_and_port(configured: Path) -> None:
    advertiser = Advertiser()
    run(["--config", str(configured), "--no-qr"], advertiser=advertiser)

    call = advertiser.calls[0]
    assert call["display_name"] == "Test Generation PC"
    assert call["port"] == 7801
    assert call["api_version"] == 1


def test_an_explicit_endpoint_is_the_address_advertised(configured: Path) -> None:
    """`start.ps1` decides the address; the gateway advertises what it is given."""

    advertiser = Advertiser()
    run(
        ["--config", str(configured), "--endpoint", "http://198.51.100.3:7801"],
        advertiser=advertiser,
    )

    assert advertiser.calls[0]["address"] == "198.51.100.3"


def test_an_advertisement_is_withdrawn_when_the_server_stops(configured: Path) -> None:
    advertiser = Advertiser()
    run(["--config", str(configured), "--no-qr"], advertiser=advertiser)

    assert advertiser.closed == 1


def test_a_network_that_blocks_multicast_does_not_stop_the_gateway(
    configured: Path,
) -> None:
    """`docs/connection.md`: discovery failing is a normal outcome, not a fault."""

    recorder = Recorder()
    code, out, _ = run(
        ["--config", str(configured), "--no-qr"],
        serve=recorder,
        advertiser=Advertiser(fails=True),
    )

    assert code == 0
    assert recorder.calls  # it served anyway
    assert "mDNS unavailable" in out


# -- who owns the terminal -------------------------------------------------


def test_an_endpoint_from_the_script_silences_our_copy_of_the_block(
    configured: Path,
) -> None:
    """`docs/runtime.md`: start.ps1 owns the readiness block and prints it once.

    Being given an endpoint is how this process knows it is not the one talking
    to the user, so it publishes and serves without printing a second copy.
    """

    advertiser = Advertiser()
    recorder = Recorder()
    _, out, _ = run(
        ["--config", str(configured), "--endpoint", "http://198.51.100.3:7801"],
        serve=recorder,
        advertiser=advertiser,
    )

    assert "QR pairing" not in out
    assert "Endpoint:" not in out
    assert "Discovery:" not in out
    # ...while still doing the mechanics the script cannot do for itself.
    assert advertiser.calls[0]["address"] == "198.51.100.3"
    assert recorder.calls


def test_without_an_endpoint_the_gateway_prints_the_block_itself(
    configured: Path,
) -> None:
    """A developer starting it by hand is the only thing on the screen."""

    _, out, _ = run(["--config", str(configured)])

    assert "QR pairing:" in out
    assert "localcanvas://connect?endpoint=" in out
    assert "Discovery:" in out
    assert "Endpoint:" in out


# -- the qr subcommand -----------------------------------------------------


def test_the_qr_subcommand_prints_a_payload_and_a_code() -> None:
    code, out, _ = run(["qr", "--endpoint", "http://198.51.100.3:7801"])

    assert code == 0
    assert out.startswith("localcanvas://connect?endpoint=http://198.51.100.3:7801")
    assert _is_a_drawn_code(out)


def test_the_qr_subcommand_needs_something_to_encode() -> None:
    code, _, err = run(["qr"])

    assert code == 2
    assert "[FAIL] No endpoint to encode" in err


def test_the_rendering_follows_the_stream_it_is_written_to() -> None:
    """T-0037: the buffer these tests hand the CLI declares no encoding.

    A stream that cannot say what it can carry is treated as unable to carry
    the half blocks, so what comes back is the ASCII drawing -- which is also
    what a redirected `qr` gets on a cp1251 machine.  The block rendering is
    exercised against a stream that does declare UTF-8 in
    ``tests/test_qr_encoding.py``.
    """

    _, ascii_out, _ = run(["qr", "--endpoint", "http://198.51.100.3:7801"])
    _, utf8_out, _ = run(["qr", "--endpoint", "http://198.51.100.3:7801"], out=Utf8Buffer())

    assert max(ord(char) for char in ascii_out) <= 126
    assert "█" in utf8_out


def _is_a_drawn_code(out: str) -> bool:
    """A QR was drawn, in whichever of the two renderings this stream got."""

    body = out.split("\n", 1)[1]
    return bool(body.strip()) and ("█" in body or "\x1b[7m" in body)


# -- the terminal stays readable -------------------------------------------


def test_the_http_clients_chatter_is_not_the_startup_output() -> None:
    """One httpx INFO line per poll would bury the output docs/runtime.md wants."""

    import logging

    from localcanvas_gateway.__main__ import _configure_logging

    before = [logging.getLogger(name).level for name in ("httpx", "httpcore")]
    try:
        _configure_logging()
        assert logging.getLogger("httpx").level == logging.WARNING
        assert logging.getLogger("httpcore").level == logging.WARNING
    finally:
        for name, level in zip(("httpx", "httpcore"), before):
            logging.getLogger(name).setLevel(level)
