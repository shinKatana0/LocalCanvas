namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// The launcher owns no process logic: it never ends, finds or signals a
/// process. Every stop is stop.ps1 and its ownership proof. Checked against
/// the source itself, so a later change cannot slip one in unnoticed.
/// </summary>
public sealed class SourceRulesTests
{
    private static IReadOnlyList<(string File, string Text)> Sources()
    {
        var directory = TestEnvironment.LauncherSources;
        var files = Directory.EnumerateFiles(directory, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase)
                           && !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase))
            .Select(path => (Path.GetRelativePath(directory, path), File.ReadAllText(path)))
            .ToArray();
        Assert.True(files.Length >= 10, $"only {files.Length} source files found under {directory}");
        return files;
    }

    [Theory]
    [InlineData(".Kill(")]
    [InlineData("Kill()")]
    [InlineData("GetProcessesByName")]
    [InlineData("GetProcessById")]
    [InlineData("GetProcesses(")]
    [InlineData("taskkill")]
    [InlineData("TerminateProcess")]
    [InlineData("OpenProcess")]
    [InlineData("Stop-Process")]
    [InlineData("CloseMainWindow")]
    [InlineData("powershell.exe\"")]
    [InlineData("netsh")]
    [InlineData("Registry.")]
    [InlineData("SetEnvironmentVariable")]
    [InlineData("Set-ExecutionPolicy")]
    public void The_launcher_source_never_contains(string forbidden)
    {
        var offenders = Sources()
            .Where(source => source.Text.Contains(forbidden, StringComparison.OrdinalIgnoreCase))
            .Select(source => source.File)
            .ToArray();
        Assert.True(offenders.Length == 0, $"'{forbidden}' appears in: {string.Join(", ", offenders)}");
    }

    [Fact]
    public void Only_the_process_runner_and_the_setup_console_start_processes()
    {
        var starters = Sources()
            .Where(source => source.Text.Contains("ProcessStartInfo", StringComparison.Ordinal) || source.Text.Contains("Process.Start", StringComparison.Ordinal))
            .Select(source => Path.GetFileName(source.File))
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(["HiddenProcessRunner.cs", "SetupConsole.cs"], starters);
    }

    [Fact]
    public void The_live_ports_appear_nowhere_in_the_launcher()
    {
        foreach (var port in TestEnvironment.LivePorts)
        {
            Assert.DoesNotContain(Sources(), source => source.Text.Contains(port.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal));
        }
    }
}
