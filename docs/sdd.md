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

allowed_actions(state: RepoState) -> { pull: bool, push: bool, fetch: bool }
    纯函数：给定仓库汇总状态，返回该显示哪些操作按钮（见 §7.5）。
    由 repo-actions 测试向量锁定（§10）。

run_repo_action(repo: RepoConfig, action: RepoAction) -> GitActionResult
    执行一个显式的安全同步操作（见 §7.5、ADR-011）。RepoAction ∈ { Pull, Push, Fetch }。
    有副作用、走网络；永不 panic，失败收敛进 GitActionResult.error。
    RepoAction 取值 UI 层不得越界（只在 allowed_actions 允许时调用）。
```

`GitActionResult`：`{ action: RepoAction, ok: bool, summary: string, error: string? }`
（`summary` 为面向用户的一行结果，如 `Fast-forwarded to <short-sha>` / `Everything up-to-date`；失败时 `error` 为 git stderr 首行）。

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

### 7.5 仓库同步操作（写，见 ADR-011）

面板在只读展示之外，提供三个**显式的安全同步操作**。它们都不可能让仓库进入需要人工善后的状态：`pull` 只允许快进，`push` 只在本地纯领先时提供，`fetch` 完全不碰工作区。**明确不做** commit / 非 ff 的 merge / rebase / 冲突解决 / stash / `push --force` / 分支切换 / 任何交互式操作。

#### 命令（均带超时，超时值取 `general.command_timeout_secs`）

| RepoAction | 命令 | 说明 |
|------------|------|------|
| `Pull` | `git -C <path> pull --ff-only` | 只能快进；不能快进时**不改动任何东西**直接非零退出 |
| `Push` | `git -C <path> push` | 推送当前分支到其 upstream；被拒时干净失败，不动本地 |
| `Fetch` | `git -C <path> fetch --quiet` | 只更新远程跟踪引用 |

#### 按钮显隐规则（`allowed_actions`，纯函数，按 `RepoState` 决定）

| RepoState | pull | push | fetch | 理由 |
|-----------|:----:|:----:|:-----:|------|
| `Clean` | ✗ | ✗ | ✓ | 无差距，只保留手动 fetch |
| `NeedsPull` | ✓ | ✗ | ✓ | `behind>0` 且 `ahead==0` → 一定能 ff |
| `NeedsPush` | ✗ | ✓ | ✓ | `ahead>0` 且 `behind==0` → 一定能 push |
| `Diverged` | ✗ | ✗ | ✓ | ahead 与 behind 同时 >0，需用户自行决定 rebase/merge |
| `Dirty` | ✗ | ✗ | ✓ | 先处理未提交改动 |
| `NoUpstream` | ✗ | ✗ | ✓ | 无 upstream，pull/push 无目标 |
| `Error` | ✗ | ✗ | ✗ | 连是不是 git 工作区都没确认 |

> 该表由 `docs/test-vectors/repo-actions/` 锁定（§10.2），两端按钮显隐必须一致。

> **Fetch 按钮的额外条件**：`allowed_actions.fetch` 表示"该状态下 fetch 是安全操作"，但 **Fetch 按钮仅在 `general.fetch_remote == false` 时才渲染**。`fetch_remote == true`（默认）时，每次刷新（启动 / 手动 / 定时 / 增删改仓库）已按 §7.1 对每个仓库自动 `git fetch --quiet`，独立的手动 Fetch 按钮是冗余的。此条件依赖全局配置而非 `RepoState`，属 UI 渲染规则（见下方执行语义 7），不进测试向量。Pull / Push 按钮不受 `fetch_remote` 影响。

#### 执行语义（UI 层，两端一致）

1. **后台执行**：操作在后台线程/队列跑，不阻塞 UI；执行期间该行的操作按钮禁用，显示进行中文案（`Pulling…` / `Pushing…` / `Fetching…`）。
2. **仅限允许的操作**：UI 只在 `allowed_actions` 为该状态放行时才发起对应操作。
3. **操作后重采该行**：操作结束后，立即对该仓库重新执行一次 §7.1/§7.2 采集，用结果刷新该行的状态徽标与计数。
4. **结果提示**：该行显示一行简短结果——成功用 `GitActionResult.summary`，失败用 `error`（git stderr 首行）。此提示在**下一次整体刷新**（Refresh 按钮 / 定时 / 增删改仓库）时清除；操作后的定向重采不清除它。
5. **失败降级**：操作失败只影响该行（延续 §2）；`pull --ff-only` / `push` 失败均无本地副作用，用户可据提示自行到终端处理。网络超时后 push 可能已在远端部分完成，此时步骤 3 的重采会显示真实状态。
6. **与整体刷新的关系**：单行操作不改变 §8.1 的代际 token；正在整体刷新（`refreshing==true`）时，操作按钮一并禁用。
7. **Fetch 按钮的渲染条件**：仅当 `general.fetch_remote == false` 时渲染 Fetch 按钮（理由见上方显隐表下的说明）。两端在配置变化后（含启动、配置重载）都要同步这个条件。

## 8. 刷新策略（UI 负责）

- **启动**：`check_environment` 给出 git/chezmoi 缺失提示 → 后台执行 `collect_snapshot` → 渲染。
- **手动刷新（整体）**：界面提供刷新按钮，重采全部仓库 + 天气。
- **手动刷新（单行）**：每个仓库行提供一个小的刷新按钮，只重采该行——用户明确知道自己动过哪个仓库时，不必为一个仓库触发整屏刷新。语义见 §8.1 末尾的"定向单行采集"。
- **后台定时**：按 `refresh_interval_secs` 周期触发（UI 计时器），`0` 则仅手动。
- **时钟**：UI 每秒/每分本地刷新，独立于快照采集。
- **耗时隔离**：所有采集在后台线程/队列执行，避免阻塞 UI；展示"上次刷新时间"与各仓库 `last_fetch_at`，让用户识别数据新鲜度。
- **增量更新**：仓库列表不等全部采集完再整体替换，而是**每采完一个仓库就更新那一行**，详见 §8.1。

### 8.1 仓库增量刷新契约（两端一致，见 ADR-010）

一次**整体**"刷新仓库"（启动 / 顶部手动按钮 / 定时 / 增删改仓库后）按下述语义执行。它是 **UI 层的调度策略**，不改变 §7.1/§7.2 的采集与派生结果，因此不在测试向量（§10）覆盖范围内，但两端必须实现同一套可观察行为：

| # | 规则 | 说明 |
|---|------|------|
| 1 | **并发上限 4** | 用最多 4 个并发单元采集（Linux：worker 线程池；macOS：`OperationQueue`）。上限同时约束线程数、并发 git 子进程数与同时对外的 fetch 连接数 |
| 2 | **行序稳定** | 刷新开始时先按**配置顺序**建好全部行，结果按行索引回填；行的顺序与完成先后无关 |
| 3 | **种子行** | 建行时沿用上一轮同 `path` 的数据（新增仓库用空占位），避免列表闪空；`name` 按最新配置刷新 |
| 4 | **"采集中"徽标** | 尚未出结果的行，状态徽标显示中性的"采集中"（灰，见 §9），不显示上一轮的旧状态结论 |
| 5 | **代际 token** | 每轮刷新分配自增 token，只接受携带当前 token 的结果；被新一轮取代的旧结果丢弃（手动与定时刷新叠加时不互相覆盖） |
| 6 | **收尾语义** | `refreshing`（按钮"刷新中"/禁用）持续到**最后一行**落地；`last_updated` 每落地一行更新一次；仓库列表为空时立即结束 |

单个仓库采集失败或超时，只影响它自己那一行（落为 `RepoState::Error` + `error`），其余行照常更新——即 §2"单项失败不拖垮整体"在时间维度上的延伸：**单项慢也不拖垮整体**。

天气采集独立于仓库刷新，各自降级，互不阻塞。

**定向单行采集**：以下两种场景都对**单个**仓库行执行一次"重采并回填该行"，而**不**触发整体刷新：

1. §7.5 的"操作后重采该行"——Pull / Push / Fetch 结束后自动重采。
2. §8 的"单行手动刷新按钮"——用户点该行的小刷新按钮时。

两者共同的语义：

- **不分配新代际 token**，直接按 `path` 定位并回填该行，其余行不受影响；被并行的整体刷新覆盖是允许的（整体刷新携带更新的 token，是更权威的结果）。
- 采集用与整体刷新相同的参数：`fetch_remote == true` 时该行也 `git fetch --quiet`（区别于 §7.5 步骤 3——那里 pull/push/fetch 已刷过 refs，故重采传 `fetch_remote=false`）。
- 采集期间该行的**所有**按钮（Pull / Push / Fetch / 单行刷新）禁用并显示进行中文案；正在整体刷新（`refreshing==true`）时这些按钮也一并禁用，二者不会并发写同一行。
- 单行手动刷新会**清除该行上一次的操作结果提示**（§7.5 步骤 4 的行内提示）——它是用户对该行状态的一次主动重置；§7.5 的自动重采则保留该提示。
- 单行采集**不**更新"整体刷新中"（`refreshing`）状态，但**会**更新 `last_updated`。

## 9. UI 设计要点（两端一致的信息架构）

四个分区，布局可各端适配：

1. **Repos**：列表/卡片，显示 name、branch、状态徽标（颜色区分 Clean/Dirty/NeedsPush/NeedsPull/Diverged/NoUpstream/Error），可展开看 ahead/behind 与文件计数；显示 `last_fetch_at`。每行按 §7.5 的 `allowed_actions` 显示 Pull / Push 按钮（Fetch 按钮仅在 `general.fetch_remote == false` 时显示，见 §7.5）：执行期间禁用并显示进行中文案，结束后自动重采该行并在行内显示一行结果（成功/失败），结果在下次整体刷新时清除。每行还有一个小的**单行刷新图标按钮**（双箭头循环图标；刷新中转圈/半透明），只重采该行（见 §8、§8.1 的"定向单行采集"），任何状态下都可用（含 `Error` 行）。
2. **chezmoi**：源仓库同步徽标 + 待应用差异列表；未启用则隐藏或灰显。
3. **Clocks**：每个配置时区一个时钟，实时更新。
4. **Weather**：当前天气 + 未来 N 日预报（图标来自 WMO code 映射）；失败显示降级文案与上次时间。

颜色语义（两端一致）：绿=Clean、黄=NeedsPush/NeedsPull/Dirty、红=Diverged/Error、灰=NoUpstream/未配置/采集中（§8.1）。

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
3. **repo-actions/**：`input` = 一个 `RepoState` 名（字符串）；`expected` = `{ pull, push, fetch }` 三个布尔。须覆盖 §7.5 显隐表每一行（7 个状态）。锁定两端操作按钮显隐一致。
4. **chezmoi-status/**：`input` = `chezmoi status` 文本；`expected` = `ChezmoiEntry[]`。
5. **weather-json/**：`input` = Open-Meteo `forecast` 返回 JSON（含正常、缺字段、空 daily 等用例）；`expected` = `WeatherReport`（含降级表现）。
6. **wmo-codes**：weather_code → 文案 的完整映射表（两端共同引用，避免文案分叉）。

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
- git 写操作只做三个显式的安全同步操作：`pull --ff-only` / `push` / `fetch`（见 §7.5、ADR-011）。**不做** commit / 非 ff 的 merge / rebase / 冲突解决 / stash / `push --force` / 分支切换 / 任何交互式操作——面板不是 git 客户端。
- 不做历史趋势、告警、通知中心。
- 不做多用户、不做鉴权。
- 不抽取共享二进制 core、不引入 FFI（见 ADR-002）。

## 13. 未来演进预留

`DashboardSnapshot` 是可序列化结构。若未来需要演进到"Agent 上报 + 中心查看"（ADR-001 方案 B），
只需在各端采集层之外各加一层上报模块，将快照序列化后 push 到服务端，**UI 与采集逻辑无需改动**。

若未来需要 OpenWeatherMap 的差异化能力（如分钟级降水临近预报，见 ADR-005 Revisit Trigger），天气采集可演进为可插拔的多提供方设计：`[weather]` 增加可选 `provider`（默认 `open-meteo`）与 `api_key`（仅 `openweathermap` 时需要）字段，`WeatherReport` 模型不变，各 provider 各自实现"拉取 + 解析为 WeatherReport"。**当前阶段（v1）不做此抽象**，只实现 Open-Meteo 一种数据源。
