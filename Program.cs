using System.Windows.Forms;

namespace BatteryDock;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new BatteryTrayContext());
    }
}
