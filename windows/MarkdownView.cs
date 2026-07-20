using System;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using MdTable = Markdig.Extensions.Tables.Table;
using MdTableCell = Markdig.Extensions.Tables.TableCell;
using MdTableRow = Markdig.Extensions.Tables.TableRow;

namespace Cleanup;

// A small native WPF renderer backed by Markdig's CommonMark parser. Agent output remains
// normal WPF content (not an embedded browser): headings, emphasis, lists, links, quotes,
// tables, and code all inherit Cleanup's current theme and resize naturally inside bubbles.
internal sealed class MarkdownView : StackPanel
{
    private readonly Brush _text, _muted, _surface, _line, _accent;
    private readonly double _fontSize;
    public string Markdown { get; private set; } = "";

    public MarkdownView(Theme theme, double fontSize)
    {
        _text = theme.Text; _muted = theme.Muted; _surface = theme.Surface3;
        _line = theme.LineStrong; _accent = theme.Accent; _fontSize = fontSize;
        ContextMenu = new ContextMenu();
        var copy = new MenuItem { Header = "Copy response" };
        copy.Click += (_, _) => { try { Clipboard.SetText(Markdown); } catch { } };
        ContextMenu.Items.Add(copy);
    }

    public void SetMarkdown(string markdown)
    {
        Markdown = markdown ?? "";
        Children.Clear();
        try
        {
            var doc = Markdig.Markdown.Parse(Markdown, MarkdownRenderer.Pipeline);
            RenderBlocks(doc, this);
        }
        catch
        {
            Children.Add(Text(Markdown));
        }
    }

    private void RenderBlocks(ContainerBlock blocks, Panel target)
    {
        foreach (var block in blocks)
        {
            switch (block)
            {
                case HeadingBlock h:
                {
                    var tb = Text("");
                    tb.FontWeight = FontWeights.SemiBold;
                    tb.FontSize = _fontSize + Math.Max(1, 5 - h.Level);
                    tb.Margin = new Thickness(0, h.Level == 1 ? 5 : 3, 0, 5);
                    RenderInlines(h.Inline, tb.Inlines);
                    target.Children.Add(tb);
                    break;
                }
                case ParagraphBlock p:
                {
                    var tb = Text(""); tb.Margin = new Thickness(0, 0, 0, 6);
                    RenderInlines(p.Inline, tb.Inlines);
                    target.Children.Add(tb);
                    break;
                }
                case ListBlock list:
                    target.Children.Add(RenderList(list));
                    break;
                case QuoteBlock quote:
                {
                    var body = new StackPanel { Margin = new Thickness(10, 2, 0, 2) };
                    RenderBlocks(quote, body);
                    target.Children.Add(new Border
                    {
                        Child = body, BorderBrush = _accent, BorderThickness = new Thickness(2, 0, 0, 0),
                        Padding = new Thickness(9, 1, 0, 1), Margin = new Thickness(0, 1, 0, 7), Opacity = 0.9
                    });
                    break;
                }
                case FencedCodeBlock fenced:
                    target.Children.Add(Code(fenced.Lines.ToString(), fenced.Info?.ToString()));
                    break;
                case CodeBlock code:
                    target.Children.Add(Code(code.Lines.ToString(), null));
                    break;
                case MdTable table:
                    target.Children.Add(RenderTable(table));
                    break;
                case ThematicBreakBlock:
                    target.Children.Add(new Border { Height = 1, Background = _line, Margin = new Thickness(0, 5, 0, 9) });
                    break;
                case LeafBlock leaf:
                    target.Children.Add(Text(leaf.Lines.ToString()));
                    break;
            }
        }
    }

    private FrameworkElement RenderList(ListBlock list)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 6) };
        var number = 1;
        foreach (var child in list)
        {
            if (child is not ListItemBlock item) continue;
            var row = new Grid { Margin = new Thickness(0, 1, 0, 2) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var marker = Text(list.IsOrdered ? number++ + "." : "•");
            marker.Foreground = _muted; marker.TextAlignment = TextAlignment.Right; marker.Margin = new Thickness(0, 0, 7, 0);
            var body = new StackPanel(); Grid.SetColumn(body, 1); RenderBlocks(item, body);
            row.Children.Add(marker); row.Children.Add(body); panel.Children.Add(row);
        }
        return panel;
    }

    private FrameworkElement RenderTable(MdTable table)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 8) };
        var columns = 0;
        foreach (var row in table) if (row is MdTableRow r) columns = Math.Max(columns, r.Count);
        for (var i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rowIndex = 0;
        foreach (var block in table)
        {
            if (block is not MdTableRow row) continue;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var col = 0; col < row.Count; col++)
            {
                if (row[col] is not MdTableCell cell) continue;
                var body = new StackPanel(); RenderBlocks(cell, body);
                var shell = new Border
                {
                    Child = body, BorderBrush = _line, BorderThickness = new Thickness(0.5),
                    Background = row.IsHeader ? _surface : Brushes.Transparent,
                    Padding = new Thickness(7, 5, 7, 1)
                };
                Grid.SetRow(shell, rowIndex); Grid.SetColumn(shell, col); grid.Children.Add(shell);
            }
            rowIndex++;
        }
        return new ScrollViewer { Content = grid, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    private FrameworkElement Code(string code, string? language)
    {
        var panel = new StackPanel();
        if (!string.IsNullOrWhiteSpace(language))
            panel.Children.Add(new TextBlock { Text = language.Trim(), Foreground = _muted, FontSize = 10, Margin = new Thickness(1, 0, 0, 5) });
        panel.Children.Add(new TextBox
        {
            Text = code.TrimEnd(), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Cascadia Mono,Consolas"), FontSize = Math.Max(11, _fontSize - 1),
            Foreground = _text, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled
        });
        return new Border
        {
            Child = panel, Background = _surface, BorderBrush = _line, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6), Padding = new Thickness(9, 7, 9, 7), Margin = new Thickness(0, 2, 0, 8)
        };
    }

    private TextBlock Text(string text) => new()
    {
        Text = text, Foreground = _text, FontSize = _fontSize, TextWrapping = TextWrapping.Wrap,
        FontFamily = new FontFamily("Segoe UI"), LineHeight = _fontSize * 1.45
    };

    private void RenderInlines(ContainerInline? container, InlineCollection target)
    {
        if (container == null) return;
        for (var node = container.FirstChild; node != null; node = node.NextSibling)
            RenderInline(node, target);
    }

    private void RenderInline(Markdig.Syntax.Inlines.Inline node, InlineCollection target)
    {
        switch (node)
        {
            case LiteralInline literal:
                target.Add(new Run(literal.Content.ToString()));
                break;
            case CodeInline code:
                target.Add(new Run(code.Content) { FontFamily = new FontFamily("Cascadia Mono,Consolas"), Background = _surface });
                break;
            case LineBreakInline:
                target.Add(new LineBreak());
                break;
            case EmphasisInline emphasis:
            {
                var span = new Span();
                if (emphasis.DelimiterCount >= 2) span.FontWeight = FontWeights.SemiBold;
                else span.FontStyle = FontStyles.Italic;
                RenderInlines(emphasis, span.Inlines); target.Add(span);
                break;
            }
            case LinkInline link:
            {
                if (link.IsImage) { target.Add(new Run("[image]")); break; }
                var span = SafeLink(link.Url) is Uri uri ? new Hyperlink { NavigateUri = uri, Foreground = _accent } : new Span();
                RenderInlines(link, span.Inlines);
                if (span is Hyperlink hyperlink)
                    hyperlink.RequestNavigate += (_, e) => { try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); } catch { } };
                target.Add(span); break;
            }
            case ContainerInline nested:
                RenderInlines(nested, target);
                break;
        }
    }

    private static Uri? SafeLink(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "mailto" ? uri : null;
}

internal static class MarkdownRenderer
{
    internal static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UseAdvancedExtensions().DisableHtml().Build();

    private static readonly Regex UnsafeAttribute = new(
        "\\s(?:href|src)\\s*=\\s*\"(?!https?://|mailto:|/)[^\"]*\"",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static string ToSafeHtml(string markdown) =>
        UnsafeAttribute.Replace(Markdig.Markdown.ToHtml(markdown ?? "", Pipeline), "");
}
