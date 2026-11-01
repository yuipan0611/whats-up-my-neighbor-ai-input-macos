using System.IO;
using System.Net.Http;
using System.Net;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NekoChat.Core;

namespace NekoChat.Windows;

internal static class ClassroomSmokeTest
{
    internal static int Run(string directory)
    {
        Directory.CreateDirectory(directory);
        try {
            Task.Run(RoundtripAsync).GetAwaiter().GetResult();
            var chat=new ChatWindow(new Settings());
            int creates=0;string? joined=null;int leaves=0;
            chat.CreateRoomRequested+=()=>creates++;
            chat.JoinRoomRequested+=code=>joined=code;
            chat.LeaveRoomRequested+=()=>leaves++;
            chat.CreateRoomButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            chat.JoinRoomCode.Text="CI-only-invitation";chat.JoinRoomButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if(creates!=1 || joined!="CI-only-invitation")throw new InvalidDataException("Room UI actions were not connected");
            Capture(chat,Path.Combine(directory,"classroom-start.png"));
            chat.RoomCode.Text="CI 流程展示（非有效邀請碼）";
            chat.SetClassroomState(true,false,"房間已建立，請私下分享邀請碼給同學。",true);
            if(chat.CreateRoomButton.IsEnabled || chat.JoinRoomButton.IsEnabled || !chat.LeaveRoomButton.IsEnabled || chat.Recipient.Visibility!=Visibility.Collapsed)
                throw new InvalidDataException("Room UI did not protect active pairing");
            Capture(chat,Path.Combine(directory,"classroom-host.png"));
            chat.LeaveRoomButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            chat.SetClassroomState(false,false,"已離開房間。");
            if(leaves!=1 || chat.RoomCode.Text.Length!=0 || !chat.CreateRoomButton.IsEnabled)throw new InvalidDataException("Room UI cleanup failed");
            File.WriteAllText(Path.Combine(directory,"classroom-result.txt"),"PASS: bundled Relay startup without Python, generated host/guest identities, invitation import, room discovery, bidirectional C# WebSocket messages/acks, parent shutdown revokes room, WPF create/join/leave actions and automatic recipient controls.");
            return 0;
        }catch(Exception ex){File.WriteAllText(Path.Combine(directory,"classroom-result.txt"),"FAIL: "+ex.GetType().Name+" "+ex.Message);return 1;}
    }
    private static async Task RoundtripAsync()
    {
        using var lifetime=new CancellationTokenSource(TimeSpan.FromSeconds(35));
        var host=await ClassroomHost.StartAsync(["127.0.0.1"],lifetime.Token);
        var invite=LanInvitation.Parse(host.Invitation.Encode());
        try {
            using var http=new HttpClient(new HttpClientHandler{AllowAutoRedirect=false,UseProxy=false});
            var endpoint=await invite.FindEndpointAsync(http,lifetime.Token);
            await using var a=new RelayConnection();await using var b=new RelayConnection();
            await a.ConnectAsync(host.LocalEndpoint,host.User,host.Token,lifetime.Token);
            await b.ConnectAsync(endpoint,invite.User,invite.Token,lifetime.Token);
            var aReady=new TaskCompletionSource();var bReady=new TaskCompletionSource();
            var toGuest=new TaskCompletionSource<ChatEvent>();var toHost=new TaskCompletionSource<ChatEvent>();
            var aAck=new TaskCompletionSource();var bAck=new TaskCompletionSource();
            var receivingA=a.ReceiveAsync(e=>{if(e.Kind=="ready")aReady.TrySetResult();if(e.Kind=="chat.message")toHost.TrySetResult(e);if(e.Kind=="chat.ack")aAck.TrySetResult();},lifetime.Token);
            var receivingB=b.ReceiveAsync(e=>{if(e.Kind=="ready")bReady.TrySetResult();if(e.Kind=="chat.message")toGuest.TrySetResult(e);if(e.Kind=="chat.ack")bAck.TrySetResult();},lifetime.Token);
            await Task.WhenAll(aReady.Task,bReady.Task).WaitAsync(lifetime.Token);
            await a.SendAsync(invite.User,"一鍵建房 🐈","host_to_guest",lifetime.Token);
            var incoming=await toGuest.Task.WaitAsync(lifetime.Token);
            if(incoming.Text!="一鍵建房 🐈" || incoming.Sender!=host.User)throw new InvalidDataException("Guest delivery failed");
            await b.SendAsync(host.User,"邀請碼加入成功","guest_to_host",lifetime.Token);
            var reply=await toHost.Task.WaitAsync(lifetime.Token);
            if(reply.Text!="邀請碼加入成功" || reply.Sender!=invite.User)throw new InvalidDataException("Host delivery failed");
            await Task.WhenAll(aAck.Task,bAck.Task).WaitAsync(lifetime.Token);
            lifetime.Cancel();
            try{await Task.WhenAll(receivingA,receivingB);}catch(OperationCanceledException){ }
        }finally{await host.DisposeAsync();}
        using var probe=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(3));
        bool gone=false;
        try{await probe.ConnectAsync(IPAddress.Loopback,invite.Port,deadline.Token);}
        catch(SocketException error)when(error.SocketErrorCode==SocketError.ConnectionRefused){gone=true;}
        if(!gone)throw new InvalidDataException("Room port remained open after owner exit");
    }
    private static void Capture(ChatWindow chat,string path)
    {
        var visual=(FrameworkElement)chat.Content;visual.Measure(new Size(430,650));visual.Arrange(new Rect(0,0,430,650));visual.UpdateLayout();
        var bitmap=new RenderTargetBitmap(430,650,96,96,PixelFormats.Pbgra32);bitmap.Render(visual);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var file=File.Create(path);encoder.Save(file);
    }
}
