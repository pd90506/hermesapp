# Runs the Windows desktop app in the UI-test VM and saves screenshots of its window,
# never opening it on the host's screen (AGENTS.md, "Windows host").
#
#   scripts/windows-test-vm/Invoke-AppInVM.ps1 -OutDir <dir> [-Name shot] [-Fresh]
#       [-AppDir <Release folder>] [-Settings <json>] [-Secret <text>] [-WaitSeconds 6]
#
# Copies the built app (scripts/windows/Build-Desktop.ps1) into C:\TalariaTest\app,
# starts it in the test user's desktop session through a scheduled task (PowerShell
# Direct runs in session 0, which has no desktop), and captures the window from that
# session with the screen's own pixels (Get-VMScreenshot.ps1's Hyper-V thumbnail is
# RGB565, good only to see what the VM shows). The app is closed afterwards.
#
# -Fresh clears the app's settings and saved secret first (the first-run page).
# -Settings writes %APPDATA%\Talaria\settings.json, and -Secret the secret, before start.
param(
    [Parameter(Mandatory)] [string] $OutDir,
    [string] $Name = 'shot',
    [string] $AppDir,
    [switch] $Fresh,
    [string] $Settings,
    [string] $Secret,
    [int] $WaitSeconds = 6
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
if (-not $AppDir) { $AppDir = "$repo\Apps\Desktop\talaria\build\windows\x64\runner\Release" }
if (-not (Test-Path "$AppDir\talaria.exe")) { throw "No talaria.exe in $AppDir; run scripts/windows/Build-Desktop.ps1" }
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
param([string]$Out)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, int f, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
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
# Escape closes a Start menu left open; Alt lets this background process move the focus.
[W]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero); [W]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
[W]::keybd_event(0x12, 0, 0, [IntPtr]::Zero); [W]::SetForegroundWindow($h) | Out-Null
[W]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 1200
$r = New-Object W+RECT
[W]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null   # DWMWA_EXTENDED_FRAME_BOUNDS
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
    Invoke-Command -Session $s -ArgumentList $capture, $user, $Name, $Fresh.IsPresent, $Settings, $Secret, $WaitSeconds {
        param($capture, $user, $name, $fresh, $settings, $secret, $wait)
        $ErrorActionPreference = 'Stop'
        Set-Content C:\TalariaTest\capture.ps1 $capture -Encoding utf8
        $appData = "$env:APPDATA\Talaria"
        if ($fresh) {
            Remove-Item $appData -Recurse -Force -ErrorAction SilentlyContinue
            cmdkey /delete:Talaria:server 2>$null | Out-Null
        }
        if ($settings) {
            New-Item -ItemType Directory -Force $appData | Out-Null
            Set-Content "$appData\settings.json" $settings -Encoding utf8
        }
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
        if ($secret) {
            # Credential Manager is per logon session: write it from the user's session.
            Set-Content C:\TalariaTest\secret.txt $secret -NoNewline
            $a = New-ScheduledTaskAction -Execute cmd.exe -Argument '/c for /f "delims=" %s in (C:\TalariaTest\secret.txt) do cmdkey /generic:Talaria:server /user:test /pass:%s'
            Register-ScheduledTask -TaskName talaria-secret -Action $a -Principal $principal -Force | Out-Null
            Start-ScheduledTask talaria-secret
            Start-Sleep 3
            Unregister-ScheduledTask talaria-secret -Confirm:$false
            Remove-Item C:\TalariaTest\secret.txt
        }
        $a = New-ScheduledTaskAction -Execute C:\TalariaTest\app\talaria.exe
        Register-ScheduledTask -TaskName talaria-app -Action $a -Principal $principal -Force | Out-Null
        Start-ScheduledTask talaria-app
        Start-Sleep $wait
        $out = "C:\TalariaTest\shots\$name.png"
        $c = New-ScheduledTaskAction -Execute powershell.exe `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\TalariaTest\capture.ps1 -Out $out"
        Register-ScheduledTask -TaskName talaria-shot -Action $c -Principal $principal -Force | Out-Null
        Start-ScheduledTask talaria-shot
        for ($i = 0; $i -lt 60 -and -not (Test-Path $out) -and -not (Test-Path "$out.err"); $i++) { Start-Sleep 1 }
        Start-Sleep 1
        Get-Process talaria -ErrorAction SilentlyContinue | Stop-Process -Force
        Unregister-ScheduledTask talaria-app -Confirm:$false
        Unregister-ScheduledTask talaria-shot -Confirm:$false
        if (-not (Test-Path $out)) { throw "No screenshot: $(Get-Content "$out.err" -ErrorAction SilentlyContinue)" }
    }
    Copy-Item "C:\TalariaTest\shots\$Name.png" -Destination $OutDir -FromSession $s -Force
    Get-Item (Join-Path $OutDir "$Name.png")
} finally {
    Remove-PSSession $s
}
