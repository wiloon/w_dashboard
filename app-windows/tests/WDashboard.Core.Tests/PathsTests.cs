namespace WDashboard.Core.Tests;

public class PathsTests
{
    public PathsTests() => Environment.SetEnvironmentVariable("WD_PATHS_TEST", "VAL");

    [Theory]
    [InlineData("%WD_PATHS_TEST%\\x", "VAL\\x")]
    [InlineData("$WD_PATHS_TEST/x", "VAL/x")]
    [InlineData("${WD_PATHS_TEST}x", "VALx")]
    [InlineData("%WD_NOPE_UNSET%\\x", "%WD_NOPE_UNSET%\\x")]
    [InlineData("$WD_NOPE_UNSET/x", "$WD_NOPE_UNSET/x")]
    [InlineData("${WD_NOPE_UNSET}", "${WD_NOPE_UNSET}")]
    [InlineData("100% sure $", "100% sure $")]
    public void ExpandEnv(string input, string expected) => Assert.Equal(expected, Paths.ExpandEnv(input));

    [Fact]
    public void ExpandTilde()
    {
        Assert.Equal(Paths.Home, Paths.Expand("~"));
        Assert.Equal(Path.Combine(Paths.Home, "a"), Paths.Expand("~/a"));
        Assert.Equal(Path.Combine(Paths.Home, "a"), Paths.Expand("~\\a"));
        Assert.Equal("a~", Paths.Expand("a~"));
    }

    [Theory]
    [InlineData(@"C:\Src\Foo", "c:/src/foo/", true)]
    [InlineData(@"C:\src\foo", @"C:\src\foo2", false)]
    public void SamePath(string a, string b, bool expected) => Assert.Equal(expected, Paths.SamePath(a, b));

    [Theory]
    [InlineData(@"C:\src\foo\", "foo")]
    [InlineData("C:/src/bar", "bar")]
    public void LastComponent(string path, string expected) => Assert.Equal(expected, Paths.LastComponent(path));

    [Fact]
    public void DefaultConfigPathHonoursXdg()
    {
        var old = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        try
        {
            Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", @"D:\cfg");
            Assert.Equal(@"D:\cfg\w_dashboard\config.toml", Paths.DefaultConfigPath());
            Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", null);
            Assert.Equal(Path.Combine(Paths.Home, ".config", "w_dashboard", "config.toml"), Paths.DefaultConfigPath());
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", old);
        }
    }
}
