$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Install the Microsoft C++ Build Tools and Windows SDK first.' }
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'No Microsoft C++ toolchain was found.' }
$developerCommand = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
$developerEnvironment = & $env:ComSpec /d /c "call `"$developerCommand`" -arch=x64 -host_arch=x64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the Microsoft build environment.' }
foreach ($entry in $developerEnvironment) {
    if ($entry -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
$swiftBase = Join-Path $env:USERPROFILE 'AppData\Local\Programs\Swift'
if (!(Test-Path -LiteralPath $swiftBase)) { $swiftBase = Join-Path $env:ProgramFiles 'Swift' }
$swiftToolchain = Get-ChildItem -LiteralPath (Join-Path $swiftBase 'Toolchains') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$swiftPlatform = Get-ChildItem -LiteralPath (Join-Path $swiftBase 'Platforms') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (!$swiftToolchain -or !$swiftPlatform) { throw 'Install the official Swift Windows toolchain first.' }
$env:SDKROOT = Join-Path $swiftPlatform.FullName 'Windows.platform\Developer\SDKs\Windows.sdk'
$swiftBin = Join-Path $swiftToolchain.FullName 'usr\bin'
$runtimeBins = Get-ChildItem -LiteralPath (Join-Path $swiftBase 'Runtimes') -Filter bin -Directory -Recurse | Select-Object -ExpandProperty FullName
$platformRuntime = Join-Path $env:SDKROOT 'usr\bin'
$env:Path = (@($swiftBin, $platformRuntime) + @($runtimeBins) + @($env:Path)) -join ';'
