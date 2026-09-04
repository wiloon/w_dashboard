# w_dashboard 实现任务拆解（Task Spec）

> 本文档把 [SDD](sdd.md) 拆解为可独立交付、可验收的任务，供分阶段实现（由 AI 依据规格生成各平台代码）。
>
> 顺序原则（见 ADR-002 / ADR-008）：**先把规格与测试向量做扎实，再让两端各自原生实现并行展开**；
> 每端内部先做"采集层并通过共享测试向量"，再做 UI。两端不共享代码，靠同一份测试向量保证一致。
>
> M0–M4 是初始交付的里程碑；此后每一次影响行为或体验的变更，同样按"先改 ADR/SDD，再两端实现"追加为新的里程碑（M5 起）。

## 里程碑总览

| 里程碑 | 目标 | 依赖 |
|--------|------|------|
| M0 | 脚手架与文档基线 | — |
| M1 | 行为契约 / 测试向量集（语言无关） | M0 |
| M2 | app-linux（Rust + Slint）完整实现 | M1 |
| M3 | app-macos（Swift + SwiftUI）完整实现 | M1 |
| M4 | 两端一致性核对与打磨 | M2, M3 |
| M5 | 刷新体验：仓库增量刷新 | M2, M3 |
| M6 | 仓库同步操作：Pull / Push / Fetch 按钮 | M2, M3 |
| M7 | 单行手动刷新按钮 | M5, M6 |
| M8 | 番茄钟：面板 + 闪烁托盘/菜单栏图标 | M2, M3 |

> **M2 与 M3 可并行**（都只依赖 M1）。两端各自独立实现全部逻辑与 UI，互不依赖。

---

## M0 — 脚手架与文档基线

- **T0.1** 初始化目录结构（`app-linux/`、`app-macos/`、`docs/test-vectors/`、`config.example.toml`）。
- **T0.2** 编写 `config.example.toml`（依 SDD §4 全字段 + 注释）。
- **T0.3** 顶层 `README.md`：项目简介、文档索引、两端构建入口占位。
- **验收**：目录与文档齐备；`config.example.toml` 字段与 SDD §4 一致。

## M1 — 行为契约 / 测试向量集（先行，语言无关）

> 这是保证两端一致的权威来源（SDD §10）。必须先于两端实现完成，且两端实现都要引用它。

- **T1.1** `git-porcelain/`：构造若干 `status --porcelain=v2 --branch` 文本样本 → 期望 `RepoStatus`。覆盖：有/无 upstream、detached、ahead/behind、staged/modified/untracked/conflicted、ignored 不计数。
- **T1.2** `repo-state/`：覆盖 SDD §7.2 决策表**每一行 + 边界**（如 Dirty 与 Diverged 同时成立时取 Dirty；干净无 upstream 取 NoUpstream）。
- **T1.3** `chezmoi-status/`：`chezmoi status` 文本样本 → 期望 `ChezmoiEntry[]`。
- **T1.4** `weather-json/`：Open-Meteo `forecast` JSON 样本（正常 / 缺字段 / 空 daily）→ 期望 `WeatherReport`（含降级表现）。
- **T1.5** `wmo-codes`：WMO weather_code → 文案 完整映射表（两端共同引用）。
- **T1.6** 约定向量文件格式（统一 `{ input, expected }`）并在 `docs/test-vectors/README.md` 说明如何被两端加载。
- **验收**：向量覆盖 §7 全部规则与关键边界；格式清晰、可被任意语言读取。

## M2 — app-linux（Rust + Slint）

> 完整独立实现；不依赖任何共享 core。

### M2a 采集层

- **T2.1** 工程脚手架与依赖（slint + slint-build、serde、toml、reqwest(blocking) 或等价、serde_json、chrono/time 等）。
- **T2.2** 数据模型（SDD §5 全部类型，Rust 原生 struct/enum）。
- **T2.3** 配置加载（SDD §4：`~`/env 展开、默认值、字段校验、可读错误）。
- **T2.4** 子进程封装（cwd/参数/超时/捕获输出/区分"命令不存在"与"非零退出"）。
- **T2.5** git 采集与解析（SDD §7.1）+ `RepoState` 派生（§7.2）。
- **T2.6** chezmoi 采集（SDD §7.3）。
- **T2.7** 天气采集（SDD §7.4：geocoding + forecast + WMO 映射 + 降级）。
- **T2.8** `collect_snapshot` 聚合 + `check_environment`（单项失败不拖垮整体）。
- **测试**：**加载 `docs/test-vectors/` 跑契约测试**（porcelain/repo-state/chezmoi/weather 全过）；配置与子进程封装的单测；少量 e2e 冒烟（临时 git 仓库）。

### M2b UI

- **T2.9** 四分区 UI（Repos / chezmoi / Clocks / Weather），用 `.slint` 文件描述界面，按 SDD §9 信息架构与颜色语义。
- **T2.10** 刷新策略（SDD §8）：启动自检 + 后台线程采集 + 手动刷新 + 定时刷新；时钟独立每秒刷新。
- **T2.11** 错误/降级展示（缺 git/chezmoi 提示、fetch 失败标记、天气降级、上次刷新时间）。
- **T2.12** `.desktop` 入口与构建说明。
- **验收**：契约测试全过；在 Linux 上读真实配置正确展示四区；后台采集不卡 UI。

## M3 — app-macos（Swift + SwiftUI）

> 完整独立实现；与 app-linux 无代码共享，仅共享 `docs/test-vectors/`。

### M3a 采集层

- **T3.1** Xcode/Swift 工程脚手架与依赖。
- **T3.2** 数据模型（SDD §5 全部类型，Swift 原生 struct/enum）。
- **T3.3** 配置加载（SDD §4，与 Linux 同规格；TOML 解析库或自实现）。
- **T3.4** 子进程封装（`Process`，含超时与错误区分）。
- **T3.5** git 采集与解析（SDD §7.1）+ `RepoState` 派生（§7.2）。
- **T3.6** chezmoi 采集（SDD §7.3）。
- **T3.7** 天气采集（SDD §7.4：`URLSession` + WMO 映射 + 降级）。
- **T3.8** `collect_snapshot` 聚合 + `check_environment`。
- **测试**：**用 XCTest 加载同一份 `docs/test-vectors/` 跑契约测试**；配置/子进程单测；少量 e2e 冒烟。

### M3b UI

- **T3.9** 四分区 SwiftUI 视图，信息架构/颜色语义与 Linux 端一致。
- **T3.10** 刷新策略：启动自检 + 后台队列（`Task`/`DispatchQueue`）采集 + 手动 + 定时；时钟用 `Timer` 独立刷新。
- **T3.11** 错误/降级展示同 Linux。
- **T3.12** 配置读取统一 `~/.config/w_dashboard/config.toml`；`.app` 打包说明。
- **验收**：契约测试全过；在 M2 Mac 上读真实配置正确展示；体验地道原生。

## M4 — 两端一致性核对与打磨

- **T4.1** 一致性核对：两端对同一组真实仓库/配置给出相同的 `state` 结论；两端均通过同一份测试向量。
- **T4.2** 信息架构/颜色语义/降级文案对齐。
- **T4.3** 错误路径走查：无网络、无 git、无 chezmoi、非法 tz、超大仓库列表性能。
- **T4.4** 顶层 README 收尾（安装、配置、两端构建与运行）。
- **验收**：两端结论一致且都过向量；常见异常均有可读降级；文档可让新机器从零跑起来。

## M5 — 刷新体验：仓库增量刷新

> 依据 [ADR-010](architecture/adr-010-incremental-repo-refresh.md) 与 [SDD §8.1](sdd.md)。
> 纯 UI 层调度改动：`collect_repo` / `collectRepo` 及 §7 的解析与派生规则一个字不改，**不新增也不修改任何测试向量**。

- **T5.1** 规格先行：写 ADR-010（为什么从"整批串行"改为"并发 + 增量"）、在 SDD §8 增加 §8.1 增量刷新契约（6 条规则）、§9 颜色语义补上"采集中=灰"。
- **T5.2** app-linux 实现（`src/main.rs`）：
  - channel 消息由 `Vec<RepoStatus>` 改为 `RepoUpdate { token, index, status }`，每采完一个即发送；
  - `spawn_collect_repos` 改为最多 `REPO_WORKERS = 4` 的 worker 线程池（`AtomicUsize` 抢任务）；
  - 新增 `RepoUi`（长期存在的 `VecModel<RepoRow>` + 代际 token + 未完成计数），`begin()` 种行、`apply()` 用 `set_row_data` 只重画一行；
  - 轮询 timer 一个 tick 内 `while try_recv` 消费全部到达的结果；
  - `.slint` 无需改动（徽标文案/颜色由 Rust 侧填入 `RepoRow`）。
- **T5.3** app-macos 实现（`AppState.swift` / `RepoListView.swift`）：
  - `refresh()` 先种 `repoStatuses` 并置 `pendingRepoIndices`，再按 4 并发的 `OperationQueue` 逐个采集；
  - `apply(status:at:token:)` 回主线程写单行、按 token 丢弃过期结果、最后一行落地才清 `refreshing`；
  - 行内 pending 时显示灰色 `Checking…` 徽标。
- **T5.4** 一致性核对：两端对照 SDD §8.1 的 6 条规则逐条走查（并发上限、行序稳定、种子行、采集中徽标、代际 token、收尾语义）。
- **验收**：
  - 点刷新后**第一个**仓库的结果立即出现，不再等全部采完；
  - 多仓库场景总耗时明显下降（开 `fetch_remote` 时约为原来的 1/4）；
  - 一个卡到 `command_timeout_secs` 的仓库只让**自己那一行**停在"采集中"，其余行照常更新；
  - 手动刷新与定时刷新叠加时，旧一轮结果不覆盖新一轮；
  - 刷新期间行序始终等于配置顺序；
  - 两端各自的既有测试仍全过（`cargo test` / `swift test`），测试向量无改动。

## M6 — 仓库同步操作：Pull / Push / Fetch 按钮

> 依据 [ADR-011](architecture/adr-011-explicit-safe-git-actions.md) 与 [SDD §7.5](sdd.md)。
> 从"纯只读"放开到三个**显式的安全同步操作**；`allowed_actions`（状态→按钮显隐）是纯函数、进测试向量，
> 三个操作本身有副作用、走网络，只做 e2e 冒烟。§7.1/§7.2 的采集与派生规则一个字不改。

- **T6.1** 规格先行：写 ADR-011；SDD §6 加 `allowed_actions` / `run_repo_action` / `GitActionResult`，§7 新增 §7.5（命令 + 显隐表 + 执行语义），§8.1 补"操作后定向单行重采"，§9 Repos 补操作按钮，§10.2 加 `repo-actions/` 类别，§12 非目标条目改为精确表述；同步 `AGENTS.md` 核心约束 #4 与 `.cursor/rules/ui-no-logic.mdc`。
- **T6.2** 测试向量：`docs/test-vectors/repo-actions/` 覆盖 §7.5 显隐表 7 个状态（`clean` / `needs-pull` / `needs-push` / `diverged` / `dirty` / `no-upstream` / `error`），格式 `{ "input": "<RepoState>", "expected": { "pull": bool, "push": bool, "fetch": bool } }`。两端契约测试各加一个 `repo-actions` 用例。
- **T6.3** app-linux 实现：
  - `src/git.rs`：`RepoAction` 枚举、`GitActionResult`、纯函数 `allowed_actions(RepoState)`、副作用函数 `run_repo_action(&RepoConfig, RepoAction, Duration)`（`pull --ff-only` / `push` / `fetch --quiet`，复用 `run_git` 封装）。
  - `ui/app-window.slint`：`RepoRow` 加 `can_pull` / `can_push` / `can_fetch` / `action_busy` / `action_note` / `action_ok`；窗口加 `auto_fetch` 属性（Fetch 按钮显隐条件 `can_fetch && !auto_fetch`）；repo 卡片加按钮行 + 结果文本；新增 `callback repo_action(string, string)`。
  - `src/main.rs`：`repo_row_from_status` 填 `can_*`（调 `git::allowed_actions`）；`start_repo_refresh` 每次 `ui.set_auto_fetch(cfg.fetch_remote)`；新增 `mpsc` 通道 `RepoActionUpdate { path, result, status }`；`on_repo_action` 标记该行 busy → 后台线程跑 `run_repo_action` 然后 `collect_repo` → 回主线程按 `path` 定位并回填该行 + 写 `action_note`；操作按钮在 `refreshing` 或该行 `action_busy` 时禁用。
  - `tests/vectors.rs` 加 `repo_actions_vectors`；`tests/` 加一个 e2e 冒烟（临时 bare remote + 克隆，制造 behind/ahead，跑 Pull/Push）。
- **T6.4** app-macos 实现（对齐同一套语义）：
  - `Sources/WDashboardCore/Git.swift`：`RepoAction`、`GitActionResult`、`allowedActions(_:)`、`runRepoAction(repo:action:timeout:)`。
  - `Sources/WDashboardApp/AppState.swift`：`repoAction(path:action:)` — 用 `repoQueue` 跑操作 + 重采，主线程按 `path` 回填行；`Set<String>` 记 busy 行、`[String:GitActionResult]` 记结果。
  - `Sources/WDashboardApp/RepoListView.swift`：按 `allowedActions(repo.state)` 显示按钮（Fetch 额外要求 `!appState.config.fetchRemote`），busy / refreshing 时禁用，行内显示结果。
  - `Tests/WDashboardCoreTests/VectorTests.swift` 加 `testRepoActionsVectors`；加一个 e2e 冒烟。
- **T6.5** 一致性核对：两端对照 §7.5 逐条走查——显隐表 7 行、三个命令、执行语义 7 条（后台执行 / 仅限允许 / 操作后重采该行 / 结果提示与清除时机 / 失败降级 / 与整体刷新的关系 / Fetch 按钮渲染条件）。
- **验收**：
  - `NeedsPull` 仓库点 Pull 后，该行自动变为 `Clean`，行内显示 `Fast-forwarded …`；
  - `NeedsPush` 仓库点 Push 后变为 `Clean`；
  - 默认 `fetch_remote == true` 时不出现 Fetch 按钮（刷新已自动 fetch）；设 `fetch_remote = false` 后，除 `Error` 外每行出现 Fetch 按钮；
  - `Diverged` / `Dirty` / `NoUpstream` 不显示 Pull / Push；`Error` 无任何按钮；
  - `pull --ff-only` 在不能快进时干净失败，工作区与 HEAD 不变，行内显示 stderr 首行；
  - 操作期间该行按钮禁用、显示进行中文案；操作只影响该行，其余行照常；
  - 两端 `repo-actions` 向量全过，既有 `cargo test` / `swift test` 全过，向量除新增 `repo-actions/` 外无改动。

## M7 — 单行手动刷新按钮

> 依据 [ADR-010 后续](architecture/adr-010-incremental-repo-refresh.md) 与 [SDD §8、§8.1](sdd.md)。
> 纯 UI 层：复用 §7.5 已建立的"定向单行采集"通道，不动采集/派生规则，不改测试向量。

- **T7.1** 规格先行：ADR-010 加"后续（单行手动刷新）"一节；SDD §8 拆出"手动刷新（整体/单行）"两条、§8.1 末尾把"操作后重采该行"扩写为通用的"定向单行采集"（两种触发场景 + 共同语义）、§9 Repos 补单行刷新按钮。
- **T7.2** app-linux 实现：
  - `ui/app-window.slint`：`RepoRow` 加 `row_refreshing: bool`；新增 `callback repo_refresh(string)`；repo 卡片按钮行加一个小的**图标按钮**（`ui/icons/refresh.svg`，双箭头循环图标，`colorize` 跟随文字色；任何状态可用，含 `Error`），`row_refreshing` / `action_busy` / `refreshing` 时禁用、刷新中图标半透明。
  - `src/main.rs`：`RepoActionUpdate.result` 改 `Option<GitActionResult>`（`None` = 单行刷新）；`on_repo_refresh` 标记该行 `row_refreshing` → 后台线程 `collect_repo`（传当前 `fetch_remote`）→ 复用 `action_tx` 回填该行、清空 `action_note`；`repo_row_from_status` / `seeded_row` 处理新字段。
- **T7.3** app-macos 实现（对齐同一套语义）：
  - `Sources/WDashboardApp/AppState.swift`：`Set<String> repoRowRefreshingPaths`；`refreshRepoRow(path:)` 用 `repoQueue` 跑 `collectRepo`（传 `config.fetchRemote`），主线程按 `path` 回填、清 `repoActionResults[path]`；整体 `refresh()` 一并清空该集合。
  - `Sources/WDashboardApp/RepoListView.swift`：每行加小的**图标按钮**（SF Symbol `arrow.triangle.2.circlepath`，`.borderless`；刷新中换成 `ProgressView` 转圈），`rowRefreshing` / `busy` / `refreshing` 时禁用；`Error` 行也显示。
- **T7.4** 一致性核对：两端对照 SDD §8.1"定向单行采集"共同语义逐条走查（不分配新 token / 同参数含 fetch / 采集期间该行按钮全禁用 / 清除上一次操作提示 / 不改 `refreshing` 但更新 `last_updated`）。
- **验收**：
  - 任一仓库行点小 Refresh 按钮，只有该行进入"Refreshing…"并在采完后回填，其余行、`refreshing` 状态、天气都不动；
  - 顶部大 Refresh 按钮行为不变（整体刷新）；
  - `Error` 行也能点单行 Refresh；
  - 单行刷新会清掉该行上一次的 Pull/Push/Fetch 结果提示；
  - 整体刷新进行中时该行所有按钮（含单行 Refresh）禁用；
  - 既有 `cargo test` / `swift test` 全过，测试向量无改动。

## M8 — 番茄钟：面板 + 闪烁托盘/菜单栏图标

> 依据 [ADR-012](architecture/adr-012-pomodoro-timer.md) 与 [SDD §11](sdd.md)。
> 移植自作者的网页版 `pomodoro-vue`。纯逻辑（`pomodoro_view` / `pomodoro_reduce`）是纯函数、进测试向量；
> 定时器 / 托盘图标 / 通知 / 声音是各端 UI 层副作用，只做人工走查。不碰 §7 任何采集与派生规则。

- **T8.1** 规格先行：写 ADR-012；SDD §1 概述补第 5 项，§4 加 `[pomodoro]` 段与校验规则，§5.6 加 `PomodoroPhase` / `PomodoroState` / `PomodoroView`，§6 加 `pomodoro_view` / `pomodoro_reduce` 签名，§9 把 Pomodoro 列为置顶分区 + 颜色语义，§10.2 加 `pomodoro/` 与 `pomodoro-transition/` 类别，新增 §11「番茄钟」（分层 / 派生规则 / 迁移规则含自动收工 / 时长冻结 / UI 职责含配置重载 / 非目标），§13 非目标补一条；同步 `AGENTS.md`「项目是什么」、`config.example.toml`、`.cursor/rules/ui-no-logic.mdc`、`CONTEXT.md` 术语。
- **T8.2** 测试向量：
  - `docs/test-vectors/pomodoro/`（10 个）：`{ "input": { "phase", "phase_started_at", "focus_secs", "break_secs", "now" }, "expected": { PomodoroView 全字段 } }`。覆盖 SDD §11.2 表每一行 + 临界（`elapsed == duration` 恰好）+ overtime + `Idle`（`phase_started_at: null`）。
  - `docs/test-vectors/pomodoro-transition/`（13 个）：`{ "input": { "state": { PomodoroState }, "event": "<PomodoroEvent>", "now" }, "expected": { PomodoroState } }`。覆盖 SDD §11.3 迁移表 7 条每一条 + `Tick` 恰好触发 `FocusEnded` / `BreakEnded` 的临界 + 自动收工阈值（规则 6）上下边界 + `Tick` 未到时不变。
  - 两端契约测试各加 `pomodoro` / `pomodoro_transition` 用例。
- **T8.3** app-linux 实现（✅ 已完成，除真机烟测）：
  - `src/pomodoro.rs`：`PomodoroPhase` / `PomodoroState` / `PomodoroView` / `PomodoroEvent`；纯函数 `pomodoro_view(&PomodoroState, i64)` 与 `pomodoro_reduce(PomodoroState, PomodoroEvent, i64)`。
  - `src/config.rs`：`PomodoroConfig` + `[pomodoro]` 段解析（`enabled` / `focus_minutes` / `break_minutes` / `notify` / `sound`，默认 25/5/true/true，`<= 0` 报错）。
  - `ui/app-window.slint`：置顶分区卡片（phase 标签 / 剩余 `mm:ss` / 进度条 / 三个按钮）；窗口加 `pomodoro_*` 属性 + `window_title` + `callback pomodoro_event(string)`；`pomodoro_enabled == false` 时整卡隐藏。
  - `src/main.rs`：内存持有 `PomodoroState`；1 秒 `slint::Timer` 跑 `Tick` + 重渲染；进入 `FocusEnded` 边沿触发通知 + 提示音（`notify-send` / `canberra-gtk-play`·`paplay` 子进程），进入 `BreakEnded` 边沿只触发通知（不响），失败静默；`[pomodoro]` 启动时读一次（v1 无热重载）；`window_title` 加 `⏰` 前缀作无托盘兜底。
  - `src/tray.rs`：`ksni`（`cfg(target_os = "linux")` target 依赖，`blocking` feature，纯 Rust/zbus，非 Linux 为 stub）起 StatusNotifierItem，按 phase 换 ARGB32 色块图标（`*Ended` 用独立线程 ~1.5Hz 闪烁），右键菜单项回投 `PomodoroEvent` 走 `mpsc` + 250ms 轮询 `slint::Timer`；无 `StatusNotifierWatcher` 时 `spawn` 返回 `None` → 仅 `⏰` 标题兜底。
  - `tests/vectors.rs` 加 `pomodoro_view_vectors` / `pomodoro_transition_vectors`；`tests/config_pomodoro.rs`（5 例）。
- **T8.4** app-macos 实现（✅ 已完成）：
  - `Sources/WDashboardCore/Pomodoro.swift`：`PomodoroPhase` / `PomodoroState` / `PomodoroView` / `PomodoroEvent`；`pomodoroView(_:now:)` 与 `pomodoroReduce(_:_:now:)`。
  - `Sources/WDashboardCore/Config.swift` + `TOML.swift`：`PomodoroConfig` + `[pomodoro]` 段解析（同规格）。
  - `Sources/WDashboardApp/PomodoroPanelView.swift`：置顶分区 SwiftUI 视图（名为 `PomodoroPanelView`，避开与 core `PomodoroView` 同名）；`AppState.swift` 持有 `PomodoroState` + `Task` 每秒 `Tick`，`@Published pomodoro: PomodoroView` 供渲染；进入 `FocusEnded` 边沿 `osascript display notification` + `NSSound(named:"Glass")`，进入 `BreakEnded` 边沿只通知；`[pomodoro]` 启动时读一次。
  - `Sources/WDashboardApp/AppDelegate.swift`：`StatusItemController` 按 phase 切 `button.image`（`timer` SF Symbol；`*Ended` `paletteColors` 红/橙非模板 + `Timer` ~0.65s 闪烁），进入 `*Ended` `NSApp.requestUserAttention(.criticalRequest)`，离开时 `cancelUserAttentionRequest`；`WDashboardApp.swift` 用 `appState.onPomodoroPhaseChange` 接线。
  - `Tests/WDashboardCoreTests/VectorTests.swift` 加 `testPomodoroViewVectors` / `testPomodoroTransitionVectors`；`ConfigPomodoroTests.swift`（5 例）。
- **T8.5** 一致性核对：两端对照 SDD §11 逐条走查——§11.2 派生表 5 行、§11.3 迁移表 7 条（含自动收工）+ 时长冻结、§11.4 UI 职责 7 条（1s tick / 面板 / 托盘状态机 4 态 / 边沿触发：FocusEnded 三样 & BreakEnded 无声 / 确认或自动收工停止提醒 / 无 SNI 兜底 / 无热重载）。
- **验收**：
  - 点「开始专注」后剩余时间每秒递减，进度条推进；到 0 进入 `FocusEnded`——托盘/菜单栏图标开始红色闪烁、弹一条系统通知、响一次提示音；
  - `FocusEnded` 状态一直闪，直到点「开始休息 / 开始专注 / 停止」之一才停；
  - 「开始休息」倒计时结束进入 `BreakEnded`，图标橙色闪烁、弹通知，但**不响提示音**；
  - `*Ended` 持续 30 分钟无人点 → 自动回到 `Idle`、停止闪烁（用向量覆盖；手动可改系统时钟验证）；
  - `pomodoro.enabled = false` 时面板与托盘状态都不出现（改配置后重启生效，v1 无热重载）；
  - `focus_minutes` / `break_minutes` 改动重启后生效；`pomodoro_reduce` 的时长冻结由向量锁定；
  - `notify = false` 关掉通知、`sound = false` 关掉提示音，闪图标都不受影响；
  - 应用重启后回到 `Idle`（状态不持久化）；
  - Linux 无 SNI host 时改为面板横幅 + 窗口标题 `⏰` 前缀；
  - 两端 `pomodoro` / `pomodoro-transition` 向量全过，既有 `cargo test` / `swift test` 全过，其余向量无改动。

---

## 验收基线（贯穿所有里程碑）

- **测试向量是一致性的权威闸门**：两端的解析与派生（git porcelain、RepoState、chezmoi status、weather JSON、WMO 映射）都必须通过 `docs/test-vectors/` 中的同一份用例。
- 任何影响行为的变更：**先改 SDD 与测试向量，再让两端各自同步实现**（见 ADR-008）。
- 任何单项数据源失败都不得导致整体崩溃或空白。
- 所有联网与子进程调用均有超时与降级。
- 两端在相同配置下对同一仓库/配置给出一致的状态结论。

## 当前阶段不做（与 SDD §13 一致）

后端/服务端、跨机汇总、Web 端、历史/告警、多用户/鉴权、共享二进制 core / FFI。
git 写操作只做 `pull --ff-only` / `push` / `fetch` 三个显式安全操作（M6、ADR-011）；不做 commit / merge / rebase / 冲突解决 / stash 等。
番茄钟只做久坐提醒（M8、ADR-012）；不做长休息 / 统计 / 跨重启恢复 / 任务清单 / 多计时器。
