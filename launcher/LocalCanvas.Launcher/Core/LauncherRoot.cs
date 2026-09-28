namespace LocalCanvas.Launcher.Core;

public sealed record RootResolution(string? Root, string? Problem);

/// <summary>
/// The LocalCanvas folder is the folder LocalCanvas.exe is in: it must hold
/// <c>scripts\start.ps1</c>. Nothing is searched for.
/// </summary>
/// <remarks>
/// <c>--root &lt;folder&gt;</c> is a developer option -- running a build from
/// its output directory against a checkout -- and the same rule applies to the
/// folder it names.
/// </remarks>
public static class LauncherRoot
{
    public const string MisplacedMessage = "LocalCanvas.exe must stay in the LocalCanvas folder.";
    public const string RootOption = "--root";

    public static RootResolution Resolve(IReadOnlyList<string> arguments, string? executableDirectory)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        string? candidate = executableDirectory;
        for (var i = 0; i < arguments.Count; i++)
        {
            if (string.Equals(arguments[i], RootOption, StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 >= arguments.Count || string.IsNullOrWhiteSpace(arguments[i + 1]))
                {
                    return new RootResolution(null, $"{RootOption} needs a folder.");
                }
                candidate = arguments[i + 1];
                break;
            }
        }
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return new RootResolution(null, "The folder LocalCanvas.exe is in could not be determined.");
        }
        string full;
        try
        {
            full = Path.GetFullPath(candidate);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return new RootResolution(null, $"{candidate} is not a usable folder path.");
        }
        full = Path.TrimEndingDirectorySeparator(full);
        var start = Path.Combine(full, "scripts", "start.ps1");
        if (!File.Exists(start))
        {
            return new RootResolution(null, $"{start} was not found. It has to be in the folder beside LocalCanvas.exe.");
        }
        return new RootResolution(full, null);
    }
}
