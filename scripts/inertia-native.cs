// inertia-native.cs - LDPlayer right-click-walk "smart inertia" agent.
//
// ASCII ONLY.  Compiled with the .NET Framework csc (C# 5) - no VS needed:
//   csc.exe /nologo /target:exe /optimize+ /out:inertia-native.exe inertia-native.cs
//
// Why native: no PowerShell, no Add-Type/csc compile at every start, no 4ms poll.
// Input is read from a WH_MOUSE_LL hook, so it is EVENT DRIVEN - near zero CPU,
// and the byte is written BEFORE LDPlayer processes the button event.
//
// Behaviour:
//   quick right click  -> REST encoding (very long glide / inertia kept)
//   long press release -> ZERO encoding (glide killed instantly)
//
// Patch site is located by BYTE SIGNATURE in the on-disk dnplycore.dll, never a
// hard-coded address, and every write is guarded: if the live bytes do not look
// like a known encoding the agent refuses to write instead of corrupting an
// unknown LDPlayer build.
//
// Usage:
//   inertia-native.exe                        run the agent
//   inertia-native.exe --longpress 200 --shortdec 255 --resetafter 1500 --log <path>
//   inertia-native.exe --selftest             offline guard + signature tests (no writes)
//   inertia-native.exe --cycle                live ZERO->REST round trip (needs elevation)
//   inertia-native.exe --logonly              observe only, never write
//   inertia-native.exe --seconds 20           exit after N seconds (testing)

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class InertiaNative
{
    const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
    const uint PAGE_EXECUTE_READWRITE = 0x40;
    const int WH_MOUSE_LL = 14;
    const int WM_RBUTTONDOWN = 0x0204;
    const int WM_RBUTTONUP = 0x0205;
    const uint TH32CS_SNAPMODULE = 0x00000008;
    const uint TH32CS_SNAPMODULE32 = 0x00000010;
    const uint IMAGE_SCN_MEM_EXECUTE = 0x20000000;

    // ---------------- Win32 ----------------
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MODULEENTRY32W
    {
        public uint dwSize; public uint th32ModuleID; public uint th32ProcessID; public uint GlblcntUsage;
        public uint ProccntUsage; public IntPtr modBaseAddr; public uint modBaseSize; public IntPtr hModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExePath;
    }

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int left; public int top; public int right; public int bottom; }

    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int nMaxCount);
    [DllImport("user32.dll")]
    static extern bool GetClipCursor(out RECT r);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")]
    static extern bool ClipCursorRect(ref RECT r);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")]
    static extern bool ClipCursorNull(IntPtr p);
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

    [DllImport("kernel32.dll")]
    static extern uint GetTickCount();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool Module32FirstW(IntPtr hSnapshot, ref MODULEENTRY32W lpme);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool Module32NextW(IntPtr hSnapshot, ref MODULEENTRY32W lpme);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out IntPtr lpNumberOfBytesRead);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out IntPtr lpNumberOfBytesWritten);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress, IntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    // ---------------- state ----------------
    // Paths are derived at runtime - nothing about the LDPlayer install is
    // hard-coded, so a reinstall to another drive/folder still works.
    static string gLogPath = Path.Combine(ExeDir(), "inertia-native.log");
    static string gDllPath = "";            // resolved by GuessDllPath()
    static int gLongPress = 200;
    static int gShortDec = 0xFF;
    static int gResetAfter = 1500;
    static int gSeconds = 0;
    static bool gLogOnly = false;
    static bool gVerbose = false;
    static bool gStop = false;
    static Timer gExitTimer = null;                     // rooted, see Main
    static bool gProbe = false;
    static int gProbeCount = 0;

    // ---- cursor-lock watchdog (LDPlayer F11 fullscreen + F8 mouse lock) ----
    // LDPlayer confines the cursor with the DESKTOP-WIDE ClipCursor().  That clip
    // is lost as soon as you Alt+Tab away and click another app, but LDPlayer
    // still believes it is locked, so it never re-applies it - you have to click
    // outside the container to wake it up again.
    // The watchdog remembers LDPlayer's own clip rect while it is foreground and
    // re-applies that exact rect the moment the container becomes foreground again.
    static bool gCursorLock = false;
    static bool gClipDebug = false;
    static bool gFgWatch = false;                       // log every foreground change
    static int gLastFgWatchPid = -1;

    // ---- hook liveness -------------------------------------------------------
    // Windows SILENTLY removes a low-level hook whose callback exceeds
    // LowLevelHooksTimeout (default 300ms).  When that happens the agent keeps
    // running and keeps logging, but never sees another mouse event - the byte
    // stays frozen at whatever it was last set to, so the two-tier behaviour
    // dies silently.  That is exactly what happened: stalls of 390/407/4500ms,
    // then no events for over an hour, with the byte stuck at REST.
    static IntPtr gHook = IntPtr.Zero;
    // int (not DateTime) so the hook thread's write is atomic and costs almost
    // nothing - this runs on every single mouse event, moves included.
    static volatile int gLastHookEventTick = 0;
    static POINT gLastCursorPos;
    static bool gHaveLastCursorPos = false;
    static DateTime gLastReinstall = DateTime.MinValue;
    static int gReinstallCount = 0;
    static bool gLastFgWasDn = false;
    static bool gWasLocked = false;
    static bool gHaveSavedClip = false;
    static RECT gSavedClip;
    static int gDnPidCache = 0;
    static DateTime gDnPidAt = DateTime.MinValue;
    static RECT gLastLoggedClip;
    static int gLastLoggedFgPid = -1;
    static int gReapplyCount = 0;

    static byte[] gRest;      // quick-click encoding
    static byte[] gZero;      // long-press encoding
    static byte[] gOrig;      // stock encoding - used as the safe resting state
    static int gRva = 0;
    static byte[] gDisk4 = null;
    static bool gVerified = false;
    static IntPtr gHandle = IntPtr.Zero;
    static long gBase = 0;
    static int gPid = 0;
    static int gResolveKey = 0;

    static volatile bool gDown = false;
    static DateTime gDownAt = DateTime.MinValue;
    static DateTime gUpAt = DateTime.MinValue;
    static volatile bool gNeedReset = false;

    static readonly object gLogLock = new object();
    static readonly object gMemLock = new object();
    static string gResultPath = null;
    static readonly StringBuilder gReport = new StringBuilder();

    // winexe has no console, so test output also goes to a report buffer/file.
    static void Out(string s)
    {
        try { Console.WriteLine(s); } catch { }
        gReport.AppendLine(s);
    }

    static void WriteReport()
    {
        if (gResultPath == null) return;
        try { File.WriteAllText(gResultPath, gReport.ToString(), Encoding.UTF8); } catch { }
    }

    // Signatures are searched in the ON-DISK dll.  Delta = distance from the
    // signature start to the 4-byte instruction.  Most specific first.
    static readonly string[] SIGS = { "e9f2fcffff83412cf08b97", "e9f2fcffff83412c", "83412cf0" };
    static readonly int[] SIGDELTA = { 5, 5, 0 };

    // ---------------- logging ----------------
    // The mouse hook runs on the SYSTEM INPUT CRITICAL PATH.  Anything slow in
    // the callback (disk I/O above all) delays or drops input for every app, and
    // past LowLevelHooksTimeout (default 300ms) Windows silently removes the hook.
    // So the hook path only ever ENQUEUES; the housekeeping thread does the I/O.
    static readonly ConcurrentQueue<string> gLogQueue = new ConcurrentQueue<string>();

    static void LogAsync(string m)
    {
        gLogQueue.Enqueue(string.Format("[{0:HH:mm:ss.fff}] {1}", DateTime.Now, m));
    }

    static void DrainLog()
    {
        if (gLogQueue.IsEmpty) return;
        StringBuilder sb = new StringBuilder();
        string line;
        while (gLogQueue.TryDequeue(out line)) sb.AppendLine(line);
        string text = sb.ToString();
        try { Console.Write(text); } catch { }
        try
        {
            lock (gLogLock) { File.AppendAllText(gLogPath, text, Encoding.UTF8); }
        }
        catch { }
    }

    static void Log(string m)
    {
        string line = string.Format("[{0:HH:mm:ss.fff}] {1}", DateTime.Now, m);
        // stdout is optional: the Task Scheduler gives a winexe no console at all,
        // and an unguarded Console.WriteLine can throw there.
        try { Console.WriteLine(line); } catch { }
        try
        {
            lock (gLogLock) { File.AppendAllText(gLogPath, line + "\r\n", Encoding.UTF8); }
        }
        catch { }
    }

    static string Hex(byte[] b)
    {
        if (b == null) return "(null)";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < b.Length; i++) { if (i > 0) sb.Append(' '); sb.Append(b[i].ToString("x2")); }
        return sb.ToString();
    }

    static byte[] FromHex(string h)
    {
        h = h.Replace(" ", "").Replace(",", "");
        byte[] r = new byte[h.Length / 2];
        for (int i = 0; i < r.Length; i++) r[i] = Convert.ToByte(h.Substring(i * 2, 2), 16);
        return r;
    }

    // ---------------- guard logic ----------------
    // "add/and dword ptr [ecx+0x2c], imm8"
    static bool TestInstruction(byte[] b)
    {
        if (b == null || b.Length < 3) return false;
        if (b[0] != 0x83) return false;
        if (b[2] != 0x2C) return false;
        if (b[1] != 0x41 && b[1] != 0x61) return false;
        return true;
    }

    // One of the encodings that legitimately belongs at this site.
    // NOTE: never compare against the DISK bytes - our own ZERO write changes
    // byte[1] 0x41 -> 0x61, and a strict disk compare would then declare the
    // site unknown and freeze the byte forever (that was a real bug).
    static bool TestKnown(byte[] b)
    {
        if (!TestInstruction(b)) return false;
        if (b.Length < 4) return false;
        if (b[1] == 0x41) return true;              // add dword [ecx+0x2c], imm8
        if (b[1] == 0x61) return b[3] == 0x00;      // and dword [ecx+0x2c], 0
        return false;
    }

    static int FindPattern(byte[] hay, string hex, int from, int to)
    {
        byte[] pat = FromHex(hex);
        int last = to - pat.Length;
        if (last > hay.Length - pat.Length) last = hay.Length - pat.Length;
        for (int i = from; i <= last; i++)
        {
            if (hay[i] != pat[0]) continue;
            bool ok = true;
            for (int j = 1; j < pat.Length; j++) { if (hay[i + j] != pat[j]) { ok = false; break; } }
            if (ok) return i;
        }
        return -1;
    }

    class Section { public string Name; public uint VA, VSize, RawSize, Raw, Chars; }

    static bool ResolveSite()
    {
        byte[] b;
        try { b = File.ReadAllBytes(gDllPath); }
        catch (Exception e) { Log("cannot read dll: " + e.Message); return false; }
        if (b.Length < 0x1000) { Log("dll too small - unexpected"); return false; }

        int pe = BitConverter.ToInt32(b, 0x3C);
        int numSec = BitConverter.ToUInt16(b, pe + 6);
        int optSize = BitConverter.ToUInt16(b, pe + 20);
        int secOff = pe + 24 + optSize;

        List<Section> secs = new List<Section>();
        for (int i = 0; i < numSec; i++)
        {
            int o = secOff + i * 40;
            if (o + 40 > b.Length) break;
            Section s = new Section();
            s.Name = Encoding.ASCII.GetString(b, o, 8).TrimEnd('\0');
            s.VSize = BitConverter.ToUInt32(b, o + 8);
            s.VA = BitConverter.ToUInt32(b, o + 12);
            s.RawSize = BitConverter.ToUInt32(b, o + 16);
            s.Raw = BitConverter.ToUInt32(b, o + 20);
            s.Chars = BitConverter.ToUInt32(b, o + 36);
            secs.Add(s);
        }

        List<Section> exec = new List<Section>();
        foreach (Section s in secs)
            if ((s.Chars & IMAGE_SCN_MEM_EXECUTE) != 0 && s.RawSize > 0) exec.Add(s);
        if (exec.Count == 0) exec = secs;

        for (int k = 0; k < SIGS.Length; k++)
        {
            foreach (Section sec in exec)
            {
                int hit = FindPattern(b, SIGS[k], (int)sec.Raw, (int)(sec.Raw + sec.RawSize));
                if (hit < 0) continue;
                int siteOff = hit + SIGDELTA[k];
                if (siteOff + 4 > b.Length) continue;
                byte[] d4 = new byte[4];
                Array.Copy(b, siteOff, d4, 0, 4);
                if (!TestInstruction(d4))
                {
                    Log(string.Format("sig '{0}' hit 0x{1:X} but target bytes {2} are not the expected instruction - rejected", SIGS[k], siteOff, Hex(d4)));
                    continue;
                }
                foreach (Section m in secs)
                {
                    if (siteOff >= m.Raw && siteOff < (m.Raw + m.RawSize))
                    {
                        gRva = (int)(m.VA + (siteOff - m.Raw));
                        gDisk4 = d4;
                        Log(string.Format("signature found: file 0x{0:X} -> RVA 0x{1:X}  ({2})  disk={3}", siteOff, gRva, m.Name, Hex(d4)));
                        return true;
                    }
                }
            }
        }
        Log("WARNING: patch site NOT found in this dnplycore.dll build - running READ-ONLY (no writes)");
        return false;
    }

    // The install directory is not hard-coded: find dnplycore.dll from the running
    // dnplayer.exe, or failing that scan the usual install locations.  Handles a
    // reinstall/move/upgrade to a different path.
    static string ExeDir()
    {
        try
        {
            string loc = System.Reflection.Assembly.GetExecutingAssembly().Location;
            if (!string.IsNullOrEmpty(loc)) return Path.GetDirectoryName(loc);
        }
        catch { }
        return Directory.GetCurrentDirectory();
    }

    static string GuessDllPath()
    {
        // 1) wherever the running dnplayer.exe lives (needs elevation)
        try
        {
            Process[] ps = Process.GetProcessesByName("dnplayer");
            if (ps.Length > 0)
            {
                string exe = ps[0].MainModule.FileName;
                string dir = (exe == null) ? null : Path.GetDirectoryName(exe);
                if (dir != null)
                {
                    string c = Path.Combine(dir, "dnplycore.dll");
                    if (File.Exists(c)) return c;
                }
            }
        }
        catch { }

        // 2) scan the usual roots, up to two levels deep, for an LDPlayer-ish folder
        List<string> roots = new List<string>();
        foreach (string d in new string[] { "C", "D", "E", "F", "G" }) roots.Add(d + @":\");
        roots.Add(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        roots.Add(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86));
        foreach (string root in roots)
        {
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) continue;
            string[] lvl1;
            try { lvl1 = Directory.GetDirectories(root); } catch { continue; }
            foreach (string sub in lvl1)
            {
                string name = Path.GetFileName(sub).ToLowerInvariant();
                if (!name.Contains("ldplayer") && !name.Contains("leidian")) continue;
                string c = Path.Combine(sub, "dnplycore.dll");
                if (File.Exists(c)) return c;
                string[] lvl2;
                try { lvl2 = Directory.GetDirectories(sub); } catch { continue; }
                foreach (string sub2 in lvl2)
                {
                    string c2 = Path.Combine(sub2, "dnplycore.dll");
                    if (File.Exists(c2)) return c2;
                }
            }
        }
        return null;
    }

    // cached per dll build (size + mtime)
    static bool GetSite()
    {
        if (gRva != 0 && gDisk4 != null) return true;
        if (!File.Exists(gDllPath))
        {
            string alt = GuessDllPath();
            if (alt != null)
            {
                if (gDllPath.Length == 0) Log("dnplycore.dll auto-discovered: " + alt);
                else Log("dnplycore.dll not at " + gDllPath + " - using " + alt);
                gDllPath = alt;
            }
        }
        if (!File.Exists(gDllPath)) { NoteTarget("dnplycore.dll missing on disk"); return false; }
        FileInfo fi = new FileInfo(gDllPath);
        int key = (int)(fi.Length * 31 + fi.LastWriteTimeUtc.Ticks);
        if (key == gResolveKey && gRva != 0) return true;
        gResolveKey = key;
        return ResolveSite();
    }

    static byte[] Read4(long addr)
    {
        byte[] buf = new byte[4];
        IntPtr got;
        if (!ReadProcessMemory(gHandle, (IntPtr)addr, buf, 4, out got)) return null;
        return buf;
    }

    static void CloseTarget()
    {
        if (gHandle != IntPtr.Zero) { CloseHandle(gHandle); gHandle = IntPtr.Zero; }
        gBase = 0; gPid = 0; gVerified = false;
    }

    static string gLastNoTarget = null;

    // log a "still not ready" condition once per state change, not every tick
    static void NoteTarget(string m)
    {
        if (m == gLastNoTarget) return;
        gLastNoTarget = m;
        Log(m);
    }

    static void EnsureTarget()
    {
        if (gHandle != IntPtr.Zero)
        {
            try { Process p = Process.GetProcessById(gPid); if (!p.HasExited) return; }
            catch { }
            Log("dnplayer gone");
            CloseTarget();
            return;
        }
        Process[] ps = Process.GetProcessesByName("dnplayer");
        if (ps.Length == 0) { if (gPid != 0) NoteTarget("dnplayer not running"); return; }
        int pid = ps[0].Id;
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, (uint)pid);
        MODULEENTRY32W e = new MODULEENTRY32W();
        e.dwSize = (uint)Marshal.SizeOf(typeof(MODULEENTRY32W));
        long found = 0;
        bool ok = Module32FirstW(snap, ref e);
        while (ok)
        {
            if (string.Compare(e.szModule, "dnplycore.dll", true) == 0) { found = e.modBaseAddr.ToInt64(); break; }
            ok = Module32NextW(snap, ref e);
        }
        CloseHandle(snap);
        if (found == 0) { NoteTarget("dnplycore.dll not found in dnplayer.exe yet"); return; }
        IntPtr h = OpenProcess(PROCESS_ALL_ACCESS, false, (uint)pid);
        if (h == IntPtr.Zero) { Log(string.Format("OpenProcess failed err={0} (must run elevated)", Marshal.GetLastWin32Error())); return; }
        gHandle = h; gBase = found; gPid = pid; gVerified = false;
        gLastNoTarget = null;
        Log(string.Format("target acquired pid={0} base=0x{1:X} handle={2}", pid, found, h.ToInt64()));
    }

    static bool ConfirmSite()
    {
        if (gHandle == IntPtr.Zero || gBase == 0) return false;
        if (!GetSite()) return false;
        byte[] live = Read4(gBase + gRva);
        bool ok = TestKnown(live);
        Log(string.Format("site check RVA 0x{0:X}: live={1} disk={2} -> verified={3}", gRva, Hex(live), Hex(gDisk4), ok));
        if (!ok)
        {
            gVerified = false;
            Log("REFUSING to write: bytes do not match a known build. No modification was made.");
            return false;
        }
        uint old;
        VirtualProtectEx(gHandle, (IntPtr)(gBase + gRva), (IntPtr)4, PAGE_EXECUTE_READWRITE, out old);
        gVerified = true;
        if (!gLogOnly) WriteVariant(gRest, "init");
        return true;
    }

    // Called from the mouse hook - must never do I/O, so every message is queued.
    static void WriteVariant(byte[] b, string who)
    {
        lock (gMemLock)
        {
            if (gHandle == IntPtr.Zero || gBase == 0 || gRva == 0) { LogAsync("  (" + who + ") no target"); return; }
            if (!gVerified)
            {
                byte[] live = Read4(gBase + gRva);
                if (!TestKnown(live)) { LogAsync("  (" + who + ") SKIPPED - site not verified"); return; }
                gVerified = true;
                LogAsync("  (" + who + ") site re-verified");
            }
            IntPtr written;
            bool ok = WriteProcessMemory(gHandle, (IntPtr)(gBase + gRva), b, 4, out written);
            if (!ok) LogAsync(string.Format("  ({0}) WRITE FAILED err={1}", who, Marshal.GetLastWin32Error()));
            else LogAsync(string.Format("  ({0}) wrote {1}", who, Hex(b)));
        }
    }

    // ---------------- hook ----------------
    static HookProc gHookProc;   // MUST stay referenced or the GC eats it

    static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        long t0 = Stopwatch.GetTimestamp();
        gLastHookEventTick = Environment.TickCount;
        if (nCode < 0)
        {
            // documented: pass straight through, never inspect
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }
        try
        {
            int msg = wParam.ToInt32();
            if (gProbe)
            {
                // Prove the hook is live without touching any button state:
                // log whatever comes through (mouse moves included) and bail out.
                gProbeCount++;
                LogAsync(string.Format("PROBE event #{0} msg=0x{1:X4}", gProbeCount, msg));
                if (gProbeCount >= 6) { gStop = true; PostQuit(); }
            }
            else if (msg == WM_RBUTTONDOWN)
            {
                gDown = true; gDownAt = DateTime.UtcNow; gNeedReset = false;
                if (!gLogOnly) WriteVariant(gRest, "on-down");
                if (gVerbose) LogAsync("RBUTTON DOWN");
                NoteLatency(lParam, "down");
            }
            else if (msg == WM_RBUTTONUP)
            {
                double held = (DateTime.UtcNow - gDownAt).TotalMilliseconds;
                gDown = false; gUpAt = DateTime.UtcNow;
                bool isLong = held >= gLongPress;
                if (!gLogOnly)
                {
                    if (isLong) { WriteVariant(gZero, "on-up-long"); gNeedReset = true; }
                    else { WriteVariant(gRest, "on-up-short"); gNeedReset = false; }
                }
                LogAsync(string.Format("RBUTTON UP   held={0:N0}ms  -> {1}", held, isLong ? "ZERO (kill glide)" : "REST (keep glide)"));
                NoteLatency(lParam, "up");
            }
        }
        catch { }

        // Anything slow here delays input for EVERY app and can get the hook
        // silently dropped (LowLevelHooksTimeout, default 300ms).  Shout about it.
        double ms = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
        if (ms > 50) LogAsync(string.Format("SLOW hook callback: {0:N1}ms (input stalls; Windows drops hooks past ~300ms)", ms));

        CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);

        // ALWAYS return 0.  For a low-level hook a NON-ZERO return value tells
        // Windows to swallow the event - the target window never sees it.  Our
        // old code forwarded whatever CallNextHookEx returned, so a non-zero
        // value from any other hook in the chain would have eaten mouse input
        // outright ("clicks reach the hook but never reach the game").
        return IntPtr.Zero;
    }

    static void MaybeReset()
    {
        if (!gNeedReset || gDown) return;
        if ((DateTime.UtcNow - gUpAt).TotalMilliseconds < gResetAfter) return;
        WriteVariant(gRest, "reset");
        gNeedReset = false;
    }

    // Did Windows hand us this event promptly?  MSLLHOOKSTRUCT.time sits at
    // offset 16 (POINT pt = 8, mouseData = 4, flags = 4) and holding the tick at
    // which the event happened; a big gap means OUR thread was blocked, which
    // stalls input for every app AND eventually gets the hook dropped.
    // Read it with Marshal.ReadInt32 so the callback allocates nothing.
    static void NoteLatency(IntPtr lParam, string what)
    {
        try
        {
            uint evtTime = (uint)Marshal.ReadInt32(lParam, 16);
            uint lat = GetTickCount() - evtTime;
            if (lat > 100) LogAsync(string.Format("LATE input ({0}): delivered {1}ms late - our thread was blocking", what, lat));
        }
        catch { }
    }

    // ---------------- hook liveness / self-heal ----------------
    // If the mouse moved but our hook saw nothing, Windows has dropped the hook.
    // Re-install it and park the byte back to the stock value so the emulator is
    // never left stuck in "always long glide".
    static void CheckHookHealth()
    {
        POINT cur;
        if (!GetCursorPos(out cur)) return;
        bool moved = !gHaveLastCursorPos || cur.x != gLastCursorPos.x || cur.y != gLastCursorPos.y;
        gLastCursorPos = cur; gHaveLastCursorPos = true;
        if (!moved) return;

        double sinceEvent = (uint)(Environment.TickCount - gLastHookEventTick);
        if (sinceEvent < 1000) return;                       // hook is delivering
        if ((DateTime.UtcNow - gLastReinstall).TotalSeconds < 5) return;   // don't thrash

        gLastReinstall = DateTime.UtcNow;
        gReinstallCount++;
        if (gHook != IntPtr.Zero) UnhookWindowsHookEx(gHook);
        gHook = SetWindowsHookEx(WH_MOUSE_LL, gHookProc, GetModuleHandle(null), 0);
        Log(string.Format("HOOK RE-INSTALLED (#{0}): mouse moved but no hook event for {1:N0}ms -> Windows had dropped it; new handle={2}",
            gReinstallCount, sinceEvent, gHook.ToInt64()));
        if (gHook == IntPtr.Zero) Log(string.Format("  SetWindowsHookEx failed err={0}", Marshal.GetLastWin32Error()));

        // put the emulator back to stock instead of leaving it stuck on REST
        if (!gLogOnly && gVerified) WriteVariant(gOrig, "hook-loss-reset");
        gLastHookEventTick = Environment.TickCount;
    }

    // ---------------- cursor lock watchdog ----------------
    static string RectStr(RECT r) { return string.Format("({0},{1})-({2},{3})", r.left, r.top, r.right, r.bottom); }
    static bool RectEq(RECT a, RECT b) { return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom; }

    // "clipped" = somebody confined the cursor to less than the whole desktop
    static bool IsClipped(RECT r)
    {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);          // virtual screen origin
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);          // virtual screen size
        return !(r.left <= vx && r.top <= vy && r.right >= vx + vw && r.bottom >= vy + vh);
    }

    static int GetDnPid()
    {
        if (gDnPidCache != 0 && (DateTime.UtcNow - gDnPidAt).TotalSeconds < 2) return gDnPidCache;
        gDnPidAt = DateTime.UtcNow;
        Process[] ps = Process.GetProcessesByName("dnplayer");
        gDnPidCache = (ps.Length > 0) ? ps[0].Id : 0;
        return gDnPidCache;
    }

    static void CursorLockTick()
    {
        IntPtr fg = GetForegroundWindow();
        uint fgPid = 0;
        if (fg != IntPtr.Zero) GetWindowThreadProcessId(fg, out fgPid);

        int dnPid = GetDnPid();
        bool fgIsDn = (dnPid != 0 && fgPid == (uint)dnPid);
        bool returning = fgIsDn && !gLastFgWasDn;
        bool lockedBefore = gWasLocked;

        RECT clip;
        if (!GetClipCursor(out clip)) { gLastFgWasDn = fgIsDn; return; }
        bool clipped = IsClipped(clip);

        // Safety: if the emulator is gone but ITS exact clip rect is still
        // confining the cursor, release it - otherwise the mouse stays trapped
        // after closing LDPlayer while locked.
        if (dnPid == 0 && clipped && gHaveSavedClip && RectEq(clip, gSavedClip))
        {
            if (ClipCursorNull(IntPtr.Zero)) Log("released stale cursor clip " + RectStr(clip) + " (dnplayer closed while locked)");
            gHaveSavedClip = false; gWasLocked = false; gLastFgWasDn = false;
            return;
        }

        if (gClipDebug && (clip.left != gLastLoggedClip.left || clip.top != gLastLoggedClip.top ||
                           clip.right != gLastLoggedClip.right || clip.bottom != gLastLoggedClip.bottom ||
                           (int)fgPid != gLastLoggedFgPid))
        {
            gLastLoggedClip = clip;
            gLastLoggedFgPid = (int)fgPid;
            Log(string.Format("clipwatch fg={0} (pid {1}) clip={2} clipped={3}", fgIsDn ? "dnplayer" : "other", fgPid, RectStr(clip), clipped));
        }

        // Learn LDPlayer's own clip rect - only while it is foreground and NOT on
        // the tick we come back, so a foreign app's leftover rect is never saved.
        if (fgIsDn && clipped && !returning)
        {
            if (!gWasLocked) Log("cursor lock ON  (dnplayer clip " + RectStr(clip) + ")");
            gWasLocked = true;
            gSavedClip = clip;
            gHaveSavedClip = true;
        }
        else if (fgIsDn && !clipped && !returning && gWasLocked)
        {
            // user pressed F8 to unlock while dnplayer was foreground (or LDPlayer released it)
            Log("cursor lock OFF (clip released by dnplayer)");
            gWasLocked = false;
        }

        // THE FIX: coming back to the container with the lock still logically on,
        // but the desktop clip gone -> put LDPlayer's own rect back.
        if (returning && lockedBefore && !clipped && gHaveSavedClip)
        {
            RECT r = gSavedClip;
            if (ClipCursorRect(ref r))
            {
                gReapplyCount++;
                Log(string.Format("RE-APPLIED cursor lock {0} (#{1})", RectStr(r), gReapplyCount));
            }
            else Log(string.Format("ClipCursor failed err={0}", Marshal.GetLastWin32Error()));
        }

        gLastFgWasDn = fgIsDn;
    }

    // ---------------- foreground watcher (who steals focus?) ----------------
    static void FgWatchTick()
    {
        IntPtr fg = GetForegroundWindow();
        uint fgPid = 0;
        if (fg != IntPtr.Zero) GetWindowThreadProcessId(fg, out fgPid);
        int p = (int)fgPid;
        if (p == gLastFgWatchPid) return;
        gLastFgWatchPid = p;

        string name = "?";
        try { name = Process.GetProcessById(p).ProcessName; } catch { }

        StringBuilder title = new StringBuilder(300);
        try { GetWindowTextW(fg, title, title.Capacity); } catch { }

        string t = title.ToString();
        if (t.Length > 90) t = t.Substring(0, 90) + "...";
        Log(string.Format("FOCUS -> {0} (pid {1})  title=\"{2}\"", name, p, t));
    }

    static void Housekeeping()
    {
        int tick = 0;
        while (!gStop)
        {
            try
            {
                if (gHandle == IntPtr.Zero || (tick % 20) == 0) EnsureTarget();
                if (gHandle != IntPtr.Zero && !gVerified) ConfirmSite();
                MaybeReset();
                if (gCursorLock) CursorLockTick();
                if (gFgWatch) FgWatchTick();
                CheckHookHealth();   // self-heal if Windows dropped our hook
                DrainLog();          // the hook thread only enqueues - all I/O happens here
            }
            catch { }
            tick++;
            Thread.Sleep(100);
        }
    }

    // ---------------- tests ----------------
    static int gFail = 0;

    static void Chk(string what, bool got, bool want)
    {
        bool ok = (got == want);
        Out(string.Format("  [{0}] {1}", ok ? "PASS" : "FAIL", what));
        if (!ok) gFail++;
    }

    static int SelfTest()
    {
        Out("== encodings the guard must ACCEPT ==");
        Chk("stock   83 41 2c f0", TestKnown(FromHex("83412cf0")), true);
        Chk("RESTB   83 41 2c ff", TestKnown(FromHex("83412cff")), true);
        Chk("-128    83 41 2c 80", TestKnown(FromHex("83412c80")), true);
        Chk("ZEROB   83 61 2c 00", TestKnown(FromHex("83612c00")), true);
        Out("== garbage the guard must REJECT ==");
        Chk("and!=0  83 61 2c 05", TestKnown(FromHex("83612c05")), false);
        Chk("offby1  f0 8b 97 a0", TestKnown(FromHex("f08b97a0")), false);
        Chk("wrongd  83 41 2d f0", TestKnown(FromHex("83412df0")), false);
        Chk("nops    90 90 90 90", TestKnown(FromHex("90909090")), false);
        Chk("zeros   00 00 00 00", TestKnown(FromHex("00000000")), false);
        Chk("null    (null)", TestKnown(null), false);
        Out("== signature -> RVA ==");
        if (gDllPath.Length == 0)
        {
            string alt = GuessDllPath();
            if (alt != null) gDllPath = alt;
        }
        Out("   dll: " + (gDllPath.Length > 0 ? gDllPath : "(not found - is LDPlayer installed?)"));
        bool ok = (gDllPath.Length > 0) && ResolveSite();
        if (!ok) { Out("  [FAIL] no signature matched"); gFail++; }
        else
        {
            Chk("RVA 0x" + gRva.ToString("X") + " == 0x5BB96", gRva == 0x5BB96, true);
            Chk("disk bytes " + Hex(gDisk4) + " == 83 41 2c f0", Hex(gDisk4) == "83 41 2c f0", true);
        }
        Out("== " + (gFail == 0 ? "ALL PASS" : gFail + " FAILED") + " ==");
        WriteReport();
        return gFail == 0 ? 0 : 1;
    }

    static int CycleTest()
    {
        EnsureTarget();
        if (gHandle == IntPtr.Zero) { Out("CYCLE TEST: FAIL - no target (elevation?)"); WriteReport(); return 2; }
        if (!ConfirmSite()) { Out("CYCLE TEST: FAIL - site not verified"); WriteReport(); return 3; }
        WriteVariant(gZero, "cycle-1-zero");
        string afterZero = Hex(Read4(gBase + gRva));
        WriteVariant(gRest, "cycle-2-rest");
        string afterRest = Hex(Read4(gBase + gRva));
        bool pass = (afterZero == "83 61 2c 00") && (afterRest == Hex(gRest)) && gVerified;
        Out(string.Format("CYCLE TEST: ZEROB->{0}  RESTB->{1}  verified={2} -> {3}", afterZero, afterRest, gVerified, pass ? "PASS" : "FAIL"));
        Log(string.Format("CYCLE TEST: ZERO={0} REST={1} verified={2} -> {3}", afterZero, afterRest, gVerified, pass ? "PASS" : "FAIL"));
        WriteReport();
        return pass ? 0 : 1;
    }

    // ---------------- main ----------------
    static int Main(string[] args)
    {
        // Built with /target:winexe, so there is never a console window (which is
        // what we want for a background agent).  NOTE: do NOT call
        // GetConsoleWindow() here - it faults the CLR on this machine.
        try { SetProcessDPIAware(); } catch { }   // keep screen rects in physical pixels

        bool selfTest = false, cycle = false;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            try
            {
                if (a == "--selftest") selfTest = true;
                else if (a == "--cycle") cycle = true;
                else if (a == "--logonly") gLogOnly = true;
                else if (a == "--verbose") gVerbose = true;
                else if (a == "--probe") { gProbe = true; gLogOnly = true; if (gSeconds == 0) gSeconds = 10; }
                else if (a == "--cursorlock") gCursorLock = true;
                else if (a == "--clipdebug") gClipDebug = true;
                else if (a == "--fgwatch") gFgWatch = true;
                else if (a == "--log") gLogPath = args[++i];
                else if (a == "--result") gResultPath = args[++i];
                else if (a == "--dll") gDllPath = args[++i];
                else if (a == "--longpress") gLongPress = int.Parse(args[++i]);
                else if (a == "--shortdec") gShortDec = int.Parse(args[++i]);
                else if (a == "--resetafter") gResetAfter = int.Parse(args[++i]);
                else if (a == "--seconds") gSeconds = int.Parse(args[++i]);
            }
            catch { Console.WriteLine("bad argument: " + a); return 64; }
        }

        gRest = new byte[] { 0x83, 0x41, 0x2C, (byte)(gShortDec & 0xFF) };
        gZero = new byte[] { 0x83, 0x61, 0x2C, 0x00 };
        gOrig = new byte[] { 0x83, 0x41, 0x2C, 0xF0 };   // stock: add ..., -0x10

        if (selfTest) return SelfTest();
        if (cycle) return CycleTest();

        // keep the log bounded across restarts
        try
        {
            if (File.Exists(gLogPath) && new FileInfo(gLogPath).Length > 4 * 1024 * 1024) File.Delete(gLogPath);
        }
        catch { }

        Log(string.Format("start  LongPressMs={0} ShortDec=0x{1:X2} ResetAfterMs={2} LogOnly={3}",
            gLongPress, gShortDec, gResetAfter, gLogOnly));
        Log("RESTB=" + Hex(gRest) + "   ZEROB=" + Hex(gZero));
        if (gCursorLock) Log("cursor-lock watchdog ON (F11 fullscreen + F8 mouse lock)");
        if (gFgWatch) Log("foreground watcher ON (logs every focus change)");
        EnsureTarget();
        if (gHandle != IntPtr.Zero) ConfirmSite();

        Thread hk = new Thread(new ThreadStart(Housekeeping));
        hk.IsBackground = true;
        hk.Start();

        gHookProc = new HookProc(HookCallback);
        gHook = SetWindowsHookEx(WH_MOUSE_LL, gHookProc, GetModuleHandle(null), 0);
        if (gHook == IntPtr.Zero)
        {
            Log(string.Format("SetWindowsHookEx failed err={0}", Marshal.GetLastWin32Error()));
            return 4;
        }
        gLastHookEventTick = Environment.TickCount;
        Log("mouse hook installed (event driven, no polling)");

        gMainThreadId = GetCurrentThreadId();

        if (gSeconds > 0)
        {
            // MUST stay rooted in a static field: a local System.Threading.Timer
            // is eligible for GC, and once collected its callback never fires
            // (that is why --seconds appeared to hang).
            gExitTimer = new Timer(delegate(object o) { gStop = true; PostQuit(); }, null, gSeconds * 1000, Timeout.Infinite);
        }

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        gStop = true;
        if (gHook != IntPtr.Zero) UnhookWindowsHookEx(gHook);
        DrainLog();
        CloseTarget();
        Log("stopped");
        return 0;
    }

    [DllImport("user32.dll")]
    static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();

    static uint gMainThreadId = 0;

    static void PostQuit()
    {
        // must target the MAIN thread - the timer callback runs on a pool thread
        if (gMainThreadId != 0) PostThreadMessage(gMainThreadId, 0x0012 /*WM_QUIT*/, IntPtr.Zero, IntPtr.Zero);
    }
}
