function Stop-WorkTimerCollector {
    param([Parameter(Mandatory)][string]$Executable)
    # Task Scheduler can stop the hidden launcher while leaving its child alive.
    # Stop only this installation's exact executable before acquiring its data lock.
    $expected = [IO.Path]::GetFullPath($Executable)
    foreach ($process in Get-Process -Name WorkTimerCollector -ErrorAction SilentlyContinue) {
        if ($process.Path -and [IO.Path]::GetFullPath($process.Path) -eq $expected) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            if (!$process.WaitForExit(5000)) { throw 'The WorkTimer collector did not stop in time.' }
        }
    }
}
