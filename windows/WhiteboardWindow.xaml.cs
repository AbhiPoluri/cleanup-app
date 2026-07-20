using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using QRCoder;
using Path = System.IO.Path;

namespace Cleanup;

public partial class WhiteboardWindow : Window
{
    private sealed class BoardMessage
    {
        public string Id { get; } = Guid.NewGuid().ToString("N");
        public required string Role { get; init; }
        public required string Text { get; set; }
        public string? ImagePath { get; init; }
        public MarkdownView? View { get; set; }
    }

    private readonly Theme _t = Theme.Detect();
    private AgentEngine _engine = new(AgentEngine.SelectedKind());
    private readonly WhiteboardCamera _camera = new();
    private readonly WhiteboardVoice _voice = new();
    private readonly WhiteboardSpeaker _speaker = new();
    private readonly WhiteboardRemote _remote = new();
    private readonly List<BoardMessage> _messages = new();
    private readonly List<string> _images = new();
    private Project _project = ProjectStore.Current();
    private CancellationTokenSource? _runCts;
    private BoardMessage? _liveAssistant;
    private bool _busy, _closing;
    private Ellipse? _dragPoint;
    private string _status = "starting camera…";

    public WhiteboardWindow()
    {
        InitializeComponent();
        Width = Math.Max(MinWidth, Settings.Current.WhiteboardWidth);
        Height = Math.Max(MinHeight, Settings.Current.WhiteboardHeight);
        ApplyTheme();
        ProjectLabel.Text = _project.Name + "  ▾";
        EngineLabel.Text = _engine.Label.Replace(Settings.Current.AgentPermission, "safe");
        MuteLabel.Text = Settings.Current.WhiteboardMuted ? "Sound off" : "Sound on";
        for (var i = 0; i < 4; i++) CameraBox.Items.Add("Camera " + (i + 1));
        CameraBox.SelectedIndex = Math.Clamp(Settings.Current.WhiteboardCamera, 0, 3);
        PositionCorners();

        _camera.Frame += b => Dispatcher.BeginInvoke(() => CameraImage.Source = b);
        _camera.Status += s => Dispatcher.BeginInvoke(() => SetStatus(s));
        _voice.Status += s => Dispatcher.BeginInvoke(() => SetStatus(s));
        _voice.Transcript += s => Dispatcher.BeginInvoke(() => SendText(s));
        _remote.OnSay = s => Dispatcher.BeginInvoke(() => SendText(s));
        _remote.OnLook = () => Dispatcher.BeginInvoke(() => Look());
        _remote.OnMute = v => Dispatcher.BeginInvoke(() => SetMuted(v));
        _remote.OnPhoto = p => Dispatcher.BeginInvoke(() => SendPhoto(p));
        _remote.UrlChanged += u => Dispatcher.BeginInvoke(() => RemoteLabel.Text = u == null ? "Phone unavailable" : "Phone remote");

        Loaded += OnLoaded;
        Closing += OnClosing;
        Closed += OnClosed;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _camera.Start(CameraBox.SelectedIndex);
        SetStatus("starting phone remote…");
        await _remote.Start();
        SetStatus(_camera.Running ? "ready" : "camera starting…");
        InputBox.Focus();
    }

    private void ApplyTheme()
    {
        Root.Background = _t.Surface; Root.BorderBrush = _t.LineStrong;
        TitleLabel.Foreground = _t.Text; StatusLabel.Foreground = _t.Faint; EngineLabel.Foreground = _t.Faint;
        ProjectChip.Background = _t.Surface2; ProjectChip.BorderBrush = _t.Line; ProjectLabel.Foreground = _t.Text;
        foreach (var b in new[] { RemoteBtn, MuteBtn, CloseBtn }) { b.Background = _t.Surface2; b.BorderBrush = _t.Line; }
        RemoteLabel.Foreground = _t.Muted; MuteLabel.Foreground = _t.Muted; CloseLabel.Foreground = _t.Muted;
        CameraCard.Background = _t.Surface2; CameraCard.BorderBrush = _t.Line;
        ChatCard.Background = _t.Surface; ChatCard.BorderBrush = _t.Line;
        CameraStage.Background = Brushes.Black;
        InputBar.Background = _t.Surface2; InputBar.BorderBrush = _t.LineStrong;
        InputBox.Foreground = _t.Text; InputBox.CaretBrush = _t.Text;
    }

    private void SetStatus(string status)
    {
        _status = status;
        StatusLabel.Text = status;
        MicBtn.Content = _voice.Recording ? "stop mic" : "mic";
        Publish();
    }

    private void Publish()
    {
        var wire = _messages.Select(m => new WhiteboardWireMessage(m.Id, m.Role, m.Text,
            m.ImagePath == null ? null : _images.IndexOf(m.ImagePath))).ToList();
        _remote.Publish(_project.Name, wire, _images, _status, _busy, Settings.Current.WhiteboardMuted);
    }

    private Border Bubble(BoardMessage message)
    {
        var text = new MarkdownView(_t, 13); text.SetMarkdown(message.Text);
        message.View = text;
        FrameworkElement content = text;
        if (message.ImagePath != null)
        {
            var panel = new StackPanel(); panel.Children.Add(text);
            try
            {
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.UriSource = new Uri(message.ImagePath); bitmap.DecodePixelWidth = 320; bitmap.EndInit(); bitmap.Freeze();
                panel.Children.Add(new Image { Source = bitmap, MaxWidth = 320, MaxHeight = 220, Stretch = Stretch.Uniform, Margin = new Thickness(0, 7, 0, 0) });
            }
            catch { }
            content = panel;
        }
        var user = message.Role == "user";
        return new Border
        {
            Child = content, Background = user ? _t.Surface3 : _t.Surface2, BorderBrush = _t.Line,
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 8, 10, 8),
            Margin = user ? new Thickness(40, 0, 0, 8) : new Thickness(0, 0, 40, 8),
            HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Left
        };
    }

    private void AddMessage(BoardMessage message)
    {
        _messages.Add(message); Feed.Children.Add(Bubble(message));
        Transcript.ScrollToEnd(); Publish();
    }

    private void AddNote(string text)
    {
        _liveAssistant = null;
        var view = new TextBlock { Text = text, Foreground = _t.Faint, FontSize = 11, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(5, 1, 5, 7) };
        Feed.Children.Add(view); Transcript.ScrollToEnd();
    }

    private void SendText(string text)
    {
        text = text.Trim();
        if (text.Length == 0 || _busy) return;
        InputBox.Clear();
        var attachBoard = text.Contains("look", StringComparison.OrdinalIgnoreCase) || text.Contains("board", StringComparison.OrdinalIgnoreCase);
        var image = attachBoard ? _camera.Snapshot(Settings.Current.WhiteboardCorners) : null;
        RunTurn(text, image);
    }

    private void SendPhoto(string path) => RunTurn("Please examine this photo and respond as my whiteboard brainstorming partner.", path);

    private void RefreshEngine()
    {
        var selected = AgentEngine.SelectedKind();
        if (_engine.Kind != selected) _engine = new AgentEngine(selected);
        EngineLabel.Text = _engine.Label.Replace(Settings.Current.AgentPermission, "safe");
    }

    private void Look()
    {
        if (_busy) return;
        var path = _camera.Snapshot(Settings.Current.WhiteboardCorners);
        if (path == null) { SetStatus("no camera frame yet"); return; }
        RunTurn("Look at the current whiteboard. Briefly describe what changed or stands out, then suggest the most useful next step.", path);
    }

    private async void RunTurn(string text, string? image)
    {
        if (_busy) return;
        RefreshEngine();
        var user = new BoardMessage { Role = "user", Text = text, ImagePath = image };
        if (image != null && !_images.Contains(image)) _images.Add(image);
        AddMessage(user);
        _busy = true; SendBtn.Content = "■"; InputBox.IsEnabled = false; LookBtn.IsEnabled = false;
        SetStatus("thinking…");
        _liveAssistant = null;
        var cts = new CancellationTokenSource(); _runCts = cts;
        var task = "You are a live whiteboard brainstorming partner. Be conversational, concrete, and concise. " +
                   "Respond in 2–4 spoken-friendly sentences unless the user asks for detail. Treat attached images as the current board.\n\nUser: " + text;
        try
        {
            var images = image == null ? Array.Empty<string>() : new[] { image };
            var dirs = image == null ? Array.Empty<string>() : new[] { Path.GetDirectoryName(image)! };
            await _engine.Run(_project, task, images, dirs,
                s => Dispatcher.BeginInvoke(() => UpdateAssistant(s)),
                s => Dispatcher.BeginInvoke(() => AddNote("▸ " + s)), cts.Token, permissionOverride: "safe");
            var reply = _messages.LastOrDefault(m => m.Role == "assistant")?.Text;
            if (!string.IsNullOrWhiteSpace(reply) && !Settings.Current.WhiteboardMuted)
            {
                _speaker.Speak(reply);
                _remote.Speak(reply);
            }
            SetStatus("ready");
        }
        catch (OperationCanceledException) { AddNote("▸ stopped"); SetStatus("stopped"); }
        catch (Exception ex) { AddNote("▸ " + ex.Message); SetStatus("agent failed"); }
        finally
        {
            _busy = false; _runCts = null; SendBtn.Content = "↑"; InputBox.IsEnabled = true; LookBtn.IsEnabled = true;
            Publish(); InputBox.Focus();
        }
    }

    private void UpdateAssistant(string text)
    {
        if (_liveAssistant == null)
        {
            _liveAssistant = new BoardMessage { Role = "assistant", Text = text };
            AddMessage(_liveAssistant);
        }
        else { _liveAssistant.Text = text; _liveAssistant.View?.SetMarkdown(text); Publish(); }
        Transcript.ScrollToEnd();
    }

    private void Send_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) _runCts?.Cancel(); else SendText(InputBox.Text);
    }
    private void Input_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0) { e.Handled = true; SendText(InputBox.Text); }
    }
    private void Look_Click(object sender, RoutedEventArgs e) => Look();
    private void Mic_Click(object sender, RoutedEventArgs e) { if (!_busy) _voice.Toggle(); }

    private void SetMuted(bool muted)
    {
        Settings.Current.WhiteboardMuted = muted; Settings.Current.Save();
        MuteLabel.Text = muted ? "Sound off" : "Sound on";
        if (muted) _speaker.Stop(); Publish();
    }
    private void Mute_Click(object sender, RoutedEventArgs e) { e.Handled = true; SetMuted(!Settings.Current.WhiteboardMuted); }

    private void Camera_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded || CameraBox.SelectedIndex < 0) return;
        Settings.Current.WhiteboardCamera = CameraBox.SelectedIndex; Settings.Current.Save();
        _camera.Start(CameraBox.SelectedIndex);
    }

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        Settings.Current.WhiteboardCorners = new[] { .08, .10, .92, .10, .92, .90, .08, .90 };
        Settings.Current.Save(); PositionCorners();
    }

    private Ellipse[] Points => new[] { P0, P1, P2, P3 };
    private void PositionCorners()
    {
        var c = Settings.Current.WhiteboardCorners is { Length: 8 } ? Settings.Current.WhiteboardCorners : new[] { .08, .10, .92, .10, .92, .90, .08, .90 };
        var polygon = new PointCollection();
        for (var i = 0; i < 4; i++)
        {
            var x = c[i * 2] * 640; var y = c[i * 2 + 1] * 480;
            Canvas.SetLeft(Points[i], x - 10); Canvas.SetTop(Points[i], y - 10); polygon.Add(new Point(x, y));
        }
        FramePolygon.Points = polygon;
    }

    private void Point_Down(object sender, MouseButtonEventArgs e)
    {
        _dragPoint = (Ellipse)sender; _dragPoint.CaptureMouse(); e.Handled = true;
    }
    private void Point_Move(object sender, MouseEventArgs e)
    {
        if (_dragPoint != sender || e.LeftButton != MouseButtonState.Pressed) return;
        var p = e.GetPosition(CornerCanvas); var i = int.Parse((string)_dragPoint.Tag);
        var c = Settings.Current.WhiteboardCorners.ToArray();
        c[i * 2] = Math.Clamp(p.X / 640, 0, 1); c[i * 2 + 1] = Math.Clamp(p.Y / 480, 0, 1);
        Settings.Current.WhiteboardCorners = c; PositionCorners();
    }
    private void Point_Up(object sender, MouseButtonEventArgs e)
    {
        if (_dragPoint != null) { _dragPoint.ReleaseMouseCapture(); _dragPoint = null; Settings.Current.Save(); }
        e.Handled = true;
    }

    private void Project_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        var menu = new ContextMenu { PlacementTarget = ProjectChip, Placement = PlacementMode.Bottom, Background = _t.Surface2, Foreground = _t.Text };
        foreach (var p in ProjectStore.List())
        {
            var item = new MenuItem { Header = (p.Slug == _project.Slug ? "✓  " : "     ") + p.Name };
            item.Click += (_, _) => { _project = ProjectStore.Find(p.Slug) ?? p; ProjectStore.SetCurrent(p.Slug); ProjectLabel.Text = p.Name + "  ▾"; AddNote("— switched to " + p.Name + " —"); Publish(); };
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    private void Remote_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (_remote.Url == null) { SetStatus("phone remote unavailable — check Wi-Fi"); return; }
        new RemoteCodeWindow(_remote.Url, _t) { Owner = this }.ShowDialog();
    }

    private void Root_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || IsInteractive(e.OriginalSource as DependencyObject)) return;
        try { DragMove(); } catch { }
    }
    private static bool IsInteractive(DependencyObject? source)
    {
        for (var node = source; node != null; node = VisualTreeHelper.GetParent(node))
            if (node is ButtonBase or TextBoxBase or ComboBox or Ellipse or ScrollBar)
                return true;
        return false;
    }
    private void Close_Click(object sender, RoutedEventArgs e) { e.Handled = true; Close(); }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_closing) return; _closing = true;
        _runCts?.Cancel(); _voice.Dispose(); _speaker.Dispose(); _camera.Dispose();
        Settings.Current.WhiteboardWidth = Width; Settings.Current.WhiteboardHeight = Height; Settings.Current.Save();
        ExportTranscript();
    }
    private void OnClosed(object? sender, EventArgs e) => _ = _remote.DisposeAsync();

    private void ExportTranscript()
    {
        if (_messages.Count(m => m.Role == "user") < 2) return;
        try
        {
            Directory.CreateDirectory(_project.SessionsDir);
            var path = Path.Combine(_project.SessionsDir, DateTime.Now.ToString("yyyy-MM-dd-HHmm") + "-whiteboard.md");
            var sb = new StringBuilder("# Whiteboard session — ").AppendLine(DateTime.Now.ToString("g")).AppendLine();
            foreach (var m in _messages) sb.Append("## ").AppendLine(m.Role == "user" ? "You" : "Whiteboard").AppendLine().AppendLine(m.Text).AppendLine();
            File.WriteAllText(path, sb.ToString());
        }
        catch (Exception ex) { Log.Write("whiteboard export: " + ex.Message); }
    }
}

internal sealed class RemoteCodeWindow : Window
{
    public RemoteCodeWindow(string url, Theme theme)
    {
        Title = "Whiteboard phone remote"; Width = 390; Height = 490; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; Background = theme.Surface; Foreground = theme.Text;
        var stack = new StackPanel { Margin = new Thickness(24) };
        stack.Children.Add(new TextBlock { Text = "Open on iPhone", FontSize = 18, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = "Use the same Wi-Fi. Accept the one-time certificate warning, then allow microphone access.", TextWrapping = TextWrapping.Wrap, Foreground = theme.Muted, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 8, 0, 14) });
        using var data = QRCodeGenerator.GenerateQrCode(url, QRCodeGenerator.ECCLevel.Q);
        var png = new PngByteQRCode(data).GetGraphic(8);
        var image = new BitmapImage(); using (var ms = new MemoryStream(png)) { image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = ms; image.EndInit(); image.Freeze(); }
        stack.Children.Add(new Image { Source = image, Width = 250, Height = 250, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center });
        var link = new TextBox { Text = url, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 8), Background = theme.Surface2, Foreground = theme.Text, BorderBrush = theme.Line, Padding = new Thickness(7) };
        stack.Children.Add(link);
        var copy = new Button { Content = "Copy address", Padding = new Thickness(12, 5, 12, 5), HorizontalAlignment = HorizontalAlignment.Center };
        copy.Click += (_, _) => { Clipboard.SetText(url); copy.Content = "Copied"; };
        stack.Children.Add(copy); Content = stack;
    }
}
