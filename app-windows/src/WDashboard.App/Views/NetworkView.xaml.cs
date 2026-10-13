using Microsoft.UI.Xaml.Controls;
using WDashboard.App.ViewModels;

namespace WDashboard.App.Views;

public sealed partial class NetworkView : UserControl
{
    public NetworkView(NetworkViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public NetworkViewModel ViewModel { get; }
}
