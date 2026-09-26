using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>The exact specified tooltip strings, and their length bound.</summary>
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
    public void A_workflow_problem_with_no_count_still_says_so_in_words()
    {
        // Attention is entered either by a count > 0 or by a workflow
        // problem (LifecycleController.WorkflowsNeedAttention): a plain
        // "Ready" here would say nothing happened when something did -- the
        // state is never said in words, a regression from the older wording
        // "Workflows need attention".
        var tooltip = TrayViewModel.TooltipFor(LauncherState.Attention, null, workflowProblem: true);
        Assert.Equal("LocalCanvas — Ready (workflow check did not complete)", tooltip);
    }

    [Fact]
    public void A_workflow_problem_is_said_even_when_the_count_is_zero() =>
        Assert.Equal("LocalCanvas — Ready (workflow check did not complete)", TrayViewModel.TooltipFor(LauncherState.Attention, 0, workflowProblem: true));

    [Fact]
    public void Neither_a_count_nor_a_problem_is_the_only_case_that_reads_as_plain_Ready()
    {
        // Defensive only: LifecycleController.WorkflowsNeedAttention means
        // Attention is never actually entered with both false, so this
        // branch is never reached from the real controller.
        Assert.Equal("LocalCanvas — Ready", TrayViewModel.TooltipFor(LauncherState.Attention, null, workflowProblem: false));
    }

    [Theory]
    [InlineData(LauncherState.Starting, null, false)]
    [InlineData(LauncherState.Ready, null, false)]
    [InlineData(LauncherState.Syncing, null, false)]
    [InlineData(LauncherState.Attention, 1, false)]
    [InlineData(LauncherState.Attention, 999, false)]
    [InlineData(LauncherState.Attention, null, true)]
    [InlineData(LauncherState.Restarting, null, false)]
    [InlineData(LauncherState.GatewayDown, null, false)]
    [InlineData(LauncherState.Stopping, null, false)]
    [InlineData(LauncherState.Failed, null, false)]
    public void Every_tooltip_stays_within_the_NotifyIcon_Text_limit(LauncherState state, int? attention, bool workflowProblem)
    {
        var tooltip = TrayViewModel.TooltipFor(state, attention, workflowProblem);
        Assert.True(tooltip.Length <= 127, $"'{tooltip}' is {tooltip.Length} characters, over the 127-character NotifyIcon.Text limit");
    }
}
