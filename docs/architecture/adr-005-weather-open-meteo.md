# ADR-005: 天气数据源——Open-Meteo

## Status

Accepted

## Context

**问题**：需要展示今天与未来几天的天气。需选定一个数据源。

**约束**：
- 纯本地应用（ADR-001），由客户端直接调用公网 API，无后端代理。
- 希望免费、无需申请 API key、无需注册。

## Options Considered

| 方案 | Pros | Cons | 何时合适 |
|------|------|------|----------|
| A. Open-Meteo | 免费；**无需 API key**；提供 current + daily/hourly 预报；自带 geocoding API | 非商业 SLA | 个人项目 |
| B. OpenWeatherMap 等 | 数据丰富 | 需注册申请 key；免费额度受限；客户端内嵌 key 不安全 | 需要商业级数据 |

## Decision

**选择 Open-Meteo**：
- 天气数据接口：`https://api.open-meteo.com/v1/forecast`，请求 `current` 与 `daily` 参数（如温度、天气代码、最高/最低温、降水概率等）。
- 地点解析：用户可在配置中直接给经纬度；或给地点名，由应用调用 Open-Meteo Geocoding API（`https://geocoding-api.open-meteo.com/v1/search`）解析为经纬度。
- 拉取与解析逻辑由规格统一定义（含 JSON 字段映射、缺字段降级、WMO code 映射），两端各自实现并以同一份测试向量校验。

## Rationale

1. 无需 API key，契合纯本地、零密钥管理的形态——避免在客户端内嵌密钥的安全问题。
2. 免费且提供完整的当前 + 多日预报，满足需求。
3. 自带 geocoding，地点配置可用名称而非手填经纬度。

## Trade-offs

- 依赖第三方免费服务的可用性，无 SLA 保证。
- 天气代码（WMO code）需在客户端映射为图标/文案。

## Consequences

- **Positive**：零密钥、免费、实现简单、解析逻辑由规格统一定义。
- **Negative**：服务偶发不可用或限流时取不到数据。
- **Mitigation**：请求设超时与失败兜底（展示"天气暂不可用"并保留上次结果与时间戳）；维护一份 WMO weather code → 文案/图标的映射表。

## Revisit Trigger

- Open-Meteo 不再满足需求（精度、可用性、限流）。
- 需要 OpenWeatherMap 特有的差异化能力（如分钟级降水临近预报）时，**不替换** Open-Meteo，而是把天气数据源设计成可插拔的多提供方：新增 OpenWeatherMap 作为可选项（需用户自行申请并配置 API key），Open-Meteo 保留为默认/零配置选项。当前阶段（v1）明确不做这个抽象，属 YAGNI（见 SDD §13）。
