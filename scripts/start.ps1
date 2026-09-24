#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Start LocalCanvas: ComfyUI (when managed) and the gateway.

.DESCRIPTION
    The runtime orchestrator of docs/runtime.md, and the one command a user
    runs daily. It is not a gateway launcher: it establishes the whole runtime,
    in both modes.

    In order, and the order is the design:

        validate the configuration
        ensure or reuse ComfyUI
        check -- cheaply -- whether the workflow folders changed
        sync, if and only if that was asked for
        start or verify the gateway
        print the connection block and the pairing QR

    ComfyUI comes before the workflow check because converting an editor-format
    workflow needs a running ComfyUI. The check itself never uses it: it writes
    nothing and contacts nothing (Invoke-LcWorkflowCheck, lib\Common.ps1).

    Managed  (runtime.manage_comfy: true)
        Probe the configured ComfyUI. Reuse it if it is already healthy, and
        take no ownership of it. Otherwise build the launch command from
        comfy.root / comfy.launcher.* / comfy.extra_args, launch it, record
        ownership, and wait on a real HTTP probe until
        startup.comfy_timeout_seconds. On timeout, fail clearly and start no
        gateway.

    External (runtime.manage_comfy: false)
        Never launch ComfyUI and never terminate it. Verify the backend, start
        the gateway only when it is usable, and fail cleanly naming the
        endpoint when it is not.

    Readiness is always a polled HTTP probe. A fixed sleep is never the
    readiness contract -- not as a substitute, and not as a supplement that
    would mask a failing probe.

    Configuration is loaded by the gateway, across a process boundary
    (docs/runtime.md, "The configuration seam"). Nothing here parses YAML,
    defaults a value or re-validates one.

    The endpoint is decided here and handed to the gateway as --endpoint; the
    readiness block below is printed here, once. The gateway does the
    mechanics: mDNS for the life of its process, and the pairing QR on request
    (docs/runtime.md, "Who owns the endpoint and the pairing block").

.PARAMETER Config
    Path to the runtime configuration. Default: config/local/runtime.yaml.

.PARAMETER PythonExe
    LocalCanvas's own interpreter. Default: .venv\Scripts\python.exe.

.PARAMETER WorkflowSources
    Path to the workflow sources configuration, which is what the workflow
    check reads. Default: config/local/workflow-sources.yaml. A file that is
    not there means the workflow folders have not been configured yet, and the
    check is skipped -- never an error.

.PARAMETER SyncWorkflows
    Sync without asking. The check still runs first and is still cheap, so a
    folder nobody touched costs exactly what it costs without this switch:
    nothing beyond the check. Only a folder with something new or changed in it
    is synced.

.PARAMETER SkipWorkflowCheck
    Do not look at the workflow folders at all. Nothing is discovered, nothing
    is hashed, and LocalCanvas starts on the catalogue it already has -- for a
    very large folder on a slow disk, or a start where you simply know nothing
    changed. It contradicts -SyncWorkflows and the two together are refused.

.EXAMPLE
    .\scripts\start.ps1
    .\scripts\start.ps1 -SyncWorkflows
    .\scripts\start.ps1 -Config "D:\My Configs\runtime.yaml"
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$PythonExe,
    [string]$WorkflowSources,
    [switch]$SyncWorkflows,
    [switch]$SkipWorkflowCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$EXIT_OK = 0
$EXIT_UNEXPECTED = 1
$EXIT_CONFIG = 2
$EXIT_COMFY = 3
$EXIT_BACKEND_DOWN = 4
$EXIT_GATEWAY = 5
# The workflow layer could not be established AND there is no catalogue to fall
# back on. Its own code, because it is a different thing from a broken
# configuration and from a backend that is down, and a user who scripts around
# this has to be able to tell them apart.
$EXIT_WORKFLOWS = 6

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\runtime.yaml' }
if (-not $WorkflowSources) { $WorkflowSources = Get-LcWorkflowSourcesPath }
$syncScript = Join-Path $PSScriptRoot 'sync-workflows.ps1'

# What scripts\sync-workflows.ps1 means by each of its exit codes. Its 3 is
# "the sync ran and something needs attention", which is NOT a failure; its 1
# is the unexpected one. The engine underneath uses 1 for attention, so keying
# on 1 here would read every ordinary attention as a crash and every crash as
# ordinary -- in both directions at once (sync-workflows.ps1:99,449).
$SYNC_EXIT_OK = 0
$SYNC_EXIT_UNEXPECTED = 1
$SYNC_EXIT_CONFIG = 2
$SYNC_EXIT_ATTENTION = 3

# The two readers of the child logs. UTF8 is not a guess about the files: it
# is the encoding this script declared for those children when it created the
# redirect (lib\Common.ps1, "Launching a child whose streams we redirect").
# Reading them back in the machine's ANSI code page -- which is what
# Get-Content defaults to under Windows PowerShell -- turns the one character
# that caused T-0085 into mojibake in the very failure report that is supposed
# to explain it.
function Get-LogTail {
    param([string]$Path, [int]$Lines = 15)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        return @(Get-Content -LiteralPath $Path -Tail $Lines -Encoding UTF8 -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Invoke-WorkflowSync {
    <#
        Run the EXISTING pipeline -- scripts\sync-workflows.ps1 -- and hand back
        its exit code. Nothing here repeats a step of it, reads a workflow file,
        or composes a sentence about one: there is one sync in this repository
        and this is not a second one.

        `& <script.ps1>` and not a new shell: measured, the child script's own
        `exit` ends that script, sets $LASTEXITCODE and lets this one carry on,
        which is what makes the exit code readable at all.
    #>
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$SourcesConfig,
        [Parameter(Mandatory)][string]$RuntimeConfig,
        [Parameter(Mandatory)][string]$PythonExe
    )
    Write-Host ''
    & $Script -Config $SourcesConfig -RuntimeConfig $RuntimeConfig -PythonExe $PythonExe
    return [int]$LASTEXITCODE
}

function Get-LogText {
    param([string[]]$Paths)
    $text = ''
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            try {
                $text += ((Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) + "`n")
            } catch { }
        }
    }
    return $text
}

# --------------------------------------------------------------------------

$comfyOwned = $false
$comfyPid = $null
$comfyReused = $false
$gatewayProcess = $null

try {
    Write-LcBanner

    # Two switches that ask for opposite things: one says sync whatever the
    # check finds, the other says do not look. Refused rather than ranked --
    # whichever of them a silent winner was, half the users who typed both
    # would get the other one (docs/runtime.md, "Startup output").
    if ($SyncWorkflows -and $SkipWorkflowCheck) {
        Write-LcFailure -What '-SyncWorkflows and -SkipWorkflowCheck contradict each other' `
            -Detail @('-SyncWorkflows syncs whatever the check finds; -SkipWorkflowCheck does not look at all.',
            'Nothing has been started.') `
            -Fix 'Pass one of them, or neither.'
        exit $EXIT_CONFIG
    }

    # -- Interpreter -------------------------------------------------------
    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
    } catch [System.IO.FileNotFoundException] {
        Write-LcFailure -What 'LocalCanvas has no Python environment yet' `
            -Detail @("Expected: $(if ($PythonExe) { $PythonExe } else { Get-LcVenvPython })") `
            -Fix 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
        exit $EXIT_CONFIG
    }
    $pythonVersion = Get-LcPythonVersion -PythonExe $python

    # -- Configuration, from the gateway ----------------------------------
    $loaded = Read-LcConfig -ConfigPath $Config -PythonExe $python
    if (-not $loaded.Ok) {
        Write-LcFailure -What $loaded.What -Detail $loaded.Detail -Fix $loaded.Hint
        exit $EXIT_CONFIG
    }
    $cfg = $loaded.Document
    $endpoints = Get-LcEndpoints -Config $cfg

    Write-LcInfo 'Configuration loaded'
    Write-LcDetail ([string](Get-LcConfigValue -Document $cfg -Path 'source'))
    Write-LcDetail "Python: $python (Python $pythonVersion)"
    Write-Host ''

    $manage = [bool](Get-LcConfigValue -Document $cfg -Path 'runtime.manage_comfy')
    $comfyUrl = $endpoints.ComfyBaseUrl
    $comfyHealthUrl = $endpoints.ComfyHealthUrl
    $comfyTimeout = [double](Get-LcConfigValue -Document $cfg -Path 'startup.comfy_timeout_seconds')
    $gatewayTimeout = [double](Get-LcConfigValue -Document $cfg -Path 'startup.gateway_timeout_seconds')

    # ======================================================================
    # ComfyUI
    # ======================================================================
    $comfyProbe = Invoke-LcProbe -Url $comfyHealthUrl -TimeoutSeconds 3
    $owned = Resolve-LcOwnedProcess -Role 'comfy'

    if (-not $manage) {
        # External mode. Never launch. Never terminate. No PID is recorded.
        Write-LcInfo "Verifying ComfyUI at $comfyUrl (external mode - LocalCanvas never starts or stops it)"
        if ($owned.State -eq 'running') {
            # A ComfyUI this project started in an earlier managed run. Saying
            # nothing and dropping the record would orphan a real process.
            Write-LcWarn "A ComfyUI started by LocalCanvas (PID $($owned.Record.pid)) is still running"
            Write-LcDetail 'External mode leaves it alone. Its ownership record has been kept,'
            Write-LcDetail 'so scripts\stop.ps1 can still stop it.'
        } elseif ($owned.State -eq 'unproven') {
            # Ownership could not be proved -- which is not proof against us.
            # The record is the only evidence there is, and dropping it would
            # orphan a process that may well be ours.
            Write-LcWarn "A ComfyUI ownership record names PID $($owned.Record.pid), and LocalCanvas could not prove it owns it"
            Write-LcDetail $owned.Reason
            Write-LcDetail 'The record has been kept rather than dropped, so a later run can still prove it.'
        } elseif ($owned.State -ne 'none') {
            Write-LcInfo "Removed a leftover ComfyUI ownership record ($($owned.Reason))"
            Remove-LcOwnedProcessRecord -Role 'comfy'
        }
        if (-not $comfyProbe.Ok) {
            Write-LcFailure -What 'ComfyUI is not reachable' `
                -Detail @(
                    "Probed: $comfyHealthUrl",
                    "Result: $($comfyProbe.Error)",
                    'runtime.manage_comfy is false, so LocalCanvas did not try to start it.',
                    'No gateway was started.') `
                -Fix 'Start ComfyUI yourself, or set runtime.manage_comfy to true in your runtime.yaml.'
            exit $EXIT_BACKEND_DOWN
        }
        Write-LcOk "ComfyUI reachable at $comfyUrl"
        $comfyReused = $true
    } elseif ($comfyProbe.Ok) {
        # Already healthy: reuse it, and do not launch a second instance.
        if ($owned.State -eq 'running') {
            $comfyOwned = $true
            $comfyPid = $owned.Record.pid
            Write-LcOk "ComfyUI already ready at $comfyUrl (started earlier by LocalCanvas, PID $comfyPid)"
        } else {
            if ($owned.State -eq 'unproven') {
                Write-LcWarn "An ownership record names PID $($owned.Record.pid), and LocalCanvas could not prove it owns it"
                Write-LcDetail $owned.Reason
                Write-LcDetail 'The record has been kept rather than dropped, so a later run can still prove it.'
            } elseif ($owned.State -ne 'none') {
                Remove-LcOwnedProcessRecord -Role 'comfy'
            }
            $comfyReused = $true
            Write-LcOk "ComfyUI already running at $comfyUrl - reusing it"
            Write-LcDetail 'It was not started by LocalCanvas, so LocalCanvas takes no ownership of it'
            Write-LcDetail 'and stop.ps1 will leave it running.'
        }
    } else {
        $comfyProcess = $null
        $comfyOutLog = Join-Path (Get-LcRuntimeDirectory) 'comfy.out.log'
        $comfyErrLog = Join-Path (Get-LcRuntimeDirectory) 'comfy.err.log'

        if ($owned.State -eq 'running') {
            # Ours, alive, not answering yet: it is still starting up.
            $comfyOwned = $true
            $comfyPid = $owned.Record.pid
            $comfyProcess = $owned.Process
            Write-LcInfo "ComfyUI is starting (PID $comfyPid, started by LocalCanvas)..."
        } else {
            if ($owned.State -eq 'unproven') {
                # Not proved ours, and not proved anyone else's either. Say what
                # is still running before starting a second ComfyUI beside it --
                # a record replaced in silence is a process nobody knows about.
                Write-LcWarn "An ownership record names PID $($owned.Record.pid), and LocalCanvas could not prove it owns it"
                Write-LcDetail $owned.Reason
                Write-LcDetail "PID $($owned.Record.pid) is still running and is being left alone."
                Write-LcDetail 'Starting ComfyUI now will replace that record with the new process.'
            } elseif ($owned.State -ne 'none') {
                Remove-LcOwnedProcessRecord -Role 'comfy'
            }

            # The launcher arrives resolved: comfy.root and the relative
            # launcher paths were combined on the other side of the seam, so
            # there is one definition of where ComfyUI is, not two.
            $root = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.root')
            $exe = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.launcher.executable_path')
            $script = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.launcher.script_path')

            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-LcFailure -What 'The configured ComfyUI root does not exist' `
                    -Detail @("comfy.root: $root") `
                    -Fix 'Correct comfy.root in your runtime.yaml. LocalCanvas never searches the machine for a ComfyUI installation.'
                exit $EXIT_COMFY
            }
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                Write-LcFailure -What 'The configured ComfyUI launcher executable does not exist' `
                    -Detail @("comfy.launcher.executable resolves to: $exe") `
                    -Fix 'Correct comfy.launcher.executable in your runtime.yaml (it is relative to comfy.root unless absolute).'
                exit $EXIT_COMFY
            }
            if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
                Write-LcFailure -What 'The configured ComfyUI script does not exist' `
                    -Detail @("comfy.launcher.script resolves to: $script") `
                    -Fix 'Correct comfy.launcher.script in your runtime.yaml (it is relative to comfy.root unless absolute).'
                exit $EXIT_COMFY
            }

            $extraArgs = @(Get-LcConfigValue -Document $cfg -Path 'comfy.extra_args' | ForEach-Object { [string]$_ })
            $comfyArgs = @($script) + $extraArgs
            $commandLine = ConvertTo-LcCommandLine -Arguments $comfyArgs

            Write-LcInfo 'Starting ComfyUI...'
            Write-LcDetail "$exe $commandLine"
            try {
                $comfyProcess = Start-LcRedirectedChild -FilePath $exe -CommandLine $commandLine `
                    -WorkingDirectory $root `
                    -StandardOutputLog $comfyOutLog -StandardErrorLog $comfyErrLog
            } catch {
                Write-LcFailure -What 'ComfyUI could not be started' `
                    -Detail @("Command: $exe $commandLine", "$($_.Exception.Message)") `
                    -Fix 'Check comfy.root and comfy.launcher.* in your runtime.yaml.' -ErrorRecord $_
                exit $EXIT_COMFY
            }

            # Ownership is recorded ONLY because LocalCanvas started it, and
            # with enough evidence beside the PID to prove identity later.
            $comfyOwned = $true
            $comfyPid = $comfyProcess.Id
            [void](Save-LcOwnedProcess -Role 'comfy' -Process $comfyProcess -Endpoint $comfyUrl `
                    -CommandLine "$exe $commandLine")
            Write-LcDetail "PID $comfyPid recorded in $(Get-LcPidFilePath -Role 'comfy')"
        }

        # Readiness: a real HTTP probe, polled to the configured timeout.
        $ready = Wait-LcHttpReady -Url $comfyHealthUrl -TimeoutSeconds $comfyTimeout -ProcessToWatch $comfyProcess
        if (-not $ready.Ok) {
            $stillRunning = $false
            if ($comfyProcess) {
                $comfyProcess.Refresh()
                $stillRunning = -not $comfyProcess.HasExited
            }
            $detail = @(
                "Probed: $comfyHealthUrl",
                "Waited: ${comfyTimeout}s ($($ready.Attempts) probes, last result: $($ready.LastError))")
            if ($stillRunning) {
                $detail += "ComfyUI was started by LocalCanvas (PID $comfyPid) and is still running."
            } elseif ($comfyProcess) {
                $detail += "ComfyUI (PID $comfyPid) exited before it became ready."
                foreach ($line in (Get-LogTail -Path $comfyErrLog)) { $detail += "  $line" }
            }
            $detail += 'No gateway was started.'
            Write-LcFailure -What "ComfyUI did not become ready within ${comfyTimeout}s" -Detail $detail `
                -Fix "Check its console output ($comfyOutLog), or raise startup.comfy_timeout_seconds."
            exit $EXIT_COMFY
        }
        Write-LcOk "ComfyUI ready at $comfyUrl"
        if ($comfyPid) { Write-LcDetail "Started by LocalCanvas (PID $comfyPid)" }
    }

    # ======================================================================
    # Workflows -- a cheap look, and a sync only when somebody asked for one
    # ======================================================================
    #
    # NEVER A BLIND AUTO-SYNC. People save experiments, half-finished graphs
    # and temporarily broken ones in the same folder as the workflows they use.
    # A save in ComfyUI must not silently change what the phone shows, so the
    # default is check, then ask, then sync -- and a session nobody is sitting
    # at is not asked at all and changes nothing.
    #
    # It is after ComfyUI on purpose: converting an editor-format workflow
    # needs a running ComfyUI, so a sync accepted here has one to talk to.
    $registry = [string](Get-LcConfigValue -Document $cfg -Path 'workflows.registry')
    # -SyncWorkflows is the whole of "do not ask me": it answers the sync
    # question yes in advance, and it answers the fall-back question below the
    # same way an unattended session is answered.
    $neverAsk = [bool]$SyncWorkflows

    Write-Host ''
    if ($SkipWorkflowCheck) {
        Write-LcInfo 'Workflows: not checked (-SkipWorkflowCheck)'
        Write-LcDetail "LocalCanvas is starting on the catalogue it already has: $registry"
    } elseif (-not (Test-Path -LiteralPath $WorkflowSources -PathType Leaf)) {
        # Not an error and not a failure: a user who has not pointed
        # LocalCanvas at a workflow folder yet has simply not done it yet.
        Write-LcInfo 'Workflows: no folder is configured yet, so nothing was checked'
        Write-LcDetail "Expected: $WorkflowSources"
        # The one-command remedy, not a file to copy and edit (T-0352, F4):
        # setup writes the source list and nothing else when that is all
        # that is missing.
        Write-LcDetail 'To point LocalCanvas at the folder your ComfyUI workflows are saved in, run:'
        Write-LcDetail '    pwsh .\scripts\setup.ps1 -WorkflowSource ''<your workflow folder>'''
    } else {
        $check = Invoke-LcWorkflowCheck -PythonExe $python `
            -SourcesConfig $WorkflowSources -RuntimeConfig $Config

        if (-not $check.Ok) {
            # ------------------------------------------------------------
            # The check itself could not run. That is infrastructure, not a
            # verdict about anybody's workflows -- so the question it raises is
            # whether there is still a catalogue to start on.
            # ------------------------------------------------------------
            Write-LcWarn $check.What
            foreach ($line in @($check.Detail)) { if ("$line".Trim()) { Write-LcDetail "$line" } }

            $catalogue = Get-LcWorkflowCatalogueCount -Registry $registry
            if ($catalogue -eq 0) {
                Write-LcFailure -What 'LocalCanvas has no workflow catalogue to start on' `
                    -Detail @(
                        "The workflow check could not run, and $registry holds no workflow definitions from an earlier run.",
                        'With neither, the app would connect and find nothing to generate with.',
                        'No gateway was started.') `
                    -Fix 'Fix the reason above, then run: pwsh .\scripts\sync-workflows.ps1'
                exit $EXIT_WORKFLOWS
            }

            Write-LcDetail "$catalogue workflow definition(s) from the last good run are still in $registry."
            $anyway = Request-LcYesNo -Question 'Start LocalCanvas anyway?' -PreAnswered:$neverAsk
            if ($anyway.Answer -eq 'no') {
                Write-LcFailure -What 'LocalCanvas was not started' `
                    -Detail @('You answered no to starting on the previous catalogue.',
                        'Nothing was changed and no gateway was started.') `
                    -Fix 'Run: pwsh .\scripts\sync-workflows.ps1 -DryRun   to see what the check could not do.'
                exit $EXIT_WORKFLOWS
            }
            Write-LcInfo "Starting on the previous catalogue ($catalogue workflow definition(s))"
        } elseif ($check.Changes -eq 0) {
            # ------------------------------------------------------------
            # Nothing new and nothing edited. This is the daily case, and it
            # ends here: no sync, no conversion, no question.
            # ------------------------------------------------------------
            Write-LcOk 'Workflows: unchanged - nothing new and nothing edited'
            Write-LcDetail ("$($check.Total) workflow file(s) checked in $($check.ElapsedMs) ms; " +
                'nothing was converted and nothing was written.')
        } else {
            # ------------------------------------------------------------
            # Something changed. Say what, in three numbers, and then ask --
            # or, where there is nobody to ask, name the command and start.
            # ------------------------------------------------------------
            Write-LcWarn "Workflows: $(Format-LcWorkflowChangeSummary -Check $check)"

            $answer = Request-LcYesNo -Question 'Sync workflows now?' -PreAnswered:$neverAsk
            if ($answer.Answer -eq 'yes') {
                $syncCode = Invoke-WorkflowSync -Script $syncScript `
                    -SourcesConfig $WorkflowSources -RuntimeConfig $Config -PythonExe $python

                if ($syncCode -eq $SYNC_EXIT_OK) {
                    Write-LcOk 'Workflows synced'
                } elseif ($syncCode -eq $SYNC_EXIT_ATTENTION) {
                    # Attention is not failure: the sync ran, wrote what it
                    # could and said which workflows a person has to look at.
                    # LocalCanvas starts on all the others.
                    Write-LcWarn 'Workflows synced; some of them need a look'
                    Write-LcDetail 'That is not a failure - everything else was imported, and LocalCanvas is starting.'
                    Write-LcDetail 'Once the reason above is fixed, run: pwsh .\scripts\sync-workflows.ps1   to try them again.'
                } else {
                    Write-LcWarn 'The workflow sync did not complete'
                    if ($syncCode -eq $SYNC_EXIT_CONFIG) {
                        Write-LcDetail 'Its own report above says what it could not read.'
                    } else {
                        Write-LcDetail "It stopped with exit code $syncCode; its own report above says what happened."
                    }
                    $catalogue = Get-LcWorkflowCatalogueCount -Registry $registry
                    if ($catalogue -eq 0) {
                        Write-LcFailure -What 'LocalCanvas has no workflow catalogue to start on' `
                            -Detail @(
                                "The sync did not complete, and $registry holds no workflow definitions from an earlier run.",
                                'No gateway was started.') `
                            -Fix 'Fix what the report above names, then run: pwsh .\scripts\sync-workflows.ps1'
                        exit $EXIT_WORKFLOWS
                    }
                    Write-LcDetail "The $catalogue definition(s) already in $registry were left exactly as they were."
                    $anyway = Request-LcYesNo -Question 'Start LocalCanvas anyway?' -PreAnswered:$neverAsk
                    if ($anyway.Answer -eq 'no') {
                        Write-LcFailure -What 'LocalCanvas was not started' `
                            -Detail @('You answered no to starting on the previous catalogue.',
                                'No gateway was started.') `
                            -Fix 'Fix what the report above names, then run this again.'
                        exit $EXIT_WORKFLOWS
                    }
                    Write-LcInfo "Starting on the previous catalogue ($catalogue workflow definition(s))"
                }
            } elseif ($answer.Answer -eq 'no') {
                Write-LcInfo 'Not synced. LocalCanvas is starting on the catalogue it already has'
                Write-LcDetail 'Your workflow files were only read, and nothing was written.'
                Write-LcDetail 'Run: pwsh .\scripts\sync-workflows.ps1   whenever you want to pick the changes up.'
            } else {
                # Nobody to ask. Nothing is written, nothing is converted and
                # standard input is not read -- the command to run is named
                # instead, and LocalCanvas starts on the catalogue it has.
                Write-LcInfo 'Nothing was synced: this session cannot be asked, and LocalCanvas never syncs on its own'
                Write-LcDetail 'Run: pwsh .\scripts\sync-workflows.ps1   to pick the changes up,'
                Write-LcDetail 'or:  pwsh .\scripts\start.ps1 -SyncWorkflows   to sync and start in one step.'
            }
        }

        # Said after the verdict rather than inside it, because it is true of
        # every branch above and is not what the question was about.
        if ($check.Ok -and $check.Removed -gt 0) {
            Write-LcWarn "$($check.Removed) workflow(s) LocalCanvas knows about are no longer in your folder"
            Write-LcDetail 'Nothing has been deleted: LocalCanvas never removes a definition on its own.'
            Write-LcDetail 'Run: pwsh .\scripts\sync-workflows.ps1 -DryRun   to see which they are.'
        }
        if ($check.Ok -and $check.Attention -gt 0) {
            Write-LcWarn "$($check.Attention) workflow file(s) need a look"
            Write-LcDetail 'LocalCanvas cannot import these as they stand: a file that is not a workflow, one that cannot'
            Write-LcDetail 'be read with confidence, or an editor-format one ComfyUI could not convert at the last sync.'
            Write-LcDetail 'Run: pwsh .\scripts\sync-workflows.ps1 -DryRun   to see what they are, and'
            Write-LcDetail '     pwsh .\scripts\sync-workflows.ps1   to import them once they are fixed.'
        }
    }

    # ======================================================================
    # The endpoint -- decided here, before the gateway is told anything
    # ======================================================================
    $endpoint = Get-LcPublishedEndpoint -Config $cfg -Endpoints $endpoints

    # ======================================================================
    # Gateway
    # ======================================================================
    Write-Host ''
    $gatewayHealthUrl = $endpoints.GatewayHealthUrl
    $gatewayOutLog = Join-Path (Get-LcRuntimeDirectory) 'gateway.out.log'
    $gatewayErrLog = Join-Path (Get-LcRuntimeDirectory) 'gateway.err.log'
    $ownedGateway = Resolve-LcOwnedProcess -Role 'gateway'

    if ($ownedGateway.State -eq 'running') {
        $gatewayProcess = $ownedGateway.Process
        Write-LcInfo "LocalCanvas Gateway is already running (PID $($ownedGateway.Record.pid))"
    } else {
        if ($ownedGateway.State -eq 'unproven') {
            # The same rule as ComfyUI: evidence that cannot be read is still
            # evidence, and destroying it is what orphans a running process.
            Write-LcWarn "A gateway ownership record names PID $($ownedGateway.Record.pid), and LocalCanvas could not prove it owns it"
            Write-LcDetail $ownedGateway.Reason
            Write-LcDetail "PID $($ownedGateway.Record.pid) is still running and is being left alone."
        } elseif ($ownedGateway.State -ne 'none') {
            Remove-LcOwnedProcessRecord -Role 'gateway'
        }

        # The stable seam onto the gateway half of this card.
        # -u so its startup output reaches the log while it is still starting.
        # --endpoint because the endpoint is decided here, not guessed there.
        # --no-qr because the readiness block below is printed here, once.
        $gatewayArgs = @(
            '-u', '-m', 'localcanvas_gateway',
            '--config', ([string](Get-LcConfigValue -Document $cfg -Path 'source')),
            '--host', ([string](Get-LcConfigValue -Document $cfg -Path 'gateway.host')),
            '--port', ([string](Get-LcConfigValue -Document $cfg -Path 'gateway.port')),
            '--endpoint', $endpoint.Url,
            '--no-qr'
        )
        $gatewayCommandLine = ConvertTo-LcCommandLine -Arguments $gatewayArgs

        Write-LcInfo 'Starting LocalCanvas Gateway...'
        # This run's output has to start empty, because it is what the block
        # below reports on. A log we cannot truncate means a gateway we do not
        # own is still holding it -- which is worth saying plainly.
        try {
            foreach ($log in @($gatewayOutLog, $gatewayErrLog)) {
                Set-Content -LiteralPath $log -Value '' -Encoding UTF8 -ErrorAction Stop
            }
        } catch {
            Write-LcFailure -What 'A previous LocalCanvas gateway is still holding its log file' `
                -Detail @("Log: $gatewayOutLog", "$($_.Exception.Message)") `
                -Fix 'Run scripts\stop.ps1 first, then start again.'
            exit $EXIT_GATEWAY
        }
        try {
            $gatewayProcess = Start-LcRedirectedChild -FilePath $python -CommandLine $gatewayCommandLine `
                -WorkingDirectory $repoRoot `
                -StandardOutputLog $gatewayOutLog -StandardErrorLog $gatewayErrLog
        } catch {
            Write-LcFailure -What 'The LocalCanvas Gateway could not be started' `
                -Detail @("Command: $python $gatewayCommandLine", "$($_.Exception.Message)") `
                -Fix 'Run scripts\setup.ps1 to (re)install the gateway into .venv.' -ErrorRecord $_
            exit $EXIT_GATEWAY
        }
        [void](Save-LcOwnedProcess -Role 'gateway' -Process $gatewayProcess `
                -Endpoint $endpoints.GatewayBaseUrl -CommandLine "$python $gatewayCommandLine")
    }

    $gatewayReady = Wait-LcHttpReady -Url $gatewayHealthUrl -TimeoutSeconds $gatewayTimeout -ProcessToWatch $gatewayProcess
    if (-not $gatewayReady.Ok) {
        $detail = @(
            "Probed: $gatewayHealthUrl",
            "Waited: ${gatewayTimeout}s ($($gatewayReady.Attempts) probes, last result: $($gatewayReady.LastError))")
        if ($gatewayReady.ProcessExited) { $detail += 'The gateway process exited before it became ready.' }
        foreach ($line in (Get-LogTail -Path $gatewayErrLog)) { $detail += "  $line" }

        # The gateway is ours, so cleaning it up is ours to do. ComfyUI is a
        # different matter: it is expensive to restart and may be reused, so it
        # is left exactly as it is and stop.ps1 is named instead.
        if ($gatewayProcess) {
            try { [void](Stop-LcOwnedProcess -Process $gatewayProcess -GraceSeconds 5) } catch { }
        }
        Remove-LcOwnedProcessRecord -Role 'gateway'
        if ($comfyOwned) {
            $detail += "ComfyUI (PID $comfyPid) was left running; scripts\stop.ps1 will stop it."
        }
        Write-LcFailure -What "The gateway did not become ready within ${gatewayTimeout}s" -Detail $detail `
            -Fix "Check $gatewayErrLog, or raise startup.gateway_timeout_seconds."
        exit $EXIT_GATEWAY
    }

    # Only an answer that identifies itself is a gateway: a body that is not
    # JSON, or names no service ($null), does not identify any more than one
    # naming another service ($false) does (docs/connection.md, T-0260).
    $identity = Test-LcGatewayIdentity -Body $gatewayReady.LastBody
    if ($identity -ne $true) {
        Write-LcWarn "Something is answering $gatewayHealthUrl but it does not identify as a LocalCanvas gateway."
        Write-LcDetail 'The app will report it as "Not a LocalCanvas server".'
    }
    Write-LcOk 'Gateway ready'

    # ======================================================================
    # What the gateway said for itself
    # ======================================================================
    # Its whole banner is not relayed -- the readiness block below is printed
    # once, here. What is worth repeating is what it warned or failed about.
    $gatewayLog = Get-LogText -Paths @($gatewayOutLog, $gatewayErrLog)
    $notices = @($gatewayLog -split "`r?`n" | Where-Object { $_ -match '^\s*\[(WARN|FAIL)\]' })
    if ($notices.Count -gt 0) {
        foreach ($line in $notices) { Write-Host $line.TrimEnd() }
    }

    if ($gatewayLog -match '(?im)mdns[^\r\n]*(unavailable|not available|failed|failure|disabled|could not|cannot)') {
        $discovery = 'mDNS unavailable - QR pairing and manual entry still work'
    } elseif ($gatewayLog -match '(?im)mdns active|_localcanvas\._tcp') {
        $discovery = 'mDNS active'
    } else {
        $discovery = 'not reported by the gateway'
    }

    # The QR is the gateway's to draw, on the endpoint decided above.
    $qrResult = Invoke-LcGatewayQr -PythonExe $python -Endpoint $endpoint.Url
    if ($qrResult.Ok) {
        $qr = $qrResult.Text
    } else {
        $qr = "unavailable - $($qrResult.Error)"
    }

    if ($endpoints.ComfyLocalhostOnly) {
        $comfyPosture = 'localhost only'
    } else {
        $comfyPosture = "$([string](Get-LcConfigValue -Document $cfg -Path 'comfy.host')):$([string](Get-LcConfigValue -Document $cfg -Path 'comfy.port')) - reachable beyond localhost (see docs/privacy-security.md)"
    }
    if ($comfyReused) {
        $comfyPosture += "`nreused - not started by LocalCanvas"
    } elseif ($comfyOwned) {
        $comfyPosture += "`nstarted by LocalCanvas (PID $comfyPid)"
    }

    Write-Host ''
    Write-LcOk 'LocalCanvas is ready'
    Write-LcField -Label 'Endpoint' -Value $endpoint.Url
    if (-not $endpoint.IsLan) {
        if ($endpoint.LocalOnlyReason -eq 'loopback-bind') {
            $bind = [string](Get-LcConfigValue -Document $cfg -Path 'gateway.host')
            Write-LcDetail "(gateway.host is $bind, so the gateway is bound to this machine only; a phone cannot reach it until gateway.host allows it)"
        } else {
            Write-LcDetail '(no LAN address was detected; this endpoint is reachable from this machine only)'
        }
    }
    Write-LcField -Label 'Discovery' -Value $discovery
    Write-LcField -Label 'QR pairing' -Value $qr
    Write-LcField -Label 'ComfyUI' -Value $comfyPosture
    Write-Host ''
    Write-LcDetail 'Stop it again with scripts\stop.ps1'
    Write-Host ''
    exit $EXIT_OK
} catch {
    if (Test-LcSeamFailure -ErrorRecord $_) {
        $lines = Get-LcSeamFailureLines -ErrorRecord $_
        Write-LcFailure -What $lines[0] -Detail @($lines | Select-Object -Skip 1)
        exit $EXIT_CONFIG
    }
    Write-LcFailure -What 'LocalCanvas could not be started' -Detail @("$($_.Exception.Message)") `
        -Fix 'Run scripts\status.ps1 to see what is running, then try again.' -ErrorRecord $_
    exit $EXIT_UNEXPECTED
}
