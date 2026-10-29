using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NekoChat.Core;

namespace NekoChat.Installer;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if(args.Length==2 && args[0]=="--smoke-install")return Smoke(args[1]);
        using var gate=new Mutex(true,"Local\\NekoChat.WindowsLite.Installer",out bool acquired);
        if(!acquired){MessageBox.Show("另一個 NekoChat 安裝程式正在執行。","NekoChat");return 1;}
        var app=new Application();
        var window=new Window{Title="安裝 NekoChat Windows Lite",Width=460,Height=350,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterScreen,
            Background=new SolidColorBrush(Color.FromRgb(250,249,247))};
        var panel=new StackPanel{Margin=new Thickness(28)};
        panel.Children.Add(new TextBlock{Text="讓小黑貓陪你聊天、語音輸入",FontSize=22,FontWeight=FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap});
        panel.Children.Add(new TextBlock{Text="安裝至目前 Windows 使用者，建立開始功能表捷徑。執行所需元件已包含，不需要另外安裝 Python 或 .NET。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,16,0,16)});
        var button=new Button{Content="安裝並啟動",Padding=new Thickness(16,10,16,10),HorizontalAlignment=HorizontalAlignment.Left};panel.Children.Add(button);
        var status=new TextBlock{Text="個人金鑰與設定會保留。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,16,0,0)};panel.Children.Add(status);
        bool installing=false;
        window.Closing+=(_,e)=>{if(installing)e.Cancel=true;};
        button.Click+=async(_,_)=> {
            installing=true;button.IsEnabled=false;status.Text="正在安裝…";
            try {
                var installed=await Task.Run(Install);
                CreateShortcut(installed);
                Process.Start(new ProcessStartInfo(Path.Combine(installed,"NekoChat.Windows.exe")){WorkingDirectory=installed,UseShellExecute=true});
                installing=false;window.Close();
            }catch(Exception ex){status.Text=ex is InvalidDataException or IOException?ex.Message:"安裝失敗。請確認檔案完整、已離開舊版程式，且學校允許安裝。";button.IsEnabled=true;}
            finally{installing=false;}
        };
        window.Content=panel;app.Run(window);return 0;
    }
    private static Stream VerifiedPayload()
    {
        var assembly=typeof(Program).Assembly;
        var payload=assembly.GetManifestResourceStream("payload.zip")??throw new InvalidDataException("此安裝檔缺少程式內容，請重新下載完整安裝檔。");
        try {
            using var digestStream=assembly.GetManifestResourceStream("payload.sha256")??throw new InvalidDataException("安裝檔缺少完整性檢查資料。");
            using var reader=new StreamReader(digestStream);
            var expected=reader.ReadToEnd().Trim();var actual=Convert.ToHexString(SHA256.HashData(payload));
            if(expected.Length!=64 || !actual.Equals(expected,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("安裝檔不完整，請重新下載。");
            payload.Position=0;return payload;
        }catch{payload.Dispose();throw;}
    }
    private static string Install()
    {
        if(Process.GetProcessesByName("NekoChat.Windows").Any(p=>{using(p)return p.SessionId==Process.GetCurrentProcess().SessionId;}))
            throw new IOException("請先從貓咪右鍵選單離開舊版 NekoChat，再按安裝。");
        var parent=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs");
        return InstallAt(parent);
    }
    private static string InstallAt(string parent)
    {
        Directory.CreateDirectory(parent);
        var destination=Path.Combine(parent,"NekoChat.WindowsLite");
        if(Directory.Exists(destination) && !File.Exists(Path.Combine(destination,"NekoChat.Windows.exe")))
            throw new IOException("安裝資料夾已有其他內容，請先由管理者確認；本次未覆寫任何檔案。");
        var staging=Path.Combine(parent,".nekochat-install-"+Guid.NewGuid().ToString("N"));
        var backup=Path.Combine(parent,".nekochat-previous-"+DateTime.UtcNow.ToString("yyyyMMddHHmmss")+"-"+Guid.NewGuid().ToString("N"));
        bool moved=false;
        try {
            using(var payload=VerifiedPayload())PayloadArchive.Extract(payload,staging);
            if(Directory.Exists(destination)){Directory.Move(destination,backup);moved=true;}
            try{Directory.Move(staging,destination);}
            catch{if(moved && !Directory.Exists(destination))Directory.Move(backup,destination);throw;}
            // Keep the previous app folder recoverable; it may contain user-provided artwork.
            return destination;
        }finally{if(Directory.Exists(staging))Directory.Delete(staging,true);}
    }
    private static void CreateShortcut(string installed,string? shortcutPath=null)
    {
        var shellType=Type.GetTypeFromProgID("WScript.Shell")??throw new IOException("無法建立開始功能表捷徑。程式已安裝，可從安裝資料夾開啟。");
        dynamic shell=Activator.CreateInstance(shellType)!;
        dynamic link=shell.CreateShortcut(shortcutPath??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"NekoChat Windows Lite.lnk"));
        link.TargetPath=Path.Combine(installed,"NekoChat.Windows.exe");link.WorkingDirectory=installed;link.Save();
    }
    private static int Smoke(string directory)
    {
        var root=Path.GetFullPath(directory);
        var temporary=Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
        if(!root.StartsWith(temporary,StringComparison.OrdinalIgnoreCase))return 2;
        Directory.CreateDirectory(root);
        try {
            var parent=Path.Combine(root,"Programs");
            var installed=InstallAt(parent);
            File.WriteAllText(Path.Combine(installed,"user-artwork-sentinel.txt"),"preserve-test-only-artwork");
            var settings=Path.Combine(root,"settings-sentinel.txt");File.WriteAllText(settings,"preserve-test-only-settings");
            installed=InstallAt(parent);
            var previous=Directory.GetDirectories(parent,".nekochat-previous-*").Single();
            if(File.ReadAllText(Path.Combine(previous,"user-artwork-sentinel.txt"))!="preserve-test-only-artwork" ||
                File.ReadAllText(settings)!="preserve-test-only-settings")throw new IOException("Upgrade did not preserve previous data");
            var shortcut=Path.Combine(root,"NekoChat Test.lnk");CreateShortcut(installed,shortcut);
            if(!File.Exists(shortcut))throw new IOException("Shortcut creation failed");
            var start=new ProcessStartInfo(Path.Combine(installed,"NekoChat.Windows.exe")){WorkingDirectory=installed,UseShellExecute=false};
            start.ArgumentList.Add("--startup-smoke-test");start.ArgumentList.Add(Path.Combine(root,"startup"));
            using var child=Process.Start(start)??throw new IOException("Installed App could not launch");
            if(!child.WaitForExit(45000)){child.Kill(entireProcessTree:true);throw new IOException("Installed App startup timed out");}
            if(child.ExitCode!=0 || !File.Exists(Path.Combine(root,"startup","startup-result.txt")))throw new IOException("Installed App startup failed");
            File.WriteAllText(Path.Combine(root,"result.txt"),"PASS: single-file setup checksum, fresh install, transactional upgrade, preserved previous artwork/settings, Start menu shortcut mechanism and actual installed App startup; no external Python/.NET installation or config edits.");return 0;
        }catch(Exception ex){File.WriteAllText(Path.Combine(root,"result.txt"),"FAIL: "+ex.GetType().Name+" "+ex.Message);return 1;}
    }
}
