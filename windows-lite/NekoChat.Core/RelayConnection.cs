using System.Net;
using System.Net.WebSockets;
using System.Text;

namespace NekoChat.Core;

public sealed class RelayConnection : IAsyncDisposable
{
    private readonly ClientWebSocket socket = new();
    private readonly SemaphoreSlim sending = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private Task? heartbeat;
    public bool Connected => socket.State == WebSocketState.Open;

    public static Uri ValidateEndpoint(string url, bool lan)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.UserInfo.Length != 0 ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath != "/nekochat/v1/ws" ||
            uri.Scheme is not ("ws" or "wss")) throw new ArgumentException("請填完整的 NekoChat Relay 位址。");
        if (uri.Scheme == "ws")
        {
            // Plaintext is an explicit LAN-only opt-in; no DNS rebinding or public hostnames.
            if (!lan || !IPAddress.TryParse(uri.Host, out var ip) || !PrivateAddress(ip))
                throw new ArgumentException("VPS 必須使用 WSS；LAN WS 只接受私有／本機 IP。");
        }
        return uri;
    }
    private static bool PrivateAddress(IPAddress ip)
    {
        if (IPAddress.IsLoopback(ip)) return true;
        var a=ip.GetAddressBytes();
        return a.Length == 4 && (a[0] == 10 || a[0] == 192 && a[1] == 168 || a[0] == 172 && a[1] is >=16 and <=31);
    }
    public async Task ConnectAsync(Uri uri, string user, string token, CancellationToken cancellation)
    {
        if (!Protocol.ValidUser(user) || string.IsNullOrWhiteSpace(token) || token.Any(char.IsWhiteSpace) || token.Contains(':'))
            throw new ArgumentException("請填有效的帳號與個人 Relay 憑證。");
        socket.Options.SetRequestHeader("Authorization", $"Bearer {user}:{token}");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        await socket.ConnectAsync(uri, timeout.Token);
        heartbeat = HeartbeatAsync();
    }
    private async Task HeartbeatAsync()
    {
        try {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(25));
            while (await timer.WaitForNextTickAsync(lifetime.Token)) await SendRawAsync(Protocol.Ping(), lifetime.Token);
        } catch (Exception ex) when (ex is OperationCanceledException or WebSocketException or ObjectDisposedException) {
            socket.Abort();
        }
    }
    private async Task SendRawAsync(string json, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        await sending.WaitAsync(timeout.Token);
        try { await socket.SendAsync(Encoding.UTF8.GetBytes(json).AsMemory(), WebSocketMessageType.Text, true, timeout.Token); }
        finally { sending.Release(); }
    }
    public Task SendAsync(string to, string text, string id, CancellationToken cancellation) =>
        SendRawAsync(Protocol.Send(to, text, id), cancellation);

    public async Task ReceiveAsync(Action<ChatEvent> onEvent, CancellationToken cancellation)
    {
        var buffer = new byte[4096];
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        while (!linked.IsCancellationRequested)
        {
            using var message = new MemoryStream();
            ValueWebSocketReceiveResult chunk;
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(70));
            do {
                chunk = await socket.ReceiveAsync(buffer.AsMemory(), deadline.Token);
                if (chunk.MessageType == WebSocketMessageType.Close) return;
                if (chunk.MessageType != WebSocketMessageType.Text || message.Length + chunk.Count > Protocol.MaxBytes)
                    throw new InvalidDataException("Relay 傳來不支援的訊息。");
                message.Write(buffer, 0, chunk.Count);
            } while (!chunk.EndOfMessage);
            onEvent(Protocol.ParseServer(new UTF8Encoding(false, true).GetString(message.ToArray())));
        }
    }
    public void Abort()
    {
        lifetime.Cancel();socket.Abort();socket.Dispose();
    }
    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync();
        socket.Abort();
        if (heartbeat is not null) { try { await heartbeat; } catch (OperationCanceledException) { } }
        socket.Dispose();
        // Send/receive callers may still be unwinding; semaphore/CTS are managed objects.
    }
}
