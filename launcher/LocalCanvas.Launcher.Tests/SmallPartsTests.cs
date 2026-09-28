using System.Diagnostics;
using System.Text;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

public sealed class SetupConsoleTests : IDisposable
{
    // Spaces, an apostrophe, a dollar sign and a backtick: each means something to PowerShell.
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc setup it's $HOME `x");

    [Fact]
    public void The_command_quotes_the_path_as_a_literal()
    {
        var command = SetupConsole.BuildCommand(@"X:\Tom's Local Canvas");
        Assert.Equal(
            @"& 'X:\Tom''s Local Canvas\scripts\setup.ps1'; $c=$LASTEXITCODE; Write-Host ''; Read-Host 'Press Enter to close this window'; exit $c",
            command);
        Assert.Equal(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], SetupConsole.BuildArguments(@"X:\Tom's Local Canvas"));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(7)]
    public async Task The_real_command_runs_setup_at_an_awkward_path_and_returns_its_exit_code(int code)
    {
        var pwsh = TestEnvironment.Pwsh;
        Assert.SkipWhen(pwsh is null, "PowerShell 7 is not installed, so the setup command was NOT run.");
        Directory.CreateDirectory(Path.Combine(_root, "scripts"));
        var marker = Path.Combine(_root, "ran.txt");
        File.WriteAllText(Path.Combine(_root, "scripts", "setup.ps1"),
            $"Set-Content -LiteralPath (Join-Path $PSScriptRoot '..\\ran.txt') -Value $PSScriptRoot\nexit {code}\n");

        // The same arguments the launcher uses, run hidden here, with Enter typed for the closing prompt.
        var info = new ProcessStartInfo(pwsh!)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in SetupConsole.BuildArguments(_root))
        {
            info.ArgumentList.Add(argument);
        }
        using var process = Process.Start(info)!;
        await process.StandardInput.WriteLineAsync();
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        Assert.True(process.WaitForExit(60_000), "the setup command did not finish");

        Assert.Equal(code, process.ExitCode);
        Assert.True(File.Exists(marker), $"setup.ps1 did not run. stdout: {await output} stderr: {await errors}");
        Assert.Equal(Path.Combine(_root, "scripts"), File.ReadAllText(marker).Trim());
    }

    public void Dispose() => TestEnvironment.RemoveDirectory(_root);
}

public sealed class PowerShellTextTests
{
    [Theory]
    [InlineData(@"C:\plain", @"'C:\plain'")]
    [InlineData(@"C:\Tom's", @"'C:\Tom''s'")]
    [InlineData("C:\\a\u2019b", "'C:\\a\u2019\u2019b'")]
    [InlineData(@"C:\$env:PATH `n", @"'C:\$env:PATH `n'")]
    public void Quoting_makes_a_literal(string text, string expected) => Assert.Equal(expected, PowerShellText.Quote(text));
}

public sealed class PwshLocatorTests
{
    private sealed class VersionRunner(Func<string, string> versionOf) : IProcessRunner
    {
        public readonly List<string> Ran = [];

        public Task<ProcessResult> RunHiddenAsync(ProcessRequest request, CancellationToken cancellationToken = default)
        {
            Ran.Add(request.FileName);
            return Task.FromResult(new ProcessResult(true, false, false, 0, 1, versionOf(request.FileName) + "\n", string.Empty, TimeSpan.Zero, null, true));
        }
    }

    [Fact]
    public async Task PATH_comes_first_then_the_PowerShell_7_folder_and_windows_powershell_is_never_tried()
    {
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            @"C:\Old\pwsh.exe",
            @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            @"C:\Program Files\PowerShell\7\pwsh.exe",
        };
        var runner = new VersionRunner(path => path.StartsWith(@"C:\Old", StringComparison.Ordinal) ? "6" : "7");
        var locator = new PwshLocator(runner, files.Contains,
            () => @"C:\Windows\System32\WindowsPowerShell\v1.0;C:\Old;""C:\Program Files\PowerShell\7""",
            () => @"C:\Program Files");

        Assert.Equal([@"C:\Old\pwsh.exe", @"C:\Program Files\PowerShell\7\pwsh.exe"], locator.Candidates());
        var found = await locator.LocateAsync();
        Assert.True(found.Found);
        Assert.Equal(@"C:\Program Files\PowerShell\7\pwsh.exe", found.Path);
        Assert.Equal(7, found.MajorVersion);
        Assert.DoesNotContain(runner.Ran, path => path.EndsWith("powershell.exe", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task Only_an_old_PowerShell_is_reported_as_missing_7()
    {
        var locator = new PwshLocator(new VersionRunner(_ => "6"), _ => true, () => @"C:\Old", () => null);
        var found = await locator.LocateAsync();
        Assert.False(found.Found);
        Assert.Contains("PowerShell 6", found.Problem);
        Assert.Equal("PowerShell 7 is required. Install PowerShell 7 and start LocalCanvas again.", PwshLocator.RequiredMessage);
    }

    [Fact]
    public async Task Nothing_found_is_reported()
    {
        var locator = new PwshLocator(new VersionRunner(_ => "7"), _ => false, () => @"C:\Nowhere", () => @"C:\Program Files");
        var found = await locator.LocateAsync();
        Assert.False(found.Found);
        Assert.Contains("was not found", found.Problem);
    }

    [Fact]
    public async Task This_machine_has_a_PowerShell_7_the_locator_accepts()
    {
        Assert.SkipWhen(TestEnvironment.Pwsh is null, "PowerShell 7 is not installed here, so the real locator was NOT exercised.");
        var found = await new PwshLocator(new HiddenProcessRunner()).LocateAsync();
        Assert.True(found.Found, found.Problem);
        Assert.True(found.MajorVersion >= 7);
    }
}

public sealed class LauncherRootTests : IDisposable
{
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc root");

    [Fact]
    public void The_exe_folder_is_the_root_when_it_holds_the_start_script()
    {
        Directory.CreateDirectory(Path.Combine(_root, "scripts"));
        File.WriteAllText(Path.Combine(_root, "scripts", "start.ps1"), string.Empty);
        Assert.Equal(_root, LauncherRoot.Resolve([], _root).Root);
    }

    [Fact]
    public void An_exe_away_from_the_scripts_is_refused()
    {
        var resolved = LauncherRoot.Resolve([], _root);
        Assert.Null(resolved.Root);
        Assert.Contains("start.ps1", resolved.Problem);
        Assert.Equal("LocalCanvas.exe must stay in the LocalCanvas folder.", LauncherRoot.MisplacedMessage);
    }

    [Fact]
    public void The_developer_option_names_another_root()
    {
        Directory.CreateDirectory(Path.Combine(_root, "scripts"));
        File.WriteAllText(Path.Combine(_root, "scripts", "start.ps1"), string.Empty);
        Assert.Equal(_root, LauncherRoot.Resolve(["--root", _root], @"X:\elsewhere").Root);
        Assert.Null(LauncherRoot.Resolve(["--root"], _root).Root);
    }

    public void Dispose() => TestEnvironment.RemoveDirectory(_root);
}

public sealed class LauncherLogTests : IDisposable
{
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc log");

    [Fact]
    public void Lines_are_timestamped_and_appended()
    {
        var path = Path.Combine(_root, ".runtime", "launcher.log");
        var log = new LauncherLog(path);
        log.Write("first");
        log.Write("second\nwith a detail");
        var lines = File.ReadAllLines(path, Encoding.UTF8);
        Assert.Equal(3, lines.Length);
        Assert.Matches(@"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2} first$", lines[0]);
        Assert.EndsWith(" second", lines[1], StringComparison.Ordinal);
        Assert.Equal("    with a detail", lines[2]);
    }

    [Fact]
    public void The_log_is_capped_keeping_one_previous_generation()
    {
        var path = Path.Combine(_root, "launcher.log");
        var log = new LauncherLog(path, capBytes: 1000);
        for (var i = 0; i < 100; i++)
        {
            log.Write($"line {i} " + new string('x', 40));
        }
        Assert.True(new FileInfo(path).Length <= 1000);
        Assert.True(new FileInfo(path + ".1").Length <= 1000);
        Assert.Contains("line 99 ", File.ReadAllText(path), StringComparison.Ordinal);
        Assert.False(File.Exists(path + ".2"));
    }

    [Fact]
    public void The_default_place_is_the_runtime_folder_of_the_root() =>
        Assert.Equal(
            string.IsNullOrEmpty(Environment.GetEnvironmentVariable("LOCALCANVAS_RUNTIME_DIR"))
                ? Path.Combine(@"X:\LocalCanvas", ".runtime", "launcher.log")
                : Path.Combine(Environment.GetEnvironmentVariable("LOCALCANVAS_RUNTIME_DIR")!, "launcher.log"),
            LauncherLog.DefaultPath(@"X:\LocalCanvas"));

    public void Dispose() => TestEnvironment.RemoveDirectory(_root);
}

public sealed class SettingsSeamTests
{
    private static ProcessResult Printed(string stdout, int exit = 0) =>
        new(true, false, false, exit, 1, stdout, string.Empty, TimeSpan.Zero, null, true);

    [Fact]
    public void The_timeouts_are_read_from_the_seam_document()
    {
        var timeouts = SeamSettingsReader.Parse(Printed("{\"startup\":{\"comfy_timeout_seconds\":45.5,\"gateway_timeout_seconds\":12}}"));
        Assert.NotNull(timeouts);
        Assert.Equal(TimeSpan.FromSeconds(45.5), timeouts.Comfy);
        Assert.Equal(TimeSpan.FromSeconds(12), timeouts.Gateway);
    }

    [Theory]
    [InlineData("not json", 0)]
    [InlineData("{\"startup\":{}}", 0)]
    [InlineData("{\"startup\":{\"comfy_timeout_seconds\":45,\"gateway_timeout_seconds\":12}}", 2)]
    public void Anything_else_is_no_answer(string stdout, int exit) =>
        Assert.Null(SeamSettingsReader.Parse(Printed(stdout, exit)));

    [Fact]
    public void The_seam_command_names_the_projects_own_interpreter_and_configuration()
    {
        Assert.Equal(
            @"& 'X:\Tom''s LC\.venv\Scripts\python.exe' -m localcanvas_gateway config --config 'X:\Tom''s LC\config\local\runtime.yaml'; exit $LASTEXITCODE",
            SeamSettingsReader.BuildCommand(@"X:\Tom's LC"));
    }
}
