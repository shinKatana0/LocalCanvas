namespace LocalCanvas.Launcher.Core;

public enum SetupChoice
{
    RunSetup,
    Cancel,
}

public enum ActiveJobAction
{
    RestartGateway,
    Exit,
}

/// <summary>A failure a user is told about: one plain line, and Details behind it.</summary>
public sealed record FailureReport(string Title, string What, string? Detail, string? Fix, string LogPath)
{
    public string DetailsText()
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(Detail))
        {
            parts.Add(Detail.Trim());
        }
        if (!string.IsNullOrWhiteSpace(Fix))
        {
            parts.Add(Fix.Trim());
        }
        parts.Add("Log: " + LogPath);
        return string.Join(Environment.NewLine + Environment.NewLine, parts);
    }
}

public enum MessageKind
{
    /// <summary>A sync finished; shown without interrupting.</summary>
    SyncSummary,

    /// <summary>A sync did not complete.</summary>
    SyncFailed,

    /// <summary>A restart of the Gateway did not complete.</summary>
    RestartFailed,

    /// <summary>Stopping left something running.</summary>
    StopIncomplete,

    /// <summary>
    /// The Gateway just went down (health monitoring, not a failed restart).
    /// Shown once per entry into GatewayDown, not on every failed poll.
    /// </summary>
    GatewayDown,
}

public sealed record LauncherMessage(MessageKind Kind, string Title, string Text, string? Details);

/// <summary>
/// Every question and dialog the lifecycle raises. The shell implements it;
/// nothing in the controller knows how it is drawn.
/// </summary>
/// <remarks>
/// Each call may be cancelled when the Windows session ends: the controller
/// then takes the safe answer and goes on stopping.
/// </remarks>
public interface IUserPrompts
{
    /// <summary>"LocalCanvas setup is required before first use." [Run setup] [Cancel]</summary>
    Task<SetupChoice> AskRunSetupAsync(CancellationToken cancellationToken);

    /// <summary>"N workflow changes detected." [Sync now] [Later]. True for Sync now.</summary>
    Task<bool> AskSyncNowAsync(int changes, CancellationToken cancellationToken);

    /// <summary>"A generation may still be running. ... anyway?" True to go ahead.</summary>
    Task<bool> ConfirmDespiteActiveJobsAsync(ActiveJobAction action, int activeJobs, CancellationToken cancellationToken);

    /// <summary>A failure with [Details] [Close]; completes when it is closed.</summary>
    Task ShowFailureAsync(FailureReport report, CancellationToken cancellationToken);

    /// <summary>A message. A summary may complete at once; a warning completes when it is closed.</summary>
    Task ShowMessageAsync(LauncherMessage message, CancellationToken cancellationToken);
}

/// <summary>The words the launcher says, in one place, so the shell and the tests agree.</summary>
public static class LauncherText
{
    public const string SetupRequired = "LocalCanvas setup is required before first use.";
    public const string SetupDidNotFinish = "Setup did not finish.";
    public const string CouldNotStart = "LocalCanvas could not start.";
    public const string ActiveJobsRestart = "A generation may still be running. Restart the Gateway anyway?";
    public const string ActiveJobsExit = "A generation may still be running. Exit LocalCanvas anyway?";
    public const string SyncCompleted = "Workflow sync completed.";
    public const string SyncDidNotComplete = "The workflow sync did not complete.";
    public const string RestartDidNotComplete = "The Gateway could not be restarted.";
    public const string StopIncomplete = "LocalCanvas could not stop everything it started.";
    public const string GatewayWentDown = "The LocalCanvas Gateway stopped. Right-click the tray icon and choose Restart Gateway.";

    public static string ChangesDetected(int changes) =>
        changes == 1 ? "1 workflow change detected." : $"{changes} workflow changes detected.";

    public static string SyncSummary(int updated, int needsReview) =>
        $"Updated: {updated} · Needs review: {needsReview}";
}
