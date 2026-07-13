# AGENTS.md — w_dashboard AI 协作指南

> 本文件供任何 AI 编码助手在本仓库工作时阅读。**动手写代码前，先读完本文件与 `docs/`。**
> 与人类协作时请用简体中文回复。

## 项目是什么

w_dashboard 是一个**纯本地原生桌面应用**，在每台主机上独立运行，只展示**本机**的状态：

1. Git 仓库同步状态（未提交 / 未 push / 需 pull / 分叉）
2. chezmoi 配置同步状态
3. 多时区时间
4. 天气（Open-Meteo）

两个目标平台各自用最地道的原生技术实现：**Linux**（Rust + Slint）与 **macOS**（Swift + SwiftUI）。
**两端不共享代码、不使用 FFI**；靠同一份规格 + 测试向量保证行为一致。

## 工作模式：规格驱动 + AI 生成（最重要）

本项目以**规格为单一事实来源（SSOT）**，代码是规格的可再生产物（见 ADR-008、ADR-002）：

- **改代码前先读规格**；**涉及行为的变更，先改规格（ADR/SDD）+ 测试向量，再让两端各自同步实现**。
- 两端（`app-linux` / `app-macos`）是两套独立实现，**禁止在它们之间共享二进制/库或引入 FFI**。
- 一致性的权威闸门是 `docs/test-vectors/`：两端的解析与派生逻辑都必须通过同一份用例。

## 必读文档（事实来源）

| 文档 | 内容 |
|------|------|
| `docs/architecture/` | 架构决策记录（ADR），解释"为什么这么定" |
| `docs/sdd.md` | 软件设计文档，定义"做成什么样"（数据模型 / 逻辑接口 / 派生规则 / 测试向量） |
| `docs/task-spec.md` | 实现任务拆解，定义"按什么顺序做"与验收标准 |
| `docs/test-vectors/` | 语言无关的行为契约，两端测试共享 |

**冲突时以 ADR 为准。** 若实现需要偏离 ADR/SDD，先更新对应文档（含理由），再改代码——不要让代码与文档悄悄分叉。

## 核心约束（最容易被违反，务必遵守）

1. **不引入后端 / 数据库 / 网络服务**（天气直接调公网 API 除外）。见 ADR-001。"上报到服务端"是未来演进，当前不做。
2. **规格是唯一事实来源**：git/chezmoi/天气/配置的逻辑由 SDD 定义；两端各自实现，**不得**让任一端的代码成为另一端的"真相"。见 ADR-002/008。
3. **两端一致靠测试向量**：解析与派生（git porcelain、`RepoState`、chezmoi status、weather JSON、WMO 映射）必须通过 `docs/test-vectors/` 的同一份用例。改了行为就要改向量。
4. **只读，不写**：本应用**不替用户执行** git commit/push/pull 或 chezmoi apply。仅采集与展示状态。
5. **git/chezmoi 通过子进程调用**（复用用户凭据），不用 `git2`/`gix`。优先 `--porcelain` 等机器可读格式。见 ADR-003。
6. **单项失败不拖垮整体**：`collect_snapshot` 永远返回快照，失败信息落到对应字段的 `error`，UI 局部降级。
7. **采集层与 UI 分层**：每端内部把"采集逻辑"与"UI"解耦；异步/线程调度归 UI 层（Rust 后台线程、Swift `Task`/`DispatchQueue`）。

## 仓库结构

```
app-linux/            # Rust + Slint：完整独立实现
app-macos/            # Swift + SwiftUI：完整独立实现
docs/                 # ADR / SDD / task-spec / test-vectors
config.example.toml   # 配置模板（两端共用同一格式）
```

配置路径（两端一致）：`$XDG_CONFIG_HOME/w_dashboard/config.toml`，回退 `~/.config/w_dashboard/config.toml`。

## 工作约定

- **实现顺序**：先做规格与测试向量（M0–M1），再让两端各自实现（M2/M3，可并行），最后一致性打磨（M4）。见 task-spec 里程碑。
- **测试**：两端的解析与状态派生必须用 `docs/test-vectors/` 跑契约测试；真实联网/调命令只做少量 e2e 冒烟。
- **行为变更流程**：改 SDD（§5 模型 / §7 派生规则）→ 改 `docs/test-vectors/` → 两端各自同步实现并跑通向量。
- **联网与子进程调用**：一律设超时与失败降级，不得无限阻塞 UI。
- 不要新增"非目标"功能（见 SDD §12）：跨机汇总、Web 端、历史/告警、多用户/鉴权、共享 core/FFI。
