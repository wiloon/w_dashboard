# ADR-009: Linux 端 GUI 框架——改用 Slint，弃用 Iced/libcosmic

## Status

Accepted（修订 ADR-002/ADR-007 中"Linux 端用 Rust + Iced/libcosmic"的具体技术选型）

## Context

**问题**：ADR-002/ADR-007 最初为 Linux 端选定 **Rust + Iced/libcosmic** 作为原生 GUI 技术栈（libcosmic 是 COSMIC 桌面环境的组件库，构建于 Iced 之上）。

**触发**：作者实测查看了 libcosmic 当前的状态，发现其处于早期发展阶段——默认组件的视觉效果（间距、图标、控件打磨）比较粗糙，尚未做美化，做出来的界面观感不佳；同时 libcosmic 的视觉风格主要面向 COSMIC 桌面环境设计，与该桌面环境强绑定。这与本项目"统一、可控、原生精致的面板"（见 ADR-007）的诉求不符。

**有利条件**：`app-linux` 目前尚未开始实现（仍处于规格阶段，见 task-spec M0/M1），更换技术选型的迁移成本为零，不涉及任何代码改动。

**约束（不变）**：
- Linux 端仍要求用 Rust 原生技术栈，不引入 Electron/Web 技术等非原生方案（延续 ADR-001 的总体取向）。
- 不引入跨语言 FFI、不与 macOS 端共享二进制/库（见 ADR-002）。

## Options Considered

| 方案 | Pros | Cons | 复杂度 | 何时合适 |
|------|------|------|--------|----------|
| A. 维持 Iced/libcosmic | 已在既有规格中；Iced 生态成熟；纯 Rust | libcosmic 视觉效果早期粗糙、未打磨；与 COSMIC 桌面强绑定，其他桌面环境（GNOME/KDE）观感不一致；若弃用 libcosmic 只用纯 Iced，则需自行搭建大量常见控件与主题，工作量大 | 中 | 若能接受当前视觉效果或愿意深度自定制主题 |
| B. 改用 Slint | 声明式 `.slint` 标记语言 + live-preview 设计器，UI/逻辑分离清晰；不依赖 COSMIC 或 wgpu 重型渲染栈，二进制更小、编译更快；跨主流桌面环境视觉更中性统一；内置组件与主题打磨程度更高；纯 Rust 集成（build.rs） | 需学习额外 DSL；生态与第三方组件比 GTK/Iced 更年轻；多一道 `.slint` 编译构建步骤 | 中 | 追求跨桌面环境一致、精致的原生观感，且能接受引入一门轻量 DSL |
| C. 改用 GTK4-rs（+ libadwaita） | GNOME 官方绑定，GNOME 环境下最原生；libadwaita 组件成熟精致 | 依赖系统级 C 库（GTK4/libadwaita），需安装对应 devel 包，跨发行版打包更重；对 C API 的绑定，Rust 侧不如原生 crate 顺手；风格偏 GNOME，非 GNOME 桌面下不一定协调 | 高 | 明确只面向 GNOME 系发行版，且接受系统库依赖 |
| D. 改用 egui | 纯 Rust、immediate mode、上手快 | 默认视觉偏"开发者工具/游戏内 UI"风格，缺乏原生桌面观感与系统主题集成 | 低 | 内部工具、不在意原生观感 |

## Decision

**选择方案 B**：Linux 端 GUI 框架由 **Rust + Iced/libcosmic** 改为 **Rust + Slint**。

`app-linux` 的其余决策不变：仍是纯 Rust 独立实现（ADR-002）、仍自行采集 git/chezmoi 状态（ADR-003/ADR-007）、仍无后端（ADR-001）。

## Rationale

1. 作者实测 libcosmic 当前视觉效果粗糙、处于早期未打磨阶段，不符合"原生精致"的诉求（ADR-007 的初衷之一），是本次重新选型的直接原因。
2. `app-linux` 尚未开始实现，零迁移成本，是更换技术栈的最佳时机——越早换，代价越低。
3. Slint 的声明式 `.slint` 文件 + live-preview 设计器与本项目"规格驱动 + AI 生成"的工作模式（ADR-008）契合度高：UI 描述本身是一份结构清晰、易由 AI 生成与校验的"数据"，与逻辑代码分离更彻底。
4. 不依赖 COSMIC 桌面环境，也不依赖系统级 GTK devel 库，跨主流桌面环境（GNOME/KDE/Xfce 等）视觉更统一、依赖更轻、打包更简单，符合"低维护成本"的总体取向（见 ADR-001）。
5. 仍是纯 Rust 生态，不引入 FFI 或跨语言绑定，不违反 ADR-002 的核心决策（两端独立原生实现）。

## Trade-offs

- 需要学习并维护额外的 `.slint` DSL 文件；构建链多一步（`build.rs` 编译 `.slint` → 生成 Rust 代码）。
- 放弃了"若 libcosmic 未来打磨完善，可获得的 COSMIC 桌面深度集成能力"（如与 COSMIC 面板/通知联动）；本项目当前也未依赖此类深度集成，损失很小。
- Slint 的社区与第三方组件生态比 GTK/Iced 更年轻，复杂交互场景可参考资料较少。

## Consequences

- **Positive**：UI 视觉可控性更高，不与单一桌面环境绑定；构建更轻量；`.slint` 文件的组织路径清晰，便于 AI 生成与维护。
- **Negative**：多引入一种 DSL 及配套构建步骤，带来额外学习成本。
- **Mitigation**：在 SDD/task-spec 的 M2 阶段明确 `.slint` 文件组织方式与 `build.rs` 集成方法；M2b 验收时用真实截图核对视觉效果，避免"换框架但未解决根本问题"。

## Revisit Trigger

- Slint 出现严重限制（授权条款变化、关键组件缺失、性能问题等）导致无法满足需求。
- libcosmic 打磨成熟、视觉效果达到可接受水平，且其 COSMIC 深度集成价值被认为超过 Slint 的跨桌面中性优势。
