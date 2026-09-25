using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// A throwaway copy of the LocalCanvas folder -- the real scripts, a real
/// <c>.venv</c> made from a real Python, and the scripts' own stub Gateway and
/// stub ComfyUI -- driven by the real controller, script runner and health
/// probe. Ephemeral loopback ports only; the path has a space and an
/// apostrophe in it.
/// </summary>
internal sealed partial class StubbedLocalCanvas : IAsyncDisposable
{
    private readonly DateTime _created = DateTime.Now;
    private readonly List<int> _ownPids = [];

    public StubbedLocalCanvas(bool manageComfy)
    {
        Python = TestEnvironment.Python!;
        Pwsh = TestEnvironment.Pwsh!;
        Scratch = TestEnvironment.NewScratchDirectory("lc e2e");
        Root = Path.Combine(Scratch, "Local Canvas o'root");
        Directory.CreateDirectory(Root);
        CopyTree(Path.Combine(TestEnvironment.Repository, "scripts"), Path.Combine(Root, "scripts"), skip: "tests");
        CopyTree(Path.Combine(TestEnvironment.Repository, "workflows", "examples"), Path.Combine(Root, "workflows", "examples"), skip: null);
        StubEnv = Path.Combine(Scratch, "stubenv");
        CopyTree(Path.Combine(TestEnvironment.Repository, "scripts", "tests", "stubenv"), StubEnv, skip: null);
        StubComfy = Path.Combine(Scratch, "stub_comfy.py");
        File.Copy(Path.Combine(TestEnvironment.Repository, "scripts", "tests", "stub_comfy.py"), StubComfy);

        ComfyPort = LoopbackServer.UnusedPort();
        GatewayPort = LoopbackServer.UnusedPort();
        while (GatewayPort == ComfyPort)
        {
            GatewayPort = LoopbackServer.UnusedPort();
        }
        ComfyMarker = Path.Combine(Scratch, "comfy launched.marker");
        GatewayMarker = Path.Combine(Scratch, "gateway launched.marker");
        ComfyRoot = Path.Combine(Scratch, "comfy root");
        Directory.CreateDirectory(ComfyRoot);

        MakeVenv();
        WriteConfig(manageComfy);
        Environment = new Dictionary<string, string?>
        {
            ["PYTHONPATH"] = StubEnv,
            ["LOCALCANVAS_RUNTIME_DIR"] = null,
            ["LC_STUB_GATEWAY_MARKER"] = GatewayMarker,
            ["LC_STUB_SYNC_MODE"] = "attention",
        };
        Log = new LauncherLog(Path.Combine(Root, ".runtime", "launcher.log"));
    }

    public string Python { get; }
    public string Pwsh { get; }
    public string Scratch { get; }
    public string Root { get; }
    public string StubEnv { get; }
    public string StubComfy { get; }
    public string ComfyRoot { get; }
    public int ComfyPort { get; }
    public int GatewayPort { get; }
    public string ComfyMarker { get; }
    public string GatewayMarker { get; }
    public Dictionary<string, string?> Environment { get; }
    public LauncherLog Log { get; }
    public FakePrompts Prompts { get; } = new() { SyncAnswer = true, JobsAnswer = true };
    public HttpHealthProbe Health { get; } = new();

    public string RuntimeDirectory => Path.Combine(Root, ".runtime");

    public LifecycleController NewController(TimeSpan? interval = null)
    {
        var processes = new HiddenProcessRunner();
        return new LifecycleController(
            new PwshScriptRunner(Pwsh, Root, processes, Log, Environment),
            Health,
            Prompts,
            new FakeSetup(() => throw new InvalidOperationException("setup must not be needed here")),
            new SeamSettingsReader(Pwsh, Root, processes, Log, Environment),
            Log,
            new LifecycleOptions { Root = Root, HealthInterval = interval ?? TimeSpan.FromSeconds(5) });
    }

    /// <summary>A ComfyUI stand-in of this test's own, not started by LocalCanvas.</summary>
    public Process StartExternalComfy()
    {
        var info = new ProcessStartInfo(Python) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { StubComfy, "--port", ComfyPort.ToString(CultureInfo.InvariantCulture), "--launch-marker", ComfyMarker })
        {
            info.ArgumentList.Add(argument);
        }
        var process = Process.Start(info)!;
        _ownPids.Add(process.Id);
        return process;
    }

    public JsonElement? Record(string role)
    {
        var path = Path.Combine(RuntimeDirectory, role + ".pid");
        if (!File.Exists(path))
        {
            return null;
        }
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.Clone();
    }

    public string? RecordHash(string role)
    {
        var path = Path.Combine(RuntimeDirectory, role + ".pid");
        return File.Exists(path) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))) : null;
    }

    public static bool Alive(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    public static DateTime StartTime(int pid)
    {
        using var process = Process.GetProcessById(pid);
        return process.StartTime;
    }

    public int MarkerLaunches(string marker) =>
        File.Exists(marker) ? File.ReadAllLines(marker).Count(line => line.Contains("pid=", StringComparison.Ordinal)) : 0;

    public IEnumerable<int> MarkerPids() =>
        new[] { ComfyMarker, GatewayMarker }
            .Where(File.Exists)
            .SelectMany(File.ReadAllLines)
            .Select(line => PidInMarker().Match(line))
            .Where(match => match.Success)
            .Select(match => int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture));

    /// <summary>End one process this test is responsible for, by its exact PID -- and only if it started after this test began.</summary>
    public void EndOwn(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            if (process.StartTime < _created)
            {
                return;
            }
            process.Kill();
            process.WaitForExit(15_000);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
    }

    private void MakeVenv()
    {
        var info = new ProcessStartInfo(Python) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "-m", "venv", "--without-pip", Path.Combine(Root, ".venv") })
        {
            info.ArgumentList.Add(argument);
        }
        using var process = Process.Start(info)!;
        var errors = process.StandardError.ReadToEnd();
        Assert.True(process.WaitForExit(120_000), "venv creation did not finish");
        Assert.True(process.ExitCode == 0, "venv creation failed: " + errors);
    }

    private static string Yaml(string path) => "\"" + path.Replace('\\', '/').Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";

    private void WriteConfig(bool manageComfy)
    {
        var local = Path.Combine(Root, "config", "local");
        Directory.CreateDirectory(local);
        var lines = new List<string>
        {
            "runtime:",
            $"  manage_comfy: {(manageComfy ? "true" : "false")}",
            "comfy:",
            $"  root: {Yaml(ComfyRoot)}",
            "  host: \"127.0.0.1\"",
            $"  port: {ComfyPort}",
            "  launcher:",
            $"    executable: {Yaml(Python)}",
            $"    script: {Yaml(StubComfy)}",
            "  extra_args:",
            "    - \"--port\"",
            $"    - \"{ComfyPort}\"",
            "    - \"--launch-marker\"",
            $"    - {Yaml(ComfyMarker)}",
            "workflows:",
            "  registry: \"workflows/examples\"",
            "gateway:",
            "  host: \"127.0.0.1\"",
            $"  port: {GatewayPort}",
            "startup:",
            "  comfy_timeout_seconds: 30",
            "  gateway_timeout_seconds: 20",
            "identity:",
            "  display_name: \"Test PC\"",
            string.Empty,
        };
        File.WriteAllText(Path.Combine(local, "runtime.yaml"), string.Join("\n", lines));
        // Read only by the stub sync engine's front end, which checks that it exists.
        File.WriteAllText(Path.Combine(local, "workflow-sources.yaml"), "sources: []\n");
    }

    private static void CopyTree(string from, string to, string? skip)
    {
        Directory.CreateDirectory(to);
        foreach (var directory in Directory.EnumerateDirectories(from))
        {
            var name = Path.GetFileName(directory);
            if (name == skip || name == "__pycache__")
            {
                continue;
            }
            CopyTree(directory, Path.Combine(to, name), null);
        }
        foreach (var file in Directory.EnumerateFiles(from))
        {
            File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        }
    }

    public async ValueTask DisposeAsync()
    {
        // Stop what the scripts started, the way a user would, then -- as a
        // safety net -- every PID this test's own stubs and records named.
        var pids = MarkerPids().ToList();
        foreach (var role in new[] { "gateway", "comfy" })
        {
            if (Record(role) is { } record && record.TryGetProperty("pid", out var pid))
            {
                pids.Add(pid.GetInt32());
            }
        }
        try
        {
            var runner = new PwshScriptRunner(Pwsh, Root, new HiddenProcessRunner(), Log, Environment);
            await runner.RunAsync(LauncherCalls.StopAll(TimeSpan.FromSeconds(90)));
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException)
        {
        }
        pids.AddRange(_ownPids);
        foreach (var pid in pids.Distinct())
        {
            EndOwn(pid);
        }
        Health.Dispose();
        TestEnvironment.RemoveDirectory(Scratch);
    }

    [GeneratedRegex(@"pid=(\d+)")]
    private static partial Regex PidInMarker();
}

[Collection(RealProcesses.Name)]
public sealed class EndToEndTests
{
    private static void SkipUnlessRunnable()
    {
        Assert.SkipWhen(TestEnvironment.Pwsh is null, "PowerShell 7 is not installed, so the end-to-end run was NOT made.");
        Assert.SkipWhen(TestEnvironment.Python is null,
            "No Python 3.10-3.13 was found (LOCALCANVAS_TEST_PYTHON or py -3.1x), so the stub runtime could not run and the end-to-end run was NOT made.");
    }

    private static async Task WaitForAsync(LifecycleController controller, Func<TrayViewModel, bool> condition, int seconds, string what, StubbedLocalCanvas site)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            if (condition(controller.ViewModel))
            {
                return;
            }
            await Task.Delay(50);
        }
        Assert.Fail($"Timed out after {seconds} s waiting for {what}; state {controller.ViewModel.State}.\n{File.ReadAllText(site.Log.Location)}");
    }

    [Fact]
    public async Task Start_detect_a_dead_Gateway_restart_it_and_exit_with_a_managed_ComfyUI()
    {
        SkipUnlessRunnable();
        await using var site = new StubbedLocalCanvas(manageComfy: true);
        var controller = site.NewController();
        await using var _ = controller;

        // Start: the stub sync reports a new workflow and one needing a look; Sync now.
        controller.Start();
        await WaitForAsync(controller, model => model.State is LauncherState.Attention && !model.Busy, 180, "startup", site);
        Assert.Equal(["sync:1"], site.Prompts.Asked);
        var gatewayRecord = site.Record("gateway")!.Value;
        var comfyRecord = site.Record("comfy")!.Value;
        var firstInstance = gatewayRecord.GetProperty("instance_id").GetString();
        var gatewayPid = gatewayRecord.GetProperty("pid").GetInt32();
        var comfyPid = comfyRecord.GetProperty("pid").GetInt32();
        var comfyStart = StubbedLocalCanvas.StartTime(comfyPid);
        var comfyRecordHash = site.RecordHash("comfy");
        Assert.Equal(firstInstance, controller.ViewModel.InstanceId);
        Assert.Equal("Gateway: Ready", controller.ViewModel.GatewayLine);
        Assert.Equal("ComfyUI: Ready", controller.ViewModel.ComfyLine);
        Assert.Equal($"http://127.0.0.1:{site.GatewayPort}", controller.ViewModel.PublishedEndpoint);

        // The Gateway dies: stopped by this test, by the exact PID in its ownership record.
        var clock = Stopwatch.StartNew();
        site.EndOwn(gatewayPid);
        await WaitForAsync(controller, model => model.State == LauncherState.GatewayDown, 30, "GatewayDown", site);
        clock.Stop();
        // Two failed probes, each after a full interval and each allowed its whole timeout (a refused
        // loopback connect on Windows takes about that long), plus scheduling slack.
        var bound = 2 * (TimeSpan.FromSeconds(5) + HttpHealthProbe.ProbeTimeout) + TimeSpan.FromSeconds(4);
        Assert.True(clock.Elapsed <= bound, $"GatewayDown took {clock.Elapsed.TotalSeconds:0.0} s, more than {bound.TotalSeconds} s");
        TestContext.Current.TestOutputHelper?.WriteLine($"GatewayDown detected {clock.Elapsed.TotalSeconds:0.00} s after the Gateway was stopped (bound {bound.TotalSeconds} s)");
        Assert.Equal("Gateway: DOWN", controller.ViewModel.GatewayLine);

        // Restart: a new instance, and ComfyUI untouched.
        Assert.True(await controller.RequestRestartGatewayAsync());
        Assert.Equal(LauncherState.Attention, controller.ViewModel.State);
        var secondInstance = site.Record("gateway")!.Value.GetProperty("instance_id").GetString();
        Assert.NotEqual(firstInstance, secondInstance);
        Assert.Equal(secondInstance, controller.ViewModel.InstanceId);
        Assert.True(StubbedLocalCanvas.Alive(comfyPid));
        Assert.Equal(comfyStart, StubbedLocalCanvas.StartTime(comfyPid));
        Assert.Equal(comfyRecordHash, site.RecordHash("comfy"));
        Assert.Equal(1, site.MarkerLaunches(site.ComfyMarker));
        Assert.Equal(2, site.MarkerLaunches(site.GatewayMarker));
        var newGatewayPid = site.Record("gateway")!.Value.GetProperty("pid").GetInt32();

        // Exit: stop.ps1 stops both, because LocalCanvas started both.
        Assert.True(await controller.RequestExitAsync());
        Assert.True(controller.Completion.IsCompleted);
        await WaitGoneAsync(newGatewayPid);
        await WaitGoneAsync(comfyPid);
        Assert.Null(site.Record("gateway"));
        Assert.Null(site.Record("comfy"));
        Assert.DoesNotContain(site.Prompts.Messages, message => message.Kind == MessageKind.StopIncomplete);
    }

    [Fact]
    public async Task Exit_leaves_an_external_ComfyUI_running()
    {
        SkipUnlessRunnable();
        await using var site = new StubbedLocalCanvas(manageComfy: false);
        using var comfy = site.StartExternalComfy();
        var up = false;
        for (var i = 0; i < 100 && !up; i++)
        {
            up = await site.Health.ProbeComfyAsync(new Uri($"http://127.0.0.1:{site.ComfyPort}"));
            if (!up)
            {
                await Task.Delay(100);
            }
        }
        Assert.True(up, "the test's own ComfyUI stand-in did not come up");

        var controller = site.NewController();
        await using var _ = controller;
        site.Prompts.SyncAnswer = false;
        controller.Start();
        await WaitForAsync(controller, model => model.State is LauncherState.Attention && !model.Busy, 180, "startup", site);
        Assert.Equal("ComfyUI: Ready (external)", controller.ViewModel.ComfyLine);
        Assert.Null(site.Record("comfy"));
        var gatewayPid = site.Record("gateway")!.Value.GetProperty("pid").GetInt32();

        Assert.True(await controller.RequestExitAsync());
        await WaitGoneAsync(gatewayPid);
        Assert.False(comfy.HasExited);
        Assert.True(await site.Health.ProbeComfyAsync(new Uri($"http://127.0.0.1:{site.ComfyPort}")));
        Assert.Equal(1, site.MarkerLaunches(site.ComfyMarker));
    }

    [Fact]
    public async Task A_new_launcher_adopts_what_a_crashed_one_left_running()
    {
        SkipUnlessRunnable();
        await using var site = new StubbedLocalCanvas(manageComfy: true);
        site.Prompts.SyncAnswer = false;

        var crashed = site.NewController();
        crashed.Start();
        await WaitForAsync(crashed, model => model.State is LauncherState.Attention && !model.Busy, 180, "the first startup", site);
        var instance = crashed.ViewModel.InstanceId;
        var gatewayPid = site.Record("gateway")!.Value.GetProperty("pid").GetInt32();
        var comfyPid = site.Record("comfy")!.Value.GetProperty("pid").GetInt32();
        // The launcher goes away without its Exit path: nothing is stopped.
        await crashed.DisposeAsync();
        Assert.True(StubbedLocalCanvas.Alive(gatewayPid));
        Assert.True(StubbedLocalCanvas.Alive(comfyPid));

        var next = site.NewController();
        await using var _ = next;
        next.Start();
        await WaitForAsync(next, model => model.State is LauncherState.Attention && !model.Busy, 180, "the second startup", site);

        Assert.Equal(instance, next.ViewModel.InstanceId);
        Assert.Equal(gatewayPid, site.Record("gateway")!.Value.GetProperty("pid").GetInt32());
        Assert.Equal(comfyPid, site.Record("comfy")!.Value.GetProperty("pid").GetInt32());
        Assert.Equal(1, site.MarkerLaunches(site.GatewayMarker));
        Assert.Equal(1, site.MarkerLaunches(site.ComfyMarker));
        Assert.Contains("gateway: reused as instance " + instance, File.ReadAllText(site.Log.Location), StringComparison.Ordinal);

        Assert.True(await next.RequestExitAsync());
        await WaitGoneAsync(gatewayPid);
        await WaitGoneAsync(comfyPid);
    }

    private static async Task WaitGoneAsync(int pid)
    {
        for (var i = 0; i < 100; i++)
        {
            if (!StubbedLocalCanvas.Alive(pid))
            {
                return;
            }
            await Task.Delay(100);
        }
        Assert.Fail($"PID {pid} is still running");
    }
}
