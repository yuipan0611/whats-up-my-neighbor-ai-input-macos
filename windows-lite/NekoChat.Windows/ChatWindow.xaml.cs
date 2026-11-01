using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace NekoChat.Windows;

public partial class ChatWindow : Window
{
    private Settings settings;
    private bool loaded;
    internal event Action? SendRequested;
    internal event Action? VoiceRequested;
    internal event Action? CancelRequested;
    internal event Action<Settings,string>? ConnectRequested;
    internal event Action? DisconnectRequested;
    internal event Action? CreateRoomRequested;
    internal event Action<string>? JoinRoomRequested;
    internal event Action? LeaveRoomRequested;
    internal ChatWindow(Settings initial)
    {
        settings=initial;InitializeComponent();Mode.SelectedIndex=initial.Lan?0:1;
        Endpoint.Text=initial.Endpoint;UserId.Text=initial.User;loaded=true;
        Closing+=OnClosing;
        try{GroqState.Text=string.IsNullOrWhiteSpace(CredentialStore.Load(CredentialStore.Groq))?"尚未設定語音金鑰。文字聊天可以直接使用。":"語音金鑰已設定，可以在記事本按 Ctrl + Alt + Space 測試。";}
        catch(Exception){GroqState.Text="目前無法讀取語音金鑰，請重新儲存。";}
    }
    private void OnClosing(object? sender,CancelEventArgs e){e.Cancel=true;Hide();}
    internal void ShowChat(string? sender=null)
    {
        if(sender is not null){Recipient.Text=sender;Tabs.SelectedIndex=1;}
        Show();if(WindowState==WindowState.Minimized)WindowState=WindowState.Normal;Activate();
    }
    internal void SetStatus(string status)=>Status.Text=status;
    internal void AddHistory(string text)
    {
        History.AppendText(text+Environment.NewLine);
        if(History.Text.Length>24000)History.Text=History.Text[^20000..];
        History.ScrollToEnd();
    }
    private void SendClick(object sender,RoutedEventArgs e)=>SendRequested?.Invoke();
    private void VoiceClick(object sender,RoutedEventArgs e)=>VoiceRequested?.Invoke();
    private void CancelClick(object sender,RoutedEventArgs e)=>CancelRequested?.Invoke();
    private void DisconnectClick(object sender,RoutedEventArgs e)=>DisconnectRequested?.Invoke();
    private void ModeChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!loaded)return;
        // Keep independent LAN/VPS endpoints while switching the selector.
        settings=settings.Lan?settings with{LanEndpoint=Endpoint.Text}:settings with{VpsEndpoint=Endpoint.Text};
        settings=settings with{Lan=Mode.SelectedIndex==0};Endpoint.Text=settings.Endpoint;
    }
    private void ConnectClick(object sender,RoutedEventArgs e)
    {
        settings=settings with{Lan=Mode.SelectedIndex==0,User=UserId.Text.Trim()};
        settings=settings.Lan?settings with{LanEndpoint=Endpoint.Text.Trim()}:settings with{VpsEndpoint=Endpoint.Text.Trim()};
        var token=RelayToken.Password;RelayToken.Clear();ConnectRequested?.Invoke(settings,token);
    }
    private void SaveGroqClick(object sender,RoutedEventArgs e)
    {
        try {
            if(string.IsNullOrWhiteSpace(GroqKey.Password))throw new ArgumentException("請先輸入自己的 Groq Key。");
            CredentialStore.Save(CredentialStore.Groq,GroqKey.Password.Trim());SetStatus("Groq Key 已存入 Windows 認證管理員。");GroqState.Text="語音金鑰已設定，可以在記事本按 Ctrl + Alt + Space 測試。";
        }catch(Exception ex){SetStatus(App.SafeError(ex));}finally{GroqKey.Clear();}
    }
    private void DeleteGroqClick(object sender,RoutedEventArgs e)
    {
        try{CredentialStore.Delete(CredentialStore.Groq);GroqKey.Clear();SetStatus("Groq Key 已刪除。");GroqState.Text="尚未設定語音金鑰。文字聊天仍可使用。";}catch(Exception ex){SetStatus(App.SafeError(ex));}
    }
    private void DeleteRelayClick(object sender,RoutedEventArgs e)
    {
        try{CredentialStore.Delete(CredentialStore.Relay(NekoChat.Core.RelayConnection.ValidateEndpoint(Endpoint.Text.Trim(),Mode.SelectedIndex==0).AbsoluteUri,UserId.Text.Trim()));RelayToken.Clear();SetStatus("已刪除此連線的憑證；現有連線請另按中斷。");}catch(Exception ex){SetStatus(App.SafeError(ex));}
    }
    private void CopyClick(object sender,RoutedEventArgs e)
    {
        if(Transcript.Text.Length>0)SetStatus(NativeInput.Copy(Transcript.Text));
    }
    internal void SetClassroomState(bool active,bool busy,string text,bool hosting=false)
    {
        CreateRoomButton.IsEnabled=!active&&!busy;JoinRoomButton.IsEnabled=!active&&!busy;
        JoinRoomCode.IsEnabled=!active&&!busy;LeaveRoomButton.IsEnabled=active||busy;
        ShareRoomPanel.Visibility=hosting?Visibility.Visible:Visibility.Collapsed;
        ConnectButton.IsEnabled=!active&&!busy;RoomStatus.Text=text;
        Recipient.IsReadOnly=active;Recipient.Visibility=active?Visibility.Collapsed:Visibility.Visible;
        RecipientLabel.Text=active?"傳送給：已配對的同學":"好友 ID";
        if(!active&&!busy){RoomCode.Clear();JoinRoomCode.Clear();}
    }
    private void CreateRoomClick(object sender,RoutedEventArgs e)=>CreateRoomRequested?.Invoke();
    private void JoinRoomClick(object sender,RoutedEventArgs e)=>JoinRoomRequested?.Invoke(JoinRoomCode.Text);
    private void LeaveRoomClick(object sender,RoutedEventArgs e)=>LeaveRoomRequested?.Invoke();
    private void CopyRoomCodeClick(object sender,RoutedEventArgs e)
    {
        if(RoomCode.Text.Length>0)SetStatus(NativeInput.Copy(RoomCode.Text,"已複製房間邀請碼，請私下交給同學"));
    }

}
