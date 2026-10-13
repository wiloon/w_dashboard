using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WDashboard.App.ViewModels;

namespace WDashboard.App.Views;

public sealed partial class DashboardView : UserControl
{
    public DashboardView(MainViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public MainViewModel ViewModel { get; }

    private async void OnManageClick(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Manage repos",
            Content = new ManageReposView(ViewModel.CreateManageRepos()),
            CloseButtonText = "Done",
        };
        dialog.Resources["ContentDialogMaxWidth"] = 640.0;
        await dialog.ShowAsync();
    }
}
