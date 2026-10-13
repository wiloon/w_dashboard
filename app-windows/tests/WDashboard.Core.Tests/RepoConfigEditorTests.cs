// "Manage repos" write-back (docs/sdd.md §4.1): other lines stay byte-for-byte,
// and loading sees the result. Mirrors app-macos ConfigRepoCrudTests, plus the
// Windows rules (case-insensitive path match, CRLF and BOM preserved).

using System.Text;

namespace WDashboard.Core.Tests;

public class RepoConfigEditorTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    [Fact]
    public void AddThenRemoveRoundTripsAndPreservesOtherSections()
    {
        var path = _dir.Write("config.toml", "# a comment that must survive\n[general]\nrefresh_interval_secs = 60\n");

        RepoConfigFile.AddRepo(path, @"C:\tmp\some\repo", "myrepo");
        var cfg = ConfigLoader.Load(path);
        Assert.Equal([new RepoConfig(@"C:\tmp\some\repo", "myrepo")], cfg.Repos);
        Assert.Equal(60, cfg.RefreshIntervalSecs);
        Assert.Contains("path = \"C:\\\\tmp\\\\some\\\\repo\"", File.ReadAllText(path));

        RepoConfigFile.RemoveRepo(path, @"C:\tmp\some\repo");
        Assert.Empty(ConfigLoader.Load(path).Repos);
        Assert.Equal("# a comment that must survive\n[general]\nrefresh_interval_secs = 60\n", File.ReadAllText(path));
    }

    [Fact]
    public void UpdateChangesPathAndNameInPlace()
    {
        var path = _dir.Write("config.toml", "[[repos]]\npath = \"/tmp/old/path\"\nname = \"old-name\"\n\n[weather]\nlocation = \"Beijing\"\n");

        RepoConfigFile.UpdateRepo(path, "/tmp/old/path", "/tmp/new/path", "new-name");

        Assert.Equal("[[repos]]\npath = \"/tmp/new/path\"\nname = \"new-name\"\n[weather]\nlocation = \"Beijing\"\n", File.ReadAllText(path));
        Assert.Equal([new RepoConfig("/tmp/new/path", "new-name")], ConfigLoader.Load(path).Repos);
    }

    [Fact]
    public void AddCreatesMissingFileAndDirectory()
    {
        var path = Path.Combine(_dir.Path, "nested", "config.toml");

        RepoConfigFile.AddRepo(path, "/tmp/fresh/repo", null);

        Assert.Equal("[[repos]]\npath = \"/tmp/fresh/repo\"\n", File.ReadAllText(path));
        Assert.Equal([new RepoConfig("/tmp/fresh/repo", null)], ConfigLoader.Load(path).Repos);
    }

    [Fact]
    public void AddAppendsNewlineWhenMissing()
    {
        Assert.Equal("a = 1\n[[repos]]\npath = \"x\"\n", RepoConfigEditor.Add("a = 1", "x", ""));
    }

    [Fact]
    public void MatchIsCaseInsensitiveAndSeparatorAgnostic()
    {
        var text = "[[repos]]\npath = \"C:/Src/Foo/\"\n[[repos]]\npath = \"C:/src/bar\"\n";
        Assert.Equal("[[repos]]\npath = \"C:/src/bar\"\n", RepoConfigEditor.Remove(text, @"c:\src\foo"));
    }

    [Fact]
    public void MatchUsesExpandedPath()
    {
        var raw = "[[repos]]\npath = \"~/proj\" # mine\n";
        Assert.Equal("", RepoConfigEditor.Remove(raw, Path.Combine(Paths.Home, "proj")));
    }

    [Fact]
    public void OnlyFirstMatchingBlockIsRemoved()
    {
        var text = "[[repos]]\npath = \"/a\"\n[[repos]]\npath = \"/a\"\n";
        Assert.Equal("[[repos]]\npath = \"/a\"\n", RepoConfigEditor.Remove(text, "/a"));
    }

    [Fact]
    public void NoMatchLeavesTextUnchanged()
    {
        var text = "[[repos]]\npath = \"/a\"\n";
        Assert.Same(text, RepoConfigEditor.Remove(text, "/b"));
        Assert.Same(text, RepoConfigEditor.Update(text, "/b", "/c", null));
    }

    [Fact]
    public void CrlfIsPreserved()
    {
        var text = "[general]\r\nfetch_remote = true\r\n[[repos]]\r\npath = \"/a\"\r\n";
        var added = RepoConfigEditor.Add(text, "/b", "b");
        Assert.Equal(text + "[[repos]]\r\npath = \"/b\"\r\nname = \"b\"\r\n", added);
        Assert.Equal("[general]\r\nfetch_remote = true\r\n[[repos]]\r\npath = \"/z\"\r\n[[repos]]\r\npath = \"/b\"\r\nname = \"b\"\r\n",
            RepoConfigEditor.Update(added, "/a", "/z", null));
    }

    [Fact]
    public void BomIsPreserved()
    {
        var path = _dir.File("config.toml");
        File.WriteAllText(path, "[general]\n", new UTF8Encoding(true));

        RepoConfigFile.AddRepo(path, "/a", null);

        var bytes = File.ReadAllBytes(path);
        Assert.Equal([0xEF, 0xBB, 0xBF], bytes[..3]);
        Assert.Equal("[general]\n[[repos]]\npath = \"/a\"\n", Encoding.UTF8.GetString(bytes[3..]));
    }

    [Fact]
    public void QuotesAreEscaped()
    {
        Assert.Equal("[[repos]]\npath = \"a\\\"b\"\n", RepoConfigEditor.Add("", "a\"b", null));
    }
}
