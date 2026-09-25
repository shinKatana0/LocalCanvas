using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// The minimal tray shell: a <see cref="NotifyIcon"/> and its menu, bound to
/// the controller's <see cref="TrayViewModel"/>. It renders snapshots and
/// forwards clicks; every decision is the controller's.
/// </summary>
internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly LifecycleController _controller;
    private readonly ILauncherLog _log;
    private readonly TimeSpan _sessionEndBound;
    private readonly SessionWindow _window;
    private readonly NotifyIcon _icon;
    private readonly TrayMenu _menu;
    private StatusWindow? _statusWindow;
    private TrayViewModel _current;
    private bool _ending;

    public TrayApplicationContext(
        LifecycleController controller,
        SingleInstance instance,
        WinFormsPrompts prompts,
        ILauncherLog log,
        TimeSpan sessionEndBound)
    {
        _controller = controller;
        _log = log;
        _sessionEndBound = sessionEndBound;
        _window = new SessionWindow(OnSessionEnding);
        _current = controller.ViewModel;

        _menu = new TrayMenu(RequestRestart, RequestSync, OpenStatus, RequestExit);

        _icon = new NotifyIcon
        {
            ContextMenuStrip = _menu.Strip,
            Icon = IconFor(_current.State),
            Text = Clip(_current.Tooltip),
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => OpenStatus();

        prompts.Attach(_window, ShowBalloon);
        controller.ViewModelChanged += model => Post(() => Apply(model));
        controller.ExitCompleted += () => Post(End);
        instance.StartListening(() =>
        {
            _log.Write("launcher: a second launch asked to show the status window");
            Post(OpenStatus);
        });

        Apply(_current);
        controller.Start();
    }

    private void Apply(TrayViewModel model)
    {
        _current = model;
        if (_ending)
        {
            return;
        }
        _icon.Text = Clip(model.Tooltip);
        _icon.Icon = IconFor(model.State);
        _menu.Apply(model);
        _statusWindow?.Apply(model);
    }

    private void OpenStatus()
    {
        if (_ending)
        {
            return;
        }
        if (_statusWindow is null || _statusWindow.IsDisposed)
        {
            _statusWindow = new StatusWindow(RequestRestart, RequestSync, RequestExit);
        }
        _statusWindow.Apply(_current);
        _statusWindow.Show();
        _statusWindow.WindowState = FormWindowState.Normal;
        _statusWindow.Activate();
    }

    private void RequestRestart() => _ = _controller.RequestRestartGatewayAsync();

    private void RequestSync() => _ = _controller.RequestSyncWorkflowsAsync();

    private void RequestExit() => _ = _controller.RequestExitAsync();

    private bool OnSessionEnding()
    {
        var stopped = _controller.EndSession(_sessionEndBound);
        End();
        return stopped;
    }

    private void End()
    {
        if (_ending)
        {
            return;
        }
        _ending = true;
        _icon.Visible = false;
        _statusWindow?.Dispose();
        ExitThread();
    }

    private void ShowBalloon(LauncherMessage message)
    {
        if (_ending)
        {
            return;
        }
        _icon.BalloonTipTitle = message.Title;
        _icon.BalloonTipText = message.Text;
        _icon.BalloonTipIcon = ToolTipIcon.Info;
        _icon.ShowBalloonTip(5000);
    }

    private void Post(Action action)
    {
        if (_window.IsDisposed || !_window.IsHandleCreated)
        {
            return;
        }
        try
        {
            _window.BeginInvoke(action);
        }
        catch (InvalidOperationException)
        {
        }
    }

    private static Icon IconFor(LauncherState state) => state switch
    {
        LauncherState.Failed => SystemIcons.Error,
        LauncherState.GatewayDown or LauncherState.Attention => SystemIcons.Warning,
        _ => SystemIcons.Application,
    };

    // NotifyIcon.Text is limited to 127 characters.
    private static string Clip(string text) => text.Length <= 127 ? text : text[..127];

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _icon.Visible = false;
            _icon.Dispose();
            _menu.Dispose();
            _statusWindow?.Dispose();
            _window.Dispose();
        }
        base.Dispose(disposing);
    }
}
