# w_dashboard 软件设计文档（SDD）

> 本文档描述 w_dashboard 的系统设计。架构决策的理由见 [docs/architecture](architecture/)。
> 本文档定义"做成什么样"，task spec 定义"按什么顺序做"。
>
> **本文档是单一事实来源（见 ADR-008）。** Linux 与 macOS 两端独立用各自原生技术实现（见 ADR-002），
> 都必须忠实于本文档的数据模型、逻辑接口、派生规则，并通过同一份测试向量（§10）。

## 1. 概述

w_dashboard 是一个**纯本地原生桌面应用**，在每台主机上独立运行，只展示**本机**的：

1. **Git 仓库同步状态**——配置中关注的仓库是否有未提交改动、未 push 提交、需要 pull 的远程更新、或已分叉。
2. **chezmoi 配置同步状态**——本地 home 是否有未应用/未提交的配置，远程是否有需要拉回的配置。
3. **多时区时间**——北京、纽约及任意可配置时区的当前时间。
4. **天气**——当前与未来数日预报（数据源 Open-Meteo）。

无后端、无数据库、无网络服务（仅天气直接调用公网 API）。

## 2. 架构总览

不存在共享的二进制/库。两端是**两套完整、独立的原生实现**，由同一份规格驱动、由同一份测试向量约束一致。

```
                    ┌───────────────────────────────────────────┐
                    │                 规格（SSOT）               │
                    │   ADR + SDD（数据模型/接口/派生规则）       │
                    │   + docs/test-vectors/（行为契约）          │
                    └───────────────┬───────────────┬───────────┘
                       AI 依据规格生成 │               │ AI 依据规格生成
                    ┌──────────────▼─────┐     ┌─────▼──────────────┐
                    │     app-linux       │     │     app-macos       │
                    │    Rust + Slint     │     │   Swift + SwiftUI    │
                    │  ┌───────────────┐  │     │  ┌───────────────┐  │
                    │  │ config/git/   │  │     │  │ config/git/   │  │
                    │  │ chezmoi/      │  │     │  │ chezmoi/      │  │
                    │  │ weather/model │  │     │  │ weather/model │  │
                    │  ├───────────────┤  │     │  ├───────────────┤  │
                    │  │   UI 层       │  │     │  │   UI 层       │  │
                    │  └───────────────┘  │     │  └───────────────┘  │
                    └─────────┬───────────┘     └──────────┬──────────┘
                              │ 子进程 / HTTP              │ 子进程 / HTTP
                       git / chezmoi / Open-Meteo    git / chezmoi / Open-Meteo
```

- 每端内部都建议分为**采集层**（config/git/chezmoi/weather/model）与 **UI 层**，两层解耦。
- 两端各自用最地道的原生类型与库，不为跨语言一致而妥协（无 FFI、无跨语言构建链）。
- 一致性由 §7 的精确派生规则 + §10 的共享测试向量保证。

## 3. 仓库目录结构

```
w_dashboard/
├── docs/
│   ├── architecture/        # ADR
│   ├── sdd.md               # 本文档
│   ├── task-spec.md         # 实现任务拆解
│   └── test-vectors/        # 语言无关行为契约（JSON），两端测试共享，见 §10
│       ├── git-porcelain/   # porcelain 文本 → RepoStatus
│       ├── repo-state/      # 字段组合 → RepoState
│       ├── chezmoi-status/  # chezmoi status 文本 → ChezmoiEntry[]
│       └── weather-json/    # Open-Meteo JSON → WeatherReport
├── app-linux/               # Rust + Slint：完整独立实现
├── app-macos/               # Swift + SwiftUI：完整独立实现
└── config.example.toml      # 配置模板（两端共用同一格式）
```

各端内部模块划分由各端按语言习惯决定（如 Rust 的 mod、Swift 的文件/类型），但都应体现"采集层 / UI 层"的分层。

## 4. 配置 schema

路径：`$XDG_CONFIG_HOME/w_dashboard/config.toml`，回退 `~/.config/w_dashboard/config.toml`（两端一致，macOS 也用 `~/.config/`，见 ADR-004）。

```toml
[general]
# 后台自动刷新间隔（秒）。0 表示仅手动刷新。
refresh_interval_secs = 900
# 单个子进程调用超时（秒）
command_timeout_secs = 20
# 是否在刷新时执行 git fetch / chezmoi fetch（联网）
fetch_remote = true

# 关注的 git 仓库（显式声明绝对路径）
[[repos]]
path = "~/workspace/projects/foo"
# 可选：覆盖显示名，缺省取目录名
name = "foo"

[[repos]]
path = "~/dotfiles-extra"

[chezmoi]
enabled = true
# 可选：显式指定 chezmoi 源目录；缺省由 `chezmoi source-path` 自动探测
# source_path = "~/.local/share/chezmoi"

[[clocks]]
label = "北京"
tz = "Asia/Shanghai"

[[clocks]]
label = "纽约"
tz = "America/New_York"

[weather]
# 二选一：直接给经纬度，或给地点名（由应用通过 geocoding 解析）
location = "Beijing"
# latitude = 39.9042
# longitude = 116.4074
# 温度单位: "celsius" | "fahrenheit"
temperature_unit = "celsius"
# 预报天数
forecast_days = 5
```

配置加载规则（两端按同一规格实现）：
- 文件不存在时返回内置默认配置（空 repos、默认时钟北京/纽约、weather 未配置则天气面板显示"未配置"）。
- 字段缺失走默认值；非法值（如非法 tz id、缺少 location 与经纬度）返回带字段定位的明确错误，UI 展示为可读提示。
- `~` 与环境变量需统一展开。

## 5. 逻辑数据模型（语言无关）

下列类型是**逻辑模型**，两端各自用原生类型表达（Rust struct/enum、Swift struct/enum），字段名可按各语言命名习惯调整，但**语义、可空性、枚举取值必须一致**。

> 时间表示：在**测试向量与跨端约定**中统一用 Unix 秒（整数）；各端内部/展示可转换为原生类型（Swift `Date`、Rust `SystemTime`/`chrono`）并本地化。

### 5.1 DashboardSnapshot（一次刷新的全部数据）

| 字段 | 类型 | 说明 |
|------|------|------|
| `generated_at` | int(unix 秒) | 本次快照生成时间 |
| `repos` | `RepoStatus[]` | 各仓库状态 |
| `chezmoi` | `ChezmoiStatus?` | 未启用则空 |
| `weather` | `WeatherReport?` | 未配置/失败则空 |
| `weather_error` | `string?` | 天气失败信息 |
| `clocks` | `ClockConfig[]` | 透传配置，UI 负责渲染时间 |

### 5.2 RepoStatus

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | string | 显示名 |
| `path` | string | 仓库路径 |
| `branch` | `string?` | 当前分支；detached 时空 |
| `upstream` | `string?` | 远程跟踪分支；无则空 |
| `ahead` | int | 本地领先（未 push）提交数 |
| `behind` | int | 远程领先（需 pull）提交数 |
| `staged` | int | 暂存改动数 |
| `modified` | int | 已跟踪文件被修改/删除数 |
| `untracked` | int | 未跟踪文件数 |
| `conflicted` | int | 冲突文件数 |
| `state` | `RepoState` | 派生的汇总状态，见 §7.2 |
| `last_fetch_at` | `int?` | 上次成功 fetch 时间 |
| `error` | `string?` | 该仓库采集错误 |

`RepoState` 枚举取值：`Clean` / `Dirty` / `NeedsPush` / `NeedsPull` / `Diverged` / `NoUpstream` / `Error`。

### 5.3 ChezmoiStatus / ChezmoiEntry

| ChezmoiStatus 字段 | 类型 | 说明 |
|------|------|------|
| `source_path` | string | chezmoi 源目录 |
| `pending_changes` | `ChezmoiEntry[]` | home 与源状态存在差异的文件 |
| `source_repo` | `RepoStatus` | 源目录作为 git 仓库的同步状态（复用 §7 逻辑） |
| `error` | `string?` | 采集错误 |

| ChezmoiEntry 字段 | 类型 | 说明 |
|------|------|------|
| `path` | string | 文件路径 |
| `status` | string | chezmoi status 状态码原样透传（如 `M`/`A`/`D`） |

### 5.4 WeatherReport / WeatherNow / WeatherDay

| WeatherReport 字段 | 类型 | 说明 |
|------|------|------|
| `location_label` | string | 地点显示名 |
| `latitude` / `longitude` | float | 经纬度 |
| `fetched_at` | int(unix 秒) | 拉取时间 |
| `current` | `WeatherNow` | 当前天气 |
| `daily` | `WeatherDay[]` | 逐日预报 |
| `temperature_unit` | string | `celsius`/`fahrenheit` |

| WeatherNow 字段 | 类型 | 说明 |
|------|------|------|
| `temperature` | float | 当前温度 |
| `weather_code` | int | WMO code |
| `description` | string | 由 code 映射的文案 |

| WeatherDay 字段 | 类型 | 说明 |
|------|------|------|
| `date` | string | `YYYY-MM-DD` |
| `temp_max` / `temp_min` | float | 当日最高/最低温 |
| `weather_code` | int | WMO code |
| `description` | string | 文案 |
| `precipitation_probability_max` | `int?` | 最大降水概率 |

### 5.5 ClockConfig

| 字段 | 类型 | 说明 |
|------|------|------|
| `label` | string | 显示名（如"北京"） |
| `tz` | string | IANA tz id（如 `Asia/Shanghai`） |

### 5.6 两端类型示意（同一模型，各自原生）

```rust
// Rust（app-linux）
pub enum RepoState { Clean, Dirty, NeedsPush, NeedsPull, Diverged, NoUpstream, Error }

pub struct RepoStatus {
    pub name: String,
    pub branch: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub state: RepoState,
    // ... 其余字段同 §5.2
}
```

```swift
// Swift（app-macos）
enum RepoState { case clean, dirty, needsPush, needsPull, diverged, noUpstream, error }

struct RepoStatus {
    let name: String
    let branch: String?
    let ahead: Int
    let behind: Int
    let state: RepoState
    // ... 其余字段同 §5.2
}
```

## 6. 逻辑接口（两端各自实现，非跨语言调用）

下列是两端都需实现的**逻辑接口**，用语言无关签名描述。各端用原生语言实现对应函数/方法；**异步与线程调度由各端自行包装**（Rust 用后台线程，Swift 用 `Task`/`DispatchQueue`），不属于本接口的一部分。

```text
load_config(path?: string) -> Config | ConfigError
    加载并校验配置；文件缺失返回默认配置。

collect_snapshot(config: Config) -> DashboardSnapshot
    采集一次完整快照（git + chezmoi + weather）。
    永不整体失败：单项失败收敛进对应字段的 error / weather_error。

collect_repos(config: Config) -> RepoStatus[]
collect_chezmoi(config: Config) -> ChezmoiStatus?
fetch_weather(config: Config) -> WeatherReport | WeatherError
    可选的细粒度接口，供 UI 局部刷新。

check_environment() -> { git: string?, chezmoi: string? }
    探测 git/chezmoi 是否可用及版本，None/空 表示未找到。
```

错误分类（语义需一致，各端用原生错误类型表达）：`Config` / `Io` / `CommandNotFound` / `Network` / `Parse`。

总则：**单项失败不拖垮整体**。`collect_snapshot` 永远返回快照，失败信息落在对应字段，UI 局部降级。

## 7. 状态采集与派生规则

### 7.1 Git 采集流程

对每个仓库依次执行（均带超时）：

1. 校验是 git 工作区：`git -C <path> rev-parse --is-inside-work-tree`，否则 `error` 置原因、`state=Error`。
2. 若 `fetch_remote`：`git -C <path> fetch --quiet`（失败仅记 `error`，不中断，沿用上次 behind）。成功更新 `last_fetch_at`。
3. 分支与 ahead/behind：解析 `git -C <path> status --porcelain=v2 --branch` 的 `# branch.head` / `# branch.upstream` / `# branch.ab +A -B`；无 `# branch.upstream` 行则视为无 upstream。
4. 工作区统计：从 porcelain v2 条目计数 `staged` / `modified` / `untracked` / `conflicted`。
5. 按 §7.2 派生 `state`。

porcelain v2 计数规则（精确）：
- 行首 `1`/`2`（普通变更/重命名）：字段 `XY` 中 `X` 非 `.` 计入 `staged`；`Y` 非 `.` 计入 `modified`。
- 行首 `u`（unmerged）：计入 `conflicted`。
- 行首 `?`：计入 `untracked`。
- 行首 `!`（ignored）：不计入任何计数。

### 7.2 RepoState 派生（决策表，按序匹配，命中即止）

> `state` 是面向用户的**单一汇总标签**，取"最该先处理的一项"。ahead/behind 与各计数字段始终完整保留，供 UI 展开显示。

| 序 | 条件 | state |
|----|------|-------|
| 1 | `error` 非空 或 非 git 工作区 | `Error` |
| 2 | `conflicted+staged+modified+untracked > 0` | `Dirty` |
| 3 | 无 upstream | `NoUpstream` |
| 4 | `ahead>0` 且 `behind>0` | `Diverged` |
| 5 | `behind>0`（且 `ahead==0`） | `NeedsPull` |
| 6 | `ahead>0`（且 `behind==0`） | `NeedsPush` |
| 7 | 其余 | `Clean` |

设计理由：用户核心痛点是"出门前怕漏提交/漏推"，故**未提交改动（Dirty）优先级最高**（除采集错误外）——工作区未干净时，先提示提交，谈推拉意义不大。工作区干净后再依次看远程关系。该表无歧义，由 `repo-state` 测试向量锁定（§10）。

### 7.3 chezmoi 采集

仅当 `chezmoi.enabled`：
1. 探测源目录：配置给定则用之，否则 `chezmoi source-path`。
2. 待应用差异：解析 `chezmoi status`（每行：状态码 + 路径）为 `ChezmoiEntry[]`。
3. 源仓库同步：对源目录复用 §7.1/§7.2 的 git 逻辑，得到 `source_repo`，从而判断"未提交/未 push/需 pull 的配置"。
4. 任一步失败记入 `ChezmoiStatus.error`。

### 7.4 天气采集

1. 若配置为地点名，先调 geocoding API 解析经纬度（可内存缓存）。
2. 调 `forecast` API 取 `current` + `daily`，按 `temperature_unit` / `forecast_days` 组装 `WeatherReport`。
3. WMO weather code → 文案映射表（两端共享同一映射，见 §10）。
4. 网络/解析失败 → `Network`/`Parse` 错误，被 `collect_snapshot` 收敛到 `weather_error`。

## 8. 刷新策略（UI 负责）

- **启动**：`check_environment` 给出 git/chezmoi 缺失提示 → 后台执行 `collect_snapshot` → 渲染。
- **手动刷新**：界面提供刷新按钮。
- **后台定时**：按 `refresh_interval_secs` 周期触发（UI 计时器），`0` 则仅手动。
- **时钟**：UI 每秒/每分本地刷新，独立于快照采集。
- **耗时隔离**：所有采集在后台线程/队列执行，避免阻塞 UI；展示"上次刷新时间"与各仓库 `last_fetch_at`，让用户识别数据新鲜度。

## 9. UI 设计要点（两端一致的信息架构）

四个分区，布局可各端适配：

1. **Repos**：列表/卡片，显示 name、branch、状态徽标（颜色区分 Clean/Dirty/NeedsPush/NeedsPull/Diverged/NoUpstream/Error），可展开看 ahead/behind 与文件计数；显示 `last_fetch_at`。
2. **chezmoi**：源仓库同步徽标 + 待应用差异列表；未启用则隐藏或灰显。
3. **Clocks**：每个配置时区一个时钟，实时更新。
4. **Weather**：当前天气 + 未来 N 日预报（图标来自 WMO code 映射）；失败显示降级文案与上次时间。

颜色语义（两端一致）：绿=Clean、黄=NeedsPush/NeedsPull/Dirty、红=Diverged/Error、灰=NoUpstream/未配置。

## 10. 行为契约与测试向量（保证两端一致的核心机制）

由于两端是独立实现（ADR-002），一致性不靠"同一份编译产物"，而靠**共享的测试向量**：用纯数据定义一组 `输入 → 期望输出`，**两端各自的测试都读同一份向量、必须得到同一结果**。

### 10.1 分层与边界

把逻辑分为两层，测试向量只锁定确定性的纯函数层：

| 层 | 性质 | 测试手段 |
|----|------|----------|
| 采集（调命令、联网） | 有副作用、不确定 | 少量 e2e 冒烟（建临时 git 仓库跑通链路，不做严格比对） |
| 解析 + 派生（纯函数） | 确定（同输入必同输出） | **测试向量（权威一致性闸门）** + 各端单元测试 |

### 10.2 测试向量内容（`docs/test-vectors/`）

每个向量是一条 `{ input, expected }` 记录，按类别分目录：

1. **git-porcelain/**：`input` = 一段 `git status --porcelain=v2 --branch` 原始文本；`expected` = 解析出的 `RepoStatus`（branch/upstream/ahead/behind/各计数）。
2. **repo-state/**：`input` = 字段组合（ahead/behind/各计数/has_upstream/error）；`expected` = 派生的 `RepoState`。须覆盖 §7.2 决策表每一行及边界。
3. **chezmoi-status/**：`input` = `chezmoi status` 文本；`expected` = `ChezmoiEntry[]`。
4. **weather-json/**：`input` = Open-Meteo `forecast` 返回 JSON（含正常、缺字段、空 daily 等用例）；`expected` = `WeatherReport`（含降级表现）。
5. **wmo-codes**：weather_code → 文案 的完整映射表（两端共同引用，避免文案分叉）。

向量格式示例（`repo-state/diverged.json`）：

```json
{
  "input": { "ahead": 2, "behind": 3, "staged": 0, "modified": 0,
             "untracked": 0, "conflicted": 0, "has_upstream": true, "error": null },
  "expected": "Diverged"
}
```

### 10.3 一致性流程

- 任何影响行为的规格变更，**必须同步新增/更新测试向量**（见 ADR-008 工作流）。
- 两端 CI 都加载 `docs/test-vectors/` 并断言 `parse(input) == expected` / `derive(input) == expected`。
- 向量是两端一致性的**客观闸门**：两端只要都过向量，即视为行为一致。

## 11. 构建与分发

- **app-linux**：独立的 Rust 工程，`cargo build`（`build.rs` 编译 `.slint` 文件为生成代码）；产物为可执行文件，配 `.desktop` 入口。测试 `cargo test`（含加载共享测试向量）。
- **app-macos**：独立的 Swift/Xcode 工程；产物为 `.app`。测试用 XCTest（含加载同一份共享测试向量）。
- 两端**无任何跨语言构建步骤**（无交叉编译、无 FFI 绑定生成、无 XCFramework）。
- 改动数据模型或派生规则时：先改 SDD 与测试向量，再让两端各自同步实现（见 ADR-008）。

## 12. 非目标（当前阶段明确不做）

- 不做后端/服务端、不做跨机汇总、不做 Web 端（见 ADR-001 的 Revisit Trigger）。
- 不做 git 写操作（不代替用户 commit/push/pull）；仅只读展示状态。
- 不做历史趋势、告警、通知中心。
- 不做多用户、不做鉴权。
- 不抽取共享二进制 core、不引入 FFI（见 ADR-002）。

## 13. 未来演进预留

`DashboardSnapshot` 是可序列化结构。若未来需要演进到"Agent 上报 + 中心查看"（ADR-001 方案 B），
只需在各端采集层之外各加一层上报模块，将快照序列化后 push 到服务端，**UI 与采集逻辑无需改动**。

若未来需要 OpenWeatherMap 的差异化能力（如分钟级降水临近预报，见 ADR-005 Revisit Trigger），天气采集可演进为可插拔的多提供方设计：`[weather]` 增加可选 `provider`（默认 `open-meteo`）与 `api_key`（仅 `openweathermap` 时需要）字段，`WeatherReport` 模型不变，各 provider 各自实现"拉取 + 解析为 WeatherReport"。**当前阶段（v1）不做此抽象**，只实现 Open-Meteo 一种数据源。
