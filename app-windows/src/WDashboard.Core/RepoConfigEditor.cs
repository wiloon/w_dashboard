// Text-level add/remove/update of `[[repos]]` blocks (docs/sdd.md §4.1). Every
// other line — other sections, comments, blank lines, key order, line endings —
// is left byte-for-byte untouched; nothing is re-serialized through Tomlyn.

using System.Text;
using Tomlyn;
using Tomlyn.Model;

namespace WDashboard.Core;

public static class RepoConfigEditor
{
    public static string Add(string text, string rawPath, string? name)
    {
        var nl = NewlineOf(text);
        var sb = new StringBuilder(text);
        if (text.Length > 0 && !text.EndsWith('\n')) sb.Append(nl);
        foreach (var line in BlockLines(rawPath, name)) sb.Append(line).Append(nl);
        return sb.ToString();
    }

    /// <summary>Remove the first block whose expanded path matches <paramref name="target"/>.</summary>
    public static string Remove(string text, string target) => Replace(text, target, null);

    /// <summary>Replace the first matching block with a fresh <c>[[repos]]</c> / path / name block.</summary>
    public static string Update(string text, string target, string newRawPath, string? newName) =>
        Replace(text, target, BlockLines(newRawPath, newName));

    private static string Replace(string text, string target, IReadOnlyList<string>? replacement)
    {
        var lines = SplitKeepingTerminators(text);
        foreach (var (start, end, path) in FindRepoBlocks(lines))
        {
            if (path is null || !Paths.SamePath(Paths.Expand(path), target)) continue;

            var nl = NewlineOf(text);
            var sb = new StringBuilder();
            for (var i = 0; i < start; i++) sb.Append(lines[i]);
            if (replacement is not null)
            {
                if (sb.Length > 0 && sb[^1] != '\n') sb.Append(nl);
                foreach (var line in replacement) sb.Append(line).Append(nl);
            }
            for (var i = end; i < lines.Count; i++) sb.Append(lines[i]);
            return sb.ToString();
        }
        return text;
    }

    private static IReadOnlyList<string> BlockLines(string rawPath, string? name)
    {
        var lines = new List<string> { "[[repos]]", $"path = {Quote(rawPath)}" };
        if (!string.IsNullOrEmpty(name)) lines.Add($"name = {Quote(name)}");
        return lines;
    }

    private static string Quote(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    private static string NewlineOf(string text) => text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";

    /// <summary>Lines with their own <c>\n</c> / <c>\r\n</c> still attached.</summary>
    private static List<string> SplitKeepingTerminators(string text)
    {
        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\n') continue;
            lines.Add(text[start..(i + 1)]);
            start = i + 1;
        }
        if (start < text.Length) lines.Add(text[start..]);
        return lines;
    }

    /// <summary>
    /// A block runs from a <c>[[repos]]</c> header up to (not including) the next line
    /// that starts with <c>[</c>, or the end of the file.
    /// </summary>
    private static IEnumerable<(int Start, int End, string? Path)> FindRepoBlocks(List<string> lines)
    {
        var i = 0;
        while (i < lines.Count)
        {
            if (Content(lines[i]) != "[[repos]]")
            {
                i++;
                continue;
            }
            var start = i;
            string? path = null;
            var j = i + 1;
            for (; j < lines.Count; j++)
            {
                var inner = Content(lines[j]);
                if (inner.StartsWith('[')) break;
                if (inner.Length > 0 && path is null) path = PathValue(inner);
            }
            yield return (start, j, path);
            i = j;
        }
    }

    private static string? PathValue(string keyValueLine)
    {
        if (!keyValueLine.StartsWith("path", StringComparison.Ordinal)) return null;
        try
        {
            var table = TomlSerializer.Deserialize<TomlTable>(keyValueLine);
            return table is not null && table.TryGetValue("path", out var v) ? v as string : null;
        }
        catch (TomlException)
        {
            return null;
        }
    }

    private static string Content(string line) => StripComment(line).Trim();

    /// <summary>Drop a trailing <c># ...</c> comment that is not inside a quoted string.</summary>
    private static string StripComment(string line)
    {
        var inString = false;
        var escaped = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (inString)
            {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
            }
            else if (c == '"') inString = true;
            else if (c == '#') return line[..i];
        }
        return line;
    }
}

/// <summary>File-level <c>add_repo</c> / <c>remove_repo</c> / <c>update_repo</c> (§6).</summary>
public static class RepoConfigFile
{
    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];

    /// <exception cref="ConfigException">The file cannot be read or written.</exception>
    public static void AddRepo(string configPath, string rawPath, string? name) =>
        Edit(configPath, text => RepoConfigEditor.Add(text, rawPath, name));

    /// <param name="target">Expanded path of the repo to remove.</param>
    public static void RemoveRepo(string configPath, string target) =>
        Edit(configPath, text => RepoConfigEditor.Remove(text, target));

    /// <param name="target">Expanded path of the repo to replace.</param>
    public static void UpdateRepo(string configPath, string target, string newRawPath, string? newName) =>
        Edit(configPath, text => RepoConfigEditor.Update(text, target, newRawPath, newName));

    private static void Edit(string configPath, Func<string, string> transform)
    {
        try
        {
            var bytes = File.Exists(configPath) ? File.ReadAllBytes(configPath) : [];
            var hasBom = bytes.AsSpan().StartsWith(Utf8Bom);
            var text = Encoding.UTF8.GetString(hasBom ? bytes[Utf8Bom.Length..] : bytes);
            var updated = transform(text);
            if (updated == text && bytes.Length > 0) return;

            var dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(configPath))!;
            Directory.CreateDirectory(dir);
            var tmp = System.IO.Path.Combine(dir, $".{System.IO.Path.GetFileName(configPath)}.{Environment.ProcessId}.tmp");
            File.WriteAllText(tmp, updated, new UTF8Encoding(encoderShouldEmitUTF8Identifier: hasBom));
            File.Move(tmp, configPath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new ConfigException(ConfigErrorKind.Io, e.Message);
        }
    }
}
