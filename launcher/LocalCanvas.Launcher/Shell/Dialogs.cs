using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>The plain system dialogs of the launcher. Visual design is not this file's concern.</summary>
internal static class Dialogs
{
    public const string Caption = "LocalCanvas";

    public static void ShowError(string heading, string? details)
    {
        var page = new TaskDialogPage
        {
            Caption = Caption,
            Heading = heading,
            Icon = TaskDialogIcon.Error,
            Buttons = { TaskDialogButton.Close },
            AllowCancel = true,
        };
        if (!string.IsNullOrWhiteSpace(details))
        {
            page.Expander = Details(details);
        }
        TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen);
    }

    public static SetupChoice AskRunSetup()
    {
        var run = new TaskDialogButton("Run setup");
        var cancel = TaskDialogButton.Cancel;
        var page = new TaskDialogPage
        {
            Caption = Caption,
            Heading = LauncherText.SetupRequired,
            Text = "Setup runs scripts\\setup.ps1 in a PowerShell window. LocalCanvas continues when it has finished.",
            Icon = TaskDialogIcon.Information,
            Buttons = { run, cancel },
            DefaultButton = run,
            AllowCancel = true,
        };
        return TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen) == run ? SetupChoice.RunSetup : SetupChoice.Cancel;
    }

    public static bool AskSyncNow(int changes)
    {
        var sync = new TaskDialogButton("Sync now");
        var later = new TaskDialogButton("Later");
        var page = new TaskDialogPage
        {
            Caption = Caption,
            Heading = LauncherText.ChangesDetected(changes),
            Text = "Sync now imports them before the Gateway starts. Later starts LocalCanvas on the workflows it already has; nothing is changed.",
            Icon = TaskDialogIcon.Information,
            Buttons = { sync, later },
            DefaultButton = sync,
            AllowCancel = true,
        };
        return TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen) == sync;
    }

    public static bool ConfirmDespiteActiveJobs(ActiveJobAction action)
    {
        var go = new TaskDialogButton(action == ActiveJobAction.Exit ? "Exit" : "Restart");
        var cancel = TaskDialogButton.Cancel;
        var page = new TaskDialogPage
        {
            Caption = Caption,
            Heading = action == ActiveJobAction.Exit ? LauncherText.ActiveJobsExit : LauncherText.ActiveJobsRestart,
            Icon = TaskDialogIcon.Warning,
            Buttons = { go, cancel },
            DefaultButton = cancel,
            AllowCancel = true,
        };
        return TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen) == go;
    }

    public static void ShowFailure(FailureReport report)
    {
        var page = new TaskDialogPage
        {
            Caption = Caption,
            Heading = report.Title,
            Text = report.What,
            Icon = TaskDialogIcon.Error,
            Buttons = { TaskDialogButton.Close },
            Expander = Details(report.DetailsText()),
            AllowCancel = true,
        };
        TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen);
    }

    public static void ShowMessage(LauncherMessage message)
    {
        var page = new TaskDialogPage
        {
            Caption = Caption,
            Heading = message.Title,
            Text = message.Text,
            Icon = message.Kind == MessageKind.SyncSummary ? TaskDialogIcon.Information : TaskDialogIcon.Warning,
            Buttons = { TaskDialogButton.Close },
            AllowCancel = true,
        };
        if (!string.IsNullOrWhiteSpace(message.Details))
        {
            page.Expander = Details(message.Details);
        }
        TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen);
    }

    private static TaskDialogExpander Details(string text) => new(text)
    {
        CollapsedButtonText = "Details",
        ExpandedButtonText = "Hide details",
        Position = TaskDialogExpanderPosition.AfterFootnote,
    };
}
