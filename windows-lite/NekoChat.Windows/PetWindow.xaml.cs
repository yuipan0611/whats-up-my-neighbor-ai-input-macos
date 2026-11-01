using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using NekoChat.Core;

namespace NekoChat.Windows;

public partial class PetWindow : Window
{
    internal event Action<string?>? OpenChat;
    internal event Action<string>? SelectCoat;
    internal event Action? ImportCoat;
    internal event Action? CancelRecording;
    private string? sender;
    private Point down;
    private bool dragging;
    private readonly DispatcherTimer bubbleTimer=new(){Interval=TimeSpan.FromSeconds(12)};
    public PetWindow()
    {
        InitializeComponent();Cat.Source=CatArtwork.Preset("original");
        Left=SystemParameters.WorkArea.Right-310;Top=SystemParameters.WorkArea.Bottom-330;
        SourceInitialized+=(_,_)=> {
            var handle=new WindowInteropHelper(this).Handle;
            SetWindowLongPtr(handle,-20,GetWindowLongPtr(handle,-20)|0x08000000|0x00000080);
        };
        bubbleTimer.Tick+=(_,_)=>{Bubble.Visibility=Visibility.Collapsed;bubbleTimer.Stop();};
        var menu=new ContextMenu();
        var open=new MenuItem{Header="聊天與連線設定…"};open.Click+=(_,_)=>OpenChat?.Invoke(null);menu.Items.Add(open);
        var coats=new MenuItem{Header="選擇花色"};
        string[] names=["原版黑貓","黑貓","白貓","灰貓","橘虎斑","賓士貓","三花貓","玳瑁貓","重點色貓"];
        for(int i=0;i<names.Length;i++) {
            var id=Appearance.Presets[i];var item=new MenuItem{Header=names[i]};item.Click+=(_,_)=>SelectCoat?.Invoke(id);coats.Items.Add(item);
        }
        menu.Items.Add(coats);
        var import=new MenuItem{Header="匯入 cat.config.json…"};import.Click+=(_,_)=>ImportCoat?.Invoke();menu.Items.Add(import);
        var cancel=new MenuItem{Header="取消錄音／轉錄（Esc）"};cancel.Click+=(_,_)=>CancelRecording?.Invoke();menu.Items.Add(cancel);
        var exit=new MenuItem{Header="離開 NekoChat"};exit.Click+=(_,_)=>Application.Current.Shutdown();menu.Items.Add(exit);
        Cat.ContextMenu=menu;
    }
    internal void SetArt(ImageSource image)=>Cat.Source=image;
    internal void Notify(string text,string? from=null,bool persistent=false,string? displayName=null)
    {
        sender=from;BubbleText.Text=from is null?text:$"{displayName??from}：{text}\n點擊回覆";
        Bubble.Visibility=Visibility.Visible;bubbleTimer.Stop();if(!persistent)bubbleTimer.Start();
    }
    private void BubbleClick(object sender,RoutedEventArgs e)=>OpenChat?.Invoke(this.sender);
    private void CatDown(object sender,MouseButtonEventArgs e){down=e.GetPosition(this);dragging=false;Cat.CaptureMouse();}
    private void CatMove(object sender,MouseEventArgs e)
    {
        if(e.LeftButton!=MouseButtonState.Pressed || !Cat.IsMouseCaptured)return;
        var point=e.GetPosition(this);var delta=point-down;
        if(dragging || Math.Abs(delta.X)>SystemParameters.MinimumHorizontalDragDistance || Math.Abs(delta.Y)>SystemParameters.MinimumVerticalDragDistance) {
            dragging=true;Left+=delta.X;Top+=delta.Y;
        }
    }
    private void CatUp(object sender,MouseButtonEventArgs e)
    {
        if(!Cat.IsMouseCaptured)return;Cat.ReleaseMouseCapture();
        Left=Math.Clamp(Left,SystemParameters.VirtualScreenLeft,SystemParameters.VirtualScreenLeft+Math.Max(0,SystemParameters.VirtualScreenWidth-Width));
        Top=Math.Clamp(Top,SystemParameters.VirtualScreenTop,SystemParameters.VirtualScreenTop+Math.Max(0,SystemParameters.VirtualScreenHeight-Height));
        if(!dragging)OpenChat?.Invoke(null);
    }
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd,int index);
    [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd,int index,IntPtr value);
}
