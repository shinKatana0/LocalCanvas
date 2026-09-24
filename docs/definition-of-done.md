# v0.1 Definition of Done

The acceptance checklist for `v0.1.0`. LCM-009 reviews **every** item below
against the built artifact. Referenced by `docs/ui-ux.md` and by the LCM-009
card, so it is the one place the list lives.

## Configuration and runtime

1. An unrelated user with an existing ComfyUI can configure LocalCanvas without
   changing source code.
2. `start.ps1` supports managed and external ComfyUI.
3. Managed startup waits for real backend readiness — never a fixed sleep.
4. An appropriate already-running ComfyUI is reused rather than duplicated.
5. `stop.ps1` stops only owned processes.

## Startup and connection

6. Android starts with a polished, restrained LocalCanvas startup animation.
7. Startup transitions naturally into connection/application state.
8. Android connects to a LocalCanvas endpoint.
9. The last successful endpoint is remembered.
10. mDNS discovery works on a normal LAN. (Networks that suppress multicast are
    an expected outcome, not a failure of this item — `docs/connection.md`. What
    is required is that discovery works where multicast works, and degrades to
    QR and manual entry where it does not.)
11. Manual endpoint entry works.
12. Local QR pairing works.
13. Gateway identity and API compatibility are verified.

## Workflows

14. The workflow registry loads.
15. The workflow picker is visually polished.
16. Workflow help explains usage.
17. Dynamic main and Advanced fields work.

## Generation

18. A prompt-only workflow works end to end.
19. An image-input workflow works end to end.
20. A video-input workflow works end to end.
21. Upload progress is usable.
22. Generation state is meaningful.
23. Cancellation behaves correctly where supported.

## Loss and recovery

24. Gateway/machine loss is detected.
25. Reconnect works.
26. ComfyUI-down is distinguished from gateway-down.
27. Surviving job state is recovered where possible.
28. Lost state is reported honestly.
29. Editable inputs survive reconnect.

## Results and layout

30. An image result can be viewed, saved and shared.
31. A video result works at the agreed v0.1 level.
32. The compact Android layout is polished.
33. The expanded/foldable layout is polished.
34. Expected error states are human-readable.

## Operations and verification

35. `status.ps1` works.
36. `doctor.ps1` works.
37. Normal generation works with WAN unavailable.

## Repository and boundaries

38. The public repository contains no original-developer machine configuration.
39. The README lets an unrelated ComfyUI user install and configure LocalCanvas.
40. Core API and client contracts do not prevent a future HTTPS/WSS endpoint.
41. No remote-access implementation has leaked into v0.1.
42. An independent review finds no Blocker or Critical issue.

## Added during bootstrap review

These two are original-developer requirements accepted after the initial list
was written. They carry the same weight as the items above.

43. Strict LAN mode is implemented and verified: reversible, never silent about
    what it changes, disclosing both the local infrastructure it permits and its
    machine-wide collateral effect, with `verify` proving **both** that the
    LocalCanvas LAN path still works and that non-local connectivity is blocked
    (`docs/privacy-security.md`).
44. The Python boundary holds: the gateway runs from its own `.venv/`, nothing
    is ever installed into ComfyUI's Python, interpreter selection is explicit
    and printed, and the supported range is a conservative range rather than one
    pinned patch version (`docs/runtime.md`).

---

After acceptance, tag `v0.1.0` and enter maintenance mode: bug fixes, security
fixes, minimal compatibility fixes. **No speculative v0.2 roadmap is written
during acceptance.**
