using System.Threading.Channels;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>A monitor whose ticks the test releases one at a time.</summary>
internal sealed class ManualTicks
{
    private readonly Channel<TaskCompletionSource> _waiting = Channel.CreateUnbounded<TaskCompletionSource>();

    public async Task Delay(TimeSpan span, CancellationToken token)
    {
        var wait = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await _waiting.Writer.WriteAsync(wait, token);
        await wait.Task.WaitAsync(token);
    }

    /// <summary>Let the monitor's next wait end. Fails if the monitor is no longer waiting.</summary>
    public async Task ReleaseAsync(int seconds = 5)
    {
        var wait = await _waiting.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(seconds));
        wait.SetResult();
    }
}

public sealed class StaleProbeTests
{
    [Fact]
    public async Task A_probe_in_flight_when_a_restart_is_asked_for_is_never_applied_after_it()
    {
        var ticks = new ManualTicks();
        await using var harness = new ControllerHarness { Delay = ticks.Delay };
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        // The restart will fail: the old Gateway does not exit. It stays up and
        // goes on answering with its old id -- which is exactly what a probe
        // made before the restart would report.
        harness.Runtime.StopGatewayResult = "still-running";

        var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Runtime.HoldNextGatewayProbe = hold;
        await ticks.ReleaseAsync();
        await harness.Runtime.ProbeHeld.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var restart = controller.RequestRestartGatewayAsync();
        await Task.WhenAny(restart, Task.Delay(1000));
        hold.SetResult();

        Assert.False(await restart.WaitAsync(TimeSpan.FromSeconds(10)));
        await Task.Delay(500);
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
        Assert.Null(harness.Model.InstanceId);
        // Nothing after the failed restart may have made it look healthy.
        var afterRestart = harness.Published.SkipWhile(model => model.State != LauncherState.Restarting).ToArray();
        Assert.DoesNotContain(afterRestart, model => model.State is LauncherState.Ready or LauncherState.Attention);
    }
}

public sealed class DocumentTrustTests
{
    private static string WithoutOk(string json)
    {
        var stripped = json.Replace("\"ok\":true,", string.Empty, StringComparison.Ordinal);
        Assert.NotEqual(json, stripped);
        return stripped;
    }

    [Fact]
    public async Task A_start_document_without_ok_is_a_failure()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Override = call => call.Names("start.ps1", "-Component", "Comfy")
            ? Doc.Outcome(call, WithoutOk(Doc.StartComfy("ready", "owned", 4100)))
            : null;
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.Single(harness.Prompts.Failures);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
        Assert.DoesNotContain(LauncherState.Ready, harness.States);
    }

    [Fact]
    public async Task A_workflow_check_document_without_ok_is_a_check_that_did_not_complete()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.Changes = 2;
        harness.Runtime.Override = call => call.Names("sync-workflows.ps1", "-DryRun", "-NoConvert")
            ? Doc.Outcome(call, WithoutOk(Doc.Sync(true, 2, 0, 0)))
            : null;
        await harness.StartAndWaitAsync(LauncherState.Attention);

        Assert.Empty(harness.Prompts.Asked);
        Assert.Equal("Workflows: 4 (check did not complete)", harness.Model.WorkflowsLine);
    }

    [Fact]
    public async Task A_Gateway_stop_document_without_ok_blocks_the_start()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.Override = call => call.Names("stop.ps1", "-Component", "Gateway")
            ? Doc.Outcome(call, WithoutOk(Doc.Stop("Gateway", "stop", "terminated", "skipped", null)))
            : null;

        Assert.False(await controller.RequestRestartGatewayAsync());
        Assert.Equal(["stop.ps1 -Component Gateway -Json"], harness.Runtime.CallNames.Skip(before));
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
    }

    [Fact]
    public async Task A_Gateway_stop_document_without_the_gateway_role_blocks_the_start()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var before = harness.Runtime.Calls.Count;
        harness.Runtime.Override = call => call.Names("stop.ps1", "-Component", "Gateway")
            ? Doc.Outcome(call, Doc.Envelope(0) + ",\"component\":\"Gateway\",\"roles\":{\"comfy\":{\"state_before\":null,\"action\":\"skipped\",\"result\":null,\"pid\":null}}}")
            : null;

        Assert.False(await controller.RequestRestartGatewayAsync());
        Assert.Equal(["stop.ps1 -Component Gateway -Json"], harness.Runtime.CallNames.Skip(before));
        Assert.Equal(LauncherState.GatewayDown, harness.Model.State);
    }

    [Fact]
    public async Task An_exit_whose_stop_reports_no_roles_is_not_reported_as_a_clean_stop()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.Override = call => call.Names("stop.ps1")
            ? Doc.Outcome(call, Doc.Envelope(0) + ",\"component\":\"All\"}")
            : null;

        Assert.True(await controller.RequestExitAsync());

        Assert.Equal("status.ps1 -Json", harness.Runtime.CallNames[^1]);
        var message = Assert.Single(harness.Prompts.Messages);
        Assert.Equal(MessageKind.StopIncomplete, message.Kind);
        Assert.Contains("The Gateway (PID 5001) is still running", message.Text, StringComparison.Ordinal);
        Assert.DoesNotContain(harness.Log.Lines, line => line.Contains("everything LocalCanvas started has stopped", StringComparison.Ordinal));
    }

    [Fact]
    public async Task An_exit_whose_stop_reports_no_roles_and_cannot_be_confirmed_says_so()
    {
        await using var harness = new ControllerHarness();
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        var stopped = false;
        harness.Runtime.Override = call =>
        {
            if (call.Names("stop.ps1"))
            {
                stopped = true;
                return Doc.Outcome(call, Doc.Envelope(0) + ",\"component\":\"All\"}");
            }
            return stopped && call.Names("status.ps1") ? Doc.Failure(call, ScriptFailure.NoDocument, "It printed nothing.", 1) : null;
        };

        Assert.True(await controller.RequestExitAsync());

        var message = Assert.Single(harness.Prompts.Messages);
        Assert.Contains("stop.ps1 did not report what became of the Gateway.", message.Text, StringComparison.Ordinal);
        Assert.Contains("What is still running could not be confirmed", message.Text, StringComparison.Ordinal);
        Assert.DoesNotContain(harness.Log.Lines, line => line.Contains("everything LocalCanvas started has stopped", StringComparison.Ordinal));
    }
}

public sealed class LauncherTimeoutTests
{
    private static ScriptOutcome TimedOut(ScriptCall call, Task stillRunning) =>
        new(call, ScriptFailure.TimedOut, null, null, "[INFO] still waiting", call.Timeout, "PID 7100", 7100, stillRunning);

    [Fact]
    public async Task A_timed_out_start_is_waited_for_before_anything_is_stopped()
    {
        await using var harness = new ControllerHarness();
        var inFlight = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Runtime.Override = call => call.Names("start.ps1", "-Component", "Gateway") ? TimedOut(call, inFlight.Task) : null;
        harness.Start();
        await harness.WaitForAsync(_ => harness.Runtime.Calls.Any(call => call.Names("start.ps1", "-Component", "Gateway")), "the Gateway start");

        await Task.Delay(700);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Script == "stop.ps1");
        Assert.Empty(harness.Prompts.Failures);
        var ended = DateTime.UtcNow;
        harness.Runtime.LiveInstance = FakeRuntime.InstanceId(90);
        inFlight.SetResult();
        await harness.WaitForExitAsync();

        var failure = Assert.Single(harness.Prompts.Failures);
        Assert.Contains("did not finish within", failure.What, StringComparison.Ordinal);
        Assert.Contains("It has ended since.", failure.What, StringComparison.Ordinal);
        Assert.True(harness.Runtime.Timeline.Single(entry => entry.Call == "start stop.ps1 -Json").At >= ended);
        Assert.Equal(["stop.ps1 -Json", "status.ps1 -Json"], harness.Runtime.CallNames.TakeLast(2));
        Assert.Null(harness.Runtime.LiveInstance);
        Assert.Contains(harness.Log.Lines, line => line == "exit: everything LocalCanvas started has stopped (confirmed by status.ps1)");
    }

    [Fact]
    public async Task A_timed_out_start_still_running_after_its_grace_is_reported_and_nothing_is_stopped_beside_it()
    {
        await using var harness = new ControllerHarness
        {
            Settings = new FixedSettings(new StartupTimeouts(TimeSpan.FromSeconds(30), TimeSpan.FromMilliseconds(300), true)),
        };
        var never = new TaskCompletionSource();
        harness.Runtime.Override = call =>
        {
            if (!call.Names("start.ps1", "-Component", "Gateway"))
            {
                return null;
            }
            harness.Runtime.LiveInstance = FakeRuntime.InstanceId(91);
            return TimedOut(call, never.Task);
        };
        harness.Start();
        await harness.WaitForExitAsync();

        var failure = Assert.Single(harness.Prompts.Failures);
        Assert.Contains("It is still running (PID 7100)", failure.What, StringComparison.Ordinal);
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Script == "stop.ps1");
        Assert.Equal("status.ps1 -Json", harness.Runtime.CallNames[^1]);
        var message = Assert.Single(harness.Prompts.Messages);
        Assert.Equal(MessageKind.StopIncomplete, message.Kind);
        Assert.Contains("start.ps1 (PID 7100) was still running, so stop.ps1 was not run beside it", message.Text, StringComparison.Ordinal);
        Assert.Contains($"answers as instance {FakeRuntime.InstanceId(91)}", message.Text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Nothing_is_run_beside_a_call_still_running_after_its_grace()
    {
        await using var harness = new ControllerHarness
        {
            CallPolicy = call => call.Script == "sync-workflows.ps1" ? call with { Grace = TimeSpan.FromMilliseconds(200) } : call,
        };
        var never = new TaskCompletionSource();
        harness.Runtime.Override = call => call.Names("sync-workflows.ps1", "-DryRun", "-NoConvert") ? TimedOut(call, never.Task) : null;
        harness.Start();
        await harness.WaitForExitAsync();

        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Names("start.ps1", "-Component", "Gateway"));
        Assert.DoesNotContain(harness.Runtime.Calls, call => call.Script == "stop.ps1");
        Assert.Contains("sync-workflows.ps1 (PID 7100) from an earlier step is still running", Assert.Single(harness.Prompts.Failures).What, StringComparison.Ordinal);
    }
}

public sealed class MonitorRobustnessTests
{
    [Fact]
    public async Task A_tick_that_throws_something_unexpected_does_not_end_the_monitor()
    {
        var ticks = new ManualTicks();
        await using var harness = new ControllerHarness { Delay = ticks.Delay };
        await harness.StartAndWaitAsync(LauncherState.Ready);

        harness.Runtime.ThrowOnNextGatewayProbe = new NotSupportedException("an address the client cannot use");
        await ticks.ReleaseAsync();
        await harness.WaitForAsync(_ => harness.Log.Text.Contains("monitor continues", StringComparison.Ordinal), "the monitor to log the failure");

        harness.Runtime.LiveInstance = null;
        await ticks.ReleaseAsync();
        await ticks.ReleaseAsync();
        await harness.WaitForAsync(model => model.State == LauncherState.GatewayDown, "GatewayDown after the unexpected failure");
    }
}

public sealed class SessionBudgetTests
{
    [Fact]
    public void The_session_end_budget_is_45_seconds() =>
        Assert.Equal(TimeSpan.FromSeconds(45), LifecycleController.DefaultSessionEndBound);

    [Fact]
    public async Task With_nothing_measured_the_reserve_is_the_assumption()
    {
        await using var harness = new ControllerHarness();
        var controller = harness.Create();
        // 1.5 x (8 s + 10 s), under the cap of two thirds of 45 s.
        Assert.Equal(TimeSpan.FromSeconds(27), controller.StopAndConfirmReserve());
    }

    [Fact]
    public async Task The_reserve_follows_what_stop_and_status_took_in_this_session()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.DurationOf = call => call.Script switch
        {
            "status.ps1" => TimeSpan.FromSeconds(8),
            "stop.ps1" => TimeSpan.FromSeconds(5),
            _ => TimeSpan.FromMilliseconds(5),
        };
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        // status.ps1 measured at startup, stop.ps1 still assumed: 1.5 x (8 + 8).
        Assert.Equal(TimeSpan.FromSeconds(24), controller.StopAndConfirmReserve());

        Assert.True(await controller.RequestRestartGatewayAsync());
        // stop.ps1 measured by the restart: 1.5 x (5 + 8).
        Assert.Equal(TimeSpan.FromSeconds(19.5), controller.StopAndConfirmReserve());
    }

    [Fact]
    public async Task The_reserve_has_a_floor_and_leaves_the_call_in_flight_a_third_of_the_budget()
    {
        await using var harness = new ControllerHarness();
        harness.Runtime.DurationOf = call => call.Script == "status.ps1" ? TimeSpan.FromMilliseconds(100) : TimeSpan.FromMilliseconds(5);
        var controller = await harness.StartAndWaitAsync(LauncherState.Ready);
        harness.Runtime.DurationOf = call => call.Script == "stop.ps1" ? TimeSpan.FromMilliseconds(100) : TimeSpan.FromMilliseconds(5);
        Assert.True(await controller.RequestRestartGatewayAsync());
        Assert.Equal(TimeSpan.FromSeconds(10), controller.StopAndConfirmReserve());

        harness.Runtime.DurationOf = call => call.Script == "stop.ps1" ? TimeSpan.FromSeconds(40) : TimeSpan.FromMilliseconds(5);
        Assert.True(await controller.RequestRestartGatewayAsync());
        Assert.Equal(TimeSpan.FromSeconds(30), controller.StopAndConfirmReserve());
    }
}