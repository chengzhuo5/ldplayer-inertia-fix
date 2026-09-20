# Build inertia-native.exe with the .NET Framework compiler.
# No Visual Studio needed - csc.exe ships with Windows (.NET Framework 4.x).
#
#   .\build.ps1
#
# NOTE: the target agent must run elevated and must be built for the OS bitness
# (x64 here) so it can enumerate modules inside the elevated dnplayer.exe.

param(
    [string]$OutDir,
    [switch]$SkipSelfTest
)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = $Here }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found - .NET Framework 4.x is required" }

$src = Join-Path $Here 'inertia-native.cs'
$exe = Join-Path $OutDir 'inertia-native.exe'
if (-not (Test-Path -LiteralPath $src)) { throw "missing source: $src" }

Write-Host "compiler: $csc"
& $csc /nologo /target:winexe /optimize+ /platform:x64 /out:$exe $src
if ($LASTEXITCODE -ne 0) { throw "compile failed (exit $LASTEXITCODE)" }
Write-Host ("built: {0} ({1} bytes)" -f $exe, (Get-Item -LiteralPath $exe).Length) -ForegroundColor Green

if (-not $SkipSelfTest) {
    # /target:winexe does not block PowerShell, so -Wait is required for the exit code
    $p = Start-Process -FilePath $exe -ArgumentList '--selftest' -PassThru -Wait -WindowStyle Hidden
    if ($p.ExitCode -eq 0) {
        Write-Host "selftest: ALL PASS" -ForegroundColor Green
    } else {
        Write-Host ("selftest exit code {0} - if LDPlayer is not installed yet, that is expected" -f $p.ExitCode) -ForegroundColor Yellow
    }
}
