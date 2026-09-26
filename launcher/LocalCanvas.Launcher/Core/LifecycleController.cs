using System.Globalization;
using System.Threading.Channels;

namespace LocalCanvas.Launcher.Core;

public sealed class LifecycleOptions
{
    public required string Root { get; init; }

    /// <summary>How often the Gateway and ComfyUI are probed.</summary>
    public TimeSpan HealthInterval { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>Consecutive failed Gateway probes before the state becomes GatewayDown.</summary>
    public int FailuresBeforeDown { get; init; } = 2;

    /// <summary>The wait between health probes. Replaced only by tests.</summary>
    public Func<TimeSpan, CancellationToken, Task> Delay { get; init; } = static (span, token) => Task.Delay(span, token);

    public Func<string, bool> FileExists { get; init; } = File.Exists;

    /// <summary>Applied to every script call before it is run. Replaced only by tests, to shorten timeouts.</summary>
    public Func<ScriptCall, ScriptCall> CallPolicy { get; init; } = static call => call;
}

/// <summary>
/// The launcher's lifecycle: one serial queue of commands, each of which acts
/// on the runtime only by calling a LocalCanvas script, and a health monitor
/// that reads the Gateway's own answer.
/// </summary>
/// <remarks>
/// <para>
/// The controller owns no process logic. It never starts ComfyUI or the
/// Gateway, never stops a process, and never looks one up by name or port:
/// starting is <c>start.ps1</c>, stopping is <c>stop.ps1</c> and its ownership
/// proof, and a crashed launcher's leftovers are adopted by the same
/// <c>start.ps1</c> calls as any start (ComfyUI is reused; the Gateway is
/// reused only when it answers with the instance id its record carries).
/// Health is read-only HTTP.
/// </para>
/// <para>
/// All state lives on the queue's single consumer. The UI reads immutable
/// <see cref="TrayViewModel"/> snapshots and sends requests; nothing it does
/// can run two script calls at once.
/// </para>
/// </remarks>
public sealed class LifecycleController : IAsyncDisposable
{
    private readonly IScriptRunner _scripts;
    private readonly IHealthProbe _health;
    private readonly IUserPrompts _prompts;
    private readonly ISetupConsole _setup;
    private readonly IRuntimeSettingsReader _settings;
    private readonly ILauncherLog _log;
    private readonly LifecycleOptions _options;

    private readonly Channel<Work> _queue = Channel.CreateUnbounded<Work>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _lifetime = new();
    private readonly CancellationTokenSource _sessionEnd = new();
    private readonly TaskCompletionSource _exitCompleted = new(TaskCreationOptions.RunContinuationsAsynchronously);

    private Task? _worker;
    private Task? _monitor;
    private int _commandClaimed;
    private int _exitClaimed;
    private int _tickQueued;
    private volatile bool _sessionEnding;
    private volatile bool _exited;
    private TimeSpan _sessionBound = DefaultSessionEndBound;
    private readonly object _publishGate = new();

    // How long stop.ps1 and status.ps1 took when last run in this session:
    // what the session-end sequence keeps for them.
    private TimeSpan? _lastStopDuration;
    private TimeSpan? _lastStatusDuration;
    private DateTime _sessionDeadline = DateTime.MaxValue;

    // Everything below is read and written by the queue's consumer only.
    private LauncherState _state = LauncherState.Starting;
    private bool _gatewayHealthy;
    private string? _expectedInstance;
    private Uri? _infoUrl;
    private Uri? _gatewayBase;
    private string? _publishedEndpoint;
    private Uri? _comfyUrl;
    private string? _comfyOwnership;
    private bool? _comfyUp;
    private bool _workflowsConfigured = true;
    private int? _workflowCount;
    private int? _attentionCount;
    private string? _workflowProblem;
    private int _consecutiveFailures;
    private string? _problem;
    private StartupTimeouts _timeouts = StartupTimeouts.Fallback;

    // A script call the launcher stopped waiting for while its PowerShell was
    // still running. Nothing is stopped beside it until it has exited.
    private ScriptOutcome? _abandoned;
    private bool _anyCallAbandoned;

    private volatile TrayViewModel _viewModel;

    public LifecycleController(
        IScriptRunner scripts,
        IHealthProbe health,
        IUserPrompts prompts,
        ISetupConsole setup,
        IRuntimeSettingsReader settings,
        ILauncherLog log,
        LifecycleOptions options)
    {
        _scripts = scripts;
        _health = health;
        _prompts = prompts;
        _setup = setup;
        _settings = settings;
        _log = log;
        _options = options;
        _viewModel = BuildViewModel();
    }

    /// <summary>A new snapshot, raised on the controller's own thread. Marshal before touching UI.</summary>
    public event Action<TrayViewModel>? ViewModelChanged;

    /// <summary>The launcher has finished: the tray icon is to be removed and the process to end.</summary>
    public event Action? ExitCompleted;

    /// <summary>
    /// How long a Windows sign-out or shutdown is held for the exit sequence:
    /// waiting for a script call still in flight, stop.ps1, then status.ps1 to
    /// confirm. A registered shutdown block reason makes Windows show it and
    /// wait for the user rather than end the process after its usual few
    /// seconds, so the bound is the launcher's own, not a Windows limit.
    /// </summary>
    public static readonly TimeSpan DefaultSessionEndBound = TimeSpan.FromSeconds(45);

    /// <summary>Kept for stop.ps1 and status.ps1 when nothing has been measured yet.</summary>
    public static readonly TimeSpan AssumedStopDuration = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan AssumedStatusDuration = TimeSpan.FromSeconds(10);

    public TrayViewModel ViewModel => _viewModel;

    public Task Completion => _exitCompleted.Task;

    private bool Aborting => _sessionEnding || _exited;

    private CancellationToken SessionToken => _sessionEnd.Token;

    private bool WorkflowsNeedAttention => (_attentionCount ?? 0) > 0 || _workflowProblem is not null;

    /// <summary>Begin: the startup sequence, then health monitoring.</summary>
    public void Start()
    {
        if (_worker is not null)
        {
            throw new InvalidOperationException("The controller has already been started.");
        }
        Volatile.Write(ref _commandClaimed, 1);
        Publish();
        _worker = Task.Run(WorkerLoopAsync);
        _ = Enqueue("startup", async () =>
        {
            try
            {
                return await RunStartupAsync().ConfigureAwait(false);
            }
            finally
            {
                Volatile.Write(ref _commandClaimed, 0);
                Publish();
            }
        });
        _monitor = Task.Run(MonitorLoopAsync);
    }

    /// <summary>Restart the Gateway. False when refused (busy, or not in a state it applies to) or cancelled.</summary>
    public Task<bool> RequestRestartGatewayAsync() =>
        RequestCommandAsync("restart", () => RunRestartAsync(askAboutJobs: true), viewModel => viewModel.CanRestartGateway);

    /// <summary>Sync workflows, restarting the Gateway if any definition was written.</summary>
    public Task<bool> RequestSyncWorkflowsAsync() =>
        RequestCommandAsync("sync", RunSyncAsync, viewModel => viewModel.CanSyncWorkflows);

    /// <summary>
    /// Exit: stop what LocalCanvas started, through <c>stop.ps1</c>, and finish.
    /// Queued behind a command that is running. True when the launcher exited;
    /// false when the user cancelled.
    /// </summary>
    public Task<bool> RequestExitAsync()
    {
        if (_exited)
        {
            return Task.FromResult(true);
        }
        if (Interlocked.CompareExchange(ref _exitClaimed, 1, 0) != 0)
        {
            return Task.FromResult(false);
        }
        // Shown now, even while the call in flight still has the queue.
        Publish();
        return Enqueue("exit", async () =>
        {
            var exited = await RunExitAsync(ExitMode.User).ConfigureAwait(false);
            if (!exited)
            {
                Volatile.Write(ref _exitClaimed, 0);
                Publish();
            }
            return exited;
        });
    }

    /// <summary>
    /// The Windows session is ending. Stops what LocalCanvas started without
    /// asking anything, and waits at most <paramref name="bound"/>. Returns
    /// true when the stop finished within it. Safe to call on the UI thread:
    /// nothing it waits for needs that thread.
    /// </summary>
    public bool EndSession(TimeSpan bound)
    {
        _log.Write($"session: Windows is ending the session; stopping LocalCanvas (bound {bound.TotalSeconds:0} s)");
        _sessionBound = bound;
        _sessionDeadline = DateTime.UtcNow + bound;
        _sessionEnding = true;
        try
        {
            _sessionEnd.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
        if (!_exited && Interlocked.CompareExchange(ref _exitClaimed, 1, 0) == 0)
        {
            _ = Enqueue("session-end", () => RunExitAsync(ExitMode.SessionEnd));
        }
        var finished = _exitCompleted.Task.Wait(bound);
        _log.Write(finished
            ? "session: the exit sequence finished within the bound"
            : "session: the exit sequence did not finish within the bound; what it has not confirmed is not known");
        return finished;
    }

    /// <summary>One health probe now, through the queue. The monitor calls this every interval.</summary>
    /// <remarks>
    /// The probe is made INSIDE the queue item that applies it. A probe made
    /// outside and applied later could land after a restart or an exit and
    /// report an instance that is no longer the one expected.
    /// </remarks>
    internal Task<bool> TickHealthAsync() => Enqueue("health", async () =>
    {
        await ApplyHealthAsync(await ReadHealthAsync().ConfigureAwait(false)).ConfigureAwait(false);
        return true;
    });

    public async ValueTask DisposeAsync()
    {
        _exited = true;
        try
        {
            await _lifetime.CancelAsync().ConfigureAwait(false);
            // A controller going away waits for nothing: a question or a
            // script call still awaited is abandoned (never ended).
            await _sessionEnd.CancelAsync().ConfigureAwait(false);
        }
        catch (ObjectDisposedException)
        {
        }
        _queue.Writer.TryComplete();
        if (_monitor is not null)
        {
            await _monitor.ConfigureAwait(false);
        }
        if (_worker is not null)
        {
            await _worker.ConfigureAwait(false);
        }
        _lifetime.Dispose();
        _sessionEnd.Dispose();
    }

    // ------------------------------------------------------------------
    // The queue
    // ------------------------------------------------------------------

    private sealed record Work(string Name, Func<Task> Run, Action Abandon);

    private Task<T> Enqueue<T>(string name, Func<Task<T>> run)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var work = new Work(
            name,
            async () =>
            {
                try
                {
                    done.TrySetResult(await run().ConfigureAwait(false));
                }
                catch (Exception exception)
                {
                    done.TrySetException(exception);
                    throw;
                }
            },
            () => done.TrySetCanceled());
        if (!_queue.Writer.TryWrite(work))
        {
            work.Abandon();
        }
        return done.Task;
    }

    private async Task<bool> RequestCommandAsync(string name, Func<Task<bool>> run, Func<TrayViewModel, bool> allowed)
    {
        if (_exited || Volatile.Read(ref _exitClaimed) != 0 || !allowed(_viewModel))
        {
            return false;
        }
        if (Interlocked.CompareExchange(ref _commandClaimed, 1, 0) != 0)
        {
            return false;
        }
        try
        {
            return await Enqueue(name, async () =>
            {
                try
                {
                    return await run().ConfigureAwait(false);
                }
                finally
                {
                    Volatile.Write(ref _commandClaimed, 0);
                    Publish();
                }
            }).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    private async Task WorkerLoopAsync()
    {
        await foreach (var work in _queue.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            if (_exited)
            {
                work.Abandon();
                continue;
            }
            try
            {
                await work.Run().ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_sessionEnding || _exited)
            {
            }
            catch (Exception exception)
            {
                _log.Write($"{work.Name}: unexpected failure: {exception}");
            }
        }
    }

    private async Task MonitorLoopAsync()
    {
        var token = _lifetime.Token;
        while (!token.IsCancellationRequested)
        {
            try
            {
                await _options.Delay(_options.HealthInterval, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            if (_exited || Volatile.Read(ref _commandClaimed) != 0 || Volatile.Read(ref _exitClaimed) != 0)
            {
                continue;
            }
            if (Interlocked.CompareExchange(ref _tickQueued, 1, 0) != 0)
            {
                continue;
            }
            try
            {
                await TickHealthAsync().ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested || _exited)
            {
            }
            catch (Exception exception)
            {
                // Whatever went wrong in one tick, the monitor goes on: a
                // monitor that died silently would leave the tray showing its
                // last state for ever.
                _log.Write($"health: a probe failed unexpectedly and the monitor continues: {exception.GetType().Name}: {exception.Message}");
            }
            finally
            {
                Volatile.Write(ref _tickQueued, 0);
            }
        }
    }

    // ------------------------------------------------------------------
    // Startup
    // ------------------------------------------------------------------

    private enum SetupOutcome
    {
        Ready,
        Cancelled,
        Failed,
    }

    private async Task<bool> RunStartupAsync()
    {
        try
        {
            return await StartupStepsAsync().ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_sessionEnding)
        {
            return false;
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            _log.Write($"startup: unexpected failure: {exception}");
            await FailStartupAsync(new FailureReport(
                LauncherText.CouldNotStart, "Something unexpected went wrong.", exception.Message, null, _log.Location))
                .ConfigureAwait(false);
            return false;
        }
    }

    private async Task<bool> StartupStepsAsync()
    {
        SetState(LauncherState.Starting);
        Publish();
        _log.Write($"startup: LocalCanvas launcher in {_options.Root}");

        var setup = await EnsureSetupAsync().ConfigureAwait(false);
        if (setup != SetupOutcome.Ready || Aborting)
        {
            return false;
        }

        _timeouts = await _settings.ReadTimeoutsAsync(SessionToken).ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }

        // ComfyUI: started, reused, verified external -- or adopted from a
        // launcher that crashed, which start.ps1 reuses on its ownership record.
        var comfy = await RunAsync(LauncherCalls.StartComfy(_timeouts)).ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }
        if (!comfy.HasDocument)
        {
            await FailStartupAsync(ReportFrom(comfy)).ConfigureAwait(false);
            return false;
        }
        var comfyDocument = StartDocument.Read(comfy.Document!.Value);
        ApplyComfy(comfyDocument.Comfy);
        if (!comfyDocument.Envelope.Ok)
        {
            await FailStartupAsync(ReportFrom(comfy, comfyDocument.Envelope)).ConfigureAwait(false);
            return false;
        }
        Publish();

        await CheckWorkflowsAtStartupAsync().ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }

        SetState(LauncherState.Starting);
        Publish();
        var failure = await StartGatewayAsync().ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }
        if (failure is not null)
        {
            await FailStartupAsync(failure).ConfigureAwait(false);
            return false;
        }
        await EnterHealthyAsync().ConfigureAwait(false);
        return true;
    }

    private async Task<SetupOutcome> EnsureSetupAsync()
    {
        var (ready, reason, failure) = await CheckSetupAsync().ConfigureAwait(false);
        if (failure is not null)
        {
            await FailStartupAsync(failure).ConfigureAwait(false);
            return SetupOutcome.Failed;
        }
        if (ready)
        {
            return SetupOutcome.Ready;
        }

        _log.Write($"setup: required -- {reason}");
        SetupChoice choice;
        try
        {
            choice = await _prompts.AskRunSetupAsync(SessionToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            choice = SetupChoice.Cancel;
        }
        if (choice == SetupChoice.Cancel || Aborting)
        {
            _log.Write("setup: cancelled; nothing was started");
            FinishExit();
            return SetupOutcome.Cancelled;
        }

        int? code;
        try
        {
            code = await _setup.RunAsync(SessionToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            FinishExit();
            return SetupOutcome.Cancelled;
        }
        if (code != 0)
        {
            await FailSetupAsync(new FailureReport(
                LauncherText.SetupDidNotFinish,
                code is null ? "The setup window could not be opened." : $"Setup ended with exit code {code.Value.ToString(CultureInfo.InvariantCulture)}.",
                "Nothing was started.",
                "Start LocalCanvas again to retry, or run scripts\\setup.ps1 in PowerShell 7 to see what it needs.",
                _log.Location)).ConfigureAwait(false);
            return SetupOutcome.Failed;
        }

        (ready, reason, failure) = await CheckSetupAsync().ConfigureAwait(false);
        if (ready)
        {
            _log.Write("setup: finished; continuing");
            return SetupOutcome.Ready;
        }
        await FailSetupAsync(new FailureReport(
            LauncherText.SetupDidNotFinish,
            "Setup finished, but LocalCanvas is still not set up.",
            failure?.What ?? reason,
            "Run scripts\\setup.ps1 in PowerShell 7 to see what it needs.",
            _log.Location)).ConfigureAwait(false);
        return SetupOutcome.Failed;
    }

    private async Task<(bool Ready, string? Reason, FailureReport? Failure)> CheckSetupAsync()
    {
        var python = Path.Combine(_options.Root, ".venv", "Scripts", "python.exe");
        var config = Path.Combine(_options.Root, "config", "local", "runtime.yaml");
        if (!_options.FileExists(python))
        {
            return (false, $"{python} does not exist.", null);
        }
        if (!_options.FileExists(config))
        {
            return (false, $"{config} does not exist.", null);
        }
        var status = await RunAsync(LauncherCalls.Status()).ConfigureAwait(false);
        if (!status.HasDocument)
        {
            return (false, null, Aborting ? null : ReportFrom(status));
        }
        var document = StatusDocument.Read(status.Document!.Value);
        if (!document.ConfigOk)
        {
            return (false, document.Envelope.Error?.What ?? "The configuration could not be loaded.", null);
        }
        return (true, null, null);
    }

    private async Task CheckWorkflowsAtStartupAsync()
    {
        // The same rule as start.ps1: no source list means nothing to check,
        // which is not an error.
        var sources = Path.Combine(_options.Root, "config", "local", "workflow-sources.yaml");
        if (!_options.FileExists(sources))
        {
            _workflowsConfigured = false;
            _log.Write("workflows: no workflow folder is configured, so nothing was checked");
            return;
        }

        var check = await RunAsync(LauncherCalls.WorkflowCheck()).ConfigureAwait(false);
        if (Aborting)
        {
            return;
        }
        if (!check.HasDocument)
        {
            // Not fatal: the Gateway starts on the catalogue already in place,
            // as start.ps1 does, and the tray says the check did not complete.
            _workflowProblem = "The workflow check did not complete. " + DescribeUnfinished(check);
            _log.Write("workflows: " + _workflowProblem);
            return;
        }
        var document = SyncDocument.Read(check.Document!.Value);
        if (!document.Envelope.Ok)
        {
            _workflowProblem = "The workflow check did not complete: " + (document.Envelope.Error?.What ?? "no reason given") + ".";
            _log.Write("workflows: " + _workflowProblem);
            return;
        }
        _attentionCount = document.Attention;
        var changes = document.Changes ?? 0;
        _log.Write($"workflows: {changes} change(s), {document.Attention ?? 0} need a look");
        if (changes <= 0)
        {
            return;
        }

        bool syncNow;
        try
        {
            syncNow = await _prompts.AskSyncNowAsync(changes, SessionToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (!syncNow)
        {
            _log.Write("workflows: Later -- starting on the catalogue already in place; nothing was synced");
            return;
        }

        SetState(LauncherState.Syncing);
        Publish();
        await RunSyncScriptAsync().ConfigureAwait(false);
    }

    /// <summary>Runs the sync and records its outcome. Returns its document when it ran.</summary>
    private async Task<SyncDocument?> RunSyncScriptAsync()
    {
        var sync = await RunAsync(LauncherCalls.WorkflowSync()).ConfigureAwait(false);
        if (Aborting)
        {
            return null;
        }
        if (!sync.HasDocument)
        {
            _workflowProblem = LauncherText.SyncDidNotComplete + " " + DescribeUnfinished(sync);
            _log.Write("sync: " + _workflowProblem);
            return null;
        }
        var document = SyncDocument.Read(sync.Document!.Value);
        if (!document.Envelope.Ok)
        {
            _workflowProblem = LauncherText.SyncDidNotComplete + " " + (document.Envelope.Error?.What ?? string.Empty);
            _log.Write("sync: " + _workflowProblem);
            return null;
        }
        _workflowProblem = null;
        _attentionCount = document.Attention;
        _log.Write($"sync: {document.DefinitionsWritten ?? 0} definition(s) written, {document.Attention ?? 0} need a look");
        return document;
    }

    /// <summary>start.ps1 -Component Gateway and the first probe. Null on success, else what failed.</summary>
    private async Task<FailureReport?> StartGatewayAsync()
    {
        var start = await RunAsync(LauncherCalls.StartGateway(_timeouts)).ConfigureAwait(false);
        if (Aborting)
        {
            return null;
        }
        if (!start.HasDocument)
        {
            return ReportFrom(start);
        }
        var document = StartDocument.Read(start.Document!.Value);
        if (!document.Envelope.Ok)
        {
            return ReportFrom(start, document.Envelope);
        }
        var gateway = document.Gateway;
        if (gateway.Status is not ("ready" or "reused") || string.IsNullOrEmpty(gateway.InstanceId) || string.IsNullOrEmpty(gateway.ProbeUrl))
        {
            return new FailureReport(
                LauncherText.CouldNotStart,
                "The Gateway did not report which instance was started.",
                $"start.ps1 reported status '{gateway.Status ?? "none"}', instance '{gateway.InstanceId ?? "none"}'.",
                null,
                _log.Location);
        }
        Uri info;
        try
        {
            info = HttpHealthProbe.InfoUrlFrom(gateway.ProbeUrl);
        }
        catch (UriFormatException)
        {
            return new FailureReport(LauncherText.CouldNotStart, "The Gateway's address could not be read.", gateway.ProbeUrl, null, _log.Location);
        }
        _expectedInstance = gateway.InstanceId;
        _infoUrl = info;
        _gatewayBase = HttpHealthProbe.BaseOf(info);
        _publishedEndpoint = gateway.PublishedEndpoint;
        _log.Write($"gateway: {gateway.Status} as instance {gateway.InstanceId} (PID {gateway.Pid?.ToString(CultureInfo.InvariantCulture) ?? "unknown"}), probed at {info}");

        // The first probe has to pass: start.ps1 verified the instance, and so
        // does the launcher, from its own side.
        var health = await _health.ProbeGatewayAsync(info, gateway.InstanceId, SessionToken).ConfigureAwait(false);
        if (!health.Ready)
        {
            return new FailureReport(
                LauncherText.CouldNotStart,
                "The Gateway did not answer as the one LocalCanvas started.",
                health.Reason,
                "Check .runtime\\gateway.err.log.",
                _log.Location);
        }
        return null;
    }

    private async Task FailStartupAsync(FailureReport report)
    {
        SetState(LauncherState.Failed);
        _problem = report.What;
        _gatewayHealthy = false;
        Publish();
        _log.Write($"startup: failed -- {report.What}" + (report.Detail is null ? string.Empty : "\n" + report.Detail));
        if (!_sessionEnding)
        {
            try
            {
                await _prompts.ShowFailureAsync(report, SessionToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
        // Close runs the Exit path: whatever LocalCanvas started and owns is stopped.
        Volatile.Write(ref _exitClaimed, 1);
        await RunExitAsync(ExitMode.AfterFailure).ConfigureAwait(false);
    }

    private async Task FailSetupAsync(FailureReport report)
    {
        SetState(LauncherState.Failed);
        _problem = report.What;
        Publish();
        _log.Write($"setup: failed -- {report.What}");
        if (!_sessionEnding)
        {
            try
            {
                await _prompts.ShowFailureAsync(report, SessionToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
        // Setup did not finish, so nothing can have been started by this launch.
        FinishExit();
    }

    // ------------------------------------------------------------------
    // Health
    // ------------------------------------------------------------------

    private async Task EnterHealthyAsync()
    {
        _consecutiveFailures = 0;
        _gatewayHealthy = true;
        _problem = null;
        SetState(WorkflowsNeedAttention ? LauncherState.Attention : LauncherState.Ready);
        Publish();
        if (_gatewayBase is not null)
        {
            _workflowCount = await _health.CountWorkflowsAsync(_gatewayBase, _lifetime.Token).ConfigureAwait(false);
            Publish();
        }
    }

    private sealed record HealthReading(GatewayHealth Gateway, bool? ComfyUp);

    private bool Monitorable => !_exited && _state is LauncherState.Ready or LauncherState.Attention or LauncherState.GatewayDown;

    /// <summary>Probe the Gateway (for the instance expected now) and ComfyUI. Null when nothing is monitored.</summary>
    private async Task<HealthReading?> ReadHealthAsync()
    {
        if (!Monitorable)
        {
            return null;
        }
        var token = _lifetime.Token;
        var gatewayProbe = _infoUrl is not null && _expectedInstance is not null
            ? _health.ProbeGatewayAsync(_infoUrl, _expectedInstance, token)
            : Task.FromResult(GatewayHealth.NotReady("No Gateway instance is expected: it was not restarted."));
        var comfyProbe = _comfyUrl is not null ? _health.ProbeComfyAsync(_comfyUrl, token) : Task.FromResult(false);
        await Task.WhenAll(gatewayProbe, comfyProbe).ConfigureAwait(false);
        return new HealthReading(await gatewayProbe.ConfigureAwait(false),
            _comfyUrl is null ? null : await comfyProbe.ConfigureAwait(false));
    }

    private async Task ApplyHealthAsync(HealthReading? reading)
    {
        if (reading is null || !Monitorable)
        {
            return;
        }
        if (reading.ComfyUp is bool up)
        {
            if (_comfyUp != up)
            {
                _log.Write($"health: ComfyUI {(up ? "answers" : "does not answer")} at {_comfyUrl}");
            }
            _comfyUp = up;
        }

        var gateway = reading.Gateway;
        if (gateway.Ready)
        {
            _consecutiveFailures = 0;
            if (_state == LauncherState.GatewayDown)
            {
                _log.Write($"health: the Gateway answers again as instance {_expectedInstance}");
                await EnterHealthyAsync().ConfigureAwait(false);
                return;
            }
        }
        else
        {
            _consecutiveFailures++;
            if (_consecutiveFailures <= _options.FailuresBeforeDown)
            {
                _log.Write($"health: Gateway probe failed ({_consecutiveFailures} in a row): {gateway.Reason}");
            }
            if (_consecutiveFailures >= _options.FailuresBeforeDown && _state != LauncherState.GatewayDown)
            {
                SetState(LauncherState.GatewayDown);
                _gatewayHealthy = false;
                _problem = gateway.Reason;
                _log.Write($"health: Gateway DOWN after {_consecutiveFailures} failed probes");
            }
        }
        Publish();
    }

    // ------------------------------------------------------------------
    // Restart, sync
    // ------------------------------------------------------------------

    private async Task<bool> RunRestartAsync(bool askAboutJobs)
    {
        if (askAboutJobs && !await ConfirmIfJobsActiveAsync(ActiveJobAction.RestartGateway).ConfigureAwait(false))
        {
            _log.Write("restart: cancelled");
            return false;
        }
        return await RestartStepsAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// Ask before interrupting a generation -- but only when the Gateway this
    /// launcher expects says so itself. When it cannot be reached, nothing is
    /// said about jobs: that would be pretending to know.
    /// </summary>
    private async Task<bool> ConfirmIfJobsActiveAsync(ActiveJobAction action)
    {
        if (_infoUrl is null || _expectedInstance is null || _sessionEnding)
        {
            return true;
        }
        var health = await _health.ProbeGatewayAsync(_infoUrl, _expectedInstance, _lifetime.Token).ConfigureAwait(false);
        if (!health.Ready || health.JobsActive is not > 0)
        {
            return true;
        }
        _log.Write($"{(action == ActiveJobAction.Exit ? "exit" : "restart")}: the Gateway reports {health.JobsActive} active job(s); asking");
        try
        {
            return await _prompts.ConfirmDespiteActiveJobsAsync(action, health.JobsActive.Value, SessionToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Only the session ending cancels a question, and then stopping is
            // what is left to do.
            return action == ActiveJobAction.Exit;
        }
    }

    private async Task<bool> RestartStepsAsync()
    {
        var previous = _expectedInstance;
        SetState(LauncherState.Restarting);
        // The instance being retired is no longer the one expected: whatever
        // answers with its id from here on is not a successful restart.
        _expectedInstance = null;
        _gatewayHealthy = false;
        _consecutiveFailures = 0;
        Publish();
        _log.Write($"restart: stopping the Gateway (instance {previous ?? "none"})");

        var stop = await RunAsync(LauncherCalls.StopGateway()).ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }
        string? why = null;
        string? details = null;
        if (!stop.HasDocument)
        {
            why = DescribeUnfinished(stop);
            details = stop.StandardErrorTail();
        }
        else
        {
            var document = StopDocument.Read(stop.Document!.Value);
            if (!document.Envelope.Ok)
            {
                why = Sentence(document.Envelope.Error?.What ?? "stop.ps1 did not complete");
                details = document.Envelope.Error?.Detail;
            }
            else if (!document.Gateway.NothingLeftRunning)
            {
                // stop.ps1 exits 0 when a stop ends still-running: the result
                // is what says whether the old Gateway is gone. Starting over a
                // live one would only reuse it or be refused on its port.
                why = DescribeLeftRunning("The Gateway", document.Gateway);
            }
        }
        if (why is not null)
        {
            await RestartFailedAsync(why, details).ConfigureAwait(false);
            return false;
        }

        var failure = await StartGatewayAsync().ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }
        if (failure is not null)
        {
            _expectedInstance = null;
            await RestartFailedAsync(failure.What, failure.Detail).ConfigureAwait(false);
            return false;
        }
        _log.Write($"restart: the Gateway is ready as instance {_expectedInstance}");
        await EnterHealthyAsync().ConfigureAwait(false);
        return true;
    }

    private async Task RestartFailedAsync(string what, string? details)
    {
        SetState(LauncherState.GatewayDown);
        _gatewayHealthy = false;
        _problem = what;
        Publish();
        _log.Write("restart: failed -- " + what + (details is null ? string.Empty : "\n" + details));
        await TellAsync(new LauncherMessage(MessageKind.RestartFailed, LauncherText.RestartDidNotComplete, what,
            JoinDetails(details, "Log: " + _log.Location))).ConfigureAwait(false);
    }

    private async Task<bool> RunSyncAsync()
    {
        SetState(LauncherState.Syncing);
        Publish();
        var document = await RunSyncScriptAsync().ConfigureAwait(false);
        if (Aborting)
        {
            return false;
        }
        if (document is null)
        {
            RestoreHealthState();
            Publish();
            await TellAsync(new LauncherMessage(MessageKind.SyncFailed, LauncherText.SyncDidNotComplete,
                _workflowProblem ?? LauncherText.SyncDidNotComplete, "Log: " + _log.Location)).ConfigureAwait(false);
            return false;
        }

        var written = document.DefinitionsWritten ?? 0;
        var review = document.Attention ?? 0;
        if (written > 0)
        {
            // The Gateway reads the catalogue once, when it starts.
            _log.Write($"sync: restarting the Gateway so it serves the {written} definition(s) written");
            if (await ConfirmIfJobsActiveAsync(ActiveJobAction.RestartGateway).ConfigureAwait(false))
            {
                await RestartStepsAsync().ConfigureAwait(false);
            }
            else
            {
                _log.Write("sync: restart declined; the Gateway serves the new workflows after its next restart");
                RestoreHealthState();
            }
        }
        else
        {
            RestoreHealthState();
        }
        Publish();
        await TellAsync(new LauncherMessage(MessageKind.SyncSummary, LauncherText.SyncCompleted,
            LauncherText.SyncSummary(written, review), document.Summary)).ConfigureAwait(false);
        return true;
    }

    private void RestoreHealthState()
    {
        if (_state is LauncherState.GatewayDown || !_gatewayHealthy)
        {
            SetState(LauncherState.GatewayDown);
            return;
        }
        SetState(WorkflowsNeedAttention ? LauncherState.Attention : LauncherState.Ready);
    }

    // ------------------------------------------------------------------
    // Exit
    // ------------------------------------------------------------------

    private enum ExitMode
    {
        User,
        AfterFailure,
        SessionEnd,
    }

    private async Task<bool> RunExitAsync(ExitMode mode)
    {
        if (_exited)
        {
            return true;
        }
        if (_sessionEnding)
        {
            mode = ExitMode.SessionEnd;
        }
        if (mode == ExitMode.User && !await ConfirmIfJobsActiveAsync(ActiveJobAction.Exit).ConfigureAwait(false))
        {
            _log.Write("exit: cancelled");
            return false;
        }

        SetState(LauncherState.Stopping);
        _gatewayHealthy = false;
        Publish();
        _log.Write($"exit: stopping what LocalCanvas started ({mode})");

        // A session end, or any call this run stopped waiting for, is
        // confirmed afterwards by status.ps1: a stop that ran after such a
        // call is not by itself proof that nothing is left.
        var confirm = mode == ExitMode.SessionEnd || _anyCallAbandoned;
        var problems = new List<string>();
        var stopProblems = new List<string>();
        string? details = null;

        if (await WaitForAbandonedAsync(mode).ConfigureAwait(false))
        {
            var timeout = mode == ExitMode.SessionEnd ? Positive(SessionRemaining) : LauncherCalls.StopAllTimeout;
            // Not cancelled by the session ending: this is the work the session end is for.
            var stop = await _scripts.RunAsync(LauncherCalls.StopAll(timeout), CancellationToken.None).ConfigureAwait(false);
            Observe(stop);
            stopProblems.AddRange(StopProblems(stop));
            details = stop.HasDocument ? StopDocument.Read(stop.Document!.Value).Envelope.Error?.Detail : stop.StandardErrorTail();
            foreach (var problem in stopProblems)
            {
                _log.Write("exit: stop.ps1: " + problem);
            }
            confirm |= stopProblems.Count > 0;
        }
        else
        {
            var still = _abandoned!;
            problems.Add($"{still.Call.Script}{Pid(still.ProcessId)} was still running, so stop.ps1 was not run beside it; what it starts is not stopped.");
            confirm = true;
        }

        if (confirm)
        {
            var (confirmed, leftovers, why) = await ConfirmWithStatusAsync(mode).ConfigureAwait(false);
            // What stop.ps1 said is kept unless status.ps1 finds everything gone.
            if (!confirmed || leftovers.Count > 0)
            {
                problems.AddRange(stopProblems);
            }
            problems.AddRange(leftovers);
            if (!confirmed)
            {
                problems.Add($"What is still running could not be confirmed: {why}");
            }
            if (confirmed && problems.Count == 0)
            {
                _log.Write("exit: everything LocalCanvas started has stopped (confirmed by status.ps1)");
            }
        }
        else
        {
            problems.AddRange(stopProblems);
            if (problems.Count == 0)
            {
                _log.Write("exit: everything LocalCanvas started has stopped");
            }
        }

        if (problems.Count > 0)
        {
            var message = new LauncherMessage(MessageKind.StopIncomplete, LauncherText.StopIncomplete, string.Join(" ", problems),
                JoinDetails(details, "Run scripts\\status.ps1 to see what is still running, and scripts\\stop.ps1 to stop it.", "Log: " + _log.Location));
            _log.Write("exit: NOT everything was stopped or confirmed stopped: " + message.Text);
            if (mode != ExitMode.SessionEnd && !_sessionEnding)
            {
                try
                {
                    await _prompts.ShowMessageAsync(message, SessionToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                }
            }
        }
        FinishExit();
        return true;
    }

    private TimeSpan SessionRemaining => _sessionDeadline - DateTime.UtcNow;

    private static TimeSpan Positive(TimeSpan span) => span > TimeSpan.FromSeconds(1) ? span : TimeSpan.FromSeconds(1);

    private static string Pid(int? pid) => pid is int found ? $" (PID {found.ToString(CultureInfo.InvariantCulture)})" : string.Empty;

    /// <summary>
    /// What the stop and its confirmation are expected to need, in two parts:
    /// 1.5 times what each took when last run in this session (an assumption
    /// before that). The total is at least 10 s and never more than two thirds
    /// of the budget, so that a call in flight always has some of it. The
    /// confirmation's part is at least 5 s (or the whole total, if smaller).
    /// </summary>
    internal (TimeSpan Stop, TimeSpan Status) ReserveParts()
    {
        var stop = 1.5 * (_lastStopDuration ?? AssumedStopDuration);
        var status = 1.5 * (_lastStatusDuration ?? AssumedStatusDuration);
        var floor = TimeSpan.FromSeconds(10);
        var cap = _sessionBound * 2 / 3;
        var total = stop + status;
        total = total < floor ? floor : total;
        total = total > cap ? cap : total;
        var statusPart = status < MinimumStatusReserve ? MinimumStatusReserve : status;
        statusPart = statusPart > total ? total : statusPart;
        return (total - statusPart, statusPart);
    }

    /// <summary>The time kept for status.ps1's confirmation is never less than this (unless the whole reserve is).</summary>
    public static readonly TimeSpan MinimumStatusReserve = TimeSpan.FromSeconds(5);

    internal TimeSpan StopAndConfirmReserve()
    {
        var (stop, status) = ReserveParts();
        return stop + status;
    }

    private static string Seconds(TimeSpan? span) => span is { } found ? $"{found.TotalSeconds:0.0} s" : "nothing";

    /// <summary>Remember how long stop.ps1 and status.ps1 take here.</summary>
    private void Observe(ScriptOutcome outcome)
    {
        if (outcome.Failure != ScriptFailure.None)
        {
            return;
        }
        if (outcome.Call.Script == "stop.ps1")
        {
            _lastStopDuration = outcome.Duration;
        }
        else if (outcome.Call.Script == "status.ps1")
        {
            _lastStatusDuration = outcome.Duration;
        }
    }

    /// <summary>
    /// Whether stop.ps1 may run: never while a script call this run stopped
    /// waiting for is still running, because a start still in progress would
    /// start what the stop had just found absent. At a session end the wait is
    /// bounded by the session budget, in two steps: first until the reserve for
    /// the stop and its confirmation is all that is left; then, if the call is
    /// still running -- so the stop cannot run anyway and its part of the
    /// reserve would go unused -- until only the confirmation's part is left.
    /// A call that ends in that second step is still stopped, with the time the
    /// budget has left, and the confirmation then gets what remains (or is
    /// reported as not made). Outside a session end the call's own grace has
    /// already been waited.
    /// </summary>
    private async Task<bool> WaitForAbandonedAsync(ExitMode mode)
    {
        if (_abandoned is not { } still || !still.IsStillRunning)
        {
            return true;
        }
        if (mode == ExitMode.SessionEnd)
        {
            var (stopPart, statusPart) = ReserveParts();
            _log.Write($"exit: keeping {(stopPart + statusPart).TotalSeconds:0.#} s of the session budget for stop.ps1 ({stopPart.TotalSeconds:0.#} s) " +
                       $"and status.ps1 ({statusPart.TotalSeconds:0.#} s); last measured {Seconds(_lastStopDuration)} and {Seconds(_lastStatusDuration)}");
            await WaitForAsync(still, SessionRemaining - (stopPart + statusPart), "to finish before anything is stopped").ConfigureAwait(false);
            if (still.IsStillRunning)
            {
                // Nothing can be stopped beside it, so the time kept for the stop
                // is the call's, not idle: only the confirmation's part is kept.
                await WaitForAsync(still, SessionRemaining - statusPart,
                    "more, with the time kept for stop.ps1, since nothing may be stopped beside it").ConfigureAwait(false);
            }
        }
        if (still.IsStillRunning)
        {
            _log.Write($"exit: {still.Call.Script}{Pid(still.ProcessId)} is still running; stop.ps1 is not run beside it");
            return false;
        }
        _log.Write($"exit: {still.Call.Script}{Pid(still.ProcessId)} has finished");
        return true;
    }

    private async Task WaitForAsync(ScriptOutcome still, TimeSpan wait, string why)
    {
        if (wait <= TimeSpan.Zero || !still.IsStillRunning)
        {
            return;
        }
        _log.Write($"exit: waiting up to {wait.TotalSeconds:0.#} s for {still.Call.Script}{Pid(still.ProcessId)} {why}");
        try
        {
            await still.StillRunning!.WaitAsync(wait).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
        }
    }

    /// <summary>status.ps1 after a stop: what is still running, from the scripts' own records and probes.</summary>
    private async Task<(bool Confirmed, List<string> Leftovers, string? Why)> ConfirmWithStatusAsync(ExitMode mode)
    {
        var leftovers = new List<string>();
        var timeout = mode == ExitMode.SessionEnd ? SessionRemaining : LauncherCalls.StatusTimeout;
        if (timeout < TimeSpan.FromSeconds(1))
        {
            return (false, leftovers, "no time was left in the session to run status.ps1.");
        }
        _log.Write("exit: confirming with status.ps1");
        var status = await _scripts.RunAsync(LauncherCalls.Status(timeout), CancellationToken.None).ConfigureAwait(false);
        Observe(status);
        if (!status.HasDocument)
        {
            return (false, leftovers, status.DescribeFailure());
        }
        var document = StatusDocument.Read(status.Document!.Value);
        if (!document.Envelope.Ok || !document.ConfigOk)
        {
            return (false, leftovers, Sentence(document.Envelope.Error?.What ?? "status.ps1 did not report"));
        }
        var gateway = document.Gateway;
        if (gateway.Ownership is "running" or "unproven")
        {
            leftovers.Add($"The Gateway{Pid(gateway.Pid)} is still running" +
                          (gateway.Reachable == true && gateway.InstanceId is { } id ? $" and answers as instance {id}." : "."));
        }
        else if (gateway.Reachable == true && gateway.Identity == "localcanvas")
        {
            leftovers.Add($"A LocalCanvas Gateway still answers at {gateway.ProbeUrl} (instance {gateway.InstanceId ?? "unknown"}).");
        }
        if (document.Comfy.Ownership is "running" or "unproven")
        {
            leftovers.Add("A ComfyUI that LocalCanvas started is still running.");
        }
        foreach (var leftover in leftovers)
        {
            _log.Write("exit: status.ps1: " + leftover);
        }
        return (true, leftovers, null);
    }

    /// <summary>What a stop result does not positively account for. Empty only when both roles are accounted for.</summary>
    private static List<string> StopProblems(ScriptOutcome stop)
    {
        var problems = new List<string>();
        if (!stop.HasDocument)
        {
            problems.Add(DescribeUnfinished(stop));
            return problems;
        }
        var document = StopDocument.Read(stop.Document!.Value);
        if (!document.Envelope.Ok)
        {
            problems.Add(Sentence(document.Envelope.Error?.What ?? "stop.ps1 did not complete"));
        }
        foreach (var (what, role) in new[] { ("The Gateway", document.Gateway), ("ComfyUI", document.Comfy) })
        {
            if (role.LeftRunning)
            {
                problems.Add(DescribeLeftRunning(what, role));
            }
            else if (!role.NothingLeftRunning)
            {
                problems.Add($"stop.ps1 did not report what became of {(what == "ComfyUI" ? what : "the Gateway")}.");
            }
        }
        return problems;
    }

    private static string DescribeLeftRunning(string what, StopRole role)
    {
        var pid = role.Pid is int found ? $" (PID {found.ToString(CultureInfo.InvariantCulture)})" : string.Empty;
        if (role.Action == "record_kept" || role.StateBefore == "unproven")
        {
            return $"{what}{pid} could not be proved to be the one LocalCanvas started, so it was left running.";
        }
        if (role.Result == "still-running")
        {
            return $"{what}{pid} did not exit and is still running.";
        }
        return $"{what}{pid} may still be running (stop.ps1 reported '{role.Action ?? "nothing"}', '{role.Result ?? "no result"}').";
    }

    private void FinishExit()
    {
        if (_exited)
        {
            return;
        }
        _exited = true;
        Volatile.Write(ref _exitClaimed, 1);
        Publish();
        try
        {
            _lifetime.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
        _queue.Writer.TryComplete();
        _log.Write("exit: the launcher is ending");
        try
        {
            ExitCompleted?.Invoke();
        }
        finally
        {
            _exitCompleted.TrySetResult();
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// <summary>
    /// Every script call of a command. One that passes its timeout is waited
    /// for a while longer (its grace): the scripts end themselves on their own
    /// timeouts, and nothing else is run until the call has ended. One still
    /// running after that is remembered, and no further call is made beside it.
    /// </summary>
    private async Task<ScriptOutcome> RunAsync(ScriptCall call)
    {
        call = _options.CallPolicy(call);
        if (_abandoned is { IsStillRunning: true } still)
        {
            _log.Write($"script: {call.Script} not run: {still.Call.Script}{Pid(still.ProcessId)} is still running");
            return new ScriptOutcome(call, ScriptFailure.NotStarted, null, null, string.Empty, TimeSpan.Zero,
                $"{still.Call.Script}{Pid(still.ProcessId)} from an earlier step is still running, and nothing is run beside it.");
        }
        var outcome = await _scripts.RunAsync(call, SessionToken).ConfigureAwait(false);
        Observe(outcome);
        if (outcome.Failure is ScriptFailure.TimedOut or ScriptFailure.Cancelled)
        {
            _anyCallAbandoned = true;
        }
        if (outcome.Failure == ScriptFailure.TimedOut && outcome.IsStillRunning && call.Grace > TimeSpan.Zero && !_sessionEnding)
        {
            _log.Write($"script: {call.Script}{Pid(outcome.ProcessId)} did not finish within {call.Timeout.TotalSeconds:0} s; " +
                       $"waiting up to {call.Grace.TotalSeconds:0} s more for it to end before anything else is run");
            try
            {
                await outcome.StillRunning!.WaitAsync(call.Grace, SessionToken).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
            }
            catch (OperationCanceledException)
            {
            }
            _log.Write(outcome.IsStillRunning
                ? $"script: {call.Script}{Pid(outcome.ProcessId)} is still running; nothing will be run beside it"
                : $"script: {call.Script}{Pid(outcome.ProcessId)} has ended");
        }
        if (outcome.IsStillRunning)
        {
            _abandoned = outcome;
        }
        return outcome;
    }

    /// <summary>A call that did not produce a document, in words that say whether it is still running.</summary>
    private static string DescribeUnfinished(ScriptOutcome outcome)
    {
        var text = outcome.DescribeFailure();
        if (outcome.Failure is ScriptFailure.TimedOut or ScriptFailure.Cancelled)
        {
            text += outcome.IsStillRunning
                ? $" It is still running{Pid(outcome.ProcessId)}. LocalCanvas does not end it, and stops nothing beside it."
                : " It has ended since.";
        }
        return text;
    }

    private async Task TellAsync(LauncherMessage message)
    {
        if (_sessionEnding)
        {
            return;
        }
        try
        {
            await _prompts.ShowMessageAsync(message, SessionToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void ApplyComfy(StartComfy comfy)
    {
        _comfyOwnership = comfy.Ownership;
        _comfyUp = comfy.Status switch
        {
            "ready" => true,
            "unreachable" or "failed" => false,
            _ => null,
        };
        if (!string.IsNullOrEmpty(comfy.Url) && Uri.TryCreate(comfy.Url, UriKind.Absolute, out var url))
        {
            _comfyUrl = url;
        }
        _log.Write($"comfy: {comfy.Status ?? "unknown"}, {comfy.Ownership ?? "unknown"}" +
                   (comfy.Pid is int pid ? $", PID {pid.ToString(CultureInfo.InvariantCulture)}" : string.Empty) +
                   (comfy.Url is null ? string.Empty : $", {comfy.Url}"));
    }

    private FailureReport ReportFrom(ScriptOutcome outcome, ScriptEnvelope? envelope = null)
    {
        if (envelope?.Error is { } error)
        {
            return new FailureReport(LauncherText.CouldNotStart, Sentence(error.What), error.Detail, error.Fix, _log.Location);
        }
        if (envelope is not null)
        {
            return new FailureReport(LauncherText.CouldNotStart,
                $"{outcome.Call.Script} ended with exit code {envelope.ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "unknown"}.",
                outcome.StandardErrorTail(), null, _log.Location);
        }
        return new FailureReport(LauncherText.CouldNotStart, DescribeUnfinished(outcome), outcome.StandardErrorTail(), null, _log.Location);
    }

    private static string Sentence(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length == 0 || trimmed.EndsWith('.') || trimmed.EndsWith('!') || trimmed.EndsWith('?') ? trimmed : trimmed + ".";
    }

    private static string? JoinDetails(params string?[] parts)
    {
        var present = parts.Where(part => !string.IsNullOrWhiteSpace(part)).Select(part => part!.Trim()).ToArray();
        return present.Length == 0 ? null : string.Join(Environment.NewLine + Environment.NewLine, present);
    }

    private void SetState(LauncherState state)
    {
        if (_state != state)
        {
            _log.Write($"state: {_state} -> {state}");
            _state = state;
        }
    }

    /// <summary>
    /// Build and raise a snapshot. Serialised: the queue's consumer publishes,
    /// and so does a request for Exit the moment it is queued.
    /// </summary>
    private void Publish()
    {
        lock (_publishGate)
        {
            var snapshot = BuildViewModel();
            _viewModel = snapshot;
            try
            {
                ViewModelChanged?.Invoke(snapshot);
            }
            catch (Exception exception) when (exception is InvalidOperationException or ObjectDisposedException)
            {
                // A shell already gone; the next snapshot is not its business.
            }
        }
    }

    private TrayViewModel BuildViewModel()
    {
        var exitClaimed = Volatile.Read(ref _exitClaimed) != 0;
        // An Exit that is queued behind a call in flight is shown at once: the
        // tray says it is exiting, not what the call it waits for is doing.
        var shown = exitClaimed ? LauncherState.Stopping : _state;
        var busy = Volatile.Read(ref _commandClaimed) != 0 || exitClaimed
                   || _state is LauncherState.Starting or LauncherState.Syncing or LauncherState.Restarting or LauncherState.Stopping;
        var actionable = !busy && !_exited
                         && _state is LauncherState.Ready or LauncherState.Attention or LauncherState.GatewayDown;
        return new TrayViewModel(
            State: shown,
            Tooltip: TrayViewModel.TooltipFor(shown),
            GatewayLine: "Gateway: " + GatewayStatus(shown),
            ComfyLine: "ComfyUI: " + ComfyStatus(),
            WorkflowsLine: "Workflows: " + WorkflowsStatus(),
            Busy: busy,
            CanRestartGateway: actionable,
            CanSyncWorkflows: actionable,
            CanOpenStatus: true,
            CanExit: !_exited && !exitClaimed,
            Problem: _problem ?? (WorkflowsNeedAttention ? AttentionText() : null),
            PublishedEndpoint: _publishedEndpoint,
            InstanceId: _expectedInstance,
            ComfyUrl: _comfyUrl?.ToString(),
            LogPath: _log.Location);
    }

    private string GatewayStatus(LauncherState state) => state switch
    {
        LauncherState.Starting => "Starting…",
        LauncherState.Restarting => "Restarting…",
        LauncherState.Stopping => "Stopping…",
        LauncherState.Failed => "Not running",
        LauncherState.GatewayDown => "DOWN",
        LauncherState.Ready or LauncherState.Attention => "Ready",
        LauncherState.Syncing => _gatewayHealthy ? "Ready" : "Starting…",
        _ => state.ToString(),
    };

    private string ComfyStatus()
    {
        var status = _comfyUp switch
        {
            true => "Ready",
            false => "Down",
            null => _state == LauncherState.Starting ? "Starting…" : "Unknown",
        };
        // Reused and external alike: LocalCanvas did not start it and will not stop it.
        return _comfyOwnership is "external" or "reused" ? status + " (external)" : status;
    }

    private string WorkflowsStatus()
    {
        var count = _workflowCount?.ToString(CultureInfo.InvariantCulture) ?? "–";
        if ((_attentionCount ?? 0) > 0)
        {
            return $"{count} ({_attentionCount} need a look)";
        }
        if (_workflowProblem is not null)
        {
            return count + " (check did not complete)";
        }
        return _workflowsConfigured ? count : count + " (no folder configured)";
    }

    private string AttentionText() =>
        _workflowProblem ?? $"{_attentionCount} workflow(s) need a look. Run scripts\\sync-workflows.ps1 -DryRun to see which.";
}
