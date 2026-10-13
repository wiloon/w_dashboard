using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WDashboard.App.ViewModels;
using WDashboard.App.Views;
using Windows.Graphics;

namespace WDashboard.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        ViewModel = new MainViewModel(DispatcherQueue);
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon("Assets/AppIcon.ico");

        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)(920 * scale), (int)(720 * scale)));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(760 * scale);
            presenter.PreferredMinimumHeight = (int)(560 * scale);
        }

        DashboardHost.Content = new DashboardView(ViewModel);
        if (ViewModel.NetworkEnabled) NetworkHost.Content = new NetworkView(ViewModel.Network);

        Closed += (_, _) => ViewModel.Dispose();
        ViewModel.Start();
    }

    public MainViewModel ViewModel { get; }

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (DashboardHost is null || NetworkHost is null) return;
        var network = sender.SelectedItem == NetworkTab;
        DashboardHost.Visibility = network ? Visibility.Collapsed : Visibility.Visible;
        NetworkHost.Visibility = network ? Visibility.Visible : Visibility.Collapsed;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
