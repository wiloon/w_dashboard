# w_dashboard 实现任务拆解（Task Spec）

> 本文档把 [SDD](sdd.md) 拆解为可独立交付、可验收的任务，供分阶段实现（由 AI 依据规格生成各平台代码）。
>
> 顺序原则（见 ADR-002 / ADR-008）：**先把规格与测试向量做扎实，再让两端各自原生实现并行展开**；
> 每端内部先做"采集层并通过共享测试向量"，再做 UI。两端不共享代码，靠同一份测试向量保证一致。

## 里程碑总览

| 里程碑 | 目标 | 依赖 |
|--------|------|------|
| M0 | 脚手架与文档基线 | — |
| M1 | 行为契约 / 测试向量集（语言无关） | M0 |
| M2 | app-linux（Rust + Iced/libcosmic）完整实现 | M1 |
| M3 | app-macos（Swift + SwiftUI）完整实现 | M1 |
| M4 | 两端一致性核对与打磨 | M2, M3 |

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

## M2 — app-linux（Rust + Iced/libcosmic）

> 完整独立实现；不依赖任何共享 core。

### M2a 采集层

- **T2.1** 工程脚手架与依赖（serde、toml、reqwest(blocking) 或等价、serde_json、chrono/time 等）。
- **T2.2** 数据模型（SDD §5 全部类型，Rust 原生 struct/enum）。
- **T2.3** 配置加载（SDD §4：`~`/env 展开、默认值、字段校验、可读错误）。
- **T2.4** 子进程封装（cwd/参数/超时/捕获输出/区分"命令不存在"与"非零退出"）。
- **T2.5** git 采集与解析（SDD §7.1）+ `RepoState` 派生（§7.2）。
- **T2.6** chezmoi 采集（SDD §7.3）。
- **T2.7** 天气采集（SDD §7.4：geocoding + forecast + WMO 映射 + 降级）。
- **T2.8** `collect_snapshot` 聚合 + `check_environment`（单项失败不拖垮整体）。
- **测试**：**加载 `docs/test-vectors/` 跑契约测试**（porcelain/repo-state/chezmoi/weather 全过）；配置与子进程封装的单测；少量 e2e 冒烟（临时 git 仓库）。

### M2b UI

- **T2.9** 四分区 UI（Repos / chezmoi / Clocks / Weather），按 SDD §9 信息架构与颜色语义。
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

---

## 验收基线（贯穿所有里程碑）

- **测试向量是一致性的权威闸门**：两端的解析与派生（git porcelain、RepoState、chezmoi status、weather JSON、WMO 映射）都必须通过 `docs/test-vectors/` 中的同一份用例。
- 任何影响行为的变更：**先改 SDD 与测试向量，再让两端各自同步实现**（见 ADR-008）。
- 任何单项数据源失败都不得导致整体崩溃或空白。
- 所有联网与子进程调用均有超时与降级。
- 两端在相同配置下对同一仓库/配置给出一致的状态结论。

## 当前阶段不做（与 SDD §12 一致）

后端/服务端、跨机汇总、Web 端、git 写操作、历史/告警、多用户/鉴权、共享二进制 core / FFI。
