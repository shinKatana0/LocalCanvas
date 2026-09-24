"""A value that is, as a whole, a web address is locked as one (T-0267).

Before this card nothing in `semantics.classify` read a web address as a web
address.  Since T-0095 one whose last component is not shaped like a file is not
path-like either, so on an input whose name carries a safe-setting word it was
handed to the user as an editable text box, on one whose name carries a prompt
word it became a prompt, and anywhere else it went to review as a string
nothing recognised.

What is held here:

* the three names the card measured, each proved to be judged by its **name**
  on an ordinary value first -- so the lock below is the value's doing and not
  something the fixture brought with it;
* the two halves of "a web address": the **whole** value, so a prompt that
  mentions one stays a prompt, and a **host**, so ``mode:fast`` stays a setting;
* the order: every lock asked before it keeps its own kind;
* (T-0082) a web address the path rule answers for is told as a web address,
  while a path with no host keeps the path sentence.

Every address here is under ``example.invalid``, a name reserved never to
resolve.  Nothing in this file reaches a network.
"""

from __future__ import annotations

import pytest

from localcanvas_gateway.workflows.sync import semantics
from localcanvas_gateway.workflows.sync.semantics import (
    Exposure,
    classify,
    looks_like_a_web_address,
)


def web_address_sentence(name: str) -> str:
    return (
        "input {!r} holds a web address; LocalCanvas never puts a web address "
        "in front of a user as a field to edit.".format(name)
    )


# --------------------------------------------------------------------------
# The card's three measurements
# --------------------------------------------------------------------------

#: (input name, an ordinary value, what the name alone makes of it, a web address)
CARD_CASES = [
    pytest.param("mode", "fast", Exposure.EXPOSE, "https://example.invalid/x", id="safe-setting"),
    pytest.param(
        "prompt", "a quiet street", Exposure.EXPOSE, "https://example.invalid/page", id="prompt"
    ),
    pytest.param("api_base", "somewhere", Exposure.UNCERTAIN, "https://example.invalid/v1", id="uncertain"),
]


@pytest.mark.parametrize("name,ordinary,unlocked,address", CARD_CASES)
def test_a_web_address_is_locked_whatever_the_input_is_called(
    name: str, ordinary: str, unlocked: Exposure, address: str
) -> None:
    # The name on its own locks nothing: an ordinary value is exposed or held.
    assert classify(name, ordinary).exposure is unlocked

    verdict = classify(name, address)

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == "url"
    assert verdict.kind == semantics.LOCKED_URL
    assert verdict.reason == web_address_sentence(name)
    assert verdict.field_type is None
    assert verdict.prompt is False


def test_surrounding_whitespace_does_not_hide_a_web_address() -> None:
    verdict = classify("mode", "  https://example.invalid/x\n")

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == semantics.LOCKED_URL


# --------------------------------------------------------------------------
# The whole value, and a host
# --------------------------------------------------------------------------

#: Prose that mentions a web address.  The second one *starts* with it, so only
#: the whole-value rule -- no inner whitespace -- refuses it: the parser alone
#: reads a scheme and a host off its front.  The last two are two addresses
#: joined by a newline and by a tab (T-0273).  ``urlsplit`` drops both
#: characters before it parses, so only whitespace read as *any* whitespace --
#: not a space alone -- refuses them.
PROSE_WITH_A_WEB_ADDRESS = [
    "a quiet street at night, style of https://example.invalid/page",
    "https://example.invalid/page is where the style comes from",
    "https://example.invalid/one\nhttps://example.invalid/two",
    "https://example.invalid/one\thttps://example.invalid/two",
]


@pytest.mark.parametrize("text", PROSE_WITH_A_WEB_ADDRESS)
def test_a_prompt_that_mentions_a_web_address_stays_a_prompt(text: str) -> None:
    assert looks_like_a_web_address(text) is False

    verdict = classify("prompt", text)

    assert verdict.exposure is Exposure.EXPOSE
    assert verdict.prompt is True
    assert verdict.field_type == "multiline"
    assert verdict.kind is None


@pytest.mark.parametrize(
    "value",
    [
        "mode:fast",
        "quality:high",
        "http://",
        "https:",
        # An authority with no host name in it (T-0273): ``netloc`` is not
        # empty here, ``hostname`` is.
        pytest.param("http://@", id="userinfo-only"),
        pytest.param("http://:80", id="port-only"),
    ],
)
def test_a_scheme_with_no_host_is_not_a_web_address(value: str) -> None:
    """``word:word`` parses into a "scheme" and a remainder; it is a setting.
    So is an authority that names no host."""

    assert looks_like_a_web_address(value) is False

    verdict = classify("mode", value)

    assert verdict.exposure is Exposure.EXPOSE
    assert verdict.field_type == "string"
    assert verdict.kind is None


def test_a_value_the_parser_refuses_goes_on_as_it_always_did() -> None:
    """``urlsplit`` raises on a broken IPv6 host; that is not a crash here."""

    assert looks_like_a_web_address("http://[::1") is False
    assert classify("mode", "http://[::1").exposure is Exposure.EXPOSE


@pytest.mark.parametrize(
    "value",
    [
        "https://example.invalid/x",
        "http://example.invalid",
        "ftp://example.invalid/a/b",
        "https://example.invalid:8443/v1?key=value#part",
        "\thttps://example.invalid/x ",
    ],
)
def test_a_whole_web_address_is_one(value: str) -> None:
    assert looks_like_a_web_address(value) is True


# --------------------------------------------------------------------------
# What answers first keeps its answer
# --------------------------------------------------------------------------


def test_a_web_address_naming_a_weights_file_stays_a_weights_file() -> None:
    """Branch 2 answers before the web-address question, and keeps its kind."""

    verdict = classify("mode", "https://example.invalid/weights.safetensors")

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == semantics.LOCKED_WEIGHTS_FILE


@pytest.mark.parametrize(
    "name,kind",
    [
        pytest.param("endpoint", "file_reference", id="locked-string-word"),
        pytest.param("image_url", "file_reference", id="locked-string-word-url"),
        pytest.param("device", "machine_setting", id="locked-any-word"),
    ],
)
def test_a_name_driven_lock_keeps_its_own_kind(name: str, kind: str) -> None:
    """The name locks these before the value is asked about (T-0082 decision).

    ``https://example.invalid/x`` is not path-like -- its last component is not
    shaped like a file -- so no value-driven branch answers for it first.
    """

    assert semantics.looks_like_a_path("https://example.invalid/x") is False

    verdict = classify(name, "https://example.invalid/x")

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == kind


# --------------------------------------------------------------------------
# A path-like web address is told as a web address (T-0082)
# --------------------------------------------------------------------------

#: Web addresses the path rule (branch 3) answers for, because their last
#: component is shaped like a file -- ``a.png``, or the host ``example.invalid``
#: when there is no path at all.  Each is proved path-like in the test, so the
#: test cannot pass by never reaching that branch.
PATH_LIKE_WEB_ADDRESSES = [
    pytest.param("image_url", "https://example.invalid/a.png", id="image-url"),
    pytest.param("endpoint", "https://example.invalid", id="endpoint"),
    pytest.param("style_reference", "http://example.invalid/refs/photo.jpg", id="unnamed"),
]


@pytest.mark.parametrize("name,address", PATH_LIKE_WEB_ADDRESSES)
def test_a_path_like_web_address_is_locked_as_a_web_address(name: str, address: str) -> None:
    assert semantics.looks_like_a_path(address) is True
    assert semantics.has_suffix(address, semantics.WEIGHT_SUFFIXES) is False

    verdict = classify(name, address)

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == semantics.LOCKED_URL
    assert verdict.reason == web_address_sentence(name)


@pytest.mark.parametrize(
    "value",
    [
        "C:/models/photo.png",
        "C:\\models\\photo.png",
        "/home/u/models/photo.png",
        "file:///C:/models/photo.png",
        "portraits/photo.png",
    ],
)
def test_a_path_with_no_host_is_still_a_path_on_this_machine(value: str) -> None:
    """A drive letter parses as a one-letter scheme, and ``file:///`` names no
    host: neither is a web address, and both keep the path sentence."""

    assert semantics.looks_like_a_web_address(value) is False

    verdict = classify("style_reference", value)

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == semantics.LOCKED_FILESYSTEM_PATH
    assert verdict.reason == (
        "input 'style_reference' holds a path on this machine; LocalCanvas never "
        "puts a filesystem path in front of a user."
    )


@pytest.mark.parametrize(
    "value",
    [
        pytest.param("C://models/x.png", id="drive-upper"),
        pytest.param("c://models/x.png", id="drive-lower"),
        pytest.param("X://path/to/images", id="drive-placeholder"),
        pytest.param("file://server/share/photo.png", id="file-with-host"),
        pytest.param("FILE://server/share/photo.png", id="file-upper"),
    ],
)
def test_a_drive_letter_or_the_file_scheme_is_a_path_not_a_web_address(value: str) -> None:
    """These parse with a scheme **and** a host, so only the two exclusions
    keep them paths (T-0272).  Each is path-like, so branch 3 answers for it."""

    assert semantics.looks_like_a_path(value) is True
    assert looks_like_a_web_address(value) is False

    verdict = classify("style_reference", value)

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == semantics.LOCKED_FILESYSTEM_PATH
    assert verdict.reason == (
        "input 'style_reference' holds a path on this machine; LocalCanvas never "
        "puts a filesystem path in front of a user."
    )


def test_the_exclusions_are_exactly_one_letter_and_file() -> None:
    """A two-letter scheme and a scheme merely starting with ``file`` are still
    web addresses: the exclusions are not a length or a prefix."""

    assert looks_like_a_web_address("ws://example.invalid/socket") is True
    assert looks_like_a_web_address("files://example.invalid/x") is True
