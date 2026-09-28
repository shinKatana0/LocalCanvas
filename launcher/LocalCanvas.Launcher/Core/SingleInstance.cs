namespace LocalCanvas.Launcher.Core;

/// <summary>
/// One launcher per Windows session. The first launch holds the mutex
/// <c>Local\LocalCanvas.Launcher</c>; a second launch sets the event
/// <c>Local\LocalCanvas.Launcher.Show</c>, which asks the first to open its
/// status window, and exits without running a single script.
/// </summary>
/// <remarks>
/// A mutex whose holder died without releasing it is abandoned, and Windows
/// hands it to the next waiter together with an
/// <see cref="AbandonedMutexException"/>. That launch owns the mutex: the
/// launcher that crashed is gone, and whatever it left running is adopted
/// through the scripts by the ordinary start.
/// </remarks>
public sealed class SingleInstance : IDisposable
{
    public const string DefaultMutexName = @"Local\LocalCanvas.Launcher";
    public const string DefaultShowEventName = @"Local\LocalCanvas.Launcher.Show";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle? _show;
    private readonly ManualResetEvent _stopListening = new(false);
    private Thread? _listener;
    private bool _disposed;

    private SingleInstance(Mutex mutex, bool isPrimary, bool wasAbandoned, EventWaitHandle? show)
    {
        _mutex = mutex;
        IsPrimary = isPrimary;
        WasAbandoned = wasAbandoned;
        _show = show;
    }

    /// <summary>This process holds the mutex and is the launcher of this session.</summary>
    public bool IsPrimary { get; }

    /// <summary>The mutex was taken over from a launcher that ended without releasing it.</summary>
    public bool WasAbandoned { get; }

    /// <summary>
    /// Claim the session. Call on the thread that will later dispose this
    /// object: a mutex is released by the thread that owns it.
    /// </summary>
    public static SingleInstance Acquire(string mutexName = DefaultMutexName, string showEventName = DefaultShowEventName)
    {
        var mutex = new Mutex(initiallyOwned: false, mutexName);
        bool owned;
        var abandoned = false;
        try
        {
            owned = mutex.WaitOne(TimeSpan.Zero);
        }
        catch (AbandonedMutexException)
        {
            owned = true;
            abandoned = true;
        }
        if (!owned)
        {
            return new SingleInstance(mutex, isPrimary: false, wasAbandoned: false, show: null);
        }
        var show = new EventWaitHandle(false, EventResetMode.AutoReset, showEventName);
        return new SingleInstance(mutex, isPrimary: true, wasAbandoned: abandoned, show);
    }

    /// <summary>
    /// Ask the launcher that holds the session to show its status window.
    /// Returns false when no launcher answered within <paramref name="wait"/>
    /// (it may still be starting up and not have created its event yet).
    /// </summary>
    public static bool SignalPrimary(TimeSpan wait, string showEventName = DefaultShowEventName)
    {
        var until = DateTime.UtcNow + wait;
        while (true)
        {
            if (EventWaitHandle.TryOpenExisting(showEventName, out var show))
            {
                using (show)
                {
                    return show.Set();
                }
            }
            if (DateTime.UtcNow >= until)
            {
                return false;
            }
            Thread.Sleep(100);
        }
    }

    /// <summary>Call <paramref name="onShow"/> (on a background thread) each time a second launch signals.</summary>
    public void StartListening(Action onShow)
    {
        ArgumentNullException.ThrowIfNull(onShow);
        if (!IsPrimary || _show is null || _listener is not null)
        {
            return;
        }
        var show = _show;
        _listener = new Thread(() =>
        {
            var handles = new WaitHandle[] { _stopListening, show };
            while (WaitHandle.WaitAny(handles) == 1)
            {
                onShow();
            }
        })
        {
            IsBackground = true,
            Name = "LocalCanvas show-request listener",
        };
        _listener.Start();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _stopListening.Set();
        _listener?.Join(TimeSpan.FromSeconds(2));
        _show?.Dispose();
        if (IsPrimary)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Not owned by this thread: the handle is closed below, and
                // Windows releases it with the process in any case.
            }
        }
        _mutex.Dispose();
        _stopListening.Dispose();
    }
}
