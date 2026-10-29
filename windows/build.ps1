param([switch]$DebugBuild)
$ErrorActionPreference = 'Stop'
$sourceRoot = Join-Path $PSScriptRoot 'source'
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath)) { throw '.NET Framework 4.x compiler was not found.' }
$sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cs' | ForEach-Object { $_.FullName }
$buildArguments = @('/nologo','/target:winexe','/platform:x64','/langversion:5','/optimize+','/codepage:65001',('/out:' + (Join-Path $PSScriptRoot 'NetScope.exe')),('/win32manifest:' + (Join-Path $sourceRoot 'app.manifest')),('/win32icon:' + (Join-Path $sourceRoot 'NetScope.ico')),'/r:System.dll','/r:System.Core.dll','/r:System.Drawing.dll','/r:System.Windows.Forms.dll','/r:System.Web.Extensions.dll','/r:System.Net.Http.dll','/r:Microsoft.VisualBasic.dll')
$libraryRoot = Join-Path $PSScriptRoot 'lib'
if(Test-Path -LiteralPath $libraryRoot){Get-ChildItem -LiteralPath $libraryRoot -Filter '*.dll' | ForEach-Object { $buildArguments += '/r:' + $_.FullName }}
& $compilerPath @buildArguments @sourceFiles
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }
Write-Output 'Built NetScope.exe'

