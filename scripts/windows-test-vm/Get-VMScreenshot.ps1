# Saves what a Hyper-V VM's screen shows as a PNG, without opening a VM window.
# Uses Hyper-V's own thumbnail API (Msvm_VirtualSystemManagementService), which returns
# the frame buffer as RGB565.
#
#   Get-VMScreenshot.ps1 -VMName TalariaTest -Path shot.png [-Width 1920 -Height 1080]
param(
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $Path,
    [int] $Width = 1920,
    [int] $Height = 1080
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ns = 'root\virtualization\v2'
$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
if (-not $vm) { throw "No VM named $VMName" }
$settings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData |
    Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
$service = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$result = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage -Arguments @{
    TargetSystem = $settings; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height
}
if ($result.ReturnValue -ne 0 -or -not $result.ImageData) { throw "Thumbnail failed: $($result.ReturnValue)" }

$data = [byte[]]$result.ImageData
$bitmap = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$rect = New-Object System.Drawing.Rectangle 0, 0, $Width, $Height
$lock = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)
try {
    for ($y = 0; $y -lt $Height; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy($data, $y * $Width * 2, [IntPtr]($lock.Scan0.ToInt64() + $y * $lock.Stride), $Width * 2)
    }
} finally { $bitmap.UnlockBits($lock) }
$bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
Get-Item $Path
