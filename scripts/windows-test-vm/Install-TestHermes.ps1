# Installs Hermes in the Windows UI-test VM, as the Mac's test VM has its own (AGENTS.md,
# "Windows host"): the official Windows installer, the `hermesapp-test` profile with
# the test model, and a dashboard on the VM's loopback that the app under test signs
# in to with a session token.
#
#   scripts/windows-test-vm/Install-TestHermes.ps1 [-Reinstall]
#
# Reads the VM's name and account, and the model key, from the repo's git-ignored .env
# (TALARIA_TEST_VM_*, CLIPROXYAPI_KEY). The profile's config.yaml is copied from the
# WSL test profile, so the model settings live in one place. Safe to run again: it
# installs Hermes only when it is missing (or with -Reinstall), and refreshes the rest.
#
# In the VM afterwards: the dashboard at http://127.0.0.1:9139, its session token in
# C:\TalariaTest\dashboard-token.txt, started at logon by the task "Hermes test dashboard".
param([switch] $Reinstall)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
# The main checkout's .env when run from a worktree.
$envFile = @("$repo\.env", "$repo\..\..\..\.env") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $envFile) { throw 'No .env with TALARIA_TEST_VM_* found' }
$kv = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; $kv[$k.Trim()] = $v.Trim().Trim('"')
}
foreach ($k in 'TALARIA_TEST_VM_NAME', 'TALARIA_TEST_VM_USER', 'TALARIA_TEST_VM_PASSWORD', 'CLIPROXYAPI_KEY') {
    if (-not $kv[$k]) { throw "$k missing from $envFile" }
}

# The WSL test profile's config (model settings), never its .env.
$config = wsl.exe -d Ubuntu-24.04 -u talaria -- cat /home/talaria/.hermes/profiles/hermesapp-test/config.yaml
if ($LASTEXITCODE -ne 0 -or -not $config) { throw 'Could not read the WSL test profile config.yaml' }
$config = ($config -join "`n")

$cred = New-Object PSCredential $kv.TALARIA_TEST_VM_USER,
    (ConvertTo-SecureString $kv.TALARIA_TEST_VM_PASSWORD -AsPlainText -Force)
$session = New-PSSession -VMName $kv.TALARIA_TEST_VM_NAME -Credential $cred
try {
    Invoke-Command -Session $session -ArgumentList $Reinstall.IsPresent, $config, $kv.CLIPROXYAPI_KEY, $kv.TALARIA_TEST_VM_USER {
        param($reinstall, $config, $key, $user)
        $ErrorActionPreference = 'Stop'
        $root = 'C:\TalariaTest'
        New-Item -ItemType Directory -Force $root | Out-Null
        $hermesHome = "$env:LOCALAPPDATA\hermes"

        function Find-Hermes {
            Get-ChildItem "$hermesHome\bin", "$hermesHome\hermes-agent" -Recurse -Depth 3 -Include hermes.exe, hermes.cmd, hermes.bat -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }

        $hermes = Find-Hermes
        if ($reinstall -or -not $hermes) {
            Write-Host 'Installing Hermes (official Windows installer)'
            $installer = "$root\install.ps1"
            Invoke-WebRequest https://hermes-agent.nousresearch.com/install.ps1 -OutFile $installer -UseBasicParsing
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -NonInteractive -SkipBrowser -SkipComputerUse
            if ($LASTEXITCODE -ne 0) { throw "Hermes installer failed ($LASTEXITCODE)" }
            Remove-Item $installer
            $hermes = Find-Hermes
            if (-not $hermes) { throw "hermes not found under $hermesHome after the install" }
        }
        Write-Host "Hermes: $hermes"

        $profileDir = "$hermesHome\profiles\hermesapp-test"
        if (-not (Test-Path $profileDir)) {
            & $hermes profile create hermesapp-test
            if ($LASTEXITCODE -ne 0) { throw 'hermes profile create failed' }
        }
        Set-Content -Path "$profileDir\config.yaml" -Value $config -Encoding utf8
        # The model key, in the profile's .env only.
        Set-Content -Path "$profileDir\.env" -Value "CLIPROXYAPI_KEY=$key" -Encoding utf8

        # The dashboard, started at logon in the test user's session.
        $tokenFile = "$root\dashboard-token.txt"
        if (-not (Test-Path $tokenFile)) {
            $bytes = New-Object byte[] 24
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            Set-Content -Path $tokenFile -Value ([Convert]::ToBase64String($bytes) -replace '[+/=]', '') -NoNewline
        }
        $start = "$root\start-dashboard.ps1"
        Set-Content -Path $start -Encoding utf8 -Value @"
`$env:HERMES_DASHBOARD_SESSION_TOKEN = (Get-Content '$tokenFile' -Raw).Trim()
& '$hermes' dashboard --host 127.0.0.1 --port 9139 --no-open --isolated *> '$root\dashboard.log'
"@
        $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $start"
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName 'Hermes test dashboard' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Stop-ScheduledTask -TaskName 'Hermes test dashboard' -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName 'Hermes test dashboard'

        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep 3
            try { $status = Invoke-RestMethod http://127.0.0.1:9139/api/status -TimeoutSec 3 } catch { $status = $null }
        } while (-not $status -and (Get-Date) -lt $deadline)
        if (-not $status) { throw "The dashboard didn't answer; see $root\dashboard.log" }
        Write-Host "Dashboard up: version $($status.version)"
    }
} finally {
    Remove-PSSession $session
}
