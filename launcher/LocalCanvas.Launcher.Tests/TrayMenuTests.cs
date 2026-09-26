using LocalCanvas.Launcher.Core;
using LocalCanvas.Launcher.Shell;

namespace LocalCanvas.Launcher.Tests;

public sealed class TrayMenuTests
{
    private static TrayViewModel Model(LauncherState state, bool actionable, bool canExit = true) => new(
        state, TrayViewModel.TooltipFor(state), "Gateway: Ready", "ComfyUI: Down (external)", "Workflows: 3",
        Busy: !actionable, CanRestartGateway: actionable, CanSyncWorkflows: actionable, CanOpenStatus: true, CanExit: canExit,
        Problem: null, PublishedEndpoint: null, InstanceId: null, ComfyUrl: null, LogPath: "log");

    [Fact]
    public void The_menu_has_exactly_the_documented_order_and_shows_the_model()
    {
        using var menu = new TrayMenu(() => { }, () => { }, () => { }, () => { });
        menu.Apply(Model(LauncherState.Ready, actionable: true));

        var items = menu.Strip.Items.Cast<ToolStripItem>()
            .Select(item => item is ToolStripSeparator ? "-" : item.Text ?? string.Empty)
            .ToArray();
        Assert.Equal(
            ["LocalCanvas", "Gateway: Ready", "ComfyUI: Down (external)", "Workflows: 3", "-", "Restart Gateway", "Sync workflows", "Open status", "-", "Exit"],
            items);
        var enabled = menu.Strip.Items.Cast<ToolStripItem>().Select(item => item.Enabled).ToArray();
        Assert.Equal([false, false, false, false, true, true, true, true, true, true], enabled);
    }

    [Fact]
    public void While_busy_only_Open_status_and_Exit_are_offered()
    {
        using var menu = new TrayMenu(() => { }, () => { }, () => { }, () => { });
        menu.Apply(Model(LauncherState.Restarting, actionable: false));
        var byText = menu.Strip.Items.Cast<ToolStripItem>().Where(item => item is not ToolStripSeparator).ToDictionary(item => item.Text!);
        Assert.False(byText["Restart Gateway"].Enabled);
        Assert.False(byText["Sync workflows"].Enabled);
        Assert.True(byText["Open status"].Enabled);
        Assert.True(byText["Exit"].Enabled);
    }

    [Fact]
    public void Restart_Gateway_is_bold_only_while_the_Gateway_is_down()
    {
        using var menu = new TrayMenu(() => { }, () => { }, () => { }, () => { });
        var restart = () => menu.Strip.Items.Cast<ToolStripItem>().Single(item => item.Text == "Restart Gateway");

        menu.Apply(Model(LauncherState.Ready, actionable: true));
        Assert.False(restart().Font.Bold);

        menu.Apply(Model(LauncherState.GatewayDown, actionable: true));
        Assert.True(restart().Font.Bold);

        menu.Apply(Model(LauncherState.Attention, actionable: true));
        Assert.False(restart().Font.Bold);
    }

    [Fact]
    public void Each_action_reaches_its_handler()
    {
        var clicked = new List<string>();
        using var menu = new TrayMenu(() => clicked.Add("restart"), () => clicked.Add("sync"), () => clicked.Add("status"), () => clicked.Add("exit"));
        menu.Apply(Model(LauncherState.Ready, actionable: true));
        foreach (var text in new[] { "Restart Gateway", "Sync workflows", "Open status", "Exit" })
        {
            menu.Strip.Items.Cast<ToolStripItem>().Single(item => item.Text == text).PerformClick();
        }
        Assert.Equal(["restart", "sync", "status", "exit"], clicked);
    }
}
