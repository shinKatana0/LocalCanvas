using System.Globalization;
using System.Text.Json;

namespace LocalCanvas.Launcher.Core;

/// <summary>The two startup timeouts of <c>runtime.yaml</c>, as the gateway's loader reads them.</summary>
public sealed record StartupTimeouts(TimeSpan Comfy, TimeSpan Gateway, bool FromConfiguration)
{
    /// <summary>
    /// Used only when the configuration could not be read here. The scripts
    /// enforce the real values themselves; these bound how long the launcher
    /// waits for a script that has stopped answering.
    /// </summary>
    public static StartupTimeouts Fallback { get; } =
        new(TimeSpan.FromSeconds(300), TimeSpan.FromSeconds(120), FromConfiguration: false);
}

public interface IRuntimeSettingsReader
{
    Task<StartupTimeouts> ReadTimeoutsAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Reads the startup timeouts through the configuration seam of
/// docs/runtime.md -- <c>.venv\Scripts\python.exe -m localcanvas_gateway config
/// --config &lt;path&gt;</c>, run by PowerShell -- so there is still exactly one
/// definition of what <c>runtime.yaml</c> means. Nothing here parses YAML.
/// </summary>
public sealed class SeamSettingsReader : IRuntimeSettingsReader
{
    private readonly string _pwsh;
    private readonly string _root;
    private readonly IProcessRunner _processes;
    private readonly ILauncherLog _log;
    private readonly IReadOnlyDictionary<string, string?>? _environment;

    public SeamSettingsReader(
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

    public static string BuildCommand(string root)
    {
        var python = Path.Combine(root, ".venv", "Scripts", "python.exe");
        var config = Path.Combine(root, "config", "local", "runtime.yaml");
        return $"& {PowerShellText.Quote(python)} -m localcanvas_gateway config --config {PowerShellText.Quote(config)}; exit $LASTEXITCODE";
    }

    public async Task<StartupTimeouts> ReadTimeoutsAsync(CancellationToken cancellationToken = default)
    {
        var result = await _processes.RunHiddenAsync(
            new ProcessRequest(
                _pwsh,
                ["-NoProfile", "-NonInteractive", "-Command", BuildCommand(_root)],
                TimeSpan.FromSeconds(60),
                _environment,
                _root),
            cancellationToken).ConfigureAwait(false);

        var timeouts = Parse(result);
        if (timeouts is null)
        {
            _log.Write(
                $"settings: the configuration could not be read here (exit {result.ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "none"}); " +
                $"waiting on scripts with the fallback bounds ({StartupTimeouts.Fallback.Comfy.TotalSeconds:0} s / {StartupTimeouts.Fallback.Gateway.TotalSeconds:0} s)");
            return StartupTimeouts.Fallback;
        }
        _log.Write($"settings: comfy_timeout_seconds {timeouts.Comfy.TotalSeconds:0.#}, gateway_timeout_seconds {timeouts.Gateway.TotalSeconds:0.#}");
        return timeouts;
    }

    internal static StartupTimeouts? Parse(ProcessResult result)
    {
        if (!result.Started || result.TimedOut || result.Cancelled || result.ExitCode != 0)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(result.StandardOutput.Trim());
            var startup = Json.Object(document.RootElement, "startup");
            var comfy = Json.Double(startup, "comfy_timeout_seconds");
            var gateway = Json.Double(startup, "gateway_timeout_seconds");
            if (comfy is not > 0 || gateway is not > 0)
            {
                return null;
            }
            return new StartupTimeouts(TimeSpan.FromSeconds(comfy.Value), TimeSpan.FromSeconds(gateway.Value), FromConfiguration: true);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>PowerShell literal text, for the two commands the launcher composes.</summary>
public static class PowerShellText
{
    /// <summary>
    /// A single-quoted PowerShell string: nothing inside it is expanded, and an
    /// apostrophe is written twice. A Windows path cannot contain a double
    /// quote, so the result survives the command line unchanged.
    /// </summary>
    public static string Quote(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        // PowerShell also treats the typographic single quotes as quote
        // characters; each is doubled the same way.
        var escaped = text
            .Replace("'", "''", StringComparison.Ordinal)
            .Replace("‘", "‘‘", StringComparison.Ordinal)
            .Replace("’", "’’", StringComparison.Ordinal)
            .Replace("‚", "‚‚", StringComparison.Ordinal)
            .Replace("‛", "‛‛", StringComparison.Ordinal);
        return "'" + escaped + "'";
    }
}
