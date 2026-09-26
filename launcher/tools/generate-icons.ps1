#requires -Version 7.0
<#
.SYNOPSIS
    Regenerates every .ico resource the launcher ships, from code -- no image
    editor and no binary checked in "by hand".

.DESCRIPTION
    Draws each tray-state icon and the application icon at the five sizes the
    launcher picks between (16/20/24/32/48 px -- the small-icon metric at
    100/125/150/200/300% DPI scaling), and writes each as a small multi-frame
    .ico under launcher\LocalCanvas.Launcher\Resources\Icons\.

    States are told apart by SHAPE as well as colour, so the difference
    survives grayscale and colour-blindness, not only hue:
      ready       green disc, white check
      starting    amber disc, white spinner arc (shared by Starting and Restarting)
      syncing     amber disc, two white circular arrows
      attention   amber/yellow triangle, white "!"
      down        red disc, white "x" (also used for the Failed state)
      stopping    plain grey disc
      app         blue disc with a white canvas frame -- the .exe's own icon,
                  a colour none of the states above use

    Run it after changing a drawing function; the .ico files it writes are
    committed, so nothing at build time depends on this script running.

.EXAMPLE
    pwsh -File launcher\tools\generate-icons.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\LocalCanvas.Launcher\Resources\Icons")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing.Common

$Sizes = @(16, 20, 24, 32, 48)

# ---------------------------------------------------------------------------
# ICO container -- a Windows icon is a directory of same-image frames, each
# one a plain PNG since Windows Vista. Built by hand here so the only
# dependency is System.Drawing.Common, already used to draw the frames.
# ---------------------------------------------------------------------------

function Write-Ico {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.Generic.List[byte[]]]$Frames,
        [Parameter(Mandatory)][int[]]$FrameSizes
    )
    if ($Frames.Count -ne $FrameSizes.Count) {
        throw "Frame count must match size count."
    }
    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        # ICONDIR
        $writer.Write([uint16]0)            # reserved
        $writer.Write([uint16]1)            # type: icon
        $writer.Write([uint16]$Frames.Count)

        $headerSize = 6 + 16 * $Frames.Count
        $offset = $headerSize
        for ($i = 0; $i -lt $Frames.Count; $i++) {
            $size = $FrameSizes[$i]
            $bytes = $Frames[$i]
            $writer.Write([byte]($size -band 0xFF))   # width (sizes here are all < 256)
            $writer.Write([byte]($size -band 0xFF))   # height
            $writer.Write([byte]0)                    # colour count: none, it is PNG
            $writer.Write([byte]0)                    # reserved
            $writer.Write([uint16]1)                  # colour planes
            $writer.Write([uint16]32)                 # bits per pixel
            $writer.Write([uint32]$bytes.Length)
            $writer.Write([uint32]$offset)
            $offset += $bytes.Length
        }
        foreach ($bytes in $Frames) {
            $writer.Write($bytes)
        }
        $writer.Flush()
        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-PngBytes {
    param([Parameter(Mandatory)][System.Drawing.Bitmap]$Bitmap)
    $stream = [System.IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function New-IconCanvas {
    param([Parameter(Mandatory)][int]$Size)
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)
    return @{ Bitmap = $bitmap; Graphics = $graphics }
}

function Add-Disc {
    param($Graphics, [int]$Size, [System.Drawing.Color]$Color)
    $margin = [Math]::Max(1, [int]($Size * 0.06))
    $rect = [System.Drawing.RectangleF]::new($margin, $margin, $Size - 2 * $margin, $Size - 2 * $margin)
    $brush = [System.Drawing.SolidBrush]::new($Color)
    try { $Graphics.FillEllipse($brush, $rect) } finally { $brush.Dispose() }
}

function Add-Triangle {
    param($Graphics, [int]$Size, [System.Drawing.Color]$Color)
    $margin = [Math]::Max(1, [int]($Size * 0.05))
    $top = [System.Drawing.PointF]::new($Size / 2.0, $margin)
    $left = [System.Drawing.PointF]::new($margin, $Size - $margin)
    $right = [System.Drawing.PointF]::new($Size - $margin, $Size - $margin)
    $brush = [System.Drawing.SolidBrush]::new($Color)
    try { $Graphics.FillPolygon($brush, [System.Drawing.PointF[]]@($top, $left, $right)) } finally { $brush.Dispose() }
}

function New-Pen {
    param([System.Drawing.Color]$Color, [single]$Width)
    $pen = [System.Drawing.Pen]::new($Color, $Width)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    return $pen
}

$White = [System.Drawing.Color]::White

function Add-Check {
    # A checkmark: a short rising stroke then a long falling one.
    param($Graphics, [int]$Size)
    $stroke = [Math]::Max(1.4, $Size * 0.11)
    $pen = New-Pen $White $stroke
    try {
        $p1 = [System.Drawing.PointF]::new($Size * 0.27, $Size * 0.53)
        $p2 = [System.Drawing.PointF]::new($Size * 0.44, $Size * 0.70)
        $p3 = [System.Drawing.PointF]::new($Size * 0.76, $Size * 0.32)
        $Graphics.DrawLines($pen, [System.Drawing.PointF[]]@($p1, $p2, $p3))
    }
    finally { $pen.Dispose() }
}

function Add-X {
    # Gateway down: a bold "x", the shape a check is deliberately not.
    param($Graphics, [int]$Size)
    $stroke = [Math]::Max(1.4, $Size * 0.12)
    $pen = New-Pen $White $stroke
    try {
        $a = $Size * 0.30
        $b = $Size * 0.70
        $Graphics.DrawLine($pen, $a, $a, $b, $b)
        $Graphics.DrawLine($pen, $a, $b, $b, $a)
    }
    finally { $pen.Dispose() }
}

function Add-SpinnerArc {
    # Starting/Restarting: an open ring -- three quarters of a circle, the
    # gap itself part of the shape (never mistaken for the closed disc-only
    # Stopping icon, nor for the two arrows of Syncing).
    param($Graphics, [int]$Size)
    $stroke = [Math]::Max(1.4, $Size * 0.14)
    $margin = $Size * 0.24
    $rect = [System.Drawing.RectangleF]::new($margin, $margin, $Size - 2 * $margin, $Size - 2 * $margin)
    $pen = New-Pen $White $stroke
    try { $Graphics.DrawArc($pen, $rect, -60, 270) } finally { $pen.Dispose() }
}

function Add-SyncArrows {
    # Syncing: two opposing arcs, each with its own arrowhead, reading as a
    # closed loop -- distinct from the single open arc of Starting.
    param($Graphics, [int]$Size)
    $stroke = [Math]::Max(1.3, $Size * 0.12)
    $margin = $Size * 0.22
    $rect = [System.Drawing.RectangleF]::new($margin, $margin, $Size - 2 * $margin, $Size - 2 * $margin)
    $pen = New-Pen $White $stroke
    $radius = ($Size - 2 * $margin) / 2.0
    $center = [System.Drawing.PointF]::new($Size / 2.0, $Size / 2.0)
    try {
        $Graphics.DrawArc($pen, $rect, -30, 150)
        $Graphics.DrawArc($pen, $rect, 150, 150)
        Add-ArrowHead $Graphics $center $radius 120 $stroke
        Add-ArrowHead $Graphics $center $radius -60 $stroke
    }
    finally { $pen.Dispose() }
}

function Add-ArrowHead {
    param($Graphics, [System.Drawing.PointF]$Center, [double]$Radius, [double]$AngleDegrees, [single]$Stroke)
    $angle = $AngleDegrees * [Math]::PI / 180.0
    $tipX = $Center.X + $Radius * [Math]::Cos($angle)
    $tipY = $Center.Y + $Radius * [Math]::Sin($angle)
    $wingLength = $Stroke * 1.6
    $wingSpread = 2.4
    $backAngle1 = $angle + [Math]::PI - 0.5
    $backAngle2 = $angle + [Math]::PI + 0.5
    $p1 = [System.Drawing.PointF]::new($tipX, $tipY)
    $p2 = [System.Drawing.PointF]::new($tipX + $wingLength * [Math]::Cos($backAngle1), $tipY + $wingLength * [Math]::Sin($backAngle1))
    $p3 = [System.Drawing.PointF]::new($tipX + $wingLength * [Math]::Cos($backAngle2), $tipY + $wingLength * [Math]::Sin($backAngle2))
    $brush = [System.Drawing.SolidBrush]::new($White)
    try { $Graphics.FillPolygon($brush, [System.Drawing.PointF[]]@($p1, $p2, $p3)) } finally { $brush.Dispose() }
}

function Add-Exclamation {
    param($Graphics, [int]$Size)
    $brush = [System.Drawing.SolidBrush]::new($White)
    try {
        $barWidth = [Math]::Max(1.2, $Size * 0.09)
        $barTop = $Size * 0.40
        $barBottom = $Size * 0.66
        $barRect = [System.Drawing.RectangleF]::new(($Size - $barWidth) / 2.0, $barTop, $barWidth, $barBottom - $barTop)
        $Graphics.FillRectangle($brush, $barRect)
        $dotDiameter = [Math]::Max(1.4, $Size * 0.10)
        $dotRect = [System.Drawing.RectangleF]::new(($Size - $dotDiameter) / 2.0, $Size * 0.72, $dotDiameter, $dotDiameter)
        $Graphics.FillEllipse($brush, $dotRect)
    }
    finally { $brush.Dispose() }
}

function Add-CanvasFrame {
    # The application icon's own glyph: a plain rounded frame, deliberately
    # not any of the state glyphs above.
    param($Graphics, [int]$Size)
    $stroke = [Math]::Max(1.3, $Size * 0.10)
    $margin = $Size * 0.28
    $rect = [System.Drawing.RectangleF]::new($margin, $margin, $Size - 2 * $margin, $Size - 2 * $margin)
    $pen = New-Pen $White $stroke
    try { $Graphics.DrawRectangle($pen, $rect.X, $rect.Y, $rect.Width, $rect.Height) } finally { $pen.Dispose() }
}

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------

$Green = [System.Drawing.Color]::FromArgb(255, 39, 153, 79)
$Amber = [System.Drawing.Color]::FromArgb(255, 224, 146, 22)
$Red = [System.Drawing.Color]::FromArgb(255, 209, 55, 47)
$Grey = [System.Drawing.Color]::FromArgb(255, 117, 117, 117)
$Blue = [System.Drawing.Color]::FromArgb(255, 41, 98, 209)

# ---------------------------------------------------------------------------
# One drawing function per .ico this script produces.
# ---------------------------------------------------------------------------

$Icons = [ordered]@{
    "ready"     = { param($g, $s) Add-Disc $g $s $Green; Add-Check $g $s }
    "starting"  = { param($g, $s) Add-Disc $g $s $Amber; Add-SpinnerArc $g $s }
    "syncing"   = { param($g, $s) Add-Disc $g $s $Amber; Add-SyncArrows $g $s }
    "attention" = { param($g, $s) Add-Triangle $g $s $Amber; Add-Exclamation $g $s }
    "down"      = { param($g, $s) Add-Disc $g $s $Red; Add-X $g $s }
    "stopping"  = { param($g, $s) Add-Disc $g $s $Grey }
    "app"       = { param($g, $s) Add-Disc $g $s $Blue; Add-CanvasFrame $g $s }
}

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

foreach ($name in $Icons.Keys) {
    $draw = $Icons[$name]
    $frames = [System.Collections.Generic.List[byte[]]]::new()
    foreach ($size in $Sizes) {
        $canvas = New-IconCanvas -Size $size
        try {
            & $draw $canvas.Graphics $size
            $frames.Add((ConvertTo-PngBytes -Bitmap $canvas.Bitmap))
        }
        finally {
            $canvas.Graphics.Dispose()
            $canvas.Bitmap.Dispose()
        }
    }
    $path = Join-Path $OutputDirectory "$name.ico"
    Write-Ico -Path $path -Frames $frames -FrameSizes $Sizes
    Write-Host "wrote $path ($($frames.Count) frames: $($Sizes -join ', '))"
}
