param(
  [string]$Mode = "window",
  [string]$ProcessPattern = "Weixin",
  [string]$OutFile = "C:\Users\10601\wechat-eye\out\shot.png",
  [string]$CropArea = "none"
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
try { [W32]::SetProcessDPIAware() | Out-Null } catch {}

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$full = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
$g = [System.Drawing.Graphics]::FromImage($full)
$g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $full.Size)

if ($Mode -eq 'window') {
  $procs = Get-Process | Where-Object { $_.ProcessName -match $ProcessPattern -and $_.MainWindowHandle -ne 0 }
  if (-not $procs) {
    Write-Output ("ERROR: no window found for process pattern: " + $ProcessPattern)
    $g.Dispose(); $full.Dispose(); exit 1
  }
  $h = $procs[0].MainWindowHandle
  $r = New-Object W32+RECT
  [W32]::GetWindowRect($h, [ref]$r) | Out-Null
  if ($r.Left -le -20000) {
    Write-Output "ERROR: window appears minimized"
    $g.Dispose(); $full.Dispose(); exit 1
  }
  # Try PrintWindow first: the window paints itself, so other windows covering
  # it do not pollute the capture (added 2026-10-08). If it fails or renders
  # blank, fall back to the screen grab below (old behavior).
  $ww = $r.Right - $r.Left; $wh = $r.Bottom - $r.Top
  $pw = $null
  if ($ww -gt 0 -and $wh -gt 0) {
    try {
      $pw = New-Object System.Drawing.Bitmap($ww, $wh)
      $pg = [System.Drawing.Graphics]::FromImage($pw)
      $phdc = $pg.GetHdc()
      $okpw = [W32]::PrintWindow($h, $phdc, 2)
      if (-not $okpw) { $okpw = [W32]::PrintWindow($h, $phdc, 0) }
      $pg.ReleaseHdc($phdc); $pg.Dispose()
      if ($okpw) {
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($fx in 0.05, 0.3, 0.5, 0.7, 0.95) {
          foreach ($fy in 0.05, 0.3, 0.5, 0.7, 0.95) {
            [void]$seen.Add($pw.GetPixel([int]($ww * $fx), [int]($wh * $fy)).ToArgb())
          }
        }
        if ($seen.Count -le 1) { $okpw = $false }   # all-same-color = blank/black render
      }
      if (-not $okpw) { $pw.Dispose(); $pw = $null }
    } catch { if ($pw) { $pw.Dispose() }; $pw = $null }
  }
  if ($pw) {
    $ox = $r.Left; $oy = $r.Top; $cropTag = ""
    # CropArea=chat: keep only the right-hand chat area (skip the left session list)
    if ($CropArea -eq 'chat') {
      $cl = [Math]::Min(310, [int]($ww * 0.35))
      $cw2 = $ww - $cl
      if ($cw2 -gt 0) {
        $cb = New-Object System.Drawing.Bitmap($cw2, $wh)
        $cg2 = [System.Drawing.Graphics]::FromImage($cb)
        $cg2.DrawImage($pw, (New-Object System.Drawing.Rectangle(0,0,$cw2,$wh)), (New-Object System.Drawing.Rectangle($cl,0,$cw2,$wh)), [System.Drawing.GraphicsUnit]::Pixel)
        $cg2.Dispose(); $pw.Dispose(); $pw = $cb
        $ww = $cw2; $ox = $r.Left + $cl; $cropTag = " crop=chat"
      }
    }
    $pw.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $pw.Dispose()
    Write-Output ("OK file=" + $OutFile + " mode=window size=" + $ww + "x" + $wh + " origin=" + $ox + "," + $oy + " via=printwindow" + $cropTag + " screen=" + $vs.Width + "x" + $vs.Height)
    $g.Dispose(); $full.Dispose()
    exit 0
  }
  # PrintWindow unavailable: screen grab fallback (may capture occluding windows)
  $x0 = [Math]::Max($r.Left, $vs.X); $y0 = [Math]::Max($r.Top, $vs.Y)
  $x1 = [Math]::Min($r.Right, $vs.X + $vs.Width); $y1 = [Math]::Min($r.Bottom, $vs.Y + $vs.Height)
  $cw = $x1 - $x0; $ch = $y1 - $y0
  if ($cw -le 0 -or $ch -le 0) {
    Write-Output "ERROR: window rect outside screen"
    $g.Dispose(); $full.Dispose(); exit 1
  }
  $cropTag = ""
  if ($CropArea -eq 'chat') {
    $cl = [Math]::Min(310, [int]($cw * 0.35))
    if ($cw - $cl -gt 0) { $x0 = $x0 + $cl; $cw = $cw - $cl; $cropTag = " crop=chat" }
  }
  $crop = New-Object System.Drawing.Bitmap($cw, $ch)
  $cg = [System.Drawing.Graphics]::FromImage($crop)
  $cg.DrawImage($full, (New-Object System.Drawing.Rectangle(0,0,$cw,$ch)), (New-Object System.Drawing.Rectangle(($x0-$vs.X),($y0-$vs.Y),$cw,$ch)), [System.Drawing.GraphicsUnit]::Pixel)
  $crop.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
  $cg.Dispose(); $crop.Dispose()
  Write-Output ("OK file=" + $OutFile + " mode=window size=" + $cw + "x" + $ch + " origin=" + $x0 + "," + $y0 + " via=screengrab" + $cropTag + " screen=" + $vs.Width + "x" + $vs.Height)
} else {
  $full.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Output ("OK file=" + $OutFile + " mode=full size=" + $vs.Width + "x" + $vs.Height)
}
$g.Dispose(); $full.Dispose()
