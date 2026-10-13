// Display-only link info (docs/sdd.md §12.7, Windows bullets): default-route
// interface, VPN, system proxy and the Wi-Fi link via the Native WLAN API.
// Not part of the cross-end model and not covered by test vectors.

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using WDashboard.Core;

namespace WDashboard.App.Services;

/// <summary>
/// <see cref="Ssid"/> is null when Windows denies WLAN access for lack of the
/// Location permission (<see cref="NeedsLocation"/>); other fields are null when unknown.
/// </summary>
public sealed record WifiInfo(string? Ssid, bool NeedsLocation, int? Rssi, double? RateMbps, int? Channel, string? Band);

public sealed record LinkInfo(bool PathAvailable, string? VpnName, bool SystemProxy, WifiInfo? Wifi, string Signature)
{
    public static LinkInfo Collect()
    {
        NetworkInterface[] nics;
        try
        {
            nics = NetworkInterface.GetAllNetworkInterfaces();
        }
        catch (NetworkInformationException)
        {
            nics = [];
        }

        var pathAvailable = nics.Any(n =>
            n.OperationalStatus == OperationalStatus.Up
            && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
            && Ipv4Gateway(n) is not null);

        var defaultNic = DefaultRouteInterface(nics);
        string? vpn = null;
        if (defaultNic is not null && IsVpn(defaultNic)) vpn = defaultNic.Name;

        var wifi = Wlan.Current();
        var physical = NetworkProbe.FindPhysicalAdapter();
        var signature = string.Join('#',
            pathAvailable,
            defaultNic?.Id ?? "-",
            physical?.Gateway.ToString() ?? "-",
            wifi?.Ssid ?? "-",
            wifi?.Channel?.ToString() ?? "-");

        return new LinkInfo(pathAvailable, vpn, SystemProxyEnabled(), wifi, signature);
    }

    private static IPAddress? Ipv4Gateway(NetworkInterface nic)
    {
        try
        {
            return nic.GetIPProperties().GatewayAddresses
                .Select(g => g.Address)
                .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(IPAddress.Any));
        }
        catch (NetworkInformationException)
        {
            return null;
        }
    }

    private static readonly string[] VpnMarkers = ["WireGuard", "Wintun", "TAP"];

    private static bool IsVpn(NetworkInterface nic) =>
        nic.NetworkInterfaceType is NetworkInterfaceType.Ppp or NetworkInterfaceType.Tunnel
        || VpnMarkers.Any(m => nic.Description.Contains(m, StringComparison.OrdinalIgnoreCase));

    /// <summary>The interface Windows picks for a public address (<c>GetBestInterfaceEx</c> to 1.1.1.1).</summary>
    private static NetworkInterface? DefaultRouteInterface(NetworkInterface[] nics)
    {
        var sockaddr = new byte[16];
        sockaddr[0] = (byte)AddressFamily.InterNetwork;
        sockaddr[4] = 1;
        sockaddr[5] = 1;
        sockaddr[6] = 1;
        sockaddr[7] = 1;
        if (GetBestInterfaceEx(sockaddr, out var index) != 0) return null;
        foreach (var nic in nics)
        {
            try
            {
                if (nic.Supports(NetworkInterfaceComponent.IPv4) && nic.GetIPProperties().GetIPv4Properties().Index == index)
                    return nic;
            }
            catch (NetworkInformationException)
            {
            }
        }
        return null;
    }

    /// <summary>Manual proxy or PAC script in the current user's WinINET settings.</summary>
    private static bool SystemProxyEnabled()
    {
        var config = default(WinHttpCurrentUserIeProxyConfig);
        if (!WinHttpGetIEProxyConfigForCurrentUser(ref config)) return false;
        var enabled = config.Proxy != IntPtr.Zero || config.AutoConfigUrl != IntPtr.Zero;
        foreach (var p in new[] { config.AutoConfigUrl, config.Proxy, config.ProxyBypass })
        {
            if (p != IntPtr.Zero) GlobalFree(p);
        }
        return enabled;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinHttpCurrentUserIeProxyConfig
    {
        [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
        public IntPtr AutoConfigUrl;
        public IntPtr Proxy;
        public IntPtr ProxyBypass;
    }

    [DllImport("iphlpapi.dll")]
    private static extern int GetBestInterfaceEx(byte[] destAddr, out uint bestIfIndex);

    [DllImport("winhttp.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpGetIEProxyConfigForCurrentUser(ref WinHttpCurrentUserIeProxyConfig config);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalFree(IntPtr mem);
}

/// <summary>Native WLAN API (<c>wlanapi.dll</c>); offsets follow the wlanapi.h struct layouts.</summary>
internal static class Wlan
{
    private const uint ErrorAccessDenied = 5;
    private const int OpcodeCurrentConnection = 7;
    private const int OpcodeChannelNumber = 8;
    private const int OpcodeRssi = 0x10000102;
    private const int InterfaceStateConnected = 1;

    // WLAN_INTERFACE_INFO: GUID + WCHAR[256] + state.
    private const int InterfaceInfoSize = 16 + 512 + 4;
    // WLAN_CONNECTION_ATTRIBUTES: state, mode, WCHAR[256] profile, then WLAN_ASSOCIATION_ATTRIBUTES.
    private const int AssociationOffset = 4 + 4 + 512;
    // Inside WLAN_ASSOCIATION_ATTRIBUTES / WLAN_BSS_ENTRY.
    private const int SsidLengthOffset = 0;
    private const int SsidBytesOffset = 4;
    private const int AssocBssidOffset = 40;
    private const int AssocRxRateOffset = 60;
    private const int AssocTxRateOffset = 64;
    private const int BssEntrySize = 360;
    private const int BssBssidOffset = 40;
    private const int BssCenterFrequencyOffset = 92;

    public static WifiInfo? Current()
    {
        if (WlanOpenHandle(2, IntPtr.Zero, out _, out var handle) != 0) return null;
        try
        {
            if (WlanEnumInterfaces(handle, IntPtr.Zero, out var list) != 0) return null;
            Guid? connected = null;
            try
            {
                var count = Marshal.ReadInt32(list, 0);
                for (var i = 0; i < count; i++)
                {
                    var item = list + 8 + i * InterfaceInfoSize;
                    if (Marshal.ReadInt32(item, 16 + 512) != InterfaceStateConnected) continue;
                    connected = Marshal.PtrToStructure<Guid>(item);
                    break;
                }
            }
            finally
            {
                WlanFreeMemory(list);
            }
            return connected is { } guid ? Query(handle, guid) : null;
        }
        finally
        {
            WlanCloseHandle(handle, IntPtr.Zero);
        }
    }

    private static WifiInfo Query(IntPtr handle, Guid guid)
    {
        string? ssid = null;
        double? rate = null;
        byte[]? bssid = null;
        var needsLocation = false;

        var rc = WlanQueryInterface(handle, ref guid, OpcodeCurrentConnection, IntPtr.Zero, out _, out var data, IntPtr.Zero);
        if (rc == 0)
        {
            try
            {
                var assoc = data + AssociationOffset;
                var len = Math.Min(32, Marshal.ReadInt32(assoc, SsidLengthOffset));
                var bytes = new byte[len];
                Marshal.Copy(assoc + SsidBytesOffset, bytes, 0, len);
                ssid = Encoding.UTF8.GetString(bytes);
                bssid = new byte[6];
                Marshal.Copy(assoc + AssocBssidOffset, bssid, 0, 6);
                var rx = (uint)Marshal.ReadInt32(assoc, AssocRxRateOffset);
                var tx = (uint)Marshal.ReadInt32(assoc, AssocTxRateOffset);
                rate = Math.Max(rx, tx) / 1000.0;
            }
            finally
            {
                WlanFreeMemory(data);
            }
        }
        else if (rc == ErrorAccessDenied)
        {
            needsLocation = true;
        }

        int? rssi = ReadInt(handle, guid, OpcodeRssi);
        var (channel, band) = bssid is null ? (null, null) : ChannelFromBss(handle, guid, bssid);
        if (channel is null && ReadInt(handle, guid, OpcodeChannelNumber) is { } ch)
        {
            channel = ch;
            band = ch <= 14 ? "2.4 GHz" : "5 GHz";
        }
        return new WifiInfo(ssid, needsLocation, rssi, rate, channel, band);
    }

    private static int? ReadInt(IntPtr handle, Guid guid, int opcode)
    {
        if (WlanQueryInterface(handle, ref guid, opcode, IntPtr.Zero, out var size, out var data, IntPtr.Zero) != 0)
            return null;
        try
        {
            return size >= 4 ? Marshal.ReadInt32(data) : null;
        }
        finally
        {
            WlanFreeMemory(data);
        }
    }

    private static (int?, string?) ChannelFromBss(IntPtr handle, Guid guid, byte[] bssid)
    {
        if (WlanGetNetworkBssList(handle, ref guid, IntPtr.Zero, 1, false, IntPtr.Zero, out var list) != 0)
            return (null, null);
        try
        {
            var count = Marshal.ReadInt32(list, 4);
            var mac = new byte[6];
            for (var i = 0; i < count; i++)
            {
                var entry = list + 8 + i * BssEntrySize;
                Marshal.Copy(entry + BssBssidOffset, mac, 0, 6);
                if (!mac.AsSpan().SequenceEqual(bssid)) continue;
                var khz = (uint)Marshal.ReadInt32(entry, BssCenterFrequencyOffset);
                return FromFrequency(khz / 1000);
            }
            return (null, null);
        }
        finally
        {
            WlanFreeMemory(list);
        }
    }

    private static (int?, string?) FromFrequency(uint mhz) => mhz switch
    {
        2484 => (14, "2.4 GHz"),
        >= 2412 and < 2484 => ((int)(mhz - 2407) / 5, "2.4 GHz"),
        >= 5925 and <= 7125 => ((int)(mhz - 5950) / 5, "6 GHz"),
        >= 5000 and < 5925 => ((int)(mhz - 5000) / 5, "5 GHz"),
        _ => (null, null),
    };

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr handle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr interfaceList);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanQueryInterface(
        IntPtr handle, ref Guid interfaceGuid, int opcode, IntPtr reserved,
        out uint dataSize, out IntPtr data, IntPtr opcodeValueType);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanGetNetworkBssList(
        IntPtr handle, ref Guid interfaceGuid, IntPtr ssid, int bssType,
        [MarshalAs(UnmanagedType.Bool)] bool securityEnabled, IntPtr reserved, out IntPtr bssList);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr memory);
}
