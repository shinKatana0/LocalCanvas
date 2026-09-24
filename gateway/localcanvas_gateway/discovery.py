"""mDNS / DNS-SD advertisement of this gateway (`docs/connection.md` §2).

    _localcanvas._tcp.local

with the four TXT records the contract lists and nothing more: ``name``,
``port``, ``version``, ``api``.  No cloud discovery, no external registry, no
account-based pairing.

Two properties this module is written to preserve:

* **Discovery is one way in, not the way in** (`docs/transport-boundary.md` §5).
  Nothing in the API layer touches this module, and a gateway whose
  advertisement fails still serves every request.  Multicast is suppressed by
  plenty of real networks; that is a normal outcome, and it is reported rather
  than being allowed to stop the gateway.
* **A discovered service is a candidate, not a connection.**  What is
  advertised is enough to attempt the identity handshake and nothing else.

The advertised address is the address of the *machine*, chosen by the operating
system's own routing table -- not a guess about network shape.  Nothing here
assumes RFC1918, a /24, or Wi-Fi.
"""

from __future__ import annotations

import logging
import socket
from typing import Any, Dict, Optional

log = logging.getLogger(__name__)

#: The service type the app browses for (`docs/connection.md`).
SERVICE_TYPE = "_localcanvas._tcp.local."

#: A destination used only to ask the OS which local address it *would* use to
#: reach something off this machine.  It is TEST-NET-3 (RFC 5737): reserved for
#: documentation, routed nowhere.  A connectionless UDP socket sends no packet,
#: so nothing leaves the machine -- this is a routing-table lookup wearing a
#: socket's clothes.
_ROUTE_LOOKUP_TARGET = ("203.0.113.1", 9)

#: Hosts that mean "every interface" and therefore name no address to advertise.
_WILDCARD_HOSTS = {"0.0.0.0", "::", "[::]", ""}


class Advertisement:
    """A live mDNS registration.  Closing it withdraws the service."""

    def __init__(self, zeroconf: Any, service_info: Any, address: str) -> None:
        self._zeroconf = zeroconf
        self._service_info = service_info
        self.address = address
        self._closed = False

    @property
    def service_name(self) -> str:
        return str(self._service_info.name)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._zeroconf.unregister_service(self._service_info)
        finally:
            self._zeroconf.close()

    def __enter__(self) -> "Advertisement":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()


def advertise(
    *,
    display_name: str,
    port: int,
    gateway_version: str,
    api_version: int,
    address: Optional[str] = None,
) -> Advertisement:
    """Publish this gateway on the local network.

    Raises whatever zeroconf raises when the network refuses the registration;
    the caller decides whether that is fatal, and in the gateway it is not.
    """

    from zeroconf import ServiceInfo, Zeroconf  # imported late: see module docstring

    resolved = address or lan_address()
    if resolved is None:
        raise OSError("no local network address could be determined for mDNS")

    service_info = ServiceInfo(
        SERVICE_TYPE,
        "{}.{}".format(_instance_label(display_name), SERVICE_TYPE),
        addresses=[socket.inet_aton(resolved)],
        port=port,
        properties=txt_records(
            display_name=display_name,
            port=port,
            gateway_version=gateway_version,
            api_version=api_version,
        ),
        server="{}.local.".format(_host_label()),
    )
    zeroconf = Zeroconf()
    try:
        zeroconf.register_service(service_info)
    except Exception:
        zeroconf.close()
        raise
    log.info("mDNS: advertising %s at %s:%s", service_info.name, resolved, port)
    return Advertisement(zeroconf, service_info, resolved)


def txt_records(
    *, display_name: str, port: int, gateway_version: str, api_version: int
) -> Dict[str, str]:
    """The four TXT keys `docs/connection.md` lists.  Small and useful only."""

    return {
        "name": display_name,
        "port": str(port),
        "version": gateway_version,
        "api": str(api_version),
    }


def lan_address(configured_host: Optional[str] = None) -> Optional[str]:
    """The IPv4 address a phone on this network would use to reach this machine.

    A configured host that names one interface is the answer already; only a
    wildcard bind leaves the question open, and then the operating system is
    asked rather than guessed at.
    """

    if configured_host is not None and configured_host not in _WILDCARD_HOSTS:
        try:
            socket.inet_aton(configured_host)
        except OSError:
            pass  # a name, not a literal: fall through to the route lookup
        else:
            return configured_host

    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(_ROUTE_LOOKUP_TARGET)
        return str(probe.getsockname()[0])
    except OSError as exc:
        log.warning("mDNS: no route to a local network address (%s)", exc)
        return None
    finally:
        probe.close()


def _instance_label(display_name: str) -> str:
    """One DNS-SD label.  Dots separate labels, so they cannot be inside one."""

    label = display_name.replace(".", "-").strip()
    return (label or "LocalCanvas")[:63]


def _host_label() -> str:
    name = socket.gethostname().split(".")[0]
    return (name or "localcanvas")[:63]


__all__ = ["Advertisement", "SERVICE_TYPE", "advertise", "lan_address", "txt_records"]
