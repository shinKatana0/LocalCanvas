using System.Diagnostics;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>The Gateway health probe against real loopback listeners on ephemeral ports.</summary>
public sealed class HealthProbeTests
{
    private const string Expected = "0123456789abcdef0123456789abcdef";
    private const string Other = "fedcba9876543210fedcba9876543210";

    private static async Task<GatewayHealth> ProbeAsync(Func<string, LoopbackServer.Reply?> answer, string? expected = Expected)
    {
        await using var server = new LoopbackServer(answer);
        using var probe = new HttpHealthProbe();
        return await probe.ProbeGatewayAsync(server.Url("/api/v1/info"), expected);
    }

    [Fact]
    public async Task The_expected_instance_is_Ready_and_reports_its_jobs()
    {
        var health = await ProbeAsync(path => path == "/api/v1/info" ? LoopbackServer.Info(Expected, jobs: 2) : null);
        Assert.True(health.Ready, health.Reason);
        Assert.Equal(2, health.JobsActive);
        Assert.Equal(Expected, health.InstanceId);
    }

    [Fact]
    public async Task Another_LocalCanvas_instance_is_not_Ready()
    {
        var health = await ProbeAsync(_ => LoopbackServer.Info(Other, jobs: 5));
        Assert.False(health.Ready);
        Assert.Null(health.JobsActive);
        Assert.Contains(Other, health.Reason);
    }

    [Fact]
    public async Task A_LocalCanvas_answer_without_an_instance_id_is_not_Ready()
    {
        var health = await ProbeAsync(_ => LoopbackServer.Info(null));
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task No_expected_instance_is_never_Ready_whatever_answers()
    {
        var health = await ProbeAsync(_ => LoopbackServer.Info(Expected), expected: null);
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task An_HTML_page_is_not_Ready()
    {
        var health = await ProbeAsync(_ => new LoopbackServer.Reply(200, "text/html", "<!doctype html><html><body>Sign in</body></html>"));
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task An_unrelated_JSON_service_is_not_Ready_even_with_the_right_id()
    {
        var health = await ProbeAsync(_ => LoopbackServer.Info(Expected, service: "something-else"));
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task An_empty_JSON_object_is_not_Ready()
    {
        var health = await ProbeAsync(_ => LoopbackServer.Json("{}"));
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task The_right_body_with_an_error_status_is_not_Ready()
    {
        var health = await ProbeAsync(_ => new LoopbackServer.Reply(503, "application/json", LoopbackServer.Info(Expected).Body));
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task An_open_port_that_never_answers_is_not_Ready_within_the_probe_timeout()
    {
        await using var server = new LoopbackServer(_ => null);
        using var probe = new HttpHealthProbe();
        var clock = Stopwatch.StartNew();
        var health = await probe.ProbeGatewayAsync(server.Url("/api/v1/info"), Expected);
        clock.Stop();

        Assert.False(health.Ready);
        Assert.Equal(1, server.Requests);
        Assert.InRange(clock.Elapsed, HttpHealthProbe.ProbeTimeout - TimeSpan.FromMilliseconds(200), HttpHealthProbe.ProbeTimeout + TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task Nothing_listening_is_not_Ready()
    {
        using var probe = new HttpHealthProbe();
        var port = LoopbackServer.UnusedPort();
        var health = await probe.ProbeGatewayAsync(new Uri($"http://127.0.0.1:{port}/api/v1/info"), Expected);
        Assert.False(health.Ready);
    }

    [Fact]
    public async Task Every_probe_opens_a_fresh_connection()
    {
        await using var server = new LoopbackServer(_ => LoopbackServer.Info(Expected));
        using var probe = new HttpHealthProbe();
        for (var i = 0; i < 3; i++)
        {
            Assert.True((await probe.ProbeGatewayAsync(server.Url("/api/v1/info"), Expected)).Ready);
        }
        Assert.Equal(3, server.Requests);
    }

    [Fact]
    public async Task ComfyUI_is_up_only_on_HTTP_200_from_system_stats()
    {
        var up = true;
        await using var server = new LoopbackServer(path => path == "/system_stats"
            ? (up ? LoopbackServer.Json("{\"system\":{}}") : LoopbackServer.Json("{\"error\":\"loading\"}", 503))
            : LoopbackServer.Json("{}", 404));
        using var probe = new HttpHealthProbe();
        Assert.True(await probe.ProbeComfyAsync(new Uri($"http://127.0.0.1:{server.Port}")));
        up = false;
        Assert.False(await probe.ProbeComfyAsync(new Uri($"http://127.0.0.1:{server.Port}")));
        Assert.False(await probe.ProbeComfyAsync(new Uri($"http://127.0.0.1:{LoopbackServer.UnusedPort()}")));
    }

    [Fact]
    public async Task The_workflow_count_is_the_length_of_workflows()
    {
        await using var server = new LoopbackServer(path => path == "/api/v1/workflows"
            ? LoopbackServer.Json("{\"workflows\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"}]}")
            : null);
        using var probe = new HttpHealthProbe();
        Assert.Equal(3, await probe.CountWorkflowsAsync(new Uri($"http://127.0.0.1:{server.Port}/")));
    }

    [Theory]
    [InlineData("http://127.0.0.1:17810/api/v1/info", "http://127.0.0.1:17810/api/v1/info")]
    [InlineData("http://127.0.0.1:17810", "http://127.0.0.1:17810/api/v1/info")]
    [InlineData("http://[::1]:17810/", "http://[::1]:17810/api/v1/info")]
    public void The_info_url_is_taken_from_the_probe_url(string probeUrl, string expected) =>
        Assert.Equal(expected, HttpHealthProbe.InfoUrlFrom(probeUrl).ToString());
}
