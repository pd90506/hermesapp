# Builds the Electron desktop app (Apps/Desktop/electron) on Windows: installs the pnpm
# workspace, type-checks and tests it, then packs an unpacked app.
#
#   scripts/windows/Build-Electron.ps1 [-SkipTests]
#
# Needs Node 22.12 or newer (winget install OpenJS.NodeJS.LTS); pnpm comes from Node's
# corepack at the version the root package.json pins. The app lands in
# Apps/Desktop/electron/dist/win-unpacked/Talaria.exe.
param(
    [switch] $SkipTests
)
$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'Node.js not found: winget install OpenJS.NodeJS.LTS' }
$version = [version]((node --version).TrimStart('v'))
if ($version -lt [version]'22.12.0') { throw "Node $version is too old: 22.12 or newer is needed" }

function Invoke-Pnpm {
    corepack pnpm @args
    if ($LASTEXITCODE -ne 0) { throw "pnpm $($args -join ' ') failed" }
}

Push-Location $repo
try {
    $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
    Invoke-Pnpm install --frozen-lockfile
    if (-not $SkipTests) {
        Invoke-Pnpm typecheck
        Invoke-Pnpm test
    }
    Invoke-Pnpm desktop:pack
} finally { Pop-Location }

$exe = Join-Path $repo 'Apps\Desktop\electron\dist\win-unpacked\Talaria.exe'
if (-not (Test-Path $exe)) { throw "Talaria.exe not found at $exe" }
Write-Host "Built: $exe"
