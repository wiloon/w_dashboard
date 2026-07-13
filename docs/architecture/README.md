# 架构决策记录（ADR）

本目录记录 w_dashboard 的关键架构决策。每个文件对应一个决策，遵循标准 ADR 格式：
Context（背景与约束）→ Options（候选方案）→ Decision（结论）→ Rationale（理由）→
Trade-offs（取舍）→ Consequences（后果与缓解）→ Revisit Trigger（重新评估的触发条件）。

## 索引

| ADR | 标题 | 状态 |
|-----|------|------|
| [ADR-001](adr-001-native-local-app.md) | 应用形态：纯原生本地应用，不做后端 | Accepted |
| [ADR-002](adr-002-spec-driven-native.md) | 代码复用：规格驱动、两端独立原生实现 | Accepted |
| [ADR-003](adr-003-shell-out-git-chezmoi.md) | 状态采集：调用 git / chezmoi 命令行 | Accepted |
| [ADR-004](adr-004-user-config.md) | 配置与仓库发现：用户级 TOML 显式声明 | Accepted |
| [ADR-005](adr-005-weather-open-meteo.md) | 天气数据源：Open-Meteo | Accepted |
| [ADR-006](adr-006-timezone-clocks.md) | 多时区时钟：基于 IANA 时区本地计算 | Accepted |
| [ADR-007](adr-007-build-custom-over-existing-tools.md) | 自建统一原生面板，而非复用 gita/mani 等现有工具 | Accepted |
| [ADR-008](adr-008-spec-as-source-of-truth.md) | 规格为单一事实来源，代码为可再生产物 | Accepted |
| [ADR-009](adr-009-linux-gui-slint.md) | Linux 端 GUI 框架：改用 Slint，弃用 Iced/libcosmic | Accepted |

## 设计总原则

> "Simplicity is the ultimate sophistication."

从简单开始，只在被证明必要时才增加复杂度。当前阶段刻意**不引入后端、数据库、网络服务**。
所有可能的扩展（如汇总多机、Web 查看）都留作未来选项，通过清晰的模块边界保证可演进，而非现在就实现。

本项目采用**规格驱动 + AI 生成**的工作模式（见 ADR-008）：ADR / SDD / task-spec 是单一事实来源，
Linux 与 macOS 两端独立用各自原生技术实现（见 ADR-002），靠精确规格与共享的行为契约 / 测试向量保证两端行为一致。
