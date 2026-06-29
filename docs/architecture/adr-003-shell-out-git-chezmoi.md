# ADR-003: 状态采集——调用 git / chezmoi 命令行

## Status

Accepted

## Context

**问题**：应用需要判断每个仓库的同步状态（未提交、未 push、需 pull、分叉），以及 chezmoi 配置的同步状态。
判断"远程是否领先"需要先从远程获取最新引用（fetch），而 fetch 私有仓库依赖用户已配置的认证凭据。

**约束**：
- 用户机器上已安装并配置好 `git`（含凭据 helper、SSH key、HTTPS token 等）和 `chezmoi`。
- 两端实现语言（Linux 用 Rust、macOS 用 Swift）都可选纯库实现（如 Rust 的 `git2`/`gix`）或调用外部命令。

## Options Considered

| 方案 | Pros | Cons | 复杂度 | 何时合适 |
|------|------|------|--------|----------|
| A. shell out 调用 `git` / `chezmoi` | 复用用户现有配置与凭据；行为与命令行完全一致；解析 porcelain 输出稳定 | 依赖外部可执行文件存在；需解析文本输出 | 低 | 需要复用用户认证与配置时 |
| B. 纯 Rust 库（`git2`/`gix`） | 无外部进程依赖 | 认证体系需自行对接（凭据 helper/SSH agent 难复用）；无法覆盖 chezmoi | 高 | 不需要复用用户凭据时 |

## Decision

**选择方案 A**：两端均通过子进程调用 `git` 与 `chezmoi`，解析其稳定输出（优先使用 `--porcelain` 等机器可读格式）。具体的解析与状态派生规则由规格统一定义（见 SDD §7/§10），两端各自实现并以同一份测试向量校验一致。

关键流程：
- **git 状态**：`git fetch`（可控开关）→ 用 `git rev-list --left-right --count @{upstream}...HEAD` 取 ahead/behind → `git status --porcelain=v2 --branch` 取工作区脏状态与分支信息。
- **chezmoi 状态**：`chezmoi status`（本机 home 与源状态的差异）+ 将 chezmoi 源目录视为一个 git 仓库，复用上面的 git 状态逻辑判断"未提交/未 push/需 pull"。

## Rationale

1. fetch 私有仓库必须复用用户既有凭据，shell out 天然继承用户环境，方案 B 要重建整套认证体系，成本与风险都高。
2. chezmoi 没有 Rust 库等价物，只能调命令行；git 也用命令行可保持采集方式统一。
3. porcelain 输出是为脚本设计的稳定契约，解析可靠。

## Trade-offs

- 运行时依赖宿主机存在 `git`（以及启用 chezmoi 时的 `chezmoi`）可执行文件。
- 需要处理子进程的错误、超时与文本解析。

## Consequences

- **Positive**：认证零配置（继承用户环境）；行为与用户手动执行命令一致；实现简单。
- **Negative**：缺少可执行文件或版本差异可能导致失败；`git fetch` 涉及网络，可能慢或失败。
- **Mitigation**：
  - 启动时探测 `git`/`chezmoi` 是否存在并给出明确提示。
  - 每个子进程调用设置超时；fetch 失败不影响展示本地已知信息，并在该仓库上标记 fetch 错误与"上次成功 fetch 时间"。
  - 解析锁定到 `--porcelain` 稳定格式，避免依赖人类可读输出。

## Revisit Trigger

- 子进程方式在性能或可靠性上出现明显瓶颈（如仓库数量极多时的 fetch 开销）。
- 出现需要而命令行无法满足的能力。
