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
    string LogPath)
{
    /// <summary>The three status lines of the tray menu, in order.</summary>
    public IReadOnlyList<string> StatusLines => [GatewayLine, ComfyLine, WorkflowsLine];

    public static string StateText(LauncherState state) => state switch
    {
        LauncherState.Starting => "Starting…",
        LauncherState.Ready => "Ready",
        LauncherState.Syncing => "Syncing workflows…",
        LauncherState.Attention => "Workflows need attention",
        LauncherState.Restarting => "Restarting the Gateway…",
        LauncherState.GatewayDown => "Gateway down",
        LauncherState.Stopping => "Exiting…",
        LauncherState.Failed => "Could not start",
        _ => state.ToString(),
    };

    public static string TooltipFor(LauncherState state) => "LocalCanvas — " + StateText(state);
}
