param([Parameter(Mandatory)][string]$PairingFile, [string]$MacHost)
$ErrorActionPreference = 'Stop'
$taskName = 'WorkTimer agent collector'
$dataDirectory = Join-Path $env:USERPROFILE 'AppData\Local\WorkTimer'
$executable = Join-Path $PSScriptRoot 'dist\windows\WorkTimerCollector.exe'
if (!(Test-Path -LiteralPath $executable)) { throw 'Run install-windows.ps1 first.' }
$pairingPath = (Resolve-Path -LiteralPath $PairingFile).Path
Stop-ScheduledTask -TaskName $taskName
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') { break }
    Start-Sleep -Milliseconds 250
}
try {
    $collectorArguments = @('--data-dir', $dataDirectory, '--pair', $pairingPath)
    if ($MacHost) { $collectorArguments += @('--host', $MacHost) }
    & $executable @collectorArguments
    if ($LASTEXITCODE -ne 0) { throw 'Pairing failed; the previous local history was retained.' }
} finally { Start-ScheduledTask -TaskName $taskName }
