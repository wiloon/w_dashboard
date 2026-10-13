// Git collection (docs/sdd.md §7.1), the explicit safe sync actions (§7.5,
// ADR-011) and the environment check (§6). Side-effecting; every failure is
// folded into RepoStatus.Error / GitActionResult.Error rather than thrown.

namespace WDashboard.Core;

/// <summary><see cref="Summary"/> is the one-line success message; <see cref="Error"/> is git's stderr first line.</summary>
public sealed record GitActionResult(RepoAction Action, bool Ok, string Summary, string? Error);

/// <summary>Versions of the external tools, <c>null</c> when not found (§6 <c>check_environment</c>).</summary>
public sealed record EnvironmentInfo(string? Git, string? Chezmoi);

public static class GitCollector
{
    private const int MaxMessageLength = 160;

    public static async Task<RepoStatus> CollectRepoAsync(
        RepoConfig repo, bool fetchRemote, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var name = string.IsNullOrEmpty(repo.Name) ? Paths.LastComponent(repo.Path) : repo.Name;
        var status = new RepoStatus { Name = name, Path = repo.Path };

        try
        {
            var check = await Git(repo.Path, timeout, cancellationToken, "rev-parse", "--is-inside-work-tree");
            if (!check.Succeeded)
                return status with { Error = OrDefault(check.Stderr.Trim(), "not a git work tree"), State = RepoState.Error };
        }
        catch (ProcessException e)
        {
            return status with { Error = e.Message, State = RepoState.Error };
        }

        if (fetchRemote)
        {
            try
            {
                var fetch = await Git(repo.Path, timeout, cancellationToken, "fetch", "--quiet");
                status = fetch.Succeeded
                    ? status with { LastFetchAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds() }
                    : status with { Error = $"fetch failed: {fetch.Stderr.Trim()}" };
            }
            catch (ProcessException e)
            {
                status = status with { Error = $"fetch failed: {e.Message}" };
            }
        }

        try
        {
            var result = await Git(repo.Path, timeout, cancellationToken, "status", "--porcelain=v2", "--branch");
            if (!result.Succeeded)
                return status with { Error = OrDefault(result.Stderr.Trim(), "git status failed"), State = RepoState.Error };

            var p = Core.Git.ParsePorcelainV2(result.Stdout);
            var state = Core.Git.DeriveState(new DeriveInput(
                p.Ahead, p.Behind, p.Staged, p.Modified, p.Untracked, p.Conflicted, p.Upstream is not null, status.Error));
            return status with
            {
                Branch = p.Branch,
                Upstream = p.Upstream,
                Ahead = p.Ahead,
                Behind = p.Behind,
                Staged = p.Staged,
                Modified = p.Modified,
                Untracked = p.Untracked,
                Conflicted = p.Conflicted,
                State = state,
            };
        }
        catch (ProcessException e)
        {
            return status with { Error = e.Message, State = RepoState.Error };
        }
    }

    /// <summary>
    /// Run one explicit sync operation (§7.5). Only <c>pull --ff-only</c>, <c>push</c> and
    /// <c>fetch --quiet</c> exist here; the caller must have checked <see cref="Core.Git.AllowedActionsFor"/>.
    /// </summary>
    public static async Task<GitActionResult> RunRepoActionAsync(
        RepoConfig repo, RepoAction action, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        string[] args = action switch
        {
            RepoAction.Pull => ["pull", "--ff-only"],
            RepoAction.Push => ["push"],
            _ => ["fetch", "--quiet"],
        };

        try
        {
            var result = await Git(repo.Path, timeout, cancellationToken, args);
            if (result.Succeeded)
            {
                var summary = OrDefault(LastLine(result.Stdout), LastLine(result.Stderr));
                summary = OrDefault(summary, action switch
                {
                    RepoAction.Pull => "Already up to date",
                    RepoAction.Push => "Everything up-to-date",
                    _ => "Fetched",
                });
                return new GitActionResult(action, true, Truncate(summary), null);
            }

            var error = OrDefault(FirstLine(result.Stderr), FirstLine(result.Stdout));
            error = OrDefault(error, $"git {action.ToString().ToLowerInvariant()} failed");
            return new GitActionResult(action, false, "", Truncate(error));
        }
        catch (ProcessException e)
        {
            return new GitActionResult(action, false, "", e.Message);
        }
    }

    public static async Task<EnvironmentInfo> CheckEnvironmentAsync(CancellationToken cancellationToken = default)
    {
        var git = VersionOf("git", cancellationToken);
        var chezmoi = VersionOf("chezmoi", cancellationToken);
        return new EnvironmentInfo(await git, await chezmoi);
    }

    private static async Task<string?> VersionOf(string tool, CancellationToken cancellationToken)
    {
        try
        {
            var result = await ProcessRunner.RunAsync(tool, ["--version"], TimeSpan.FromSeconds(5), cancellationToken);
            return result.Succeeded ? OrDefault(FirstLine(result.Stdout), tool) : null;
        }
        catch (ProcessException)
        {
            return null;
        }
    }

    private static Task<ProcessResult> Git(string path, TimeSpan timeout, CancellationToken ct, params string[] args) =>
        ProcessRunner.RunAsync("git", ["-C", path, .. args], timeout, ct);

    private static IEnumerable<string> NonEmptyLines(string text) =>
        text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0);

    private static string FirstLine(string text) => NonEmptyLines(text).FirstOrDefault() ?? "";

    private static string LastLine(string text) => NonEmptyLines(text).LastOrDefault() ?? "";

    private static string OrDefault(string s, string fallback) => s.Length > 0 ? s : fallback;

    private static string Truncate(string s) =>
        s.Length <= MaxMessageLength ? s : s[..(MaxMessageLength - 1)] + "…";
}
