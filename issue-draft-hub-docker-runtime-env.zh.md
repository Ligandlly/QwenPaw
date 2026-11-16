## Summary

在 Hub 托管的运行时中（`QWENPAW_RUNTIME_ID` 由 provisioner 注入），能否提供一个面板来设置
docker 运行时的环境变量，尤其是以 `QWENPAW_` 开头的那些。

## Component(s) Affected

- [x] Core / Backend (app, agents, config, providers, utils, local_models)
- [x] Console (frontend web UI)
- [ ] Channels (DingTalk, Feishu, QQ, Discord, iMessage, etc.)
- [ ] Skills
- [ ] CLI
- [ ] Documentation (website)
- [ ] Tests
- [ ] CI/CD
- [ ] Scripts / Deploy

## Problem / Motivation

独立运行 QwenPaw 时，若干行为通过普通 `QWENPAW_*` 环境变量暴露：日志轮转
（`QWENPAW_LOG_MAX_SIZE`、`QWENPAW_LOG_MAX_BACKUPS`）、上传限制
（`QWENPAW_UPLOAD_MAX_SIZE_MB`）、图片解码上限（`QWENPAW_MAX_IMAGE_PIXELS`）、遥测
（`QWENPAW_TELEMETRY_DISABLED`）、技能扫描（`QWENPAW_SKILL_SCAN_MODE`）、tool-guard
（`QWENPAW_TOOL_GUARD_*`）以及 LLM 重试/限流开关（`QWENPAW_LLM_*`）。

在 Hub 模式下既没有面板，也没有受支持的途径把这些值传进租户运行时：

- 想把 `QWENPAW_LOG_MAX_SIZE=50MB` 或关闭遥测的租户完全无从下手。
- 运维无法表达"这些默认值适用于本 Hub 上的所有运行时"，只能逐个租户处理 —— 或者对租户容器
  完全没有可用的调节手段。
- 唯一的绕过方式是 `docker exec` / 重建容器，这不受支持，且下次 `start()` 就丢失。

这不只是"少了一个 UI"：目前有三个独立层面拒绝整个命名空间，所以只加面板还不够。

| 层面 | 结果 | 代码 |
| --- | --- | --- |
| Hub 凭据（`PUT /api/hub/credentials`，作用域 `tenant` 或 `runtime:<id>`） | `400 Credential name is reserved by the runtime: QWENPAW_LOG_MAX_SIZE` | `runtime_credential_name_allowed()` 即 `user_environment_key_allowed()`，其 `_CONTROL_PREFIXES` 含 `QWENPAW_`（`src/qwenpaw/utils/runtime_environment.py:34-51`、`src/qwenpaw/hub/credentials.py:29-31`） |
| 运行时自身的 `PATCH /envs`（控制台 → Settings → Environment Variables） | `400 Environment variable is managed internally: QWENPAW_LOG_MAX_SIZE` | `is_managed_control_key()`（`src/qwenpaw/envs/registry.py:233-241`） |
| provisioner | 它们自己的 `QWENPAW_*` 边界值在凭据映射合并**之后**写入，所以即使值传进来了也会被替换 | `src/qwenpaw/hub/docker_provisioner.py:196-216`、`src/qwenpaw/hub/local_provisioner.py:332-380` |

`PATCH /envs` 这一层是实际执行仓库中的 `validate_env_key()` 验证的，分设置/不设置
`QWENPAW_RUNTIME_ID` 两种情况：

| 键 | 独立运行（未设置 `QWENPAW_RUNTIME_ID`） | 托管运行时（已设置 `QWENPAW_RUNTIME_ID`） |
| --- | --- | --- |
| `QWENPAW_LOG_MAX_SIZE` | 通过 | **拒绝：managed internally** |
| `QWENPAW_LOG_MAX_BACKUPS` | 通过 | **拒绝：managed internally** |
| `QWENPAW_TELEMETRY_DISABLED` | 通过 | **拒绝：managed internally** |
| `QWENPAW_MAX_IMAGE_PIXELS` | 通过 | **拒绝：managed internally** |
| `QWENPAW_UPLOAD_MAX_SIZE_MB` | 通过 | **拒绝：managed internally** |
| `QWENPAW_SKILL_SCAN_MODE` | 通过 | **拒绝：managed internally** |
| `QWENPAW_TOOL_GUARD_ENABLED` | 通过 | **拒绝：managed internally** |
| `QWENPAW_LLM_MAX_RETRIES` | 拒绝：read-only | **拒绝：managed internally** |
| `QWENPAW_LLM_STREAM_IDLE_TIMEOUT` | 通过 | 通过（有 `hot_runtime` 规格） |
| `MY_TEST_VAR` | 通过 | 通过 |

`ENV_VAR_SPECS` 共 17 条，只有 `QWENPAW_LLM_STREAM_FIRST_CONTENT_TIMEOUT` /
`QWENPAW_LLM_STREAM_IDLE_TIMEOUT` 是 `hot_runtime`；日志 / 遥测 / 图片 / 上传 / tool-guard
相关开关均不在目录中。两个控制台表单也都是"前端放行、后端拒绝"（Hub 凭据表单只校验大写格式，
环境变量编辑器只校验键名正则，见 `console/src/pages/Settings/Environments/index.tsx:120`）。

## Proposed Solution

提供受支持的途径 —— 最好是 Hub 控制台里的面板 —— 为托管租户运行时定义环境变量，包括白名单内的
`QWENPAW_*` 名字。

1. **按运行时设置环境变量的面板 / API**，沿用 Hub 已有的粒度：Hub 全局默认、租户级、
   `runtime:<id>` 级。
2. **`QWENPAW_*` 可调项白名单**（日志、上传、图片、遥测、技能扫描、tool-guard、LLM
   重试/限流），让租户或运维能像独立运行 QwenPaw 时一样设置。
3. **边界键继续保持保留**（`QWENPAW_WORKING_DIR`、`QWENPAW_SECRET_DIR`、`QWENPAW_RUNTIME_ID`、
   `QWENPAW_RUNTIME_INTERNAL_TOKEN`、`QWENPAW_AUTH_ENABLED` 等），仍由 Hub 覆盖。
4. **明确的生效语义**：Docker 环境变量在容器创建后不可变更，因此面板应说明需要重启，并提供
   "应用并重启"，而不是静默无效。

实现要点 / 可复用部件：

- `TenantCredentialVault` 已支持租户级与运行时级的加密存储，`resolve_environment()` 也已在
  `start()` 时把值注入容器环境（`src/qwenpaw/hub/credentials.py:202-217`）。非 `QWENPAW_` 的名字
  今天就能端到端工作，所以缺口是前缀策略和 UI/校验，而不是底层管道。
- 运行时已暴露带类型的目录（`GET /envs/catalog`），含 `default`、`effective_value`、
  `editable`、`mutability`，面板可直接渲染，无需另建一套 schema。

粗略验收标准：

- 管理员可为托管运行时定义 Hub 全局的 `QWENPAW_*` 默认值；租户（或单个运行时）可覆盖白名单内的
  子集。
- 设置后进入"需要重启"状态，"应用并重启"会重建容器，使新变量出现在 `docker inspect` 中。
- 保留的边界键被拒绝时，提示需说明原因和允许的替代项，并在控制台提交前校验。
- 生效值可见（可直接用目录的 `effective_value`），以便区分"管理员默认 / 租户覆盖 / 边界值"。

## Alternatives Considered

- **只扩展 `ENV_VAR_SPECS`**：把日志 / 遥测 / 图片 / tool-guard 相关键标记为 `hot_runtime`，让
  运行时控制台可直接编辑。改动更小，但绕过了 Hub（没有全局默认、没有按运行时作用域，也无法帮助
  已停止的运行时或全新容器）。
- **仅在管理员配置中增加字段**：添加 `runtime.docker.environment`（`DockerRuntimeConfig` 目前
  是 `extra="forbid"`）。适合部署级默认值，但租户无法按运行时控制，且每次变更都要重载 Hub 配置。
- **只放宽 Hub 凭据过滤**：可沿用现有 UI，但边界自有的 `QWENPAW_*` 名字会与 provisioner 自己的
  值冲突，而后者在合并之后写入，会静默胜出。
- **现有绕过方式**：`docker exec` 进入租户容器，或手工修改进程环境。不受支持、Hub 不可见，且
  下次 `start()` 就丢失。
- **宿主机级 `HUB_RUNTIME_ENV_*` 透传**：对运维有用，但仍无按租户控制，且难以按运行时审计。

## Additional Context

- QwenPaw `v2.2.2`（`main` 上同样如此），Hub 模式，`runtime.provisioner: docker`，
  Docker Engine 29.x + Linux 容器。
- `runtime.provisioner: local` 存在同样缺口，因为 `LocalProcessRuntimeProvisioner` 的构造方式
  一致；Docker 只是更明显，因为容器环境变量在创建后无法修改。
- 实现前待确认问题：
  1. `QWENPAW_` 的一揽子封锁是有意的纵深防御还是权宜之计？能否接受显式的"用户可调项白名单"？
  2. 面板应放在哪里：Hub → Credentials（在现有存储表单上加白名单）、Hub → 运行时详情
     （"Runtime environment" 区块），还是管理员配置？
  3. 是否需要两级模型 —— 管理员默认值 + 租户/运行时级覆盖，与现有 `tenant` vs `runtime:<id>`
     凭据作用域保持一致？
  4. 鉴于 Docker 环境变量创建后不可变，"需要重启 / 应用并重启"能否作为该功能的契约？
  5. 哪些名字必须始终由 Hub 掌控？假设为：`QWENPAW_WORKING_DIR`、`QWENPAW_SECRET_DIR`、
     `QWENPAW_BACKUP_DIR`、`QWENPAW_RUNTIME_ID`、`QWENPAW_TENANT_ID`、
     `QWENPAW_RUNTIME_INTERNAL_TOKEN`、`QWENPAW_RUNTIME_API_URL`、`QWENPAW_AUTH_ENABLED`、
     `QWENPAW_RUNNING_IN_CONTAINER`、`QWENPAW_HUB_MODEL_URL`、`QWENPAW_HUB_MODEL_TOKEN`。

## Willing to Contribute

- [x] I am willing to open a PR for this feature (after discussion).
