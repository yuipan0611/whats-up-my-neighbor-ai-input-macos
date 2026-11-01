using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using NekoChat.Core;

namespace NekoChat.Windows;

internal sealed class ClassroomHost : IAsyncDisposable
{
    private readonly Process process;
    private int stopped;
    internal string User {get;}
    internal string Token {get;}
    internal LanInvitation Invitation {get;}
    internal Uri LocalEndpoint {get;}
    private ClassroomHost(Process process,string user,string token,LanInvitation invitation)
    {
        this.process=process;User=user;Token=token;Invitation=invitation;
        LocalEndpoint=RelayConnection.ValidateEndpoint($"ws://127.0.0.1:{invitation.Port}/nekochat/v1/ws",true);
    }
    internal static string[] LocalAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n=>n.OperationalStatus==OperationalStatus.Up && n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel))
        .OrderByDescending(n=>n.GetIPProperties().GatewayAddresses.Count>0)
        .SelectMany(n=>n.GetIPProperties().UnicastAddresses)
        .Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork)
        .Select(a=>a.Address.ToString()).Where(a=>LanInvitation.PrivateIPv4(a) && !a.StartsWith("127.",StringComparison.Ordinal))
        .Distinct(StringComparer.Ordinal).Take(7).ToArray();

    internal static async Task<ClassroomHost> StartAsync(string[] addresses,CancellationToken cancellation)
    {
        if(addresses.Length==0 || addresses.Any(a=>!LanInvitation.PrivateIPv4(a)))
            throw new InvalidDataException("找不到可用的教室網路。請先連上 Wi-Fi 或網路線，再建立房間。");
        var executable=Path.Combine(AppContext.BaseDirectory,"Relay","NekoChatRelay.exe");
        if(!File.Exists(executable))throw new InvalidDataException("缺少內建房間服務，請使用完整的一鍵安裝包重新安裝。");
        string hostUser=LanInvitation.NewUser(),guestUser=LanInvitation.NewUser();
        string hostToken=LanInvitation.NewToken(),guestToken=LanInvitation.NewToken(),room=Guid.NewGuid().ToString("N");
        var bootstrap=new {
            version=1,room_id=room,bind_hosts=addresses,
            policy=new {mode="lan",users=new Dictionary<string,object>{
                [hostUser]=new{token_sha256=LanInvitation.Digest(hostToken),friends=new[]{guestUser}},
                [guestUser]=new{token_sha256=LanInvitation.Digest(guestToken),friends=new[]{hostUser}}
            }}
        };
        var start=new ProcessStartInfo(executable) {
            WorkingDirectory=AppContext.BaseDirectory,UseShellExecute=false,CreateNoWindow=true,
            RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,
            StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8
        };
        var process=Process.Start(start)??throw new IOException("無法啟動內建房間服務。");
        try {
            // Consume diagnostics without exposing bootstrap/authentication data in UI or logs.
            _=DrainAsync(process.StandardError);
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(bootstrap));
            await process.StandardInput.FlushAsync(cancellation);
            var line=await process.StandardOutput.ReadLineAsync(cancellation).AsTask().WaitAsync(TimeSpan.FromSeconds(20),cancellation);
            if(line is null || line.Length>1024)throw new InvalidDataException("房間服務啟動失敗，請重新建立房間。");
            using var ready=JsonDocument.Parse(line);
            int port=ready.RootElement.GetProperty("port").GetInt32();
            if(ready.RootElement.GetProperty("version").GetInt32()!=1 || ready.RootElement.GetProperty("room_id").GetString()!=room)
                throw new InvalidDataException("房間服務回應不正確。");
            var invite=new LanInvitation(1,room,addresses,port,guestUser,hostUser,guestToken);invite.Validate();
            var result=new ClassroomHost(process,hostUser,hostToken,invite);
            using var http=new HttpClient(new HttpClientHandler{AllowAutoRedirect=false,UseProxy=false});
            var local=invite with{Hosts=["127.0.0.1"]};
            await local.FindEndpointAsync(http,cancellation);
            return result;
        }catch {
            StopProcess(process);throw;
        }
    }
    private static async Task DrainAsync(StreamReader reader)
    {
        try{while(await reader.ReadLineAsync().ConfigureAwait(false) is not null){ }}
        catch(Exception ex)when(ex is IOException or ObjectDisposedException){ }
    }
    private static void StopProcess(Process process)
    {
        try {
            if(!process.HasExited){process.StandardInput.Close();if(!process.WaitForExit(1500)){process.Kill(entireProcessTree:true);process.WaitForExit(3000);}}
        }catch(Exception ex)when(ex is InvalidOperationException or IOException or System.ComponentModel.Win32Exception){ }
        finally{process.Dispose();}
    }
    internal void Stop()
    {
        if(Interlocked.Exchange(ref stopped,1)==0)StopProcess(process);
    }
    public ValueTask DisposeAsync(){Stop();return ValueTask.CompletedTask;}
}
