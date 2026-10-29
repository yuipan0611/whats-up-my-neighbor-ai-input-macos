using System.IO;
using System.Buffers.Binary;
using System.IO.Compression;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NekoChat.Core;

namespace NekoChat.Windows;

internal static class CatArtwork
{
    private static string Asset(string name)=>Path.Combine(AppContext.BaseDirectory,"Assets",name);
    internal static string PresetJson(string id)=>File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"Coats",id+".json"));
    internal static BitmapSource Preset(string id)=>LoadPng(Asset(id+".png"));
    private static BitmapSource LoadPng(string path)
    {
        var bytes=File.ReadAllBytes(path);
        if(bytes.Length>5_000_000) throw new InvalidDataException("圖片過大。");
        byte[] signature=[137,80,78,71,13,10,26,10];
        if(bytes.Length<24 || !bytes.AsSpan(0,8).SequenceEqual(signature) ||
            BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16,4)) is 0 or >2048 ||
            BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20,4)) is 0 or >2048)
            throw new InvalidDataException("請使用 2048×2048 以內的 PNG。");
        using var stream=new MemoryStream(bytes);
        var decoder=new PngBitmapDecoder(stream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
        var bitmap=decoder.Frames[0];
        if(bitmap.PixelWidth>2048 || bitmap.PixelHeight>2048) throw new InvalidDataException("圖片最大為 2048×2048。");
        bitmap.Freeze();return bitmap;
    }
    internal static BitmapSource FromConfig(string path)
    {
        var info=new FileInfo(path);
        if(info.Length>65536) throw new InvalidDataException("貓咪設定過大。");
        var json=File.ReadAllText(path);
        var appearance=Appearance.Load(json,PresetJson);
        using var document=JsonDocument.Parse(json);
        if(document.RootElement.TryGetProperty("image",out var image) && image.ValueKind==JsonValueKind.String) {
            var relative=image.GetString()!;
            if(Path.IsPathRooted(relative) || relative.Contains(':')) throw new InvalidDataException("圖片請放在設定同一資料夾內。");
            var root=Path.GetDirectoryName(Path.GetFullPath(path))!+Path.DirectorySeparatorChar;
            var full=Path.GetFullPath(Path.Combine(root,relative));
            if(!full.StartsWith(root,StringComparison.OrdinalIgnoreCase) || Path.GetExtension(full).ToLowerInvariant()!=".png")
                throw new InvalidDataException("只支援設定資料夾內的 PNG。");
            return LoadPng(full);
        }
        var canonical=Appearance.Load(PresetJson(appearance.Preset),PresetJson);
        if(appearance.Seed==1 && appearance.Parts.All(p=>canonical.Parts[p.Key]==p.Value)) return Preset(appearance.Preset);
        return Render(appearance);
    }
    private static byte[] Unzip(string name)
    {
        using var stream=File.OpenRead(Asset(name));using var gzip=new GZipStream(stream,CompressionMode.Decompress);
        using var result=new MemoryStream();gzip.CopyTo(result);return result.ToArray();
    }
    internal static BitmapSource Render(Appearance appearance)
    {
        var original=new FormatConvertedBitmap(Preset("original"),PixelFormats.Bgra32,null,0);
        int w=original.PixelWidth,h=original.PixelHeight;
        var bytes=new byte[w*h*4];original.CopyPixels(bytes,w*4,0);
        var map=Unzip("anatomy.bin.gz");var masks=Unzip("tabby.bin.gz");
        if(map.Length!=w*h*9 || masks.Length!=3*512*512) throw new InvalidDataException("花色素材不完整。");
        for(int n=0;n<w*h;n++) {
            int i=n*4;if(bytes[i+3]==0)continue;
            var part=Appearance.PartNames[map[n*9]];
            double u=BitConverter.ToSingle(map,n*9+1),v=BitConverter.ToSingle(map,n*9+5);
            var style=appearance.Parts[part];var coat=Rgb(style.Color);var secondary=Rgb(style.PatternColor);
            double shift=appearance.Seed%997/997.0*.12;
            bool Ellipse(double x,double y,double rx,double ry)=>Math.Pow((u-x)/rx,2)+Math.Pow((v-y)/ry,2)<1;
            double Distance(double x,double y,double rx,double ry)=>Math.Pow((u-x)/rx,2)+Math.Pow((v-y)/ry,2);
            if(style.Pattern=="tabby") {
                int region=part=="head"?0:part=="tail"?2:1;
                double offset=(appearance.Seed%997/996.0-1/996.0)*.012;
                double sampleV=region==2?v:v-offset;
                double coverage=u<0||u>1||sampleV<0||sampleV>1?0:masks[region*512*512+Math.Min(511,(int)(sampleV*512))*512+Math.Min(511,(int)(u*512))]/255.0;
                coat=coat.Zip(secondary,(a,b)=>a+(b-a)*coverage).ToArray();
            } else if(style.Pattern is "patches" or "calico") {
                bool orange=Ellipse(.20+shift,.30,.24,.36)||Ellipse(.75,.79-shift,.27,.31);
                bool dark=Ellipse(.89-shift,.22,.24,.34)||Ellipse(.15,.87,.28,.28);
                if(orange)coat=secondary;
                else if(style.Pattern=="calico" && part=="head" && !dark && (u<.25||u>.78)) {
                    bool left=u<.5;
                    coat=(left?Distance(.20+shift,.30,.24,.36):Distance(.75,.79-shift,.27,.31)) <
                        (left?Distance(.15,.87,.28,.28):Distance(.89-shift,.22,.24,.34))?secondary:Rgb("#393431");
                } else if(style.Pattern=="calico" && dark)coat=Rgb("#393431");
            } else if(style.Pattern=="whiteSpots" && Ellipse(.48+shift,.65,.23,.42) || style.Pattern=="point" && Ellipse(.50,.76,.36,.23))coat=secondary;
            double luminance=(bytes[i]+bytes[i+1]+bytes[i+2])/3.0;
            double feature=Math.Clamp((luminance-65)/175,0,1),detail=Math.Clamp(.88+luminance*.006,.72,1.08);
            bool light=.299*coat[0]+.587*coat[1]+.114*coat[2]>150;
            if(light && luminance>27 && luminance<90)detail=1-.60*(luminance-27)/63;
            var ink=Rgb(light?"#51443A":"#FFF8EC");
            for(int channel=0;channel<3;channel++)bytes[i+2-channel]=(byte)Math.Clamp(coat[channel]*detail*(1-feature)+ink[channel]*feature,0,255);
        }
        var result=BitmapSource.Create(w,h,96,96,PixelFormats.Bgra32,null,bytes,w*4);result.Freeze();return result;
    }
    private static double[] Rgb(string hex)=>[Convert.ToByte(hex.Substring(1,2),16),Convert.ToByte(hex.Substring(3,2),16),Convert.ToByte(hex.Substring(5,2),16)];
}
