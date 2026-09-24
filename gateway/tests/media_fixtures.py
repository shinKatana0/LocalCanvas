"""Container heads for the tests that are about what a file *is*.

A test that sniffs a byte string somebody typed proves that the sniffer reads
that byte string.  So everything here is built the way the format defines
itself -- box sizes, segment lengths and offsets are **computed** from the
content, never written out as literals -- and every one of these is walked by an
independent parser in ``test_media_sniffing.py`` before it is used, so a fixture
that is not really the container it claims to be fails there and says so.

What each of these is, exactly, so that no test claims more than it has:

``png_bytes()``
    A real PNG file, read off this repository at run time: the Android
    launcher icon, produced by the toolchain that produced it and not by this
    module.  Every one of its chunks passes its own CRC (asserted in the test),
    which is a thing a typed constant does not do.

:data:`JPEG`
    A JPEG's real segment structure as a phone camera writes it -- SOI, JFIF
    APP0, Exif APP1 carrying a valid little-endian TIFF IFD, the Annex K
    quantisation and Huffman tables, SOF0 with real dimensions, SOS, EOI -- with
    filler where the entropy-coded scan would be.  The scan is the one part that
    cannot be produced without an encoder, and nothing in this repository can
    encode one; no JPEG, HEIC or video file exists anywhere inside the
    workspace to copy a real head from (measured: the only image files this
    repository contains are the five launcher PNGs), and going looking for
    one elsewhere on the machine is not something this suite does.

:data:`GIF` and :data:`BMP`
    Complete, valid small files.  Both formats are small enough to write
    whole: the GIF carries a real LZW stream (clear, one pixel, end-of-
    information) and the BMP real rows with their padding bytes.
    :data:`BMP_BY_HEADER_SIZE` holds one BMP per documented DIB header size,
    each header written field by field.

:data:`WEBP`
    A real RIFF/WEBP container -- ``RIFF``, a size field that matches the file,
    the ``WEBP`` form type and a ``VP8L`` chunk with its own size -- with filler
    for the VP8L bitstream, which again needs an encoder.  The AVI and the WAVE
    in :data:`NOT_MEDIA` come out of the same container builder and differ from
    it only in the form type, which is the byte the sniffer decides on.

:data:`HEIC`, :data:`HEIF`, :data:`MP4`
    Real ISO base media files: an ``ftyp`` box declaring major and compatible
    brands, a ``meta`` box holding a ``pict`` handler for the two image ones,
    and ``mdat`` where the coded picture would be.  The box sizes chain exactly
    to the end of the file, which is what the walker in the test checks.  The
    MP4 is here to be *refused*: it is the reason a still image cannot be
    recognised by ``ftyp`` alone.

:data:`AVI`, :data:`WEBM`, :data:`MATROSKA`, :data:`THREE_GP`,
:data:`MPEG_PROGRAM_STREAM`, :data:`MPEG_ELEMENTARY_STREAM`
    One real container per entry of ``ALLOWED_TYPES["video"]``, built to the
    same rule as everything above: every length, every size and every start
    code computed from the content, and a walker in the test that follows them.
    The AVI is not a new fixture -- it is the one already here, which the image
    side built as a *negative* and the video side reads as a positive.  The
    EBML pair differ only in their ``DocType``, which is the whole of what tells
    a WebM from a Matroska; the two MPEG streams are ISO 11172's own bit
    layouts, written with a bit writer because MPEG's headers are not
    byte-aligned.

:data:`TRANSPORT_STREAM`
    A real MPEG transport stream -- 188-byte packets, a program association
    table naming the PID of a program map table, that table naming the PID the
    video is on, and a real MPEG CRC-32 on each section.  It is here to be
    **refused**, and it has to be real for the refusal to mean anything.

:data:`NOT_MEDIA`, :data:`VIDEO_NEAR_MISSES` and :data:`NOT_VIDEO`
    Files that are really other things, each with its own real signature --
    and, at the end of each, the near misses.  For the image side: a RIFF that
    is a video, a RIFF that is a sound, a real PNG damaged the way PNG's own
    signature is designed to catch, a text file that begins ``BM``, and the
    real BMP declaring a DIB header size the format does not define.  For the
    video side, fourteen of them, listed at :data:`VIDEO_NEAR_MISSES`: a RIFF
    that is a picture, the AVI in RIFF's big-endian form, two EBML documents
    that stop at each of the DocType walk's two bounds, an EBML whose DocType
    is four letters of one, two MPEG start codes that end a stream rather than
    beginning one, two ISO base media files whose major brand is a
    photograph's, the transport stream, a 3GPP2 clip and an M4V, and two
    legacy QuickTime movies with no ``ftyp`` box.  A magic
    number is only worth the byte it stops at, and those are where it stops.
"""

from __future__ import annotations

from pathlib import Path

#: The repository this test tree belongs to.
REPO_ROOT = Path(__file__).resolve().parents[2]

#: A real PNG that is part of this repository rather than of this module.
PNG_PATH = (
    REPO_ROOT
    / "app"
    / "android"
    / "app"
    / "src"
    / "main"
    / "res"
    / "mipmap-mdpi"
    / "ic_launcher.png"
)


def png_bytes() -> bytes:
    """The launcher icon's real bytes, or a failure that says what is missing."""

    assert PNG_PATH.is_file(), (
        "the real PNG these tests read is missing: {}".format(PNG_PATH)
    )
    return PNG_PATH.read_bytes()


def _text_mode_transfer(data: bytes) -> bytes:
    r"""What a transfer in text mode does to a binary file: CRLF becomes LF.

    Not an invented corruption, and not noise.  PNG's signature carries ``\r\n``
    and a DOS end-of-file byte for precisely this reason -- the specification
    lists a line-ending conversion among the accidents those eight bytes exist
    to detect -- so a PNG that has been through an ASCII-mode transfer stops
    being a PNG at byte four instead of halfway through a decoder.  A sniffer
    that read only ``\x89PNG`` would undo that and write the damaged file into
    ComfyUI's input directory as ``.png``.
    """

    return data.replace(b"\r\n", b"\n")


# -- JPEG ------------------------------------------------------------------

#: ITU-T T.81 Annex K, table K.1: the luminance quantisation table every
#: ordinary encoder starts from.
_QUANTISATION = bytes(
    (
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    )
)

#: Annex K again, table K.3: the DC luminance Huffman table.
_HUFFMAN_COUNTS = bytes((0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0))
_HUFFMAN_VALUES = bytes(range(12))


def _jpeg_segment(marker: int, payload: bytes) -> bytes:
    """One marker segment, with the length JPEG defines: payload plus its own."""

    return bytes((0xFF, marker)) + (len(payload) + 2).to_bytes(2, "big") + payload


def _tiff_ifd(entries) -> bytes:
    """A little-endian TIFF header and one IFD, as Exif carries it.

    Values of four bytes or fewer sit in the entry; longer ones are placed after
    the directory and referenced by an offset from the start of the TIFF header,
    which is what makes this a directory rather than a blob.
    """

    header = b"II" + (42).to_bytes(2, "little") + (8).to_bytes(4, "little")
    directory_size = 2 + 12 * len(entries) + 4
    values_start = 8 + directory_size

    directory = len(entries).to_bytes(2, "little")
    values = b""
    for tag, text in sorted(entries):
        value = text + b"\x00"
        directory += tag.to_bytes(2, "little")
        directory += (2).to_bytes(2, "little")  # ASCII
        directory += len(value).to_bytes(4, "little")
        if len(value) <= 4:
            directory += value.ljust(4, b"\x00")
        else:
            directory += (values_start + len(values)).to_bytes(4, "little")
            values += value
    directory += (0).to_bytes(4, "little")  # no next IFD
    return header + directory + values


def _jpeg(width: int, height: int) -> bytes:
    jfif = b"JFIF\x00" + bytes((1, 1, 1)) + (72).to_bytes(2, "big") + (72).to_bytes(
        2, "big"
    ) + bytes((0, 0))
    exif = b"Exif\x00\x00" + _tiff_ifd(
        [(0x010F, b"LocalCanvas"), (0x0110, b"Test Camera")]
    )
    frame = (
        bytes((8,))
        + height.to_bytes(2, "big")
        + width.to_bytes(2, "big")
        + bytes((3,))
        + bytes((1, 0x22, 0))
        + bytes((2, 0x11, 1))
        + bytes((3, 0x11, 1))
    )
    scan = bytes((3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0))
    return (
        b"\xff\xd8"  # SOI
        + _jpeg_segment(0xE0, jfif)
        + _jpeg_segment(0xE1, exif)
        + _jpeg_segment(0xDB, b"\x00" + _QUANTISATION)
        + _jpeg_segment(0xC0, frame)
        + _jpeg_segment(0xC4, b"\x00" + _HUFFMAN_COUNTS + _HUFFMAN_VALUES)
        + _jpeg_segment(0xDA, scan)
        # Where the entropy-coded scan would be.  No 0xFF byte appears in it, so
        # nothing in the filler can be read as a marker.
        + bytes(range(1, 200)) * 3
        + b"\xff\xd9"  # EOI
    )


#: One photograph, in the shape a camera writes one.
JPEG = _jpeg(4032, 3024)


# -- GIF -------------------------------------------------------------------


def _gif(version: bytes) -> bytes:
    """A complete one-pixel GIF, palette and LZW stream included.

    The image data is three 3-bit codes -- clear (4), pixel index 0, end of
    information (5) -- packed least-significant-bit first into two bytes, which
    is the whole of what a one-pixel image compresses to.
    """

    codes = [4, 0, 5]
    bits = 0
    width = 0
    packed = bytearray()
    for code in codes:
        bits |= code << width
        width += 3
        while width >= 8:
            packed.append(bits & 0xFF)
            bits >>= 8
            width -= 8
    if width:
        packed.append(bits & 0xFF)

    screen = (
        (1).to_bytes(2, "little")
        + (1).to_bytes(2, "little")
        + bytes((0xF0, 0, 0))  # global colour table of two entries
    )
    palette = bytes((0, 0, 0, 255, 255, 255))
    # The descriptor is: separator, left, top, width, height, packed fields.
    image = (
        b"\x2c"
        + (0).to_bytes(2, "little")
        + (0).to_bytes(2, "little")
        + (1).to_bytes(2, "little")
        + (1).to_bytes(2, "little")
        + bytes((0,))
    )
    data = bytes((2,)) + bytes((len(packed),)) + bytes(packed) + b"\x00"
    return b"GIF" + version + screen + palette + image + data + b"\x3b"


#: Both versions there have ever been.  A sniffer that knows only one of them
#: refuses real files.
GIF89A = _gif(b"89a")
GIF87A = _gif(b"87a")
GIF = GIF89A


# -- BMP -------------------------------------------------------------------


#: Every size a BMP's DIB header is documented to have, and the header each one
#: is: ``BITMAPCOREHEADER`` (12), OS/2 2.x's short ``OS22XBITMAPHEADER`` (16),
#: ``BITMAPINFOHEADER`` (40), the V2 and V3 info headers that add the colour
#: masks (52, 56), OS/2's full ``OS22XBITMAPHEADER`` (64), and
#: ``BITMAPV4HEADER`` and ``BITMAPV5HEADER`` (108, 124).  The header's first
#: four bytes are its own size, which is what a reader uses to know which of
#: these it is holding.
BMP_DIB_HEADER_SIZES = (12, 16, 40, 52, 56, 64, 108, 124)

#: ``BI_RGB`` and ``BI_BITFIELDS``: uncompressed, and uncompressed with the
#: channel masks the V2 header and later ones carry.
_BI_RGB = 0
_BI_BITFIELDS = 3

#: ``LCS_sRGB``, the colour space a V4 or V5 header names when it names one.
_LCS_SRGB = int.from_bytes(b"sRGB", "big")

#: ``LCS_GM_IMAGES``, the rendering intent a V5 header carries for a photograph.
_LCS_GM_IMAGES = 4


def _u16(value: int) -> bytes:
    return value.to_bytes(2, "little")


def _u32(value: int) -> bytes:
    return value.to_bytes(4, "little")


def _bmp(width: int, height: int, header_size: int = 40) -> bytes:
    """A complete BMP whose DIB header is the one ``header_size`` names.

    Every header is written field by field, so its length is what its fields add
    up to and is then checked against ``header_size`` rather than padded to it.

    * 12 -- ``BITMAPCOREHEADER``: 16-bit width and height, 24 bits per pixel.
    * 16 -- OS/2 2.x's short ``OS22XBITMAPHEADER``: only the first 16 bytes of
      the 64-byte one -- size, 32-bit width and height, planes, bit count --
      with every field after them taken as zero, 24 bits per pixel.
    * 40 -- ``BITMAPINFOHEADER``: the ordinary one, 24 bits per pixel,
      ``BI_RGB``.  This is byte for byte the BMP this module always had.
    * 64 -- ``OS22XBITMAPHEADER``: the 40-byte fields and OS/2's own 24 bytes
      after them (units, reserved, recording, rendering, two sizes, colour
      encoding, identifier), 24 bits per pixel.
    * 52, 56, 108, 124 -- the V2, V3, V4 and V5 headers, which exist to carry
      channel masks, so these are 32-bit ``BI_BITFIELDS`` files with real
      masks; the V4 names sRGB, and the V5 adds a rendering intent and an empty
      profile.

    Rows are padded to four bytes, as the format says.
    """

    bits = 32 if header_size in (52, 56, 108, 124) else 24
    row = (width * bits // 8 + 3) // 4 * 4
    pixel = bytes([0x20, 0x40, 0x80]) if bits == 24 else bytes([0x20, 0x40, 0x80, 0xFF])
    pixels = (pixel + bytes(row - len(pixel))) * height

    if header_size == 12:
        info = _u32(12) + _u16(width) + _u16(height) + _u16(1) + _u16(bits)
    elif header_size == 16:
        info = (
            _u32(16)
            + width.to_bytes(4, "little", signed=True)
            + height.to_bytes(4, "little", signed=True)
            + _u16(1)
            + _u16(bits)
        )
    else:
        info = (
            _u32(header_size)
            + width.to_bytes(4, "little", signed=True)
            + height.to_bytes(4, "little", signed=True)
            + _u16(1)
            + _u16(bits)
            + _u32(_BI_RGB if bits == 24 else _BI_BITFIELDS)
            + _u32(len(pixels))
            + _u32(2835)
            + _u32(2835)
            + _u32(0)
            + _u32(0)
        )
        if header_size == 64:
            info += (
                _u16(0)  # units: pixels per metre
                + _u16(0)  # reserved
                + _u16(0)  # recording: bottom-up
                + _u16(0)  # no halftoning
                + _u32(0)
                + _u32(0)
                + _u32(0)  # colour encoding: RGB
                + _u32(0)  # application identifier
            )
        if header_size in (52, 56, 108, 124):
            info += _u32(0x00FF0000) + _u32(0x0000FF00) + _u32(0x000000FF)
        if header_size in (56, 108, 124):
            info += _u32(0xFF000000)
        if header_size in (108, 124):
            info += _u32(_LCS_SRGB) + bytes(36) + _u32(0) * 3  # endpoints, gamma
        if header_size == 124:
            info += _u32(_LCS_GM_IMAGES) + _u32(0) + _u32(0) + _u32(0)
    assert len(info) == header_size, (header_size, len(info))

    offset = 14 + len(info)
    header = (
        b"BM"
        + _u32(offset + len(pixels))
        + _u16(0)
        + _u16(0)
        + _u32(offset)
    )
    return header + info + pixels


BMP = _bmp(2, 2)

#: One complete BMP per documented DIB header size, keyed by that size.  The
#: 40-byte one **is** :data:`BMP`, not a second copy of it.
BMP_BY_HEADER_SIZE = {
    size: (BMP if size == 40 else _bmp(2, 2, header_size=size))
    for size in BMP_DIB_HEADER_SIZES
}


def _with_u32_at(data: bytes, offset: int, value: int) -> bytes:
    """The same file with one little-endian field rewritten, and nothing else."""

    return data[:offset] + _u32(value) + data[offset + 4 :]


#: A real BMP whose file-size field at offset 2 is wrong, the way some encoders
#: write it.  The gateway does not read that field, and this is what says so.
BMP_WITH_A_WRONG_FILE_SIZE = _with_u32_at(BMP, 2, 0)

#: The real BMP with its DIB header size rewritten to one the format does not
#: define -- one past ``BITMAPINFOHEADER``'s.  ``BM`` to the byte, the rest of
#: the file intact, and not a BMP any reader could parse.
BMP_DECLARING_AN_UNDEFINED_HEADER_SIZE = _with_u32_at(BMP, 14, 41)

#: What was uploaded when T-0126 was reviewed: a text file whose first two letters
#: happen to be ``BM``.  It was written into ComfyUI's input directory as
#: ``.bmp``.
TEXT_BEGINNING_BM = b"BMX this is a text file, and it is not a picture.\n"


# -- RIFF: WebP, and the RIFF files that are not WebP -----------------------


def _riff(form_type: bytes, chunks: bytes) -> bytes:
    """A RIFF container: the tag, the size of all that follows it, the form type.

    One builder for every RIFF fixture here.  What the sniffer decides on is
    the **form type** at bytes 8-11, and the three fixtures below differ in
    exactly that and in nothing else about the container -- so a second copy of
    this arithmetic would be a second thing to keep true.
    """

    body = form_type + chunks
    return b"RIFF" + len(body).to_bytes(4, "little") + body


def _riff_chunk(kind: bytes, payload: bytes) -> bytes:
    """One chunk: its four-character code, its own size, its content."""

    chunk = kind + len(payload).to_bytes(4, "little") + payload
    if len(chunk) % 2:  # RIFF chunks are padded to an even length
        chunk += b"\x00"
    return chunk


def _rifx(form_type: bytes, chunks: bytes) -> bytes:
    """RIFF's other byte order.  Same container, ``RIFX``, sizes big-endian.

    It is a real form of the format -- RIFF is little-endian and RIFX is the
    big-endian one, and the four characters at the front are how a reader knows
    which it is holding.  Here it is the near miss the AVI needs: bytes 8-11 say
    ``AVI `` exactly as the AVI's do, and the four bytes before them do not say
    ``RIFF``.
    """

    body = form_type + chunks
    return b"RIFX" + len(body).to_bytes(4, "big") + body


def _rifx_chunk(kind: bytes, payload: bytes) -> bytes:
    chunk = kind + len(payload).to_bytes(4, "big") + payload
    if len(chunk) % 2:
        chunk += b"\x00"
    return chunk


def _webp(payload: bytes) -> bytes:
    return _riff(b"WEBP", _riff_chunk(b"VP8L", payload))


#: ``0x2f`` is VP8L's own signature byte; the rest stands in for the bitstream.
WEBP = _webp(b"\x2f" + bytes(range(120)))


def _avi_bytes(order: str = "little") -> bytes:
    """A video in a RIFF container: a WebP's first four bytes, and not a WebP.

    ``avih`` is the real 56-byte ``MainAVIHeader`` -- microseconds per frame,
    flags, frame and stream counts, dimensions, the four reserved words -- in
    the ``hdrl`` list an AVI opens with, followed by the ``movi`` list the
    frames would live in.

    ``order`` swaps the whole container between RIFF and RIFX, which is one
    builder rather than two: the RIFX form below has to be the *same file* in
    the other byte order for it to prove anything about the four bytes the
    gateway reads first.
    """

    avih = b"".join(
        value.to_bytes(4, order)
        for value in (
            40000,  # microseconds per frame: 25 fps
            0,  # maximum bytes per second
            0,  # padding granularity
            0x10,  # AVIF_HASINDEX
            1,  # total frames
            0,  # initial frames
            1,  # streams
            0,  # suggested buffer size
            320,  # width
            240,  # height
            0,  # reserved
            0,
            0,
            0,
        )
    )
    container, chunk = (
        (_riff, _riff_chunk) if order == "little" else (_rifx, _rifx_chunk)
    )
    hdrl = chunk(b"LIST", b"hdrl" + chunk(b"avih", avih))
    return container(b"AVI ", hdrl + chunk(b"LIST", b"movi"))


#: The one video container this repository already had.  It was built for the
#: image side as a *negative* -- proof that a WebP sniff cannot be fooled by any
#: RIFF -- and it is a positive for the video side, which is the same file
#: answering two questions.  There is one of it, not two.
AVI = _avi_bytes()

#: The same AVI in RIFF's big-endian form.  ``AVI `` at bytes 8-11 to the byte,
#: and ``RIFX`` rather than ``RIFF`` in front of it -- so a sniffer that read
#: the form type without the magic would store it as ``.avi``.
RIFX_AVI = _avi_bytes("big")


def _wave() -> bytes:
    """A sound in a RIFF container: the other RIFF a file manager can offer.

    A real PCM ``fmt `` chunk -- format 1, one channel, 8 kHz, 16-bit, with the
    byte rate and block alignment those imply -- and a ``data`` chunk holding
    one cycle of a square wave.
    """

    fmt = (
        (1).to_bytes(2, "little")  # PCM
        + (1).to_bytes(2, "little")  # channels
        + (8000).to_bytes(4, "little")  # samples per second
        + (16000).to_bytes(4, "little")  # bytes per second: 8000 * 1 * 2
        + (2).to_bytes(2, "little")  # block align: 1 channel * 16 bits
        + (16).to_bytes(2, "little")  # bits per sample
    )
    samples = b"\x00\x40" * 8 + b"\x00\xc0" * 8
    return _riff(b"WAVE", _riff_chunk(b"fmt ", fmt) + _riff_chunk(b"data", samples))


# -- ISO base media: HEIC, HEIF, and the MP4 that must not be mistaken for one


def _box(kind: bytes, payload: bytes) -> bytes:
    """One ISO-BMFF box: its own size, its type, its content."""

    return (len(payload) + 8).to_bytes(4, "big") + kind + payload


def _ftyp(major: bytes, compatible) -> bytes:
    return _box(
        b"ftyp", major + (0).to_bytes(4, "big") + b"".join(compatible)
    )


def _meta_pict() -> bytes:
    """A ``meta`` box holding the ``pict`` handler every HEIF image carries."""

    handler = _box(
        b"hdlr",
        bytes(4)  # version and flags
        + bytes(4)
        + b"pict"
        + bytes(12)
        + b"LocalCanvas\x00",
    )
    return _box(b"meta", bytes(4) + handler)


def _isobmff(major: bytes, compatible, *, image: bool) -> bytes:
    body = _ftyp(major, compatible)
    if image:
        body += _meta_pict()
    return body + _box(b"mdat", bytes(range(64)) * 2)


#: An iOS-shaped HEIC: major brand ``heic``, ``mif1`` among its compatibles.
HEIC = _isobmff(b"heic", [b"mif1", b"heic", b"miaf", b"MiHB"], image=True)

#: An Android-shaped HEIF: major brand ``mif1``.
HEIF = _isobmff(b"mif1", [b"mif1", b"miaf", b"MiHB"], image=True)

#: A ``mif1``-major file that names ``heic`` among its compatible brands, which
#: is what a phone that writes HEVC-coded images into a generic container does.
HEIF_WITH_HEIC_COMPATIBLE = _isobmff(
    b"mif1", [b"mif1", b"miaf", b"heic"], image=True
)

#: Not an image, and it opens exactly like one.
MP4 = _isobmff(b"isom", [b"isom", b"iso2", b"avc1", b"mp41"], image=False)

#: Nor is this: QuickTime's brand, which is what an iPhone video carries.
MOV = _isobmff(b"qt  ", [b"qt  "], image=False)

#: An AVIF still.  A real image, a real ISO-BMFF file -- and outside the closed
#: set of what this gateway stores, so it is refused like anything else outside
#: it rather than written under an extension the set does not contain.
AVIF = _isobmff(b"avif", [b"avif", b"mif1", b"miaf"], image=True)

#: A 3GPP clip, in the shape a phone writes one: major brand ``3gp4``, and
#: ``isom`` and ``mp41`` among its compatible brands -- which is the temptation
#: on the video side.  A sniffer that scanned the compatible list would answer
#: ``video/mp4`` and store this clip as ``.mp4``.
THREE_GP = _isobmff(b"3gp4", [b"3gp4", b"3gp5", b"isom", b"mp41"], image=False)

#: A HEIF **image sequence**: several still photographs in one ISO-BMFF file,
#: which is what a phone's burst or motion photo is.  Its major brand ``msf1``
#: is an image brand, and ``iso8`` -- an ISO base media brand this gateway knows
#: as an MP4 -- is among its compatibles.  So it is the temptation with the cost
#: on the other foot: a video sniffer that scanned the compatible list would
#: take somebody's photographs for a film and store them as ``.mp4``.
HEIF_SEQUENCE = _isobmff(b"msf1", [b"msf1", b"iso8", b"hevc", b"mif1"], image=True)

#: Every major brand a HEIC or HEIF photograph may open with, written out here
#: rather than read off the gateway's table: the HEVC-coded ``heic``/``heix``/
#: ``heim``/``heis``, their image-sequence forms ``hevc``/``hevx``/``hevm``/
#: ``hevs``, and the plain HEIF ``mif1``, ``mif2`` and ``msf1``.  One real ISO
#: base media file per brand, keyed by it, each carrying the ``pict`` handler
#: and naming ``mif1`` and ``miaf`` among its compatibles the way a camera does.
#: Since T-0127 the brand decides which sentence a person is shown, so a brand
#: without a file here is a brand whose refusal nothing checks.
HEIF_IMAGE_BRANDS = (
    b"heic", b"heix", b"heim", b"heis",
    b"hevc", b"hevx", b"hevm", b"hevs",
    b"mif1", b"mif2", b"msf1",
)
HEIF_BY_BRAND = {
    brand: _isobmff(brand, [brand, b"mif1", b"miaf"], image=True)
    for brand in HEIF_IMAGE_BRANDS
}

#: The MP4 major brands the video table did not carry until T-0162: ``mp4v``,
#: an MP4 brand like ``mp41``, and ``iso3``, ``iso7``, ``iso9`` and ``isoa``,
#: ISO/IEC 14496-12's own revisions beside the ``isoN`` brands it already knew.
#: One real ISO base media file per brand, keyed by it, each naming ``isom``
#: among its compatibles the way a muxer does.
MP4_BRANDS_THE_TABLE_WAS_MISSING = (b"mp4v", b"iso3", b"iso7", b"iso9", b"isoa")
MP4_BY_ADDED_BRAND = {
    brand: _isobmff(brand, [brand, b"isom"], image=False)
    for brand in MP4_BRANDS_THE_TABLE_WAS_MISSING
}

#: A 3GPP2 clip: major brand ``3g2a``.  ``video/3gpp2`` is not in the closed
#: set, so this is refused -- and writing it out as ``.3gp`` would be a lie.
THREE_GPP2 = _isobmff(b"3g2a", [b"3g2a"], image=False)

#: An Apple M4V in the shape iTunes writes one: major brand ``M4V `` and ``mp42``
#: and ``isom`` -- brands this gateway knows as an MP4 -- among its compatibles.
#: ``video/x-m4v`` is not in the closed set, so this is refused, and the
#: compatibles are the temptation to store it as ``.mp4`` anyway.
M4V = _isobmff(b"M4V ", [b"M4V ", b"M4A ", b"mp42", b"isom"], image=False)


def _mvhd() -> bytes:
    """A QuickTime movie header: version 0, 100 bytes of payload.

    Version and flags, creation and modification times, a time scale of 600
    and a duration of one second, the preferred rate 1.0 and volume 1.0, ten
    reserved bytes, the identity matrix in 16.16 and 2.30 fixed point, the six
    preview, poster and selection fields, and the next track id.
    """

    identity = b"".join(
        value.to_bytes(4, "big")
        for value in (0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
    )
    return _box(
        b"mvhd",
        bytes(4)  # version 0, no flags
        + bytes(8)  # creation and modification time
        + (600).to_bytes(4, "big")
        + (600).to_bytes(4, "big")
        + (0x10000).to_bytes(4, "big")  # rate 1.0
        + (0x100).to_bytes(2, "big")  # volume 1.0
        + bytes(10)
        + identity
        + bytes(24)
        + (2).to_bytes(4, "big"),  # next track id
    )


#: Legacy QuickTime movies, which have **no** ``ftyp`` box: it is optional in
#: QuickTime, and a file written before it existed opens with its movie box, or
#: with a ``wide`` placeholder and the media data.  Both shapes, each a real box
#: chain.  They are refused -- there is no signature here this gateway reads,
#: and recognising one is a structural walk, which is its own decision.
QUICKTIME_WITHOUT_FTYP_MOOV_FIRST = _box(b"moov", _mvhd()) + _box(
    b"mdat", bytes(range(64)) * 2
)
QUICKTIME_WITHOUT_FTYP_WIDE_FIRST = (
    _box(b"wide", b"") + _box(b"mdat", bytes(range(64)) * 2) + _box(b"moov", _mvhd())
)


# -- EBML: WebM, Matroska, and the EBML files that are neither ---------------


def _vint(value: int, *, length: int = 1) -> bytes:
    """One EBML variable-length integer.

    The leading zeroes of the first byte count the bytes that follow it, so the
    number carries its own length.  An all-ones value is reserved -- it means
    "unknown" -- so a value that would come out as one takes a longer form.
    """

    while value >= (1 << (7 * length)) - 1:
        length += 1
    return (value | (1 << (7 * length))).to_bytes(length, "big")


def _ebml(element_id: int, payload: bytes) -> bytes:
    """One EBML element: its id as the specification tabulates it, size, content.

    The id is written with its own marker bits, which is the form ``DocType``
    is ``0x4282`` in.  The size is computed from the payload, never written out:
    an element whose declared size were a literal would be the thing this module
    exists not to build.
    """

    identifier = element_id.to_bytes((element_id.bit_length() + 7) // 8, "big")
    return identifier + _vint(len(payload)) + payload


def _ebml_uint(element_id: int, value: int) -> bytes:
    width = max(1, (value.bit_length() + 7) // 8)
    return _ebml(element_id, value.to_bytes(width, "big"))


def _ebml_segment() -> bytes:
    """The Segment every one of these documents carries, with its Info element."""

    info = (
        _ebml_uint(0x2AD7B1, 1000000)  # TimestampScale: one millisecond
        + _ebml(0x4D80, b"LocalCanvas")  # MuxingApp
        + _ebml(0x5741, b"LocalCanvas")  # WritingApp
    )
    return _ebml(0x18538067, _ebml(0x1549A966, info))  # Segment > Info


def _ebml_document(doctype: bytes, *, before_the_doctype: bytes = b"") -> bytes:
    """A real EBML document: the header, and a Segment with an Info element.

    ``before_the_doctype`` puts padding ahead of the ``DocType`` element, which
    is how a file whose DocType sits past the gateway's peek is made.  EBML
    allows it -- ``Void`` is a real element, and its whole purpose is to occupy
    space -- so the resulting file is a valid document that simply cannot be
    identified from 64 bytes.
    """

    header = _ebml(
        0x1A45DFA3,
        before_the_doctype
        + _ebml_uint(0x4286, 1)  # EBMLVersion
        + _ebml_uint(0x42F7, 1)  # EBMLReadVersion
        + _ebml_uint(0x42F2, 4)  # EBMLMaxIDLength
        + _ebml_uint(0x42F3, 8)  # EBMLMaxSizeLength
        + _ebml(0x4282, doctype)  # DocType
        + _ebml_uint(0x4287, 4)  # DocTypeVersion
        + _ebml_uint(0x4285, 2),  # DocTypeReadVersion
    )
    return header + _ebml_segment()


def _ebml_declaring_less_than_it_holds(doctype: bytes) -> bytes:
    """A header whose own size covers two elements, with the DocType after it.

    The near miss for the *other* bound.  ``_ebml_video_type`` stops at two
    things -- :data:`SNIFF_BYTES`, which
    :data:`MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK` is about, and **the header's
    own declared size**, which is this one.  Here the DocType is at byte 13,
    well inside the peek, and outside the header that is supposed to contain it:
    a walk that ran to the end of what it had rather than to the end of the
    header would read a ``DocType`` this document does not declare.

    It is not a file a muxer writes.  It is the shape that tells a bounded walk
    from an unbounded one, which is the only thing a near miss is for.
    """

    declared = _ebml_uint(0x4286, 1) + _ebml_uint(0x42F7, 1)
    beyond = (
        _ebml(0x4282, doctype)  # DocType, outside the header's declared size
        + _ebml_uint(0x42F2, 4)
        + _ebml_uint(0x42F3, 8)
        + _ebml_uint(0x4287, 4)
        + _ebml_uint(0x4285, 2)
    )
    header = (0x1A45DFA3).to_bytes(4, "big") + _vint(len(declared)) + declared + beyond
    return header + _ebml_segment()


def _void(size: int) -> bytes:
    """``Void``, the element EBML has for exactly this: space that means nothing."""

    return _ebml(0xEC, bytes(size))


#: A WebM.  Every WebM is also a valid Matroska file -- the two share their four
#: magic bytes and their whole syntax -- so what tells them apart is this
#: ``DocType`` and nothing else.
WEBM = _ebml_document(b"webm")

#: A Matroska.  Byte for byte the same shape as the WebM above except for the
#: eight characters of its DocType, which is the point: a sniffer that ignored
#: the DocType would store this as ``.webm``.
MATROSKA = _ebml_document(b"matroska")

#: A real EBML document whose DocType is neither.  ``webm2`` is not a DocType
#: anybody writes; it is chosen to *begin* with ``webm``, because a sniffer that
#: matched a prefix or searched for the four letters anywhere in the header
#: would take this for a WebM.  The container around it is as real as the two
#: above.
EBML_DOCTYPE_THAT_ONLY_BEGINS_WITH_WEBM = _ebml_document(b"webm2")

#: A real Matroska with 50 bytes of ``Void`` pushed in front of its DocType, so
#: the DocType lands past the 64 bytes the gateway peeks at.  It is refused, and
#: that refusal is the bound rather than the file: the same document without the
#: padding is :data:`MATROSKA` and is accepted.
MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK = _ebml_document(
    b"matroska", before_the_doctype=_void(48)
)

#: The other bound: a ``webm`` DocType at byte 13 -- inside the peek -- and
#: outside the header that is supposed to declare it.
EBML_DECLARING_LESS_THAN_IT_HOLDS = _ebml_declaring_less_than_it_holds(b"webm")


# -- MPEG: a program stream, an elementary stream, and a transport stream ----


class _Bits:
    """A bit-level writer.  MPEG's headers are not byte-aligned and this is why.

    Every field below is written at the width the specification gives it, so the
    marker bits land where a decoder looks for them instead of where a
    hand-written constant happened to put them.
    """

    def __init__(self) -> None:
        self._value = 0
        self._length = 0

    def write(self, value: int, width: int) -> "_Bits":
        assert 0 <= value < (1 << width), (value, width)
        self._value = (self._value << width) | value
        self._length += width
        return self

    def bytes(self) -> bytes:
        assert self._length % 8 == 0, self._length
        return self._value.to_bytes(self._length // 8, "big")


#: Filler for the coded picture data.  It contains no zero byte at all, so
#: nothing inside it can be read as a start code -- a start code is three of
#: them followed by an identifier, and a fixture that accidentally contained one
#: would make a walk over start codes prove nothing.
_MPEG_FILLER = bytes(range(1, 61))


def _mpeg_elementary_stream(width: int, height: int) -> bytes:
    """An MPEG-1 video elementary stream: sequence, GOP, picture, slice, end.

    ISO/IEC 11172-2's own layout, bit for bit: the sequence header carries the
    picture size, the aspect ratio and the frame rate code in the 12- and
    4-bit fields it defines them in, and every start code that follows is where
    the previous structure's own length puts it.
    """

    sequence = (
        _Bits()
        .write(width, 12)
        .write(height, 12)
        .write(1, 4)  # aspect ratio: square pixels
        .write(3, 4)  # frame rate code 3: 25 frames per second
        .write(104000, 18)  # bit rate, in units of 400 bits per second
        .write(1, 1)  # marker bit
        .write(20, 10)  # VBV buffer size
        .write(1, 1)  # constrained parameters
        .write(0, 1)  # no intra quantiser matrix
        .write(0, 1)  # no non-intra quantiser matrix
        .bytes()
    )
    group = (
        _Bits()
        .write(0, 1)  # drop frame
        .write(0, 5)  # hours
        .write(0, 6)  # minutes
        .write(1, 1)  # marker bit
        .write(0, 6)  # seconds
        .write(0, 6)  # pictures
        .write(1, 1)  # closed GOP
        .write(0, 1)  # broken link
        .write(0, 5)  # to the byte boundary
        .bytes()
    )
    picture = (
        _Bits()
        .write(0, 10)  # temporal reference
        .write(1, 3)  # coding type 1: an I picture
        .write(0xFFFF, 16)  # VBV delay
        .write(0, 1)  # no extra picture information
        .write(0, 2)  # to the byte boundary
        .bytes()
    )
    slice_header = (
        _Bits()
        .write(8, 5)  # quantiser scale
        .write(0, 1)  # no extra slice information
        .write(0, 2)  # to the byte boundary
        .bytes()
    )
    return (
        b"\x00\x00\x01\xb3" + sequence
        + b"\x00\x00\x01\xb8" + group
        + b"\x00\x00\x01\x00" + picture
        + b"\x00\x00\x01\x01" + slice_header + _MPEG_FILLER
        + b"\x00\x00\x01\xb7"  # sequence end
    )


def _mpeg_program_stream(payload: bytes) -> bytes:
    """An MPEG-1 system stream: pack header, system header, one PES, end code.

    This is what a ``.mpg`` or ``.mpeg`` file off a DVD or an old camcorder is,
    and its first four bytes -- the pack start code -- are what the gateway
    identifies it by.  The lengths below are computed from the content, so a
    walk that follows them arrives exactly at the end code.
    """

    pack = (
        _Bits()
        .write(0b0010, 4)
        .write(0, 3)  # system clock reference, bits 32..30
        .write(1, 1)  # marker bit
        .write(0, 15)  # bits 29..15
        .write(1, 1)  # marker bit
        .write(0, 15)  # bits 14..0
        .write(1, 1)  # marker bit
        .write(1, 1)  # marker bit
        .write(3528, 22)  # mux rate, in units of 50 bytes per second
        .write(1, 1)  # marker bit
        .bytes()
    )
    system = (
        _Bits()
        .write(1, 1)  # marker bit
        .write(3528, 22)  # rate bound
        .write(1, 1)  # marker bit
        .write(0, 6)  # audio bound
        .write(0, 1)  # fixed flag
        .write(1, 1)  # CSPS flag
        .write(0, 1)  # system audio lock
        .write(1, 1)  # system video lock
        .write(1, 1)  # marker bit
        .write(1, 5)  # video bound
        .write(0xFF, 8)  # reserved
        .write(0xE0, 8)  # stream id: video stream 0
        .write(0b11, 2)
        .write(1, 1)  # buffer bound scale: units of 1024 bytes
        .write(46, 13)  # buffer size bound
        .bytes()
    )
    pes_payload = b"\x0f" + payload  # no PTS and no DTS on this packet
    return (
        b"\x00\x00\x01\xba" + pack
        + b"\x00\x00\x01\xbb" + len(system).to_bytes(2, "big") + system
        + b"\x00\x00\x01\xe0" + len(pes_payload).to_bytes(2, "big") + pes_payload
        + b"\x00\x00\x01\xb9"  # ISO 11172 end code
    )


#: A bare video elementary stream, and the system stream that carries one.
MPEG_ELEMENTARY_STREAM = _mpeg_elementary_stream(320, 240)
MPEG_PROGRAM_STREAM = _mpeg_program_stream(MPEG_ELEMENTARY_STREAM)

#: The two near misses ``video/mpeg`` needs, and they are not invented: each is
#: the **last four bytes of the fixture above it** -- a real MPEG start code, and
#: one that ends a stream rather than beginning one.  ``00 00 01`` is three
#: bytes of prefix shared by every start code there is, so a sniffer that
#: stopped there would take a file that begins with an end code for a film.
MPEG_SEQUENCE_END_ALONE = MPEG_ELEMENTARY_STREAM[-4:] + _MPEG_FILLER
MPEG_PROGRAM_END_ALONE = MPEG_PROGRAM_STREAM[-4:] + _MPEG_FILLER


#: One transport stream packet, and there are 188 bytes in every one of them.
TS_PACKET_BYTES = 188

#: The PID a program association table always has, and the two this file picks
#: for its program map and its video.
TS_PAT_PID = 0x0000
TS_PMT_PID = 0x1000
TS_VIDEO_PID = 0x0100

#: MPEG-1 video, as a program map table names a stream type.
TS_STREAM_TYPE_MPEG1_VIDEO = 0x01


def mpeg_crc32(data: bytes) -> int:
    """The CRC-32 an MPEG-2 section carries: polynomial 0x04C11DB7, unreflected.

    Written out rather than taken from ``zlib``, because ``zlib.crc32`` is the
    reflected Ethernet variant and is a different number.  It is here rather
    than in the test because a section has to be *built* with it; the test
    recomputes it independently over the bytes it walks.
    """

    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc


def _psi_section(table_id: int, extension: int, body: bytes) -> bytes:
    """One program-specific information section, with its own length and CRC."""

    section_length = 5 + len(body) + 4  # the five bytes below, the body, the CRC
    head = (
        bytes((table_id,))
        + ((0b1011 << 12) | section_length).to_bytes(2, "big")
        + extension.to_bytes(2, "big")
        + bytes((0xC1, 0x00, 0x00))  # version 0, current, section 0 of 0
        + body
    )
    return head + mpeg_crc32(head).to_bytes(4, "big")


def _ts_packet(pid: int, payload: bytes, *, start: bool = True, counter: int = 0) -> bytes:
    """One 188-byte packet: sync byte, PID, continuity counter, payload.

    Short payloads are stuffed with ``0xff``, which is what a real multiplexer
    does after a section.
    """

    assert len(payload) <= TS_PACKET_BYTES - 4, len(payload)
    header = (
        bytes((0x47,))
        + (((0x4000 if start else 0) | pid)).to_bytes(2, "big")
        + bytes((0x10 | (counter & 0x0F),))  # payload only, no adaptation field
    )
    return header + payload.ljust(TS_PACKET_BYTES - 4, b"\xff")


def _transport_stream() -> bytes:
    """A real MPEG transport stream: a PAT, the PMT it points at, and a PES.

    Everything cross-references: the program association table names the PID of
    the program map table, the program map table names the PID the video is on,
    and both sections carry the CRC-32 that makes them checkable rather than
    merely plausible.  It exists to be **refused** -- ``video/mp2t`` is not in
    the closed set and ``.mpeg`` would not describe it -- so it has to be real,
    or the refusal would be a refusal of noise.
    """

    pat = _psi_section(
        0x00, 1, (0x0001).to_bytes(2, "big") + (0xE000 | TS_PMT_PID).to_bytes(2, "big")
    )
    pmt = _psi_section(
        0x02,
        1,
        (0xE000 | TS_VIDEO_PID).to_bytes(2, "big")  # PCR PID
        + (0xF000).to_bytes(2, "big")  # no program info
        + bytes((TS_STREAM_TYPE_MPEG1_VIDEO,))
        + (0xE000 | TS_VIDEO_PID).to_bytes(2, "big")
        + (0xF000).to_bytes(2, "big"),  # no elementary stream info
    )
    video = MPEG_ELEMENTARY_STREAM.ljust(TS_PACKET_BYTES - 4 - 7, b"\xff")
    pes = b"\x00\x00\x01\xe0" + (len(video) + 1).to_bytes(2, "big") + b"\x0f" + video
    return (
        _ts_packet(TS_PAT_PID, b"\x00" + pat)
        + _ts_packet(TS_PMT_PID, b"\x00" + pmt)
        + _ts_packet(TS_VIDEO_PID, pes, counter=0)
    )


#: The third thing ``video/mpeg`` can mean, and the one this gateway refuses.
TRANSPORT_STREAM = _transport_stream()


# -- things that are not media at all --------------------------------------

#: Each carries its own format's real signature, so a "refused" here is the
#: sniffer failing to recognise a *file*, not failing to recognise noise.
#:
#: The last five are **near misses**, and a signature is only worth the byte it
#: stops at.  ``avi`` and ``wave`` are real RIFF files: their first four bytes
#: are a WebP's to the byte, and the form type at bytes 8-11 is not ``WEBP``.
#: The damaged PNG is this repository's own launcher icon after an ASCII-mode
#: transfer, which is the accident PNG's four trap bytes exist to catch.  The
#: two ``BM`` files are a BMP's first two bytes and no more: a text file, and
#: the real BMP with a DIB header size the format does not define.  A sniffer
#: that read ``RIFF`` alone, the first four bytes of PNG's signature alone, or
#: ``BM`` alone, would accept them and write them into ComfyUI's input
#: directory under an extension that describes nothing.
NOT_MEDIA = {
    "pdf": b"%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n",
    "zip": b"PK\x03\x04\x14\x00\x00\x00\x08\x00" + bytes(64),
    "windows executable": b"MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff"
    + bytes(64),
    "elf executable": b"\x7fELF\x02\x01\x01\x00" + bytes(64),
    "utf-8 text": "a prompt, not a picture\n".encode("utf-8") * 4,
    "svg": b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>',
    "gzip": b"\x1f\x8b\x08\x00" + bytes(64),
    "ebml magic and nothing after it": b"\x1aE\xdf\xa3" + bytes(64),
    "avi": AVI,
    "wave": _wave(),
    "png damaged in a text-mode transfer": _text_mode_transfer(png_bytes()),
    "text beginning bm": TEXT_BEGINNING_BM,
    "bmp declaring an undefined header size": BMP_DECLARING_AN_UNDEFINED_HEADER_SIZE,
}

#: The entries of :data:`NOT_MEDIA` that are not images and **are** videos, so
#: that the video side can take the rest of that dict as its own refusal corpus
#: without hand-copying it.  One name, and a test asserts that the exclusion is
#: earned -- that what is named here really is identified as a video -- because
#: a list of exclusions nobody checks is how a body quietly stops being tested.
VIDEOS_IN_NOT_MEDIA = ("avi",)

#: The video side's own near misses: files that reach one byte further into a
#: signature than anything in :data:`NOT_MEDIA` does, and stop.  Every one is a
#: real container or is derived from one, and every one exists because a
#: sniffer that read one byte less would accept it:
#:
#: * ``webp`` -- a RIFF whose form type is a picture's, which the AVI's own
#:   builder produced;
#: * ``rifx avi`` -- the AVI in RIFF's big-endian form: ``AVI `` at bytes 8-11
#:   to the byte, and not ``RIFF`` in front of it;
#: * ``ebml whose doctype only begins with webm`` -- four letters are not a
#:   DocType;
#: * ``matroska whose doctype is past the peek`` and ``ebml declaring less than
#:   it holds`` -- the two bounds the DocType walk stops at, one of them
#:   :data:`SNIFF_BYTES` and the other the header's own declared size;
#: * ``mpeg sequence end alone`` and ``mpeg program end alone`` -- real start
#:   codes that end a stream rather than beginning one, so the fourth byte is
#:   load-bearing and ``00 00 01`` alone is not an answer;
#: * ``avif`` and ``heif image sequence`` -- ISO base media whose major brand is
#:   a photograph's, the second naming an MP4 brand among its compatibles;
#: * ``mpeg transport stream`` -- the whole of the ``video/mpeg`` decision:
#:   real, structurally checkable, and outside the closed set;
#: * ``3gpp2`` and ``m4v`` -- ISO base media whose major brand is a video
#:   format outside the closed set, the second naming MP4 brands among its
#:   compatibles (T-0162 kept both refused);
#: * ``quicktime without ftyp, moov first`` and ``..., wide first`` -- real
#:   legacy QuickTime movies with no ``ftyp`` box for a brand to be read from.
VIDEO_NEAR_MISSES = {
    "webp": WEBP,
    "rifx avi": RIFX_AVI,
    "ebml whose doctype only begins with webm": EBML_DOCTYPE_THAT_ONLY_BEGINS_WITH_WEBM,
    "matroska whose doctype is past the peek": MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK,
    "ebml declaring less than it holds": EBML_DECLARING_LESS_THAN_IT_HOLDS,
    "mpeg sequence end alone": MPEG_SEQUENCE_END_ALONE,
    "mpeg program end alone": MPEG_PROGRAM_END_ALONE,
    "avif": AVIF,
    "heif image sequence": HEIF_SEQUENCE,
    "mpeg transport stream": TRANSPORT_STREAM,
    "3gpp2": THREE_GPP2,
    "m4v": M4V,
    "quicktime without ftyp, moov first": QUICKTIME_WITHOUT_FTYP_MOOV_FIRST,
    "quicktime without ftyp, wide first": QUICKTIME_WITHOUT_FTYP_WIDE_FIRST,
}

#: Files the **video** half must refuse, each a real file of some other kind:
#: every non-video entry of :data:`NOT_MEDIA`, derived rather than retyped, and
#: every near miss above.
#:
#: Both halves are guarded in ``test_media_sniffing.py`` rather than trusted.
#: The derived half is guarded by :data:`VIDEOS_IN_NOT_MEDIA` having to be
#: earned; the near misses are named there verbatim, because there is no other
#: source of truth for what belongs here and an entry that quietly left the
#: corpus would take its whole refusal with it.
NOT_VIDEO = dict(
    [
        (name, data)
        for name, data in NOT_MEDIA.items()
        if name not in VIDEOS_IN_NOT_MEDIA
    ]
    + list(VIDEO_NEAR_MISSES.items())
)


__all__ = [
    "AVI",
    "AVIF",
    "BMP",
    "BMP_BY_HEADER_SIZE",
    "BMP_DECLARING_AN_UNDEFINED_HEADER_SIZE",
    "BMP_DIB_HEADER_SIZES",
    "BMP_WITH_A_WRONG_FILE_SIZE",
    "EBML_DECLARING_LESS_THAN_IT_HOLDS",
    "EBML_DOCTYPE_THAT_ONLY_BEGINS_WITH_WEBM",
    "GIF",
    "GIF87A",
    "GIF89A",
    "HEIC",
    "HEIF",
    "HEIF_BY_BRAND",
    "HEIF_IMAGE_BRANDS",
    "HEIF_SEQUENCE",
    "HEIF_WITH_HEIC_COMPATIBLE",
    "JPEG",
    "MATROSKA",
    "M4V",
    "MATROSKA_WITH_ITS_DOCTYPE_PAST_THE_PEEK",
    "MOV",
    "MP4",
    "MP4_BRANDS_THE_TABLE_WAS_MISSING",
    "MP4_BY_ADDED_BRAND",
    "MPEG_ELEMENTARY_STREAM",
    "MPEG_PROGRAM_END_ALONE",
    "MPEG_PROGRAM_STREAM",
    "MPEG_SEQUENCE_END_ALONE",
    "NOT_MEDIA",
    "NOT_VIDEO",
    "PNG_PATH",
    "QUICKTIME_WITHOUT_FTYP_MOOV_FIRST",
    "QUICKTIME_WITHOUT_FTYP_WIDE_FIRST",
    "REPO_ROOT",
    "RIFX_AVI",
    "TEXT_BEGINNING_BM",
    "THREE_GP",
    "THREE_GPP2",
    "TRANSPORT_STREAM",
    "TS_PACKET_BYTES",
    "TS_PAT_PID",
    "TS_PMT_PID",
    "TS_STREAM_TYPE_MPEG1_VIDEO",
    "TS_VIDEO_PID",
    "VIDEO_NEAR_MISSES",
    "VIDEOS_IN_NOT_MEDIA",
    "WEBM",
    "WEBP",
    "mpeg_crc32",
    "png_bytes",
]
