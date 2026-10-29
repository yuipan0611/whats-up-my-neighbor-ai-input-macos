using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.Json;
using NekoChat.Core;

internal static class ClassroomChecks
{
    internal static async Task<int> Run()
    {
        int checks=0;
        void Check(bool value,string message){checks++;if(!value)throw new Exception(message);}
        void Reject(Action action,string message){bool failed=false;try{action();}catch(Exception e)when(e is InvalidDataException or IOException){failed=true;}Check(failed,message);}
        var guestToken=LanInvitation.NewToken();var hostToken=LanInvitation.NewToken();
        Check(guestToken.Length==43 && guestToken!=hostToken,"individual random room credentials");
        var invite=new LanInvitation(1,new string('a',32),["192.168.1.20"],12345,LanInvitation.NewUser(),LanInvitation.NewUser(),guestToken);
        var encoded=invite.Encode();var decoded=LanInvitation.Parse(encoded);
        Check(decoded.User==invite.User && decoded.Token==guestToken && decoded.Hosts.SequenceEqual(invite.Hosts),"private invitation roundtrip");
        Check(!Encoding.UTF8.GetString(Convert.FromBase64String(encoded[6..].Replace('-','+').Replace('_','/').PadRight((encoded.Length-6+3)/4*4,'='))).Contains(hostToken),"host token never shared");
        foreach(var host in new[]{"0.0.0.0","8.8.8.8","example.com","127.1","169.254.1.1","::1","192.168.1.20.evil"})
            Reject(()=>(invite with{Hosts=[host]}).Encode(),"unsafe invitation host "+host);
        foreach(var invalid in new[]{invite with{Version=2},invite with{Port=0},invite with{Port=65536},invite with{Peer=invite.User},
            invite with{Token="short"},invite with{RoomId="bad"},invite with{Hosts=[]},invite with{Hosts=["10.0.0.1","10.0.0.1"]}})
            Reject(()=>invalid.Encode(),"invalid room capability");
        Reject(()=>LanInvitation.Parse("https://example.com"),"URL is not an invitation");
        Reject(()=>LanInvitation.Parse("NEKO1-"+new string('x',5000)),"bounded invite");
        string EncodeJson(string text)=>"NEKO1-"+Convert.ToBase64String(Encoding.UTF8.GetBytes(text)).TrimEnd('=').Replace('+','-').Replace('/','_');
        var json=JsonSerializer.Serialize(invite,new JsonSerializerOptions{PropertyNamingPolicy=JsonNamingPolicy.CamelCase});
        Reject(()=>LanInvitation.Parse(EncodeJson(json.Replace("\"version\":1","\"version\":1,\"version\":1"))),"duplicate invite fields");
        Reject(()=>LanInvitation.Parse(EncodeJson(json.Replace("\"version\":1","\"version\":1,\"command\":\"paste\""))),"unknown invite commands");
        var handler=new RoomHealthHandler(invite.RoomId);using var client=new HttpClient(handler);
        var endpoint=await invite.FindEndpointAsync(client,CancellationToken.None);
        Check(endpoint.AbsoluteUri=="ws://192.168.1.20:12345/nekochat/v1/ws" && handler.Calls==1 && !handler.SawAuthorization,"room discovery sends no credentials");
        handler.RoomId=new string('b',32);bool mismatch=false;
        try{await invite.FindEndpointAsync(client,CancellationToken.None);}catch(InvalidDataException){mismatch=true;}
        Check(mismatch,"wrong room rejected");
        using(var cancel=new CancellationTokenSource()){
            cancel.Cancel();bool canceled=false;
            try{await invite.FindEndpointAsync(client,cancel.Token);}catch(OperationCanceledException){canceled=true;}
            Check(canceled,"room join cancellation");
        }
        var root=Path.Combine(Path.GetTempPath(),"nekochat-installer-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try {
            MemoryStream Payload(string? extra=null){
                var stream=new MemoryStream();using(var zip=new ZipArchive(stream,ZipArchiveMode.Create,true)){
                    foreach(var name in PayloadArchive.RequiredFiles.Concat(extra is null?[]:new[]{extra})){
                        using var writer=new StreamWriter(zip.CreateEntry(name).Open());writer.Write("test-only-payload");
                    }
                }stream.Position=0;return stream;
            }
            using(var valid=Payload())PayloadArchive.Extract(valid,Path.Combine(root,"installed"));
            Check(File.ReadAllText(Path.Combine(root,"installed","Relay","NekoChatRelay.exe"))=="test-only-payload","full app/relay install payload");
            using(var valid=Payload())Reject(()=>PayloadArchive.Extract(valid,Path.Combine(root,"installed")),"never overwrite an existing folder");
            foreach(var unsafeName in new[]{"../escape.txt","C:/escape.txt","/absolute.txt","Relay/../../escape.txt","Relay/file:secret","Relay/CON.txt","Relay/trailing.","nekochat.windows.exe"}){
                using var bad=Payload(unsafeName);
                var target=Path.Combine(root,Guid.NewGuid().ToString("N"));
                Reject(()=>PayloadArchive.Extract(bad,target),"unsafe install path "+unsafeName);
                Check(!Directory.Exists(target),"invalid payload writes nothing");
            }
            using(var incomplete=new MemoryStream()){
                using(var zip=new ZipArchive(incomplete,ZipArchiveMode.Create,true))zip.CreateEntry("readme.txt");incomplete.Position=0;
                Reject(()=>PayloadArchive.Extract(incomplete,Path.Combine(root,"incomplete")),"missing bundled Relay rejected");
            }
        }finally{Directory.Delete(root,true);}
        return checks;
    }
    private sealed class RoomHealthHandler(string roomId):HttpMessageHandler {
        internal string RoomId=roomId;internal int Calls;internal bool SawAuthorization;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation){
            Calls++;SawAuthorization|=request.Headers.Authorization is not null;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(JsonSerializer.Serialize(new{protocol="nekochat",version=1,room_id=RoomId}))});
        }
    }
}
