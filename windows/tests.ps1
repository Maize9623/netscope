param(
    [string]$OutputDirectory = '',
    [switch]$LiveQuota
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ('NetScope-tests-' + [Guid]::NewGuid().ToString('N'))
}
$runDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath)) { throw '.NET Framework 4.x compiler was not found.' }
$sourceRoot = Join-Path $PSScriptRoot 'source'
$testsRoot = Join-Path $PSScriptRoot 'tests'
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cs' -File | ForEach-Object FullName)
$references = @('/r:System.dll','/r:System.Core.dll','/r:System.Drawing.dll','/r:System.Windows.Forms.dll','/r:System.Web.Extensions.dll','/r:System.Net.Http.dll','/r:Microsoft.VisualBasic.dll','/r:System.Management.dll','/r:System.Runtime.Serialization.dll','/r:System.Xml.dll')
$libDirectory = Join-Path $PSScriptRoot 'lib'
if (Test-Path -LiteralPath $libDirectory) {
    foreach ($item in Get-ChildItem -LiteralPath $libDirectory -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $runDirectory -Recurse -Force
    }
    foreach ($dependency in Get-ChildItem -LiteralPath $libDirectory -Filter '*.dll' -File -Recurse) {
        try {
            [Reflection.AssemblyName]::GetAssemblyName($dependency.FullName) | Out-Null
            $references += '/r:' + $dependency.FullName
            Copy-Item -LiteralPath $dependency.FullName -Destination (Join-Path $runDirectory $dependency.Name) -Force
        } catch [System.BadImageFormatException] {
            # Native libraries are copied above; only managed assemblies are compiler references.
        }
    }
}
$libraryPath = Join-Path $runDirectory 'NetScope.dll'
$libraryArgs = @('/nologo','/target:library','/platform:x64','/langversion:5','/codepage:65001','/optimize+',('/out:' + $libraryPath)) + $references
& $compilerPath @libraryArgs @sourceFiles
if ($LASTEXITCODE -ne 0) { throw 'Application source compilation for tests failed.' }
$names = @('DiagnosticsTests','ControllerReviewTests','QuotaClientTests','FinalIntegrationTests','AiReportTests','ProcessInsightsTests','ProcessTrafficTests','DeviceAITests','DeviceIdentityTests','CollectorAdapterTests','DeviceDiscoveryTests','DiscoveryControllerTests','UiRegression')
$overall = New-Object 'System.Collections.Generic.List[string]'
$failureCount = 0
foreach ($name in $names) {
    $testExecutable = Join-Path $runDirectory ($name + '.exe')
    $testSource = Join-Path $testsRoot ($name + '.cs')
    $testArgs = @('/nologo','/target:exe','/platform:x64','/langversion:5','/codepage:65001',('/out:' + $testExecutable),('/r:' + $libraryPath)) + $references
    $testSources = @($testSource)
    if ($name -eq 'ProcessTrafficTests') {
        # Compile the internal counter and its tests together; production visibility stays internal.
        $testArgs = @($testArgs | Where-Object { $_ -ne ('/r:' + $libraryPath) })
        $testSources += Join-Path $sourceRoot 'ProcessTraffic.cs'
    }
    if ($name -eq 'DeviceIdentityTests') {
        # Inject a fake DNS resolver; the tests never issue name lookups.
        $testArgs = @($testArgs | Where-Object { $_ -ne ('/r:' + $libraryPath) })
        $testSources += Join-Path $sourceRoot 'Models.cs'
        $testSources += Join-Path $sourceRoot 'DeviceIdentity.cs'
    }
    if ($name -eq 'CollectorAdapterTests' -or $name -eq 'DeviceDiscoveryTests') {
        $testArgs = @($testArgs | Where-Object { $_ -ne ('/r:' + $libraryPath) })
        $testSources += Join-Path $sourceRoot 'Models.cs'
        $testSources += Join-Path $sourceRoot 'NetworkCollector.cs'
        if ($name -eq 'DeviceDiscoveryTests') {
            $testSources += Join-Path $sourceRoot 'DeviceIdentity.cs'
            $testSources += Join-Path $sourceRoot 'DeviceDiscovery.cs'
        }
    }
    if ($name -eq 'UiRegression') {
        $testArgs = @($testArgs | Where-Object { $_ -ne ('/r:' + $libraryPath) })
        $testArgs += '/main:UiRegression'
        $testSources += $sourceFiles
    }
    & $compilerPath @testArgs @testSources
    if ($LASTEXITCODE -ne 0) { throw ('Test compilation failed: ' + $name) }
    $arguments = @()
    if ($name -eq 'UiRegression') { $arguments = @($runDirectory) }
    if ($name -eq 'FinalIntegrationTests') { $arguments = @((Join-Path $sourceRoot 'MainForm.cs')) }
    if ($name -eq 'QuotaClientTests' -and $LiveQuota) {
        $codexCommand = Get-Command 'codex.exe' -ErrorAction Stop
        $arguments = @($codexCommand.Source)
    }
    $lines = @(& $testExecutable @arguments 2>&1 | ForEach-Object { $_.ToString() })
    $testExitCode = $LASTEXITCODE
    $lines | Set-Content -LiteralPath (Join-Path $runDirectory ($name + '.results.txt')) -Encoding UTF8
    $lines | ForEach-Object { Write-Output $_ }
    $overall.Add($name + ': exit ' + $testExitCode)
    if ($testExitCode -ne 0) { $failureCount++ }
}
$overall.Add('Finished: ' + (Get-Date).ToString('o'))
$overall.Add('Default tests are synthetic/local: no monitoring timer, model call, network request, UAC prompt, or ETW session.')
$overall.Add('LiveQuota=' + [string][bool]$LiveQuota + '; optional live quota read calls no model and consumes no reset credit.')
$overall.Add('Test data and detailed logs: ' + $runDirectory)
$overall | Set-Content -LiteralPath (Join-Path $runDirectory 'summary.txt') -Encoding UTF8
$overall | ForEach-Object { Write-Output $_ }
if ($failureCount -gt 0) { throw ($failureCount.ToString() + ' test suites failed.') }
