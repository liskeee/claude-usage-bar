# Captures a screen region (layered windows included) and saves it enlarged, to check the readout and popup.
param([int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Out, [int]$Zoom = 2)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class SnapNative {
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, int op);
}
'@
$shot = New-Object System.Drawing.Bitmap $Width, $Height
$g = [System.Drawing.Graphics]::FromImage($shot)
$hdc = $g.GetHdc(); $screen = [SnapNative]::GetDC([IntPtr]::Zero)
[void][SnapNative]::BitBlt($hdc, 0, 0, $Width, $Height, $screen, $X, $Y, 0x00CC0020 -bor 0x40000000) # SRCCOPY | CAPTUREBLT
[void][SnapNative]::ReleaseDC([IntPtr]::Zero, $screen); $g.ReleaseHdc($hdc); $g.Dispose()
$big = New-Object System.Drawing.Bitmap ($Width * $Zoom), ($Height * $Zoom)
$bg = [System.Drawing.Graphics]::FromImage($big)
$bg.InterpolationMode = 'NearestNeighbor'; $bg.PixelOffsetMode = 'Half'
$bg.DrawImage($shot, 0, 0, $big.Width, $big.Height)
$big.Save($Out); $bg.Dispose(); $big.Dispose(); $shot.Dispose()
