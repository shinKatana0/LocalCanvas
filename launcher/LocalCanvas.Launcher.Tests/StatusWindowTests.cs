using LocalCanvas.Launcher.Core;
using LocalCanvas.Launcher.Shell;

namespace LocalCanvas.Launcher.Tests;

/// <summary>A fake <see cref="IQrCommand"/>: no PowerShell, no python, just what the status window asked for.</summary>
internal sealed class FakeQrCommand : IQrCommand
{
    public Func<string, string?>? Result { get; set; }
    public readonly List<string> Requested = [];

    /// <summary>
    /// A request for this endpoint waits here before answering -- and
    /// deliberately does not observe <paramref name="cancellationToken"/>
    /// while doing so: the real seam's own process is never ended either, so
    /// a "cancelled" (superseded) request can still complete normally, late.
    /// </summary>
    public readonly Dictionary<string, TaskCompletionSource> Holds = new();

    public async Task<string?> WritePngAsync(string endpoint, CancellationToken cancellationToken = default)
    {
        Requested.Add(endpoint);
        if (Holds.TryGetValue(endpoint, out var hold))
        {
            await hold.Task.ConfigureAwait(false);
        }
        return Result?.Invoke(endpoint);
    }
}

/// <summary>A fake <see cref="ITextClipboard"/>: records exactly what was set, nothing touches the real clipboard.</summary>
internal sealed class FakeClipboard : ITextClipboard
{
    public readonly List<string> Texts = [];

    public void SetText(string text) => Texts.Add(text);
}

public sealed class StatusWindowTests : IDisposable
{
    private const string Root = @"X:\LocalCanvas";
    private readonly List<string> _restarts = [];
    private readonly FakeQrCommand _qr = new();
    private readonly FakeClipboard _clipboard = new();
    private StatusWindow? _window;

    private static TrayViewModel Model(
        LauncherState state = LauncherState.Ready,
        string gatewayLine = "Gateway: Ready",
        string comfyLine = "ComfyUI: Ready",
        string workflowsLine = "Workflows: 4",
        bool canRestart = true,
        string? publishedEndpoint = "http://192.0.2.10:7801",
        int? ready = 4,
        int? needALook = 0,
        string? problem = null) => new(
        state, TrayViewModel.TooltipFor(state), gatewayLine, comfyLine, workflowsLine,
        Busy: false, CanRestartGateway: canRestart, CanSyncWorkflows: true, CanOpenStatus: true, CanExit: true,
        Problem: problem, PublishedEndpoint: publishedEndpoint, InstanceId: null, ComfyUrl: null, LogPath: @"X:\LocalCanvas\.runtime\launcher.log",
        WorkflowsReady: ready, WorkflowsNeedALook: needALook);

    private StatusWindow NewWindow()
    {
        _window = new StatusWindow(() => _restarts.Add("restart"), Root, _qr, _clipboard);
        // A Control's own Visible getter follows its parent chain: an
        // un-shown Form reads every child as invisible regardless of what
        // was set on the child. Shown off-screen (the same trick
        // SessionWindow uses), the window is never seen by anyone, and
        // children report their own real state.
        _window.StartPosition = FormStartPosition.Manual;
        _window.Location = new Point(-32000, -32000);
        _window.ShowInTaskbar = false;
        _window.Show();
        return _window;
    }

    [Fact]
    public void Apply_shows_gateway_status_endpoint_comfy_status_and_workflow_counts()
    {
        var window = NewWindow();
        window.Apply(Model(gatewayLine: "Gateway: Ready", comfyLine: "ComfyUI: Ready (external)", ready: 7, needALook: 2));

        Assert.Equal("Status: Ready", TextOf(window, "Gateway status"));
        Assert.Equal("Endpoint: http://192.0.2.10:7801", TextOf(window, "Endpoint"));
        Assert.Equal("Status: Ready (external)", TextOf(window, "ComfyUI status"));
        Assert.Equal("Ready: 7", TextOf(window, "Workflows ready"));
        Assert.Equal("Needs a look: 2", TextOf(window, "Workflows needing a look"));
    }

    [Fact]
    public void No_endpoint_yet_is_said_plainly_and_disables_Copy_address()
    {
        var window = NewWindow();
        window.Apply(Model(publishedEndpoint: null, ready: null));

        Assert.Equal("Endpoint: not published yet", TextOf(window, "Endpoint"));
        Assert.False(((Control)Find(window, "Copy address")).Enabled);
        Assert.Equal("Ready: -", TextOf(window, "Workflows ready"));
    }

    [Fact]
    public void Restart_Gateway_is_offered_only_while_the_Gateway_is_down()
    {
        var window = NewWindow();

        window.Apply(Model(LauncherState.Ready));
        Assert.False(((Control)Find(window, "Restart Gateway")).Visible);

        window.Apply(Model(LauncherState.GatewayDown, gatewayLine: "Gateway: DOWN", canRestart: true));
        var restart = (Control)Find(window, "Restart Gateway");
        Assert.True(restart.Visible);
        Assert.True(restart.Enabled);

        window.Apply(Model(LauncherState.Ready));
        Assert.False(((Control)Find(window, "Restart Gateway")).Visible);
    }

    [Fact]
    public void Restart_Gateway_click_reaches_the_action_it_was_given()
    {
        var window = NewWindow();
        window.Apply(Model(LauncherState.GatewayDown, gatewayLine: "Gateway: DOWN"));
        ((Button)Find(window, "Restart Gateway")).PerformClick();
        Assert.Equal(["restart"], _restarts);
    }

    [Fact]
    public void The_QR_command_is_asked_for_the_published_endpoint_and_shown_on_success()
    {
        var pngPath = Path.Combine(Path.GetTempPath(), $"lc-status-window-test-{Guid.NewGuid():N}.png");
        File.WriteAllBytes(pngPath, OnePixelPng());
        try
        {
            _qr.Result = endpoint => endpoint == "http://192.0.2.10:7801" ? pngPath : null;
            var window = NewWindow();
            window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801"));

            Assert.Equal(["http://192.0.2.10:7801"], _qr.Requested);
            Assert.True(IsQrShown(window), "the QR image should be visible once the command succeeds");
            Assert.False(((Control)Find(window, "QR fallback")).Visible);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    public void When_the_QR_command_fails_the_address_is_shown_on_its_own()
    {
        _qr.Result = _ => null;
        var window = NewWindow();
        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801"));

        Assert.Equal(["http://192.0.2.10:7801"], _qr.Requested);
        Assert.False(IsQrShown(window));
        Assert.Contains("No pairing QR available", TextOf(window, "QR fallback"), StringComparison.Ordinal);
        Assert.Contains("address", TextOf(window, "QR fallback"), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Applying_the_same_endpoint_again_does_not_ask_the_QR_command_a_second_time()
    {
        _qr.Result = _ => null;
        var window = NewWindow();
        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801"));
        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801", gatewayLine: "Gateway: Ready"));
        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801", ready: 9));

        Assert.Equal(["http://192.0.2.10:7801"], _qr.Requested);
    }

    [Fact]
    public void A_changed_endpoint_is_asked_for_again()
    {
        _qr.Result = _ => null;
        var window = NewWindow();
        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801"));
        window.Apply(Model(publishedEndpoint: "http://192.0.2.11:7801"));

        Assert.Equal(["http://192.0.2.10:7801", "http://192.0.2.11:7801"], _qr.Requested);
    }

    [Fact]
    public void The_Endpoint_label_follows_a_changed_endpoint()
    {
        _qr.Result = _ => null;
        var window = NewWindow();

        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801"));
        Assert.Equal("Endpoint: http://192.0.2.10:7801", TextOf(window, "Endpoint"));

        window.Apply(Model(publishedEndpoint: "http://192.0.2.11:7801"));
        Assert.Equal("Endpoint: http://192.0.2.11:7801", TextOf(window, "Endpoint"));

        window.Apply(Model(publishedEndpoint: null));
        Assert.Equal("Endpoint: not published yet", TextOf(window, "Endpoint"));
    }

    [Fact]
    public void Copy_address_copies_exactly_the_shown_endpoint()
    {
        _qr.Result = _ => null;
        var window = NewWindow();
        const string Endpoint = "http://192.0.2.10:7801";
        window.Apply(Model(publishedEndpoint: Endpoint));

        ((Button)Find(window, "Copy address")).PerformClick();

        var copied = Assert.Single(_clipboard.Texts);
        Assert.Equal(Endpoint, copied);
        Assert.Equal("Endpoint: " + Endpoint, TextOf(window, "Endpoint"));
    }

    [Fact]
    public void Copy_address_follows_a_changed_endpoint_too()
    {
        _qr.Result = _ => null;
        var window = NewWindow();
        window.Apply(Model(publishedEndpoint: "http://192.0.2.10:7801"));
        window.Apply(Model(publishedEndpoint: "http://192.0.2.11:7801"));

        ((Button)Find(window, "Copy address")).PerformClick();

        Assert.Equal(["http://192.0.2.11:7801"], _clipboard.Texts);
    }

    [Fact]
    public void A_superseded_requests_late_result_never_overwrites_the_newer_one()
    {
        const string EndpointA = "http://192.0.2.10:7801";
        const string EndpointB = "http://192.0.2.11:7801";
        var pngPath = Path.Combine(Path.GetTempPath(), $"lc-status-window-test-{Guid.NewGuid():N}.png");
        File.WriteAllBytes(pngPath, OnePixelPng());
        try
        {
            var holdA = new TaskCompletionSource();
            _qr.Holds[EndpointA] = holdA;
            // A succeeds (late) with a real image; B fails (fast) with no
            // image. If A's late, superseded result were ever applied, the
            // QR image would wrongly appear after B already settled on its
            // fallback text.
            _qr.Result = endpoint => endpoint == EndpointA ? pngPath : null;

            var window = NewWindow();
            window.Apply(Model(publishedEndpoint: EndpointA));
            Assert.Equal([EndpointA], _qr.Requested);

            window.Apply(Model(publishedEndpoint: EndpointB));
            Assert.Equal([EndpointA, EndpointB], _qr.Requested);
            Assert.False(IsQrShown(window), "B's (fast, failing) result should already be showing the fallback");
            Assert.Contains("No pairing QR available", TextOf(window, "QR fallback"), StringComparison.Ordinal);

            // A's held request now completes, out of order, after B already
            // settled. Its continuation resumes on a thread-pool thread (the
            // same as the real seam resuming after real process I/O), so it
            // is marshalled through BeginInvoke -- pumped here the way the
            // launcher's own message loop would in the real app.
            holdA.SetResult();
            PumpMessages();

            Assert.False(IsQrShown(window), "A's late, superseded result must never overwrite B's");
            Assert.Contains("No pairing QR available", TextOf(window, "QR fallback"), StringComparison.Ordinal);
            Assert.Equal("Endpoint: " + EndpointB, TextOf(window, "Endpoint"));
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    public void The_inner_guard_discards_a_result_already_queued_before_it_was_superseded()
    {
        // The scenario the OUTER guard (checked right after the await,
        // before anything is queued) cannot cover: A's endpoint is still the
        // one expected at that moment, so the outer check passes and its
        // Apply is queued via BeginInvoke. Only after that is B applied,
        // superseding A -- so only the guard INSIDE the queued Apply can
        // still discard A's result once messages are finally pumped.
        const string EndpointA = "http://192.0.2.10:7801";
        const string EndpointB = "http://192.0.2.11:7801";
        var pngPath = Path.Combine(Path.GetTempPath(), $"lc-status-window-test-{Guid.NewGuid():N}.png");
        File.WriteAllBytes(pngPath, OnePixelPng());
        try
        {
            var holdA = new TaskCompletionSource();
            _qr.Holds[EndpointA] = holdA;
            _qr.Result = endpoint => endpoint == EndpointA ? pngPath : null;

            var window = NewWindow();
            window.Apply(Model(publishedEndpoint: EndpointA));
            Assert.Equal([EndpointA], _qr.Requested);

            // Completed on a plain background thread, with B not yet
            // applied: the outer guard for A passes and BeginInvoke(Apply)
            // is called before Join() below returns. A raw Thread, joined,
            // not a Task awaited or Wait()ed: showing the window installs a
            // WindowsFormsSynchronizationContext on this thread, and an
            // async continuation captured by it would need a message pump
            // that nothing runs until after this method returns --
            // deadlocking the test. A plain thread join needs no pump, and
            // the background thread's own work needs none either
            // (BeginInvoke only posts a message; it does not wait for it to
            // be handled).
            var release = new System.Threading.Thread(() => holdA.SetResult());
            release.Start();
            release.Join();
            System.Threading.Thread.Sleep(200);

            // Only now does B supersede A.
            window.Apply(Model(publishedEndpoint: EndpointB));
            Assert.Equal([EndpointA, EndpointB], _qr.Requested);

            PumpMessages();

            Assert.False(IsQrShown(window), "A's result, queued before B superseded it, must still be discarded");
            Assert.Contains("No pairing QR available", TextOf(window, "QR fallback"), StringComparison.Ordinal);
            Assert.Equal("Endpoint: " + EndpointB, TextOf(window, "Endpoint"));
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    public void Close_hides_the_window_instead_of_disposing_it()
    {
        var window = NewWindow();
        window.Apply(Model());
        ((Button)Find(window, "Close")).PerformClick();
        Assert.False(window.IsDisposed);
    }

    private static byte[] OnePixelPng()
    {
        using var bitmap = new System.Drawing.Bitmap(1, 1);
        bitmap.SetPixel(0, 0, System.Drawing.Color.White);
        using var stream = new MemoryStream();
        bitmap.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
        return stream.ToArray();
    }

    /// <summary>
    /// Runs the window's own message loop briefly, the way the real
    /// launcher's <c>Application.Run</c> would: a <c>BeginInvoke</c>d
    /// continuation (a real process's exit resumes on a thread-pool thread,
    /// same as a held fake completing here) only executes once something
    /// pumps messages for it.
    /// </summary>
    private static void PumpMessages(int milliseconds = 500)
    {
        var until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (DateTime.UtcNow < until)
        {
            Application.DoEvents();
            System.Threading.Thread.Sleep(10);
        }
    }

    private static bool IsQrShown(Control root) => Find(root, "Pairing QR code") is PictureBox { Visible: true, Image: not null };

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

    public void Dispose() => _window?.Dispose();
}
