using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Cleanup;

// Small mono prompt for creating / editing a project: a name field + an optional
// multiline brief. Built in code (no XAML partial) so it can be spun up from anywhere.
// In edit mode the name is shown read-only (renaming would re-slug the dir).
public sealed class ProjectDialog : Window
{
    private readonly TextBox _name;
    private readonly TextBox _brief;

    public string ProjectName => _name.Text.Trim();
    public string Brief => _brief.Text.Trim();

    public ProjectDialog(Window owner, string title, string name, string brief, bool editMode)
    {
        var t = Theme.Detect();
        Owner = owner;
        Title = title;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        SizeToContent = SizeToContent.Height;
        Width = 360;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;

        var root = new Border
        {
            Background = t.Surface,
            BorderBrush = t.LineStrong,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(18, 16, 18, 14),
        };
        root.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) DragMove(); };

        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = title,
            Foreground = t.Text,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 12),
        });

        stack.Children.Add(Caption("Name", t));
        _name = Field(t, name);
        _name.IsReadOnly = editMode;
        _name.Opacity = editMode ? 0.6 : 1.0;
        stack.Children.Add(Wrap(_name, t));

        stack.Children.Add(Caption("Brief (optional)", t));
        _brief = Field(t, brief);
        _brief.AcceptsReturn = true;
        _brief.TextWrapping = TextWrapping.Wrap;
        _brief.Height = 68;
        _brief.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        _brief.VerticalContentAlignment = VerticalAlignment.Top;
        stack.Children.Add(Wrap(_brief, t));

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 6, 0, 0),
        };
        var cancel = Btn("Cancel", t, accent: false);
        cancel.MouseLeftButtonUp += (_, _) => { DialogResult = false; Close(); };
        var ok = Btn(editMode ? "Save" : "Create", t, accent: true);
        ok.MouseLeftButtonUp += (_, _) => Confirm(editMode);
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        stack.Children.Add(buttons);

        root.Child = stack;
        Content = root;

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { DialogResult = false; Close(); }
            else if (e.Key == Key.Enter && !ReferenceEquals(Keyboard.FocusedElement, _brief)) Confirm(editMode);
        };
        Loaded += (_, _) => { if (!editMode) _name.Focus(); else _brief.Focus(); };
    }

    private void Confirm(bool editMode)
    {
        if (!editMode && ProjectName.Length == 0) { _name.Focus(); System.Media.SystemSounds.Beep.Play(); return; }
        DialogResult = true;
        Close();
    }

    private static TextBlock Caption(string text, Theme t) => new()
    {
        Text = text, Foreground = t.Faint, FontSize = 11, Margin = new Thickness(0, 0, 0, 3),
    };

    private static TextBox Field(Theme t, string initial) => new()
    {
        Text = initial ?? "",
        Foreground = t.Text,
        CaretBrush = t.Text,
        FontSize = 13,
        Background = Brushes.Transparent,
        BorderThickness = new Thickness(0),
    };

    private static Border Wrap(TextBox box, Theme t) => new()
    {
        Child = box,
        Background = t.Surface2,
        BorderBrush = t.Line,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(9, 6, 9, 6),
        Margin = new Thickness(0, 0, 0, 12),
    };

    private static Border Btn(string label, Theme t, bool accent)
    {
        var tb = new TextBlock
        {
            Text = label,
            FontSize = 12,
            Foreground = accent ? t.OnAccent : t.Muted,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        return new Border
        {
            Child = tb,
            Background = accent ? t.Accent : t.Surface2,
            BorderBrush = accent ? t.Accent : t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(7),
            Padding = new Thickness(14, 5, 14, 5),
            Margin = new Thickness(8, 0, 0, 0),
            Cursor = Cursors.Hand,
        };
    }
}
