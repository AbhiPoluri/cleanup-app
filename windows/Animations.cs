using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Cleanup;

// Mono-legal motion helpers. Everything here animates ONLY Opacity and
// RenderTransform (scale / translate) — never layout (Width/Height/Margin) and
// never a hue. Easing functions are frozen and shared; per-element animations
// are cheap throwaways.
internal static class Anim
{
    public static readonly QuadraticEase EaseOut = Frozen(new QuadraticEase { EasingMode = EasingMode.EaseOut });
    public static readonly QuadraticEase EaseInOut = Frozen(new QuadraticEase { EasingMode = EasingMode.EaseInOut });

    private static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }
    public static Duration Ms(double m) => new Duration(TimeSpan.FromMilliseconds(m));

    // Installs (once) a TransformGroup = [ScaleTransform, TranslateTransform] with
    // a centred origin, and hands back the two transforms for animation.
    public static (ScaleTransform s, TranslateTransform t) Transforms(FrameworkElement e)
    {
        if (e.RenderTransform is TransformGroup g && g.Children.Count == 2 &&
            g.Children[0] is ScaleTransform s0 && g.Children[1] is TranslateTransform t0)
            return (s0, t0);

        var s = new ScaleTransform(1, 1);
        var t = new TranslateTransform(0, 0);
        var grp = new TransformGroup();
        grp.Children.Add(s);
        grp.Children.Add(t);
        e.RenderTransformOrigin = new Point(0.5, 0.5);
        e.RenderTransform = grp;
        return (s, t);
    }

    // Fade in from 0 while translating up from +dy → 0.
    public static void FadeSlideIn(FrameworkElement e, double dy, double ms, double beginMs = 0)
    {
        var (_, t) = Transforms(e);
        e.Opacity = 0;
        t.Y = dy;
        var begin = TimeSpan.FromMilliseconds(beginMs);
        e.BeginAnimation(UIElement.OpacityProperty,
            new DoubleAnimation(0, 1, Ms(ms)) { EasingFunction = EaseOut, BeginTime = begin });
        t.BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(dy, 0, Ms(ms)) { EasingFunction = EaseOut, BeginTime = begin });
    }

    // Quick "pop": scale up to peak then settle back to 1.
    public static void ScalePop(FrameworkElement e, double peak = 1.06, double ms = 140)
    {
        var (s, _) = Transforms(e);
        var a = new DoubleAnimationUsingKeyFrames { Duration = Ms(ms) };
        a.KeyFrames.Add(new EasingDoubleKeyFrame(peak, KeyTime.FromPercent(0.5), EaseOut));
        a.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromPercent(1.0), EaseOut));
        s.BeginAnimation(ScaleTransform.ScaleXProperty, a);
        s.BeginAnimation(ScaleTransform.ScaleYProperty, a.Clone());
    }

    // Scale toward a target (press-down / release).
    public static void ScaleTo(FrameworkElement e, double to, double ms = 90)
    {
        var (s, _) = Transforms(e);
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(to, Ms(ms)) { EasingFunction = EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(to, Ms(ms)) { EasingFunction = EaseOut });
    }

    public static void OpacityTo(UIElement e, double to, double ms = 100)
        => e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(to, Ms(ms)) { EasingFunction = EaseOut });

    // Dip opacity down to `low` then back to 1 — a single "refresh" flash.
    public static void Dip(UIElement e, double low = 0.4, double ms = 300)
    {
        var a = new DoubleAnimationUsingKeyFrames { Duration = Ms(ms) };
        a.KeyFrames.Add(new EasingDoubleKeyFrame(low, KeyTime.FromPercent(0.3), EaseOut));
        a.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromPercent(1.0), EaseOut));
        e.BeginAnimation(UIElement.OpacityProperty, a);
    }
}

// Three dots pulsing in a staggered opacity loop, theme text colour. The ONLY
// repeating animation in the app — Stop() fully tears the loops down (no leaked
// clocks) so it must be called before the panel is discarded.
internal sealed class LoadingDots : StackPanel
{
    private readonly Ellipse[] _dots = new Ellipse[3];
    private bool _running;

    public LoadingDots(Brush color, double size = 5, double gap = 5)
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        for (int i = 0; i < 3; i++)
        {
            var e = new Ellipse
            {
                Width = size,
                Height = size,
                Fill = color,
                Opacity = 0.22,
                Margin = new Thickness(0, 0, i < 2 ? gap : 0, 0),
            };
            _dots[i] = e;
            Children.Add(e);
        }
    }

    public void Start()
    {
        if (_running) return;
        _running = true;
        for (int i = 0; i < 3; i++)
        {
            var a = new DoubleAnimation(0.22, 0.9, Anim.Ms(520))
            {
                BeginTime = TimeSpan.FromMilliseconds(i * 150),
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = Anim.EaseInOut,
            };
            _dots[i].BeginAnimation(UIElement.OpacityProperty, a);
        }
    }

    public void Stop()
    {
        if (!_running) return;
        _running = false;
        foreach (var d in _dots)
        {
            d.BeginAnimation(UIElement.OpacityProperty, null);   // detaches the clock
            d.Opacity = 0.22;
        }
    }
}

internal enum CardState { Fresh, RefineLoading, Done, Error }

// A single variant card that updates in place (rather than being torn down and
// rebuilt), so its state changes can crossfade and its selection ring can
// animate. Selection/hover is a single overlay Border whose opacity animates:
// 0 = idle, ~0.4 = hover, 1 = selected. The overlay carries the Surface3 fill +
// Accent ring, so both track together via one opacity animation.
internal sealed class VariantCard
{
    public readonly Border Root;
    private readonly Border _sel;
    private readonly Border _badge;
    private readonly TextBlock _badgeText;
    private readonly StackPanel _doneStack;
    private readonly TextBlock _text;
    private readonly TextBlock _styleLabel;
    private readonly LoadingDots _dots;
    private readonly TextBlock _error;
    private readonly Theme _t;

    private CardState _state = CardState.Fresh;
    private bool _selected;
    private bool _hover;

    public VariantCard(int index, Theme t, Action<int> onSelect)
    {
        _t = t;

        _text = new TextBlock { FontSize = 13, Foreground = t.Text, TextWrapping = TextWrapping.Wrap };
        _styleLabel = new TextBlock
        {
            FontSize = 10,
            FontFamily = new FontFamily("Consolas"),
            Foreground = t.Faint,
            Margin = new Thickness(0, 4, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        _doneStack = new StackPanel { Visibility = Visibility.Collapsed };
        _doneStack.Children.Add(_text);
        _doneStack.Children.Add(_styleLabel);

        _dots = new LoadingDots(t.Text) { Margin = new Thickness(1, 3, 0, 3) };
        _error = new TextBlock
        {
            FontSize = 12,
            Foreground = t.Muted,
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };

        var content = new StackPanel();
        content.Children.Add(_doneStack);
        content.Children.Add(_dots);
        content.Children.Add(_error);

        _badgeText = new TextBlock
        {
            Text = (index + 1).ToString(),
            FontSize = 10,
            FontFamily = new FontFamily("Consolas"),
            Foreground = t.Faint,
        };
        _badge = new Border
        {
            Child = _badgeText,
            BorderBrush = t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(5, 1, 5, 1),
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Top,
        };

        var row = new DockPanel { Margin = new Thickness(11) };
        DockPanel.SetDock(_badge, Dock.Left);
        row.Children.Add(_badge);
        row.Children.Add(content);

        _sel = new Border
        {
            Background = t.Surface3,
            BorderBrush = t.Accent,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(9),
            Opacity = 0,
        };

        var grid = new Grid();
        grid.Children.Add(_sel);
        grid.Children.Add(row);

        Root = new Border
        {
            Child = grid,
            Background = t.Surface2,
            BorderBrush = t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(9),
            Margin = new Thickness(0, 0, 0, 8),
            Cursor = Cursors.Hand,
        };
        Root.MouseLeftButtonUp += (_, _) => onSelect(index);
        Root.MouseEnter += (_, _) => Hover(true);
        Root.MouseLeave += (_, _) => Hover(false);
    }

    public void EnterFresh()
    {
        _state = CardState.Fresh;
        _doneStack.Visibility = Visibility.Collapsed;
        _error.Visibility = Visibility.Collapsed;
        _dots.Visibility = Visibility.Visible;
        _dots.Start();
    }

    public void SetSelected(bool sel, bool animate)
    {
        _selected = sel;
        _badgeText.Foreground = sel ? _t.Text : _t.Faint;
        _badgeText.FontWeight = sel ? FontWeights.SemiBold : FontWeights.Normal;
        _badge.BorderBrush = sel ? _t.LineStrong : _t.Line;
        double target = sel ? 1.0 : (_hover ? 0.4 : 0.0);
        if (animate)
            Anim.OpacityTo(_sel, target, 120);
        else
        {
            _sel.BeginAnimation(UIElement.OpacityProperty, null);
            _sel.Opacity = target;
        }
    }

    private void Hover(bool on)
    {
        _hover = on;
        if (_selected) return;
        Anim.OpacityTo(_sel, on ? 0.4 : 0.0, 100);
    }

    // Refine in flight: keep the current text but dim it and pulse the dots.
    public void ShowRefineLoading()
    {
        if (_state != CardState.Done) return;
        _state = CardState.RefineLoading;
        _dots.Visibility = Visibility.Visible;
        _dots.Start();
        Anim.OpacityTo(_doneStack, 0.35, 120);
    }

    public void SetDone(string text, string? styleLabel)
    {
        _dots.Stop();
        _dots.Visibility = Visibility.Collapsed;
        _error.Visibility = Visibility.Collapsed;

        _text.Text = text;
        _styleLabel.Text = styleLabel ?? "";
        _styleLabel.Visibility = styleLabel != null ? Visibility.Visible : Visibility.Collapsed;

        double from = _state == CardState.RefineLoading ? 0.35 : 0.0;
        _state = CardState.Done;
        _doneStack.Visibility = Visibility.Visible;

        var (_, t) = Anim.Transforms(_doneStack);
        _doneStack.BeginAnimation(UIElement.OpacityProperty,
            new DoubleAnimation(from, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        t.Y = 4;
        t.BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(4, 0, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
    }

    public void SetError(string msg)
    {
        _dots.Stop();
        _dots.Visibility = Visibility.Collapsed;
        _doneStack.Visibility = Visibility.Collapsed;
        _state = CardState.Error;
        _error.Text = "⚠ " + msg + " — check Settings";
        _error.Visibility = Visibility.Visible;
        _error.Opacity = 0;
        Anim.OpacityTo(_error, 1, 140);
    }

    public void StopDots() => _dots.Stop();
}
