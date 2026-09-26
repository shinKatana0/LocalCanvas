using System.Runtime.InteropServices;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// "Open logs folder": reveals a folder in Explorer through the shell's own
/// <c>ShellExecute</c>, the ordinary way a Windows application hands the user
/// off to the file manager. This starts no process LocalCanvas has to account
/// for or stop -- it is not part of the documented machine interface
/// (docs/runtime.md) the lifecycle controller calls through, and Explorer is
/// not something LocalCanvas started, owns, or will ever stop.
/// </summary>
internal static partial class OpenFolder
{
    private const int ShowNormal = 1;

    public static void InExplorer(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }
        ShellExecuteW(IntPtr.Zero, "open", path, null, null, ShowNormal);
    }

    [LibraryImport("shell32.dll", EntryPoint = "ShellExecuteW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr ShellExecuteW(IntPtr hwnd, string? operation, string file, string? parameters, string? directory, int showCommand);
}
