# Builds the Windows desktop app (Apps/Desktop/talaria) with everything it needs beside
# its exe: HermesBridge.dll from Packages/HermesKit, the Swift runtime and the VC++
# runtime (a clean Windows has neither; without them the app fails with 0xC0000135).
#
#   scripts/windows/Build-Desktop.ps1 [-Configuration Release|Debug]
#
# Swift builds into %LOCALAPPDATA%\talaria-build, outside the repo and with a short path
# (MSBuild, used by Flutter, fails on paths over 260 characters). The app lands in
# Apps/Desktop/talaria/build/windows/x64/runner/<Configuration>.
param(
    [ValidateSet('Release', 'Debug')] [string] $Configuration = 'Release'
)
# Native tools write warnings to stderr, which 'Stop' would turn into failures: each
# step checks its exit code instead.
$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$app = Join-Path $repo 'Apps\Desktop\talaria'
$scratch = Join-Path $env:LOCALAPPDATA 'talaria-build'

# The Visual Studio and Swift environment, for a shell that predates their install.
$vcvars = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvars64.bat' |
    Select-Object -First 1
if (-not $vcvars) { throw 'vcvars64.bat not found: install Visual Studio Build Tools with the C++ workload' }
cmd /c "`"$($vcvars.FullName)`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) }
}
$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$sdk = Get-ChildItem "$swiftRoot\Platforms\*\Windows.platform\Developer\SDKs\Windows.sdk" | Select-Object -Last 1
$runtime = Get-ChildItem "$swiftRoot\Runtimes\*\usr\bin" | Select-Object -Last 1
$toolchain = Get-ChildItem "$swiftRoot\Toolchains\*\usr\bin" | Select-Object -Last 1
if (-not ($sdk -and $runtime -and $toolchain)) { throw "Swift not found under $swiftRoot (winget install Swift.Toolchain)" }
$env:SDKROOT = $sdk.FullName + '\'
$env:Path = "$($toolchain.FullName);$($runtime.FullName);$env:Path"

$swiftConfig = $Configuration.ToLower()
Write-Host "Building HermesBridge ($swiftConfig)"
swift build --package-path (Join-Path $repo 'Packages\HermesKit') --product HermesBridge `
    -c $swiftConfig --scratch-path $scratch
if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
$dll = Get-ChildItem $scratch -Recurse -Filter HermesBridge.dll |
    Where-Object { $_.DirectoryName -match "\\$swiftConfig" } | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $dll) { throw "HermesBridge.dll not found under $scratch" }

Write-Host 'Building the Flutter app'
Push-Location $app
try {
    flutter build windows "--$swiftConfig"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
} finally { Pop-Location }

$out = Join-Path $app "build\windows\x64\runner\$Configuration"
Copy-Item $dll.FullName $out
Copy-Item "$($runtime.FullName)\*.dll" $out
Write-Host "Built: $out\talaria.exe"
