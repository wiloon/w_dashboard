using System.Text.Json;
using System.Text.Json.Serialization;

namespace WDashboard.Core.Tests;

/// <summary>Locates and loads docs/test-vectors/ (the cross-end consistency gate, docs/sdd.md §10).</summary>
internal static class Vectors
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        Converters = { new JsonStringEnumConverter() },
    };

    private static readonly Lazy<string> RootDir = new(() =>
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "docs", "test-vectors");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("docs/test-vectors not found above " + AppContext.BaseDirectory);
    });

    public static string PathOf(string subdir, string file) => Path.Combine(RootDir.Value, subdir, file);

    /// <summary>One xUnit case per <c>*.json</c> file in <paramref name="subdir"/>, by file name.</summary>
    public static TheoryData<string> Files(string subdir)
    {
        var files = Directory.GetFiles(Path.Combine(RootDir.Value, subdir), "*.json")
            .Select(Path.GetFileName)
            .Order(StringComparer.Ordinal)
            .ToList();
        if (files.Count == 0) throw new InvalidOperationException($"no vectors in {subdir}");
        var data = new TheoryData<string>();
        foreach (var f in files) data.Add(f!);
        return data;
    }

    public static T Load<T>(string subdir, string file) =>
        JsonSerializer.Deserialize<T>(File.ReadAllText(PathOf(subdir, file)), Json)
        ?? throw new InvalidDataException($"{subdir}/{file} deserialized to null");

    public static JsonDocument LoadDocument(string subdir, string file) =>
        JsonDocument.Parse(File.ReadAllText(PathOf(subdir, file)));
}

internal sealed record Vector<TInput, TExpected>(TInput Input, TExpected Expected);
