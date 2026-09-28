using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Shell;

/// <summary>
/// Applies one <see cref="TrayViewModel"/> snapshot to the tray icon, the
/// menu, and the status window if one is open. Extracted out of
/// <see cref="TrayApplicationContext"/> so that "does a later model actually
/// reach the menu, not just the first one" is testable on its own -- without
/// a real <see cref="LifecycleController"/>, <see cref="SingleInstance"/>'s
/// session-wide mutex, or a session window.
/// </summary>
internal sealed class TrayPresenter(NotifyIcon icon, TrayIcons icons, TrayMenu menu, Func<StatusWindow?> statusWindow)
{
    public void Apply(TrayViewModel model)
    {
        icon.Text = Clip(model.Tooltip);
        icon.Icon = icons.IconFor(model.State);
        menu.Apply(model);
        statusWindow()?.Apply(model);
    }

    // NotifyIcon.Text is limited to 127 characters.
    private static string Clip(string text) => text.Length <= 127 ? text : text[..127];
}
