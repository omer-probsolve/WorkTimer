param([switch]$Release, [switch]$Test)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
. (Join-Path $PSScriptRoot 'Tools\SwiftEnvironment.ps1')
$configuration = if ($Release) { 'release' } else { 'debug' }
& swift build -c $configuration --product WorkTimerCollector
if ($LASTEXITCODE -ne 0) { throw 'Collector build failed.' }
if ($Test) {
    & swift test
    if ($LASTEXITCODE -ne 0) { throw 'WorkTimer tests failed.' }
}
