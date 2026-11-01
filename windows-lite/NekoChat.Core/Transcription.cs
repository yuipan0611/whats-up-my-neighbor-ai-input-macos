using System.Net.Http.Headers;
using System.Text.Json;

namespace NekoChat.Core;

public interface ITranscriptionProvider
{
    Task<string> TranscribeAsync(byte[] wav, string apiKey, CancellationToken cancellation);
}

public sealed class GroqWhisperProvider(HttpClient http) : ITranscriptionProvider
{
    public async Task<string> TranscribeAsync(byte[] wav, string apiKey, CancellationToken cancellation)
    {
        if (wav.Length is < 44 or > 24_000_000) throw new ArgumentException("錄音大小不正確。");
        if (string.IsNullOrWhiteSpace(apiKey)) throw new ArgumentException("請先儲存自己的 Groq API Key。");
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent("whisper-large-v3"), "model");
        form.Add(new StringContent("json"), "response_format");
        form.Add(new StringContent("0"), "temperature");
        var audio = new ByteArrayContent(wav);
        audio.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(audio, "file", "speech.wav");
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.groq.com/openai/v1/audio/transcriptions") { Content = form };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        using var response = await http.SendAsync(request, cancellation);
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"Groq 轉錄失敗（HTTP {(int)response.StatusCode}），請檢查金鑰、額度與網路。");
        // Do not surface provider response bodies: they may contain user audio/text.
        var raw = await response.Content.ReadAsStringAsync(cancellation);
        if (raw.Length > 100_000) throw new InvalidDataException("轉錄回應過大。");
        using var result = JsonDocument.Parse(raw);
        if (!result.RootElement.TryGetProperty("text", out var value) || value.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("Groq 回應缺少文字。");
        var text = value.GetString()!.Trim();
        if (text.Length == 0) throw new InvalidDataException("未辨識到語音，請再試一次。");
        return text;
    }
}
