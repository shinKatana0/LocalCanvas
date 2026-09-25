using System.Globalization;
using System.Text;
using System.Text.Json;

namespace LocalCanvas.Launcher.Core;

/// <summary>One call of a LocalCanvas script: <c>scripts\&lt;Script&gt;</c> with its arguments.</summary>
/// <remarks><c>-Json</c> is always added by the runner and never by a caller.</remarks>
public sealed record ScriptCall(string Script, IReadOnlyList<string> Arguments, TimeSpan Timeout)
{
    public string Describe() =>
        Arguments.Count == 0 ? $"{Script} -Json" : $"{Script} {string.Join(' ', Arguments)} -Json";

    public bool Names(string script, params string[] arguments) =>
        string.Equals(Script, script, StringComparison.OrdinalIgnoreCase)
        && Arguments.Count == arguments.Length
        && Arguments.Zip(arguments).All(pair => string.Equals(pair.First, pair.Second, StringComparison.OrdinalIgnoreCase));
}

public enum ScriptFailure
{
    /// <summary>The script ran and printed one JSON document.</summary>
    None,

    /// <summary>PowerShell could not be started at all.</summary>
    NotStarted,

    /// <summary>The script did not finish within its timeout. It was left running.</summary>
    TimedOut,

    /// <summary>The wait was abandoned (the session is ending).</summary>
    Cancelled,

    /// <summary>The script finished without printing exactly one JSON object.</summary>
    NoDocument,
}

/// <summary>
/// What a script call produced. A timeout, a crash and a standard output that
/// is not one JSON document are failures with details -- never a success.
/// </summary>
public sealed record ScriptOutcome(
    ScriptCall Call,
    ScriptFailure Failure,
    int? ExitCode,
    JsonElement? Document,
    string StandardError,
    TimeSpan Duration,
    string? FailureDetail)
{
    public bool HasDocument => Failure == ScriptFailure.None && Document.HasValue;

    /// <summary>A sentence for a user about a call that produced no document.</summary>
    public string DescribeFailure()
    {
        var detail = string.IsNullOrWhiteSpace(FailureDetail) ? string.Empty : " " + FailureDetail;
        return Failure switch
        {
            ScriptFailure.NotStarted => $"PowerShell could not run {Call.Script}.{detail}",
            ScriptFailure.TimedOut => $"{Call.Script} did not finish within {Call.Timeout.TotalSeconds:0} seconds. It was left running.",
            ScriptFailure.Cancelled => $"{Call.Script} was still running when LocalCanvas stopped waiting for it.",
            ScriptFailure.NoDocument => $"{Call.Script} ended (exit code {ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "unknown"}) without reporting a result.{detail}",
            _ => string.Empty,
        };
    }

    /// <summary>The last lines the script wrote to standard error, for Details.</summary>
    public string? StandardErrorTail(int lines = 15)
    {
        if (string.IsNullOrWhiteSpace(StandardError))
        {
            return null;
        }
        var all = StandardError.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Split('\n')
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .ToArray();
        return string.Join(Environment.NewLine, all.Skip(Math.Max(0, all.Length - lines)));
    }
}

public interface IScriptRunner
{
    Task<ScriptOutcome> RunAsync(ScriptCall call, CancellationToken cancellationToken = default);
}

/// <summary>
/// Runs <c>pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
/// &lt;root&gt;\scripts\&lt;name&gt;.ps1 &lt;args&gt; -Json</c> with no window and reads the one
/// JSON document it prints (docs/runtime.md, "Machine interface").
/// </summary>
/// <remarks>
/// <c>-ExecutionPolicy Bypass</c> applies to that one PowerShell process: files
/// extracted from a downloaded ZIP carry the mark of the web, and the scripts
/// could not run without it. No machine or user policy is changed.
/// </remarks>
public sealed class PwshScriptRunner : IScriptRunner
{
    private readonly string _pwsh;
    private readonly string _root;
    private readonly IProcessRunner _processes;
    private readonly ILauncherLog _log;
    private readonly IReadOnlyDictionary<string, string?>? _environment;

    public PwshScriptRunner(
        string pwsh,
        string root,
        IProcessRunner processes,
        ILauncherLog log,
        IReadOnlyDictionary<string, string?>? environment = null)
    {
        _pwsh = pwsh;
        _root = root;
        _processes = processes;
        _log = log;
        _environment = environment;
    }

    public static IReadOnlyList<string> BuildArguments(string root, ScriptCall call)
    {
        ArgumentNullException.ThrowIfNull(call);
        var arguments = new List<string>
        {
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", Path.Combine(root, "scripts", call.Script),
        };
        arguments.AddRange(call.Arguments);
        arguments.Add("-Json");
        return arguments;
    }

    public async Task<ScriptOutcome> RunAsync(ScriptCall call, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(call);
        _log.Write($"script: {call.Describe()} (timeout {call.Timeout.TotalSeconds:0} s)");
        var result = await _processes.RunHiddenAsync(
            new ProcessRequest(_pwsh, BuildArguments(_root, call), call.Timeout, _environment, _root),
            cancellationToken).ConfigureAwait(false);

        var outcome = Interpret(call, result);
        var ms = (long)result.Duration.TotalMilliseconds;
        var how = outcome.Failure == ScriptFailure.None ? "document" : outcome.Failure.ToString();
        _log.Write(
            $"script: {call.Script} exit {result.ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "none"} " +
            $"in {ms} ms ({how})" +
            (result.ProcessId is int pid && (result.TimedOut || result.Cancelled) ? $", PID {pid} left running" : string.Empty) +
            (outcome.FailureDetail is { } detail && outcome.Failure != ScriptFailure.None ? $": {detail}" : string.Empty));
        if (!string.IsNullOrWhiteSpace(result.StandardError))
        {
            _log.Write($"script: {call.Script} stderr:\n{result.StandardError.TrimEnd()}");
        }
        if (outcome.Failure == ScriptFailure.NoDocument && !string.IsNullOrWhiteSpace(result.StandardOutput))
        {
            _log.Write($"script: {call.Script} stdout (not a document):\n{Clip(result.StandardOutput, 4000)}");
        }
        return outcome;
    }

    internal static ScriptOutcome Interpret(ScriptCall call, ProcessResult result)
    {
        if (!result.Started)
        {
            return new ScriptOutcome(call, ScriptFailure.NotStarted, null, null, result.StandardError, result.Duration, result.StartError);
        }
        if (result.Cancelled)
        {
            return new ScriptOutcome(call, ScriptFailure.Cancelled, null, null, result.StandardError, result.Duration, null);
        }
        if (result.TimedOut)
        {
            return new ScriptOutcome(call, ScriptFailure.TimedOut, null, null, result.StandardError, result.Duration,
                result.ProcessId is int pid ? $"PID {pid.ToString(CultureInfo.InvariantCulture)}" : null);
        }

        var text = result.StandardOutput.Trim();
        if (text.Length == 0)
        {
            return new ScriptOutcome(call, ScriptFailure.NoDocument, result.ExitCode, null, result.StandardError, result.Duration,
                "It printed nothing.");
        }
        try
        {
            using var parsed = JsonDocument.Parse(text);
            if (parsed.RootElement.ValueKind != JsonValueKind.Object)
            {
                return new ScriptOutcome(call, ScriptFailure.NoDocument, result.ExitCode, null, result.StandardError, result.Duration,
                    "What it printed is not a JSON object.");
            }
            return new ScriptOutcome(call, ScriptFailure.None, result.ExitCode, parsed.RootElement.Clone(),
                result.StandardError, result.Duration, null);
        }
        catch (JsonException exception)
        {
            return new ScriptOutcome(call, ScriptFailure.NoDocument, result.ExitCode, null, result.StandardError, result.Duration,
                "What it printed is not one JSON document: " + exception.Message);
        }
    }

    private static string Clip(string text, int length) =>
        text.Length <= length ? text.TrimEnd() : new StringBuilder(text, 0, length, length + 20).Append(" [...]").ToString();
}
