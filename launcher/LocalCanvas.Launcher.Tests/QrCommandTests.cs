using System.Text.RegularExpressions;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

public sealed class QrCommandTests : IDisposable
{
    // Spaces and an apostrophe: the same kind of awkward path the other seam tests use.
    private readonly string _root = TestEnvironment.NewScratchDirectory("lc qr it's");

    private static readonly Regex FileNamePattern = new(@"pairing-qr-[0-9a-f]{32}\.png", RegexOptions.Compiled);

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

    /// <summary>The one-per-request file name the last argument's command line asks for.</summary>
    private static string FileNameAskedFor(ProcessRequest request)
    {
        var match = FileNamePattern.Match(request.Arguments[^1]);
        Assert.True(match.Success, $"no pairing-qr-<hex>.png filename found in: {request.Arguments[^1]}");
        return match.Value;
    }

    [Fact]
    public void The_command_names_the_projects_own_interpreter_and_quotes_the_endpoint_and_the_path()
    {
        Assert.Equal(
            @"& 'X:\Tom''s LC\.venv\Scripts\python.exe' -m localcanvas_gateway qr --endpoint 'http://192.0.2.10:7801' --png 'X:\Tom''s LC\.runtime\pairing-qr-aaaa.png'; exit $LASTEXITCODE",
            GatewayQrCommand.BuildCommand(@"X:\Tom's LC", "http://192.0.2.10:7801", @"X:\Tom's LC\.runtime\pairing-qr-aaaa.png"));
    }

    [Fact]
    public async Task A_clean_exit_with_the_file_present_is_the_path_written()
    {
        var processes = new FakeProcesses(request =>
        {
            File.WriteAllBytes(Path.Combine(_root, ".runtime", FileNameAskedFor(request)), [1, 2, 3]);
            return Ok();
        });
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, new MemoryLog());

        var path = await command.WritePngAsync("http://192.0.2.10:7801");

        Assert.NotNull(path);
        Assert.Equal(Path.Combine(_root, ".runtime"), Path.GetDirectoryName(path));
        Assert.Matches(FileNamePattern, Path.GetFileName(path));
        var request = Assert.Single(processes.Requests);
        Assert.Equal(@"C:\PowerShell\pwsh.exe", request.FileName);
        Assert.Contains("qr", request.Arguments[^1]);
        Assert.Contains("http://192.0.2.10:7801", request.Arguments[^1]);
    }

    [Fact]
    public async Task Two_requests_are_written_to_two_different_files()
    {
        // Real race this guards against: an endpoint changes while the
        // previous request's process is still running (never ended by this
        // launcher). One shared file name would let the slower, superseded
        // process overwrite the newer result; a unique name per request
        // cannot collide regardless of completion order.
        var written = new List<string>();
        var processes = new FakeProcesses(request =>
        {
            var path = Path.Combine(_root, ".runtime", FileNameAskedFor(request));
            written.Add(path);
            File.WriteAllBytes(path, [1]);
            return Ok();
        });
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, new MemoryLog());

        var pathA = await command.WritePngAsync("http://192.0.2.10:7801");
        var pathB = await command.WritePngAsync("http://192.0.2.11:7801");

        Assert.NotNull(pathA);
        Assert.NotNull(pathB);
        Assert.NotEqual(pathA, pathB);
        Assert.Equal(2, written.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Fact]
    public async Task A_new_request_sweeps_up_files_left_by_earlier_ones()
    {
        var runtime = Path.Combine(_root, ".runtime");
        Directory.CreateDirectory(runtime);
        var orphanA = Path.Combine(runtime, "pairing-qr-" + Guid.NewGuid().ToString("N") + ".png");
        var orphanB = Path.Combine(runtime, "pairing-qr-" + Guid.NewGuid().ToString("N") + ".png");
        File.WriteAllBytes(orphanA, [1]);
        File.WriteAllBytes(orphanB, [2]);
        // A file this sweep must never touch: not its own naming pattern.
        var unrelated = Path.Combine(runtime, "launcher.log");
        File.WriteAllText(unrelated, "kept");

        // A failing run: nothing is written for the new request itself, so
        // only the sweep of the two pre-existing files is being observed.
        var processes = new FakeProcesses(_ => Ok(exitCode: 2));
        var command = new GatewayQrCommand(@"C:\PowerShell\pwsh.exe", _root, processes, new MemoryLog());

        var result = await command.WritePngAsync("http://192.0.2.10:7801");

        Assert.Null(result);
        Assert.False(File.Exists(orphanA), "an orphaned pairing QR from an earlier request should not pile up");
        Assert.False(File.Exists(orphanB), "an orphaned pairing QR from an earlier request should not pile up");
        Assert.True(File.Exists(unrelated), "the sweep must only ever remove its own pairing-qr-*.png files");
    }

    [Fact]
    public async Task A_nonzero_exit_is_reported_as_no_image_even_if_a_file_exists()
    {
        var log = new MemoryLog();
        var processes = new FakeProcesses(request =>
        {
            var path = Path.Combine(_root, ".runtime", FileNameAskedFor(request));
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, [9]);
            return Ok(exitCode: 2);
        });
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

    public void Dispose() => TestEnvironment.RemoveDirectory(_root);
}
