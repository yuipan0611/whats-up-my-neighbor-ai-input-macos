using System.IO;
using System.Text.Json;

namespace NekoChat.Windows;

internal record Settings
{
    public bool Lan { get; init; } = true;
    public string LanEndpoint { get; init; } = "ws://127.0.0.1:8765/nekochat/v1/ws";
    public string VpsEndpoint { get; init; } = "wss://relay.example.invalid/nekochat/v1/ws";
    public string User { get; init; } = "";
    public string Coat { get; init; } = "original";
    internal string Endpoint => Lan ? LanEndpoint : VpsEndpoint;
    internal static readonly string DirectoryPath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NekoChat.WindowsLite");
    private static string FilePath=>Path.Combine(DirectoryPath,"settings.json");
    internal static Settings Load()
    {
        if (!File.Exists(FilePath)) return new();
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception ex) when (ex is IOException or JsonException) { return new(); }
    }
    internal void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(FilePath+".tmp", JsonSerializer.Serialize(this));
        File.Move(FilePath+".tmp", FilePath, true);
    }
}
