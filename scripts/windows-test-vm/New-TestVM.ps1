# Creates the headless Windows 11 test VM in Hyper-V and starts its unattended install.
# Needs the account in "Hyper-V Administrators". Nothing opens on the host's screen.
#
#   New-TestVM.ps1 -WindowsIso <Win11 multi-edition ISO> [-Name TalariaTest] [-Root C:\VMs]
#
# The VM's local account comes from the git-ignored .env at the repo root
# (TALARIA_TEST_VM_USER, TALARIA_TEST_VM_PASSWORD); see AGENTS.md "Windows host".
param(
    [Parameter(Mandatory)] [string] $WindowsIso,
    [string] $Name = 'TalariaTest',
    [string] $Root = 'C:\VMs',
    [string] $EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)
$ErrorActionPreference = 'Stop'

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "A VM named $Name already exists" }
$folder = Join-Path $Root $Name
New-Item -ItemType Directory -Force $folder | Out-Null

# Answer file: the template with the account filled in, on its own small ISO.
$values = @{}
Get-Content $EnvFile | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
foreach ($key in 'TALARIA_TEST_VM_USER', 'TALARIA_TEST_VM_PASSWORD') {
    if (-not $values[$key]) { throw "$key is missing from $EnvFile" }
}
$answerDir = Join-Path $folder 'unattend'
New-Item -ItemType Directory -Force $answerDir | Out-Null
$xml = (Get-Content -Raw (Join-Path $PSScriptRoot 'autounattend.template.xml')).
    Replace('__USER__', $values['TALARIA_TEST_VM_USER']).
    Replace('__PASSWORD__', $values['TALARIA_TEST_VM_PASSWORD'])
[IO.File]::WriteAllText((Join-Path $answerDir 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding $false))
$answerIso = Join-Path $folder 'unattend.iso'
& (Join-Path $PSScriptRoot 'New-AnswerIso.ps1') -Source $answerDir -Iso $answerIso | Out-Null

# Generation 2, 4 cores, 8 GB fixed memory, 80 GB dynamic disk, 1920x1080 screen.
New-VM -Name $Name -Generation 2 -MemoryStartupBytes 8GB -Path $Root `
    -NewVHDPath (Join-Path $folder "$Name.vhdx") -NewVHDSizeBytes 80GB -SwitchName 'Default Switch' | Out-Null
Set-VMProcessor -VMName $Name -Count 4
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Set-VMVideo -VMName $Name -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080
Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
try {
    Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
    Enable-VMTPM -VMName $Name
} catch {
    Write-Warning "No virtual TPM ($($_.Exception.Message)); the answer file bypasses the TPM check."
}
$dvd = Add-VMDvdDrive -VMName $Name -Path $WindowsIso -Passthru
Add-VMDvdDrive -VMName $Name -Path $answerIso
Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
Start-VM -Name $Name

# Gen 2 firmware asks to "Press any key to boot from CD or DVD" for a few seconds; answer
# through the VM's virtual keyboard. Stop well before Setup's own screen comes up: an Enter
# there presses its Cancel button.
$ns = 'root\virtualization\v2'
$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$keyboard = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard
for ($i = 0; $i -lt 6; $i++) {
    Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{ keyCode = [uint32]0x0D } | Out-Null
    Start-Sleep -Seconds 1
}
Write-Host "$Name is installing Windows. Check it with Get-VMScreenshot.ps1."
