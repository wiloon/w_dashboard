// Real-git smoke tests (docs/sdd.md §7.1 / §7.5) against throwaway local repos;
// no network. Skipped implicitly when git is missing (the env check returns null).

namespace WDashboard.Core.Tests;

public class GitCollectorSmokeTests : IDisposable
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    private static async Task Git(string cwd, params string[] args)
    {
        var r = await ProcessRunner.RunAsync(
            "git", ["-C", cwd, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", .. args], Timeout);
        Assert.True(r.Succeeded, $"git {string.Join(' ', args)}: {r.Stderr}");
    }

    private async Task<(string Remote, string Clone)> RemoteAndClone()
    {
        var seed = Path.Combine(_dir.Path, "seed");
        var remote = Path.Combine(_dir.Path, "remote.git");
        var clone = Path.Combine(_dir.Path, "clone");
        Directory.CreateDirectory(seed);
        await Git(seed, "init", "-q", "-b", "main");
        await File.WriteAllTextAsync(Path.Combine(seed, "a.txt"), "a");
        await Git(seed, "add", ".");
        await Git(seed, "commit", "-q", "-m", "init");
        await Git(_dir.Path, "clone", "-q", "--bare", seed, remote);
        await Git(_dir.Path, "clone", "-q", remote, clone);
        return (remote, clone);
    }

    [Fact]
    public async Task EnvironmentReportsGit()
    {
        var env = await GitCollector.CheckEnvironmentAsync();
        Assert.StartsWith("git version", env.Git);
    }

    [Fact]
    public async Task MissingCommandIsCommandNotFound()
    {
        var e = await Assert.ThrowsAsync<ProcessException>(() =>
            ProcessRunner.RunAsync("wd-definitely-not-a-command", [], Timeout));
        Assert.Equal(ProcessErrorKind.CommandNotFound, e.Kind);
    }

    [Fact]
    public async Task TimeoutKillsProcess()
    {
        var e = await Assert.ThrowsAsync<ProcessException>(() =>
            ProcessRunner.RunAsync("powershell", ["-NoProfile", "-Command", "Start-Sleep 30"], TimeSpan.FromMilliseconds(500)));
        Assert.Equal(ProcessErrorKind.Timeout, e.Kind);
    }

    [Fact]
    public async Task NonRepoIsError()
    {
        var status = await GitCollector.CollectRepoAsync(new RepoConfig(_dir.Path, null), false, Timeout);
        Assert.Equal(RepoState.Error, status.State);
        Assert.NotNull(status.Error);
    }

    [Fact]
    public async Task CleanThenDirtyThenNeedsPushThenPushed()
    {
        var (_, clone) = await RemoteAndClone();
        var repo = new RepoConfig(clone, null);

        var status = await GitCollector.CollectRepoAsync(repo, fetchRemote: true, Timeout);
        Assert.Equal(RepoState.Clean, status.State);
        Assert.Equal("clone", status.Name);
        Assert.Equal("main", status.Branch);
        Assert.Equal("origin/main", status.Upstream);
        Assert.NotNull(status.LastFetchAt);

        await File.WriteAllTextAsync(Path.Combine(clone, "b.txt"), "b");
        status = await GitCollector.CollectRepoAsync(repo, false, Timeout);
        Assert.Equal(RepoState.Dirty, status.State);
        Assert.Equal(1, status.Untracked);

        await Git(clone, "add", ".");
        await Git(clone, "commit", "-q", "-m", "b");
        status = await GitCollector.CollectRepoAsync(repo, false, Timeout);
        Assert.Equal(RepoState.NeedsPush, status.State);
        Assert.Equal(1, status.Ahead);

        var push = await GitCollector.RunRepoActionAsync(repo, RepoAction.Push, Timeout);
        Assert.True(push.Ok, push.Error);
        status = await GitCollector.CollectRepoAsync(repo, false, Timeout);
        Assert.Equal(RepoState.Clean, status.State);
    }

    [Fact]
    public async Task NeedsPullThenFastForward()
    {
        var (remote, clone) = await RemoteAndClone();
        var other = Path.Combine(_dir.Path, "other");
        await Git(_dir.Path, "clone", "-q", remote, other);
        await File.WriteAllTextAsync(Path.Combine(other, "c.txt"), "c");
        await Git(other, "add", ".");
        await Git(other, "commit", "-q", "-m", "c");
        await Git(other, "push", "-q");

        var repo = new RepoConfig(clone, "mine");
        var status = await GitCollector.CollectRepoAsync(repo, fetchRemote: true, Timeout);
        Assert.Equal(RepoState.NeedsPull, status.State);
        Assert.Equal("mine", status.Name);
        Assert.Equal(1, status.Behind);

        var pull = await GitCollector.RunRepoActionAsync(repo, RepoAction.Pull, Timeout);
        Assert.True(pull.Ok, pull.Error);
        Assert.NotEmpty(pull.Summary);
        Assert.Equal(RepoState.Clean, (await GitCollector.CollectRepoAsync(repo, false, Timeout)).State);
    }

    [Fact]
    public async Task FailedActionReportsFirstStderrLine()
    {
        var seed = Path.Combine(_dir.Path, "solo");
        Directory.CreateDirectory(seed);
        await Git(seed, "init", "-q");
        var result = await GitCollector.RunRepoActionAsync(new RepoConfig(seed, null), RepoAction.Pull, Timeout);
        Assert.False(result.Ok);
        Assert.False(string.IsNullOrWhiteSpace(result.Error));
        Assert.DoesNotContain('\n', result.Error!);
    }
}
