// One Repos row (docs/sdd.md §9 item 2, §7.5, §8.1). Pure rendering of a
// RepoStatus plus the row's transient UI state.

using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml.Media;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed partial class RepoRowViewModel : ObservableObject
{
    private readonly ReposViewModel _owner;

    public RepoRowViewModel(ReposViewModel owner, RepoStatus status)
    {
        _owner = owner;
        Status = status;
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Name), nameof(Branch), nameof(BadgeText), nameof(BadgeBrush), nameof(ShowPull),
        nameof(ShowPush), nameof(ShowFetch), nameof(Details), nameof(ErrorText), nameof(HasError), nameof(LastFetchText),
        nameof(HasLastFetch))]
    public partial RepoStatus Status { get; set; }

    /// <summary>Collection still in flight: neutral "Checking…" badge, no buttons (§8.1 rule 4).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(BadgeText), nameof(BadgeBrush), nameof(ShowPull), nameof(ShowPush),
        nameof(ShowFetch), nameof(ShowRowRefresh))]
    public partial bool Pending { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PullLabel), nameof(PushLabel), nameof(FetchLabel), nameof(ActionsEnabled))]
    public partial RepoAction? BusyAction { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ActionsEnabled), nameof(RefreshIconOpacity))]
    public partial bool RowRefreshing { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ResultText), nameof(ResultBrush), nameof(HasResult))]
    public partial GitActionResult? ActionResult { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(DetailsLabel))]
    public partial bool Expanded { get; set; }

    public string Path => Status.Path;
    public string Name => Status.Name;
    public string Branch => Status.Branch ?? "detached";

    public string BadgeText => Pending ? "Checking…" : Status.State switch
    {
        RepoState.Clean => "Clean",
        RepoState.Dirty => "Dirty",
        RepoState.NeedsPush => "Needs Push",
        RepoState.NeedsPull => "Needs Pull",
        RepoState.Diverged => "Diverged",
        RepoState.NoUpstream => "No Upstream",
        _ => "Error",
    };

    public SolidColorBrush BadgeBrush => Palette.Brush(Pending ? Palette.Gray : Palette.RepoState(Status.State));

    private AllowedActions Allowed => Git.AllowedActionsFor(Status.State);
    private bool ButtonsVisible => !Pending && string.IsNullOrEmpty(Status.Error);

    public bool ShowPull => ButtonsVisible && Allowed.Pull;
    public bool ShowPush => ButtonsVisible && Allowed.Push;

    /// <summary>Only when <c>fetch_remote</c> is off; otherwise every refresh already fetches (§7.5).</summary>
    public bool ShowFetch => ButtonsVisible && Allowed.Fetch && !_owner.FetchRemote;

    public bool ShowRowRefresh => !Pending;

    public string PullLabel => BusyAction == RepoAction.Pull ? "Pulling…" : "Pull";
    public string PushLabel => BusyAction == RepoAction.Push ? "Pushing…" : "Push";
    public string FetchLabel => BusyAction == RepoAction.Fetch ? "Fetching…" : "Fetch";

    public bool ActionsEnabled => BusyAction is null && !RowRefreshing && !_owner.Refreshing;

    public double RefreshIconOpacity => RowRefreshing ? 0 : 1;

    public bool HasResult => ActionResult is not null;
    public string ResultText => ActionResult is null ? "" : ActionResult.Ok ? ActionResult.Summary : ActionResult.Error ?? "action failed";
    public SolidColorBrush ResultBrush => Palette.Brush(ActionResult?.Ok == true ? Palette.Green : Palette.Red);

    public string DetailsLabel => Expanded ? "Hide" : "Details";

    public string Details =>
        $"ahead {Status.Ahead} · behind {Status.Behind} · staged {Status.Staged} · modified {Status.Modified} · " +
        $"untracked {Status.Untracked} · conflicted {Status.Conflicted}";

    public bool HasError => !string.IsNullOrEmpty(Status.Error);
    public string ErrorText => Status.Error ?? "";

    public bool HasLastFetch => Status.LastFetchAt is not null;
    public string LastFetchText => Status.LastFetchAt is { } t
        ? "last fetch: " + DateTimeOffset.FromUnixTimeSeconds(t).ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture)
        : "";

    public void NotifyOwnerChanged()
    {
        OnPropertyChanged(nameof(ActionsEnabled));
        OnPropertyChanged(nameof(ShowFetch));
    }

    [RelayCommand]
    private void ToggleExpanded() => Expanded = !Expanded;

    [RelayCommand]
    private Task Pull() => _owner.RunActionAsync(this, RepoAction.Pull);

    [RelayCommand]
    private Task Push() => _owner.RunActionAsync(this, RepoAction.Push);

    [RelayCommand]
    private Task Fetch() => _owner.RunActionAsync(this, RepoAction.Fetch);

    [RelayCommand]
    private Task RefreshRow() => _owner.RefreshRowAsync(this);
}
