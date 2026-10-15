# ADR-015: 新增 Windows 端——C# + .NET 10 + WinUI（Windows App SDK）独立原生实现

## Status

Accepted（新增第三个目标平台；不改变 ADR-001 的"无后端 / 无数据库"、ADR-002 的"各端独立原生实现、不共享代码、无 FFI"、
ADR-003 的子进程调用、ADR-008 的规格驱动。在 ADR-002 的框架下把"两端"扩为"三端"）

## Context

**问题**：作者也在 Windows 主机上工作，希望 w_dashboard 在 Windows 上同样常驻：看本机仓库同步状态、番茄钟提醒、天气、网络健康。
现有两端是 Linux（Rust + Slint）与 macOS（Swift + SwiftUI），Windows 需要选一套"在该平台上最地道"的原生技术栈。

**触发**：作者提出开发 Windows 版本，要求"纯原生 GUI"，不用网页技术。

**外部背景**（2026）：微软在 2026 年 3 月确认把 Windows 11 开始菜单等 Shell 组件从 React Native 迁回 WinUI；
Build 2026 上宣布 WinUI 是 Windows 应用的"正式生产平台"、不再另起新框架，并把 "WinUI 3" 简称为 "WinUI"。
业界对"系统级 UI 用网页 / JS 技术导致卡顿"的批评，与本项目一贯排除 Electron / Web 技术的取向一致。

**参照基准**：Windows 端以 **SDD + macOS 端当前实现**为基准（macOS 是功能最全的一端：「当下」卡片、Repos 含增删改与
Pull / Push / Fetch、Weather、番茄钟、`Network`标签页）。Linux 端缺的部分（「当下」合并、`Network`）不影响 Windows 端范围。
chezmoi 面板各端都尚未实现，Windows 端同样暂缓。

**本次已确认的取舍**（见会话问答，2026-10-13）：

| 问题 | 结论 |
|------|------|
| GUI 技术栈 | **C# + .NET + WinUI（Windows App SDK）**；WPF 为备选 |
| v1 范围 | **完全对齐 macOS 当前功能**；chezmoi 暂缓（与另两端一致） |
| 配置路径 | `%USERPROFILE%\.config\w_dashboard\config.toml`；设置了 `XDG_CONFIG_HOME` 时优先 `%XDG_CONFIG_HOME%\w_dashboard\config.toml`——与另两端同一规则 |
| 托盘显示 | 托盘图标 16×16 放不下文字：**只显示图标**（随番茄钟阶段变色 / 闪烁），北京时间与阶段信息放 tooltip |
| 关闭窗口 | **隐藏到托盘、进程继续**（番茄钟不中断）；托盘菜单 `Exit` 才真正退出 |
| 托盘交互 | 左键唤起主窗口；右键菜单 `Start focus` / `Start break` / `Stop` / `Exit` |
| 任务栏闪烁 | `*Ended` 时托盘闪烁 **+ 任务栏按钮闪烁**（`FlashWindowEx`，对应 macOS Dock 跳动）；空闲提醒不闪任务栏 |
| 打包分发 | **不打 MSIX**：自包含发布目录 + PowerShell 安装脚本（开始菜单快捷方式 + `HKCU\…\Run` 开机自启） |
| 最低系统 | **只支持 Windows 11** |
| 网关 ping | **用 .NET `Ping` 类**取每次 RTT，不解析 `ping.exe`（中文系统输出是本地化文本）；`ping-output/` 向量不适用于 Windows |
| Captive 检测地址 | **沿用 `captive.apple.com`**，与 macOS 一致，规格与向量不改 |
| 文档 | 本 ADR + 全仓库"两端"→"各端" + task-spec M11 |
| 规格回填 | macOS 已实现但 SDD 未写的三项（常驻图标显示北京时间、仓库增删改与配置写回、安装与开机自启）**先补进 SDD**，各端以规格为准 |

**约束（不变）**：无后端（ADR-001）；三端独立实现、不共享代码 / 二进制、无 FFI（ADR-002）；git 走子进程（ADR-003）；
纯逻辑进测试向量、副作用留在采集入口 / UI 层（ADR-008、SDD §10.1）；UI 文案一律英文（AGENTS.md 核心约束 8）。

## Options Considered

| 方案 | Pros | Cons | 复杂度 | 何时合适 |
|------|------|------|--------|----------|
| **A. C# + WinUI（Windows App SDK）** | 微软主推且承诺长期投入的原生框架；Win11 原生观感（Mica / 圆角 / 深浅色）开箱即用；自带系统通知 API；支持 Native AOT | 无内置托盘（需 `H.NotifyIcon.WinUI`）；无 XAML 可视化设计器；仍有已知 bug / 内存偏高（微软 2026 年在优化）；不打包部署需处理运行时 | 中 | 追求 Win11 原生观感、长期演进 |
| B. C# + WPF | 极成熟、生态大、坑少；单文件 exe 分发最简单；托盘库成熟 | 默认观感偏旧（需 .NET 9+ Fluent 主题或 WPF-UI）；不支持 Native AOT；不是微软的未来方向 | 低 | 求稳、要兼容老系统 |
| C. 复用 `app-linux`（Rust + Slint 编到 Windows） | 工作量最小，Slint 支持 Windows | 违背 ADR-002"各端最地道"；Linux 与 Windows 共用代码，需先修订 ADR-002；非 Windows 原生观感 | 低 | 只想省事、不在意原生 |
| D. Rust + windows-rs / C++ Win32 | 最底层、最轻 | UI 开发成本高，AI 生成与维护都吃力 | 高 | 极端在意体积 / 资源 |
| E. Avalonia / MAUI / Tauri / Electron / Flutter | 跨平台 | 非原生或定位跨平台，与"各端最地道"、排除网页技术的取向冲突 | — | 不适用 |

## Decision

选**方案 A**：新增 `app-windows/`，用 **C# + .NET 10（LTS）+ WinUI（Windows App SDK 当前稳定版）**独立实现全部逻辑与 UI。

### 工程结构

```
app-windows/
├── WDashboard.sln
├── src/
│   ├── WDashboard.Core/        # 采集层 + 纯函数：config / git / weather / pomodoro / network（net10.0，无 UI 依赖）
│   └── WDashboard.App/         # WinUI 可执行项目：视图、托盘、通知、链路信息、调度（net10.0-windows）
├── tests/
│   └── WDashboard.Core.Tests/  # xUnit：加载 ../docs/test-vectors/ 的契约测试 + 配置 / 增删改单测 + 少量冒烟
└── Scripts/
    ├── install-windows.ps1
    └── uninstall-windows.ps1
```

- `WDashboard.Core` 对应 macOS 的 `WDashboardCore`：不引用任何 WinUI 类型，纯逻辑可在任意 .NET 环境测试。
- UI 采用 MVVM（`CommunityToolkit.Mvvm`）；后台采集用 `Task` + `SemaphoreSlim`（并发上限 4，SDD §8.1），回 UI 线程用 `DispatcherQueue`。

### 平台机制映射（各端对照）

| 规格要求 | Windows 实现 |
|----------|--------------|
| 子进程（git，ADR-003） | `System.Diagnostics.Process`：`CreateNoWindow = true`、`UseShellExecute = false`；stdout / stderr 固定 UTF-8 解码；超时后 `Kill(entireProcessTree: true)`；环境变量加 `GIT_TERMINAL_PROMPT=0` 防止后台进程卡在凭据输入 |
| 配置解析 | `Tomlyn` 读取；仓库增删改按 SDD §4.1 的**文本级编辑**写回（不经 TOML 库重新序列化，保证保留注释） |
| 路径 | `~` 展开为 `%USERPROFILE%`；`%VAR%` 与 `$VAR` 形式的环境变量都展开；比较仓库路径时规范化分隔符、去尾部分隔符、**不区分大小写** |
| HTTP（天气 / RTT / 测速） | `HttpClient` + `SocketsHttpHandler`，默认跟随系统代理（`HttpClient.DefaultProxy`） |
| 时区 | `TimeZoneInfo.FindSystemTimeZoneById` 直接用 IANA id（.NET 6+ 依赖 ICU） |
| 网关 ICMP | 物理网卡（Wi-Fi 优先，否则有线）的 IPv4 默认网关（`NetworkInterface.GetIPProperties().GatewayAddresses`）；`System.Net.NetworkInformation.Ping` 逐个发 `probe_samples` 次，间隔 200 ms，单次超时 `probe_timeout_ms`；成功的 `RoundtripTime` 组成 `rtts_ms` 交 `probe_stats`（不经 `parse_ping`） |
| HTTP RTT | `HttpCompletionOption.ResponseHeadersRead` + `Stopwatch`：请求发出 → 收到响应头 |
| TCP 握手 | `Socket.ConnectAsync` 计时 |
| Captive 检测 | `UseProxy = false`；`ConnectCallback` 里用 `IP_UNICAST_IF` 把 socket 绑定到物理网卡接口索引；不跟随重定向；超时 5 秒 |
| 链路信息 | 默认路由接口 / VPN：`NetworkInterface`（`Ppp` / `Tunnel` 类型或 WireGuard / Wintun 适配器视为 VPN）；系统代理：WinINET 当前用户代理设置；Wi-Fi：Native WLAN API（`wlanapi.dll`） |
| 网络切换 | `NetworkChange.NetworkAddressChanged` / `NetworkAvailabilityChanged`，去抖 3 秒，启动时先建基线 |
| 托盘 | `H.NotifyIcon.WinUI`（`Shell_NotifyIcon`）；预制 `.ico` 资产，闪烁 = 定时切换图标 |
| 任务栏闪烁 | `FlashWindowEx(FLASHW_ALL \| FLASHW_TIMERNOFG)`；确认时 `FLASHW_STOP` |
| 系统通知 | Windows App SDK `AppNotificationManager`（不打包模式需先 `Register()`）；失败静默 |
| 提示音 | `PlaySound` 播放系统声音别名（如 `SystemNotification`）；失败静默 |
| 单实例 | Windows App SDK `AppInstance.FindOrRegisterForKey`：再次启动时激活已运行实例的主窗口后退出 |

### Windows 与另两端的已知差异（均写入 SDD，属可接受的平台差异）

1. **网关 RTT 精度**：`Ping.RoundtripTime` 是整数毫秒（小于 1 ms 记 0）。统计口径仍按 SDD §12.3，只是输入精度较低。
2. **Wi-Fi 噪声 / 信噪比**：Windows WLAN API 不提供噪声值，这两项显示 `—`。RSSI 用 `wlan_intf_opcode_rssi`（dBm），信道 / 频段由 BSS 中心频率换算。
3. **SSID 需要定位权限**：Windows 11 24H2 起，桌面应用读 SSID 需用户在"设置 → 隐私和安全性 → 位置"里允许桌面应用访问位置。未授权时显示 `(needs Location permission)`，与 macOS 一致。
4. **托盘不显示文字**：macOS 菜单栏直接显示北京时间 `HH:mm`；Windows 放进 tooltip（SDD §9.1）。

## Rationale

1. **延续"各端最地道"**（ADR-002）：Linux 用 Rust 生态、macOS 用 Apple 原生框架，Windows 对应的就是 .NET + 微软当前主推的 UI 框架。
2. **框架长期可靠**：微软 2026 年明确押注 WinUI、不再换框架，并把自家 Shell 迁回 WinUI；选它不会被抛弃。
3. **与 macOS 能力一一对应**：通知、托盘、任务栏注意力提示、单实例、网络 API 都有原生对应物，规格里的 UI 层职责都能落地。
4. **C# 便于 AI 生成**：语料充足，契约测试（xUnit 数据驱动）与另两端的写法同构。
5. **.NET 10 是 LTS**：支持到 2028 年 11 月；.NET 9 将于 2026 年 11 月停止支持。

## Trade-offs

- **三份实现**：一致性的维护成本从"两端"变成"三端"，测试向量与规格精度更加关键。
- **WinUI 的短板**：托盘依赖第三方库；无可视化设计器（UI 由 AI 按规格生成，影响小）；内存占用比 WPF 高。
- **不打包分发**：放弃 MSIX 带来的应用身份与干净卸载；换来免证书、脚本化安装。通知在不打包模式下需要额外注册。
- **`ping-output/` 向量对 Windows 不适用**：Windows 绕开文本解析，网关结果的正确性改由 `probe-stats/` 向量与冒烟测试保证。
- **只支持 Windows 11**：放弃 Windows 10 用户（作者无此需求）。

## Consequences

- **Positive**：Windows 主机也能常驻 w_dashboard；Win11 原生观感；平台能力与 macOS 对齐。
- **Negative**：多一套实现与构建链（.NET SDK + Windows App SDK）；文档中所有"两端"表述需要改写。
- **Mitigation**：
  - **AGENTS.md / SDD / task-spec / CONTEXT.md / `.cursor/rules/`**：所有"两端"改为"各端"，仓库结构加 `app-windows/`。
  - **SDD 补规格**：§4 配置路径（Windows）与 §4.1 仓库增删改与配置写回；§9.1 常驻图标（托盘 / 菜单栏）与主窗口生命周期；§11.4 托盘与通知的 Windows 实现；§12 网关 / Captive / 链路信息 / 网络切换的 Windows 实现；§13 构建、安装与开机自启。
  - **task-spec 新增 M11「app-windows」**。
  - **测试向量零改动**：Windows 端跑除 `ping-output/` 外的全部向量。
  - 本 ADR 的工程结构与机制映射是实现阶段的起点；若实测某机制不可行（如 `IP_UNICAST_IF` 在全局 VPN 下无效），先改本 ADR / SDD 再改代码。

## Revisit Trigger

- WinUI 出现阻断性问题（托盘方案失效、不打包模式下通知 / 单实例无法工作、内存占用不可接受）→ 评估改用方案 B（WPF）。
- 需要发布给他人或上架 Microsoft Store → 重新评估 MSIX 打包与代码签名。
- 三端维护成本明显超出收益 → 重新评估 ADR-002（如 Linux 与 Windows 共用 Rust + Slint）。
