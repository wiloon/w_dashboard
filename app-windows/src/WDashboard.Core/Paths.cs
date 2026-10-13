// Path expansion and comparison (docs/sdd.md §4).

using System.Text;

namespace WDashboard.Core;

public static class Paths
{
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>
    /// <c>%XDG_CONFIG_HOME%\w_dashboard\config.toml</c>, falling back to
    /// <c>%USERPROFILE%\.config\w_dashboard\config.toml</c> (§4, ADR-015).
    /// </summary>
    public static string DefaultConfigPath()
    {
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        var baseDir = string.IsNullOrEmpty(xdg) ? Path.Combine(Home, ".config") : xdg;
        return Path.Combine(baseDir, "w_dashboard", "config.toml");
    }

    /// <summary>Expand environment variables, then a leading <c>~</c>.</summary>
    public static string Expand(string raw) => ExpandTilde(ExpandEnv(raw));

    /// <summary>
    /// Expand <c>$VAR</c> / <c>${VAR}</c> / <c>%VAR%</c>. Unknown variables are left
    /// as written.
    /// </summary>
    public static string ExpandEnv(string input)
    {
        var sb = new StringBuilder(input.Length);
        var i = 0;
        while (i < input.Length)
        {
            var c = input[i];
            if (c == '$' && i + 1 < input.Length && input[i + 1] == '{')
            {
                var close = input.IndexOf('}', i + 2);
                var name = close < 0 ? input[(i + 2)..] : input[(i + 2)..close];
                var value = Lookup(name);
                if (value is not null) sb.Append(value);
                else sb.Append("${").Append(name).Append(close < 0 ? "" : "}");
                i = close < 0 ? input.Length : close + 1;
            }
            else if (c == '$')
            {
                var j = i + 1;
                while (j < input.Length && (char.IsLetterOrDigit(input[j]) || input[j] == '_')) j++;
                var name = input[(i + 1)..j];
                var value = name.Length == 0 ? null : Lookup(name);
                sb.Append(value ?? input[i..j]);
                i = j;
            }
            else if (c == '%')
            {
                var close = input.IndexOf('%', i + 1);
                var name = close < 0 ? "" : input[(i + 1)..close];
                var value = name.Length == 0 ? null : Lookup(name);
                if (value is null)
                {
                    sb.Append(c);
                    i++;
                }
                else
                {
                    sb.Append(value);
                    i = close + 1;
                }
            }
            else
            {
                sb.Append(c);
                i++;
            }
        }
        return sb.ToString();
    }

    private static string? Lookup(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : null;

    private static string ExpandTilde(string path)
    {
        if (path == "~") return Home;
        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
            return Path.Combine(Home, path[2..]);
        return path;
    }

    /// <summary>
    /// Normalize an already-expanded path for comparison: <c>/</c> → <c>\</c>, trailing
    /// separators trimmed (§4 path comparison).
    /// </summary>
    public static string Normalize(string expanded)
    {
        var p = expanded.Replace('/', '\\');
        return p.Length > 1 ? p.TrimEnd('\\') : p;
    }

    /// <summary>Windows path equality: normalized, case-insensitive (§4).</summary>
    public static bool SamePath(string a, string b) =>
        string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>Default display name for a repo: the last path component.</summary>
    public static string LastComponent(string path)
    {
        var trimmed = Normalize(path);
        var name = Path.GetFileName(trimmed);
        return string.IsNullOrEmpty(name) ? path : name;
    }
}
