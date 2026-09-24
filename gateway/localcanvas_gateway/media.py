"""The temporary media store, and the resolver that fills T-0002's seam.

`docs/api.md` contracts ``POST /api/v1/media``: one file plus its ``kind``,
answered with a ``media_id`` document.  This module owns everything behind that
sentence -- what is accepted, where the bytes live, how long they live, and how
a ``media_id`` becomes the value a ComfyUI loader input expects.

**This is not a library.**  There is no listing endpoint, no permanent store and
no server-side gallery; those are explicit non-goals.  A reaped file is gone,
and a job that references one fails with a field-attributed error rather than
generating from nothing.

Four rules shape the code below.

**What a file is, the file says.**  An upload arrives with a declared content
type and a filename, and both of them are the client's word.  A picture chosen
on a phone comes labelled ``image/jpeg`` by one app, ``image/jpg`` by the next
and ``application/octet-stream`` by the picker that will not commit -- the same
photograph each time -- so a gateway that decides from the label decides from
the least trustworthy thing in the request.  This one reads the head of the
body and takes the answer from the magic number
(:func:`sniff_image_type`, :func:`sniff_video_type`).  That is *stricter* than
believing the label, not looser: the extension the stored file gets now
describes what the bytes are, so no client can have something written into
ComfyUI's input directory under an extension that lies about it.  The set of
what may be stored does not widen -- :data:`ALLOWED_TYPES` is still the whole
of it, and a file matching nothing in it is still refused with
``unsupported_media_type`` -- or, for a HEIC or HEIF photograph the bytes
identify, with ``unsupported_image_heic`` and a sentence that says what to
choose instead (:data:`NAMED_IMAGE_REFUSALS`, T-0127).

Both kinds are decided this way.  The image half arrived first (T-0126) and the
video half followed it (T-0129), for the same reason and against the same
measured defect: a clip picked out of an Android gallery arrives labelled
``application/octet-stream`` or with no type at all just as a photograph does,
and a client that declared ``video/mp4`` could have any body at all written
into ComfyUI's input directory under ``.mp4``.  The **declared content type is
now consulted nowhere** -- :func:`decided_content_type` does not take one.

**A filename from a phone is untrusted input.**  It is never joined into a
path -- not after sanitising, not "just for the extension".  The name on disk is
derived from the gateway's own ``media_id`` and from the *content type it read
out of the file*, so a name that escapes the store cannot be constructed even
if the checks in :func:`checked_filename` were all removed.  The checks exist anyway,
because a hostile name should be refused out loud rather than quietly renamed:
a user whose picture came back under a different name learned nothing, and a
client sending ``..\\..\\autoexec.bat`` should be told no.

**The gateway never learns ComfyUI's filesystem layout.**  Resolution goes
through ComfyUI's own ``POST /upload/image`` endpoint, which answers with the
name and subfolder it actually stored the file under; the bound value is
composed from *that* answer and nothing else.  No input directory is
configured, searched for or guessed at (`docs/architecture.md`).

**The residue is stated, and clearable in one action.**  ComfyUI keeps those
files and offers no way to delete one, and LocalCanvas never writes to or
deletes from a user's ComfyUI installation.  So they are all asked into a single
:data:`COMFY_INPUT_SUBFOLDER` rather than scattered among the user's own inputs:
they still accumulate, and one folder is what makes emptying them a single
action (`docs/privacy-security.md`, "Data handling").

**Nothing here runs on a timer.**  Expiry is applied when the store is next
touched, in the same spirit as the job store's lazy refresh: no background
thread, and an answer that was true at the moment it was asked for.
"""

from __future__ import annotations

import logging
import re
import secrets
import shutil
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass, field as dataclass_field
from datetime import datetime, timezone
from itertools import chain
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import (
    TYPE_CHECKING,
    Any,
    Callable,
    Dict,
    Iterable,
    Iterator,
    Mapping,
    Optional,
)

from .errors import ApiError, ValidationFailure

if TYPE_CHECKING:  # pragma: no cover - types only
    # Only ever a type here, and kept out of the runtime import graph on
    # purpose: `config.py` imports this module for the store's default limits,
    # and configuration has no business loading the workflow registry to read
    # a YAML file.  ``from __future__ import annotations`` above is what makes
    # the annotations below strings, so nothing needs it at run time.
    from .workflows import InputField

log = logging.getLogger(__name__)


#: The two kinds a media field can be (`docs/workflow-schema.md`).
MEDIA_KINDS = ("image", "video")

#: The shape of every id this gateway issues, as ``docs/api.md`` shows it:
#: ``m-3f9c1a``.  A reference that does not match it cannot have come from here,
#: which is the only media miss the gateway can speak about with certainty.
MEDIA_ID = re.compile(r"^m-[0-9a-f]{6}$")

#: What may be uploaded, and the extension the stored file gets.  The extension
#: comes from **here**, never from the uploaded filename: it is the one part of
#: the name that ends up on disk, so it is chosen from a closed set.  Which
#: entry of the set an upload lands on is decided from the file's own first
#: bytes -- :func:`sniff_image_type` for an image and :func:`sniff_video_type`
#: for a video -- and by nothing the client says.
#:
#: This list is about what the gateway is willing to put into ComfyUI's input
#: directory, not a claim about what any node can load -- which formats a
#: workflow understands is ComfyUI's business and the curator's, not this
#: module's.
#:
#: HEIC and HEIF are the one deliberate exception, and they are left out rather
#: than forgotten (T-0127).  A HEIC photograph is the default camera format on
#: a great many phones, and whether a ComfyUI install can read one depends on
#: an optional package the gateway cannot see -- so accepting it meant a person
#: picked a photo, waited, and got a generation failure that said nothing about
#: the format.  The sniffer still identifies both, and
#: :data:`NAMED_IMAGE_REFUSALS` turns that into a refusal at upload that says
#: what to do instead.
ALLOWED_TYPES: Mapping[str, Mapping[str, str]] = {
    "image": {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
        "image/gif": ".gif",
        "image/bmp": ".bmp",
    },
    "video": {
        "video/mp4": ".mp4",
        "video/quicktime": ".mov",
        "video/webm": ".webm",
        "video/x-matroska": ".mkv",
        "video/3gpp": ".3gp",
        "video/mpeg": ".mpeg",
        "video/x-msvideo": ".avi",
    },
}

#: Image types the sniffer identifies, that are outside :data:`ALLOWED_TYPES`,
#: and that are refused with a code and a sentence of their own rather than
#: the generic ``unsupported_media_type``: ``(code, message)`` per type.  What
#: decides is still the type read out of the bytes -- never the client's
#: label -- so a JPEG labelled ``image/heic`` is accepted as the JPEG it is,
#: and a HEIC labelled ``image/jpeg`` is refused by name.
NAMED_IMAGE_REFUSALS: Mapping[str, "tuple[str, str]"] = {
    media_type: (
        "unsupported_image_heic",
        "That photo is in HEIC/HEIF format, which LocalCanvas cannot use yet. "
        "Choose a JPEG or PNG, or turn off high-efficiency (HEIC) photos in the "
        "camera settings.",
    )
    for media_type in ("image/heic", "image/heif")
}

#: The sizes a BMP's DIB header is documented to have, read as the
#: little-endian ``uint32`` at byte 14 that opens the header:
#: ``BITMAPCOREHEADER`` (12), OS/2 2.x's short ``OS22XBITMAPHEADER`` (16: the
#: first 16 bytes of the full one, the rest taken as zero),
#: ``BITMAPINFOHEADER`` (40), the V2 and V3 info headers (52, 56), OS/2's full
#: ``OS22XBITMAPHEADER`` (64), ``BITMAPV4HEADER`` (108) and ``BITMAPV5HEADER``
#: (124).  A file beginning ``BM`` whose header declares any other size is not
#: a BMP this gateway stores (:func:`sniff_image_type`).
_BMP_DIB_HEADER_SIZES = frozenset({12, 16, 40, 52, 56, 64, 108, 124})

#: The brands an ISO base media file declares when it holds a still image.
#: One container carries many things -- an MP4 video opens byte for byte like a
#: HEIC photograph, ``ftyp`` and all -- so the brand is the whole of what tells
#: them apart, and a brand this gateway does not know is not an image it will
#: store.  ``heic``/``heix``/``hevc``/``hevx`` and their ``m``/``s`` variants
#: are HEVC-coded images; ``mif1``, ``mif2`` and ``msf1`` are the plain HEIF
#: image and image-sequence brands, which is what many Android cameras write.
#: Neither type is stored any more (T-0127): they are identified so that the
#: refusal can name the format (:data:`NAMED_IMAGE_REFUSALS`).
#: ``isom``, ``mp42`` and ``qt  `` are deliberately absent: they are videos,
#: they are looked up in :data:`_ISOBMFF_VIDEO_BRANDS` instead, and a request
#: that asked for an image gets the refusal any other non-image gets.  ``avif``
#: is absent because it is in neither set -- a real still image, outside
#: :data:`ALLOWED_TYPES` altogether, refused like anything else outside it.
#: Only a file's **major** brand is looked up here, for the reason
#: :func:`_isobmff_image_type` gives.
_ISOBMFF_IMAGE_BRANDS: Mapping[bytes, str] = {
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

#: The brands an ISO base media file declares when it holds a **video**.  The
#: same container, the same ``ftyp`` box and the same rule as
#: :data:`_ISOBMFF_IMAGE_BRANDS` above: only the **major** brand is looked up,
#: for the reason :func:`_isobmff_video_type` gives, and the two tables share
#: no entry, so one lookup cannot answer the other's question.
#:
#: ``isom`` and its ``isoN`` revisions (``iso2`` to ``iso9`` and ``isoa``),
#: ``mp41``/``mp42``/``mp4v``, ``avc1``, ``mmp4``, ``dash`` and ``MSNV`` are
#: the brands ordinary MP4 files carry -- an Android camera writes ``mp42`` or
#: ``isom``, an iPhone's exported MP4 ``mp42``.  ``qt  `` (with its two
#: trailing spaces) is QuickTime's own, which is what an iPhone's ``.mov``
#: carries.  The ``3g*`` family is 3GPP's, and is listed rather than matched by
#: prefix so that no brand is claimed by accident.
#:
#: **Three kinds of video file are refused here, deliberately**, and they are
#: not the same kind of absence.  Every one of them was, before this table
#: existed, accepted whenever the client named a type in the set -- and then
#: stored under an extension that did not describe it.
#:
#: Two are the closed set doing its job, and are costs rather than oversights:
#: **3GPP2** (``3g2a``, ``3g2b``, ``3g2c``) is ``video/3gpp2`` and **``M4V ``**
#: (with ``M4VH``, ``M4VP``) is ``video/x-m4v``, and neither type is in
#: :data:`ALLOWED_TYPES`.  Writing a ``.3g2`` out as ``.3gp`` is the lie this
#: module exists to stop.
#:
#: The third is a **legacy QuickTime movie with no ``ftyp`` box at all** --
#: ``ftyp`` is optional in QuickTime, and such a file opens with ``moov`` or
#: with ``wide``/``mdat`` -- so nothing here is even consulted and it is refused
#: for having no signature this gateway reads.  Recognising one means walking
#: its boxes, which is a structural check and a decision of its own.
#:
#: The table used to be **incomplete** as well, which was a different thing:
#: ``iso3``, ``iso7``, ``iso9`` and ``isoa`` -- ISO/IEC 14496-12's own later
#: revisions -- and ``mp4v`` are MP4 brands, ``video/mp4`` was already in the
#: set, and those files were refused only because nothing here named them.
#: T-0162 added them and decided the three above the other way.
_ISOBMFF_VIDEO_BRANDS: Mapping[bytes, str] = {
    **{
        brand: "video/mp4"
        for brand in (
            b"isom",
            b"iso2",
            b"iso3",
            b"iso4",
            b"iso5",
            b"iso6",
            b"iso7",
            b"iso8",
            b"iso9",
            b"isoa",
            b"mp41",
            b"mp42",
            b"mp4v",
            b"avc1",
            b"mmp4",
            b"dash",
            b"MSNV",
        )
    },
    b"qt  ": "video/quicktime",
    **{
        brand: "video/3gpp"
        for brand in (
            b"3gp1",
            b"3gp2",
            b"3gp3",
            b"3gp4",
            b"3gp5",
            b"3gp6",
            b"3gp7",
            b"3gp8",
            b"3gp9",
            b"3ge6",
            b"3ge9",
            b"3gg6",
            b"3gg9",
            b"3gh9",
            b"3gm9",
            b"3gr6",
            b"3gr9",
            b"3gs6",
            b"3gs9",
        )
    },
}

#: EBML's four-byte magic, which a WebM and a Matroska share to the byte.  What
#: tells them apart is the ``DocType`` element inside the EBML header, and it is
#: at no fixed offset (:func:`_ebml_video_type`).
_EBML_MAGIC = b"\x1aE\xdf\xa3"

#: ``DocType`` is a two-byte element id, ``0x4282``.
_EBML_DOCTYPE_ID = b"\x42\x82"

#: The two DocTypes in :data:`ALLOWED_TYPES`.  A ``webm`` is a profile of
#: Matroska and every one of them is also a valid Matroska file -- which is
#: exactly why the DocType is read rather than the magic: the file says which of
#: the two it is, and storing one under the other's extension would be the lie
#: this module exists to stop.  ``webm`` is not a substring match either: a
#: DocType of ``webm2`` is not ``webm``.
_EBML_DOCTYPES: Mapping[bytes, str] = {
    b"webm": "video/webm",
    b"matroska": "video/x-matroska",
}

#: MPEG's own start codes, and the whole of what ``video/mpeg`` means here.
#: ``00 00 01 ba`` opens a program stream (a ``.mpg``/``.mpeg`` from a DVD or an
#: old camcorder) and ``00 00 01 b3`` a bare video elementary stream.
#:
#: An MPEG **transport** stream is deliberately not here, and
#: :func:`sniff_video_type` says what that costs.
_MPEG_START_CODES = (b"\x00\x00\x01\xba", b"\x00\x00\x01\xb3")

#: How much of the head is enough to answer the question.  Eighteen bytes would
#: do for an image -- the longest thing read is a BMP's DIB header size, which
#: ends at byte 18, past WebP's form type and an ISO-BMFF major brand at byte
#: 12 -- and 64 is a round number well clear of that, and clear too of the EBML
#: header a WebM's
#: ``DocType`` sits inside (:func:`_ebml_video_type`, which is the one thing
#: here that has to *search* rather than look at an offset, and is bounded by
#: this number for that reason).  It costs nothing to ask for: the body arrives
#: in chunks of :data:`CHUNK_BYTES`, so the peek below takes one chunk either
#: way.
#:
#: It is a **peek**, and the number matters for that reason rather than for
#: precision: this many bytes are looked at before the body is written, and the
#: rest of the upload goes on streaming to disk exactly as it did before
#: (:meth:`MediaStore.store`).  A gateway that read the file to identify it
#: would hold a phone's video in memory, which is the thing ``chunks`` exists to
#: prevent.
SNIFF_BYTES = 64

MEGABYTE = 1024 * 1024

#: The store's policy, as a person would write it.  These are **defaults**, not
#: the rule: every one is a typed field of ``media:`` in ``runtime.yaml``
#: (`docs/runtime.md`), because a user whose phone shoots larger clips, or whose
#: PC has little free disk, must not have to edit source.  They
#: are declared here rather than in the loader because they are facts about this
#: store -- how big a phone video is, how long someone takes to write a prompt --
#: and :mod:`localcanvas_gateway.config` reads them from here so that there is
#: one definition of each and nothing to drift.
#:
#: Per-kind ceilings are generous rather than tight: the point is to stop an
#: unbounded write to the user's disk, not to second-guess a camera.
DEFAULT_MAX_IMAGE_MEGABYTES = 64
DEFAULT_MAX_VIDEO_MEGABYTES = 1024

#: The whole store's ceiling.  When a new upload would push past it the oldest
#: items are dropped first -- deliberately, and logged, because the alternative
#: is a temporary directory that grows until the disk is full.
DEFAULT_MAX_STORE_MEGABYTES = 4096

#: How long an uploaded file stays.  Long enough to pick an image, write a
#: prompt, get interrupted and come back; short enough that a phone's camera
#: roll does not accumulate on someone's PC.
DEFAULT_TTL_SECONDS = 3600.0

MAX_UPLOAD_BYTES: Mapping[str, int] = {
    "image": DEFAULT_MAX_IMAGE_MEGABYTES * MEGABYTE,
    "video": DEFAULT_MAX_VIDEO_MEGABYTES * MEGABYTE,
}
MAX_STORE_BYTES = DEFAULT_MAX_STORE_MEGABYTES * MEGABYTE
TTL_SECONDS = DEFAULT_TTL_SECONDS

#: Read size while the upload is written to disk.  The request body is never
#: held whole in memory.
CHUNK_BYTES = 256 * 1024

#: Characters Windows refuses in a filename, plus the separators.  A name
#: carrying one of these is refused rather than repaired.
_ILLEGAL_CHARACTERS = set('<>:"|?*/\\')

#: Unicode categories a filename may not contain: control, format,
#: surrogate and private-use.  :func:`checked_filename` says why each one.
_FORBIDDEN_CATEGORIES = frozenset({"Cc", "Cf", "Cs", "Co"})

#: Windows device names.  ``CON.txt`` is still ``CON``, so the stem is what is
#: checked.  These never reach the filesystem here -- the stored name is
#: gateway-generated -- but a client sending one is doing something that should
#: be answered with a refusal.
_RESERVED_WINDOWS_NAMES = (
    {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
    | {"COM{}".format(digit) for digit in range(0, 10)}
    | {"LPT{}".format(digit) for digit in range(0, 10)}
)

#: A filename longer than this is refused.  It is only ever echoed back to the
#: app, so the limit is about not storing junk, not about any filesystem's cap.
MAX_FILENAME_LENGTH = 200

#: What the file is called inside ComfyUI's input directory.  Built from the
#: gateway's own id and the accepted content type, so two phones uploading
#: ``IMG_0001.jpg`` cannot collide and neither name reaches a path.
_COMFY_UPLOAD_NAME = "{media_id}{extension}"

#: The subfolder of ComfyUI's input directory these files are asked to go in.
#:
#: They accumulate there and LocalCanvas cannot reap them: ComfyUI exposes no
#: delete for an input file, and LocalCanvas never writes to -- or deletes
#: from -- the user's ComfyUI installation.  That residue is
#: stated rather than quietly true (`docs/privacy-security.md`, "Data
#: handling"), and one folder is what makes it **clearable in one action**
#: instead of scattered among the user's own input files.
#:
#: It is a name handed to ComfyUI, not a path this gateway resolves: ComfyUI
#: decides where its input directory is and answers with the subfolder it
#: actually used, which is the half of the reference the resolver then binds.
COMFY_INPUT_SUBFOLDER = "localcanvas"


class MediaRejected(ApiError):
    """An upload the gateway will not accept, in the documented error shape."""

    def __init__(self, status_code: int, code: str, message: str, field: str) -> None:
        super().__init__(status_code=status_code, code=code, message=message, field=field)


@dataclass
class MediaItem:
    """One uploaded file the gateway is holding.

    ``resolved_value`` is the memo that makes a retried submission cheap: once
    this file has been handed to ComfyUI, the value its loader input takes is
    known and the file is not uploaded a second time.  It is gateway-side and
    never serialised -- :meth:`to_view` is the whole of what the app sees.
    """

    media_id: str
    kind: str
    filename: str
    content_type: str
    bytes: int
    path: Path
    created_at: float
    expires_at: float
    resolved_value: Optional[Any] = None
    lock: threading.Lock = dataclass_field(default_factory=threading.Lock, repr=False)

    @property
    def is_settled(self) -> bool:
        """False while this item's file is still open and being written.

        A reservation is in ``_items`` from the moment its id is claimed, with
        ``bytes`` still zero, so that no second upload can draw the same id.
        Housekeeping must leave it alone until its own writer is done with it:
        discarding it would unlink a file another thread has open -- which on
        Windows fails outright -- and drop the entry that writer is about to
        fill in, turning a routine eviction into a 500 and an orphaned file
        nothing will ever reap.  Its writer removes it on every failure path,
        so nothing leaks by waiting.
        """

        return self.bytes > 0

    @property
    def comfy_upload_name(self) -> str:
        """The name ComfyUI is *asked* to store this file under.

        Derived from the gateway's id and the accepted content type.  The
        uploaded filename is not part of it, by design.  Nor is this necessarily
        the name that ends up bound: ComfyUI renames rather than clobbering, and
        the resolver binds whatever it answers with.
        """

        return _COMFY_UPLOAD_NAME.format(
            media_id=self.media_id, extension=self.path.suffix
        )

    def to_view(self) -> Dict[str, Any]:
        """The document `docs/api.md` specifies, and nothing besides.

        No path, no store location, no resolved value: the app learns that its
        file arrived, how big it was and when it stops being usable.
        """

        return {
            "media_id": self.media_id,
            "kind": self.kind,
            "filename": self.filename,
            "bytes": self.bytes,
            "expires_at": _timestamp(self.expires_at),
        }


class MediaStore:
    """Temporary storage for uploaded media, owned by the gateway.

    The store directory is created by :mod:`tempfile` and belongs to this
    object: it is emptied by :meth:`close`, and every file inside it is named
    by this class.
    """

    def __init__(
        self,
        root: Optional[Path] = None,
        *,
        ttl_seconds: float = TTL_SECONDS,
        max_upload_bytes: Mapping[str, int] = MAX_UPLOAD_BYTES,
        max_store_bytes: int = MAX_STORE_BYTES,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._owns_root = root is None
        self.root = Path(root) if root is not None else Path(
            tempfile.mkdtemp(prefix="localcanvas-media-")
        )
        self.root.mkdir(parents=True, exist_ok=True)
        self.ttl_seconds = ttl_seconds
        self.max_upload_bytes = dict(max_upload_bytes)
        self.max_store_bytes = max_store_bytes
        self._clock = clock
        self._lock = threading.Lock()
        self._items: Dict[str, MediaItem] = {}

    # -- accepting ---------------------------------------------------------

    def store(
        self, *, kind: Any, filename: Any, content_type: Any, chunks: Iterable[bytes]
    ) -> MediaItem:
        """Validate and write one upload.  Raises :class:`MediaRejected`.

        ``chunks`` is consumed lazily and written straight to disk, so a video
        never exists whole in the gateway's memory.  The size ceiling is
        enforced *while* writing: an oversized body is abandoned partway rather
        than accepted and measured afterwards.

        ``content_type`` is the type the client declared.  It is accepted
        because the request carries one and is **consulted nowhere**: what the
        file is comes from the file (:func:`decided_content_type`, which is not
        given it), and what is recorded on the item is what was read out of the
        bytes.  It stays in this signature because a multipart part has a
        content type whether anyone believes it or not, and dropping it from
        here would push a change into the HTTP layer that has nothing to
        decide either.

        The head of the body is looked at before any of it is written, because
        the extension the file gets is read out of it (:func:`sniff_image_type`
        or :func:`sniff_video_type`) and the extension is part of the name
        reserved below.  That look is a
        **peek**, not a read: :func:`_peeked` takes chunks off the front until
        it holds :data:`SNIFF_BYTES`, hands the rest of the stream back
        untouched, and the loop below then writes the head and goes on
        streaming.  What is held is bounded by one chunk, whatever the size of
        the file.

        The order of the three refusals is deliberate.  An empty body is
        ``empty_upload`` and never anything else -- nothing can be identified in
        no bytes, so the question is not even asked.  Bytes that identify
        nothing this gateway stores are ``unsupported_media_type`` (or, for a
        HEIC or HEIF photograph, ``unsupported_image_heic``), decided from
        the peek, before a byte reaches the disk.  Size is the one thing that
        cannot be known from a head, so ``file_too_large`` is still raised while
        writing.
        """

        kind = checked_kind(kind)
        name = checked_filename(filename)

        head, rest = _peeked(chunks, SNIFF_BYTES)
        if not head:
            raise MediaRejected(
                status_code=400,
                code="empty_upload",
                message="That file was empty, so there is nothing to generate from.",
                field="file",
            )
        media_type, extension = decided_content_type(kind, head)

        self.reap()

        media_id, path = self._reserve(extension)
        limit = self.max_upload_bytes.get(kind, MAX_UPLOAD_BYTES[kind])
        written = 0
        try:
            with path.open("wb") as handle:
                for chunk in chain((head,), rest):
                    if not chunk:
                        continue
                    written += len(chunk)
                    if written > limit:
                        raise MediaRejected(
                            status_code=413,
                            code="file_too_large",
                            message="That {} is too large to send. The limit is {}.".format(
                                kind, _megabytes(limit)
                            ),
                            field="file",
                        )
                    handle.write(chunk)
        except BaseException:
            path.unlink(missing_ok=True)
            with self._lock:
                self._items.pop(media_id, None)
            raise

        now = self._clock()
        with self._lock:
            item = self._items[media_id]
            item.kind = kind
            item.filename = name
            item.content_type = media_type
            item.bytes = written
            item.created_at = now
            item.expires_at = now + self.ttl_seconds
            self._evict_over_capacity()
        log.info(
            "media %s accepted: %s, %s bytes, expires %s",
            media_id,
            media_type,
            written,
            _timestamp(item.expires_at),
        )
        return item

    def _reserve(self, extension: str) -> "tuple[str, Path]":
        """Claim an unused id and its path before any byte is written."""

        with self._lock:
            for _ in range(64):
                media_id = "m-" + secrets.token_hex(3)
                if media_id in self._items:
                    continue
                path = self.root / (media_id + extension)
                if path.exists():
                    continue
                now = self._clock()
                self._items[media_id] = MediaItem(
                    media_id=media_id,
                    kind="",
                    filename="",
                    content_type="",
                    bytes=0,
                    path=path,
                    created_at=now,
                    expires_at=now + self.ttl_seconds,
                )
                return media_id, path
        raise ApiError(  # pragma: no cover - 2**24 ids, 64 draws
            status_code=500,
            code="media_store_unavailable",
            message="This upload could not be stored on the LocalCanvas server.",
        )

    # -- reading -----------------------------------------------------------

    def get(self, media_id: Any) -> Optional[MediaItem]:
        """The item, or ``None`` if it never existed or has expired.

        Expiry is applied here rather than by a timer, so the answer is true at
        the moment it is asked for.
        """

        self.reap()
        if not isinstance(media_id, str):
            return None
        with self._lock:
            return self._items.get(media_id)

    def __len__(self) -> int:
        with self._lock:
            return len(self._items)

    @property
    def total_bytes(self) -> int:
        with self._lock:
            return sum(item.bytes for item in self._items.values())

    # -- lifetime ----------------------------------------------------------

    def reap(self) -> int:
        """Drop everything past its expiry.  Returns how many went."""

        now = self._clock()
        with self._lock:
            expired = [
                item
                for item in self._items.values()
                if item.is_settled and item.expires_at <= now
            ]
            for item in expired:
                self._discard(item)
        for item in expired:
            log.info("media %s expired and was deleted", item.media_id)
        return len(expired)

    def _evict_over_capacity(self) -> None:
        """Drop the oldest items until the store fits.  Caller holds the lock."""

        total = sum(item.bytes for item in self._items.values())
        if total <= self.max_store_bytes:
            return
        # Oldest first, and settled only: an upload still being written weighs
        # nothing towards the ceiling and freeing it would free no bytes.
        settled = [item for item in self._items.values() if item.is_settled]
        for item in sorted(settled, key=lambda entry: entry.created_at):
            if total <= self.max_store_bytes:
                break
            total -= item.bytes
            self._discard(item)
            log.warning(
                "media %s dropped: the temporary store is over its %s ceiling",
                item.media_id,
                _megabytes(self.max_store_bytes),
            )

    def _discard(self, item: MediaItem) -> None:
        """Remove one item and its file.  Caller holds the lock."""

        self._items.pop(item.media_id, None)
        try:
            item.path.unlink(missing_ok=True)
        except OSError as exc:  # pragma: no cover - the file is ours and local
            log.warning("media %s could not be deleted: %s", item.media_id, exc)

    def close(self) -> None:
        """Forget everything and remove the store directory if we made it."""

        with self._lock:
            items, self._items = list(self._items.values()), {}
            for item in items:
                try:
                    item.path.unlink(missing_ok=True)
                except OSError:  # pragma: no cover - best effort on shutdown
                    pass
            if self._owns_root:
                shutil.rmtree(self.root, ignore_errors=True)


class ComfyInputResolver:
    """Turns a ``media_id`` into the value a ComfyUI loader input expects.

    This is the implementation of :class:`~localcanvas_gateway.workflows.MediaValueResolver`
    -- the seam T-0002 left in ``workflows/binding.py``.  Binding asks; nothing
    reaches around it, and **the app never learns what the answer is**
    (`docs/api.md`: no ComfyUI concepts in any response).

    How the answer is obtained matters as much as what it is.  ComfyUI needs the
    file inside its own input directory, and the gateway does not know where
    that is and must not find out (`docs/architecture.md`: the only coupling
    between the two is HTTP).  So the file is handed over through ComfyUI's own
    ``POST /upload/image``, which stores it and answers with the name and
    subfolder it actually used; the bound value is composed from that answer.
    No path is constructed here, and none is configured.

    The upload happens once per file: the value is memoised on the item, so a
    resubmitted job -- a retry, or a second generation from the same
    picture -- costs no second transfer.
    """

    def __init__(self, store: MediaStore, comfy: Any) -> None:
        self._store = store
        self._comfy = comfy

    def resolve(self, field: "InputField", value: Any) -> Any:
        media_id = _media_id(field, value)
        if not MEDIA_ID.match(media_id):
            # Not a reference this gateway could ever have issued.  That is the
            # one media miss it can speak about with certainty, so it is the one
            # that gets `media_not_found` (`docs/api.md`); everything else is
            # `media_expired` below.
            raise ValidationFailure(
                field=field.id,
                code="media_not_found",
                message="{} was not sent correctly. Choose it again.".format(field.label),
            )
        item = self._store.get(media_id)
        if item is None:
            # `docs/api.md`: a job referencing media the store no longer holds
            # fails with ``media_expired`` **attributed to the field**, so the
            # app can clear that field and ask for the file again rather than
            # reporting a mysterious generation failure.  Reaped and
            # never-issued-but-well-formed are indistinguishable here and are
            # not distinguished: the user's action is the same either way.
            raise ValidationFailure(
                field=field.id,
                code="media_expired",
                message=(
                    "{} is no longer on the server. Choose it again and send it."
                ).format(field.label),
            )
        if item.kind != field.type.value:
            raise ValidationFailure(
                field=field.id,
                code="media_kind_mismatch",
                message="{} needs {}.".format(
                    field.label,
                    "an image" if field.type.value == "image" else "a video",
                ),
            )

        with item.lock:
            if item.resolved_value is None:
                uploaded = self._comfy.upload_input(
                    path=item.path,
                    filename=item.comfy_upload_name,
                    content_type=item.content_type,
                    subfolder=COMFY_INPUT_SUBFOLDER,
                )
                # ComfyUI's answer, not the request: it decides both halves, and
                # it is free to have used a different name or a different
                # subfolder than the ones it was asked for.
                item.resolved_value = uploaded.reference
                log.info(
                    "media %s handed to ComfyUI as an input file in %s/",
                    item.media_id,
                    uploaded.subfolder or "the input directory",
                )
            return item.resolved_value


def _media_id(field: "InputField", value: Any) -> str:
    """The reference shape `docs/api.md` documents: ``{"media_id": ...}``."""

    if isinstance(value, Mapping):
        candidate = value.get("media_id")
        if isinstance(candidate, str) and candidate:
            return candidate
    raise ValidationFailure(
        field=field.id,
        code="invalid_input",
        message="{} was not sent correctly. Choose it again.".format(field.label),
    )


# --------------------------------------------------------------------------
# Checking what arrived
# --------------------------------------------------------------------------


def checked_kind(kind: Any) -> str:
    """``image`` or ``video``, and nothing else."""

    if isinstance(kind, str) and kind in MEDIA_KINDS:
        return kind
    raise MediaRejected(
        status_code=400,
        code="invalid_request",
        message="That kind of file cannot be sent to this server.",
        field="kind",
    )


def _peeked(chunks: Iterable[bytes], size: int) -> "tuple[bytes, Iterator[bytes]]":
    """The first ``size`` bytes of a stream, and the stream itself, unread.

    Chunks are taken off the front only until that many bytes are in hand, so
    what is held is one chunk more than ``size`` at the very worst and has
    nothing to do with how big the file is.  The iterator comes back positioned
    where the peek stopped, and the caller writes the head it was given and then
    goes on consuming it -- which is what keeps a phone's video streaming
    straight to disk instead of arriving in the gateway's memory.
    """

    rest = iter(chunks)
    head = b""
    for chunk in rest:
        if not chunk:
            continue
        head += chunk
        if len(head) >= size:
            break
    return head, rest


def sniff_image_type(head: bytes) -> Optional[str]:
    """The image type these first bytes *are*, or ``None`` for none of them.

    One entry per image in :data:`ALLOWED_TYPES`, plus the HEIC and HEIF of
    :data:`NAMED_IMAGE_REFUSALS`, and nothing else: this answers what the file
    is, and :data:`ALLOWED_TYPES` remains the whole of what the gateway is
    willing to store -- the two outside it are identified only so that their
    refusal can name them.  ``None`` is the honest answer for
    anything else -- a PDF, an executable, an MP4, a JPEG that got truncated to
    two bytes -- and the caller turns it into ``unsupported_media_type``.

    The signatures are the formats' own, and each is checked at the offset the
    format defines it at rather than searched for:

    ``ff d8 ff``
        JPEG's start-of-image marker and the first byte of the marker that
        follows it.  ``ff d8`` alone is two bytes and would match too much.
    ``89 50 4e 47 0d 0a 1a 0a``
        PNG's eight-byte signature, CRLF and EOF traps included.
    ``GIF87a`` / ``GIF89a``
        the only two GIF versions there are.
    ``RIFF`` .... ``WEBP``
        WebP is a RIFF file whose form type sits at byte 8; the four bytes
        between are the chunk size and say nothing about the format.  An AVI is
        also RIFF, and is not this.
    ``BM`` and a DIB header size at byte 14
        BMP's magic number is two ASCII letters, which begin plenty of text, so
        they are not taken alone.  The DIB header that follows the 14-byte
        file header opens with its own size as a little-endian ``uint32``, and
        that size is one of the few the format defines
        (:data:`_BMP_DIB_HEADER_SIZES`) -- which turns two letters into a
        structure.  The file-size field at byte 2 is deliberately **not**
        read: some encoders write it wrong, no decoder needs it, and a real
        picture refused over it would be the defect this module removed.
    ``ftyp`` at byte 4
        ISO base media format, which is a container rather than a format: the
        major brand that follows says whether it holds a HEIC photograph, a
        HEIF one, or something this gateway does not store
        (:func:`_isobmff_image_type`).
    """

    if head[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    if head[:2] == b"BM" and len(head) >= 18:
        if int.from_bytes(head[14:18], "little") in _BMP_DIB_HEADER_SIZES:
            return "image/bmp"
    if head[4:8] == b"ftyp":
        return _isobmff_image_type(head)
    return None


def _isobmff_image_type(head: bytes) -> Optional[str]:
    """HEIC, HEIF, or neither, read off the ``ftyp`` box's **major** brand.

    The major brand is the file's own statement of what it primarily is, and it
    is the only brand consulted.  The compatible brands deliberately are not:
    they are a list of specifications the file also conforms to, and an AVIF --
    a real still image, coded with AV1, which nothing in :data:`ALLOWED_TYPES`
    describes -- names ``mif1`` among its own.  A gateway that scanned that list
    would write an AVIF into ComfyUI's input directory called ``.heif``, which
    is the very thing this module stopped doing when it stopped believing
    ``Content-Type``.

    The cost is stated rather than hidden: a file whose major brand this
    gateway does not know is refused even if it names a brand this gateway does
    know further down its list.  That is an honest refusal of something
    unidentified, and it is the direction to err in -- an MP4's ``isom``, a
    QuickTime's ``qt  `` and an AVIF's ``avif`` all land here and get the same
    answer they got before this function existed.
    """

    return _ISOBMFF_IMAGE_BRANDS.get(head[8:12])


def sniff_video_type(head: bytes) -> Optional[str]:
    """The video type these first bytes *are*, or ``None`` for none of them.

    :func:`sniff_image_type`'s sibling, written to the same rule: one entry per
    video in :data:`ALLOWED_TYPES` and nothing outside it, every signature read
    at the offset its format defines rather than searched for, and ``None`` --
    which the caller turns into ``unsupported_media_type`` -- as the honest
    answer for anything else.

    ``RIFF`` .... ``AVI ``
        An AVI is a RIFF file whose form type sits at byte 8.  So is a WebP, and
        so is a WAVE; the four bytes between are a chunk size and say nothing
        about the format.  ``RIFF`` alone is not an AVI.
    ``1a 45 df a3``
        EBML, which is a container syntax rather than a format: a WebM and a
        Matroska share these four bytes to the byte and are told apart by the
        ``DocType`` element inside the header (:func:`_ebml_video_type`).
    ``ftyp`` at byte 4
        ISO base media, whose **major** brand says whether it holds an MP4, a
        QuickTime movie, a 3GPP clip, a still photograph or something this
        gateway does not store (:func:`_isobmff_video_type`).
    ``00 00 01 ba`` / ``00 00 01 b3``
        MPEG's pack start code and sequence header start code: a program stream
        and a bare video elementary stream, which is what a ``.mpg`` or
        ``.mpeg`` file is.

    **What ``video/mpeg`` does not include, stated as a cost.**  The third
    thing an MPEG stream can be is a *transport* stream, and it has no magic
    number: it is the byte ``0x47`` repeating every 188 bytes, so the shortest
    honest confirmation of one is 189 bytes against a 64-byte peek, and one
    ``0x47`` is the letter ``G``.  A transport stream is also not really this
    entry of the set: its media type is ``video/mp2t`` and its extensions are
    ``.ts`` and ``.m2ts``, neither of which :data:`ALLOWED_TYPES` contains, so
    identifying one would mean writing it into ComfyUI's input directory as
    ``.mpeg`` -- a name that does not describe it, which is the whole of what
    this module stopped doing.  It is therefore refused, exactly as an AVIF is
    refused on the image side and for the same reason: it is a real file of a
    format outside the closed set.

    The cost is real and is not hidden: **a transport stream that a client
    declared ``video/mpeg`` was accepted before this function existed** and was
    stored as ``.mpeg``.  It is refused now.  A client that declared anything
    else for one -- ``video/mp2t``, ``application/octet-stream``, nothing at
    all, which is what a picker sends -- was already refused before, so what
    changed is one label's worth of behaviour and not a whole format's.
    """

    if head[:4] == b"RIFF" and head[8:12] == b"AVI ":
        return "video/x-msvideo"
    if head[:4] == _EBML_MAGIC:
        return _ebml_video_type(head)
    if head[4:8] == b"ftyp":
        return _isobmff_video_type(head)
    if head[:4] in _MPEG_START_CODES:
        return "video/mpeg"
    return None


def _isobmff_video_type(head: bytes) -> Optional[str]:
    """An MP4, a QuickTime movie, a 3GPP clip -- or none of them.

    The **major** brand and nothing else, which is
    :func:`_isobmff_image_type`'s rule and holds here for the same reason.  The
    compatible brands are a list of specifications a file also conforms to, and
    reading them writes one container out under another's extension: a 3GPP
    clip names ``isom`` among its own, and a HEIF image sequence names ``iso8``
    among its own, so a gateway that scanned the list would store somebody's
    still photographs as ``.mp4``.

    The cost is the same cost, accepted the same way: a file whose major brand
    this gateway does not know is refused even when it names a brand this
    gateway does know further down its list.
    """

    return _ISOBMFF_VIDEO_BRANDS.get(head[8:12])


def _ebml_video_type(head: bytes) -> Optional[str]:
    """WebM, Matroska, or neither, read off the ``DocType`` in the EBML header.

    This is the one thing in either sniffer that has to *search*: EBML is a
    sequence of (id, size, payload) elements, so ``DocType`` is at whatever
    offset the elements before it put it.  The search is bounded twice over --
    by the header's own declared size, and by :data:`SNIFF_BYTES`, which is what
    this function is allowed to have seen -- and it **refuses rather than reads
    on**.  A file whose ``DocType`` sits past the peek is unidentified, which
    the caller turns into a refusal.

    Every field is read from the file: the element ids and the sizes are EBML
    variable-length integers, decoded by :func:`_ebml_number`, so a header whose
    lengths do not add up walks off the end of itself and answers ``None``.
    """

    window = head[:SNIFF_BYTES]
    size, offset = _ebml_number(window, 4, keep_marker=False)
    if size is None:
        return None
    end = min(offset + size, len(window))
    while offset < end:
        element_id, offset = _ebml_number(window, offset, keep_marker=True)
        if element_id is None:
            return None
        length, offset = _ebml_number(window, offset, keep_marker=False)
        if length is None:
            return None
        if element_id == _EBML_DOCTYPE_ID:
            if offset + length > len(window):
                return None
            return _EBML_DOCTYPES.get(window[offset : offset + length])
        offset += length
    return None


def _ebml_number(
    data: bytes, offset: int, *, keep_marker: bool
) -> "tuple[Any, int]":
    """One EBML variable-length integer, and where it ends.

    The first byte's leading zeroes count the bytes that follow it, so the
    number carries its own length.  An element **id** is used as it is written,
    marker bit and all -- that is the form the specification tabulates ids in,
    and ``DocType`` is ``0x4282`` there.  A **size** is the value with that
    marker cleared.

    ``(None, offset)`` for a number that cannot be read at all: a first byte of
    zero, which would mean a length this parser does not accept, or a number
    that runs off the end of what has been peeked at.
    """

    if offset >= len(data):
        return None, offset
    first = data[offset]
    if first == 0:
        return None, offset
    length = 9 - first.bit_length()
    if offset + length > len(data):
        return None, offset
    if keep_marker:
        return data[offset : offset + length], offset + length
    value = first & (0xFF >> length)
    for byte in data[offset + 1 : offset + length]:
        value = (value << 8) | byte
    return value, offset + length


#: Which sniffer answers for which kind.  A closed mapping rather than an
#: ``if``: a kind with no sniffer has no way to fall back to the client's word.
_SNIFFERS: Mapping[str, Callable[[bytes], Optional[str]]] = {
    "image": sniff_image_type,
    "video": sniff_video_type,
}


def decided_content_type(kind: str, head: bytes) -> "tuple[str, str]":
    """What the gateway believes an upload is, and the extension it will get.

    **Both kinds are decided by their bytes**, and this function takes no
    declared content type because there is nothing left for one to decide.  A
    photograph labelled ``image/jpg``, ``application/octet-stream``, ``image/*``
    or nothing at all is the same photograph; a clip labelled ``video/mp4`` is
    only a clip if its bytes are one.  Every one of those labels is what some
    Android picker really sends, and the last of them -- no label at all -- is
    what a picker sends when it will not commit.

    The ``kind`` still comes from the request, and still matters: it says which
    of the two closed sets the file has to be in.  A JPEG sent as a video is
    refused because a JPEG is not in the video set, and an MP4 sent as an image
    because an MP4 is not in the image one -- each on its own bytes now, rather
    than on a label agreeing with a label.

    An image the bytes identify as one of :data:`NAMED_IMAGE_REFUSALS` is
    refused with that entry's code and sentence instead of the generic one
    (T-0127).  Only the type read out of the file is looked up there, and only
    once :data:`ALLOWED_TYPES` has said no, so that set stays the one thing
    that decides what is stored.
    """

    media_type = _SNIFFERS[kind](head)
    extension = ALLOWED_TYPES[kind].get(media_type) if media_type else None
    if media_type is not None and extension is None:
        named = NAMED_IMAGE_REFUSALS.get(media_type)
        if named is not None:
            code, message = named
            raise MediaRejected(
                status_code=415, code=code, message=message, field="file"
            )
    if media_type is None or extension is None:
        raise MediaRejected(
            status_code=415,
            code="unsupported_media_type",
            message="That file format cannot be used as {}.".format(
                "an image" if kind == "image" else "a video"
            ),
            field="file",
        )
    return media_type, extension


def checked_filename(filename: Any) -> str:
    """The uploaded name, refused outright if it is not simply a name.

    Refused, not repaired.  Everything here is a name that could only arrive
    from a client doing something other than naming a file: a separator, a
    drive, a NUL or another control character, a Windows device name, a name
    that is only dots.  The store does not need this to be safe -- the name
    never becomes a path -- but a client sending ``..\\..\\evil`` deserves a
    refusal rather than a silent rename, and the user deserves to see their own
    filename in the answer when it was an ordinary one.
    """

    rejected = MediaRejected(
        status_code=400,
        code="invalid_filename",
        message="That file's name cannot be used. Rename it and try again.",
        field="filename",
    )

    if not isinstance(filename, str):
        raise rejected
    name = filename
    if not name or name != name.strip() or len(name) > MAX_FILENAME_LENGTH:
        raise rejected
    if any(character in _ILLEGAL_CHARACTERS for character in name):
        raise rejected
    # NUL and every other character that is an instruction rather than a
    # letter.  Checked by Unicode category, not by ordinal, because the
    # dangerous ones are not all in ASCII:
    #
    # * ``Cc`` -- the control characters, NUL and 0x7F included;
    # * ``Cf`` -- the format characters, which is where the real damage is.
    #   This name is only ever echoed back and **displayed by the app**, and
    #   U+202E RIGHT-TO-LEFT OVERRIDE makes a name render as something other
    #   than itself.  Nothing reaches disk either way -- this is not a store
    #   escape -- but handing a phone a filename that draws as a different name
    #   is a spoofing surface, and it closes here rather than in every renderer
    #   downstream.  U+2066..U+2069 and the zero-width joiners are the same
    #   category and go with it;
    # * ``Cs`` and ``Co`` -- lone surrogates and private-use characters, which
    #   name nothing and render as whatever the reader's font invents.
    #
    # ``Cn`` (unassigned) is deliberately *not* refused: it would reject a
    # filename carrying an emoji newer than the running Python's Unicode
    # tables, which is a fact about this interpreter and not about the name.
    if any(unicodedata.category(character) in _FORBIDDEN_CATEGORIES for character in name):
        raise rejected
    # ``C:name.jpg`` carries no separator and is still drive-relative.
    if PureWindowsPath(name).drive or PurePosixPath(name).is_absolute():
        raise rejected
    if set(name) == {"."}:
        raise rejected
    # Windows silently strips a trailing dot, so two different names would
    # name one file.
    if name.endswith("."):
        raise rejected
    stem = name.split(".")[0].upper()
    if stem in _RESERVED_WINDOWS_NAMES:
        raise rejected
    return name


def _timestamp(epoch_seconds: float) -> str:
    """The same shape the job store uses: UTC, whole seconds, ``Z``."""

    return (
        datetime.fromtimestamp(epoch_seconds, timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _megabytes(value: int) -> str:
    return "{} MB".format(value // (1024 * 1024))


__all__ = [
    "ALLOWED_TYPES",
    "CHUNK_BYTES",
    "COMFY_INPUT_SUBFOLDER",
    "DEFAULT_MAX_IMAGE_MEGABYTES",
    "DEFAULT_MAX_STORE_MEGABYTES",
    "DEFAULT_MAX_VIDEO_MEGABYTES",
    "DEFAULT_TTL_SECONDS",
    "ComfyInputResolver",
    "MAX_STORE_BYTES",
    "MAX_UPLOAD_BYTES",
    "MEDIA_ID",
    "MEDIA_KINDS",
    "MEGABYTE",
    "MediaItem",
    "MediaRejected",
    "MediaStore",
    "NAMED_IMAGE_REFUSALS",
    "SNIFF_BYTES",
    "TTL_SECONDS",
    "checked_filename",
    "checked_kind",
    "decided_content_type",
    "sniff_image_type",
    "sniff_video_type",
]
