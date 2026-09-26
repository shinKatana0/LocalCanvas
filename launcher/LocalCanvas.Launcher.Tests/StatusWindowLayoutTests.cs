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

    private static TrayViewModel Model() => new(
        LauncherState.Ready, TrayViewModel.TooltipFor(LauncherState.Ready), "Gateway: Ready", "ComfyUI: Ready", "Workflows: 1",
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

        // The same effect UI Automation's InvokePattern has on z-order when
        // it presses a button (SetFocus and raising the HWND): BringToFront
        // moves the control to the front of its parent's z-order and child
        // list -- exactly the mechanism the reviewer diagnosed. This is a
        // deterministic, non-UIA way to exercise the identical WinForms
        // behaviour.
        Find(window, "Copy address").BringToFront();

        var after = VisibleOrder(window);
        Assert.Equal(before, after);
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
