using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace NekoChat.Core;

public record ChatEvent(string Kind, string Id, string? Sender = null, string? Text = null,
    string? Status = null, string? Code = null, string? User = null);

public static partial class Protocol
{
    public const int MaxBytes = 16384;
    [GeneratedRegex("^[a-z0-9][a-z0-9_-]{0,31}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex UserPattern();
    [GeneratedRegex("^[A-Za-z0-9_-]{1,64}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex IdPattern();
    public static bool ValidUser(string value) => UserPattern().IsMatch(value);
    public static bool ValidText(string value) => !string.IsNullOrWhiteSpace(value) && value.EnumerateRunes().Count() <= 2000;
    public static string Send(string to, string text, string id)
    {
        if (!ValidUser(to) || !ValidText(text) || !IdPattern().IsMatch(id))
            throw new ArgumentException("好友 ID 或訊息格式不正確（最多 2000 字）。");
        return JsonSerializer.Serialize(new { protocol = "nekochat", version = 1, kind = "chat.send", id, to, text });
    }
    public static string Ping() => JsonSerializer.Serialize(new { protocol = "nekochat", version = 1, kind = "ping", id = Guid.NewGuid().ToString("N") });
    public static ChatEvent ParseServer(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > MaxBytes) throw new InvalidDataException("訊息過大。");
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("協議格式不符。");
        var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var p in root.EnumerateObject())
            if (!fields.TryAdd(p.Name, p.Value)) throw new InvalidDataException("重複欄位。");
        string Get(string key) => fields.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()! : throw new InvalidDataException("缺少協議欄位。");
        if (Get("protocol") != "nekochat" || !fields.TryGetValue("version", out var version) ||
            version.ValueKind != JsonValueKind.Number || version.GetRawText() != "1")
            throw new InvalidDataException("不支援的協議版本。");
        var kind = Get("kind"); var id = Get("id");
        if (!IdPattern().IsMatch(id)) throw new InvalidDataException("訊息 ID 不正確。");
        string[] extras = kind switch {
            "ready" => ["user"], "chat.message" => ["sender", "text"],
            "chat.ack" => ["status"], "error" => ["code"], "pong" => [],
            _ => throw new InvalidDataException("未知的聊天事件。")
        };
        var allowed = new HashSet<string>(new[] { "protocol", "version", "kind", "id" }.Concat(extras));
        if (!allowed.SetEquals(fields.Keys)) throw new InvalidDataException("未知的聊天欄位。");
        foreach (var key in extras) _ = Get(key);
        if (kind == "ready" && !ValidUser(Get("user")) || kind == "chat.message" &&
            (!ValidUser(Get("sender")) || !ValidText(Get("text")))) throw new InvalidDataException("訊息格式不正確。");
        if (kind == "chat.ack" && Get("status") is not ("delivered" or "duplicate")) throw new InvalidDataException("回條格式不正確。");
        if (kind == "error" && Get("code") is not ("invalid_event" or "forbidden" or "offline" or "rate_limited")) throw new InvalidDataException("錯誤格式不正確。");
        return new(kind, id, kind == "chat.message" ? Get("sender") : null,
            kind == "chat.message" ? Get("text") : null, kind == "chat.ack" ? Get("status") : null,
            kind == "error" ? Get("code") : null, kind == "ready" ? Get("user") : null);
    }
}
