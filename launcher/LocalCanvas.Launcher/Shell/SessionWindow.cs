using System.Runtime.InteropServices;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// A top-level window that is never shown. It receives
/// <c>WM_QUERYENDSESSION</c> -- Windows sends it to top-level windows, hidden
/// ones included, and never to a message-only window -- and it is the control
/// everything else is marshalled onto the UI thread through.
/// </summary>
internal sealed partial class SessionWindow : Form
{
    private const int WmQueryEndSession = 0x0011;
    private const string BlockReason = "Stopping LocalCanvas";
    private readonly Func<bool> _onSessionEnding;

    public SessionWindow(Func<bool> onSessionEnding)
    {
        _onSessionEnding = onSessionEnding;
        Text = "LocalCanvas";
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        Size = new Size(1, 1);
        _ = Handle;
    }

    protected override void SetVisibleCore(bool value) => base.SetVisibleCore(false);

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WmQueryEndSession)
        {
            // Registered for the length of the stop, so the sign-out screen
            // says what LocalCanvas is doing. The stop is bounded; the session
            // is allowed to end afterwards whatever it reported.
            var blocked = ShutdownBlockReasonCreate(Handle, BlockReason);
            try
            {
                _onSessionEnding();
            }
            finally
            {
                if (blocked)
                {
                    ShutdownBlockReasonDestroy(Handle);
                }
            }
            m.Result = 1;
            return;
        }
        base.WndProc(ref m);
    }

    [LibraryImport("user32.dll", EntryPoint = "ShutdownBlockReasonCreate", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShutdownBlockReasonCreate(IntPtr window, string reason);

    [LibraryImport("user32.dll", EntryPoint = "ShutdownBlockReasonDestroy")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShutdownBlockReasonDestroy(IntPtr window);
}
