using System.Globalization;

namespace LocalCanvas.Launcher.Core;

public interface IQrCommand
{
    /// <summary>
    /// Writes the pairing QR for <paramref name="endpoint"/> as a PNG and
    /// returns its path, or null when it could not be produced -- the caller
    /// shows the address on its own in that case.
    /// </summary>
    Task<string?> WritePngAsync(string endpoint, CancellationToken cancellationToken = default);
}

/// <summary>
/// The pairing QR image, through the same seam as <see cref="SeamSettingsReader"/>:
/// <c>.venv\Scripts\python.exe -m localcanvas_gateway qr --endpoint &lt;url&gt;
/// --png &lt;path&gt;</c>, run by PowerShell with no window and no console. A
/// failure of any kind -- the interpreter missing, the command failing, no
/// file written -- is reported as null, never as an exception the status
/// window has to guard against: a QR image is one of several equally valid
/// ways to reach an endpoint (docs/connection.md), never the only one.
/// </summary>
public sealed class GatewayQrCommand(string pwsh, string root, IProcessRunner processes, ILauncherLog log) : IQrCommand
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    public static string BuildCommand(string root, string endpoint, string pngPath)
    {
        var python = Path.Combine(root, ".venv", "Scripts", "python.exe");
        return $"& {PowerShellText.Quote(python)} -m localcanvas_gateway qr --endpoint {PowerShellText.Quote(endpoint)} --png {PowerShellText.Quote(pngPath)}; exit $LASTEXITCODE";
    }

    public async Task<string?> WritePngAsync(string endpoint, CancellationToken cancellationToken = default)
    {
        string path;
        try
        {
            var directory = LauncherLog.RuntimeDirectory(root);
            Directory.CreateDirectory(directory);
            path = Path.Combine(directory, "pairing-qr.png");
            // A stale image from a previous endpoint must never be shown as
            // this one's: gone before the command runs, not merely
            // overwritten on success.
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            log.Write($"qr: the runtime folder could not be prepared: {exception.Message}");
            return null;
        }

        var result = await processes.RunHiddenAsync(
            new ProcessRequest(pwsh, ["-NoProfile", "-NonInteractive", "-Command", BuildCommand(root, endpoint, path)], Timeout, null, root),
            cancellationToken).ConfigureAwait(false);

        if (!result.Started || result.TimedOut || result.Cancelled || result.ExitCode != 0 || !File.Exists(path))
        {
            log.Write("qr: the pairing image could not be produced" +
                       $" (exit {result.ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "none"}); showing the address only");
            return null;
        }
        return path;
    }
}
