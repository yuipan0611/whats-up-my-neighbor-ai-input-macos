using System.Net;
using System.Text;
using System.Text.Json;
using NekoChat.Core;

int checks=0;
void Check(bool result,string description) {checks++;if(!result)throw new Exception(description);}
void Reject(Action action,string name) {bool rejected=false;try{action();}catch(Exception ex)when(ex is ArgumentException or InvalidDataException or JsonException or InvalidOperationException or FormatException){rejected=true;}Check(rejected,name);}
string Json(string id)=>File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"Coats",id+".json"));
foreach(var id in Appearance.Presets) {
    var a=Appearance.Load(Json(id),Json);Check(a.Preset==id&&a.Parts.Count==16,"full existing coat "+id);
}
var custom=Appearance.Load("""{"version":2,"appearance":{"preset":"white","seed":99,"parts":{"head":{"color":"#aabbcc","pattern":"tabby","patternColor":"#123456"}}}}""",Json);
Check(custom.Seed==99&&custom.Parts["head"].Color=="#AABBCC"&&custom.Parts["tail"].Color=="#F4EFE5","part override and fallback");
Reject(()=>Appearance.Load("""{"version":2,"appearance":{"preset":"white","parts":{"shell":{"color":"#000000"}}}}""",Json),"unknown anatomy");
Reject(()=>Appearance.Load("""{"version":2,"appearance":{"preset":"white","parts":{"head":{"color":"red"}}}}""",Json),"bad color");
Check(Protocol.ValidText(string.Concat(Enumerable.Repeat("🐈",2000))),"Unicode scalar limit");
Check(!Protocol.ValidText(string.Concat(Enumerable.Repeat("🐈",2001))),"Unicode scalar overflow");
Check(!Protocol.ValidText(" \r\n\t"),"whitespace");
foreach(var user in new[]{"../bob","A","a b","a\n","",new string('a',33)})Check(!Protocol.ValidUser(user),"bad user "+user);
var raw=Protocol.Send("bob","下課見 🐈","id_1");using(var doc=JsonDocument.Parse(raw))Check(doc.RootElement.GetProperty("text").GetString()=="下課見 🐈","send encoding");
Reject(()=>Protocol.Send("bob","","id"),"blank send");
Check(Protocol.ParseServer("""{"protocol":"nekochat","version":1,"kind":"chat.message","id":"i","sender":"alice","text":"hello"}""").Sender=="alice","receive chat");
foreach(var kind in new[]{"executeRequest","agent.run","chat.send","paste"})Reject(()=>Protocol.ParseServer($$"""{"protocol":"nekochat","version":1,"kind":"{{kind}}","id":"i"}"""),"remote event rejected");
foreach(var json in new[]{
    """{"protocol":"nekochat","version":1,"kind":"ready","id":"i","user":"alice","action":"paste"}""",
    """{"protocol":"office","version":1,"kind":"ready","id":"i","user":"alice"}""",
    """{"protocol":"nekochat","version":true,"kind":"ready","id":"i","user":"alice"}""",
    """{"protocol":"nekochat","version":1.0,"kind":"ready","id":"i","user":"alice"}""",
    """{"protocol":"nekochat","version":1,"kind":"ready","id":"i","user":"alice","user":"bob"}""",
    """{"protocol":"nekochat","version":2,"kind":"ready","id":"i","user":"alice"}""",
    """{"protocol":"nekochat","version":1,"kind":"error","id":"i","code":"run_shell"}"""
})Reject(()=>Protocol.ParseServer(json),"invalid server packet");
foreach(var url in new[]{"ws://example.com/nekochat/v1/ws","ws://8.8.8.8/nekochat/v1/ws","ws://127.0.0.1/office/ws","wss://u:p@example.com/nekochat/v1/ws","wss://example.com/nekochat/v1/ws?token=secret","https://example.com/nekochat/v1/ws"})
    Reject(()=>RelayConnection.ValidateEndpoint(url,true),"endpoint restrictions");
Reject(()=>RelayConnection.ValidateEndpoint("ws://192.168.1.5/nekochat/v1/ws",false),"VPS needs WSS");
Check(RelayConnection.ValidateEndpoint("ws://192.168.1.5/nekochat/v1/ws",true).Scheme=="ws","explicit private LAN");
Check(RelayConnection.ValidateEndpoint("wss://example.com/nekochat/v1/ws",false).Scheme=="wss","public WSS");

var handler=new FakeHandler();using var http=new HttpClient(handler);var provider=new GroqWhisperProvider(http);
var wav=new byte[32044];Encoding.ASCII.GetBytes("RIFF").CopyTo(wav,0);
Check(await provider.TranscribeAsync(wav,"test-only-api-key",CancellationToken.None)=="下課見","transcription result");
Check(handler.Endpoint=="https://api.groq.com/openai/v1/audio/transcriptions"&&handler.Auth=="Bearer test-only-api-key","fixed TLS provider and auth");
Check(handler.Body.Contains("whisper-large-v3")&&handler.Body.Contains("speech.wav")&&handler.Body.Contains("audio/wav"),"multipart audio contract");
handler.Code=HttpStatusCode.Unauthorized;bool safe=false;
try{await provider.TranscribeAsync(wav,"test-only-api-key",CancellationToken.None);}catch(HttpRequestException ex){safe=!ex.Message.Contains("sensitive-server-response");}Check(safe,"provider body never surfaced");
if(args.Length==2&&args[0]=="--live") {
    var port=args[1];await using var alice=new RelayConnection();await using var bob=new RelayConnection();
    using var cancel=new CancellationTokenSource(TimeSpan.FromSeconds(20));
    var url=RelayConnection.ValidateEndpoint($"ws://127.0.0.1:{port}/nekochat/v1/ws",true);
    await alice.ConnectAsync(url,"alice","test-only-alice-not-a-real-credential",cancel.Token);
    await bob.ConnectAsync(url,"bob","test-only-bob-not-a-real-credential",cancel.Token);
    var ar=new TaskCompletionSource();var br=new TaskCompletionSource();var received=new TaskCompletionSource<ChatEvent>();var ack=new TaskCompletionSource<ChatEvent>();
    var at=alice.ReceiveAsync(e=>{if(e.Kind=="ready")ar.TrySetResult();if(e.Kind=="chat.ack")ack.TrySetResult(e);},cancel.Token);
    var bt=bob.ReceiveAsync(e=>{if(e.Kind=="ready")br.TrySetResult();if(e.Kind=="chat.message")received.TrySetResult(e);},cancel.Token);
    await Task.WhenAll(ar.Task,br.Task).WaitAsync(cancel.Token);
    await alice.SendAsync("bob","C# ↔ FastAPI 🐈","dotnet_live",cancel.Token);
    Check((await received.Task.WaitAsync(cancel.Token)).Text=="C# ↔ FastAPI 🐈","C# real Relay delivery");
    Check((await ack.Task.WaitAsync(cancel.Token)).Status=="delivered","C# live ack");
    cancel.Cancel();try{await Task.WhenAll(at,bt);}catch(OperationCanceledException){}
}
checks += await ClassroomChecks.Run();
Console.WriteLine($"NekoChat core: {checks} behavior checks passed.");

sealed class FakeHandler:HttpMessageHandler {
    public string Endpoint="",Auth="",Body="";
    public HttpStatusCode Code=HttpStatusCode.OK;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation) {
        Endpoint=request.RequestUri!.AbsoluteUri;Auth=request.Headers.Authorization!.ToString();Body=await request.Content!.ReadAsStringAsync(cancellation);
        return new HttpResponseMessage(Code){Content=new StringContent(Code==HttpStatusCode.OK?"{\"text\":\"下課見\"}":"sensitive-server-response")};
    }
}
