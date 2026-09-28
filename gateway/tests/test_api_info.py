"""``GET /api/v1/info`` -- the identity handshake.

Two things this endpoint must get right, because the whole connection flow rests
on them (`docs/connection.md`, `docs/recovery.md`): the identity fields the
client checks before trusting a server at all, and a ``comfy.status`` that is
live rather than remembered from startup.
"""

from __future__ import annotations

import re
import sys

import pytest

from conftest import TEST_DISPLAY_NAME
from localcanvas_gateway.comfy import READY_TTL_SECONDS
from localcanvas_gateway.config import PromptTranslationConfig
from localcanvas_gateway.translation.errors import backend_missing
from localcanvas_gateway.translation.fake import FakeTranslator
from workflow_fixtures import EVERY_FIELD


def build(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    return gateway_factory()


def test_the_identity_document_has_exactly_the_documented_keys(
    gateway_factory, builder
) -> None:
    body = build(gateway_factory, builder).client.get("/api/v1/info").json()

    assert set(body) == {
        "service",
        "api_version",
        "gateway_version",
        "instance_id",
        "display_name",
        "comfy",
        "jobs",
        "capabilities",
    }
    assert set(body["comfy"]) == {"status", "detail"}
    assert set(body["jobs"]) == {"active"}


def test_the_service_name_is_exactly_localcanvas(gateway_factory, builder) -> None:
    """The client rejects anything else, so this string is load-bearing."""

    body = build(gateway_factory, builder).client.get("/api/v1/info").json()

    assert body["service"] == "localcanvas"
    assert body["api_version"] == 1


def test_the_display_name_comes_from_configuration(gateway_factory, builder) -> None:
    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(display_name="Kitchen Table PC")

    assert harness.client.get("/api/v1/info").json()["display_name"] == "Kitchen Table PC"


def test_the_gateway_version_is_the_package_version(gateway_factory, builder) -> None:
    from localcanvas_gateway import __version__

    body = build(gateway_factory, builder).client.get("/api/v1/info").json()

    assert body["gateway_version"] == __version__


# ==========================================================================
# instance_id -- this process's identity, not the build's (`docs/api.md`)
# ==========================================================================


def test_instance_id_is_32_lowercase_hex_characters_when_generated(
    gateway_factory, builder
) -> None:
    body = build(gateway_factory, builder).client.get("/api/v1/info").json()

    assert re.fullmatch(r"[0-9a-f]{32}", body["instance_id"])


def test_instance_id_equals_the_one_the_gateway_was_given(gateway_factory, builder) -> None:
    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(instance_id="ab" * 16)

    assert harness.client.get("/api/v1/info").json()["instance_id"] == "ab" * 16


def test_instance_id_differs_between_two_gateways_started_with_none_given(
    gateway_factory, builder
) -> None:
    """Two processes that never named an id must not collide on a generated one."""

    builder.add("flow", EVERY_FIELD)
    first = gateway_factory().client.get("/api/v1/info").json()["instance_id"]
    second = gateway_factory().client.get("/api/v1/info").json()["instance_id"]

    assert first != second


# ==========================================================================
# jobs.active -- a cheap, live count of what this process is still doing
# ==========================================================================


def test_jobs_active_counts_queued_and_running_jobs(gateway_factory, builder) -> None:
    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory()

    harness.submit("flow", {"prompt": "a cat"})
    harness.submit("flow", {"prompt": "a dog"})

    assert harness.client.get("/api/v1/info").json()["jobs"]["active"] == 2


def test_jobs_active_excludes_completed_failed_and_cancelled_jobs(
    gateway_factory, builder
) -> None:
    """Driven through real `JobStore` states, not a mocked counter.

    Each of the three terminal states is reached the way the job store's own
    tests reach it -- moving the fake backend and then reading the job back,
    which is what actually refreshes its state -- so a counter that read
    something other than `JobStore` itself would be caught here.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory()

    completed_id = harness.submit("flow", {"prompt": "completed"}).json()["job_id"]
    failed_id = harness.submit("flow", {"prompt": "failed"}).json()["job_id"]
    cancelled_id = harness.submit("flow", {"prompt": "cancelled"}).json()["job_id"]
    still_queued_id = harness.submit("flow", {"prompt": "still queued"}).json()["job_id"]

    # Submissions and prompt ids arrive in the same order, so this is the
    # job-id -> prompt-id mapping the fake's own list carries.
    prompt_of = {
        job_id: submission["prompt_id"]
        for job_id, submission in zip(
            [completed_id, failed_id, cancelled_id, still_queued_id],
            harness.fake.submissions,
        )
    }

    harness.fake.complete(prompt_of[completed_id])
    harness.client.get("/api/v1/jobs/{}".format(completed_id))  # forces the refresh

    harness.fake.fail(prompt_of[failed_id])
    harness.client.get("/api/v1/jobs/{}".format(failed_id))

    harness.client.post("/api/v1/jobs/{}/cancel".format(cancelled_id))

    assert harness.client.get("/api/v1/info").json()["jobs"]["active"] == 1


def test_jobs_active_is_cheap_no_comfy_call_for_the_count_itself(
    gateway_factory, builder
) -> None:
    """The count comes from the store this process already holds.

    `/info` still probes ComfyUI once for `comfy.status`
    (`test_info_is_cheap_enough_to_poll`); this asserts the count on top of
    that costs nothing extra by holding ComfyUI's probe counter still across
    a burst of calls with jobs outstanding.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory()
    harness.submit("flow", {"prompt": "a cat"})

    before = harness.fake.probe_count
    for _ in range(5):
        assert harness.client.get("/api/v1/info").json()["jobs"]["active"] == 1

    assert harness.fake.probe_count == before + 1


def test_comfy_status_is_ready_with_no_detail_when_it_is(
    gateway_factory, builder
) -> None:
    body = build(gateway_factory, builder).client.get("/api/v1/info").json()

    assert body["comfy"] == {"status": "ready", "detail": None}


def test_comfy_status_is_live_not_remembered(gateway_factory, builder) -> None:
    """The app polls this endpoint to notice ComfyUI coming and going.

    A ``ready`` answer is reused for a couple of seconds, so "live" means
    within that window rather than instantly -- the clock is moved rather than
    slept through.
    """

    harness = build(gateway_factory, builder)
    assert harness.client.get("/api/v1/info").json()["comfy"]["status"] == "ready"

    harness.fake.ready = False
    harness.clock.advance(READY_TTL_SECONDS + 0.1)
    assert harness.client.get("/api/v1/info").json()["comfy"]["status"] == "starting"

    harness.fake.ready = True
    assert harness.client.get("/api/v1/info").json()["comfy"]["status"] == "ready"


def test_a_backend_that_is_not_ready_is_never_cached(gateway_factory, builder) -> None:
    """Only ``ready`` is reused.

    ``starting`` and ``unavailable`` are the answers a user is waiting to see
    change; caching those would put a delay exactly where `docs/recovery.md`
    wants none.
    """

    harness = build(gateway_factory, builder)
    harness.fake.ready = False
    assert harness.client.get("/api/v1/info").json()["comfy"]["status"] == "starting"

    probes = harness.fake.probe_count
    harness.fake.ready = True

    # No clock movement at all: the previous answer was not cached, so ComfyUI
    # is asked again and the recovery is seen immediately.
    assert harness.client.get("/api/v1/info").json()["comfy"]["status"] == "ready"
    assert harness.fake.probe_count == probes + 1


def test_comfy_status_is_unavailable_when_the_backend_is_gone(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)
    harness.fake.stop()

    comfy = harness.client.get("/api/v1/info").json()["comfy"]

    assert comfy["status"] == "unavailable"
    assert isinstance(comfy["detail"], str) and comfy["detail"]


def test_the_detail_is_a_sentence_not_a_diagnostic(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)
    harness.fake.ready = False

    detail = harness.client.get("/api/v1/info").json()["comfy"]["detail"]

    assert "Traceback" not in detail
    assert "http" not in detail
    assert detail.endswith(".")


def test_capabilities_advertise_only_what_is_implemented(
    gateway_factory, builder
) -> None:
    """Every word here is now backed by an endpoint that does what it says.

    ``translation`` is asserted as a key and no further: it is the one entry
    that is not a promise about this build but a description of this PC, and
    what it says is pinned in its own section below.
    """

    capabilities = build(gateway_factory, builder).client.get("/api/v1/info").json()[
        "capabilities"
    ]

    assert set(capabilities) == {"cancel", "media_upload", "events", "translation"}
    assert capabilities["cancel"] is True
    assert capabilities["media_upload"] is True
    assert capabilities["events"] is True


def test_the_cancel_capability_is_backed_by_an_endpoint_that_acts(
    gateway_factory, builder
) -> None:
    """A capability the app can only discover by trying is worse than none.

    The word and the behaviour are asserted together: the endpoint answers, it
    reaches ComfyUI, and the state that comes back is a real one.
    """

    harness = build(gateway_factory, builder)
    job_id = harness.submit("flow", {"prompt": "a cat"}).json()["job_id"]

    response = harness.client.post("/api/v1/jobs/{}/cancel".format(job_id))

    assert response.status_code == 200
    assert response.json()["state"] == "cancelled"
    assert harness.fake.queue_deletes == [harness.prompt_id]


def test_the_events_capability_is_backed_by_a_socket_that_opens(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)
    job_id = harness.submit("flow", {"prompt": "a cat"}).json()["job_id"]

    with harness.client.websocket_connect(
        "/api/v1/jobs/{}/events".format(job_id)
    ) as socket:
        assert socket.receive_json() == {"type": "state", "state": "queued"}


def test_info_is_cheap_enough_to_poll(gateway_factory, builder) -> None:
    """`docs/api.md` calls this endpoint safe to poll, so polling must be cheap.

    It is not cheap for ComfyUI: producing ``/object_info`` walks every node
    class and enumerates model directories on disk.  A burst of ``/info`` calls
    therefore costs **one** probe, not one each.
    """

    harness = build(gateway_factory, builder)
    before = harness.fake.probe_count

    for _ in range(5):
        assert harness.client.get("/api/v1/info").json()["comfy"]["status"] == "ready"

    assert harness.fake.probe_count == before + 1

    harness.clock.advance(READY_TTL_SECONDS + 0.1)
    harness.client.get("/api/v1/info")

    assert harness.fake.probe_count == before + 2


# ==========================================================================
# capabilities.translation -- what this PC can translate, said in advance
# (T-0043)
#
# The machines below are the whole state space, and each one is its own test:
# "the extra is not installed" and "the extra is installed and idle" are the
# pair the block exists to tell apart, because only the first of them is fixed
# by installing the extra.
# ==========================================================================


def translation_block(harness) -> dict:
    return harness.client.get("/api/v1/info").json()["capabilities"]["translation"]


def machine(gateway_factory, builder, *, enabled: bool, translator):
    builder.add("flow", EVERY_FIELD)
    return gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=enabled),
        translator=translator,
    )


def test_a_pc_without_the_extra_says_so(gateway_factory, builder) -> None:
    """The common case for an unrelated user, and the one `pip install` fixes.

    A translator that answers every call with ``translation_unavailable`` *is*
    a PC with no backend -- that is what the error means -- so the fixture and
    the machine it stands for are the same statement.
    """

    harness = machine(
        gateway_factory,
        builder,
        enabled=False,
        translator=FakeTranslator(fails_with=backend_missing()),
    )

    assert translation_block(harness) == {
        "enabled": False,
        "installed": False,
        "pairs": [],
    }


def test_a_pc_with_the_extra_installed_and_idle_says_that_instead(
    gateway_factory, builder
) -> None:
    """The other half of the pair, and the reason ``installed`` is not derived.

    Same ``enabled: false`` as the test above and a different answer, so a
    client can tell "install the extra" from "switch the stage on" -- which a
    single boolean could never have said.
    """

    harness = machine(
        gateway_factory, builder, enabled=False, translator=FakeTranslator()
    )

    assert translation_block(harness) == {
        "enabled": False,
        "installed": True,
        "pairs": [],
    }


def test_a_translating_pc_names_the_pairs_it_really_has(
    gateway_factory, builder
) -> None:
    harness = machine(
        gateway_factory,
        builder,
        enabled=True,
        translator=FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night"),
    )

    assert translation_block(harness) == {
        "enabled": True,
        "installed": True,
        "pairs": [{"source": "ru", "target": "en"}],
    }


def test_a_configured_source_with_no_model_is_not_advertised(
    gateway_factory, builder
) -> None:
    """``pairs`` is what would really be used, not what was configured.

    Both ``ru`` and ``ja`` are configured sources; only one has a model here.
    Advertising the other would promise a translation that fails at submission
    with ``translation_model_missing``.
    """

    harness = machine(
        gateway_factory,
        builder,
        enabled=True,
        translator=FakeTranslator().teach("ja", "en", "夜の東京", "Tokyo at night"),
    )

    assert translation_block(harness)["pairs"] == [{"source": "ja", "target": "en"}]


def test_a_stage_switched_on_with_nothing_installed_is_honest_about_it(
    gateway_factory, builder
) -> None:
    """The misconfiguration a submission would otherwise discover the hard way.

    ``enabled`` and ``installed`` disagree, which is exactly the sentence the
    app could not say before this block existed: switched on here, not set up
    on this PC.
    """

    harness = machine(
        gateway_factory,
        builder,
        enabled=True,
        translator=FakeTranslator(fails_with=backend_missing()),
    )

    assert translation_block(harness) == {
        "enabled": True,
        "installed": False,
        "pairs": [],
    }


def test_the_capability_carries_no_model_no_path_and_no_backend_name(
    gateway_factory, builder
) -> None:
    """Asserted over what is sent, not over what the code looks like.

    This document is read by an unrelated user's phone
    (`docs/privacy-security.md`), so the check is structural as well as by
    keyword: every string in the block has to be a language code, which leaves
    nowhere for a filename, a directory or a backend's name to hide.
    """

    harness = machine(
        gateway_factory,
        builder,
        enabled=True,
        translator=FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night"),
    )
    response = harness.client.get("/api/v1/info")
    block = response.json()["capabilities"]["translation"]

    assert set(block) == {"enabled", "installed", "pairs"}
    assert isinstance(block["enabled"], bool) and isinstance(block["installed"], bool)
    assert block["pairs"], "the machine under test has a pair installed"
    for pair in block["pairs"]:
        assert set(pair) == {"source", "target"}
        for code in pair.values():
            assert re.fullmatch(r"[a-z]{2,3}(-[a-z]{2,4})?", code), code

    lowered = response.text.lower()
    for forbidden in (
        "argos",
        "opennmt",
        "torch",
        "stanza",
        "ctranslate",
        "site-packages",
        ".venv",
        ".pt",
        ".bin",
        "model",
        "package",
        "\\\\",
        "/",
    ):
        assert forbidden not in lowered, forbidden


def test_a_handshake_imports_nothing_on_a_pc_that_has_the_extra(
    gateway_factory, builder, importable_backend
) -> None:
    """The handshake is polled, and the extra is 981 MB of imports.

    The default harness runs the *real* backend adapter, translation is
    switched on, and ``importable_backend`` puts a package on ``sys.path`` that
    the adapter's own import would find -- so this is the machine the guard is
    about, and an implementation that reached the backend here would be caught.
    Presence is answered by searching the path, never by importing what it
    found, and the pairs were walked at startup.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory(prompt_translation=PromptTranslationConfig(enabled=True))
    # The stub is genuinely importable, so "not in sys.modules" below is a
    # statement about this code rather than about this PC.
    assert harness.state.translation.translator.installed() is True
    assert "argostranslate" in sys.modules, (
        "assembling the gateway is where the walk -- and its import -- belongs"
    )

    # Forget what startup imported.  What is under test is what a *request*
    # costs, and with the stub still on the path an implementation that walked
    # the models per handshake would bring it straight back.
    for name in [
        name
        for name in list(sys.modules)
        if name == "argostranslate" or name.startswith("argostranslate.")
    ]:
        del sys.modules[name]

    for _ in range(5):
        assert harness.client.get("/api/v1/info").status_code == 200

    assert "argostranslate" not in sys.modules


def test_enabled_and_installed_are_live_rather_than_remembered(
    gateway_factory, builder
) -> None:
    """Two of the three answers are a promise made now, not at startup.

    ``comfy.status`` beside them is live for the same reason: an answer that
    was true when the gateway started goes on being given after it has stopped
    being true.  The extra going away takes the pairs with it, because the
    block says what *would* happen, not what was once installed.
    """

    translator = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")
    harness = machine(gateway_factory, builder, enabled=True, translator=translator)
    assert translation_block(harness) == {
        "enabled": True,
        "installed": True,
        "pairs": [{"source": "ru", "target": "en"}],
    }

    # The extra is removed from under the running gateway.
    translator.fails_with = backend_missing()

    assert translation_block(harness) == {
        "enabled": True,
        "installed": False,
        "pairs": [],
    }


def test_the_pairs_are_the_walk_done_at_startup(gateway_factory, builder) -> None:
    """And they are walked **once**, before the server listens (T-0043).

    This is the answer that cannot be live: reading which models are installed
    reaches the backend, and reaching the backend imports it.  So a model
    installed while the gateway runs appears after a restart -- the same
    explicit setup step that installed it -- and no number of handshakes walks
    the models again.
    """

    translator = FakeTranslator()
    harness = machine(gateway_factory, builder, enabled=True, translator=translator)
    assert translator.pair_walks == [(("ru", "ja"), "en")], "walked once, at startup"

    translator.teach("ru", "en", "ночной Токио", "Tokyo at night")
    for _ in range(5):
        assert translation_block(harness)["pairs"] == []

    assert translator.pair_walks == [(("ru", "ja"), "en")], "and never in a request"

    # A gateway started now finds the model, because startup is when it looks.
    restarted = gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True), translator=translator
    )
    assert translation_block(restarted)["pairs"] == [{"source": "ru", "target": "en"}]


def test_a_switched_off_pc_walks_no_models_at_startup_either(
    gateway_factory, builder
) -> None:
    """The cost is paid by the machine that asked for translation, and no other."""

    translator = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")
    machine(gateway_factory, builder, enabled=False, translator=translator)

    assert translator.pair_walks == []


def test_the_startup_banner_says_what_was_found(gateway_factory, builder) -> None:
    """A cost worth paying is a cost worth showing (`docs/runtime.md`).

    ASCII, because the console's code page is not ours to choose, and one line
    per situation -- the pairs, or which of the two setup steps is missing.
    """

    from localcanvas_gateway.api import translation_summary

    def summary(*, enabled: bool, translator) -> str:
        harness = machine(
            gateway_factory, builder, enabled=enabled, translator=translator
        )
        return translation_summary(harness.state.translation.capability())

    taught = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")

    assert summary(enabled=True, translator=taught) == "ru->en"
    assert summary(enabled=False, translator=FakeTranslator()) == "off"
    assert summary(
        enabled=True, translator=FakeTranslator(fails_with=backend_missing())
    ) == "switched on, but not installed on this PC"
    assert summary(enabled=True, translator=FakeTranslator()) == (
        "switched on, but no language models are installed on this PC"
    )
