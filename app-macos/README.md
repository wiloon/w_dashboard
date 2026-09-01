# app-macos

Swift + SwiftUI 实现，独立于 `app-linux`（不共享代码/FFI，见 ADR-002）。规格见 `../docs/sdd.md`。

工程形式是纯 Swift Package Manager（无第三方依赖，只用 Foundation/SwiftUI），Xcode 可直接打开本目录的 `Package.swift`。

## 目录

- `Sources/WDashboardCore`：采集层（config / git / weather / 数据模型），纯 Foundation，无 UI 依赖。
- `Sources/WDashboardApp`：SwiftUI 可执行 target（Repos / Clocks / Weather 三分区）。
- `Tests/WDashboardCoreTests`：加载 `../docs/test-vectors/` 的契约测试 + config 增删改单测。
- `Scripts/build-app.sh`：release 构建并组装 `dist/WDashboard.app`。

## 构建 / 运行 / 测试

```sh
swift build            # 编译两个 target
swift test              # 跑契约测试（两端一致性闸门，见 docs/sdd.md §10）+ config CRUD 测试
swift run WDashboardApp  # 启动窗口
```

配置文件路径与 Linux 端一致：`$XDG_CONFIG_HOME/w_dashboard/config.toml`，回退 `~/.config/w_dashboard/config.toml`（见 `../config.example.toml`）。文件不存在时使用内置默认值（空 repos、默认时钟）。

## 打包为 .app

```sh
./Scripts/build-app.sh
open dist/WDashboard.app
```

## 当前范围

对齐 `app-linux` 当前实现：Repos（含仓库增删改，以及 Pull / Push / Fetch 同步操作按钮，见 SDD §7.5 / ADR-011）、Clocks、Weather 三分区。chezmoi 面板尚未在两端任一侧实现，留待后续里程碑两端同步做（见 `../docs/task-spec.md`）。
