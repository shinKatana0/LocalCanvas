namespace LocalCanvas.Launcher.Core;

/// <summary>
/// Every script call the launcher makes, in one place. Each is a documented
/// entry point of docs/runtime.md, "Machine interface"; the launcher has no
/// other way to act on the runtime.
/// </summary>
public static class LauncherCalls
{
    public static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(90);
    public static readonly TimeSpan WorkflowCheckTimeout = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan WorkflowSyncTimeout = TimeSpan.FromMinutes(60);
    public static readonly TimeSpan StopGatewayTimeout = TimeSpan.FromSeconds(90);
    public static readonly TimeSpan StopAllTimeout = TimeSpan.FromSeconds(120);

    /// <summary>Beyond the configured ComfyUI timeout: PowerShell, the configuration seam and the first probe.</summary>
    public static readonly TimeSpan ComfyMargin = TimeSpan.FromSeconds(90);

    /// <summary>Beyond twice the configured Gateway timeout (a reuse check, then a launch).</summary>
    public static readonly TimeSpan GatewayMargin = TimeSpan.FromSeconds(60);

    /// <summary>How much longer a call that is not a start is waited for after its timeout.</summary>
    public static readonly TimeSpan DefaultGrace = TimeSpan.FromSeconds(60);

    public static ScriptCall Status() => new("status.ps1", [], StatusTimeout, DefaultGrace);

    /// <summary>status.ps1 with a timeout of its own: the confirmation after a stop.</summary>
    public static ScriptCall Status(TimeSpan timeout) => new("status.ps1", [], timeout, TimeSpan.Zero);

    public static ScriptCall StartComfy(StartupTimeouts timeouts) =>
        new("start.ps1", ["-Component", "Comfy"], timeouts.Comfy + ComfyMargin, timeouts.Comfy);

    /// <summary>The cheap check: converts nothing, writes nothing, asks ComfyUI nothing.</summary>
    public static ScriptCall WorkflowCheck() => new("sync-workflows.ps1", ["-DryRun", "-NoConvert"], WorkflowCheckTimeout, DefaultGrace);

    public static ScriptCall WorkflowSync() => new("sync-workflows.ps1", [], WorkflowSyncTimeout, TimeSpan.FromMinutes(5));

    public static ScriptCall StartGateway(StartupTimeouts timeouts) =>
        new("start.ps1", ["-Component", "Gateway"], timeouts.Gateway + timeouts.Gateway + GatewayMargin, timeouts.Gateway);

    public static ScriptCall StopGateway() => new("stop.ps1", ["-Component", "Gateway"], StopGatewayTimeout, DefaultGrace);

    /// <summary>Both roles: the owned Gateway, then an owned ComfyUI. A reused or external ComfyUI is left alone by the script.</summary>
    public static ScriptCall StopAll(TimeSpan timeout) => new("stop.ps1", [], timeout, TimeSpan.Zero);
}
