using System.Collections.Concurrent;
using LocalCanvas.Launcher.Core;

namespace LocalCanvas.Launcher.Tests;

/// <summary>A controller wired to fakes. Health ticks happen only when a test asks for one.</summary>
internal sealed class ControllerHarness : IAsyncDisposable
{
    public const string Root = @"X:\LocalCanvas";
    public static readonly string Python = Path.Combine(Root, ".venv", "Scripts", "python.exe");
    public static readonly string RuntimeYaml = Path.Combine(Root, "config", "local", "runtime.yaml");
    public static readonly string SourcesYaml = Path.Combine(Root, "config", "local", "workflow-sources.yaml");

    public readonly FakeRuntime Runtime = new();
    public readonly FakePrompts Prompts = new();
    public readonly MemoryLog Log = new();
    public readonly ConcurrentDictionary<string, bool> Files = new(StringComparer.OrdinalIgnoreCase);
    public readonly ConcurrentQueue<TrayViewModel> Published = new();
    public FakeSetup Setup;
    public int? SetupExitCode = 0;
    private LifecycleController? _controller;

    public ControllerHarness(bool setUp = true, bool sourcesConfigured = true)
    {
        if (setUp)
        {
            Files[Python] = true;
            Files[RuntimeYaml] = true;
        }
        if (sourcesConfigured)
        {
            Files[SourcesYaml] = true;
        }
        Setup = new FakeSetup(() => SetupExitCode);
    }

    public Func<TimeSpan, CancellationToken, Task> Delay { get; set; } =
        static (_, token) => Task.Delay(Timeout.InfiniteTimeSpan, token);

    public LifecycleController Controller => _controller ?? throw new InvalidOperationException("Start first.");

    public TrayViewModel Model => Controller.ViewModel;

    public IEnumerable<LauncherState> States => Published.Select(model => model.State);

    public LifecycleController Create()
    {
        _controller = new LifecycleController(
            Runtime, Runtime, Prompts, Setup, new FixedSettings(), Log,
            new LifecycleOptions
            {
                Root = Root,
                Delay = Delay,
                FileExists = path => Files.ContainsKey(path),
            });
        _controller.ViewModelChanged += model => Published.Enqueue(model);
        return _controller;
    }

    public LifecycleController Start()
    {
        var controller = _controller ?? Create();
        controller.Start();
        return controller;
    }

    /// <summary>Start, and wait until startup has finished with <paramref name="state"/>.</summary>
    public async Task<LifecycleController> StartAndWaitAsync(LauncherState state)
    {
        var controller = Start();
        await WaitForAsync(model => model.State == state && !model.Busy, $"startup to end in {state}");
        return controller;
    }

    public async Task WaitForAsync(Func<TrayViewModel, bool> condition, string what, int seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            if (_controller is not null && condition(_controller.ViewModel))
            {
                return;
            }
            await Task.Delay(10);
        }
        Assert.Fail($"Timed out waiting for {what}. Last state: {_controller?.ViewModel.State}, busy {_controller?.ViewModel.Busy}.\nCalls: {string.Join(" | ", Runtime.CallNames)}\nLog:\n{Log.Text}");
    }

    public async Task WaitForExitAsync(int seconds = 10)
    {
        var finished = await Task.WhenAny(Controller.Completion, Task.Delay(TimeSpan.FromSeconds(seconds)));
        Assert.True(finished == Controller.Completion,
            $"The controller did not exit.\nCalls: {string.Join(" | ", Runtime.CallNames)}\nLog:\n{Log.Text}");
    }

    public async ValueTask DisposeAsync()
    {
        if (_controller is not null)
        {
            await _controller.DisposeAsync();
        }
    }
}
