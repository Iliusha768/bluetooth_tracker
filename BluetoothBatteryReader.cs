using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

namespace BatteryDock;

internal sealed record BatteryDevice(string Id, string Name, int? Percent);

internal static class BluetoothBatteryReader
{
    private static readonly string[] RequestedProperties =
    [
        "System.Devices.Aep.IsConnected",
        "System.Devices.BatteryLife",
        "System.Devices.Aep.DeviceAddress"
    ];

    public static async Task<IReadOnlyList<BatteryDevice>> ReadAsync()
    {
        var byAddress = new Dictionary<string, BatteryDevice>(StringComparer.OrdinalIgnoreCase);

        await CollectAsync(BluetoothLEDevice.GetDeviceSelector(), isLe: true, byAddress);
        await CollectAsync(BluetoothDevice.GetDeviceSelector(), isLe: false, byAddress);

        return byAddress.Values.OrderBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    private static async Task CollectAsync(
        string selector, bool isLe, Dictionary<string, BatteryDevice> devices)
    {
        var found = await DeviceInformation.FindAllAsync(
            selector, RequestedProperties, DeviceInformationKind.AssociationEndpoint);

        foreach (var item in found)
        {
            if (!item.Properties.TryGetValue("System.Devices.Aep.IsConnected", out var connected)
                || connected is not bool || !(bool)connected)
                continue;

            string address = item.Properties.TryGetValue("System.Devices.Aep.DeviceAddress", out var rawAddress)
                ? rawAddress?.ToString() ?? item.Id : item.Id;
            int? percent = ReadProperty(item);

            // GATT works for LE devices that implement the standard Battery Service.
            // A single device can appear in both enumerations, so keep one entry per address.
            if (isLe && percent is null)
            {
                try { percent = await ReadGattAsync(item.Id); }
                catch (Exception) { /* The device may deny access or disconnect while reading. */ }
            }

            string name = string.IsNullOrWhiteSpace(item.Name) ? "Bluetooth-устройство" : item.Name;
            var current = new BatteryDevice(item.Id, name, percent);
            if (!devices.TryGetValue(address, out var previous)
                || (previous.Percent is null && current.Percent is not null))
                devices[address] = current;
        }
    }

    private static int? ReadProperty(DeviceInformation item)
    {
        if (!item.Properties.TryGetValue("System.Devices.BatteryLife", out var value) || value is null)
            return null;

        try
        {
            int percent = Convert.ToInt32(value);
            // Windows uses 101 for an unknown battery state.
            return percent is >= 0 and <= 100 ? percent : null;
        }
        catch (Exception) { return null; }
    }

    private static async Task<int?> ReadGattAsync(string id)
    {
        using var device = await BluetoothLEDevice.FromIdAsync(id);
        if (device is null || device.ConnectionStatus != BluetoothConnectionStatus.Connected)
            return null;

        var services = await device.GetGattServicesForUuidAsync(
            GattServiceUuids.Battery, BluetoothCacheMode.Cached);
        if (services.Status != GattCommunicationStatus.Success)
            return null;

        int? percent = null;
        foreach (var service in services.Services)
        {
            using (service)
            {
                var characteristics = await service.GetCharacteristicsForUuidAsync(
                    GattCharacteristicUuids.BatteryLevel, BluetoothCacheMode.Cached);
                if (characteristics.Status != GattCommunicationStatus.Success)
                    continue;

                foreach (var characteristic in characteristics.Characteristics)
                {
                    if (!characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Read))
                        continue;

                    var result = await characteristic.ReadValueAsync(BluetoothCacheMode.Uncached);
                    if (result.Status != GattCommunicationStatus.Success || result.Value.Length < 1)
                        continue;

                    var reader = DataReader.FromBuffer(result.Value);
                    int value = reader.ReadByte();
                    if (value is >= 0 and <= 100)
                    {
                        percent = value;
                        break;
                    }
                }
            }
        }

        return percent;
    }
}
