#!/usr/bin/env pwsh
<#
  永久修复：把雷电"右键行走"松手后的惯性衰减改成一步归零。

  dnplycore.dll（PE32，ImageBase 0x10000000）

    VA 0x1005BB96   文件偏移 0x5AF96
      83 41 2c f0   add dword ptr [ecx + 0x2c], -0x10   ← 原始：每步 -16 → 滑步
      83 61 2c 00   and dword ptr [ecx + 0x2c], 0       ← 修复：一步归零 → 立刻停

  两条编码都是 4 字节，原地替换，不破坏后续指令。
  已在运行中的游戏里实测：改 -128 后滑步明显变短；改成清零后立刻停、行走正常。

  用法（雷电必须完全关闭）：
      .\patch-inertia-dll.ps1            # 打补丁（自动备份 + 校验 + 自检）
      .\patch-inertia-dll.ps1 -Restore   # 还原原版
      .\patch-inertia-dll.ps1 -Show      # 只看当前状态
#>
param([switch]$Restore, [switch]$Show, [string]$LdPlayerDir)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# LDPlayer is not installed in a fixed place - find dnplycore.dll unless told where.
function Find-LdDll {
    try {
        $p = Get-Process dnplayer -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.Path) {
            $c = Join-Path (Split-Path -Parent $p.Path) 'dnplycore.dll'
            if (Test-Path -LiteralPath $c) { return $c }
        }
    } catch { }
    $roots = @('C:\', 'D:\', 'E:\', 'F:\', $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($r in $roots) {
        foreach ($sub in (Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -notmatch 'ldplayer|leidian') { continue }
            $c = Join-Path $sub.FullName 'dnplycore.dll'
            if (Test-Path -LiteralPath $c) { return $c }
            foreach ($s2 in (Get-ChildItem -LiteralPath $sub.FullName -Directory -ErrorAction SilentlyContinue)) {
                $c2 = Join-Path $s2.FullName 'dnplycore.dll'
                if (Test-Path -LiteralPath $c2) { return $c2 }
            }
        }
    }
    return $null
}

$dll = if ($LdPlayerDir) { Join-Path $LdPlayerDir 'dnplycore.dll' } else { Find-LdDll }
if (-not $dll) { throw "dnplycore.dll not found - pass -LdPlayerDir '<LDPlayer folder>'" }
$bak = Join-Path $Here 'backup\dnplycore.dll.orig'

$OFFSET = 0x5AF96
$ORIG   = [byte[]]@(0x83,0x41,0x2c,0xf0)   # add dword ptr [ecx+0x2c], -0x10
$FIX    = [byte[]]@(0x83,0x61,0x2c,0x00)   # and dword ptr [ecx+0x2c], 0

function Same([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
function Hex([byte[]]$a) { ($a | ForEach-Object { '{0:x2}' -f $_ }) -join ' ' }

if (-not (Test-Path -LiteralPath $dll)) { throw "not found: $dll" }
$cur = ([IO.File]::ReadAllBytes($dll))[$OFFSET..($OFFSET + 3)]
Write-Host ("dnplycore.dll   file 0x{0:X}   current: {1}" -f $OFFSET, (Hex $cur))

if ($Show) {
    Write-Host ("state: {0}" -f $(if (Same $cur $ORIG) { 'ORIGINAL (有惯性)' } elseif (Same $cur $FIX) { 'PATCHED (惯性已修复)' } else { 'UNKNOWN' }))
    exit 0
}

$running = Get-Process dnplayer,Ld9BoxHeadless -ErrorAction SilentlyContinue
if ($running) {
    Write-Host ("雷电还在运行: " + (($running | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ')) -ForegroundColor Yellow
    Write-Host "请先完全关闭雷电再执行（或先用 livepatch.ps1 打内存补丁，不用关）。" -ForegroundColor Yellow
    exit 2
}

if ($Restore) {
    if (Same $cur $ORIG) { Write-Host "已经是原版，无需还原" -ForegroundColor Green; exit 0 }
    if (-not (Test-Path -LiteralPath $bak)) { throw "backup missing: $bak" }
    Copy-Item -LiteralPath $bak -Destination $dll -Force
    Write-Host "已从备份还原" -ForegroundColor Green
    exit 0
}

if (Same $cur $FIX) { Write-Host "已经是修复版" -ForegroundColor Green; exit 0 }
if (-not (Same $cur $ORIG)) {
    throw ("file 0x{0:X} 的字节是 {1}，既不是原版也不是修复版 —— 版本可能不同，拒绝修改" -f $OFFSET, (Hex $cur))
}

if (-not (Test-Path -LiteralPath $bak)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $bak) | Out-Null
    Copy-Item -LiteralPath $dll -Destination $bak -Force
    Write-Host "备份 -> $bak"
}

$fs = [IO.File]::Open($dll, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { [void]$fs.Seek($OFFSET, [IO.SeekOrigin]::Begin); $fs.Write($FIX, 0, 4); $fs.Flush($true) }
finally { $fs.Dispose() }

$after = ([IO.File]::ReadAllBytes($dll))[$OFFSET..($OFFSET + 3)]
Write-Host ("after: {0}" -f (Hex $after)) -ForegroundColor Yellow
if (Same $after $FIX) { Write-Host "PATCHED OK - 启动雷电即可（右键行走松手立刻停）" -ForegroundColor Green }
else { Write-Host "校验失败，正在还原" -ForegroundColor Red; Copy-Item -LiteralPath $bak -Destination $dll -Force }
