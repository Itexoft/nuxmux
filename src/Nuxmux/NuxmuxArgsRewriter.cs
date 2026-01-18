// Copyright (c) 2011-2026 Denis Kudelin
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// This Source Code Form is "Incompatible With Secondary Licenses", as defined by the Mozilla Public License, v. 2.0.

using System.Text;
using System.Text.RegularExpressions;

namespace Itexoft.Nuxmux;

internal static class NuxmuxArgsRewriter
{
    public static string[] Rewrite(string? nuxmuxArgsRewrite, string binName, string[] args)
    {
        if (args is null)
            throw new ArgumentNullException(nameof(args));

        if (binName is null)
            throw new ArgumentNullException(nameof(binName));

        if (string.IsNullOrWhiteSpace(nuxmuxArgsRewrite))
            return args;

        var spec = TrimWrappingQuotes(nuxmuxArgsRewrite.Trim());

        if (spec.Length == 0)
            return args;

        var normalizedBinName = NormalizeBinName(binName);

        var rules = ParseApplicableRules(spec, normalizedBinName);

        if (rules.Count == 0)
            return args;

        foreach (var t in args)
        {
            if (t is null)
                throw new ArgumentException("args contains null element", nameof(args));
        }

        var merged = MergeArgs(args);

        for (var r = 0; r < rules.Count; r++)
            merged = rules[r].Apply(merged);

        var rewritten = SplitArgs(merged);

        return rewritten;
    }

    private static List<Rule> ParseApplicableRules(string spec, string normalizedBinName)
    {
        var rules = new List<Rule>();
        var i = 0;

        while (true)
        {
            SkipSeparators(spec, ref i);

            if (i >= spec.Length)
                break;

            if (spec[i] == '\'' || spec[i] == '"')
            {
                var inner = ReadQuoted(spec, ref i);

                if (inner.Length != 0)
                    rules.AddRange(ParseApplicableRules(inner, normalizedBinName));

                continue;
            }

            var parsed = ParseOneRule(spec, ref i);

            if (parsed.BinName is not null && !BinNameEquals(normalizedBinName, parsed.BinName))
                continue;

            try
            {
                var options = parsed.Options | RegexOptions.CultureInvariant;
                var regex = new Regex(parsed.Pattern, options);
                rules.Add(new Rule(regex, parsed.Replacement, parsed.Global));
            }
            catch (ArgumentException ex)
            {
                var scope = parsed.BinName ?? "<any>";

                throw new FormatException($"Invalid regex in NUXMUX_ARGS_REWRITE for bin '{scope}': {ex.Message}", ex);
            }
        }

        return rules;
    }

    private static ParsedRule ParseOneRule(string spec, ref int i)
    {
        if (LooksLikeSed(spec, i))
        {
            var sed = ParseSed(spec, ref i);

            return new ParsedRule(null, sed.Pattern, sed.Replacement, sed.Options, sed.Global);
        }

        var binStart = i;

        while (i < spec.Length && !char.IsWhiteSpace(spec[i]) && spec[i] != ';' && spec[i] != '\'' && spec[i] != '"')
            i++;

        if (i == binStart)
            throw new FormatException($"Invalid rule at position {binStart}");

        if (i >= spec.Length || !char.IsWhiteSpace(spec[i]))
            throw new FormatException($"Invalid rule at position {binStart}: expected whitespace after bin name");

        var binRaw = spec.Substring(binStart, i - binStart).Trim();
        binRaw = TrimWrappingQuotes(binRaw);
        var bin = NormalizeBinName(binRaw);

        SkipWhitespace(spec, ref i);

        if (!LooksLikeSed(spec, i))
            throw new FormatException($"Invalid rule for bin '{bin}' at position {i}: expected sed expression");

        var sed2 = ParseSed(spec, ref i);

        return new ParsedRule(bin, sed2.Pattern, sed2.Replacement, sed2.Options, sed2.Global);
    }

    private static Sed ParseSed(string spec, ref int i)
    {
        if (!LooksLikeSed(spec, i))
            throw new FormatException($"Invalid sed expression at position {i}");

        i++;

        var delim = spec[i];

        if (char.IsWhiteSpace(delim) || delim == ';' || char.IsLetterOrDigit(delim))
            throw new FormatException($"Invalid sed delimiter '{delim}' at position {i}");

        i++;

        var pattern = ReadUntilDelimiter(spec, ref i, delim);

        if (i >= spec.Length || spec[i] != delim)
            throw new FormatException("Unterminated sed pattern");

        i++;

        var replacement = ReadUntilDelimiter(spec, ref i, delim);

        if (i >= spec.Length || spec[i] != delim)
            throw new FormatException("Unterminated sed replacement");

        i++;

        var options = RegexOptions.None;
        var global = false;

        var flagsStart = i;
        var j = i;

        while (j < spec.Length && IsFlag(spec[j]))
            j++;

        if (j > flagsStart && (j == spec.Length || IsRuleSeparator(spec[j])))
        {
            for (var k = flagsStart; k < j; k++)
            {
                var c = char.ToLowerInvariant(spec[k]);

                if (c == 'g')
                {
                    global = true;

                    continue;
                }

                if (c == 'i')
                {
                    options |= RegexOptions.IgnoreCase;

                    continue;
                }

                if (c == 'm')
                {
                    options |= RegexOptions.Multiline;

                    continue;
                }

                if (c == 's')
                {
                    options |= RegexOptions.Singleline;

                    continue;
                }

                throw new FormatException($"Unknown sed flag '{spec[k]}' at position {k}");
            }

            i = j;
        }

        return new Sed(pattern, replacement, options, global);
    }

    private static string ReadUntilDelimiter(string spec, ref int i, char delim)
    {
        var sb = new StringBuilder();
        var escaped = false;

        while (i < spec.Length)
        {
            var c = spec[i];

            if (!escaped && c == delim)
                break;

            if (!escaped && c == '\\')
            {
                escaped = true;
                sb.Append(c);
                i++;

                continue;
            }

            escaped = false;
            sb.Append(c);
            i++;
        }

        return sb.ToString();
    }

    private static bool LooksLikeSed(string spec, int i)
    {
        if (i >= spec.Length)
            return false;

        if (spec[i] != 's')
            return false;

        var next = i + 1;

        if (next >= spec.Length)
            return false;

        var delim = spec[next];

        if (char.IsWhiteSpace(delim) || delim == ';' || char.IsLetterOrDigit(delim))
            return false;

        return true;
    }

    private static void SkipSeparators(string spec, ref int i)
    {
        while (i < spec.Length)
        {
            var c = spec[i];

            if (c == ';' || char.IsWhiteSpace(c))
            {
                i++;

                continue;
            }

            break;
        }
    }

    private static void SkipWhitespace(string spec, ref int i)
    {
        while (i < spec.Length && char.IsWhiteSpace(spec[i]))
            i++;
    }

    private static string ReadQuoted(string spec, ref int i)
    {
        var q = spec[i];
        i++;

        var sb = new StringBuilder();

        while (i < spec.Length)
        {
            var c = spec[i];

            if (c == '\\' && i + 1 < spec.Length)
            {
                var n = spec[i + 1];

                if (n == q || n == '\\')
                {
                    sb.Append(n);
                    i += 2;

                    continue;
                }
            }

            if (c == q)
            {
                i++;

                return sb.ToString();
            }

            sb.Append(c);
            i++;
        }

        throw new FormatException("Unterminated quote in NUXMUX_ARGS_REWRITE");
    }

    private static bool IsRuleSeparator(char c) => c == ';' || char.IsWhiteSpace(c) || c == '\'' || c == '"';

    private static bool IsFlag(char c)
    {
        c = char.ToLowerInvariant(c);

        return c == 'g' || c == 'i' || c == 'm' || c == 's';
    }

    private static bool BinNameEquals(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    private static string NormalizeBinName(string binName)
    {
        var s = binName.Trim();
        s = Path.GetFileName(s);

        if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            s = s.Substring(0, s.Length - 4);

        return s;
    }

    private static string TrimWrappingQuotes(string s)
    {
        if (s.Length >= 2)
        {
            var first = s[0];
            var last = s[^1];

            if ((first == '\'' && last == '\'') || (first == '"' && last == '"'))
                return s.Substring(1, s.Length - 2);
        }

        return s;
    }

    private static string MergeArgs(string[] args)
    {
        if (args.Length == 0)
            return string.Empty;

        var sb = new StringBuilder();

        sb.Append(' ');

        for (var i = 0; i < args.Length; i++)
        {
            if (i != 0)
                sb.Append(' ');

            AppendArg(sb, args[i]);
        }

        sb.Append(' ');

        return sb.ToString();
    }

    private static void AppendArg(StringBuilder sb, string arg)
    {
        if (arg.Length == 0)
        {
            sb.Append("\"\"");

            return;
        }

        if (!NeedsQuotes(arg))
        {
            sb.Append(arg);

            return;
        }

        sb.Append('"');

        var i = 0;

        while (i < arg.Length)
        {
            var bs = 0;

            while (i < arg.Length && arg[i] == '\\')
            {
                bs++;
                i++;
            }

            if (i == arg.Length)
            {
                sb.Append('\\', bs * 2);

                break;
            }

            if (arg[i] == '"')
            {
                sb.Append('\\', bs * 2 + 1);
                sb.Append('"');
                i++;

                continue;
            }

            sb.Append('\\', bs);
            sb.Append(arg[i]);
            i++;
        }

        sb.Append('"');
    }

    private static bool NeedsQuotes(string arg)
    {
        foreach (var c in arg)
        {
            if (char.IsWhiteSpace(c) || c == '"')
                return true;
        }

        return false;
    }

    private static string[] SplitArgs(string merged)
    {
        if (string.IsNullOrWhiteSpace(merged))
            return Array.Empty<string>();

        var args = new List<string>();
        var i = 0;

        while (true)
        {
            while (i < merged.Length && char.IsWhiteSpace(merged[i]))
                i++;

            if (i >= merged.Length)
                break;

            var sb = new StringBuilder();
            var inQuotes = false;

            while (i < merged.Length)
            {
                var c = merged[i];

                if (c == '\\')
                {
                    var bs = 0;

                    while (i < merged.Length && merged[i] == '\\')
                    {
                        bs++;
                        i++;
                    }

                    if (i < merged.Length && merged[i] == '"')
                    {
                        sb.Append('\\', bs / 2);

                        if ((bs & 1) == 0)
                            inQuotes = !inQuotes;
                        else
                            sb.Append('"');

                        i++;

                        continue;
                    }

                    sb.Append('\\', bs);

                    continue;
                }

                if (c == '"')
                {
                    inQuotes = !inQuotes;
                    i++;

                    continue;
                }

                if (!inQuotes && char.IsWhiteSpace(c))
                    break;

                sb.Append(c);
                i++;
            }

            if (inQuotes)
                throw new FormatException("Unterminated quote in rewritten args string");

            args.Add(sb.ToString());
        }

        return args.ToArray();
    }

    private readonly struct Rule(Regex regex, string replacement, bool global)
    {
        public Regex Regex { get; } = regex;
        public string Replacement { get; } = replacement;
        public bool Global { get; } = global;

        public string Apply(string input)
        {
            if (this.Global)
                return this.Regex.Replace(input, this.Replacement);

            return this.Regex.Replace(input, this.Replacement, 1);
        }
    }

    private readonly struct ParsedRule(string? binName, string pattern, string replacement, RegexOptions options, bool global)
    {
        public string? BinName { get; } = binName;
        public string Pattern { get; } = pattern;
        public string Replacement { get; } = replacement;
        public RegexOptions Options { get; } = options;
        public bool Global { get; } = global;
    }

    private readonly struct Sed(string pattern, string replacement, RegexOptions options, bool global)
    {
        public string Pattern { get; } = pattern;
        public string Replacement { get; } = replacement;
        public RegexOptions Options { get; } = options;
        public bool Global { get; } = global;
    }
}
