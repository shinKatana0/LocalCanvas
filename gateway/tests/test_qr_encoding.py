"""The pairing QR adapts to the stream it is written to (`docs/connection.md` §3).

The compact rendering is drawn from three block characters that exist in no
single-byte Windows code page.  On an interactive console they arrive fine; the
moment stdout is a pipe or a file, Python encodes with the machine's ANSI code
page and the command dies with ``UnicodeEncodeError``.

So the rendering is chosen from what the stream can carry, *before* the first
character is written.  What is asserted here:

* the capability check itself, as a function, including its two -- and only its
  two -- caught failures;
* that a capable stream still gets **byte-identical** output to what this
  repository produced before the check existed;
* that an incapable stream gets pure ASCII, encoding the very same payload;
* that ``--wide`` is never overridden by detection;
* that no stream is reconfigured anywhere in the package, now or later.
"""

from __future__ import annotations

import hashlib
import io
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
import segno

from localcanvas_gateway import pairing
from localcanvas_gateway.pairing import (
    COMPACT_BLOCKS,
    encoding_can_represent,
    pairing_payload,
    pairing_qr,
    pairing_qr_for_stream,
    render_qr,
    stream_can_draw_blocks,
)

ENDPOINT = "http://192.0.2.42:7801"

#: The compact rendering of ``ENDPOINT`` exactly as this repository drew it
#: before the capability check existed: segno 1.6.6's own ``terminal()`` with
#: ``compact=True``, ``border=1``, the text UTF-8 encoded -- computed from segno
#: directly, not from this package.  A capable stream must keep getting
#: exactly these bytes: the polished output is the whole reason the compact
#: mode was not simply dropped, so a silent change to it is a regression, not
#: an improvement.
COMPACT_SHA256 = "4de9682d61faab5be327ccf6e3a65f972c0d28b97a3c37b5162aa81a06f54323"

PACKAGE_ROOT = Path(pairing.__file__).resolve().parent


class Stream:
    """A stand-in for a text stream: only its encoding matters to the check."""

    def __init__(self, encoding, errors: str = "strict") -> None:
        self.encoding = encoding
        self.errors = errors


class StreamWithoutEncoding:
    """Not every file-like object a caller passes has an ``encoding`` at all."""


# -- the capability check, on its own ---------------------------------------


@pytest.mark.parametrize("encoding", ["utf-8", "UTF-8", "utf-16", "utf_32"])
def test_an_encoding_that_carries_the_blocks_answers_yes(encoding: str) -> None:
    assert encoding_can_represent(COMPACT_BLOCKS, encoding) is True


@pytest.mark.parametrize("encoding", ["ascii", "cp1251", "cp1252", "latin-1"])
def test_an_encoding_that_cannot_carry_the_blocks_answers_no(encoding: str) -> None:
    assert encoding_can_represent(COMPACT_BLOCKS, encoding) is False


def test_an_unknown_encoding_name_answers_no_instead_of_raising() -> None:
    """LookupError is an answer, not a crash: an unknown codec is not capable."""

    assert encoding_can_represent(COMPACT_BLOCKS, "not-a-real-codec") is False


@pytest.mark.parametrize("encoding", [None, "", 0, object()])
def test_an_unusable_encoding_answers_no(encoding) -> None:
    assert encoding_can_represent(COMPACT_BLOCKS, encoding) is False


def test_the_check_does_not_swallow_unrelated_failures() -> None:
    """Only UnicodeEncodeError and LookupError are answers; nothing else is."""

    class Exploding(str):
        def encode(self, *args, **kwargs):  # noqa: D401 - deliberate blow-up
            raise ValueError("something else entirely")

    with pytest.raises(ValueError):
        encoding_can_represent(Exploding(COMPACT_BLOCKS), "utf-8")


def test_the_blocks_are_the_three_characters_the_compact_rendering_uses() -> None:
    """The constant is the real character set, not a guess kept in sync by hand."""

    above_ascii = {ch for ch in pairing_qr(ENDPOINT, compact=True) if ord(ch) > 126}

    assert above_ascii == set(COMPACT_BLOCKS)


def test_a_stream_that_declares_utf8_can_draw_them() -> None:
    assert stream_can_draw_blocks(Stream("utf-8")) is True


@pytest.mark.parametrize("encoding", ["cp1251", "cp1252", "ascii"])
def test_a_single_byte_stream_cannot(encoding: str) -> None:
    assert stream_can_draw_blocks(Stream(encoding)) is False


def test_a_stream_with_no_encoding_is_not_capable() -> None:
    """The safe answer, not a guess: ASCII reads everywhere, mojibake nowhere."""

    assert stream_can_draw_blocks(Stream(None)) is False
    assert stream_can_draw_blocks(StreamWithoutEncoding()) is False
    assert stream_can_draw_blocks(io.StringIO()) is False


def test_a_replacing_stream_is_still_not_capable() -> None:
    """"Can it be represented", not "will the write throw".

    A stream carrying ``errors="replace"`` never raises -- it would quietly
    draw the code out of question marks, which scans as nothing at all.
    """

    assert stream_can_draw_blocks(Stream("cp1251", errors="replace")) is False


# -- the selection ----------------------------------------------------------


def test_a_capable_stream_gets_todays_compact_rendering_byte_for_byte() -> None:
    rendered = pairing_qr_for_stream(ENDPOINT, Stream("utf-8"))

    assert rendered == pairing_qr(ENDPOINT, compact=True)
    assert hashlib.sha256(rendered.encode("utf-8")).hexdigest() == COMPACT_SHA256


def test_an_incapable_stream_gets_pure_ascii() -> None:
    rendered = pairing_qr_for_stream(ENDPOINT, Stream("cp1251"))

    assert rendered == render_qr(pairing_payload(ENDPOINT), compact=False)
    assert max(ord(ch) for ch in rendered) <= 126


@pytest.mark.parametrize("encoding", ["cp1251", "cp1252", "ascii"])
def test_the_ascii_rendering_actually_encodes_in_those_code_pages(encoding: str) -> None:
    """The point of the exercise: this is the write that used to die."""

    rendered = pairing_qr_for_stream(ENDPOINT, Stream(encoding))

    assert rendered.encode(encoding, errors="strict")


def test_wide_is_an_instruction_and_beats_detection() -> None:
    """`--wide` on a UTF-8 terminal still draws wide -- the user said so."""

    on_utf8 = pairing_qr_for_stream(ENDPOINT, Stream("utf-8"), wide=True)

    assert on_utf8 == render_qr(pairing_payload(ENDPOINT), compact=False)
    assert on_utf8 != pairing_qr(ENDPOINT, compact=True)


def test_both_renderings_encode_the_very_same_code() -> None:
    """Decoded back to modules, the two drawings are the same QR.

    Not "both were built from the same call" -- the matrices are read out of
    the two renderings and compared with the one segno makes for the payload.
    """

    payload = pairing_payload(ENDPOINT)
    expected = _bordered(segno.make(payload, error="m"))

    compact = _compact_matrix(pairing_qr_for_stream(ENDPOINT, Stream("utf-8")))
    wide = _wide_matrix(pairing_qr_for_stream(ENDPOINT, Stream("cp1251")))

    assert wide == expected
    # The compact drawing packs two module rows per line, so an odd-sized code
    # leaves one half-row of padding at the bottom.
    assert compact[: len(expected)] == expected
    assert len(compact) - len(expected) <= 1


def test_the_payload_itself_is_untouched_by_any_of_this() -> None:
    assert pairing_payload(ENDPOINT) == "localcanvas://connect?endpoint={}".format(ENDPOINT)


# -- the rules that must survive later edits --------------------------------


def test_nothing_in_the_package_reconfigures_a_stream() -> None:
    """`docs/connection.md` presentation rule: adapt to the stream, not it to us.

    Redirected output may deliberately be in a non-UTF-8 encoding, and silently
    re-encoding a caller's file is a worse failure than an ASCII drawing.  The
    scan is over the shipped package, not over these tests -- the tests have to
    name the environment variable in order to force it on a child process.

    It is a plain text scan, so the package may not even *mention* these in
    prose.  That is the cheap price of a guard nothing can reintroduce quietly.
    """

    forbidden = ("reconfigure(", "sys.stdout =", "sys.stderr =", "PYTHONIOENCODING")
    offenders = []
    for source in sorted(PACKAGE_ROOT.rglob("*.py")):
        text = source.read_text(encoding="utf-8")
        for needle in forbidden:
            if needle in text:
                offenders.append("{}: {}".format(source.name, needle))

    assert offenders == []


def test_the_qr_path_catches_two_named_errors_and_nothing_broader() -> None:
    text = Path(pairing.__file__).read_text(encoding="utf-8")

    assert "except Exception" not in text
    assert not re.search(r"^\s*except\s*:", text, re.MULTILINE)


# -- end to end, with the child's encoding forced ---------------------------


def _child_env(io_encoding) -> dict:
    env = dict(os.environ)
    # This test is about *this working tree's* code, so the child imports from
    # here rather than from whatever copy happens to be installed in the
    # environment -- an installation lags the branch by definition.  Testing
    # the installed artifact is `test_packaging.py`'s job, and it drops
    # PYTHONPATH on purpose to do it.
    env["PYTHONPATH"] = str(PACKAGE_ROOT.parent)
    # UTF-8 mode would decide the answer instead of the variable under test.
    env.pop("PYTHONUTF8", None)
    env.pop("PYTHONIOENCODING", None)
    if io_encoding is not None:
        env["PYTHONIOENCODING"] = io_encoding
    return env


@pytest.mark.parametrize("io_encoding", ["cp1251", "cp1252", "ascii", "utf-8", None])
def test_the_qr_subcommand_survives_redirection_on_any_of_these(
    tmp_path: Path, io_encoding
) -> None:
    """Redirected to a real file, with the child's encoding set by us.

    ``None`` means the variable is absent from the child's environment
    entirely -- the case that used to make this suite's colour depend on which
    shell launched it.
    """

    target = tmp_path / "qr.txt"
    with target.open("wb") as sink:
        result = subprocess.run(
            [sys.executable, "-m", "localcanvas_gateway", "qr", "--endpoint", ENDPOINT],
            cwd=str(tmp_path),
            env=_child_env(io_encoding),
            stdout=sink,
            stderr=subprocess.PIPE,
        )

    assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")

    written = target.read_bytes()
    decoded = written.decode(io_encoding or "utf-8", errors="strict")
    assert "localcanvas://connect?endpoint={}".format(ENDPOINT) in decoded
    assert decoded.strip()

    if io_encoding in ("cp1251", "cp1252", "ascii"):
        assert max(written) <= 126  # nothing above ASCII reached the file


# -- helpers ----------------------------------------------------------------
#
# segno's terminal output draws light modules with reverse video, so the
# mappings below are the library's polarity, not an assumption about it: they
# are checked against ``segno.make(...).matrix`` in the test above.

_WIDE_MODULE = re.compile(r"\x1b\[(7|49)m(\s+)\x1b\[0m")

#: half-block character -> (top module is dark, bottom module is dark)
_COMPACT_HALVES = {"█": (False, False), "▀": (False, True), "▄": (True, False), " ": (True, True)}


def _bordered(code) -> list:
    matrix = [[bool(module) for module in row] for row in code.matrix]
    width = len(matrix[0]) + 2
    quiet = [False] * width
    return [quiet] + [[False] + row + [False] for row in matrix] + [quiet]


def _wide_matrix(text: str) -> list:
    rows = []
    for line in text.splitlines():
        row = []
        for match in _WIDE_MODULE.finditer(line):
            dark = match.group(1) == "49"
            row.extend([dark] * (len(match.group(2)) // 2))
        rows.append(row)
    return rows


def _compact_matrix(text: str) -> list:
    rows = []
    for line in text.splitlines():
        top, bottom = [], []
        for char in line:
            top_dark, bottom_dark = _COMPACT_HALVES[char]
            top.append(top_dark)
            bottom.append(bottom_dark)
        rows.append(top)
        rows.append(bottom)
    return rows
