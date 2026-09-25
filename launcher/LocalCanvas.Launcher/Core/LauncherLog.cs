using System.Globalization;
using System.Text;

namespace LocalCanvas.Launcher.Core;

public interface ILauncherLog
{
    /// <summary>Where the log is written, for the Details a user is shown.</summary>
    string Location { get; }

    void Write(string message);
}

/// <summary>
/// The launcher's own log: <c>.runtime\launcher.log</c> under the LocalCanvas
/// folder, appended to, one timestamped line per event, and capped in size.
/// </summary>
/// <remarks>
/// The runtime directory is the scripts' own: <c>LOCALCANVAS_RUNTIME_DIR</c>
/// moves it for them and therefore for this log too, so a second runtime can
/// be exercised without writing into the one in use. Nothing is sent
/// anywhere: this file is the whole of the launcher's diagnostics.
/// </remarks>
public sealed class LauncherLog : ILauncherLog
{
    public const long DefaultCapBytes = 1024 * 1024;

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    private readonly object _gate = new();
    private readonly long _capBytes;

    public LauncherLog(string path, long capBytes = DefaultCapBytes)
    {
        Location = path;
        _capBytes = capBytes;
    }

    public string Location { get; }

    public static string DefaultPath(string root)
    {
        var moved = Environment.GetEnvironmentVariable("LOCALCANVAS_RUNTIME_DIR");
        var directory = string.IsNullOrEmpty(moved) ? Path.Combine(root, ".runtime") : moved;
        return Path.Combine(directory, "launcher.log");
    }

    public void Write(string message)
    {
        var stamp = DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture);
        var lines = (message ?? string.Empty).Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var text = new StringBuilder();
        text.Append(stamp).Append(' ').Append(lines[0]).Append(Environment.NewLine);
        for (var i = 1; i < lines.Length; i++)
        {
            text.Append("    ").Append(lines[i]).Append(Environment.NewLine);
        }
        var payload = text.ToString();

        lock (_gate)
        {
            try
            {
                var directory = Path.GetDirectoryName(Location);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                var existing = new FileInfo(Location);
                if (existing.Exists && existing.Length + Utf8.GetByteCount(payload) > _capBytes)
                {
                    // One previous generation is kept; the log never grows past
                    // twice the cap in total.
                    File.Move(Location, Location + ".1", overwrite: true);
                }
                File.AppendAllText(Location, payload, Utf8);
            }
            catch (IOException)
            {
                // Diagnostics must never become the failure being reported.
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
