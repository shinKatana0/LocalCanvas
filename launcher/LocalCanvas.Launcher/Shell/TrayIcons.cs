using System.Reflection;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// The tray-state icons: <c>.ico</c> resources embedded in the exe (the
/// published build is one file with nothing beside it to load them from),
/// each with frames at 16/20/24/32/48 px.
/// </summary>
/// <remarks>
/// <para>
/// States are told apart by shape as well as colour: Ready is a green disc
/// with a check, Starting and Restarting share an amber disc with an open
/// spinner arc, Syncing is an amber disc with two circular arrows, Attention
/// is an amber/yellow triangle (not a disc) with "!", Gateway down and a
/// startup Failure are both the red disc with "x" -- both mean LocalCanvas
/// cannot be used from the phone right now -- and Stopping is a plain grey
/// disc.
/// </para>
/// <para>
/// The frame handed to Windows is the one nearest <see cref="SmallIconSize"/>
/// (<c>GetSystemMetrics(SM_CXSMICON)</c>, which follows the notification
/// area's own DPI), not a fixed 16 px scaled by GDI afterwards -- the reason
/// the resources carry five sizes instead of one.
/// </para>
/// </remarks>
internal sealed class TrayIcons : IDisposable
{
    private readonly Icon _ready;
    private readonly Icon _starting;
    private readonly Icon _syncing;
    private readonly Icon _attention;
    private readonly Icon _down;
    private readonly Icon _stopping;
    private readonly IReadOnlyDictionary<LauncherState, Icon> _byState;

    public TrayIcons(Size? sizeHint = null)
    {
        var size = sizeHint ?? SmallIconSize();
        _ready = Load("ready", size);
        _starting = Load("starting", size);
        _syncing = Load("syncing", size);
        _attention = Load("attention", size);
        _down = Load("down", size);
        _stopping = Load("stopping", size);
        _byState = new Dictionary<LauncherState, Icon>
        {
            [LauncherState.Starting] = _starting,
            [LauncherState.Ready] = _ready,
            [LauncherState.Syncing] = _syncing,
            [LauncherState.Attention] = _attention,
            [LauncherState.Restarting] = _starting,
            [LauncherState.GatewayDown] = _down,
            [LauncherState.Stopping] = _stopping,
            [LauncherState.Failed] = _down,
        };
    }

    public Icon IconFor(LauncherState state) => _byState[state];

    /// <summary>The small-icon metric Windows reports for the current DPI (usually 16 px at 100%).</summary>
    public static Size SmallIconSize() => SystemInformation.SmallIconSize;

    /// <summary>Loads one named icon at the frame nearest <paramref name="size"/>, for tests that want a specific resolution.</summary>
    internal static Icon Load(string name, Size size)
    {
        using var stream = ResourceStream(name);
        return new Icon(stream, size);
    }

    internal static Stream ResourceStream(string name)
    {
        var resourceName = $"LocalCanvas.Launcher.Icons.{name}.ico";
        return Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"The embedded icon '{resourceName}' was not found.");
    }

    public void Dispose()
    {
        _ready.Dispose();
        _starting.Dispose();
        _syncing.Dispose();
        _attention.Dispose();
        _down.Dispose();
        _stopping.Dispose();
    }
}
