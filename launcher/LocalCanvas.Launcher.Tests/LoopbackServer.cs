using System.Net;
using System.Net.Sockets;
using System.Text;

namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// A real HTTP listener on 127.0.0.1 and an ephemeral port, answering from a
/// function of the request path. A null answer holds the connection open and
/// says nothing -- a port that accepts and never answers.
/// </summary>
internal sealed class LoopbackServer : IAsyncDisposable
{
    public sealed record Reply(int Status, string ContentType, string Body);

    private readonly TcpListener _listener;
    private readonly Func<string, Reply?> _answer;
    private readonly CancellationTokenSource _stop = new();
    private readonly List<TcpClient> _held = [];
    private readonly Task _loop;
    private int _requests;

    public LoopbackServer(Func<string, Reply?> answer)
    {
        _answer = answer;
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        TestEnvironment.AssertNotALivePort(Port);
        _loop = Task.Run(AcceptLoopAsync);
    }

    public int Port { get; }

    public int Requests => Volatile.Read(ref _requests);

    public Uri Url(string path) => new($"http://127.0.0.1:{Port}{path}");

    public static Reply Json(string body, int status = 200) => new(status, "application/json", body);

    public static Reply Info(string? instanceId, int jobs = 0, string service = "localcanvas") =>
        Json($"{{\"service\":\"{service}\",\"api_version\":1,\"instance_id\":{(instanceId is null ? "null" : "\"" + instanceId + "\"")},\"jobs\":{{\"active\":{jobs}}}}}");

    /// <summary>A port on which nothing is listening: bound, read, released.</summary>
    public static int UnusedPort()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        TestEnvironment.AssertNotALivePort(port);
        return port;
    }

    private async Task AcceptLoopAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token);
            }
            catch (Exception exception) when (exception is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                return;
            }
            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        try
        {
            var stream = client.GetStream();
            var request = new StringBuilder();
            var buffer = new byte[4096];
            while (!request.ToString().Contains("\r\n\r\n", StringComparison.Ordinal))
            {
                var read = await stream.ReadAsync(buffer, _stop.Token);
                if (read == 0)
                {
                    client.Dispose();
                    return;
                }
                request.Append(Encoding.ASCII.GetString(buffer, 0, read));
            }
            Interlocked.Increment(ref _requests);
            var path = request.ToString().Split(' ', 3)[1];
            var reply = _answer(path);
            if (reply is null)
            {
                lock (_held)
                {
                    _held.Add(client);
                }
                return;
            }
            var body = Encoding.UTF8.GetBytes(reply.Body);
            var head = Encoding.ASCII.GetBytes(
                $"HTTP/1.1 {reply.Status} X\r\nContent-Type: {reply.ContentType}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(head, _stop.Token);
            await stream.WriteAsync(body, _stop.Token);
            await stream.FlushAsync(_stop.Token);
            client.Dispose();
        }
        catch (Exception exception) when (exception is IOException or OperationCanceledException or ObjectDisposedException or SocketException)
        {
            client.Dispose();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        _listener.Stop();
        lock (_held)
        {
            foreach (var client in _held)
            {
                client.Dispose();
            }
        }
        try
        {
            await _loop;
        }
        catch (OperationCanceledException)
        {
        }
        _stop.Dispose();
    }
}
