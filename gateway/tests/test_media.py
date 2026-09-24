"""The media store: what it accepts, where it puts it, and when it forgets.

Two things are being held in place here.

**A filename from a phone is untrusted input.**  The hostile names below are not
a formality: they are the shapes an attacker actually sends.  Each is asserted
twice -- refused by name, and proven to have left nothing behind anywhere under
the test's temporary directory.  The second assertion is the one that would
still fail if every check in ``checked_filename`` were deleted and the store
started joining names to paths.

The hostile names are also sent **raw**.  ``httpx`` normalises a filename on its
way into a multipart header -- it drops a NUL, escapes a quote, and lets a
quoted-pair swallow a backslash -- so a hostile name sent through it arrives
harmless, and a test that used it would be testing the client library.  An
attacker does not use ``httpx``.

**The store is not a library.**  `docs/api.md` says so in as many words -- no
listing endpoint, no permanent store, no server-side gallery -- so the absence
of those is tested rather than assumed, and expiry is tested for actually
deleting the file rather than merely forgetting the id.
"""

from __future__ import annotations

import re
from dataclasses import replace
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import media_fixtures
from conftest import IMPATIENT, UPLOAD_BYTES, FakeClock, config_for
from localcanvas_gateway.api import build_gateway, create_app
from localcanvas_gateway.comfy import ComfyClient
from localcanvas_gateway.config import MediaConfig
from localcanvas_gateway.media import (
    MEGABYTE,
    MediaRejected,
    MediaStore,
    checked_filename,
)
from workflow_fixtures import EVERY_FIELD, IMAGE_FIELD

#: What a file in the store may be called: the gateway's own id, and an
#: extension from the allow-list.  Nothing from the uploaded name.
STORED_NAME = re.compile(r"^m-[0-9a-f]{6}\.[a-z0-9]+$")

#: ``lcvictim`` is distinctive enough that finding it anywhere on disk cannot be
#: a coincidence.
HOSTILE_NAMES = [
    r"..\..\lcvictim.jpg",
    "../../lcvictim.jpg",
    "/etc/lcvictim.jpg",
    r"C:\Windows\lcvictim.jpg",
    "C:lcvictim.jpg",  # drive-relative, and carries no separator at all
    "sub/dir/lcvictim.jpg",
    "lcvictim\x00.jpg",
    "lcvictim\n.jpg",
    "CON",
    "con.jpg",
    "NUL.jpeg",
    "COM1.jpg",
    "LPT9.png",
    "aux.JPG",
    ".",
    "..",
    "picture.jpg.",
    " picture.jpg",
    "picture.jpg ",
    "",
    "pic<ture>.jpg",
    'pic"ture".jpg',
    "pic|ture.jpg",
    "x" * 201 + ".jpg",
]

#: Names that reach no filesystem and are dangerous anyway: this string is
#: echoed back and **drawn by the app**, so a name that renders as a different
#: name is a spoofing surface even though nothing is written under it.
#: U+202E is the classic -- it reverses what follows, so an attacker names a
#: file to display with an extension it does not have.
SPOOFING_NAMES = [
    "lcpwn\u202egpj.jpg",  # RIGHT-TO-LEFT OVERRIDE
    "lcpwn\u202dgpj.jpg",  # LEFT-TO-RIGHT OVERRIDE
    "lc\u2066pwn\u2069.jpg",  # isolates
    "lc\u200bpwn.jpg",  # zero-width space
    "lc\u200dpwn.jpg",  # zero-width joiner
    "\ufeffpicture.jpg",  # byte-order mark
    "pic\u0085ture.jpg",  # NEL, a C1 control outside ASCII
    "pic\ue000ture.jpg",  # private use: renders as whatever the font invents
]


@pytest.fixture
def harness(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    builder.add("needs_image", IMAGE_FIELD)
    return gateway_factory()


def error_of(response):
    body = response.json()
    assert set(body) == {"error"}
    assert set(body["error"]) == {"code", "message", "field"}
    return body["error"]


def files_under(root: Path):
    return [path for path in root.rglob("*") if path.is_file()]


def raw_upload(harness, filename: str, *, kind: str = "image", data: bytes = UPLOAD_BYTES):
    """POST a multipart body byte for byte, with no client library in the way."""

    boundary = "----lctest"
    crlf = "\r\n"
    head = crlf.join(
        [
            "--" + boundary,
            'Content-Disposition: form-data; name="kind"',
            "",
            kind,
            "--" + boundary,
            'Content-Disposition: form-data; name="file"; filename="{}"'.format(filename),
            "Content-Type: image/jpeg",
            "",
            "",
        ]
    )
    tail = crlf + "--" + boundary + "--" + crlf
    body = head.encode("utf-8") + data + tail.encode("utf-8")

    return harness.client.post(
        "/api/v1/media",
        content=body,
        headers={"content-type": "multipart/form-data; boundary={}".format(boundary)},
    )


# -- the documented answer -------------------------------------------------


def test_an_upload_answers_the_documented_document(harness) -> None:
    response = harness.upload()

    assert response.status_code == 201
    body = response.json()
    assert set(body) == {"media_id", "kind", "filename", "bytes", "expires_at"}
    assert re.match(r"^m-[0-9a-f]{6}$", body["media_id"])
    assert body["kind"] == "image"
    assert body["filename"] == "IMG_0142.jpg"
    assert body["bytes"] == len(UPLOAD_BYTES)
    assert body["expires_at"] == "2026-01-01T01:00:00Z"


def test_the_answer_names_no_location_on_this_pc(harness) -> None:
    """The app is told its file arrived, not where it went."""

    body = harness.upload().text

    assert str(harness.state.media.root) not in body
    assert "://" not in body


def test_two_uploads_are_two_files_with_two_ids(harness) -> None:
    first = harness.uploaded_id()
    second = harness.uploaded_id()

    assert first != second
    assert len(files_under(harness.state.media.root)) == 2


def test_a_video_is_accepted_as_a_video(harness) -> None:
    """The body is a real MP4, because the gateway reads it now.

    It used to be filler under a ``video/mp4`` label, which was the whole of
    what the gateway looked at -- and is why this test passed while the endpoint
    would take a PDF under that label too (T-0129).
    """

    response = harness.upload(
        kind="video",
        filename="clip.mp4",
        content_type="video/mp4",
        data=media_fixtures.MP4,
    )

    assert response.status_code == 201
    assert response.json()["kind"] == "video"


# -- what is refused -------------------------------------------------------


def test_an_unknown_kind_is_refused(harness) -> None:
    response = harness.upload(kind="drawing")

    assert response.status_code == 400
    assert error_of(response)["field"] == "kind"
    assert files_under(harness.state.media.root) == []


def test_a_file_outside_the_allow_list_is_refused(harness) -> None:
    """The allow-list is still closed; what it is applied to has moved.

    It used to be applied to the declared content type, and this test used to
    send a JPEG labelled ``application/x-msdownload`` and watch the label refuse
    it -- which is why the label is now the honest one and the *body* is a
    Windows executable.  ``test_media_sniffing.py`` is where the rest of that
    question lives, and the body comes from the same fixture module it uses --
    a second copy of a magic number is a second thing to keep true.
    """

    response = harness.upload(
        filename="setup.exe",
        content_type="application/x-msdownload",
        data=media_fixtures.NOT_MEDIA["windows executable"],
    )

    assert response.status_code == 415
    assert error_of(response)["code"] == "unsupported_media_type"
    assert files_under(harness.state.media.root) == []


def test_an_image_sent_as_a_video_is_refused(harness) -> None:
    """The kind the client asked for and the bytes it sent have to agree.

    It used to be the declared *type* that had to agree with the kind; now the
    body does, and this body is a JPEG whatever it is called.

    The second half is what stops this passing for the wrong reason: the same
    bytes are accepted as an image, so the 415 above is this body being refused
    *as a video* rather than being refused for anything else.
    """

    response = harness.upload(kind="video", content_type="image/jpeg")

    assert response.status_code == 415
    assert error_of(response)["code"] == "unsupported_media_type"
    assert files_under(harness.state.media.root) == []

    assert harness.upload(kind="image", content_type="image/jpeg").status_code == 201


def test_a_request_with_no_file_is_refused_in_the_documented_shape(harness) -> None:
    response = harness.client.post("/api/v1/media", data={"kind": "image"})

    assert response.status_code == 400
    assert error_of(response)["field"] == "file"


def test_an_empty_file_is_refused(harness) -> None:
    response = harness.upload(data=b"")

    assert response.status_code == 400
    assert error_of(response)["code"] == "empty_upload"
    assert files_under(harness.state.media.root) == []


def test_an_oversized_upload_is_refused_and_leaves_nothing_behind(
    gateway_factory, builder
) -> None:
    """The body is a real JPEG on purpose.

    Size is the one thing that cannot be read off a file's head, so it is still
    measured while writing -- and a body that was not a real image would be
    refused for its format before the ceiling was ever reached, leaving this
    test green and the ceiling untested.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(max_upload_bytes={"image": 1024, "video": 1024})

    response = harness.upload(data=media_fixtures.JPEG + bytes(4096))

    assert response.status_code == 413
    assert error_of(response)["code"] == "file_too_large"
    assert files_under(harness.state.media.root) == []


def test_the_size_limit_is_applied_while_writing_not_afterwards(tmp_path) -> None:
    """An oversized body is abandoned partway, not accepted and then measured.

    Proven by handing the store a generator and asking, afterwards, how much of
    it was consumed: a store that read the upload first and checked second would
    have drained it.
    """

    store = MediaStore(tmp_path / "store", max_upload_bytes={"image": 1024, "video": 1024})
    consumed = []

    def chunks():
        # A real JPEG at the front, so that what stops this upload is its size.
        # A body that was not an image at all would be refused for its format
        # instead, and the ceiling this test is about would never be reached.
        yield media_fixtures.JPEG
        for index in range(100):
            consumed.append(index)
            yield b"a" * 512

    with pytest.raises(MediaRejected) as error:
        store.store(
            kind="image", filename="big.jpg", content_type="image/jpeg", chunks=chunks()
        )

    assert error.value.code == "file_too_large"
    assert error.value.status_code == 413
    assert len(consumed) < 10
    assert files_under(store.root) == []


# -- hostile filenames -----------------------------------------------------


@pytest.mark.parametrize("name", HOSTILE_NAMES)
def test_a_filename_that_is_not_simply_a_name_is_refused(name: str) -> None:
    with pytest.raises(MediaRejected) as error:
        checked_filename(name)
    assert error.value.status_code == 400
    assert error.value.field == "filename"


@pytest.mark.parametrize(
    "name", ["IMG_0142.jpg", "holiday photo.png", "clip (2).mp4", "..jpg", "снимок.jpg"]
)
def test_an_ordinary_filename_survives_unchanged(name: str) -> None:
    """The refusals above must not be a rule that rejects everything."""

    assert checked_filename(name) == name


@pytest.mark.parametrize("name", HOSTILE_NAMES)
def test_a_hostile_filename_sent_raw_never_becomes_a_file(
    harness, tmp_path, name: str
) -> None:
    """The endpoint's own guarantee, driven with the real bytes.

    Two things are asserted and both matter.  Nothing lands outside the store,
    whatever happened -- the safety property, which would fail loudly if the
    store ever joined an uploaded name to its root.  And a name that survived
    the wire intact is *refused*, in the documented shape: a 201 has to have had
    its name changed in transit, because accepting one of these as written would
    be the bug.
    """

    before = set(files_under(tmp_path))

    response = raw_upload(harness, name)

    if response.status_code == 201:
        assert response.json()["filename"] != name, name
    else:
        assert response.status_code == 400, name
        assert error_of(response)["field"] in ("filename", "file")

    # Everything the request created, wherever it landed -- not only what the
    # store admits to holding.
    appeared = set(files_under(tmp_path)) - before
    for path in appeared:
        assert path.parent == harness.state.media.root, (name, str(path))
        assert STORED_NAME.match(path.name), (name, path.name)


@pytest.mark.parametrize("name", SPOOFING_NAMES)
def test_a_name_that_draws_as_a_different_name_is_refused(name: str) -> None:
    """Not a store escape -- a display surface handed to the app.

    Nothing here reaches disk: the stored file is named from the gateway's own
    id either way. What these do is come back in the ``filename`` field, which
    the app renders, where a bidi override turns one name into another on a
    screen the user is trusting. It closes here rather than in every renderer
    downstream.
    """

    with pytest.raises(MediaRejected) as error:
        checked_filename(name)
    assert error.value.field == "filename"


@pytest.mark.parametrize("name", SPOOFING_NAMES)
def test_a_spoofing_name_is_never_echoed_back_over_http(harness, name: str) -> None:
    response = raw_upload(harness, name)

    assert response.status_code == 400, name
    assert name not in response.text


def test_ordinary_non_ascii_filenames_still_work(harness) -> None:
    """The refusals above must not become "no alphabet but mine".

    Refusing by Unicode *category* rather than by ordinal is what allows this:
    a Cyrillic, Japanese or accented name is letters, and letters are fine.
    """

    for name in ("\u0441\u043d\u0438\u043c\u043e\u043a.jpg", "\u5199\u771f.png", "caf\u00e9.jpg", "na\u00efve (2).jpeg"):
        response = harness.upload(filename=name)
        assert response.status_code == 201, name
        assert response.json()["filename"] == name


def test_nothing_an_upload_names_ever_becomes_a_path(harness, tmp_path) -> None:
    """The store's own proof, independent of every check above.

    Even an accepted upload's name does not reach the filesystem: what is on
    disk is the gateway's id and an extension chosen from the allow-list.  A
    store that joined the uploaded name to its root would fail here while
    passing every refusal test in this file.
    """

    accepted = 0
    for name in HOSTILE_NAMES:
        accepted += raw_upload(harness, name).status_code == 201
    # These two have to be **accepted**, asserted rather than counted: they are
    # the ordinary uploads whose stored names this test is about, and a count
    # that simply went down by one would leave it green while checking one file
    # fewer.  The video one earns the assertion twice over, because its body is
    # now read (T-0129) and a body the gateway refused would drop out silently.
    ordinary_image = harness.upload(filename="IMG_0142.jpg")
    ordinary_video = harness.upload(
        kind="video",
        filename="clip.mp4",
        content_type="video/mp4",
        data=media_fixtures.MP4,
    )
    assert ordinary_image.status_code == 201, ordinary_image.text
    assert ordinary_video.status_code == 201, ordinary_video.text
    accepted += 2

    stored = files_under(harness.state.media.root)
    assert len(stored) == accepted
    for path in stored:
        assert path.parent == harness.state.media.root
        assert STORED_NAME.match(path.name), path.name

    assert not [path for path in files_under(tmp_path) if "lcvictim" in path.name]
    assert not [path for path in files_under(tmp_path) if path.name.startswith("IMG_")]
    assert not [path for path in files_under(tmp_path) if path.name.startswith("clip")]


# -- lifetime --------------------------------------------------------------


def test_an_expired_file_is_deleted_from_disk_not_merely_forgotten(harness) -> None:
    media_id = harness.uploaded_id()
    path = harness.state.media.get(media_id).path
    assert path.exists()

    harness.media_clock.advance(3600 + 1)

    assert harness.state.media.get(media_id) is None
    assert not path.exists()
    assert files_under(harness.state.media.root) == []


def test_media_outlives_a_submission(harness) -> None:
    """`docs/api.md`: media outlives job submission, so a retry is free."""

    media_id = harness.uploaded_id()
    harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    assert harness.state.media.get(media_id) is not None


def test_the_store_drops_its_oldest_when_it_is_over_its_ceiling(
    gateway_factory, builder
) -> None:
    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(max_store_bytes=len(UPLOAD_BYTES) * 2)

    first = harness.uploaded_id()
    harness.media_clock.advance(1)
    second = harness.uploaded_id()
    harness.media_clock.advance(1)
    third = harness.uploaded_id()

    assert harness.state.media.get(first) is None
    assert harness.state.media.get(second) is not None
    assert harness.state.media.get(third) is not None
    assert len(files_under(harness.state.media.root)) == 2


def test_an_upload_in_flight_is_not_evicted_out_from_under_itself(tmp_path) -> None:
    """A store over its ceiling must not break the upload that is filling it.

    A reservation sits in the store from the moment its id is claimed, with
    zero bytes and its file still open for writing. An eviction sweep that
    treats it like any other item unlinks a file another thread has open --
    which on Windows raises, and is swallowed -- and pops the entry that thread
    is about to fill in, so the upload dies with a KeyError behind a 500 and
    leaves a file in the store root that nothing will ever reap.

    The ordering that makes it bite is real and not contrived: ``created_at`` is
    stamped when an upload **settles**, so an upload that started earlier and is
    still going is *older* than one that started later and has finished -- which
    puts it first in an oldest-first eviction, ahead of the settled items the
    sweep is actually there to remove.
    """

    clock = FakeClock(1000.0)
    store = MediaStore(tmp_path / "store", max_store_bytes=200, clock=clock)

    def chunks_of_the_slow_upload():
        # A real GIF -- 35 bytes, the smallest whole image there is -- so that
        # these deliberately tiny bodies are still identifiable files.  This
        # first chunk is longer than SNIFF_BYTES on purpose: the head is peeked
        # at before the reservation is made, so a shorter one would pull the
        # chunk below off the generator early and the interleaving this test is
        # about would happen before there was a reservation to threaten.
        yield media_fixtures.GIF89A + b"s" * 45
        # Mid-write. Another upload finishes and its own book-keeping sweeps a
        # store that is now over capacity -- with this reservation the oldest
        # thing in it.
        clock.advance(100)
        store.store(
            kind="image",
            filename="other.jpg",
            content_type="image/jpeg",
            chunks=iter([media_fixtures.GIF89A + b"o" * 265]),
        )
        yield b"s" * 20

    slow = store.store(
        kind="image",
        filename="slow.jpg",
        content_type="image/jpeg",
        chunks=chunks_of_the_slow_upload(),
    )

    assert slow.bytes == 100
    assert slow.path.exists()
    assert store.get(slow.media_id) is not None
    assert store.total_bytes <= 200
    # Nothing orphaned: every file left on disk is one the store still knows
    # about, looked up the way any caller would.
    for path in files_under(store.root):
        assert store.get(path.stem) is not None, path.name


def test_an_upload_slower_than_the_ttl_is_not_reaped_mid_write(tmp_path) -> None:
    """The reaper has the same hazard as the evictor, reached a different way.

    A reservation's expiry is stamped when its id is claimed, so an upload that
    takes longer than the whole TTL -- a large video over a slow phone
    connection, with a short ttl_seconds configured -- is already "expired"
    while its file is still open. A reaper that believed that would delete the
    file out from under the thread writing it.

    The clock is moved by hand rather than waited on, so this is the same code
    path with none of the flakiness.
    """

    clock = FakeClock(1000.0)
    store = MediaStore(tmp_path / "store", ttl_seconds=10.0, clock=clock)

    def chunks_of_a_slow_upload():
        # A real WebM -- 81 bytes, and the smallest whole video fixture there
        # is -- so that this deliberately tiny body is still an identifiable
        # file.  It is longer than SNIFF_BYTES on purpose, for the reason the
        # eviction test above gives: the head is peeked at before the id is
        # reserved, so the reap below has to happen after a chunk that is long
        # enough to end the peek.
        yield media_fixtures.WEBM
        # The upload has now outlived its own reservation's expiry.
        clock.advance(60)
        # And the hazard is reachable, asserted rather than assumed: the
        # reservation really is in the store at this moment -- if the chunk
        # above had been shorter than the peek, the store would still be
        # accumulating a head and there would be nothing here to threaten --
        # and the reaper really does look at it and leave it alone.
        assert len(store) == 1, "there is no reservation for the reaper to threaten"
        assert store.reap() == 0, "the reaper took an upload that was still open"
        yield b"v" * 10

    item = store.store(
        kind="video",
        filename="long.mp4",
        content_type="video/mp4",
        chunks=chunks_of_a_slow_upload(),
    )

    assert item.bytes == len(media_fixtures.WEBM) + 10
    assert item.path.exists()
    # And it gets its life from when it *finished*, not from when it started.
    assert store.get(item.media_id) is not None
    clock.advance(11)
    assert store.get(item.media_id) is None


def test_closing_the_store_removes_the_directory_it_made() -> None:
    """A gateway that exits leaves none of the user's photographs behind."""

    store = MediaStore()
    root = store.root
    store.store(
        kind="image",
        filename="IMG_0142.jpg",
        content_type="image/jpeg",
        chunks=iter([UPLOAD_BYTES]),
    )
    assert files_under(root)

    store.close()

    assert not root.exists()


# -- configured, not compiled in -------------------------------------------


def test_the_configured_limits_are_the_ones_the_store_enforces(
    builder, fake_comfy, tmp_path
) -> None:
    """The wiring, not the loader.

    `test_config.py` proves `runtime.yaml` is *read* correctly. This proves the
    values are *used*: a gateway built from a configuration with a one-megabyte
    ceiling refuses two megabytes. Without this, `build_gateway` could keep
    handing the store its own defaults and every configuration test would still
    pass — which is exactly how a setting becomes decorative.
    """

    builder.add("flow", EVERY_FIELD)
    config = replace(
        config_for("127.0.0.1", fake_comfy.port, builder.root),
        media=MediaConfig(
            max_image_megabytes=1,
            max_video_megabytes=1,
            max_store_megabytes=2,
            ttl_seconds=5.0,
        ),
    )
    comfy = ComfyClient(config.comfy.base_url, timeout=IMPATIENT, probe_timeout=IMPATIENT)
    state = build_gateway(config, comfy=comfy, registry=builder.load())
    try:
        assert state.media.ttl_seconds == 5.0
        assert state.media.max_upload_bytes == {"image": MEGABYTE, "video": MEGABYTE}
        assert state.media.max_store_bytes == 2 * MEGABYTE

        client = TestClient(create_app(state), raise_server_exceptions=False)
        refused = client.post(
            "/api/v1/media",
            files={
                "file": (
                    "big.jpg",
                    # A real JPEG, two megabytes long: refused for its size,
                    # which is what this test is about, and not for its format.
                    media_fixtures.JPEG + bytes(2 * MEGABYTE),
                    "image/jpeg",
                )
            },
            data={"kind": "image"},
        )
        accepted = client.post(
            "/api/v1/media",
            files={"file": ("small.jpg", UPLOAD_BYTES, "image/jpeg")},
            data={"kind": "image"},
        )
    finally:
        state.media.close()
        comfy.close()

    assert refused.status_code == 413
    assert "1 MB" in refused.json()["error"]["message"]
    assert accepted.status_code == 201


# -- not a library ---------------------------------------------------------


def test_an_uploaded_file_cannot_be_read_back_over_the_api(harness) -> None:
    """No listing endpoint, no gallery: the store holds media, it does not serve it."""

    media_id = harness.uploaded_id()

    for path in ("/api/v1/media", "/api/v1/media/{}".format(media_id)):
        assert harness.client.get(path).status_code in (404, 405), path
    assert harness.client.delete("/api/v1/media/{}".format(media_id)).status_code in (
        404,
        405,
    )


def test_the_store_is_not_reachable_through_a_job_result(harness) -> None:
    """The result route serves ComfyUI outputs, never the upload store."""

    harness.uploaded_id()
    response = harness.client.get("/api/v1/jobs/j-nope/result/0")

    assert response.status_code == 404
