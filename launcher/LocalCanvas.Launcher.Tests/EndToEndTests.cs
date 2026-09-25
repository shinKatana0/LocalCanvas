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
        SlowConfigFlag = Path.Combine(Scratch, "slow config.flag");
        SlowTheCopiedConfigSeam();
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
            ["LC_TEST_SLOW_CONFIG_FLAG"] = SlowConfigFlag,
            ["LC_TEST_SLOW_CONFIG_SECONDS"] = "3",
        };
        Log = new LauncherLog(Path.Combine(Root, ".runtime", "launcher.log"));
    }

    public string Python { get; }
    public string Pwsh { get; }
    public string Scratch { get; }
    public string Root { get; }
    public string StubEnv { get; }
    public string StubComfy { get; }

    /// <summary>While this file exists, the next configuration read (and only that one) takes 3 s longer.</summary>
    public string SlowConfigFlag { get; }
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

    public LifecycleController NewController(TimeSpan? interval = null, IScriptRunner? runner = null, Func<ScriptCall, ScriptCall>? callPolicy = null)
    {
        var processes = new HiddenProcessRunner();
        return new LifecycleController(
            runner ?? Runner(),
            Health,
            Prompts,
            new FakeSetup(() => throw new InvalidOperationException("setup must not be needed here")),
            new SeamSettingsReader(Pwsh, Root, processes, Log, Environment),
            Log,
            new LifecycleOptions { Root = Root, HealthInterval = interval ?? TimeSpan.FromSeconds(5), CallPolicy = callPolicy ?? (static call => call) });
    }

    public PwshScriptRunner Runner() => new(Pwsh, Root, new HiddenProcessRunner(), Log, Environment);

    /// <summary>
    /// A start that is slow before it launches anything: the COPY of the stub
    /// gateway in this test's scratch folder reads the configuration 3 s late,
    /// once, when the flag file exists. The repository's stub is untouched.
    /// </summary>
    private void SlowTheCopiedConfigSeam()
    {
        var stub = Path.Combine(StubEnv, "localcanvas_gateway", "__main__.py");
        Assert.StartsWith(Scratch, stub, StringComparison.OrdinalIgnoreCase);
        var text = File.ReadAllText(stub);
        const string anchor = "def _config_command(argv):\n";
        Assert.Single(Regex.Matches(text, Regex.Escape(anchor)));
        File.WriteAllText(stub, text.Replace(anchor, anchor +
            "    _flag = os.environ.get(\"LC_TEST_SLOW_CONFIG_FLAG\")\n" +
            "    if _flag and os.path.exists(_flag):\n" +
            "        os.remove(_flag)\n" +
            "        time.sleep(float(os.environ.get(\"LC_TEST_SLOW_CONFIG_SECONDS\") or \"5\"))\n", StringComparison.Ordinal));
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

/// <summary>
/// Wraps the real runner: makes the next Gateway start slow, and records when
/// each call began and when a call the launcher stopped waiting for ended.
/// </summary>
internal sealed class RecordingRunner(IScriptRunner inner, string slowFlag) : IScriptRunner
{
    public readonly System.Collections.Concurrent.ConcurrentQueue<(string What, DateTime At)> Timeline = new();

    public Task? GatewayStartStillRunning { get; private set; }

    public int? GatewayStartPid { get; private set; }

    public async Task<ScriptOutcome> RunAsync(ScriptCall call, CancellationToken cancellationToken = default)
    {
        if (call.Names("start.ps1", "-Component", "Gateway"))
        {
            File.WriteAllText(slowFlag, "slow");
        }
        Timeline.Enqueue(("start " + call.Describe(), DateTime.UtcNow));
        var outcome = await inner.RunAsync(call, cancellationToken);
        if (outcome.StillRunning is { } running)
        {
            var recorded = running.ContinueWith(_ => Timeline.Enqueue(("ended " + call.Describe(), DateTime.UtcNow)), TaskScheduler.Default);
            outcome = outcome with { StillRunning = recorded };
            if (call.Names("start.ps1", "-Component", "Gateway"))
            {
                GatewayStartStillRunning = recorded;
                GatewayStartPid = outcome.ProcessId;
            }
        }
        else
        {
            Timeline.Enqueue(("ended " + call.Describe(), DateTime.UtcNow));
        }
        return outcome;
    }

    public DateTime When(string what) => Timeline.First(entry => entry.What == what).At;
}

/// <summary>Stopping never runs beside a start that is still in flight -- on the real scripts.</summary>
[Collection(RealProcesses.Name)]
public sealed class InFlightEndToEndTests
{
    private static void SkipUnlessRunnable()
    {
        Assert.SkipWhen(TestEnvironment.Pwsh is null, "PowerShell 7 is not installed, so the end-to-end run was NOT made.");
        Assert.SkipWhen(TestEnvironment.Python is null,
            "No Python 3.10-3.13 was found (LOCALCANVAS_TEST_PYTHON or py -3.1x), so the stub runtime could not run and the end-to-end run was NOT made.");
    }

    private static async Task WaitUntilAsync(Func<bool> condition, int seconds, string what, StubbedLocalCanvas site)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            if (condition())
            {
                return;
            }
            await Task.Delay(50);
        }
        Assert.Fail($"Timed out after {seconds} s waiting for {what}.\n{File.ReadAllText(site.Log.Location)}");
    }

    /// <summary>Nothing the stub Gateway ever launched here is still alive.</summary>
    private static async Task AssertNoGatewayLeftAsync(StubbedLocalCanvas site)
    {
        var launched = File.Exists(site.GatewayMarker)
            ? File.ReadAllLines(site.GatewayMarker).Select(line => Regex.Match(line, @"pid=(\d+)")).Where(m => m.Success)
                .Select(m => int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)).ToArray()
            : [];
        Assert.NotEmpty(launched);
        for (var i = 0; i < 100 && launched.Any(StubbedLocalCanvas.Alive); i++)
        {
            await Task.Delay(100);
        }
        Assert.DoesNotContain(launched, StubbedLocalCanvas.Alive);
        Assert.Null(site.Record("gateway"));
    }

    [Fact]
    public async Task Session_end_during_a_slow_Gateway_start_waits_for_it_before_stopping_and_reports_truthfully()
    {
        SkipUnlessRunnable();
        await using var site = new StubbedLocalCanvas(manageComfy: true);
        site.Prompts.SyncAnswer = false;
        var runner = new RecordingRunner(site.Runner(), site.SlowConfigFlag);
        var controller = site.NewController(runner: runner);
        await using var _ = controller;
        controller.Start();
        await WaitUntilAsync(() => runner.Timeline.Any(entry => entry.What == "start start.ps1 -Component Gateway -Json"), 180, "the Gateway start", site);
        await Task.Delay(1500);

        var clock = System.Diagnostics.Stopwatch.StartNew();
        var finished = await Task.Run(() => controller.EndSession(LifecycleController.DefaultSessionEndBound));
        var took = clock.Elapsed;

        // Whatever the budget allowed, the start that was in flight ends by itself.
        Assert.NotNull(runner.GatewayStartStillRunning);
        await runner.GatewayStartStillRunning!.WaitAsync(TimeSpan.FromSeconds(90));
        var log = File.ReadAllText(site.Log.Location);
        TestContext.Current.TestOutputHelper?.WriteLine(
            $"session end took {took.TotalSeconds:0.0} s (finished within the bound: {finished}); start ran " +
            $"{(runner.When("ended start.ps1 -Component Gateway -Json") - runner.When("start start.ps1 -Component Gateway -Json")).TotalSeconds:0.0} s");

        // The invariants: stop.ps1 only after the start's process ended...
        Assert.True(runner.When("start stop.ps1 -Json") >= runner.When("ended start.ps1 -Component Gateway -Json"),
            "stop.ps1 ran while the Gateway start was still in flight");
        // ...no Gateway left afterwards: no process the stub launched, no record, the port silent...
        await AssertNoGatewayLeftAsync(site);
        Assert.False(PortAnswers(site.GatewayPort), $"port {site.GatewayPort} still accepts connections");
        // ...and the log is truthful: confirmed by status.ps1, or plainly not confirmed. Never a bare claim.
        var confirmed = log.Contains("exit: everything LocalCanvas started has stopped (confirmed by status.ps1)", StringComparison.Ordinal);
        var unconfirmed = log.Contains("What is still running could not be confirmed", StringComparison.Ordinal);
        TestContext.Current.TestOutputHelper?.WriteLine(confirmed ? "outcome: confirmed by status.ps1" : unconfirmed ? "outcome: truthfully not confirmed" : "outcome: neither");
        Assert.True(confirmed || unconfirmed, log);
        Assert.DoesNotContain("exit: everything LocalCanvas started has stopped\n", log.Replace("\r\n", "\n", StringComparison.Ordinal), StringComparison.Ordinal);
    }

    private static bool PortAnswers(int port)
    {
        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            client.Connect(System.Net.IPAddress.Loopback, port);
            return true;
        }
        catch (System.Net.Sockets.SocketException)
        {
            return false;
        }
    }
    [Fact]
    public async Task A_Gateway_start_past_the_launchers_timeout_is_waited_out_then_stopped_and_confirmed()
    {
        SkipUnlessRunnable();
        await using var site = new StubbedLocalCanvas(manageComfy: true);
        site.Prompts.SyncAnswer = false;
        var runner = new RecordingRunner(site.Runner(), site.SlowConfigFlag);
        // The launcher's own timeout on the Gateway start, shortened to 3 s so
        // that it passes while the (3 s slower) start is still running.
        var controller = site.NewController(runner: runner, callPolicy: call => call.Names("start.ps1", "-Component", "Gateway")
            ? call with { Timeout = TimeSpan.FromSeconds(3), Grace = TimeSpan.FromSeconds(60) }
            : call);
        await using var _ = controller;
        controller.Start();

        var done = await Task.WhenAny(controller.Completion, Task.Delay(TimeSpan.FromSeconds(240)));
        var log = File.ReadAllText(site.Log.Location);
        Assert.True(done == controller.Completion, log);

        var failure = Assert.Single(site.Prompts.Failures);
        Assert.Contains("did not finish within 3 seconds. It has ended since.", failure.What, StringComparison.Ordinal);
        Assert.True(runner.When("start stop.ps1 -Json") >= runner.When("ended start.ps1 -Component Gateway -Json"),
            "stop.ps1 ran while the Gateway start was still in flight");
        Assert.Contains("exit: everything LocalCanvas started has stopped (confirmed by status.ps1)", log, StringComparison.Ordinal);
        await AssertNoGatewayLeftAsync(site);
        Assert.Null(site.Record("comfy"));
    }
}