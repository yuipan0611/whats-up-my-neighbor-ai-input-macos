using NAudio.Wave;
using System.IO;

namespace NekoChat.Windows;

internal sealed class AudioRecorder : IDisposable
{
    private readonly MemoryStream stream=new();
    private readonly IWaveIn input;
    private readonly WaveFileWriter writer;
    private readonly TaskCompletionSource<byte[]> stopped=new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object gate=new();
    private int stopping;
    private int disposed;
    internal AudioRecorder(IWaveIn? source=null)
    {
        input=source ?? new WaveInEvent { WaveFormat=new WaveFormat(16000,16,1), BufferMilliseconds=100 };
        writer=new WaveFileWriter(stream,input.WaveFormat);
        input.DataAvailable+=(_,e)=> {
            lock(gate) { if (Volatile.Read(ref disposed)==0 && stream.Length < 2_100_000) writer.Write(e.Buffer,0,e.BytesRecorded); }
        };
        input.RecordingStopped+=(_,e)=> {
            lock(gate) {
            if(Volatile.Read(ref disposed)!=0)return;
            writer.Flush();
            if(e.Exception is not null) stopped.TrySetException(new IOException("無法錄音，請檢查麥克風權限與裝置。"));
            else { writer.Dispose(); stopped.TrySetResult(stream.ToArray()); }
            }
        };
    }
    internal void Start()=>input.StartRecording();
    internal async Task<byte[]> StopAsync()
    {
        if (Interlocked.Exchange(ref stopping,1)==0) input.StopRecording();
        return await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed,1)!=0) return;
        Interlocked.Exchange(ref stopping,1);
        input.Dispose();
        lock(gate) {
            writer.Dispose();
            if(stream.TryGetBuffer(out var buffer)) System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer.AsSpan());
            stream.Dispose();
        }
    }
}
