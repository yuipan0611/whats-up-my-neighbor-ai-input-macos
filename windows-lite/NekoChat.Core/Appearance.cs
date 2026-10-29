using System.Text.Json;
using System.Text.RegularExpressions;

namespace NekoChat.Core;

public record PartStyle(string Color, string Pattern, string PatternColor);
public sealed record Appearance(string Preset, uint Seed, IReadOnlyDictionary<string,PartStyle> Parts)
{
    public static readonly string[] PartNames=["head","leftEar","rightEar","muzzle","chest","belly","body",
        "frontLeftLeg","frontRightLeg","rearLeftLeg","rearRightLeg","frontLeftPaw","frontRightPaw","rearLeftPaw","rearRightPaw","tail"];
    public static readonly string[] Presets=["original","black","white","blue","orange-tabby","tuxedo","calico","tortoiseshell","colorpoint"];
    private static string Color(JsonElement node) {
        var value=node.GetString() ?? "";
        if (!Regex.IsMatch(value,"^#[0-9a-fA-F]{6}$")) throw new InvalidDataException("花色必須使用 #RRGGBB。");
        return value.ToUpperInvariant();
    }
    public static Appearance Load(string json, Func<string,string> presetJson)
    {
        if (json.Length>65536) throw new InvalidDataException("花色 JSON 過大。");
        using var doc=JsonDocument.Parse(json,new JsonDocumentOptions{MaxDepth=12});
        var root=doc.RootElement;
        if(root.GetProperty("version").GetInt32() is not (1 or 2)) throw new InvalidDataException("不支援的貓咪設定版本。");
        if(!root.TryGetProperty("appearance",out var value)) return Base("original",presetJson);
        if(value.ValueKind!=JsonValueKind.Object || value.EnumerateObject().Any(p=>p.Name is not ("preset" or "seed" or "parts")))
            throw new InvalidDataException("花色格式不正確。");
        var id=value.GetProperty("preset").GetString() ?? "";
        if(!Presets.Contains(id)) throw new InvalidDataException("未知花色。");
        var basic=Base(id,presetJson);
        var seed=value.TryGetProperty("seed",out var s) ? s.GetUInt32() : 1;
        var parts=new Dictionary<string,PartStyle>(basic.Parts);
        if(value.TryGetProperty("parts",out var overrides)) foreach(var item in overrides.EnumerateObject()) {
            if(!parts.TryGetValue(item.Name,out var style)) throw new InvalidDataException("未知的花色部位。");
            foreach(var p in item.Value.EnumerateObject()) style=p.Name switch {
                "color"=>style with {Color=Color(p.Value)}, "patternColor"=>style with {PatternColor=Color(p.Value)},
                "pattern"=>style with {Pattern=ParsePattern(p.Value)}, _=>throw new InvalidDataException("未知的部位欄位。")
            };
            parts[item.Name]=style;
        }
        return new(id,seed,parts);
    }
    private static string ParsePattern(JsonElement e) => e.GetString() is string value &&
        new[]{"none","tabby","patches","calico","whiteSpots","point"}.Contains(value)
        ? value : throw new InvalidDataException("未知花紋。");
    private static Appearance Base(string id,Func<string,string> json)
    {
        using var d=JsonDocument.Parse(json(id));
        var parts=d.RootElement.GetProperty("appearance").GetProperty("parts");
        return new(id,1,PartNames.ToDictionary(p=>p,p=>new PartStyle(Color(parts.GetProperty(p).GetProperty("color")),
            ParsePattern(parts.GetProperty(p).GetProperty("pattern")),Color(parts.GetProperty(p).GetProperty("patternColor")))));
    }
}
