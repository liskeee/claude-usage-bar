# Simulates a left click on the readout by posting WM_LBUTTONUP to its window.
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ClickNative {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string w);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
# [NullString]::Value: PowerShell would turn $null into "" for string parameters
$taskbar = [ClickNative]::FindWindow('Shell_TrayWnd', [NullString]::Value)
$bar = [ClickNative]::FindWindowEx($taskbar, [IntPtr]::Zero, [NullString]::Value, 'ClaudeUsageBar')
if ($bar -eq [IntPtr]::Zero) { throw 'ClaudeUsageBar readout not found in the taskbar' }
[void][ClickNative]::PostMessage($bar, 0x202, [IntPtr]::Zero, [IntPtr]::Zero)
'clicked 0x{0:X}' -f [long]$bar
