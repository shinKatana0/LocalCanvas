namespace LocalCanvas.Launcher.Shell;

/// <summary>The one clipboard write the status window makes, behind a seam a test can replace.</summary>
internal interface ITextClipboard
{
    void SetText(string text);
}

internal sealed class SystemClipboard : ITextClipboard
{
    public void SetText(string text) => Clipboard.SetText(text);
}
