using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// <see cref="IUserPrompts"/> on the UI thread. Every answer is delivered
/// through a task that a cancelled token completes at once, so the
/// controller never waits on a UI thread that is itself waiting -- which is
/// exactly the situation when Windows ends the session while a dialog is open.
/// </summary>
internal sealed class WinFormsPrompts : IUserPrompts
{
    private Control? _ui;
    private Action<LauncherMessage>? _balloon;

    public void Attach(Control ui, Action<LauncherMessage> balloon)
    {
        _ui = ui;
        _balloon = balloon;
    }

    public Task<SetupChoice> AskRunSetupAsync(CancellationToken cancellationToken) =>
        OnUi(Dialogs.AskRunSetup, cancellationToken);

    public Task<bool> AskSyncNowAsync(int changes, CancellationToken cancellationToken) =>
        OnUi(() => Dialogs.AskSyncNow(changes), cancellationToken);

    public Task<bool> ConfirmDespiteActiveJobsAsync(ActiveJobAction action, int activeJobs, CancellationToken cancellationToken) =>
        OnUi(() => Dialogs.ConfirmDespiteActiveJobs(action), cancellationToken);

    public Task ShowFailureAsync(FailureReport report, CancellationToken cancellationToken) =>
        OnUi(() =>
        {
            Dialogs.ShowFailure(report);
            return true;
        }, cancellationToken);

    public Task ShowMessageAsync(LauncherMessage message, CancellationToken cancellationToken)
    {
        switch (message.Kind)
        {
            case MessageKind.StopIncomplete:
                // Shown before the launcher ends, and waited for.
                return OnUi(() =>
                {
                    Dialogs.ShowMessage(message);
                    return true;
                }, cancellationToken);
            case MessageKind.SyncSummary:
            case MessageKind.GatewayDown:
                Post(() => _balloon?.Invoke(message));
                return Task.CompletedTask;
            default:
                // Shown, but the lifecycle does not wait for it to be closed.
                Post(() => Dialogs.ShowMessage(message));
                return Task.CompletedTask;
        }
    }

    private void Post(Action action)
    {
        var ui = _ui ?? throw new InvalidOperationException("No window to show dialogs on.");
        if (!ui.IsDisposed)
        {
            ui.BeginInvoke(action);
        }
    }

    private Task<T> OnUi<T>(Func<T> show, CancellationToken cancellationToken)
    {
        var answer = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var registration = cancellationToken.Register(() => answer.TrySetCanceled(cancellationToken));
        Post(() =>
        {
            try
            {
                if (!answer.Task.IsCompleted)
                {
                    answer.TrySetResult(show());
                }
            }
            catch (Exception exception)
            {
                answer.TrySetException(exception);
            }
            finally
            {
                registration.Dispose();
            }
        });
        return answer.Task;
    }
}
