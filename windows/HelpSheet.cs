using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Cleanup;

// Builds the compact mono cheat-sheet shown in the popup / agent help overlay.
// Left column = the trigger (key combo or glyph), right column = what it does.
internal static class HelpSheet
{
    public static void Populate(Panel host, Theme t, string title, (string Key, string Desc)[] rows)
    {
        host.Children.Clear();
        host.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = t.Text,
            Margin = new Thickness(0, 0, 0, 12),
        });

        foreach (var (key, desc) in rows)
        {
            var grid = new Grid { Margin = new Thickness(0, 0, 0, 7) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(128) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var k = new TextBlock
            {
                Text = key,
                FontSize = 11.5,
                FontFamily = new FontFamily("Consolas"),
                Foreground = t.Text,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Top,
            };
            Grid.SetColumn(k, 0);
            grid.Children.Add(k);

            var d = new TextBlock
            {
                Text = desc,
                FontSize = 12,
                Foreground = t.Muted,
                TextWrapping = TextWrapping.Wrap,
            };
            Grid.SetColumn(d, 1);
            grid.Children.Add(d);

            host.Children.Add(grid);
        }

        host.Children.Add(new TextBlock
        {
            Text = "Esc or ? to close",
            FontSize = 11,
            Foreground = t.Faint,
            Margin = new Thickness(0, 8, 0, 0),
        });
    }
}
