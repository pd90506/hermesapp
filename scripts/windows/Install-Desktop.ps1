# Builds the Windows desktop app from this checkout and installs it for the current
# user, replacing the copy installed before; then removes what the build left behind.
# Run it from the main checkout after a merge (AGENTS.md, "Windows host").
#
#   scripts/windows/Install-Desktop.ps1
#
# Installs to %LOCALAPPDATA%\Programs\Talaria, with a Start menu shortcut. A running
# Talaria from there is closed first. Settings (%APPDATA%\Talaria) and the saved
# sign-in (Credential Manager) are kept. Nothing is started.
$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$app = Join-Path $repo 'Apps\Desktop\talaria'
$target = Join-Path $env:LOCALAPPDATA 'Programs\Talaria'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Talaria.lnk'

& "$PSScriptRoot\Build-Desktop.ps1" -Configuration Release
if (-not $?) { throw 'The build failed; nothing was installed' }
$built = Join-Path $app 'build\windows\x64\runner\Release'
if (-not (Test-Path "$built\talaria.exe")) { throw "No talaria.exe in $built; nothing was installed" }

Get-Process talaria -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.CloseMainWindow() | Out-Null; if (-not $_.WaitForExit(5000)) { $_ | Stop-Process -Force } }

# The new build, exactly: robocopy /MIR also removes files the old one had.
robocopy $built $target /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Copying to $target failed (robocopy $LASTEXITCODE)" }

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = Join-Path $target 'talaria.exe'
$link.WorkingDirectory = $target
$link.Description = 'Talaria, a Hermes client'
$link.Save()

# No leftovers: the Flutter build, its generated files, and the Swift build.
foreach ($dir in @((Join-Path $app 'build'), (Join-Path $app '.dart_tool'),
                   (Join-Path $app 'windows\flutter\ephemeral'),
                   (Join-Path $repo 'Apps\Desktop\hermes_bridge\.dart_tool'),
                   (Join-Path $env:LOCALAPPDATA 'talaria-build'))) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
}
Write-Host "Installed: $target\talaria.exe (Start menu: Talaria)"
