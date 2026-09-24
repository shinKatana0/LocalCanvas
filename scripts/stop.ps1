#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Stop the processes LocalCanvas started -- and only those.

.DESCRIPTION
    docs/runtime.md, "Process ownership":

      * Never kill by name. Not python.exe, not "a ComfyUI process", not
        "whatever holds port 8188". A user's other Python work is not ours to
        end. Nothing in this script ever looks a process up by name or by port.

      * A PID file alone is not proof of ownership, because Windows reuses
        PIDs. Every PID is checked against the start time and image path
        recorded beside it, and anything that cannot be positively confirmed
        counts against ownership and is left alone.

      * If ComfyUI was reused rather than launched, this script leaves it
        running and says so. What it stops is what an ownership record proves
        LocalCanvas started -- in either mode, because a ComfyUI this project
        started is this project's to stop even if the configuration has since
        been switched to external.

      * A stale PID file, for a process that no longer exists, is cleaned up
        quietly.

      * When ownership can be neither proved nor disproved -- the identity of
        the process could not be read, or none was recorded -- the process is
        left alone and its ownership record is KEPT. Deleting it would be the
        one irreversible move available: the process goes on running and no
        LocalCanvas command could ever claim it again.

.PARAMETER Config
    Path to the runtime configuration. Default: config/local/runtime.yaml.
    Optional: without it, this script still stops exactly what the ownership
    records name.

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

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\runtime.yaml' }

function Stop-Role {
    <#
        Resolve one ownership record and act on exactly what it proves.
        Returns $true when a process was actually stopped.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role,
        [Parameter(Mandatory)][string]$Label
    )
    $owned = Resolve-LcOwnedProcess -Role $Role
    switch ($owned.State) {
        'none' {
            Write-LcInfo "$Label is not owned by LocalCanvas - nothing to stop"
            return $false
        }
        'stale' {
            Remove-LcOwnedProcessRecord -Role $Role
            Write-LcInfo "$Label - stale PID file removed ($($owned.Reason))"
            return $false
        }
        'unreadable' {
            Remove-LcOwnedProcessRecord -Role $Role
            Write-LcInfo "$Label - unusable PID file removed ($($owned.Reason))"
            return $false
        }
        'mismatch' {
            # PROVED not ours: that PID is running a different executable, so
            # the process the record described is gone and the PID has been
            # reused. Left alone, and the record goes with it.
            Write-LcWarn "$Label - PID $($owned.Record.pid) is NOT the process LocalCanvas started"
            Write-LcDetail $owned.Reason
            Write-LcDetail 'Leaving that process alone and removing the ownership record, which now describes a process that no longer exists.'
            Remove-LcOwnedProcessRecord -Role $Role
            return $false
        }
        'unproven' {
            # NOT proved ours -- which is not the same as proved not ours, and
            # the difference is the whole of T-0088. Deleting the record here
            # turned "owned but temporarily unverifiable" into "unowned
            # forever": the process kept running and nothing could reclaim it.
            # So it is left alone AND the record is kept.
            Write-LcWarn "$Label - LocalCanvas could not prove it owns PID $($owned.Record.pid)"
            Write-LcDetail $owned.Reason
            Write-LcDetail "PID $($owned.Record.pid) is still running and was NOT stopped."
            Write-LcDetail "The ownership record was kept, so a later stop can prove it and stop it: $($owned.PidFile)"
            Write-LcDetail 'If you know that process is not LocalCanvas''s, stop it yourself and delete that file.'
            return $false
        }
        'running' {
            $processId = $owned.Record.pid
            Write-LcInfo "Stopping $Label (PID $processId)..."
            $outcome = Stop-LcOwnedProcess -Process $owned.Process
            if ($outcome -eq 'still-running') {
                Write-LcWarn "$Label (PID $processId) did not exit; the ownership record was kept."
                return $false
            }
            Remove-LcOwnedProcessRecord -Role $Role
            Write-LcOk "$Label stopped (PID $processId, $outcome)"
            return $true
        }
    }
    return $false
}

try {
    Write-LcBanner
    Write-LcInfo 'Stopping LocalCanvas'
    Write-Host ''

    # Configuration is a nicety here, not a requirement: ownership records
    # carry everything needed to stop what we started.
    $cfg = $null
    $endpoints = $null
    $manage = $true
    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
        $loaded = Read-LcConfig -ConfigPath $Config -PythonExe $python
        if ($loaded.Ok) {
            $cfg = $loaded.Document
            $endpoints = Get-LcEndpoints -Config $cfg
            $manage = [bool](Get-LcConfigValue -Document $cfg -Path 'runtime.manage_comfy')
        } else {
            Write-LcWarn "$($loaded.What); stopping only what the ownership records name."
            foreach ($line in $loaded.Detail) { Write-LcDetail $line }
            Write-Host ''
        }
    } catch {
        # Including a failure of the seam itself. Whatever the configuration
        # turns out to be, it never prevents this script from stopping what the
        # ownership records prove LocalCanvas started.
        Write-LcWarn 'Configuration could not be read; stopping only what the ownership records name.'
        $detail = if (Test-LcSeamFailure -ErrorRecord $_) {
            Get-LcSeamFailureLines -ErrorRecord $_
        } else {
            @("$($_.Exception.Message)")
        }
        foreach ($line in $detail) { Write-LcDetail $line }
        Write-Host ''
    }

    [void](Stop-Role -Role 'gateway' -Label 'LocalCanvas Gateway')

    # Ownership decides, not the mode. A ComfyUI whose record proves LocalCanvas
    # started it is stopped; anything else is left exactly where it is.
    $stoppedComfy = Stop-Role -Role 'comfy' -Label 'ComfyUI'
    if (-not $stoppedComfy) {
        if (-not $manage) {
            Write-LcInfo 'ComfyUI is external (runtime.manage_comfy: false) - LocalCanvas never stops it'
        }
        if ($endpoints) {
            # If a ComfyUI is nevertheless answering, it is someone else's and
            # stays exactly where it is.
            $probe = Invoke-LcProbe -Url $endpoints.ComfyHealthUrl -TimeoutSeconds 3
            if ($probe.Ok) {
                Write-LcInfo "ComfyUI is still running at $($endpoints.ComfyBaseUrl) - leaving it alone"
                Write-LcDetail 'LocalCanvas did not start it, so LocalCanvas does not stop it.'
            }
        }
    }

    Write-Host ''
    Write-LcOk 'Done'
    Write-Host ''
    exit 0
} catch {
    if (Test-LcSeamFailure -ErrorRecord $_) {
        $lines = Get-LcSeamFailureLines -ErrorRecord $_
        Write-LcFailure -What $lines[0] -Detail @($lines | Select-Object -Skip 1)
        exit 1
    }
    Write-LcFailure -What 'Stopping LocalCanvas did not complete' -Detail @("$($_.Exception.Message)") `
        -Fix 'Run scripts\status.ps1 to see what is still running.' -ErrorRecord $_
    exit 1
}
