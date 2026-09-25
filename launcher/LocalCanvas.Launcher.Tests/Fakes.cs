using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// A pretend runtime: answers every script call with the document the real
/// script documents for that situation, and answers health probes from what
/// those calls did. A Gateway "exists" from the start call that reports it
/// until the stop call that removes it.
/// </summary>
internal sealed class FakeRuntime : IScriptRunner, IHealthProbe
{
    private readonly object _gate = new();
    private readonly List<ScriptCall> _calls = [];
    private int _instances;

    public const string ComfyUrl = "http://127.0.0.1:18188";
    public const string ProbeUrl = "http://127.0.0.1:17801/api/v1/info";

    public bool ConfigOk { get; set; } = true;
    public string ComfyOwnership { get; set; } = "owned";
    public int? ComfyPid { get; set; } = 4100;
    public int Changes { get; set; }
    public int CheckAttention { get; set; }
    public int DefinitionsWritten { get; set; }
    public int SyncAttention { get; set; }
    public string? ReuseInstance { get; set; }
    public string StopGatewayAction { get; set; } = "stop";
    public string? StopGatewayResult { get; set; } = "terminated";
    public string StopComfyAction { get; set; } = "stop";
    public string? StopComfyResult { get; set; } = "terminated";

    /// <summary>The instance id that answers /api/v1/info, or null when no Gateway answers.</summary>
    public string? LiveInstance { get; set; }

    public int? JobsActive { get; set; }
    public bool ComfyUp { get; set; } = true;
    public int? WorkflowCount { get; set; } = 4;

    /// <summary>Return an outcome here to replace the default answer to a call.</summary>
    public Func<ScriptCall, ScriptOutcome?>? Override { get; set; }

    /// <summary>Awaited before each call is answered.</summary>
    public Func<ScriptCall, CancellationToken, Task>? BeforeAnswer { get; set; }

    public int GatewayProbes;
    public readonly ConcurrentQueue<string?> ProbedInstances = new();
    public event Action? GatewayProbed;

    public IReadOnlyList<ScriptCall> Calls
    {
        get
        {
            lock (_gate)
            {
                return [.. _calls];
            }
        }
    }

    public IReadOnlyList<string> CallNames => Calls.Select(call => call.Describe()).ToArray();

    public static string InstanceId(int number) => number.ToString("x32", CultureInfo.InvariantCulture);

    public async Task<ScriptOutcome> RunAsync(ScriptCall call, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            _calls.Add(call);
        }
        if (BeforeAnswer is not null)
        {
            try
            {
                await BeforeAnswer(call, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return new ScriptOutcome(call, ScriptFailure.Cancelled, null, null, string.Empty, TimeSpan.Zero, null);
            }
        }
        if (Override?.Invoke(call) is { } replaced)
        {
            return replaced;
        }
        return Answer(call);
    }

    private ScriptOutcome Answer(ScriptCall call)
    {
        if (call.Names("status.ps1"))
        {
            return Doc.Outcome(call, Doc.Envelope(ConfigOk ? 0 : 2) + $",\"config_ok\":{Doc.Bool(ConfigOk)}}}");
        }
        if (call.Names("start.ps1", "-Component", "Comfy"))
        {
            return Doc.Outcome(call, Doc.StartComfy("ready", ComfyOwnership, ComfyPid));
        }
        if (call.Names("sync-workflows.ps1", "-DryRun", "-NoConvert"))
        {
            return Doc.Outcome(call, Doc.Sync(dryRun: true, changes: Changes, attention: CheckAttention, written: 0), CheckAttention > 0 ? 3 : 0);
        }
        if (call.Names("sync-workflows.ps1"))
        {
            return Doc.Outcome(call, Doc.Sync(dryRun: false, changes: 0, attention: SyncAttention, written: DefinitionsWritten), SyncAttention > 0 ? 3 : 0);
        }
        if (call.Names("start.ps1", "-Component", "Gateway"))
        {
            if (ReuseInstance is not null)
            {
                LiveInstance = ReuseInstance;
                return Doc.Outcome(call, Doc.StartGateway("reused", ReuseInstance, 5100));
            }
            var id = InstanceId(Interlocked.Increment(ref _instances));
            LiveInstance = id;
            return Doc.Outcome(call, Doc.StartGateway("ready", id, 5000 + _instances));
        }
        if (call.Names("stop.ps1", "-Component", "Gateway"))
        {
            if (StopGatewayAction is "stop" && StopGatewayResult is "exited" or "terminated" || StopGatewayAction is "none" or "record_removed")
            {
                LiveInstance = null;
            }
            return Doc.Outcome(call, Doc.Stop("Gateway", StopGatewayAction, StopGatewayResult, "skipped", null));
        }
        if (call.Names("stop.ps1"))
        {
            if (StopGatewayResult is "exited" or "terminated")
            {
                LiveInstance = null;
            }
            return Doc.Outcome(call, Doc.Stop("All", StopGatewayAction, StopGatewayResult, StopComfyAction, StopComfyResult));
        }
        throw new InvalidOperationException("The fake runtime does not know " + call.Describe());
    }

    public Task<GatewayHealth> ProbeGatewayAsync(Uri infoUrl, string? expectedInstanceId, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref GatewayProbes);
        ProbedInstances.Enqueue(expectedInstanceId);
        GatewayHealth result;
        if (expectedInstanceId is null)
        {
            result = GatewayHealth.NotReady("No Gateway instance is expected.");
        }
        else if (LiveInstance is null)
        {
            result = GatewayHealth.NotReady("could not be reached");
        }
        else if (LiveInstance != expectedInstanceId)
        {
            result = GatewayHealth.NotReady("another instance", LiveInstance);
        }
        else
        {
            result = new GatewayHealth(true, string.Empty, LiveInstance, JobsActive);
        }
        GatewayProbed?.Invoke();
        return Task.FromResult(result);
    }

    public Task<bool> ProbeComfyAsync(Uri comfyBaseUrl, CancellationToken cancellationToken = default) => Task.FromResult(ComfyUp);

    public Task<int?> CountWorkflowsAsync(Uri gatewayBaseUrl, CancellationToken cancellationToken = default) =>
        Task.FromResult(LiveInstance is null ? null : WorkflowCount);
}

/// <summary>The documents of docs/runtime.md, "Machine interface", as the scripts print them.</summary>
internal static class Doc
{
    public static string Bool(bool value) => value ? "true" : "false";

    public static string Str(string? value) => value is null ? "null" : JsonSerializer.Serialize(value);

    public static string Num(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "null";

    /// <summary>The opening of a document, without its closing brace.</summary>
    public static string Envelope(int exitCode, bool? ok = null, string? what = null, string? detail = null, string? fix = null)
    {
        var isOk = ok ?? exitCode == 0;
        var error = isOk ? "null" : $"{{\"what\":{Str(what ?? $"Exited with code {exitCode}")},\"detail\":{Str(detail)},\"fix\":{Str(fix)}}}";
        return $"{{\"result_version\":1,\"ok\":{Bool(isOk)},\"exit_code\":{exitCode},\"error\":{error}";
    }

    public static string StartComfy(string status, string ownership, int? pid, int exitCode = 0, string? what = null, string? detail = null, string? fix = null) =>
        Envelope(exitCode, null, what, detail, fix) +
        $",\"component\":\"Comfy\",\"comfy\":{{\"status\":{Str(status)},\"url\":{Str(FakeRuntime.ComfyUrl)},\"ownership\":{Str(ownership)},\"pid\":{Num(pid)}}}" +
        ",\"gateway\":{\"status\":\"skipped\",\"probe_url\":\"http://127.0.0.1:17801/api/v1/info\",\"instance_id\":null,\"pid\":null,\"published_endpoint\":null,\"is_lan\":null,\"local_only_reason\":null},\"workflows\":null}";

    public static string StartGateway(string status, string? instance, int? pid, int exitCode = 0, string? what = null, string? detail = null, string? fix = null) =>
        Envelope(exitCode, null, what, detail, fix) +
        ",\"component\":\"Gateway\",\"comfy\":{\"status\":\"skipped\",\"url\":\"http://127.0.0.1:18188\",\"ownership\":\"none\",\"pid\":null}" +
        $",\"gateway\":{{\"status\":{Str(status)},\"probe_url\":{Str(FakeRuntime.ProbeUrl)},\"instance_id\":{Str(instance)},\"pid\":{Num(pid)},\"published_endpoint\":\"http://192.0.2.10:17801\",\"is_lan\":true,\"local_only_reason\":null}},\"workflows\":null}}";

    public static string Sync(bool dryRun, int changes, int attention, int written, int exitCode = 0, bool? ok = null, string? what = null) =>
        Envelope(exitCode, ok ?? exitCode is 0 or 3, what) +
        $",\"dry_run\":{Bool(dryRun)},\"no_convert\":{Bool(dryRun)},\"counts\":{{}},\"unconverted_editor\":null,\"changes\":{changes},\"attention\":{attention}" +
        $",\"new\":{changes},\"changed\":0,\"retry\":0,\"removed\":0,\"attention_items\":[],\"attention_items_total\":{attention},\"definitions_written\":{written},\"summary\":\"summary line\"}}";

    public static string Stop(string component, string gatewayAction, string? gatewayResult, string comfyAction, string? comfyResult, int exitCode = 0) =>
        Envelope(exitCode) +
        $",\"component\":{Str(component)},\"roles\":{{" +
        $"\"gateway\":{{\"state_before\":{Str(gatewayAction == "stop" ? "running" : gatewayAction == "record_kept" ? "unproven" : "none")},\"action\":{Str(gatewayAction)},\"result\":{Str(gatewayResult)},\"pid\":5001}}," +
        $"\"comfy\":{{\"state_before\":{Str(comfyAction == "stop" ? "running" : comfyAction == "skipped" ? null : "none")},\"action\":{Str(comfyAction)},\"result\":{Str(comfyResult)},\"pid\":4100}}}}}}";

    public static ScriptOutcome Outcome(ScriptCall call, string json, int? exitCode = null)
    {
        using var document = JsonDocument.Parse(json);
        var code = exitCode ?? (document.RootElement.TryGetProperty("exit_code", out var said) ? said.GetInt32() : 0);
        return new ScriptOutcome(call, ScriptFailure.None, code, document.RootElement.Clone(), "[INFO] human lines", TimeSpan.FromMilliseconds(5), null);
    }

    public static ScriptOutcome Failure(ScriptCall call, ScriptFailure failure, string? detail = null, int? exitCode = null) =>
        new(call, failure, exitCode, null, "[FAIL] something on stderr", TimeSpan.FromMilliseconds(5), detail);
}

internal sealed class FakePrompts : IUserPrompts
{
    public SetupChoice SetupAnswer { get; set; } = SetupChoice.RunSetup;
    public bool SyncAnswer { get; set; } = true;
    public bool JobsAnswer { get; set; } = true;

    public readonly ConcurrentQueue<string> Asked = new();
    public readonly ConcurrentQueue<FailureReport> Failures = new();
    public readonly ConcurrentQueue<LauncherMessage> Messages = new();

    /// <summary>When set, a question waits for this before answering (or for cancellation).</summary>
    public TaskCompletionSource? Hold { get; set; }

    public async Task<SetupChoice> AskRunSetupAsync(CancellationToken cancellationToken)
    {
        Asked.Enqueue("setup");
        await WaitHold(cancellationToken);
        return SetupAnswer;
    }

    public async Task<bool> AskSyncNowAsync(int changes, CancellationToken cancellationToken)
    {
        Asked.Enqueue($"sync:{changes}");
        await WaitHold(cancellationToken);
        return SyncAnswer;
    }

    public async Task<bool> ConfirmDespiteActiveJobsAsync(ActiveJobAction action, int activeJobs, CancellationToken cancellationToken)
    {
        Asked.Enqueue($"jobs:{action}:{activeJobs}");
        await WaitHold(cancellationToken);
        return JobsAnswer;
    }

    public async Task ShowFailureAsync(FailureReport report, CancellationToken cancellationToken)
    {
        Failures.Enqueue(report);
        await WaitHold(cancellationToken);
    }

    public Task ShowMessageAsync(LauncherMessage message, CancellationToken cancellationToken)
    {
        Messages.Enqueue(message);
        return Task.CompletedTask;
    }

    private async Task WaitHold(CancellationToken cancellationToken)
    {
        if (Hold is { } hold)
        {
            await hold.Task.WaitAsync(cancellationToken);
        }
    }
}

internal sealed class FakeSetup(Func<int?> run) : ISetupConsole
{
    public int Runs;

    public Task<int?> RunAsync(CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref Runs);
        return Task.FromResult(run());
    }
}

internal sealed class FixedSettings : IRuntimeSettingsReader
{
    public static readonly StartupTimeouts Timeouts = new(TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(20), true);

    public Task<StartupTimeouts> ReadTimeoutsAsync(CancellationToken cancellationToken = default) => Task.FromResult(Timeouts);
}

internal sealed class MemoryLog : ILauncherLog
{
    public readonly ConcurrentQueue<string> Lines = new();

    public string Location => @"X:\LocalCanvas\.runtime\launcher.log";

    public void Write(string message) => Lines.Enqueue(message);

    public string Text => string.Join(Environment.NewLine, Lines);
}
