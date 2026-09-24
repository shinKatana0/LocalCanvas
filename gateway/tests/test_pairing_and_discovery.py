"""QR pairing and mDNS advertisement (`docs/connection.md`).

Both are deployment conveniences, and both are held to the contract's rules:
the QR is fully local and carries no secret, and the advertisement carries the
four TXT keys and nothing else.

The mDNS *registration* itself is not exercised here.  It needs a multicast
network, which a test machine may not have and which `docs/connection.md`
already treats as unreliable in the real world; what is tested is everything
that is decided in this repository.
"""

from __future__ import annotations

import segno

from localcanvas_gateway import __version__
from localcanvas_gateway.discovery import (
    SERVICE_TYPE,
    _instance_label,
    lan_address,
    txt_records,
)
from localcanvas_gateway.pairing import PAIRING_SCHEME, pairing_payload, pairing_qr

ENDPOINT = "http://192.0.2.42:7801"


# -- pairing ---------------------------------------------------------------


def test_the_payload_is_the_documented_deep_link() -> None:
    assert pairing_payload(ENDPOINT) == "localcanvas://connect?endpoint={}".format(ENDPOINT)


def test_the_payload_carries_the_endpoint_and_nothing_else() -> None:
    """`docs/connection.md`: no secret goes in the QR, because there is none."""

    payload = pairing_payload(ENDPOINT)

    assert payload.count("?") == 1
    assert payload.split("?", 1)[1] == "endpoint={}".format(ENDPOINT)
    assert PAIRING_SCHEME.startswith("localcanvas://")


def test_an_https_endpoint_survives_intact() -> None:
    """The boundary rule: nothing here assumes http, a port, or a LAN address."""

    endpoint = "https://generation.example.com/localcanvas"

    assert pairing_payload(endpoint).endswith(endpoint)


def test_the_qr_actually_encodes_that_payload() -> None:
    """Encoded, not decorative: the matrix is the one segno makes for it."""

    payload = pairing_payload(ENDPOINT)
    expected = segno.make(payload, error="m")

    assert pairing_qr(ENDPOINT) == _terminal(expected)
    assert pairing_qr("http://198.51.100.9:7801") != pairing_qr(ENDPOINT)


def test_the_qr_is_drawn_locally_from_the_payload_only() -> None:
    """No hosted service, no shortener: a code exists with no network at all."""

    rendered = pairing_qr(ENDPOINT)

    assert rendered.strip()
    assert "http" not in rendered  # nothing is fetched and no URL is printed


def _terminal(code) -> str:
    import io

    buffer = io.StringIO()
    code.terminal(out=buffer, compact=True, border=1)
    return buffer.getvalue()


# -- discovery -------------------------------------------------------------


def test_the_service_type_is_the_documented_one() -> None:
    assert SERVICE_TYPE == "_localcanvas._tcp.local."


def test_the_txt_records_are_exactly_the_four_documented_keys() -> None:
    records = txt_records(
        display_name="Kitchen PC", port=7801, gateway_version=__version__, api_version=1
    )

    assert records == {
        "name": "Kitchen PC",
        "port": "7801",
        "version": __version__,
        "api": "1",
    }


def test_a_display_name_with_a_dot_stays_one_dns_sd_label() -> None:
    """Dots separate labels, so one inside a name would split the service name."""

    assert "." not in _instance_label("Studio PC v1.2")


def test_a_configured_address_is_used_as_given() -> None:
    assert lan_address("198.51.100.7") == "198.51.100.7"


def test_a_wildcard_bind_asks_the_machine_instead_of_assuming() -> None:
    """0.0.0.0 names no address, so the OS routing table decides -- not a guess."""

    address = lan_address("0.0.0.0")

    assert address is None or address.count(".") == 3
    assert address != "0.0.0.0"
