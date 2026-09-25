using System.Diagnostics;

namespace LocalCanvas.Launcher.Tests;

/// <summary>Where the tests find the repository, PowerShell 7 and a Python for the stubs.</summary>
internal static class TestEnvironment
{
    /// <summary>
    /// The ports of a developer's own ComfyUI and Gateway. No test binds or
    /// contacts either: everything here uses ephemeral loopback ports.
    /// </summary>
    public static readonly int[] LivePorts = [8188, 7801];

    public static void AssertNotALivePort(int port) =>
        Assert.False(LivePorts.Contains(port), $"Port {port} belongs to a live ComfyUI or Gateway and must not be used by a test.");

    private static readonly Lazy<string> RepositoryRoot = new(() =>
    {
        var moved = Environment.GetEnvironmentVariable("LOCALCANVAS_TEST_REPOSITORY");
        if (!string.IsNullOrEmpty(moved))
        {
            return moved;
        }
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "scripts", "start.ps1"))
                && Directory.Exists(Path.Combine(directory.FullName, "launcher")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        throw new InvalidOperationException("The repository root (scripts\\start.ps1 beside launcher\\) was not found above " + AppContext.BaseDirectory);
    });

    public static string Repository => RepositoryRoot.Value;

    public static string LauncherSources => Path.Combine(Repository, "launcher", "LocalCanvas.Launcher");

    private static readonly Lazy<string?> PwshPath = new(() =>
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory.Trim().Trim('"'), "pwsh.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        var installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        return File.Exists(installed) ? installed : null;
    });

    public static string? Pwsh => PwshPath.Value;

    /// <summary>
    /// A Python 3.10-3.13 for the stub gateway and stub ComfyUI:
    /// <c>LOCALCANVAS_TEST_PYTHON</c>, else what <c>py -3.10</c> names. Never
    /// guessed further than that.
    /// </summary>
    private static readonly Lazy<string?> PythonPath = new(() =>
    {
        var named = Environment.GetEnvironmentVariable("LOCALCANVAS_TEST_PYTHON");
        if (!string.IsNullOrEmpty(named))
        {
            return File.Exists(named) ? named : null;
        }
        foreach (var selector in new[] { "-3.10", "-3.11", "-3.12", "-3.13" })
        {
            try
            {
                var info = new ProcessStartInfo("py", [selector, "-c", "import sys; print(sys.executable)"])
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                using var process = Process.Start(info)!;
                var output = process.StandardOutput.ReadToEnd().Trim();
                process.WaitForExit(30_000);
                if (process.ExitCode == 0 && File.Exists(output))
                {
                    return output;
                }
            }
            catch (System.ComponentModel.Win32Exception)
            {
                return null;
            }
        }
        return null;
    });

    public static string? Python => PythonPath.Value;

    public static string NewScratchDirectory(string prefix)
    {
        var path = Path.Combine(Path.GetTempPath(), $"{prefix} {Guid.NewGuid():N}"[..(prefix.Length + 13)]);
        Directory.CreateDirectory(path);
        return path;
    }

    public static void RemoveDirectory(string path)
    {
        for (var attempt = 0; attempt < 30; attempt++)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, recursive: true);
                }
                return;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(500);
            }
        }
    }
}
