using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Speech.Recognition;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Path = System.IO.Path;   // disambiguate from System.Windows.Shapes.Path

namespace Cleanup;

// Agent mode: a clean, borderless chat window that spins up an agentic CLI (Codex
// or Claude Code) and streams its work in. Mirrors PopupWindow's chrome (resizable
// borderless, drag-anywhere, entrance/exit animation, size persistence). Voice input
// via System.Speech. Engine / model / permission tier all come from Agent settings.
public partial class AgentWindow : Window
{
    private readonly Theme _t = Theme.Detect();
    private readonly AgentEngine _engine;
    private Project _project = ProjectStore.Current();   // supplies cwd + resume for every turn
    private readonly ScreenUtil.NativePoint _anchor;
    private readonly double _fontSize = Math.Clamp(Settings.Current.FontSize, 11, 18);

    private string? _context;                 // selection context, appended to the FIRST task only
    private CancellationTokenSource? _runCts;  // in-flight turn (null = idle)
    private bool _busy;
    private bool _closeRequested;

    // live assistant bubble the streaming text writes into (null → next text opens a new
    // one). A read-only TextBox so the agent's output is selectable/copyable.
    private TextBox? _curBubbleText;
    private bool _autoScroll = true;

    // ---- attachments (per-message; tray clears after send) ----
    private readonly List<Attachment> _attachments = new();
    private SolidColorBrush _borderBrush = null!;   // owned clone so the drag-highlight can animate it
    private bool _dragHighlight;

    private static readonly string[] ImageExts =
        { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif" };
    private static bool IsImagePath(string p) =>
        Array.IndexOf(ImageExts, Path.GetExtension(p).ToLowerInvariant()) >= 0;
    private static string AttachName(string p)
    {
        var n = Path.GetFileName(p.TrimEnd('\\', '/'));
        return string.IsNullOrEmpty(n) ? p : n;
    }

    private sealed class Attachment
    {
        public required string Path;
        public string Name => AttachName(Path);
        public bool IsImage => IsImagePath(Path);
    }

    // ---- voice ----
    // Two engines share the mic button:
    //   * System.Speech (SAPI dictation) — the built-in, always-available fallback. Live
    //     hypotheses stream into the input as you talk.
    //   * Parakeet (local onnx-asr) — record-then-transcribe. Mic ON records 16k mono wav
    //     via MCI; mic OFF stops, transcribes, and inserts the text. Chosen per-toggle when
    //     Settings.VoiceASR == "parakeet" AND the venv/helper are installed; otherwise SAPI.
    private SpeechRecognitionEngine? _speech;
    private bool _recording;
    private string _voiceBase = "";    // input text when recording started
    private string _voiceFinal = "";   // finalized phrases appended since

    // Parakeet record-then-transcribe state
    private bool _usingParakeet;       // which engine THIS recording session picked (latched at StartRecording)
    private string? _mciAlias;         // MCI device alias while recording (null = not recording via MCI)
    private string? _recWavPath;       // wav being captured this session
    private bool _transcribing;        // between stop and text-inserted (mic disabled, dim)
    private DispatcherTimer? _recCap;  // ~60s auto-stop guard

    public AgentWindow(string? context, ScreenUtil.NativePoint anchor)
    {
        _anchor = anchor;
        _engine = new AgentEngine(AgentEngine.SelectedKind());

        InitializeComponent();

        Width = Math.Max(MinWidth, Settings.Current.AgentWidth);
        Height = Math.Max(MinHeight, Settings.Current.AgentHeight);

        ApplyTheme();
        EngineLabel.Text = _engine.Label;
        ProjectChipText.Text = _project.Name;

        // selection context → dim collapsed pill; kept for the first task
        var ctx = context?.Trim();
        if (!string.IsNullOrEmpty(ctx))
        {
            _context = ctx;
            var head = ctx.Replace("\n", " ");
            if (head.Length > 80) head = head[..80] + "…";
            ContextText.Text = "context: " + head;
            ContextPill.Visibility = Visibility.Visible;
        }

        InputBox.TextChanged += (_, _) =>
            InputPlaceholder.Visibility = InputBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        WireButton(CloseBtn, 0.85);
        WireButton(ProjectChip, 0.9);
        WireButton(NewSessionBtn, 0.85);
        WireButton(HelpBtn, 0.85);
        WireButton(AttachBtn, 0.9);
        WireButton(MicBtn, 0.9);
        WireButton(SendBtn, 1.0);

        InitSpeech();

        // if the selected engine's CLI is missing, say so and keep input disabled
        if (_engine.ResolveCli() == null)
        {
            AddDimLine(_engine.Kind == AgentEngineKind.Codex
                ? "Codex CLI not found. Install it (npm i -g @openai/codex) and run `codex login`, then reopen. — see Health in Settings"
                : "Claude Code CLI not found. Install it and run `claude` once to log in, then reopen. — see Health in Settings");
            InputBox.IsEnabled = false;
            SendBtn.Opacity = 0.4;
        }
        else if (_project.HasSession)
        {
            AddDimLine($"resuming {_project.Name} — ⊕ for a fresh session");
        }
        else
        {
            AddDimLine("Ready — ask the agent to do anything. Follow-ups keep the same session.");
        }

        Closing += (_, _) => SaveSize();
        Closed += (_, _) => Cleanup();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            if (_helpOpen) ToggleHelp(false); else SafeClose();
        };

        Opacity = 0;
        Loaded += (_, _) => { PlayEntrance(); if (InputBox.IsEnabled) InputBox.Focus(); };
    }

    // ---------- theming ----------

    private void ApplyTheme()
    {
        Root.Background = _t.Surface;
        // owned clone (theme brushes are shared singletons) so the drag-over highlight
        // can animate the border colour without mutating the palette.
        _borderBrush = new SolidColorBrush(((SolidColorBrush)_t.LineStrong).Color);
        Root.BorderBrush = _borderBrush;
        TitleLabel.Foreground = _t.Text;
        EngineLabel.Foreground = _t.Faint;
        StatusDot.Fill = _t.Text;
        ProjectChip.Background = _t.Surface2; ProjectChip.BorderBrush = _t.Line;
        ProjectChipText.Foreground = _t.Text; ProjectChipCaret.Foreground = _t.Faint;
        NewSessionBtn.Background = _t.Surface2; NewSessionBtn.BorderBrush = _t.Line; NewSessionGlyph.Foreground = _t.Muted;
        HelpBtn.Background = _t.Surface2; HelpBtn.BorderBrush = _t.Line; HelpLabel.Foreground = _t.Muted;
        HelpOverlay.Background = new SolidColorBrush(Color.FromArgb(0xCC, 0, 0, 0));
        HelpCard.Background = _t.Surface; HelpCard.BorderBrush = _t.LineStrong;
        CloseBtn.Background = _t.Surface2; CloseBtn.BorderBrush = _t.Line; CloseLabel.Foreground = _t.Muted;
        ContextPill.Background = _t.Surface2; ContextPill.BorderBrush = _t.Line; ContextText.Foreground = _t.Muted;
        InputBar.Background = _t.Surface2; InputBar.BorderBrush = _t.LineStrong;
        InputBox.Foreground = _t.Text; InputBox.CaretBrush = _t.Text;
        InputPlaceholder.Foreground = _t.Faint;
        AttachBtn.Background = _t.Surface2; AttachBtn.BorderBrush = _t.Line; AttachGlyph.Foreground = _t.Muted;
        MicBtn.Background = _t.Surface2; MicBtn.BorderBrush = _t.Line; MicGlyph.Foreground = _t.Muted;
        SendBtn.Background = _t.Accent; SendGlyph.Foreground = _t.OnAccent; StopGlyph.Foreground = _t.OnAccent;
    }

    // ---------- projects (chip menu · switch · new · edit · fresh session) ----------

    // Build + open the mono project menu off the chip: project list (✓ current), New project…,
    // divider, Edit project brief….
    private void ProjectChip_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var menu = new ContextMenu
        {
            Background = _t.Surface2,
            Foreground = _t.Text,
            BorderBrush = _t.LineStrong,
            FontSize = 12,
            PlacementTarget = ProjectChip,
            Placement = PlacementMode.Bottom,
        };
        foreach (var p in ProjectStore.List())
        {
            var slug = p.Slug;
            var mark = slug == _project.Slug ? "✓  " : "     ";
            var item = new MenuItem { Header = mark + p.Name, Background = _t.Surface2, Foreground = _t.Text };
            item.Click += (_, _) => SwitchProject(slug);
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        var add = new MenuItem { Header = "New project…", Background = _t.Surface2, Foreground = _t.Text };
        add.Click += (_, _) => NewProjectFlow();
        menu.Items.Add(add);
        menu.Items.Add(new Separator());
        var edit = new MenuItem { Header = "Edit project brief…", Background = _t.Surface2, Foreground = _t.Text };
        edit.Click += (_, _) => EditBriefFlow();
        menu.Items.Add(edit);
        menu.IsOpen = true;
    }

    // Switch the window's project: reset CLI session state (the engine reads the new project's
    // resume state on the next turn), swap cwd, update the chip + tray, drop a dim marker.
    private void SwitchProject(string slug)
    {
        if (slug == _project.Slug) return;
        var p = ProjectStore.Find(slug);
        if (p == null) return;
        _project = p;
        ProjectStore.SetCurrent(slug);
        ProjectChipText.Text = p.Name;
        AddDimLine($"— switched to {p.Name} —");
        Log.Write($"agent: switch project={slug} resume={(p.HasSession ? "continue" : "fresh")}");
    }

    private void NewProjectFlow()
    {
        var dlg = new ProjectDialog(this, "New project", "", "", editMode: false);
        if (dlg.ShowDialog() == true)
        {
            var p = ProjectStore.Create(dlg.ProjectName, dlg.Brief);
            SwitchProject(p.Slug);
        }
    }

    private void EditBriefFlow()
    {
        var dlg = new ProjectDialog(this, "Edit project brief", _project.Name, _project.Brief, editMode: true);
        if (dlg.ShowDialog() == true)
        {
            _project.Brief = dlg.Brief;
            ProjectStore.Save(_project);
            ProjectStore.WriteInstructionFiles(_project);   // brief change → regenerate CLAUDE.md / AGENTS.md
            AddDimLine($"updated {_project.Name}'s brief");
        }
    }

    // ⊕ — start a fresh conversation in this project (clears resume state so the next turn
    // omits --continue / resume). Claude's own per-cwd auto-memory for the project is untouched.
    private void NewSession_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        _project.HasSession = false;
        _project.CodexSessionId = null;
        ProjectStore.Save(_project);
        AddDimLine($"started a fresh session in {_project.Name}");
        Log.Write($"agent: new session project={_project.Slug}");
    }

    // ---------- transcript ----------

    private void Transcript_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        // only react to user scrolls (content-growth events have ExtentHeightChange != 0)
        if (e.ExtentHeightChange == 0)
            _autoScroll = Transcript.VerticalOffset >= Transcript.ScrollableHeight - 2;
    }

    private void AutoScroll() { if (_autoScroll) Transcript.ScrollToEnd(); }

    // The styled bubble shell (shared by user + assistant).
    private Border WrapBubble(FrameworkElement child, bool user) => new()
    {
        Child = child,
        Background = user ? _t.Surface3 : _t.Surface2,
        BorderBrush = user ? _t.LineStrong : _t.Line,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(12, 9, 12, 9),
        Margin = user ? new Thickness(44, 0, 0, 10) : new Thickness(0, 0, 44, 10),
        HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Left,
    };

    // User bubble: typed text, plus a dim paperclip + "file, file" line beneath it when the
    // turn carried attachments (so the user sees what went along).
    private void AddUserBubble(string text, IReadOnlyList<string>? attachNames, IReadOnlyList<string>? imagePaths = null)
    {
        _curBubbleText = null;
        var main = new TextBlock { Text = text, Foreground = _t.Text, TextWrapping = TextWrapping.Wrap, FontSize = _fontSize };
        FrameworkElement content = main;
        bool hasImgs = imagePaths is { Count: > 0 };
        bool hasNames = attachNames is { Count: > 0 };
        if (hasImgs || hasNames)
        {
            var panel = new StackPanel();
            panel.Children.Add(main);
            // image attachments render as clickable thumbnails (open full-size); non-images fall
            // back to the dim paperclip filename line below.
            if (hasImgs)
            {
                var wrap = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
                foreach (var p in imagePaths!)
                {
                    var card = BuildBubbleThumb(p);
                    if (card != null) wrap.Children.Add(card);
                }
                if (wrap.Children.Count > 0) panel.Children.Add(wrap);
            }
            if (hasNames)
            {
            var attachLine = new TextBlock
            {
                Foreground = _t.Faint,
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 4, 0, 0),
            };
            attachLine.Inlines.Add(new System.Windows.Documents.Run(" ")
                { FontFamily = new FontFamily("Segoe Fluent Icons,Segoe MDL2 Assets") });
            attachLine.Inlines.Add(new System.Windows.Documents.Run(string.Join(", ", attachNames!)));
            panel.Children.Add(attachLine);
            }
            content = panel;
        }
        var b = WrapBubble(content, user: true);
        Feed.Children.Add(b);
        Anim.FadeSlideIn(b, 6, 180);
        AutoScroll();
    }

    // Assistant bubble: a read-only, borderless, transparent TextBox so the output is
    // selectable/copyable, plus a dim hover-reveal copy chip in the bottom-right corner.
    private void AddAssistantBubble()
    {
        var box = new TextBox
        {
            Foreground = _t.Text,
            FontSize = _fontSize,
            TextWrapping = TextWrapping.Wrap,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            IsReadOnly = true,
            IsReadOnlyCaretVisible = false,
            AcceptsReturn = true,
            TextAlignment = TextAlignment.Left,
            CaretBrush = Brushes.Transparent,
            SelectionBrush = _t.LineStrong,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        // let the wheel scroll the transcript rather than being swallowed by the box
        box.PreviewMouseWheel += (_, e) =>
        {
            if (e.Handled) return;
            e.Handled = true;
            Transcript.RaiseEvent(new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta)
            { RoutedEvent = UIElement.MouseWheelEvent });
        };

        var copy = BuildCopyChip(() => box.Text);
        var grid = new Grid();
        grid.Children.Add(box);
        grid.Children.Add(copy);

        var b = WrapBubble(grid, user: false);
        b.MouseEnter += (_, _) => Anim.OpacityTo(copy, 0.75, 100);
        b.MouseLeave += (_, _) => Anim.OpacityTo(copy, 0.0, 150);

        _curBubbleText = box;
        Feed.Children.Add(b);
        Anim.FadeSlideIn(b, 6, 180);
        AutoScroll();
    }

    // Dim copy affordance: click copies the whole bubble, flashes "copied" ~1s.
    private Border BuildCopyChip(Func<string> getText)
    {
        var glyph = new TextBlock { Text = "⧉", FontSize = 11, Foreground = _t.Faint, FontFamily = new FontFamily("Consolas") };
        var chip = new Border
        {
            Child = glyph,
            Background = _t.Surface2,
            BorderBrush = _t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(5, 1, 5, 1),
            Cursor = Cursors.Hand,
            Opacity = 0.0,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        chip.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            try { Clipboard.SetText(getText() ?? ""); } catch { }
            glyph.Text = "copied";
            Anim.OpacityTo(chip, 1.0, 80);
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1000) };
            timer.Tick += (_, _) => { timer.Stop(); glyph.Text = "⧉"; };
            timer.Start();
        };
        return chip;
    }

    private void UpdateBubble(string text)
    {
        HideThinking();
        if (_curBubbleText == null) AddAssistantBubble();
        _curBubbleText!.Text = text;
        AutoScroll();
    }

    // Assistant-styled bubble with pulsing dots — visible whenever the agent is
    // working but has produced no output yet (first token on big models can take
    // 10s+; without this the window reads as dead and users assume it broke).
    private Border? _thinkingRow;
    private LoadingDots? _thinkingDots;

    private void ShowThinking()
    {
        if (_thinkingRow != null) return;
        _thinkingDots = new LoadingDots(_t.Text, 6, 5);
        _thinkingRow = new Border
        {
            Child = _thinkingDots,
            Background = _t.Surface2,
            BorderBrush = _t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(13, 11, 13, 11),
            Margin = new Thickness(0, 0, 44, 10),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Feed.Children.Add(_thinkingRow);
        _thinkingDots.Start();
        Anim.FadeSlideIn(_thinkingRow, 6, 180);
        AutoScroll();
    }

    private void HideThinking()
    {
        if (_thinkingRow == null) return;
        _thinkingDots?.Stop();
        Feed.Children.Remove(_thinkingRow);
        _thinkingRow = null;
        _thinkingDots = null;
    }

    // dim one-liner (tool use / raw output / stopped); slides in 4px and closes the bubble
    private void AddToolLine(string s)
    {
        HideThinking();
        _curBubbleText = null;
        var tb = new TextBlock
        {
            Text = s,
            Foreground = _t.Faint,
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 0, 0, 9),
        };
        Feed.Children.Add(tb);
        Anim.FadeSlideIn(tb, 4, 160);
        // still working after a tool line → dots return below it (keeps liveness
        // visible through the gaps between tool calls)
        if (_busy) ShowThinking();
        AutoScroll();
    }

    private void AddErrorLine(string msg)
    {
        _curBubbleText = null;
        var tb = new TextBlock
        {
            Text = "⚠ " + msg,
            Foreground = _t.Muted,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 2, 0, 9),
        };
        Feed.Children.Add(tb);
        Anim.FadeSlideIn(tb, 4, 160);
        AutoScroll();
    }

    private void AddDimLine(string s)
    {
        _curBubbleText = null;
        var tb = new TextBlock
        {
            Text = s,
            Foreground = _t.Faint,
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 2, 0, 10),
        };
        Feed.Children.Add(tb);
        Anim.FadeSlideIn(tb, 4, 200);
        AutoScroll();
    }

    // ---------- send / run / stop ----------

    private void Send_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (_busy) { _runCts?.Cancel(); return; }
        Submit();
    }

    private void Input_KeyDown(object sender, KeyEventArgs e)
    {
        // Ctrl+V with a bitmap (and no text) on the clipboard → attach the image; a
        // screenshot → paste is the killer flow. Normal text paste is never intercepted.
        if (e.Key == Key.V && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control && !_busy)
        {
            if (TryPasteImage()) { e.Handled = true; return; }
        }
        // Enter sends; Shift+Enter inserts a newline (AcceptsReturn handles that)
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
        {
            e.Handled = true;
            if (!_busy) Submit();
        }
    }

    // ---------- attachments (picker · drag-drop · paste) ----------

    private void Attach_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (_busy) return;
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Multiselect = true,
            Title = "Attach files",
            CheckFileExists = true,
            Filter = "All files (*.*)|*.*",
        };
        if (dlg.ShowDialog(this) == true)
            foreach (var f in dlg.FileNames) AddAttachment(f);
    }

    // External attach (e.g. a fresh snip) — reuse the exact attachment pipeline the
    // picker/drag-drop/paste paths use, so it threads into the task identically.
    public void AttachExternal(string path) => AddAttachment(path);

    private void AddAttachment(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        var full = path;
        try { full = Path.GetFullPath(path); } catch { }
        if (_attachments.Any(a => string.Equals(a.Path, full, StringComparison.OrdinalIgnoreCase))) return;
        var att = new Attachment { Path = full };
        _attachments.Add(att);
        AddAttachPill(att);
        AttachTrayScroll.Visibility = Visibility.Visible;
    }

    private void AddAttachPill(Attachment att)
    {
        // images get a real thumbnail card; everything else keeps the icon+name pill
        var chip = att.IsImage ? BuildTrayThumb(att) : BuildTrayPill(att);
        AttachTray.Children.Add(chip);
        Anim.FadeSlideIn(chip, 4, 160);
    }

    private Border BuildTrayPill(Attachment att)
    {
        var icon = new TextBlock { Text = att.IsImage ? "" : "", FontFamily = new FontFamily("Segoe Fluent Icons,Segoe MDL2 Assets"), Foreground = _t.Muted, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 5, 0) };
        var shown = att.Name;
        if (shown.Length > 24) shown = shown[..22] + "\u2026";
        var label = new TextBlock { Text = shown, FontSize = 11, Foreground = _t.Muted, VerticalAlignment = VerticalAlignment.Center, ToolTip = att.Path };
        var close = new TextBlock { Text = "\u2715", FontSize = 10, Foreground = _t.Faint, Cursor = Cursors.Hand, Margin = new Thickness(7, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(icon);
        sp.Children.Add(label);
        sp.Children.Add(close);
        var pill = new Border
        {
            Child = sp,
            Background = _t.Surface2,
            BorderBrush = _t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(0, 0, 6, 6),
        };
        close.MouseLeftButtonUp += (_, e) => { e.Handled = true; RemoveAttachment(att, pill); };
        return pill;
    }

    // Image tray card: a rounded, mono-bordered thumbnail (aspect-fit crop) with a ✕ remove
    // badge overlaid top-right. Click the thumbnail to open the file. Decoded downscaled so
    // the full-size bitmap isn't retained and the file handle closes immediately.
    private FrameworkElement BuildTrayThumb(Attachment att)
    {
        var card = new Grid { Margin = new Thickness(0, 0, 6, 6) };
        var bmp = LoadThumb(att.Path, 112);
        var pic = new Border
        {
            Width = 74, Height = 56,
            CornerRadius = new CornerRadius(6),
            BorderBrush = _t.Line, BorderThickness = new Thickness(1),
            Background = bmp != null ? new ImageBrush(bmp) { Stretch = Stretch.UniformToFill } : _t.Surface2,
            Cursor = Cursors.Hand, ToolTip = att.Path,
        };
        pic.MouseLeftButtonUp += (_, e) => { e.Handled = true; OpenFile(att.Path); };
        card.Children.Add(pic);
        var badgeText = new TextBlock { Text = "\u2715", FontSize = 9, FontWeight = FontWeights.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var badge = new Border
        {
            Width = 16, Height = 16, CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(0x8C, 0, 0, 0)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x4D, 255, 255, 255)), BorderThickness = new Thickness(0.5),
            Child = badgeText, Cursor = Cursors.Hand,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 3, 3, 0), ToolTip = "Remove",
        };
        badge.MouseLeftButtonUp += (_, e) => { e.Handled = true; RemoveAttachment(att, card); };
        card.Children.Add(badge);
        return card;
    }

    // Clickable 120x90 thumbnail for a sent user bubble (opens full-size on click).
    private Border? BuildBubbleThumb(string path)
    {
        var bmp = LoadThumb(path, 180);
        if (bmp == null) return null;
        var card = new Border
        {
            Width = 120, Height = 90,
            CornerRadius = new CornerRadius(8),
            BorderBrush = _t.Line, BorderThickness = new Thickness(1),
            Background = new ImageBrush(bmp) { Stretch = Stretch.UniformToFill },
            Cursor = Cursors.Hand, Margin = new Thickness(0, 0, 6, 6), ToolTip = "Open full size",
        };
        card.MouseLeftButtonUp += (_, e) => { e.Handled = true; OpenFile(path); };
        return card;
    }

    // Decode a downscaled thumbnail bitmap (OnLoad = decode now + release the file handle,
    // DecodePixelHeight = don't hold full-size pixels). Frozen so it's cross-thread safe.
    private static BitmapImage? LoadThumb(string path, int decodePixelHeight)
    {
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            bmp.DecodePixelHeight = decodePixelHeight;
            bmp.UriSource = new Uri(path);
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch (Exception ex) { Log.Write("agent: thumbnail load failed \u2014 " + ex.Message); return null; }
    }

    private static void OpenFile(string path)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Write("agent: open attachment failed \u2014 " + ex.Message); }
    }

    private void RemoveAttachment(Attachment att, FrameworkElement chip)
    {
        _attachments.Remove(att);
        AttachTray.Children.Remove(chip);
        if (_attachments.Count == 0) AttachTrayScroll.Visibility = Visibility.Collapsed;
    }

    private void ClearAttachTray()
    {
        _attachments.Clear();
        AttachTray.Children.Clear();
        AttachTrayScroll.Visibility = Visibility.Collapsed;
    }

    private bool TryPasteImage()
    {
        try
        {
            // real text paste (incl. copied files that also carry text) → let the box handle it
            if (!Clipboard.ContainsImage() || Clipboard.ContainsText()) return false;
            var img = Clipboard.GetImage();
            if (img == null) return false;
            var dir = Path.Combine(Path.GetTempPath(), "Cleanup");
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, $"attach-{DateTime.Now:yyyyMMdd-HHmmss-fff}.png");
            using (var fs = new FileStream(file, FileMode.Create))
            {
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(img));
                enc.Save(fs);
            }
            AddAttachment(file);
            return true;
        }
        catch (Exception ex) { Log.Write("agent: paste image failed — " + ex.Message); return false; }
    }

    // ---------- drag & drop (subtle border highlight while hovering) ----------

    private void Root_DragEnter(object sender, DragEventArgs e) => Root_DragOver(sender, e);

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
            SetDragHighlight(true);
        }
        else e.Effects = DragDropEffects.None;
        e.Handled = true;
    }

    private void Root_DragLeave(object sender, DragEventArgs e)
    {
        // DragLeave also fires when crossing child elements — only clear when the
        // pointer is actually outside the window.
        var p = e.GetPosition(Root);
        if (p.X >= 0 && p.Y >= 0 && p.X <= Root.ActualWidth && p.Y <= Root.ActualHeight) return;
        SetDragHighlight(false);
    }

    private void Root_Drop(object sender, DragEventArgs e)
    {
        SetDragHighlight(false);
        if (e.Data.GetDataPresent(DataFormats.FileDrop) && e.Data.GetData(DataFormats.FileDrop) is string[] files)
            foreach (var f in files) AddAttachment(f);   // folders attach as-is
        e.Handled = true;
    }

    private void SetDragHighlight(bool on)
    {
        if (_dragHighlight == on) return;
        _dragHighlight = on;
        var to = on ? ((SolidColorBrush)_t.Accent).Color : ((SolidColorBrush)_t.LineStrong).Color;
        _borderBrush.BeginAnimation(SolidColorBrush.ColorProperty,
            new ColorAnimation(to, Anim.Ms(150)) { EasingFunction = Anim.EaseOut });
    }

    private void Submit()
    {
        var text = InputBox.Text.Trim();
        var atts = _attachments.ToList();
        // sending attachments alone (no text) is valid
        if (text.Length == 0 && atts.Count == 0) { System.Media.SystemSounds.Beep.Play(); return; }
        if (_recording) CancelRecordingForSubmit();

        InputBox.Clear();
        var display = text.Length == 0 ? "Look at the attached file(s)." : text;
        var bubbleImgs = atts.Where(a => a.IsImage).Select(a => a.Path).ToList();
        var bubbleDocs = atts.Where(a => !a.IsImage).Select(a => a.Name).ToList();
        AddUserBubble(display, bubbleDocs, bubbleImgs);
        ClearAttachTray();

        // selection-context block comes first, attachments block after it
        var task = display;
        if (_context != null)
        {
            task += "\n\nContext — the user had this text selected:\n" + _context;
            _context = null;
            Anim.OpacityTo(ContextPill, 0, 160);
            ContextPill.IsHitTestVisible = false;
        }

        // validate at send time — nonexistent paths are skipped with a dim note
        var valid = new List<string>();
        foreach (var a in atts)
        {
            if (File.Exists(a.Path) || Directory.Exists(a.Path)) valid.Add(a.Path);
            else AddToolLine("▸ skipped missing file: " + a.Name);
        }
        if (valid.Count > 0)
            task += "\n\nAttached files (read them before answering):\n" +
                    string.Join("\n", valid.Select(p => "- " + p));

        var images = valid.Where(IsImagePath).ToList();
        var attachDirs = valid.Select(p => Path.GetDirectoryName(p) ?? "")
                              .Where(d => d.Length > 0).Distinct().ToList();
        _ = RunTurn(task, images, attachDirs);
    }

    private async Task RunTurn(string task, IReadOnlyList<string> images, IReadOnlyList<string> attachDirs)
    {
        SetBusy(true);
        _curBubbleText = null;
        var cts = new CancellationTokenSource();
        _runCts = cts;
        try
        {
            await _engine.Run(_project, task, images, attachDirs,
                onText: s => Dispatcher.BeginInvoke(() => UpdateBubble(s)),
                onEvent: s => Dispatcher.BeginInvoke(() => AddToolLine(s)),
                cts.Token);
        }
        catch (OperationCanceledException) { AddToolLine("▸ stopped"); }
        catch (Exception ex) { AddErrorLine(ex.Message); }
        finally
        {
            if (ReferenceEquals(_runCts, cts)) _runCts = null;
            SetBusy(false);
            if (InputBox.IsEnabled) InputBox.Focus();
        }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        InputBox.IsEnabled = !busy;
        AttachBtn.IsEnabled = !busy;
        AttachBtn.Opacity = AttachBtn.IsEnabled ? 0.9 : 0.4;
        MicBtn.IsEnabled = !busy && MicAvailable && !_transcribing;
        MicBtn.Opacity = MicBtn.IsEnabled ? 0.9 : 0.4;
        // morph send ↔ stop (crossfade + a small scale pop)
        Anim.OpacityTo(SendGlyph, busy ? 0.0 : 1.0, 140);
        Anim.OpacityTo(StopGlyph, busy ? 1.0 : 0.0, 140);
        Anim.ScalePop(SendBtn, 1.12, 160);
        SendBtn.ToolTip = busy ? "Stop" : "Send  (Enter)";
        if (busy) { StartDot(); ShowThinking(); } else { StopDot(); HideThinking(); }
    }

    private void StartDot()
    {
        StatusDot.Visibility = Visibility.Visible;
        StatusDot.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.9, 0.25, Anim.Ms(700))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = Anim.EaseInOut,
        });
    }

    private void StopDot()
    {
        StatusDot.BeginAnimation(UIElement.OpacityProperty, null);
        StatusDot.Visibility = Visibility.Collapsed;
    }

    // ---------- voice ----------

    // Mic is usable if EITHER engine can serve it: the SAPI recognizer initialized, or the
    // Parakeet venv is installed and selected. Parakeet without SAPI is a valid config.
    private bool MicAvailable => _speech != null || VoiceEngine.ParakeetSelectedAndReady;

    private void InitSpeech()
    {
        try
        {
            _speech = new SpeechRecognitionEngine();
            _speech.SetInputToDefaultAudioDevice();
            _speech.LoadGrammar(new DictationGrammar());
            _speech.SpeechHypothesized += (_, e) => Dispatcher.BeginInvoke(() => OnHypothesis(e.Result.Text));
            _speech.SpeechRecognized += (_, e) => Dispatcher.BeginInvoke(() => OnRecognized(e.Result.Text));
        }
        catch (Exception ex)
        {
            _speech = null;
            Log.Write("agent: speech init failed — " + ex.Message);
        }
        // Only hard-disable the mic when NEITHER engine can serve it. When Parakeet is
        // available, the button stays live even though SAPI failed to init.
        if (!MicAvailable)
        {
            MicBtn.IsEnabled = false;
            MicBtn.Opacity = 0.4;
            MicBtn.ToolTip = "Voice input unavailable — no microphone or speech engine";
        }
    }

    private void Mic_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (!MicAvailable || _busy || _transcribing) return;
        if (_recording) StopRecording(); else StartRecording();
    }

    private void StartRecording()
    {
        _voiceBase = InputBox.Text.Length > 0 && !InputBox.Text.EndsWith(" ") ? InputBox.Text + " " : InputBox.Text;
        _voiceFinal = "";

        // Prefer Parakeet (record-then-transcribe) when selected AND ready; else SAPI.
        _usingParakeet = Settings.Current.VoiceASR == "parakeet" && VoiceEngine.ParakeetSelectedAndReady;
        if (_usingParakeet)
        {
            if (StartMciRecording())
            {
                _recording = true;
                RestyleMic();
                StartRecCap();
                return;
            }
            // recording device failed to open → surface + fall back to SAPI this toggle
            Log.Write("agent: MCI record start failed — falling back to SAPI");
            _usingParakeet = false;
        }

        if (_speech == null)
        {
            MicBtn.ToolTip = "Voice input unavailable — recording failed and no fallback recognizer";
            return;
        }
        _recording = true;
        RestyleMic();
        StartRecCap();
        try { _speech.RecognizeAsync(RecognizeMode.Multiple); }
        catch (Exception ex) { Log.Write("agent: RecognizeAsync failed — " + ex.Message); StopRecording(); }
    }

    private void StopRecording()
    {
        if (!_recording) return;
        _recording = false;
        StopRecCap();

        if (_usingParakeet)
        {
            RestyleMic();
            _ = FinishParakeet();   // async: save + close the wav, transcribe, insert
            return;
        }

        try { _speech?.RecognizeAsyncCancel(); } catch { }
        InputBox.Text = (_voiceBase + _voiceFinal).TrimEnd();   // drop any trailing hypothesis
        InputBox.Foreground = _t.Text;
        InputBox.CaretIndex = InputBox.Text.Length;
        RestyleMic();
        if (InputBox.IsEnabled) InputBox.Focus();
    }

    // Send while recording: discard the in-flight capture instead of transcribing after the
    // box is cleared (SAPI path just cancels; Parakeet path also drops the wav).
    private void CancelRecordingForSubmit()
    {
        if (!_recording) return;
        _recording = false;
        StopRecCap();
        if (_usingParakeet)
        {
            var wav = StopMciRecording();
            try { if (wav != null && File.Exists(wav)) File.Delete(wav); } catch { }
        }
        else { try { _speech?.RecognizeAsyncCancel(); } catch { } }
        RestyleMic();
    }

    // Parakeet finish: flip to the dim "transcribing…" state, save+close the wav, run it
    // through the local helper, and insert the text. On any failure the input is left as it
    // was (base text) and a mic tooltip explains — next toggle can fall back to SAPI.
    private async Task FinishParakeet()
    {
        _transcribing = true;
        SetMicTranscribing(true);
        string? wav = StopMciRecording();
        string? text = null;
        if (wav != null && File.Exists(wav))
        {
            try { text = await VoiceEngine.Transcribe(wav); }
            catch (Exception ex) { Log.Write("agent: transcribe failed — " + ex.Message); }
        }
        _transcribing = false;
        SetMicTranscribing(false);

        if (!string.IsNullOrWhiteSpace(text))
        {
            InputBox.Text = (_voiceBase + text!.Trim());
            InputBox.Foreground = _t.Text;
            InputBox.CaretIndex = InputBox.Text.Length;
            InputPlaceholder.Visibility = InputBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            MicBtn.ToolTip = "Couldn't transcribe — check Local voice in Settings, or try again";
            Log.Write("agent: parakeet transcription empty/failed");
        }
        try { if (wav != null && File.Exists(wav)) File.Delete(wav); } catch { }
        RestyleMic();
        if (InputBox.IsEnabled && !_busy) InputBox.Focus();
    }

    private void OnHypothesis(string h)
    {
        if (!_recording || _usingParakeet) return;
        InputBox.Text = _voiceBase + _voiceFinal + h;
        InputBox.Foreground = _t.Faint;   // dim = not yet final
        InputBox.CaretIndex = InputBox.Text.Length;
    }

    private void OnRecognized(string r)
    {
        if (!_recording || _usingParakeet) return;
        if (!string.IsNullOrWhiteSpace(r)) _voiceFinal += (_voiceFinal.Length > 0 ? " " : "") + r.Trim();
        InputBox.Text = _voiceBase + _voiceFinal;
        InputBox.Foreground = _t.Text;
        InputBox.CaretIndex = InputBox.Text.Length;
    }

    private void RestyleMic()
    {
        if (_recording)
        {
            MicBtn.Background = _t.Surface3;
            MicBtn.BorderBrush = _t.LineStrong;
            MicGlyph.Foreground = _t.Text;
            MicGlyph.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1.0, 0.4, Anim.Ms(600))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = Anim.EaseInOut,
            });
        }
        else
        {
            MicGlyph.BeginAnimation(UIElement.OpacityProperty, null);
            MicGlyph.Opacity = 1;
            MicBtn.Background = _t.Surface2;
            MicBtn.BorderBrush = _t.Line;
            MicGlyph.Foreground = _t.Muted;
        }
    }

    // Dim, non-pulsing, disabled state shown briefly between "stopped recording" and "text
    // inserted" while Parakeet transcribes.
    private void SetMicTranscribing(bool on)
    {
        if (on)
        {
            MicGlyph.BeginAnimation(UIElement.OpacityProperty, null);
            MicBtn.IsEnabled = false;
            MicBtn.Opacity = 0.5;
            MicGlyph.Foreground = _t.Faint;
            MicBtn.ToolTip = "transcribing…";
        }
        else
        {
            MicBtn.IsEnabled = !_busy && MicAvailable;
            MicBtn.Opacity = MicBtn.IsEnabled ? 0.9 : 0.4;
            MicBtn.ToolTip = "Voice input";
        }
    }

    // ---------- MCI (winmm) recording: 16k mono pcm16 wav — exactly what onnx-asr wants ----------

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    private static extern int mciSendString(string command, System.Text.StringBuilder? returnValue, int returnLength, IntPtr callback);

    // Open a waveaudio device, force 16 kHz / mono / 16-bit, and start recording. Returns
    // false (leaving nothing open) if any step fails.
    private bool StartMciRecording()
    {
        var alias = "cleanupcap";
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "Cleanup");
            Directory.CreateDirectory(dir);
            _recWavPath = Path.Combine(dir, $"voice-{DateTime.Now:yyyyMMdd-HHmmss-fff}.wav");
            if (Mci($"open new type waveaudio alias {alias}") != 0) return false;
            // 16k mono pcm16 (samplespersec 16000 · channels 1 · bitspersample 16;
            // bytespersec/alignment follow from those). Best-effort — recording still works
            // if a driver ignores a field.
            Mci($"set {alias} time format ms bitspersample 16 channels 1 samplespersec 16000 alignment 2 bytespersec 32000");
            if (Mci($"record {alias}") != 0) { Mci($"close {alias}"); return false; }
            _mciAlias = alias;
            return true;
        }
        catch (Exception ex)
        {
            Log.Write("agent: MCI start exception — " + ex.Message);
            try { Mci($"close {alias}"); } catch { }
            _mciAlias = null; _recWavPath = null;
            return false;
        }
    }

    // Stop + save + close the device. Returns the saved wav path, or null on failure.
    private string? StopMciRecording()
    {
        var alias = _mciAlias;
        var wav = _recWavPath;
        _mciAlias = null; _recWavPath = null;
        if (alias == null || wav == null) return null;
        try
        {
            Mci($"stop {alias}");
            int save = Mci($"save {alias} \"{wav}\"");
            Mci($"close {alias}");
            return save == 0 ? wav : null;
        }
        catch (Exception ex) { Log.Write("agent: MCI stop exception — " + ex.Message); return null; }
    }

    private static int Mci(string command)
    {
        int rc = mciSendString(command, null, 0, IntPtr.Zero);
        if (rc != 0) Log.Write($"agent: mci '{command}' rc={rc}");
        return rc;
    }

    // ~60s hard cap on a single recording so a forgotten mic doesn't record forever (and
    // Parakeet ASR stays snappy on a bounded clip). Applies to both engines.
    private void StartRecCap()
    {
        StopRecCap();
        _recCap = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        _recCap.Tick += (_, _) =>
        {
            StopRecCap();
            if (_recording) { Log.Write("agent: mic 60s auto-stop"); StopRecording(); }
        };
        _recCap.Start();
    }

    private void StopRecCap() { _recCap?.Stop(); _recCap = null; }

    // ---------- window chrome (borderless, resizable) — mirrors PopupWindow ----------

    private const int GWL_STYLE = -16;
    private const int WS_THICKFRAME = 0x00040000;
    private const int WM_NCHITTEST = 0x0084;
    private const int HTCLIENT = 1, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13,
                      HTTOPRIGHT = 14, HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out ScreenUtil.NativeRect r);

    private static readonly IntPtr HWND_TOP = IntPtr.Zero;
    private const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        SetWindowLong(h, GWL_STYLE, GetWindowLong(h, GWL_STYLE) | WS_THICKFRAME);
        HwndSource.FromHwnd(h)?.AddHook(WndProc);
        PositionNearAnchor(h);
    }

    private void PositionNearAnchor(IntPtr h)
    {
        uint dpi = ScreenUtil.DpiForPoint(_anchor.X, _anchor.Y);
        double s = dpi / 96.0;
        var wa = ScreenUtil.WorkAreaForPoint(_anchor.X, _anchor.Y);
        int cx = (int)Math.Round(Width * s);
        int cy = (int)Math.Round(Height * s);
        int pad = (int)Math.Round(8 * s);
        int x = _anchor.X - (int)Math.Round(40 * s);
        int y = _anchor.Y + (int)Math.Round(12 * s);
        x = Math.Max(wa.Left + pad, Math.Min(x, wa.Right - cx - pad));
        y = Math.Max(wa.Top + pad, Math.Min(y, wa.Bottom - cy - pad));
        SetWindowPos(h, HWND_TOP, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_NCHITTEST) { handled = true; return (IntPtr)HitTest(hwnd, lParam); }
        return IntPtr.Zero;
    }

    private int HitTest(IntPtr hwnd, IntPtr lParam)
    {
        if (!GetWindowRect(hwnd, out var r)) return HTCLIENT;
        int mx = (short)(lParam.ToInt32() & 0xFFFF);
        int my = (short)((lParam.ToInt32() >> 16) & 0xFFFF);
        uint dpi = ScreenUtil.DpiForPoint(mx, my);
        int b = (int)Math.Round(6 * dpi / 96.0);
        bool left = mx >= r.Left && mx < r.Left + b;
        bool right = mx <= r.Right - 1 && mx > r.Right - 1 - b;
        bool top = my >= r.Top && my < r.Top + b;
        bool bottom = my <= r.Bottom - 1 && my > r.Bottom - 1 - b;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
        return HTCLIENT;
    }

    private void SaveSize()
    {
        if (ActualWidth < MinWidth || ActualHeight < MinHeight) return;
        Settings.Current.AgentWidth = ActualWidth;
        Settings.Current.AgentHeight = ActualHeight;
        Settings.Current.Save();
    }

    // ---------- drag anywhere ----------

    private void Root_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (IsInteractive(e.OriginalSource as DependencyObject)) return;
        DragMove();
    }

    private bool IsInteractive(DependencyObject? src)
    {
        for (var d = src; d != null && d != Root; d = VisualTreeHelper.GetParent(d))
        {
            if (d is TextBoxBase or ScrollBar or Thumb) return true;
            if (ReferenceEquals(d, Transcript) || ReferenceEquals(d, InputBar) ||
                ReferenceEquals(d, CloseBtn) || ReferenceEquals(d, AttachBtn) ||
                ReferenceEquals(d, MicBtn) || ReferenceEquals(d, SendBtn) ||
                ReferenceEquals(d, ContextPill) || ReferenceEquals(d, AttachTrayScroll) ||
                ReferenceEquals(d, ProjectChip) || ReferenceEquals(d, NewSessionBtn) ||
                ReferenceEquals(d, HelpBtn) || ReferenceEquals(d, HelpOverlay))
                return true;
        }
        return false;
    }

    // ---------- lifecycle animation ----------

    private void PlayEntrance()
    {
        var (s, t) = Anim.Transforms(Root);
        s.ScaleX = s.ScaleY = 0.97;
        t.Y = 6;
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.97, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.97, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(6, 0, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
    }

    private void Close_Click(object sender, MouseButtonEventArgs e) { e.Handled = true; SafeClose(); }

    // ---------- help overlay ----------

    private bool _helpOpen;

    private void Help_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        ToggleHelp(!_helpOpen);
    }

    private void HelpOverlay_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        ToggleHelp(false);
    }

    private void HelpCard_Click(object sender, MouseButtonEventArgs e) => e.Handled = true;

    private void ToggleHelp(bool on)
    {
        if (on == _helpOpen) return;
        _helpOpen = on;
        if (on)
        {
            HelpSheet.Populate(HelpContent, _t, "Agent shortcuts", new (string, string)[]
            {
                ("attach · drag · paste", "attach files, a folder, or a pasted screenshot"),
                ("mic", "voice input (needs a microphone)"),
                ("project chip ▾", "switch or create a project (its folder is the agent's cwd)"),
                ("⊕", "start a fresh session in this project"),
                ("engine · model · tier", "set in Settings — safe reads only, standard edits, full no sandbox"),
                ("Enter · Shift+Enter", "send · newline"),
                ("Esc", "close the window"),
            });
            HelpOverlay.Opacity = 0;
            HelpOverlay.Visibility = Visibility.Visible;
            Anim.OpacityTo(HelpOverlay, 1.0, 120);
            Anim.FadeSlideIn(HelpCard, 8, 160);
        }
        else
        {
            var fade = new DoubleAnimation(0, Anim.Ms(120)) { EasingFunction = Anim.EaseOut };
            fade.Completed += (_, _) => { if (!_helpOpen) HelpOverlay.Visibility = Visibility.Collapsed; };
            HelpOverlay.BeginAnimation(UIElement.OpacityProperty, fade);
        }
    }

    // Idempotent animated close; also kills any in-flight run (Closed → Cleanup does
    // the same, so an already-torn-down window is safe).
    public void SafeClose()
    {
        if (_closeRequested) return;
        _closeRequested = true;
        _runCts?.Cancel();
        var (s, _) = Anim.Transforms(Root);
        var fade = new DoubleAnimation(0, Anim.Ms(120)) { EasingFunction = Anim.EaseOut };
        fade.Completed += (_, _) => { try { Close(); } catch { } };
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        BeginAnimation(OpacityProperty, fade);
    }

    private void Cleanup()
    {
        try { _runCts?.Cancel(); } catch { }
        try { StopRecCap(); } catch { }
        // close any in-flight MCI capture (Parakeet path) so the device isn't left open
        try
        {
            if (_mciAlias != null)
            {
                var wav = StopMciRecording();
                if (wav != null && File.Exists(wav)) File.Delete(wav);
            }
        }
        catch { }
        try { if (_recording && !_usingParakeet) _speech?.RecognizeAsyncCancel(); } catch { }
        try { _speech?.Dispose(); } catch { }
        _speech = null;
        // Note: the VoiceEngine helper process is app-global and killed on app exit
        // (AppController.Dispose → VoiceEngine.Shutdown), not per-window.
    }

    // ---------- micro-interactions (shared with the popup's feel) ----------

    private static void WireButton(Border b, double baseOp)
    {
        b.Opacity = baseOp;
        b.MouseEnter += (_, _) => Anim.OpacityTo(b, 1.0, 100);
        b.MouseLeave += (_, _) => { Anim.OpacityTo(b, baseOp, 120); Anim.ScaleTo(b, 1.0, 90); };
        b.PreviewMouseLeftButtonDown += (_, _) => Anim.ScaleTo(b, 0.95, 80);
        b.PreviewMouseLeftButtonUp += (_, _) => Anim.ScaleTo(b, 1.0, 90);
    }
}
