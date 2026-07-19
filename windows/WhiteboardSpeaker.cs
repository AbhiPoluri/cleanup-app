using System;
using System.IO;
using System.Media;
using System.Speech.Synthesis;
using System.Threading;
using System.Threading.Tasks;

namespace Cleanup;

// Speaks completed Whiteboard responses. System speech is the zero-setup path; Kokoro uses the
// same managed local-voice helper exposed in Settings. A generation token makes Stop immediate.
internal sealed class WhiteboardSpeaker : IDisposable
{
    private readonly SpeechSynthesizer _system = new();
    private CancellationTokenSource? _cts;
    private SoundPlayer? _player;

    public event Action<bool>? SpeakingChanged;

    public void Speak(string text)
    {
        Stop();
        text = text.Trim();
        if (text.Length == 0) return;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        SpeakingChanged?.Invoke(true);
        if (Settings.Current.VoiceTTS == "kokoro" && VoiceEngine.IsInstalled)
            _ = SpeakKokoro(text, ct);
        else
        {
            _system.SpeakCompleted += Completed;
            _system.Rate = -1;
            _system.SpeakAsync(text);
        }
    }

    private void Completed(object? sender, SpeakCompletedEventArgs e)
    {
        _system.SpeakCompleted -= Completed;
        SpeakingChanged?.Invoke(false);
    }

    private async Task SpeakKokoro(string text, CancellationToken ct)
    {
        var dir = Path.Combine(Path.GetTempPath(), "Cleanup");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, $"wb-tts-{Guid.NewGuid():N}.wav");
        try
        {
            var result = await VoiceEngine.Synthesize(text, path, Settings.Current.KokoroVoice, ct);
            if (result == null || ct.IsCancellationRequested) return;
            await Task.Run(() =>
            {
                using var p = new SoundPlayer(path);
                _player = p; p.PlaySync();
            }, ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Log.Write("whiteboard tts: " + ex.Message); }
        finally
        {
            _player = null;
            try { File.Delete(path); } catch { }
            SpeakingChanged?.Invoke(false);
        }
    }

    public void Stop()
    {
        _cts?.Cancel(); _cts?.Dispose(); _cts = null;
        try { _system.SpeakAsyncCancelAll(); } catch { }
        try { _player?.Stop(); } catch { }
        _player = null;
        SpeakingChanged?.Invoke(false);
    }

    public void Dispose() { Stop(); _system.Dispose(); }
}
