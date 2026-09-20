#!/usr/bin/env pwsh
<#
  Live, in-memory patch for LDPlayer's right-click-walk inertia.
  MUST run elevated (dnplayer.exe runs at High integrity).

  Target: dnplycore.dll + 0x5BB96   (all three forms are 4 bytes, in-place swap)

      83 41 2c f0   add dword ptr [ecx+0x2c], -0x10   original  (-16/step)
      83 41 2c 80   add dword ptr [ecx+0x2c], -0x80   probe     (-128/step, 8x faster)  <- CONFIRMED shorter
      83 61 2c 00   and dword ptr [ecx+0x2c], 0       zero      (cleared in one step)

  Usage:
      .\livepatch.ps1 -Show             # base + current bytes
      .\livepatch.ps1 -Set 83612c00    # write a 4-byte variant
      .\livepatch.ps1 -Orig             # back to original
#>
param([switch]$Show, [switch]$Orig, [string]$Set)

$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LOG = Join-Path $Here 'livepatch.log'
function L([string]$m) { Add-Content -LiteralPath $LOG -Value ("[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $m) -Encoding UTF8 }
Remove-Item -LiteralPath $LOG -ErrorAction SilentlyContinue
L "start Show=$Show Orig=$Orig Set=$Set"

$RVA   = 0x5BB96
$PAGE  = 0x1F0FFF
$ORIGB = '83412cf0'
$KNOWN = @('83412cf0','83412c80','83412cff','83612c00')   # only patch if it is one of ours

try {
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    L ("elevated = {0}" -f $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

    if (-not ('LP.N' -as [type])) {
        Add-Type -Namespace LP -Name N -MemberDefinition @'
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
public static bool VirtualProtectEx(IntPtr p, IntPtr a, int n, uint np, out uint op) {
    return _VirtualProtectEx(p, a, (UIntPtr)n, np, out op);
}
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
'@
    }

    $proc = Get-Process dnplayer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { L "dnplayer.exe not running"; exit 2 }

    $snap = [LP.N]::CreateToolhelp32Snapshot(0x18, [uint32]$proc.Id)
    $e = New-Object LP.N+MODULEENTRY32W
    $e.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'LP.N+MODULEENTRY32W')
    $base = $null
    $ok = [LP.N]::Module32FirstW($snap, [ref]$e)
    while ($ok) { if ($e.szModule -ieq 'dnplycore.dll') { $base = [int64]$e.modBaseAddr; break }; $ok = [LP.N]::Module32NextW($snap, [ref]$e) }
    [void][LP.N]::CloseHandle($snap)
    if (-not $base) {
        if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            L "cannot read dnplayer's module list: THIS SESSION IS NOT ELEVATED."
            L "dnplayer.exe runs at High integrity - re-run through elev.ps1."
        } else {
            L "dnplycore.dll not found in dnplayer.exe (unexpected build?)"
        }
        exit 5
    }

    $h = [LP.N]::OpenProcess($PAGE, $false, [uint32]$proc.Id)
    if ([int64]$h -eq 0) { L ("OpenProcess failed err={0} (must be elevated)" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 6 }
    L ("pid={0}  dnplycore base=0x{1:X}  addr=0x{2:X}" -f $proc.Id, $base, ($base + $RVA))

    try {
        $got = [IntPtr]::Zero
        $cur = New-Object byte[] 4
        if (-not [LP.N]::ReadProcessMemory($h, [IntPtr]($base + $RVA), $cur, 4, [ref]$got)) { L "read failed"; exit 7 }
        $curHex = ($cur | ForEach-Object { '{0:x2}' -f $_ }) -join ''
        L ("current = {0}" -f (($cur | ForEach-Object { '{0:x2}' -f $_ }) -join ' '))

        if ($Show -or (-not $Orig -and -not $Set)) { L "show only"; exit 0 }

        $target = if ($Orig) { $ORIGB } elseif ($Set) { ($Set -replace '[\s,]','').ToLower() } else { $null }
        if (-not $target -or $target.Length -ne 8 -or $target -notmatch '^[0-9a-f]{8}$') { L "bad -Set value"; exit 8 }

        if ($KNOWN -notcontains $curHex) {
            L ("REFUSING: current bytes {$0} are not a known variant - wrong build?" -f $curHex); exit 9
        }
        if ($curHex -eq '83412cff') {
            L "note: 83412cff is the resident watcher's value (scheduled task LDPlayer-InertiaSmart)."
            L "note: the watcher rewrites it within ~1.5s, so this one-shot write will NOT stick. Stop the task first."
        }
        if ($target -eq $curHex) { L "already in the requested state"; exit 0 }

        $old = [uint32]0
        [void][LP.N]::VirtualProtectEx($h, [IntPtr]($base + $RVA), 4, 0x40, [ref]$old)
        $w = [IntPtr]::Zero
        $nb = [byte[]]@([convert]::ToByte($target.Substring(0,2),16),[convert]::ToByte($target.Substring(2,2),16),[convert]::ToByte($target.Substring(4,2),16),[convert]::ToByte($target.Substring(6,2),16))
        $wr = [LP.N]::WriteProcessMemory($h, [IntPtr]($base + $RVA), $nb, 4, [ref]$w)
        [void][LP.N]::VirtualProtectEx($h, [IntPtr]($base + $RVA), 4, $old, [ref]$old)   # restore page protection

        $chk = New-Object byte[] 4
        [void][LP.N]::ReadProcessMemory($h, [IntPtr]($base + $RVA), $chk, 4, [ref]$got)
        $chkHex = ($chk | ForEach-Object { '{0:x2}' -f $_ }) -join ''
        L ("write ok={0}  after = {1}" -f $wr, (($chk | ForEach-Object { '{0:x2}' -f $_ }) -join ' '))
        L ("RESULT: {0}" -f $(if ($chkHex -eq $target) { 'OK' } else { 'write did not stick' }))
        exit 0
    } finally { [void][LP.N]::CloseHandle($h) }
}
catch { L ("EXCEPTION: {0} @ {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage); exit 9 }
