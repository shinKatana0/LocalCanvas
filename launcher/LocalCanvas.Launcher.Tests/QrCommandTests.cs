using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

public sealed class QrCommandTests : IDisposable
{
    // Spaces and an apostrophe: the same kind of awkward path the other seam tests use.
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc qr it's");

    private sealed class FakeProcesses(Func<ProcessRequest, ProcessResult> answer) : IProcessRunner
    {
        public readonly List<ProcessRequest> Requests = [];

        public Task<ProcessResult> RunHiddenAsync(ProcessRequest request, CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            return Task.FromResult(answer(request));
        }
    }

    private static ProcessResult Ok(int exitCode = 0) => new(true, false, false, exitCode, 1, string.Empty, string.Empty, TimeSpan.Zero, null, true);

    [Fact]
    public void The_command_names_the_projects_own_interpreter_and_quotes_the_endpoint_and_the_path()
    {
        Assert.Equal(
            @"& 'X:\Tom''s LC\.venv\Scripts\python.exe' -m localcanvas_gateway qr --endpoint 'http://192.0.2.10:7801' --png 'X:\Tom''s LC\.runtime\pairing-qr.png'; exit $LASTEXITCODE",
            GatewayQrCommand.BuildCommand(@"X:\Tom's LC", "http://192.0.2.10:7801", @"X:\Tom's LC\.runtime\pairing-qr.png"));
    }

    [Fact]
    public async Task A_clean_exit_with_the_file_present_is_the_path_written()
    {
        var expected = Path.Combine(_root, ".runtime", "pairing-qr.png");
        var processes = new FakeProcesses(_ =>
        {
            File.WriteAllBytes(expected, [1, 2, 3]);
            return Ok();
        });
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, new MemoryLog());

        var path = await command.WritePngAsync("http://192.0.2.10:7801");

        Assert.Equal(expected, path);
        var request = Assert.Single(processes.Requests);
        Assert.Equal(@"C:\PowerShell\pwsh.exe", request.FileName);
        Assert.Contains("qr", request.Arguments[^1]);
        Assert.Contains("http://192.0.2.10:7801", request.Arguments[^1]);
    }

    [Fact]
    public async Task A_nonzero_exit_is_reported_as_no_image_even_if_a_file_exists()
    {
        var stale = Path.Combine(_root, ".runtime", "pairing-qr.png");
        var processes = new FakeProcesses(_ =>
        {
            Directory.CreateDirectory(Path.GetDirectoryName(stale)!);
            File.WriteAllBytes(stale, [9]);
            return Ok(exitCode: 2);
        });
        var log = new MemoryLog();
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, log);

        // A failing run in the real command never writes the file in the
        // first place; this only proves WritePngAsync trusts the exit code,
        // not merely "does a file happen to be there".
        var path = await command.WritePngAsync("http://192.0.2.10:7801");

        Assert.Null(path);
        Assert.Contains(log.Lines, line => line.Contains("qr:", StringComparison.Ordinal));
    }

    [Fact]
    public async Task No_file_written_despite_a_clean_exit_is_null()
    {
        var processes = new FakeProcesses(_ => Ok());
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, new MemoryLog());

        var path = await command.WritePngAsync("http://192.0.2.10:7801");

        Assert.Null(path);
    }

    [Fact]
    public async Task A_timed_out_or_cancelled_call_is_null()
    {
        var timedOut = new FakeProcesses(_ => new ProcessResult(true, true, false, null, 1, string.Empty, string.Empty, TimeSpan.Zero, null, false));
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, timedOut, new MemoryLog());
        Assert.Null(await command.WritePngAsync("http://192.0.2.10:7801"));
    }

    [Fact]
    public async Task A_stale_image_from_a_previous_endpoint_is_gone_before_the_command_runs()
    {
        var path = Path.Combine(_root, ".runtime", "pairing-qr.png");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, [0xAA]);

        var seenAtStart = new List<bool>();
        var processes = new FakeProcesses(_ =>
        {
            seenAtStart.Add(File.Exists(path));
            // A failing run: the stale file must stay gone, not be replaced.
            return Ok(exitCode: 2);
        });
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, new MemoryLog());

        var result = await command.WritePngAsync("http://192.0.2.10:7801");

        Assert.Null(result);
        Assert.Equal([false], seenAtStart);
        Assert.False(File.Exists(path), "the stale image from the previous endpoint must not be shown as this one's");
    }

    public void Dispose() => TestEnvironment.RemoveDirectory(_root);
}
