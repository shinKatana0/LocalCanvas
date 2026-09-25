using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>The script runner against real PowerShell 7 and small scripts of the test's own.</summary>
public sealed partial class ScriptRunnerTests : IDisposable
{
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc runner o'root");
    private readonly MemoryLog _log = new();

    public ScriptRunnerTests()
    {
        Directory.CreateDirectory(Path.Combine(_root, "scripts"));
        Write("echo.ps1", """
            param([string]$Name, [switch]$Flag, [switch]$Json)
            $stdin = [Console]::In.ReadToEnd()
            [Console]::Error.WriteLine('[INFO] a human line')
            @{ result_version = 1; ok = $true; exit_code = 0; error = $null; name = $Name; flag = [bool]$Flag; json = [bool]$Json; stdin = $stdin; root = $PSScriptRoot } | ConvertTo-Json -Compress
            exit 0
            """);
        Write("fails.ps1", """
            param([switch]$Json)
            @{ result_version = 1; ok = $false; exit_code = 5; error = @{ what = 'Port 1 is already in use'; detail = 'Probed'; fix = 'Stop it' } } | ConvertTo-Json -Compress
            exit 5
            """);
        Write("garbage.ps1", "param([switch]$Json)\nWrite-Output 'this is not JSON'\nexit 0\n");
        Write("two.ps1", "param([switch]$Json)\nWrite-Output '{\"ok\":true}'\nWrite-Output '{\"ok\":true}'\nexit 0\n");
        Write("array.ps1", "param([switch]$Json)\nWrite-Output '[1,2]'\nexit 0\n");
        Write("silent.ps1", "param([switch]$Json)\nexit 0\n");
        Write("crash.ps1", "param([switch]$Json)\n$ErrorActionPreference = 'Stop'\nthrow 'boom'\n");
        Write("slow.ps1", "param([switch]$Json)\nStart-Sleep -Seconds 120\n");
    }

    private void Write(string name, string text) => File.WriteAllText(Path.Combine(_root, "scripts", name), text);

    private PwshScriptRunner Runner()
    {
        var pwsh = TestEnvironment.Pwsh;
        Assert.SkipWhen(pwsh is null, "PowerShell 7 is not installed, so the runner was NOT exercised against a real pwsh.");
        return new PwshScriptRunner(pwsh!, _root, new HiddenProcessRunner(), _log);
    }

    [Fact]
    public void The_command_line_is_the_documented_one()
    {
        var arguments = PwshScriptRunner.BuildArguments(@"X:\Local Canvas", new ScriptCall("start.ps1", ["-Component", "Gateway"], TimeSpan.FromSeconds(1)));
        Assert.Equal(
            ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", @"X:\Local Canvas\scripts\start.ps1", "-Component", "Gateway", "-Json"],
            arguments);
    }

    [Fact]
    public async Task One_JSON_document_is_parsed_arguments_arrive_whole_and_stdin_is_closed()
    {
        var clock = Stopwatch.StartNew();
        var outcome = await Runner().RunAsync(new ScriptCall("echo.ps1", ["-Name", "a b 'c'", "-Flag"], TimeSpan.FromSeconds(60)));
        clock.Stop();

        Assert.Equal(ScriptFailure.None, outcome.Failure);
        Assert.True(outcome.HasDocument);
        var document = outcome.Document!.Value;
        Assert.Equal("a b 'c'", document.GetProperty("name").GetString());
        Assert.True(document.GetProperty("flag").GetBoolean());
        Assert.True(document.GetProperty("json").GetBoolean());
        // Standard input was closed at once: reading it to the end returned nothing and did not wait.
        Assert.Equal(string.Empty, document.GetProperty("stdin").GetString());
        Assert.Equal(Path.Combine(_root, "scripts"), document.GetProperty("root").GetString());
        Assert.Equal(0, outcome.ExitCode);
        Assert.Contains("[INFO] a human line", outcome.StandardError);
        // Every call is in the log, with its exit code and duration, and its stderr.
        Assert.Contains(_log.Lines, line => line.StartsWith("script: echo.ps1 -Name a b 'c' -Flag -Json", StringComparison.Ordinal));
        Assert.Contains(_log.Lines, line => ExitLine().IsMatch(line));
        Assert.Contains(_log.Lines, line => line.Contains("[INFO] a human line", StringComparison.Ordinal));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(50));
    }

    [Fact]
    public async Task A_failure_document_is_a_document_with_its_error()
    {
        var outcome = await Runner().RunAsync(new ScriptCall("fails.ps1", [], TimeSpan.FromSeconds(60)));
        Assert.True(outcome.HasDocument);
        Assert.Equal(5, outcome.ExitCode);
        var envelope = ScriptEnvelope.Read(outcome.Document!.Value);
        Assert.False(envelope.Ok);
        Assert.Equal("Port 1 is already in use", envelope.Error!.What);
    }

    [Theory]
    [InlineData("garbage.ps1")]
    [InlineData("two.ps1")]
    [InlineData("array.ps1")]
    [InlineData("silent.ps1")]
    [InlineData("crash.ps1")]
    public async Task Anything_but_exactly_one_JSON_object_is_a_failure(string script)
    {
        var outcome = await Runner().RunAsync(new ScriptCall(script, [], TimeSpan.FromSeconds(60)));
        Assert.Equal(ScriptFailure.NoDocument, outcome.Failure);
        Assert.False(outcome.HasDocument);
        Assert.NotEmpty(outcome.DescribeFailure());
    }

    [Fact]
    public async Task A_missing_pwsh_is_a_failure()
    {
        var runner = new PwshScriptRunner(Path.Combine(_root, "no such pwsh.exe"), _root, new HiddenProcessRunner(), _log);
        var outcome = await runner.RunAsync(new ScriptCall("echo.ps1", [], TimeSpan.FromSeconds(10)));
        Assert.Equal(ScriptFailure.NotStarted, outcome.Failure);
    }

    [Fact]
    public async Task A_script_past_its_timeout_is_a_failure_and_is_left_running()
    {
        var outcome = await Runner().RunAsync(new ScriptCall("slow.ps1", [], TimeSpan.FromSeconds(3)));
        Assert.Equal(ScriptFailure.TimedOut, outcome.Failure);
        var pid = int.Parse(PidOf().Match(outcome.FailureDetail ?? string.Empty).Groups[1].Value, CultureInfo.InvariantCulture);
        try
        {
            // The launcher never ends a process: the one it timed out on is still there.
            using var survivor = Process.GetProcessById(pid);
            Assert.False(survivor.HasExited);
            Assert.Contains(_log.Lines, line => line.Contains($"PID {pid} left running", StringComparison.Ordinal));
        }
        finally
        {
            // This test's own pwsh, stopped by the exact PID it was started with.
            try
            {
                using var own = Process.GetProcessById(pid);
                own.Kill();
                own.WaitForExit(10_000);
            }
            catch (ArgumentException)
            {
            }
        }
    }

    public void Dispose() => TestEnvironment.RemoveDirectory(_root);

    [GeneratedRegex(@"^script: echo\.ps1 exit 0 in \d+ ms \(document\)$")]
    private static partial Regex ExitLine();

    [GeneratedRegex(@"PID (\d+)")]
    private static partial Regex PidOf();
}
