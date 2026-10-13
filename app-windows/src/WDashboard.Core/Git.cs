// Git status parsing and RepoState derivation (docs/sdd.md §7.1 / §7.2) plus the
// action-button table (§7.5). Pure functions, locked by docs/test-vectors/
// git-porcelain/, repo-state/ and repo-actions/.

namespace WDashboard.Core;

/// <summary>Parsed `git status --porcelain=v2 --branch`, before RepoState derivation.</summary>
public sealed record ParsedGitStatus(
    string? Branch,
    string? Upstream,
    int Ahead,
    int Behind,
    int Staged,
    int Modified,
    int Untracked,
    int Conflicted);

/// <summary>Inputs to the §7.2 decision table.</summary>
public sealed record DeriveInput(
    int Ahead,
    int Behind,
    int Staged,
    int Modified,
    int Untracked,
    int Conflicted,
    bool HasUpstream,
    string? Error);

public enum RepoAction { Pull, Push, Fetch }

public sealed record AllowedActions(bool Pull, bool Push, bool Fetch);

public static class Git
{
    public static ParsedGitStatus ParsePorcelainV2(string text)
    {
        string? branch = null;
        string? upstream = null;
        int ahead = 0, behind = 0, staged = 0, modified = 0, untracked = 0, conflicted = 0;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith("# branch.head ", StringComparison.Ordinal))
            {
                var rest = line["# branch.head ".Length..];
                branch = rest == "(detached)" ? null : rest;
            }
            else if (line.StartsWith("# branch.upstream ", StringComparison.Ordinal))
            {
                upstream = line["# branch.upstream ".Length..];
            }
            else if (line.StartsWith("# branch.ab ", StringComparison.Ordinal))
            {
                foreach (var tok in line["# branch.ab ".Length..].Split(' ', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (tok.StartsWith('+'))
                    {
                        ahead = int.TryParse(tok.AsSpan(1), out var a) ? a : 0;
                    }
                    else if (tok.StartsWith('-'))
                    {
                        behind = int.TryParse(tok.AsSpan(1), out var b) ? b : 0;
                    }
                }
            }
            else if (line.StartsWith('#'))
            {
                // Other headers (e.g. branch.oid) are not needed.
            }
            else
            {
                var parts = line.Split(' ', 3);
                switch (parts[0])
                {
                    case "1":
                    case "2":
                        var xy = parts.Length > 1 ? parts[1] : "";
                        var x = xy.Length > 0 ? xy[0] : '.';
                        var y = xy.Length > 1 ? xy[1] : '.';
                        if (x != '.') staged++;
                        if (y != '.') modified++;
                        break;
                    case "u":
                        conflicted++;
                        break;
                    case "?":
                        untracked++;
                        break;
                    // "!" (ignored) and anything else do not count, per §7.1.
                }
            }
        }

        return new ParsedGitStatus(branch, upstream, ahead, behind, staged, modified, untracked, conflicted);
    }

    /// <summary>§7.2 decision table, matched in order, first match wins.</summary>
    public static RepoState DeriveState(DeriveInput input)
    {
        if (input.Error is not null) return RepoState.Error;
        if (input.Conflicted + input.Staged + input.Modified + input.Untracked > 0) return RepoState.Dirty;
        if (!input.HasUpstream) return RepoState.NoUpstream;
        if (input.Ahead > 0 && input.Behind > 0) return RepoState.Diverged;
        if (input.Behind > 0) return RepoState.NeedsPull;
        if (input.Ahead > 0) return RepoState.NeedsPush;
        return RepoState.Clean;
    }

    /// <summary>§7.5 button table.</summary>
    public static AllowedActions AllowedActionsFor(RepoState state) => state switch
    {
        RepoState.Error => new AllowedActions(Pull: false, Push: false, Fetch: false),
        RepoState.NeedsPull => new AllowedActions(Pull: true, Push: false, Fetch: true),
        RepoState.NeedsPush => new AllowedActions(Pull: false, Push: true, Fetch: true),
        _ => new AllowedActions(Pull: false, Push: false, Fetch: true),
    };
}
