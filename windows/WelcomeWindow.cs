using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Cleanup;

// First-run welcome (and reopenable "Welcome & health…" from the tray). One screen,
// not a wizard: what the app does + the trigger keys, then an embedded compact Health
// checklist so any broken dependency is visible up front. Mono theme, borderless with
// the same entrance animation as the popup. "Get started" sets Settings.DidOnboard.
public sealed class WelcomeWindow : Window
{
    private readonly Theme _t = Theme.Detect();
    private readonly Border _root;
    private readonly StackPanel _healthPanel;
    private bool _closeRequested;
    // Polls the cheap health rows every ~2s while the welcome screen is open, so a
    // permission/hotkey change flips its row without re-running the CLI probes.
    private System.Windows.Threading.DispatcherTimer? _healthPoll;

    public WelcomeWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Title = "Welcome to Cleanup";

        var content = new StackPanel { Width = 460, Margin = new Thickness(24, 20, 24, 20) };

        // ---- header (draggable) ----
        var header = new StackPanel { Cursor = Cursors.SizeAll };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(new TextBlock
        {
            Text = "✦  Cleanup",
            FontSize = 22,
            FontWeight = FontWeights.Bold,
            Foreground = _t.Text,
        });
        titleRow.Children.Add(new TextBlock
        {
            Text = "  " + Updater.DisplayVersion,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            Foreground = _t.Faint,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 3),
        });
        header.Children.Add(titleRow);
        header.Children.Add(new TextBlock
        {
            Text = "Clean up any text, or hand a task to an agent — from any app.",
            FontSize = 12.5,
            Foreground = _t.Muted,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0),
        });
        header.MouseLeftButtonDown += (_, e) => { if (e.ChangedButton == MouseButton.Left) DragMove(); };
        content.Children.Add(header);

        // ---- feature lines ----
        var s = Settings.Current;
        var features = new StackPanel { Margin = new Thickness(0, 16, 0, 4) };
        features.Children.Add(Feature("✦", "Clean up",
            $"select text, then {s.HotkeyDisplay} (or the ✦ button) for rewrite variants"));
        features.Children.Add(Feature("", "Instant",
            $"{s.HotkeyDisplay2} (or the instant button) rewrites in place — no popup", iconFont: true));
        features.Children.Add(Feature("", "Agent",
            "the agent button opens an agent that can read files and run tasks", iconFont: true));
        features.Children.Add(Feature("", "Snip",
            "screenshot a region straight into the agent", iconFont: true));
        content.Children.Add(features);

        content.Children.Add(new Border
        {
            Height = 1,
            Background = _t.Line,
            Margin = new Thickness(0, 14, 0, 12),
        });

        // ---- embedded health checklist ----
        content.Children.Add(new TextBlock
        {
            Text = "Setup check",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = _t.Text,
            Margin = new Thickness(0, 0, 0, 8),
        });
        _healthPanel = new StackPanel();
        _healthPanel.Children.Add(new TextBlock
        {
            Text = "checking…",
            FontSize = 11,
            Foreground = _t.Faint,
        });
        content.Children.Add(_healthPanel);

        // ---- get started ----
        var startLabel = new TextBlock
        {
            Text = "Get started",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = _t.OnAccent,
        };
        var startBtn = new Border
        {
            Child = startLabel,
            Background = _t.Accent,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(18, 8, 18, 8),
            Margin = new Thickness(0, 18, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            Cursor = Cursors.Hand,
        };
        WireButton(startBtn, 1.0);
        startBtn.MouseLeftButtonUp += (_, e) => { e.Handled = true; SafeClose(); };
        content.Children.Add(startBtn);

        _root = new Border
        {
            Child = content,
            Background = _t.Surface,
            BorderBrush = _t.LineStrong,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
        };
        Content = _root;

        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { e.Handled = true; SafeClose(); } };
        Opacity = 0;
        Loaded += (_, _) => PlayEntrance();

        _ = LoadHealth();

        _healthPoll = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _healthPoll.Tick += (_, _) =>
        {
            var rows = Health.RefreshCheapRows();
            if (rows != null)
                HealthView.Render(_healthPanel, rows,
                    titleBrush: _t.Text, mutedBrush: _t.Muted,
                    fixBrush: _t.Muted, fixBorderBrush: _t.Line, compact: true);
        };
        _healthPoll.Start();
        Closed += (_, _) => _healthPoll?.Stop();
    }

    private FrameworkElement Feature(string glyph, string name, string detail, bool iconFont = false)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 9) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var g = new TextBlock
        {
            Text = glyph,
            FontSize = iconFont ? 13 : 14,
            Foreground = _t.Text,
            VerticalAlignment = VerticalAlignment.Top,
        };
        // Segoe Fluent Icons glyph (monochrome) for the icon features; ✦ stays text.
        if (iconFont) g.FontFamily = new FontFamily("Segoe Fluent Icons,Segoe MDL2 Assets");
        Grid.SetColumn(g, 0);
        grid.Children.Add(g);

        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12.5 };
        text.Inlines.Add(new System.Windows.Documents.Run(name + " — ")
        { FontWeight = FontWeights.SemiBold, Foreground = _t.Text });
        text.Inlines.Add(new System.Windows.Documents.Run(detail) { Foreground = _t.Muted });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        return grid;
    }

    private async System.Threading.Tasks.Task LoadHealth()
    {
        try
        {
            var rows = await Health.GetRowsAsync();
            HealthView.Render(_healthPanel, rows,
                titleBrush: _t.Text, mutedBrush: _t.Muted,
                fixBrush: _t.Muted, fixBorderBrush: _t.Line, compact: true);
        }
        catch
        {
            _healthPanel.Children.Clear();
            _healthPanel.Children.Add(new TextBlock
            {
                Text = "couldn't run the setup check — open Settings → Health to retry",
                FontSize = 11,
                Foreground = _t.Faint,
                TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    private void PlayEntrance()
    {
        var (sc, tr) = Anim.Transforms(_root);
        sc.ScaleX = sc.ScaleY = 0.97;
        tr.Y = 6;
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        sc.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.97, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        sc.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.97, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        tr.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(6, 0, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
    }

    // Idempotent animated close; marks onboarding done so it never nags again (the
    // tray item reopens it on demand).
    public void SafeClose()
    {
        if (_closeRequested) return;
        _closeRequested = true;
        if (!Settings.Current.DidOnboard)
        {
            Settings.Current.DidOnboard = true;
            try { Settings.Current.Save(); } catch { }
        }
        var (sc, _) = Anim.Transforms(_root);
        var fade = new DoubleAnimation(0, Anim.Ms(120)) { EasingFunction = Anim.EaseOut };
        fade.Completed += (_, _) => { try { Close(); } catch { } };
        sc.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        sc.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        BeginAnimation(OpacityProperty, fade);
    }

    private static void WireButton(Border b, double baseOp)
    {
        b.Opacity = baseOp;
        b.MouseEnter += (_, _) => Anim.OpacityTo(b, 1.0, 100);
        b.MouseLeave += (_, _) => { Anim.OpacityTo(b, baseOp, 120); Anim.ScaleTo(b, 1.0, 90); };
        b.PreviewMouseLeftButtonDown += (_, _) => Anim.ScaleTo(b, 0.95, 80);
        b.PreviewMouseLeftButtonUp += (_, _) => Anim.ScaleTo(b, 1.0, 90);
    }
}
