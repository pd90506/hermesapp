# Runs the Windows desktop app in the UI-test VM and saves screenshots of its window,
# never opening it on the host's screen (AGENTS.md, "Windows host").
#
#   scripts/windows-test-vm/Invoke-AppInVM.ps1 -OutDir <dir> [-Name shot] [-Fresh]
#       [-AppDir <win-unpacked folder>] [-Settings <json>] [-WaitSeconds 6]
#       [-Steps <PowerShell>]
#
# Copies the built Electron app (scripts/windows/Build-Electron.ps1) into C:\TalariaTest\app,
# starts it in the test user's desktop session through a scheduled task (PowerShell
# Direct runs in session 0, which has no desktop), and captures the window from that
# session with the screen's own pixels (Get-VMScreenshot.ps1's Hyper-V thumbnail is
# RGB565, good only to see what the VM shows). The app is closed afterwards.
#
# -Fresh clears the app's data folder, settings and saved secret included (the first-run page).
# -Settings writes %APPDATA%\Talaria Desktop\settings.json before start. The secret is
# encrypted for the user (safeStorage) and can't be written from outside: sign in with -Steps.
# -Steps drives the app before the screenshot, in the user's session, with `Click x y`
# (pixels from the window's top-left), `Write-Text 'text'` (into the focused field),
# `Key 0x0D` (a key press by virtual-key code) and `Wait seconds`,
# e.g. -Steps "Click 305 68; Wait 2; Click 790 755; Wait 1; Write-Text 'Hi'; Key 0x0D; Wait 20".
param(
    [Parameter(Mandatory)] [string] $OutDir,
    [string] $Name = 'shot',
    [string] $AppDir,
    [switch] $Fresh,
    [string] $Settings,
    [int] $WaitSeconds = 6,
    [string] $Steps
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
if (-not $AppDir) { $AppDir = "$repo\Apps\Desktop\electron\dist\win-unpacked" }
if (-not (Test-Path "$AppDir\Talaria.exe")) { throw "No Talaria.exe in $AppDir; run scripts/windows/Build-Electron.ps1" }
$envFile = @("$repo\.env", "$repo\..\..\..\.env") | Where-Object { Test-Path $_ } | Select-Object -First 1
$kv = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*TALARIA_TEST_VM_\w+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; $kv[$k.Trim()] = $v.Trim().Trim('"')
}
$user = $kv.TALARIA_TEST_VM_USER
$cred = New-Object PSCredential $user, (ConvertTo-SecureString $kv.TALARIA_TEST_VM_PASSWORD -AsPlainText -Force)
New-Item -ItemType Directory -Force $OutDir | Out-Null

# Captures the app's window as it shows on the screen, run inside the user's session.
$capture = @'
param([string]$Out, [string]$Steps)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, int f, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  // Moves the keyboard focus to h: a background process may not, unless it shares
  // the input queue of the window that has it.
  public static bool Activate(IntPtr h) {
    uint me = GetCurrentThreadId();
    uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    uint target = GetWindowThreadProcessId(h, IntPtr.Zero);
    AttachThreadInput(me, fg, true); AttachThreadInput(me, target, true);
    BringWindowToTop(h); SetForegroundWindow(h);
    AttachThreadInput(me, fg, false); AttachThreadInput(me, target, false);
    return GetForegroundWindow() == h;
  }
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  // Key presses as a keyboard sends them, with their scan codes: Flutter reads keys by
  // scan code, and drops SendKeys' VK_PACKET characters and keys without one.
  static void Key(byte vk, bool up) { keybd_event(vk, (byte)MapVirtualKey(vk, 0), up ? 2 : 0, IntPtr.Zero); }
  public static void Press(byte vk, bool shift) {
    if (shift) Key(0x10, false);
    Key(vk, false); Key(vk, true);
    if (shift) Key(0x10, true);
  }
  [StructLayout(LayoutKind.Sequential)] public struct GTI { public int cbSize; public int flags; public IntPtr active; public IntPtr focus; public IntPtr capture; public IntPtr menuOwner; public IntPtr moveSize; public IntPtr caret; public RECT rc; }
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint t, ref GTI g);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  // Text as WM_CHAR messages to the window with the keyboard focus (the Flutter view):
  // Flutter's text fields take no text from synthesized key presses in the VM, while
  // its shortcuts and Enter do.
  public static bool TypeText(IntPtr top, string text) {
    var g = new GTI(); g.cbSize = Marshal.SizeOf(g);
    GetGUIThreadInfo(GetWindowThreadProcessId(top, IntPtr.Zero), ref g);
    if (g.focus == IntPtr.Zero) return false;
    foreach (char c in text) { PostMessage(g.focus, 0x0102, (IntPtr)c, (IntPtr)1); System.Threading.Thread.Sleep(10); }
    return true;
  }
}
"@
[W]::SetProcessDPIAware() | Out-Null
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 60 -and $h -eq [IntPtr]::Zero; $i++) {
    $p = Get-Process talaria -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { $h = $p.MainWindowHandle }
    if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500 }
}
if ($h -eq [IntPtr]::Zero) { 'no window' | Set-Content "$Out.err"; exit 1 }
# Escape closes a Start menu left open.
[W]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero); [W]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
[W]::Activate($h) | Out-Null
Start-Sleep -Milliseconds 1200
$r = New-Object W+RECT
[W]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null   # DWMWA_EXTENDED_FRAME_BOUNDS
if ($Steps -and (Test-Path $Steps)) {
    function Click([int]$x, [int]$y) {
        [W]::SetCursorPos($r.L + $x, $r.T + $y) | Out-Null
        [W]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); [W]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
    }
    # Not `Type`: PowerShell's alias for Get-Content would win over a function of that name.
    function Write-Text([string]$text) {
        if (-not [W]::TypeText($h, $text)) { 'Type: no window has the keyboard focus' | Add-Content "$Out.warn" }
        Start-Sleep -Milliseconds 300
    }
    # A virtual-key code: 0x0D Enter, 0x1B Escape, 0x09 Tab.
    function Key([int]$vk, [switch]$Shift) { [W]::Press([byte]$vk, $Shift.IsPresent) }
    function Wait([double]$seconds) { Start-Sleep -Milliseconds ($seconds * 1000) }
    if (-not [W]::Activate($h)) { 'the app is not in the foreground' | Set-Content "$Out.warn" }
    try { . $Steps } catch { "steps failed: $_" | Add-Content "$Out.warn" }
    [W]::SetCursorPos(0, 0) | Out-Null   # no hover left on the shot
    Start-Sleep -Milliseconds 500
    [W]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null
}
$w = $r.R - $r.L; $hh = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $hh))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
'@

$s = New-PSSession -VMName $kv.TALARIA_TEST_VM_NAME -Credential $cred
try {
    Invoke-Command -Session $s {
        Get-Process talaria -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 1
        Remove-Item C:\TalariaTest\app, C:\TalariaTest\shots -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force C:\TalariaTest\shots | Out-Null
    }
    Copy-Item $AppDir -Destination C:\TalariaTest\app -ToSession $s -Recurse
    Invoke-Command -Session $s -ArgumentList $capture, $user, $Name, $Fresh.IsPresent, $Settings, $WaitSeconds, $Steps {
        param($capture, $user, $name, $fresh, $settings, $wait, $steps)
        $ErrorActionPreference = 'Stop'
        Set-Content C:\TalariaTest\capture.ps1 $capture -Encoding utf8
        Remove-Item C:\TalariaTest\steps.ps1 -ErrorAction SilentlyContinue
        if ($steps) { Set-Content C:\TalariaTest\steps.ps1 $steps -Encoding utf8 }
        # The app's data folder in the test user's profile (src/main/main.ts, userData; this session runs as the test user).
        $appData = "$env:APPDATA\Talaria Desktop"
        if ($fresh) { Remove-Item $appData -Recurse -Force -ErrorAction SilentlyContinue }
        if ($settings) {
            New-Item -ItemType Directory -Force $appData | Out-Null
            Set-Content "$appData\settings.json" $settings -Encoding utf8
        }
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
        $a = New-ScheduledTaskAction -Execute C:\TalariaTest\app\Talaria.exe
        Register-ScheduledTask -TaskName talaria-app -Action $a -Principal $principal -Force | Out-Null
        Start-ScheduledTask talaria-app
        Start-Sleep $wait
        $out = "C:\TalariaTest\shots\$name.png"
        $c = New-ScheduledTaskAction -Execute powershell.exe `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\TalariaTest\capture.ps1 -Out $out -Steps C:\TalariaTest\steps.ps1"
        Register-ScheduledTask -TaskName talaria-shot -Action $c -Principal $principal -Force | Out-Null
        Start-ScheduledTask talaria-shot
        for ($i = 0; $i -lt 300 -and -not (Test-Path $out) -and -not (Test-Path "$out.err"); $i++) { Start-Sleep 1 }
        Start-Sleep 1
        Get-Process talaria -ErrorAction SilentlyContinue | Stop-Process -Force
        Unregister-ScheduledTask talaria-app -Confirm:$false
        Unregister-ScheduledTask talaria-shot -Confirm:$false
        if (-not (Test-Path $out)) { throw "No screenshot: $(Get-Content "$out.err" -ErrorAction SilentlyContinue)" }
        if (Test-Path "$out.warn") { Write-Warning (Get-Content "$out.warn" -Raw) }
    }
    Copy-Item "C:\TalariaTest\shots\$Name.png" -Destination $OutDir -FromSession $s -Force
    Get-Item (Join-Path $OutDir "$Name.png")
} finally {
    Remove-PSSession $s
}
