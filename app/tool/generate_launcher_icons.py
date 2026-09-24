#!/usr/bin/env python3
r"""Draw LocalCanvas's launcher icon and write every Android asset it needs.

Run it from anywhere, with any Python 3.9 or newer:

    python app/tool/generate_launcher_icons.py            # write the assets
    python app/tool/generate_launcher_icons.py --check    # verify they match

`--check` regenerates everything into memory and compares it byte for byte with
what is committed.  It writes nothing and exits non-zero on the first file that
differs, so "the committed assets are what this script produces" is one command
rather than a promise.

WHY THERE IS A SCRIPT HERE AT ALL
---------------------------------
An icon that exists only as five PNGs nobody can regenerate is a binary blob:
the next person who wants the spark a shade larger has to open a paint program
and match the geometry by eye.  The mark is defined here as numbers, once, and
every asset is derived from those numbers -- so the five densities cannot drift
apart from each other or from the adaptive icon.

WHY IT DEPENDS ON NOTHING
-------------------------
Not Pillow, not cairosvg, not a pub package -- only `struct` and `binascii`,
which are in the standard library, and not even `zlib`.  Three reasons, in
order:

* LocalCanvas's `.venv` holds the gateway's dependencies alone, and the
  imaging libraries are not in it.  A generator that needed one would either
  pollute that environment or be unrunnable.
* A PNG of flat colour is a few dozen lines to write correctly -- IHDR, one
  IDAT of filter-0 scanlines, IEND, each with its own CRC-32 -- and writing it
  here means the reader can see exactly what ends up on disk.  That matters more
  than usual: `gateway/tests/media_fixtures.py` reads the mdpi PNG off disk at
  run time and verifies its chunk checksums, so this script's output is also a
  test fixture.
* And the compression is written out too, which is not obvious and is measured
  rather than preferred.  `zlib.compress` gives different bytes on different
  interpreters -- Python 3.14's zlib-ng and Python 3.10's zlib 1.2.13 disagree
  on this very image -- so an asset committed from one machine failed `--check`
  on another with nothing wrong.  See the DEFLATE section below.

THE MARK
--------
A canvas -- a rounded rectangular frame -- with a small four-point spark inside
it, toward the upper right.  Graphite ground `#0E0F12`, frame and spark in the
one soft-indigo accent `#8FA5F7`.  Both values are `LcPalette.dark.canvas` and
`LcPalette.accent` from `app/lib/theme/tokens.dart`; there is no third colour,
and `docs/ui-ux.md` is why -- one restrained accent, used for meaning.

Everything is laid out on the adaptive icon's own 108x108dp canvas, so one set
of numbers serves both jobs:

* the **adaptive foreground** uses that canvas directly, and the whole mark sits
  inside the 36dp-radius circle around its centre -- the largest region a
  circular launcher mask is guaranteed to keep;
* the **legacy PNGs** are the centre 72x72dp of the same canvas scaled up to
  fill the square, which is the standard relationship between the two forms.

ANTI-ALIASING WITHOUT A THIRD COLOUR
------------------------------------
Edges are supersampled: each pixel is `SAMPLES x SAMPLES` point-in-shape tests,
and the fraction that land inside the mark becomes a blend factor `t`.  The
pixel is then `ground + t * (accent - ground)` -- so every colour in the file
lies on the straight line between the two, and a third colour cannot appear
without someone putting it here.  `app/test/launcher_icon_test.dart` checks that
property against the committed bytes.
"""

from __future__ import annotations

import argparse
import binascii
import math
import struct
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

# ---------------------------------------------------------------------------
# The palette.  Two colours, and their names say where they come from.
# ---------------------------------------------------------------------------

#: `LcPalette.dark.canvas` -- app/lib/theme/tokens.dart
GROUND = (0x0E, 0x0F, 0x12)
#: `LcPalette.accent` -- app/lib/theme/tokens.dart
ACCENT = (0x8F, 0xA5, 0xF7)

GROUND_HEX = "#FF0E0F12"
ACCENT_HEX = "#FF8FA5F7"

# ---------------------------------------------------------------------------
# The geometry, in adaptive-icon design units: a 108x108 canvas, centre 54,54.
# ---------------------------------------------------------------------------

CANVAS = 108.0
CENTRE = CANVAS / 2.0

#: Only the centre 72x72dp of the canvas is guaranteed visible, and a circular
#: mask keeps the *inscribed circle* of that square -- radius 36 about the
#: centre.  Nothing the mark draws may leave it.
SAFE_RADIUS = 36.0

#: The centre 72x72dp region, which is what the legacy square PNG shows.
LEGACY_ORIGIN = CENTRE - 36.0
LEGACY_EXTENT = 72.0

#: The canvas frame: a rounded square outline.
FRAME_HALF = 25.0
FRAME_RADIUS = 8.5
FRAME_STROKE = 5.0

#: The spark: a four-point star, up and to the right inside the frame.
SPARK_CENTRE = (60.0, 48.0)
SPARK_OUTER = 9.5
SPARK_INNER = 3.6

#: Edge quality.  8x8 gives 65 blend levels, which is more than a 48px icon can
#: show and cheap enough to stay a second-long script.
SAMPLES = 8

#: Every legacy density Android asks for, and the pixel size it must be.
DENSITIES: Dict[str, int] = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

#: The cubic approximation of a quarter circle.
KAPPA = 0.5522847498307936


# ---------------------------------------------------------------------------
# Shapes.  Each answers one question: is this point inside me?
# ---------------------------------------------------------------------------


def _in_rounded_rect(x: float, y: float, half: float, radius: float) -> bool:
    """Inside the rounded square of the given half-size, centred on the canvas."""

    dx = abs(x - CENTRE)
    dy = abs(y - CENTRE)
    if dx > half or dy > half:
        return False
    flat = half - radius
    if dx <= flat or dy <= flat:
        return True
    return (dx - flat) ** 2 + (dy - flat) ** 2 <= radius * radius


def _star_vertices() -> List[Tuple[float, float]]:
    """The spark's eight corners: four points, four waists between them."""

    cx, cy = SPARK_CENTRE
    points: List[Tuple[float, float]] = []
    for step in range(8):
        angle = math.pi / 2.0 * (step / 2.0)
        radius = SPARK_OUTER if step % 2 == 0 else SPARK_INNER
        points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


def _in_polygon(x: float, y: float, polygon: Sequence[Tuple[float, float]]) -> bool:
    """Even-odd ray casting, the textbook one."""

    inside = False
    count = len(polygon)
    for index in range(count):
        x0, y0 = polygon[index]
        x1, y1 = polygon[(index + 1) % count]
        if (y0 > y) != (y1 > y):
            crossing = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
            if x < crossing:
                inside = not inside
    return inside


_STAR = _star_vertices()


def _in_mark(x: float, y: float) -> bool:
    """Inside the frame's stroke, or inside the spark."""

    in_frame = _in_rounded_rect(x, y, FRAME_HALF, FRAME_RADIUS) and not _in_rounded_rect(
        x, y, FRAME_HALF - FRAME_STROKE, FRAME_RADIUS - FRAME_STROKE
    )
    return in_frame or _in_polygon(x, y, _STAR)


# ---------------------------------------------------------------------------
# Rasterising.
# ---------------------------------------------------------------------------


def _coverage(size: int) -> List[List[float]]:
    """A `size x size` grid of blend factors, supersampled `SAMPLES` per axis.

    The pixel grid covers the centre `LEGACY_EXTENT` of the design canvas, which
    is what a legacy square icon shows of an adaptive one.
    """

    scale = LEGACY_EXTENT / size
    sub = scale / SAMPLES
    total = float(SAMPLES * SAMPLES)
    rows: List[List[float]] = []
    for row in range(size):
        top = LEGACY_ORIGIN + row * scale
        line: List[float] = []
        for column in range(size):
            left = LEGACY_ORIGIN + column * scale
            hits = 0
            for sy in range(SAMPLES):
                y = top + (sy + 0.5) * sub
                for sx in range(SAMPLES):
                    if _in_mark(left + (sx + 0.5) * sub, y):
                        hits += 1
            line.append(hits / total)
        rows.append(line)
    return rows


def _blend(t: float) -> Tuple[int, int, int]:
    """`ground` at t=0, `accent` at t=1, and only the line between them ever."""

    return tuple(  # type: ignore[return-value]
        int(round(ground + t * (accent - ground)))
        for ground, accent in zip(GROUND, ACCENT)
    )


def _chunk(kind: bytes, payload: bytes) -> bytes:
    """One PNG chunk: length, type, payload, and the CRC-32 over the last two."""

    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


# ---------------------------------------------------------------------------
# DEFLATE, written here rather than taken from `zlib`.
#
# MEASURED, 2026-09-10, and the reason this section exists at all.  The first
# version of this script called `zlib.compress(raw, 9)`, and the assets it wrote
# were reproducible only on the interpreter that wrote them:
#
#     Python 3.10.11, zlib 1.2.13        raw sha d8123533ec611c38 -> 314 bytes
#     Python 3.14.6,  zlib 1.3.1.zlib-ng raw sha d8123533ec611c38 -> 315 bytes
#
# Identical input, different output.  Both streams are valid and decode to the
# same pixels, but `--check` compares bytes, so on a machine whose `python3` is
# newer the committed assets looked wrong when nothing was wrong -- a guard
# firing on correct code, which is worse than no guard.  Two Pythons on one
# machine were enough to show it.
#
# So the compressor is part of the script now.  A fixed-Huffman DEFLATE block
# (RFC 1951 section 3.2.6) over a greedy LZ77 match search: no dynamic code
# tables to build, nothing tuned, and the same bytes out of any Python 3.9 or
# newer, on any platform, for ever.  It compresses a little worse than zlib's
# dynamic Huffman -- a few hundred bytes across all five icons -- which is the
# whole price of the property the acceptance criterion actually asks for.
#
# The output is checked by things that did not write it: `flutter test` decodes
# every one of these files with Dart's own zlib and walks its chunk CRCs, the
# gateway's media suite reads the mdpi PNG off disk, and AAPT2 decodes all five
# during an Android build.
# ---------------------------------------------------------------------------

#: RFC 1951 section 3.2.5, table of length codes: (code, base length, extra bits).
_LENGTH_CODES = (
    (257, 3, 0), (258, 4, 0), (259, 5, 0), (260, 6, 0), (261, 7, 0),
    (262, 8, 0), (263, 9, 0), (264, 10, 0), (265, 11, 1), (266, 13, 1),
    (267, 15, 1), (268, 17, 1), (269, 19, 2), (270, 23, 2), (271, 27, 2),
    (272, 31, 2), (273, 35, 3), (274, 43, 3), (275, 51, 3), (276, 59, 3),
    (277, 67, 4), (278, 83, 4), (279, 99, 4), (280, 115, 4), (281, 131, 5),
    (282, 163, 5), (283, 195, 5), (284, 227, 5), (285, 258, 0),
)

#: The same table for distances: (code, base distance, extra bits).
_DISTANCE_CODES = (
    (0, 1, 0), (1, 2, 0), (2, 3, 0), (3, 4, 0), (4, 5, 1), (5, 7, 1),
    (6, 9, 2), (7, 13, 2), (8, 17, 3), (9, 25, 3), (10, 33, 4), (11, 49, 4),
    (12, 65, 5), (13, 97, 5), (14, 129, 6), (15, 193, 6), (16, 257, 7),
    (17, 385, 7), (18, 513, 8), (19, 769, 8), (20, 1025, 9), (21, 1537, 9),
    (22, 2049, 10), (23, 3073, 10), (24, 4097, 11), (25, 6145, 11),
    (26, 8193, 12), (27, 12289, 12), (28, 16385, 13), (29, 24577, 13),
)

WINDOW = 32768
MIN_MATCH = 3
MAX_MATCH = 258
#: How far back the search looks along one hash chain.  A hard number, not a
#: heuristic that could vary: the output must not depend on how fast the machine
#: is or on how full a dictionary happens to be.
MAX_CHAIN = 32


class _Bits:
    """A DEFLATE bit sink.

    Two ways in, because DEFLATE uses both: Huffman codes are written from the
    most significant bit down, and everything else -- block headers, the extra
    bits after a length or a distance -- from the least significant bit up.
    Getting these two the wrong way round is the classic way to produce a stream
    that looks plausible and decodes to nothing.
    """

    def __init__(self) -> None:
        self.out = bytearray()
        self._acc = 0
        self._used = 0

    def value(self, value: int, count: int) -> None:
        """`count` bits of `value`, least significant first."""

        for index in range(count):
            self._acc |= ((value >> index) & 1) << self._used
            self._used += 1
            if self._used == 8:
                self.out.append(self._acc)
                self._acc = 0
                self._used = 0

    def code(self, code: int, count: int) -> None:
        """A Huffman code: `count` bits of `code`, most significant first."""

        for index in range(count - 1, -1, -1):
            self.value((code >> index) & 1, 1)

    def finish(self) -> bytes:
        if self._used:
            self.out.append(self._acc)
            self._acc = 0
            self._used = 0
        return bytes(self.out)


def _fixed_code(symbol: int) -> Tuple[int, int]:
    """The fixed literal/length code for a symbol, as (code, bit count)."""

    if symbol < 144:
        return 0b00110000 + symbol, 8
    if symbol < 256:
        return 0b110010000 + symbol - 144, 9
    if symbol < 280:
        return symbol - 256, 7
    return 0b11000000 + symbol - 280, 8


def _length_code(length: int) -> Tuple[int, int, int]:
    for code, base, extra in reversed(_LENGTH_CODES):
        if length >= base:
            return code, length - base, extra
    raise AssertionError("length {} is below the shortest match".format(length))


def _distance_code(distance: int) -> Tuple[int, int, int]:
    for code, base, extra in reversed(_DISTANCE_CODES):
        if distance >= base:
            return code, distance - base, extra
    raise AssertionError("distance {} is below one".format(distance))


def _deflate(data: bytes) -> bytes:
    """One final fixed-Huffman block: greedy LZ77, then the codes for it."""

    bits = _Bits()
    bits.value(1, 1)  # BFINAL
    bits.value(1, 2)  # BTYPE = 01, fixed Huffman

    chains: Dict[bytes, List[int]] = {}
    position = 0
    size = len(data)
    while position < size:
        best_length = 0
        best_distance = 0
        if position + MIN_MATCH <= size:
            key = data[position : position + MIN_MATCH]
            for candidate in chains.get(key, ()):
                distance = position - candidate
                if distance > WINDOW:
                    break
                length = MIN_MATCH
                limit = min(MAX_MATCH, size - position)
                while (
                    length < limit
                    and data[candidate + length] == data[position + length]
                ):
                    length += 1
                if length > best_length:
                    best_length = length
                    best_distance = distance
                    if length == limit:
                        break

        if best_length >= MIN_MATCH:
            code, extra_value, extra_bits = _length_code(best_length)
            symbol, width = _fixed_code(code)
            bits.code(symbol, width)
            if extra_bits:
                bits.value(extra_value, extra_bits)
            code, extra_value, extra_bits = _distance_code(best_distance)
            bits.code(code, 5)
            if extra_bits:
                bits.value(extra_value, extra_bits)
            step = best_length
        else:
            symbol, width = _fixed_code(data[position])
            bits.code(symbol, width)
            step = 1

        # Every position inside a match still goes into the dictionary, or the
        # next match cannot start in the middle of what was just copied.
        for offset in range(step):
            at = position + offset
            if at + MIN_MATCH <= size:
                chain = chains.setdefault(data[at : at + MIN_MATCH], [])
                chain.insert(0, at)
                del chain[MAX_CHAIN:]
        position += step

    symbol, width = _fixed_code(256)  # end of block
    bits.code(symbol, width)
    return bits.finish()


def _adler32(data: bytes) -> int:
    """RFC 1950's checksum, written out so nothing here comes from a library."""

    low, high = 1, 0
    for byte in data:
        low = (low + byte) % 65521
        high = (high + low) % 65521
    return (high << 16) | low


def _zlib_stream(data: bytes) -> bytes:
    """RFC 1950 around RFC 1951: two header bytes, the block, the checksum.

    `0x78 0x01` is deflate with a 32K window and no preset dictionary, and the
    pair is a multiple of 31, which is the header's own check.
    """

    return b"\x78\x01" + _deflate(data) + struct.pack(">I", _adler32(data))


def _png(size: int) -> bytes:
    """An 8-bit RGBA PNG of the mark, opaque everywhere.

    Deliberately minimal -- signature, IHDR, one IDAT, IEND.  No `tIME`, no
    text chunks, nothing that carries a clock: the same input must give the same
    bytes on every run, and a timestamp is the usual reason it does not.
    """

    coverage = _coverage(size)
    raw = bytearray()
    for row in coverage:
        raw.append(0)  # filter type 0: none.  Predictable, and small enough here.
        for t in row:
            red, green, blue = _blend(t)
            raw += bytes((red, green, blue, 0xFF))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    body = _zlib_stream(bytes(raw))
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", header)
        + _chunk(b"IDAT", body)
        + _chunk(b"IEND", b"")
    )


# ---------------------------------------------------------------------------
# Vector drawables.  The adaptive icon needs no rasterising at all.
# ---------------------------------------------------------------------------


def _number(value: float) -> str:
    """A path coordinate, printed the same way every run."""

    text = "{:.3f}".format(value).rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def _rounded_rect_path(half: float, radius: float) -> str:
    """A closed rounded square about the canvas centre, corners as cubics."""

    x0, y0 = CENTRE - half, CENTRE - half
    x1, y1 = CENTRE + half, CENTRE + half
    pull = radius * (1.0 - KAPPA)

    def point(*values: float) -> str:
        return ",".join(_number(value) for value in values)

    return " ".join(
        (
            "M" + point(x0 + radius, y0),
            "L" + point(x1 - radius, y0),
            "C" + point(x1 - pull, y0, x1, y0 + pull, x1, y0 + radius),
            "L" + point(x1, y1 - radius),
            "C" + point(x1, y1 - pull, x1 - pull, y1, x1 - radius, y1),
            "L" + point(x0 + radius, y1),
            "C" + point(x0 + pull, y1, x0, y1 - pull, x0, y1 - radius),
            "L" + point(x0, y0 + radius),
            "C" + point(x0, y0 + pull, x0 + pull, y0, x0 + radius, y0),
            "Z",
        )
    )


def _star_path() -> str:
    vertices = _STAR
    head = "M" + ",".join(_number(value) for value in vertices[0])
    rest = " ".join(
        "L" + ",".join(_number(value) for value in vertex) for vertex in vertices[1:]
    )
    return "{} {} Z".format(head, rest)


def _foreground_xml() -> bytes:
    """The adaptive foreground: the frame ring and the spark, accent on nothing.

    `evenOdd` is what makes the frame a ring -- the inner rounded square is a
    hole in the outer one rather than a second shape on top of it, so the
    background shows through the canvas exactly as it does around it.
    """

    ring = "{} {}".format(
        _rounded_rect_path(FRAME_HALF, FRAME_RADIUS),
        _rounded_rect_path(FRAME_HALF - FRAME_STROKE, FRAME_RADIUS - FRAME_STROKE),
    )
    return _xml(
        [
            "<!--",
            "  Generated by app/tool/generate_launcher_icons.py. Edit the geometry",
            "  there and re-run it, not this file.",
            "",
            "  The whole mark stays inside the {}dp-radius circle about the centre of".format(
                _number(SAFE_RADIUS)
            ),
            "  this 108dp canvas, which is what a circular launcher mask keeps.",
            "-->",
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
            '    android:width="108dp"',
            '    android:height="108dp"',
            '    android:viewportWidth="108"',
            '    android:viewportHeight="108">',
            '    <path',
            '        android:fillColor="{}"'.format(ACCENT_HEX),
            '        android:fillType="evenOdd"',
            '        android:pathData="{}" />'.format(ring),
            '    <path',
            '        android:fillColor="{}"'.format(ACCENT_HEX),
            '        android:pathData="{}" />'.format(_star_path()),
            "</vector>",
        ]
    )


def _background_xml() -> bytes:
    """The adaptive background: the graphite ground, edge to edge.

    Full bleed on purpose.  The background layer is what the launcher parallaxes
    and masks, so anything less than the whole 108dp canvas shows as a seam.
    """

    return _xml(
        [
            "<!--",
            "  Generated by app/tool/generate_launcher_icons.py.",
            "-->",
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
            '    android:width="108dp"',
            '    android:height="108dp"',
            '    android:viewportWidth="108"',
            '    android:viewportHeight="108">',
            '    <path',
            '        android:fillColor="{}"'.format(GROUND_HEX),
            '        android:pathData="M0,0 L108,0 L108,108 L0,108 Z" />',
            "</vector>",
        ]
    )


def _adaptive_xml() -> bytes:
    return _xml(
        [
            "<!--",
            "  Generated by app/tool/generate_launcher_icons.py.",
            "",
            "  Android 8 and later masks these two layers to the shape the device",
            "  uses for every other icon.  The legacy mipmap PNGs stay for older",
            "  releases; this file does not replace them.",
            "-->",
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <background android:drawable="@drawable/ic_launcher_background" />',
            '    <foreground android:drawable="@drawable/ic_launcher_foreground" />',
            "</adaptive-icon>",
        ]
    )


def _xml(lines: Iterable[str]) -> bytes:
    """UTF-8, LF endings, one trailing newline, on every platform.

    And a guard that cost a build to learn: XML forbids a double hyphen inside a
    comment, and the prose style used everywhere else in this repository is full
    of them.  AAPT2's message for it is "Failed to parse XML file" against a
    path in `build/intermediates/`, which says nothing about the character or
    the line -- so the generator refuses to write one rather than let the next
    person spend the same half hour.
    """

    body = "\n".join(['<?xml version="1.0" encoding="utf-8"?>', *lines])
    for index, comment in enumerate(body.split("<!--")):
        if index == 0:
            continue
        if "--" in comment.split("-->", 1)[0]:
            raise SystemExit(
                "an XML comment contains a double hyphen, which XML does not "
                "allow; AAPT2 will refuse the file:\n  {}".format(
                    " ".join(comment.split("-->", 1)[0].split())[:120]
                )
            )
    return (body + "\n").encode("utf-8")


# ---------------------------------------------------------------------------
# What gets written where.
# ---------------------------------------------------------------------------

RES = Path("android") / "app" / "src" / "main" / "res"


def assets() -> Dict[Path, bytes]:
    """Every generated file, by its path relative to the Flutter package root."""

    out: Dict[Path, bytes] = {}
    for density, size in DENSITIES.items():
        out[RES / "mipmap-{}".format(density) / "ic_launcher.png"] = _png(size)
    out[RES / "drawable" / "ic_launcher_foreground.xml"] = _foreground_xml()
    out[RES / "drawable" / "ic_launcher_background.xml"] = _background_xml()
    out[RES / "mipmap-anydpi-v26" / "ic_launcher.xml"] = _adaptive_xml()
    return out


def package_root() -> Path:
    """The `app/` directory this script is committed inside.

    Derived from `__file__` and from nothing else -- no argument, no environment
    variable, no working directory.  A generator that can be pointed at an
    arbitrary tree is a generator that will one day overwrite somebody else's,
    and this one has no reason to be pointable.
    """

    root = Path(__file__).resolve().parent.parent
    if not (root / "pubspec.yaml").is_file():
        raise SystemExit(
            "refusing to write: {} is not the Flutter package "
            "(no pubspec.yaml beside it)".format(root)
        )
    return root


def _path_reach() -> float:
    """How far the foreground's furthest path coordinate is from the centre.

    Every coordinate, control points included.  A cubic never leaves the convex
    hull of its four points, so this over-states the drawing's real reach and
    can only be wrong in the safe direction -- and it is the same number
    `app/test/launcher_icon_test.dart` recomputes from the committed XML.
    """

    text = _foreground_xml().decode("utf-8")
    start = text.index('android:pathData="')
    coordinates: List[float] = []
    while True:
        try:
            start = text.index('android:pathData="', start)
        except ValueError:
            break
        start += len('android:pathData="')
        end = text.index('"', start)
        for token in text[start:end].replace(",", " ").split():
            body = token.lstrip("MLCZmlcz")
            if body:
                coordinates.append(float(body))
        start = end
    points = list(zip(coordinates[0::2], coordinates[1::2]))
    return max(math.hypot(x - CENTRE, y - CENTRE) for x, y in points)


def _self_check() -> None:
    """Refuse to write a mark a circular launcher mask would clip.

    That is what a well-meant edit to the geometry above does silently, and it
    is cheaper to catch here than on a phone.
    """

    worst = _path_reach()
    if worst > SAFE_RADIUS:
        raise SystemExit(
            "the mark reaches {:.2f}dp from the centre, past the {:.0f}dp a circular "
            "mask keeps -- shrink it".format(worst, SAFE_RADIUS)
        )


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="compare the committed assets with what this script produces, and write nothing",
    )
    args = parser.parse_args(argv)

    _self_check()
    root = package_root()
    generated = assets()

    if args.check:
        problems = 0
        for relative, expected in sorted(generated.items()):
            target = root / relative
            if not target.is_file():
                print("missing:  {}".format(relative.as_posix()))
                problems += 1
            elif target.read_bytes() != expected:
                print("differs:  {}".format(relative.as_posix()))
                problems += 1
            else:
                print("matches:  {}".format(relative.as_posix()))
        if problems:
            print(
                "\n{} file(s) do not match. Re-run this script without --check.".format(
                    problems
                )
            )
            return 1
        print("\nall {} generated assets match.".format(len(generated)))
        return 0

    for relative, payload in sorted(generated.items()):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
        print("wrote {} ({} bytes)".format(relative.as_posix(), len(payload)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
