using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;

namespace NekoChat.Windows;

internal sealed class Hotkeys : IDisposable
{
    private readonly IntPtr window;
    private readonly HwndSource source;
    internal event Action? Toggle;
    internal event Action? Cancel;
    internal bool Registered { get; }
    internal Hotkeys(Window owner)
    {
        window=new WindowInteropHelper(owner).Handle;
        source=HwndSource.FromHwnd(window)!;
        source.AddHook(Hook);
        Registered=RegisterHotKey(window, 1, 0x4000 | 0x0001 | 0x0002, 0x20);
    }
    internal void EnableCancel(bool enabled) {
        if (enabled) RegisterHotKey(window, 2, 0x4000, 0x1B);
        else UnregisterHotKey(window, 2);
    }
    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (msg==0x0312) { handled=true; if(wparam.ToInt32()==1) Toggle?.Invoke(); else if(wparam.ToInt32()==2) Cancel?.Invoke(); }
        return IntPtr.Zero;
    }
    public void Dispose() { UnregisterHotKey(window,1); UnregisterHotKey(window,2); source.RemoveHook(Hook); }
    [DllImport("user32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr hwnd,int id,uint modifiers,uint key);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(IntPtr hwnd,int id);
}

internal sealed record FocusTarget(IntPtr Window, int ProcessId, int[] RuntimeId);

internal static class NativeInput
{
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, Input[] inputs,int size);
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Data; }
    // Include MOUSEINPUT to preserve INPUT union size on x64 and x86.
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Key,Scan; public uint Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X,Y; public uint MouseData,Flags,Time; public UIntPtr Extra; }
    internal static async Task<FocusTarget?> CaptureAsync()
    {
        try { return await Task.Run(Capture).WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (Exception ex) when (ex is TimeoutException or ElementNotAvailableException or InvalidOperationException or COMException or UnauthorizedAccessException) { return null; }
    }
    private static FocusTarget? Capture()
    {
        var window=GetForegroundWindow();
        GetWindowThreadProcessId(window,out var process);
        if (window==IntPtr.Zero || process==Environment.ProcessId) return null;
        var element=AutomationElement.FocusedElement;
        if (element is null || element.Current.ProcessId != process || element.Current.IsPassword ||
            !element.Current.IsEnabled || !element.Current.HasKeyboardFocus) return null;
        bool editable=element.TryGetCurrentPattern(ValuePattern.Pattern,out var pattern) && !((ValuePattern)pattern).Current.IsReadOnly;
        if (!editable) return null; // Unknown/contenteditable controls safely fall back to clipboard.
        var runtime=element.GetRuntimeId();
        return GetForegroundWindow()==window?new(window,(int)process,runtime):null;
    }
    private static bool Same(FocusTarget target)
    {
        var current=Capture();
        return current is not null && current.Window==target.Window && current.ProcessId==target.ProcessId && current.RuntimeId.SequenceEqual(target.RuntimeId);
    }
    internal static async Task<string> InsertAsync(string text, FocusTarget? target, CancellationToken cancellation)
    {
        // Never activate/restore another app or press Enter. Changed focus means copy only.
        bool valid=false;
        if (target is not null) {
            try { valid=await Task.Run(()=>Same(target)).WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (Exception ex) when (ex is TimeoutException or ElementNotAvailableException or InvalidOperationException or COMException or UnauthorizedAccessException) { }
        }
        cancellation.ThrowIfCancellationRequested();
        bool modifiersDown=new[]{0x10,0x11,0x12,0x5B,0x5C}.Any(k=>(GetAsyncKeyState(k)&0x8000)!=0);
        if (!valid || modifiersDown || text.Any(char.IsControl)) return Copy(text,"焦點改變或欄位不支援");
        // Recheck top-level foreground immediately before posting events.
        cancellation.ThrowIfCancellationRequested();
        if (GetForegroundWindow()!=target!.Window) return Copy(text,"焦點已改變");
        var inputs=text.SelectMany(c=>new[]{
            new Input {Type=1,Data=new InputUnion{Keyboard=new KeyboardInput{Scan=c,Flags=0x0004}}},
            new Input {Type=1,Data=new InputUnion{Keyboard=new KeyboardInput{Scan=c,Flags=0x0004|0x0002}}}
        }).ToArray();
        if (SendInput((uint)inputs.Length,inputs,Marshal.SizeOf<Input>())!=(uint)inputs.Length)
            return Copy(text,"系統無法完整輸入，請檢查是否已有部分文字");
        return "已送出文字輸入事件，請確認原本的文字欄位。";
    }
    internal static string Copy(string text,string reason="手動複製")
    {
        try { Clipboard.SetText(text); return reason+"；文字已複製，可自行貼上。"; }
        catch (COMException) { return "剪貼簿忙碌；文字保留於聊天視窗的『最近轉錄』，請稍後再複製。"; }
    }
}
