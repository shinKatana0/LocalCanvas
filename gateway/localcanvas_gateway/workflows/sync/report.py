"""A run's result as one JSON document.

The same seam ``localcanvas_gateway config`` already uses (`docs/runtime.md`):
Python decides, PowerShell renders, and the boundary between them is one JSON
document on stdout.  The script holds no opinion about what a state means and
composes no sentence of its own -- every phrase a user reads about a workflow
was written here and is tested here.

The document is **pure ASCII**.  ``json.dumps`` escapes anything else as
``\\uXXXX``, which matters because those bytes cross a pipe on Windows: the
receiving shell decodes a native command's output with the console's code page,
and a UTF-8 em dash arriving in a cp866 console is two wrong characters.  As
``\\u2014`` it arrives as itself and ``ConvertFrom-Json`` turns it back into the
character.  ``test_the_report_is_pure_ascii_on_the_wire`` holds this.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List

from .classify import WorkflowState
from .engine import (
    DRY_RUN_CONVERSION_NOTICE,
    DRY_RUN_NOTICE,
    DRY_RUN_NOTICE_ASCII,
    REPORT_VERSION,
    SyncReport,
)


def report_document(report: SyncReport) -> Dict[str, Any]:
    """``report`` as the plain data the front end renders."""

    counts = report.counts()
    return {
        "sync_report_version": REPORT_VERSION,
        "config": str(report.config.source),
        "repo_root": str(report.config.repo_root),
        "generated": report.generated,
        "dry_run": report.dry_run,
        # Present whether or not this was a dry run, so the script never has to
        # decide what to say -- only whether to say it, and which of the two
        # forms of the same sentence the terminal in front of it can carry.
        "notice": DRY_RUN_NOTICE if report.dry_run else None,
        "notice_ascii": DRY_RUN_NOTICE_ASCII if report.dry_run else None,
        "sources": [
            {
                "declared": scan.declared,
                "path": str(scan.root),
                "recursive": scan.recursive,
                "files": len(scan.candidates),
                "skipped": [
                    {"path": item.path, "reason": item.reason} for item in scan.skipped
                ],
            }
            for scan in report.scans
        ],
        "counts": counts,
        "workflows": [_workflow(item) for item in report.workflows],
        "attention": [_workflow(item) for item in report.attention],
        "warnings": list(report.warnings),
        "inventory": {
            "path": str(report.inventory_path),
            "written": report.inventory_written,
        },
        # Where the definitions this run generated went, and how many of them
        # there were.  A count rather than a list: the list is on each
        # workflow, and a second copy of it would be a second thing to keep
        # true.
        "definitions": {
            "path": str(report.config.output.definitions),
            "written": report.definitions_written,
            "failed": report.definitions_failed,
        },
        # What the bridge did, for the run as a whole.  Present with zeroes
        # when nothing needed converting, so the front end never has to ask
        # whether the key is there -- the same rule as ``definition`` above.
        # ``comfy`` is null until something has actually been converted or
        # reused, because until then this run has not established which
        # ComfyUI it is talking to.
        "conversion": {
            "counts": report.conversion_counts(),
            # Present and null unless a dry run actually converted something.
            # The distinction it draws -- converted to look, never kept -- is
            # the whole of the dry-run promise where this stage is concerned,
            # and it is written here, in Python, like every other sentence a
            # user reads.
            "notice": (
                DRY_RUN_CONVERSION_NOTICE
                if report.dry_run and report.conversion_counts()["converted"]
                else None
            ),
            "comfy": (
                report.comfy_identity.to_document()
                if report.comfy_identity is not None
                else None
            ),
        },
        # The editor-format workflows this run did not convert, by what the
        # inventory says about them: new, edited, imported before and
        # untouched, or still needing a look (engine.py, ``editor_history``).
        # It is what the startup check -- a run with no bridge -- counts a
        # canvas by (T-0350), and it changes none of the states above: under
        # ``--no-convert`` every one of these workflows is still reported as
        # ``NEEDS_API_EXPORT``, exactly as before. Present with zeroes when
        # there was nothing unconverted, like the two blocks above.
        "unconverted_editor": report.unconverted_editor_counts(),
        # What the ComfyUI this run talked to declared its inputs accept, and
        # how much of it was used.  ``declared`` is null when there was no
        # ComfyUI to ask, which is a different answer from a contract that
        # settled nothing -- the same distinction ``conversion`` draws above.
        # ``refused_as_file_names`` is the one of the three that cannot be
        # derived from the others, and it is why the block is not two numbers:
        # "declared nothing" and "declared plenty, all of it a file picker"
        # are the same silence without it, and they need opposite actions.
        "runtime_contract": {
            "declared": report.runtime_declared,
            "fields": report.runtime_fields,
            "refused_as_file_names": report.runtime_refused_as_file_names,
        },
        "summary": summary_line(report),
    }


def summary_line(report: SyncReport) -> str:
    """One sentence that fits on a terminal line."""

    counts = report.counts()
    total = len(report.workflows)
    importable = (
        counts[WorkflowState.NEW.value]
        + counts[WorkflowState.CHANGED.value]
        + counts[WorkflowState.UNCHANGED.value]
    )
    parts: List[str] = [
        "{} workflow{} found".format(total, "" if total == 1 else "s"),
        "{} importable ({} new, {} changed, {} unchanged)".format(
            importable,
            counts[WorkflowState.NEW.value],
            counts[WorkflowState.CHANGED.value],
            counts[WorkflowState.UNCHANGED.value],
        ),
        # Definitions, beside the states and never folded into them: an
        # unchanged workflow whose definition was written -- for the first
        # time, or again because this importer now reads it differently --
        # is counted here and nowhere else (T-0246).  A dry run counts what a
        # real run would write, and says so.
        _definitions_part(report),
    ]
    # Only in a run that was asked to (T-0116), so a run that was not reports
    # exactly what it did before the request existed.
    if report.regenerate_labels:
        parts.append(_regenerated_part(report))
    conversions = report.conversion_counts()
    obtained = conversions["converted"] + conversions["reused"]
    if obtained:
        parts.append(
            "{} converted by ComfyUI ({} reused from an earlier run)".format(
                obtained, conversions["reused"]
            )
        )
    refused = conversions["failed"] + conversions["unavailable"]
    if refused:
        parts.append("{} not converted".format(refused))
    attention = len(report.attention)
    duplicates = counts[WorkflowState.EXACT_DUPLICATE.value]
    if duplicates:
        parts.append("{} exact duplicate{}".format(duplicates, "" if duplicates == 1 else "s"))
    parts.append(
        "nothing needs attention" if attention == 0
        else "{} need{} attention".format(attention, "s" if attention == 1 else "")
    )
    return ", ".join(parts) + "."


def _definitions_part(report: SyncReport) -> str:
    if report.dry_run:
        count = report.definitions_would_write
        return "{} definition{} would be written".format(
            count, "" if count == 1 else "s"
        )
    count = report.definitions_written
    return "{} definition{} written".format(count, "" if count == 1 else "s")


def _regenerated_part(report: SyncReport) -> str:
    """The request to regenerate, and what it replaced across the run.

    Every count is always said, a zero included, so the part has one shape and
    the presentation keys (T-0274) are never left for the reader to infer.
    """

    replaced = report.words_replaced
    labels = sum(1 for item in replaced if item.key == "label")
    hints = sum(1 for item in replaced if item.key == "help")
    keys = sum(1 for item in replaced if item.key == "presentation")
    part = (
        "labels, help and presentation generated again on request: {} label{}, "
        "{} help line{} and {} presentation key{} {} replaced".format(
            labels,
            "" if labels == 1 else "s",
            hints,
            "" if hints == 1 else "s",
            keys,
            "" if keys == 1 else "s",
            "would be" if report.dry_run else "were",
        )
    )
    withheld = report.definitions_not_regenerated
    if withheld:
        part += ", {} definition{} left as {} for want of an answer from ComfyUI".format(
            withheld,
            "" if withheld == 1 else "s",
            "it was" if withheld == 1 else "they were",
        )
    return part


def render(report: SyncReport) -> str:
    """The document as the exact text written to stdout."""

    return json.dumps(report_document(report), indent=2, ensure_ascii=True, sort_keys=False)


def _workflow(item) -> Dict[str, Any]:
    candidate = item.candidate
    classification = item.classification
    return {
        "id": item.id,
        "state": item.state.value,
        "format": classification.format.value if classification is not None else None,
        "source_path": str(candidate.path) if candidate is not None else (
            item.remembered.source_path if item.remembered is not None else None
        ),
        "source_relative": candidate.relative if candidate is not None else (
            item.remembered.source_relative if item.remembered is not None else None
        ),
        "content_hash": classification.content_hash if classification is not None else (
            item.remembered.content_hash if item.remembered is not None else None
        ),
        "reason": item.reason,
        "aliases": [alias.get("source_path") for alias in item.aliases],
        # Present and null for a workflow no definition was attempted for, so
        # the key is always there and the front end never has to ask whether
        # it is.
        "definition": (
            item.definition.to_document() if item.definition is not None else None
        ),
        # How this workflow's graph was obtained.  Null for an API-format
        # export: nothing was asked of ComfyUI about it, which is a different
        # thing from having asked and been refused, and the two must not
        # render the same.
        "conversion": (
            item.conversion.to_document() if item.conversion is not None else None
        ),
        # Every literal input the importer considered, whatever it decided.
        # Empty -- never absent -- for a workflow no graph was analysed for,
        # for the same reason as above.
        "controls": [
            _control(record)
            for record in (item.plan.controls if item.plan is not None else ())
        ],
    }


def _control(record) -> Dict[str, Any]:
    """One entry of the control inventory.

    Nothing here composes a sentence: ``reason`` is the one the judgement
    already wrote, and the rest is the identity a curator matches against what
    they see in ComfyUI.  Every key is present on every entry, so the front
    end never has to ask whether one is.
    """

    return {
        "node": record.node,
        "input": record.input,
        "field": record.field,
        "label": record.label,
        "section": record.section,
        "kind": record.kind,
        "reason": record.reason,
    }


__all__ = ["render", "report_document", "summary_line"]
