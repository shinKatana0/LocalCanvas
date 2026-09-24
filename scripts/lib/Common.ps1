<#
.SYNOPSIS
    Shared helpers for the LocalCanvas runtime scripts.

.DESCRIPTION
    Dot-sourced by setup.ps1 / start.ps1 / stop.ps1 / status.ps1. Holds the
    four things all of them need and none of them should re-invent:

      * the terminal vocabulary of docs/runtime.md ([INFO] / [ OK ] / [FAIL]);
      * configuration, read through the gateway's own loader (never a second
        YAML parser in PowerShell);
      * readiness, expressed only as a polled HTTP probe -- never a sleep;
      * process ownership, expressed as a PID plus enough evidence to prove
        the PID still names the process LocalCanvas started.

    Nothing in here kills a process by name, and nothing in here changes
    anything outside the repository.
#>

Set-StrictMode -Version Latest

# PowerShell 7.4+ turns a non-zero exit from a native command into a
# terminating error when $ErrorActionPreference is 'Stop'. The helpers here
# deliberately read $LASTEXITCODE themselves -- a configuration reader that
# exits 2 to report a bad config is not an exception to be swallowed by the
# host -- so that behaviour is switched off for the scripts that dot-source
# this file. (Harmless no-op on Windows PowerShell 5.1.)
$PSNativeCommandUseErrorActionPreference = $false

# Invoke-LcProbe constructs HttpClientHandler and HttpClient, which live in
# System.Net.Http. Windows PowerShell 5.1 does not load that assembly by
# default, so without this every probe failed there with "Unable to find type
# [System.Net.Http.HttpClientHandler]." and every check built on one reported
# that nothing answered (T-0217). MEASURED, 2026-09-16: under 5.1.26100 the
# type is absent before this line and present after it (GAC System.Net.Http
# 4.0.0.0); under pwsh 7.6.6 it is already loaded, and the call succeeds, twice,
# changing nothing. Loaded here, when the library is dot-sourced, so that it is
# in place before any function below constructs anything.
Add-Type -AssemblyName 'System.Net.Http'

# The only place in the runtime scripts where a delay is allowed to exist:
# the gap between two probes of a polling loop. It is never the readiness
# contract, only the interval at which the contract is tested.
$script:PollIntervalMs = 250

$script:HandleInheritanceDisabled = $false

# Marks a failure of the configuration seam itself -- a document that does
# not carry a field the scripts consume -- so the scripts can report it as
# the configuration problem it is instead of as an unexpected error.
$script:SeamFailureMarker = '[configuration-seam]'

function Disable-LcHandleInheritance {
    <#
        Stop the processes we launch from inheriting this script's own standard
        handles.

        Windows starts a child with bInheritHandles=TRUE, so a child inherits
        every inheritable handle we hold -- including our stdout -- even when
        its own output is redirected to a file. Anything reading start.ps1's
        output through a pipe (a CI job, another script, the test harness) then
        waits for end-of-file on a pipe the gateway is holding open, and hangs
        long after start.ps1 has finished. Clearing the inherit flag on our own
        three standard handles is process-local and changes nothing else.

        Best effort: if it cannot be done, the launch still happens.
    #>
    if ($script:HandleInheritanceDisabled) { return }
    try {
        if (-not ('LocalCanvas.NativeHandles' -as [type])) {
            Add-Type -Namespace 'LocalCanvas' -Name 'NativeHandles' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetHandleInformation(System.IntPtr hObject, uint dwMask, uint dwFlags);
'@
        }
        $invalid = [IntPtr](-1)
        foreach ($id in @(-10, -11, -12)) {
            # STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE
            $handle = [LocalCanvas.NativeHandles]::GetStdHandle($id)
            if ($handle -ne [IntPtr]::Zero -and $handle -ne $invalid) {
                [void][LocalCanvas.NativeHandles]::SetHandleInformation($handle, 1, 0)
            }
        }
        $script:HandleInheritanceDisabled = $true
    } catch {
        Write-LcWarn 'Could not detach the child processes from this terminal''s handles.'
        Write-LcDetail 'If this terminal appears to hang after startup, close it; the runtime keeps running.'
    }
}

# --------------------------------------------------------------------------
# Launching a child whose streams we redirect
# --------------------------------------------------------------------------
#
# LocalCanvas starts two processes, ComfyUI and its own gateway, and redirects
# the standard streams of both into log files under .runtime/. A redirected
# stream is not a console, and on Windows CPython therefore encodes it with the
# machine's ANSI code page instead of the UTF-8 it would use for a console. On
# a machine whose ANSI code page is not UTF-8 -- which is most machines outside
# the English-speaking world -- the first log line carrying a character that
# code page has not got raises UnicodeEncodeError inside the child's own
# logging, and the child dies during start-up. Measured: ComfyUI exits while
# loading custom nodes, and managed start reports only a readiness timeout
# (T-0085).
#
# Creating that redirect is what makes the encoding ours to declare. We chose
# the file, so we chose its contract, and leaving the contract to the machine's
# ANSI code page is the defect. So every child started here is told its streams
# are UTF-8, in its OWN environment, and start.ps1 reads those logs back as
# UTF-8.
#
# WHY AN ENVIRONMENT VARIABLE, AND NOT `-X utf8`. This is the load-bearing
# reason for everything below it, so it is written here rather than left to be
# rediscovered. Both work: measured on a machine whose ANSI code page is 1251,
# a redirected child with nothing declared reports stdout=cp1251 and dies on
# U+25CB, while the same child with either `-X utf8` or PYTHONIOENCODING=utf-8
# reports stdout=utf-8 and keeps the character. `-X utf8` is a command-line
# flag, needs no control over the child's environment at all, and would let
# this file keep Start-Process -- so on the face of it it is the smaller
# change, and the rest of this section would be unjustifiable weight.
#
# It is still the wrong lever. `-X utf8` turns on PEP 540 UTF-8 mode, which
# also changes locale.getpreferredencoding(), and therefore the default
# encoding of every open() inside ComfyUI's own code -- third-party file I/O
# that LocalCanvas never redirected and has no business reaching into.
# PYTHONIOENCODING changes the standard streams and nothing else, which is
# exactly the surface we took responsibility for by redirecting it. Declaring
# more than we own would be the same mistake as declaring nothing, in the other
# direction.
#
# And an environment variable is per-process or it is nothing: setting it in
# THIS process would reach every child of this shell and outlive the launch,
# which is the workaround this replaces. Start-Process cannot give a child an
# environment of its own on the floor this project requires: its -Environment
# parameter is PowerShell 7.4+, and README.md requires 7.0 or newer. (It once
# said "and README.md makes Windows PowerShell a supported host", which stopped
# being true at T-0287; the 7.4 floor is the reason that remains, and raising
# the required version is a product decision this comment does not take --
# T-0290.) So the launch below makes the same CreateProcess call Start-Process
# makes underneath, with an environment block of its own. That is the whole of
# why this is here.
#
# This is not in tension with the rule the project follows for its own terminal
# output (sync-workflows.ps1::Test-LcTerminalCanWrite, and T-0037 before it).
# That rule governs what LocalCanvas writes to a console it does NOT own, where
# the rendering adapts to the stream and the stream is never adapted to the
# text. This is the other case: a stream we created ourselves, feeding a file
# we own, carrying a child's output. Nothing here touches a console code page,
# this process's own environment or encoding state, or any process LocalCanvas
# did not start.
$script:LcChildStreamEncoding = 'utf-8'

function Get-LcChildEnvironment {
    <#
        The environment one child is given: this process's own, plus the
        stream encoding declared for that child.

        Built as a list and handed to CreateProcess. It is never applied to
        this process: PYTHONIOENCODING here would reach every child of this
        shell and outlive the launch, which is the workaround T-0085 was filed
        to replace, not the fix.

        Sorted the way Windows sorts an environment block, case-insensitively,
        so a child that walks it sees the order it would see from any other
        launcher.
    #>
    $map = [System.Collections.Generic.SortedDictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $name = [string]$entry.Key
        if (-not $name) { continue }
        $map[$name] = [string]$entry.Value
    }
    $map['PYTHONIOENCODING'] = $script:LcChildStreamEncoding
    return @($map.Keys | ForEach-Object { "$_=$($map[$_])" })
}

function Initialize-LcChildProcessType {
    <#
        The launcher itself.

        There is exactly one reason it is here, and it is the one the block
        above this function sets out: an environment variable is per-process,
        Start-Process cannot give a child an environment of its own, and the
        encoding we owe the child is a variable in the child's environment. So
        this makes the same CreateProcess call Start-Process makes underneath,
        with an environment block of its own, and differs from it in nothing
        else.

        In nothing else is the load-bearing half. Real file handles for the
        redirected streams, and a process id that is the child's own rather
        than a shim's or a shell's, are true of Start-Process too: neither of
        them argues for a line of what follows, and reading them as if they did
        is how this ends up looking justified by properties it never needed
        CreateProcess for. They are stated here only because the code below
        must not lose them -- the ownership record is written from that process
        id (T-0088), and the log is the child's own file handle, which is why
        it survives this script exiting.

        When the required floor reaches PowerShell 7.4, Start-Process
        -Environment does the whole of what this exists for, and this can go.
        (It used to say "when Windows PowerShell stops being a supported host";
        that happened at T-0287 and was not enough -- README.md requires 7.0,
        and -Environment needs 7.4. T-0290 holds the decision.)

        The child is created suspended and resumed by the caller once it holds
        a process object for it. A child that exits in its first milliseconds
        is an ordinary outcome here (that is precisely the T-0085 failure), and
        without this the launcher could fail to look up a process that had
        already gone rather than reporting what it did.
    #>
    if ('LocalCanvas.ChildProcess' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace LocalCanvas
{
    public static class ChildProcess
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            public int Inherit;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public int Size;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public int Flags;
            public short ShowWindow;
            public short Reserved2;
            public IntPtr Reserved3;
            public IntPtr StdInput;
            public IntPtr StdOutput;
            public IntPtr StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Created
        {
            public IntPtr Process;
            public IntPtr Thread;
            public int ProcessId;
            public int ThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
            string name, uint access, uint share, ref SecurityAttributes security,
            uint disposition, uint attributes, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(
            string image, StringBuilder line, IntPtr processAttributes,
            IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment,
            string directory, ref StartupInfo startup, out Created created);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint ShareRead = 0x00000001;
        private const uint CreateAlways = 2;
        private const uint OpenExisting = 3;
        private const uint AttributeNormal = 0x00000080;
        private const uint UnicodeEnvironment = 0x00000400;
        private const uint Suspended = 0x00000004;
        private const int UseStdHandles = 0x00000100;
        private static readonly IntPtr Invalid = new IntPtr(-1);

        // One process handle per launch, held for the life of THIS process --
        // the same guarantee Start-Process -PassThru gives. While the handle
        // is open Windows cannot hand that process id to anything else, so an
        // ownership record written from it can never come to name a different
        // process.
        private static readonly List<IntPtr> Held = new List<IntPtr>();
        private static readonly Dictionary<int, IntPtr> Threads = new Dictionary<int, IntPtr>();

        private static IntPtr OpenForChild(string path, bool writing)
        {
            SecurityAttributes security = new SecurityAttributes();
            security.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            security.Descriptor = IntPtr.Zero;
            security.Inherit = 1;
            IntPtr handle = CreateFileW(
                path,
                writing ? GenericWrite : GenericRead,
                // Read-only sharing, as the redirection it replaces had: a log
                // a running child holds may be tailed and may not be truncated
                // out from under it.
                ShareRead,
                ref security,
                writing ? CreateAlways : OpenExisting,
                AttributeNormal,
                IntPtr.Zero);
            if (handle == Invalid)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The log file could not be opened for the child process: " + path);
            }
            return handle;
        }

        public static int Start(
            string line, string directory, string outputLog, string errorLog,
            string[] environment)
        {
            IntPtr input = IntPtr.Zero;
            IntPtr output = IntPtr.Zero;
            IntPtr error = IntPtr.Zero;
            IntPtr block = IntPtr.Zero;
            try
            {
                // NUL, not this process's own standard input: a background
                // child must not be left holding the terminal that started it.
                input = OpenForChild("NUL", false);
                output = OpenForChild(outputLog, true);
                error = OpenForChild(errorLog, true);

                StringBuilder text = new StringBuilder();
                foreach (string entry in environment)
                {
                    text.Append(entry).Append('\0');
                }
                text.Append('\0');
                block = Marshal.StringToHGlobalUni(text.ToString());

                StartupInfo startup = new StartupInfo();
                startup.Size = Marshal.SizeOf(typeof(StartupInfo));
                startup.Flags = UseStdHandles;
                startup.StdInput = input;
                startup.StdOutput = output;
                startup.StdError = error;

                Created created;
                bool started = CreateProcessW(
                    null, new StringBuilder(line, line.Length + 1),
                    IntPtr.Zero, IntPtr.Zero, true,
                    UnicodeEnvironment | Suspended, block, directory,
                    ref startup, out created);
                if (!started)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                Held.Add(created.Process);
                Threads[created.ProcessId] = created.Thread;
                return created.ProcessId;
            }
            finally
            {
                if (block != IntPtr.Zero) { Marshal.FreeHGlobal(block); }
                if (input != IntPtr.Zero && input != Invalid) { CloseHandle(input); }
                if (output != IntPtr.Zero && output != Invalid) { CloseHandle(output); }
                if (error != IntPtr.Zero && error != Invalid) { CloseHandle(error); }
            }
        }

        public static void Resume(int processId)
        {
            IntPtr thread;
            if (!Threads.TryGetValue(processId, out thread)) { return; }
            Threads.Remove(processId);
            if (ResumeThread(thread) == 0xFFFFFFFF)
            {
                int code = Marshal.GetLastWin32Error();
                CloseHandle(thread);
                throw new Win32Exception(code);
            }
            CloseHandle(thread);
        }
    }
}
'@
}

function Start-LcRedirectedChild {
    <#
        Start one child with its standard output and error redirected into two
        log files, and its stream encoding declared for it and for nothing else.

        The one place a redirected child is launched, used by both of them --
        ComfyUI and the gateway have the same exposure, and one decision
        applied twice is how it stays one decision.

        Returns the child's own System.Diagnostics.Process, which is what the
        readiness watch and the ownership record are written from.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$CommandLine = '',
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StandardOutputLog,
        [Parameter(Mandatory)][string]$StandardErrorLog
    )
    Disable-LcHandleInheritance
    Initialize-LcChildProcessType

    # argv[0] is part of a command line, and a path with a space in it is
    # quoted by the same function every other argument goes through.
    $line = ConvertTo-LcArgument $FilePath
    if ($CommandLine) { $line = "$line $CommandLine" }

    try {
        $processId = [LocalCanvas.ChildProcess]::Start(
            $line, $WorkingDirectory, $StandardOutputLog, $StandardErrorLog,
            (Get-LcChildEnvironment))
    } catch {
        # A .NET exception arrives wrapped in a method-invocation error whose
        # message is about the call rather than about what went wrong.
        $reason = "$($_.Exception.Message)"
        if ($_.Exception.InnerException) { $reason = "$($_.Exception.InnerException.Message)" }
        throw $reason
    }

    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
    } finally {
        # Always, including on the path where the lookup failed: a child left
        # suspended is a child nothing will ever run or stop.
        [LocalCanvas.ChildProcess]::Resume($processId)
    }
    return $process
}

# --------------------------------------------------------------------------
# Terminal vocabulary (docs/runtime.md, "Startup output")
# --------------------------------------------------------------------------

function Write-LcBanner {
    Write-Host ''
    Write-Host 'LocalCanvas'
    Write-Host ''
}

function Write-LcInfo { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-LcOk { param([string]$Message) Write-Host "[ OK ] $Message" }
function Write-LcWarn { param([string]$Message) Write-Host "[WARN] $Message" }
function Write-LcFail { param([string]$Message) Write-Host "[FAIL] $Message" }

function Write-LcDetail {
    param([string]$Message)
    foreach ($line in ($Message -split "`r?`n")) { Write-Host "       $line" }
}

function Write-LcField {
    param([string]$Label, [string]$Value)
    Write-Host ''
    Write-Host "       ${Label}:"
    foreach ($line in ($Value -split "`r?`n")) { Write-Host "       $line" }
}

<#
    The primary failure surface. A raw PowerShell stack trace is never it:
    a failure says what was attempted, what happened, and the one most likely
    fix. Full detail goes to .runtime/last-error.log for the curious.
#>
function Write-LcFailure {
    param(
        [Parameter(Mandatory)][string]$What,
        [string[]]$Detail = @(),
        [string]$Fix,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    Write-Host ''
    Write-LcFail $What
    foreach ($line in $Detail) { Write-LcDetail $line }
    if ($Fix) { Write-LcDetail $Fix }
    if ($ErrorRecord) {
        $logPath = Join-Path (Get-LcRuntimeDirectory) 'last-error.log'
        try {
            $payload = @(
                "[$(Get-Date -Format 'o')] $What",
                ($ErrorRecord | Out-String),
                ($ErrorRecord.ScriptStackTrace)
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath $logPath -Value $payload -Encoding UTF8
            Write-LcDetail "Full detail: $logPath"
        } catch {
            # Diagnostics must never become the failure being reported.
        }
    }
    Write-Host ''
}

# --------------------------------------------------------------------------
# Repository layout
# --------------------------------------------------------------------------

function Get-LcRepoRoot {
    # scripts/lib/Common.ps1 -> scripts/lib -> scripts -> repo root
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Test-LcPathIsUnder {
    <#
        Is $Path the directory $Root itself, or something inside it?

        A path question, not a string question, and that difference is the
        whole reason it is a function: 'C:\path\to\gateway-old' starts with
        'C:\path\to\gateway' and is not inside it, and the path
        'C:\path\to\gateway\..\other' does not start with it and is not inside
        it either. Both are decided here by normalising each side and comparing
        segment by segment, so neither a shared prefix nor a '..' can answer
        wrongly.

        Neither side has to exist: this is asked about paths a probe printed,
        which may name a package installed somewhere that has since moved.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root
    )
    if (-not $Path -or -not $Root) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $base = [System.IO.Path]::GetFullPath($Root)
    } catch {
        return $false
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $full = $full.TrimEnd($separator)
    $base = $base.TrimEnd($separator)
    if ($full -eq $base) { return $true }
    # The separator is part of the comparison: without it 'gateway-old' would
    # answer yes for 'gateway'.
    return $full.StartsWith($base + $separator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LcRuntimePath {
    <#
        The runtime state directory, named but not created -- status.ps1 is
        read-only and must not bring it into existence just by reporting.

        Defaults to .runtime/ at the repository root. LOCALCANVAS_RUNTIME_DIR
        moves it, so a second runtime can be exercised without touching the
        state of the one you are using.
    #>
    $override = [Environment]::GetEnvironmentVariable('LOCALCANVAS_RUNTIME_DIR')
    if ($override) { return $override }
    return (Join-Path (Get-LcRepoRoot) '.runtime')
}

function Get-LcRuntimeDirectory {
    $path = Get-LcRuntimePath
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function Get-LcVenvPython {
    return (Join-Path (Get-LcRepoRoot) '.venv\Scripts\python.exe')
}

<#
    Interpreter selection is explicit and observable (docs/runtime.md). The
    scripts invoke .venv\Scripts\python.exe directly; they never fall back to a
    bare `py` or `python`, and never to ComfyUI's interpreter.
#>
function Resolve-LcPython {
    param([string]$PythonExe)
    $candidate = if ($PythonExe) { $PythonExe } else { Get-LcVenvPython }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            "The LocalCanvas Python interpreter was not found at '$candidate'.", $candidate)
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-LcSupportedPythonFloor {
    <#
        The supported range is declared once, in packaging metadata
        (gateway/pyproject.toml, docs/runtime.md "Supported Python versions").
        This reads the floor from there rather than keeping a second copy of
        it, and it lives here rather than in setup.ps1 because doctor.ps1 has
        to report the same number setup.ps1 built against -- two readers of one
        declaration is how they come to disagree.

        Returns { Major; Minor; Ceiling; Specifier; Source } or $null when the
        metadata carries no floor at all; pip enforces the authoritative range
        at install time either way.

        SPECIFIER IS THE WHOLE DECLARED RANGE, and it is here because half of
        it is worse than none (T-0173, B3). The declaration is
        ">=3.10,<3.14" and what setup.ps1 printed was "Supported Python: >=
        3.10" -- so on a machine whose default `py` is 3.14, the line told a
        user their interpreter was supported while pip would refuse it. The
        ceiling is not a second number to keep here: it is read out of the
        same line as the floor, because two readers of one declaration is how
        they come to disagree.

        CEILING IS THAT SAME NUMBER, PARSED, so a check can gate on it and not
        only print it (T-0281). Printing the whole range while gating on half
        of it is the same defect wearing a different coat: doctor.ps1 said
        "Python environment ok" for an interpreter at 3.14 against a declared
        ">=3.10,<3.14", and pip would refuse the gateway on it. { Major; Minor;
        Inclusive } for the `<` or `<=` in the declaration, or $null when there
        is none -- and a declaration this cannot read leaves it $null, which
        gates on the floor alone, exactly as before.
    #>
    $pyproject = Join-Path (Get-LcRepoRoot) 'gateway\pyproject.toml'
    if (Test-Path -LiteralPath $pyproject) {
        $line = Select-String -LiteralPath $pyproject -Pattern '^\s*requires-python\s*=' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($line) {
            # The declared value, as written: everything after the '=', with a
            # trailing comment and the surrounding quotes taken off. Read
            # before the floor is matched, because -match rewrites $Matches.
            $declared = ($line.Line -replace '^\s*requires-python\s*=\s*', '')
            $declared = ($declared -replace '\s+#.*$', '').Trim().Trim('"').Trim("'").Trim()

            # The ceiling FIRST, and into plain variables: every -match below
            # rewrites $Matches, so reading one match after running the next
            # is how a parser quietly reports the wrong number.
            $ceiling = $null
            if ($declared -match '<(=?)\s*(\d+)\.(\d+)') {
                $ceiling = [pscustomobject]@{
                    Major = [int]$Matches[2]; Minor = [int]$Matches[3]
                    Inclusive = ($Matches[1] -eq '=')
                }
            } elseif ($declared -match '<(=?)\s*(\d+)(?![\d.])') {
                # "<4" -- a whole major series excluded, which is the other
                # shape this declaration is ever written in.
                $ceiling = [pscustomobject]@{
                    Major = [int]$Matches[2]; Minor = 0
                    Inclusive = ($Matches[1] -eq '=')
                }
            }

            if ($line.Line -match '>=\s*(\d+)\.(\d+)') {
                return [pscustomobject]@{
                    Major     = [int]$Matches[1]
                    Minor     = [int]$Matches[2]
                    Ceiling   = $ceiling
                    Specifier = $declared
                    Source    = $pyproject
                }
            }
        }
    }
    return $null
}

function Test-LcPythonVersionSupported {
    <#
        Is this interpreter inside the WHOLE declared range (T-0281)?

        Test-LcVersionAtLeast below answers half the question, and half is
        what made doctor.ps1 report "Python environment ok" for a 3.14 against
        a declared ">=3.10,<3.14" -- a verdict pip then contradicts at install
        time. This one asks the range the metadata actually declares, which it
        is handed rather than reading a second time.

        $Range is what Get-LcSupportedPythonFloor returned. A range with no
        ceiling, or a version this cannot parse, answers exactly as the floor
        check alone does: nothing here turns an unreadable declaration into a
        refusal.
    #>
    param([string]$Version, $Range)
    if (-not $Range) { return $true }
    if (-not (Test-LcVersionAtLeast -Version $Version -Floor $Range)) { return $false }
    if (-not (Test-LcHasProperty -Object $Range -Name 'Ceiling')) { return $true }
    $ceiling = $Range.Ceiling
    if (-not $ceiling) { return $true }
    $parts = "$Version".Split('.')
    if ($parts.Count -lt 2) { return $true }
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -ne $ceiling.Major) { return $major -lt $ceiling.Major }
    if ($ceiling.Inclusive) { return $minor -le $ceiling.Minor }
    return $minor -lt $ceiling.Minor
}

function Test-LcVersionAtLeast {
    param([string]$Version, $Floor)
    if (-not $Floor) { return $true }
    $parts = "$Version".Split('.')
    if ($parts.Count -lt 2) { return $true }
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -ne $Floor.Major) { return $major -gt $Floor.Major }
    return $minor -ge $Floor.Minor
}

# --------------------------------------------------------------------------
# Probing an external executable
# --------------------------------------------------------------------------
#
# A PROBE IS NOT A COMMAND (T-0299). The scripts ask two questions of an
# external executable before they do anything else -- "which Python is this?"
# and "what does the gateway's own loader make of this configuration?" -- and
# both used to be asked with PowerShell's call operator, `& $exe ... 2>&1`.
# That operator is a fine way to RUN a program and a poor way to PROBE one,
# for three reasons, all three measured rather than reasoned:
#
#   1. IT HANDS THE CHILD THIS TERMINAL'S STANDARD INPUT. In the test suite
#      and in CI that input is a pipe, so a child that reads it gets
#      end-of-file at once and nobody notices. A user runs doctor.ps1 from a
#      real console, where the same handle is the keyboard. MEASURED: an
#      executable that reads standard input, handed to the version probe with
#      a console attached, was still running when the measurement was stopped
#      -- and with the identical call and a redirected standard input it
#      returned in about a tenth of a second. A probe must never be able to
#      wait for a person.
#
#   2. IT HAS NO BOUND AT ALL. `& $exe` returns when the child returns. There
#      is no deadline to miss, so a child that never returns is a script that
#      never returns, and the output the user last saw is the banner.
#
#   3. ON A FAILED LAUNCH IT FALLS BACK TO THE WINDOWS SHELL. When
#      CreateProcess refuses the image, PowerShell retries the launch through
#      ShellExecute -- the same call that opens a file by its association.
#      MEASURED, against a text file named `not python.exe`: the exception
#      that comes back is "StandardOutputEncoding is only supported when
#      standard output is redirected", which is .NET refusing a redirect on a
#      shell-execute launch, so the retry is not a guess about the code path,
#      it is visible in the message. That retry goes through association and
#      reputation machinery whose cost belongs to Windows and to the state of
#      the machine, not to us: on this development machine it completed in
#      57-80 ms in every condition tried, and it was measured at 38,853 ms on
#      the same machine a day earlier, with a doctor run that printed its
#      banner and then nothing for over ten minutes (T-0294 round 2, T-0299).
#      A cost we do not control and cannot predict is exactly what a probe may
#      not be exposed to. `[System.Diagnostics.Process]::Start` with
#      UseShellExecute disabled never takes that route: it fails with a plain
#      Win32 error, in about 60 ms, identically in every condition.
#
# So a probe is launched here instead, with the shell route closed, standard
# input closed, both output streams drained concurrently, and a deadline of
# its own. The bound is NOT a global timeout bolted over the call: it is a
# property of the individual question being asked, which is why the two
# questions below carry two different numbers.

# The bound on ONE probe. Two numbers because they are not the same question.
#
# The interpreter's own version: python.exe starts, prints three numbers and
# exits. MEASURED on the development machine, 21 runs across a redirected
# standard input, a console with a window and a console without one: 252-275 ms
# every time. Thirty seconds is a hundredfold margin over that, and still a
# finite number a person will sit through.
$script:PythonVersionProbeSeconds = 30

# The configuration seam: the same interpreter, plus the import of the gateway
# package and everything it imports, plus reading and validating the document.
# That is a different order of work from printing a version number, so it gets
# a number of its own rather than sharing an arbitrary one with it.
$script:ConfigLoaderProbeSeconds = 120

# The pairing QR: the same interpreter and the same package import as the
# configuration seam, plus rendering one code. The same order of work, so the
# same number -- written separately all the same, because the day one of them
# has to change is the day sharing a constant would change the other by
# accident.
$script:GatewayQrProbeSeconds = 120

# The workflow-change check: the same interpreter and package import again,
# plus reading and hashing every file in the user's workflow folders. That last
# part is the one cost here that grows with somebody else's disk, and it is why
# this number is larger than the two above rather than equal to them. It is
# still a finite bound on a command a user runs daily -- a check that hangs is
# a LocalCanvas that never starts.
$script:WorkflowCheckProbeSeconds = 300

# How long the probe waits for the two output pipes to finish after the child
# has gone. A child that exits leaving a grandchild holding the pipe would
# otherwise keep this open for ever, which is the deadline reappearing at the
# end of the function it was added to.
$script:ProbeDrainSeconds = 10

# NEITHER OF THESE IS A READINESS DEADLINE, and neither replaces one.
# startup.comfy_timeout_seconds and startup.gateway_timeout_seconds cover a
# slow ComfyUI start (docs/runtime.md); they are the user's to set, they are
# waiting for a server to come up rather than for a program to answer, and
# nothing here touches them.

function Invoke-LcExecutableProbe {
    <#
        Ask one question of one external executable, under a deadline.

        Returns, always -- it throws for nothing the executable can do:

          Component      what this probe was asking, for the diagnostic
          Command        the command line, for the diagnostic
          Started        did the process start at all
          Exited         did it exit on its own, inside the deadline
          TimedOut       was it stopped because the deadline passed
          ExitCode       its exit code, or -1 when there is none
          StandardOutput captured whole, separately
          StandardError  captured whole, separately
          ProcessId      the id of the process THIS call started, or 0
          ElapsedMs      wall time of the probe
          WorkingDirectory  the directory the child was given
          Failure        one actionable sentence naming the component, or ''

        THE CHILD IS ALWAYS GIVEN A DIRECTORY, and that is a fix rather than a
        detail (T-0307). .NET's own failure sentence for a launch that did not
        happen reads "An error occurred trying to start process '<exe>' with
        working directory '<dir>'", and <dir> is ProcessStartInfo's when one is
        set and the HOSTING PROCESS's .NET current directory when it is not --
        which is where pwsh was started, not where the user has since
        Set-Location'd. Measured from a clean clone: the doctor's diagnostic
        named a directory that had nothing to do with the failure. So when the
        caller does not choose one, the repository root is used: a directory
        LocalCanvas picked on purpose, the same one in every session, and one
        that is true of the sentence it appears in.

        Standard output and standard error stay APART. The caller of the
        configuration seam needs the document on one side and the loader's
        complaint on the other, and reading them out of one merged stream by
        asking which pipeline objects happen to be strings is a guess about
        PowerShell's object model rather than a fact about the child.

        Both are drained by a reader of their own, started before the wait.
        Reading one to the end and then the other deadlocks the moment the
        child fills the pipe the reader is not on -- a 4 KB buffer is all it
        takes -- and that is a hang no deadline above this function would
        explain.

        What it does NOT do, deliberately: it does not decide the child's text
        encoding. The streams are decoded exactly as the call operator decoded
        them before, so a healthy run produces the same characters it always
        did; the child's stream encoding is declared in one place in this file
        (Get-LcChildEnvironment) for the children we redirect into log files,
        and widening that decision is not this card's to take.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][double]$TimeoutSeconds,
        [string]$WorkingDirectory
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $line = ConvertTo-LcCommandLine $Arguments
    $shown = (ConvertTo-LcArgument $FilePath)
    if ($line) { $shown = "$shown $line" }

    # T-0307: never let an INHERITED directory reach a sentence this project
    # prints. Resolved here, once, so every caller gets the same answer.
    if (-not $WorkingDirectory) {
        try { $WorkingDirectory = Get-LcRepoRoot } catch { $WorkingDirectory = '' }
    }

    $result = [pscustomobject]@{
        Component      = $Component
        Command        = $shown
        Started        = $false
        Exited         = $false
        TimedOut       = $false
        ExitCode       = -1
        StandardOutput = ''
        StandardError  = ''
        ProcessId      = 0
        ElapsedMs      = 0
        TimeoutSeconds = $TimeoutSeconds
        WorkingDirectory = $WorkingDirectory
        Failure        = ''
    }

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    # Our own quoting, not the host's. The call operator hands arguments to
    # each host's native-argument rules, and Windows PowerShell 5.1's drop an
    # embedded double quote (T-0248); a command line this file built itself is
    # read back by CommandLineToArgvW the way ConvertTo-LcArgument wrote it,
    # under either host.
    $info.Arguments = $line
    # The three that close the shell route of reason 3 above, and with it the
    # association lookup, the reputation check and any dialog they could raise.
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
    } catch {
        # A .NET exception arrives wrapped in a method-invocation error whose
        # message is about the call rather than about what went wrong.
        $reason = "$($_.Exception.Message)"
        if ($_.Exception.InnerException) { $reason = "$($_.Exception.InnerException.Message)" }
        $result.Failure = "$Component could not be started: $reason"
        $result.ElapsedMs = [int]$watch.Elapsed.TotalMilliseconds
        return $result
    }

    try {
        $result.Started = $true
        $result.ProcessId = $process.Id

        # NO INTERACTIVE STANDARD INPUT, EVER. The child was given a pipe of
        # our own rather than this terminal, and the pipe is closed before it
        # can be read: a child that reads standard input sees end-of-file
        # immediately, whether this script was started from a console, from a
        # pipe or from a scheduled task.
        try { $process.StandardInput.Close() } catch { }

        $outRead = $process.StandardOutput.ReadToEndAsync()
        $errRead = $process.StandardError.ReadToEndAsync()

        $deadlineMs = [int][math]::Ceiling($TimeoutSeconds * 1000)
        if ($process.WaitForExit($deadlineMs)) {
            $result.Exited = $true
            $result.ExitCode = $process.ExitCode
        } else {
            $result.TimedOut = $true
            # ONLY THE PROCESS THIS PROBE STARTED. Addressed through the object
            # Start handed back, which is the one process this call created --
            # never by image name, never by a search of the process table,
            # never by whatever else on the machine happens to be running the
            # same interpreter.
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit([int]($script:ProbeDrainSeconds * 1000))
        }

        $drainMs = [int]($script:ProbeDrainSeconds * 1000)
        try { if ($outRead.Wait($drainMs)) { $result.StandardOutput = "$($outRead.Result)" } } catch { }
        try { if ($errRead.Wait($drainMs)) { $result.StandardError = "$($errRead.Result)" } } catch { }
    } finally {
        try { $process.Dispose() } catch { }
    }

    if ($result.TimedOut) {
        $result.Failure = (
            "$Component did not answer within $TimeoutSeconds seconds and was stopped " +
            "(process id $($result.ProcessId)). Nothing else on this machine was touched.")
    }
    $result.ElapsedMs = [int]$watch.Elapsed.TotalMilliseconds
    return $result
}

function Get-LcPythonVersionProbe {
    <#
        The interpreter version probe, with the reason it failed kept.

        Get-LcPythonVersion below answers the question four scripts ask -- a
        version string, or 'unknown' -- and that answer cannot say WHY. The
        doctor is the one caller that has to tell a user why, so it takes this
        one instead: { Version; Failure; TimedOut; Probe }, where Failure is
        one sentence naming the component, or '' when the interpreter answered.
    #>
    param([Parameter(Mandatory)][string]$PythonExe)

    # No quote character in the code, on purpose (T-0248). Windows PowerShell
    # 5.1 passes a native argument by its legacy rules and drops an embedded
    # double quote: measured, print("%d.%d.%d" % ...) reached Python as
    # print(%d.%d.%d % ...), a SyntaxError, and this said 'unknown' for every
    # interpreter. chr(46) is the dot.
    $probe = Invoke-LcExecutableProbe -FilePath $PythonExe `
        -Arguments @('-c', 'import sys; print(*sys.version_info[:3], sep=chr(46))') `
        -Component 'The Python interpreter' `
        -TimeoutSeconds $script:PythonVersionProbeSeconds

    $version = 'unknown'
    if ($probe.Exited -and $probe.ExitCode -eq 0) {
        $first = @("$($probe.StandardOutput)" -split "`r?`n" |
            Where-Object { $_ -and $_.Trim() }) | Select-Object -First 1
        if ($first) { $version = "$first".Trim() }
    }

    $failure = "$($probe.Failure)"
    if (-not $failure -and $version -eq 'unknown') {
        $said = @("$($probe.StandardError)" -split "`r?`n" |
            Where-Object { $_ -and $_.Trim() }) | Select-Object -First 1
        $failure = "The Python interpreter ran but printed no version number (exit code $($probe.ExitCode))."
        if ($said) { $failure = "$failure It said: $("$said".Trim())" }
    }

    return [pscustomobject]@{
        Version  = $version
        Failure  = $failure
        TimedOut = $probe.TimedOut
        Probe    = $probe
    }
}

function Get-LcPythonVersion {
    param([Parameter(Mandatory)][string]$PythonExe)
    return (Get-LcPythonVersionProbe -PythonExe $PythonExe).Version
}

# --------------------------------------------------------------------------
# Command lines that survive spaces
# --------------------------------------------------------------------------

<#
    Quote one argument the way CommandLineToArgvW will read it back. Building a
    command line by naive concatenation is exactly how a path with a space
    turns into two arguments (docs/runtime.md, "Configuration").
#>
function ConvertTo-LcArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s""]') { return $Value }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }
        if ($char -eq '"') {
            [void]$builder.Append('\' * ($backslashes * 2 + 1))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append('\' * $backslashes)
            [void]$builder.Append($char)
        }
        $backslashes = 0
    }
    [void]$builder.Append('\' * ($backslashes * 2))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-LcCommandLine {
    param([string[]]$Arguments = @())
    return (($Arguments | ForEach-Object { ConvertTo-LcArgument $_ }) -join ' ')
}

# --------------------------------------------------------------------------
# Configuration -- the seam, not a second reader
# --------------------------------------------------------------------------
#
# docs/runtime.md, "The configuration seam": there is ONE definition of what
# runtime.yaml means and it lives in the gateway. These scripts never parse
# YAML, apply no defaults, check no required keys and coerce no types. The
# configuration arrives already decided, as one JSON document, across a process
# boundary:
#
#     .venv\Scripts\python.exe -m localcanvas_gateway config --config <path>
#
# The loader is REQUIRED. A missing or failing one is a clear failure telling
# the user to run setup.ps1 -- never a fallback to a second reader, because two
# readers drift apart and the same file then gets accepted by one half of the
# project and rejected by the other. That has already happened here once.

function New-LcConfigFailure {
    param([string]$What, [string[]]$Detail = @(), [string]$Hint)
    return [pscustomobject]@{
        Ok = $false; Document = $null; What = $What; Detail = $Detail; Hint = $Hint
    }
}

function Read-LcConfig {
    <#
        Run the configuration seam and return what it said.

        Never throws: it returns { Ok; Document; What; Detail; Hint }, so the
        caller renders the loader's own words rather than inventing a message
        of its own. Ok=$false is a normal outcome -- a user's configuration is
        wrong far more often than anything here is.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$PythonExe
    )
    # Through the bounded probe boundary (T-0299), like every other external
    # executable these scripts interrogate: no interactive standard input, a
    # deadline of this probe's own, and the two output streams kept apart.
    $probe = Invoke-LcExecutableProbe -FilePath $PythonExe `
        -Arguments @('-m', 'localcanvas_gateway', 'config', '--config', $ConfigPath) `
        -Component "The gateway's configuration loader" `
        -TimeoutSeconds $script:ConfigLoaderProbeSeconds

    $ran = "$PythonExe -m localcanvas_gateway config --config $ConfigPath"

    if (-not $probe.Started) {
        return New-LcConfigFailure -What $probe.Failure `
            -Detail @("Ran: $ran") `
            -Hint 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
    }
    if ($probe.TimedOut) {
        return New-LcConfigFailure -What $probe.Failure `
            -Detail @("Ran: $ran") `
            -Hint 'Check that this interpreter is the one scripts\setup.ps1 built, and run this again.'
    }

    $exitCode = $probe.ExitCode

    # The document on one side and the loader's complaint on the other, taken
    # from two streams rather than sorted out of one merged pipeline by object
    # type. Same order as before: what the loader said on standard error, then
    # what it printed.
    $stdout = @("$($probe.StandardOutput)" -split "`r?`n")
    $stderr = @("$($probe.StandardError)" -split "`r?`n")
    $said = @($stderr + $stdout | Where-Object { $_ -and $_.Trim() })

    if ($exitCode -ne 0) {
        $joined = ($said -join "`n")
        if ($joined -match '(?i)no module named .?localcanvas_gateway') {
            return New-LcConfigFailure -What 'The LocalCanvas gateway is not installed in this environment' `
                -Detail @("Interpreter: $PythonExe") `
                -Hint 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
        }
        if ($joined -match '(?i)unrecognized arguments|invalid choice') {
            return New-LcConfigFailure -What 'This gateway does not provide the configuration command' `
                -Detail @("Ran: $ran") `
                -Hint 'Run scripts\setup.ps1 to install a current gateway into .venv.'
        }
        # The loader's own message, verbatim. It names the file, the key, what
        # was expected and what was there; nothing here can improve on it. When
        # it already came formatted as a [FAIL] block, that block is used as-is
        # rather than wrapped in a second one saying the same thing.
        $what = 'Configuration could not be loaded'
        $detail = $said
        if ($said.Count -gt 0 -and $said[0] -match '^\s*\[FAIL\]\s*(.+)$') {
            $what = $Matches[1].Trim()
            $detail = @($said | Select-Object -Skip 1 | ForEach-Object { $_.Trim() })
        }
        return New-LcConfigFailure -What $what -Detail $detail `
            -Hint 'Correct the configuration and run this again.'
    }

    $document = ($stdout -join "`n").Trim()
    if (-not $document) {
        return New-LcConfigFailure -What 'The configuration command printed nothing' `
            -Detail @("Ran: $ran") `
            -Hint 'Run scripts\setup.ps1 to reinstall the gateway into .venv.'
    }
    try {
        $parsed = $document | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return New-LcConfigFailure -What 'The configuration command did not print a JSON document' `
            -Detail (@("Ran: $ran") + @($document -split "`r?`n" | Select-Object -First 5)) `
            -Hint 'Run scripts\setup.ps1 to reinstall the gateway into .venv.'
    }
    return [pscustomobject]@{
        Ok = $true; Document = $parsed; What = ''; Detail = @(); Hint = ''
    }
}

function Test-LcHasProperty {
    <#
        Does $Object carry a property called $Name?

        Written with the indexer rather than `.PSObject.Properties.Name
        -contains ...`, because that form enumerates a collection member and
        throws under Set-StrictMode the moment the object has no properties at
        all -- which is exactly the case worth handling: an empty section in a
        document that is missing something.
    #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    try {
        return ($null -ne $Object.PSObject.Properties[$Name])
    } catch {
        return $false
    }
}

function Test-LcSeamFailure {
    <#
        Did this error come from the configuration seam rather than from
        anything the user did? A document missing a field the scripts consume
        is a version skew between the two halves, and it deserves the
        configuration exit code and a message, not a generic "unexpected".
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    return ("$($ErrorRecord.Exception.Message)".StartsWith($script:SeamFailureMarker))
}

function Get-LcSeamFailureLines {
    param([Parameter(Mandatory)]$ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message)".Substring($script:SeamFailureMarker.Length)
    return @($text -split "`r?`n" | Where-Object { $_.Trim() })
}

function Get-LcConfigValue {
    <#
        Read one dotted field out of the configuration document.

        This is not validation of the user's configuration -- that already
        happened, on the other side of the seam. It is an integrity check on
        the seam itself: a document without a field the scripts consume means
        the scripts and the gateway are out of step, and saying so is far
        better than a null propagating into a command line.
    #>
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Optional
    )
    $current = $Document
    foreach ($segment in $Path.Split('.')) {
        if (-not (Test-LcHasProperty -Object $current -Name $segment)) {
            if ($Optional) { return $null }
            $version = 'unknown'
            if (Test-LcHasProperty -Object $Document -Name 'config_version') {
                $version = [string]$Document.config_version
            }
            throw ($script:SeamFailureMarker +
                "`nThe configuration document from the gateway has no '$Path'." +
                "`nThe gateway and the runtime scripts are out of step " +
                "(document version: $version)." +
                "`nRun scripts\setup.ps1 to reinstall the gateway into .venv.")
        }
        $current = $current.$segment
    }
    return $current
}

# --------------------------------------------------------------------------
# Probing addresses (a transport concern, not a configuration one)
# --------------------------------------------------------------------------

function Get-LcProbeHost {
    # A service bound to a wildcard address is not reachable at it; it is
    # reachable on loopback, which is where a local probe belongs.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BindHost)
    if ($BindHost -in @('0.0.0.0', '::', '*', '')) { return '127.0.0.1' }
    return $BindHost
}

function Get-LcUrl {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [string]$Path = ''
    )
    $literal = if ($HostName -like '*:*' -and -not $HostName.StartsWith('[')) { "[$HostName]" } else { $HostName }
    return "http://${literal}:$Port$Path"
}

# ComfyUI's own HTTP surface: cheap, unauthenticated, on every build.
$script:ComfyHealthPath = '/system_stats'
# docs/api.md -- the identity handshake, and the gateway readiness probe.
$script:GatewayHealthPath = '/api/v1/info'

function Get-LcEndpoints {
    <#
        The URLs the scripts probe.

        ComfyUI's origin is composed on the other side of the seam and taken
        from the document as it stands -- it is the same string the gateway
        itself will talk to, and one definition of it is the point. Only the
        health path is added, which is transport and belongs here.

        The gateway's own probe address cannot come from the document: it binds
        a wildcard address far more often than not, and a wildcard is not
        something to connect to. Substituting loopback for it is a probing
        decision, and applies to nothing else.
    #>
    param([Parameter(Mandatory)]$Config)
    $comfyBase = [string](Get-LcConfigValue -Document $Config -Path 'comfy.base_url')
    $comfyHost = [string](Get-LcConfigValue -Document $Config -Path 'comfy.host')
    $gatewayBind = [string](Get-LcConfigValue -Document $Config -Path 'gateway.host')
    $gatewayHost = Get-LcProbeHost -BindHost $gatewayBind
    $gatewayPort = [int](Get-LcConfigValue -Document $Config -Path 'gateway.port')
    return [pscustomobject]@{
        ComfyBaseUrl        = $comfyBase
        ComfyHealthUrl      = ($comfyBase.TrimEnd('/') + $script:ComfyHealthPath)
        GatewayBaseUrl      = Get-LcUrl -HostName $gatewayHost -Port $gatewayPort
        GatewayHealthUrl    = Get-LcUrl -HostName $gatewayHost -Port $gatewayPort -Path $script:GatewayHealthPath
        GatewayBindsAll     = ($gatewayBind -in @('0.0.0.0', '::', '*'))
        ComfyLocalhostOnly  = ($comfyHost -in @('127.0.0.1', 'localhost', '::1'))
    }
}

# --------------------------------------------------------------------------
# Readiness -- a real HTTP probe, polled; never a sleep
# --------------------------------------------------------------------------

function Invoke-LcProbe {
    <#
        One HTTP GET. Returns a result object rather than throwing, because a
        refused connection is the expected state of a service that has not
        finished starting.

        Answered says whether anything answered at all -- an HTTP status, or a
        connection that came back with a line that is not HTTP -- as opposed
        to nothing: refused, unreachable, silent until the deadline, or closed
        before a complete answer (Test-LcProbeAnswered). "Nothing is running there" and "something else
        is running there" are different reports (T-0239).
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [double]$TimeoutSeconds = 2
    )
    $result = [pscustomobject]@{ Ok = $false; StatusCode = 0; Body = ''; Error = ''; Answered = $false }
    $client = $null
    $clock = $null
    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        # The probe's own clock, for Get-LcProbeFailureCause: under Windows
        # PowerShell 5.1 it is the only evidence that a cancellation was the
        # deadline (T-0250).
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        $result.Answered = $true
        try {
            $result.StatusCode = [int]$response.StatusCode
            $result.Ok = $response.IsSuccessStatusCode
            $result.Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $result.Ok) { $result.Error = "HTTP $($result.StatusCode)" }
        } finally {
            $response.Dispose()
        }
    } catch {
        $elapsed = if ($clock) { $clock.Elapsed.TotalSeconds } else { $null }
        $result.Error = Get-LcProbeFailureCause -Exception $_.Exception -TimeoutSeconds $TimeoutSeconds `
            -ElapsedSeconds $elapsed
        if (-not $result.Answered) {
            $result.Answered = Test-LcProbeAnswered -Exception $_.Exception
        }
    } finally {
        if ($client) { $client.Dispose() }
    }
    return $result
}

function Test-LcProbeAnswered {
    <#
        Did a request that failed get an answer that was not HTTP, rather than
        no answer at all (T-0239)? One rule, for Invoke-LcProbe and for the
        comfy doctor's websocket handshake (T-0259), so both doctors say the
        same thing about the same port.

        THE RULE (T-0266). Something else is answering only when a complete
        answer line came back and it was not HTTP. The runtime says exactly
        that in one of two ways, and nothing else counts:

          * pwsh: the innermost exception is an HttpRequestException with
            nothing beneath it -- the status line was read and refused;
          * Windows PowerShell 5.1: a WebException whose status is
            ServerProtocolViolation.

        Everything else is a check that could not be made: a refusal, a reset,
        the deadline, a TLS handshake that failed, and a connection that ended
        before a complete answer -- closed without a byte, closed inside the
        status line or the headers, or with the body cut short. Those arrive
        with something beneath the HTTP failure (an IOException, HttpIOException,
        SocketException, AuthenticationException or cancellation) or as a
        WebException with another status. A failure this cannot place is
        "nothing answered", which is what the doctors said before T-0239.

        MEASURED 2026-09-17, loopback, pwsh 7.6.6 and Windows PowerShell
        5.1.26100.9444 (PowerShell's MethodInvocationException wrapper left
        out). The plain requests ran ten times per shape per shell and were
        identical every time; the "+ LF" shape and the websocket handshakes
        twice, and https once:
          "NOT HTTP AT ALL" + CRLF CRLF, or + LF      -> something else
              pwsh: HttpRequestException (InvalidResponse), nothing beneath
              5.1:  HttpRequestException -> WebException (ServerProtocolViolation)
          accepted, request read, closed, no byte     -> could not be made
              pwsh: HttpRequestException (ResponseEnded) -> HttpIOException (ResponseEnded)
              5.1:  HttpRequestException -> WebException (ConnectionClosed)
          "HTTP/1.1 200", or headers with no blank line, then closed -> could not be made
              pwsh: the same as closed, no byte;  5.1: WebException (ConnectionClosed)
          complete headers, body cut short            -> could not be made
              pwsh: HttpRequestException (ResponseEnded) -> HttpIOException (ResponseEnded)
              5.1:  HttpRequestException -> IOException
          reset (SO_LINGER 0)                         -> could not be made
              pwsh: HttpRequestException -> IOException -> SocketException (ConnectionReset)
              5.1:  HttpRequestException -> WebException (ReceiveFailure) -> IOException -> SocketException
          refused                                     both: ... -> SocketException (ConnectionRefused)
          https:// asked of a plain HTTP port         -> could not be made
              pwsh: HttpRequestException (SecureConnectionError) -> AuthenticationException
              5.1:  HttpRequestException -> WebException (SendFailure) -> IOException
          the websocket handshake, "NOT HTTP AT ALL"  -> something else
              pwsh: WebSocketException -> HttpRequestException (InvalidResponse), nothing beneath
              5.1:  WebSocketException -> WebException (ServerProtocolViolation), no HttpRequestException
          silent past the deadline   pwsh: TaskCanceledException -> TimeoutException -> ...
                                     5.1:  TaskCanceledException, nothing beneath it

        THE LIMIT, MEASURED: bytes that are not HTTP with NO line ending, then
        a close ("NOT HTTP AT ALL", "X", ten bytes shaped like a TLS record).
        pwsh cannot tell that from a close without a byte -- same chain, same
        message:
              pwsh: HttpRequestException (ResponseEnded) -> HttpIOException (ResponseEnded)
              5.1:  HttpRequestException -> WebException (ServerProtocolViolation)
        So that one shape is "could not be made" under pwsh and "something
        else" under 5.1. It is a fact about what each runtime reports, stated
        here and not a behaviour anyone chose.
    #>
    param([Parameter(Mandatory)][System.Exception]$Exception)
    $innermost = $null
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.Net.WebException]) {
            return ([string]$current.Status -eq 'ServerProtocolViolation')
        }
        $innermost = $current
    }
    return ($innermost -is [System.Net.Http.HttpRequestException])
}

# How far short of its deadline a probe's own clock may read and a bare
# cancellation still be the deadline (T-0250). MEASURED on loopback, 20 runs
# each of a silent listener and a refused port at 0.5 s and 1 s deadlines,
# clocked around Invoke-LcProbe: the request never ended before its deadline --
# the smallest overshoot was +0.003 s under pwsh 7.6.6 and +0.007 s under
# Windows PowerShell 5.1. A tenth of a second only absorbs timer granularity
# (15.6 ms) and is far shorter than any failure that ends a request early.
$script:LcProbeDeadlineToleranceSeconds = 0.1

function Get-LcProbeFailureCause {
    <#
        What to say about a probe request that failed, out of its exception
        chain (T-0200).

          * a TimeoutException anywhere in the chain is the probe's own
            deadline -- HttpClient puts one there only when its Timeout fires
            -- and is said plainly, with the deadline, whatever follows it in
            the chain. Not the innermost "A task was canceled.", which is the
            request's bookkeeping, and not the aborted read under it;
          * otherwise a socket error -- a refused connection, an unreachable
            host, a connection reset -- is quoted in the socket layer's own
            words, as it always was;
          * anything else is quoted innermost, as before.

        MEASURED, pwsh 7.6.6 on Windows 11, loopback:
          a port nothing listens on is refused after about 2.05 s. Above that
          deadline the chain is HttpRequestException -> SocketException
          (ConnectionRefused); below it, TaskCanceledException ->
          TimeoutException -> TaskCanceledException, no socket error.
          a listener that accepts and never answers, at any deadline:
          TaskCanceledException -> TimeoutException -> TaskCanceledException
          -> IOException -> SocketException (OperationAborted). The socket
          error there is how the cancellation looks from the socket, which is
          why the deadline is decided first (T-0200, review round 2).

        UNDER WINDOWS POWERSHELL 5.1 THERE IS NO TimeoutException (T-0250).
        .NET Framework's HttpClient ends a request at its Timeout with a bare
        TaskCanceledException. MEASURED, 5.1.26100.9444, loopback, deadlines
        0.5 / 1 / 3 / 10 s: a silent listener gives MethodInvocationException ->
        TaskCanceledException and nothing beneath it, at every deadline; a
        refused port gives the same below the refusal time (about 2.05 s here)
        and HttpRequestException -> WebException -> SocketException above it.
        No refusal arrived as a bare cancellation before the deadline. So that
        chain is also the deadline, when all of these hold:
          * past PowerShell's own wrapper, the cause is a TaskCanceledException
            with nothing beneath it;
          * -ElapsedSeconds, the probe's own clock around the request, reached
            the deadline, less $script:LcProbeDeadlineToleranceSeconds;
          * nothing else cancelled it -- which is why the clock is required:
            the probe gives HttpClient no token of its own, so its Timeout is
            the only canceller it has, and a cancellation that came before the
            deadline is quoted as it is, not called the deadline. A caller
            with no clock gets no such reading.
    #>
    param(
        [Parameter(Mandatory)][System.Exception]$Exception,
        [Parameter(Mandatory)][double]$TimeoutSeconds,
        [System.Nullable[double]]$ElapsedSeconds = $null
    )
    $socket = $null
    $timedOut = $false
    $innermost = $Exception
    $cause = $null
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($null -eq $socket -and $current -is [System.Net.Sockets.SocketException]) { $socket = $current }
        if ($current -is [System.TimeoutException]) { $timedOut = $true }
        if ($null -eq $cause -and $current -isnot [System.Management.Automation.MethodInvocationException]) {
            $cause = $current
        }
        $innermost = $current
    }
    if (-not $timedOut -and $null -ne $ElapsedSeconds -and
        $cause -is [System.Threading.Tasks.TaskCanceledException] -and $null -eq $cause.InnerException -and
        $ElapsedSeconds -ge ($TimeoutSeconds - $script:LcProbeDeadlineToleranceSeconds)) {
        $timedOut = $true
    }
    if ($timedOut) {
        # Formatted invariantly, whatever the culture of the machine running it.
        $seconds = $TimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        return "No answer arrived within $seconds second(s)."
    }
    if ($null -ne $socket) { return $socket.Message }
    return $innermost.Message
}

function Test-LcGatewayIdentity {
    <#
        docs/connection.md: an arbitrary HTTP endpoint is never treated as a
        compatible gateway. Returns $true, $false, or $null when the body did
        not parse as JSON at all or names no service.

        JSON that is not an OBJECT is $false, in both shells (T-0256). The
        first character is asked, as ConvertFrom-LcDoctorJsonObject does,
        because ConvertFrom-Json enumerates a top-level array: measured, an
        array holding a gateway's answer was $true under pwsh 7.6.6 and $null
        under Windows PowerShell 5.1, and 5.1 has no -NoEnumerate.
    #>
    param([string]$Body)
    if (-not $Body) { return $null }
    try {
        $doc = $Body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not $Body.Trim().StartsWith('{')) { return $false }
    if (-not (Test-LcHasProperty -Object $doc -Name 'service')) { return $null }
    return ($doc.service -eq 'localcanvas')
}

function Wait-LcHttpReady {
    <#
        THE readiness contract. A fixed sleep is never it -- not as a
        substitute, not as a supplement that masks a failing probe. The probe
        below is polled until it succeeds or until $TimeoutSeconds elapses,
        and the only delay involved is the interval between two probes.

        Returns { Ok; ElapsedSeconds; Attempts; LastError; LastBody } and, when
        -ProcessToWatch is given, stops early with Ok=$false the moment the
        process being waited on has exited -- there is nothing left to wait for.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][double]$TimeoutSeconds,
        [System.Diagnostics.Process]$ProcessToWatch,
        [double]$ProbeTimeoutSeconds = 2
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    $lastError = ''
    $lastBody = ''
    $exited = $false
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $attempts++
        $probe = Invoke-LcProbe -Url $Url -TimeoutSeconds $ProbeTimeoutSeconds
        if ($probe.Ok) {
            $stopwatch.Stop()
            return [pscustomobject]@{
                Ok             = $true
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
                Attempts       = $attempts
                LastError      = ''
                LastBody       = $probe.Body
                ProcessExited  = $false
            }
        }
        $lastError = $probe.Error
        $lastBody = $probe.Body
        if ($ProcessToWatch) {
            $ProcessToWatch.Refresh()
            if ($ProcessToWatch.HasExited) { $exited = $true; break }
        }
        Start-Sleep -Milliseconds $script:PollIntervalMs  # poll-interval
    }
    $stopwatch.Stop()
    return [pscustomobject]@{
        Ok             = $false
        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        Attempts       = $attempts
        LastError      = $lastError
        LastBody       = $lastBody
        ProcessExited  = $exited
    }
}

# --------------------------------------------------------------------------
# Process ownership
# --------------------------------------------------------------------------
#
# A PID file alone is not proof of ownership: Windows reuses PIDs, and the
# process wearing ours tomorrow may be the user's own work. So the record
# carries the process start time and image path beside the PID, and every
# signalling path verifies all three first. A mismatch means "not ours", and
# not-ours is left alone.
#
# Nothing here ever looks a process up by name or by the port it holds.
#
# Two failures that look alike are kept apart, because the right thing to do
# with the ownership record differs:
#
#   * PROVED NOT OURS -- the PID is running a different program now. The record
#     describes a process that is gone, and dropping it is right.
#   * NOT PROVED OURS -- the identity could not be read, or was never recorded,
#     or the two start times disagree. Dropping the record here is how a
#     LocalCanvas-started ComfyUI was leaked (T-0088): the process keeps
#     running, the only evidence is destroyed, and nothing can ever reclaim it.
#     So the record is kept and the process is left alone.

function Get-LcPidFilePath {
    param([Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role)
    return (Join-Path (Get-LcRuntimePath) "$Role.pid")
}

function Get-LcProcessIdentity {
    <#
        What one live process actually is: the executable it was created from,
        when it started, and the command line it was given -- all from one
        query, addressed by PID and by nothing else.

        NOT from $process.Path or $process.MainModule.FileName. Both resolve
        through the target's *main module*, which is a different question from
        "which executable is this", and on Windows the answer comes back wrong
        rather than absent: it returned C:\WINDOWS\SYSTEM32\ntdll.dll for a
        ComfyUI that had been serving HTTP for minutes, and a wrong image path
        is indistinguishable from somebody else's process (T-0088). A wrong
        answer is worse than no answer here, because it is acted upon.

        Win32_Process answers about the process itself. Measured on Windows 11
        with PowerShell 7.6: for a live child process ExecutablePath is the
        real interpreter path, CommandLine is complete, and CreationDate agrees
        with .NET's StartTime to within one tick.

        Returns Readable=$false and a Reason when the identity cannot be read
        -- for a protected process, for instance. "Could not read" never counts
        as "matches".
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    $identity = [pscustomobject]@{
        Readable       = $false
        ExecutablePath = ''
        StartTimeUtc   = $null
        CommandLine    = ''
        Reason         = ''
    }

    $info = $null
    try {
        $info = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    } catch {
        $identity.Reason = "the identity of PID $ProcessId could not be read: $("$($_.Exception.Message)".Trim())"
        return $identity
    }
    if (-not $info) {
        $identity.Reason = "PID $ProcessId has no process record"
        return $identity
    }

    $executable = ''
    if ($info.ExecutablePath) { $executable = [string]$info.ExecutablePath }
    if (-not $executable) {
        $identity.Reason = "the executable of PID $ProcessId could not be read"
        return $identity
    }

    $started = $null
    try {
        if ($info.CreationDate) { $started = ([datetime]$info.CreationDate).ToUniversalTime() }
    } catch {
        $started = $null
    }
    if ($null -eq $started) {
        $identity.Reason = "the start time of PID $ProcessId could not be read"
        return $identity
    }

    $identity.Readable = $true
    $identity.ExecutablePath = $executable
    $identity.StartTimeUtc = $started
    if ($info.CommandLine) { $identity.CommandLine = [string]$info.CommandLine }
    return $identity
}

function Save-LcOwnedProcess {
    param(
        [Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role,
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [string]$Endpoint = '',
        [string]$CommandLine = ''
    )
    # Recorded from the SAME source the verification reads. An asymmetry here
    # is what turned a healthy process into an unrecognised one: the launch
    # side read the right value and the verification side read a module path,
    # so the two could never agree (T-0088).
    $identity = Get-LcProcessIdentity -ProcessId $Process.Id
    $imagePath = ''
    $startUtc = $null
    if ($identity.Readable) {
        $imagePath = $identity.ExecutablePath
        $startUtc = $identity.StartTimeUtc
    } else {
        # Without it, nothing later can prove this process is ours -- so say so
        # now, while there is still a terminal to say it to.
        Write-LcWarn "The identity of PID $($Process.Id) could not be read ($($identity.Reason)); LocalCanvas will not be able to prove it owns that process later."
    }
    if ($null -eq $startUtc) {
        try { $startUtc = $Process.StartTime.ToUniversalTime() } catch { $startUtc = [datetime]::MinValue }
    }
    $record = [ordered]@{
        pid          = $Process.Id
        role         = $Role
        # Ticks are the authoritative copy: a number survives a JSON
        # round-trip unchanged, whereas ConvertFrom-Json rewrites anything
        # that looks like a date into a DateTime of its own choosing.
        start_time_utc_ticks = $startUtc.Ticks
        start_time   = $startUtc.ToString('o')
        image_path   = $imagePath
        command_line = $CommandLine
        endpoint     = $Endpoint
        owned_by     = 'localcanvas'
        written_at   = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Get-LcPidFilePath -Role $Role
    Set-Content -LiteralPath $path -Value ($record | ConvertTo-Json -Depth 4) -Encoding UTF8
    return $path
}

function Remove-LcOwnedProcessRecord {
    param([Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role)
    $path = Get-LcPidFilePath -Role $Role
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-LcRecordedStartTime {
    <#
        The UTC start time an ownership record claims, or $null when it does
        not carry a usable one.

        Two representations are accepted on purpose. Ticks are what this code
        writes and the only form that survives a JSON round-trip untouched.
        The ISO string is kept for humans reading the file -- and read back as
        a fallback, because ConvertFrom-Json turns it into a DateTime before
        this function ever sees it.
    #>
    param([Parameter(Mandatory)]$Record)
    if (Test-LcHasProperty -Object $Record -Name 'start_time_utc_ticks') {
        $ticks = [long]0
        if ([long]::TryParse([string]$Record.start_time_utc_ticks, [ref]$ticks) -and $ticks -gt 0) {
            return [datetime]::new($ticks, [System.DateTimeKind]::Utc)
        }
    }
    if ((Test-LcHasProperty -Object $Record -Name 'start_time') -and $Record.start_time) {
        if ($Record.start_time -is [datetime]) {
            return ([datetime]$Record.start_time).ToUniversalTime()
        }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse(
                [string]$Record.start_time, [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return $parsed.ToUniversalTime()
        }
    }
    return $null
}

function Resolve-LcOwnedProcess {
    <#
        Answer the only question that matters before signalling anything:
        is the process this PID file names still the process we started?

        State is one of:
          none      -- no PID file: LocalCanvas owns nothing in this role.
          unreadable-- a PID file we cannot make sense of. It names no process,
                       so there is nothing to keep it for.
          stale     -- the PID names no live process. Safe to clean up.
          mismatch  -- PROVED NOT OURS: a live process wears the PID and is
                       running a different executable. That is what PID reuse
                       looks like, and the record describes a process that is
                       gone. Never signalled.
          unproven  -- NOT PROVED OURS: a live process wears the PID and
                       ownership could not be established -- the identity could
                       not be read, none was recorded, or the start times
                       disagree. Never signalled EITHER, but the record is
                       evidence and must be kept: destroying it is what leaks a
                       process LocalCanvas started (T-0088).
          running   -- verified ours: PID, start time and executable all agree.

        Ownership is PID + start time + executable identity. Never the process
        name, never the port it holds, never the PID on its own.
    #>
    param([Parameter(Mandatory)][ValidateSet('comfy', 'gateway')][string]$Role)

    $path = Get-LcPidFilePath -Role $Role
    $result = [pscustomobject]@{
        State = 'none'; Record = $null; Process = $null; PidFile = $path; Reason = ''
        Identity = $null
    }
    if (-not (Test-Path -LiteralPath $path)) { return $result }

    try {
        $record = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json
    } catch {
        $result.State = 'unreadable'
        $result.Reason = 'the PID file could not be parsed'
        return $result
    }
    $result.Record = $record
    if (-not (Test-LcHasProperty -Object $record -Name 'pid')) {
        $result.State = 'unreadable'
        $result.Reason = 'the PID file has no pid field'
        return $result
    }
    # A PID file is untrusted input like any other file on disk: a value that
    # is not a process id at all is a broken record, never a crash.
    $processId = 0
    if (-not [int]::TryParse([string]$record.pid, [ref]$processId) -or $processId -le 0) {
        $result.State = 'unreadable'
        $result.Reason = "'$($record.pid)' is not a process id"
        return $result
    }

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) {
        $result.State = 'stale'
        $result.Reason = "PID $($record.pid) is not running"
        return $result
    }

    # Identity evidence. Anything we cannot positively confirm counts against
    # ownership, never for it -- but "cannot confirm" and "confirmed to be
    # something else" are different answers with different consequences for the
    # record, so they are kept apart below.
    $identity = Get-LcProcessIdentity -ProcessId $processId
    $result.Identity = $identity
    if (-not $identity.Readable) {
        # It may have exited between the two reads; that is a stale record and
        # not an unprovable one.
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            $result.State = 'stale'
            $result.Reason = "PID $($record.pid) is not running"
            return $result
        }
        $result.State = 'unproven'
        $result.Reason = $identity.Reason
        return $result
    }

    $recordedImage = ''
    if (Test-LcHasProperty -Object $record -Name 'image_path') {
        $recordedImage = [string]$record.image_path
    }
    if (-not $recordedImage) {
        # An absent image path is not a free pass, and it is not proof against
        # us either. Ownership has to be proved, and evidence that was never
        # recorded proves nothing in either direction.
        $result.State = 'unproven'
        $result.Reason = "no image path was recorded for PID $($record.pid), so ownership cannot be proved"
        return $result
    }
    if (-not [string]::Equals($identity.ExecutablePath, $recordedImage, [StringComparison]::OrdinalIgnoreCase)) {
        # A different executable is positive proof that this is not the process
        # we started. Compared whole: two python.exe in different directories
        # are two different programs, and the file name proves nothing at all.
        $result.State = 'mismatch'
        $result.Reason = "PID $($record.pid) is running $($identity.ExecutablePath), not $recordedImage"
        return $result
    }

    $recordedStart = Get-LcRecordedStartTime -Record $record
    if ($null -eq $recordedStart) {
        $result.State = 'unproven'
        $result.Reason = "the start time recorded for PID $($record.pid) could not be read, so ownership cannot be proved"
        return $result
    }
    if ([math]::Abs(($identity.StartTimeUtc - $recordedStart).TotalSeconds) -gt 2) {
        # The executable agrees and the start time does not: most likely the
        # PID was reused by another copy of the same program. Refused all the
        # same -- but a disagreement between two clock readings is not the same
        # class of evidence as a different executable, so the record stays and
        # a later run can decide again.
        $result.State = 'unproven'
        $result.Reason = "PID $($record.pid) is running $recordedImage but started at $($identity.StartTimeUtc.ToString('o')), not at $($recordedStart.ToString('o'))"
        return $result
    }

    $result.State = 'running'
    $result.Process = $process
    return $result
}

function Stop-LcOwnedProcess {
    <#
        Stop one verified-owned process. Asks first, insists second, and never
        touches anything it has not verified. Returns a short outcome string.
    #>
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [double]$GraceSeconds = 10
    )
    $hasWindow = $false
    try { $hasWindow = ($Process.MainWindowHandle -ne [IntPtr]::Zero) } catch { $hasWindow = $false }
    if ($hasWindow) {
        # Ask before insisting -- but only where there is something to ask.
        try { [void]$Process.CloseMainWindow() } catch { }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt $GraceSeconds) {
            $Process.Refresh()
            if ($Process.HasExited) { return 'exited' }
            Start-Sleep -Milliseconds $script:PollIntervalMs  # poll-interval
        }
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $Process.Refresh()
    if ($Process.HasExited) { return 'exited' }
    Stop-Process -Id $Process.Id -Force -ErrorAction Stop
    $stopwatch.Restart()
    while ($stopwatch.Elapsed.TotalSeconds -lt $GraceSeconds) {
        $Process.Refresh()
        if ($Process.HasExited) { return 'terminated' }
        Start-Sleep -Milliseconds $script:PollIntervalMs  # poll-interval
    }
    return 'still-running'
}

# --------------------------------------------------------------------------
# The endpoint a phone would use
# --------------------------------------------------------------------------

function Get-LcLanAddress {
    <#
        Read-only. Returns the machine's most likely LAN IPv4 address, or
        $null. Nothing here changes an adapter, a route or a firewall.
    #>
    try {
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $candidate = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object {
                    $_.IPAddress -notlike '127.*' -and
                    $_.IPAddress -notlike '169.254.*' -and
                    $_.PrefixOrigin -in @('Dhcp', 'Manual')
                } |
                Sort-Object -Property @{ Expression = { $_.PrefixOrigin -eq 'Dhcp' }; Descending = $true } |
                Select-Object -First 1
            if ($candidate) { return $candidate.IPAddress }
        }
    } catch {
        # Fall through to DNS.
    }
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())
        $ipv4 = $addresses |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '127.*' -and $_.ToString() -notlike '169.254.*' } |
            Select-Object -First 1
        if ($ipv4) { return $ipv4.ToString() }
    } catch {
        # No LAN address is a reportable fact, not an error.
    }
    return $null
}

function Test-LcLoopbackHost {
    <#
        Is this host a loopback literal: an address in 127.0.0.0/8, ::1, or
        the name localhost?

        Answered from the string alone. Nothing is resolved, so a name that
        merely resolves to loopback is not caught here, and a name that merely
        starts like a loopback address (127.0.0.1.example) is not mistaken
        for one.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HostName)
    $name = $HostName.Trim()
    if ($name.StartsWith('[') -and $name.EndsWith(']')) { $name = $name.Substring(1, $name.Length - 2) }
    if ($name -ieq 'localhost') { return $true }
    $parsed = [System.Net.IPAddress]::Any
    if (-not [System.Net.IPAddress]::TryParse($name, [ref]$parsed)) { return $false }
    return [System.Net.IPAddress]::IsLoopback($parsed)
}

function Get-LcPublishedEndpoint {
    <#
        The endpoint printed for the user and passed to the gateway as
        --endpoint: the address a phone on the LAN would type.

        docs/runtime.md, "Who owns the endpoint and the pairing block": both
        halves can compute a LAN address and two answers is one too many, so
        start.ps1 decides it here and the gateway advertises and encodes
        exactly what it is given.

        When the gateway binds one specific interface, that is the answer; when
        it binds all of them, the LAN address is.

        IsLan is a claim about that answer, and it is made only where it is
        true: a gateway bound to a loopback literal is reachable from this
        machine and from nothing else, whatever LAN address the machine also
        has (T-0119).

        LocalOnlyReason says why IsLan is false, so a reader never gives one
        reason for the other (T-0224): 'loopback-bind' when gateway.host is a
        loopback literal, 'no-lan-address' when the gateway binds every
        interface and this machine has no LAN address to publish. It is $null
        when IsLan is true. Every answer carries it.

        gateway.host "[::]" is "::" written as a URL literal: the gateway
        accepts it and binds the same wildcard, so it is published as the wide
        bind it is, never as a host to type (T-0257).
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Endpoints)
    $port = [int](Get-LcConfigValue -Document $Config -Path 'gateway.port')
    $bind = [string](Get-LcConfigValue -Document $Config -Path 'gateway.host')
    if (-not ($Endpoints.GatewayBindsAll -or $bind -eq '[::]')) {
        $loopback = Test-LcLoopbackHost -HostName $bind
        return [pscustomobject]@{
            Url             = (Get-LcUrl -HostName $bind -Port $port)
            IsLan           = (-not $loopback)
            LocalOnlyReason = $(if ($loopback) { 'loopback-bind' } else { $null })
        }
    }
    $lan = Get-LcLanAddress
    if ($lan) {
        return [pscustomobject]@{
            Url = (Get-LcUrl -HostName $lan -Port $port); IsLan = $true; LocalOnlyReason = $null
        }
    }
    return [pscustomobject]@{
        Url = (Get-LcUrl -HostName '127.0.0.1' -Port $port); IsLan = $false; LocalOnlyReason = 'no-lan-address'
    }
}

function Invoke-LcGatewayQr {
    <#
        Ask the gateway to render the pairing QR for an endpoint.

        The QR and the pairing payload are the gateway's to produce -- one
        implementation, one place to test -- so this runs its `qr` command and
        returns what it printed. A failure is reported, never faked: nothing
        here builds a localcanvas:// URL of its own.

        Through the bounded probe boundary (T-0299), like the configuration
        seam and the interpreter version read. This is the call-operator site a
        user meets EVERY DAY -- it is the last thing start.ps1 does before the
        readiness block -- and the call operator is what took 38,853 ms on this
        machine once, through the shell-execute retry the probe closes off.
        A QR that cannot be drawn is a line in the readiness block; a QR that
        never comes back is a daily command that never finishes.
    #>
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$Endpoint
    )
    $probe = Invoke-LcExecutableProbe -FilePath $PythonExe `
        -Arguments @('-m', 'localcanvas_gateway', 'qr', '--endpoint', $Endpoint) `
        -Component "The gateway's pairing QR" `
        -TimeoutSeconds $script:GatewayQrProbeSeconds

    $stdout = @("$($probe.StandardOutput)" -split "`r?`n")
    $stderr = @("$($probe.StandardError)" -split "`r?`n")
    $drawn = @($stdout | Where-Object { $_ -and $_.Trim() })

    if (-not $probe.Started -or $probe.TimedOut) {
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = $probe.Failure }
    }
    if ($probe.ExitCode -ne 0 -or $drawn.Count -eq 0) {
        $reason = (@($stderr + $stdout) | Where-Object { $_ -and $_.Trim() } |
            ForEach-Object { $_.Trim() } | Select-Object -First 2) -join ' '
        if (-not $reason) { $reason = "the pairing QR command printed nothing (exit code $($probe.ExitCode))" }
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = $reason }
    }
    # Trailing blank lines only: the QR's own blank rows are inside the block
    # and are part of the picture.
    $text = ("$($probe.StandardOutput)" -replace "`r`n", "`n").TrimEnd("`n")
    return [pscustomobject]@{ Ok = $true; Text = $text; Error = '' }
}

# --------------------------------------------------------------------------
# Is anybody there? (T-0322)
# --------------------------------------------------------------------------
#
# start.ps1 is the one command a user runs daily, and one of the things it may
# have to do is ask a question. A question is only ever asked of a session that
# can answer one, and deciding that is a measurement rather than an assumption.

function Test-LcInteractiveSession {
    <#
        Is a person sitting at this session, able to answer a question?

        ASKED BEFORE Read-Host IS EVER REACHED, and that ordering is the whole
        point. This repository's convention for a question is Read-Host inside
        try/catch with a switch that pre-answers it (comfy\lib\Models.ps1,
        scripts\strict-lan.ps1), and the catch is a real guard: under
        `pwsh -NonInteractive` Read-Host throws instead of reading. But a catch
        cannot save a session whose standard input is an OPEN pipe that nobody
        will ever write to -- a scheduled task, a CI step, a parent process
        holding the handle. There Read-Host does not throw. It BLOCKS, with no
        deadline and no way out, and a daily command that stops for ever is
        worse than one that asks nothing at all. So the console is asked first
        and Read-Host is reached only when the answer here is yes.

        [Console]::IsInputRedirected is the measurement and not a guess.
        MEASURED on this machine, over pwsh started with standard input from
        NUL, from a pipe holding text, from an empty pipe, with -NonInteractive
        and without it: $true in every one of them. It is $false only when
        standard input really is a console -- a terminal somebody typed the
        command into, which is exactly the session this function exists to
        recognise.

        [Environment]::UserInteractive is consulted second, and deliberately
        second: measured, it stays $true under -NonInteractive with every
        stream redirected, so on its own it settles nothing. It is $false in a
        Windows service, which is a session with no console to redirect in the
        first place, and that is the one thing it is asked about.
    #>
    try {
        if ([Console]::IsInputRedirected) { return $false }
        return [bool][Environment]::UserInteractive
    } catch {
        # A host that will not answer this question is a host that cannot be
        # asked one either.
        return $false
    }
}

function Read-LcConsoleAnswer {
    <#
        The one Read-Host on the runtime startup path, and it is never reached
        except behind Test-LcInteractiveSession.

        $null means this session could not be asked -- never '', which is a
        real answer a person gave by pressing Enter. The two must not be the
        same value: "the default was accepted" and "nobody was there" lead to
        opposite behaviour everywhere this is used.
    #>
    param([Parameter(Mandatory)][string]$Prompt)
    try {
        return [string](Read-Host $Prompt)
    } catch {
        return $null
    }
}

function Request-LcYesNo {
    <#
        One [Y/n] question, default yes, asked only of a session that can
        answer it.

        Returns { Answer; Asked }, where Answer is 'yes', 'no' or 'unasked'.
        Three values and not a boolean, because the caller of every such
        question here has three things to do: act, do not act, and say what it
        is doing instead of asking.

        -PreAnswered is the switch form of the same yes, and it skips the
        question rather than answering it: that is the shape comfy\lib\Models.ps1
        and scripts\strict-lan.ps1 already use, and a user who has learned one
        of them has learned all three.

        An answer that is neither empty nor yes is a NO. This question stands in
        front of a mutation, and a mutation is not something to perform on an
        answer nobody could read; the prompt says [Y/n], so the default is
        reached by pressing Enter and not by typing something unrecognised.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [switch]$PreAnswered
    )
    if ($PreAnswered) {
        return [pscustomobject]@{ Answer = 'yes'; Asked = $false }
    }
    if (-not (Test-LcInteractiveSession)) {
        return [pscustomobject]@{ Answer = 'unasked'; Asked = $false }
    }
    $answer = Read-LcConsoleAnswer -Prompt "$Question [Y/n]"
    if ($null -eq $answer) {
        # The host refused the prompt after all -- a -NonInteractive session
        # attached to a real console is exactly that shape.
        return [pscustomobject]@{ Answer = 'unasked'; Asked = $false }
    }
    $said = "$answer".Trim().ToLowerInvariant()
    if ($said -eq '' -or $said -eq 'y' -or $said -eq 'yes') {
        return [pscustomobject]@{ Answer = 'yes'; Asked = $true }
    }
    return [pscustomobject]@{ Answer = 'no'; Asked = $true }
}

# --------------------------------------------------------------------------
# The cheap workflow-change check (T-0322)
# --------------------------------------------------------------------------
#
# What a user's workflow folder is now, compared with what LocalCanvas recorded
# last time. Cheap means two things exactly, and both are structural rather
# than a matter of care:
#
#   --dry-run    the engine writes nothing at all -- no inventory, no
#                definition, no imported graph, no conversion snapshot;
#   --no-convert the engine is given NO conversion bridge, so the one line that
#                can reach ComfyUI (bridge.ensure_identity, reached only from
#                _convert) is never reached for this run. _examine, which
#                hashes, runs before _convert, so a full classification is had
#                with zero ComfyUI contact.
#
# Both are set here and neither is a parameter, because a caller that could
# leave one out is a caller that eventually will. The measured requirement of
# this card is that an unchanged tree costs ZERO native conversions, and this
# is the line where that is true or not.
#
# Identity is the engine's own and is content-based: content_hash is sha256
# over the raw source bytes and canonical_hash over the same document with its
# keys sorted, both already recorded per entry in the inventory. No mtime is
# recorded anywhere in the sync package, and nothing here invents one.

function Get-LcWorkflowSourcesPath {
    # Where the curator's configuration lives in the shipped layout. Named, not
    # created, and not read here: these scripts parse no YAML (docs/runtime.md,
    # "The configuration seam").
    return (Join-Path (Get-LcRepoRoot) 'config\local\workflow-sources.yaml')
}

function Get-LcWorkflowCatalogueCount {
    <#
        How many workflow definitions the gateway would serve out of a registry
        root -- which is what "a valid catalogue" means on the path where the
        check itself could not run.

        READ ONLY, and that is not decoration: status.ps1 established that a
        path which only reports must not bring a directory into existence, and
        a registry root that is not there is an answer (zero), never something
        to create. The shape mirrors the gateway's own loader
        (workflows/registry.py:110-118): recursive, .yaml and .yml,
        case-insensitively; a file whose name begins with a dot is not a
        definition, and NEITHER IS ANYTHING INSIDE A DIRECTORY whose name
        begins with one -- the loader prunes those directories from its walk,
        so a `.git` or `.trash` folder full of yaml would make this count
        definitions the gateway will never serve.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Registry)
    if (-not $Registry) { return 0 }
    if (-not (Test-Path -LiteralPath $Registry -PathType Container)) { return 0 }
    try {
        $root = (Resolve-Path -LiteralPath $Registry).Path.TrimEnd('\', '/')
        $found = 0
        foreach ($file in (Get-ChildItem -LiteralPath $Registry -File -Recurse -ErrorAction Stop)) {
            if ($file.Name.StartsWith('.')) { continue }
            if (@('.yaml', '.yml') -notcontains $file.Extension.ToLowerInvariant()) { continue }
            # Every directory name between the root and this file. Split with
            # the regex operator rather than String.Split: measured, passing
            # an array of two separators to that method matched neither and
            # returned the whole path as one part, so the rule silently did
            # nothing.
            $between = @(($file.FullName.Substring($root.Length) -split '[\\/]+') |
                Where-Object { $_ } | Select-Object -SkipLast 1)
            if (@($between | Where-Object { $_.StartsWith('.') }).Count -gt 0) { continue }
            $found++
        }
        return $found
    } catch {
        # A registry root that cannot be read is not a catalogue anything here
        # can promise the user something about.
        return 0
    }
}

function New-LcWorkflowCheckResult {
    <#
        ElapsedMs is THE WHOLE CHECK -- the child process, the pipe drain, and
        every line of script-side work after it -- and not the probe's own
        number. It is measured that way because it is printed to the user, and
        a figure that leaves out more than half of what they waited for is not
        a measurement of anything (T-0322 review, D1: at 250 workflows the
        probe reported 4701 ms of an 8120 ms check).
    #>
    param(
        [bool]$Ok = $false,
        [string]$What = '',
        [string[]]$Detail = @(),
        [string]$Fix = '',
        [int]$ElapsedMs = 0
    )
    return [pscustomobject]@{
        Ok        = $Ok
        New       = 0
        Changed   = 0
        Retry     = 0
        Removed   = 0
        Unchanged = 0
        Attention = 0
        Total     = 0
        Changes   = 0
        What      = $What
        Detail    = $Detail
        Fix       = $Fix
        ElapsedMs = $ElapsedMs
    }
}

function Invoke-LcWorkflowCheck {
    <#
        Classify the configured workflow sources against the last run, writing
        nothing and contacting ComfyUI not at all.

        Never throws. It returns the result object above, and Ok=$false is a
        normal outcome the caller decides what to do about: a check that could
        not run is not a reason to refuse to start LocalCanvas when there is a
        catalogue to start on.

        THE ENGINE'S EXIT CODES ARE NOT THE SCRIPT'S. This talks to
        `python -m localcanvas_gateway.workflows sync` directly, where 0 means
        "ran, nothing needs attention", 1 means "ran, something does" and 2
        means "could not run at all". Both 0 and 1 are a check that RAN -- an
        editor-format workflow makes every --no-convert run say 1 for ever, and
        a startup that read that as a failure would be unusable. It is
        scripts\sync-workflows.ps1 that turns attention into exit 3, and whose
        own 1 means unexpected; that translation belongs to the script, is
        keyed on there, and is not repeated here.

        WHAT THIS FUNCTION MAY NOT DO TO THE WHOLE REPORT, and it is not a
        style point (T-0322 review, D1). The engine's document is one JSON
        object describing every workflow in the folder: MEASURED at 250
        workflows it is 7.8 MB and 241,808 lines. Splitting it into lines and
        trimming each of them cost 3874 ms of an 8120 ms check -- and every
        reader of that split is in the failure branch below, where standard
        output is normally EMPTY. The expensive case was exactly the case that
        threw the value away. So the split is built INSIDE that branch and
        nowhere else, and the only whole-document work a successful check does
        is the one ConvertFrom-Json it cannot avoid.
    #>
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$SourcesConfig,
        [Parameter(Mandatory)][string]$RuntimeConfig
    )

    # The whole check, not the child process: see New-LcWorkflowCheckResult.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    $probe = Invoke-LcExecutableProbe -FilePath $PythonExe `
        -Arguments @(
            '-m', 'localcanvas_gateway.workflows', 'sync',
            '--config', $SourcesConfig,
            '--runtime-config', $RuntimeConfig,
            '--dry-run',
            '--no-convert') `
        -Component 'The workflow check' `
        -TimeoutSeconds $script:WorkflowCheckProbeSeconds

    if (-not $probe.Started -or $probe.TimedOut) {
        return New-LcWorkflowCheckResult -What 'LocalCanvas could not check your workflow folder' `
            -Detail @($probe.Failure) `
            -Fix 'Run scripts\setup.ps1 to (re)install the gateway into .venv.' `
            -ElapsedMs ([int]$watch.Elapsed.TotalMilliseconds)
    }
    if ($probe.ExitCode -ne 0 -and $probe.ExitCode -ne 1) {
        # HERE, and only here. This branch is reached when the engine failed
        # before it printed a document, so what it said is a handful of [FAIL]
        # lines rather than a report of every workflow on the disk.
        $said = @(@("$($probe.StandardError)" -split "`r?`n") +
            @("$($probe.StandardOutput)" -split "`r?`n") |
            Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
        $what = 'LocalCanvas could not check your workflow folder'
        $detail = $said
        if ($said.Count -gt 0 -and $said[0] -match '^\s*\[FAIL\]\s*(.+)$') {
            $what = $Matches[1].Trim()
            $detail = @($said | Select-Object -Skip 1)
        }
        return New-LcWorkflowCheckResult -What $what -Detail $detail `
            -Fix 'Run: pwsh .\scripts\sync-workflows.ps1 -DryRun   to see the whole report.' `
            -ElapsedMs ([int]$watch.Elapsed.TotalMilliseconds)
    }

    $document = ("$($probe.StandardOutput)").Trim()
    if (-not $document) {
        return New-LcWorkflowCheckResult -What 'The workflow check printed nothing' `
            -Detail @("Ran: $($probe.Command)") `
            -Fix 'Run scripts\setup.ps1 to reinstall the gateway into .venv.' `
            -ElapsedMs ([int]$watch.Elapsed.TotalMilliseconds)
    }
    try {
        $report = $document | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return New-LcWorkflowCheckResult -What 'The workflow check did not print a JSON document' `
            -Detail @($document -split "`r?`n" | Select-Object -First 3) `
            -Fix 'Run scripts\setup.ps1 to reinstall the gateway into .venv.' `
            -ElapsedMs ([int]$watch.Elapsed.TotalMilliseconds)
    }

    # Every read through Test-LcHasProperty: Set-StrictMode -Version Latest is
    # on, and which keys a document carries depends on the gateway installed in
    # .venv, which this script does not get to assume.
    $counts = $null
    if (Test-LcHasProperty -Object $report -Name 'counts') { $counts = $report.counts }
    if ($null -eq $counts) {
        return New-LcWorkflowCheckResult -What 'The workflow check did not say what it found' `
            -Detail @('Its report carried no counts, so the gateway and the runtime scripts are out of step.') `
            -Fix 'Run scripts\setup.ps1 to install a current gateway into .venv.' `
            -ElapsedMs ([int]$watch.Elapsed.TotalMilliseconds)
    }
    $count = {
        param($Name)
        if (Test-LcHasProperty -Object $counts -Name $Name) { return [int]$counts.$Name }
        return 0
    }

    # EDITOR-FORMAT WORKFLOWS (T-0350). What ComfyUI's Save writes is a canvas,
    # and this run converts nothing, so the engine reports every canvas as
    # NEEDS_API_EXPORT. Its `unconverted_editor` block says what the inventory
    # knows about each of them instead: new, edited, imported before and
    # untouched, not converted last time for a reason that was not the file's
    # (no browser, ComfyUI or its frontend not ready -- `retry`), or still
    # needing a look. So a canvas somebody just saved is counted -- and
    # offered -- exactly like an API export, one whose conversion could not
    # even be attempted is offered again, and one the last sync imported is
    # not reported again on every start. A gateway that predates the block
    # reads as zeroes, which is the old behaviour.
    $editor = $null
    if (Test-LcHasProperty -Object $report -Name 'unconverted_editor') {
        $editor = $report.unconverted_editor
    }
    $editorCount = {
        param($Name)
        if ($null -ne $editor -and (Test-LcHasProperty -Object $editor -Name $Name)) {
            return [int]$editor.$Name
        }
        return 0
    }
    $editorNew = & $editorCount 'new'
    $editorChanged = & $editorCount 'changed'
    $editorUnchanged = & $editorCount 'unchanged'
    $editorRetry = & $editorCount 'retry'

    $result = New-LcWorkflowCheckResult -Ok $true
    $result.New = (& $count 'NEW') + $editorNew
    $result.Changed = (& $count 'CHANGED') + $editorChanged
    $result.Removed = & $count 'REMOVED_FROM_SOURCE'
    $result.Unchanged = (& $count 'UNCHANGED') + $editorUnchanged
    $result.Retry = $editorRetry
    # The canvases counted above are taken back out of NEEDS_API_EXPORT, so
    # none is counted twice; what is left there is one that still needs a look.
    $result.Attention = (& $count 'INVALID') +
        [Math]::Max(0, (& $count 'NEEDS_API_EXPORT') - $editorNew - $editorChanged -
            $editorUnchanged - $editorRetry) +
        (& $count 'NEEDS_REVIEW') + (& $count 'UNSUPPORTED_INPUT')
    $result.Total = $result.New + $result.Changed + $result.Retry + $result.Unchanged +
        $result.Attention + (& $count 'EXACT_DUPLICATE')

    # WHAT COUNTS AS A CHANGE, and it is two numbers rather than four.
    #
    # NEW and CHANGED are what a sync would pick up, and they are what the
    # question in front of a sync is about. They are COUNTED, never inferred
    # from "would this run have written something": a definition can be
    # rewritten for an UNCHANGED workflow when the importer has learned to read
    # it differently (engine.py, REWRITTEN_NOTICE), and a check keyed on that
    # would ask to sync a folder nobody had touched.
    #
    # REMOVED_FROM_SOURCE is reported and is deliberately NOT a change here. A
    # removal is carried forward in the inventory on every run until the user
    # acts on it (engine.py, _carry_forward), so a question keyed on it would
    # be asked at every single start, for ever, about the same file -- and
    # answering yes could not make it stop, because nothing deletes the entry.
    # It is said once per start, in the summary line, and never turned into a
    # prompt.
    #
    # A canvas whose last conversion could not even be attempted (Retry) is a
    # change in the same sense: a sync would pick it up, and the reason it was
    # not picked up last time was the machine, not the file (T-0350).
    $result.Changes = $result.New + $result.Changed + $result.Retry

    # Last, so that the number handed back -- and printed -- is everything the
    # user waited for and not the part of it that happened in another process.
    $result.ElapsedMs = [int]$watch.Elapsed.TotalMilliseconds
    return $result
}

function Format-LcWorkflowChangeSummary {
    <#
        New / Changed / Removed on one line. A zero is left out: this line is
        read at a glance on every start, and "0 removed" is noise on a folder
        nobody has removed anything from.
    #>
    param([Parameter(Mandatory)]$Check)
    $parts = @()
    if ($Check.New -gt 0) { $parts += "$($Check.New) new" }
    if ($Check.Changed -gt 0) { $parts += "$($Check.Changed) changed" }
    if ((Test-LcHasProperty -Object $Check -Name 'Retry') -and $Check.Retry -gt 0) {
        $parts += "$($Check.Retry) not converted last time"
    }
    if ($Check.Removed -gt 0) { $parts += "$($Check.Removed) no longer in your folder" }
    if ($parts.Count -eq 0) { return 'nothing new, nothing changed' }
    return ($parts -join ', ')
}
