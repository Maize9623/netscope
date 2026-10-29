param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ('NetScope-loopback-' + [Guid]::NewGuid().ToString('N'))
}
$runDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath)) { throw '.NET Framework compiler was not found.' }
$executable = Join-Path $runDirectory 'CollectorLocalTest.exe'
$sources = @(
    (Join-Path $PSScriptRoot 'source\Models.cs'),
    (Join-Path $PSScriptRoot 'source\NetworkCollector.cs'),
    (Join-Path $PSScriptRoot 'tests\CollectorLocalTest.cs')
)
$compilerArguments = @('/nologo','/target:exe','/platform:x64','/langversion:5','/codepage:65001',('/out:' + $executable),'/r:System.dll','/r:System.Core.dll')
& $compilerPath @compilerArguments @sources
if ($LASTEXITCODE -ne 0) { throw 'Loopback test compilation failed.' }
Write-Output 'Optional local network test: listens only on 127.0.0.1 at an OS-selected port; no external HTTP or DNS.'
Write-Output 'Also reads local adapter/neighbor data. A working up adapter with a gateway is required for warmup checks.'
Write-Output 'Expected duration: about 15 seconds. This suite is deliberately excluded from tests.ps1.'
$lines = @(& $executable 2>&1 | ForEach-Object { $_.ToString() })
$testExitCode = $LASTEXITCODE
$lines | Set-Content -LiteralPath (Join-Path $runDirectory 'CollectorLocalTest.results.txt') -Encoding UTF8
$lines | ForEach-Object { Write-Output $_ }
Write-Output ('Detailed result: ' + (Join-Path $runDirectory 'CollectorLocalTest.results.txt'))
if ($testExitCode -ne 0) { throw ('Loopback suite failed: exit ' + $testExitCode) }
