<#
.SYNOPSIS
    The bookkeeping behind comfy/doctor.ps1: what a check is, what a PASS is
    allowed to mean, and the summary that cannot say "fine" over a check that
    could not be made.

.DESCRIPTION
    Dot-sourced by comfy/doctor.ps1, which dot-sources nothing else: this file
    brings in Bootstrap.ps1 (for Get-LcComfyInstallation and the project's own
    terminal vocabulary), and Bootstrap.ps1 brings in scripts/lib/Common.ps1.

    THE ONE RULE THIS FILE ENFORCES STRUCTURALLY, because both doctors this
    project has written broke it by hand:

      Every PASS must correspond to something the intended consumer can
      actually reach, proved by a real request or a real action. No PASS from
      reading a config file, and no PASS from a directory existing.

    So Add-LcDoctorCheck REFUSES a PASS whose kind is 'configuration'. It is a
    throw, not a lint: a later edit that decides a present directory is good
    news is an exception with a message, not a green line.

    AND ITS COROLLARY, which is where T-0115 cost this project a user-present
    validation session: a check that could not be made is not a check that
    passed. Every check carries an Unmade flag; a check may be Unmade only as a
    warning, never as a pass; and the closing verdict counts those separately
    from the warnings that merely say an optional thing is absent. A run with
    one unmade check ends on a line that says so and an exit code that is not
    zero.

    WHY THE COUNTS ARE DERIVED RATHER THAN INCREMENTED. A reference bootstrap
    stack examined before this layer was written kept its own failure
    counter and only the existence checks touched it, so the summary and the
    body could and did disagree -- eighteen printed checks, every runtime one a
    warning, and a success line printed over a dead ComfyUI. Here the verdict
    is computed from the very records that were printed, so the only way to
    make the two disagree is to change what a record means, which is one place
    and is tested.

    WHAT THIS FILE NEVER DOES: write anything, anywhere. It has no write
    primitive of its own, and the two the layer has live behind
    Assert-LcMutationAllowed, which throws unless Initialize-LcBootstrap has
    opened a run -- and the doctor never opens one.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Bootstrap.ps1')

# --------------------------------------------------------------------------
# The record of one run
# --------------------------------------------------------------------------

$script:LcDoctorChecks = $null

function Reset-LcDoctorReport {
    <#
        Open a report. Nothing may be recorded before this, so a library that
        is merely dot-sourced holds no state from a previous run.
    #>
    $script:LcDoctorChecks = [System.Collections.Generic.List[object]]::new()
}

function Get-LcDoctorChecks {
    if ($null -eq $script:LcDoctorChecks) {
        throw 'REFUSED: no doctor report has been opened. Call Reset-LcDoctorReport first.'
    }
    return @($script:LcDoctorChecks)
}

function Add-LcDoctorCheck {
    <#
        Record one check and print it.

        Status is what was found. Kind is what the check is capable of
        proving -- 'reality' when a real request or a real action produced the
        answer, 'configuration' when the answer came from a file, a name or a
        path. Unmade says the check could not be made at all, which is a
        different thing from a thing being absent.

        THREE REFUSALS, and each of them is one of the ways a doctor lies:

          * a PASS of kind 'configuration'. A present directory, a parsed
            manifest and a formed URL are four kinds of not-yet-checked,
            and none of them may print as good news;
          * a PASS that could not be made. That is the sentence T-0115 was
            filed for, in code;
          * an Unmade check recorded as anything but a warning. A failure
            would overstate it -- nothing was proved either way -- and an
            info line would hide it from the summary entirely.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'fail', 'info')][string]$Status,
        [Parameter(Mandatory)][ValidateSet('reality', 'configuration')][string]$Kind,
        [string]$Value = '',
        [string[]]$Detail = @(),
        [switch]$Unmade
    )
    if ($Status -eq 'pass' -and $Kind -ne 'reality') {
        throw ("REFUSED: '$Name' would pass on a $Kind check. A PASS may only be " +
            'printed by a check that reached the thing itself. Print it as info, ' +
            'or make it a real request.')
    }
    if ($Unmade -and $Status -ne 'warn') {
        throw ("REFUSED: '$Name' could not be made and was recorded as '$Status'. " +
            'A check that could not be made is a warning: it proved nothing, so it ' +
            'may neither pass nor fail.')
    }

    $script:LcDoctorChecks.Add([pscustomobject]@{
            Name   = $Name
            Status = $Status
            Kind   = $Kind
            Value  = $Value
            Unmade = [bool]$Unmade
        })

    $shown = if ($Unmade) { "COULD NOT BE MADE: $Value" } else { $Value }
    $headline = if ($shown) { "$Name [$Kind] - $shown" } else { "$Name [$Kind]" }
    switch ($Status) {
        'pass' { Write-LcOk $headline }
        'warn' { Write-LcWarn $headline }
        'fail' { Write-LcFail $headline }
        'info' { Write-LcInfo $headline }
    }
    foreach ($line in $Detail) { Write-LcDetail $line }
}

function Get-LcDoctorPassCount {
    return @(Get-LcDoctorChecks | Where-Object { $_.Status -eq 'pass' }).Count
}

function Get-LcDoctorFailureCount {
    return @(Get-LcDoctorChecks | Where-Object { $_.Status -eq 'fail' }).Count
}

function Get-LcDoctorUnmadeCount {
    return @(Get-LcDoctorChecks | Where-Object { $_.Unmade }).Count
}

function Get-LcDoctorAbsentCount {
    <#
        Warnings that are NOT unmade checks: an optional thing that is absent.
        Counted apart because it is the one kind of warning a successful run
        may carry -- a healthy installation without an optional pack is
        healthy, and failing it is what makes a doctor useless in the case it
        exists for.
    #>
    return @(Get-LcDoctorChecks | Where-Object { $_.Status -eq 'warn' -and -not $_.Unmade }).Count
}

function Get-LcDoctorExitCode {
    <#
        0  every check was made, none failed, and at least one of them reached
           the thing itself -- optional absences allowed
        2  nothing failed, and either a check could not be made or nothing
           tested reality at all
        3  at least one check failed: LocalCanvas cannot work against this

        The order matters and is the whole point: an unmade check can never
        reach 0, and a failure is reported even when something was also unmade.

        THE LAST CONDITION IS NOT A FORMALITY. Without it a report holding
        nothing but configuration lines -- or holding nothing at all -- ends on
        the success word, which is the summary lying about a run that proved
        nothing. The shipped script cannot produce that state today; this
        library is what the card's rule is anchored in, so the rule is held
        here rather than in the caller that happens to be careful.
    #>
    if ((Get-LcDoctorFailureCount) -gt 0) { return 3 }
    if ((Get-LcDoctorUnmadeCount) -gt 0) { return 2 }
    if ((Get-LcDoctorPassCount) -eq 0) { return 2 }
    return 0
}

function Write-LcDoctorVerdict {
    <#
        The closing block, and it is written so that the LAST line alone
        carries all three numbers. A summary that mentions only what failed can
        be true and still leave a reader believing an unmade check was a passed
        one, which is exactly what "No problems found." did in T-0115.

        Details first, verdict last: the last line of a doctor's output is the
        one people read.
    #>
    param([Parameter(Mandatory)][string]$Subject)

    $failures = Get-LcDoctorFailureCount
    $unmade = Get-LcDoctorUnmadeCount
    $absent = Get-LcDoctorAbsentCount
    $passes = Get-LcDoctorPassCount
    $exitCode = Get-LcDoctorExitCode

    Write-Host ''
    if ($unmade -gt 0) {
        Write-LcDetail 'A check that could not be made is not a check that passed.'
        foreach ($check in (Get-LcDoctorChecks | Where-Object { $_.Unmade })) {
            Write-LcDetail "Not made: $($check.Name)"
        }
    }
    if ($absent -gt 0) {
        Write-LcDetail 'Optional things absent do not decide compatibility; see the [WARN] lines.'
    }

    if ($failures -gt 0) {
        Write-LcFail ("NOT COMPATIBLE: $Subject - $failures check(s) failed, " +
            "$unmade could not be made, $passes passed.")
        return $exitCode
    }
    if ($unmade -gt 0) {
        Write-LcWarn ("UNKNOWN: $Subject - $unmade check(s) could not be made, " +
            "so nothing here says this ComfyUI works. $passes passed, 0 failed.")
        return $exitCode
    }
    if ($passes -eq 0) {
        Write-LcWarn ("UNKNOWN: $Subject - nothing here tested reality and passed, " +
            'so nothing here says this ComfyUI works. 0 failed, 0 could not be made.')
        return $exitCode
    }
    Write-LcOk ("COMPATIBLE: $Subject - $passes check(s) tested reality and passed, " +
        "0 could not be made, $absent optional item(s) absent.")
    return $exitCode
}

# --------------------------------------------------------------------------
# Small answers the checks are built from, each testable on its own
# --------------------------------------------------------------------------

function Get-LcComfyBaseUrl {
    <#
        The origin, without a trailing separator, so that every path below can
        be appended without producing a double one.
    #>
    param([Parameter(Mandatory)][string]$Url)
    return $Url.Trim().TrimEnd('/')
}

function Resolve-LcDoctorGatewayEndpoint {
    <#
        WHICH gateway this doctor may say anything about, and where that
        address came from.

        T-0300, measured: the gateway check used the documented default port
        and nothing else, so a user who had moved gateway.port was told about
        whatever answered on the default -- once about a DIFFERENT LocalCanvas
        gateway, which the check then printed as a pass about theirs.

        The order below is the whole precedence model, and none of it is a
        second reader of the configuration:

          1. -GatewayUrl, given on the command line. It wins, and the report
             says the URL came from the flag;
          2. the effective configuration -- host and port both -- read through
             the gateway's OWN loader (Read-LcConfig) and turned into an
             address by the same Get-LcEndpoints scripts\doctor.ps1 probes
             with. Nothing is parsed here, and no default survives it;
          3. only where there is no configuration to read: the documented
             default, said to BE the default, with the reason the
             configuration was not read and what to pass instead.

        Returns { Url; Source; FromConfiguration; Detail } and never throws: a
        configuration that cannot be read is an ordinary answer for a layer
        that runs before there is a gateway environment.
    #>
    param(
        [AllowEmptyString()][string]$GatewayUrl = '',
        [AllowEmptyString()][string]$ConfigPath = '',
        [AllowEmptyString()][string]$PythonExe = '',
        [Parameter(Mandatory)][string]$DefaultUrl
    )

    if ($GatewayUrl) {
        return [pscustomobject]@{
            Url               = (Get-LcComfyBaseUrl -Url $GatewayUrl)
            Source            = 'the -GatewayUrl argument'
            FromConfiguration = $false
            Detail            = @('Given on the command line, so it wins over your configuration.')
        }
    }

    $configPath = if ($ConfigPath) { $ConfigPath } else { (Join-Path (Get-LcRepoRoot) 'config\local\runtime.yaml') }
    $python = if ($PythonExe) { $PythonExe } else { (Get-LcVenvPython) }
    $why = ''
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $why = "There is no configuration at $configPath."
    } elseif (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        $why = "There is no LocalCanvas interpreter at $python, so $configPath could not be read."
    } else {
        $loaded = Read-LcConfig -ConfigPath $configPath -PythonExe $python
        if ($loaded.Ok) {
            try {
                $endpoints = Get-LcEndpoints -Config $loaded.Document
                return [pscustomobject]@{
                    Url               = (Get-LcComfyBaseUrl -Url $endpoints.GatewayBaseUrl)
                    Source            = "your configuration at $configPath"
                    FromConfiguration = $true
                    Detail            = @(
                        'gateway.host and gateway.port, read through the gateway''s own loader: the address scripts\doctor.ps1 probes.')
                }
            } catch {
                $why = "$configPath was read and it names no gateway address this can probe."
            }
        } else {
            $why = "$configPath could not be read: $($loaded.What)"
        }
    }

    return [pscustomobject]@{
        Url               = (Get-LcComfyBaseUrl -Url $DefaultUrl)
        Source            = "this script's default"
        FromConfiguration = $false
        Detail            = @(
            $why,
            'Your configuration was NOT read, so this address is a guess and not a fact about your gateway.',
            'Pass -GatewayUrl to name the gateway, or -Config to name the configuration that does.')
    }
}

function ConvertFrom-LcDoctorJson {
    <#
        A response body as a document, or $null when it is not JSON at all.
        Never throws: "something answered and it was not JSON" is an ordinary
        answer here, and it is one the caller reports rather than crashes on.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    if (-not $Body) { return $null }
    try {
        return ($Body | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function ConvertFrom-LcDoctorJsonObject {
    <#
        A response body as a JSON OBJECT, or $null when it is anything else --
        not JSON, an array, a number, a string. The one place the doctor decides
        that, for every answer that has to be a map: /object_info (node type to
        definition) and /history (prompt id to entry, which the gateway refuses
        as anything but a mapping). T-0245: there were two decisions, and only
        one of them knew about arrays.

        THE FIRST CHARACTER IS ASKED, because ConvertFrom-Json enumerates a
        top-level array: measured, [{"a":1}] reads back as the object inside it,
        so an /object_info of [{"X": {...}}] was reported as a registry of one
        node type, X. -NoEnumerate would say it too, but Windows PowerShell 5.1
        does not have it, and a first non-whitespace '{' means the same thing in
        both shells. It must also parse: a body that merely starts with '{' --
        a truncated answer, a template page -- is not an object either.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    if (-not $Body.Trim().StartsWith('{')) { return $null }
    return (ConvertFrom-LcDoctorJson -Body $Body)
}

function Get-LcJsonPropertyCount {
    <#
        How many keys a JSON object came back with. -1 when the document is not
        an object at all, so that "not an object" and "an empty object" cannot
        be confused -- they are different failures and say different things.
    #>
    param($Document)
    if ($null -eq $Document) { return -1 }
    if ($Document -isnot [System.Management.Automation.PSCustomObject]) { return -1 }
    return @($Document.PSObject.Properties).Count
}

function Test-LcSameOrigin {
    <#
        Are these two URLs the same server?

        A URI COMPARISON AND NOT A STRING PREFIX, and that distinction is a
        measured false PASS rather than a preference. With a prefix test, a
        page served by http://127.0.0.1:6000 that names
        http://127.0.0.1:60001/stolen.js has its script fetched from an
        unrelated server on port 60001, and the doctor prints that the script
        is served by THIS ComfyUI. http://127.0.0.1:8188.evil.invalid/x.js
        passes the same way. A PASS that names the wrong server is the thing
        this script exists to prevent.

        The identical hazard for paths is already named in this repository, in
        scripts/tests/run_tests.py::path_is_inside: "a startswith on
        .../stubenv also accepts .../stubenv-other".

        Scheme, host and port, all three, compared as the uri parser sees them
        so that a default port and an explicit one agree. Anything that does
        not parse as an absolute URI is not the same origin as anything.
    #>
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Candidate
    )
    if (-not $Candidate) { return $false }
    try {
        $left = [uri]$Base
        $right = [uri]$Candidate
    } catch {
        return $false
    }
    if (-not $left.IsAbsoluteUri -or -not $right.IsAbsoluteUri) { return $false }
    if ($left.Scheme -ne $right.Scheme) { return $false }
    if ($left.Host -ne $right.Host) { return $false }
    return ($left.Port -eq $right.Port)
}

function Test-LcNodeClassRegistered {
    <#
        Is this node class a key of the /object_info document -- exactly, byte
        for byte?

        CASE-SENSITIVELY, and that is the point of the function existing.
        PowerShell compares strings case-insensitively by default, and the
        project's own property helper inherits that, so 'ksampler' would be
        reported as registered for a class ComfyUI itself would reject as a
        class_type: the graph a workflow carries names the class exactly.
        Reporting a near-miss as present is the same defect family as T-0170's
        commit id, which passed validation in upper case and went into the
        record as typed -- and it matters here before anything starts feeding
        these names mechanically.

        Iterating the keys rather than indexing them is what makes -ceq
        possible: the indexer is the case-insensitive lookup.
    #>
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )
    if ($null -eq $Document) { return $false }
    if ($Document -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    foreach ($property in $Document.PSObject.Properties) {
        if ($property.Name -ceq $Name) { return $true }
    }
    return $false
}

function Get-LcComfyEventsUrl {
    <#
        The address of ComfyUI's event socket, without its clientId query --
        the one the gateway listens on for a job's progress and completion.

        DERIVED FROM THE BASE BY SCHEME, exactly as the gateway derives it
        (gateway/localcanvas_gateway/comfy/client.py, events_url): https gives
        wss, anything else gives ws. docs/transport-boundary.md section 2 --
        never a hardcoded ws://, because a ComfyUI behind TLS would then be
        asked a question the gateway never asks.
    #>
    param([Parameter(Mandatory)][string]$BaseUrl)
    $base = Get-LcComfyBaseUrl -Url $BaseUrl
    if ($base -notmatch '^(.*?)://(.*)$') { return "ws://$base/ws" }
    $scheme = if ($Matches[1] -eq 'https') { 'wss' } else { 'ws' }
    return "${scheme}://$($Matches[2])/ws"
}

function Invoke-LcWebSocketProbe {
    <#
        One websocket handshake. It opens and it closes: nothing is sent on the
        socket, and nothing is asked of ComfyUI but the upgrade itself.

        Returns { Opened; Answered; Http; StatusCode; Error } and never throws,
        like Invoke-LcProbe, because "nothing is listening" is an ordinary
        answer.

          Opened    the upgrade happened.
          Answered  something came back -- an upgrade, a refusal of one, or a
                    line that is not HTTP at all (Test-LcProbeAnswered, T-0259).
                    The difference between "it told us no" and "it told us
                    nothing" is the difference between a FAIL and a check that
                    could not be made, so it is decided here, once.
          Http      what came back was HTTP: an upgrade or a refusal of one.
                    Answered without Http is something else answering.
          StatusCode  the HTTP status of the answer when the shell can say it,
                    0 otherwise.
          Error     for no answer and for an answer that is not HTTP, the
                    probe's own sentence (Get-LcProbeFailureCause, the one
                    Invoke-LcProbe uses); for a refusal, the websocket layer's
                    own words.

        MEASURED, loopback, pwsh 7.6.6 (.NET 10) and Windows PowerShell 5.1,
        and the reason this is longer than a ConnectAsync call:

          * pwsh reports the refusing status in HttpStatusCode, once
            CollectHttpResponseDetails is on. 5.1 has neither: a 404 arrives as
            a WebException carrying the response, and a 200 as a bare
            WebSocketException with nothing underneath it. A transport failure
            always has something underneath it in both shells -- the socket
            error, or the aborted request -- so a WebSocketException that is
            the innermost exception is the websocket layer judging an answer
            that did arrive;
          * the deadline is a cancelled token here, not HttpClient's timeout,
            so no TimeoutException is in the chain. It is put there, around the
            real exception, so that the one sentence for a deadline is the one
            Get-LcProbeFailureCause already says rather than a second copy;
          * 5.1 refuses CloseAsync when a message is already waiting -- which a
            real ComfyUI sends the moment a client connects. The upgrade has
            already happened by then, so a close that fails changes nothing
            and the socket is disposed either way.

        No proxy, as Invoke-LcProbe: the address being judged is the one asked.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [double]$TimeoutSeconds = 5
    )
    $opened = $false
    $answered = $false
    $http = $false
    $status = 0
    $said = ''
    $socket = $null
    $deadline = $null
    try {
        $socket = [System.Net.WebSockets.ClientWebSocket]::new()
        $socket.Options.Proxy = $null
        if (Test-LcHasProperty -Object $socket.Options -Name 'CollectHttpResponseDetails') {
            $socket.Options.CollectHttpResponseDetails = $true
        }
        $deadline = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds($TimeoutSeconds))
        try {
            $null = $socket.ConnectAsync([uri]$Url, $deadline.Token).GetAwaiter().GetResult()
            $opened = ($socket.State -eq 'Open')
            $answered = $true
            $http = $true
            $status = 101
        } catch {
            $innermost = $null
            if (Test-LcHasProperty -Object $socket -Name 'HttpStatusCode') {
                $status = [int]$socket.HttpStatusCode
            }
            for ($current = $_.Exception; $null -ne $current; $current = $current.InnerException) {
                if ($current -is [System.Net.WebException] -and $null -ne $current.Response) {
                    $status = [int]$current.Response.StatusCode
                }
                $innermost = $current
            }
            $http = ($status -gt 0 -or $innermost -is [System.Net.WebSockets.WebSocketException])
            # Not HTTP at all is an answer too, decided by the rule the plain
            # probe uses, so both doctors' checks say the same about a port
            # (T-0259). Its words are the probe's, as for no answer.
            $answered = ($http -or (Test-LcProbeAnswered -Exception $_.Exception))
            if ($http) {
                $said = $innermost.Message
            } else {
                $status = 0
                $cause = $_.Exception
                if ($deadline.IsCancellationRequested) {
                    $cause = [System.TimeoutException]::new('The deadline passed.', $cause)
                }
                $said = Get-LcProbeFailureCause -Exception $cause -TimeoutSeconds $TimeoutSeconds
            }
        }
        if ($opened) {
            $closing = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds($TimeoutSeconds))
            try {
                $null = $socket.CloseAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $closing.Token).GetAwaiter().GetResult()
            } catch {
                # The upgrade already happened, which is the whole question;
                # the socket is disposed below whether or not it closed cleanly.
                $null = $_
            } finally {
                $closing.Dispose()
            }
        }
    } catch {
        $said = "$($_.Exception.Message)"
    } finally {
        if ($null -ne $socket) { $socket.Dispose() }
        if ($null -ne $deadline) { $deadline.Dispose() }
    }
    return [pscustomobject]@{
        Opened     = $opened
        Answered   = $answered
        Http       = $http
        StatusCode = $status
        Error      = $said
    }
}

function Get-LcFrontendScriptUrl {
    <#
        The URL of the first script the served page names, or $null.

        This is what makes the bridge check more than a ping: a page is only
        the ComfyUI editor if the bundle it names is actually served, and that
        bundle is where window.app and graphToPrompt come from (T-0084). The
        request that fetches it is a request to the same ComfyUI.

        SAME ORIGIN ONLY, decided by Test-LcSameOrigin -- scheme, host and
        port, never a string prefix. A page that names a script on some other
        server proves nothing about this installation, so such a URL returns
        $null and the caller reports a check it could not make, rather than
        fetching somebody else's file and calling it a pass.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    if (-not $Body) { return $null }
    $base = Get-LcComfyBaseUrl -Url $BaseUrl
    $source = $null
    if ($Body -match '<script[^>]*\ssrc\s*=\s*"([^"]+)"') {
        $source = $Matches[1]
    } elseif ($Body -match "<script[^>]*\ssrc\s*=\s*'([^']+)'") {
        $source = $Matches[1]
    }
    if (-not $source) { return $null }
    $source = $source.Trim()
    if (-not $source) { return $null }
    if ($source.StartsWith('//')) { return $null }
    if ($source -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
        if (Test-LcSameOrigin -Base $base -Candidate $source) { return $source }
        return $null
    }
    if ($source.StartsWith('/')) { return ($base + $source) }
    if ($source.StartsWith('./')) { return ($base + $source.Substring(1)) }
    return ($base + '/' + $source)
}

# Where an installed Chrome or Edge is on Windows. The list the conversion
# bridge itself uses is in gateway/localcanvas_gateway/workflows/sync/bridge.py
# (BROWSER_CANDIDATES); this one is a PowerShell copy of it and the asymmetry
# is deliberate and safe in one direction only: a browser this list misses
# costs a WARN saying the bridge may not be able to run, and never a PASS.
# Nothing here searches the machine, reads the registry or installs anything.
$script:LcBrowserCandidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
)

function Get-LcBrowserCandidates {
    return @($script:LcBrowserCandidates)
}

function Get-LcExecutableVersion {
    <#
        The product version a program reports about itself, or $null.

        THIS IS WHY IT IS NOT Test-Path. A file called chrome.exe existing is a
        name on disk; a file that answers with its own version resource is a
        program. The distinction is the card's rule applied to the one check
        that is about this PC rather than about the installation, and a text
        file renamed chrome.exe returns $null here.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    } catch {
        return $null
    }
    if ($null -eq $info) { return $null }
    $version = $info.ProductVersion
    if (-not $version) { $version = $info.FileVersion }
    if (-not $version) { return $null }
    return $version.Trim()
}
