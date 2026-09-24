#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Diagnose a LocalCanvas installation before things go wrong.

.DESCRIPTION
    Read-only in the strict sense: doctor starts nothing, stops nothing, writes
    no file, creates no directory, and changes no firewall rule, adapter or
    route. It reads, probes and reports.

    It answers, in order, the questions docs/runtime.md lists for it:

      * is there a LocalCanvas Python environment, and is it a supported one;
      * is the configuration present, parseable and complete -- read through
        the SAME seam every other script uses (docs/runtime.md, "The
        configuration seam"), never through a second reader of its own;
      * do the ComfyUI root and launcher this configuration names exist;
      * are the ports free, or held by something, or held by us;
      * is the gateway reachable, and does it identify as a LocalCanvas gateway;
      * is there a LAN address, and does anything ANSWER at the endpoint a
        phone would use -- probed, with a bounded timeout, never inferred from
        the fact that the address can be spelled;
      * does multicast DNS work on this machine, and is the address that
        answered the one a phone would have to reach;
      * what does the firewall say about the gateway's port, and on which
        profile;
      * IS COMFYUI BOUND TO LOCALHOST -- the check the whole security posture
        rests on (docs/privacy-security.md);
      * and is strict LAN mode on.

    EXIT CODES (docs/runtime.md; the same three comfy/doctor.ps1 uses)
      0  every check it could make came back clean
      2  nothing failed, and a check did not come back clean -- or the
         configuration could not be loaded, so nothing below it was diagnosed
      3  something failed
      1  the diagnosis itself could not be completed
    A check that can only be made from an elevated shell, run unelevated, is
    reported as not measured and counts toward none of them.

.PARAMETER Config
    Path to the runtime configuration. Default: config/local/runtime.yaml.

.PARAMETER PythonExe
    LocalCanvas's own interpreter. Default: .venv\Scripts\python.exe.

.EXAMPLE
    .\scripts\doctor.ps1
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$PythonExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\StrictLan.ps1')

$EXIT_OK = 0
$EXIT_UNEXPECTED = 1
$EXIT_CONFIG = 2
# Nothing failed, and at least one check did not come back clean. The same 2
# comfy/doctor.ps1 exits with for UNKNOWN (T-0199).
$EXIT_UNCLEAN = 2
$EXIT_PROBLEMS = 3

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\runtime.yaml' }

# Every check this run printed, as it was printed. The summary AND the exit
# code are computed from this one list, once, in Get-DoctorVerdict -- which is
# comfy/doctor.ps1's method. T-0115 made the summary honest and left the exit
# code saying 0 over a check that could not be made (T-0199): two counts kept
# by two hands had already disagreed once, so there is now one.
$script:Checks = [System.Collections.Generic.List[object]]::new()

# Every probe doctor makes is bounded. An endpoint that accepts the connection
# and then says nothing must not hang the diagnosis -- that is how the machine
# in T-0115 actually behaved.
$script:ProbeTimeoutSeconds = 3

function Write-Check {
    <#
        One diagnosis, in the vocabulary of docs/runtime.md, recorded exactly
        as it is printed.

          ok     measured, and clean
          info   a fact, which is neither clean nor unclean
          warn   did not come back clean: it could not be made, or it was made
                 and found something worth knowing. Either way the run is not
                 a clean bill of health, and its exit code is not 0
          fail   will stop LocalCanvas working, or weakens the security posture
          admin  can only be made from an elevated shell, and this one is not
                 (T-0120, T-0015). Printed on a line of its own as not
                 measured, named again in the summary, and counted as neither
                 a warning nor a failure: running unelevated is the documented
                 way to run doctor, and says nothing about the machine
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail', 'info', 'admin')][string]$Status,
        [string]$Value = '',
        [string[]]$Detail = @()
    )
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status })
    $headline = if ($Value) { "$Name - $Value" } else { $Name }
    switch ($Status) {
        'ok' { Write-LcOk $headline }
        'warn' { Write-LcWarn $headline }
        'fail' { Write-LcFail $headline }
        'info' { Write-LcInfo $headline }
        'admin' {
            $notMeasured = "$Name - not measured, needs Administrator"
            if ($Value) { $notMeasured += ": $Value" }
            Write-LcInfo $notMeasured
        }
    }
    foreach ($line in $Detail) { Write-LcDetail $line }
}

function Get-DoctorVerdict {
    <#
        What the checks printed so far add up to, taken once: the counts the
        summary prints and the exit code, from the same list.

          3  at least one check failed
          2  none failed, and at least one did not come back clean
          0  otherwise

        The order is the point: a failure is reported even when something also
        warned, and a warning can never reach 0. A check that needs
        Administrator is in neither count (docs/runtime.md).
    #>
    $checks = @($script:Checks)
    $failures = @($checks | Where-Object { $_.Status -eq 'fail' }).Count
    $unclean = @($checks | Where-Object { $_.Status -eq 'warn' }).Count
    $notMeasured = @($checks | Where-Object { $_.Status -eq 'admin' } | ForEach-Object { $_.Name })
    $exitCode = if ($failures -gt 0) { $EXIT_PROBLEMS }
    elseif ($unclean -gt 0) { $EXIT_UNCLEAN }
    else { $EXIT_OK }
    return [pscustomobject]@{
        Failures    = $failures
        Unclean     = $unclean
        NotMeasured = $notMeasured
        ExitCode    = $exitCode
    }
}

function Write-DoctorSummary {
    <#
        The closing block, drawn from Get-DoctorVerdict, and the exit code that
        goes with it -- returned rather than exited, so that the one number the
        caller exits with is the one this block was printed from.

        A check that needs Administrator is named before the verdict, on its
        own line, in every shape: the verdict below it may be clean without it,
        but it is never silent about it.
    #>
    $verdict = Get-DoctorVerdict
    $notMeasured = @($verdict.NotMeasured)
    Write-Host ''
    if ($notMeasured.Count -gt 0) {
        Write-LcInfo "$($notMeasured.Count) check(s) need Administrator and were not measured: $($notMeasured -join ', ')."
        Write-LcDetail 'Run doctor.ps1 from an elevated prompt to measure them. They count neither as warnings nor as problems.'
    }
    if ($verdict.Failures -gt 0) {
        Write-LcFail "$($verdict.Failures) problem(s) found - see the [FAIL] lines above."
        if ($verdict.Unclean -gt 0) {
            Write-LcDetail "$($verdict.Unclean) further check(s) did not come back clean - see the [WARN] lines above."
        }
    } elseif ($verdict.Unclean -gt 0) {
        Write-LcWarn "No failures, but $($verdict.Unclean) check(s) did not come back clean - see the [WARN] lines above."
        Write-LcDetail 'A check that could not be made is not a check that passed.'
        Write-LcDetail 'This run is not a clean bill of health.'
    } else {
        Write-LcOk 'No problems found.'
    }
    Write-Host ''
    return $verdict.ExitCode
}

function Get-ActiveTcpPorts {
    <#
        Which TCP ports are being listened on, as ports.

        Deliberately NOT a lookup of which process holds a port: docs/runtime.md
        forbids addressing a process by the port it holds, and this answers
        only "is anything listening here", which is what a diagnosis needs.
        Ownership is answered from LocalCanvas's own records, below.
    #>
    try {
        $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        return @($properties.GetActiveTcpListeners() | ForEach-Object { [int]$_.Port })
    } catch {
        return $null
    }
}

function ConvertTo-Ipv4Number {
    <# One dotted-quad as a number, or $null when it is not one. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)
    $parsed = [System.Net.IPAddress]::Any
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $null }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $bytes = $parsed.GetAddressBytes()
    return [uint32](([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor
        ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3])
}

function Test-AddressInPrefix {
    <# Does one IPv4 address fall inside one 'a.b.c.d/len' prefix? #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prefix
    )
    if ($Prefix -notmatch '^\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})/([0-9]{1,2})\s*$') { return $false }
    $network = ConvertTo-Ipv4Number -Address $Matches[1]
    $length = [int]$Matches[2]
    $value = ConvertTo-Ipv4Number -Address $Address
    if ($null -eq $network -or $null -eq $value -or $length -gt 32) { return $false }
    if ($length -eq 0) { return $true }
    $mask = [uint32](0xFFFFFFFFL -band (0xFFFFFFFFL -shl (32 - $length)))
    return (($value -band $mask) -eq ($network -band $mask))
}

function Get-AddressRouteLines {
    <#
        What this machine's route table says about reaching one address, and
        which interface holds that address, as lines of evidence.

        Read-only, and it needs no elevation: Get-NetRoute and Get-NetIPAddress
        are readable by a standard user. Only the firewall table is restricted
        to Administrators, which is why that check -- and only that one --
        is reported as not measured when doctor is run unelevated.

        These lines report what was measured and stop there. Which interface a
        route points at is a fact; why it points there belongs to whatever
        installed the route, and doctor neither judges that nor names a remedy
        inside another product's settings.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)
    if ($null -eq (ConvertTo-Ipv4Number -Address $Address)) { return @() }
    if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
        return @("This machine's route table could not be read, so the route to $Address is not known.")
    }
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
    } catch {
        return @("This machine's route table could not be read: $("$($_.Exception.Message)".Trim())")
    }
    # The default route covers every address and so says nothing about this
    # one. Longest prefix first, then lowest metric: the order the machine
    # itself would choose between them in.
    $covering = @($routes |
        Where-Object {
            "$($_.DestinationPrefix)" -ne '0.0.0.0/0' -and
            (Test-AddressInPrefix -Address $Address -Prefix "$($_.DestinationPrefix)")
        } |
        Sort-Object -Property `
            @{ Expression = { [int]("$($_.DestinationPrefix)" -split '/')[1] }; Descending = $true }, `
            @{ Expression = { [int]$_.RouteMetric }; Descending = $false })
    $lines = @()
    if ($covering.Count -eq 0) {
        $lines += "No route on this machine covers $Address except the default route."
    } else {
        $lines += "Routes on this machine that cover ${Address}:"
        foreach ($route in $covering) {
            $lines += ("  {0} -> interface '{1}' (index {2}), route metric {3}" -f
                $route.DestinationPrefix, $route.InterfaceAlias, $route.ifIndex, $route.RouteMetric)
        }
    }
    $holder = @()
    try {
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $holder = @(Get-NetIPAddress -IPAddress $Address -AddressFamily IPv4 -ErrorAction Stop)
        }
    } catch {
        $holder = @()
    }
    if ($holder.Count -gt 0) {
        $lines += ("This machine holds {0} on interface '{1}'." -f $Address, $holder[0].InterfaceAlias)
    } else {
        $lines += "No interface on this machine holds $Address."
    }
    $lines += 'Reported as measured. Doctor reads the route table and changes nothing in it.'
    return $lines
}

function New-MulticastDnsQuery {
    <#
        One standard mDNS query for '_services._dns-sd._udp.local', PTR, with
        the QU (unicast response) bit set so a responder answers to the
        ephemeral port this is sent from rather than to 5353, which is normally
        already held.
    #>
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $bytes.AddRange([byte[]]@(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0))
    foreach ($label in @('_services', '_dns-sd', '_udp', 'local')) {
        $raw = [System.Text.Encoding]::ASCII.GetBytes($label)
        $bytes.Add([byte]$raw.Length)
        $bytes.AddRange($raw)
    }
    $bytes.Add(0)
    $bytes.AddRange([byte[]]@(0, 12))
    $bytes.AddRange([byte[]]@(0x80, 0x01))
    return $bytes.ToArray()
}

function Test-MulticastDns {
    <#
        Does multicast DNS actually work from this machine? Sends one query and
        waits, once, for any answer. The wait is a socket deadline, not a
        sleep: nothing here is timed by the clock in place of a probe.

        Silence is reported as silence. It means either that multicast is
        blocked here or that no responder happens to be on this network, and
        the two cannot be told apart from one query.
    #>
    param([int]$TimeoutMs = 1500)
    $client = $null
    try {
        $client = [System.Net.Sockets.UdpClient]::new(0, [System.Net.Sockets.AddressFamily]::InterNetwork)
        $client.Client.ReceiveTimeout = $TimeoutMs
        $query = New-MulticastDnsQuery
        $target = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('224.0.0.251'), 5353)
        [void]$client.Send($query, $query.Length, $target)
        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $answer = $client.Receive([ref]$remote)
        return [pscustomobject]@{ Ok = ($answer.Length -gt 0); From = $remote.Address.ToString(); Error = '' }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        # A deadline with no answer is silence, not a broken test: it is the
        # ordinary outcome on a network with no responder, and it is reported
        # as silence rather than dressed up as a failure of the check itself.
        if ($inner -is [System.Net.Sockets.SocketException] -and
            $inner.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
            return [pscustomobject]@{ Ok = $false; From = ''; Error = '' }
        }
        return [pscustomobject]@{ Ok = $false; From = ''; Error = $inner.Message }
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Test-PortInFilter {
    param([string[]]$LocalPort, [int]$Port)
    foreach ($entry in @($LocalPort)) {
        $value = "$entry".Trim()
        if (-not $value) { continue }
        if ($value -eq 'Any') { return $true }
        if ($value -eq "$Port") { return $true }
        if ($value -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $true }
    }
    return $false
}

function Get-GatewayPortRules {
    <#
        The inbound rules this machine's firewall holds for one port, and the
        profiles they apply to. Read-only, and it asks about a port -- never
        about a process.

        NeedsAdministrator is true in exactly one case: the port-filter table
        refused this shell on a permission, and this shell is not elevated.
        That is the documented, elevated-only check (T-0015), and it is not
        made any other way -- netsh's output is localized, and asking rule by
        rule works unelevated but costs about thirty seconds. Any other failure,
        and the same refusal in an elevated shell, is a check that could not
        be made, because elevating would not have made it.
    #>
    param([int]$Port)
    if (-not (Get-Command Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Readable = $false; NeedsAdministrator = $false; Rules = @()
            Reason   = 'the NetSecurity cmdlets are not available on this system.'
        }
    }
    try {
        # One query for the port filters, then one for the rules, correlated by
        # InstanceID. The alternative -- piping each rule to
        # Get-NetFirewallPortFilter -- is a CIM round trip per rule and takes
        # about half a minute on an ordinary Windows install.
        $filters = @(Get-NetFirewallPortFilter -ErrorAction Stop)
    } catch {
        $message = "$($_.Exception.Message)".Trim()
        # Decided by the error's category, never by its text: the message is
        # localized. Measured unelevated on Windows 11: a CimException whose
        # category is PermissionDenied (NativeErrorCode AccessDenied).
        $refusedOnPermission = ("$($_.CategoryInfo.Category)" -eq 'PermissionDenied')
        if ($refusedOnPermission -and -not (Test-LcElevated)) {
            return [pscustomobject]@{
                Readable = $false; NeedsAdministrator = $true; Rules = @()
                Reason   = ("this machine refused to list its firewall port filters: " +
                    "$message Windows restricts that table to Administrators; " +
                    'run doctor.ps1 from an elevated prompt to include this check.')
            }
        }
        return [pscustomobject]@{
            Readable = $false; NeedsAdministrator = $false; Rules = @()
            Reason   = "this machine's firewall port filters could not be listed: $message"
        }
    }
    $wanted = @{}
    foreach ($filter in $filters) {
        if ("$($filter.Protocol)" -notin @('TCP', 'Any')) { continue }
        if (-not (Test-PortInFilter -LocalPort @($filter.LocalPort) -Port $Port)) { continue }
        $wanted["$($filter.InstanceID)"] = $true
    }
    $matched = @()
    if ($wanted.Count -gt 0) {
        try {
            foreach ($rule in @(Get-NetFirewallRule -Direction Inbound -ErrorAction Stop)) {
                if (-not $wanted.ContainsKey("$($rule.InstanceID)")) { continue }
                if ("$($rule.Enabled)" -ne 'True') { continue }
                $matched += [pscustomobject]@{
                    DisplayName = [string]$rule.DisplayName
                    Action      = [string]$rule.Action
                    Profile     = [string]$rule.Profile
                }
            }
        } catch {
            return [pscustomobject]@{
                Readable = $false; NeedsAdministrator = $false; Rules = @()
                Reason   = "this machine's inbound firewall rules could not be read: $("$($_.Exception.Message)".Trim())"
            }
        }
    }
    return [pscustomobject]@{ Readable = $true; NeedsAdministrator = $false; Rules = $matched; Reason = '' }
}

function Write-FirewallCheck {
    <#
        The firewall posture for the gateway port, as one check. A function of
        its own so that the same decision is what every run makes -- and what
        the tests drive, over this machine's real firewall.
    #>
    param([Parameter(Mandatory)][int]$Port)
    $portRules = Get-GatewayPortRules -Port $Port
    $byHand = 'Until then, check by hand that the gateway port is allowed on Private networks only, never on Public.'
    if (-not $portRules.Readable -and $portRules.NeedsAdministrator) {
        Write-Check -Name 'Firewall' -Status 'admin' -Value "the rules for port $Port were not read" -Detail @(
            $portRules.Reason, $byHand)
    } elseif (-not $portRules.Readable) {
        Write-Check -Name 'Firewall' -Status 'warn' -Value "the rules for port $Port could not be read" -Detail @(
            $portRules.Reason, $byHand)
    } elseif (@($portRules.Rules).Count -eq 0) {
        Write-Check -Name 'Firewall' -Status 'warn' -Value "no enabled inbound rule allows port $Port" -Detail @(
            'A phone will not reach the gateway until the port is allowed inbound.',
            'Allow it on Private networks only, never on Public (docs/privacy-security.md).')
    } else {
        $public = @($portRules.Rules | Where-Object { $_.Action -eq 'Allow' -and ($_.Profile -match 'Public' -or $_.Profile -eq 'Any') })
        $detail = @($portRules.Rules | ForEach-Object { "$($_.Action)  [$($_.Profile)]  $($_.DisplayName)" })
        if ($public.Count -gt 0) {
            Write-Check -Name 'Firewall' -Status 'warn' -Value "port $Port is allowed on a Public profile" -Detail (
                $detail + @('Allow the gateway port on Private networks only, never on Public (docs/privacy-security.md).'))
        } else {
            Write-Check -Name 'Firewall' -Status 'ok' -Value "port $Port is allowed inbound on Private only" -Detail $detail
        }
    }
}

function Get-OwnershipLine {
    param([Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role)
    $owned = Resolve-LcOwnedProcess -Role $Role
    switch ($owned.State) {
        'none' { return 'not started by LocalCanvas' }
        'stale' { return "stale ownership record ($($owned.Reason)) - stop.ps1 will clean it up" }
        'unreadable' { return "unusable ownership record ($($owned.Reason)) - stop.ps1 will clean it up" }
        'mismatch' { return "ownership record does NOT match PID $($owned.Record.pid) ($($owned.Reason)) - not ours" }
        'unproven' { return "ownership of PID $($owned.Record.pid) could NOT be proved ($($owned.Reason)) - it is still running, and the record was kept" }
        'running' { return "started by LocalCanvas (PID $($owned.Record.pid))" }
    }
    return 'unknown'
}

function Get-UnansweredLine {
    <#
        What follows a probe that did not succeed (T-0239).

        "That is normal when LocalCanvas is not running" is true only when
        NOTHING answered. When something answered -- an HTTP status, or bytes
        that are not HTTP (Invoke-LcProbe's Answered) -- something else is
        running on that port, and calling it normal would send the reader to
        start LocalCanvas on a port another program holds.

        Which of two things answered is said too. An HTTP answer with an error
        status (StatusCode above 0) is the service on that port answering and
        saying it failed -- not "something else". Only an answer that is not
        HTTP at all (Answered, with StatusCode 0) is something else answering.
        Measured under pwsh and 5.1: HTTP 404 and 500 give Answered True with
        their status; a line that is not HTTP gives Answered True with 0. A
        hang-up without a byte is no answer at all, and keeps the sentence
        for nothing answering (T-0266).
    #>
    param(
        [Parameter(Mandatory)]$Probe,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Normal
    )
    $port = ([System.Uri]$Url).Port
    if ($Probe.Answered -and $Probe.StatusCode -gt 0) { return "The service on port $port answered with an error." }
    if ($Probe.Answered) { return "Something else is answering on port $port." }
    return $Normal
}

function Get-EndpointAnswerLine {
    <#
        One address of the endpoint check, said as what came back from it:
        nothing, an HTTP error status, or an answer that was not the gateway's.
    #>
    param([Parameter(Mandatory)]$Probe, [Parameter(Mandatory)][string]$Url)
    if ($Probe.Answered -and $Probe.StatusCode -gt 0) { return "The answer at $Url was HTTP $($Probe.StatusCode)." }
    if ($Probe.Answered) { return "The answer at $Url was not the gateway's: $($Probe.Error)" }
    return "Nothing answered at $Url."
}

function Get-EndpointHeadline {
    <#
        What the endpoint check's headline says when the gateway did not answer:
        nothing answered, only HTTP errors came back, or something that was not
        HTTP answered (T-0239, T-0251).
    #>
    param([Parameter(Mandatory)][object[]]$Probes)
    $answered = @($Probes | Where-Object { $_.Answered })
    if ($answered.Count -eq 0) { return 'nothing answered' }
    if (@($answered | Where-Object { $_.StatusCode -eq 0 }).Count -gt 0) { return 'no gateway answered' }
    return 'answered with an error'
}

try {
    Write-LcBanner
    Write-LcInfo 'LocalCanvas doctor (read-only; nothing on this machine is changed)'
    Write-LcDetail "Repository: $repoRoot"
    Write-Host ''

    # ------------------------------------------------------------------
    # The Python environment
    # ------------------------------------------------------------------
    $expectedPython = if ($PythonExe) { $PythonExe } else { Get-LcVenvPython }
    $python = $null
    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
    } catch [System.IO.FileNotFoundException] {
        Write-Check -Name 'Python environment' -Status 'fail' -Value 'missing' -Detail @(
            "Expected an interpreter at: $expectedPython",
            'Run scripts\setup.ps1 to create .venv and install the gateway into it.')
        Write-Host ''
        # A failure was just recorded, so this is 3 -- taken from the record.
        exit (Get-DoctorVerdict).ExitCode
    }

    # The probe rather than the bare version string (T-0299): this is the one
    # caller that has to tell a user WHY the interpreter did not answer, and
    # 'unknown' cannot say. Every other caller keeps Get-LcPythonVersion.
    $versionProbe = Get-LcPythonVersionProbe -PythonExe $python
    $version = $versionProbe.Version
    $floor = Get-LcSupportedPythonFloor
    if ($version -eq 'unknown') {
        # Nothing below this can be diagnosed through an interpreter that does
        # not answer, so the diagnosis stops here rather than reporting a
        # cascade of failures that all have this one cause.
        #
        # A probe that ran out of time is a different answer from one that came
        # back wrong, and a user who waited for the deadline is owed the
        # difference: "broken" describes an interpreter that answered and
        # answered badly.
        $value = if ($versionProbe.TimedOut) { 'did not answer in time' } else { 'broken' }
        $detail = @("$python exists but did not answer as a Python interpreter.")
        if ($versionProbe.Failure) { $detail += $versionProbe.Failure }
        $detail += 'Run scripts\setup.ps1 -Recreate to rebuild the environment.'
        Write-Check -Name 'Python environment' -Status 'fail' -Value $value -Detail $detail
        Write-Host ''
        # A failure was just recorded, so this is 3 -- taken from the record.
        exit (Get-DoctorVerdict).ExitCode
    } elseif ($floor -and -not (Test-LcPythonVersionSupported -Version $version -Range $floor)) {
        # THE WHOLE DECLARED RANGE, gated on and printed (T-0281). This check
        # used to compare against the floor alone and print ">= 3.10" while the
        # metadata declared ">=3.10,<3.14" -- so a .venv built on 3.14 was
        # reported "Python environment ok", and pip refused the gateway on the
        # very interpreter this script had just blessed. The range comes from
        # Get-LcSupportedPythonFloor, the one reader scripts\setup.ps1 prints
        # from, so the gate and the printed line cannot drift apart.
        Write-Check -Name 'Python environment' -Status 'fail' -Value "Python $version, outside the supported range $($floor.Specifier)" -Detail @(
            "Interpreter: $python",
            "Supported range declared in: $($floor.Source)",
            'Run scripts\setup.ps1 -Recreate to rebuild the environment on a supported version.')
    } else {
        $supported = if ($floor) { $floor.Specifier } else { 'not declared' }
        Write-Check -Name 'Python environment' -Status 'ok' -Value "Python $version" -Detail @(
            "Interpreter: $python", "Supported: $supported (from gateway/pyproject.toml)")
    }

    # ------------------------------------------------------------------
    # Configuration -- across the seam, never a second reader
    # ------------------------------------------------------------------
    $loaded = Read-LcConfig -ConfigPath $Config -PythonExe $python
    if (-not $loaded.Ok) {
        Write-Check -Name 'Configuration' -Status 'fail' -Value 'could not be loaded' -Detail (
            @("Read through the gateway's own loader, with: $python") + @($loaded.Detail) + @($loaded.Hint))
        Write-Host ''
        Write-LcDetail 'Everything below configuration could not be diagnosed until this is fixed.'
        Write-Host ''
        exit $EXIT_CONFIG
    }
    $cfg = $loaded.Document
    Write-Check -Name 'Configuration' -Status 'ok' -Value 'loaded and valid' -Detail @(
        "Source: $([string](Get-LcConfigValue -Document $cfg -Path 'source'))",
        "Read through the gateway's own loader; these scripts never parse YAML.")

    $manage = [bool](Get-LcConfigValue -Document $cfg -Path 'runtime.manage_comfy')
    Write-Check -Name 'Mode' -Status 'info' -Value $(
        if ($manage) { 'managed - LocalCanvas may start ComfyUI' }
        else { 'external - LocalCanvas never starts or stops ComfyUI' })

    $endpoints = Get-LcEndpoints -Config $cfg
    $gatewayPort = [int](Get-LcConfigValue -Document $cfg -Path 'gateway.port')
    $comfyPort = [int](Get-LcConfigValue -Document $cfg -Path 'comfy.port')

    # ------------------------------------------------------------------
    # ComfyUI: where it is, and -- the security-critical one -- what it binds
    # ------------------------------------------------------------------
    if ($manage) {
        $comfyRoot = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.root')
        if ($comfyRoot -and (Test-Path -LiteralPath $comfyRoot -PathType Container)) {
            Write-Check -Name 'ComfyUI root' -Status 'ok' -Value $comfyRoot
        } else {
            Write-Check -Name 'ComfyUI root' -Status 'fail' -Value 'does not exist' -Detail @(
                "comfy.root names: $comfyRoot",
                'Correct comfy.root in your runtime.yaml. LocalCanvas never searches the machine for a ComfyUI.')
        }
        $launcher = Get-LcConfigValue -Document $cfg -Path 'comfy.launcher' -Optional
        if ($null -eq $launcher) {
            Write-Check -Name 'ComfyUI launcher' -Status 'fail' -Value 'not configured' -Detail @(
                'runtime.manage_comfy is true, so comfy.launcher is required.')
        } else {
            foreach ($part in @(
                    @{ Label = 'executable'; Path = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.launcher.executable_path') },
                    @{ Label = 'script'; Path = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.launcher.script_path') })) {
                if ($part.Path -and (Test-Path -LiteralPath $part.Path -PathType Leaf)) {
                    Write-Check -Name "ComfyUI launcher $($part.Label)" -Status 'ok' -Value $part.Path
                } else {
                    Write-Check -Name "ComfyUI launcher $($part.Label)" -Status 'fail' -Value 'does not exist' -Detail @(
                        "Configured as: $(if ($part.Path) { $part.Path } else { '(empty)' })")
                }
            }
        }
    }

    # THE check the security posture rests on (docs/privacy-security.md).
    $comfyHost = [string](Get-LcConfigValue -Document $cfg -Path 'comfy.host')
    if ($endpoints.ComfyLocalhostOnly) {
        Write-Check -Name 'ComfyUI binding' -Status 'ok' -Value 'localhost only' -Detail @(
            "comfy.host is $comfyHost, so ComfyUI is reachable from this machine only.")
    } else {
        Write-Check -Name 'ComfyUI binding' -Status 'fail' -Value "NOT bound to localhost ($comfyHost)" -Detail @(
            'ComfyUI has no authentication. Anything on this network can reach it, drive it and read its files.',
            'The gateway is meant to be the only LAN-facing surface (docs/privacy-security.md).',
            "Set comfy.host to 127.0.0.1 and start ComfyUI without a --listen that exposes it.")
    }
    # Managed mode builds ComfyUI's own command line, so a --listen there
    # exposes it regardless of what comfy.host says LocalCanvas talks to.
    if ($manage) {
        $extra = @(Get-LcConfigValue -Document $cfg -Path 'comfy.extra_args')
        for ($index = 0; $index -lt $extra.Count; $index++) {
            $argument = [string]$extra[$index]
            if ($argument -ne '--listen' -and -not $argument.StartsWith('--listen=')) { continue }
            $value = if ($argument.StartsWith('--listen=')) { $argument.Substring(9) }
            elseif ($index + 1 -lt $extra.Count) { [string]$extra[$index + 1] }
            else { '0.0.0.0' }
            if ($value -notin @('127.0.0.1', 'localhost', '::1')) {
                Write-Check -Name 'ComfyUI launch arguments' -Status 'fail' -Value "--listen $value puts ComfyUI on the network" -Detail @(
                    'comfy.extra_args tells ComfyUI to listen beyond localhost. Remove it unless you deliberately want ComfyUI itself LAN-facing.')
            }
        }
    }

    # ------------------------------------------------------------------
    # Ports
    # ------------------------------------------------------------------
    $listening = Get-ActiveTcpPorts
    foreach ($entry in @(
            @{ Label = 'Gateway port'; Port = $gatewayPort; Role = 'gateway' },
            @{ Label = 'ComfyUI port'; Port = $comfyPort; Role = 'comfy' })) {
        if ($null -eq $listening) {
            Write-Check -Name $entry.Label -Status 'warn' -Value "$($entry.Port) - could not be checked" -Detail @(
                'This machine''s TCP listener table could not be read.')
            continue
        }
        $ownership = Get-OwnershipLine -Role $entry.Role
        if ($listening -notcontains $entry.Port) {
            Write-Check -Name $entry.Label -Status 'ok' -Value "$($entry.Port) - free" -Detail @($ownership)
        } elseif ($ownership -like 'started by LocalCanvas*') {
            Write-Check -Name $entry.Label -Status 'ok' -Value "$($entry.Port) - in use, held by us" -Detail @($ownership)
        } else {
            Write-Check -Name $entry.Label -Status 'warn' -Value "$($entry.Port) - in use, not by us" -Detail @(
                $ownership,
                'Something is listening on this port that LocalCanvas did not start. In external mode that is expected.')
        }
    }

    # ------------------------------------------------------------------
    # Reachability
    # ------------------------------------------------------------------
    $comfyProbe = Invoke-LcProbe -Url $endpoints.ComfyHealthUrl -TimeoutSeconds 3
    if ($comfyProbe.Ok) {
        Write-Check -Name 'ComfyUI' -Status 'ok' -Value "reachable at $($endpoints.ComfyBaseUrl)"
    } else {
        Write-Check -Name 'ComfyUI' -Status 'warn' -Value "not reachable at $($endpoints.ComfyBaseUrl)" -Detail @(
            $comfyProbe.Error,
            (Get-UnansweredLine -Probe $comfyProbe -Url $endpoints.ComfyHealthUrl `
                -Normal 'That is normal when LocalCanvas is not running.'))
    }

    $gatewayProbe = Invoke-LcProbe -Url $endpoints.GatewayHealthUrl -TimeoutSeconds 3
    if (-not $gatewayProbe.Ok) {
        Write-Check -Name 'Gateway' -Status 'warn' -Value "not reachable at $($endpoints.GatewayBaseUrl)" -Detail @(
            $gatewayProbe.Error,
            (Get-UnansweredLine -Probe $gatewayProbe -Url $endpoints.GatewayHealthUrl `
                -Normal 'That is normal when LocalCanvas is not running. Start it with scripts\start.ps1.'))
    } elseif ((Test-LcGatewayIdentity -Body $gatewayProbe.Body) -ne $true) {
        Write-Check -Name 'Gateway' -Status 'fail' -Value 'answering, but it is not a LocalCanvas gateway' -Detail @(
            "Something else is listening on $($endpoints.GatewayBaseUrl).")
    } else {
        Write-Check -Name 'Gateway' -Status 'ok' -Value "reachable at $($endpoints.GatewayBaseUrl)"
    }

    # ------------------------------------------------------------------
    # The address a phone would use
    # ------------------------------------------------------------------
    $lan = Get-LcLanAddress
    if ($lan) {
        Write-Check -Name 'LAN address' -Status 'ok' -Value $lan
    } else {
        Write-Check -Name 'LAN address' -Status 'fail' -Value 'none detected' -Detail @(
            'No usable IPv4 address was found, so no phone can reach this machine.',
            'Check that this PC is actually on the network.')
    }
    # The endpoint is PROBED, never inferred. An address that can be formed is
    # not an address anything answers at, and the difference between the two is
    # the whole of T-0115: a machine reported healthy while no device on the
    # network, including itself, could reach the gateway at this URL. One
    # request settles it, and it needs no elevation.
    $published = Get-LcPublishedEndpoint -Config $cfg -Endpoints $endpoints
    $publishedHost = ([System.Uri]$published.Url).Host
    $loopbackUrl = Get-LcUrl -HostName '127.0.0.1' -Port $gatewayPort
    $endpointProbe = Invoke-LcProbe -Url ($published.Url + $script:GatewayHealthPath) `
        -TimeoutSeconds $script:ProbeTimeoutSeconds
    $localOnly = if ($published.IsLan) { @() } else { @('Reachable from this machine only.') }
    $startIt = 'That is normal when LocalCanvas is not running. Start it with scripts\start.ps1.'
    $publishedHealthUrl = $published.Url + $script:GatewayHealthPath
    $loopbackHealthUrl = $loopbackUrl + $script:GatewayHealthPath
    if ($endpointProbe.Ok) {
        Write-Check -Name 'Endpoint' -Status $(if ($published.IsLan) { 'ok' } else { 'warn' }) `
            -Value $published.Url -Detail (
            @("The gateway answered at $($published.Url)$($script:GatewayHealthPath).") + $localOnly)
    } elseif ($published.Url -eq $loopbackUrl) {
        # There is one address here and it is loopback, so there is no second
        # probe to compare against: no gateway is answering at all -- and
        # whether anything else is decides the sentence (T-0239).
        $said = Get-EndpointHeadline -Probes @($endpointProbe)
        Write-Check -Name 'Endpoint' -Status 'warn' -Value "$($published.Url) - $said" -Detail (
            @((Get-EndpointAnswerLine -Probe $endpointProbe -Url $publishedHealthUrl),
                (Get-UnansweredLine -Probe $endpointProbe -Url $publishedHealthUrl -Normal $startIt)) + $localOnly)
    } else {
        # Two addresses, two answers. Loopback answering while the published
        # address does not is the signature, and it is itself the diagnosis.
        $loopbackProbe = Invoke-LcProbe -Url ($loopbackUrl + $script:GatewayHealthPath) `
            -TimeoutSeconds $script:ProbeTimeoutSeconds
        if ($loopbackProbe.Ok) {
            Write-Check -Name 'Endpoint' -Status 'fail' `
                -Value "$($published.Url) does not answer, though 127.0.0.1 does" -Detail (@(
                    "The gateway answered at $loopbackUrl$($script:GatewayHealthPath).",
                    "It did not answer at $($published.Url)$($script:GatewayHealthPath): $($endpointProbe.Error)",
                    'The gateway itself is fine. Something between this network and it is not,',
                    'and a phone given this endpoint will not reach it either.') + $localOnly +
                (Get-AddressRouteLines -Address $publishedHost))
        } elseif (-not $endpointProbe.Answered -and -not $loopbackProbe.Answered) {
            # Every loopback host but 127.0.0.1 itself lands here when nothing
            # answers, so the line saying it is local-only is added here too
            # (T-0119, review round 1).
            Write-Check -Name 'Endpoint' -Status 'warn' -Value "$($published.Url) - nothing answered" -Detail (@(
                    "Nothing answered at $publishedHealthUrl,",
                    "and nothing answered at $loopbackHealthUrl either.",
                    $startIt) + $localOnly +
                (Get-AddressRouteLines -Address $publishedHost))
        } else {
            # Something answered at one of the two addresses, and it was not
            # the gateway: something else holds the port (T-0239) -- or, when
            # every answer was an HTTP error status, the service there answered
            # with an error (T-0251).
            $said = Get-EndpointHeadline -Probes @($endpointProbe, $loopbackProbe)
            $holder = if ($said -eq 'answered with an error') {
                "The service on port $gatewayPort answered with an error."
            } else {
                "Something else is answering on port $gatewayPort."
            }
            Write-Check -Name 'Endpoint' -Status 'warn' -Value "$($published.Url) - $said" -Detail (@(
                    (Get-EndpointAnswerLine -Probe $endpointProbe -Url $publishedHealthUrl),
                    (Get-EndpointAnswerLine -Probe $loopbackProbe -Url $loopbackHealthUrl),
                    $holder) + $localOnly +
                (Get-AddressRouteLines -Address $publishedHost))
        }
    }

    # ------------------------------------------------------------------
    # Discovery
    # ------------------------------------------------------------------
    $mdns = Test-MulticastDns
    if ($mdns.Ok -and $lan -and $mdns.From -and $mdns.From -ne $lan) {
        # "Multicast works" was true and useless in T-0115: the answer came
        # from an address that is not the one a phone would have to reach.
        Write-Check -Name 'mDNS' -Status 'warn' -Value 'the answer came from an address that is not this machine''s LAN address' -Detail @(
            "A query sent to 224.0.0.251:5353 was answered from $($mdns.From).",
            "The LAN address reported above is $lan.",
            'A device that finds LocalCanvas by discovery is handed the address a responder advertises.',
            'One query cannot tell a responder on this machine from another device on this network,',
            'so this is reported as measured and no further conclusion is drawn from it.')
    } elseif ($mdns.Ok) {
        Write-Check -Name 'mDNS' -Status 'ok' -Value 'multicast DNS works on this machine' -Detail @(
            "A responder at $($mdns.From) answered a query sent to 224.0.0.251:5353.")
    } elseif ($mdns.Error) {
        Write-Check -Name 'mDNS' -Status 'warn' -Value 'could not be tested' -Detail @(
            $mdns.Error,
            'The app can still be pointed at the endpoint by hand or by QR.')
    } else {
        Write-Check -Name 'mDNS' -Status 'warn' -Value 'no responder answered' -Detail @(
            'Either multicast is blocked on this machine or network, or nothing on this network answers mDNS.',
            'One query cannot tell those apart. The app can still be pointed at the endpoint by hand or by QR.')
    }

    # ------------------------------------------------------------------
    # Firewall posture for the gateway port
    # ------------------------------------------------------------------
    $categories = @()
    try {
        if (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
            $categories = @(Get-NetConnectionProfile -ErrorAction Stop |
                ForEach-Object { "$($_.Name): $($_.NetworkCategory)" })
        }
    } catch {
        $categories = @()
    }
    if ($categories.Count -gt 0) {
        Write-Check -Name 'Network category' -Status 'info' -Value '' -Detail $categories
    }

    Write-FirewallCheck -Port $gatewayPort

    # ------------------------------------------------------------------
    # Strict LAN mode
    # ------------------------------------------------------------------
    $strictRules = Get-LcStrictLanRules
    if ($null -eq $strictRules) {
        Write-Check -Name 'Strict LAN mode' -Status 'warn' -Value 'unknown' -Detail @(
            "This machine's firewall could not be read, so the state of group '$(Get-LcStrictLanGroup)' is not known.")
    } else {
        $count = @($strictRules).Count
        if ($count -eq 0) {
            Write-Check -Name 'Strict LAN mode' -Status 'info' -Value 'OFF' -Detail @(
                "LocalCanvas owns no rule in group '$(Get-LcStrictLanGroup)'.",
                'It is optional. See scripts\strict-lan.ps1 status and docs/privacy-security.md.')
        } else {
            Write-Check -Name 'Strict LAN mode' -Status 'info' -Value "ON ($count LocalCanvas rules)" -Detail @(
                'While it is on, every application on this PC is cut off from the Internet, not just ComfyUI.',
                'Details: scripts\strict-lan.ps1 status   Undo: scripts\strict-lan.ps1 disable')
        }
    }

    # The summary accounts for every check, including the ones that could not
    # be made. A run with a warning in it is not a clean bill of health, and
    # saying it is was half of what T-0115 cost. The exit code is the one the
    # summary was drawn from, which is the other half (T-0199).
    exit (Write-DoctorSummary)
} catch {
    if (Test-LcSeamFailure -ErrorRecord $_) {
        $lines = Get-LcSeamFailureLines -ErrorRecord $_
        Write-LcFailure -What $lines[0] -Detail @($lines | Select-Object -Skip 1)
        exit $EXIT_CONFIG
    }
    Write-LcFailure -What 'The diagnosis could not be completed' -Detail @("$($_.Exception.Message)") `
        -Fix 'Check that config\local\runtime.yaml exists and is valid.'
    exit $EXIT_UNEXPECTED
}
