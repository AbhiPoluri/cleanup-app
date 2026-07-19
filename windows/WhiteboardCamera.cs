using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using OpenCvSharp;

namespace Cleanup;

// OpenCV-backed webcam loop. Frames are retained as Mats for perspective-corrected snapshots and
// encoded to frozen BitmapImages for WPF. All native resources are owned/disposed here.
internal sealed class WhiteboardCamera : IDisposable
{
    private readonly object _gate = new();
    private VideoCapture? _capture;
    private Mat? _latest;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public event Action<BitmapSource>? Frame;
    public event Action<string>? Status;
    public bool Running => _capture?.IsOpened() == true;

    public void Start(int index)
    {
        Stop();
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        _loop = Task.Run(() => CaptureLoop(index, ct), ct);
    }

    private void CaptureLoop(int index, CancellationToken ct)
    {
        try
        {
            var cap = new VideoCapture(index, VideoCaptureAPIs.DSHOW);
            _capture = cap;
            cap.Set(VideoCaptureProperties.FrameWidth, 1280);
            cap.Set(VideoCaptureProperties.FrameHeight, 720);
            cap.Set(VideoCaptureProperties.Fps, 24);
            if (!cap.IsOpened()) { Status?.Invoke("camera unavailable"); return; }
            Status?.Invoke($"camera {index + 1} ready");
            using var mat = new Mat();
            while (!ct.IsCancellationRequested)
            {
                if (!cap.Read(mat) || mat.Empty()) { Thread.Sleep(40); continue; }
                lock (_gate)
                {
                    _latest?.Dispose();
                    _latest = mat.Clone();
                }
                // JPEG is much cheaper than a per-frame pixel copy and BitmapImage releases the stream.
                Cv2.ImEncode(".jpg", mat, out var bytes, new ImageEncodingParam(ImwriteFlags.JpegQuality, 82));
                var bi = new BitmapImage();
                using (var ms = new MemoryStream(bytes, writable: false))
                {
                    bi.BeginInit();
                    bi.CacheOption = BitmapCacheOption.OnLoad;
                    bi.StreamSource = ms;
                    bi.EndInit();
                }
                bi.Freeze();
                Frame?.Invoke(bi);
                Thread.Sleep(35);
            }
        }
        catch (Exception ex)
        {
            Log.Write("whiteboard camera: " + ex.Message);
            Status?.Invoke("camera failed — " + ex.Message);
        }
    }

    // Save a fresh dewarped PNG. Corners are normalized TL,TR,BR,BL coordinates.
    public string? Snapshot(double[] corners)
    {
        Mat? src;
        lock (_gate) src = _latest?.Clone();
        if (src == null || src.Empty()) { src?.Dispose(); return null; }
        using (src)
        {
            var c = corners is { Length: 8 } ? corners : new[] { .08, .10, .92, .10, .92, .90, .08, .90 };
            var w = src.Width; var h = src.Height;
            var p = new[]
            {
                new Point2f((float)(c[0] * w), (float)(c[1] * h)),
                new Point2f((float)(c[2] * w), (float)(c[3] * h)),
                new Point2f((float)(c[4] * w), (float)(c[5] * h)),
                new Point2f((float)(c[6] * w), (float)(c[7] * h)),
            };
            static double Dist(Point2f a, Point2f b) => Math.Sqrt(Math.Pow(a.X - b.X, 2) + Math.Pow(a.Y - b.Y, 2));
            var outW = Math.Clamp((int)Math.Max(Dist(p[0], p[1]), Dist(p[3], p[2])), 320, 2200);
            var outH = Math.Clamp((int)Math.Max(Dist(p[0], p[3]), Dist(p[1], p[2])), 240, 1800);
            var dstPts = new[] { new Point2f(0, 0), new Point2f(outW - 1, 0), new Point2f(outW - 1, outH - 1), new Point2f(0, outH - 1) };
            using var transform = Cv2.GetPerspectiveTransform(p, dstPts);
            using var dst = new Mat();
            Cv2.WarpPerspective(src, dst, transform, new Size(outW, outH), InterpolationFlags.Cubic,
                BorderTypes.Constant, Scalar.White);
            var dir = Path.Combine(Path.GetTempPath(), "Cleanup");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, $"board-{DateTime.Now:yyyyMMdd-HHmmss-fff}.png");
            return Cv2.ImWrite(path, dst) ? path : null;
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _loop?.Wait(500); } catch { }
        _loop = null;
        _cts?.Dispose(); _cts = null;
        _capture?.Release(); _capture?.Dispose(); _capture = null;
        lock (_gate) { _latest?.Dispose(); _latest = null; }
    }

    public void Dispose() => Stop();
}
