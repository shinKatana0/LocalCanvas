#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Report what LocalCanvas is running, what it owns, and where to reach it.

.DESCRIPTION
    Read-only, in the strict sense: this script starts nothing, stops nothing,
    writes no file, and does not even create the runtime state directory in
    order to report on it. It answers four questions -- what is running, what
    LocalCanvas owns as opposed to merely reuses, whether ComfyUI and the
    gateway are healthy, and what the endpoint is.

.PARAMETER Config
    Path to the runtime configuration. Default: config/local/runtime.yaml.

.PARAMETER PythonExe
    LocalCanvas's own interpreter. Default: .venv\Scripts\python.exe.

.PARAMETER Json
    Print exactly one JSON document on standard output, and every human line
    on standard error. Still read-only: the document is composed from what
    was read, and nothing is written to produce it (docs/runtime.md,
    "Machine interface").
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$PythonExe,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
if ($Json) { Enable-LcMachineOutput }

$EXIT_OK = 0
$EXIT_UNEXPECTED = 1
$EXIT_CONFIG = 2

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\runtime.yaml' }

# What a -Json run reports. Every field is present on every path; what could
# not be read is null.
$statusResult = [ordered]@{
    config_ok = $false
    mode      = $null
    comfy     = [ordered]@{ url = $null; healthy = $null; ownership = $null }
    gateway   = [ordered]@{
        probe_url = $null; reachable = $null; identity = $null; instance_id = $null
        instance_matches_record = $null; ownership = $null; pid = $null; published_endpoint = $null
    }
}

function Complete-Run {
    # Every way out of this script, so that a -Json run prints its one
    # document on every path. Composed in memory and written to standard
    # output: nothing is created on disk to report.
    param([Parameter(Mandatory)][int]$Code)
    if ($Json) {
        try {
            $document = New-LcResultDocument -ExitCode $Code -Ok ($Code -eq $EXIT_OK)
            foreach ($key in @($statusResult.Keys)) { $document[$key] = $statusResult[$key] }
            Write-LcResultDocument -Document $document
        } catch {
            Write-LcResultFallback -ExitCode $Code -Reason "$($_.Exception.Message)"
        }
    }
    exit $Code
}

function Get-OwnershipLine {
    param([Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role, $Owned)
    $owned = if ($null -ne $Owned) { $Owned } else { Resolve-LcOwnedProcess -Role $Role }
    switch ($owned.State) {
        'none' { return 'not started by LocalCanvas' }
        'stale' { return "stale ownership record ($($owned.Reason)) - stop.ps1 will clean it up" }
        'unreadable' { return "unusable ownership record ($($owned.Reason)) - stop.ps1 will clean it up" }
        'mismatch' { return "ownership record does NOT match PID $($owned.Record.pid) ($($owned.Reason)) - not ours" }
        'unproven' { return "ownership of PID $($owned.Record.pid) could NOT be proved ($($owned.Reason)) - it is still running, and LocalCanvas will not stop what it cannot prove" }
        'running' { return "started by LocalCanvas (PID $($owned.Record.pid))" }
    }
    return 'unknown'
}

try {
    Write-LcBanner
    Write-LcInfo 'LocalCanvas status'
    Write-LcLine ''

    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
    } catch [System.IO.FileNotFoundException] {
        Write-LcFailure -What 'LocalCanvas has no Python environment yet' `
            -Detail @("Expected: $(if ($PythonExe) { $PythonExe } else { Get-LcVenvPython })") `
            -Fix 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
        Complete-Run $EXIT_CONFIG
    }

    $loaded = Read-LcConfig -ConfigPath $Config -PythonExe $python
    if (-not $loaded.Ok) {
        Write-LcFailure -What $loaded.What -Detail $loaded.Detail -Fix $loaded.Hint
        Complete-Run $EXIT_CONFIG
    }
    $cfg = $loaded.Document
    $endpoints = Get-LcEndpoints -Config $cfg
    $statusResult.config_ok = $true

    $manage = [bool](Get-LcConfigValue -Document $cfg -Path 'runtime.manage_comfy')
    $statusResult.mode = $(if ($manage) { 'managed' } else { 'external' })
    $mode = if ($manage) { 'managed (LocalCanvas may start ComfyUI)' }
    else { 'external (LocalCanvas never starts or stops ComfyUI)' }

    Write-LcField -Label 'Configuration' -Value ([string](Get-LcConfigValue -Document $cfg -Path 'source'))
    Write-LcField -Label 'Interpreter' -Value "$python (Python $(Get-LcPythonVersion -PythonExe $python))"
    Write-LcField -Label 'Mode' -Value $mode

    $comfyProbe = Invoke-LcProbe -Url $endpoints.ComfyHealthUrl -TimeoutSeconds 3
    $comfyHealth = if ($comfyProbe.Ok) { 'reachable' } else { "not reachable ($($comfyProbe.Error))" }
    $comfyOwned = Resolve-LcOwnedProcess -Role 'comfy'
    $statusResult.comfy = [ordered]@{
        url = $endpoints.ComfyBaseUrl; healthy = [bool]$comfyProbe.Ok; ownership = $comfyOwned.State
    }
    Write-LcField -Label 'ComfyUI' -Value "$($endpoints.ComfyBaseUrl)`n$comfyHealth`n$(Get-OwnershipLine -Role 'comfy' -Owned $comfyOwned)"

    $gatewayProbe = Invoke-LcProbe -Url $endpoints.GatewayHealthUrl -TimeoutSeconds 3
    $gatewayOwned = Resolve-LcOwnedProcess -Role 'gateway'
    # Who answered: a LocalCanvas gateway, something else, or nothing at all.
    # An HTTP error or a line that is not HTTP is an answer, and not ours.
    $gatewayAnswer = $null
    if ($gatewayProbe.Ok) {
        $gatewayAnswer = Get-LcGatewayAnswer -Body $gatewayProbe.Body
        $gatewayIdentity = $gatewayAnswer.Identity
    } elseif ($gatewayProbe.Answered -or $gatewayProbe.StatusCode -gt 0) {
        $gatewayIdentity = 'foreign'
    } else {
        $gatewayIdentity = 'none'
    }
    $answeredInstance = if ($null -ne $gatewayAnswer) { $gatewayAnswer.InstanceId } else { $null }
    $recordedInstance = Get-LcRecordedInstanceId -Record $gatewayOwned.Record
    $recordedPid = $null
    $recordedEndpoint = $null
    if ($null -ne $gatewayOwned.Record) {
        if (Test-LcHasProperty -Object $gatewayOwned.Record -Name 'pid') { $recordedPid = $gatewayOwned.Record.pid }
        if (Test-LcHasProperty -Object $gatewayOwned.Record -Name 'published_endpoint') {
            $recordedEndpoint = $gatewayOwned.Record.published_endpoint
        }
    }
    $statusResult.gateway = [ordered]@{
        probe_url               = $endpoints.GatewayHealthUrl
        reachable               = [bool]$gatewayProbe.Ok
        identity                = $gatewayIdentity
        instance_id             = $answeredInstance
        # Only a comparison that has two sides: null when either the answer
        # or the record carries no instance id.
        instance_matches_record = $(if ($answeredInstance -and $recordedInstance) { $answeredInstance -eq $recordedInstance } else { $null })
        ownership               = $gatewayOwned.State
        pid                     = $recordedPid
        published_endpoint      = $recordedEndpoint
    }
    if ($gatewayProbe.Ok) {
        # Only an answer that identifies itself is a gateway: a body that is not
        # JSON, or names no service ($null), does not identify any more than one
        # naming another service ($false) does (docs/connection.md, T-0260).
        $identity = Test-LcGatewayIdentity -Body $gatewayProbe.Body
        $gatewayHealth = if ($identity -ne $true) {
            'answering, but it does not identify as a LocalCanvas gateway'
        } else { 'reachable' }
    } else {
        $gatewayHealth = "not reachable ($($gatewayProbe.Error))"
    }
    Write-LcField -Label 'Gateway' -Value "$($endpoints.GatewayBaseUrl)`n$gatewayHealth`n$(Get-OwnershipLine -Role 'gateway' -Owned $gatewayOwned)"

    $endpoint = Get-LcPublishedEndpoint -Config $cfg -Endpoints $endpoints
    if ($null -eq $statusResult.gateway.published_endpoint) {
        # No record says what a running gateway was told, so this is what the
        # configuration would publish.
        $statusResult.gateway.published_endpoint = $endpoint.Url
    }
    Write-LcField -Label 'Endpoint' -Value $endpoint.Url
    if (-not $endpoint.IsLan) {
        if ($endpoint.LocalOnlyReason -eq 'loopback-bind') {
            $bind = [string](Get-LcConfigValue -Document $cfg -Path 'gateway.host')
            Write-LcDetail "(gateway.host is $bind, so the gateway is bound to this machine only; a phone cannot reach it until gateway.host allows it)"
        } else {
            Write-LcDetail '(no LAN address was detected; this endpoint is reachable from this machine only)'
        }
    }

    $posture = if ($endpoints.ComfyLocalhostOnly) { 'ComfyUI: localhost only' }
    else { "ComfyUI: $([string](Get-LcConfigValue -Document $cfg -Path 'comfy.host')):$([string](Get-LcConfigValue -Document $cfg -Path 'comfy.port')) - reachable beyond localhost (see docs/privacy-security.md)" }
    Write-LcField -Label 'Posture' -Value $posture

    Write-LcLine ''
    Complete-Run $EXIT_OK
} catch {
    if (Test-LcSeamFailure -ErrorRecord $_) {
        $lines = Get-LcSeamFailureLines -ErrorRecord $_
        Write-LcFailure -What $lines[0] -Detail @($lines | Select-Object -Skip 1)
        Complete-Run $EXIT_CONFIG
    }
    Write-LcFailure -What 'Status could not be reported' -Detail @("$($_.Exception.Message)") `
        -Fix 'Check that config\local\runtime.yaml exists and is valid.'
    Complete-Run $EXIT_UNEXPECTED
}
