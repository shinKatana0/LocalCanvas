"""What an upload *is*, decided by the upload rather than by what it claims.

The defect this file is written against was found by a person choosing a
photograph on a phone: the same JPEG was accepted when the picker labelled it
``image/jpeg`` and refused when the picker next to it labelled it ``image/jpg``,
``application/octet-stream``, ``image/*`` or nothing at all.  Every row of that
measured table is a test here, and all of them send **one** body.

It was fixed for images first (T-0126) and for video afterwards (T-0129), and
the second half of the file is the second half of that work: the same measured
table for a clip, the same closed set, and the same question asked at the
boundary -- *can the gateway be made to write a file into ComfyUI's input
directory under an extension that does not describe it?*  It was NO for images
and YES for video until the video sniff existed.

Three properties are held in place, and they are not the same property:

**The bytes decide.**  The declared content type and the filename are both the
client's word, and neither is consulted for either kind any more.

**The set does not widen.**  ``ALLOWED_TYPES`` is still the whole of what the
gateway will write into ComfyUI's input directory; a file matching nothing in it
is refused with ``unsupported_media_type``, and an AVIF and an MP4 -- real
files, real signatures -- are refused for being outside it rather than accepted
for being nearly right.

**The upload is still streamed.**  ``_chunks`` exists so that a phone's video
never lands in the gateway's memory, and identifying a file is a *peek* at its
head, not a read of it.  That is the property most easily lost while adding a
sniff, so it is measured twice below -- once by watching the memory the store
holds while a large body goes through it, and once by watching the file grow on
disk while the body is still being handed over.

The fixtures come from ``media_fixtures.py``, and the first section here is the
proof that they are the containers they claim to be: each is walked by a parser
written from the format's own definition, so a fixture that is really a byte
string somebody typed fails there rather than quietly making the sniffer look
right.
"""

from __future__ import annotations

import tracemalloc
import zlib
from pathlib import Path
from typing import Optional

import pytest

import media_fixtures as fixtures
from localcanvas_gateway.media import (
    ALLOWED_TYPES,
    COMFY_INPUT_SUBFOLDER,
    NAMED_IMAGE_REFUSALS,
    SNIFF_BYTES,
    _ISOBMFF_IMAGE_BRANDS,
    MediaRejected,
    MediaStore,
    sniff_image_type,
    sniff_video_type,
)
from workflow_fixtures import EVERY_FIELD, IMAGE_FIELD

#: A workflow whose value comes from a video upload, bound to the media loader
#: in ``conftest.DEFAULT_GRAPH``.  It lives here rather than in
#: ``workflow_fixtures.py`` because this is the only file that needs one: what
#: it is for is to carry a video all the way to ComfyUI's input directory.
VIDEO_FIELD = """
- id: source_video
  label: Source video
  type: video
  required: true
  bind:
    node: "40"
    input: video
"""


@pytest.fixture
def harness(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    builder.add("needs_image", IMAGE_FIELD)
    builder.add("needs_video", VIDEO_FIELD)
    return gateway_factory()


def error_of(response):
    body = response.json()
    assert set(body) == {"error"}
    return body["error"]


def files_under(root: Path):
    return [path for path in root.rglob("*") if path.is_file()]


def post(
    harness,
    data: bytes,
    *,
    filename: str = "IMG_0142.jpg",
    declared: Optional[str] = "image/jpeg",
    kind: str = "image",
):
    """POST one multipart body byte for byte, with no client library in the way.

    ``declared=None`` leaves the file part's ``Content-Type`` header out
    altogether, which is a different request from one that declares
    ``application/octet-stream`` and is the last row of the measured table.
    ``httpx`` cannot send it: it supplies a type of its own when none is given,
    so the request that a phone's picker really makes has to be written out
    here.
    """

    boundary = "----lct0126"
    crlf = "\r\n"
    lines = [
        "--" + boundary,
        'Content-Disposition: form-data; name="kind"',
        "",
        kind,
        "--" + boundary,
        'Content-Disposition: form-data; name="file"; filename="{}"'.format(filename),
    ]
    if declared is not None:
        lines.append("Content-Type: " + declared)
    lines += ["", ""]
    body = (
        crlf.join(lines).encode("utf-8")
        + data
        + (crlf + "--" + boundary + "--" + crlf).encode("utf-8")
    )
    return harness.client.post(
        "/api/v1/media",
        content=body,
        headers={"content-type": "multipart/form-data; boundary={}".format(boundary)},
    )


def stored(harness, response):
    """The item the store is holding for an accepted upload."""

    assert response.status_code == 201, response.text
    item = harness.state.media.get(response.json()["media_id"])
    assert item is not None
    return item


# ==========================================================================
# The fixtures are containers, not typed constants
#
# Each parser below is written from the format's own definition and reads
# structure -- lengths, offsets, chains, checksums -- rather than a magic
# number.  The sniffer under test reads magic numbers and nothing else, so
# nothing here can pass by agreeing with it.
# ==========================================================================


def test_the_png_fixture_is_a_real_file_with_intact_chunk_checksums() -> None:
    """Read off this repository, and verified by the format's own CRCs.

    A PNG carries a CRC-32 per chunk.  Recomputing them is a check no
    hand-written constant survives, and it is arithmetic over the whole file
    rather than a look at its first bytes.
    """

    data = fixtures.png_bytes()
    assert fixtures.PNG_PATH.is_file()

    offset, kinds = 8, []
    while offset < len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        recorded = int.from_bytes(data[offset + 8 + length : offset + 12 + length], "big")
        assert zlib.crc32(kind + payload) == recorded, kind
        kinds.append(kind)
        offset += 12 + length

    assert offset == len(data)
    assert kinds[0] == b"IHDR"
    assert kinds[-1] == b"IEND"


def test_the_jpeg_fixture_is_a_real_segment_chain() -> None:
    """Walked by its segment lengths, which is how a decoder reads a JPEG.

    Every length is read from the file and used to find the next marker, so the
    walk arrives at SOS only if all of them are right.  The Exif directory is
    parsed as a TIFF directory on the way past, and the frame's dimensions are
    read out of SOF0 rather than assumed.
    """

    data = fixtures.JPEG
    assert data[:2] == b"\xff\xd8"

    offset, seen = 2, []
    frame = exif = None
    while data[offset] == 0xFF and data[offset + 1] != 0xDA:
        marker = data[offset + 1]
        length = int.from_bytes(data[offset + 2 : offset + 4], "big")
        payload = data[offset + 4 : offset + 2 + length]
        if marker == 0xE1:
            exif = payload
        if marker == 0xC0:
            frame = payload
        seen.append(marker)
        offset += 2 + length

    assert data[offset + 1] == 0xDA, "the segment chain did not land on SOS"
    assert seen == [0xE0, 0xE1, 0xDB, 0xC0, 0xC4]
    assert data[-2:] == b"\xff\xd9"

    # SOF0: precision, height, width -- the picture's real shape.
    assert frame[0] == 8
    assert int.from_bytes(frame[1:3], "big") == 3024
    assert int.from_bytes(frame[3:5], "big") == 4032

    # APP1: an Exif TIFF directory whose entries are found by their offsets.
    assert exif[:6] == b"Exif\x00\x00"
    tiff = exif[6:]
    assert tiff[:2] == b"II"
    assert int.from_bytes(tiff[2:4], "little") == 42
    directory = int.from_bytes(tiff[4:8], "little")
    count = int.from_bytes(tiff[directory : directory + 2], "little")
    tags = []
    for index in range(count):
        entry = tiff[directory + 2 + 12 * index : directory + 14 + 12 * index]
        tag = int.from_bytes(entry[0:2], "little")
        size = int.from_bytes(entry[4:8], "little")
        at = int.from_bytes(entry[8:12], "little")
        tags.append((tag, tiff[at : at + size - 1]))
    assert tags == [(0x010F, b"LocalCanvas"), (0x0110, b"Test Camera")]


def test_the_gif_fixtures_are_complete_files() -> None:
    """Walked from the screen descriptor through the sub-blocks to the trailer.

    The colour table's size is computed from the packed field, the image
    descriptor is found after it, and the LZW sub-blocks are chained by their
    own lengths.  A file that ends exactly on its trailer is a whole GIF.
    """

    for data in (fixtures.GIF87A, fixtures.GIF89A):
        assert data[3:6] in (b"87a", b"89a")
        packed = data[10]
        table = 3 * 2 ** ((packed & 0x07) + 1) if packed & 0x80 else 0
        offset = 13 + table
        assert data[offset] == 0x2C, "no image descriptor after the colour table"
        assert int.from_bytes(data[offset + 5 : offset + 7], "little") == 1
        assert int.from_bytes(data[offset + 7 : offset + 9], "little") == 1
        offset += 10  # descriptor
        assert data[offset] == 2, "LZW minimum code size"
        offset += 1
        while data[offset]:
            offset += 1 + data[offset]
        assert data[offset + 1] == 0x3B, "no trailer where the sub-blocks end"
        assert offset + 2 == len(data)


#: The DIB header sizes the BMP format documents, written out here rather than
#: imported, so that neither the fixture module nor ``media.py`` is the source
#: of the list these tests hold them both to.
DOCUMENTED_BMP_HEADER_SIZES = {12, 16, 40, 52, 56, 64, 108, 124}


@pytest.mark.parametrize(
    "header_size",
    [pytest.param(size, id="dib-{}".format(size)) for size in fixtures.BMP_DIB_HEADER_SIZES],
)
def test_the_bmp_fixtures_declare_their_own_size_and_pixels(header_size) -> None:
    """Every length in a BMP's two headers is checked against the file.

    One per documented DIB header size.  The header is read the way its own
    size says to read it -- 16-bit dimensions in the 12-byte core header,
    32-bit ones everywhere else, nothing past the bit count in OS/2's 16-byte
    short header, and the channel masks where the V2 header and later carry
    them -- and the pixel array has to be exactly the rows those dimensions and
    that depth call for, starting where the file header says.
    """

    data = fixtures.BMP_BY_HEADER_SIZE[header_size]
    assert data[:2] == b"BM"
    assert int.from_bytes(data[2:6], "little") == len(data)
    offset = int.from_bytes(data[10:14], "little")
    assert int.from_bytes(data[14:18], "little") == header_size
    assert offset == 14 + header_size, "the pixels start right after the header"

    if header_size == 12:
        width = int.from_bytes(data[18:20], "little")
        height = int.from_bytes(data[20:22], "little")
        planes = int.from_bytes(data[22:24], "little")
        bits = int.from_bytes(data[24:26], "little")
    elif header_size == 16:
        width = int.from_bytes(data[18:22], "little", signed=True)
        height = int.from_bytes(data[22:26], "little", signed=True)
        planes = int.from_bytes(data[26:28], "little")
        bits = int.from_bytes(data[28:30], "little")
        assert bits == 24, "no compression field: an uncompressed 24-bit file"
    else:
        width = int.from_bytes(data[18:22], "little", signed=True)
        height = int.from_bytes(data[22:26], "little", signed=True)
        planes = int.from_bytes(data[26:28], "little")
        bits = int.from_bytes(data[28:30], "little")
        compression = int.from_bytes(data[30:34], "little")
        assert int.from_bytes(data[34:38], "little") == len(data) - offset
        if header_size in (52, 56, 108, 124):
            assert compression == 3, "BI_BITFIELDS: the masks are what it is for"
            masks = [
                int.from_bytes(data[at : at + 4], "little") for at in (54, 58, 62)
            ]
            assert masks == [0x00FF0000, 0x0000FF00, 0x000000FF]
            if header_size != 52:
                assert int.from_bytes(data[66:70], "little") == 0xFF000000, "alpha"
        else:
            assert compression == 0, "BI_RGB"
        if header_size in (108, 124):
            assert data[70:74] == b"BGRs", "LCS_sRGB, stored little-endian"

    assert planes == 1
    assert (width, height) == (2, 2)
    assert bits in (24, 32)
    assert len(data) - offset == (width * bits // 8 + 3) // 4 * 4 * height


def test_the_bmp_fixtures_are_one_per_documented_header_size() -> None:
    """The per-size tests below take their parameters from the fixture module,
    so a size that quietly left it would leave them green; this says it cannot.
    And the 40-byte one is the BMP every other image test already uses."""

    assert set(fixtures.BMP_BY_HEADER_SIZE) == DOCUMENTED_BMP_HEADER_SIZES
    assert set(fixtures.BMP_DIB_HEADER_SIZES) == DOCUMENTED_BMP_HEADER_SIZES
    assert fixtures.BMP_BY_HEADER_SIZE[40] == fixtures.BMP


def test_the_bm_near_misses_are_what_they_claim_to_be() -> None:
    """A refusal of these is only worth something if they really are this close.

    The text file is text and begins ``BM``.  The undefined-header BMP is the
    real BMP with the four bytes at offset 14 changed and nothing else -- and
    the value written there is not a size the format defines.  The BMP with a
    wrong file-size field is the real BMP with the four bytes at offset 2
    changed and nothing else.
    """

    text = fixtures.TEXT_BEGINNING_BM
    assert text[:2] == b"BM"
    assert text.endswith(b"\n") and text[:-1].decode("ascii").isprintable()
    assert len(text) >= 18, "long enough to have a header-size field to read"
    assert int.from_bytes(text[14:18], "little") not in DOCUMENTED_BMP_HEADER_SIZES

    undefined = fixtures.BMP_DECLARING_AN_UNDEFINED_HEADER_SIZE
    assert undefined[:14] == fixtures.BMP[:14]
    assert undefined[18:] == fixtures.BMP[18:]
    assert int.from_bytes(undefined[14:18], "little") == 41
    assert 41 not in DOCUMENTED_BMP_HEADER_SIZES

    wrong_size = fixtures.BMP_WITH_A_WRONG_FILE_SIZE
    assert wrong_size[:2] == fixtures.BMP[:2]
    assert wrong_size[6:] == fixtures.BMP[6:]
    assert int.from_bytes(wrong_size[2:6], "little") != len(wrong_size)


@pytest.mark.parametrize(
    "name, data, magic, order, form, chunks",
    [
        ("webp", fixtures.WEBP, b"RIFF", "little", b"WEBP", [b"VP8L"]),
        ("avi", fixtures.AVI, b"RIFF", "little", b"AVI ", [b"LIST", b"LIST"]),
        (
            "wave",
            fixtures.NOT_MEDIA["wave"],
            b"RIFF",
            "little",
            b"WAVE",
            [b"fmt ", b"data"],
        ),
        (
            "rifx avi",
            fixtures.RIFX_AVI,
            b"RIFX",
            "big",
            b"AVI ",
            [b"LIST", b"LIST"],
        ),
    ],
)
def test_the_riff_fixtures_are_containers_that_add_up(
    name, data, magic, order, form, chunks
) -> None:
    """RIFF's size field and the chunk chain inside it both have to be right.

    Four are walked here, and the three that are not the WebP are the reason.
    The AVI and the WAVE open with the same four bytes as the WebP and carry a
    different form type, which is the only thing that tells a WebP from either
    of them.  The RIFX is the mirror of that on the video side: the same AVI in
    RIFF's big-endian form, so bytes 8-11 say ``AVI `` to the byte and the four
    in front of them do not say ``RIFF``.  A sniffer that read either half
    without the other would take one of these for the other, and a fixture that
    were not really a container of its own could not show that.
    """

    assert data[:4] == magic, name
    assert int.from_bytes(data[4:8], order) == len(data) - 8, name
    assert data[8:12] == form, name

    offset = 12
    walked = []
    while offset < len(data):
        kind = data[offset : offset + 4]
        size = int.from_bytes(data[offset + 4 : offset + 8], order)
        walked.append(kind)
        offset += 8 + size + (size % 2)
    assert offset == len(data), name
    assert walked == chunks, name


def test_the_rifx_avi_is_the_avi_with_nothing_but_its_byte_order_changed() -> None:
    """The near miss is only a near miss if it really is the same file.

    Same length, same form type, same chunk names -- and every size field
    reversed, which is what makes the four bytes at the front the whole of the
    difference the gateway sees.
    """

    avi, rifx = fixtures.AVI, fixtures.RIFX_AVI

    assert len(rifx) == len(avi)
    assert rifx[:4] == b"RIFX" and avi[:4] == b"RIFF"
    assert rifx[8:12] == avi[8:12] == b"AVI "
    assert rifx[4:8] == avi[4:8][::-1], "the container size is not byte-swapped"
    assert rifx != avi


def test_the_damaged_png_fixture_is_a_real_png_with_its_trap_bytes_gone() -> None:
    """The near miss is a near miss: four bytes right, the next four wrong.

    It is the repository's own PNG after a text-mode transfer, so what it
    proves is that ``\\r\\n\\x1a\\n`` is load-bearing -- and it can only prove
    that if the file it was made from really was a PNG.
    """

    real = fixtures.png_bytes()
    damaged = fixtures.NOT_MEDIA["png damaged in a text-mode transfer"]

    assert real[:8] == b"\x89PNG\r\n\x1a\n"
    assert damaged[:4] == real[:4]
    assert damaged[:8] != real[:8]
    assert damaged[:8] == b"\x89PNG\n\x1a\n" + real[8:9]
    assert b"\r\n" not in damaged


@pytest.mark.parametrize(
    "name, data, brands",
    [
        ("heic", fixtures.HEIC, [b"heic", b"mif1", b"heic", b"miaf", b"MiHB"]),
        ("heif", fixtures.HEIF, [b"mif1", b"mif1", b"miaf", b"MiHB"]),
        ("avif", fixtures.AVIF, [b"avif", b"avif", b"mif1", b"miaf"]),
        ("mp4", fixtures.MP4, [b"isom", b"isom", b"iso2", b"avc1", b"mp41"]),
        ("mov", fixtures.MOV, [b"qt  ", b"qt  "]),
        ("3gp", fixtures.THREE_GP, [b"3gp4", b"3gp4", b"3gp5", b"isom", b"mp41"]),
        (
            "heif sequence",
            fixtures.HEIF_SEQUENCE,
            [b"msf1", b"msf1", b"iso8", b"hevc", b"mif1"],
        ),
        ("3gpp2", fixtures.THREE_GPP2, [b"3g2a", b"3g2a"]),
        ("m4v", fixtures.M4V, [b"M4V ", b"M4V ", b"M4A ", b"mp42", b"isom"]),
    ]
    + [
        (
            "mp4 " + brand.decode("ascii"),
            fixtures.MP4_BY_ADDED_BRAND[brand],
            [brand, brand, b"isom"],
        )
        for brand in (b"mp4v", b"iso3", b"iso7", b"iso9", b"isoa")
    ]
    + [
        (
            "heif brand " + brand.decode("ascii"),
            fixtures.HEIF_BY_BRAND[brand],
            [brand, brand, b"mif1", b"miaf"],
        )
        for brand in fixtures.HEIF_IMAGE_BRANDS
    ],
)
def test_the_isobmff_fixtures_are_real_box_chains(name, data, brands) -> None:
    """Walked box by box, by the sizes the boxes declare.

    ISO base media is nothing but a chain of length-prefixed boxes, so a chain
    that arrives exactly at the end of the file is a real one -- and the brands
    the sniffer decides on are read here out of the ``ftyp`` box's own layout
    rather than taken from the fixture module.
    """

    offset, boxes = 0, []
    while offset < len(data):
        size = int.from_bytes(data[offset : offset + 4], "big")
        assert size >= 8, (name, offset, size)
        boxes.append(data[offset + 4 : offset + 8])
        offset += size
    assert offset == len(data), name
    assert boxes[0] == b"ftyp", name

    ftyp = int.from_bytes(data[0:4], "big")
    declared = [data[8:12]] + [
        data[start : start + 4] for start in range(16, ftyp, 4)
    ]
    assert declared == brands, name

    if name in ("heic", "heif", "avif", "heif sequence") or name.startswith(
        "heif brand "
    ):
        assert b"meta" in boxes, name
        assert b"pict" in data, name


@pytest.mark.parametrize(
    "name, data, top_level",
    [
        (
            "moov first",
            fixtures.QUICKTIME_WITHOUT_FTYP_MOOV_FIRST,
            [b"moov", b"mdat"],
        ),
        (
            "wide first",
            fixtures.QUICKTIME_WITHOUT_FTYP_WIDE_FIRST,
            [b"wide", b"mdat", b"moov"],
        ),
    ],
)
def test_the_legacy_quicktime_fixtures_are_movies_with_no_ftyp(
    name, data, top_level
) -> None:
    """Walked box by box, and into the movie box, by the sizes they declare.

    What they are here to show is an absence -- no ``ftyp`` anywhere -- so the
    walk first proves there is a movie to be absent from: a ``moov`` holding a
    100-byte version-0 ``mvhd`` whose time scale, duration, rate and matrix
    are read back out of its layout.
    """

    offset, boxes, moov = 0, [], None
    while offset < len(data):
        size = int.from_bytes(data[offset : offset + 4], "big")
        assert size >= 8, (name, offset, size)
        kind = data[offset + 4 : offset + 8]
        boxes.append(kind)
        if kind == b"moov":
            moov = data[offset + 8 : offset + size]
        offset += size
    assert offset == len(data), name
    assert boxes == top_level, name
    assert b"ftyp" not in data, name

    assert int.from_bytes(moov[0:4], "big") == len(moov) == 108, name
    assert moov[4:8] == b"mvhd", name
    mvhd = moov[8:]
    assert mvhd[0] == 0, "version 0"
    assert int.from_bytes(mvhd[12:16], "big") == 600, "time scale"
    assert int.from_bytes(mvhd[16:20], "big") == 600, "one second"
    assert int.from_bytes(mvhd[20:24], "big") == 0x10000, "rate 1.0"
    assert int.from_bytes(mvhd[36:40], "big") == 0x10000, "matrix a = 1.0"
    assert int.from_bytes(mvhd[68:72], "big") == 0x40000000, "matrix w = 1.0"
    assert int.from_bytes(mvhd[96:100], "big") == 2, "next track id"


def walk_ebml(data: bytes, start: int, end: int, found: dict) -> int:
    """Walk one run of EBML elements, recording every (id, payload) pair.

    Written from EBML's own definition and independently of ``media.py``: the
    element id and the size are variable-length integers whose first byte's
    leading zeroes count the bytes after it, and an element's payload is
    followed immediately by the next element.  A document whose sizes do not add
    up therefore fails to arrive at ``end``, which is what the callers assert.
    """

    offset = start
    while offset < end:
        first = data[offset]
        assert first, (offset, "a zero first byte is not a valid EBML number")
        id_length = 9 - first.bit_length()
        identifier = data[offset : offset + id_length]
        offset += id_length

        first = data[offset]
        assert first, (offset, "a zero first byte is not a valid EBML size")
        size_length = 9 - first.bit_length()
        size = first & (0xFF >> size_length)
        for byte in data[offset + 1 : offset + size_length]:
            size = (size << 8) | byte
        offset += size_length

        assert offset + size <= end, (identifier, offset, size, end)
        found.setdefault(identifier, []).append((offset, data[offset : offset + size]))
        if identifier in (b"\x1aE\xdf\xa3", b"\x18S\x80\x67", b"\x15\x49\xa9\x66"):
            walk_ebml(data, offset, offset + size, found)
        offset += size
    return offset


@pytest.mark.parametrize(
    "name, data, doctype",
    [
        ("webm", fixtures.WEBM, b"webm"),
        ("matroska", fixtures.MATROSKA, b"matroska"),
        (
            "doctype that only begins with webm",
            fixtures.EBML_DOCTYPE_THAT_ONLY_BEGINS_WITH_WEBM,
            b"webm2",
        ),
        (
            "doctype past the peek",
            fixtures.MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK,
            b"matroska",
        ),
    ],
)
def test_the_ebml_fixtures_are_documents_whose_elements_add_up(
    name, data, doctype
) -> None:
    """Walked element by element, by the sizes the elements declare.

    All four carry the same four magic bytes, which is exactly why the walk
    matters: what distinguishes them is inside the header, and a fixture that
    were four magic bytes followed by filler could not show that.  The Segment
    and its Info element are walked into as well, so the document is a document
    rather than a header on its own.
    """

    found: dict = {}
    assert walk_ebml(data, 0, len(data), found) == len(data), name

    assert len(found[b"\x1aE\xdf\xa3"]) == 1, name  # the EBML header
    assert len(found[b"\x18S\x80\x67"]) == 1, name  # the Segment
    assert len(found[b"\x42\x82"]) == 1, name  # exactly one DocType
    assert found[b"\x42\x82"][0][1] == doctype, name

    assert found[b"\x42\xf2"][0][1] == b"\x04", name  # EBMLMaxIDLength
    assert found[b"\x2a\xd7\xb1"][0][1] == (1000000).to_bytes(3, "big"), name
    assert found[b"\x57\x41"][0][1] == b"LocalCanvas", name  # WritingApp


def test_the_short_header_ebml_fixture_puts_its_doctype_inside_the_peek() -> None:
    """The DocType walk stops at two bounds, and this fixture is the second one.

    ``MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK`` is about :data:`SNIFF_BYTES`.
    This one is about the header's **own declared size**: the DocType is at
    byte 13, comfortably inside the peek, and outside the header that is
    supposed to contain it.  A walk that ran to the end of what it held rather
    than to the end of the header would read a ``DocType`` this document does
    not declare -- so unless the fixture really is shaped this way, the refusal
    it earns proves nothing.
    """

    data = fixtures.EBML_DECLARING_LESS_THAN_IT_HOLDS

    assert data[:4] == fixtures.WEBM[:4], "it has to be EBML at all"
    size_byte = data[4]
    assert size_byte & 0x80, "the header's size is one byte here"
    declared_end = 5 + (size_byte & 0x7F)

    assert declared_end == 13
    assert data[declared_end : declared_end + 2] == b"\x42\x82", (
        "the DocType has to be the element immediately past the declared end"
    )
    assert data[declared_end + 3 : declared_end + 7] == b"webm"
    assert declared_end + 7 <= SNIFF_BYTES, "and it has to be inside the peek"


def test_the_mpeg_near_misses_are_the_fixtures_own_end_codes() -> None:
    """Each is the last four bytes of a real stream, and nothing typed.

    A start code is ``00 00 01`` and then the byte that says which one it is.
    These two are the codes that *end* a stream -- the sequence end code of the
    elementary stream and the ISO 11172 end code of the program stream -- so a
    sniffer that matched three bytes would call a file that begins with the end
    of a film a film.
    """

    sequence_end = fixtures.MPEG_SEQUENCE_END_ALONE
    program_end = fixtures.MPEG_PROGRAM_END_ALONE

    assert sequence_end[:4] == fixtures.MPEG_ELEMENTARY_STREAM[-4:]
    assert program_end[:4] == fixtures.MPEG_PROGRAM_STREAM[-4:]
    assert sequence_end[:3] == program_end[:3] == b"\x00\x00\x01"
    assert (sequence_end[3], program_end[3]) == (0xB7, 0xB9)
    # And they are not the codes the sniffer answers to, which is the point.
    assert sequence_end[:4] not in (
        fixtures.MPEG_ELEMENTARY_STREAM[:4],
        fixtures.MPEG_PROGRAM_STREAM[:4],
    )
    assert program_end[:4] not in (
        fixtures.MPEG_ELEMENTARY_STREAM[:4],
        fixtures.MPEG_PROGRAM_STREAM[:4],
    )


def start_codes(data: bytes):
    """Every MPEG start code in a stream, as (offset, identifier) pairs.

    ``00 00 01`` and the byte after it.  The fixtures carry no zero byte in
    their filler, so a start code found here is a start code that was written,
    not one that a payload happened to spell.
    """

    return [
        (at, data[at + 3])
        for at in range(len(data) - 3)
        if data[at : at + 3] == b"\x00\x00\x01"
    ]


def test_the_mpeg_elementary_stream_fixture_is_a_real_sequence_of_headers() -> None:
    """ISO 11172-2's layout, read back out of the bits it was written into.

    The picture size and the frame rate are 12- and 4-bit fields inside the
    sequence header, so reading them back is arithmetic over the whole header
    rather than a look at its first bytes -- and the start codes that follow are
    where the previous header's own width put them.
    """

    data = fixtures.MPEG_ELEMENTARY_STREAM
    codes = start_codes(data)

    assert [identifier for _, identifier in codes] == [0xB3, 0xB8, 0x00, 0x01, 0xB7]
    assert codes[0][0] == 0
    assert codes[-1][0] == len(data) - 4, "the sequence end code is not at the end"

    header = int.from_bytes(data[4:12], "big")
    assert header >> (64 - 12) == 320  # horizontal size
    assert (header >> (64 - 24)) & 0xFFF == 240  # vertical size
    assert (header >> (64 - 28)) & 0xF == 1  # square pixels
    assert (header >> (64 - 32)) & 0xF == 3  # 25 frames per second
    assert (header >> (64 - 51)) & 1 == 1, "the marker bit after the bit rate"

    # The GOP header's own marker bit, in the middle of its 25-bit time code.
    group = int.from_bytes(data[16:20], "big")
    assert (group >> (32 - 13)) & 1 == 1
    assert (group >> (32 - 26)) & 1 == 1, "closed GOP"


def test_the_mpeg_program_stream_fixture_carries_that_elementary_stream() -> None:
    """The pack, the system header and the PES packet, walked by their lengths.

    Only the pack header has a fixed length; the two after it declare their own,
    so a walk that arrives exactly at the end code has followed real numbers.
    The PES packet's payload is compared with the elementary stream fixture, so
    the two are one file and not two unrelated byte strings.
    """

    data = fixtures.MPEG_PROGRAM_STREAM
    assert data[:4] == b"\x00\x00\x01\xba"

    pack = int.from_bytes(data[4:12], "big")
    assert pack >> 60 == 0b0010, "the pack header's own four-bit prefix"
    assert (pack >> (64 - 8)) & 1 == 1, "a marker bit inside the clock reference"
    assert (pack >> 1) & 0x3FFFFF == 3528, "mux rate"
    assert pack & 1 == 1, "the marker bit after the mux rate"

    offset = 12
    assert data[offset : offset + 4] == b"\x00\x00\x01\xbb"
    system_length = int.from_bytes(data[offset + 4 : offset + 6], "big")
    system = data[offset + 6 : offset + 6 + system_length]
    assert system[6] == 0xE0, "the system header names video stream 0"
    offset += 6 + system_length

    assert data[offset : offset + 4] == b"\x00\x00\x01\xe0"
    pes_length = int.from_bytes(data[offset + 4 : offset + 6], "big")
    pes = data[offset + 6 : offset + 6 + pes_length]
    assert pes[0] == 0x0F, "no PTS and no DTS on this packet"
    assert pes[1:] == fixtures.MPEG_ELEMENTARY_STREAM
    offset += 6 + pes_length

    assert data[offset:] == b"\x00\x00\x01\xb9"
    assert offset + 4 == len(data)


def test_the_transport_stream_fixture_is_a_real_packet_grid_with_valid_crcs() -> None:
    """The file that decides ``video/mpeg``, proved to be what it claims.

    Three things are checked and none of them is a magic number: the packet grid
    (``0x47`` every 188 bytes, which is the only thing a transport stream has
    instead of a signature), the CRC-32 on each of the two sections, recomputed
    here over the bytes walked, and the cross-references -- the program
    association table names the PID the program map is on, and the program map
    names the PID the video is on.

    This fixture exists to be **refused**, so it is the one that most needs to be
    real: a refusal of a plausible prefix followed by zeros would prove nothing
    about a refusal of somebody's camcorder file.
    """

    data = fixtures.TRANSPORT_STREAM
    size = fixtures.TS_PACKET_BYTES
    assert len(data) % size == 0
    packets = [data[at : at + size] for at in range(0, len(data), size)]
    assert len(packets) == 3

    read = []
    for index, packet in enumerate(packets):
        assert packet[0] == 0x47, index
        word = int.from_bytes(packet[1:3], "big")
        assert word & 0x8000 == 0, "no transport error"
        assert word & 0x4000, "every packet here starts a payload unit"
        assert packet[3] & 0x30 == 0x10, "payload only, no adaptation field"
        assert packet[3] & 0x0F == 0, "continuity counter"
        read.append((word & 0x1FFF, packet[4:]))

    def section_of(payload: bytes):
        pointer = payload[0]
        body = payload[1 + pointer :]
        length = int.from_bytes(body[1:3], "big") & 0x0FFF
        section = body[: 3 + length]
        assert body[1] & 0x80, "a section with a syntax section carries a CRC"
        recorded = int.from_bytes(section[-4:], "big")
        assert fixtures.mpeg_crc32(section[:-4]) == recorded, "section CRC"
        return section

    pat_pid, pat_payload = read[0]
    assert pat_pid == fixtures.TS_PAT_PID
    pat = section_of(pat_payload)
    assert pat[0] == 0x00, "table_id 0: a program association table"
    assert int.from_bytes(pat[8:10], "big") == 1, "program number"
    assert int.from_bytes(pat[10:12], "big") & 0x1FFF == read[1][0]

    pmt_pid, pmt_payload = read[1]
    assert pmt_pid == fixtures.TS_PMT_PID
    pmt = section_of(pmt_payload)
    assert pmt[0] == 0x02, "table_id 2: a program map table"
    assert int.from_bytes(pmt[8:10], "big") & 0x1FFF == read[2][0], "PCR PID"
    assert int.from_bytes(pmt[10:12], "big") & 0x0FFF == 0, "no program info"
    assert pmt[12] == fixtures.TS_STREAM_TYPE_MPEG1_VIDEO
    assert int.from_bytes(pmt[13:15], "big") & 0x1FFF == read[2][0]
    assert int.from_bytes(pmt[15:17], "big") & 0x0FFF == 0, "no stream info"

    video_pid, video_payload = read[2]
    assert video_pid == fixtures.TS_VIDEO_PID
    assert video_payload[:4] == b"\x00\x00\x01\xe0", "a PES packet for a video stream"
    # And the packet carries the elementary stream itself, which is the
    # assertion the program stream's walker makes about its own PES packet: a
    # PES header in front of filler would be a header in front of filler.
    declared = int.from_bytes(video_payload[4:6], "big")
    assert declared == len(video_payload) - 6, "the PES length must fill the packet"
    assert video_payload[6] == 0x0F, "no PTS and no DTS on this packet"
    elementary = video_payload[7:]
    assert elementary[: len(fixtures.MPEG_ELEMENTARY_STREAM)] == (
        fixtures.MPEG_ELEMENTARY_STREAM
    )
    assert set(elementary[len(fixtures.MPEG_ELEMENTARY_STREAM) :]) <= {0xFF}, (
        "everything after the stream is the multiplexer's stuffing"
    )


# ==========================================================================
# The measured table
# ==========================================================================

#: The seven requests measured against the live gateway, in the order they were
#: measured.  One JPEG body, seven labels: the first three were accepted -- one
#: of them writing ``.heic`` onto a JPEG -- and the last four were refused with
#: 415, which is what a person choosing a photograph on a phone ran into.
MEASURED_TABLE = [
    ("image/jpeg", "IMG_0142.jpg"),
    ("image/heic", "IMG_0142.heic"),
    ("image/heif", "IMG_0142.heif"),
    ("image/jpg", "IMG_0142.jpg"),
    ("application/octet-stream", "IMG_0142.jpg"),
    ("image/*", "IMG_0142.jpg"),
    (None, "IMG_0142.jpg"),
]


@pytest.mark.parametrize("declared, filename", MEASURED_TABLE)
def test_one_jpeg_is_accepted_however_the_picker_labelled_it(
    harness, declared, filename
) -> None:
    """The measured table, turned round: every row is a 201 now.

    Including the row with no ``Content-Type`` header at all, which is what an
    Android picker sends when it will not say what it is handing over.
    """

    response = post(harness, fixtures.JPEG, filename=filename, declared=declared)

    assert response.status_code == 201, (declared, response.text)
    body = response.json()
    assert body["kind"] == "image"
    assert body["filename"] == filename
    assert body["bytes"] == len(fixtures.JPEG)


@pytest.mark.parametrize("declared, filename", MEASURED_TABLE)
def test_the_extension_describes_the_bytes_whatever_the_label_said(
    harness, declared, filename
) -> None:
    """Accepting it is half the answer; storing it as what it is, the other.

    Two rows of the table declare HEIC and HEIF over a JPEG body, and one names
    the file ``.heic``.  Before this, the gateway believed all three and wrote
    ``.heic`` onto a JPEG -- so this is the half that is *stricter* than what it
    replaced, not the half that is more permissive.
    """

    item = stored(
        harness, post(harness, fixtures.JPEG, filename=filename, declared=declared)
    )

    assert item.content_type == "image/jpeg"
    assert item.path.suffix == ".jpg"
    assert item.comfy_upload_name.endswith(".jpg")
    # And the body that was written is the body that was sent: the head the
    # sniff peeked at is written like the rest of it, not consumed by looking.
    assert item.path.read_bytes() == fixtures.JPEG


@pytest.mark.parametrize(
    "declared",
    ["image/png", "image/heic", "application/octet-stream", "video/mp4", None],
)
def test_the_declared_type_never_decides_when_it_disagrees_with_the_file(
    harness, declared
) -> None:
    """A client may say anything; what is written is what arrived.

    The old behaviour is the exact opposite of this test: a body declared
    ``image/png`` was written with ``.png`` on the end whatever it contained.
    """

    item = stored(
        harness, post(harness, fixtures.JPEG, filename="whatever.png", declared=declared)
    )

    assert item.content_type == "image/jpeg"
    assert item.path.suffix == ".jpg"


# ==========================================================================
# Every format in the closed set, and nothing outside it
# ==========================================================================


def image_fixtures():
    """One real container per entry of ``ALLOWED_TYPES["image"]``, named.

    Named because an unnamed one puts the whole fixture in the test id, and a
    failure nobody can read is a failure nobody acts on.

    HEIC and HEIF are not here: they left the closed set (T-0127), and their
    fixtures now prove the refusal instead -- :func:`heic_fixtures`.
    """

    return [
        pytest.param(expected, extension, data, id=label)
        for label, expected, extension, data in [
            ("jpeg", "image/jpeg", ".jpg", fixtures.JPEG),
            ("png", "image/png", ".png", fixtures.png_bytes()),
            ("gif89a", "image/gif", ".gif", fixtures.GIF89A),
            ("gif87a", "image/gif", ".gif", fixtures.GIF87A),
            ("bmp", "image/bmp", ".bmp", fixtures.BMP),
            ("webp", "image/webp", ".webp", fixtures.WEBP),
        ]
    ]


def test_the_image_fixtures_cover_every_entry_of_the_closed_set() -> None:
    """The docstring above claims its own completeness, so this asserts it.

    Three tests take their whole coverage from ``image_fixtures()`` -- the
    sniffer on its own, the upload sent undeclared, and the head delivered four
    bytes at a time.  A type added to ``ALLOWED_TYPES["image"]`` without a
    fixture, or a fixture row quietly dropped from the list, left all three
    green while covering one format fewer: a review of T-0126 dropped the
    WebP row and every test in the media selection still passed (T-0137).

    Compared with the imported ``ALLOWED_TYPES`` itself rather than with a copy
    of its keys, so a set that is emptied or renamed fails here instead of two
    empty sets agreeing.  The video half has the same guard.
    """

    covered = {parameter.values[0] for parameter in image_fixtures()}

    assert covered == set(ALLOWED_TYPES["image"])


@pytest.mark.parametrize("expected, extension, data", image_fixtures())
def test_every_image_in_the_closed_set_is_recognised_from_its_head(
    expected, extension, data
) -> None:
    """The sniffer alone, on real containers, with no HTTP in the way."""

    assert sniff_image_type(data) == expected
    assert ALLOWED_TYPES["image"][expected] == extension


@pytest.mark.parametrize("expected, extension, data", image_fixtures())
def test_every_image_in_the_closed_set_survives_the_upload_undeclared(
    harness, expected, extension, data
) -> None:
    """And the same formats through the endpoint, sent the way a picker sends.

    ``application/octet-stream`` and a filename that says nothing: every one of
    these is refused outright by a gateway that believes the label.
    """

    item = stored(
        harness,
        post(harness, data, filename="download", declared="application/octet-stream"),
    )

    assert item.content_type == expected
    assert item.path.suffix == extension
    assert item.bytes == len(data)


#: A delivery narrower than every signature the sniffer reads except JPEG's
#: three-byte marker.
#: The store promises to *accumulate* until it holds :data:`SNIFF_BYTES`, and
#: nothing else in this suite makes it keep that promise: every other caller
#: hands it one chunk at least as long as the whole file, so the peek is
#: satisfied by the first chunk and the loop inside ``_peeked`` never runs
#: twice.
TRICKLE_BYTES = 4


@pytest.mark.parametrize("expected, extension, data", image_fixtures())
def test_a_head_split_across_chunks_is_still_identified(
    tmp_path, expected, extension, data
) -> None:
    """The same formats, handed over four bytes at a time.

    This is where :data:`SNIFF_BYTES` earns its value.  The peek is what the
    store is allowed to look at before it commits to an extension, and a peek
    shorter than a signature identifies nothing: a WebP's form type ends at
    byte 12, an ISO-BMFF major brand at byte 12 and a BMP's DIB header size at
    byte 18 (the ISO-BMFF case now lives in
    :func:`test_a_heic_head_split_across_chunks_is_still_refused_by_name`, since
    HEIC left the closed set), so a store that asked for
    four bytes and got them would refuse a real photograph from a real phone --
    which is this defect over again rather than a different one.  Because the
    parameters are ``image_fixtures()``, a signature added later that reads
    past ``SNIFF_BYTES`` fails here too, without anyone remembering to raise a
    number.

    The stored file is compared to the body byte for byte, so a peek that ate
    the head instead of writing it fails here as well.
    """

    store = MediaStore(tmp_path / "store")

    item = store.store(
        kind="image",
        filename="download",
        content_type="application/octet-stream",
        chunks=iter(
            [data[at : at + TRICKLE_BYTES] for at in range(0, len(data), TRICKLE_BYTES)]
        ),
    )

    assert item.content_type == expected
    assert item.path.suffix == extension
    assert item.bytes == len(data)
    assert item.path.read_bytes() == data


# ==========================================================================
# HEIC and HEIF: identified by their bytes, and refused by name (T-0127)
#
# A HEIC photograph is the default camera format on a great many phones, and a
# ComfyUI install may or may not be able to read one -- that depends on an
# optional package the gateway cannot see.  Accepting it meant the user picked
# a photo, waited, and got a generation failure that said nothing about the
# format.  So the two types left ``ALLOWED_TYPES`` and are refused at upload,
# before anything is written or queued, with a code of their own and a message
# that says what to do instead.
# ==========================================================================

#: The whole refusal body, verbatim.  Written out rather than imported from the
#: gateway, so a sentence that drifted is caught here instead of agreed with.
HEIC_REFUSAL = {
    "error": {
        "code": "unsupported_image_heic",
        "message": (
            "That photo is in HEIC/HEIF format, which LocalCanvas cannot use "
            "yet. Choose a JPEG or PNG, or turn off high-efficiency (HEIC) "
            "photos in the camera settings."
        ),
        "field": "file",
    }
}


def heic_fixtures():
    """A real HEIC and a real HEIF container, named, with the type each *is*."""

    return [
        pytest.param(expected, data, id=label)
        for label, expected, data in [
            ("heic", "image/heic", fixtures.HEIC),
            ("heif", "image/heif", fixtures.HEIF),
        ]
    ]


def test_the_heic_fixtures_cover_every_named_refusal() -> None:
    """The image-fixture pin's twin: every type refused by name has a fixture.

    Compared with the imported ``NAMED_IMAGE_REFUSALS`` itself, so a type
    added there without a fixture -- or a fixture row quietly dropped -- fails
    here instead of leaving the refusal tests one format short.
    """

    covered = {parameter.values[0] for parameter in heic_fixtures()}

    assert covered == set(NAMED_IMAGE_REFUSALS)


@pytest.mark.parametrize("expected, data", heic_fixtures())
def test_heic_and_heif_are_still_identified_and_are_outside_the_closed_set(
    expected, data
) -> None:
    """The sniffer still knows them -- that is how the refusal can name them.

    A sniffer that forgot the brands would refuse them too, but with the
    generic code, and the person holding the phone would learn nothing.
    """

    assert sniff_image_type(data) == expected
    assert expected not in ALLOWED_TYPES["image"]
    assert expected not in ALLOWED_TYPES["video"]


@pytest.mark.parametrize(
    "declared, filename",
    [
        ("image/heic", "IMG_0142.heic"),
        ("image/heif", "IMG_0142.heif"),
        ("image/jpeg", "IMG_0142.jpg"),
        ("application/octet-stream", "download"),
        (None, "IMG_0142.jpg"),
    ],
)
@pytest.mark.parametrize("expected, data", heic_fixtures())
def test_a_heic_or_heif_photo_is_refused_at_upload_with_its_own_code(
    harness, expected, data, declared, filename
) -> None:
    """Refused on its bytes, whatever the picker called it, and nothing kept.

    The rows labelled ``image/jpeg`` and named ``.jpg``, and the undeclared
    ones, are the point: a refusal that believed the label would let those
    through, and a phone's picker sends exactly those labels.  Nothing reaches
    the store, nothing reaches ComfyUI's input directory, nothing is queued.
    """

    response = post(harness, data, filename=filename, declared=declared)

    assert response.status_code == 415, (expected, declared, response.text)
    assert response.json() == HEIC_REFUSAL, (expected, declared)
    assert files_under(harness.state.media.root) == []
    assert len(harness.state.media) == 0
    assert harness.fake.uploads == []
    assert harness.fake.submissions == []


#: Every HEIC and HEIF major brand, with the type it is -- written out here, not
#: read off the gateway, so a brand dropped from or remapped in
#: ``_ISOBMFF_IMAGE_BRANDS`` is a disagreement rather than a smaller loop.
HEIF_BRAND_TYPES = {
    b"heic": "image/heic",
    b"heix": "image/heic",
    b"heim": "image/heic",
    b"heis": "image/heic",
    b"hevc": "image/heic",
    b"hevx": "image/heic",
    b"hevm": "image/heic",
    b"hevs": "image/heic",
    b"mif1": "image/heif",
    b"mif2": "image/heif",
    b"msf1": "image/heif",
}


def test_every_image_brand_the_sniffer_knows_is_one_this_file_tests() -> None:
    """The brand list below is the gateway's table, neither more nor less.

    Compared with the imported table itself, so a brand added to it without a
    row here -- or dropped from it -- fails by name instead of leaving the
    per-brand refusal one brand short, and the fixture module is held to the
    same list.
    """

    assert dict(_ISOBMFF_IMAGE_BRANDS) == HEIF_BRAND_TYPES
    assert set(fixtures.HEIF_BY_BRAND) == set(HEIF_BRAND_TYPES)


@pytest.mark.parametrize("declared", [None, "image/jpeg"], ids=["undeclared", "image-jpeg"])
@pytest.mark.parametrize(
    "brand, expected",
    [
        pytest.param(brand, expected, id=brand.decode("ascii"))
        for brand, expected in HEIF_BRAND_TYPES.items()
    ],
)
def test_every_heif_image_brand_is_refused_by_name(
    harness, brand, expected, declared
) -> None:
    """Each major brand a phone may write, refused with the sentence of its own.

    Since T-0127 the brand is what decides whether a person reads the
    actionable sentence or the generic one, so every brand is sent: a brand the
    sniffer forgot would still be refused, but as ``unsupported_media_type``,
    and nothing about the photo's format would reach the person holding it.
    """

    data = fixtures.HEIF_BY_BRAND[brand]
    assert sniff_image_type(data) == expected

    response = post(harness, data, filename="IMG_0142.jpg", declared=declared)

    assert response.status_code == 415, (brand, declared, response.text)
    assert response.json() == HEIC_REFUSAL, (brand, declared)
    assert files_under(harness.state.media.root) == []
    assert len(harness.state.media) == 0
    assert harness.fake.uploads == []
    assert harness.fake.submissions == []


def test_a_jpeg_labelled_heic_is_still_accepted_as_the_jpeg_it_is(harness) -> None:
    """Content wins in the other direction too: the label is not the refusal."""

    for declared, filename in (
        ("image/heic", "IMG_0142.heic"),
        ("image/heif", "IMG_0142.heif"),
    ):
        item = stored(
            harness, post(harness, fixtures.JPEG, filename=filename, declared=declared)
        )
        assert item.content_type == "image/jpeg"
        assert item.path.suffix == ".jpg"
        assert item.path.read_bytes() == fixtures.JPEG


@pytest.mark.parametrize("expected, data", heic_fixtures())
def test_a_heic_head_split_across_chunks_is_still_refused_by_name(
    tmp_path, expected, data
) -> None:
    """Four bytes at a time, straight into the store.

    This keeps the ISO-BMFF half of what
    :func:`test_a_head_split_across_chunks_is_still_identified` used to pin:
    the major brand ends at byte 12, so a peek too short to reach it could not
    name the format, and the refusal would fall back to the generic code.
    """

    store = MediaStore(tmp_path / "store")

    with pytest.raises(MediaRejected) as refused:
        store.store(
            kind="image",
            filename="download",
            content_type="application/octet-stream",
            chunks=iter(
                [
                    data[at : at + TRICKLE_BYTES]
                    for at in range(0, len(data), TRICKLE_BYTES)
                ]
            ),
        )

    assert refused.value.status_code == 415
    assert refused.value.code == "unsupported_image_heic"
    assert refused.value.field == "file"
    assert len(store) == 0
    assert files_under(tmp_path / "store") == []


@pytest.mark.parametrize("expected, data", heic_fixtures())
def test_a_heic_sent_as_a_video_keeps_the_generic_refusal(
    harness, expected, data
) -> None:
    """The video kind never identified a photograph, and still does not.

    The named refusal is about a photo chosen for an image field; a HEIC sent
    as a clip is simply not a video, as it was before.
    """

    response = post(harness, data, filename="clip.mp4", declared="video/mp4", kind="video")

    assert response.status_code == 415, expected
    assert error_of(response)["code"] == "unsupported_media_type", expected
    assert files_under(harness.state.media.root) == [], expected


@pytest.mark.parametrize(
    "header_size",
    [pytest.param(size, id="dib-{}".format(size)) for size in fixtures.BMP_DIB_HEADER_SIZES],
)
def test_a_bmp_of_every_documented_header_size_is_identified(
    harness, header_size
) -> None:
    """``BM`` is a BMP when its DIB header size is one the format defines.

    Every one of the eight, by the sniffer and through the endpoint sent the way
    a picker sends -- because a BMP check that knew only the common 40-byte
    header would refuse a real picture written with a V5 header, which is the
    defect T-0126 existed to remove rather than a different one.
    """

    data = fixtures.BMP_BY_HEADER_SIZE[header_size]

    assert sniff_image_type(data) == "image/bmp"

    item = stored(
        harness,
        post(harness, data, filename="download", declared="application/octet-stream"),
    )
    assert item.content_type == "image/bmp"
    assert item.path.suffix == ".bmp"
    assert item.path.read_bytes() == data


@pytest.mark.parametrize(
    "name, data",
    [
        pytest.param("text beginning bm", fixtures.TEXT_BEGINNING_BM, id="text"),
        pytest.param(
            "bmp declaring a 41-byte header",
            fixtures.BMP_DECLARING_AN_UNDEFINED_HEADER_SIZE,
            id="dib-41",
        ),
        pytest.param(
            "bmp declaring a zero-byte header",
            fixtures.BMP[:14] + (0).to_bytes(4, "little") + fixtures.BMP[18:],
            id="dib-0",
        ),
        pytest.param(
            "a real bmp cut off before its header size is whole",
            fixtures.BMP[:17],
            id="truncated-at-17",
        ),
    ],
)
def test_bm_alone_is_not_a_bmp(name, data) -> None:
    """Two ASCII letters begin plenty of files that are not pictures.

    Each of these begins ``BM``, and none of them carries a DIB header size the
    format defines -- the last one because it stops before the four bytes that
    would say, although the three it does have are the real BMP's.
    """

    assert data[:2] == b"BM", name
    assert sniff_image_type(data) is None, name


def test_the_text_file_once_stored_as_a_bmp_is_refused(harness) -> None:
    """The review's measurement, turned round.

    A text file beginning ``BM`` was accepted and written into ComfyUI's input
    directory as ``.bmp`` with the type ``image/bmp``.  It is refused now, with
    the documented error, and nothing is stored.  The same request with a real
    BMP body is accepted first, so the refusal is the body's and not the
    request's.
    """

    accepted = post(harness, fixtures.BMP, filename="notes.bmp", declared="image/bmp")
    assert accepted.status_code == 201, accepted.text
    assert len(files_under(harness.state.media.root)) == 1

    response = post(
        harness, fixtures.TEXT_BEGINNING_BM, filename="notes.bmp", declared="image/bmp"
    )

    assert response.status_code == 415, response.text
    assert response.json() == {
        "error": {
            "code": "unsupported_media_type",
            "message": "That file format cannot be used as an image.",
            "field": "file",
        }
    }
    assert len(files_under(harness.state.media.root)) == 1, "only the real BMP"


def test_a_bmp_whose_file_size_field_is_wrong_is_still_a_bmp(harness) -> None:
    """The file-size field at offset 2 is not read, deliberately.

    Some encoders write it wrong, and a real picture refused for a field no
    decoder needs is the defect T-0126 removed.  The header size is the
    structure that is checked; this is the field that is not.
    """

    data = fixtures.BMP_WITH_A_WRONG_FILE_SIZE
    assert int.from_bytes(data[2:6], "little") != len(data)

    assert sniff_image_type(data) == "image/bmp"
    item = stored(harness, post(harness, data, filename="scan.bmp", declared=None))
    assert item.path.suffix == ".bmp"


def test_a_files_major_brand_decides_and_its_compatible_brands_do_not() -> None:
    """Which brand of an ``ftyp`` box is believed, pinned from both sides.

    A ``mif1``-major file that names ``heic`` further down its list is identified
    as what it says it primarily is, not as the first brand a scan happens to
    recognise.  Neither is stored any more (T-0127): the answer decides which
    type the refusal names, and :func:`test_every_heif_image_brand_is_refused_by_name`
    covers that for every brand.  The AVIF is the same rule with the cost on the other foot: a
    real still image, ``mif1`` among its own compatible brands, and outside the
    closed set -- so a sniffer that scanned the list would write it into
    ComfyUI's input directory as ``.heif``, and this one does not know it.
    """

    assert sniff_image_type(fixtures.HEIF_WITH_HEIC_COMPATIBLE) == "image/heif"
    assert sniff_image_type(fixtures.AVIF) is None
    assert b"mif1" in fixtures.AVIF[:32], "the AVIF fixture must carry the temptation"


@pytest.mark.parametrize(
    "name, data",
    [
        pytest.param(name, data, id=name.replace(" ", "-"))
        for name, data in sorted(fixtures.NOT_MEDIA.items())
        + [
            ("avif", fixtures.AVIF),
            ("mp4", fixtures.MP4),
            ("quicktime", fixtures.MOV),
        ]
    ],
)
def test_a_file_outside_the_closed_set_is_refused_however_it_is_declared(
    harness, name, data
) -> None:
    """The set does not widen because the decision moved to the bytes.

    The three at the end matter most.  An AVIF is a real still image, an MP4 and
    a MOV are real ISO base media files, and all three open with ``ftyp`` just
    as a HEIC does -- so a sniffer that recognised the container instead of the
    brand would write a video into ComfyUI's input directory under ``.heic``.
    They are refused, and refused for the honest reason: they are not in the
    list of what this gateway stores.
    """

    # Declared as an image and declared as nothing: the two labels that decided
    # this before, neither of which decides it now.
    for declared in ("image/jpeg", None):
        response = post(harness, data, filename="thing.jpg", declared=declared)

        error = error_of(response)
        assert response.status_code == 415, (name, declared)
        assert error["code"] == "unsupported_media_type", (name, declared)
        assert error["field"] == "file", (name, declared)
        assert files_under(harness.state.media.root) == [], (name, declared)


def test_a_video_uploaded_as_an_image_is_refused_on_what_the_bytes_say(
    harness,
) -> None:
    """The kind and the file have to agree, and now the file has a say.

    Declared ``image/heic``, named ``.heic``, sent as ``kind=image``: every
    piece of the client's word says photograph, and the body is an MP4.  This
    request was accepted before, and the file was written as ``.heic``.
    """

    response = post(
        harness, fixtures.MP4, filename="IMG_0142.heic", declared="image/heic"
    )

    assert response.status_code == 415
    assert error_of(response)["code"] == "unsupported_media_type"
    assert files_under(harness.state.media.root) == []


def test_a_truncated_jpeg_too_short_to_identify_is_refused(harness) -> None:
    """Two bytes are not a JPEG.  ``ff d8`` alone matches far too much."""

    response = post(harness, b"\xff\xd8", declared="image/jpeg")

    assert response.status_code == 415
    assert error_of(response)["code"] == "unsupported_media_type"
    assert files_under(harness.state.media.root) == []


# ==========================================================================
# What the sniff must not swallow
# ==========================================================================


def test_an_empty_upload_is_empty_upload_and_not_an_unrecognised_one(
    harness,
) -> None:
    """Nothing can be identified in no bytes, so the question is not asked.

    A sniff that ran first would answer ``unsupported_media_type`` here, which
    tells the user their file is the wrong format when their file is empty.
    """

    response = post(harness, b"", declared="image/jpeg")

    assert response.status_code == 400
    assert error_of(response)["code"] == "empty_upload"
    assert files_under(harness.state.media.root) == []


def test_a_stream_of_empty_chunks_is_an_empty_upload(tmp_path) -> None:
    """The store's own answer, one level below HTTP."""

    store = MediaStore(tmp_path / "store")

    with pytest.raises(MediaRejected) as raised:
        store.store(
            kind="image",
            filename="IMG_0142.jpg",
            content_type="image/jpeg",
            chunks=iter([b"", b"", b""]),
        )

    assert raised.value.code == "empty_upload"
    assert raised.value.status_code == 400
    assert files_under(store.root) == []


def test_a_real_jpeg_over_the_limit_is_still_file_too_large(
    gateway_factory, builder
) -> None:
    """Size cannot be read off a head, so it is still measured while writing.

    The body is a real JPEG -- if it were not, this would be refused for its
    format and the size ceiling would never be reached, and the test would pass
    while proving nothing.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(max_upload_bytes={"image": 4096, "video": 4096})

    response = post(harness, fixtures.JPEG + bytes(8192), declared="image/jpeg")

    assert response.status_code == 413
    assert error_of(response)["code"] == "file_too_large"
    assert files_under(harness.state.media.root) == []


def test_the_ceiling_is_reached_by_the_peeked_head_too(tmp_path) -> None:
    """A limit smaller than the peek is still a limit.

    The head is taken off the stream before anything is written, so an
    implementation that wrote it without counting it would let a file through
    at up to one chunk over the ceiling.
    """

    store = MediaStore(tmp_path / "store", max_upload_bytes={"image": 32, "video": 32})

    with pytest.raises(MediaRejected) as raised:
        store.store(
            kind="image",
            filename="IMG_0142.jpg",
            content_type="image/jpeg",
            chunks=iter([fixtures.JPEG]),
        )

    assert raised.value.code == "file_too_large"
    assert raised.value.status_code == 413
    assert files_under(store.root) == []


# ==========================================================================
# Still streamed
# ==========================================================================

#: Big enough that holding it would be obvious, small enough to write in a test.
STREAM_CHUNK = 256 * 1024
STREAM_CHUNKS = 64  # 16 MB in all


#: Both kinds go through this, because both are decided from a head now and the
#: kind the contract actually names is the video one: "a phone's video must
#: never land in the gateway's memory".  The image row is the one T-0126 left
#: here; the video row is the same measurement on the path this card changed.
STREAMED_KINDS = [
    pytest.param("image", fixtures.JPEG, id="image"),
    pytest.param("video", fixtures.MP4, id="video"),
]


@pytest.mark.parametrize("kind, head", STREAMED_KINDS)
def test_a_large_upload_is_never_held_whole_in_memory(tmp_path, kind, head) -> None:
    """The property ``_chunks`` exists for, measured rather than asserted.

    Sixteen megabytes go through the store, and the peak memory Python held
    while they did is compared against them.  A store that read the body to
    identify it -- ``data = b"".join(chunks)``, or an ``UploadFile.read()`` with
    no argument -- peaks at the size of the file; this one peaks at about one
    chunk, because that is all a peek can hold on to.

    The threshold is deliberately loose: what is being told apart is "one chunk"
    from "the whole file", and those differ by a factor of sixty here.
    """

    store = MediaStore(tmp_path / "store")
    total = STREAM_CHUNK * STREAM_CHUNKS

    def chunks():
        yield head
        for index in range(STREAM_CHUNKS):
            yield bytes(STREAM_CHUNK)

    tracemalloc.start()
    try:
        tracemalloc.reset_peak()
        item = store.store(
            kind=kind,
            filename="download",
            content_type="application/octet-stream",
            chunks=chunks(),
        )
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert item.bytes == total + len(head)
    assert item.path.stat().st_size == item.bytes
    assert peak < 4 * STREAM_CHUNK, "the store held {} bytes of a {} byte upload".format(
        peak, total
    )


@pytest.mark.parametrize("kind, head", STREAMED_KINDS)
def test_the_body_reaches_the_disk_while_the_body_is_still_arriving(
    tmp_path, kind, head
) -> None:
    """The other half of the same property, seen from outside the store.

    The generator looks at the store's directory each time it is asked for
    another chunk, and records what is on disk by then.  A store that buffered
    the upload would show an empty file until the very end; this one shows the
    file growing by a chunk at a time, which also proves the peeked head was
    written and not eaten.
    """

    store = MediaStore(tmp_path / "store")
    observed = []
    # One chunk the size ``api/media.py`` really reads, with the file's own head
    # at the front of it -- which is also the chunk the peek takes.
    first = head + bytes(STREAM_CHUNK - len(head))

    def on_disk() -> int:
        return sum(path.stat().st_size for path in files_under(store.root))

    def chunks():
        yield first
        for index in range(3):
            observed.append(on_disk())
            yield bytes(STREAM_CHUNK)

    item = store.store(
        kind=kind,
        filename="download",
        content_type="application/octet-stream",
        chunks=chunks(),
    )

    assert observed == [STREAM_CHUNK, 2 * STREAM_CHUNK, 3 * STREAM_CHUNK]
    assert item.bytes == 4 * STREAM_CHUNK
    # The peeked head went to disk with everything else rather than being eaten
    # by the look at it.
    assert item.path.read_bytes()[: len(head)] == head


# ==========================================================================
# All the way to ComfyUI's input directory
# ==========================================================================


def test_comfyui_is_handed_a_name_that_describes_the_file(harness) -> None:
    """The question this card has to answer NO to, asked at the boundary.

    A JPEG declared ``image/png`` and named ``photo.png`` is bound into a job.
    What ComfyUI is asked to store is named from the gateway's own id and the
    type read out of the file, and the type sent with it is that type too -- so
    nothing a client can say puts a file into that directory under an extension
    that does not describe it.
    """

    response = post(harness, fixtures.JPEG, filename="photo.png", declared="image/png")
    media_id = response.json()["media_id"]

    submitted = harness.submit("needs_image", {"source_image": {"media_id": media_id}})
    assert submitted.status_code == 201, submitted.text

    upload = harness.fake.uploads[0]
    assert upload["requested_filename"] == media_id + ".jpg"
    assert upload["content_type"] == "image/jpeg"
    assert upload["requested_subfolder"] == COMFY_INPUT_SUBFOLDER
    assert upload["bytes"] == len(fixtures.JPEG)


# ==========================================================================
# The video half: the same question, asked of the other kind
#
# What was measured before this card, against the live gateway, with the same
# body every time and only the label changing:
#
#     kind=video, video/mp4                -> 201
#     kind=video, application/octet-stream -> 415   (an Android picker)
#     kind=video, no Content-Type at all   -> 415
#
# and, in the other direction, all 23 of the bodies measured in review -- a PDF, a ZIP,
# an SVG, a Windows executable -- accepted under video/mp4 and written into
# ComfyUI's input directory as .mp4.
# ==========================================================================


def video_fixtures():
    """One real container per entry of ``ALLOWED_TYPES["video"]``, named.

    ``video/mpeg`` appears twice because it is two different files: a program
    stream and a bare elementary stream share the entry and share no bytes.
    """

    return [
        pytest.param(expected, extension, data, id=label)
        for label, expected, extension, data in [
            ("mp4", "video/mp4", ".mp4", fixtures.MP4),
            ("quicktime", "video/quicktime", ".mov", fixtures.MOV),
            ("3gp", "video/3gpp", ".3gp", fixtures.THREE_GP),
            ("webm", "video/webm", ".webm", fixtures.WEBM),
            ("matroska", "video/x-matroska", ".mkv", fixtures.MATROSKA),
            ("avi", "video/x-msvideo", ".avi", fixtures.AVI),
            ("mpeg program stream", "video/mpeg", ".mpeg", fixtures.MPEG_PROGRAM_STREAM),
            (
                "mpeg elementary stream",
                "video/mpeg",
                ".mpeg",
                fixtures.MPEG_ELEMENTARY_STREAM,
            ),
        ]
    ]


#: The video half of the measured table.  One MP4 body every time; the first row
#: is the only one that was accepted before, and it was accepted for the wrong
#: reason -- the label -- rather than because the body was an MP4.
MEASURED_VIDEO_TABLE = [
    ("video/mp4", "clip.mp4"),
    ("video/webm", "clip.webm"),
    ("video/quicktime", "clip.mov"),
    ("video/mpeg", "clip.mpeg"),
    ("image/jpeg", "clip.jpg"),
    ("application/octet-stream", "clip.mp4"),
    ("video/*", "clip.mp4"),
    (None, "clip.mp4"),
]


def test_the_video_fixtures_cover_every_entry_of_the_closed_set() -> None:
    """The list above says nothing about its own completeness, so this does.

    Three tests take their parameters from ``video_fixtures()``.  A type added
    to ``ALLOWED_TYPES["video"]`` without a fixture, or a fixture quietly
    dropped from the list, would leave all three still green while covering one
    format fewer -- which is a real thing that happens, was filed against the
    image side as T-0137, and is guarded there the same way now.
    """

    covered = {parameter.values[0] for parameter in video_fixtures()}

    assert covered == set(ALLOWED_TYPES["video"])


@pytest.mark.parametrize("declared, filename", MEASURED_VIDEO_TABLE)
def test_one_mp4_is_accepted_however_the_picker_labelled_it(
    harness, declared, filename
) -> None:
    """The measured table for video, turned round: every row is a 201 now.

    Including the row with no ``Content-Type`` header at all, which is what an
    Android picker sends for a clip exactly as it does for a photograph, and
    which was a 415 before this card.
    """

    response = post(
        harness, fixtures.MP4, filename=filename, declared=declared, kind="video"
    )

    assert response.status_code == 201, (declared, response.text)
    body = response.json()
    assert body["kind"] == "video"
    assert body["filename"] == filename
    assert body["bytes"] == len(fixtures.MP4)


@pytest.mark.parametrize("declared, filename", MEASURED_VIDEO_TABLE)
def test_the_stored_video_extension_describes_the_bytes(
    harness, declared, filename
) -> None:
    """And every row stores the file as what it *is*.

    Four rows declare a video type this body is not and name the file after it;
    one declares a photograph.  Before this card the first four were written out
    under the declared type's extension -- an MP4 stored ``.webm`` -- and the
    fifth was refused.
    """

    item = stored(
        harness,
        post(harness, fixtures.MP4, filename=filename, declared=declared, kind="video"),
    )

    assert item.content_type == "video/mp4"
    assert item.path.suffix == ".mp4"
    assert item.comfy_upload_name.endswith(".mp4")
    assert item.path.read_bytes() == fixtures.MP4


@pytest.mark.parametrize("expected, extension, data", video_fixtures())
def test_every_video_in_the_closed_set_is_recognised_from_its_head(
    expected, extension, data
) -> None:
    """The sniffer alone, on real containers, with no HTTP in the way."""

    assert sniff_video_type(data) == expected
    assert ALLOWED_TYPES["video"][expected] == extension


@pytest.mark.parametrize("expected, extension, data", video_fixtures())
def test_every_video_in_the_closed_set_survives_the_upload_undeclared(
    harness, expected, extension, data
) -> None:
    """And the same containers through the endpoint, sent the way a picker sends.

    ``application/octet-stream`` and a filename that says nothing: every one of
    these was refused outright by the gateway that believed the label.
    """

    item = stored(
        harness,
        post(
            harness,
            data,
            filename="download",
            declared="application/octet-stream",
            kind="video",
        ),
    )

    assert item.content_type == expected
    assert item.path.suffix == extension
    assert item.bytes == len(data)


@pytest.mark.parametrize("expected, extension, data", video_fixtures())
def test_a_video_head_split_across_chunks_is_still_identified(
    tmp_path, expected, extension, data
) -> None:
    """The same containers, handed over four bytes at a time.

    This is where :data:`~localcanvas_gateway.media.SNIFF_BYTES` earns its value
    on the video side, and it earns more of it than on the image side: an AVI's
    form type ends at byte 12, an ISO-BMFF major brand at byte 12, and a WebM's
    ``DocType`` is past byte 24.  A store that asked for four bytes and got them
    would refuse somebody's real clip.

    The stored file is compared to the body byte for byte, so a peek that ate
    the head instead of writing it fails here as well.
    """

    store = MediaStore(tmp_path / "store")

    item = store.store(
        kind="video",
        filename="download",
        content_type="application/octet-stream",
        chunks=iter(
            [data[at : at + TRICKLE_BYTES] for at in range(0, len(data), TRICKLE_BYTES)]
        ),
    )

    assert item.content_type == expected
    assert item.path.suffix == extension
    assert item.bytes == len(data)
    assert item.path.read_bytes() == data


@pytest.mark.parametrize(
    "name, data",
    [
        pytest.param(name, data, id=name.replace(" ", "-"))
        for name, data in sorted(fixtures.NOT_VIDEO.items())
    ],
)
def test_a_file_outside_the_video_set_is_refused_however_it_is_declared(
    harness, name, data
) -> None:
    """Every body that is not one of the seven, refused under ``kind=video``.

    The first group is every non-video entry of ``NOT_MEDIA`` -- the PDF, the
    ZIP, the SVG and the Windows executable among them, all four of which were
    measured being accepted under ``video/mp4`` and written into
    ComfyUI's input directory as ``.mp4``.  The rest are the near misses: a
    RIFF that is a picture, an EBML that is neither WebM nor Matroska, an
    ISO-BMFF whose major brand is a photograph's, and a real transport stream.
    """

    for declared in ("video/mp4", None):
        response = post(
            harness, data, filename="clip.mp4", declared=declared, kind="video"
        )

        error = error_of(response)
        assert response.status_code == 415, (name, declared)
        assert error["code"] == "unsupported_media_type", (name, declared)
        assert error["field"] == "file", (name, declared)
        assert files_under(harness.state.media.root) == [], (name, declared)


#: What ``VIDEO_NEAR_MISSES`` has to contain, written out where the tests can
#: see it.  ``video_fixtures()`` can be checked against ``ALLOWED_TYPES``; this
#: corpus has no such source of truth, so the list is the guard -- and without
#: one, deleting a near miss from the fixture module leaves the whole suite
#: green while its refusal stops being tested at all (T-0137's shape).
EVERY_VIDEO_NEAR_MISS = {
    "webp",
    "rifx avi",
    "ebml whose doctype only begins with webm",
    "matroska whose doctype is past the peek",
    "ebml declaring less than it holds",
    "mpeg sequence end alone",
    "mpeg program end alone",
    "avif",
    "heif image sequence",
    "mpeg transport stream",
    "3gpp2",
    "m4v",
    "quicktime without ftyp, moov first",
    "quicktime without ftyp, wide first",
}


def test_the_video_refusal_corpus_is_the_list_it_claims_to_be() -> None:
    """Both halves of ``NOT_VIDEO``, guarded rather than trusted.

    The derived half has to be every non-video entry of ``NOT_MEDIA`` -- so a
    body added there is refused as a video too, without anyone remembering --
    and the near misses have to be the fourteen named above, so that none of them can
    quietly leave.
    """

    assert set(fixtures.VIDEO_NEAR_MISSES) == EVERY_VIDEO_NEAR_MISS

    derived = set(fixtures.NOT_MEDIA) - set(fixtures.VIDEOS_IN_NOT_MEDIA)
    assert derived <= set(fixtures.NOT_VIDEO)
    assert set(fixtures.NOT_VIDEO) == derived | EVERY_VIDEO_NEAR_MISS


@pytest.mark.parametrize("name", fixtures.VIDEOS_IN_NOT_MEDIA)
def test_what_the_video_corpus_leaves_out_of_not_media_really_is_a_video(
    name,
) -> None:
    """The corpus above is derived, so what it excludes has to be earned.

    ``NOT_VIDEO`` is ``NOT_MEDIA`` minus the entries that are videos, and a
    list of exclusions nobody checks is how a body quietly stops being tested.
    Every name on that list has to be a file the gateway really does identify as
    a video -- otherwise it belongs in the refusal corpus above.
    """

    assert sniff_video_type(fixtures.NOT_MEDIA[name]) is not None
    assert sniff_image_type(fixtures.NOT_MEDIA[name]) is None


@pytest.mark.parametrize("expected, extension, data", image_fixtures())
def test_every_image_in_the_closed_set_is_refused_as_a_video(
    harness, expected, extension, data
) -> None:
    """An image cannot get in through the video kind, on its own bytes.

    Declared ``video/mp4`` and named ``.mp4``: every part of the client's word
    says clip.  Before this card the word was all there was, and a photograph
    sent this way was written into ComfyUI's input directory as ``.mp4``.
    """

    response = post(
        harness, data, filename="clip.mp4", declared="video/mp4", kind="video"
    )

    assert response.status_code == 415, expected
    assert error_of(response)["code"] == "unsupported_media_type", expected
    assert files_under(harness.state.media.root) == [], expected


@pytest.mark.parametrize("expected, extension, data", video_fixtures())
def test_every_video_in_the_closed_set_is_refused_as_an_image(
    harness, expected, extension, data
) -> None:
    """And the same in the other direction, which is the older half of the rule.

    Declared ``image/jpeg`` and named ``.jpg``.  The two brand tables share no
    entry, so an ISO-BMFF file answers one question or the other and never both.
    """

    response = post(harness, data, filename="photo.jpg", declared="image/jpeg")

    assert response.status_code == 415, expected
    assert error_of(response)["code"] == "unsupported_media_type", expected
    assert files_under(harness.state.media.root) == [], expected


def test_a_videos_major_brand_decides_and_its_compatible_brands_do_not() -> None:
    """The image side's rule, on the video side, pinned from both sides.

    A 3GPP clip names ``isom`` and ``mp41`` among its compatible brands, so a
    sniffer that scanned that list would store it as ``.mp4``.  A HEIF image
    sequence -- somebody's burst of photographs -- names ``iso8`` among its own,
    so the same sniffer would take it for a film.  Both temptations are asserted
    to be really present in the fixtures, and both brands are asserted to be
    ones this gateway would answer to if they were *major*, because otherwise
    this test would pass against a table that simply did not know them.
    """

    assert sniff_video_type(fixtures.THREE_GP) == "video/3gpp"
    assert sniff_video_type(fixtures.HEIF_SEQUENCE) is None
    assert sniff_image_type(fixtures.HEIF_SEQUENCE) == "image/heif"

    assert b"isom" in fixtures.THREE_GP[16:32], "the 3GPP fixture must carry it"
    assert b"iso8" in fixtures.HEIF_SEQUENCE[16:32], "the HEIF fixture must carry it"
    # And those two brands are known -- as major brands, which is the only place
    # this gateway reads a brand from.
    assert sniff_video_type(b"\x00\x00\x00\x10ftypisom") == "video/mp4"
    assert sniff_video_type(b"\x00\x00\x00\x10ftypiso8") == "video/mp4"


@pytest.mark.parametrize(
    "brand",
    [
        pytest.param(brand, id=brand.decode("ascii"))
        for brand in (b"mp4v", b"iso3", b"iso7", b"iso9", b"isoa")
    ],
)
def test_the_mp4_brands_the_table_was_missing_are_mp4s(harness, brand) -> None:
    """The incomplete half of the brand table, completed (T-0162).

    ``mp4v`` is an MP4 brand like ``mp41``; ``iso3``, ``iso7``, ``iso9`` and
    ``isoa`` are ISO/IEC 14496-12's own revisions beside the ``isoN`` brands the
    table already carried.  Each is a real ISO base media file with that major
    brand, identified by the sniffer and stored through the endpoint as
    ``.mp4`` when sent the way a picker sends.  The brands are written out here
    rather than taken from the fixture module, so a brand that left it could
    not take its test with it.
    """

    data = fixtures.MP4_BY_ADDED_BRAND[brand]
    assert data[8:12] == brand, "the brand has to be the major one"

    assert sniff_video_type(data) == "video/mp4"
    assert sniff_image_type(data) is None

    item = stored(
        harness,
        post(
            harness,
            data,
            filename="download",
            declared="application/octet-stream",
            kind="video",
        ),
    )
    assert (item.content_type, item.path.suffix) == ("video/mp4", ".mp4")
    assert item.path.read_bytes() == data


def test_the_added_brands_are_the_fixture_modules_list() -> None:
    """The per-brand test names its five; the fixture module must hold them."""

    assert set(fixtures.MP4_BY_ADDED_BRAND) == {b"mp4v", b"iso3", b"iso7", b"iso9", b"isoa"}


@pytest.mark.parametrize(
    "name, data",
    [
        pytest.param("3gpp2", fixtures.THREE_GPP2, id="3g2a"),
        pytest.param("m4v", fixtures.M4V, id="m4v"),
        pytest.param(
            "quicktime without ftyp, moov first",
            fixtures.QUICKTIME_WITHOUT_FTYP_MOOV_FIRST,
            id="quicktime-moov-first",
        ),
        pytest.param(
            "quicktime without ftyp, wide first",
            fixtures.QUICKTIME_WITHOUT_FTYP_WIDE_FIRST,
            id="quicktime-wide-first",
        ),
    ],
)
def test_3gpp2_m4v_and_a_quicktime_without_ftyp_stay_refused(name, data) -> None:
    """The halves of T-0162 that were decided the other way, and stay refused.

    3GPP2 and M4V are the closed set doing its job: ``video/3gpp2`` and
    ``video/x-m4v`` are not in ``ALLOWED_TYPES``, and storing either as
    ``.3gp`` or ``.mp4`` would be the lie this module exists to stop.  A legacy
    QuickTime movie has no ``ftyp`` box to read a brand from, and recognising
    one by walking its boxes is a decision of its own.

    Each is refused by the video sniffer and by the image one.  The endpoint's
    refusal of all four is ``test_a_file_outside_the_video_set_is_refused...``,
    which takes them from ``VIDEO_NEAR_MISSES``.  The M4V is asserted to carry
    MP4 brands the table does know among its compatibles, so its refusal is the
    major brand's and not an accident of a table that knew none of them.
    """

    assert name in fixtures.VIDEO_NEAR_MISSES
    assert fixtures.VIDEO_NEAR_MISSES[name] == data

    assert sniff_video_type(data) is None, name
    assert sniff_image_type(data) is None, name

    if name == "m4v":
        assert b"mp42" in data[16:32] and b"isom" in data[16:32]
        assert sniff_video_type(b"\x00\x00\x00\x10ftypmp42") == "video/mp4"


def test_a_webm_and_a_matroska_are_told_apart_by_their_doctype(harness) -> None:
    """The one difference between the two files is the one the gateway reads.

    Every WebM is a valid Matroska: the two share their magic number, their
    syntax and everything else in the header.  A sniffer that stopped at the
    magic would store a Matroska as ``.webm`` -- and ComfyUI would be handed a
    ``.webm`` holding a file that is not one.
    """

    assert fixtures.WEBM[:4] == fixtures.MATROSKA[:4], "the magic is shared"

    webm = stored(
        harness,
        post(harness, fixtures.WEBM, filename="clip.mkv", declared=None, kind="video"),
    )
    matroska = stored(
        harness,
        post(
            harness, fixtures.MATROSKA, filename="clip.webm", declared=None, kind="video"
        ),
    )

    assert (webm.content_type, webm.path.suffix) == ("video/webm", ".webm")
    assert (matroska.content_type, matroska.path.suffix) == (
        "video/x-matroska",
        ".mkv",
    )


def test_an_ebml_document_whose_doctype_is_past_the_peek_is_refused(harness) -> None:
    """Bounded, and refusing rather than reading on -- with the cost stated.

    ``DocType`` is at no fixed offset, so finding it is a search, and a search
    over a stream is how a peek turns into a read.  The search stops at
    ``SNIFF_BYTES``, so a document that pads its header past that is refused.

    The refusal is the bound and not the file, which is what the second half of
    this test shows: the same document without the padding is accepted as a
    Matroska.  The cost is a real Matroska whose muxer writes a large ``Void``
    or a ``CRC-32`` element ahead of its DocType; no muxer this project knows of
    does, and reading on would mean holding an unbounded amount of somebody's
    video to identify it.
    """

    padded = fixtures.MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK
    assert b"matroska" in padded, "the fixture must really carry the DocType"
    assert padded.index(b"matroska") > SNIFF_BYTES, "and carry it past the peek"

    refused = post(harness, padded, filename="clip.mkv", declared=None, kind="video")
    assert refused.status_code == 415
    assert error_of(refused)["code"] == "unsupported_media_type"

    item = stored(
        harness,
        post(harness, fixtures.MATROSKA, filename="clip.mkv", declared=None, kind="video"),
    )
    assert item.content_type == "video/x-matroska"


def test_both_shapes_of_an_mpeg_stream_are_video_mpeg(harness) -> None:
    """A program stream and a bare elementary stream are one entry of the set.

    They share no bytes -- ``00 00 01 ba`` opens one and ``00 00 01 b3`` the
    other -- and both are what a ``.mpeg`` file can be, so both are identified.
    """

    for data in (fixtures.MPEG_PROGRAM_STREAM, fixtures.MPEG_ELEMENTARY_STREAM):
        item = stored(
            harness,
            post(harness, data, filename="clip.mpeg", declared=None, kind="video"),
        )
        assert item.content_type == "video/mpeg"
        assert item.path.suffix == ".mpeg"

    assert fixtures.MPEG_PROGRAM_STREAM[:4] != fixtures.MPEG_ELEMENTARY_STREAM[:4]


def test_a_transport_stream_is_refused_and_that_is_the_cost_of_this_decision(
    harness,
) -> None:
    """The one thing this card takes away, stated as a test rather than a note.

    A transport stream has no signature: it is ``0x47`` every 188 bytes, so
    confirming one needs 189 bytes against a 64-byte peek, and one ``0x47`` is
    the letter ``G``.  It is also not this entry of the closed set -- its type is
    ``video/mp2t`` and its extensions are ``.ts`` and ``.m2ts``, neither of which
    ``ALLOWED_TYPES`` contains -- so identifying one would mean writing it out as
    ``.mpeg``, a name that does not describe it.

    **The cost, plainly.** A transport stream that a client declared
    ``video/mpeg`` used to be accepted, and was stored as ``.mpeg``.  It is
    refused now.  Declared as anything else -- ``video/mp2t``, octet-stream,
    nothing at all, which is what a picker sends -- it was already refused
    before, so what changed is one label's worth of behaviour.
    """

    assert fixtures.TRANSPORT_STREAM[0] == 0x47
    assert fixtures.TRANSPORT_STREAM[fixtures.TS_PACKET_BYTES] == 0x47
    assert sniff_video_type(fixtures.TRANSPORT_STREAM) is None

    for declared in ("video/mpeg", "video/mp2t", "application/octet-stream", None):
        response = post(
            harness,
            fixtures.TRANSPORT_STREAM,
            filename="clip.mpeg",
            declared=declared,
            kind="video",
        )
        assert response.status_code == 415, declared
        assert error_of(response)["code"] == "unsupported_media_type", declared
        assert files_under(harness.state.media.root) == [], declared


# ==========================================================================
# What the video sniff must not swallow either
# ==========================================================================


def test_an_empty_video_upload_is_empty_upload_and_not_an_unrecognised_one(
    harness,
) -> None:
    """The refusal order is the same on both paths, and for the same reason."""

    response = post(harness, b"", filename="clip.mp4", declared="video/mp4", kind="video")

    assert response.status_code == 400
    assert error_of(response)["code"] == "empty_upload"
    assert files_under(harness.state.media.root) == []


def test_a_real_mp4_over_the_limit_is_still_file_too_large(
    gateway_factory, builder
) -> None:
    """Size cannot be read off a head on this path either.

    The body is a real MP4 -- if it were not, this would be refused for its
    format and the ceiling would never be reached, and the test would pass while
    proving nothing.  That is asserted rather than reasoned about: the same
    fixture without the filler goes through the same gateway at the same
    ceiling, so what stops the body below is its size and nothing else.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(max_upload_bytes={"image": 4096, "video": 4096})

    assert len(fixtures.MP4) < 4096, "the fixture itself must fit under the ceiling"
    accepted = post(
        harness, fixtures.MP4, filename="clip.mp4", declared="video/mp4", kind="video"
    )
    assert accepted.status_code == 201, accepted.text

    response = post(
        harness,
        fixtures.MP4 + bytes(8192),
        filename="clip.mp4",
        declared="video/mp4",
        kind="video",
    )

    assert response.status_code == 413
    assert error_of(response)["code"] == "file_too_large"
    assert len(files_under(harness.state.media.root)) == 1, "only the accepted one"


# ==========================================================================
# All the way to ComfyUI's input directory, for a video
# ==========================================================================


def test_comfyui_is_handed_a_video_name_that_describes_the_file(harness) -> None:
    """The question this card has to answer NO to, asked at the boundary.

    A Matroska declared ``video/webm`` and named ``clip.webm`` is bound into a
    job.  What ComfyUI is asked to store is named from the gateway's own id and
    the type read out of the file, and the type sent with it is that type too.
    Asserted on the recorded upload, not on the response: the answer to the app
    names nothing on this PC, so it could not show this either way.
    """

    response = post(
        harness,
        fixtures.MATROSKA,
        filename="clip.webm",
        declared="video/webm",
        kind="video",
    )
    media_id = response.json()["media_id"]

    submitted = harness.submit("needs_video", {"source_video": {"media_id": media_id}})
    assert submitted.status_code == 201, submitted.text

    upload = harness.fake.uploads[0]
    assert upload["requested_filename"] == media_id + ".mkv"
    assert upload["content_type"] == "video/x-matroska"
    assert upload["requested_subfolder"] == COMFY_INPUT_SUBFOLDER
    assert upload["bytes"] == len(fixtures.MATROSKA)


def test_a_media_kind_mismatch_still_fires_in_both_directions(harness) -> None:
    """What the sniff must not cost: the field still has to want this kind.

    Both files are now accepted on their own bytes -- the MP4 as a video and the
    JPEG as an image -- so this is the check that a file which got in honestly
    still cannot be bound to a field of the other kind.  It is the only rule
    here that the sniff could have quietly made unreachable.
    """

    video_id = post(
        harness, fixtures.MP4, filename="clip.mp4", declared=None, kind="video"
    ).json()["media_id"]
    image_id = post(harness, fixtures.JPEG, declared=None).json()["media_id"]

    to_image_field = harness.submit(
        "needs_image", {"source_image": {"media_id": video_id}}
    )
    to_video_field = harness.submit(
        "needs_video", {"source_video": {"media_id": image_id}}
    )

    assert error_of(to_image_field)["code"] == "media_kind_mismatch"
    assert error_of(to_image_field)["field"] == "source_image"
    assert error_of(to_video_field)["code"] == "media_kind_mismatch"
    assert error_of(to_video_field)["field"] == "source_video"
    assert harness.fake.submissions == []


def test_the_store_still_answers_the_documented_document(harness) -> None:
    """The endpoint's contract is unchanged by any of the above."""

    response = post(harness, fixtures.JPEG, declared=None)

    body = response.json()
    assert set(body) == {"media_id", "kind", "filename", "bytes", "expires_at"}
    assert body["kind"] == "image"
    assert body["filename"] == "IMG_0142.jpg"
    assert body["expires_at"] == "2026-01-01T01:00:00Z"
