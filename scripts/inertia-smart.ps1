#!/usr/bin/env pwsh
<#
  Smart inertia control for LDPlayer's right-click-walk.

  ASCII ONLY - this script is started by powershell.exe (Windows PowerShell 5.1).

  Behaviour wanted:
      single quick right click -> keep a very long glide (inertia)
      long press + release     -> stop instantly (no glide)

  How:
      the glide lives in dnplycore.dll:
          83 41 2c f0   add dword ptr [ecx+0x2c], -0x10   = glide       (ORIGINAL)
          83 41 2c ff   add dword ptr [ecx+0x2c], -0x01   = 16x glide   (quick click)
          83 61 2c 00   and dword ptr [ecx+0x2c], 0       = instant stop (long press)

      this watcher picks which one is in memory:
          right button DOWN            -> RESTB   (press started)
          UP, held >= LongPressMs      -> ZEROB   (long press: kill the glide)
          UP, held <  LongPressMs      -> RESTB   (quick click: keep the glide)
          ResetAfterMs after release   -> RESTB   (reset for the next press)

  UPDATE SAFETY (important)
      The patch site is located by a BYTE SIGNATURE inside the on-disk
      dnplycore.dll, not by a hard-coded address.  If an LDPlayer update only
      moves the code around, this still finds it.
      Before writing, the live bytes are checked to still look like the expected
      instruction.  If they do not, the watcher REFUSES to write and says so in
      the log - it will never blindly overwrite an unknown build.

  MUST run elevated.  Log: C:\leidian\inertia-smart.log

  Usage:
      .\inertia-smart.ps1 -LogOnly             # only log button events (diagnostic)
      .\inertia-smart.ps1 -LongPressMs 400     # <=400ms counts as a "quick click"
#>
param(
    [int]$LongPressMs = 200,
    [int]$ShortDec = 0xFF,
    [int]$ResetAfterMs = 1500,
    [int]$PollMs = 4,
    [int]$Seconds = 1800,
    [string]$LogPath,
    [string]$DllPath,
    [switch]$LogOnly,
    [switch]$SelfTest,
    [switch]$CycleTest
)

$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LogPath) { $LogPath = Join-Path $Here 'inertia-smart.log' }
# the DLL path is normally discovered from the running dnplayer.exe - see Get-Site

$LOG = $LogPath
function L([string]$m) { Add-Content -LiteralPath $LOG -Value ("[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $m) -Encoding UTF8 }

function HexOf([byte[]]$a) {
    if ($null -eq $a) { return '(null)' }
    if ($a.Length -eq 0) { return '(empty)' }
    return (($a | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')
}

function HexToBytes([string]$h) {
    $c = ($h -replace '[\s,]', '')
    $n = [int]($c.Length / 2)
    $r = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i++) { $r[$i] = [convert]::ToByte($c.Substring($i * 2, 2), 16) }
    return $r
}

# ---- patch encodings -------------------------------------------------------
# RESTB = "rest" / quick-click variant: add dword ptr [ecx+0x2c], <ShortDec signed>
#   0xF0 = -16  -> original glide
#   0xFF = -1   -> 16x slower (very long)
$RESTB = [byte[]]@(0x83, 0x41, 0x2c, [byte]$ShortDec)
$ZEROB = [byte[]]@(0x83, 0x61, 0x2c, 0x00)
$PAGE = 0x1F0FFF
$VK_RB = 0x02

# Signatures are searched in the ON-DISK (unpatched) dll; Delta is the distance
# from the signature start to the 4-byte instruction.  Most specific first.
#   sig 1/2 start at file 0x5AF91 -> instruction at 0x5AF96  (delta 5)
$SIGS = @(
    @{ Hex = 'e9 f2 fc ff ff 83 41 2c f0 8b 97'; D = 5 },
    @{ Hex = 'e9 f2 fc ff ff 83 41 2c';          D = 5 },
    @{ Hex = '83 41 2c f0';                      D = 0 }
)

if (-not ('SM.N' -as [type])) {
    Add-Type -Namespace SM -Name N -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct MODULEENTRY32W {
  public uint dwSize; public uint th32ModuleID; public uint th32ProcessID; public uint GlblcntUsage;
  public uint ProccntUsage; public IntPtr modBaseAddr; public uint modBaseSize; public IntPtr hModule;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string szModule;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szExePath;
}
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateToolhelp32Snapshot(uint f, uint pid);
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Module32FirstW(IntPtr s, ref MODULEENTRY32W e);
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Module32NextW(IntPtr s, ref MODULEENTRY32W e);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool i, uint pid);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr p, IntPtr a, byte[] b, int n, out IntPtr r);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr p, IntPtr a, byte[] b, int n, out IntPtr w);
[DllImport("kernel32.dll", SetLastError=true, EntryPoint="VirtualProtectEx")]
static extern bool _VirtualProtectEx(IntPtr p, IntPtr a, UIntPtr n, uint np, out uint op);
public static bool VirtualProtectEx(IntPtr p, IntPtr a, int n, uint np, out uint op) { return _VirtualProtectEx(p, a, (UIntPtr)n, np, out op); }
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
'@
}

# ---- state -----------------------------------------------------------------
$handle = [IntPtr]::Zero
$base = 0
$RVA = 0
$disk4 = $null
$verified = $false
$procId = 0
$cacheKey = $null
$cacheSite = $null

function Close-Target {
    if ($script:handle -ne [IntPtr]::Zero) { [void][SM.N]::CloseHandle($script:handle); $script:handle = [IntPtr]::Zero }
    $script:base = 0; $script:procId = 0; $script:verified = $false
}

function Read-At([int64]$addr) {
    $buf = New-Object byte[] 4
    $got = [IntPtr]::Zero
    if (-not [SM.N]::ReadProcessMemory($script:handle, [IntPtr]$addr, $buf, 4, [ref]$got)) { return $null }
    return $buf
}

# Is this really "add/and dword ptr [ecx+0x2c], imm8"?
function Test-Instruction([byte[]]$b) {
    if ($null -eq $b -or $b.Length -lt 3) { return $false }
    if ($b[0] -ne 0x83) { return $false }
    if ($b[2] -ne 0x2C) { return $false }
    if ($b[1] -ne 0x41 -and $b[1] -ne 0x61) { return $false }
    return $true
}

# Does the LIVE memory hold one of the encodings that legitimately belongs here?
#   83 41 2c XX   add dword ptr [ecx+0x2c], imm8   -> stock build, or our RESTB
#   83 61 2c 00   and dword ptr [ecx+0x2c], 0      -> our ZEROB
# NOTE: comparing against the DISK bytes is wrong - our own ZEROB legitimately
# changes byte[1] from 0x41 to 0x61, and a strict disk compare would then
# declare the site "unknown" and freeze the byte forever.
function Test-Known([byte[]]$b) {
    if (-not (Test-Instruction $b)) { return $false }
    if ($b[1] -eq 0x41) { return $true }
    if ($b[1] -eq 0x61) { return ($b[3] -eq 0x00) }
    return $false
}

# Offline regression test: no elevation, no process, no writes.
function Invoke-SelfTest {
    $script:stFail = 0
    function Chk([string]$what, [bool]$got, [bool]$want) {
        $ok = ($got -eq $want)
        Write-Host ("  [{0}] {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $what)
        if (-not $ok) { $script:stFail++ }
    }
    Write-Host "== encodings the guard must ACCEPT =="
    Chk 'stock   83 41 2c f0' (Test-Known ([byte[]]@(0x83,0x41,0x2c,0xf0))) $true
    Chk 'RESTB   83 41 2c ff' (Test-Known ([byte[]]@(0x83,0x41,0x2c,0xff))) $true
    Chk '-128    83 41 2c 80' (Test-Known ([byte[]]@(0x83,0x41,0x2c,0x80))) $true
    Chk 'ZEROB   83 61 2c 00' (Test-Known ([byte[]]@(0x83,0x61,0x2c,0x00))) $true
    Write-Host "== garbage the guard must REJECT =="
    Chk 'and!=0  83 61 2c 05' (Test-Known ([byte[]]@(0x83,0x61,0x2c,0x05))) $false
    Chk 'offby1  f0 8b 97 a0' (Test-Known ([byte[]]@(0xf0,0x8b,0x97,0xa0))) $false
    Chk 'wrongd  83 41 2d f0' (Test-Known ([byte[]]@(0x83,0x41,0x2d,0xf0))) $false
    Chk 'nops    90 90 90 90' (Test-Known ([byte[]]@(0x90,0x90,0x90,0x90))) $false
    Chk 'zeros   00 00 00 00' (Test-Known ([byte[]]@(0x00,0x00,0x00,0x00))) $false
    Chk 'null    (null)'      (Test-Known $null) $false
    Write-Host "== signature -> RVA =="
    $site = Resolve-Site
    if ($null -eq $site) {
        Write-Host "  [FAIL] no signature matched"; $script:stFail++
    } else {
        Chk ("file 0x{0:X} == 0x5AF96" -f $site.FileOff) ($site.FileOff -eq 0x5AF96) $true
        Chk ("RVA  0x{0:X} == 0x5BB96" -f $site.Rva)     ($site.Rva     -eq 0x5BB96) $true
        Chk ("disk bytes {0}" -f (HexOf $site.Bytes))    ((HexOf $site.Bytes) -eq '83 41 2c f0') $true
    }
    Write-Host ("== {0} ==" -f $(if ($script:stFail -eq 0) { 'ALL PASS' } else { "$($script:stFail) FAILED" }))
    exit $(if ($script:stFail -eq 0) { 0 } else { 1 })
}

function Find-Pattern([byte[]]$b, [byte[]]$pat, [int]$from, [int]$to) {
    $n = $pat.Length
    if ($n -le 0) { return -1 }
    if ($to -gt $b.Length) { $to = $b.Length }
    $last = $to - $n
    $i = $from
    while ($i -ge 0 -and $i -le $last) {
        $i = [Array]::IndexOf($b, [byte]$pat[0], $i)
        if ($i -lt 0 -or $i -gt $last) { return -1 }
        $ok = $true
        for ($j = 1; $j -lt $n; $j++) { if ($b[$i + $j] -ne $pat[$j]) { $ok = $false; break } }
        if ($ok) { return $i }
        $i = $i + 1
    }
    return -1
}

# ldplayer is not installed in a fixed place - find dnplycore.dll at runtime
$script:dllWarned = $false
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

function Ensure-DllPath {
    if ($DllPath) { return $true }
    $found = Find-LdDll
    if ($found) { $script:DllPath = $found; L ("using dll " + $found); return $true }
    if (-not $script:dllWarned) { $script:dllWarned = $true; L "dnplycore.dll not found (is LDPlayer installed?)" }
    return $false
}

# Read the on-disk dll, find the patch site, map its file offset to an RVA.
function Resolve-Site {
    if (-not (Ensure-DllPath)) { return $null }
    $b = $null
    try { $b = [IO.File]::ReadAllBytes($DllPath) } catch { L ("cannot read dll: {0}" -f $_.Exception.Message); return $null }
    if ($b.Length -lt 0x1000) { L "dll too small - unexpected"; return $null }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -lt 0 -or $pe -gt ($b.Length - 0x100)) { L "bad PE header"; return $null }
    $numSec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $secOff = $pe + 24 + $optSize
    $secs = @()
    for ($i = 0; $i -lt $numSec; $i++) {
        $o = $secOff + $i * 40
        if ($o + 40 -gt $b.Length) { break }
        $secs += [pscustomobject]@{
            Name  = [Text.Encoding]::ASCII.GetString($b, $o, 8).TrimEnd([char]0)
            VA    = [BitConverter]::ToUInt32($b, $o + 12)
            RawSz = [BitConverter]::ToUInt32($b, $o + 16)
            Raw   = [BitConverter]::ToUInt32($b, $o + 20)
            Chars = [BitConverter]::ToUInt32($b, $o + 36)
        }
    }
    # only scan executable sections (avoids false hits in data)
    $exec = @($secs | Where-Object { ($_.Chars -band 0x20000000) -ne 0 -and $_.RawSz -gt 0 })
    if ($exec.Count -eq 0) { $exec = $secs }
    foreach ($s in $SIGS) {
        $pat = HexToBytes $s.Hex
        foreach ($sec in $exec) {
            $from = [int]$sec.Raw
            $to = [int]($sec.Raw + $sec.RawSz)
            $off = Find-Pattern $b $pat $from $to
            if ($off -ge 0) {
                $siteOff = $off + $s.D
                if ($siteOff + 3 -ge $b.Length) { continue }
                $d4 = $b[$siteOff..($siteOff + 3)]
                # a signature hit whose delta lands somewhere else must NOT be trusted
                if (-not (Test-Instruction $d4)) {
                    L ("sig '{0}' hit 0x{1:X} but target bytes {2} are not the expected instruction - rejected" -f $s.Hex, $siteOff, (HexOf $d4))
                    continue
                }
                foreach ($m in $secs) {
                    if ($siteOff -ge $m.Raw -and $siteOff -lt ($m.Raw + $m.RawSz)) {
                        $rva = [int]($m.VA + ($siteOff - $m.Raw))
                        return [pscustomobject]@{ Rva = $rva; FileOff = $siteOff; Section = $m.Name; Bytes = $d4; Sig = $s.Hex }
                    }
                }
            }
        }
    }
    return $null
}

# Cached per dll build (size + mtime): scanning 1 MB on every poll would be silly.
function Get-Site {
    if (-not (Ensure-DllPath)) { $script:cacheSite = $null; return $null }
    $fi = Get-Item -LiteralPath $DllPath -ErrorAction SilentlyContinue
    if (-not $fi) { L "dnplycore.dll missing on disk"; return $null }
    $key = '{0}:{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
    if ($key -eq $script:cacheKey) { return $script:cacheSite }
    $script:cacheKey = $key
    $site = Resolve-Site
    if ($site) {
        L ("signature found: file 0x{0:X} -> RVA 0x{1:X}  ({2})  disk={3}" -f $site.FileOff, $site.Rva, $site.Section, (HexOf $site.Bytes))
    } else {
        L "WARNING: patch site NOT found in this dnplycore.dll build - running READ-ONLY (no writes)"
    }
    $script:cacheSite = $site
    return $site
}

function Set-Bytes([byte[]]$b, [string]$who) {
    if ($script:handle -eq [IntPtr]::Zero -or $script:base -eq 0 -or $script:RVA -eq 0) { L "  ($who) no target"; return }
    $live = Read-At ([int64]$script:base + $script:RVA)
    if (-not (Test-Known $live)) {
        if ($script:verified) {
            $script:verified = $false
            L ("  ($who) ABORT - live bytes {0} no longer look like the patch site; switching to READ-ONLY" -f (HexOf $live))
        }
        return
    }
    if (-not $script:verified) { $script:verified = $true; L ("  ($who) site re-verified") }
    $w = [IntPtr]::Zero
    $ok = [SM.N]::WriteProcessMemory($script:handle, [IntPtr]([int64]$script:base + $script:RVA), $b, 4, [ref]$w)
    if (-not $ok) { L ("  ($who) WRITE FAILED err={0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    else { L ("  ($who) wrote " + (HexOf $b)) }
}

# Locate + verify the site for the current target; on success write the init byte.
function Confirm-Site {
    if ($script:handle -eq [IntPtr]::Zero -or $script:base -eq 0) { return }
    if ($script:verified) { return }
    $site = Get-Site
    if (-not $site) { $script:disk4 = $null; return }
    if ($script:RVA -ne $site.Rva) {
        $script:RVA = $site.Rva
        $script:disk4 = $site.Bytes
        L ("using RVA 0x{0:X}" -f $script:RVA)
    }
    $live = Read-At ([int64]$script:base + $script:RVA)
    $ok = Test-Known $live
    L ("site check RVA 0x{0:X}: live={1} disk={2} -> verified={3}" -f $script:RVA, (HexOf $live), (HexOf $script:disk4), $ok)
    if (-not $ok) {
        L "REFUSING to write: bytes do not match a known build. No modification was made."
        return
    }
    if ($LogOnly) { $script:verified = $true; return }
    $old = [uint32]0
    [void][SM.N]::VirtualProtectEx($script:handle, [IntPtr]([int64]$script:base + $script:RVA), 4, 0x40, [ref]$old)
    $script:verified = $true
    Set-Bytes $RESTB 'init'
    $script:state = 'ORIG'

    # End-to-end regression test for the bug where a ZERO write made the next
    # Set-Bytes abort (live 83 61 2c 00 compared against disk 83 41 2c f0).
    # Leaves the byte at RESTB, which is the correct resting state.
    if ($CycleTest) {
        Set-Bytes $ZEROB 'cycle-1-zero'
        $afterZero = HexOf (Read-At ([int64]$script:base + $script:RVA))
        Set-Bytes $RESTB 'cycle-2-rest'
        $afterRest = HexOf (Read-At ([int64]$script:base + $script:RVA))
        $pass = ($afterZero -eq '83 61 2c 00') -and ($afterRest -eq (HexOf $RESTB)) -and $script:verified
        L ("CYCLE TEST: after ZEROB={0}  after RESTB={1}  verified={2} -> {3}" -f $afterZero, $afterRest, $script:verified, $(if ($pass) { 'PASS' } else { 'FAIL' }))
        Write-Host ("CYCLE TEST: ZEROB->{0}  RESTB->{1}  verified={2} -> {3}" -f $afterZero, $afterRest, $script:verified, $(if ($pass) { 'PASS' } else { 'FAIL' }))
        exit $(if ($pass) { 0 } else { 1 })
    }
}

if ($SelfTest) { Invoke-SelfTest }

Write-Host "starting smart inertia watcher (elevated)" -ForegroundColor Cyan
if (Test-Path -LiteralPath $LOG) { Remove-Item -LiteralPath $LOG -Force -ErrorAction SilentlyContinue }
L ("start  LongPressMs=$LongPressMs ShortDec=0x{0:X2} ResetAfterMs=$ResetAfterMs PollMs=$PollMs LogOnly={1}" -f $ShortDec, [bool]$LogOnly)
L ("RESTB=" + (HexOf $RESTB) + "   ZEROB=" + (HexOf $ZEROB))

$wasDown = $false
$downAt = [datetime]::MinValue
$lastUp = [datetime]::MinValue
$state = 'ORIG'
$lastRefresh = [datetime]::MinValue
$deadline = if ($Seconds -le 0) { [datetime]::MaxValue } else { (Get-Date).AddSeconds($Seconds) }
$lastLogCheck = Get-Date

while ((Get-Date) -lt $deadline) {
    $now = Get-Date

    # keep the log bounded so a long-running watcher cannot fill the disk
    if (($now - $lastLogCheck).TotalSeconds -gt 60) {
        $lastLogCheck = $now
        $fi = Get-Item -LiteralPath $LOG -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 2MB) { Remove-Item -LiteralPath $LOG -ErrorAction SilentlyContinue; L "log rotated" }
    }

    # (re)acquire the target every 2 s
    if (($now - $lastRefresh).TotalMilliseconds -gt 2000) {
        $lastRefresh = $now
        $proc = Get-Process dnplayer -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) {
            if ($procId -ne 0) { L "dnplayer not running"; Close-Target }
        }
        elseif ($proc.Id -ne $procId) {
            Close-Target
            $procId = $proc.Id
            $snap = [SM.N]::CreateToolhelp32Snapshot(0x18, [uint32]$procId)
            $e = New-Object SM.N+MODULEENTRY32W
            $e.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'SM.N+MODULEENTRY32W')
            $ok = [SM.N]::Module32FirstW($snap, [ref]$e)
            while ($ok) { if ($e.szModule -ieq 'dnplycore.dll') { $base = [int64]$e.modBaseAddr; break }; $ok = [SM.N]::Module32NextW($snap, [ref]$e) }
            [void][SM.N]::CloseHandle($snap)
            if ($base) {
                $handle = [SM.N]::OpenProcess($PAGE, $false, [uint32]$procId)
                L ("target acquired pid={0} base=0x{1:X} handle={2}" -f $procId, $base, [int64]$handle)
            } else { L "dnplycore.dll not found in dnplayer.exe yet" }
        }
        Confirm-Site
    }

    # button edges
    $down = (([SM.N]::GetAsyncKeyState($VK_RB)) -band 0x8000) -ne 0
    if ($down -and -not $wasDown) {
        $downAt = $now
        L "RBUTTON DOWN"
        if (-not $LogOnly) { Set-Bytes $RESTB 'on-down'; $state = 'ORIG' }
    }
    elseif (-not $down -and $wasDown) {
        $held = ($now - $downAt).TotalMilliseconds
        $lastUp = $now
        $long = $held -ge $LongPressMs
        L ("RBUTTON UP   held={0:N0}ms  -> {1}" -f $held, $(if ($long) { 'ZERO (kill glide)' } else { 'REST (keep glide)' }))
        if (-not $LogOnly) {
            if ($long) { Set-Bytes $ZEROB 'on-up-long'; $state = 'ZERO' }
            else       { Set-Bytes $RESTB 'on-up-short'; $state = 'ORIG' }
        }
    }
    $wasDown = $down

    # reset after the movement has settled
    if (-not $LogOnly -and $state -eq 'ZERO' -and -not $down -and
        ($now - $lastUp).TotalMilliseconds -gt $ResetAfterMs) {
        Set-Bytes $RESTB 'reset'
        $state = 'ORIG'
    }

    Start-Sleep -Milliseconds $PollMs
}
