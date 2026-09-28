using LocalCanvas.Launcher.Core;
using LocalCanvas.Launcher.Shell;

namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// A regression test for an accessibility defect: invoking a button through
/// UI Automation's Invoke pattern (how Narrator and other assistive
/// technology press a button) raises that button's HWND to the top of the
/// native z-order. A FlowLayoutPanel re-syncs its Controls order to match,
/// which visibly reorders every row below the header -- "Copy address" ends
/// up above "Gateway". <see cref="StatusWindow"/> uses a TableLayoutPanel
/// instead, whose layout is driven by each control's assigned row, never by
/// z-order, so it cannot be reordered this way.
/// </summary>
public sealed class StatusWindowLayoutTests : IDisposable
{
    private sealed class NeverQr : IQrCommand
    {
        public Task<string?> WritePngAsync(string endpoint, CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
    }

    private static TrayViewModel Model(LauncherState state = LauncherState.Ready, string gatewayLine = "Gateway: Ready") => new(
        state, TrayViewModel.TooltipFor(state), gatewayLine, "ComfyUI: Ready", "Workflows: 1",
        Busy: false, CanRestartGateway: true, CanSyncWorkflows: true, CanOpenStatus: true, CanExit: true,
        Problem: null, PublishedEndpoint: "http://192.0.2.10:7801", InstanceId: null, ComfyUrl: null, LogPath: @"X:\LocalCanvas\.runtime\launcher.log");

    private StatusWindow? _window;

    private StatusWindow NewWindow()
    {
        _window = new StatusWindow(() => { }, @"X:\LocalCanvas", new NeverQr());
        // Off-screen, the same trick used elsewhere: Control.Top below reads
        // real post-layout values only once the window has actually been
        // shown (an un-shown Form never runs a layout pass).
        _window.StartPosition = FormStartPosition.Manual;
        _window.Location = new Point(-32000, -32000);
        _window.ShowInTaskbar = false;
        _window.Show();
        return _window;
    }

    [Fact]
    public void Invoking_Copy_address_the_way_UI_Automation_does_does_not_reorder_the_layout()
    {
        var window = NewWindow();
        window.Apply(Model());

        var before = VisibleOrder(window);
        Assert.Contains("Copy address", before);
        Assert.Contains("Gateway", before);
        AssertBottomRowIsPinned(window);

        // The same effect UI Automation's InvokePattern has on z-order when
        // it presses a button (SetFocus and raising the HWND): BringToFront
        // moves the control to the front of its parent's z-order and child
        // list -- exactly the mechanism described above. This is a
        // deterministic, non-UIA way to exercise the identical WinForms
        // behaviour.
        Find(window, "Copy address").BringToFront();

        var after = VisibleOrder(window);
        Assert.Equal(before, after);
        AssertBottomRowIsPinned(window);
    }

    /// <summary>
    /// The bottom row (Open logs folder, then Close) each in their own fixed
    /// cell: without one, a control added to a TableLayoutPanel falls back to
    /// the next free cell in Controls-collection order, which visibly
    /// misplaces it (observed: Open logs folder jumping to the panel's left
    /// edge while Close stays put) without any control ever changing parent
    /// or z-order -- a distinct failure mode from the main panel's, and one
    /// BringToFront alone does not exercise.
    /// </summary>
    private static void AssertBottomRowIsPinned(Form window)
    {
        var openLogs = Find(window, "Open logs folder");
        var close = Find(window, "Close");
        Assert.True(openLogs.Left < close.Left, $"Open logs folder ({openLogs.Left}) should sit left of Close ({close.Left})");
        // Right-aligned as a pair: both sit in the right portion of the
        // button row's own parent, not pinned to its left edge.
        var panelWidth = close.Parent!.ClientSize.Width;
        Assert.True(openLogs.Left > panelWidth / 2, $"Open logs folder (x={openLogs.Left}) should be right-aligned, not at the panel's left edge (width {panelWidth})");
        Assert.True(close.Right <= panelWidth, $"Close (right={close.Right}) should not overflow its panel (width {panelWidth})");
    }

    [Fact]
    public void Copy_address_still_works_after_being_brought_to_front()
    {
        var clipboard = new FakeClipboard();
        _window = new StatusWindow(() => { }, @"X:\LocalCanvas", new NeverQr(), clipboard);
        _window.StartPosition = FormStartPosition.Manual;
        _window.Location = new Point(-32000, -32000);
        _window.ShowInTaskbar = false;
        _window.Show();
        _window.Apply(Model());

        var button = (Button)Find(_window, "Copy address");
        button.BringToFront();
        button.PerformClick();

        Assert.Equal(["http://192.0.2.10:7801"], clipboard.Texts);
    }

    [Fact]
    public void Restart_Gateway_is_visible_without_scrolling_and_comes_before_the_bottom_row_in_tab_order()
    {
        var window = NewWindow();
        window.Apply(Model(LauncherState.GatewayDown, "Gateway: DOWN"));

        var restart = Find(window, "Restart Gateway");
        Assert.True(restart.Visible);
        // Within its own scrollable panel's visible viewport (scroll
        // position starts at the top): reaching it needs neither a scroll
        // nor tabbing past the workflow counts and the bottom row.
        var viewportHeight = restart.Parent!.ClientSize.Height;
        Assert.True(restart.Bottom <= viewportHeight,
            $"Restart Gateway (bottom={restart.Bottom}) should be visible without scrolling in its panel's viewport (height {viewportHeight})");

        // In the Gateway section itself, not after it: this is what actually
        // distinguishes "next to Status: DOWN" from merely fitting on screen
        // in a short test window -- a real running window's QR image and
        // workflow content push a later row well past the fold even though a
        // sparse test fixture's would not. (The QR PictureBox itself is
        // skipped here: it stays Visible = false with no QR command wired
        // up, and an invisible control's own Top is not meaningfully laid
        // out -- the always-visible section labels around it are enough.)
        var comfyTop = Find(window, "ComfyUI").Top;
        var workflowsTop = Find(window, "Workflows").Top;
        Assert.True(restart.Top < comfyTop, $"Restart Gateway (top={restart.Top}) should sit before the ComfyUI section (top={comfyTop})");
        Assert.True(restart.Top < workflowsTop, $"Restart Gateway (top={restart.Top}) should sit before the Workflows section (top={workflowsTop})");

        var order = TabOrder(window);
        var restartIndex = order.IndexOf("Restart Gateway");
        var copyAddressIndex = order.IndexOf("Copy address");
        var openLogsIndex = order.IndexOf("Open logs folder");
        var closeIndex = order.IndexOf("Close");
        Assert.True(restartIndex >= 0, "Restart Gateway should be reachable by Tab while the Gateway is down");
        // Before Copy address (still in the Gateway section) as well as
        // before the bottom row -- the latter alone is true for any row in
        // the main panel, since the bottom row is a separate, later
        // container regardless of where within the main panel a row sits.
        Assert.True(restartIndex < copyAddressIndex, $"Restart Gateway (tab #{restartIndex}) should precede Copy address (#{copyAddressIndex})");
        Assert.True(restartIndex < openLogsIndex, $"Restart Gateway (tab #{restartIndex}) should precede Open logs folder (#{openLogsIndex})");
        Assert.True(restartIndex < closeIndex, $"Restart Gateway (tab #{restartIndex}) should precede Close (#{closeIndex})");
    }

    [Fact]
    public void Restart_Gateway_is_hidden_and_out_of_tab_order_while_not_down()
    {
        var window = NewWindow();
        window.Apply(Model(LauncherState.Ready));

        Assert.False(Find(window, "Restart Gateway").Visible);
        Assert.DoesNotContain("Restart Gateway", TabOrder(window));
    }

    /// <summary>
    /// The effective Tab order a real user would reach (Control.GetNextControl
    /// -- null past the last control, so this always terminates -- filtered to
    /// Visible and TabStop the same way keyboard navigation skips a hidden or
    /// disabled control that GetNextControl's own raw traversal does not).
    /// </summary>
    private static List<string> TabOrder(Form window)
    {
        var order = new List<string>();
        Control? current = null;
        for (var i = 0; i < 50; i++)
        {
            current = window.GetNextControl(current, true);
            if (current is null)
            {
                break;
            }
            if (current.TabStop && current.Visible && !string.IsNullOrEmpty(current.AccessibleName))
            {
                order.Add(current.AccessibleName!);
            }
        }
        return order;
    }

    /// <summary>Every named control, top to bottom by its actual post-layout position.</summary>
    private static List<string> VisibleOrder(Control root)
    {
        var all = new List<Control>();
        Collect(root, all);
        return all.Where(c => !string.IsNullOrEmpty(c.AccessibleName))
                  .OrderBy(c => c.Top)
                  .ThenBy(c => c.Left)
                  .Select(c => c.AccessibleName!)
                  .ToList();
    }

    private static void Collect(Control root, List<Control> into)
    {
        foreach (Control control in root.Controls)
        {
            into.Add(control);
            if (control.HasChildren)
            {
                Collect(control, into);
            }
        }
    }

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
