using System;
using System.IO;
using System.Threading.Tasks;
using NAudio.Wave;

namespace Cleanup;

// Toggle-to-talk recorder for the Windows Whiteboard. Recording is always PCM16/16k mono so the
// local Parakeet helper can consume it directly; if Parakeet is unavailable, Windows dictation is
// handled by a temporary System.Speech recognizer over the recorded WAV.
internal sealed class WhiteboardVoice : IDisposable
{
    private WaveInEvent? _input;
    private WaveFileWriter? _writer;
    private string? _path;
    public bool Recording => _input != null;
    public event Action<string>? Transcript;
    public event Action<string>? Status;

    public void Toggle()
    {
        if (Recording) StopAndTranscribe(); else Start();
    }

    public void Start()
    {
        if (Recording) return;
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "Cleanup");
            Directory.CreateDirectory(dir);
            _path = Path.Combine(dir, $"wb-mic-{Guid.NewGuid():N}.wav");
            _input = new WaveInEvent { WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 80 };
            _writer = new WaveFileWriter(_path, _input.WaveFormat);
            _input.DataAvailable += (_, e) => _writer?.Write(e.Buffer, 0, e.BytesRecorded);
            _input.RecordingStopped += (_, _) => { _writer?.Dispose(); _writer = null; };
            _input.StartRecording();
            Status?.Invoke("listening — tap mic when done");
        }
        catch (Exception ex)
        {
            Status?.Invoke("microphone unavailable");
            Log.Write("whiteboard mic: " + ex.Message);
            DisposeCapture();
        }
    }

    public void StopAndTranscribe()
    {
        var input = _input; var path = _path;
        if (input == null || path == null) return;
        _input = null; _path = null;
        try { input.StopRecording(); } catch { }
        input.Dispose();
        _writer?.Dispose(); _writer = null;
        Status?.Invoke("transcribing…");
        _ = Transcribe(path);
    }

    private async Task Transcribe(string path)
    {
        string? text = null;
        try
        {
            if (Settings.Current.VoiceASR == "parakeet" && VoiceEngine.IsInstalled)
                text = await VoiceEngine.Transcribe(path);
            else
            {
                using var rec = new System.Speech.Recognition.SpeechRecognitionEngine();
                rec.LoadGrammar(new System.Speech.Recognition.DictationGrammar());
                rec.SetInputToWaveFile(path);
                text = await Task.Run(() => rec.Recognize()?.Text);
            }
        }
        catch (Exception ex) { Log.Write("whiteboard transcription: " + ex.Message); }
        finally { try { File.Delete(path); } catch { } }
        text = text?.Trim();
        if (!string.IsNullOrEmpty(text)) { Status?.Invoke("heard: " + text); Transcript?.Invoke(text); }
        else Status?.Invoke("couldn't hear that");
    }

    private void DisposeCapture()
    {
        try { _input?.StopRecording(); } catch { }
        _input?.Dispose(); _input = null;
        _writer?.Dispose(); _writer = null;
        if (_path != null) { try { File.Delete(_path); } catch { } _path = null; }
    }

    public void Dispose() => DisposeCapture();
}
