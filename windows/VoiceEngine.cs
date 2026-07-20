using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Cleanup;

internal readonly record struct VoiceInstallProgress(
    int Step, int TotalSteps, double Percent, string Title, string Detail);

internal enum VoiceInstallResult
{
    Success,
    Failed,
    Cancelled,
    MissingPython,
}

// Manager for the OPTIONAL local voice engines (Parakeet ASR + Kokoro TTS). Everything
// runs inside a managed Python venv at Documents\Cleanup\voice\venv and is driven by a
// single persistent helper.py (stdin/stdout JSON-lines, IDENTICAL protocol to the Mac
// build). The helper process is spawned lazily, reused across requests (serialized by a
// gate — the protocol is strictly one-request-one-response), CreateNoWindow, and killed
// on app exit via Shutdown(). When the venv/helper isn't present, every op fails soft and
// the caller falls back to the Windows built-in recognizer.
internal static class VoiceEngine
{
    // ---- paths ----
    private static string Documents =>
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
    public static string VoiceDir => Path.Combine(Documents, "Cleanup", "voice");
    private static string VenvDir => Path.Combine(VoiceDir, "venv");
    private static string HelperPath => Path.Combine(VoiceDir, "helper.py");
    // Windows venv interpreter (created by `python -m venv`)
    private static string VenvPython => Path.Combine(VenvDir, "Scripts", "python.exe");

    // ---- helper process state (guarded by _gate) ----
    private static Process? _proc;
    private static StreamWriter? _stdin;
    private static StreamReader? _stdout;
    private static readonly SemaphoreSlim _gate = new(1, 1);

    // ---- availability ----

    // The venv exists (python present) AND the helper is written. Pure filesystem check —
    // cheap, no process spawn. A true here means Request() has something to talk to.
    public static bool IsInstalled => File.Exists(VenvPython) && File.Exists(HelperPath);

    // Parakeet is usable when it's the selected ASR engine and the venv is installed. The
    // ping (which confirms the helper actually imports onnx-asr) is done separately/cached
    // by callers that need certainty; the mic uses this cheap gate + a soft fallback.
    public static bool ParakeetSelectedAndReady =>
        Settings.Current.VoiceASR == "parakeet" && IsInstalled;

    // Whether the Parakeet model has already been downloaded (huggingface_hub cache) — lets
    // Health say "ready" vs "downloads on first use". Honours HF_HOME / HF_HUB_CACHE if set.
    public static bool ParakeetModelPresent()
    {
        try
        {
            var hubCache = Environment.GetEnvironmentVariable("HF_HUB_CACHE");
            if (string.IsNullOrEmpty(hubCache))
            {
                var hfHome = Environment.GetEnvironmentVariable("HF_HOME");
                var root = string.IsNullOrEmpty(hfHome)
                    ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cache", "huggingface")
                    : hfHome;
                hubCache = Path.Combine(root, "hub");
            }
            return Directory.Exists(Path.Combine(hubCache, "models--istupakov--parakeet-tdt-0.6b-v3-onnx"));
        }
        catch { return false; }
    }

    // Whether the Kokoro TTS model has been fetched into the voice dir.
    public static bool KokoroModelPresent()
    {
        try { return File.Exists(Path.Combine(VoiceDir, "models", "kokoro-v1.0.onnx")); }
        catch { return false; }
    }

    // ---- request/response ----

    // Send one op and await its reply line. Spawns the helper on first use, reuses it after.
    // Serialized by the gate so concurrent callers can't interleave lines. Returns null on
    // any transport failure (dead helper, timeout) — callers treat null as "unavailable".
    public static async Task<JsonDocument?> Request(object op, int timeoutMs, CancellationToken ct = default)
    {
        if (!IsInstalled) return null;
        await _gate.WaitAsync(ct);
        try
        {
            if (!EnsureProc()) return null;
            var line = JsonSerializer.Serialize(op);
            await _stdin!.WriteLineAsync(line);
            await _stdin.FlushAsync();

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(timeoutMs);
            var readTask = _stdout!.ReadLineAsync();
            var completed = await Task.WhenAny(readTask, Task.Delay(Timeout.Infinite, timeoutCts.Token));
            if (completed != readTask)
            {
                // timed out or cancelled — the helper may be mid-download or wedged; drop it
                KillProc();
                return null;
            }
            timeoutCts.Cancel();   // read won → stop the timeout timer promptly
            var reply = await readTask;
            if (reply == null) { KillProc(); return null; }
            return JsonDocument.Parse(reply);
        }
        catch (Exception ex)
        {
            Log.Write("voice: request failed — " + ex.Message);
            KillProc();
            return null;
        }
        finally { _gate.Release(); }
    }

    // ping → (asr, tts) capability flags, or null if the helper can't be reached. Fast
    // (no model load), so Health can call it directly.
    public static async Task<(bool Asr, bool Tts)?> Ping(CancellationToken ct = default)
    {
        using var doc = await Request(new { op = "ping" }, 15000, ct);
        if (doc == null) return null;
        var root = doc.RootElement;
        if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True) return null;
        bool asr = root.TryGetProperty("asr", out var a) && a.ValueKind == JsonValueKind.True;
        bool tts = root.TryGetProperty("tts", out var t) && t.ValueKind == JsonValueKind.True;
        return (asr, tts);
    }

    // Transcribe a 16k-mono-pcm16 wav. First call downloads the Parakeet model (slow — hence
    // the generous timeout); later calls are quick. Returns null on any failure.
    public static async Task<string?> Transcribe(string wavPath, CancellationToken ct = default)
    {
        // 5 min: the very first transcription pulls the ~2GB model over the network
        using var doc = await Request(new { op = "asr", path = wavPath }, 300000, ct);
        if (doc == null) return null;
        var root = doc.RootElement;
        if (root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True &&
            root.TryGetProperty("text", out var txt) && txt.ValueKind == JsonValueKind.String)
            return txt.GetString();
        if (root.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.String)
            Log.Write("voice: asr error — " + err.GetString());
        return null;
    }

    // Synthesize `text` into a wav at `outPath` via Kokoro. FORWARD-LOOKING — no Windows
    // surface plays TTS yet, but the op is fully wired so the stack is testable. Returns the
    // path on success, null otherwise.
    public static async Task<string?> Synthesize(string text, string outPath, string? voice = null, CancellationToken ct = default)
    {
        object op = voice == null
            ? new { op = "tts", text, @out = outPath }
            : new { op = "tts", text, voice, @out = outPath };
        using var doc = await Request(op, 300000, ct);
        if (doc == null) return null;
        var root = doc.RootElement;
        if (root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True &&
            root.TryGetProperty("path", out var p) && p.ValueKind == JsonValueKind.String)
            return p.GetString();
        if (root.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.String)
            Log.Write("voice: tts error — " + err.GetString());
        return null;
    }

    // ---- process lifecycle ----

    private static bool EnsureProc()
    {
        if (_proc is { HasExited: false } && _stdin != null && _stdout != null) return true;
        KillProc();
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = VenvPython,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                WorkingDirectory = VoiceDir,
            };
            psi.ArgumentList.Add(HelperPath);
            _proc = Process.Start(psi);
            if (_proc == null) return false;
            _stdin = _proc.StandardInput;
            _stdout = _proc.StandardOutput;
            // drain stderr so a chatty download progress bar can't fill the pipe and wedge us
            _ = Task.Run(async () =>
            {
                try { await _proc.StandardError.ReadToEndAsync(); } catch { }
            });
            Log.Write("voice: helper started");
            return true;
        }
        catch (Exception ex)
        {
            Log.Write("voice: helper start failed — " + ex.Message);
            KillProc();
            return false;
        }
    }

    private static void KillProc()
    {
        try { if (_proc is { HasExited: false }) _proc.Kill(true); } catch { }
        try { _proc?.Dispose(); } catch { }
        _proc = null;
        _stdin = null;
        _stdout = null;
    }

    // Called from AppController.Dispose — mirrors the agent-window kill discipline.
    public static void Shutdown() => KillProc();

    // ---- install (venv + pip) ----

    // Locate a system Python ≥3.10 to build the venv from. Prefers the Windows launcher
    // (`py -3`), then `where python`/`python3`. Returns the invocation as (exe, prefixArgs)
    // so `py -3` can carry its `-3` selector. null → no suitable Python found.
    private static (string Exe, string[] Pre)? FindSystemPython()
    {
        // py -3 : the launcher picks the newest 3.x; most reliable on Windows
        if (ProbePython("py", new[] { "-3" })) return ("py", new[] { "-3" });
        foreach (var name in new[] { "python", "python3" })
        {
            var p = WhereOnPath(name);
            if (p != null && ProbePython(p, Array.Empty<string>())) return (p, Array.Empty<string>());
        }
        return null;
    }

    // Run `<exe> [pre] -c "print(sys.version_info…)"` and accept ≥3.10.
    private static bool ProbePython(string exe, string[] pre)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            foreach (var a in pre) psi.ArgumentList.Add(a);
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add("import sys;print('%d.%d' % sys.version_info[:2])");
            using var proc = Process.Start(psi);
            if (proc == null) return false;
            var outp = proc.StandardOutput.ReadToEnd().Trim();
            proc.WaitForExit(5000);
            var parts = outp.Split('.');
            return parts.Length == 2 && int.TryParse(parts[0], out var maj) &&
                   int.TryParse(parts[1], out var min) && (maj > 3 || (maj == 3 && min >= 10));
        }
        catch { return false; }
    }

    private static string? WhereOnPath(string name)
    {
        try
        {
            using var proc = Process.Start(new ProcessStartInfo("where", name)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            });
            if (proc == null) return null;
            var outp = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(3000);
            foreach (var raw in outp.Split('\n'))
            {
                var path = raw.Trim();
                if (path.Length > 0 && File.Exists(path)) return path;
            }
            return null;
        }
        catch { return null; }
    }

    // True once a system Python ≥3.10 is found (drives the install-row copy).
    public static bool SystemPythonAvailable() => FindSystemPython() != null;

    // Async install: create the venv, upgrade pip, pip install the two packages, then write
    // the helper. The installer reports honest stage-based progress: pip does not expose a
    // reliable aggregate byte percentage, so the long package step stays at its stage
    // boundary instead of showing a fake download percentage. Idempotent — re-running
    // repairs a half-built install.
    public static async Task<VoiceInstallResult> Install(
        Action<VoiceInstallProgress> progress, CancellationToken ct = default)
    {
        const int steps = 5;
        void Report(int step, double percent, string title, string detail) =>
            progress(new VoiceInstallProgress(step, steps, percent, title, detail));

        try
        {
            Report(1, 5, "Checking requirements", "Looking for Python 3.10 or newer.");
            var py = FindSystemPython();
            if (py == null)
            {
                return VoiceInstallResult.MissingPython;
            }
            Directory.CreateDirectory(VoiceDir);

            Report(2, 18, "Preparing the local environment",
                File.Exists(VenvPython) ? "Reusing the existing managed environment." : "Creating an isolated Python environment.");
            if (!File.Exists(VenvPython))
            {
                if (!await RunToCompletion(py.Value.Exe, Concat(py.Value.Pre, new[] { "-m", "venv", VenvDir }), VoiceDir, ct))
                    return VoiceInstallResult.Failed;
            }
            if (!File.Exists(VenvPython))
                return VoiceInstallResult.Failed;

            Report(3, 34, "Preparing the package installer", "Updating pip inside Cleanup's environment.");
            if (!await RunToCompletion(VenvPython,
                    new[] { "-m", "pip", "install", "--upgrade", "pip" }, VoiceDir, ct))
                return VoiceInstallResult.Failed;

            Report(4, 52, "Downloading voice packages",
                "Installing Parakeet and Kokoro. This is usually the longest step and can take several minutes.");
            // onnx-asr[cpu,hub]: cpu → onnxruntime, hub → huggingface_hub (needed for the
            // Parakeet model download). kokoro-onnx: the TTS stack.
            if (!await RunToCompletion(VenvPython,
                    new[] { "-m", "pip", "install", "onnx-asr[cpu,hub]", "kokoro-onnx" }, VoiceDir, ct))
                return VoiceInstallResult.Failed;

            Report(5, 90, "Finishing setup", "Writing the local helper and verifying the installation.");
            WriteHelper();

            Report(5, 100, "Local voice is installed", "Parakeet and Kokoro are ready to use.");
            Log.Write("voice: install complete");
            return VoiceInstallResult.Success;
        }
        catch (OperationCanceledException) { return VoiceInstallResult.Cancelled; }
        catch (Exception ex)
        {
            Log.Write("voice: install failed — " + ex.Message);
            return VoiceInstallResult.Failed;
        }
    }

    // Write helper.py (byte-identical to the tested reference; normalized to LF).
    public static void WriteHelper()
    {
        Directory.CreateDirectory(VoiceDir);
        File.WriteAllText(HelperPath, HelperSource.Replace("\r\n", "\n"), new UTF8Encoding(false));
    }

    private static string[] Concat(string[] a, string[] b)
    {
        var r = new string[a.Length + b.Length];
        Array.Copy(a, r, a.Length);
        Array.Copy(b, 0, r, a.Length, b.Length);
        return r;
    }

    // Spawn a one-shot child (venv/pip build step), stream nothing, wait for exit. Output is
    // captured to the log tail on failure. Kills the tree on cancellation.
    private static async Task<bool> RunToCompletion(string exe, string[] args, string cwd, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = cwd,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        var proc = new Process { StartInfo = psi };
        try { proc.Start(); }
        catch (Exception ex) { Log.Write($"voice: spawn {exe} failed — {ex.Message}"); proc.Dispose(); return false; }
        using var reg = ct.Register(() => { try { if (!proc.HasExited) proc.Kill(true); } catch { } });
        var errTask = proc.StandardError.ReadToEndAsync();
        _ = proc.StandardOutput.ReadToEndAsync();   // drain
        await proc.WaitForExitAsync(ct);
        if (proc.ExitCode != 0)
        {
            string tail = "";
            try { tail = (await errTask ?? "").Trim(); } catch { }
            if (tail.Length > 300) tail = "…" + tail[^300..];
            Log.Write($"voice: `{Path.GetFileName(exe)} {string.Join(' ', args)}` exit {proc.ExitCode} {tail}");
            proc.Dispose();
            return false;
        }
        proc.Dispose();
        return true;
    }

    // ---- embedded helper source ----
    // MUST stay byte-identical to the reference tested against the throwaway venv (ping /
    // ASR / TTS all verified). Verbatim string: quotes are doubled, backslashes are literal
    // (so "\n" is Python's newline escape, not a C# newline).
    private const string HelperSource = @"#!/usr/bin/env python3
# Cleanup local voice helper. Persistent process, stdin/stdout JSON-lines protocol,
# IDENTICAL on macOS and Windows. One JSON request per input line, one JSON reply per
# output line. The loop never crashes: every failure is reported as {""ok"":false,...}.
#
#   {""op"":""asr"",""path"":""<wav>""}                            -> {""ok"":true,""text"":""...""}
#   {""op"":""tts"",""text"":""..."",""voice"":""..."",""out"":""<wav>""}  -> {""ok"":true,""path"":""<wav>""}
#   {""op"":""ping""}                                          -> {""ok"":true,""asr"":bool,""tts"":bool}
#   (anything wrong)                                       -> {""ok"":false,""error"":""...""}
#
# ASR: onnx-asr Parakeet TDT 0.6B v3 (HF istupakov/parakeet-tdt-0.6b-v3-onnx).
# TTS: kokoro-onnx 0.5.x. All model files lazy-download on first use into ./models.
import sys
import os
import json
import wave
import urllib.request

VOICE_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(VOICE_DIR, ""models"")

# Kokoro model + voices are fetched on first TTS use (kokoro-onnx doesn't self-download).
KOKORO_MODEL_URL = ""https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx""
KOKORO_VOICES_URL = ""https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin""
DEFAULT_VOICE = ""af_heart""

_asr = None
_tts = None


def _download(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + "".part""
    with urllib.request.urlopen(url) as r, open(tmp, ""wb"") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, dest)
    return dest


def get_asr():
    global _asr
    if _asr is None:
        import onnx_asr
        # preset name maps to HF istupakov/parakeet-tdt-0.6b-v3-onnx (downloaded once).
        # Pin the CPU provider: deterministic across macOS/Windows and matches the CPU-only
        # onnxruntime we install (avoids a CoreML external-data init failure on macOS).
        _asr = onnx_asr.load_model(""nemo-parakeet-tdt-0.6b-v3"", providers=[""CPUExecutionProvider""])
    return _asr


def get_tts():
    global _tts
    if _tts is None:
        from kokoro_onnx import Kokoro
        model = _download(KOKORO_MODEL_URL, os.path.join(MODELS_DIR, ""kokoro-v1.0.onnx""))
        voices = _download(KOKORO_VOICES_URL, os.path.join(MODELS_DIR, ""voices-v1.0.bin""))
        _tts = Kokoro(model, voices)
    return _tts


def do_asr(req):
    path = req.get(""path"")
    if not path or not os.path.exists(path):
        return {""ok"": False, ""error"": ""asr: wav not found""}
    text = get_asr().recognize(path)
    if isinstance(text, (list, tuple)):
        text = "" "".join(str(t) for t in text)
    return {""ok"": True, ""text"": (text or """").strip()}


def do_tts(req):
    text = (req.get(""text"") or """").strip()
    if not text:
        return {""ok"": False, ""error"": ""tts: empty text""}
    out = req.get(""out"")
    if not out:
        return {""ok"": False, ""error"": ""tts: no output path""}
    voice = req.get(""voice"") or DEFAULT_VOICE
    import numpy as np
    samples, sr = get_tts().create(text, voice=voice, speed=1.0, lang=""en-us"")
    pcm = np.clip(np.asarray(samples, dtype=""float32""), -1.0, 1.0)
    pcm = (pcm * 32767.0).astype(""<i2"")
    out_abs = os.path.abspath(out)
    os.makedirs(os.path.dirname(out_abs), exist_ok=True)
    with wave.open(out_abs, ""wb"") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sr))
        w.writeframes(pcm.tobytes())
    return {""ok"": True, ""path"": out}


def do_ping():
    asr_ok = False
    tts_ok = False
    try:
        import onnx_asr  # noqa: F401
        asr_ok = True
    except Exception:
        asr_ok = False
    try:
        import kokoro_onnx  # noqa: F401
        tts_ok = True
    except Exception:
        tts_ok = False
    return {""ok"": True, ""asr"": asr_ok, ""tts"": tts_ok}


def handle(req):
    op = req.get(""op"")
    if op == ""ping"":
        return do_ping()
    if op == ""asr"":
        return do_asr(req)
    if op == ""tts"":
        return do_tts(req)
    return {""ok"": False, ""error"": ""unknown op: %r"" % (op,)}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as e:
            sys.stdout.write(json.dumps({""ok"": False, ""error"": ""bad json: %s"" % e}) + ""\n"")
            sys.stdout.flush()
            continue
        try:
            resp = handle(req)
        except Exception as e:
            resp = {""ok"": False, ""error"": str(e)}
        sys.stdout.write(json.dumps(resp) + ""\n"")
        sys.stdout.flush()


if __name__ == ""__main__"":
    main()
";
}
