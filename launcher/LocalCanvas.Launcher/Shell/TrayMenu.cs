using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// The tray menu, in its fixed order: <c>LocalCanvas</c> (header), the three
/// status lines, a separator, Restart Gateway, Sync workflows, Open status, a
/// separator, Exit. It shows a <see cref="TrayViewModel"/> and forwards clicks.
/// </summary>
internal sealed class TrayMenu : IDisposable
{
    private readonly ToolStripMenuItem _gateway;
    private readonly ToolStripMenuItem _comfy;
    private readonly ToolStripMenuItem _workflows;
    private readonly ToolStripMenuItem _restart;
    private readonly ToolStripMenuItem _sync;
    private readonly ToolStripMenuItem _status;
    private readonly ToolStripMenuItem _exit;

    public TrayMenu(Action restart, Action sync, Action openStatus, Action exit)
    {
        var header = new ToolStripMenuItem("LocalCanvas") { Enabled = false };
        header.Font = new Font(header.Font, FontStyle.Bold);
        _gateway = new ToolStripMenuItem("Gateway:") { Enabled = false };
        _comfy = new ToolStripMenuItem("ComfyUI:") { Enabled = false };
        _workflows = new ToolStripMenuItem("Workflows:") { Enabled = false };
        _restart = new ToolStripMenuItem("Restart Gateway", null, (_, _) => restart());
        _sync = new ToolStripMenuItem("Sync workflows", null, (_, _) => sync());
        _status = new ToolStripMenuItem("Open status", null, (_, _) => openStatus());
        _exit = new ToolStripMenuItem("Exit", null, (_, _) => exit());

        Strip = new ContextMenuStrip();
        Strip.Items.AddRange(
        [
            header,
            _gateway,
            _comfy,
            _workflows,
            new ToolStripSeparator(),
            _restart,
            _sync,
            _status,
            new ToolStripSeparator(),
            _exit,
        ]);
    }

    public ContextMenuStrip Strip { get; }

    public void Apply(TrayViewModel model)
    {
        _gateway.Text = model.GatewayLine;
        _comfy.Text = model.ComfyLine;
        _workflows.Text = model.WorkflowsLine;
        _restart.Enabled = model.CanRestartGateway;
        _sync.Enabled = model.CanSyncWorkflows;
        _status.Enabled = model.CanOpenStatus;
        _exit.Enabled = model.CanExit;
    }

    public void Dispose() => Strip.Dispose();
}
