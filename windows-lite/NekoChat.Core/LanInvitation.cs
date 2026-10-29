using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NekoChat.Core;

/// <summary>A private capability for one guest. Never contains the host's credential.</summary>
public sealed record LanInvitation(int Version, string RoomId, string[] Hosts, int Port,
    string User, string Peer, string Token)
{
    public override string ToString()=>"NekoChat private LAN invitation";
    private const string Prefix = "NEKO1-";
    private static readonly JsonSerializerOptions JsonOptions = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        MaxDepth = 4
    };
    public static string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+','-').Replace('/','_');
    public static string NewUser() => "cat-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
    public static string Digest(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();
    public static bool PrivateIPv4(string host)
    {
        if (!IPAddress.TryParse(host, out var ip) || ip.GetAddressBytes().Length != 4 || ip.ToString() != host) return false;
        var a = ip.GetAddressBytes();
        return a[0] == 127 || a[0] == 10 || a[0] == 192 && a[1] == 168 || a[0] == 172 && a[1] is >= 16 and <= 31;
    }
    public void Validate()
    {
        if (Version != 1 || RoomId is null || RoomId.Length != 32 || RoomId.Any(c => !char.IsAsciiHexDigitLower(c)) ||
            Hosts is null || Hosts.Length is < 1 or > 8 || Hosts.Any(h => h is null || !PrivateIPv4(h)) ||
            Hosts.Distinct(StringComparer.Ordinal).Count() != Hosts.Length || Port is < 1 or > 65535 ||
            User is null || Peer is null || !Protocol.ValidUser(User) || !Protocol.ValidUser(Peer) || User == Peer ||
            Token is null || Token.Length != 43 || Token.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_')))
            throw new InvalidDataException("邀請碼格式不正確，請向同學重新複製完整邀請碼。");
    }
    public string Encode()
    {
        Validate();
        return Prefix + Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(this,JsonOptions)).TrimEnd('=').Replace('+','-').Replace('/','_');
    }
    public static LanInvitation Parse(string code)
    {
        code = code.Trim();
        if (code.Length > 4096 || !code.StartsWith(Prefix,StringComparison.Ordinal)) throw new InvalidDataException("請貼上 NekoChat 房間邀請碼。");
        try {
            var encoded = code[Prefix.Length..].Replace('-','+').Replace('_','/');
            var bytes = Convert.FromBase64String(encoded.PadRight((encoded.Length+3)/4*4,'='));
            using var doc = JsonDocument.Parse(bytes,new JsonDocumentOptions { MaxDepth=4 });
            var names = doc.RootElement.EnumerateObject().Select(p=>p.Name).ToArray();
            if (names.Length != names.Distinct(StringComparer.Ordinal).Count()) throw new JsonException();
            var invite = JsonSerializer.Deserialize<LanInvitation>(bytes,JsonOptions) ?? throw new JsonException();
            invite.Validate();return invite;
        } catch(Exception ex) when (ex is JsonException or FormatException or InvalidOperationException) {
            throw new InvalidDataException("邀請碼無法讀取，請重新複製完整內容。");
        }
    }
    public async Task<Uri> FindEndpointAsync(HttpClient http, CancellationToken cancellation)
    {
        Validate();
        foreach (var host in Hosts) {
            cancellation.ThrowIfCancellationRequested();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(TimeSpan.FromSeconds(2));
            try {
                using var response = await http.GetAsync($"http://{host}:{Port}/healthz",HttpCompletionOption.ResponseHeadersRead,timeout.Token);
                if (!response.IsSuccessStatusCode) continue;
                await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
                var bytes = new byte[2049];var count=0;
                while(count<bytes.Length) {int n=await stream.ReadAsync(bytes.AsMemory(count),timeout.Token);if(n==0)break;count+=n;}
                if(count>2048)continue;
                using var health=JsonDocument.Parse(bytes.AsMemory(0,count));
                if(health.RootElement.GetProperty("protocol").GetString()=="nekochat" &&
                    health.RootElement.GetProperty("version").GetInt32()==1 &&
                    health.RootElement.GetProperty("room_id").GetString()==RoomId)
                    return RelayConnection.ValidateEndpoint($"ws://{host}:{Port}/nekochat/v1/ws",true);
            }catch(Exception ex) when(ex is HttpRequestException or JsonException or KeyNotFoundException or InvalidOperationException or OperationCanceledException) {
                cancellation.ThrowIfCancellationRequested();
            }
        }
        throw new InvalidDataException("找不到同學的房間。請確認房主仍開著 App、兩台在同一教室網路，且允許互連；學校隔離時需由管理者提供 VPS 連線。");
    }
}
