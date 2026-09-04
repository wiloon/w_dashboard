# w_dashboard

一个纯本地原生桌面应用，在每台主机上独立运行，展示本机的 git / chezmoi / 时间 / 天气状态，
并内置一个常驻桌面小工具（番茄钟）。本文件是**术语表**——只定义词，不写实现。

概念的"为什么这么定"见 `docs/architecture/`（ADR）；"做成什么样"见 `docs/sdd.md`。

## Language

### 总体

**采集层**：
每端内部产出结构化数据的那一层——读配置、调 `git`/`chezmoi` 子进程、拉天气、跑派生规则。与 UI 层解耦。
_Avoid_: 数据层, backend, service

**UI 层**：
每端内部负责渲染、后台线程/队列调度、定时/手动触发刷新、本地化展示的那一层。不含业务判定逻辑。

**Snapshot**（`DashboardSnapshot`）：
一次刷新采到的本机全部数据（各仓库状态 + chezmoi + 天气 + 时钟配置）。是可序列化结构。
_Avoid_: dump, report

**Test vector（测试向量）**：
`docs/test-vectors/` 下一条 `{ input, expected }` 纯数据记录。两端各自的测试都读同一份、必须得到同一结果——是两端一致性的客观闸门。
_Avoid_: fixture, 用例

**Derive（派生）**：
把原始采集字段按 SDD 的决策表算成一个面向用户的结论（如 `RepoState`）。派生规则必须是纯函数。

### Git 面板

**Watched repo（关注的仓库）**：
配置里 `[[repos]]` 显式声明路径、由应用跟踪同步状态的一个 git 工作区。
_Avoid_: project, tracked repo

**RepoState**：
一个关注仓库的**单一汇总状态标签**：`Clean` / `Dirty` / `NeedsPush` / `NeedsPull` / `Diverged` / `NoUpstream` / `Error`。取"最该先处理的一项"。ahead/behind 与文件计数始终完整保留，供 UI 展开。
_Avoid_: status（"status" 指原始字段集，"state" 指汇总标签）

**Safe sync action（安全同步操作）**：
面板允许的三个显式 git 写操作之一：`pull --ff-only` / `push` / `fetch`。定义特征是**不可能让仓库进入需要人工善后的状态**。commit / merge / rebase / 冲突解决 / stash 明确不做。
_Avoid_: git 操作, git command

**Incremental refresh（增量刷新）**：
一次整体刷新里，每采完一个仓库就更新那一行，而不是等全部采完再整体替换。

**定向单行采集**：
只重采一个仓库行、回填该行，不触发整屏刷新、不分配新代际 token。由"操作后自动重采"和"单行刷新按钮"两种场景触发。

### 番茄钟

**Pomodoro（番茄钟）**：
内置的久坐提醒工具——专注一段、休息一段，时段结束时闪烁托盘/菜单栏图标做强提醒。**不是**任务清单、不是番茄工作法统计、不计数。
_Avoid_: timer, 计时器（"计时器" 指实现里的 tick 定时器，不是这个功能）

**Focus（专注）** / **Break（休息）**：
番茄钟的两种计时时段。专注默认 25 分钟、休息默认 5 分钟。
_Avoid_: work/rest, session, 'L'/'S'（pomodoro-vue 的旧叫法）

**Phase**：
番茄钟当前处于 `Idle` / `Focus` / `Break` / `FocusEnded` / `BreakEnded` 五者之一。

**超时提醒态（`*Ended`）**：
`FocusEnded` 或 `BreakEnded`：时段时间已到、正等用户处理。此态下托盘图标闪烁（专注红、休息橙）。
_Avoid_: overtime, 结束态, done

**Acknowledge（确认）**：
用户按番茄钟任一按钮（开始专注 / 开始休息 / 停止），使番茄钟离开超时提醒态。没有独立的"确认"事件，按钮本身就是确认。

**自动收工**：
超时提醒态持续 30 分钟仍无人确认时，番茄钟自己回到 `Idle`（视为人已离开）。等效于用户按了停止。

**时长冻结**：
一个时段一旦开始，它的目标时长就定死了；中途改配置里的 `focus_minutes` / `break_minutes` 只从下一次回到 `Idle` 之后生效。
