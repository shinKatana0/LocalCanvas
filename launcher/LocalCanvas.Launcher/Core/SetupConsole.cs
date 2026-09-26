using System.ComponentModel;
using System.Diagnostics;

namespace LocalCanvas.Launcher.Core;

public interface ISetupConsole
{
    /// <summary>Run setup in a console the user can see and answer. Returns its exit code, or null if it could not be started.</summary>
    Task<int?> RunAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// The first-run setup is <c>scripts\setup.ps1</c> itself, in a visible
/// console window, and nothing else: there is no second setup implementation
/// in the launcher. The window stays open until the user has read it.
/// </summary>
public sealed class SetupConsole : ISetupConsole
{
    private readonly string _pwsh;
    private readonly string _root;
    private readonly ILauncherLog _log;

    public SetupConsole(string pwsh, string root, ILauncherLog log)
    {
        _pwsh = pwsh;
        _root = root;
        _log = log;
    }

    public static string BuildCommand(string root)
    {
        var script = Path.Combine(root, "scripts", "setup.ps1");
        return $"& {PowerShellText.Quote(script)}; $c=$LASTEXITCODE; Write-Host ''; Read-Host 'Press Enter to close this window'; exit $c";
    }

    public static IReadOnlyList<string> BuildArguments(string root) =>
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", BuildCommand(root)];

    public async Task<int?> RunAsync(CancellationToken cancellationToken = default)
    {
        var info = new ProcessStartInfo(_pwsh)
        {
            UseShellExecute = false,
            // A console of its own, visible: setup may ask the user things.
            CreateNoWindow = false,
            WorkingDirectory = _root,
        };
        foreach (var argument in BuildArguments(_root))
        {
            info.ArgumentList.Add(argument);
        }
        _log.Write("setup: running scripts\\setup.ps1 in a visible console");
        try
        {
            using var process = Process.Start(info);
            if (process is null)
            {
                _log.Write("setup: the console could not be started");
                return null;
            }
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            _log.Write($"setup: exit {process.ExitCode}");
            return process.ExitCode;
        }
        catch (Win32Exception exception)
        {
            _log.Write($"setup: the console could not be started: {exception.Message}");
            return null;
        }
    }
}
