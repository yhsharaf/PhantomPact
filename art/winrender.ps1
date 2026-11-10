<#
Windows' own text engine for the art scripts (art/make_arabic_art.py). WPF lays a line out and fills its outline, and
WPF shapes through DirectWrite, so Arabic comes out joined and right to left, with each font's own letter forms and
ligatures (Pillow can't here: it has no raqm). No download: WPF is part of Windows' .NET Framework 4.

    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File art/winrender.ps1

Started once, then asked line by line: one request a line on stdin, one answer a line on stdout, both JSON in plain
ASCII (other letters as \u escapes, so the console's code page never matters). It says {"ready":true} first.
  {"text": "...", "font": "Sakkal Majalla", "px": 60, "bold": true}
      px: the font's size in pixels. "rtl": false lays a left-to-right line. "draw": true also sends the picture.
  -> {"advance": .., "ink": [left, top, right, bottom], "height": .., "font_file": ".."}
      measured from the line's start on its baseline. Right to left, the line runs from -advance to 0.
      With "draw": also "png" (base64: the line in white on clear) and "x", "y": where the line's start and its
      baseline fall in that picture.
Digits stay 0-9 as typed, as the game's own text keeps them.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml
$refs = [AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.GetName().Name -in @('PresentationCore', 'WindowsBase', 'System.Xaml',
                                          'PresentationFramework') } |
    ForEach-Object { $_.Location } | Sort-Object -Unique

$code = @'
using System;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class PPLine
{
    static string Num(double v) { return v.ToString("0.###", CultureInfo.InvariantCulture); }

    static string Esc(string s)
    {
        var b = new System.Text.StringBuilder();
        foreach (char c in s ?? "")
        {
            if (c == '\\' || c == '"') { b.Append('\\').Append(c); }
            else if (c < 32 || c > 126) { b.Append("\\u").Append(((int)c).ToString("x4")); }
            else { b.Append(c); }
        }
        return b.ToString();
    }

    public static string Line(string text, string family, double px, bool bold, bool rtl, bool draw, int pad)
    {
        var face = new Typeface(new FontFamily(family), FontStyles.Normal, bold ? FontWeights.Bold : FontWeights.Normal,
                                FontStretches.Normal);
        GlyphTypeface glyphs;
        string file = face.TryGetGlyphTypeface(out glyphs) ? glyphs.FontUri.LocalPath : "";
        // The culture only decides the digits: en-US keeps 0-9 as typed. The direction is FlowDirection's.
        var ft = new FormattedText(text, CultureInfo.GetCultureInfo("en-US"),
                                   rtl ? FlowDirection.RightToLeft : FlowDirection.LeftToRight, face, px,
                                   Brushes.White, 1.0);
        Geometry geo = ft.BuildGeometry(new Point(0, 0));
        Rect ink = geo.Bounds;
        if (ink.IsEmpty) { ink = new Rect(0, ft.Baseline, 0, 0); }
        double b = ft.Baseline;
        string answer = "{\"advance\":" + Num(ft.WidthIncludingTrailingWhitespace) +
                        ",\"ink\":[" + Num(ink.Left) + "," + Num(ink.Top - b) + "," + Num(ink.Right) + "," +
                        Num(ink.Bottom - b) + "]" +
                        ",\"height\":" + Num(ft.Height) + ",\"font_file\":\"" + Esc(file) + "\"";
        if (draw)
        {
            // Right to left, WPF lays the line out to the left of where it starts: the picture holds just the ink.
            double ox = Math.Floor(ink.Left), oy = Math.Floor(ink.Top);
            int w = (int)Math.Ceiling(ink.Right - ox) + 2 * pad, h = (int)Math.Ceiling(ink.Bottom - oy) + 2 * pad;
            double dx = pad - ox, dy = pad - oy;
            var dv = new DrawingVisual();
            using (DrawingContext dc = dv.RenderOpen())
            {
                dc.PushTransform(new TranslateTransform(dx, dy));
                dc.DrawGeometry(Brushes.White, null, geo);
                dc.Pop();
            }
            var rtb = new RenderTargetBitmap(Math.Max(w, 1), Math.Max(h, 1), 96, 96, PixelFormats.Pbgra32);
            rtb.Render(dv);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(new FormatConvertedBitmap(rtb, PixelFormats.Bgra32, null, 0)));
            using (var ms = new MemoryStream())
            {
                enc.Save(ms);
                answer += ",\"x\":" + Num(dx) + ",\"y\":" + Num(dy + b) +
                          ",\"png\":\"" + Convert.ToBase64String(ms.ToArray()) + "\"";
            }
        }
        return answer + "}";
    }
}
'@
if (-not ('PPLine' -as [type])) {
    Add-Type -TypeDefinition $code -ReferencedAssemblies $refs
}

$stdin = [Console]::In
$stdout = [Console]::Out
$stdout.WriteLine('{"ready":true}')
$stdout.Flush()
while ($null -ne ($line = $stdin.ReadLine())) {
    if (-not $line.Trim()) { continue }
    try {
        $j = $line | ConvertFrom-Json
        $rtl = if ($null -ne $j.rtl) { [bool]$j.rtl } else { $true }
        $pad = if ($null -ne $j.pad) { [int]$j.pad } else { 2 }
        $answer = [PPLine]::Line([string]$j.text, [string]$j.font, [double]$j.px, [bool]$j.bold, $rtl,
                                 [bool]$j.draw, $pad)
    } catch {
        $msg = ($_.Exception.Message -replace '[^\x20-\x7e]', '?') -replace '\\', '/' -replace '"', "'"
        $answer = '{"error":"' + $msg + '"}'
    }
    $stdout.WriteLine($answer)
    $stdout.Flush()
}
