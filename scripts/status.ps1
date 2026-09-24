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
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$PythonExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$EXIT_OK = 0
$EXIT_UNEXPECTED = 1
$EXIT_CONFIG = 2

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\runtime.yaml' }

function Get-OwnershipLine {
    param([Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role)
    $owned = Resolve-LcOwnedProcess -Role $Role
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
    Write-Host ''

    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
    } catch [System.IO.FileNotFoundException] {
        Write-LcFailure -What 'LocalCanvas has no Python environment yet' `
            -Detail @("Expected: $(if ($PythonExe) { $PythonExe } else { Get-LcVenvPython })") `
            -Fix 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
        exit $EXIT_CONFIG
    }

    $loaded = Read-LcConfig -ConfigPath $Config -PythonExe $python
    if (-not $loaded.Ok) {
        Write-LcFailure -What $loaded.What -Detail $loaded.Detail -Fix $loaded.Hint
        exit $EXIT_CONFIG
    }
    $cfg = $loaded.Document
    $endpoints = Get-LcEndpoints -Config $cfg

    $manage = [bool](Get-LcConfigValue -Document $cfg -Path 'runtime.manage_comfy')
    $mode = if ($manage) { 'managed (LocalCanvas may start ComfyUI)' }
    else { 'external (LocalCanvas never starts or stops ComfyUI)' }

    Write-LcField -Label 'Configuration' -Value ([string](Get-LcConfigValue -Document $cfg -Path 'source'))
    Write-LcField -Label 'Interpreter' -Value "$python (Python $(Get-LcPythonVersion -PythonExe $python))"
    Write-LcField -Label 'Mode' -Value $mode

    $comfyProbe = Invoke-LcProbe -Url $endpoints.ComfyHealthUrl -TimeoutSeconds 3
    $comfyHealth = if ($comfyProbe.Ok) { 'reachable' } else { "not reachable ($($comfyProbe.Error))" }
    Write-LcField -Label 'ComfyUI' -Value "$($endpoints.ComfyBaseUrl)`n$comfyHealth`n$(Get-OwnershipLine -Role 'comfy')"

    $gatewayProbe = Invoke-LcProbe -Url $endpoints.GatewayHealthUrl -TimeoutSeconds 3
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
    Write-LcField -Label 'Gateway' -Value "$($endpoints.GatewayBaseUrl)`n$gatewayHealth`n$(Get-OwnershipLine -Role 'gateway')"

    $endpoint = Get-LcPublishedEndpoint -Config $cfg -Endpoints $endpoints
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

    Write-Host ''
    exit $EXIT_OK
} catch {
    if (Test-LcSeamFailure -ErrorRecord $_) {
        $lines = Get-LcSeamFailureLines -ErrorRecord $_
        Write-LcFailure -What $lines[0] -Detail @($lines | Select-Object -Skip 1)
        exit $EXIT_CONFIG
    }
    Write-LcFailure -What 'Status could not be reported' -Detail @("$($_.Exception.Message)") `
        -Fix 'Check that config\local\runtime.yaml exists and is valid.'
    exit $EXIT_UNEXPECTED
}
