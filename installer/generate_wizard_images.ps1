# Generates the branded BMPs Inno Setup's modern wizard uses:
#   - images\wizard_image.bmp        (410x785, 164:314 aspect, 2.5x for hi-DPI)
#       -> left sidebar band on the Welcome / Finished pages
#   - images\wizard_small_image.bmp  (140x140 square, 2.4x for hi-DPI)
#       -> top-right header glyph on the interior pages
#
# Design: charcoal vertical gradient + orange radial glow + the ZestSSH
# app mark + Geist wordmark/tagline + a JetBrains Mono `>_` terminal motif
# (echoing the logo). Brand fonts are loaded from the repo's asset files so
# the installer art uses the real typography; falls back to Segoe/Consolas
# if a private font can't be rasterised.
#
# Run:  powershell -ExecutionPolicy Bypass -File generate_wizard_images.ps1

Add-Type -AssemblyName System.Drawing

$root    = Split-Path -Parent $PSCommandPath
$repo    = Split-Path -Parent $root

# The art is deliberately VERSION-AGNOSTIC: it carries no version number, so it
# never has to be regenerated per release and can never drift from the build.
# The installer shows the version in its title bar and finish-page body copy,
# both derived from the build. Regenerate this art only on a logo change.
Write-Host "Generating version-agnostic installer art"
$iconPng = Join-Path $repo 'assets\ZestSSH.png'
$fontDir = Join-Path $repo 'assets\fonts'
$outDir  = Join-Path $root 'images'
$outBig  = Join-Path $outDir 'wizard_image.bmp'
$outSmall= Join-Path $outDir 'wizard_small_image.bmp'

if (-not (Test-Path $iconPng)) { Write-Error "Source icon not found: $iconPng"; exit 1 }
if (-not (Test-Path $outDir))  { New-Item -ItemType Directory -Path $outDir | Out-Null }

# ── Brand palette ────────────────────────────────────────────────────
$cCharcoalTop = [System.Drawing.Color]::FromArgb(255, 24, 24, 27)   # #18181B
$cCharcoalBot = [System.Drawing.Color]::FromArgb(255,  8,  8, 10)   # #08080A
$cOrange      = [System.Drawing.Color]::FromArgb(255, 232, 96, 10)  # #E8600A
$cWhite       = [System.Drawing.Color]::FromArgb(255, 250, 250, 250)# #FAFAFA
$cMuted       = [System.Drawing.Color]::FromArgb(255, 161, 161, 170)# #A1A1AA
$cDim         = [System.Drawing.Color]::FromArgb(255, 113, 113, 122)# #71717A

# ── Load brand fonts privately (with graceful fallback) ──────────────
$pfc = New-Object System.Drawing.Text.PrivateFontCollection
function Add-BrandFont([string]$file) {
    $p = Join-Path $fontDir $file
    if (Test-Path $p) { try { $pfc.AddFontFile($p) } catch { } }
}
Add-BrandFont 'GeistSans-SemiBold.ttf'
Add-BrandFont 'GeistSans-Medium.ttf'
Add-BrandFont 'GeistSans-Regular.ttf'
Add-BrandFont 'JetBrainsMono-Regular.ttf'
Add-BrandFont 'JetBrainsMono-Bold.ttf'

# Resolve a private FontFamily by (partial) name; $null if unavailable.
function Get-Family([string]$needle) {
    foreach ($f in $pfc.Families) { if ($f.Name -match $needle) { return $f } }
    return $null
}
$famGeist = Get-Family 'Geist'
$famMono  = Get-Family 'JetBrains'

# Build a Font from a private family, trying styles in order, else a
# guaranteed system font, so rendering never fails on a font quirk.
function New-BrandFont($family, [single]$size, [string]$sysFallback, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
    if ($family -ne $null) {
        foreach ($s in @($style, [System.Drawing.FontStyle]::Regular, [System.Drawing.FontStyle]::Bold)) {
            if ($family.IsStyleAvailable($s)) {
                try { return New-Object System.Drawing.Font($family, $size, $s) } catch { }
            }
        }
    }
    return New-Object System.Drawing.Font($sysFallback, $size, $style)
}

$source = [System.Drawing.Image]::FromFile($iconPng)

function Set-Quality($g) {
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
}

try {
    # ══ Big sidebar banner : 410 x 785 (164:314) ═════════════════════
    $W = 410; $H = 785
    $big = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($big)
    try {
        Set-Quality $g

        # Vertical charcoal gradient
        $rect  = New-Object System.Drawing.Rectangle 0, 0, $W, $H
        $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $cCharcoalTop, $cCharcoalBot, 90)
        $g.FillRectangle($bgBrush, $rect); $bgBrush.Dispose()

        # Faint hairline grid texture (technical feel), very low alpha
        $gridPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(10, 255, 255, 255)), 1
        for ($y = 0; $y -lt $H; $y += 32) { $g.DrawLine($gridPen, 0, $y, $W, $y) }
        for ($x = 0; $x -lt $W; $x += 32) { $g.DrawLine($gridPen, $x, 0, $x, $H) }
        $gridPen.Dispose()

        # Orange radial glow behind the mark
        $glowR = 300
        $glowRect = New-Object System.Drawing.Rectangle ([int](($W-$glowR)/2)), 120, $glowR, $glowR
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $gp.AddEllipse($glowRect)
        $glow = New-Object System.Drawing.Drawing2D.PathGradientBrush $gp
        $glow.CenterColor    = [System.Drawing.Color]::FromArgb(70, 232, 96, 10)
        $glow.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 232, 96, 10))
        $g.FillEllipse($glow, $glowRect); $glow.Dispose(); $gp.Dispose()

        # Large faint `>_` watermark (echoes the logo), low opacity
        $wmFont = New-BrandFont $famMono 150 'Consolas' ([System.Drawing.FontStyle]::Bold)
        $wmBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(14, 232, 96, 10))
        $sfWm = New-Object System.Drawing.StringFormat
        $sfWm.Alignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString(">_", $wmFont, $wmBrush, (New-Object System.Drawing.RectangleF 0, 470, $W, 180), $sfWm)
        $wmBrush.Dispose(); $wmFont.Dispose()

        # App mark, 150px, centered, with a soft drop shadow
        $iconSize = 150
        $iconX = [int](($W - $iconSize) / 2)
        $iconY = 150
        $shadow = New-Object System.Drawing.Drawing2D.GraphicsPath
        $shadow.AddEllipse($iconX + 12, $iconY + 20, $iconSize - 24, $iconSize - 10)
        $shBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush $shadow
        $shBrush.CenterColor    = [System.Drawing.Color]::FromArgb(120, 0, 0, 0)
        $shBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        $g.FillPath($shBrush, $shadow); $shBrush.Dispose(); $shadow.Dispose()
        $g.DrawImage($source, $iconX, $iconY, $iconSize, $iconSize)

        # Wordmark "ZestSSH"
        $sfC = New-Object System.Drawing.StringFormat
        $sfC.Alignment = [System.Drawing.StringAlignment]::Center
        $wordFont = New-BrandFont $famGeist 34 'Segoe UI Semibold' ([System.Drawing.FontStyle]::Bold)
        $wordBrush = New-Object System.Drawing.SolidBrush $cWhite
        $g.DrawString("ZestSSH", $wordFont, $wordBrush, (New-Object System.Drawing.RectangleF 0, 328, $W, 48), $sfC)
        $wordBrush.Dispose(); $wordFont.Dispose()

        # Tagline
        $tagFont = New-BrandFont $famGeist 14 'Segoe UI' ([System.Drawing.FontStyle]::Regular)
        $tagBrush = New-Object System.Drawing.SolidBrush $cMuted
        $g.DrawString("The Fresh SSH Client", $tagFont, $tagBrush, (New-Object System.Drawing.RectangleF 0, 384, $W, 26), $sfC)
        $tagBrush.Dispose(); $tagFont.Dispose()

        # Thin orange accent line
        $accentPen = New-Object System.Drawing.Pen $cOrange, 2
        $g.DrawLine($accentPen, [int]($W/2 - 42), 424, [int]($W/2 + 42), 424)
        $accentPen.Dispose()

        # Bottom eyebrow: brand only. NO version number here: the installer's
        # title bar and finish-page body copy carry the version (both build-
        # derived), so this static artwork can never go stale.
        $footFont = New-BrandFont $famMono 12 'Consolas' ([System.Drawing.FontStyle]::Regular)
        $footBrush = New-Object System.Drawing.SolidBrush $cDim
        $g.DrawString("AFFLUENT LABS", $footFont, $footBrush, (New-Object System.Drawing.RectangleF 0, ($H-56), $W, 20), $sfC)
        $footBrush.Dispose(); $footFont.Dispose()
    } finally { $g.Dispose() }
    $big.Save($outBig, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $big.Dispose()
    Write-Host "Wrote $outBig (410x785)"

    # ══ Small header glyph : 140 x 140 (square) ══════════════════════
    $S = 140
    $small = New-Object System.Drawing.Bitmap $S, $S
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    try {
        Set-Quality $g2
        $g2.Clear([System.Drawing.Color]::FromArgb(255, 17, 17, 19))  # #111113

        # Subtle orange radial glow
        $r2 = 130
        $gr2 = New-Object System.Drawing.Rectangle ([int](($S-$r2)/2)), ([int](($S-$r2)/2)), $r2, $r2
        $p2 = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p2.AddEllipse($gr2)
        $gl2 = New-Object System.Drawing.Drawing2D.PathGradientBrush $p2
        $gl2.CenterColor    = [System.Drawing.Color]::FromArgb(45, 232, 96, 10)
        $gl2.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 232, 96, 10))
        $g2.FillEllipse($gl2, $gr2); $gl2.Dispose(); $p2.Dispose()

        $isz = 104
        $ix = [int](($S - $isz) / 2); $iy = [int](($S - $isz) / 2)
        $g2.DrawImage($source, $ix, $iy, $isz, $isz)
    } finally { $g2.Dispose() }
    $small.Save($outSmall, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $small.Dispose()
    Write-Host "Wrote $outSmall (140x140)"
} finally {
    $source.Dispose()
    $pfc.Dispose()
}
