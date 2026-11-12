param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (!$SkipBuild) { & (Join-Path $PSScriptRoot 'build-windows.ps1') -Release -Test }
. (Join-Path $PSScriptRoot 'Tools\SwiftEnvironment.ps1')
$binPath = & swift build -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Could not locate the release build.' }
$binary = Join-Path $binPath 'WorkTimerCollector.exe'
if (!(Test-Path -LiteralPath $binary)) { throw 'Build the release collector first.' }
$destination = Join-Path $PSScriptRoot 'dist\windows'
$dataDirectory = Join-Path $env:USERPROFILE 'AppData\Local\WorkTimer'
$taskName = 'WorkTimer agent collector'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) { Stop-ScheduledTask -TaskName $taskName }
for ($attempt = 0; $existing -and $attempt -lt 20; $attempt++) {
    if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') { break }
    Start-Sleep -Milliseconds 250
}
. (Join-Path $PSScriptRoot 'Tools\StopCollector.ps1')
Stop-WorkTimerCollector -Executable (Join-Path $destination 'WorkTimerCollector.exe')
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -LiteralPath $binary -Destination $destination -Force
foreach ($runtimeBin in $runtimeBins) {
    Get-ChildItem -LiteralPath $runtimeBin -Filter '*.dll' -File | Copy-Item -Destination $destination -Force
}
New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
& icacls $dataDirectory /inheritance:r /grant:r "*$($identity.User.Value):(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the local collector data folder.' }
$executable = Join-Path $destination 'WorkTimerCollector.exe'
$launcherPath = Join-Path $destination 'run-collector.ps1'
@'
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot 'WorkTimerCollector.exe'
$dataDirectory = Join-Path $env:USERPROFILE 'AppData\Local\WorkTimer'
& $collector --data-dir $dataDirectory
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $launcherPath -Encoding UTF8
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`"" -WorkingDirectory $destination
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output "Collector installed and started. Local data: $dataDirectory"
