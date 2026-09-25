using System.Diagnostics;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

public sealed class SingleInstanceTests
{
    private static (string Mutex, string Show) Names()
    {
        var unique = Guid.NewGuid().ToString("N");
        return ($@"Local\LocalCanvas.Test.{unique}", $@"Local\LocalCanvas.Test.{unique}.Show");
    }

    private static T OnOtherThread<T>(Func<T> work)
    {
        T result = default!;
        var thread = new Thread(() => result = work());
        thread.Start();
        thread.Join();
        return result;
    }

    [Fact]
    public void The_first_claim_is_primary_and_a_second_is_not()
    {
        var (mutex, show) = Names();
        using var first = SingleInstance.Acquire(mutex, show);
        Assert.True(first.IsPrimary);
        Assert.False(first.WasAbandoned);
        var secondIsPrimary = OnOtherThread(() =>
        {
            using var second = SingleInstance.Acquire(mutex, show);
            return second.IsPrimary;
        });
        Assert.False(secondIsPrimary);
    }

    [Fact]
    public void An_abandoned_claim_is_taken_over()
    {
        var (mutex, show) = Names();
        // A holder that ends without releasing: its thread exits while it owns the mutex.
        SingleInstance? crashed = null;
        var holder = new Thread(() => crashed = SingleInstance.Acquire(mutex, show));
        holder.Start();
        holder.Join();
        Assert.True(crashed!.IsPrimary);

        using var next = SingleInstance.Acquire(mutex, show);
        Assert.True(next.IsPrimary);
        Assert.True(next.WasAbandoned);
        GC.KeepAlive(crashed);
    }

    [Fact]
    public void A_second_launch_signals_the_first()
    {
        var (mutex, show) = Names();
        using var first = SingleInstance.Acquire(mutex, show);
        using var signalled = new ManualResetEventSlim();
        first.StartListening(signalled.Set);

        Assert.True(OnOtherThread(() => SingleInstance.SignalPrimary(TimeSpan.FromSeconds(2), show)));
        Assert.True(signalled.Wait(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void Released_on_dispose_so_the_next_launch_is_primary()
    {
        var (mutex, show) = Names();
        var first = SingleInstance.Acquire(mutex, show);
        first.Dispose();
        var nextIsPrimary = OnOtherThread(() =>
        {
            using var next = SingleInstance.Acquire(mutex, show);
            return next.IsPrimary && !next.WasAbandoned;
        });
        Assert.True(nextIsPrimary);
    }
}

/// <summary>Two real LocalCanvas.exe processes, against a root of fake scripts that log every call.</summary>
[Collection(RealProcesses.Name)]
public sealed class TwoLaunchesTests : IDisposable
{
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc two launches");
    private readonly List<Process> _launched = [];

    [Fact]
    public async Task The_second_launch_signals_the_first_exits_and_runs_no_script()
    {
        Assert.SkipWhen(TestEnvironment.Pwsh is null, "PowerShell 7 is not installed, so two launches were NOT run.");
        Assert.SkipWhen(Mutex.TryOpenExisting(SingleInstance.DefaultMutexName, out var existing) && Dispose(existing),
            "A LocalCanvas launcher is already running in this session, so the single-instance rule was NOT exercised (the test would only signal it).");
        var exe = Path.Combine(AppContext.BaseDirectory, "LocalCanvas.exe");
        Assert.True(File.Exists(exe), exe);

        await using var gateway = new LoopbackServer(path => path switch
        {
            "/api/v1/info" => LoopbackServer.Info(FakeScriptsRoot.Instance),
            "/system_stats" => LoopbackServer.Json("{\"system\":{}}"),
            "/api/v1/workflows" => LoopbackServer.Json("{\"workflows\":[]}"),
            _ => LoopbackServer.Json("{}", 404),
        });
        FakeScriptsRoot.Create(_root, gateway.Port);
        var calls = Path.Combine(_root, "calls.log");
        var log = Path.Combine(_root, ".runtime", "launcher.log");

        var first = Launch(exe);
        await WaitUntilAsync(() => File.Exists(log) && File.ReadAllText(log).Contains("-> Ready", StringComparison.Ordinal), 90,
            () => "the first launch to reach Ready. Log:\n" + (File.Exists(log) ? File.ReadAllText(log) : "(none)"));
        var callsBefore = File.ReadAllLines(calls);
        Assert.Contains(callsBefore, line => line.StartsWith("start.ps1 -Component Gateway", StringComparison.Ordinal));

        var second = Launch(exe);
        Assert.True(second.WaitForExit(20_000), "the second launch did not exit");
        Assert.Equal(0, second.ExitCode);
        await WaitUntilAsync(() => File.ReadAllText(log).Contains("a second launch asked to show the status window", StringComparison.Ordinal), 20,
            () => "the first launch to hear the signal. Log:\n" + File.ReadAllText(log));

        Assert.Equal(callsBefore, File.ReadAllLines(calls));
        Assert.Single(File.ReadAllLines(log), line => line.Contains("launcher: LocalCanvas ", StringComparison.Ordinal) && line.Contains(" started, PID ", StringComparison.Ordinal));
        Assert.False(first.HasExited);
    }

    private static bool Dispose(Mutex mutex)
    {
        mutex.Dispose();
        return true;
    }

    private Process Launch(string exe)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false };
        info.ArgumentList.Add("--root");
        info.ArgumentList.Add(_root);
        info.Environment.Remove("LOCALCANVAS_RUNTIME_DIR");
        var process = Process.Start(info)!;
        _launched.Add(process);
        return process;
    }

    private static async Task WaitUntilAsync(Func<bool> condition, int seconds, Func<string> what)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            try
            {
                if (condition())
                {
                    return;
                }
            }
            catch (IOException)
            {
            }
            await Task.Delay(200);
        }
        Assert.Fail("Timed out waiting for " + what());
    }

    public void Dispose()
    {
        // The launches this test started, by their exact PIDs. The fake scripts start nothing.
        foreach (var process in _launched)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(10_000);
                }
            }
            catch (InvalidOperationException)
            {
            }
            process.Dispose();
        }
        TestEnvironment.RemoveDirectory(_root);
    }
}

[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class RealProcesses
{
    public const string Name = "real processes";
}

/// <summary>A LocalCanvas folder whose scripts only print documents and log that they were called.</summary>
internal static class FakeScriptsRoot
{
    public const string Instance = "11112222333344445555666677778888";

    public static void Create(string root, int gatewayPort)
    {
        TestEnvironment.AssertNotALivePort(gatewayPort);
        var scripts = Path.Combine(root, "scripts");
        Directory.CreateDirectory(scripts);
        Directory.CreateDirectory(Path.Combine(root, ".venv", "Scripts"));
        File.WriteAllText(Path.Combine(root, ".venv", "Scripts", "python.exe"), string.Empty);
        Directory.CreateDirectory(Path.Combine(root, "config", "local"));
        File.WriteAllText(Path.Combine(root, "config", "local", "runtime.yaml"), "# not read by these scripts\n");

        const string log = "Add-Content -LiteralPath (Join-Path $PSScriptRoot '..\\calls.log') -Value (($MyInvocation.MyCommand.Name + ' ' + ($args -join ' ')).Trim())\n";
        File.WriteAllText(Path.Combine(scripts, "status.ps1"),
            log + "Write-Output '{\"result_version\":1,\"ok\":true,\"exit_code\":0,\"error\":null,\"config_ok\":true}'\nexit 0\n");
        File.WriteAllText(Path.Combine(scripts, "start.ps1"), log +
            "if ($args -contains 'Comfy') {\n" +
            $"  Write-Output '{{\"result_version\":1,\"ok\":true,\"exit_code\":0,\"error\":null,\"component\":\"Comfy\",\"comfy\":{{\"status\":\"ready\",\"url\":\"http://127.0.0.1:{gatewayPort}\",\"ownership\":\"external\",\"pid\":null}},\"gateway\":{{\"status\":\"skipped\"}},\"workflows\":null}}'\n" +
            "} else {\n" +
            $"  Write-Output '{{\"result_version\":1,\"ok\":true,\"exit_code\":0,\"error\":null,\"component\":\"Gateway\",\"comfy\":{{\"status\":\"skipped\"}},\"gateway\":{{\"status\":\"ready\",\"probe_url\":\"http://127.0.0.1:{gatewayPort}/api/v1/info\",\"instance_id\":\"{Instance}\",\"pid\":1,\"published_endpoint\":\"http://127.0.0.1:{gatewayPort}\",\"is_lan\":false,\"local_only_reason\":\"loopback-bind\"}},\"workflows\":null}}'\n" +
            "}\nexit 0\n");
        File.WriteAllText(Path.Combine(scripts, "stop.ps1"), log +
            "Write-Output '{\"result_version\":1,\"ok\":true,\"exit_code\":0,\"error\":null,\"component\":\"All\",\"roles\":{\"gateway\":{\"state_before\":\"none\",\"action\":\"none\",\"result\":null,\"pid\":null},\"comfy\":{\"state_before\":\"none\",\"action\":\"none\",\"result\":null,\"pid\":null}}}'\nexit 0\n");
        File.WriteAllText(Path.Combine(scripts, "setup.ps1"), log + "exit 0\n");
    }
}
