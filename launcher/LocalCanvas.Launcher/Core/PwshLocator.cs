using System.Globalization;

namespace LocalCanvas.Launcher.Core;

public sealed record PwshLocation(string? Path, int? MajorVersion, string? Problem)
{
    public bool Found => Path is not null && Problem is null;
}

/// <summary>
/// Finds PowerShell 7: <c>pwsh.exe</c> on PATH, then
/// <c>%ProgramFiles%\PowerShell\7\pwsh.exe</c>, each confirmed by running it
/// and asking for its major version. Windows PowerShell
/// (<c>powershell.exe</c>, 5.1) is never a candidate: the scripts refuse it.
/// </summary>
public sealed class PwshLocator
{
    public const string RequiredMessage = "PowerShell 7 is required. Install PowerShell 7 and start LocalCanvas again.";
    public const string InstallCommand = "winget install --id Microsoft.PowerShell --source winget";
    public const string ExecutableName = "pwsh.exe";
    public static readonly TimeSpan VersionTimeout = TimeSpan.FromSeconds(30);

    private readonly IProcessRunner _processes;
    private readonly Func<string, bool> _fileExists;
    private readonly Func<string?> _pathVariable;
    private readonly Func<string?> _programFiles;

    public PwshLocator(IProcessRunner processes)
        : this(
            processes,
            File.Exists,
            () => Environment.GetEnvironmentVariable("PATH"),
            () => Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles))
    {
    }

    public PwshLocator(
        IProcessRunner processes,
        Func<string, bool> fileExists,
        Func<string?> pathVariable,
        Func<string?> programFiles)
    {
        _processes = processes;
        _fileExists = fileExists;
        _pathVariable = pathVariable;
        _programFiles = programFiles;
    }

    /// <summary>Where to look, in order. Only paths that exist are returned.</summary>
    public IReadOnlyList<string> Candidates()
    {
        var found = new List<string>();
        foreach (var directory in (_pathVariable() ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string candidate;
            try
            {
                candidate = System.IO.Path.Combine(directory.Trim('"'), ExecutableName);
            }
            catch (ArgumentException)
            {
                continue;
            }
            Add(found, candidate);
        }
        var programFiles = _programFiles();
        if (!string.IsNullOrEmpty(programFiles))
        {
            Add(found, System.IO.Path.Combine(programFiles, "PowerShell", "7", ExecutableName));
        }
        return found;
    }

    public async Task<PwshLocation> LocateAsync(CancellationToken cancellationToken = default)
    {
        var tooOld = new List<string>();
        foreach (var candidate in Candidates())
        {
            var result = await _processes.RunHiddenAsync(
                new ProcessRequest(candidate, ["-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.Major"], VersionTimeout),
                cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0
                && int.TryParse(result.StandardOutput.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var major))
            {
                if (major >= 7)
                {
                    return new PwshLocation(candidate, major, null);
                }
                tooOld.Add($"{candidate} is PowerShell {major}.");
            }
            else
            {
                tooOld.Add($"{candidate} did not report its version.");
            }
        }
        var detail = tooOld.Count == 0
            ? "pwsh.exe was not found on PATH or in the PowerShell 7 installation folder."
            : string.Join(Environment.NewLine, tooOld);
        return new PwshLocation(null, null, detail);
    }

    private void Add(List<string> found, string candidate)
    {
        if (found.Contains(candidate, StringComparer.OrdinalIgnoreCase))
        {
            return;
        }
        if (_fileExists(candidate))
        {
            found.Add(candidate);
        }
    }
}
