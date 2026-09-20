#!/usr/bin/env pwsh
<#
  Install / remove the "smart inertia" scheduled task for LDPlayer right-click walk.

      quick right click  -> long glide
      long press+release -> stop instantly

  The task must run with HIGHEST privileges in the CURRENT USER's interactive
  session - otherwise it cannot see the mouse input (per-session) nor write into
  dnplayer.exe (which runs elevated).

  Two engines, same behaviour:
      exe  inertia-native.exe   event driven (WH_MOUSE_LL hook), ~0% CPU,
                                no PowerShell, no Add-Type compile
      ps   inertia-smart.ps1    polls GetAsyncKeyState every -PollMs ms

  Both live next to this script; nothing about the LDPlayer install is hard-coded.

  Usage (needs elevation; call through elev.ps1):
      .\install-inertia-task.ps1                                  # auto: exe if built
      .\install-inertia-task.ps1 -Engine ps -PollMs 8             # fall back to PowerShell
      .\install-inertia-task.ps1 -CursorLock                      # + F8 mouse-lock watchdog
      .\install-inertia-task.ps1 -LongPressMs 250 -ShortDec 0xFC  # tune
      .\install-inertia-task.ps1 -Remove
      .\install-inertia-task.ps1 -Status
#>
param(
    [int]$LongPressMs = 200,
    [int]$ShortDec = 0xFF,
    [int]$PollMs = 4,
    [ValidateSet('auto', 'exe', 'ps')][string]$Engine = 'auto',
    [switch]$CursorLock,
    [switch]$ClipDebug,
    [switch]$Remove,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$TaskName = 'LDPlayer-InertiaSmart'
# everything lives next to this script - no hard-coded install paths
$Here     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script   = Join-Path $Here 'inertia-smart.ps1'
$Log      = Join-Path $Here 'inertia-smart.log'
$Exe      = Join-Path $Here 'inertia-native.exe'
$ExeLog   = Join-Path $Here 'inertia-native.log'
$Elev     = Join-Path $Here 'elev.ps1'

# dnplycore.dll is NOT hard-coded either: search the usual roots.
function Find-LdDll {
    param([string[]]$Roots)
    if (-not $Roots) {
        $Roots = @('C:\', 'D:\', 'E:\', 'F:\', $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
                 Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    }
    foreach ($root in $Roots) {
        foreach ($sub in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -notmatch 'ldplayer|leidian') { continue }
            $c = Join-Path $sub.FullName 'dnplycore.dll'
            if (Test-Path -LiteralPath $c) { return $c }
            foreach ($sub2 in (Get-ChildItem -LiteralPath $sub.FullName -Directory -ErrorAction SilentlyContinue)) {
                $c2 = Join-Path $sub2.FullName 'dnplycore.dll'
                if (Test-Path -LiteralPath $c2) { return $c2 }
            }
        }
    }
    return $null
}

# Only processes that are actually OUR agents - never a generic "long-lived
# powershell" sweep, which would kill unrelated user windows.
function Get-WatcherProcs {
    $self = $PID
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
          $_.ProcessId -ne $self -and (
              $_.Name -ieq 'inertia-native.exe' -or
              ($_.Name -ieq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine -like '*inertia-smart.ps1*')
          )
      })
}

function Kill-Watchers {
    foreach ($p in Get-WatcherProcs) {
        Write-Host ("  stop agent pid {0} ({1})" -f $p.ProcessId, $p.Name)
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

if ($Status) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "not installed"; exit 0 }
    $t | Select-Object TaskName, State | Format-List
    $t.Actions | Select-Object Execute, Arguments | Format-List
    $t.Principal | Select-Object UserId, RunLevel, LogonType | Format-List
    Get-ScheduledTaskInfo -TaskName $TaskName |
        Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns | Format-List
    $eng = if ($t.Actions[0].Execute -like '*inertia-native*') { 'exe (event driven)' } else { 'ps (polling)' }
    Write-Host ("engine: {0}" -f $eng)
    $w = @(Get-WatcherProcs)
    Write-Host ("agent processes: {0}" -f $w.Count)
    foreach ($p in $w) { Write-Host ("  pid {0} ({1})" -f $p.ProcessId, $p.Name) }
    foreach ($lp in @($Log, $ExeLog)) {
        if (Test-Path -LiteralPath $lp) { Write-Host ("--- {0} tail ---" -f (Split-Path $lp -Leaf)); Get-Content -LiteralPath $lp -Tail 6 }
    }
    Write-Host "--- dll state (read-only) ---"
    $dll = Find-LdDll
    if ($dll) {
        $b = [IO.File]::ReadAllBytes($dll)
        $off = 0x5AF96
        $cur = ($b[$off..($off+3)] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
        Write-Host ("  {0}" -f $dll)
        Write-Host ("  @0x{0:X}: {1}  (83 41 2c f0 = untouched original)" -f $off, $cur)
    } else {
        Write-Host "  dnplycore.dll not found (is LDPlayer installed?)"
    }
    exit 0
}

if ($Remove) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "task unregistered" -ForegroundColor Green
    } else { Write-Host "task was not installed" -ForegroundColor Yellow }
    Kill-Watchers
    Write-Host "the in-memory byte returns to normal when LDPlayer restarts" -ForegroundColor DarkGray
    exit 0
}

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw ("elevation required - run: {0} -Script {1}" -f $Elev, (Join-Path $Here 'install-inertia-task.ps1'))
}
$useExe = ($Engine -eq 'exe') -or ($Engine -eq 'auto' -and (Test-Path -LiteralPath $Exe))
if ($Engine -eq 'exe' -and -not (Test-Path -LiteralPath $Exe)) { throw "missing $Exe (compile inertia-native.cs first)" }

if ($useExe) {
    $extra = ''
    if ($CursorLock) { $extra += ' --cursorlock' }
    if ($ClipDebug)  { $extra += ' --clipdebug' }
    $argLine = "--longpress $LongPressMs --shortdec $ShortDec --resetafter 1500 --log `"$ExeLog`"$extra"
    $action  = New-ScheduledTaskAction -Execute $Exe -Argument $argLine
    Write-Host ("engine: exe (event driven, WH_MOUSE_LL){0}" -f $(if ($CursorLock) { ' + cursor-lock watchdog' } else { '' })) -ForegroundColor Cyan
} else {
    if (-not (Test-Path -LiteralPath $Script)) { throw "missing $Script" }
    $argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -LongPressMs $LongPressMs -ShortDec $ShortDec -PollMs $PollMs -Seconds 0"
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    Write-Host "engine: ps (polling every $PollMs ms)" -ForegroundColor Cyan
}

$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -MultipleInstances IgnoreNew -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host ("task registered: {0}" -f $TaskName) -ForegroundColor Green
Write-Host ("  args: LongPressMs={0}  ShortDec=0x{1:X2}" -f $LongPressMs, $ShortDec)

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Kill-Watchers            # drop any manual watcher so the task's instance owns the byte
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8

$i = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ("  started, LastTaskResult={0}" -f $i.LastTaskResult)
$activeLog = if ($useExe) { $ExeLog } else { $Log }
if (Test-Path -LiteralPath $activeLog) {
    Write-Host ("--- {0} tail ---" -f (Split-Path $activeLog -Leaf))
    Get-Content -LiteralPath $activeLog -Tail 8
}
