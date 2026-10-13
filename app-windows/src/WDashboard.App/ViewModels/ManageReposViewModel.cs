// "Manage repos" dialog (docs/sdd.md §4.1): the only place that writes the
// config file. On success the owner reloads config and does a whole refresh.

using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed record ManagedRepo(string DisplayName, string Path, string? ConfigName);

public sealed partial class ManageReposViewModel : ObservableObject
{
    private readonly string _configPath;
    private readonly Action _onChanged;

    public ManageReposViewModel(string configPath, IEnumerable<RepoConfig> repos, Action onChanged)
    {
        _configPath = configPath;
        _onChanged = onChanged;
        SetRepos(repos);
    }

    public ObservableCollection<ManagedRepo> Repos { get; } = [];

    [ObservableProperty]
    public partial string PathText { get; set; } = "";

    [ObservableProperty]
    public partial string NameText { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    public partial string FormError { get; private set; } = "";

    /// <summary>Expanded path of the repo being edited; <c>null</c> in add mode.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEditing), nameof(IsAdding), nameof(FormTitle))]
    public partial string? EditingPath { get; private set; }

    public bool HasError => FormError.Length > 0;
    public bool IsEditing => EditingPath is not null;
    public bool IsAdding => EditingPath is null;
    public string FormTitle => IsEditing ? "Edit repo" : "Add repo";

    public void SetRepos(IEnumerable<RepoConfig> repos)
    {
        Repos.Clear();
        foreach (var r in repos)
            Repos.Add(new ManagedRepo(string.IsNullOrEmpty(r.Name) ? Paths.LastComponent(r.Path) : r.Name, r.Path, r.Name));
    }

    [RelayCommand]
    private void Add()
    {
        var path = PathText.Trim();
        var name = NameText.Trim();
        if (path.Length == 0)
        {
            FormError = "Path cannot be empty";
            return;
        }
        Write(() => RepoConfigFile.AddRepo(_configPath, path, name.Length == 0 ? null : name));
    }

    [RelayCommand]
    private void Save()
    {
        if (EditingPath is not { } target) return;
        var path = PathText.Trim();
        var name = NameText.Trim();
        if (path.Length == 0)
        {
            FormError = "Path cannot be empty";
            return;
        }
        Write(() => RepoConfigFile.UpdateRepo(_configPath, target, path, name.Length == 0 ? null : name));
    }

    [RelayCommand]
    private void Cancel() => ResetForm();

    [RelayCommand]
    private void Edit(ManagedRepo repo)
    {
        EditingPath = repo.Path;
        PathText = repo.Path;
        NameText = repo.ConfigName ?? "";
        FormError = "";
    }

    [RelayCommand]
    private void Remove(ManagedRepo repo) => Write(() => RepoConfigFile.RemoveRepo(_configPath, repo.Path));

    private void Write(Action edit)
    {
        try
        {
            edit();
            ResetForm();
            _onChanged();
        }
        catch (ConfigException e)
        {
            FormError = e.Message;
        }
    }

    private void ResetForm()
    {
        EditingPath = null;
        PathText = "";
        NameText = "";
        FormError = "";
    }
}
