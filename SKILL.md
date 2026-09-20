---
name: ldplayer-inertia-fix
description: 修复雷电模拟器(LDPlayer)右键行走的两个体验问题：(1) 松开右键后角色还在滑 —— 单击保留超长惯性、长按松手立刻停；(2) F11 全屏按 F8 锁定鼠标后，Alt+Tab 切走再切回光标就跑出容器，必须点容器外面才能重新锁上。做法是用字节特征码定位 dnplycore.dll 里控制惯性衰减的那条指令做内存补丁（带形态守卫，雷电升级只会失效不会改坏），再用 WH_MOUSE_LL 钩子实现两级行为、用 ClipCursor 看门狗修好鼠标锁定。Use when 用户提到雷电右键行走惯性、松开还在走、走路飘/滑步停不下来、右键行走太滑、F8 鼠标锁定失效、全屏后光标跑出模拟器、Alt+Tab 后鼠标锁不住、LDPlayer right-click walk inertia/glide, stop-on-release, F8 mouse lock cursor escape, dnplycore.dll patch。
---

# 雷电模拟器 · 右键行走惯性 & F8 鼠标锁定修复

两个独立的问题，一个常驻代理同时解决：

| 问题 | 机制 | 修复 |
|---|---|---|
| 松开右键后角色**还在滑**（惯性不可控） | `dnplycore.dll` 的移动逻辑松手后**不把虚拟摇杆归零**，而是每步减 16 直到减到 0 | 4 字节内存补丁，**单击**用 −1（≈16 倍滑步）、**长按**松手直接清零 |
| F11 全屏 + **F8 锁定鼠标**，Alt+Tab 切走点一下再切回就锁不住 | F8 用的是**桌面级共享**的 `ClipCursor()`；切走时被释放/覆盖，雷电自己不再重设 | 记住雷电自己的裁剪矩形，切回容器时**原样写回** |

## 快速开始

```powershell
# 0. 前置：雷电 14.x，Windows，需要管理员。
#    先完全关闭雷电，编译代理（不需要 Visual Studio）
cd <本目录>\scripts
.\build.ps1

# 1. 离线自检：13 项守卫 + 特征码定位（不需要提权、不写内存）
.\inertia-native.exe --selftest --result selftest.txt

# 2. 安装计划任务（需要提权，用自带的 elev.ps1）
.\elev.ps1 -Script .\install-inertia-task.ps1 -ScriptArgs '-Engine','exe','-CursorLock'

# 3. 看状态
.\install-inertia-task.ps1 -Status

# 4. 卸载（磁盘 DLL 从未被修改，卸完就是原版）
.\elev.ps1 -Script .\install-inertia-task.ps1 -ScriptArgs '-Remove'
```

装好后：**单击右键**保留超长惯性；**长按右键约 0.3 秒以上再松手**立刻停。
F11 + F8 锁定后，Alt+Tab 来回切不再需要点容器外面。

## 常见调参

```powershell
# 长按判定阈值（默认 200ms）：单击/长按的分界线
-ScriptArgs '-LongPressMs','250'

# 单击时的惯性长度：ShortDec 是每步减多少，0..255，越小惯性越长
-ScriptArgs '-ShortDec','255'      # -1/步 ≈ 16 倍，已是单条立即数的极限
-ScriptArgs '-ShortDec','240'      # -16/步 = 原版惯性
-ScriptArgs '-ShortDec','128'      # -128/步，明显变短

# 不想常驻 exe，用 PowerShell 版引擎（CPU 约 22% 单核，exe 是 0%）
-ScriptArgs '-Engine','ps','-PollMs','8'
```

## 关键前提（踩过才知道）

1. **必须提权**。`dnplayer.exe` 以管理员权限运行，不提升权限连它的模块列表都读不到（会报
   "dnplycore.dll not found in dnplayer.exe yet"）。用自带的 `elev.ps1`。
2. **必须交互式会话**。`GetAsyncKeyState` 是按会话的，计划任务必须
   `RunLevel Highest` + `LogonType Interactive`，否则读不到鼠标。
3. **不要改磁盘上的 DLL**（除非你只想"所有右键一律立刻停"）。改磁盘会让补丁在雷电升级后
   被覆盖，而且没法做两级行为。看门狗/代理只改内存，重启模拟器即恢复原版。

## 出问题先跑自检

```powershell
# 离线：守卫逻辑 + 特征码 -> RVA，不写内存
.\inertia-native.exe --selftest --result selftest.txt

# 在线往返：真写一次"清零"再写回，需要提权、需要雷电在跑
.\inertia-native.exe --cycle --log cycle.log

# 钩子存活：会打印收到的鼠标消息（移动 0x0200 / 滚轮 0x020A）
.\inertia-native.exe --probe --log probe.log
```

日志里的两条关键行：

```
signature found: file 0x5AF96 -> RVA 0x5BB96      ← 惯性补丁定位成功
cursor lock ON  (dnplayer clip (4,260)-(2558,1336))  ← 鼠标锁定识别成功
```

## 雷电升级后会怎样

- **鼠标锁定看门狗**：几乎不受影响。它不碰雷电任何内部结构，锁定矩形是**运行时学来的**，
  分辨率/黑边/窗口变化会自动适应。唯一假设是进程名 `dnplayer`。
- **惯性补丁**：按**特征码**定位，代码挪位置照样能找到；那个函数被改写时
  **拒绝写入并记日志**，不会改坏模拟器 —— 最坏只是补丁失效。
- 两者**独立失效**，互不影响。

深入原理、四种字节编码、特征码表、以及所有已被推翻的猜测见 [REFERENCE.md](REFERENCE.md)。
