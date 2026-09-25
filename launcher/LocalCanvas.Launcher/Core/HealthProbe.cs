using System.Net;
using System.Text.Json;

namespace LocalCanvas.Launcher.Core;

/// <summary>What one gateway probe found.</summary>
/// <param name="Ready">
/// HTTP 200, a JSON object, <c>service == "localcanvas"</c> and the expected
/// <c>instance_id</c>. Nothing less.
/// </param>
/// <param name="Reason">Why it is not ready, in a sentence; empty when it is.</param>
/// <param name="JobsActive"><c>jobs.active</c> -- only from the expected instance.</param>
public sealed record GatewayHealth(bool Ready, string Reason, string? InstanceId, int? JobsActive)
{
    public static GatewayHealth NotReady(string reason, string? instanceId = null) => new(false, reason, instanceId, null);
}

public interface IHealthProbe
{
    Task<GatewayHealth> ProbeGatewayAsync(Uri infoUrl, string? expectedInstanceId, CancellationToken cancellationToken = default);

    Task<bool> ProbeComfyAsync(Uri comfyBaseUrl, CancellationToken cancellationToken = default);

    Task<int?> CountWorkflowsAsync(Uri gatewayBaseUrl, CancellationToken cancellationToken = default);
}

/// <summary>
/// The launcher's only direct contact with the runtime: read-only HTTP GETs,
/// two seconds each, never through a proxy, a fresh connection every time.
/// </summary>
/// <remarks>
/// A PID that exists and a port that accepts are never evidence of health
/// (docs/runtime.md, "Readiness is identity-verified"): the gateway is ready
/// only when it answers <c>/api/v1/info</c> as LocalCanvas with the instance
/// id of the process the scripts started.
/// </remarks>
public sealed class HttpHealthProbe : IHealthProbe, IDisposable
{
    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(2);
    private const int MaxBodyBytes = 1024 * 1024;
    private readonly HttpClient _client;

    public HttpHealthProbe()
    {
        var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            ConnectTimeout = ProbeTimeout,
            PooledConnectionLifetime = TimeSpan.Zero,
            AutomaticDecompression = DecompressionMethods.None,
            UseCookies = false,
        };
        _client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public static Uri InfoUrlFrom(string probeUrl)
    {
        var uri = new Uri(probeUrl, UriKind.Absolute);
        if (uri.AbsolutePath.TrimEnd('/').EndsWith("/api/v1/info", StringComparison.OrdinalIgnoreCase))
        {
            return uri;
        }
        return new Uri(BaseOf(uri), "api/v1/info");
    }

    public static Uri BaseOf(Uri uri) => new(uri.GetLeftPart(UriPartial.Authority) + "/");

    public async Task<GatewayHealth> ProbeGatewayAsync(Uri infoUrl, string? expectedInstanceId, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(infoUrl);
        if (string.IsNullOrEmpty(expectedInstanceId))
        {
            return GatewayHealth.NotReady("No Gateway instance is expected.");
        }
        var answer = await GetAsync(infoUrl, cancellationToken).ConfigureAwait(false);
        if (answer.Problem is { } problem)
        {
            return GatewayHealth.NotReady(problem);
        }
        if (answer.Status != HttpStatusCode.OK)
        {
            return GatewayHealth.NotReady($"{infoUrl} answered HTTP {(int)answer.Status}.");
        }
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(answer.Body);
        }
        catch (JsonException)
        {
            return GatewayHealth.NotReady($"{infoUrl} answered with something that is not JSON.");
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return GatewayHealth.NotReady($"{infoUrl} answered with JSON that is not an object.");
            }
            if (Json.String(root, "service") != "localcanvas")
            {
                return GatewayHealth.NotReady($"{infoUrl} is answered by something that is not a LocalCanvas Gateway.");
            }
            var instance = Json.String(root, "instance_id");
            if (!string.Equals(instance, expectedInstanceId, StringComparison.Ordinal))
            {
                return GatewayHealth.NotReady(
                    instance is null
                        ? $"{infoUrl} is a LocalCanvas Gateway that does not say which instance it is."
                        : $"{infoUrl} is answered by another LocalCanvas Gateway (instance {instance}).",
                    instance);
            }
            var jobs = Json.Int(Json.Object(root, "jobs"), "active");
            return new GatewayHealth(true, string.Empty, instance, jobs);
        }
    }

    public async Task<bool> ProbeComfyAsync(Uri comfyBaseUrl, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(comfyBaseUrl);
        var answer = await GetAsync(new Uri(BaseOf(comfyBaseUrl), "system_stats"), cancellationToken).ConfigureAwait(false);
        return answer.Problem is null && answer.Status == HttpStatusCode.OK;
    }

    public async Task<int?> CountWorkflowsAsync(Uri gatewayBaseUrl, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(gatewayBaseUrl);
        var answer = await GetAsync(new Uri(BaseOf(gatewayBaseUrl), "api/v1/workflows"), cancellationToken).ConfigureAwait(false);
        if (answer.Problem is not null || answer.Status != HttpStatusCode.OK)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(answer.Body);
            return document.RootElement.ValueKind == JsonValueKind.Object
                   && document.RootElement.TryGetProperty("workflows", out var list)
                   && list.ValueKind == JsonValueKind.Array
                ? list.GetArrayLength()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public void Dispose() => _client.Dispose();

    private sealed record Answer(HttpStatusCode Status, byte[] Body, string? Problem);

    private async Task<Answer> GetAsync(Uri url, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(ProbeTimeout);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.ConnectionClose = true;
            request.Headers.Accept.ParseAdd("application/json");
            using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token)
                .ConfigureAwait(false);
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            using var buffer = new MemoryStream();
            var chunk = new byte[16 * 1024];
            while (true)
            {
                var read = await stream.ReadAsync(chunk, deadline.Token).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }
                if (buffer.Length + read > MaxBodyBytes)
                {
                    return new Answer(response.StatusCode, [], $"{url} answered with more than {MaxBodyBytes} bytes.");
                }
                buffer.Write(chunk, 0, read);
            }
            return new Answer(response.StatusCode, buffer.ToArray(), null);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new Answer(0, [], $"{url} did not answer within {ProbeTimeout.TotalSeconds:0} seconds.");
        }
        catch (HttpRequestException exception)
        {
            return new Answer(0, [], $"{url} could not be reached ({exception.HttpRequestError}).");
        }
        catch (IOException exception)
        {
            return new Answer(0, [], $"{url} could not be read ({exception.Message}).");
        }
    }
}
