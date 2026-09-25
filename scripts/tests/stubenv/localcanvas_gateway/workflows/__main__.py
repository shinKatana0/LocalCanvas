"""Test double for the workflow sync engine.

It implements the whole seam ``scripts/sync-workflows.ps1`` depends on, so
every path the script takes through it is exercised by the suite:

    <python> -m localcanvas_gateway.workflows sync --config <path>
            --runtime-config <path> [--dry-run] [--no-convert]
        One JSON report on stdout and exit 0 (nothing needs attention) or 1
        (something does); a ``[FAIL]`` block on stderr and exit 2 when the run
        could not happen at all.

Nothing here classifies anything. The real engine lives in
``gateway/localcanvas_gateway/workflows/sync/`` and is tested by pytest; this
double produces the report *shape* the script renders, and records the
arguments it was given so a test can prove what the script actually asked for.

Steered by environment variables, so the tests can drive every path without a
second stub:

    LC_STUB_SYNC_MARKER   append the argv of each invocation to this file
    LC_STUB_SYNC_MODE     ok | tree | attention | legacy | rewritten | fatal |
                          fatal-long | inventory-setting | token-in-path |
                          inventory | garbage | silent | crash (default: ok)

``tree`` is the one mode with a real folder behind it (T-0322): it hashes the
files in ``LC_STUB_SYNC_SOURCE``, compares them with ``LC_STUB_SYNC_STATE`` and
reports genuine NEW / CHANGED / UNCHANGED / REMOVED_FROM_SOURCE counts, so a
caller that DECIDES from those counts can be tested. It also logs every native
conversion it invokes, which is the measurement this card turns on; see its own
section below.

``fatal``, ``inventory-setting`` and ``token-in-path`` are failures found before
anything is written. The second one's words name the inventory setting, and the
third one's source path holds the marker token inside a longer line -- so a
front end that looked for the word, or for the token anywhere in a line, rather
than for the marker as a line of its own, would misread them;
``inventory`` is the engine's block for an inventory that could not be written
after the run wrote its files, marker line included.

``rewritten`` is the report for an unchanged workflow whose definition was
written again because the importer now reads it differently: its definition
carries the engine's ``rewritten`` sentence. ``ok`` deliberately carries no
``rewritten`` key at all, as an engine from before T-0246 does not.

``legacy`` is the report an OLDER gateway prints: the same document without
``definitions``, without ``conversion``, without a per-workflow
``definition`` or ``conversion`` and without ``controls``. It exists because the script runs under
``Set-StrictMode -Version Latest``, where reading a key a document does not
carry throws -- so the guard on every new read has something to be proved
against, on a document that is genuinely missing them rather than on a promise
that it would be handled.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Mirrors gateway/localcanvas_gateway/workflows/sync/engine.py::DRY_RUN_NOTICE.
# The em dash is the character the contract names; it reaches the script as a
# \u2014 escape inside the JSON document, never as raw bytes on a pipe.
DRY_RUN_NOTICE = "Dry run \u2014 no files changed."
# Mirrors ...sync/engine.py::DRY_RUN_NOTICE_ASCII: the same sentence for a
# terminal whose code page has no em dash.
DRY_RUN_NOTICE_ASCII = "Dry run - no files changed."
# Mirrors ...sync/engine.py::DRY_RUN_DEFINITION_NOTICE.
DRY_RUN_DEFINITION_NOTICE = "a dry run writes nothing, so this was not written."
# Mirrors ...sync/engine.py::REWRITTEN_NOTICE.
REWRITTEN_NOTICE = (
    "this workflow file has not changed, but this importer now reads it "
    "differently, so its definition was written again. Kept from the file: "
    "its name, its translation setting, and every presentation key, field "
    "label and help line you wrote. Everything else was generated again from "
    "the workflow -- the list of fields and each field's type, section, "
    "default, choices, limits and bindings -- so an edit you made to any of "
    "those was replaced."
)
# Mirror ...sync/engine.py::INVENTORY_NOT_WRITTEN_MARKER and
# INVENTORY_NOT_WRITTEN_NOTICE: the [FAIL] block of the one exit 2 that comes
# after files were written (T-0225).
INVENTORY_NOT_WRITTEN_MARKER = "[INVENTORY_NOT_WRITTEN]"
INVENTORY_NOT_WRITTEN_NOTICE = (
    "The inventory could not be written, and it is written last: definitions, "
    "imported workflow graphs and conversion snapshots this run wrote may "
    "already be on disk. The next successful sync will record them."
)
# Mirrors ...sync/engine.py::DRY_RUN_CONVERSION_NOTICE.
DRY_RUN_CONVERSION_NOTICE = (
    "a dry run converts in order to see what would import, and keeps none of "
    "it: nothing was remembered and nothing was written."
)
# Mirrors gateway/localcanvas_gateway/workflows/sync/engine.py::REPORT_VERSION.
REPORT_VERSION = 1

EXIT_OK = 0
EXIT_ATTENTION = 1
EXIT_FATAL = 2


# Mirrors the sentence gateway/.../sync/semantics.py::classify() composes on
# its weights-suffix branch, and the slug that branch carries. The script
# prints it as it stands; a stub that shortened it would be testing a phrase
# nobody ships.
LOCKED_REASON = (
    "input 'ckpt_name' names a file of weights to load; which file loads is "
    "what the workflow *is*, not how it generates."
)
LOCKED_KIND = "weights_file"
# Mirrors ...sync/analysis.py, case C of the four media cases.
TECHNICAL_REASON = (
    "input 'mask' on node 12 is a matte the graph uses internally, not a "
    "picture a user chooses."
)
TECHNICAL_KIND = "technical_media"


def _report(config, dry_run, attention, legacy=False, converting=True,
            rewritten=False):
    workflow = {
        "id": "sample-workflow",
        "state": "NEEDS_API_EXPORT",
        "format": "ui",
        "source_path": os.path.join("C:\\", "workflows", "sample workflow.json"),
        "source_relative": "sample workflow.json",
        "content_hash": "sha256:" + "0" * 64,
        "reason": (
            "ComfyUI is not reachable at http://127.0.0.1:8188, so this "
            "workflow was not converted. Start ComfyUI with scripts\start.ps1, "
            "then run this sync again."
        ),
        "aliases": [],
        # Mirrors ...sync/bridge.py::Conversion.to_document.
        "conversion": {
            "status": "unavailable",
            "category": "COMFY_UNREACHABLE",
            "detail": "connection refused",
            "comfy": None,
        },
        # Nothing was analysed, so both keys are present and empty rather than
        # absent: the real engine's document is the same shape for every
        # workflow in it.
        "definition": None,
        "controls": [],
    }
    good = {
        "id": "portrait",
        "state": "NEW",
        "format": "api",
        "source_path": os.path.join("C:\\", "workflows", "portrait.json"),
        "source_relative": "portrait.json",
        "content_hash": "sha256:" + "1" * 64,
        "reason": None,
        "aliases": [],
        "conversion": {
            "status": "converted",
            "category": None,
            "detail": None,
            "comfy": {
                "comfyui_version": "0.0.0-stub",
                "frontend_version": "0.0.0-stub",
                "node_type_count": 3,
                "digest": "sha256:" + "2" * 64,
            },
        },
        "definition": {
            "path": os.path.join("C:\\", "definitions", "portrait.yaml"),
            "written": not dry_run,
            "skipped": DRY_RUN_DEFINITION_NOTICE if dry_run else None,
            "problem": None,
            "presentation": {"badge": "TXT2IMG"},
            "notes": [],
        },
        "controls": [
            {
                "node": "4",
                "input": "ckpt_name",
                "field": None,
                "label": None,
                "section": "locked",
                "kind": LOCKED_KIND,
                "reason": LOCKED_REASON,
            },
            {
                "node": "6",
                "input": "text",
                "field": "prompt",
                "label": "Prompt",
                "section": "main",
                "kind": None,
                "reason": "input 'text' holds text written in a person's own language.",
            },
            {
                "node": "12",
                "input": "mask",
                "field": None,
                "label": None,
                "section": "technical",
                "kind": TECHNICAL_KIND,
                "reason": TECHNICAL_REASON,
            },
        ],
    }
    if rewritten and not dry_run:
        good["state"] = "UNCHANGED"
        good["definition"]["rewritten"] = REWRITTEN_NOTICE
    if not converting:
        # Nothing was asked of ComfyUI about any workflow, so no workflow
        # carries a conversion record -- which is what the real engine does
        # with --no-convert, and is a different thing from having asked and
        # been refused.
        for entry in (workflow, good):
            entry["conversion"] = None
    if legacy:
        for entry in (workflow, good):
            entry.pop("definition")
            entry.pop("controls")
            entry.pop("conversion")
    workflows = [good] + ([workflow] if attention else [])
    counts = {
        "INVALID": 0,
        "NEEDS_API_EXPORT": 1 if attention else 0,
        "NEEDS_REVIEW": 0,
        "UNSUPPORTED_INPUT": 0,
        "EXACT_DUPLICATE": 0,
        "NEW": 1,
        "CHANGED": 0,
        "UNCHANGED": 0,
        "REMOVED_FROM_SOURCE": 0,
    }
    document = {
        "sync_report_version": REPORT_VERSION,
        "config": os.path.abspath(config),
        "repo_root": os.path.dirname(os.path.dirname(os.path.abspath(config))),
        "generated": "2026-01-01T00:00:00Z",
        "dry_run": bool(dry_run),
        "notice": DRY_RUN_NOTICE if dry_run else None,
        "notice_ascii": DRY_RUN_NOTICE_ASCII if dry_run else None,
        "sources": [
            {
                "declared": "C:/workflows",
                "path": os.path.join("C:\\", "workflows"),
                "recursive": True,
                "files": len(workflows),
                "skipped": [],
            }
        ],
        "counts": counts,
        "workflows": workflows,
        "attention": [workflow] if attention else [],
        "warnings": [],
        "inventory": {
            "path": os.path.join("C:\\", "inventory.json"),
            "written": not dry_run,
        },
        "definitions": {
            "path": os.path.join("C:\\", "definitions"),
            "written": 0 if dry_run else 1,
            "failed": 0,
        },
        # Mirrors ...sync/report.py: present with zeroes when nothing needed
        # converting, so the script never has to ask whether the key is there.
        # With --no-convert nothing is asked of ComfyUI, so every count is zero
        # and no ComfyUI is identified. That is what the real engine's document
        # says in that case, and it is the one case in which the front end must
        # print no conversion block at all -- so the stub has to be able to
        # produce it, or the suppression branch is untestable.
        "conversion": {
            "notice": DRY_RUN_CONVERSION_NOTICE if (dry_run and converting) else None,
            "counts": {
                "converted": 1 if converting else 0,
                "reused": 0,
                "failed": 0,
                "unavailable": (1 if attention else 0) if converting else 0,
            },
            "comfy": (
                {
                    "comfyui_version": "0.0.0-stub",
                    "frontend_version": "0.0.0-stub",
                    "node_type_count": 3,
                    "digest": "sha256:" + "2" * 64,
                }
                if converting
                else None
            ),
        },
        "summary": (
            "2 workflows found, 1 importable (1 new, 0 changed, 0 unchanged), "
            "1 needs attention."
            if attention
            else "1 workflow found, 1 importable (1 new, 0 changed, 0 unchanged), "
            "nothing needs attention."
        ),
    }
    if legacy:
        document.pop("definitions")
        document.pop("conversion")
    return document


# ==========================================================================
# Tree mode (T-0322): the same seam, with a real folder behind it
# ==========================================================================
#
# ``LC_STUB_SYNC_MODE=tree`` makes the double classify an actual directory of
# files instead of printing a fixed report. It exists because the startup path
# added by T-0322 decides what to DO from the counts -- new, changed, removed,
# unchanged -- and a double that always says "1 new" can prove nothing about
# that decision.
#
# It is still a double and not a second engine, so WHAT IT MIRRORS AND WHAT IT
# DOES NOT is written out rather than claimed in one word. It mirrors:
#
#   * identity is CONTENT, in both of the engine's two forms. ``content_hash``
#     is sha256 over the raw bytes and ``canonical_hash`` is sha256 over
#     ``json.dumps(document, sort_keys=True, separators=(",", ":"),
#     ensure_ascii=True)`` -- exactly the recipes of
#     ``sync/classify.py::content_hash`` and ``::_canonical_hash``, which is
#     why a reformat or a key reordering is UNCHANGED here as it is there.
#     Nothing looks at a modification time, because the sync package records
#     none anywhere. ``test_the_double_hashes_a_workflow_the_way_the_engine_does``
#     holds the two recipes against the engine's own source, statically.
#   * the two-phase match against history (engine.py::_match_against_history):
#     content across every candidate first, then the canonical hash, and only
#     what neither claimed is matched by its path.
#   * the ordering of engine.py:446 and :451. Files are read and hashed first;
#     the conversion bridge is reached afterwards, and ONLY when this run was
#     given one. ``--no-convert`` means there is no bridge, so no conversion is
#     invoked and nothing is logged -- which is the fact the whole card rests
#     on, and the reason the log below exists to be counted.
#   * two byte-identical sources cost ONE conversion (engine.py,
#     ``converted_this_run``), and duplicates are grouped AFTER conversion and
#     only among IMPORTABLE workflows (engine.py::_mark_duplicates): two
#     identical files that could not be converted are two problems, each
#     reported against its own file, not one hidden behind the other.
#   * NOTHING IS EVER DELETED. An entry whose file is gone is carried forward
#     and reported as REMOVED_FROM_SOURCE; a file that has become unreadable
#     leaves the previous entry and the previous definition exactly as they
#     were.
#
# It does NOT mirror, and nothing here may be read as evidence about them:
# the importer's semantic analysis and the sentences it writes; the definition
# FORMAT (a definition here is three lines of yaml, not a workflow definition);
# UNSUPPORTED_INPUT, which needs that analysis and is never produced; the
# conversion snapshot cache and the REUSED status; WHY A CONVERSION FAILED --
# the two failures LC_STUB_SYNC_CONVERT models below (run-wide ``unavailable``,
# per-graph ``failed``) carry sentences of this double's own; an entry carried
# forward as removed, which keeps its old state here where the engine records
# REMOVED_FROM_SOURCE; alias ids, and a canonical-hash (reformatted) alias
# match, which the engine does not make either; ids, which here are the file's
# stem rather than the engine's allocated slug; and the runtime contract. Everything in that second list is
# the gateway's own, and pytest holds it there.
#
# Steered by four more variables, all of them paths this suite owns:
#
#   LC_STUB_SYNC_SOURCE       the folder of *.json workflow files to classify
#   LC_STUB_SYNC_STATE        the inventory: what the last run recorded
#   LC_STUB_SYNC_DEFINITIONS  the catalogue a real run writes definitions into
#   LC_STUB_SYNC_CONVERSIONS  one JSON line per native conversion invoked
#
# and one that is not a path (T-0350):
#
#   LC_STUB_SYNC_CONVERT      ``unavailable`` makes every conversion this run
#                             attempts fail the way the engine's does when
#                             there is no browser or no ComfyUI to ask -- the
#                             run-wide failure, recorded ``unavailable``;
#                             ``refused`` makes ComfyUI refuse each graph --
#                             the content failure, recorded ``failed``. Either
#                             way the canvas stays NEEDS_API_EXPORT, gets no
#                             definition, and is recorded in the inventory as
#                             not imported. Anything else: every one succeeds.
#
# THE EDITOR HISTORY (T-0350). A run with no bridge also reports the engine's
# ``unconverted_editor`` block (engine.py::editor_history): for each canvas it
# did not convert, new / changed / unchanged / attention, decided from the
# inventory entry it matched -- unchanged only when that entry records an
# importable state, which is why the inventory below now records ``state``,
# ``format``, ``conversion`` and ``aliases`` as the engine's does. A canvas the
# last sync recorded NEEDS_API_EXPORT with conversion ``unavailable`` (or no
# conversion record) is ``retry``; with ``failed`` it is ``attention``. A canvas
# no entry claims is looked up among the entries' aliases BY CONTENT, as
# engine.py::_match_editor_aliases does, so the copy of an imported canvas is
# unchanged. An entry written by this double before that carries no
# ``state``; this double only ever wrote importable entries, so a missing state
# reads as imported.

ATTENTION_STATES = (
    "INVALID",
    "NEEDS_API_EXPORT",
    "NEEDS_REVIEW",
    "UNSUPPORTED_INPUT",
    "REMOVED_FROM_SOURCE",
)

#: The states that mean the file is an importable workflow. Only these are
#: grouped as duplicates, and only these claim an inventory entry.
IMPORTABLE_STATES = ("NEW", "CHANGED", "UNCHANGED")

#: What a canvas says under ``LC_STUB_SYNC_CONVERT=unavailable``. The category
#: is one of the engine's own (bridge.py, CATEGORY_BROWSER_NOT_FOUND); the
#: sentence is this double's, and like every sentence here it is not evidence
#: about the engine's wording -- pytest holds that.
STUB_UNAVAILABLE_CATEGORY = "BROWSER_NOT_FOUND"
STUB_UNAVAILABLE_REASON = (
    "no installed browser was found, so this workflow was not converted and "
    "nothing was written for it. Install Google Chrome or Microsoft Edge and "
    "run this sync again."
)
#: What a canvas says under ``LC_STUB_SYNC_CONVERT=refused``: ComfyUI was asked
#: about this graph and refused it (bridge.py, CATEGORY_CONVERSION_REJECTED).
STUB_REFUSED_CATEGORY = "CONVERSION_REJECTED"
STUB_REFUSED_REASON = (
    "ComfyUI's own frontend refused to convert this workflow. Open it in "
    "ComfyUI and see what it says about it."
)


def _tree_parse(raw):
    """The document, or ``None`` when these bytes are not a workflow at all."""
    try:
        document = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(document, dict) or not document:
        return None
    return document


def _tree_format(document):
    """What the bytes are, decided from content and never from the name."""
    if document is None:
        return "invalid"
    if isinstance(document.get("nodes"), list):
        return "ui"
    if all(isinstance(node, dict) and "class_type" in node for node in document.values()):
        return "api"
    return "ambiguous"


def _tree_content_hash(raw):
    """Mirrors sync/classify.py::content_hash -- identity is what is in it.

    Prefixed with the algorithm for the engine's own reason: an unprefixed hex
    string would compare unequal after an algorithm change and every workflow
    would look changed at once.
    """
    import hashlib  # noqa: PLC0415 - only this mode needs it

    return "sha256:" + hashlib.sha256(raw).hexdigest()


def _tree_canonical_hash(document):
    """Mirrors sync/classify.py::_canonical_hash -- the meaning, not the bytes.

    Two exports of the same graph can differ by an indent or by key order and
    be the same workflow. Keeping this recipe identical to the engine's is what
    makes a reformat UNCHANGED here as it is there, and the design cites exactly
    that property as its feasibility proof.
    """
    if document is None:
        return None
    try:
        text = json.dumps(
            document, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
    except (TypeError, ValueError):
        return None
    import hashlib  # noqa: PLC0415 - only this mode needs it

    return "sha256:" + hashlib.sha256(text.encode("ascii")).hexdigest()


def _log_conversion(entry):
    """Record that the native bridge was reached. Counted, never inferred."""
    path = os.environ.get("LC_STUB_SYNC_CONVERSIONS")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def _read_state(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _tree_command(args):
    source = os.environ.get("LC_STUB_SYNC_SOURCE", "")
    state_path = os.environ.get("LC_STUB_SYNC_STATE", "")
    definitions_dir = os.environ.get("LC_STUB_SYNC_DEFINITIONS", "")
    state = _read_state(state_path)

    found = []
    for directory, _dirs, names in os.walk(source):
        for name in sorted(names):
            if not name.lower().endswith(".json"):
                continue
            path = os.path.join(directory, name)
            try:
                with open(path, "rb") as handle:
                    raw = handle.read()
            except OSError:
                continue
            document = _tree_parse(raw)
            found.append(
                {
                    "path": path,
                    "relative": os.path.relpath(path, source).replace("\\", "/"),
                    "hash": _tree_content_hash(raw),
                    "canonical": _tree_canonical_hash(document),
                    "format": _tree_format(document),
                    "source_format": _tree_format(document),
                    "converted": False,
                    "conversion_failed": None,
                    "aliases": [],
                }
            )
    found.sort(key=lambda item: item["relative"])

    # The bridge, after everything has been hashed and only when this run has
    # one. engine.py:446 hashes, engine.py:451 converts, and --no-convert means
    # there is nothing at :451 to reach ComfyUI with.
    targets = [item for item in found if item["format"] == "ui"]
    converted = 0
    unavailable = 0
    failed = 0
    refuse = os.environ.get("LC_STUB_SYNC_CONVERT", "")
    if targets and not args.no_convert:
        _log_conversion({"event": "ensure_identity"})
        already = set()
        for item in targets:
            if refuse == "unavailable":
                # The engine's whole-run bridge failure: every canvas gets the
                # same answer and none of them a graph (engine.py::_convert,
                # ``identity_failure``). Nothing is converted, so nothing is
                # logged as a conversion.
                item["conversion_failed"] = "unavailable"
                unavailable += 1
                continue
            if refuse == "refused":
                # ComfyUI was asked about this graph and said no: the content
                # failure (bridge.py, ``_judge``). It was asked, so it is
                # logged as a conversion invoked.
                _log_conversion({"event": "convert", "source": item["relative"]})
                item["conversion_failed"] = "failed"
                failed += 1
                continue
            if item["hash"] not in already:
                already.add(item["hash"])
                _log_conversion({"event": "convert", "source": item["relative"]})
                converted += 1
            item["format"] = "api"
            item["converted"] = True

    # What the bytes alone decide, now that conversion has had its turn. NEW is
    # the default a history match may later refine; the other three outrank it
    # and keep saying so whatever the history holds (classify.py, WorkflowState).
    for item in found:
        item["state"] = {
            "invalid": "INVALID",
            "ui": "NEEDS_API_EXPORT",
            "ambiguous": "NEEDS_REVIEW",
        }.get(item["format"], "NEW")
        item["duplicate"] = False

    # Duplicates AFTER conversion and only among IMPORTABLE workflows
    # (engine.py::_mark_duplicates): two identical files that could not be
    # converted are two problems, and folding one behind the other would hide
    # half of it. Keyed on the canonical hash where there is one, exactly as
    # the engine keys it.
    canonical_first = {}
    for item in found:
        if item["state"] not in IMPORTABLE_STATES:
            continue
        key = item["canonical"] or item["hash"]
        first = canonical_first.get(key)
        if first is None:
            canonical_first[key] = item
            continue
        item["duplicate"] = True
        item["state"] = "EXACT_DUPLICATE"
        item["id"] = first["relative"]
        first["aliases"].append({
            "source_path": item["path"],
            "source_relative": item["relative"],
            "content_hash": item["hash"],
        })

    # The two-phase match against history (engine.py::_match_against_history):
    # content across every candidate first, then the canonical hash, and only
    # what neither claimed is matched by its path. A duplicate never claims an
    # entry -- it is an alias of the canonical copy, not a workflow of its own.
    by_hash = {}
    by_canonical = {}
    by_relative = {}
    for workflow_id, entry in state.items():
        if not isinstance(entry, dict):
            continue
        by_hash.setdefault(entry.get("content_hash"), workflow_id)
        if entry.get("canonical_hash"):
            by_canonical.setdefault(entry.get("canonical_hash"), workflow_id)
        by_relative.setdefault(entry.get("source_relative"), workflow_id)

    considered = [item for item in found if not item["duplicate"]]
    claimed = set()
    for item in considered:
        item["matched"] = None
        item["matched_by_content"] = False
        matched = by_hash.get(item["hash"])
        if matched is None or matched in claimed:
            matched = by_canonical.get(item["canonical"]) if item["canonical"] else None
        if matched is None or matched in claimed:
            continue
        claimed.add(matched)
        item["matched"] = matched
        item["matched_by_content"] = True
    for item in considered:
        if item["matched"] is not None:
            continue
        matched = by_relative.get(item["relative"])
        if matched is None or matched in claimed:
            continue
        claimed.add(matched)
        item["matched"] = matched
    for item in considered:
        item["id"] = item["matched"] or os.path.splitext(
            os.path.basename(item["relative"]))[0]
        if item["state"] != "NEW":
            # A file that needs attention keeps saying so, whatever it used
            # to be.
            continue
        if item["matched"] is None:
            continue
        item["state"] = "UNCHANGED" if item["matched_by_content"] else "CHANGED"

    # engine.py::editor_history, for every canvas no conversion was attempted
    # for -- which under --no-convert is every canvas there is.
    editor = {"new": 0, "changed": 0, "unchanged": 0, "retry": 0, "attention": 0}
    by_alias = {}
    for workflow_id, entry in state.items():
        if isinstance(entry, dict):
            for alias in entry.get("aliases") or []:
                if isinstance(alias, dict) and alias.get("content_hash"):
                    by_alias.setdefault(alias["content_hash"], workflow_id)
    for item in considered:
        if item["format"] != "ui" or not args.no_convert:
            continue
        matched, by_content = item["matched"], item["matched_by_content"]
        if matched is None and item["hash"] in by_alias:
            matched, by_content = by_alias[item["hash"]], True
        if matched is None:
            editor["new"] += 1
            continue
        if not by_content:
            editor["changed"] += 1
            continue
        entry = state[matched]
        recorded = entry.get("state", "NEW")
        conversion = entry.get("conversion")
        if recorded in IMPORTABLE_STATES:
            editor["unchanged"] += 1
        elif recorded == "NEEDS_API_EXPORT" and (
                not isinstance(conversion, dict)
                or conversion.get("status") == "unavailable"):
            editor["retry"] += 1
        else:
            editor["attention"] += 1

    removed = [
        {"id": workflow_id, "entry": entry}
        for workflow_id, entry in sorted(state.items())
        if isinstance(entry, dict) and workflow_id not in claimed
    ]

    counts = {name: 0 for name in (
        "INVALID", "NEEDS_API_EXPORT", "NEEDS_REVIEW", "UNSUPPORTED_INPUT",
        "EXACT_DUPLICATE", "NEW", "CHANGED", "UNCHANGED", "REMOVED_FROM_SOURCE")}
    for item in found:
        counts[item["state"]] += 1
    counts["REMOVED_FROM_SOURCE"] = len(removed)

    importable = [item for item in found if item["state"] in IMPORTABLE_STATES]

    written = 0
    if not args.dry_run:
        # Definitions first, then the inventory -- the engine's own order.
        # Only an importable workflow is written: a file that has become
        # unreadable leaves the definition its last good run produced alone,
        # which is the whole of "a failed update preserves what was there".
        if definitions_dir:
            os.makedirs(definitions_dir, exist_ok=True)
            for item in importable:
                with open(
                    os.path.join(definitions_dir, item["id"] + ".yaml"),
                    "w", encoding="utf-8",
                ) as handle:
                    handle.write(
                        "id: {}\nname: {}\ncontent_hash: {}\n".format(
                            item["id"], item["id"], item["hash"]))
        if state_path:
            # Carried forward, never pruned: an entry no file explains any more
            # stays exactly as it was, and so does one whose file this run
            # could not read.
            updated = dict(state)
            # A canvas the bridge was asked about and could not convert is
            # recorded as well, as the engine records it: NEEDS_API_EXPORT, so
            # the next check can tell it from one the last sync imported.
            refused = [item for item in considered if item["conversion_failed"]]
            for item in importable + refused:
                updated[item["id"]] = {
                    "state": item["state"],
                    "format": item["source_format"],
                    "content_hash": item["hash"],
                    "canonical_hash": item["canonical"],
                    "source_relative": item["relative"],
                    "source_path": item["path"],
                    "aliases": item["aliases"],
                    "conversion": (
                        {"status": item["conversion_failed"]}
                        if item["conversion_failed"]
                        else {"status": "converted"} if item["converted"]
                        else None
                    ),
                }
            with open(state_path, "w", encoding="utf-8") as handle:
                json.dump(updated, handle, indent=2, sort_keys=True)
        written = len(importable)

    def _entry(item):
        return {
            "id": item["id"],
            "state": item["state"],
            "format": item["format"],
            "source_path": item["path"],
            "source_relative": item["relative"],
            "content_hash": item["hash"],
            "reason": None if item["state"] in IMPORTABLE_STATES
            else STUB_UNAVAILABLE_REASON if item["conversion_failed"] == "unavailable"
            else STUB_REFUSED_REASON if item["conversion_failed"] == "failed"
            else "this workflow file needs a look; run the sync to see why.",
            "aliases": [alias["source_path"] for alias in item["aliases"]],
            "definition": None,
            "conversion": {
                "status": item["conversion_failed"],
                "category": (STUB_UNAVAILABLE_CATEGORY
                             if item["conversion_failed"] == "unavailable"
                             else STUB_REFUSED_CATEGORY),
                "detail": (STUB_UNAVAILABLE_REASON
                           if item["conversion_failed"] == "unavailable"
                           else STUB_REFUSED_REASON),
                "comfy": None,
            } if item["conversion_failed"] else None,
            "controls": [],
        }

    attention = [_entry(item) for item in found if item["state"] in ATTENTION_STATES]
    attention += [
        {
            "id": gone["id"],
            "state": "REMOVED_FROM_SOURCE",
            "format": None,
            "source_path": gone["entry"].get("source_path"),
            "source_relative": gone["entry"].get("source_relative"),
            "content_hash": gone["entry"].get("content_hash"),
            "reason": "no file in your folders carries this workflow any more. "
                      "Nothing has been deleted.",
            "aliases": [],
            "definition": None,
            "conversion": None,
            "controls": [],
        }
        for gone in removed
    ]

    document = {
        "sync_report_version": REPORT_VERSION,
        "config": os.path.abspath(args.config),
        "repo_root": os.path.dirname(os.path.abspath(args.config)),
        "generated": "2026-01-01T00:00:00Z",
        "dry_run": bool(args.dry_run),
        "notice": DRY_RUN_NOTICE if args.dry_run else None,
        "notice_ascii": DRY_RUN_NOTICE_ASCII if args.dry_run else None,
        "sources": [
            {
                "declared": source,
                "path": source,
                "recursive": True,
                "files": len(found),
                "skipped": [],
            }
        ],
        "counts": counts,
        "workflows": [_entry(item) for item in found],
        "attention": attention,
        "warnings": [],
        "inventory": {"path": state_path, "written": not args.dry_run},
        "definitions": {
            "path": definitions_dir,
            "written": written,
            "failed": 0,
        },
        "conversion": {
            "notice": DRY_RUN_CONVERSION_NOTICE if (args.dry_run and converted) else None,
            # A count is a count of CONVERSION RECORDS, and a run with no
            # bridge makes none: engine.py::_convert returns at
            # ``if bridge is None`` before anything is recorded, so under
            # --no-convert every one of these is zero -- including
            # ``unavailable``, which means "asked and could not be answered"
            # and not "would have needed asking". ``unavailable`` and
            # ``failed`` are non-zero only for a run that had a bridge and
            # LC_STUB_SYNC_CONVERT asked it to fail. See the list above of
            # what this double does not mirror.
            "counts": {
                "converted": converted,
                "reused": 0,
                "failed": failed,
                "unavailable": unavailable,
            },
            "comfy": None,
        },
        "unconverted_editor": editor,
        "summary": (
            "{} workflow file(s) found, {} importable ({} new, {} changed, "
            "{} unchanged), {} need attention.".format(
                len(found), len(importable), counts["NEW"], counts["CHANGED"],
                counts["UNCHANGED"], len(attention))
        ),
    }
    json.dump(document, sys.stdout, ensure_ascii=True)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return EXIT_ATTENTION if attention else EXIT_OK


def _sync_command(argv):
    parser = argparse.ArgumentParser(prog="python -m localcanvas_gateway.workflows sync")
    parser.add_argument("--config", required=True)
    parser.add_argument("--repo-root", default=None)
    parser.add_argument("--runtime-config", default=None)
    parser.add_argument("--comfy-url", default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-convert", action="store_true")
    parser.add_argument("--regenerate-labels", action="store_true")
    args = parser.parse_args(argv)

    marker = os.environ.get("LC_STUB_SYNC_MARKER")
    if marker:
        with open(marker, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(list(argv)) + "\n")

    mode = os.environ.get("LC_STUB_SYNC_MODE", "ok")
    if mode == "tree":
        return _tree_command(args)
    if mode == "fatal":
        print(
            "[FAIL] {}: no workflow sources configuration here.".format(args.config),
            file=sys.stderr,
            flush=True,
        )
        print(
            "       Copy config/examples/workflow-sources.example.yaml to "
            "config/local/workflow-sources.yaml",
            file=sys.stderr,
            flush=True,
        )
        return EXIT_FATAL
    if mode == "fatal-long":
        # More, and longer, lines than a -Json error carries: the bound on
        # what sync-workflows.ps1 copies out of the engine's own words.
        print("[FAIL] " + "x" * 1000, file=sys.stderr, flush=True)
        for number in range(1, 60):
            print("       engine line {:02d}".format(number), file=sys.stderr, flush=True)
        return EXIT_FATAL
    if mode == "inventory-setting":
        # Mirrors ...sync/config.py for an output section with no inventory.
        print(
            "[FAIL] {}: output.inventory: required setting is missing.".format(
                args.config
            ),
            file=sys.stderr,
            flush=True,
        )
        return EXIT_FATAL
    if mode == "token-in-path":
        # Mirrors ...sync/discovery.py::resolve_root for a source folder that
        # does not exist, declared with the marker token inside its path.
        print(
            "[FAIL] sources: C:/workflows/missing {} folder: this folder does "
            "not exist. LocalCanvas reads only the folders you name here and "
            "never searches the machine for another one, so there is nothing "
            "to fall back to.".format(INVENTORY_NOT_WRITTEN_MARKER),
            file=sys.stderr,
            flush=True,
        )
        return EXIT_FATAL
    if mode == "inventory":
        for line in (
            "[FAIL] the inventory could not replace the previous one (Access is "
            "denied); workflow-inventory.json was left as it was.",
            "       " + INVENTORY_NOT_WRITTEN_MARKER,
            "       " + INVENTORY_NOT_WRITTEN_NOTICE,
        ):
            print(line, file=sys.stderr, flush=True)
        return EXIT_FATAL
    if mode == "garbage":
        print("this is not JSON", flush=True)
        return EXIT_OK
    if mode == "silent":
        return EXIT_OK
    if mode == "crash":
        print("something went very wrong", file=sys.stderr, flush=True)
        return 7

    attention = mode == "attention"
    # ensure_ascii keeps the document pure ASCII on the wire, exactly as the
    # real engine does: the em dash arrives as \u2014 and never as raw bytes.
    json.dump(
        _report(
            args.config,
            args.dry_run,
            attention,
            legacy=(mode == "legacy"),
            converting=not args.no_convert,
            rewritten=(mode == "rewritten"),
        ),
        sys.stdout,
        ensure_ascii=True,
    )
    sys.stdout.write("\n")
    sys.stdout.flush()
    return EXIT_ATTENTION if attention else EXIT_OK


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "sync":
        return _sync_command(argv[1:])
    print(
        "usage: python -m localcanvas_gateway.workflows sync --config PATH",
        file=sys.stderr,
        flush=True,
    )
    return EXIT_FATAL


if __name__ == "__main__":
    sys.exit(main())
