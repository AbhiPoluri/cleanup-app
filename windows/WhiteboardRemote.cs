using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using NAudio.Wave;

namespace Cleanup;

internal sealed record WhiteboardWireMessage(string Id, string Role, string Text, int? Image);

// Token-protected LAN HTTPS remote. Kestrel owns TLS directly, avoiding HttpListener's admin-only
// certificate bindings. The self-signed certificate includes the current LAN IP as a SAN.
internal sealed class WhiteboardRemote : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly ConcurrentDictionary<Guid, Channel<string>> _clients = new();
    private readonly string _token = Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant();
    private WebApplication? _app;
    private List<WhiteboardWireMessage> _messages = new();
    private List<string> _images = new();
    private string _project = "Whiteboard", _status = "starting…";
    private bool _running, _muted;

    public Action<string>? OnSay;
    public Action? OnLook;
    public Action<bool>? OnMute;
    public Action<string>? OnPhoto;
    public string? Url { get; private set; }
    public event Action<string?>? UrlChanged;

    public async Task Start()
    {
        if (_app != null) return;
        var ip = LanAddress();
        if (ip == null) { Log.Write("whiteboard remote: no LAN IPv4"); return; }
        var port = FreePort();
        var cert = RemoteCertificate(ip);
        try
        {
            var builder = WebApplication.CreateBuilder(new WebApplicationOptions { ApplicationName = typeof(WhiteboardRemote).Assembly.FullName });
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(o => o.Listen(IPAddress.Any, port, l => l.UseHttps(cert)));
            var app = builder.Build();
            Map(app);
            await app.StartAsync();
            _app = app;
            Url = $"https://{ip}:{port}/?t={_token}";
            UrlChanged?.Invoke(Url);
            Log.Write("whiteboard remote: " + Url);
        }
        catch (Exception ex) { Log.Write("whiteboard remote start: " + ex.Message); }
    }

    private void Map(WebApplication app)
    {
        app.MapGet("/", async c =>
        {
            if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
            c.Response.ContentType = "text/html; charset=utf-8";
            await c.Response.WriteAsync(Page);
        });
        app.MapGet("/state", async c =>
        {
            if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
            object state; lock (_gate) state = new { project = _project, status = _status, running = _running, muted = _muted, imgs = _images.Count };
            await c.Response.WriteAsJsonAsync(state);
        });
        app.MapGet("/events", Events);
        app.MapPost("/say", async c =>
        {
            if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
            var body = await JsonSerializer.DeserializeAsync<Dictionary<string, JsonElement>>(c.Request.Body);
            var text = body != null && body.TryGetValue("text", out var t) ? t.GetString()?.Trim() : null;
            if (!string.IsNullOrEmpty(text)) OnSay?.Invoke(text);
            await c.Response.WriteAsJsonAsync(new { ok = true });
        });
        app.MapPost("/look", async c => { if (!Authorized(c)) { c.Response.StatusCode = 403; return; } OnLook?.Invoke(); await c.Response.WriteAsJsonAsync(new { ok = true }); });
        app.MapPost("/mute", async c =>
        {
            if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
            var body = await JsonSerializer.DeserializeAsync<Dictionary<string, JsonElement>>(c.Request.Body);
            var value = body != null && body.TryGetValue("value", out var v) && v.ValueKind == JsonValueKind.True;
            OnMute?.Invoke(value); await c.Response.WriteAsJsonAsync(new { ok = true });
        });
        app.MapPost("/voice", Voice);
        app.MapPost("/upload", Upload);
        app.MapGet("/img/{index:int}", async c =>
        {
            if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
            var i = int.Parse((string)c.Request.RouteValues["index"]!);
            string? path; lock (_gate) path = i >= 0 && i < _images.Count ? _images[i] : null;
            if (path == null || !File.Exists(path)) { c.Response.StatusCode = 404; return; }
            var ext = Path.GetExtension(path).ToLowerInvariant();
            c.Response.ContentType = ext is ".jpg" or ".jpeg" ? "image/jpeg" : ext is ".webp" ? "image/webp" : "image/png";
            await c.Response.SendFileAsync(path);
        });
    }

    private bool Authorized(HttpContext c) => c.Request.Query["t"] == _token || c.Request.Headers["X-Token"] == _token;

    private async Task Events(HttpContext c)
    {
        if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
        c.Response.ContentType = "text/event-stream";
        c.Response.Headers.CacheControl = "no-cache";
        var id = Guid.NewGuid();
        var channel = Channel.CreateUnbounded<string>();
        _clients[id] = channel;
        try
        {
            List<WhiteboardWireMessage> msgs; string status; bool running, muted; int imgs;
            lock (_gate) { msgs = _messages.ToList(); status = _status; running = _running; muted = _muted; imgs = _images.Count; }
            foreach (var m in msgs) await WriteEvent(c, JsonSerializer.Serialize(new { type = "msg", id = m.Id, role = m.Role, text = m.Text, html = MarkdownRenderer.ToSafeHtml(m.Text), image = m.Image is int n ? $"/img/{n}?t={_token}" : null }));
            await WriteEvent(c, JsonSerializer.Serialize(new { type = "status", text = status }));
            await WriteEvent(c, JsonSerializer.Serialize(new { type = "running", value = running }));
            await WriteEvent(c, JsonSerializer.Serialize(new { type = "settings", muted }));
            await WriteEvent(c, JsonSerializer.Serialize(new { type = "imgs", count = imgs }));
            await foreach (var frame in channel.Reader.ReadAllAsync(c.RequestAborted)) await WriteEvent(c, frame);
        }
        catch (OperationCanceledException) { }
        finally { _clients.TryRemove(id, out _); }
    }

    private static async Task WriteEvent(HttpContext c, string json)
    {
        await c.Response.WriteAsync("data: " + json + "\n\n");
        await c.Response.Body.FlushAsync();
    }

    public void Publish(string project, IReadOnlyList<WhiteboardWireMessage> messages, IReadOnlyList<string> images,
        string status, bool running, bool muted)
    {
        lock (_gate) { _project = project; _messages = messages.ToList(); _images = images.ToList(); _status = status; _running = running; _muted = muted; }
        foreach (var m in messages) Push(new { type = "msg", id = m.Id, role = m.Role, text = m.Text, html = MarkdownRenderer.ToSafeHtml(m.Text), image = m.Image is int n ? $"/img/{n}?t={_token}" : null });
        Push(new { type = "status", text = status }); Push(new { type = "running", value = running });
        Push(new { type = "settings", muted }); Push(new { type = "imgs", count = images.Count });
    }

    public void Speak(string text) { if (!string.IsNullOrWhiteSpace(text)) Push(new { type = "speech", text }); }

    private void Push(object value)
    {
        var json = JsonSerializer.Serialize(value);
        foreach (var c in _clients.Values) c.Writer.TryWrite(json);
    }

    private async Task Voice(HttpContext c)
    {
        if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
        var dir = Path.Combine(Path.GetTempPath(), "Cleanup"); Directory.CreateDirectory(dir);
        var ext = c.Request.ContentType?.Contains("webm", StringComparison.OrdinalIgnoreCase) == true ? ".webm" : ".m4a";
        var source = Path.Combine(dir, "phone-" + Guid.NewGuid().ToString("N") + ext);
        var wav = source + ".wav";
        var started = System.Diagnostics.Stopwatch.StartNew();
        using var progressTimer = new Timer(_ =>
        {
            var elapsed = started.Elapsed;
            Push(new { type = "voice_progress", seconds = (int)elapsed.TotalSeconds,
                text = elapsed.TotalSeconds < 8 ? "transcribing" : "transcribing · first use may be downloading the local model" });
        }, null, TimeSpan.Zero, TimeSpan.FromSeconds(2));
        try
        {
            if (c.Request.ContentLength > 3_000_000) { c.Response.StatusCode = 413; return; }
            await using (var fs = File.Create(source))
                await CopyWithLimit(c.Request.Body, fs, 3_000_000, c.RequestAborted);
            Push(new { type = "voice_progress", seconds = (int)started.Elapsed.TotalSeconds, text = "preparing recording" });
            await Task.Run(() => ConvertToWav(source, wav), c.RequestAborted);
            string? text;
            if (Settings.Current.VoiceASR == "parakeet" && VoiceEngine.IsInstalled)
            {
                Push(new { type = "voice_progress", seconds = (int)started.Elapsed.TotalSeconds, text = "transcribing with Parakeet" });
                text = await VoiceEngine.Transcribe(wav, c.RequestAborted);
            }
            else
            {
                Push(new { type = "voice_progress", seconds = (int)started.Elapsed.TotalSeconds, text = "transcribing with Windows speech" });
                text = await SystemTranscribe(wav, c.RequestAborted);
            }
            text = text?.Trim();
            if (string.IsNullOrEmpty(text))
            {
                Log.Write($"whiteboard remote voice: empty result engine={Settings.Current.VoiceASR} elapsed={started.ElapsedMilliseconds}ms");
                await c.Response.WriteAsJsonAsync(new { ok = false, reason = "No speech was recognized. Try again closer to the microphone." });
                return;
            }
            await c.Response.WriteAsJsonAsync(new { ok = true, text });
            OnSay?.Invoke(text);
            Log.Write($"whiteboard remote voice: ok engine={Settings.Current.VoiceASR} chars={text.Length} elapsed={started.ElapsedMilliseconds}ms");
        }
        catch (OperationCanceledException) { Log.Write("whiteboard remote voice: request cancelled"); }
        catch (InvalidDataException ex)
        {
            Log.Write("whiteboard remote voice: " + ex.Message);
            if (!c.RequestAborted.IsCancellationRequested)
                await c.Response.WriteAsJsonAsync(new { ok = false, reason = ex.Message });
        }
        catch (Exception ex)
        {
            Log.Write("whiteboard remote voice: " + ex.Message);
            if (!c.RequestAborted.IsCancellationRequested)
                await c.Response.WriteAsJsonAsync(new { ok = false, reason = "The recording could not be transcribed. Check Local voice in Windows Settings." });
        }
        finally { try { File.Delete(source); } catch { } try { File.Delete(wav); } catch { } }
    }

    private static async Task CopyWithLimit(Stream input, Stream output, int maxBytes, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var total = 0;
        while (true)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length), ct);
            if (read == 0) break;
            total += read;
            if (total > maxBytes) throw new InvalidDataException("The recording is too long. Keep voice messages under about two minutes.");
            await output.WriteAsync(buffer.AsMemory(0, read), ct);
        }
        if (total == 0) throw new InvalidDataException("The phone sent an empty recording.");
    }

    private static void ConvertToWav(string source, string wav)
    {
        using var reader = new MediaFoundationReader(source);
        using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16000, 16, 1)) { ResamplerQuality = 60 };
        WaveFileWriter.CreateWaveFile(wav, resampler);
    }

    private static async Task<string?> SystemTranscribe(string wav, CancellationToken ct)
    {
        var task = Task.Run(() =>
        {
            using var rec = new System.Speech.Recognition.SpeechRecognitionEngine();
            rec.LoadGrammar(new System.Speech.Recognition.DictationGrammar()); rec.SetInputToWaveFile(wav);
            return rec.Recognize()?.Text;
        }, ct);
        return await task.WaitAsync(TimeSpan.FromSeconds(45), ct);
    }

    private async Task Upload(HttpContext c)
    {
        if (!Authorized(c)) { c.Response.StatusCode = 403; return; }
        if (c.Request.ContentLength > 10_500_000) { c.Response.StatusCode = 413; return; }
        var ext = c.Request.ContentType?.Contains("png", StringComparison.OrdinalIgnoreCase) == true ? ".png" : ".jpg";
        var dir = Path.Combine(Path.GetTempPath(), "Cleanup"); Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "phone-photo-" + Guid.NewGuid().ToString("N") + ext);
        await using (var fs = File.Create(path)) await c.Request.Body.CopyToAsync(fs, c.RequestAborted);
        OnPhoto?.Invoke(path); await c.Response.WriteAsJsonAsync(new { ok = true });
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0); l.Start(); var p = ((IPEndPoint)l.LocalEndpoint).Port; l.Stop(); return p;
    }
    private static string? LanAddress() => Dns.GetHostAddresses(Dns.GetHostName())
        .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a) && !a.ToString().StartsWith("169.254."))?.ToString();

    private static X509Certificate2 RemoteCertificate(string ip)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cleanup"); Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "remote-tls-" + ip.Replace('.', '-') + ".pfx"); const string password = "cleanup-remote";
        if (File.Exists(path)) return new X509Certificate2(path, password, X509KeyStorageFlags.Exportable);
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest("CN=" + ip, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        req.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
        req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, false));
        req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        var san = new SubjectAlternativeNameBuilder(); san.AddIpAddress(IPAddress.Parse(ip)); req.CertificateExtensions.Add(san.Build());
        using var created = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(5));
        File.WriteAllBytes(path, created.Export(X509ContentType.Pfx, password));
        return new X509Certificate2(path, password, X509KeyStorageFlags.Exportable);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var c in _clients.Values) c.Writer.TryComplete(); _clients.Clear();
        if (_app != null) { try { await _app.StopAsync(TimeSpan.FromSeconds(2)); } catch { } await _app.DisposeAsync(); _app = null; }
        Url = null;
    }

    private const string Page = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,maximum-scale=1"><meta name="color-scheme" content="dark"><title>Cleanup Whiteboard</title>
<style>:root{--b:#141414;--s:#1c1c1c;--s2:#292929;--t:#f2f2f2;--m:#999;--l:#3b3b3b}*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}body{margin:0;height:100dvh;display:flex;flex-direction:column;background:var(--b);color:var(--t);font-family:-apple-system,system-ui,sans-serif;overflow:hidden}header{padding:calc(env(safe-area-inset-top) + 11px) 14px 10px;background:var(--s);border-bottom:1px solid var(--l)}#project{font-weight:650}#status{font:11px ui-monospace,monospace;color:var(--m);margin-top:3px}.cert{font-size:10px;color:#666}#feed{flex:1;overflow:auto;padding:12px;display:flex;flex-direction:column;gap:8px}.msg{max-width:84%;padding:8px 11px;border:1px solid var(--l);border-radius:12px;font-size:14px;white-space:normal}.user{align-self:flex-end;background:var(--s2)}.assistant{align-self:flex-start;background:var(--s)}.tool,.note{align-self:center;border:0;color:#777;font:11px ui-monospace,monospace;text-align:center}.msg p{margin:0 0 7px}.msg p:last-child{margin-bottom:0}.msg h1,.msg h2,.msg h3{font-size:1em;margin:8px 0 5px;font-weight:700}.msg ul,.msg ol{margin:5px 0;padding-left:21px}.msg li{margin:3px 0}.msg blockquote{margin:6px 0;padding-left:9px;border-left:2px solid var(--m);color:#ccc}.msg pre{max-width:100%;overflow:auto;background:var(--s2);border:1px solid var(--l);border-radius:7px;padding:8px}.msg code{font:12px ui-monospace,SFMono-Regular,monospace;background:var(--s2);padding:1px 3px;border-radius:3px}.msg pre code{background:transparent;padding:0}.msg table{border-collapse:collapse;display:block;max-width:100%;overflow:auto}.msg td,.msg th{border:1px solid var(--l);padding:5px 7px}.msg a{color:var(--t);text-decoration:underline}.msg img{display:block;max-width:100%;border-radius:8px;margin-top:6px}#heard{display:none;padding:8px 12px;background:var(--s2);border-top:1px solid var(--l);font-size:12px;color:var(--m)}#heard.on{display:block}#heard b{color:var(--t)}#row{display:flex;gap:7px;padding:8px 10px;background:var(--s);border-top:1px solid var(--l)}input{flex:1;min-width:0;background:var(--s2);border:1px solid var(--l);border-radius:10px;color:var(--t);padding:10px;font-size:16px}button{border:1px solid var(--l);background:var(--s2);color:var(--t);border-radius:10px}#send{width:42px;font-size:18px;background:var(--t);color:#111}#talk{padding:12px 10px calc(env(safe-area-inset-bottom) + 12px);background:var(--s);border-top:1px solid var(--l);display:flex;align-items:center;justify-content:center;gap:10px}#ptt{width:112px;height:112px;border-radius:56px;font-weight:700;text-transform:uppercase;touch-action:none}#ptt.rec{border-color:var(--t);transform:scale(.97)}.small{width:43px;height:40px;font-size:18px}</style></head>
<body><header><div id="project">Whiteboard</div><div id="status">connecting…</div><div class="cert">first visit: accept the certificate warning</div></header><div id="feed"></div><div id="heard"></div><div id="row"><input id="inp" placeholder="type a message…"><button id="send">↑</button></div><div id="talk"><button id="look" class="small">◉</button><button id="ptt">Hold</button><button id="mute" class="small">🔊</button><button id="photo" class="small">＋</button><input id="file" type="file" accept="image/*" capture="environment" hidden></div>
<script>(function(){var token=new URLSearchParams(location.search).get('t')||'',q=s=>document.querySelector(s),feed=q('#feed'),els={},muted=false,stream=null,rec=null,chunks=[],holding=false,sendClip=false,unlocked=false,heardTimer;
function url(p){return p+(p.indexOf('?')>=0?'&':'?')+'t='+encodeURIComponent(token)}function stat(s){q('#status').textContent=s||''}function unlock(){unlocked=true;if(speechSynthesis)try{speechSynthesis.resume()}catch(_){}}function speak(t){if(!t||muted||!unlocked||!speechSynthesis)return;try{speechSynthesis.cancel();var u=new SpeechSynthesisUtterance(t);u.rate=.96;speechSynthesis.speak(u)}catch(_){}}
function up(m){var e=els[m.id];if(!e){e=document.createElement('div');e.className='msg '+m.role;els[m.id]=e;feed.appendChild(e)}e.innerHTML=m.html||'';if(!m.html)e.appendChild(document.createTextNode(m.text||''));if(m.image){var im=document.createElement('img');im.src=m.image;e.appendChild(im)}feed.scrollTop=feed.scrollHeight}function heard(t){var h=q('#heard');h.innerHTML='<b>Heard: </b>';h.appendChild(document.createTextNode(t));h.classList.add('on');clearTimeout(heardTimer);heardTimer=setTimeout(()=>h.classList.remove('on'),12000)}
var es=new EventSource(url('/events'));es.onmessage=e=>{var d;try{d=JSON.parse(e.data)}catch(_){return}if(d.type==='msg')up(d);else if(d.type==='status')stat(d.text);else if(d.type==='voice_progress')stat((d.text||'transcribing')+' · '+(d.seconds||0)+'s');else if(d.type==='settings'){muted=!!d.muted;q('#mute').textContent=muted?'🔇':'🔊'}else if(d.type==='speech')speak(d.text)};
function post(p,o){return fetch(url(p),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o||{})})}function send(){var i=q('#inp'),t=i.value.trim();if(t){i.value='';post('/say',{text:t})}}q('#send').onclick=()=>{unlock();send()};q('#inp').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();unlock();send()}};q('#look').onclick=()=>{unlock();post('/look',{})};q('#mute').onclick=()=>{unlock();muted=!muted;q('#mute').textContent=muted?'🔇':'🔊';if(muted)speechSynthesis.cancel();post('/mute',{value:muted})};
async function start(){unlock();try{stream=stream||await navigator.mediaDevices.getUserMedia({audio:true});var mime=['audio/mp4','audio/webm;codecs=opus','audio/webm'].find(x=>MediaRecorder.isTypeSupported(x))||'';rec=mime?new MediaRecorder(stream,{mimeType:mime}):new MediaRecorder(stream);chunks=[];rec.ondataavailable=e=>{if(e.data.size)chunks.push(e.data)};rec.onstop=finish;rec.start();q('#ptt').classList.add('rec');q('#ptt').textContent='Release'}catch(e){stat(location.protocol!=='https:'?'voice needs https':'allow microphone in Safari')}}async function finish(){q('#ptt').classList.remove('rec');q('#ptt').textContent='Hold';if(!sendClip)return;sendClip=false;var b=new Blob(chunks,{type:rec.mimeType||'audio/mp4'}),ac=new AbortController(),timeout=setTimeout(()=>ac.abort(),960000);stat('uploading recording…');try{var r=await fetch(url('/voice'),{method:'POST',headers:{'Content-Type':b.type},body:b,signal:ac.signal}),d=await r.json();if(d.ok&&d.text){heard(d.text);stat('sending transcript…')}else stat(d.reason||"couldn't hear that")}catch(e){stat(e.name==='AbortError'?'transcription timed out':'voice failed — check the Windows log')}finally{clearTimeout(timeout)}}
var p=q('#ptt');p.onpointerdown=e=>{e.preventDefault();try{p.setPointerCapture(e.pointerId)}catch(_){}holding=true;sendClip=false;start()};p.onpointerup=e=>{if(!holding)return;holding=false;sendClip=true;if(rec&&rec.state!=='inactive')rec.stop()};p.onpointercancel=()=>{holding=false;sendClip=false;if(rec&&rec.state!=='inactive')rec.stop()};
q('#photo').onclick=()=>q('#file').click();q('#file').onchange=function(){var f=this.files&&this.files[0];this.value='';if(!f)return;stat('sending photo…');fetch(url('/upload'),{method:'POST',headers:{'Content-Type':f.type||'image/jpeg'},body:f}).then(()=>stat('sent')).catch(()=>stat('photo failed'))};fetch(url('/state')).then(r=>r.json()).then(s=>{q('#project').textContent=s.project||'Whiteboard';stat(s.status);muted=!!s.muted;q('#mute').textContent=muted?'🔇':'🔊'});})();</script></body></html>
""";
}
