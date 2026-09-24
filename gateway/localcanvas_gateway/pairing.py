"""The QR pairing payload, and a QR rendered into a terminal.

`docs/connection.md` §3: pairing is **fully local**.  No external QR service, no
URL shortener, no hosted redirect, no cloud pairing -- the code is drawn from
the bytes on this machine and read by a camera in the same room.

The payload is one deep link carrying connection information only::

    localcanvas://connect?endpoint=http://192.0.2.42:7801

**No secret goes in it.**  v0.1 has no authentication, so there is nothing to
put there, and a future authenticated deployment must not be built by smuggling
a credential into an ordinary URL.

The endpoint is *given* to this module, never guessed from it.  Whoever starts
the gateway knows which address a phone should use; deriving one here would be
the gateway naming its own host, which is the habit
`docs/transport-boundary.md` exists to prevent.

Two renderings, chosen by what the stream can carry
---------------------------------------------------
The compact rendering is drawn from half- and full-block characters, none of
which exists in ascii, cp1251 or cp1252.  On Windows they reach an interactive
console fine, but the moment stdout is a pipe or a file Python encodes with the
machine's ANSI code page and the write dies with ``UnicodeEncodeError``.

So the rendering *adapts to the stream*; the stream is never adapted to it.
Nothing in this package re-opens a stream, replaces the process's own streams,
or sets the interpreter's stdio encoding from the inside: redirected output may
deliberately be in a non-UTF-8 encoding, and mojibake in a user's file is a
worse failure than a code drawn out of ASCII.  The choice is made *before* the
first character is written -- catching the error afterwards would leave half a
QR already on the stream.
"""

from __future__ import annotations

import io
from typing import Any
from urllib.parse import quote

import segno

#: The app's deep-link scheme (`docs/connection.md` §3).
PAIRING_SCHEME = "localcanvas://connect"

#: The only characters above ASCII that the compact rendering is drawn from:
#: UPPER HALF BLOCK, LOWER HALF BLOCK, FULL BLOCK.  Measured against segno
#: 1.6.6; the ``compact=False`` rendering uses none of them.
COMPACT_BLOCKS = "▀▄█"


def encoding_can_represent(text: str, encoding: Any) -> bool:
    """Can ``encoding`` represent every character of ``text``?

    Strict semantics on purpose: the question is "can this be represented",
    not "will writing it throw".  A stream carrying ``errors="replace"`` would
    not raise and would draw a QR made of question marks.

    Only two failures answer "no": the codec cannot encode the text, and
    Python does not know the codec's name.  Anything else is somebody else's
    bug and is left to propagate.
    """

    if not isinstance(encoding, str) or not encoding:
        return False
    try:
        text.encode(encoding, errors="strict")
    except (UnicodeEncodeError, LookupError):
        return False
    return True


def stream_can_draw_blocks(stream: Any) -> bool:
    """Can this stream carry the compact rendering's block characters?

    A stream with no usable ``encoding`` -- absent, ``None``, or not a name --
    is treated as *not* capable.  That is the safe answer rather than a guess:
    the ASCII rendering is readable everywhere, an unencodable one is readable
    nowhere.
    """

    return encoding_can_represent(COMPACT_BLOCKS, getattr(stream, "encoding", None))


def pairing_payload(endpoint: str) -> str:
    """The exact string the QR encodes."""

    return "{}?endpoint={}".format(PAIRING_SCHEME, quote(endpoint, safe=":/?#[]@!$&'()*+,;=~"))


def render_qr(payload: str, *, compact: bool = True, border: int = 1) -> str:
    """The QR as text, ready to print.

    ``compact`` packs two rows into each line of half-block characters, which
    is what makes the code fit an ordinary terminal window; a terminal that
    cannot draw them can ask for the full-size rendering instead.
    """

    code = segno.make(payload, error="m")
    buffer = io.StringIO()
    if compact:
        code.terminal(out=buffer, compact=True, border=border)
    else:
        code.terminal(out=buffer, border=border)
    return buffer.getvalue()


def pairing_qr(endpoint: str, *, compact: bool = True, border: int = 1) -> str:
    """The terminal QR for one endpoint, payload and rendering together."""

    return render_qr(pairing_payload(endpoint), compact=compact, border=border)


def pairing_qr_for_stream(
    endpoint: str, stream: Any, *, wide: bool = False, border: int = 1
) -> str:
    """The QR in whichever rendering ``stream`` can actually carry.

    ``wide`` is the person's own instruction (``qr --wide``) and always wins:
    detection picks a rendering when nobody said which, it never overrides
    somebody who did.

    Both renderings encode the same payload -- only the drawing differs.
    """

    compact = not wide and stream_can_draw_blocks(stream)
    return pairing_qr(endpoint, compact=compact, border=border)


__all__ = [
    "COMPACT_BLOCKS",
    "PAIRING_SCHEME",
    "encoding_can_represent",
    "pairing_payload",
    "pairing_qr",
    "pairing_qr_for_stream",
    "render_qr",
    "stream_can_draw_blocks",
]
