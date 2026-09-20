#!/usr/bin/env pwsh
<#
  Run a PowerShell script elevated (ConsentPromptBehaviorAdmin=0 on this box
  means silent elevation) and bring its output back.

  Start-Process -Verb RunAs cannot redirect stdio, and passing an inline
  "-Command" string with quotes gets mangled by ArgumentList.  So we write a
  tiny wrapper .ps1 and run that with -File instead.

  Usage:
      .\elev.ps1 -Script C:\leidian\livepatch.ps1 -ScriptArgs '-Probe'
      .\elev.ps1 -Script C:\leidian\livepatch.ps1            # no args
#>
param(
    [Parameter(Mandatory)][string]$Script,
    [string[]]$ScriptArgs = @(),
    [string]$Log,
    [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
if (-not $Log) { $Log = [IO.Path]::ChangeExtension($Script, '.elev.log') }
Remove-Item -LiteralPath $Log -ErrorAction SilentlyContinue

$argLine = ($ScriptArgs -join ' ')
$wrapper = @"
`$ErrorActionPreference = 'Continue'
& '$Script' $argLine *> '$Log'
"--- exit=`$LASTEXITCODE  errors=`$(`$Error.Count) ---" | Add-Content -LiteralPath '$Log'
`$Error | ForEach-Object { ('ERROR: ' + `$_.ToString()) } | Add-Content -LiteralPath '$Log'
`$Error | ForEach-Object { ('AT   : ' + `$_.InvocationInfo.PositionMessage) } | Add-Content -LiteralPath '$Log'
"@
$wf = Join-Path $env:TEMP ('elev_' + [guid]::NewGuid().ToString('N') + '.ps1')
Set-Content -LiteralPath $wf -Value $wrapper -Encoding ASCII

try {
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wf)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Write-Host "elevated process still running after ${TimeoutSec}s (pid $($p.Id))" -ForegroundColor Yellow
    } else {
        Write-Host ("elevated exit code {0}" -f $p.ExitCode) -ForegroundColor DarkGray
    }
} finally {
    Remove-Item -LiteralPath $wf -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log }
else { Write-Host "(no log produced - check $Log)" -ForegroundColor Yellow }
