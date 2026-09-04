# ADR-012: 番茄钟——在 w_dashboard 内新增一个常驻桌面小工具，时段结束闪烁托盘图标

## Status

Accepted（在 ADR-001「只展示本机状态」之外，新增一类**常驻桌面小工具**能力；不改变 ADR-001 的
"无后端 / 无数据库"、ADR-002 的两端独立原生实现、ADR-003 的子进程调用、ADR-008 的规格驱动）

## Context

**问题**：久坐对腰颈不好，需要一个"每隔一段时间提醒起身活动"的番茄钟——工作一段（专注），
然后休息一段。作者已有网页版实现 [`pomodoro-vue`](https://github.com/wiloon/pomodoro-vue)，
挂在一台闲置手机上常亮显示。现在想把它**并入常开的 w_dashboard 桌面端**：桌面端已经常驻、
在 macOS 菜单栏 / KDE 托盘有存在感，可以在**时段结束时把托盘/菜单栏图标换成一个橙红色、会闪的图标**
做强提醒——用户不用一直盯着倒计时看。

**触发**：作者提出——"在这个工具里实现一个番茄钟。工作时段结束后，把任务栏图标替换成一个
橙黄或红色的、能闪的图标；UI 上要有开启一个时段的操作接口。参考我自己的 pomodoro-vue。"

**参考实现 `pomodoro-vue` 的关键行为**（以代码为准，README 的 30 分钟是旧文案）：

| 方面 | 行为 |
|------|------|
| 时段 | 专注 `L` = 25 min，休息 `S` = 5 min |
| 推进 | **手动**：「Next」按钮切换时段。时间到了**不自动切**，而是进入**超时提醒态**——进度条变绿、每 N 秒（默认 10）响一次提示音、时段结束的那一刻发一条系统通知——直到用户点 Next |
| 计数 | 当前 session 序号、当日专注数，存 `localStorage` |
| 通知 | Web Notifications API，时段结束发一条（`Focus ended` / `Break ended`），不重复 |
| 设置 | 提示音选择（bell / rain）、提示音间隔 |

**本次已确认的取舍**（见会话问答）：

- **目标 Linux 环境 = KDE Plasma**：原生支持 StatusNotifierItem 托盘。
- **推进方式 = 手动 + 持续提醒**：与 `pomodoro-vue` 一致，时段结束后图标一直闪 + 一条通知，直到用户点「开始休息 / 开始专注 / 停止」。
- **提醒方式 = 闪托盘图标 + 系统通知 + 提示音**（闪图标是核心，通知/声音是加强）。
- **专注结束比休息结束更强**：`FocusEnded` = 闪红 + 通知 + 提示音；`BreakEnded` = 闪橙 + 通知，**不响提示音**（用户原始诉求只提到"工作时段结束"）。
- **自动收工**：`*Ended` 持续超时满 30 分钟仍无人确认 → 视为人已离开，`pomodoro_reduce` 自己把 phase 收回 `Idle`（避免关机一夜后开机看到无意义的常闪）。
- **不跨重启保留状态**：番茄钟状态只存内存，重启回到空闲。当日完成数也不持久化。

**约束（不变）**：

- 无后端 / 无数据库（ADR-001）。番茄钟状态**只在内存**。
- 两端独立原生实现、不共享代码、无 FFI（ADR-002）。
- 确定性纯函数逻辑进测试向量；副作用（定时器 / 托盘 / 通知 / 声音）留在各端 UI 层（ADR-008、SDD §10.1）。
- 采集层 / UI 层分层（SDD §6、`.cursor/rules/ui-no-logic.mdc`）。
- 联网 / 子进程调用一律设超时与失败降级（AGENTS.md）——本模块的通知 / 声音走子进程时同样适用。

**这不是什么**：不是任务管理、不是番茄工作法统计分析、不是多人协作、不是多计时器。
就是"久坐提醒 + 时段结束强提示"这一个工具。

## Options Considered

### 一、是否并入 w_dashboard

| 方案 | Pros | Cons | 复杂度 | 何时合适 |
|------|------|------|--------|----------|
| A. 维持网页版现状，w_dashboard 不做 | 边界最清晰；w_dashboard 永远是纯监视器 | 手机网页版没有桌面级强提醒；两处维护；桌面前工作时手机不一定在视野里 | 低 | 认为 w_dashboard 只能是"本机状态监视器" |
| **B. w_dashboard 加一个「番茄钟」面板 + 托盘图标状态机**（选中） | 复用已常驻的进程与菜单栏/托盘存在感（网页版做不到的正是这点）；一个窗口看全；实现上复用既有分层与向量机制 | w_dashboard 身份从"纯监视器"扩为"监视器 + 一个常驻小工具"，需要把边界重新钉死 | 中 | 想要桌面级强提醒，且愿意接受 app 身份变宽 |
| C. 独立的原生番茄钟小程序 | 职责单一 | 又多一个要开机自启、要占一个托盘位的应用；与 w_dashboard 的窗口/托盘/构建/打包重复造轮子 | 中 | 番茄钟功能会长成一个大工具（统计、多计时器…） |

### 二、Linux 端"闪烁任务栏图标"的实现机制

| 方案 | Pros | Cons | 何时合适 |
|------|------|------|----------|
| **A. StatusNotifierItem 托盘图标（`ksni` crate：纯 Rust + zbus，独立 D-Bus 线程，不依赖 GTK）**（选中） | KDE 原生支持；与 Slint 事件循环完全解耦；可换图标 + 附带右键菜单（开始/停止）；最小化到托盘也在 | 多引入 `ksni` + `zbus` 依赖；非 SNI 环境（未装扩展的 GNOME）没有托盘 | KDE / 多数支持 SNI 的桌面 |
| B. `tray-icon` crate（Tauri 系） | 跨平台 API 统一 | Linux 侧历史上要拉 GTK；与 Slint 的 winit 事件循环集成更绕 | 想用一套 API 同时管两端托盘 |
| C. 窗口 urgency 提示（`_NET_WM_STATE_DEMANDS_ATTENTION` / Wayland urgency） | 不加托盘依赖，直接闪任务栏条目 | Slint 不直接暴露，需 `raw-window-handle` + x11/wl 底层调用；跨合成器行为不一致；窗口最小化到托盘时没有窗口可闪 | 只想闪任务栏、且窗口一直可见 |
| D. 只在窗口内闪 + 改窗口标题 | 零依赖 | 窗口不在前台就看不到——正是要解决的场景 | 仅作无 SNI host 时的兜底 |

→ 选 **A（`ksni`）**，**D 作为无 SNI host 时的降级兜底**。

### 三、macOS 端

已有 `NSStatusItem`（`app-macos/Sources/WDashboardApp/AppDelegate.swift`，目前只用来点击唤起主窗口）。
时段结束时用一个 `Timer` 每 ~0.6s 切换 `statusItem.button.image`（正常 template 图 ↔ 橙红彩色图）实现闪烁；
可选叠加 `NSApp.requestUserAttention(.criticalRequest)` 让 Dock 图标持续跳动。用户确认后
`NSApp.cancelUserAttentionRequest(_:)` + 恢复图标。几乎零新增基础设施。

### 四、时段推进

手动 + 持续提醒（与 `pomodoro-vue` 一致，见 Context 问答）。不做自动切换。

### 五、图标来源

| 方案 | Pros | Cons |
|------|------|------|
| **自绘一对"番茄"图标**（选中） | 风格自主可控；无第三方授权/署名负担；番茄是番茄钟的通用符号，辨识度高 | 要自己画（成本很低，见"图标设计"） |
| 复用图标集（MDI `timer` / Lucide `timer` / SF Symbols `timer`） | 现成 | MDI/Lucide 要处理授权与视觉风格统一；SF Symbols 只能用在 macOS，跨端不一致 |

项目现有天气图标用的是 `basmilius/weather-icons`（MIT）；番茄钟图标改为**自绘**，两端共用同一份 SVG
（macOS 侧 idle/running 用 template 渲染跟随明暗，alert 用彩色）。

## Decision

选**方案 B**：w_dashboard 新增「番茄钟（Pomodoro）」模块——一个**面板** + 一个**托盘/菜单栏图标状态机**。
番茄钟的其余定位不变：无后端（ADR-001）、两端独立实现（ADR-002）、纯逻辑进向量（ADR-008）。

### 领域模型（纯逻辑，进测试向量）

**`PomodoroPhase`** 枚举：

| 取值 | 含义 |
|------|------|
| `Idle` | 空闲，没有进行中的时段 |
| `Focus` | 专注进行中 |
| `Break` | 休息进行中 |
| `FocusEnded` | 专注时间已到，**等用户确认**（超时提醒态，图标闪烁） |
| `BreakEnded` | 休息时间已到，等用户确认（超时提醒态，图标闪烁） |

**`PomodoroState`**（内存中唯一的一份状态）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `phase` | `PomodoroPhase` | 当前阶段 |
| `phase_started_at` | `int?`(unix 秒) | 当前 `Focus`/`Break` 段的开始时刻；`Idle` 时为空 |
| `focus_secs` | `int` | 专注时长；UI 层在 `phase == Idle` 时从配置写入，之后对进行中的时段冻结（见 SDD §11.3） |
| `break_secs` | `int` | 休息时长；同上 |

> `FocusEnded` / `BreakEnded` 时 `phase_started_at` **保留**为原时段的开始时刻，用于算 `overtime_secs`。

**纯函数（两端各自实现，签名语言无关）**：

```text
pomodoro_view(state: PomodoroState, now: int) -> PomodoroView
    从状态 + 当前时刻推导展示数据。纯函数，进 docs/test-vectors/pomodoro/。
    PomodoroView {
      phase:          PomodoroPhase,
      remaining_secs: int,      // Focus/Break: max(0, duration - elapsed)；*Ended / Idle: 0
      elapsed_secs:   int,      // Focus/Break: now - phase_started_at；*Ended: 冻结为 duration；Idle: 0
      overtime_secs:  int,      // *Ended: now - phase_started_at - duration；否则 0
      progress:       float,    // Focus/Break: clamp(elapsed / duration, 0, 1)；*Ended: 1；Idle: 0
      alerting:       bool,     // phase ∈ { FocusEnded, BreakEnded }
    }

pomodoro_reduce(state: PomodoroState, event: PomodoroEvent, now: int) -> PomodoroState
    状态迁移。纯函数，进 docs/test-vectors/pomodoro-transition/。
    PomodoroEvent ∈ { StartFocus, StartBreak, Stop, Tick }

    迁移规则（按序匹配，精确表见 SDD §11.3）：
     1. StartFocus → { phase: Focus, phase_started_at: now }
     2. StartBreak → { phase: Break, phase_started_at: now }
     3. Stop       → { phase: Idle,  phase_started_at: null }
     4. Tick 且 phase == Focus 且 (now - phase_started_at) >= focus_secs → FocusEnded
     5. Tick 且 phase == Break 且 (now - phase_started_at) >= break_secs → BreakEnded
     6. Tick 且 phase ∈ {FocusEnded, BreakEnded} 且 overtime >= 1800s → Idle（自动收工）
     7. 其余 Tick → 状态不变
    时长冻结：reduce 只读 state.focus_secs / state.break_secs，从不读配置——
    进行中（含 *Ended）的时段目标时长定死在 state。配置的时长变更由 UI 层在
    phase == Idle 时才写回 state（见 SDD §11.4 步骤 7）。
```

> 与 SDD §7.2 的 `RepoState` 决策表同构：一张无歧义的规则表，由测试向量逐行锁定，两端必须得出同一结果。

### 配置（SDD §4 新增 `[pomodoro]` 段）

```toml
[pomodoro]
# 是否启用番茄钟面板与托盘图标状态
enabled = true
# 专注时长（分钟）
focus_minutes = 25
# 休息时长（分钟）
break_minutes = 5
# 时段结束时发一条系统通知
notify = true
# 时段结束时播放一次提示音
sound = true
```

- `enabled = false`：面板隐藏，不注册托盘图标状态（托盘只保留现有"点击唤起窗口"行为）。
- 字段缺失走默认值（25 / 5 / true / true）；非法值（如 `focus_minutes <= 0`）返回带字段定位的可读错误，按 SDD §4 既有规则处理。

### UI 层职责（两端各自实现，**不进向量**）

1. **1 秒 tick 定时器**（Slint `Timer` / SwiftUI `Timer`）：每秒调 `pomodoro_reduce(state, Tick, now)` 更新状态，再调 `pomodoro_view` 重渲染。与时钟的每秒刷新（ADR-006）同类。
2. **面板**（第 5 个分区，信息架构两端一致）：
   - 当前 phase 标签（Idle / Focus / Break / Focus done / Break done）——面板置于窗口最上面，因为它是唯一需要主动操作的分区
   - 剩余时间 `mm:ss`（`*Ended` 显示 `+mm:ss` 超时）
   - 进度条（`*Ended` 满格并变色）
   - 按钮：`开始专注` `开始休息` `停止`——按 phase 高亮/禁用（`Idle` 突出"开始专注"；`*Ended` 三个都可点，点任意一个即"确认"）
3. **托盘 / 菜单栏图标状态机**（`alerting` 与 `phase` 驱动）：

   | phase | 图标 |
   |-------|------|
   | `Idle` | 无番茄钟图标（或暗色番茄），仅保留现有点击行为 |
   | `Focus` / `Break` | 常态番茄图标；tooltip 显示剩余时间与阶段 |
   | `FocusEnded` | **闪烁**：UI 定时器 ~1.5 Hz 在「红色番茄」与「暗/透明」之间切换 |
   | `BreakEnded` | **闪烁**：同上，用「橙色番茄」 |

   - 图标菜单项（Linux `ksni` 菜单 / macOS 可后续加）= 对应 `PomodoroEvent`。
   - Linux：`ksni`（StatusNotifierItem）。macOS：切换 `statusItem.button.image`，可选叠加 `NSApp.requestUserAttention(.criticalRequest)`。
4. **进入 `*Ended` 的那一刻（phase 边沿，只触发一次）**：
   - `notify == true` → 一条系统通知（macOS `UNUserNotificationCenter`；Linux `notify-send` 子进程，延续 ADR-003 的 "shell out" 风格）。文案：专注结束「该起来活动了」/ 休息结束「可以开始专注了」。
   - `sound == true` **且进入的是 `FocusEnded`** → 播一次提示音（macOS `NSSound`；Linux `canberra-gtk-play` / `paplay` 子进程）。`BreakEnded` 不响。子进程失败静默降级。
5. **确认（用户点任意「开始…」/「停止」，或规则 6 自动收工）**：停止图标闪烁定时器、复位图标、取消 `requestUserAttention`。
6. **无 SNI host 兜底（Linux）**：检测不到 StatusNotifierWatcher 时，`*Ended` 态改为——面板内大号高亮横幅 + 窗口标题加前缀 `⏰`。
7. **配置加载**：v1 无配置热重载——`[pomodoro]` 启动时读一次，改设置需重启（重启本就回 `Idle`）。将来加热重载时的规则见 SDD §11.4 步骤 7。

### 明确不做（v1）

长休息（每 4 个专注后一次长休息）、当日 / 历史统计、跨重启恢复、重复提示音（只响一次，不做每 N 秒 ding）、
任务清单、多个并行计时器、番茄钟设置界面（改配置文件即可）。

## Rationale

1. **复用常驻进程 + 托盘/菜单栏存在感**——这正是网页版做不到的（挂手机上只能盯着看）。加一个面板远比再维护一个独立应用便宜（方案 C 要各自处理开机自启、托盘位、打包）。
2. **纯逻辑做成纯函数进向量**：phase 状态机 + tick 推导是确定性的，和 §7.2 `RepoState` 决策表同构，两端一致性有客观闸门；副作用（定时器 / 托盘 / 通知 / 声音）本就该在各端 UI 层（SDD §10.1）。
3. **不持久化**符合 ADR-001「无数据库」的初衷，且番茄钟是"此刻"的活动，应用重启打断的情形罕见——不值得为它破坏一直坚持的约束。
4. **`ksni`** 纯 Rust、跑独立 D-Bus 线程，不把 GTK 拖进 Slint 工程；作者的 Linux 机是 KDE，原生支持 SNI。
5. **macOS 侧几乎零新增基础设施**：`NSStatusItem` 已经在，只加一个图标切换定时器 + 可选 Dock 抖动。
6. **手动推进 + 持续提醒**与网页版行为一致，用户迁移直觉不变；持续闪图标正是"强提醒直到确认"的诉求本身。

## Trade-offs

- w_dashboard 身份从"本机状态纯监视器"扩为"监视器 + 一个常驻小工具"。需要靠本 ADR 把边界钉死：**只做久坐提醒这一个工具**，不滑向"效率套件"（Revisit Trigger 里明确了触发线）。
- 两端各多一份 UI 层代码：tick 定时器 + 托盘图标状态机 + 通知 / 声音。托盘部分两端机制完全不同（`ksni` vs `NSStatusItem`），无法共享，只能靠这份规格对齐**可观察行为**。
- app-linux 目前依赖很精简，新增 `ksni` / `zbus`。
- 非 SNI 环境（未装扩展的 GNOME）Linux 端拿不到托盘闪烁，只能兜底横幅——但作者用 KDE，可接受。
- 通知 / 声音走子进程（`notify-send` / `paplay`），依赖桌面装了这些工具——延续 ADR-003 的取舍，缺失就静默降级。
- 番茄钟状态不持久化：应用崩溃 / 重启会丢掉进行中的时段。这是刻意的（见 Rationale 3）。

## Consequences

- **Positive**：久坐提醒并入一个已经常开的窗口；时段结束强提醒不需要用户主动看倒计时；纯逻辑有向量护栏，两端行为一致有客观闸门；实现上复用既有分层、配置加载、向量机制。
- **Negative**：两端 UI 层复杂度上升；多一个跨语言无法统一的子系统（托盘图标）；文档面（SDD、task-spec、AGENTS.md 里"应用是什么"的口径）要同步改。
- **Mitigation**：
  - **SDD 新增 §11「番茄钟」**：数据模型（`PomodoroPhase` / `PomodoroState`）、`pomodoro_view` / `pomodoro_reduce` 纯函数签名与规则表、配置 `[pomodoro]`、UI 层职责与托盘状态机、降级路径。
  - **新增 `docs/test-vectors/pomodoro/`**：`{ input: { phase, phase_started_at, focus_secs, break_secs, now }, expected: PomodoroView }`，覆盖每个 phase、临界（`elapsed == duration`）、overtime、`Idle`。
  - **新增 `docs/test-vectors/pomodoro-transition/`**：`{ input: { state, event, now }, expected: PomodoroState }`，覆盖 §11.3 的 7 条迁移规则每一条 + `Tick` 触发 `*Ended` 的临界 + 自动收工阈值上下边界。
  - **task-spec 加里程碑 M8「番茄钟」**：规格先行（本 ADR + SDD §11）→ 向量 → 两端实现（Linux `ksni` / macOS `NSStatusItem`）→ 对照 §11 逐条一致性走查。
  - **AGENTS.md「项目是什么」**：补一句——除展示本机状态外，含一个常驻桌面小工具（番茄钟）。
  - **`config.example.toml`** 加 `[pomodoro]` 段（全字段 + 注释）。
  - **图标资产**：`app-linux/ui/icons/tray/tomato-{active,alert-focus,alert-break}.svg`；macOS 放 `app-macos/Resources/`。设计见下节。

## 图标设计

一个**番茄**符号（番茄钟的通用意象），三个状态位图，均 `viewBox="0 0 24 24"`：

| 文件 | 用途 | 配色 |
|------|------|------|
| `tomato-active` | `Focus` / `Break` 进行中 | 单色剪影（`#000`）——macOS 作 template 跟随明暗；Linux 托盘 ~70% 不透明度 |
| `tomato-alert-focus` | `FocusEnded` 闪烁的"亮"帧 | 红 `#E4372E` 果身 + 深绿 `#2E7D32` 叶 |
| `tomato-alert-break` | `BreakEnded` 闪烁的"亮"帧 | 橙 `#FF7A1A` 果身 + 深绿叶 |

**闪烁** = UI 定时器（~1.5 Hz）在"亮帧"与"暗帧/透明"之间切换图标；不用 SVG 动画（托盘图标动画支持不可靠）。
专注结束用**红**（更急迫），休息结束用**橙**（较柔和）。

彩色版（`tomato-alert-focus`，改 `--body` 即得 break 版）：

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <!-- 果身 -->
  <ellipse cx="12" cy="14" rx="8" ry="7.4" fill="#E4372E"/>
  <!-- 高光 -->
  <ellipse cx="9" cy="11.4" rx="1.9" ry="2.5" fill="#FFFFFF" opacity="0.28"/>
  <!-- 叶/萼（5 瓣）+ 蒂 -->
  <path fill="#2E7D32" d="M12 3.1c.7 1 .9 2.1.5 3.2 1-.9 2.3-1.2 3.6-.9-.5 1.3-1.6 2.1-2.9 2.4 1.2.3 2.1 1 2.7 2.1-1.4.3-2.8 0-3.9-.9.2 1.3-.2 2.5-1 3.4-.9-.9-1.3-2.1-1.1-3.4-1.1.9-2.5 1.2-3.9.9.6-1.1 1.6-1.9 2.8-2.1-1.3-.3-2.4-1.1-2.9-2.4 1.3-.3 2.6 0 3.6.9-.5-1.1-.3-2.2.4-3.2z"/>
</svg>
```

单色剪影版（`tomato-active`）：

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <path fill="#000000" d="M12 3.1c.7 1 .9 2.1.5 3.2 1-.9 2.3-1.2 3.6-.9-.5 1.3-1.6 2.1-2.9 2.4 1.2.3 2.1 1 2.7 2.1-1.4.3-2.8 0-3.9-.9.2 1.3-.2 2.5-1 3.4-.9-.9-1.3-2.1-1.1-3.4-1.1.9-2.5 1.2-3.9.9.6-1.1 1.6-1.9 2.8-2.1-1.3-.3-2.4-1.1-2.9-2.4 1.3-.3 2.6 0 3.6.9-.5-1.1-.3-2.2.4-3.2z"/>
  <ellipse cx="12" cy="14" rx="8" ry="7.4" fill="#000000"/>
</svg>
```

> 这些是设计稿；实现阶段（M8）落到上述路径时可再微调几何。M8b 验收时用真实截图核对托盘 / 菜单栏的实际观感。

## Revisit Trigger

- 作者开始要长休息 / 当日统计 / 历史趋势——重新评估"是否值得引入哪怕一个小状态文件"，以及番茄钟是否该独立成应用（方案 C）。
- 迁到非 KDE、无 SNI 托盘的环境，兜底横幅不够用——重新评估窗口 urgency / 其他机制。
- 想要多设备同步番茄状态（手机 + 桌面一致）——那属于 ADR-001 方案 B（后端）的范畴，另开 ADR。
- 番茄钟之外又想往 w_dashboard 塞第二、第三个小工具——停下来先问"这还叫不叫 dashboard"。
