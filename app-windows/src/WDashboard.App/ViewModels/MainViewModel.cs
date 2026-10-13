// Top-level state and refresh orchestration (docs/sdd.md §8): config load,
// check_environment, the 1s clock tick, the auto-refresh timer and the
// sections. Mirrors app-macos AppState.

using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly DispatcherQueueTimer _clockTimer;
    private readonly DispatcherQueueTimer _refreshTimer;
    private bool _started;

    public MainViewModel(DispatcherQueue dispatcher)
    {
        ConfigPath = Paths.DefaultConfigPath();
        Config config;
        try
        {
            config = ConfigLoader.Load(ConfigPath);
        }
        catch (ConfigException e)
        {
            ConfigError = $"Config error: {e.Message} — using defaults";
            config = new Config();
        }
        Config = config;

        Pomodoro = new PomodoroViewModel(config.Pomodoro, dispatcher);
        Clocks = new ClocksViewModel(config.Clocks);
        Repos = new ReposViewModel(config);
        Weather = new WeatherViewModel(config);
        Network = new NetworkViewModel(config.Network, dispatcher);

        _clockTimer = dispatcher.CreateTimer();
        _clockTimer.Interval = TimeSpan.FromSeconds(1);
        _clockTimer.Tick += (_, _) => Clocks.Tick();
        _refreshTimer = dispatcher.CreateTimer();
        _refreshTimer.Tick += (_, _) => RefreshAll();
    }

    public string ConfigPath { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NetworkEnabled))]
    public partial Config Config { get; private set; }

    public string? ConfigError { get; }
    public bool HasConfigError => ConfigError is not null;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasEnvironmentWarning))]
    public partial string? EnvironmentWarning { get; private set; }

    public bool HasEnvironmentWarning => EnvironmentWarning is not null;

    public bool NetworkEnabled => Config.Network.Enabled;

    public PomodoroViewModel Pomodoro { get; }
    public ClocksViewModel Clocks { get; }
    public ReposViewModel Repos { get; }
    public WeatherViewModel Weather { get; }
    public NetworkViewModel Network { get; }

    /// <summary>Called once the window is up: environment check, first collection, timers.</summary>
    public void Start()
    {
        if (_started) return;
        _started = true;
        _ = CheckEnvironmentAsync();
        RefreshAll();
        Clocks.Tick();
        _clockTimer.Start();
        StartRefreshTimer();
        Pomodoro.Start();
        Network.Start();
    }

    public void RefreshAll()
    {
        Repos.Refresh();
        _ = Weather.RefreshAsync();
    }

    public ManageReposViewModel CreateManageRepos()
    {
        ManageReposViewModel? vm = null;
        vm = new ManageReposViewModel(ConfigPath, Config.Repos, () =>
        {
            ReloadAndRefresh();
            vm!.SetRepos(Config.Repos);
        });
        return vm;
    }

    /// <summary>After a <c>Manage…</c> edit: reload config (keeping the old one on failure) and refresh.</summary>
    private void ReloadAndRefresh()
    {
        try
        {
            var reloaded = ConfigLoader.Load(ConfigPath);
            Config = reloaded;
            Clocks.Reset(reloaded.Clocks);
            Repos.UpdateConfig(reloaded);
            Weather.UpdateConfig(reloaded);
        }
        catch (ConfigException)
        {
        }
        RefreshAll();
    }

    private async Task CheckEnvironmentAsync()
    {
        var env = await Task.Run(() => GitCollector.CheckEnvironmentAsync());
        EnvironmentWarning = env.Git is null ? "git not found in PATH — repo status unavailable" : null;
    }

    private void StartRefreshTimer()
    {
        _refreshTimer.Stop();
        if (Config.RefreshIntervalSecs <= 0) return;
        _refreshTimer.Interval = TimeSpan.FromSeconds(Config.RefreshIntervalSecs);
        _refreshTimer.Start();
    }

    public void Dispose()
    {
        _clockTimer.Stop();
        _refreshTimer.Stop();
        Pomodoro.Stop();
        Network.Dispose();
    }
}
