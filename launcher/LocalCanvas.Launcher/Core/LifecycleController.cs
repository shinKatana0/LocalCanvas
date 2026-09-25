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
    private TimeSpan _sessionBound = TimeSpan.FromSeconds(25);

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
        _log.Write(finished ? "session: stopped" : "session: the stop did not finish within the bound");
        return finished;
    }

    /// <summary>One health probe now, through the queue. The monitor calls this every interval.</summary>
    internal Task<bool> TickHealthAsync() => Enqueue("health", async () =>
    {
        await RunHealthTickAsync().ConfigureAwait(false);
        return true;
    });

    public async ValueTask DisposeAsync()
    {
        _exited = true;
        try
        {
            await _lifetime.CancelAsync().ConfigureAwait(false);
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
            catch (Exception exception) when (exception is OperationCanceledException or InvalidOperationException)
            {
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
            _workflowProblem = "The workflow check did not complete. " + check.DescribeFailure();
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
            _workflowProblem = LauncherText.SyncDidNotComplete + " " + sync.DescribeFailure();
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

    private async Task RunHealthTickAsync()
    {
        if (_exited || _state is not (LauncherState.Ready or LauncherState.Attention or LauncherState.GatewayDown))
        {
            return;
        }
        var token = _lifetime.Token;
        var gatewayProbe = _infoUrl is not null && _expectedInstance is not null
            ? _health.ProbeGatewayAsync(_infoUrl, _expectedInstance, token)
            : Task.FromResult(GatewayHealth.NotReady("No Gateway instance is expected: it was not restarted."));
        var comfyProbe = _comfyUrl is not null ? _health.ProbeComfyAsync(_comfyUrl, token) : Task.FromResult(false);
        await Task.WhenAll(gatewayProbe, comfyProbe).ConfigureAwait(false);

        if (_comfyUrl is not null)
        {
            var up = await comfyProbe.ConfigureAwait(false);
            if (_comfyUp != up)
            {
                _log.Write($"health: ComfyUI {(up ? "answers" : "does not answer")} at {_comfyUrl}");
            }
            _comfyUp = up;
        }

        var gateway = await gatewayProbe.ConfigureAwait(false);
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
            why = stop.DescribeFailure();
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
        var timeout = mode == ExitMode.SessionEnd ? _sessionBound : LauncherCalls.StopAllTimeout;
        // Not cancelled by the session ending: this is the work the session end is for.
        var stop = await _scripts.RunAsync(LauncherCalls.StopAll(timeout), CancellationToken.None).ConfigureAwait(false);
        var leftovers = DescribeStop(stop);
        if (leftovers is not null)
        {
            _log.Write("exit: " + leftovers.Text + (leftovers.Details is null ? string.Empty : "\n" + leftovers.Details));
            if (mode != ExitMode.SessionEnd && !_sessionEnding)
            {
                try
                {
                    await _prompts.ShowMessageAsync(leftovers, SessionToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                }
            }
        }
        else
        {
            _log.Write("exit: everything LocalCanvas started has stopped");
        }
        FinishExit();
        return true;
    }

    private LauncherMessage? DescribeStop(ScriptOutcome stop)
    {
        if (!stop.HasDocument)
        {
            return new LauncherMessage(MessageKind.StopIncomplete, LauncherText.StopIncomplete, stop.DescribeFailure(),
                JoinDetails(stop.StandardErrorTail(), "Run scripts\\status.ps1 to see what is still running.", "Log: " + _log.Location));
        }
        var document = StopDocument.Read(stop.Document!.Value);
        var problems = new List<string>();
        if (!document.Envelope.Ok)
        {
            problems.Add(Sentence(document.Envelope.Error?.What ?? "stop.ps1 did not complete"));
        }
        if (document.Gateway.LeftRunning)
        {
            problems.Add(DescribeLeftRunning("The Gateway", document.Gateway));
        }
        if (document.Comfy.LeftRunning)
        {
            problems.Add(DescribeLeftRunning("ComfyUI", document.Comfy));
        }
        if (problems.Count == 0)
        {
            return null;
        }
        return new LauncherMessage(MessageKind.StopIncomplete, LauncherText.StopIncomplete, string.Join(" ", problems),
            JoinDetails(document.Envelope.Error?.Detail, "Run scripts\\status.ps1 to see what is still running.", "Log: " + _log.Location));
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

    private Task<ScriptOutcome> RunAsync(ScriptCall call) => _scripts.RunAsync(call, SessionToken);

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
        return new FailureReport(LauncherText.CouldNotStart, outcome.DescribeFailure(), outcome.StandardErrorTail(), null, _log.Location);
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

    private void Publish()
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

    private TrayViewModel BuildViewModel()
    {
        var exitClaimed = Volatile.Read(ref _exitClaimed) != 0;
        var busy = Volatile.Read(ref _commandClaimed) != 0 || exitClaimed
                   || _state is LauncherState.Starting or LauncherState.Syncing or LauncherState.Restarting or LauncherState.Stopping;
        var actionable = !busy && !_exited
                         && _state is LauncherState.Ready or LauncherState.Attention or LauncherState.GatewayDown;
        return new TrayViewModel(
            State: _state,
            Tooltip: TrayViewModel.TooltipFor(_state),
            GatewayLine: "Gateway: " + GatewayStatus(),
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

    private string GatewayStatus() => _state switch
    {
        LauncherState.Starting => "Starting…",
        LauncherState.Restarting => "Restarting…",
        LauncherState.Stopping => "Stopping…",
        LauncherState.Failed => "Not running",
        LauncherState.GatewayDown => "DOWN",
        LauncherState.Ready or LauncherState.Attention => "Ready",
        LauncherState.Syncing => _gatewayHealthy ? "Ready" : "Starting…",
        _ => _state.ToString(),
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
