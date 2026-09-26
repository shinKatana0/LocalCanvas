using LocalCanvas.Launcher.Core;
using LocalCanvas.Launcher.Shell;

namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// TrayApplicationContext's fan-out, isolated: does a second, later model
/// actually reach the menu (and the status window, if one is open), or does
/// the presenter get stuck showing only the first one it was ever given.
/// </summary>
public sealed class TrayPresenterTests : IDisposable
{
    private readonly NotifyIcon _icon = new();
    private readonly TrayIcons _icons = new(new Size(16, 16));
    private readonly TrayMenu _menu = new(() => { }, () => { }, () => { }, () => { });

    private static TrayViewModel Model(string workflowsLine, LauncherState state = LauncherState.Ready, string gatewayLine = "Gateway: Ready") => new(
        state, TrayViewModel.TooltipFor(state), gatewayLine, "ComfyUI: Ready", workflowsLine,
        Busy: false, CanRestartGateway: true, CanSyncWorkflows: true, CanOpenStatus: true, CanExit: true,
        Problem: null, PublishedEndpoint: null, InstanceId: null, ComfyUrl: null, LogPath: "log");

    [Fact]
    public void A_second_model_reaches_the_menu_not_only_the_first()
    {
        var presenter = new TrayPresenter(_icon, _icons, _menu, () => null);

        presenter.Apply(Model("Workflows: 1"));
        Assert.Equal("Workflows: 1", MenuWorkflowsText());

        presenter.Apply(Model("Workflows: 2"));
        Assert.Equal("Workflows: 2", MenuWorkflowsText());

        presenter.Apply(Model("Workflows: 3"));
        Assert.Equal("Workflows: 3", MenuWorkflowsText());
    }

    [Fact]
    public void The_icon_and_tooltip_also_follow_a_later_model()
    {
        var presenter = new TrayPresenter(_icon, _icons, _menu, () => null);

        presenter.Apply(Model("Workflows: 1", LauncherState.Ready));
        Assert.Equal("LocalCanvas — Ready", _icon.Text);
        // The identity of the icon object, not only the tooltip text: a
        // mutant that keeps the first Icon (e.g. icon.Icon ??= ...) would
        // still leave the tooltip text alone and only this catches it.
        Assert.Same(_icons.IconFor(LauncherState.Ready), _icon.Icon);

        presenter.Apply(Model("Workflows: 1", LauncherState.GatewayDown));
        Assert.Equal("LocalCanvas — Gateway down", _icon.Text);
        Assert.Same(_icons.IconFor(LauncherState.GatewayDown), _icon.Icon);
        Assert.NotSame(_icons.IconFor(LauncherState.Ready), _icon.Icon);
    }

    [Fact]
    public void An_open_status_window_also_receives_every_later_model()
    {
        var qr = new NeverQr();
        using var status = new StatusWindow(() => { }, @"X:\LocalCanvas", qr);
        var presenter = new TrayPresenter(_icon, _icons, _menu, () => status);

        presenter.Apply(Model("Workflows: 1", gatewayLine: "Gateway: Ready"));
        // The status window's OWN content, not the menu's: a mutant that
        // drops the `statusWindow()?.Apply(model)` call entirely would still
        // leave the menu correct and only this catches it.
        Assert.Equal("Status: Ready", TextOf(status, "Gateway status"));

        presenter.Apply(Model("Workflows: 5", gatewayLine: "Gateway: DOWN"));
        Assert.Equal("Status: DOWN", TextOf(status, "Gateway status"));
        Assert.Equal("Workflows: 5", MenuWorkflowsText());
    }

    private string MenuWorkflowsText() =>
        _menu.Strip.Items.Cast<ToolStripItem>().Single(item => (item.Text ?? string.Empty).StartsWith("Workflows:", StringComparison.Ordinal)).Text!;

    private static string TextOf(Control root, string accessibleName) => Find(root, accessibleName).Text;

    private static Control Find(Control root, string accessibleName)
    {
        foreach (Control control in root.Controls)
        {
            if (control.AccessibleName == accessibleName)
            {
                return control;
            }
            if (control.HasChildren)
            {
                try
                {
                    return Find(control, accessibleName);
                }
                catch (InvalidOperationException)
                {
                }
            }
        }
        throw new InvalidOperationException($"No control named '{accessibleName}' was found.");
    }

    private sealed class NeverQr : IQrCommand
    {
        public Task<string?> WritePngAsync(string endpoint, CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
    }

    public void Dispose()
    {
        _menu.Dispose();
        _icons.Dispose();
        _icon.Dispose();
    }
}
