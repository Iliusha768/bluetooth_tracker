using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BatteryDock;

internal sealed class BatteryTrayContext : ApplicationContext
{
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 60_000 };
    private readonly List<NotifyIcon> _icons = [];
    private bool _refreshing;

    public BatteryTrayContext()
    {
        SetIcons([new BatteryDevice("status", "Поиск Bluetooth-устройств…", null)]);
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();
        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            var devices = await BluetoothBatteryReader.ReadAsync();
            SetIcons(devices.Count == 0
                ? [new BatteryDevice("status", "Подключённые Bluetooth-устройства не найдены", null)]
                : devices);
        }
        catch (Exception error)
        {
            SetIcons([new BatteryDevice("status", "Не удалось прочитать устройства: " + error.Message, null)]);
        }
        finally { _refreshing = false; }
    }

    private void SetIcons(IReadOnlyList<BatteryDevice> devices)
    {
        foreach (var old in _icons)
        {
            old.Visible = false;
            old.ContextMenuStrip?.Dispose();
            old.Icon?.Dispose();
            old.Dispose();
        }
        _icons.Clear();

        foreach (var device in devices)
        {
            var menu = new ContextMenuStrip();
            var heading = new ToolStripMenuItem($"{device.Name}: {FormatPercent(device.Percent)}")
            { Enabled = false };
            menu.Items.Add(heading);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Обновить", null, async (_, _) => await RefreshAsync());
            menu.Items.Add("Выход", null, (_, _) => ExitThread());

            var icon = new NotifyIcon
            {
                Icon = MakeIcon(device.Percent),
                Text = Truncate($"{device.Name}: {FormatPercent(device.Percent)}", 63),
                ContextMenuStrip = menu,
                Visible = true
            };
            icon.MouseClick += (_, e) =>
            {
                if (e.Button == MouseButtons.Left)
                    menu.Show(Cursor.Position);
            };
            _icons.Add(icon);
        }
    }

    private static string FormatPercent(int? value) => value is null ? "нет данных" : $"{value}%";
    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..(max - 1)] + "…";

    private static Icon MakeIcon(int? value)
    {
        using var bitmap = new Bitmap(64, 64);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            var color = value switch
            {
                <= 15 => Color.FromArgb(190, 48, 48),
                <= 35 => Color.FromArgb(190, 120, 28),
                null => Color.FromArgb(65, 72, 84),
                _ => Color.FromArgb(35, 122, 80)
            };
            using var brush = new SolidBrush(color);
            using var outline = new GraphicsPath();
            outline.AddArc(1, 1, 28, 28, 180, 90);
            outline.AddArc(35, 1, 28, 28, 270, 90);
            outline.AddArc(35, 35, 28, 28, 0, 90);
            outline.AddArc(1, 35, 28, 28, 90, 90);
            outline.CloseFigure();
            graphics.FillPath(brush, outline);
            string label = value is null ? "?" : $"{value}%";
            float fontSize = label.Length >= 4 ? 21 : label.Length == 3 ? 27 : 38;
            using var font = new Font("Segoe UI", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
            using var textBrush = new SolidBrush(Color.White);
            using var format = new StringFormat
            { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            graphics.DrawString(label, font, textBrush, new RectangleF(1, 0, 62, 62), format);
        }

        IntPtr handle = bitmap.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    protected override void ExitThreadCore()
    {
        _timer.Stop();
        _timer.Dispose();
        foreach (var icon in _icons)
        {
            icon.Visible = false;
            icon.ContextMenuStrip?.Dispose();
            icon.Icon?.Dispose();
            icon.Dispose();
        }
        _icons.Clear();
        base.ExitThreadCore();
    }
}
