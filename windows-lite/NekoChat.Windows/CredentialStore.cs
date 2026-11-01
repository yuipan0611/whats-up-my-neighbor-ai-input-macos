using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace NekoChat.Windows;

internal static class CredentialStore
{
    internal const string Classroom = "NekoChat.WindowsLite/Classroom";
    internal const string Groq = "NekoChat.WindowsLite/Groq";
    internal static string Relay(string endpoint, string user) => "NekoChat.WindowsLite/Relay/" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(endpoint + "\n" + user)));
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Write(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Read(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteNative(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr buffer);
    internal static void Save(string target, string secret)
    {
        var bytes = Encoding.Unicode.GetBytes(secret);
        if (bytes.Length is < 2 or > 2560) throw new ArgumentException("憑證長度不正確。");
        var pointer = Marshal.AllocCoTaskMem(bytes.Length);
        try {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
            var c = new Credential { Type=1, TargetName=target, Comment="NekoChat Windows Lite", CredentialBlobSize=(uint)bytes.Length,
                CredentialBlob=pointer, Persist=2, UserName=Environment.UserName, TargetAlias="" };
            if (!Write(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "無法儲存 Windows 認證。");
        } finally {
            for (int i=0; i<bytes.Length; i++) Marshal.WriteByte(pointer, i, 0);
            Marshal.FreeCoTaskMem(pointer); CryptographicOperations.ZeroMemory(bytes);
        }
    }
    internal static string? Load(string target)
    {
        if (!Read(target, 1, 0, out var pointer)) {
            if (Marshal.GetLastWin32Error()==1168) return null;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "無法讀取 Windows 認證。");
        }
        try {
            var c=Marshal.PtrToStructure<Credential>(pointer);
            return Marshal.PtrToStringUni(c.CredentialBlob, checked((int)c.CredentialBlobSize/2));
        } finally { CredFree(pointer); }
    }
    internal static void Delete(string target)
    {
        if (!DeleteNative(target, 1, 0) && Marshal.GetLastWin32Error()!=1168)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "無法移除 Windows 認證。");
    }
}
