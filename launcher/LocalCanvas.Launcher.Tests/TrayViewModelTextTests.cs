using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>The exact tooltip strings the brief names, and their length bound.</summary>
public sealed class TooltipTests
{
    [Fact]
    public void Ready() => Assert.Equal("LocalCanvas — Ready", TrayViewModel.TooltipFor(LauncherState.Ready));

    [Fact]
    public void Gateway_down() => Assert.Equal("LocalCanvas — Gateway down", TrayViewModel.TooltipFor(LauncherState.GatewayDown));

    [Fact]
    public void Syncing() => Assert.Equal("LocalCanvas — Syncing workflows…", TrayViewModel.TooltipFor(LauncherState.Syncing));

    [Fact]
    public void Ready_with_workflows_needing_a_look() =>
        Assert.Equal("LocalCanvas — Ready (2 workflows need a look)", TrayViewModel.TooltipFor(LauncherState.Attention, 2));

    [Fact]
    public void A_single_workflow_needing_a_look_is_worded_in_the_singular() =>
        Assert.Equal("LocalCanvas — Ready (1 workflow needs a look)", TrayViewModel.TooltipFor(LauncherState.Attention, 1));

    [Fact]
    public void No_count_yet_reads_as_plain_Ready() =>
        Assert.Equal("LocalCanvas — Ready", TrayViewModel.TooltipFor(LauncherState.Attention, null));

    [Theory]
    [InlineData(LauncherState.Starting, null)]
    [InlineData(LauncherState.Ready, null)]
    [InlineData(LauncherState.Syncing, null)]
    [InlineData(LauncherState.Attention, 1)]
    [InlineData(LauncherState.Attention, 999)]
    [InlineData(LauncherState.Restarting, null)]
    [InlineData(LauncherState.GatewayDown, null)]
    [InlineData(LauncherState.Stopping, null)]
    [InlineData(LauncherState.Failed, null)]
    public void Every_tooltip_stays_within_the_NotifyIcon_Text_limit(LauncherState state, int? attention)
    {
        var tooltip = TrayViewModel.TooltipFor(state, attention);
        Assert.True(tooltip.Length <= 127, $"'{tooltip}' is {tooltip.Length} characters, over the 127-character NotifyIcon.Text limit");
    }
}
