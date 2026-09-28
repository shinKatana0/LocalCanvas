using LocalCanvas.Launcher.Core;
using LocalCanvas.Launcher.Shell;

namespace LocalCanvas.Launcher;

internal static class Program
{
    /// <summary>
    /// How long the launcher holds a Windows sign-out or shutdown to stop what
    /// it started (see LifecycleController.DefaultSessionEndBound). The window
    /// registers a shutdown block reason for that time, so Windows shows
    /// "Stopping LocalCanvas" and waits for the user instead of ending the
    /// process after a few seconds. Best effort: the user can still end it sooner.
    /// </summary>
    public static readonly TimeSpan SessionEndBound = LifecycleController.DefaultSessionEndBound;

    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        // One launcher per session. A second launch asks the first to show
        // itself and ends here: no script is run, nothing is read or written.
        using var instance = SingleInstance.Acquire();
        if (!instance.IsPrimary)
        {
            SingleInstance.SignalPrimary(TimeSpan.FromSeconds(5));
            return 0;
        }

        var resolved = LauncherRoot.Resolve(args, Path.GetDirectoryName(Environment.ProcessPath));
        if (resolved.Root is null)
        {
            Dialogs.ShowError(LauncherRoot.MisplacedMessage, resolved.Problem);
            return 2;
        }
        var root = resolved.Root;

        var log = new LauncherLog(LauncherLog.DefaultPath(root));
        log.Write($"launcher: LocalCanvas {typeof(Program).Assembly.GetName().Version} started, PID {Environment.ProcessId}, folder {root}");
        if (instance.WasAbandoned)
        {
            log.Write("launcher: the previous launcher ended without releasing its claim on this session");
        }

        var processes = new HiddenProcessRunner();
        var pwsh = new PwshLocator(processes).LocateAsync().GetAwaiter().GetResult();
        if (!pwsh.Found)
        {
            log.Write($"launcher: {PwshLocator.RequiredMessage} {pwsh.Problem}");
            Dialogs.ShowError(PwshLocator.RequiredMessage, $"{pwsh.Problem}{Environment.NewLine}{Environment.NewLine}To install it:{Environment.NewLine}{PwshLocator.InstallCommand}");
            return 3;
        }
        log.Write($"launcher: PowerShell {pwsh.MajorVersion} at {pwsh.Path}");

        using var health = new HttpHealthProbe();
        var prompts = new WinFormsPrompts();
        var controller = new LifecycleController(
            new PwshScriptRunner(pwsh.Path!, root, processes, log),
            health,
            prompts,
            new SetupConsole(pwsh.Path!, root, log),
            new SeamSettingsReader(pwsh.Path!, root, processes, log),
            log,
            new LifecycleOptions { Root = root });

        using (var context = new TrayApplicationContext(controller, instance, prompts, log, SessionEndBound, root, pwsh.Path!, processes))
        {
            Application.Run(context);
        }
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
        log.Write("launcher: ended");
        return 0;
    }
}
