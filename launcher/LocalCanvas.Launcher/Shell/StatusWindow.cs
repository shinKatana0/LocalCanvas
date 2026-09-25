using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// The status window: Gateway status, its published endpoint, a pairing QR
/// and a Copy address button; ComfyUI status; the workflow counts; a Restart
/// Gateway button while the Gateway is down; Open logs folder; Close. A view
/// of the <see cref="TrayViewModel"/> only -- every action still runs through
/// the controller, the same as the tray menu -- and it live-updates from the
/// same snapshots the tray does, while it is open.
/// </summary>
internal sealed class StatusWindow : Form
{
    private readonly IQrCommand _qr;
    private readonly string _root;

    private readonly Label _gatewayHeader = NewHeader("Gateway");
    private readonly Label _gatewayStatus = NewLabel("Gateway status");
    private readonly Label _endpoint = NewLabel("Endpoint");
    private readonly Button _copyAddress = NewButton("Copy address");
    private readonly PictureBox _qrImage = new()
    {
        Size = new Size(160, 160),
        SizeMode = PictureBoxSizeMode.Zoom,
        BorderStyle = BorderStyle.FixedSingle,
        Margin = new Padding(0, 4, 0, 4),
        AccessibleName = "Pairing QR code",
        Visible = false,
    };
    private readonly Label _qrFallback = NewLabel("QR fallback");
    private readonly Label _comfyHeader = NewHeader("ComfyUI");
    private readonly Label _comfyStatus = NewLabel("ComfyUI status");
    private readonly Label _workflowsHeader = NewHeader("Workflows");
    private readonly Label _workflowsReady = NewLabel("Workflows ready");
    private readonly Label _workflowsAttention = NewLabel("Workflows needing a look");
    private readonly Label _problem = NewLabel("Problem");
    private readonly Label _log = NewLabel("Log");
    private readonly Button _restart = NewButton("Restart Gateway");
    private readonly Button _openLogs = NewButton("Open logs folder");
    private readonly Button _close = NewButton("Close");

    private string? _qrEndpoint;
    private CancellationTokenSource? _qrLoad;
    private Image? _qrPicture;

    public StatusWindow(Action restart, string root, string pwsh, IProcessRunner processes, ILauncherLog log)
        : this(restart, root, new GatewayQrCommand(pwsh, root, processes, log))
    {
    }

    /// <summary>For tests: a fake <see cref="IQrCommand"/> instead of a real PowerShell call.</summary>
    internal StatusWindow(Action restart, string root, IQrCommand qr)
    {
        _root = root;
        _qr = qr;

        Text = "LocalCanvas";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = true;
        ClientSize = new Size(440, 520);

        _qrFallback.Text = "No pairing QR yet.";

        var lines = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(12),
        };
        lines.Controls.AddRange(
        [
            _gatewayHeader, _gatewayStatus, _endpoint, _copyAddress, _qrImage, _qrFallback,
            _comfyHeader, _comfyStatus,
            _workflowsHeader, _workflowsReady, _workflowsAttention,
            _problem,
            _restart,
            _log,
        ]);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Padding = new Padding(8),
        };
        buttons.Controls.AddRange([_close, _openLogs]);

        Controls.Add(lines);
        Controls.Add(buttons);

        _restart.Click += (_, _) => restart();
        _copyAddress.Click += (_, _) => CopyAddress();
        _openLogs.Click += (_, _) => OpenFolder.InExplorer(LauncherLog.RuntimeDirectory(_root));
        // Same as the window's own titlebar close: the window is dismissed,
        // LocalCanvas keeps running, and the single instance is reused (not
        // re-created, with a needless second QR fetch) the next time the
        // tray's Open status is used.
        _close.Click += (_, _) => Hide();

        CancelButton = _close;
    }

    public void Apply(TrayViewModel model)
    {
        _gatewayStatus.Text = "Status: " + model.GatewayLine["Gateway: ".Length..];
        _endpoint.Text = model.PublishedEndpoint is null ? "Endpoint: not published yet" : "Endpoint: " + model.PublishedEndpoint;
        _copyAddress.Enabled = model.PublishedEndpoint is not null;
        _comfyStatus.Text = "Status: " + model.ComfyLine["ComfyUI: ".Length..];
        _workflowsReady.Text = "Ready: " + (model.WorkflowsReady?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "-");
        _workflowsAttention.Text = "Needs a look: " + (model.WorkflowsNeedALook ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        _problem.Text = model.Problem ?? string.Empty;
        _problem.Visible = model.Problem is not null;
        _log.Text = "Log: " + model.LogPath;
        _restart.Visible = model.State == LauncherState.GatewayDown;
        _restart.Enabled = model.CanRestartGateway;

        ApplyQr(model.PublishedEndpoint);
    }

    /// <summary>Fetches the QR again only when the published endpoint has actually changed.</summary>
    private void ApplyQr(string? endpoint)
    {
        if (endpoint == _qrEndpoint)
        {
            return;
        }
        _qrEndpoint = endpoint;
        _qrLoad?.Cancel();
        _qrLoad?.Dispose();
        _qrLoad = null;
        SetQrImage(null);

        if (endpoint is null)
        {
            _qrFallback.Text = "No pairing QR yet.";
            _qrFallback.Visible = true;
            return;
        }

        _qrFallback.Text = "Preparing the pairing QR…";
        _qrFallback.Visible = true;
        var cancellation = new CancellationTokenSource();
        _qrLoad = cancellation;
        _ = LoadQrAsync(endpoint, cancellation);
    }

    private async Task LoadQrAsync(string endpoint, CancellationTokenSource owner)
    {
        string? path;
        try
        {
            path = await _qr.WritePngAsync(endpoint, owner.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (owner.IsCancellationRequested || IsDisposed)
        {
            return;
        }
        void Apply()
        {
            if (owner.IsCancellationRequested || IsDisposed)
            {
                return;
            }
            ApplyQrResult(path);
        }
        try
        {
            // No handle anywhere in the chain (the window has never been
            // shown, as in a test that never calls Show()): InvokeRequired is
            // false, and the result is applied directly on this thread. Once
            // shown, the real seam's WritePngAsync genuinely goes async, so
            // this resumes on a thread-pool thread and is marshalled instead.
            if (InvokeRequired)
            {
                BeginInvoke(Apply);
            }
            else
            {
                Apply();
            }
        }
        catch (InvalidOperationException)
        {
            // The window's handle (or ObjectDisposedException, which derives
            // from it) went away between the check above and the call.
        }
    }

    private void ApplyQrResult(string? path)
    {
        if (path is null)
        {
            _qrFallback.Text = "No pairing QR available. Use the address above.";
            _qrFallback.Visible = true;
            SetQrImage(null);
            return;
        }
        try
        {
            using var stream = new MemoryStream(File.ReadAllBytes(path));
            SetQrImage(Image.FromStream(stream));
            _qrFallback.Visible = false;
        }
        catch (IOException)
        {
            _qrFallback.Text = "No pairing QR available. Use the address above.";
            _qrFallback.Visible = true;
            SetQrImage(null);
        }
    }

    private void SetQrImage(Image? image)
    {
        var previous = _qrPicture;
        _qrPicture = image;
        _qrImage.Image = image;
        _qrImage.Visible = image is not null;
        previous?.Dispose();
    }

    private void CopyAddress()
    {
        var text = _qrEndpoint;
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        Clipboard.SetText(text);
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

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _qrLoad?.Cancel();
            _qrLoad?.Dispose();
            _qrPicture?.Dispose();
        }
        base.Dispose(disposing);
    }

    private static Label NewHeader(string text)
    {
        var label = NewLabel(text);
        label.Text = text;
        label.Font = new Font(label.Font, FontStyle.Bold);
        label.Margin = new Padding(0, 10, 0, 4);
        return label;
    }

    private static Label NewLabel(string name) => new()
    {
        AutoSize = true,
        MaximumSize = new Size(400, 0),
        Margin = new Padding(0, 0, 0, 4),
        AccessibleName = name,
    };

    private static Button NewButton(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Margin = new Padding(0, 2, 0, 8),
        AccessibleName = text,
    };
}
