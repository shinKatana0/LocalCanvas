namespace LocalCanvas.Launcher.Core;

/// <summary>The launcher's state, as the tray icon shows it.</summary>
public enum LauncherState
{
    /// <summary>Setup check, ComfyUI, the workflow check and the Gateway are being brought up.</summary>
    Starting,

    /// <summary>The Gateway answers as the instance LocalCanvas started.</summary>
    Ready,

    /// <summary>A workflow sync is running.</summary>
    Syncing,

    /// <summary>The Gateway is healthy, and workflows need a look.</summary>
    Attention,

    /// <summary>The Gateway is being stopped and started again.</summary>
    Restarting,

    /// <summary>The Gateway stopped answering as the instance LocalCanvas started, or could not be restarted.</summary>
    GatewayDown,

    /// <summary>Exit has been asked for: everything LocalCanvas started is being, or is about to be, stopped.</summary>
    Stopping,

    /// <summary>Startup failed.</summary>
    Failed,
}

/// <summary>
/// An immutable snapshot of everything the tray shows. The controller
/// publishes a new one on every change; the shell only renders it.
/// </summary>
/// <remarks>
/// ComfyUI being down is a status line, not a state of its own: the icon is
/// about whether LocalCanvas can be used from the phone, which is the
/// Gateway's health, and a ComfyUI that is down while the Gateway is up is
/// reported by the Gateway itself to the phone. It is also not something the
/// launcher can act on -- it never starts ComfyUI outside startup.
/// </remarks>
public sealed record TrayViewModel(
    LauncherState State,
    string Tooltip,
    string GatewayLine,
    string ComfyLine,
    string WorkflowsLine,
    bool Busy,
    bool CanRestartGateway,
    bool CanSyncWorkflows,
    bool CanOpenStatus,
    bool CanExit,
    string? Problem,
    string? PublishedEndpoint,
    string? InstanceId,
    string? ComfyUrl,
    string LogPath,
    int? WorkflowsReady = null,
    int? WorkflowsNeedALook = null)
{
    /// <summary>The three status lines of the tray menu, in order.</summary>
    public IReadOnlyList<string> StatusLines => [GatewayLine, ComfyLine, WorkflowsLine];

    /// <param name="attentionCount">
    /// How many workflows need a look, used only for <see cref="LauncherState.Attention"/>:
    /// the Gateway is Ready, so the word said is still "Ready", with the count
    /// alongside it -- never the separate word "Attention", which names no
    /// state the Gateway line or the tray menu ever shows either.
    /// </param>
    public static string StateText(LauncherState state, int? attentionCount = null) => state switch
    {
        LauncherState.Starting => "Starting…",
        LauncherState.Ready => "Ready",
        LauncherState.Syncing => "Syncing workflows…",
        LauncherState.Attention => attentionCount is > 0 ? $"Ready ({Plural(attentionCount.Value, "workflow")} need{(attentionCount == 1 ? "s" : string.Empty)} a look)" : "Ready",
        LauncherState.Restarting => "Restarting the Gateway…",
        LauncherState.GatewayDown => "Gateway down",
        LauncherState.Stopping => "Exiting…",
        LauncherState.Failed => "Could not start",
        _ => state.ToString(),
    };

    public static string TooltipFor(LauncherState state, int? attentionCount = null) => "LocalCanvas — " + StateText(state, attentionCount);

    private static string Plural(int count, string noun) =>
        $"{count.ToString(System.Globalization.CultureInfo.InvariantCulture)} {noun}" + (count == 1 ? string.Empty : "s");
}
