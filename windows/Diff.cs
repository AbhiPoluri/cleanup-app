using System;
using System.Collections.Generic;
using System.Text;

namespace Cleanup;

internal enum DiffKind { Same, Removed, Added }

// One contiguous run of the merged diff. Text keeps its original whitespace so
// the rendered flow reproduces spacing exactly.
internal readonly struct DiffSegment
{
    public readonly DiffKind Kind;
    public readonly string Text;
    public DiffSegment(DiffKind kind, string text) { Kind = kind; Text = text; }
}

// Word-level LCS diff. Texts are short chat-sized messages, so the classic
// O(n*m) dynamic-programming table is comfortably fast and exact.
internal static class Diff
{
    // Split into tokens where each token is either a maximal run of
    // non-whitespace OR a maximal run of whitespace. Emitting whitespace as its
    // own tokens lets the diff align on word boundaries while still being able
    // to rebuild the exact original spacing when rendered.
    public static List<string> Tokenize(string s)
    {
        var tokens = new List<string>();
        int i = 0, n = s.Length;
        while (i < n)
        {
            int start = i;
            bool ws = char.IsWhiteSpace(s[i]);
            while (i < n && char.IsWhiteSpace(s[i]) == ws) i++;
            tokens.Add(s.Substring(start, i - start));
        }
        return tokens;
    }

    // Diff `original` against `variant`, returning ordered, merged segments.
    // Within any replaced region, all removed text is emitted before the added
    // text (removed-then-added), and adjacent same-kind runs are merged.
    public static List<DiffSegment> Compute(string original, string variant)
    {
        var a = Tokenize(original);
        var b = Tokenize(variant);
        int n = a.Count, m = b.Count;

        // dp[i, j] = length of the LCS of a[i..] and b[j..]
        var dp = new int[n + 1, m + 1];
        for (int i = n - 1; i >= 0; i--)
            for (int j = m - 1; j >= 0; j--)
                dp[i, j] = a[i] == b[j]
                    ? dp[i + 1, j + 1] + 1
                    : Math.Max(dp[i + 1, j], dp[i, j + 1]);

        // Forward walk of the DP table → raw per-token segments.
        var raw = new List<DiffSegment>();
        int x = 0, y = 0;
        while (x < n && y < m)
        {
            if (a[x] == b[y]) { raw.Add(new DiffSegment(DiffKind.Same, a[x])); x++; y++; }
            else if (dp[x + 1, y] >= dp[x, y + 1]) { raw.Add(new DiffSegment(DiffKind.Removed, a[x])); x++; }
            else { raw.Add(new DiffSegment(DiffKind.Added, b[y])); y++; }
        }
        while (x < n) { raw.Add(new DiffSegment(DiffKind.Removed, a[x])); x++; }
        while (y < m) { raw.Add(new DiffSegment(DiffKind.Added, b[y])); y++; }

        return Merge(raw);
    }

    // Collapse the raw token stream: merge consecutive Same runs, and for each
    // changed region (a maximal run with no Same) gather all removed text then
    // all added text into at most one Removed + one Added segment.
    private static List<DiffSegment> Merge(List<DiffSegment> raw)
    {
        var result = new List<DiffSegment>();
        int i = 0;
        while (i < raw.Count)
        {
            if (raw[i].Kind == DiffKind.Same)
            {
                var same = new StringBuilder();
                while (i < raw.Count && raw[i].Kind == DiffKind.Same) { same.Append(raw[i].Text); i++; }
                result.Add(new DiffSegment(DiffKind.Same, same.ToString()));
            }
            else
            {
                var removed = new StringBuilder();
                var added = new StringBuilder();
                while (i < raw.Count && raw[i].Kind != DiffKind.Same)
                {
                    if (raw[i].Kind == DiffKind.Removed) removed.Append(raw[i].Text);
                    else added.Append(raw[i].Text);
                    i++;
                }
                if (removed.Length > 0) result.Add(new DiffSegment(DiffKind.Removed, removed.ToString()));
                if (added.Length > 0) result.Add(new DiffSegment(DiffKind.Added, added.ToString()));
            }
        }
        return result;
    }
}
