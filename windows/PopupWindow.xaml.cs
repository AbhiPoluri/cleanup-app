using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace Cleanup;

public partial class PopupWindow : Window
{
    private readonly string _original;
    private readonly IntPtr _targetHwnd;
    private readonly Theme _t = Theme.Detect();
    private static readonly string[] Tones = { "Clean", "Professional", "Casual", "Blunt" };

    private string _tone;
    private int _count;
    private int _selected;
    private string?[] _results = Array.Empty<string?>();   // null = loading
    private string?[] _errors = Array.Empty<string?>();
    private readonly List<CancellationTokenSource> _cts = new();
    private readonly List<Border> _chipBorders = new();
    private TextBox? _customToneBox;
    private bool _refining;

    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
    private struct POINT { public int X, Y; }

    public PopupWindow(string original, IntPtr targetHwnd)
    {
        _original = original;
        _targetHwnd = targetHwnd;
        _tone = Settings.Current.DefaultTone;
        _count = Math.Clamp(Settings.Current.DefaultCount, 1, 5);

        InitializeComponent();
        ApplyTheme();
        BuildChips();
        VariantSlider.Value = _count;
        ModelLabel.Text = Settings.Current.ModelLabel + " ▾";
        ModelChip.MouseLeftButtonUp += (_, _) => AppController.OpenSettings();
        RefineBox.TextChanged += (_, _) =>
            RefinePlaceholder.Visibility = RefineBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        Deactivated += (_, _) => { if (!Program.TestMode) Close(); };
        Closed += (_, _) => CancelAll();
        PreviewKeyDown += OnPreviewKeyDown;
        Loaded += (_, _) => PositionNearCursor();

        GenerateAll();
    }

    // ---------- theming ----------

    private void ApplyTheme()
    {
        Root.Background = _t.Surface;
        Root.BorderBrush = _t.LineStrong;
        TitleLabel.Foreground = _t.Muted;
        ModelChip.BorderBrush = _t.Line;
        ModelLabel.Foreground = _t.Faint;
        VariantsLabel.Foreground = _t.Faint;
        CountLabel.Foreground = _t.Text;
        ModeHint.Foreground = _t.Faint;
        HintLabel.Foreground = _t.Faint;
        CopyBtn.BorderBrush = _t.LineStrong;
        CopyLabel.Foreground = _t.Muted;
        ReplaceBtn.Background = _t.Accent;
        ReplaceLabel.Foreground = _t.OnAccent;
        RefineBorder.Background = _t.Surface2;
        RefineBorder.BorderBrush = _t.LineStrong;
        RefineBox.Foreground = _t.Text;
        RefineBox.CaretBrush = _t.Text;
        RefinePlaceholder.Foreground = _t.Faint;
        RefineStatus.Foreground = _t.Muted;
    }

    private void PositionNearCursor()
    {
        GetCursorPos(out var p);
        var src = PresentationSource.FromVisual(this);
        double scale = src?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        double x = p.X / scale - 40, y = p.Y / scale + 12;
        var wa = SystemParameters.WorkArea;
        Left = Math.Max(wa.Left + 8, Math.Min(x, wa.Right - Width - 8));
        Top = Math.Max(wa.Top + 8, Math.Min(y, wa.Bottom - Height - 8));
    }

    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left) DragMove();
    }

    // ---------- chips ----------

    private void BuildChips()
    {
        ChipsPanel.Children.Clear();
        _chipBorders.Clear();
        foreach (var tone in Tones)
        {
            var label = new TextBlock { Text = tone, FontSize = 12 };
            var chip = new Border
            {
                Child = label,
                // WPF doesn't clamp oversized radii like CSS — anything over half the
                // chip height renders as an oval, so this must stay ≈ height/2
                CornerRadius = new CornerRadius(13),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12, 4, 12, 4),
                Margin = new Thickness(0, 0, 6, 0),
                Cursor = Cursors.Hand,
                Tag = tone,
            };
            chip.MouseLeftButtonUp += (_, _) => { SetTone(tone); };
            _chipBorders.Add(chip);
            ChipsPanel.Children.Add(chip);
        }

        _customToneBox = new TextBox
        {
            FontSize = 12,
            Width = 110,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = _t.Text,
            CaretBrush = _t.Text,
        };
        _customToneBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !string.IsNullOrWhiteSpace(_customToneBox.Text))
                SetTone(_customToneBox.Text.Trim());
        };
        var custom = new Border
        {
            Child = _customToneBox,
            CornerRadius = new CornerRadius(13),
            BorderThickness = new Thickness(1),
            BorderBrush = _t.LineStrong,
            Padding = new Thickness(10, 3, 10, 3),
        };
        ChipsPanel.Children.Add(custom);
        RestyleChips();
    }

    private void RestyleChips()
    {
        foreach (var chip in _chipBorders)
        {
            bool on = (string)chip.Tag == _tone;
            chip.Background = on ? _t.Surface3 : _t.Surface2;
            chip.BorderBrush = on ? _t.LineStrong : _t.Line;
            var label = (TextBlock)chip.Child;
            label.Foreground = on ? _t.Text : _t.Muted;
            label.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
        }
    }

    private void SetTone(string tone)
    {
        if (tone == _tone) return;
        _tone = tone;
        RestyleChips();
        GenerateAll();
    }

    // ---------- slider ----------

    private DispatcherTimer? _sliderDebounce;

    private void Slider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        int n = (int)Math.Round(e.NewValue);
        if (CountLabel != null) CountLabel.Text = n.ToString();
        if (ModeHint != null) ModeHint.Text = n == 1 ? "single rewrite" : "pick a card";
        if (n == _count) return;
        // debounce so dragging across ticks doesn't fire a request per tick
        _sliderDebounce?.Stop();
        _sliderDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        _sliderDebounce.Tick += (_, _) =>
        {
            _sliderDebounce!.Stop();
            _count = n;
            Settings.Current.DefaultCount = n;
            Settings.Current.Save();
            GenerateAll();
        };
        _sliderDebounce.Start();
    }

    // ---------- generation ----------

    private void CancelAll()
    {
        foreach (var c in _cts) c.Cancel();
        _cts.Clear();
        _refining = false;
        RefineStatus.Text = "↵";
    }

    private void GenerateAll()
    {
        CancelAll();
        _results = new string?[_count];
        _errors = new string?[_count];
        _selected = 0;
        RebuildCards();
        for (int i = 0; i < _count; i++)
        {
            int idx = i;
            var cts = new CancellationTokenSource();
            _cts.Add(cts);
            _ = RunVariant(idx, cts.Token);
        }
    }

    private async Task RunVariant(int idx, CancellationToken ct)
    {
        try
        {
            var text = await Llm.Complete(Prompts.System, Prompts.Variant(_original, _tone, idx), ct);
            if (ct.IsCancellationRequested) return;
            _results[idx] = text;
        }
        catch (Exception ex)
        {
            if (ct.IsCancellationRequested) return;
            _errors[idx] = ex.Message;
        }
        Dispatcher.Invoke(RebuildCards);
    }

    private void RefineBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var instruction = RefineBox.Text.Trim();
        var current = _selected < _results.Length ? _results[_selected] : null;
        if (instruction.Length == 0 || current == null || _refining) return;
        RefineBox.Text = "";
        _refining = true;
        RefineStatus.Text = "…";
        int idx = _selected;
        var cts = new CancellationTokenSource();
        _cts.Add(cts);
        _ = Task.Run(async () =>
        {
            try
            {
                var text = await Llm.Complete(Prompts.System, Prompts.Refine(current, instruction), cts.Token);
                if (!cts.Token.IsCancellationRequested) _results[idx] = text;
            }
            catch (Exception ex)
            {
                if (!cts.Token.IsCancellationRequested) _errors[idx] = ex.Message;
            }
            Dispatcher.Invoke(() =>
            {
                _refining = false;
                RefineStatus.Text = "↵";
                RebuildCards();
            });
        });
    }

    // ---------- cards ----------

    private void RebuildCards()
    {
        CardsPanel.Children.Clear();
        for (int i = 0; i < _count; i++)
        {
            int idx = i;
            bool sel = idx == _selected;

            var content = new StackPanel();
            if (_errors[idx] != null)
            {
                content.Children.Add(new TextBlock
                {
                    Text = "⚠ " + _errors[idx] + " — check Settings",
                    FontSize = 12,
                    Foreground = _t.Muted,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else if (_results[idx] == null)
            {
                content.Children.Add(new TextBlock
                {
                    Text = "writing…",
                    FontSize = 12,
                    Foreground = _t.Faint,
                });
            }
            else
            {
                content.Children.Add(new TextBlock
                {
                    Text = _results[idx],
                    FontSize = 13,
                    Foreground = _t.Text,
                    TextWrapping = TextWrapping.Wrap,
                });
                if (_count > 1)
                {
                    content.Children.Add(new TextBlock
                    {
                        Text = Prompts.Styles[idx % Prompts.Styles.Length].Label,
                        FontSize = 10,
                        FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                        Foreground = _t.Faint,
                        Margin = new Thickness(0, 4, 0, 0),
                    });
                }
            }

            var numBadge = new Border
            {
                Child = new TextBlock
                {
                    Text = (idx + 1).ToString(),
                    FontSize = 10,
                    FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                    Foreground = sel ? _t.Text : _t.Faint,
                },
                BorderBrush = sel ? _t.LineStrong : _t.Line,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(0, 2, 10, 0),
                VerticalAlignment = VerticalAlignment.Top,
            };

            var row = new DockPanel();
            DockPanel.SetDock(numBadge, Dock.Left);
            row.Children.Add(numBadge);
            row.Children.Add(content);

            var card = new Border
            {
                Child = row,
                Background = sel ? _t.Surface3 : _t.Surface2,
                BorderBrush = sel ? _t.Accent : _t.Line,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(11),
                Margin = new Thickness(0, 0, 0, 8),
                Cursor = Cursors.Hand,
            };
            card.MouseLeftButtonUp += (_, _) => SelectCard(idx);
            CardsPanel.Children.Add(card);
        }
    }

    private void SelectCard(int i)
    {
        if (i < 0 || i >= _count) return;
        _selected = i;
        RebuildCards();
    }

    // ---------- actions ----------

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { Close(); e.Handled = true; return; }
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        switch (e.Key)
        {
            case Key.Enter: DoReplace(); e.Handled = true; break;
            case Key.R: GenerateAll(); e.Handled = true; break;
            case >= Key.D1 and <= Key.D5:
                SelectCard(e.Key - Key.D1); e.Handled = true; break;
        }
    }

    private void Copy_Click(object sender, MouseButtonEventArgs e) => DoCopy();
    private void Replace_Click(object sender, MouseButtonEventArgs e) => DoReplace();

    private void DoCopy()
    {
        var text = _selected < _results.Length ? _results[_selected] : null;
        if (text == null) { System.Media.SystemSounds.Beep.Play(); return; }
        try { Clipboard.SetText(text); } catch { }
        Close();
    }

    private async void DoReplace()
    {
        var text = _selected < _results.Length ? _results[_selected] : null;
        if (text == null) { System.Media.SystemSounds.Beep.Play(); return; }
        var hwnd = _targetHwnd;
        Close();
        await Capture.PasteInto(hwnd, text);
    }
}
