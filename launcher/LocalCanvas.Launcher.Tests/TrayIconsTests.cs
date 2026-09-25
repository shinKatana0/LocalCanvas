using LocalCanvas.Launcher.Core;
using LocalCanvas.Launcher.Shell;

namespace LocalCanvas.Launcher.Tests;

/// <summary>
/// The tray-state icons: which resource each <see cref="LauncherState"/>
/// maps to, and that states told apart in the brief actually differ in the
/// pixels drawn -- not only in a colour a test could not tell from a simple
/// recolour of the very same glyph.
/// </summary>
public sealed class TrayIconsTests : IDisposable
{
    private const int Size = 32;
    private readonly TrayIcons _icons = new(new System.Drawing.Size(Size, Size));

    [Theory]
    [InlineData(LauncherState.Ready, "ready")]
    [InlineData(LauncherState.Starting, "starting")]
    [InlineData(LauncherState.Restarting, "starting")]
    [InlineData(LauncherState.Syncing, "syncing")]
    [InlineData(LauncherState.Attention, "attention")]
    [InlineData(LauncherState.GatewayDown, "down")]
    [InlineData(LauncherState.Failed, "down")]
    [InlineData(LauncherState.Stopping, "stopping")]
    public void Each_state_maps_to_the_documented_icon(LauncherState state, string resource)
    {
        using var expected = TrayIcons.Load(resource, new System.Drawing.Size(Size, Size));
        AssertIdenticalPixels(expected.ToBitmap(), _icons.IconFor(state).ToBitmap());
    }

    [Fact]
    public void Starting_and_Restarting_render_pixel_for_pixel_identical()
    {
        AssertIdenticalPixels(_icons.IconFor(LauncherState.Starting).ToBitmap(), _icons.IconFor(LauncherState.Restarting).ToBitmap());
    }

    [Fact]
    public void Gateway_down_and_a_startup_Failure_render_pixel_for_pixel_identical()
    {
        // A startup Failure is not named in the brief's icon list; it means
        // the same thing to the user as Gateway down -- LocalCanvas cannot be
        // used from the phone -- so it shares that icon rather than adding an
        // eighth glyph the brief never asked for.
        AssertIdenticalPixels(_icons.IconFor(LauncherState.GatewayDown).ToBitmap(), _icons.IconFor(LauncherState.Failed).ToBitmap());
    }

    [Fact]
    public void Ready_and_Gateway_down_differ_in_the_glyph_drawn_not_only_in_colour()
    {
        var ready = ForegroundMask(_icons.IconFor(LauncherState.Ready).ToBitmap());
        var down = ForegroundMask(_icons.IconFor(LauncherState.GatewayDown).ToBitmap());

        var shared = ready.Intersect(down).Count();
        var union = ready.Union(down).Count();
        var overlapFraction = union == 0 ? 1.0 : (double)shared / union;

        Assert.True(ready.Count > 10, "the Ready icon should have a visible white glyph");
        Assert.True(down.Count > 10, "the Gateway-down icon should have a visible white glyph");
        // A check mark and an "x" occupy substantially different pixels: a
        // mutation that only recoloured the same glyph green->red would keep
        // this overlap near 1.0.
        Assert.True(overlapFraction < 0.6, $"the check and the x overlap too much ({overlapFraction:P0}) to be different shapes");
    }

    [Fact]
    public void Starting_and_Syncing_share_the_disc_but_differ_in_the_arrows_drawn()
    {
        var startingDisc = _icons.IconFor(LauncherState.Starting).ToBitmap();
        var syncingDisc = _icons.IconFor(LauncherState.Syncing).ToBitmap();

        // Same outer silhouette: both are the same amber disc.
        var startingSilhouette = SilhouetteMask(startingDisc);
        var syncingSilhouette = SilhouetteMask(syncingDisc);
        var silhouetteOverlap = (double)startingSilhouette.Intersect(syncingSilhouette).Count() / startingSilhouette.Union(syncingSilhouette).Count();
        Assert.True(silhouetteOverlap > 0.9, "Starting and Syncing should be the same disc");

        // Different inner glyph: the open arc versus the two arrows.
        var startingGlyph = ForegroundMask(startingDisc);
        var syncingGlyph = ForegroundMask(syncingDisc);
        var glyphOverlap = (double)startingGlyph.Intersect(syncingGlyph).Count() / startingGlyph.Union(syncingGlyph).Count();
        Assert.True(glyphOverlap < 0.75, $"the spinner arc and the sync arrows overlap too much ({glyphOverlap:P0}) to be different shapes");
    }

    [Fact]
    public void Attention_is_a_triangle_not_a_disc()
    {
        using var triangle = _icons.IconFor(LauncherState.Attention).ToBitmap();
        using var disc = _icons.IconFor(LauncherState.Ready).ToBitmap();

        // A disc's silhouette is close to as wide near the top as near the
        // bottom; a triangle pointing up is far narrower at the top (the
        // apex) than at the bottom (the base). Row 2 and row Size-3 avoid the
        // one-pixel antialiased edge.
        var triangleTop = OpaqueRowWidth(triangle, 2);
        var triangleBottom = OpaqueRowWidth(triangle, Size - 3);
        var discTop = OpaqueRowWidth(disc, 2);
        var discBottom = OpaqueRowWidth(disc, Size - 3);

        Assert.True(triangleBottom > 0 && triangleTop >= 0);
        var triangleRatio = (double)triangleTop / triangleBottom;
        var discRatio = discBottom == 0 ? 0 : (double)discTop / discBottom;

        Assert.True(triangleRatio < 0.35, $"the triangle should be far narrower at the top than the bottom (ratio {triangleRatio:0.00})");
        Assert.True(discRatio > 0.6, $"the disc should be close to as wide at the top as the bottom (ratio {discRatio:0.00})");
    }

    [Fact]
    public void Stopping_is_a_plain_disc_with_no_white_glyph()
    {
        var stopping = ForegroundMask(_icons.IconFor(LauncherState.Stopping).ToBitmap());
        var ready = ForegroundMask(_icons.IconFor(LauncherState.Ready).ToBitmap());
        Assert.True(stopping.Count < 5, $"Stopping should draw no glyph, found {stopping.Count} white pixels");
        Assert.True(ready.Count > 10);
    }

    [Fact]
    public void The_five_documented_sizes_are_all_present_in_every_resource()
    {
        // "app" is deliberately not among these: it is baked into the exe as
        // its own native icon (ApplicationIcon), not an embedded resource
        // loaded at runtime, so it is checked on disk instead, below.
        foreach (var name in new[] { "ready", "starting", "syncing", "attention", "down", "stopping" })
        {
            foreach (var size in new[] { 16, 20, 24, 32, 48 })
            {
                using var icon = TrayIcons.Load(name, new System.Drawing.Size(size, size));
                using var bitmap = icon.ToBitmap();
                Assert.Equal(size, bitmap.Width);
                Assert.Equal(size, bitmap.Height);
            }
        }
    }

    [Fact]
    public void The_application_icon_carries_the_same_five_sizes_on_disk()
    {
        var path = Path.Combine(TestEnvironment.LauncherSources, "Resources", "Icons", "app.ico");
        Assert.True(File.Exists(path), $"{path} was not found -- run launcher\\tools\\generate-icons.ps1");
        foreach (var size in new[] { 16, 20, 24, 32, 48 })
        {
            using var icon = new Icon(path, new System.Drawing.Size(size, size));
            using var bitmap = icon.ToBitmap();
            Assert.Equal(size, bitmap.Width);
            Assert.Equal(size, bitmap.Height);
        }
    }

    [Fact]
    public void The_small_icon_size_used_at_runtime_is_positive()
    {
        var size = TrayIcons.SmallIconSize();
        Assert.True(size.Width > 0);
        Assert.True(size.Height > 0);
    }

    /// <summary>Pixels that are close to white and not transparent -- the glyph colour every icon draws in.</summary>
    private static HashSet<(int X, int Y)> ForegroundMask(System.Drawing.Bitmap bitmap)
    {
        var pixels = new HashSet<(int, int)>();
        for (var y = 0; y < bitmap.Height; y++)
        {
            for (var x = 0; x < bitmap.Width; x++)
            {
                var pixel = bitmap.GetPixel(x, y);
                if (pixel.A > 128 && pixel.R > 200 && pixel.G > 200 && pixel.B > 200)
                {
                    pixels.Add((x, y));
                }
            }
        }
        return pixels;
    }

    /// <summary>Every non-transparent pixel -- the outer shape (disc or triangle).</summary>
    private static HashSet<(int X, int Y)> SilhouetteMask(System.Drawing.Bitmap bitmap)
    {
        var pixels = new HashSet<(int, int)>();
        for (var y = 0; y < bitmap.Height; y++)
        {
            for (var x = 0; x < bitmap.Width; x++)
            {
                if (bitmap.GetPixel(x, y).A > 128)
                {
                    pixels.Add((x, y));
                }
            }
        }
        return pixels;
    }

    private static int OpaqueRowWidth(System.Drawing.Bitmap bitmap, int row)
    {
        var count = 0;
        for (var x = 0; x < bitmap.Width; x++)
        {
            if (bitmap.GetPixel(x, row).A > 128)
            {
                count++;
            }
        }
        return count;
    }

    private static void AssertIdenticalPixels(System.Drawing.Bitmap a, System.Drawing.Bitmap b)
    {
        using (a)
        using (b)
        {
            Assert.Equal(a.Width, b.Width);
            Assert.Equal(a.Height, b.Height);
            for (var y = 0; y < a.Height; y++)
            {
                for (var x = 0; x < a.Width; x++)
                {
                    Assert.Equal(a.GetPixel(x, y), b.GetPixel(x, y));
                }
            }
        }
    }

    public void Dispose() => _icons.Dispose();
}
