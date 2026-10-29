using System.IO;
using System.Net.Http;
using System.Windows;
using NekoChat.Core;

namespace NekoChat.Windows;

public partial class App
{
    private ClassroomHost? classroomHost;
    private string? classroomPeer;
    private CancellationTokenSource? classroomCancel;
    private bool classroomBusy;
    private readonly HttpClient roomHttp=new(new HttpClientHandler{AllowAutoRedirect=false,UseProxy=false}){Timeout=TimeSpan.FromSeconds(20)};
    private void InitializeClassroom()
    {
        // Credentials from a crashed old room are useless after its owning Relay exits.
        try{CredentialStore.Delete(CredentialStore.Classroom);}catch(Exception){ }
        chat.CreateRoomRequested+=async()=>await CreateClassroomAsync();
        chat.JoinRoomRequested+=async code=>await JoinClassroomAsync(code);
        chat.LeaveRoomRequested+=async()=> {
            if(classroomBusy){classroomCancel?.Cancel();chat.RoomStatus.Text="正在取消房間連線…";}
            else await LeaveClassroomAsync();
        };
    }
    private async Task CreateClassroomAsync()
    {
        if(classroomBusy)return;
        classroomBusy=true;
        try {
            await LeaveClassroomAsync();
            classroomCancel=new CancellationTokenSource(TimeSpan.FromSeconds(30));
            chat.SetClassroomState(false,true,"正在建立房間…");
            classroomHost=await ClassroomHost.StartAsync(ClassroomHost.LocalAddresses(),classroomCancel.Token);
            classroomPeer=classroomHost.Invitation.User;
            chat.RoomCode.Text=classroomHost.Invitation.Encode();
            chat.Recipient.Text=classroomPeer;
            chat.SetClassroomState(true,false,"房間服務已啟動，正在連線…",hosting:true);
            if(!await ConnectAsync(settings with{Lan=true,LanEndpoint=classroomHost.LocalEndpoint.AbsoluteUri,User=classroomHost.User},classroomHost.Token,true))
                await LeaveClassroomAsync("建立連線失敗，請確認 Windows 網路權限後重試。");
        }catch(Exception ex){await LeaveClassroomAsync(RoomError(ex));}
        finally{classroomBusy=false;}
    }
    private async Task JoinClassroomAsync(string code)
    {
        if(classroomBusy)return;
        classroomBusy=true;
        try {
            var invite=LanInvitation.Parse(code);
            await LeaveClassroomAsync();
            classroomCancel=new CancellationTokenSource(TimeSpan.FromSeconds(25));
            chat.SetClassroomState(false,true,"正在尋找同學的房間…");
            var endpoint=await invite.FindEndpointAsync(roomHttp,classroomCancel.Token);
            classroomPeer=invite.Peer;chat.Recipient.Text=invite.Peer;chat.JoinRoomCode.Clear();
            chat.SetClassroomState(true,false,"已找到房間，正在驗證連線…");
            if(await ConnectAsync(settings with{Lan=true,LanEndpoint=endpoint.AbsoluteUri,User=invite.User},invite.Token,true))chat.ShowChat(invite.Peer);
            else await LeaveClassroomAsync("加入失敗，請向房主取得新的邀請碼後重試。");
        }catch(Exception ex){await LeaveClassroomAsync(RoomError(ex));}
        finally{classroomBusy=false;}
    }
    private void ClassroomReady()
    {
        chat.SetClassroomState(true,false,classroomHost is null?"已加入房間，收件人已設定為同學，可以互傳訊息。":"房間已建立，請把邀請碼私下交給一位同學，等待對方加入。",classroomHost is not null);
    }
    private async Task LeaveClassroomAsync(string message="已離開房間；語音輸入仍可使用。")
    {
        classroomCancel?.Cancel();classroomCancel?.Dispose();classroomCancel=null;
        await DisconnectAsync();
        var host=classroomHost;classroomHost=null;classroomPeer=null;
        if(host is not null)await host.DisposeAsync();
        try{CredentialStore.Delete(CredentialStore.Classroom);}catch(Exception){ }
        chat.SetClassroomState(false,false,message);
    }
    private static string RoomError(Exception ex)=>ex switch {
        OperationCanceledException=>"已取消或連線逾時，請確認同學仍開著房間後再試一次。",
        InvalidDataException=>ex.Message,
        _=>"房間無法啟動或連線。請確認使用完整安裝包、教室網路可互連，並依學校規範允許 Windows 網路存取。"
    };
    private void DisposeClassroom()
    {
        classroomCancel?.Cancel();classroomHost?.Stop();
        try{CredentialStore.Delete(CredentialStore.Classroom);}catch(Exception){ }
        roomHttp.Dispose();
    }
}
