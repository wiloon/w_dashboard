// Repos section orchestration (docs/sdd.md §8 / §8.1, ADR-010): concurrency 4,
// stable row order, seeded rows, "Checking…" badges, generation tokens and the
// finish semantics; plus the §7.5 actions and the per-row refresh. Runs on the
// UI thread; collection itself runs on the thread pool.

using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed partial class ReposViewModel : ObservableObject
{
    private readonly SemaphoreSlim _gate = new(4);
    private Config _config;
    private int _token;
    private int _pending;

    public ReposViewModel(Config config) => _config = config;

    public ObservableCollection<RepoRowViewModel> Rows { get; } = [];

    public bool FetchRemote => _config.FetchRemote;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRefresh))]
    public partial bool Refreshing { get; private set; }

    [ObservableProperty]
    public partial string LastUpdated { get; private set; } = "never";

    [ObservableProperty]
    public partial bool IsEmpty { get; private set; } = true;

    public bool CanRefresh => !Refreshing;

    partial void OnRefreshingChanged(bool value)
    {
        foreach (var row in Rows) row.NotifyOwnerChanged();
    }

    public void UpdateConfig(Config config)
    {
        _config = config;
        foreach (var row in Rows) row.NotifyOwnerChanged();
    }

    /// <summary>Whole-list refresh (§8.1).</summary>
    [RelayCommand]
    public void Refresh()
    {
        var token = ++_token;
        var repos = _config.Repos;

        var previous = Rows.ToList();
        Rows.Clear();
        foreach (var repo in repos)
        {
            var name = string.IsNullOrEmpty(repo.Name) ? Paths.LastComponent(repo.Path) : repo.Name;
            var known = previous.FirstOrDefault(r => Paths.SamePath(r.Path, repo.Path));
            var seed = known is null
                ? new RepoStatus { Name = name, Path = repo.Path }
                : known.Status with { Name = name };
            Rows.Add(new RepoRowViewModel(this, seed) { Pending = true });
        }
        IsEmpty = Rows.Count == 0;
        _pending = Rows.Count;
        Refreshing = _pending > 0;
        if (_pending == 0) Touch();

        var fetchRemote = _config.FetchRemote;
        var timeout = _config.CommandTimeout;
        for (var i = 0; i < repos.Count; i++)
        {
            var index = i;
            var repo = repos[i];
            _ = CollectAsync(repo, fetchRemote, timeout).ContinueWith(
                t => Apply(index, token, t.Result),
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnRanToCompletion,
                TaskScheduler.FromCurrentSynchronizationContext());
        }
    }

    private void Apply(int index, int token, RepoStatus status)
    {
        if (token != _token || index >= Rows.Count) return;
        Land(Rows[index], status);
    }

    /// <summary>§7.5: run the action, then re-collect the row with <c>fetch_remote=false</c>.</summary>
    public async Task RunActionAsync(RepoRowViewModel row, RepoAction action)
    {
        if (!row.ActionsEnabled) return;
        var repo = FindRepo(row.Path);
        if (repo is null) return;

        row.BusyAction = action;
        row.ActionResult = null;
        var timeout = _config.CommandTimeout;
        var (result, status) = await Gated(async () =>
        {
            var r = await GitCollector.RunRepoActionAsync(repo, action, timeout);
            var s = await GitCollector.CollectRepoAsync(repo, fetchRemote: false, timeout);
            return (r, s);
        });
        row.BusyAction = null;
        row.ActionResult = result;
        Land(row, status);
    }

    /// <summary>§8.1 targeted single-row collection: no new token, clears the row's last result.</summary>
    public async Task RefreshRowAsync(RepoRowViewModel row)
    {
        if (!row.ActionsEnabled) return;
        var repo = FindRepo(row.Path);
        if (repo is null) return;

        row.RowRefreshing = true;
        row.ActionResult = null;
        var status = await CollectAsync(repo, _config.FetchRemote, _config.CommandTimeout);
        row.RowRefreshing = false;
        Land(row, status);
    }

    private void Land(RepoRowViewModel row, RepoStatus status)
    {
        if (!Rows.Contains(row)) return;
        row.Status = status;
        if (row.Pending)
        {
            row.Pending = false;
            if (--_pending == 0) Refreshing = false;
        }
        Touch();
    }

    private RepoConfig? FindRepo(string path) => _config.Repos.FirstOrDefault(r => Paths.SamePath(r.Path, path));

    private Task<RepoStatus> CollectAsync(RepoConfig repo, bool fetchRemote, TimeSpan timeout) =>
        Gated(() => GitCollector.CollectRepoAsync(repo, fetchRemote, timeout));

    private async Task<T> Gated<T>(Func<Task<T>> work)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return await Task.Run(work).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private void Touch() => LastUpdated = DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture);
}
