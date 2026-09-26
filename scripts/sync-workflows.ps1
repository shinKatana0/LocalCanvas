#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Read your own ComfyUI workflow folder and report what LocalCanvas found.

.DESCRIPTION
    A thin front end. Everything that reads a byte of a workflow -- discovery,
    hashing, JSON parsing, format classification, the comparison with the last
    run -- happens in the gateway's own engine:

        <python> -m localcanvas_gateway.workflows sync --config <path>

    and this script resolves the interpreter, runs it, renders what it said and
    sets the exit code. It composes no sentence about a workflow of its own:
    every phrase below the summary was written in Python, where it is tested,
    and arrives here in one JSON document. This is the same seam every other
    script uses for configuration (docs/runtime.md) and it exists for the same
    reason -- one definition of what a workflow file means, and it is not in
    PowerShell.

    Two promises the engine holds and this script must not weaken:

      * the folders named in config/local/workflow-sources.yaml are the ONLY
        folders read. Nothing scans the machine, walks up out of a folder, or
        follows a path found inside a workflow file;
      * your workflow files are only ever read. Nothing renames, moves, deletes
        or rewrites one, and nothing LocalCanvas produces may be written inside
        a source folder.

    With -DryRun the engine does all of the above and writes nothing at all.

    Workflows saved in ComfyUI's EDITOR format cannot be run as they stand, and
    LocalCanvas does not convert one into the other -- that needs the node
    definitions of the exact ComfyUI build that saved it. The engine asks your
    own ComfyUI to convert them, in its own frontend, in a browser that resolves
    nothing but loopback (docs/privacy-security.md). It starts nothing: if
    ComfyUI is not running, each editor workflow is reported with what to do
    about it, and everything else in the folder is read as usual. Start ComfyUI
    with scripts\start.ps1 first if you want them converted.

.PARAMETER Config
    Path to the workflow sources configuration.
    Default: config/local/workflow-sources.yaml.

.PARAMETER PythonExe
    LocalCanvas's own interpreter. Default: .venv\Scripts\python.exe.

.PARAMETER RuntimeConfig
    Path to the runtime configuration, read only for the ComfyUI address an
    editor-format workflow is converted through.
    Default: config/local/runtime.yaml. It is read by the engine, on the Python
    side of the seam -- this script parses no YAML (docs/runtime.md).

.PARAMETER NoConvert
    Do not ask ComfyUI to convert anything. Editor-format workflows are reported
    as needing an API export, exactly as before this capability existed.

.PARAMETER DryRun
    Do everything except write. No inventory, no file of any kind.

.PARAMETER RegenerateLabels
    Write every importable definition with each field's label and help line,
    and every presentation key the importer generates, generated again,
    replacing the ones a normal run keeps as yours. The name, the translation
    setting and any presentation key the importer never generates are kept.
    The report says, for each workflow, which labels, help lines and
    presentation keys that a normal run would have kept were replaced. With
    -DryRun it says what would be replaced and writes nothing.

.PARAMETER Json
    Print exactly one compact JSON document on standard output -- the counts,
    the changes and attention start.ps1 would act on, the workflows that need
    a look, and how many definitions were written -- and every human line on
    standard error. Not the engine's whole report. Exit codes are unchanged
    (docs/runtime.md, "Machine interface").

.EXAMPLE
    .\scripts\sync-workflows.ps1 -DryRun

.EXAMPLE
    .\scripts\sync-workflows.ps1
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$RuntimeConfig,
    [string]$PythonExe,
    [switch]$NoConvert,
    [switch]$DryRun,
    [switch]$RegenerateLabels,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
if ($Json) { Enable-LcMachineOutput }

$EXIT_OK = 0
$EXIT_UNEXPECTED = 1
$EXIT_CONFIG = 2
$EXIT_ATTENTION = 3

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\workflow-sources.yaml' }
if (-not $RuntimeConfig) { $RuntimeConfig = Join-Path $repoRoot 'config\local\runtime.yaml' }

# The engine's report, once there is one: what a -Json document is made from.
$report = $null
# How many of the workflows that need a look a -Json document lists by name.
# The engine's own report lists every one of them, and can run to megabytes.
$AttentionItemsCap = 50
# How much of the engine's own exit-2 text a -Json error carries: lines, and
# characters per line. Its whole text is on standard error regardless.
$EngineDetailLines = 40
$EngineLineChars = 500

function Complete-Run {
    <#
        Every way out of this script, so that a -Json run prints its one
        document on every path.

        ok is true when the sync ran -- exit 0, or 3, where it ran and some
        workflows need a look, which is not a failure (docs/runtime.md). Its
        "changes" and "attention" come from Measure-LcWorkflowReport, the
        arithmetic start.ps1's check uses, so the two can never disagree.
    #>
    param([Parameter(Mandatory)][int]$Code)
    if ($Json) {
        try {
            $ran = $Code -in @($EXIT_OK, $EXIT_ATTENTION)
            $document = New-LcResultDocument -ExitCode $Code -Ok $ran
            $document['dry_run'] = [bool]$DryRun
            $document['no_convert'] = [bool]$NoConvert
            $counts = $null
            $editor = $null
            $measured = $null
            $items = @()
            $itemsTotal = 0
            $written = $null
            $summary = $null
            if ($null -ne $report) {
                $counts = Get-LcSaid $report 'counts'
                $editor = Get-LcSaid $report 'unconverted_editor'
                $measured = Measure-LcWorkflowReport -Report $report
                $attentionList = @(Get-LcSaidList $report 'attention')
                $itemsTotal = $attentionList.Count
                foreach ($item in ($attentionList | Select-Object -First $AttentionItemsCap)) {
                    $reason = [string](Get-LcSaid $item 'reason')
                    $items += , ([ordered]@{
                            id     = Get-LcSaid $item 'id'
                            state  = Get-LcSaid $item 'state'
                            # One line: the first line of the engine's own sentence.
                            reason = $(if ($reason) { ($reason -split "`r?`n")[0].Trim() } else { $null })
                        })
                }
                $definitions = Get-LcSaid $report 'definitions'
                if ($null -ne $definitions) { $written = Get-LcSaid $definitions 'written' }
                $summary = Get-LcSaid $report 'summary'
            }
            $document['counts'] = $counts
            $document['unconverted_editor'] = $editor
            $document['changes'] = $(if ($null -ne $measured) { $measured.Changes } else { $null })
            $document['attention'] = $(if ($null -ne $measured) { $measured.Attention } else { $null })
            $document['new'] = $(if ($null -ne $measured) { $measured.New } else { $null })
            $document['changed'] = $(if ($null -ne $measured) { $measured.Changed } else { $null })
            $document['retry'] = $(if ($null -ne $measured) { $measured.Retry } else { $null })
            $document['removed'] = $(if ($null -ne $measured) { $measured.Removed } else { $null })
            $document['attention_items'] = $items
            $document['attention_items_total'] = $itemsTotal
            $document['definitions_written'] = $written
            $document['summary'] = $summary
            Write-LcResultDocument -Document $document
        } catch {
            Write-LcResultFallback -ExitCode $Code -Reason "$($_.Exception.Message)"
        }
    }
    exit $Code
}

function Test-LcTerminalCanWrite {
    <#
        Can this terminal represent every character of $Text?

        Asked, never imposed. A Windows console is commonly cp437, cp866 or
        cp1251, and none of them has an em dash; the two ways to force one
        through are both worse than asking. Writing UTF-8 bytes into such a
        console puts mojibake in front of the user, and switching the console's
        code page from inside a script changes state this script does not own
        -- and leaves it changed if the script is interrupted. So the text
        adapts to the stream and the stream is never adapted to the text, which
        is the rule this repository already settled for the pairing QR
        (gateway/localcanvas_gateway/pairing.py).

        The question is "can this be represented", not "will writing it throw":
        an encoder with a replacement fallback writes a question mark quite
        happily, so the answer is a round trip.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        $encoding = [Console]::OutputEncoding
        if ($null -eq $encoding) { return $false }
        return ($encoding.GetString($encoding.GetBytes($Text)) -eq $Text)
    } catch {
        return $false
    }
}

function Get-LcSaid {
    <#
        One value out of the engine's document, or $null if it said nothing.

        Set-StrictMode -Version Latest is on, so reading a property a document
        does not carry THROWS -- and which keys a document carries depends on
        which version of the gateway is installed in .venv, which this script
        does not get to assume. An older engine's report is rendered without
        the parts it has nothing to say about, rather than turned into a stack
        trace. Test-LcHasProperty (lib\Common.ps1) is the indexer form of the
        check, for the reasons written there.
    #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-LcHasProperty -Object $Object -Name $Name)) { return $null }
    return $Object.$Name
}

function Get-LcSaidList {
    <#
        The same, for a key holding a list: an absent one is no entries, which
        is what a foreach over it should do. Wrap the call in @() -- a function
        returning an empty array hands back nothing at all.
    #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    $value = Get-LcSaid -Object $Object -Name $Name
    if ($null -eq $value) { return @() }
    return @($value)
}

function Write-EngineLines {
    <#
        The engine's own words, indented, exactly as it wrote them. Nothing
        here rewords a failure: the message names the file, the key, what was
        expected and what was there, and no wrapper can improve on that.
    #>
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $text = "$line".TrimEnd()
        if (-not $text.Trim()) { continue }
        if ($text -match '^\s*\[(?:FAIL|WARN|INFO| OK )\]') {
            Write-LcLine $text.Trim()
        } else {
            Write-LcDetail $text.Trim()
        }
    }
}

function Get-LcEngineFailure {
    <#
        The engine's exit-2 lines as a -Json error: What is its first [FAIL]
        line without the tag (or its first line, when it wrote no tag), and
        Detail is every line it wrote, trimmed, in order.

        Bounded, because the lines are the engine's and their length is not
        this script's to assume: at most $EngineDetailLines lines of at most
        $EngineLineChars characters each, with a line saying how many more
        are on standard error. The [INVENTORY_NOT_WRITTEN] marker is a signal
        for this script, not a sentence for a reader, and is left out -- the
        closing sentence the caller adds says what it means.
    #>
    param([string[]]$Lines)
    $said = @(@($Lines) | ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -and $_ -cne '[INVENTORY_NOT_WRITTEN]' })
    $cut = {
        param([string]$Text)
        if ($Text.Length -le $EngineLineChars) { return $Text }
        return $Text.Substring(0, $EngineLineChars - 3) + '...'
    }
    $first = @($said | Where-Object { $_ -match '^\[FAIL\]' } | Select-Object -First 1)
    $what = ''
    if ($first.Count -gt 0) { $what = ($first[0] -replace '^\[FAIL\]\s*', '').Trim() }
    if (-not $what -and $said.Count -gt 0) { $what = $said[0] }
    if (-not $what) { $what = 'The sync could not be started' }
    $detail = @($said | Select-Object -First $EngineDetailLines | ForEach-Object { & $cut $_ })
    if ($said.Count -gt $EngineDetailLines) {
        $detail += "... and $($said.Count - $EngineDetailLines) more line(s), on standard error"
    }
    return [pscustomobject]@{ What = (& $cut $what); Detail = $detail }
}

try {
    Write-LcBanner
    Write-LcInfo 'LocalCanvas workflow sync'
    Write-LcDetail "Repository: $repoRoot"

    # ------------------------------------------------------------------
    # The interpreter -- explicit and printed, never a bare `py`
    # ------------------------------------------------------------------
    $expectedPython = if ($PythonExe) { $PythonExe } else { Get-LcVenvPython }
    $python = $null
    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
    } catch [System.IO.FileNotFoundException] {
        Write-LcFailure -What 'The LocalCanvas Python interpreter was not found' -Detail @(
            "Expected an interpreter at: $expectedPython") `
            -Fix 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
        Complete-Run $EXIT_CONFIG
    }
    Write-LcDetail "Interpreter: $python"
    Write-LcDetail "Configuration: $Config"
    Write-LcLine ''

    # ------------------------------------------------------------------
    # No source list at all: the beginner's case, answered with a command
    # ------------------------------------------------------------------
    # The engine's own sentence for a missing file tells the reader to copy
    # the example YAML and edit it. Somebody who has not pointed LocalCanvas
    # at a workflow folder yet needs no YAML at all -- setup writes the list,
    # and nothing else, from one parameter (T-0352, F4). Only ABSENCE is
    # answered here; every other problem with the file is the engine's to
    # describe, in its own words, as before.
    if (-not (Test-Path -LiteralPath $Config)) {
        $detail = @("There is no workflow source list at: $Config")
        if ($PSBoundParameters.ContainsKey('Config')) {
            $detail += ('The command below writes the list to config\local\workflow-sources.yaml; ' +
                'run this again without -Config afterwards.')
        }
        $detail += 'No file was written.'
        Write-LcFailure -What 'No workflow folder is configured yet' -Detail $detail `
            -Fix ("Point LocalCanvas at the folder your ComfyUI workflows are saved in: " +
                "pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'")
        Complete-Run $EXIT_CONFIG
    }

    # ------------------------------------------------------------------
    # The engine
    # ------------------------------------------------------------------
    $arguments = @(
        '-m', 'localcanvas_gateway.workflows', 'sync',
        '--config', $Config,
        '--runtime-config', $RuntimeConfig)
    if ($DryRun) { $arguments += '--dry-run' }
    if ($NoConvert) { $arguments += '--no-convert' }
    if ($RegenerateLabels) { $arguments += '--regenerate-labels' }

    # The engine's stderr is data, not a fault -- and only for this one call.
    #
    # $ErrorActionPreference is 'Stop' for the whole script (see the top of the
    # file) and it stays that way: that is what turns a mistake anywhere else in
    # here into a stop rather than a wrong answer. But Windows PowerShell 5.1 --
    # which README.md supported when this was written and does not support now,
    # and which the gate at the top of this file turns away (T-0294) --
    # raises a terminating
    # NativeCommandError the moment a native command writes to stderr while the
    # preference is 'Stop'. The engine writes its own [FAIL] lines there, so
    # under 5.1 control left this very line for the outer catch before any of
    # the branches below could look at $exitCode: every engine failure came out
    # as exit 1 and the generic "could not be completed" wording, instead of the
    # engine's own words and its own exit code (T-0112). PowerShell 7 does not
    # treat native stderr as an error, which is why it was never seen there.
    #
    # So the preference is lowered around THIS invocation and restored in
    # `finally`. Scoped deliberately, and not widened to the script: lowering it
    # globally would swallow real errors in every other line here to fix one
    # call. Between the two assignments nothing happens but running the engine
    # and reading its exit code -- and the exit code, not the stream, is what
    # every branch below decides on.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $python @arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    # A native command's stderr arrives as ErrorRecords and its stdout as
    # strings: the document on one side, the human-readable failure on the
    # other. Same split as Read-LcConfig, for the same reason.
    $stdout = @($output | Where-Object { $_ -is [string] })
    $stderr = @($output | Where-Object { $_ -isnot [string] } | ForEach-Object { "$_" })

    if ($exitCode -eq $EXIT_CONFIG) {
        $said = @($stderr + $stdout | Where-Object { $_ -and $_.Trim() })
        if ($said.Count -eq 0) {
            $said = @("[FAIL] The sync could not be started",
                "Ran: $python $($arguments -join ' ')")
        }
        Write-EngineLines -Lines $said
        Write-LcLine ''
        # Two kinds of exit 2, and the closing sentence has to be true for the
        # one this is (T-0225). Every cause is found before the engine writes
        # anything -- except an inventory that could not be written, which the
        # engine writes last, after the definitions, imported graphs and
        # conversion snapshots. Its [FAIL] block alone carries this marker as a
        # line of its own (engine.py, INVENTORY_NOT_WRITTEN_MARKER).
        $inventoryNotWritten = @($stderr | Where-Object {
                $_ -and $_.Trim() -ceq '[INVENTORY_NOT_WRITTEN]' }).Count -gt 0
        if ($inventoryNotWritten) {
            $closing = 'The inventory was not written, but definitions, imported workflow graphs and conversion snapshots this run wrote may already be on disk. The next successful sync will record them.'
        } else {
            $closing = 'No file was written.'
        }
        Write-LcDetail $closing
        Write-LcLine ''
        # The document's error is the engine's own words, not "Exited with
        # code 2": the lines above are the only description of what is wrong,
        # and a caller showing error.detail has nothing else to show. Recorded
        # without printing -- the terminal already has them, verbatim.
        $failure = Get-LcEngineFailure -Lines $said
        Set-LcLastFailure -What $failure.What -Detail (@($failure.Detail) + @($closing))
        Complete-Run $EXIT_CONFIG
    }

    $document = ($stdout -join "`n").Trim()
    if ($exitCode -ne $EXIT_OK -and $exitCode -ne 1) {
        Write-LcFailure -What 'The sync engine did not complete' -Detail (
            @("Ran: $python $($arguments -join ' ')", "Exit code: $exitCode") +
            @($stderr | Where-Object { $_ -and $_.Trim() })) `
            -Fix 'Run scripts\doctor.ps1 to check the installation.'
        Complete-Run $EXIT_UNEXPECTED
    }
    if (-not $document) {
        Write-LcFailure -What 'The sync engine printed nothing' -Detail @(
            "Ran: $python $($arguments -join ' ')") `
            -Fix 'Run scripts\setup.ps1 to reinstall the gateway into .venv.'
        Complete-Run $EXIT_UNEXPECTED
    }
    try {
        $report = $document | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-LcFailure -What 'The sync engine did not print a JSON document' -Detail (
            @("Ran: $python $($arguments -join ' ')") +
            @($document -split "`r?`n" | Select-Object -First 5)) `
            -Fix 'Run scripts\setup.ps1 to reinstall the gateway into .venv.'
        Complete-Run $EXIT_UNEXPECTED
    }

    # ------------------------------------------------------------------
    # Rendering -- the report's own words, in this project's vocabulary
    # ------------------------------------------------------------------
    foreach ($source in @($report.sources)) {
        $shape = if ($source.recursive) { 'and the folders inside it' } else { 'this folder only' }
        Write-LcOk "Source: $($source.path)"
        Write-LcDetail "$($source.files) workflow file(s), $shape"
        foreach ($skipped in @($source.skipped)) {
            Write-LcDetail "Not read: $($skipped.path)"
            Write-LcDetail "          $($skipped.reason)"
        }
    }

    foreach ($warning in @($report.warnings)) {
        Write-LcWarn "$warning"
    }

    $attention = @($report.attention)
    if ($attention.Count -eq 0) {
        Write-LcOk $report.summary
    } else {
        Write-LcWarn $report.summary
        foreach ($item in $attention) {
            Write-LcLine ''
            Write-LcWarn "$($item.state)  $($item.id)"
            if ($item.source_path) { Write-LcDetail "$($item.source_path)" }
            # The deterministic category, when there is one: a token a person
            # can search for and quote, printed above the sentence rather than
            # instead of it.
            $itemConversion = Get-LcSaid $item 'conversion'
            if ($null -ne $itemConversion) {
                $category = Get-LcSaid $itemConversion 'category'
                if ($category) { Write-LcDetail "[$category]" }
            }
            if ($item.reason) { Write-LcDetail "$($item.reason)" }
        }
    }

    # ------------------------------------------------------------------
    # What ComfyUI converted, and what it produced it with
    # ------------------------------------------------------------------
    # Through Get-LcSaid, like everything below: an older engine in .venv
    # has no such key, and reading one that is not there throws under
    # Set-StrictMode. Nothing is printed at all when no workflow needed
    # converting -- a folder of API exports must not grow a line about a
    # capability it never used.
    $conversion = Get-LcSaid $report 'conversion'
    if ($null -ne $conversion) {
        $counts = Get-LcSaid $conversion 'counts'
        $converted = [int](Get-LcSaid $counts 'converted')
        $reused = [int](Get-LcSaid $counts 'reused')
        $failed = [int](Get-LcSaid $counts 'failed')
        $unavailable = [int](Get-LcSaid $counts 'unavailable')
        if (($converted + $reused + $failed + $unavailable) -gt 0) {
            Write-LcLine ''
            Write-LcInfo 'Converted by ComfyUI'
            Write-LcDetail ("{0} converted, {1} reused from an earlier run, {2} refused, {3} not attempted" -f
                $converted, $reused, $failed, $unavailable)
            $comfy = Get-LcSaid $conversion 'comfy'
            if ($null -ne $comfy) {
                Write-LcDetail ("ComfyUI {0}, frontend {1}, {2} node types" -f
                    (Get-LcSaid $comfy 'comfyui_version'),
                    (Get-LcSaid $comfy 'frontend_version'),
                    (Get-LcSaid $comfy 'node_type_count'))
            }
            # The engine's sentence about what a dry run did with what it
            # converted, verbatim. Without it "N converted" under a dry run
            # reads as N snapshots written, which is the one thing a dry run
            # promises it did not do.
            $conversionNotice = Get-LcSaid $conversion 'notice'
            if ($conversionNotice) { Write-LcDetail "$conversionNotice" }
        }
    }

    Write-LcLine ''
    if ($report.inventory.written) {
        Write-LcInfo "Inventory: $($report.inventory.path)"
    } else {
        Write-LcInfo "Inventory: $($report.inventory.path) (not written)"
    }

    # ------------------------------------------------------------------
    # Where the definitions went
    # ------------------------------------------------------------------
    # Every read below goes through Test-LcHasProperty. Set-StrictMode
    # -Version Latest is on, so touching a property an older engine's document
    # does not carry throws -- and the version of the engine on the machine is
    # not this script's to assume.
    $definitions = Get-LcSaid $report 'definitions'
    if ($null -ne $definitions) {
        Write-LcInfo "Definitions: $(Get-LcSaid $definitions 'path')"
        Write-LcDetail ("{0} written, {1} not written" -f
            (Get-LcSaid $definitions 'written'),
            (Get-LcSaid $definitions 'failed'))
    }

    # ------------------------------------------------------------------
    # Per workflow: where its definition went, and what stayed hidden
    # ------------------------------------------------------------------
    # Printed by default and never behind a switch. Whoever reviews an import
    # has to be able to see that a structural control was recognised and
    # locked on purpose, and a switch is the thing that is forgotten exactly
    # once -- in the run that mattered.
    foreach ($item in @(Get-LcSaidList $report 'workflows')) {
        $definition = Get-LcSaid $item 'definition'
        $hidden = @(@(Get-LcSaidList $item 'controls') | Where-Object {
            @('locked', 'technical') -contains (Get-LcSaid $_ 'section') })
        if ($null -eq $definition -and $hidden.Count -eq 0) { continue }

        Write-LcLine ''
        Write-LcInfo "$(Get-LcSaid $item 'id')"
        if ($null -ne $definition) {
            $path = Get-LcSaid $definition 'path'
            if (Get-LcSaid $definition 'written') {
                Write-LcDetail "Definition: $path"
            } else {
                Write-LcDetail "Definition: $path (not written)"
            }
            # The engine's own sentence about why, whichever of them it
            # wrote -- including why a definition was written again although
            # its workflow did not change. Nothing here rewords one and nothing
            # here invents one.
            foreach ($key in @('skipped', 'problem', 'rewritten')) {
                $said = Get-LcSaid $definition $key
                if ($said) { Write-LcDetail "            $said" }
            }
        }
        foreach ($control in $hidden) {
            $slug = Get-LcSaid $control 'kind'
            $where = "node $(Get-LcSaid $control 'node') input '$(Get-LcSaid $control 'input')'"
            if ($slug) { $where = "$where [$slug]" }
            Write-LcDetail "Not exposed: $where"
            Write-LcDetail "             $(Get-LcSaid $control 'reason')"
        }
    }

    if ($report.dry_run) {
        Write-LcLine ''
        # The engine's sentence, verbatim. There is exactly one copy of it, in
        # Python, where it is tested; both forms of it come from there, and all
        # that is decided here is which one this terminal can actually draw.
        $notice = [string]$report.notice
        if (-not (Test-LcTerminalCanWrite $notice)) {
            $notice = [string]$report.notice_ascii
        }
        Write-LcLine $notice
    }
    Write-LcLine ''

    if ($attention.Count -gt 0) { Complete-Run $EXIT_ATTENTION }
    Complete-Run $EXIT_OK
} catch {
    Write-LcFailure -What 'The workflow sync could not be completed' -Detail @("$($_.Exception.Message)") `
        -Fix "Check that $Config exists and is valid, and run scripts\doctor.ps1." `
        -ErrorRecord $_
    Complete-Run $EXIT_UNEXPECTED
}
