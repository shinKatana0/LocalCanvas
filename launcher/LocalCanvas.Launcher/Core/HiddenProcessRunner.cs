using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace LocalCanvas.Launcher.Core;

/// <summary>One process to run without a window, and how long to wait for it.</summary>
public sealed record ProcessRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    TimeSpan Timeout,
    IReadOnlyDictionary<string, string?>? Environment = null,
    string? WorkingDirectory = null);

/// <summary>What became of a <see cref="ProcessRequest"/>.</summary>
public sealed record ProcessResult(
    bool Started,
    bool TimedOut,
    bool Cancelled,
    int? ExitCode,
    int? ProcessId,
    string StandardOutput,
    string StandardError,
    TimeSpan Duration,
    string? StartError,
    bool OutputComplete);

public interface IProcessRunner
{
    Task<ProcessResult> RunHiddenAsync(ProcessRequest request, CancellationToken cancellationToken = default);
}

/// <summary>
/// Runs a process with no window, standard input closed at once, and both
/// output streams captured.
/// </summary>
/// <remarks>
/// A process that outlives its timeout is reported as timed out and is left
/// exactly as it is: the launcher never ends a process (docs/runtime.md,
/// "Machine interface"). Everything a script starts is stopped by
/// <c>stop.ps1</c>, on its ownership proof, and by nothing else.
/// </remarks>
public sealed class HiddenProcessRunner : IProcessRunner
{
    /// <summary>
    /// How long the output streams may stay open after the process has exited.
    /// A pipe held by something the process left behind would otherwise keep
    /// the caller waiting for as long as that lives.
    /// </summary>
    public static readonly TimeSpan StreamDrainBound = TimeSpan.FromSeconds(5);

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    public async Task<ProcessResult> RunHiddenAsync(ProcessRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var info = new ProcessStartInfo(request.FileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8,
        };
        foreach (var argument in request.Arguments)
        {
            info.ArgumentList.Add(argument);
        }
        if (!string.IsNullOrEmpty(request.WorkingDirectory))
        {
            info.WorkingDirectory = request.WorkingDirectory;
        }
        if (request.Environment is not null)
        {
            foreach (var (name, value) in request.Environment)
            {
                if (value is null)
                {
                    info.Environment.Remove(name);
                }
                else
                {
                    info.Environment[name] = value;
                }
            }
        }

        var clock = Stopwatch.StartNew();
        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        process.Exited += (_, _) => exited.TrySetResult();
        try
        {
            if (!process.Start())
            {
                return NotStarted(clock, "The process did not start.");
            }
        }
        catch (Win32Exception exception)
        {
            return NotStarted(clock, exception.Message);
        }
        catch (InvalidOperationException exception)
        {
            return NotStarted(clock, exception.Message);
        }

        int? processId = null;
        try
        {
            processId = process.Id;
        }
        catch (InvalidOperationException)
        {
        }

        // Nobody is asked anything: standard input is closed before the
        // process can read from it.
        try
        {
            process.StandardInput.Close();
        }
        catch (IOException)
        {
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var pumps = Task.WhenAll(
            Pump(process.StandardOutput, stdout),
            Pump(process.StandardError, stderr));

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(request.Timeout);
        var cancelled = false;
        var timedOut = false;
        try
        {
            await exited.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            cancelled = cancellationToken.IsCancellationRequested;
            timedOut = !cancelled;
        }

        if (timedOut || cancelled)
        {
            // Left running, on purpose. Its PID is in the result for the log.
            return new ProcessResult(
                Started: true, TimedOut: timedOut, Cancelled: cancelled, ExitCode: null, ProcessId: processId,
                StandardOutput: Snapshot(stdout), StandardError: Snapshot(stderr),
                Duration: clock.Elapsed, StartError: null, OutputComplete: false);
        }

        var drained = true;
        try
        {
            await pumps.WaitAsync(StreamDrainBound).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            drained = false;
        }

        int? exitCode = null;
        try
        {
            exitCode = process.ExitCode;
        }
        catch (InvalidOperationException)
        {
        }

        return new ProcessResult(
            Started: true, TimedOut: false, Cancelled: false, ExitCode: exitCode, ProcessId: processId,
            StandardOutput: Snapshot(stdout), StandardError: Snapshot(stderr),
            Duration: clock.Elapsed, StartError: null, OutputComplete: drained);
    }

    private static ProcessResult NotStarted(Stopwatch clock, string reason) => new(
        Started: false, TimedOut: false, Cancelled: false, ExitCode: null, ProcessId: null,
        StandardOutput: string.Empty, StandardError: string.Empty,
        Duration: clock.Elapsed, StartError: reason, OutputComplete: true);

    private static async Task Pump(StreamReader reader, StringBuilder into)
    {
        var buffer = new char[4096];
        try
        {
            while (true)
            {
                var read = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
                if (read == 0)
                {
                    return;
                }
                lock (into)
                {
                    into.Append(buffer, 0, read);
                }
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private static string Snapshot(StringBuilder text)
    {
        lock (text)
        {
            return text.ToString();
        }
    }
}
