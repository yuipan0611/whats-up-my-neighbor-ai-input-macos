using System.Net.Http;
using System.Security.Cryptography;
using System.Windows.Threading;
using NekoChat.Core;

namespace NekoChat.Windows;

public partial class App
{
    private Hotkeys? hotkeys;
    private AudioRecorder? recorder;
    private readonly HttpClient transcriptionHttp=new(new HttpClientHandler {AllowAutoRedirect=false}){Timeout=TimeSpan.FromSeconds(90)};
    private ITranscriptionProvider provider=null!;
    private CancellationTokenSource? voiceCancel;
    private FocusTarget? focusTarget;
    private bool recordingChat;
    private bool startingRecording;
    private bool transcribing;
    private bool canceling;
    private readonly DispatcherTimer recordingLimit=new(){Interval=TimeSpan.FromSeconds(60)};

    private void InitializeVoice()
    {
        provider=new GroqWhisperProvider(transcriptionHttp);
        hotkeys=new Hotkeys(pet);
        hotkeys.Toggle+=async()=>await ToggleVoiceAsync(false);
        hotkeys.Cancel+=async()=>await CancelVoiceAsync();
        pet.CancelRecording+=async()=>await CancelVoiceAsync();
        chat.VoiceRequested+=async()=>await ToggleVoiceAsync(true);
        chat.CancelRequested+=async()=>await CancelVoiceAsync();
        recordingLimit.Tick+=async(_,_)=>{recordingLimit.Stop();if(recorder is not null)await FinishVoiceAsync();};
        if(!hotkeys.Registered)chat.SetStatus("Ctrl + Alt + Space 已被其他程式占用；聊天語音仍可使用。請關閉衝突程式後重開 NekoChat。");
    }
    private async Task ToggleVoiceAsync(bool chatMode)
    {
        if(startingRecording || transcribing || canceling){chat.SetStatus("正在準備錄音或轉錄；Esc 可取消。");return;}
        if(recorder is not null) {
            if(recordingChat!=chatMode){chat.SetStatus("另一種錄音正在進行，請先完成或取消。");return;}
            await FinishVoiceAsync();return;
        }
        startingRecording=true;
        voiceCancel?.Dispose();voiceCancel=new();
        hotkeys?.EnableCancel(true);
        try {
            if(string.IsNullOrWhiteSpace(CredentialStore.Load(CredentialStore.Groq)))throw new ArgumentException("請先在連線與語音頁面儲存自己的 Groq API Key。");
            recordingChat=chatMode;
            focusTarget=chatMode?null:await NativeInput.CaptureAsync();
            voiceCancel.Token.ThrowIfCancellationRequested();
            recorder=new AudioRecorder();recorder.Start();recordingLimit.Start();
            chat.VoiceButton.Content=chatMode?"■ 停止並轉成草稿":"🎙 語音草稿";
            pet.Notify(chatMode?"聊天錄音中…按語音按鈕停止，Esc 取消。":"語音輸入錄音中…Ctrl + Alt + Space 停止，Esc 取消。",persistent:true);
            chat.SetStatus("錄音中，最長 60 秒。音訊將送至 Groq 轉錄。");
        }catch(Exception ex){recorder?.Dispose();recorder=null;hotkeys?.EnableCancel(false);pet.Notify(SafeError(ex));chat.SetStatus(SafeError(ex));}
        finally{startingRecording=false;}
    }
    private async Task FinishVoiceAsync()
    {
        var current=recorder;if(current is null || transcribing)return;
        recorder=null;recordingLimit.Stop();transcribing=true;
        var cancellation=voiceCancel!.Token;
        byte[]? wav=null;
        try {
            pet.Notify("正在轉成文字…Esc 可取消。",persistent:true);chat.VoiceButton.Content="轉錄中…";
            wav=await current.StopAsync();
            cancellation.ThrowIfCancellationRequested();
            var key=CredentialStore.Load(CredentialStore.Groq)??throw new ArgumentException("請重新儲存自己的 Groq API Key。");
            var text=await provider.TranscribeAsync(wav,key,cancellation);
            cancellation.ThrowIfCancellationRequested();
            chat.Transcript.Text=text;
            if(recordingChat) {
                // A local user recording creates a draft. It never sends automatically.
                chat.Draft.AppendText((chat.Draft.Text.Length==0?"":Environment.NewLine)+text);
                chat.SetStatus("語音已加入聊天草稿；確認好友與內容後再按傳送。");pet.Notify("語音草稿已就緒，確認後再傳送。");
            }else {
                var status=await NativeInput.InsertAsync(text,focusTarget,cancellation);
                chat.SetStatus(status);pet.Notify(status);
            }
        }catch(Exception ex){chat.SetStatus(SafeError(ex));pet.Notify(SafeError(ex));}
        finally {
            if(wav is not null)CryptographicOperations.ZeroMemory(wav);
            current.Dispose();focusTarget=null;transcribing=false;hotkeys?.EnableCancel(false);chat.VoiceButton.Content="🎙 語音草稿";
        }
    }
    private async Task CancelVoiceAsync()
    {
        if(canceling)return;canceling=true;
        try {
        voiceCancel?.Cancel();recordingLimit.Stop();
        var current=recorder;recorder=null;
        if(current is not null) {
            try{var bytes=await current.StopAsync();CryptographicOperations.ZeroMemory(bytes);}catch(Exception){ }
            finally{current.Dispose();}
        }
        hotkeys?.EnableCancel(false);focusTarget=null;chat.VoiceButton.Content="🎙 語音草稿";
        chat.SetStatus("已取消錄音／轉錄。");pet.Notify("已取消。");
        }finally{canceling=false;}
    }
    private void DisposeVoice()
    {
        voiceCancel?.Cancel();recordingLimit.Stop();hotkeys?.Dispose();recorder?.Dispose();transcriptionHttp.Dispose();
    }
}
