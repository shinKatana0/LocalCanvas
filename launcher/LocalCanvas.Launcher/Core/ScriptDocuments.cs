using System.Text.Json;

namespace LocalCanvas.Launcher.Core;

/// <summary>
/// Typed, lenient views of the <c>-Json</c> documents of docs/runtime.md,
/// "Machine interface". A field that is absent or of another type reads as
/// null: which keys a document carries is the scripts' business, and a
/// launcher that threw on a missing one would turn a version skew into a
/// crash.
/// </summary>
public sealed record ScriptError(string What, string? Detail, string? Fix);

public sealed record ScriptEnvelope(bool Ok, int? ExitCode, ScriptError? Error)
{
    public static ScriptEnvelope Read(JsonElement document) => new(
        Json.Bool(document, "ok") ?? false,
        Json.Int(document, "exit_code"),
        ReadError(document));

    private static ScriptError? ReadError(JsonElement document)
    {
        var error = Json.Object(document, "error");
        if (error is not { } found)
        {
            return null;
        }
        return new ScriptError(
            Json.String(found, "what") ?? "The script reported a failure.",
            Json.String(found, "detail"),
            Json.String(found, "fix"));
    }
}

public sealed record StartComfy(string? Status, string? Url, string? Ownership, int? Pid);

public sealed record StartGateway(
    string? Status,
    string? ProbeUrl,
    string? InstanceId,
    int? Pid,
    string? PublishedEndpoint,
    bool? IsLan,
    string? LocalOnlyReason);

public sealed record StartDocument(ScriptEnvelope Envelope, string? Component, StartComfy Comfy, StartGateway Gateway)
{
    public static StartDocument Read(JsonElement document)
    {
        var comfy = Json.Object(document, "comfy");
        var gateway = Json.Object(document, "gateway");
        return new StartDocument(
            ScriptEnvelope.Read(document),
            Json.String(document, "component"),
            new StartComfy(
                Json.String(comfy, "status"),
                Json.String(comfy, "url"),
                Json.String(comfy, "ownership"),
                Json.Int(comfy, "pid")),
            new StartGateway(
                Json.String(gateway, "status"),
                Json.String(gateway, "probe_url"),
                Json.String(gateway, "instance_id"),
                Json.Int(gateway, "pid"),
                Json.String(gateway, "published_endpoint"),
                Json.Bool(gateway, "is_lan"),
                Json.String(gateway, "local_only_reason")));
    }
}

public sealed record StopRole(string? StateBefore, string? Action, string? Result, int? Pid)
{
    public static StopRole Read(JsonElement? role) => new(
        Json.String(role, "state_before"),
        Json.String(role, "action"),
        Json.String(role, "result"),
        Json.Int(role, "pid"));

    /// <summary>
    /// The process this role's record named is gone, or there was none: a stop
    /// that ended in <c>exited</c> or <c>terminated</c>, or no running record
    /// at all (<c>none</c>, or a record that was removed as stale, unusable or
    /// someone else's).
    /// </summary>
    public bool NothingLeftRunning =>
        (Action == "stop" && Result is "exited" or "terminated")
        || Action is "none" or "record_removed";

    /// <summary>A process this role's record named may still be running.</summary>
    public bool LeftRunning =>
        Result == "still-running" || Action == "record_kept" || (Action == "stop" && Result is null);
}

public sealed record StopDocument(ScriptEnvelope Envelope, string? Component, StopRole Gateway, StopRole Comfy)
{
    public static StopDocument Read(JsonElement document)
    {
        var roles = Json.Object(document, "roles");
        return new StopDocument(
            ScriptEnvelope.Read(document),
            Json.String(document, "component"),
            StopRole.Read(Json.Object(roles, "gateway")),
            StopRole.Read(Json.Object(roles, "comfy")));
    }
}

public sealed record StatusGateway(bool? Reachable, string? Identity, string? InstanceId, string? Ownership, int? Pid, string? ProbeUrl);

public sealed record StatusComfy(bool? Healthy, string? Ownership, string? Url);

public sealed record StatusDocument(ScriptEnvelope Envelope, bool ConfigOk, StatusGateway Gateway, StatusComfy Comfy)
{
    public static StatusDocument Read(JsonElement document)
    {
        var gateway = Json.Object(document, "gateway");
        var comfy = Json.Object(document, "comfy");
        return new StatusDocument(
            ScriptEnvelope.Read(document),
            Json.Bool(document, "config_ok") ?? false,
            new StatusGateway(
                Json.Bool(gateway, "reachable"),
                Json.String(gateway, "identity"),
                Json.String(gateway, "instance_id"),
                Json.String(gateway, "ownership"),
                Json.Int(gateway, "pid"),
                Json.String(gateway, "probe_url")),
            new StatusComfy(
                Json.Bool(comfy, "healthy"),
                Json.String(comfy, "ownership"),
                Json.String(comfy, "url")));
    }
}

public sealed record SyncAttentionItem(string? Id, string? State, string? Reason);

public sealed record SyncDocument(
    ScriptEnvelope Envelope,
    bool? DryRun,
    int? Changes,
    int? Attention,
    int? New,
    int? Changed,
    int? Retry,
    int? Removed,
    int? DefinitionsWritten,
    string? Summary,
    IReadOnlyList<SyncAttentionItem> AttentionItems,
    int? AttentionItemsTotal)
{
    public static SyncDocument Read(JsonElement document)
    {
        var items = new List<SyncAttentionItem>();
        if (document.TryGetProperty("attention_items", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in list.EnumerateArray())
            {
                items.Add(new SyncAttentionItem(
                    Json.String(item, "id"), Json.String(item, "state"), Json.String(item, "reason")));
            }
        }
        return new SyncDocument(
            ScriptEnvelope.Read(document),
            Json.Bool(document, "dry_run"),
            Json.Int(document, "changes"),
            Json.Int(document, "attention"),
            Json.Int(document, "new"),
            Json.Int(document, "changed"),
            Json.Int(document, "retry"),
            Json.Int(document, "removed"),
            Json.Int(document, "definitions_written"),
            Json.String(document, "summary"),
            items,
            Json.Int(document, "attention_items_total"));
    }
}

internal static class Json
{
    public static JsonElement? Object(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } found)
        {
            return null;
        }
        return found.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Object ? value : null;
    }

    public static string? String(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } found || !found.TryGetProperty(name, out var value))
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    public static int? Int(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } found || !found.TryGetProperty(name, out var value))
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;
    }

    public static double? Double(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } found || !found.TryGetProperty(name, out var value))
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) ? number : null;
    }

    public static bool? Bool(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } found || !found.TryGetProperty(name, out var value))
        {
            return null;
        }
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }
}
