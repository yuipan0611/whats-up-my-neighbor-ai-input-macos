using System.IO.Compression;

namespace NekoChat.Core;

/// <summary>Extract a trusted installer payload into a NEW staging directory only.</summary>
public static class PayloadArchive
{
    public static readonly string[] RequiredFiles = ["NekoChat.Windows.exe", "coreclr.dll", "hostfxr.dll", "PresentationFramework.dll", "Relay/NekoChatRelay.exe", "Relay/_internal/base_library.zip"];
    private const long MaximumBytes = 512L * 1024 * 1024;
    private static string Normalize(string value)
    {
        value = value.Replace('\\','/');
        if (string.IsNullOrEmpty(value) || value.StartsWith('/')) throw new InvalidDataException("安裝檔路徑不正確。");
        var parts = value.TrimEnd('/').Split('/');
        foreach (var part in parts) {
            var stem = part.Split('.')[0].ToUpperInvariant();
            if (part.Length == 0 || part is "." or ".." || part.EndsWith(' ') || part.EndsWith('.') ||
                part.Any(c => c < 32 || "<>:\"|?*".Contains(c)) || stem is "CON" or "PRN" or "AUX" or "NUL" ||
                stem.Length == 4 && (stem.StartsWith("COM",StringComparison.Ordinal) || stem.StartsWith("LPT",StringComparison.Ordinal)) && stem[3] is >= '1' and <= '9')
                throw new InvalidDataException("安裝檔包含不安全的路徑。");
        }
        return string.Join('/',parts);
    }
    public static void Extract(Stream payload, string destination)
    {
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("安裝暫存資料夾已存在。");
        using var zip = new ZipArchive(payload,ZipArchiveMode.Read,leaveOpen:true);
        if (zip.Entries.Count is 0 or >4096) throw new InvalidDataException("安裝檔內容數量不正確。");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long total=0;
        foreach(var entry in zip.Entries) {
            var path=Normalize(entry.FullName);
            if(!paths.Add(path) || (entry.ExternalAttributes>>16 & 0xF000)==0xA000 || entry.Length<0 || (total+=entry.Length)>MaximumBytes)
                throw new InvalidDataException("安裝檔內容不正確或過大。");
            if(!entry.FullName.EndsWith('/') && !entry.FullName.EndsWith('\\')) files.Add(path);
        }
        if(!RequiredFiles.All(files.Contains)) throw new InvalidDataException("安裝檔缺少 App 或內建中繼服務。");
        var root=Path.GetFullPath(destination)+Path.DirectorySeparatorChar;
        Directory.CreateDirectory(destination);
        try {
            foreach(var entry in zip.Entries) {
                var normalized=Normalize(entry.FullName);
                var full=Path.GetFullPath(Path.Combine(root,normalized.Replace('/',Path.DirectorySeparatorChar)));
                if(!full.StartsWith(root,StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安裝檔路徑超出安裝資料夾。");
                if(!files.Contains(normalized)) {Directory.CreateDirectory(full);continue;}
                Directory.CreateDirectory(Path.GetDirectoryName(full)!);
                using var input=entry.Open();using var output=new FileStream(full,FileMode.CreateNew,FileAccess.Write);
                var buffer=new byte[65536];long copied=0;int count;
                while((count=input.Read(buffer))>0) {
                    copied+=count;
                    if(copied>entry.Length || copied>MaximumBytes) throw new InvalidDataException("安裝檔解壓縮大小不正確。");
                    output.Write(buffer,0,count);
                }
                if(copied!=entry.Length) throw new InvalidDataException("安裝檔不完整。");
            }
        }catch {Directory.Delete(destination,true);throw;}
    }
}
