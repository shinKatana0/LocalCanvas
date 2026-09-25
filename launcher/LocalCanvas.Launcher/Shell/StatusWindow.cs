using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// A placeholder status window: the view model as plain text, and the tray
/// menu's actions as buttons. Closing it hides it; LocalCanvas keeps running.
/// </summary>
internal sealed class StatusWindow : Form
{
    private readonly Label _state = NewLabel("State");
    private readonly Label _gateway = NewLabel("Gateway");
    private readonly Label _comfy = NewLabel("ComfyUI");
    private readonly Label _workflows = NewLabel("Workflows");
    private readonly Label _problem = NewLabel("Problem");
    private readonly Label _endpoint = NewLabel("Endpoint");
    private readonly Label _log = NewLabel("Log");
    private readonly Button _restart = NewButton("Restart Gateway");
    private readonly Button _sync = NewButton("Sync workflows");
    private readonly Button _exit = NewButton("Exit");

    public StatusWindow(Action restart, Action sync, Action exit)
    {
        Text = "LocalCanvas";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(480, 300);
        Size = new Size(560, 340);
        ShowInTaskbar = true;

        var lines = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(12),
        };
        lines.Controls.AddRange([_state, _gateway, _comfy, _workflows, _problem, _endpoint, _log]);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Padding = new Padding(8),
        };
        buttons.Controls.AddRange([_exit, _sync, _restart]);

        Controls.Add(lines);
        Controls.Add(buttons);

        _restart.Click += (_, _) => restart();
        _sync.Click += (_, _) => sync();
        _exit.Click += (_, _) => exit();
    }

    public void Apply(TrayViewModel model)
    {
        _state.Text = "LocalCanvas: " + TrayViewModel.StateText(model.State);
        _gateway.Text = model.GatewayLine;
        _comfy.Text = model.ComfyLine;
        _workflows.Text = model.WorkflowsLine;
        _problem.Text = model.Problem ?? string.Empty;
        _problem.Visible = model.Problem is not null;
        _endpoint.Text = model.PublishedEndpoint is null ? string.Empty : "Endpoint: " + model.PublishedEndpoint;
        _endpoint.Visible = model.PublishedEndpoint is not null;
        _log.Text = "Log: " + model.LogPath;
        _restart.Enabled = model.CanRestartGateway;
        _sync.Enabled = model.CanSyncWorkflows;
        _exit.Enabled = model.CanExit;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    private static Label NewLabel(string name) => new()
    {
        AutoSize = true,
        MaximumSize = new Size(520, 0),
        Margin = new Padding(0, 0, 0, 6),
        AccessibleName = name,
    };

    private static Button NewButton(string text) => new()
    {
        Text = text,
        AutoSize = true,
        AccessibleName = text,
    };
}
