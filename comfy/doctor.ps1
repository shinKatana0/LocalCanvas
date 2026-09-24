#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Will THIS ComfyUI work with LocalCanvas? One question, answered by asking
    the ComfyUI itself.

.DESCRIPTION
    Not "is this ComfyUI complete", not "is your generation stack healthy".
    Only the compatibility question, and only in terms of things LocalCanvas
    actually reaches.

    THE RULE THIS SCRIPT IS BUILT AROUND, and it is the whole of it:

      Every PASS corresponds to something the intended consumer can actually
      reach, proved by a real request or a real action. There is no PASS from
      reading a config file, and no PASS from a directory existing.

    Every printed check says which kind it is -- [reality] when a real request
    or a real action produced the answer, [configuration] when it came from a
    file, a path or a name. The library refuses to print a PASS on a
    configuration check at all, so the ratio is not a matter of care
    (a report that mixes the two kinds reads a parsed file as a working
    installation).

    AND THE COROLLARY, which is what T-0115 cost:

      A check that could not be made is not a check that passed.

    A check that could not be made prints COULD NOT BE MADE, is listed again in
    the closing block, and takes the exit code off zero. The last line always
    carries all three numbers -- failed, not made, passed -- so it cannot be
    read as good news over a check that never ran.

    READ-ONLY, ALWAYS. It starts nothing, installs nothing, writes nothing into
    any ComfyUI, and runs no git in a tree it does not own. The installation it
    is asked about is usually one LocalCanvas did not install -- that is the
    common case -- and the script has no write primitive of its own: the two in
    this layer live behind Assert-LcMutationAllowed, which throws unless
    Initialize-LcBootstrap has opened a run, and this script never opens one.

    The one process it may start is LocalCanvas's own interpreter, and only to
    READ the configuration the gateway check's address comes from -- the same
    loader every other script reads it through (T-0300). With -GatewayUrl, or
    with no configuration file, it is not started at all. Importing the gateway
    that way leaves CPython's own bytecode cache under gateway/, exactly as
    every other script that reads the configuration does; that directory is
    gitignored, and nothing of yours is written.

    WHAT IT DOES WHEN NOTHING IS LISTENING. It says so, on every check that
    needed an answer, as a check that could not be made -- with the one
    sentence that acts on it ("start ComfyUI and run this again") -- and it
    ends on UNKNOWN with a non-zero exit code. It does not crash, and it does
    not print a clean bill of health over a ComfyUI that is not running.

    EXIT CODES
      0  COMPATIBLE     -- every check was made, none failed
      2  UNKNOWN        -- nothing failed, and at least one check could not be
                           made. Not a pass
      3  NOT COMPATIBLE -- at least one check failed
      1  the run itself could not be completed

.PARAMETER BaseUrl
    Where ComfyUI listens, as the gateway would address it. Omitted, it is
    ComfyUI's own default, http://127.0.0.1:8188 -- and the first line of the
    output says which of the two was used, because a verdict about an address
    nobody uses is worth nothing.

.PARAMETER ComfyRoot
    The installation on disk, when you want the configuration facts as well.
    Omitted, they are not asked for: LocalCanvas reaches ComfyUI over HTTP and
    over nothing else, so the compatibility answer never needs a path.

.PARAMETER RequireNodeClass
    Node classes the selected profile requires. Each is looked up in the live
    /object_info by key, and one that is not registered is a FAIL.

.PARAMETER OptionalNodeClass
    Node classes that are good to have. Absent is a WARN and the run can still
    succeed: a healthy installation must not fail because an optional pack is
    not installed.

.PARAMETER BrowserPath
    The Chrome or Edge the UI->API bridge would drive. Omitted, the usual
    install locations are tried.

.PARAMETER GatewayUrl
    Where a LocalCanvas gateway would answer, if one is running. It does not
    have to be. Omitted, the address is taken from your effective
    configuration -- gateway.host and gateway.port, through the gateway's own
    loader, which is the same address scripts\doctor.ps1 probes -- and only
    where there is no configuration to read does the documented default stand.
    Given, it wins, and the report says the URL came from this flag. Either
    way the check names the endpoint it actually probed (T-0300).

.PARAMETER Config
    The runtime configuration the gateway address is taken from.
    Default: config/local/runtime.yaml, the same file every other script reads.

.PARAMETER PythonExe
    The interpreter that reads that configuration -- LocalCanvas's own, never
    ComfyUI's. Default: .venv\Scripts\python.exe. It is used for nothing else
    here: this script asks ComfyUI over HTTP and over nothing else.

.PARAMETER TimeoutSeconds
    How long one request may take before it counts as no answer.

.EXAMPLE
    .\comfy\doctor.ps1
    .\comfy\doctor.ps1 -BaseUrl 'http://127.0.0.1:8000'
    .\comfy\doctor.ps1 -ComfyRoot 'C:\ComfyUI' -RequireNodeClass 'KSampler'
#>
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$ComfyRoot,
    [string[]]$RequireNodeClass = @(),
    [string[]]$OptionalNodeClass = @(),
    [string]$BrowserPath,
    [string]$GatewayUrl,
    [string]$Config,
    [string]$PythonExe,
    [double]$TimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Doctor.ps1')

# ComfyUI's own default, and the one config/examples/runtime.example.yaml
# shows. Nothing personal, nothing discovered: an address this script would
# rather be told than guess, which is why it prints which of the two it used.
$script:DefaultComfyUrl = 'http://127.0.0.1:8188'
# The gateway's documented default. It is the LAST resort and never an
# override: with a -GatewayUrl or a readable configuration this address is not
# probed at all, because a verdict about whatever answers on the default port
# is a verdict about somebody else's gateway (T-0300).
$script:DefaultGatewayUrl = 'http://127.0.0.1:7801'
$script:GatewayInfoPath = '/api/v1/info'

$EXIT_UNEXPECTED = 1

function Get-LcDoctorProbe {
    <#
        One real HTTP GET, through the project's own probe -- the same one the
        runtime scripts use, with a bounded deadline, so that a host which
        accepts and then says nothing is a no-answer rather than a hang.
    #>
    param([Parameter(Mandatory)][string]$Url)
    return (Invoke-LcProbe -Url $Url -TimeoutSeconds $TimeoutSeconds)
}

function Get-LcProbeFailureDetail {
    <#
        What to say about a request that got nothing back. The error is the
        transport's own words; the second line is the only action that helps.
    #>
    param([Parameter(Mandatory)]$Probe)
    $said = if ($Probe.Error) { $Probe.Error } else { 'no answer, and no error either' }
    return @(
        "The request said: $said",
        'Start ComfyUI and run this again, or pass -BaseUrl if it listens elsewhere.')
}

try {
    Write-LcBanner
    Reset-LcDoctorReport

    $requestedBase = if ($BaseUrl) { $BaseUrl } else { $script:DefaultComfyUrl }
    $base = Get-LcComfyBaseUrl -Url $requestedBase
    # The gateway's address, decided in one place and by the project's own
    # configuration resolution -- never a second precedence model here (T-0300).
    $gatewayEndpoint = Resolve-LcDoctorGatewayEndpoint `
        -GatewayUrl ([string]$GatewayUrl) -ConfigPath ([string]$Config) `
        -PythonExe ([string]$PythonExe) -DefaultUrl $script:DefaultGatewayUrl
    $gateway = $gatewayEndpoint.Url

    # ------------------------------------------------------------------
    # Which address is being judged. Configuration, and named as such: a
    # formed URL is not a reachable one, which is the sentence T-0115 was
    # filed for. Everything below tests this address by contacting it.
    # ------------------------------------------------------------------
    $urlSource = if ($BaseUrl) { 'the -BaseUrl argument' } else { "this script's default" }
    $endpointDetail = @("Source: $urlSource.")
    if (-not $BaseUrl) {
        $endpointDetail += 'ComfyUI''s own address is not taken from your LocalCanvas configuration: this layer answers about a ComfyUI that may have no LocalCanvas configuration at all. (The gateway check below does read it -- see its own Source line.)'
        $endpointDetail += 'If your ComfyUI listens elsewhere, pass -BaseUrl. The verdict at the end names the address it judged.'
    }
    Add-LcDoctorCheck -Name 'Endpoint' -Status 'info' -Kind 'configuration' -Value $base -Detail $endpointDetail

    # ------------------------------------------------------------------
    # Reality: does anything answer, and is it a ComfyUI
    # ------------------------------------------------------------------
    $statsUrl = "$base/system_stats"
    $statsProbe = Get-LcDoctorProbe -Url $statsUrl
    $statsDocument = $null

    if ($statsProbe.Ok) {
        Add-LcDoctorCheck -Name 'ComfyUI API' -Status 'pass' -Kind 'reality' `
            -Value "answered HTTP $($statsProbe.StatusCode) at $statsUrl"
    } elseif ($statsProbe.StatusCode -gt 0) {
        Add-LcDoctorCheck -Name 'ComfyUI API' -Status 'fail' -Kind 'reality' `
            -Value "answered HTTP $($statsProbe.StatusCode) at $statsUrl" -Detail @(
            'Something is listening there and it did not serve ComfyUI''s status endpoint.')
    } elseif ($statsProbe.Answered) {
        # Something answered, and not as HTTP: an answer that says no, so a
        # FAIL -- never "nothing answered" over a detail line quoting what came
        # back (T-0251). Invoke-LcProbe's Answered decides, not a status of 0,
        # which such an answer has too.
        Add-LcDoctorCheck -Name 'ComfyUI API' -Status 'fail' -Kind 'reality' `
            -Value "Something else is answering at $statsUrl" -Detail @(
            (Get-LcProbeFailureDetail -Probe $statsProbe)[0])
    } else {
        Add-LcDoctorCheck -Name 'ComfyUI API' -Status 'warn' -Kind 'reality' -Unmade `
            -Value "nothing answered at $statsUrl" -Detail (Get-LcProbeFailureDetail -Probe $statsProbe)
    }

    if (-not $statsProbe.Ok) {
        Add-LcDoctorCheck -Name 'ComfyUI identity' -Status 'warn' -Kind 'reality' -Unmade `
            -Value 'the status endpoint was not readable, so nothing identified itself' -Detail @(
            'Which ComfyUI this is, and which frontend it wants, are unknown for this run.')
    } else {
        # A JSON OBJECT, through the one helper /object_info and /history use:
        # an array holding a system report is not one (T-0256).
        $statsDocument = ConvertFrom-LcDoctorJsonObject -Body $statsProbe.Body
        $system = $null
        if ($null -ne $statsDocument -and (Test-LcHasProperty -Object $statsDocument -Name 'system')) {
            $system = $statsDocument.system
        }
        if ($null -eq $system -or -not (Test-LcHasProperty -Object $system -Name 'comfyui_version')) {
            Add-LcDoctorCheck -Name 'ComfyUI identity' -Status 'fail' -Kind 'reality' `
                -Value "something answered at $statsUrl and it is not a ComfyUI" -Detail @(
                'A ComfyUI answers /system_stats with a system report carrying comfyui_version.',
                'docs/connection.md: an arbitrary HTTP endpoint is never treated as a compatible service.')
        } else {
            Add-LcDoctorCheck -Name 'ComfyUI identity' -Status 'pass' -Kind 'reality' `
                -Value "ComfyUI $($system.comfyui_version) said so itself at $statsUrl"

            # Facts, printed and not judged. The interpreter that matters is
            # the one ComfyUI is already running under, and this is it saying
            # so -- no interpreter is selected, started or guessed at here.
            $python = 'not reported by this build'
            if (Test-LcHasProperty -Object $system -Name 'python_version') {
                $python = [string]$system.python_version
            }
            Add-LcDoctorCheck -Name 'Python running ComfyUI' -Status 'info' -Kind 'reality' `
                -Value $python -Detail @(
                'Reported by the running ComfyUI. LocalCanvas neither chooses nor starts an interpreter for it.')

            $frontend = 'not reported by this build'
            if (Test-LcHasProperty -Object $system -Name 'required_frontend_version') {
                $frontend = [string]$system.required_frontend_version
            }
            Add-LcDoctorCheck -Name 'Frontend this ComfyUI asks for' -Status 'info' -Kind 'reality' `
                -Value $frontend -Detail @(
                'Reported, not judged: LocalCanvas drives whichever frontend the installation ships.')
        }
    }

    # ------------------------------------------------------------------
    # Reality: the node definitions, by key membership
    # ------------------------------------------------------------------
    $objectUrl = "$base/object_info"
    $objectProbe = Get-LcDoctorProbe -Url $objectUrl
    $objectDocument = $null
    $objectCount = -1

    if ($objectProbe.Ok) {
        $objectDocument = ConvertFrom-LcDoctorJsonObject -Body $objectProbe.Body
        $objectCount = Get-LcJsonPropertyCount -Document $objectDocument
    }

    if (-not $objectProbe.Ok -and -not $objectProbe.Answered) {
        Add-LcDoctorCheck -Name 'Node definitions' -Status 'warn' -Kind 'reality' -Unmade `
            -Value "nothing answered at $objectUrl" -Detail (Get-LcProbeFailureDetail -Probe $objectProbe)
        $objectDocument = $null
    } elseif (-not $objectProbe.Ok -and $objectProbe.StatusCode -eq 0) {
        # Answered, and not as HTTP (T-0251).
        Add-LcDoctorCheck -Name 'Node definitions' -Status 'fail' -Kind 'reality' `
            -Value "Something else is answering at $objectUrl" -Detail @(
            (Get-LcProbeFailureDetail -Probe $objectProbe)[0])
        $objectDocument = $null
    } elseif (-not $objectProbe.Ok) {
        Add-LcDoctorCheck -Name 'Node definitions' -Status 'fail' -Kind 'reality' `
            -Value "$objectUrl answered HTTP $($objectProbe.StatusCode)" -Detail @(
            'LocalCanvas asks /object_info what this installation can run. Without it nothing can be checked against a workflow.')
        $objectDocument = $null
    } elseif ($objectCount -lt 0) {
        Add-LcDoctorCheck -Name 'Node definitions' -Status 'fail' -Kind 'reality' `
            -Value "$objectUrl answered and it did not send a JSON object" -Detail @(
            'The answer is meant to be a map of node type to definition.')
        $objectDocument = $null
    } elseif ($objectCount -eq 0) {
        Add-LcDoctorCheck -Name 'Node definitions' -Status 'fail' -Kind 'reality' `
            -Value "$objectUrl listed no node types at all" -Detail @(
            'Nothing can run, and the UI->API bridge waits for registered node types, so it would never become ready (T-0084).')
        $objectDocument = $null
    } else {
        Add-LcDoctorCheck -Name 'Node definitions' -Status 'pass' -Kind 'reality' `
            -Value "$objectUrl listed the node types this installation registered" -Detail @(
            "Fact, not a verdict: $objectCount node type(s) registered.")
    }

    # ------------------------------------------------------------------
    # Reality: the classes a profile needs, asked of the registry and not of
    # the disk. The reference stack did the opposite twice: a
    # present directory under custom_nodes reported as the node being
    # installed, while a node that fails to import leaves its directory
    # exactly as it was.
    # ------------------------------------------------------------------
    $customNodesNote = @()
    if ($ComfyRoot) {
        $customNodesNote = @('A directory under custom_nodes is not an answer: a node that fails to import leaves it exactly as it was.')
    }

    foreach ($class in @($RequireNodeClass)) {
        if ($null -eq $objectDocument) {
            Add-LcDoctorCheck -Name "Node class '$class' (required)" -Status 'warn' -Kind 'reality' -Unmade `
                -Value 'the node registry was not readable, so nothing was asked about it' -Detail @(
                'Required by the selected profile. Whether it is registered is unknown for this run.')
        } elseif (Test-LcNodeClassRegistered -Document $objectDocument -Name $class) {
            Add-LcDoctorCheck -Name "Node class '$class' (required)" -Status 'pass' -Kind 'reality' `
                -Value "registered, and $objectUrl says so"
        } else {
            Add-LcDoctorCheck -Name "Node class '$class' (required)" -Status 'fail' -Kind 'reality' `
                -Value "not registered in $objectUrl" -Detail (@(
                    'The selected profile requires it, so LocalCanvas cannot run that profile against this installation.') + $customNodesNote)
        }
    }

    foreach ($class in @($OptionalNodeClass)) {
        if ($null -eq $objectDocument) {
            Add-LcDoctorCheck -Name "Node class '$class' (optional)" -Status 'warn' -Kind 'reality' -Unmade `
                -Value 'the node registry was not readable, so nothing was asked about it'
        } elseif (Test-LcNodeClassRegistered -Document $objectDocument -Name $class) {
            Add-LcDoctorCheck -Name "Node class '$class' (optional)" -Status 'pass' -Kind 'reality' `
                -Value "registered, and $objectUrl says so"
        } else {
            Add-LcDoctorCheck -Name "Node class '$class' (optional)" -Status 'warn' -Kind 'reality' `
                -Value "not registered in $objectUrl" -Detail (@(
                    'Optional: it is absent, and this run can still succeed. Nothing that needs it will work.') + $customNodesNote)
        }
    }

    # ------------------------------------------------------------------
    # Reality: what running a job uses (T-0205)
    #
    # The gateway runs a job over three things (gateway/localcanvas_gateway/
    # comfy/client.py): POST /prompt submits it, ComfyUI's event websocket
    # reports its progress and completion, and GET /history/<id> collects the
    # outcome. The checks above reach none of them, so a reverse proxy that
    # forwards plain requests and not websocket upgrades -- the commonest way
    # a proxied ComfyUI is broken -- used to earn COMPATIBLE while no job could
    # ever finish.
    #
    # Two of the three are asked, and both are requests that run nothing:
    #
    #   * the websocket is opened with a fresh clientId and closed again.
    #     Nothing is sent on it;
    #   * /history is asked about a prompt id nobody submitted, which ComfyUI
    #     answers without queueing anything.
    #
    # POST /prompt is NOT asked, and never will be: it asks ComfyUI to run
    # something, and this doctor asks ComfyUI to run nothing.
    #
    # Severity follows the rest of this script. An answer that says no is a
    # FAIL; no answer at all is a check that could not be made.
    # ------------------------------------------------------------------
    $eventsUrl = Get-LcComfyEventsUrl -BaseUrl $base
    $eventsProbe = Invoke-LcWebSocketProbe `
        -Url ("$eventsUrl" + '?clientId=' + [guid]::NewGuid().ToString('N')) -TimeoutSeconds $TimeoutSeconds

    if ($eventsProbe.Opened) {
        Add-LcDoctorCheck -Name 'Jobs: the event websocket' -Status 'pass' -Kind 'reality' `
            -Value "$eventsUrl upgraded to a websocket" -Detail @(
            'Opened with a fresh clientId and closed again; nothing was sent on it.',
            'This is where the gateway follows a job''s progress and learns that it finished.')
    } elseif ($eventsProbe.Answered -and -not $eventsProbe.Http) {
        # Answered, and not as HTTP: the plain-URL checks' FAIL, in the same
        # words (T-0251, T-0259).
        Add-LcDoctorCheck -Name 'Jobs: the event websocket' -Status 'fail' -Kind 'reality' `
            -Value "Something else is answering at $eventsUrl" -Detail @(
            (Get-LcProbeFailureDetail -Probe $eventsProbe)[0])
    } elseif ($eventsProbe.Answered) {
        $refusal = if ($eventsProbe.StatusCode -gt 0 -and $eventsProbe.StatusCode -ne 101) {
            "$eventsUrl answered HTTP $($eventsProbe.StatusCode) and did not upgrade to a websocket"
        } else {
            "$eventsUrl answered and did not upgrade to a websocket"
        }
        Add-LcDoctorCheck -Name 'Jobs: the event websocket' -Status 'fail' -Kind 'reality' `
            -Value $refusal -Detail @(
            "The handshake said: $($eventsProbe.Error)",
            'The gateway follows every job''s progress and completion on this websocket, so no job could report progress or finish.',
            'If a reverse proxy is in front of ComfyUI, check that it forwards websocket upgrades (the Upgrade and Connection headers) for /ws.')
    } else {
        Add-LcDoctorCheck -Name 'Jobs: the event websocket' -Status 'warn' -Kind 'reality' -Unmade `
            -Value "nothing answered at $eventsUrl" -Detail (Get-LcProbeFailureDetail -Probe $eventsProbe)
    }

    # A prompt id no ComfyUI generates -- it makes uuid4s -- and that this
    # doctor, which never submits one, cannot have submitted.
    $historyUrl = "$base/history/localcanvas-doctor-" + [guid]::NewGuid().ToString('N')
    $historyProbe = Get-LcDoctorProbe -Url $historyUrl
    $historyAsked = "Asked about a prompt id nobody submitted: $historyUrl"

    if (-not $historyProbe.Ok -and -not $historyProbe.Answered) {
        Add-LcDoctorCheck -Name 'Jobs: the history' -Status 'warn' -Kind 'reality' -Unmade `
            -Value "nothing answered at $base/history" -Detail (@($historyAsked) + (Get-LcProbeFailureDetail -Probe $historyProbe))
    } elseif (-not $historyProbe.Ok -and $historyProbe.StatusCode -eq 0) {
        # Answered, and not as HTTP (T-0251).
        Add-LcDoctorCheck -Name 'Jobs: the history' -Status 'fail' -Kind 'reality' `
            -Value "Something else is answering at $base/history" -Detail @(
            $historyAsked, (Get-LcProbeFailureDetail -Probe $historyProbe)[0])
    } elseif (-not $historyProbe.Ok) {
        Add-LcDoctorCheck -Name 'Jobs: the history' -Status 'fail' -Kind 'reality' `
            -Value "$base/history answered HTTP $($historyProbe.StatusCode)" -Detail @(
            $historyAsked,
            'The gateway collects every job''s outcome here, so no job could deliver a result.')
    } elseif ((Get-LcJsonPropertyCount -Document (ConvertFrom-LcDoctorJsonObject -Body $historyProbe.Body)) -lt 0) {
        # A JSON OBJECT, not merely JSON: the gateway reads the answer as a map
        # of prompt id to entry and refuses anything else, so an array or a
        # bare string would fail every job at its very end. Decided by the one
        # helper /object_info uses too (T-0245).
        Add-LcDoctorCheck -Name 'Jobs: the history' -Status 'fail' -Kind 'reality' `
            -Value "$base/history answered, and what came back is not a JSON object" -Detail @(
            $historyAsked,
            'The gateway reads a job''s outcome from this answer as JSON, so no job could deliver a result.',
            'A login page or a reverse proxy answering in ComfyUI''s place looks like this.')
    } else {
        Add-LcDoctorCheck -Name 'Jobs: the history' -Status 'pass' -Kind 'reality' `
            -Value "$base/history answered with a JSON object, and nothing was queued to get it" -Detail @(
            $historyAsked,
            'This is where the gateway collects a job''s outcome.')
    }

    # ------------------------------------------------------------------
    # Reality: the UI->API bridge (T-0084)
    #
    # This is the thing LocalCanvas actually needs from a ComfyUI, and the
    # hardest to fake. The bridge points a real browser at this exact URL and
    # calls ComfyUI's OWN frontend -- app.loadGraphData, then
    # app.graphToPrompt -- because converting an editor workflow needs the node
    # definitions of the build that saved it, and guessing is forbidden. So the
    # two things asked here are the two the browser would need to find:
    #
    #   * the editor page is served at this address, and is a page rather than
    #     an API answer. An API-only endpoint, a proxy, or a 404 passes every
    #     JSON check above and still cannot be converted against;
    #   * the script that page names is served BY THIS SAME ComfyUI and has a
    #     body. That bundle is where window.app comes from.
    #
    # Neither can pass against a ComfyUI that is not running: the PASS is
    # printed from bytes that came back over the wire, and there are none.
    # ------------------------------------------------------------------
    $pageUrl = "$base/"
    $pageProbe = Get-LcDoctorProbe -Url $pageUrl
    $pageBody = ''

    if (-not $pageProbe.Ok -and -not $pageProbe.Answered) {
        Add-LcDoctorCheck -Name 'Bridge: the editor page' -Status 'warn' -Kind 'reality' -Unmade `
            -Value "nothing answered at $pageUrl" -Detail (Get-LcProbeFailureDetail -Probe $pageProbe)
    } elseif (-not $pageProbe.Ok -and $pageProbe.StatusCode -eq 0) {
        # Answered, and not as HTTP (T-0251).
        Add-LcDoctorCheck -Name 'Bridge: the editor page' -Status 'fail' -Kind 'reality' `
            -Value "Something else is answering at $pageUrl" -Detail @(
            (Get-LcProbeFailureDetail -Probe $pageProbe)[0])
    } elseif (-not $pageProbe.Ok) {
        Add-LcDoctorCheck -Name 'Bridge: the editor page' -Status 'fail' -Kind 'reality' `
            -Value "$pageUrl answered HTTP $($pageProbe.StatusCode)" -Detail @(
            'The conversion browser opens exactly this URL, and would get that answer instead of ComfyUI''s editor.')
    } elseif ($pageProbe.Body -notmatch '(?is)<html|<!doctype\s+html') {
        Add-LcDoctorCheck -Name 'Bridge: the editor page' -Status 'fail' -Kind 'reality' `
            -Value "$pageUrl answered, and what came back is not an HTML page" -Detail @(
            'The conversion browser opens exactly this URL and needs ComfyUI''s own editor there.',
            'An API surface with no frontend in front of it answers every check above and still cannot convert a workflow.')
    } else {
        $pageBody = $pageProbe.Body
        Add-LcDoctorCheck -Name 'Bridge: the editor page' -Status 'pass' -Kind 'reality' `
            -Value "$pageUrl served an HTML page, which is where the browser is pointed"
    }

    if (-not $pageBody) {
        Add-LcDoctorCheck -Name 'Bridge: the frontend bundle' -Status 'warn' -Kind 'reality' -Unmade `
            -Value 'there was no page to read a script from' -Detail @(
            'Whether this installation serves the frontend that defines app.graphToPrompt is unknown for this run.')
    } else {
        $scriptUrl = Get-LcFrontendScriptUrl -BaseUrl $base -Body $pageBody
        if (-not $scriptUrl) {
            Add-LcDoctorCheck -Name 'Bridge: the frontend bundle' -Status 'warn' -Kind 'reality' -Unmade `
                -Value 'the page named no script served by this ComfyUI' -Detail @(
                'A script on another host would say nothing about this installation, so it is not fetched.')
        } else {
            $scriptProbe = Get-LcDoctorProbe -Url $scriptUrl
            # WHAT THE BUNDLE IS ASKED FOR, and why not finding it decides
            # nothing. The two calls the bridge makes are app.loadGraphData and
            # app.graphToPrompt; naming them is read out of the bytes that came
            # back, never asserted about a script nobody looked at -- which is
            # the defect this whole file is built against.
            #
            # BUT A SCRIPT THAT DOES NOT NAME THEM IS NOT EVIDENCE OF ANYTHING,
            # and here is the measurement that says so rather than an opinion
            # about frontends (T-0173, B5). Against a current, healthy ComfyUI
            # -- 0.33.0, frontend 1.49.6 -- the script the page names came back
            # 3161 characters and named NEITHER call, while every one of the
            # eight checks that reach what LocalCanvas actually uses passed:
            # /system_stats, /object_info, the /ws upgrade, /history and the
            # editor page itself. 3161 characters is an entry point and not a
            # whole frontend, so where the two calls are in that installation
            # is something NOBODY HERE HAS READ -- and that is exactly the
            # point: the grep can prove the positive and can prove nothing at
            # all from the negative.
            #
            # Holding the verdict down on that negative made COMPATIBLE
            # unreachable for every current installation -- the doctor's best
            # possible answer was UNKNOWN, which is the same class of useless
            # as a summary that says fine over a dead ComfyUI.
            #
            # The other option was considered and refused: reading further --
            # following what the entry point imports until the calls turn up --
            # is a rule this repository cannot measure, because the only
            # current frontend available to check it against is a configured
            # running ComfyUI, which this card may not contact. An unproved
            # rule that can hold the verdict down is the defect again, one
            # layer deeper.
            #
            # It is therefore reported and not judged: an informational check,
            # which counts as neither a pass nor a check that could not be
            # made. What proves the conversion is the editor page above and the
            # bridge's own run, and neither of them is this grep.
            #
            # A script the page names and this ComfyUI does NOT serve stays a
            # FAIL below -- that is the server answering "no" about its own
            # editor, not a question this doctor left open.
            $bridgeCalls = @('loadGraphData', 'graphToPrompt')
            $named = @($bridgeCalls | Where-Object { $scriptProbe.Body -cmatch $_ })
            if ($scriptProbe.Ok -and $scriptProbe.Body -and $named.Count -eq $bridgeCalls.Count) {
                Add-LcDoctorCheck -Name 'Bridge: the frontend bundle' -Status 'pass' -Kind 'reality' `
                    -Value "the page's script is served by this ComfyUI: $scriptUrl" -Detail @(
                    "Fact, not a verdict: $($scriptProbe.Body.Length) character(s) came back.",
                    'They name loadGraphData and graphToPrompt, which are the two calls the bridge makes (T-0084).')
            } elseif ($scriptProbe.Ok -and $scriptProbe.Body) {
                Add-LcDoctorCheck -Name 'Bridge: the frontend bundle' -Status 'info' -Kind 'reality' `
                    -Value "$scriptUrl was served and names $($named.Count) of the $($bridgeCalls.Count) calls the bridge makes" -Detail @(
                    "Fact, not a verdict: $($scriptProbe.Body.Length) character(s) came back, naming $($named.Count) of $($bridgeCalls.Count).",
                    'Reported and not judged. What was measured: against a healthy ComfyUI 0.33.0 / frontend 1.49.6, the script its page named came back 3161 characters and named neither call, while every check that reaches what LocalCanvas uses passed (T-0173).',
                    'So a script that does not name them establishes nothing -- 3161 characters is an entry point, not a whole frontend -- and this check does not hold the verdict down: what proves the conversion is the editor page above and the bridge''s own run.')
            } elseif ($scriptProbe.StatusCode -gt 0) {
                Add-LcDoctorCheck -Name 'Bridge: the frontend bundle' -Status 'fail' -Kind 'reality' `
                    -Value "$scriptUrl answered HTTP $($scriptProbe.StatusCode)" -Detail @(
                    'The page names a script this ComfyUI does not serve, so the editor cannot finish loading.')
            } else {
                # Nothing came back at all -- a deadline, a dropped connection,
                # a ComfyUI that died between the page and the bundle. That is
                # "it told us nothing", not the 404 above's "it told us no", so
                # it is a check that could not be made and never a failure: a
                # slow fetch is not an incompatibility (T-0206).
                Add-LcDoctorCheck -Name 'Bridge: the frontend bundle' -Status 'warn' -Kind 'reality' -Unmade `
                    -Value "$scriptUrl sent nothing back" -Detail (Get-LcProbeFailureDetail -Probe $scriptProbe)
            }
        }
    }

    # The browser is a fact about THIS PC and not about the installation, so
    # its absence is a warning and never a failure -- the ComfyUI above is
    # exactly as compatible either way. It is also not proved by a file
    # existing: a program is something that answers with its own version.
    #
    # Three outcomes and one code path, which is why a run with -BrowserPath
    # exercises the same decision a run without it does:
    #
    #   a program answered with its own version  -> PASS, and it is a reality
    #     check because a version resource is read out of the file, not a name
    #     read off a directory entry;
    #   a file is there and says nothing about itself -> COULD NOT BE MADE.
    #     What that file is was not established, and guessing from its name is
    #     the mistake this whole script exists to avoid;
    #   nothing is there -> an optional thing is absent, and the run may still
    #     succeed. Where it looked is printed either way.
    #
    $browserCandidates = if ($BrowserPath) { @($BrowserPath) } else { Get-LcBrowserCandidates }
    $browserWhere = "looked at $(@($browserCandidates).Count) location(s)"
    $browserFound = $null
    $browserPresent = $null
    foreach ($candidate in $browserCandidates) {
        if ($null -ne $browserFound) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            if ($null -eq $browserPresent) { $browserPresent = $candidate }
            $version = Get-LcExecutableVersion -Path $candidate
            if ($version) { $browserFound = "$candidate reports version $version" }
        }
    }
    if ($browserFound) {
        Add-LcDoctorCheck -Name 'Bridge: a browser to drive it' -Status 'pass' -Kind 'reality' `
            -Value $browserFound -Detail @(
            'Read from the program itself, not from the name of a file.')
    } elseif ($null -ne $browserPresent) {
        Add-LcDoctorCheck -Name 'Bridge: a browser to drive it' -Status 'warn' -Kind 'reality' -Unmade `
            -Value "a file is at $browserPresent and it does not report a version" -Detail @(
            'Whether that is a browser could not be established here, and its name is not an answer.')
    } else {
        Add-LcDoctorCheck -Name 'Bridge: a browser to drive it' -Status 'warn' -Kind 'reality' `
            -Value "no browser to drive it ($browserWhere)" -Detail (@(
                'Optional here: this is a fact about this PC, not about the ComfyUI above.',
                'Workflow sync reports BROWSER_NOT_FOUND until one is installed, or pass -BrowserPath.') +
            @($browserCandidates))
    }

    # ------------------------------------------------------------------
    # Configuration. None of this can pass, by construction: the library
    # refuses a PASS that is not backed by a request or an action.
    # ------------------------------------------------------------------
    if (-not $ComfyRoot) {
        Add-LcDoctorCheck -Name 'Installation on disk' -Status 'info' -Kind 'configuration' `
            -Value 'not asked: no -ComfyRoot was given' -Detail @(
            'Everything above was measured over HTTP, which is the only coupling LocalCanvas has with ComfyUI (docs/architecture.md).')
    } else {
        # A DISK FACT MAY NOT ANNUL THE ANSWER. Get-LcComfyInstallation throws
        # on an install record it cannot parse or whose schema it does not
        # know -- a hard refusal, and the right one for setup.ps1, which is
        # about to write there. Here it ended the whole run at exit 1 with no
        # verdict at all, AFTER every reality check had already passed, while
        # the very line below says the disk facts do not change the answer
        # above. So the refusal becomes what it is for this script: a
        # configuration check that could not be made.
        $installation = $null
        $installationProblem = ''
        try {
            $installation = Get-LcComfyInstallation -Root $ComfyRoot
        } catch {
            $installationProblem = "$($_.Exception.Message)"
        }
        if ($null -eq $installation) {
            Add-LcDoctorCheck -Name 'Installation on disk' -Status 'warn' -Kind 'configuration' -Unmade `
                -Value "the installation at $ComfyRoot could not be read" -Detail @(
                $installationProblem,
                'The answer above stands: it was measured over HTTP and does not depend on this path.')
        } else {
            $evidence = @($installation.Evidence)
            if ($installation.Kind -eq 'Existing' -or $installation.Kind -eq 'Ours') {
                Add-LcDoctorCheck -Name 'Installation on disk' -Status 'info' -Kind 'configuration' `
                    -Value "a ComfyUI is at $($installation.AppDirectory)" -Detail (@(
                        'Found by reading names on disk. That is not a running service, and the answer above came from HTTP.') + $evidence)
            } else {
                Add-LcDoctorCheck -Name 'Installation on disk' -Status 'warn' -Kind 'configuration' `
                    -Value "no ComfyUI at $ComfyRoot ($($installation.Kind))" -Detail (@(
                        'This does not change the answer above: LocalCanvas reaches ComfyUI over HTTP and never through this path.') + $evidence)
            }

            $customNodes = $null
            if ($installation.AppDirectory) {
                $customNodes = Join-Path $installation.AppDirectory 'custom_nodes'
            }
            if ($customNodes -and (Test-Path -LiteralPath $customNodes -PathType Container)) {
                $directories = @(Get-ChildItem -LiteralPath $customNodes -Directory -ErrorAction SilentlyContinue)
                Add-LcDoctorCheck -Name 'custom_nodes on disk' -Status 'info' -Kind 'configuration' `
                    -Value "$($directories.Count) director(ies) under $customNodes" -Detail @(
                    'A present directory says nothing about whether the node loaded: a node that fails to import leaves it exactly as it was.',
                    'Only the node registry above answers that, which is why a required class is checked there and not here.')
            } else {
                Add-LcDoctorCheck -Name 'custom_nodes on disk' -Status 'info' -Kind 'configuration' `
                    -Value 'no custom_nodes directory was read' -Detail @(
                    'Nothing follows from that either way: registration is what the checks above use.')
            }
        }
    }

    # The path is printed rather than described, so that "this check looked in
    # the right place" is something a reader -- and a test -- can see. A check
    # that names no path can be wrong about where it looked and never say so.
    $workflowSources = Join-Path (Get-LcRepoRoot) 'config\local\workflow-sources.yaml'
    if (Test-Path -LiteralPath $workflowSources -PathType Leaf) {
        Add-LcDoctorCheck -Name 'Workflow source' -Status 'info' -Kind 'configuration' `
            -Value "configured in $workflowSources" -Detail @(
            'This check says the file is there and nothing more. What is in it is read by scripts\sync-workflows.ps1, which is what tells you whether your workflows import.')
    } else {
        Add-LcDoctorCheck -Name 'Workflow source' -Status 'warn' -Kind 'configuration' `
            -Value "nothing at $workflowSources" -Detail @(
            'Optional here: it decides what LocalCanvas syncs, not whether this ComfyUI is compatible.',
            'Copy-Item config/examples/workflow-sources.example.yaml config/local/workflow-sources.yaml')
    }

    # ------------------------------------------------------------------
    # The LocalCanvas gateway, if one happens to be running. It does not have
    # to be: this script judges a ComfyUI. docs/versioning.md -- api_version is
    # the only number that gates anything, so it is reported as the fact it is.
    # ------------------------------------------------------------------
    $gatewayUrlFull = $gateway + $script:GatewayInfoPath
    $gatewayProbe = Get-LcDoctorProbe -Url $gatewayUrlFull
    # WHAT WAS PROBED, ON EVERY OUTCOME, and read off the very string the
    # request was made with: a verdict names the endpoint it tested or it is a
    # verdict about an address the reader has to guess (T-0300).
    $gatewayWhere = @(
        "Probed: $gatewayUrlFull",
        "Source: $($gatewayEndpoint.Source).") + @($gatewayEndpoint.Detail)
    if (-not $gatewayProbe.Ok) {
        Add-LcDoctorCheck -Name 'LocalCanvas gateway' -Status 'warn' -Kind 'reality' `
            -Value "no LocalCanvas gateway answered at $gatewayUrlFull" -Detail (@(
                'Optional here, and absent rather than unknown: whether one is running does not decide whether this ComfyUI is compatible.',
                'scripts\doctor.ps1 is the gateway''s own doctor and asks a different question.') + $gatewayWhere)
    } elseif ((Test-LcGatewayIdentity -Body $gatewayProbe.Body) -eq $true) {
        $gatewayDocument = ConvertFrom-LcDoctorJson -Body $gatewayProbe.Body
        $apiVersion = 'not reported'
        if ($null -ne $gatewayDocument -and (Test-LcHasProperty -Object $gatewayDocument -Name 'api_version')) {
            $apiVersion = [string]$gatewayDocument.api_version
        }
        Add-LcDoctorCheck -Name 'LocalCanvas gateway' -Status 'pass' -Kind 'reality' `
            -Value "a LocalCanvas gateway answered at $gatewayUrlFull" -Detail (@(
                "Fact, not a verdict: it speaks api_version $apiVersion.",
                'docs/versioning.md: an app and a gateway work together if and only if their api_version is identical.') + $gatewayWhere)
    } else {
        Add-LcDoctorCheck -Name 'LocalCanvas gateway' -Status 'warn' -Kind 'reality' `
            -Value "something answered at $gatewayUrlFull and it did not identify itself as LocalCanvas" -Detail (@(
                'docs/connection.md: an arbitrary HTTP endpoint is never treated as a compatible gateway.') + $gatewayWhere)
    }

    $verdict = Write-LcDoctorVerdict -Subject $base
    exit $verdict
} catch {
    Write-LcFailure -What 'The compatibility check could not be completed' `
        -Detail @("$($_.Exception.Message)") -ErrorRecord $_ `
        -Fix 'Run it again with -BaseUrl naming where your ComfyUI listens.'
    exit $EXIT_UNEXPECTED
}
