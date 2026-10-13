namespace WDashboard.Core.Tests;

public class GitVectorTests
{
    public static TheoryData<string> PorcelainFiles => Vectors.Files("git-porcelain");
    public static TheoryData<string> RepoStateFiles => Vectors.Files("repo-state");
    public static TheoryData<string> RepoActionFiles => Vectors.Files("repo-actions");

    private sealed record RepoStateInput(
        int Ahead, int Behind, int Staged, int Modified, int Untracked, int Conflicted, bool HasUpstream, string? Error);

    [Theory]
    [MemberData(nameof(PorcelainFiles))]
    public void GitPorcelain(string file)
    {
        var v = Vectors.Load<Vector<string, ParsedGitStatus>>("git-porcelain", file);
        Assert.Equal(v.Expected, Git.ParsePorcelainV2(v.Input));
    }

    [Theory]
    [MemberData(nameof(RepoStateFiles))]
    public void RepoStateDerivation(string file)
    {
        var v = Vectors.Load<Vector<RepoStateInput, RepoState>>("repo-state", file);
        var i = v.Input;
        var input = new DeriveInput(i.Ahead, i.Behind, i.Staged, i.Modified, i.Untracked, i.Conflicted, i.HasUpstream, i.Error);
        Assert.Equal(v.Expected, Git.DeriveState(input));
    }

    [Theory]
    [MemberData(nameof(RepoActionFiles))]
    public void RepoActions(string file)
    {
        var v = Vectors.Load<Vector<RepoState, AllowedActions>>("repo-actions", file);
        Assert.Equal(v.Expected, Git.AllowedActionsFor(v.Input));
    }
}
