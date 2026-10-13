using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WDashboard.App.ViewModels;

namespace WDashboard.App.Views;

public sealed partial class ManageReposView : UserControl
{
    public ManageReposView(ManageReposViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public ManageReposViewModel ViewModel { get; }

    private void OnEditClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is ManagedRepo repo) ViewModel.EditCommand.Execute(repo);
    }

    private void OnRemoveClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is ManagedRepo repo) ViewModel.RemoveCommand.Execute(repo);
    }
}
