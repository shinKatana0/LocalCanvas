using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

public sealed class StartupTests
{
    [Fact]
    public async Task A_daily_start_runs_the_four_documented_calls_in_order_and_is_Ready()
    {
        await using var harness = new ControllerHarness();
        await harness.StartAndWaitAsync(LauncherState.Ready);

        Assert.Equal(
            ["status.ps1 -Json", "start.ps1 -Component Comfy -Json", "sync-workflows.ps1 -DryRun -NoConvert -Json", "start.ps1 -Component Gateway -Json"],
            harness.Runtime.CallNames);
        var model = harness.Model;
        Assert.Equal("LocalCanvas — Ready", model.Tooltip);
        Assert.Equal(["Gateway: Ready", "ComfyUI: Ready", "Workflows: 4"], model.StatusLines);
        Assert.Equal(FakeRuntime.InstanceId(1), model.InstanceId);
        Assert.True(model.CanRestartGateway);
        Assert.True(model.CanSyncWorkflows);
        Assert.True(model.CanExit);
        Assert.Empty(harness.Prompts.Asked);
        // The first probe after the start is what made it Ready, with the id start.ps1 reported.
        Assert.Contains(FakeRuntime.InstanceId(1), harness.Runtime.ProbedInstances);
    }

    [Fact]
    public async Task Timeouts_of_the_start_calls_come_from_the_configuration()
    {
        await using var harness = new ControllerHarness();
        await harness.StartAndWaitAsync(LauncherState.Ready);

        var comfy = harness.Runtime.Calls.Single(call => call.Names("start.ps1", "-Component", "Comfy"));
        var gateway = harness.Runtime.Calls.Single(call => call.Names("start.ps1", "-Component", "Gateway"));
        Assert.Equal(FixedSettings.Timeouts.Comfy + LauncherCalls.ComfyMargin, comfy.Timeout);
        Assert.Equal(FixedSettings.Timeouts.Gateway * 2 + LauncherCalls.GatewayMargin, gateway.Timeout);
    }

    [Fact]
    public async Task Starting_is_shown_while_the_start_runs_and_no_action_is_offered()
    {
        await using var harness = new ControllerHarness();
        var release = new TaskCompletionSource();
        harness.Runtime.BeforeAnswer = async (call, token) =>
        {
            if (call.Names("start.ps1", "-Component", "Comfy"))
            {
                await release.Task.WaitAsync(token);
            }
        };
        harness.Start();
        await harness.WaitForAsync(_ => harness.Runtime.Calls.Any(call => call.Script == "start.ps1"), "the ComfyUI start");

        var model = harness.Model;
        Assert.Equal(LauncherState.Starting, model.State);
        Assert.True(model.Busy);
        Assert.Equal(["Gateway: Starting…", "ComfyUI: Starting…", "Workflows: –"], model.StatusLines);
        Assert.False(model.CanRestartGateway);
        Assert.False(model.CanSyncWorkflows);
        Assert.False(await harness.Controller.RequestRestartGatewayAsync());
        Assert.False(await harness.Controller.RequestSyncWorkflowsAsync());
        release.SetResult();
        await harness.WaitForAsync(m => m.State == LauncherState.Ready && !m.Busy, "Ready");
        Assert.Single(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
    }

    [Fact]
    public async Task Changes_answered_Sync_now_are_synced_before_the_Gateway_starts()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Changes = 3;
        harness.Runtime.DefinitionsWritten = 3;
        await harness.StartAndWaitAsync(LauncherState.Ready);

        Assert.Equal(["sync:3"], harness.Prompts.Asked);
        Assert.Equal(
            ["status.ps1 -Json", "start.ps1 -Component Comfy -Json", "sync-workflows.ps1 -DryRun -NoConvert -Json",
             "sync-workflows.ps1 -Json", "start.ps1 -Component Gateway -Json"],
            harness.Runtime.CallNames);
        Assert.Contains(LauncherState.Syncing, harness.States);
    }

    [Fact]
    public async Task Later_starts_on_the_catalogue_in_place_and_syncs_nothing()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Changes = 2;
        harness.Prompts.SyncAnswer = false;
        await harness.StartAndWaitAsync(LauncherState.Ready);

        Assert.Equal(["sync:2"], harness.Prompts.Asked);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("sync-workflows.ps1"));
        Assert.Single(harness.Runtime.Calls, call => call.Script == "sync-workflows.ps1");
        Assert.DoesNotContain(LauncherState.Syncing, harness.States);
    }

    [Fact]
    public async Task No_change_means_no_question()
    {
        await using var harness = new ControllerHarness();
        await harness.StartAndWaitAsync(LauncherState.Ready);
        Assert.DoesNotContain(harness.Prompts.Asked, asked => asked.StartsWith("sync", StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_workflow_needing_review_makes_the_healthy_state_Attention()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.CheckAttention = 2;
        await harness.StartAndWaitAsync(LauncherState.Attention);

        Assert.Equal("Gateway: Ready", harness.Model.GatewayLine);
        Assert.Equal("Workflows: 4 (2 need a look)", harness.Model.WorkflowsLine);
        Assert.NotNull(harness.Model.Problem);
    }

    [Fact]
    public async Task A_sync_that_leaves_workflows_needing_review_is_Attention()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Changes = 2;
        harness.Runtime.DefinitionsWritten = 1;
        harness.Runtime.SyncAttention = 1;
        await harness.StartAndWaitAsync(LauncherState.Attention);
        Assert.Equal("Workflows: 4 (1 need a look)", harness.Model.WorkflowsLine);
    }

    [Fact]
    public async Task A_failed_workflow_check_is_not_fatal_and_is_reported_as_Attention()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Override = call => call.Names("sync-workflows.ps1", "-DryRun", "-NoConvert")
            ? Doc.Outcome(call, Doc.Sync(true, 0, 0, 0, exitCode: 2, ok: false, what: "The sources configuration is invalid"))
            : null;
        await harness.StartAndWaitAsync(LauncherState.Attention);

        Assert.Single(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
        Assert.Equal("Workflows: 4 (check did not complete)", harness.Model.WorkflowsLine);
        Assert.Contains("The sources configuration is invalid", harness.Model.Problem);
    }

    [Fact]
    public async Task A_workflow_check_that_prints_no_document_is_not_fatal_either()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Override = call => call.Names("sync-workflows.ps1", "-DryRun", "-NoConvert")
            ? Doc.Failure(call, ScriptFailure.NoDocument, "It printed nothing.", 1)
            : null;
        await harness.StartAndWaitAsync(LauncherState.Attention);
        Assert.Single(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
    }

    [Fact]
    public async Task Without_a_workflow_source_list_nothing_is_checked()
    {
        await using var harness = new ControllerHarness(sourcesConfigured: false);
        await harness.StartAndWaitAsync(LauncherState.Ready);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Script == "sync-workflows.ps1");
        Assert.Equal("Workflows: 4 (no folder configured)", harness.Model.WorkflowsLine);
    }

    [Fact]
    public async Task An_external_ComfyUI_is_labelled_external()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.ComfyOwnership = "external";
        harness.Runtime.ComfyPid = null;
        await harness.StartAndWaitAsync(LauncherState.Ready);
        Assert.Equal("ComfyUI: Ready (external)", harness.Model.ComfyLine);
    }
}

public sealed class StartupFailureTests
{
    [Fact]
    public async Task A_ComfyUI_start_failure_shows_its_own_words_then_runs_the_Exit_path()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Override = call => call.Names("start.ps1", "-Component", "Comfy")
            ? Doc.Outcome(call, Doc.StartComfy("unreachable", "external", null, exitCode: 4,
                what: "ComfyUI is not reachable", detail: "Probed: http://127.0.0.1:18188/system_stats", fix: "Start ComfyUI yourself."))
            : null;
        harness.Start();
        await harness.WaitForExitAsync();

        var failure = Assert.Single(harness.Prompts.Failures);
        Assert.Equal(LauncherText.CouldNotStart, failure.Title);
        Assert.Equal("ComfyUI is not reachable.", failure.What);
        Assert.Contains("Probed: http://127.0.0.1:18188/system_stats", failure.DetailsText());
        Assert.Contains("Start ComfyUI yourself.", failure.DetailsText());
        Assert.Contains(harness.Log.Location, failure.DetailsText());
        Assert.Contains(LauncherState.Failed, harness.States);
        // Close runs the Exit path: stop.ps1 for everything, and nothing started after the failure.
        Assert.Equal(["status.ps1 -Json", "start.ps1 -Component Comfy -Json", "stop.ps1 -Json"], harness.Runtime.CallNames);
        Assert.Equal("ComfyUI: Down (external)", harness.Model.ComfyLine);
    }

    [Fact]
    public async Task A_Gateway_start_failure_is_a_startup_failure()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Override = call => call.Names("start.ps1", "-Component", "Gateway")
            ? Doc.Outcome(call, Doc.StartGateway("failed", null, null, exitCode: 5, what: "Port 17801 is already in use"))
            : null;
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Equal("Port 17801 is already in use.", Assert.Single(harness.Prompts.Failures).What);
        Assert.Equal("stop.ps1 -Json", harness.Runtime.CallNames[^1]);
    }

    [Fact]
    public async Task A_first_probe_that_does_not_find_the_started_instance_is_a_startup_failure()
    {
        await using var harness = new ControllerHarness();
        // start.ps1 says ready, but what answers is another instance.
        harness.Runtime.Override = call =>
        {
            if (!call.Names("start.ps1", "-Component", "Gateway"))
            {
                return null;
            }
            harness.Runtime.LiveInstance = FakeRuntime.InstanceId(99);
            return Doc.Outcome(call, Doc.StartGateway("ready", FakeRuntime.InstanceId(7), 5007));
        };
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Equal("The Gateway did not answer as the one LocalCanvas started.", Assert.Single(harness.Prompts.Failures).What);
        Assert.DoesNotContain(LauncherState.Ready, harness.States);
    }

    [Theory]
    [InlineData(ScriptFailure.TimedOut)]
    [InlineData(ScriptFailure.NoDocument)]
    [InlineData(ScriptFailure.NotStarted)]
    public async Task A_timeout_a_crash_or_no_document_is_never_a_success(ScriptFailure failure)
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Override = call => call.Names("start.ps1", "-Component", "Comfy")
            ? Doc.Failure(call, failure, "detail", failure == ScriptFailure.NoDocument ? 1 : null)
            : null;
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Single(harness.Prompts.Failures);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
        Assert.DoesNotContain(LauncherState.Ready, harness.States);
    }
}

public sealed class SetupTests
{
    [Fact]
    public async Task A_missing_environment_asks_for_setup_without_running_any_script()
    {
        await using var harness = new ControllerHarness(setUp: false);
        harness.Prompts.SetupAnswer = SetupChoice.Cancel;
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Equal(["setup"], harness.Prompts.Asked);
        Assert.Empty(harness.Runtime.Calls);
        Assert.Equal(0, harness.Setup.Runs);
    }

    [Fact]
    public async Task A_configuration_status_reports_as_not_ok_asks_for_setup()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.ConfigOk = false;
        harness.Prompts.SetupAnswer = SetupChoice.Cancel;
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Equal(["setup"], harness.Prompts.Asked);
        Assert.Equal(["status.ps1 -Json"], harness.Runtime.CallNames);
    }

    [Fact]
    public async Task Setup_that_succeeds_is_checked_again_and_the_start_continues()
    {
        await using var harness = new ControllerHarness(setUp: false);
        harness.Setup = new FakeSetup(() =>
        {
            harness.Files[ControllerHarness.Python] = true;
            harness.Files[ControllerHarness.RuntimeYaml] = true;
            return 0;
        });
        await harness.StartAndWaitAsync(LauncherState.Ready);

        Assert.Equal(1, harness.Setup.Runs);
        Assert.Equal("status.ps1 -Json", harness.Runtime.CallNames[0]);
    }

    [Fact]
    public async Task Setup_that_fails_says_so_and_starts_nothing()
    {
        await using var harness = new ControllerHarness(setUp: false);
        harness.SetupExitCode = 3;
        harness.Start();
        await harness.WaitForExitAsync();

        var failure = Assert.Single(harness.Prompts.Failures);
        Assert.Equal(LauncherText.SetupDidNotFinish, failure.Title);
        Assert.Equal("Setup ended with exit code 3.", failure.What);
        Assert.Empty(harness.Runtime.Calls);
    }

    [Fact]
    public async Task Setup_that_exits_0_but_leaves_it_unset_is_not_a_loop()
    {
        await using var harness = new ControllerHarness(setUp: false);
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Equal(1, harness.Setup.Runs);
        Assert.Equal("Setup finished, but LocalCanvas is still not set up.", Assert.Single(harness.Prompts.Failures).What);
    }
}

public sealed class HealthTests
{
    [Fact]
    public async Task One_failed_probe_is_not_down_and_two_are()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);

        harness.Runtime.LiveInstance = null;
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.Ready, harness.Model.State);
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
        Assert.Equal("LocalCanvas — Gateway down", harness.Model.Tooltip);
        Assert.Equal("Gateway: DOWN", harness.Model.GatewayLine);
        Assert.True(harness.Model.CanRestartGateway);
    }

    [Fact]
    public async Task A_Gateway_with_another_instance_id_is_down()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);

        harness.Runtime.LiveInstance = FakeRuntime.InstanceId(42);
        await controller.TickHealthAsync();
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
    }

    [Fact]
    public async Task A_later_pass_returns_to_Ready_and_to_Attention_when_workflows_need_it()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.CheckAttention = 1;
        var controller = await harness.StartAndWaitAsync(LauncherState.Attention);
        var live = harness.Runtime.LiveInstance;

        harness.Runtime.LiveInstance = null;
        await controller.TickHealthAsync();
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
        harness.Runtime.LiveInstance = live;
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.Attention, harness.Model.State);
    }

    [Fact]
    public async Task ComfyUI_going_down_is_a_status_line_and_not_a_state()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.ComfyUp = false;
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.Ready, harness.Model.State);
        Assert.Equal("ComfyUI: Down", harness.Model.ComfyLine);
    }

    [Fact]
    public async Task The_monitor_probes_on_its_own_every_interval()
    {
        var ticks = System.Threading.Channels.Channel.CreateUnbounded<TaskCompletionSource>();
        await using var harness = new ControllerHarness
        {
            Delay = async (_, token) =>
            {
                var wait = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                await ticks.Writer.WriteAsync(wait, token);
                await wait.Task.WaitAsync(token);
            },
        };
        await harness.StartAndWaitAsync(LauncherState.Ready);
        var probesAtReady = harness.Runtime.GatewayProbes;

        harness.Runtime.LiveInstance = null;
        for (var i = 0; i < 2; i++)
        {
            var wait = await ticks.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
            wait.SetResult();
            await harness.WaitForAsync(_ => harness.Runtime.GatewayProbes >= probesAtReady + i + 1, $"probe {i + 1}");
        }
        await harness.WaitForAsync(model => model.State == LauncherState.GatewayDown, "GatewayDown from the monitor alone");
    }
}

public sealed class RestartTests
{
    [Fact]
    public async Task Restart_stops_and_starts_the_Gateway_only_and_expects_the_new_instance()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;

        Assert.True(await controller.RequestRestartGatewayAsync());

        var restart = harness.Runtime.CallNames.Skip(before).ToArray();
        Assert.Equal(["stop.ps1 -Component Gateway -Json", "start.ps1 -Component Gateway -Json"], restart);
        Assert.DoesNotContain(harness.Runtime.Calls.Skip(before), call => call.Arguments.Contains("Comfy"));
        Assert.Equal(LauncherState.Ready, harness.Model.State);
        Assert.Equal(FakeRuntime.InstanceId(2), harness.Model.InstanceId);
        Assert.Contains(LauncherState.Restarting, harness.States);
        Assert.Equal(FakeRuntime.InstanceId(2), harness.Runtime.ProbedInstances.Last());
    }

    [Fact]
    public async Task Restart_from_GatewayDown_recovers()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.LiveInstance = null;
        await controller.TickHealthAsync();
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);

        Assert.True(await controller.RequestRestartGatewayAsync());
        Assert.Equal(LauncherState.Ready, harness.Model.State);
    }

    [Theory]
    [InlineData("stop", "still-running")]
    [InlineData("record_kept", null)]
    public async Task A_stop_that_leaves_the_Gateway_running_is_GatewayDown_with_no_start(string action, string? result)
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.StopGatewayAction = action;
        harness.Runtime.StopGatewayResult = result;

        Assert.False(await controller.RequestRestartGatewayAsync());

        Assert.Equal(["stop.ps1 -Component Gateway -Json"], harness.Runtime.CallNames.Skip(before));
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
        Assert.Contains("PID 5001", harness.Model.Problem);
        Assert.Equal(MessageKind.RestartFailed, Assert.Single(harness.Prompts.Messages).Kind);

        // The old Gateway is still alive and answering with the old id; that
        // is not a restart, and it stays down until one succeeds.
        Assert.NotNull(harness.Runtime.LiveInstance);
        await controller.TickHealthAsync();
        await controller.TickHealthAsync();
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
    }

    [Fact]
    public async Task A_failed_start_after_the_stop_stays_GatewayDown()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.Override = call => call.Names("start.ps1", "-Component", "Gateway")
            ? Doc.Outcome(call, Doc.StartGateway("failed", null, null, exitCode: 5, what: "The gateway did not become ready within 20s"))
            : null;

        Assert.False(await controller.RequestRestartGatewayAsync());
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
        Assert.Equal("The gateway did not become ready within 20s.", harness.Model.Problem);
        await controller.TickHealthAsync();
        await controller.TickHealthAsync();
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
    }

    [Fact]
    public async Task A_stop_with_no_document_is_not_followed_by_a_start()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.Override = call => call.Names("stop.ps1", "-Component", "Gateway")
            ? Doc.Failure(call, ScriptFailure.TimedOut)
            : null;

        Assert.False(await controller.RequestRestartGatewayAsync());
        Assert.Single(harness.Runtime.Calls.Skip(before));
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
    }

    [Fact]
    public async Task Active_jobs_are_asked_about_and_a_no_touches_nothing()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.JobsActive = 2;
        harness.Prompts.JobsAnswer = false;

        Assert.False(await controller.RequestRestartGatewayAsync());
        Assert.Equal(["jobs:RestartGateway:2"], harness.Prompts.Asked);
        Assert.Equal(before, harness.Runtime.Calls.Count);
        Assert.Equal(LauncherState.Ready, harness.Model.State);
        Assert.True(harness.Model.CanRestartGateway);
    }

    [Fact]
    public async Task Active_jobs_answered_yes_restart()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.JobsActive = 1;
        Assert.True(await controller.RequestRestartGatewayAsync());
        Assert.Equal(["jobs:RestartGateway:1"], harness.Prompts.Asked);
    }

    [Fact]
    public async Task No_active_jobs_means_no_question()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.JobsActive = 0;
        Assert.True(await controller.RequestRestartGatewayAsync());
        Assert.Empty(harness.Prompts.Asked);
    }
}

public sealed class SyncCommandTests
{
    [Fact]
    public async Task A_sync_that_writes_definitions_restarts_the_Gateway_and_reports_a_summary()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.DefinitionsWritten = 2;
        harness.Runtime.SyncAttention = 1;

        Assert.True(await controller.RequestSyncWorkflowsAsync());

        Assert.Equal(
            ["sync-workflows.ps1 -Json", "stop.ps1 -Component Gateway -Json", "start.ps1 -Component Gateway -Json"],
            harness.Runtime.CallNames.Skip(before));
        Assert.Equal(LauncherState.Attention, harness.Model.State);
        var summary = Assert.Single(harness.Prompts.Messages);
        Assert.Equal(MessageKind.SyncSummary, summary.Kind);
        Assert.Equal(LauncherText.SyncCompleted, summary.Title);
        Assert.Equal("Updated: 2, Needs review: 1", summary.Text);
        Assert.Contains(LauncherState.Syncing, harness.States);
    }

    [Fact]
    public async Task A_sync_that_writes_nothing_does_not_restart()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;

        Assert.True(await controller.RequestSyncWorkflowsAsync());
        Assert.Equal(["sync-workflows.ps1 -Json"], harness.Runtime.CallNames.Skip(before));
        Assert.Equal(LauncherState.Ready, harness.Model.State);
        Assert.Equal("Updated: 0, Needs review: 0", Assert.Single(harness.Prompts.Messages).Text);
    }

    [Fact]
    public async Task A_sync_that_clears_the_attention_returns_to_Ready()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.CheckAttention = 1;
        var controller = await harness.StartAndWaitAsync(LauncherState.Attention);
        harness.Runtime.DefinitionsWritten = 1;
        harness.Runtime.SyncAttention = 0;

        Assert.True(await controller.RequestSyncWorkflowsAsync());
        Assert.Equal(LauncherState.Ready, harness.Model.State);
    }

    [Fact]
    public async Task A_failed_sync_restarts_nothing_and_says_so()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.Override = call => call.Names("sync-workflows.ps1")
            ? Doc.Outcome(call, Doc.Sync(false, 0, 0, 0, exitCode: 2, ok: false, what: "A source folder cannot be read"))
            : null;

        Assert.False(await controller.RequestSyncWorkflowsAsync());
        Assert.Equal(["sync-workflows.ps1 -Json"], harness.Runtime.CallNames.Skip(before));
        Assert.Equal(MessageKind.SyncFailed, Assert.Single(harness.Prompts.Messages).Kind);
        Assert.Equal(LauncherState.Attention, harness.Model.State);
    }

    [Fact]
    public async Task Active_jobs_declined_after_a_sync_leave_the_Gateway_running()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.DefinitionsWritten = 1;
        harness.Runtime.JobsActive = 1;
        harness.Prompts.JobsAnswer = false;

        Assert.True(await controller.RequestSyncWorkflowsAsync());
        Assert.Equal(["sync-workflows.ps1 -Json"], harness.Runtime.CallNames.Skip(before));
        Assert.Equal(["jobs:RestartGateway:1"], harness.Prompts.Asked);
        Assert.Equal(LauncherState.Ready, harness.Model.State);
    }
}

public sealed class ExitTests
{
    [Fact]
    public async Task Exit_is_stop_ps1_for_everything_and_nothing_else()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        var ended = 0;
        controller.ExitCompleted += () => Interlocked.Increment(ref ended);

        Assert.True(await controller.RequestExitAsync());

        var stop = Assert.Single(harness.Runtime.Calls.Skip(before));
        Assert.Equal("stop.ps1", stop.Script);
        Assert.Empty(stop.Arguments);
        Assert.Equal(LauncherCalls.StopAllTimeout, stop.Timeout);
        Assert.True(controller.Completion.IsCompleted);
        Assert.Equal(1, ended);
        Assert.Equal(LauncherState.Stopping, harness.Model.State);
        Assert.Empty(harness.Prompts.Messages);
    }

    [Fact]
    public async Task Active_jobs_are_asked_about_and_Cancel_keeps_running()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.JobsActive = 3;
        harness.Prompts.JobsAnswer = false;

        Assert.False(await controller.RequestExitAsync());
        Assert.Equal(["jobs:Exit:3"], harness.Prompts.Asked);
        Assert.Equal(before, harness.Runtime.Calls.Count);
        Assert.False(controller.Completion.IsCompleted);
        Assert.True(harness.Model.CanExit);

        harness.Prompts.JobsAnswer = true;
        Assert.True(await controller.RequestExitAsync());
        Assert.Equal("stop.ps1 -Json", harness.Runtime.CallNames[^1]);
    }

    [Fact]
    public async Task An_unreachable_Gateway_says_nothing_about_jobs()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.JobsActive = 3;
        harness.Runtime.LiveInstance = null;

        Assert.True(await controller.RequestExitAsync());
        Assert.Empty(harness.Prompts.Asked);
    }

    [Fact]
    public async Task A_stop_that_left_something_running_is_reported()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.StopComfyAction = "record_kept";
        harness.Runtime.StopComfyResult = null;

        Assert.True(await controller.RequestExitAsync());
        var message = Assert.Single(harness.Prompts.Messages);
        Assert.Equal(MessageKind.StopIncomplete, message.Kind);
        Assert.Contains("ComfyUI (PID 4100)", message.Text);
    }

    [Fact]
    public async Task Exit_asked_during_startup_waits_its_turn_and_never_overlaps_a_script()
    {
        await using var harness = new ControllerHarness();
        var release = new TaskCompletionSource();
        var running = 0;
        var overlapped = false;
        harness.Runtime.BeforeAnswer = async (call, token) =>
        {
            if (Interlocked.Increment(ref running) > 1)
            {
                overlapped = true;
            }
            try
            {
                if (call.Names("start.ps1", "-Component", "Comfy"))
                {
                    await release.Task.WaitAsync(token);
                }
            }
            finally
            {
                Interlocked.Decrement(ref running);
            }
        };
        harness.Start();
        await harness.WaitForAsync(_ => harness.Runtime.Calls.Any(call => call.Script == "start.ps1"), "the ComfyUI start");
        var exit = harness.Controller.RequestExitAsync();
        await Task.Delay(100);
        Assert.False(exit.IsCompleted);
        release.SetResult();

        Assert.True(await exit.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.False(overlapped);
        Assert.Equal("stop.ps1 -Json", harness.Runtime.CallNames[^1]);
    }
}

public sealed class SessionEndTests
{
    [Fact]
    public async Task Session_end_stops_everything_without_asking_even_with_active_jobs()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.JobsActive = 2;
        var before = harness.Runtime.Calls.Count;

        var finished = await Task.Run(() => controller.EndSession(TimeSpan.FromSeconds(10)));

        Assert.True(finished);
        Assert.Empty(harness.Prompts.Asked);
        var stop = Assert.Single(harness.Runtime.Calls.Skip(before));
        Assert.Equal("stop.ps1", stop.Script);
        Assert.Empty(stop.Arguments);
        Assert.Equal(TimeSpan.FromSeconds(10), stop.Timeout);
        Assert.True(controller.Completion.IsCompleted);
    }

    [Fact]
    public async Task Session_end_during_an_open_question_does_not_wait_for_the_answer()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Changes = 2;
        harness.Prompts.Hold = new TaskCompletionSource();
        harness.Start();
        await harness.WaitForAsync(_ => !harness.Prompts.Asked.IsEmpty, "the sync question");

        var finished = await Task.Run(() => harness.Controller.EndSession(TimeSpan.FromSeconds(10)));

        Assert.True(finished);
        Assert.Equal("stop.ps1 -Json", harness.Runtime.CallNames[^1]);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("sync-workflows.ps1"));
    }

    [Fact]
    public async Task Session_end_during_a_script_abandons_the_wait_and_stops()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.BeforeAnswer = async (call, token) =>
        {
            if (call.Names("start.ps1", "-Component", "Comfy"))
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
            }
        };
        harness.Start();
        await harness.WaitForAsync(_ => harness.Runtime.Calls.Any(call => call.Script == "start.ps1"), "the ComfyUI start");

        var finished = await Task.Run(() => harness.Controller.EndSession(TimeSpan.FromSeconds(10)));

        Assert.True(finished);
        Assert.Equal("stop.ps1 -Json", harness.Runtime.CallNames[^1]);
        Assert.Empty(harness.Prompts.Failures);
    }
}

public sealed class StaleRecoveryTests
{
    [Fact]
    public async Task Leftovers_of_a_crashed_launcher_are_adopted_through_the_scripts()
    {
        // What start.ps1 reports when the previous launcher died: its ComfyUI
        // is reused on its ownership record, and its Gateway -- still answering
        // with the instance id its record carries -- is reused, not replaced.
        await using var harness = new ControllerHarness();
        var survivor = FakeRuntime.InstanceId(0xdead);
        harness.Runtime.LiveInstance = survivor;
        harness.Runtime.ReuseInstance = survivor;
        await harness.StartAndWaitAsync(LauncherState.Ready);

        Assert.Equal(
            ["status.ps1 -Json", "start.ps1 -Component Comfy -Json", "sync-workflows.ps1 -DryRun -NoConvert -Json", "start.ps1 -Component Gateway -Json"],
            harness.Runtime.CallNames);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Script == "stop.ps1");
        Assert.Equal(survivor, harness.Model.InstanceId);
        Assert.Equal("ComfyUI: Ready", harness.Model.ComfyLine);
    }
}

public sealed class BusyTests
{
    [Fact]
    public async Task A_second_command_while_one_runs_is_refused_not_queued()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var release = new TaskCompletionSource();
        harness.Runtime.BeforeAnswer = async (call, token) =>
        {
            if (call.Names("sync-workflows.ps1"))
            {
                await release.Task.WaitAsync(token);
            }
        };
        var sync = controller.RequestSyncWorkflowsAsync();
        await harness.WaitForAsync(model => model.State == LauncherState.Syncing, "Syncing");

        Assert.True(harness.Model.Busy);
        Assert.False(harness.Model.CanRestartGateway);
        Assert.False(harness.Model.CanSyncWorkflows);
        Assert.True(harness.Model.CanExit);
        Assert.False(await controller.RequestRestartGatewayAsync());
        Assert.False(await controller.RequestSyncWorkflowsAsync());
        release.SetResult();
        Assert.True(await sync);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("stop.ps1", "-Component", "Gateway"));
    }
}
