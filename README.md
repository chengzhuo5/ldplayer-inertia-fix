# ldplayer-inertia-fix

修复雷电模拟器（LDPlayer）**右键行走**的两个体验问题。纯本机、不联网、不改磁盘上任何文件。

| 问题 | 修复后的行为 |
|---|---|
| 松开右键后角色**还在滑**，惯性不可控 | **单击**保留超长惯性，**长按**（约 0.3 秒以上）松手**立刻停** |
| F11 全屏 + F8 锁定鼠标后，**Alt+Tab 切走再切回**光标就跑出容器 | 切回容器时自动补回锁定，不再需要点容器外面 |

## 原理（一句话版）

1. **惯性**：`dnplycore.dll` 处理松手时**不把虚拟摇杆归零**，而是每步减 0x10 直到减到 0。
   把这条 `add dword ptr [ecx+0x2c], -0x10` 换成别的立即数就能改惯性长度 ——
   单击用 `-0x01`（≈16 倍滑步），长按松手时换成 `and dword ptr [ecx+0x2c], 0`（直接清零）。
2. **鼠标锁定**：F8 用的是 Windows 的桌面级共享 `ClipCursor()`，切走时会被释放/覆盖，
   而雷电自己不再重设。看门狗记住雷电的裁剪矩形，切回容器时原样写回。

详细原理、特征码表、以及所有踩过的坑见 **[REFERENCE.md](REFERENCE.md)**。

## 安装

需要 Windows + 雷电 14.x + 管理员权限。**不需要** Visual Studio（`csc.exe` 是系统自带的）。

```powershell
cd scripts

# 1. 编译常驻代理
.\build.ps1

# 2. 离线自检（不写内存、不需要提权）
.\inertia-native.exe --selftest --result selftest.txt

# 3. 安装计划任务（提权）
.\elev.ps1 -Script .\install-inertia-task.ps1 -ScriptArgs '-Engine','exe','-CursorLock'

# 4. 查看状态
.\install-inertia-task.ps1 -Status
```

装好后直接进游戏即可。计划任务会在**每次登录时自动启动**，重启模拟器不用管。

## 卸载

```powershell
.\elev.ps1 -Script .\install-inertia-task.ps1 -ScriptArgs '-Remove'
```

磁盘上的 `dnplycore.dll` **从未被修改**，所以卸载后彻底恢复原版（内存里的改动随模拟器重启消失）。

## 调参

```powershell
# 单击/长按的分界（默认 200ms）
-ScriptArgs '-LongPressMs','250'

# 单击时的惯性长度：ShortDec = 每步减多少，0..255，越小惯性越长
-ScriptArgs '-ShortDec','255'   # -1/步 ≈ 16 倍，单条立即数编码的极限
-ScriptArgs '-ShortDec','240'   # -16/步 = 原版
-ScriptArgs '-ShortDec','128'   # -128/步，明显变短

# 不用常驻 exe，退回 PowerShell 引擎（CPU 约 22% 单核，exe 是 0%）
-ScriptArgs '-Engine','ps','-PollMs','8'

# 想看鼠标锁定在做什么（诊断日志）
-ScriptArgs '-CursorLock','-ClipDebug'
```

## ⚠️ 出问题先看会话

**输入是按 Windows 会话隔离的。** 如果同一用户在系统里有多个会话
（比如一个断开的残留 RDP 会话 + 正在用的 console 会话），`LogonType Interactive`
的计划任务**可能被调度进那个没有输入的会话** —— 此时内存补丁照常工作
（`verified=True`）但**鼠标完全读不到**，看起来就像"补丁失效、游戏里没效果"，而且**一个错误都不报**。

```powershell
query session                                      # 看有没有残留会话（Disc 状态的那种）
Get-Process inertia-native | Select-Object Id,SessionId
Get-Content <安装目录>\inertia-native.log -Tail 5   # 心跳
```

代理现在会自己检测并警告：

```
!! WRONG SESSION: this agent is in session 1 but the active console session is 2.
```

正常心跳应该 `sess` 等于 `console`，且 `hookEvents` 在持续增长：

```
heartbeat: sess=2/console=2 hookEvents=36500 pollEdges=110 drained=166 queued=0
           hook=True verified=True down=False | threads: poll=0ms house=0ms drain=0ms ago
```

**所以本项目的持久化用 Startup 启动器，而不是计划任务** —— Startup 项天然运行在
交互式 console 会话里。详见 [REFERENCE.md](REFERENCE.md) §4.11。

## 特性

- **CPU ≈ 0%** —— 用 `WH_MOUSE_LL` 低层鼠标钩子事件驱动，不轮询（PowerShell 版是 4ms 轮询，约 22% 单核）
- **不写死任何地址** —— 用字节特征码在磁盘 DLL 里定位，再按 PE 节表换算 RVA
- **雷电升级不会改坏** —— 命中位置会先校验指令形态；对不上就**拒绝写入并记日志**，模拟器照常能用
- **不写死安装路径** —— 从运行中的 `dnplayer.exe` 反推安装目录，装到哪个盘都行
- **日志有界** —— 常驻代理的心跳默认 **60 秒一条**，日志超过 2 MB 自动轮转（保留最后 1000 行）；调试时用 `--heartbeat 10` 调快
- **自带三个自检** —— `--selftest`（离线）/ `--cycle`（在线往返）/ `--probe`（钩子存活）

## 文件

| 文件 | 说明 |
|---|---|
| `scripts/inertia-native.cs` | 原生常驻代理源码（C#，用系统自带 `csc.exe` 编译） |
| `scripts/build.ps1` | 编译 + 自检 |
| `scripts/install-inertia-task.ps1` | 计划任务安装 / 卸载 / 状态 |
| `scripts/inertia-smart.ps1` | PowerShell 版引擎（备用，功能等价） |
| `scripts/patch-inertia-dll.ps1` | 改**磁盘** DLL 的永久方案（只有"一律立刻停"，没有两级行为） |
| `scripts/livepatch.ps1` | 一次性内存补丁，手动试各种编码 |
| `scripts/elev.ps1` | 提权调用器（`dnplayer.exe` 是管理员权限，必须提权） |

## 注意

- 本工具只修改**你自己机器上正在运行的进程内存**，不修改磁盘文件、不联网、不注入游戏。
- 与雷电模拟器官方无关，未获其授权或认可。使用风险自负。
- 游戏内使用请遵守对应游戏的用户协议。

## License

MIT，见 [LICENSE](LICENSE)。
