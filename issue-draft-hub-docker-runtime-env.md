## Summary

In a Hub-managed runtime (`QWENPAW_RUNTIME_ID` is injected by the provisioner), is it possible to have a panel to set docker runtime environment variables, especially those whose names start with `QWENPAW_`?

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

Standalone QwenPaw exposes a number of behaviours as plain `QWENPAW_*` environment variables: log
rotation (`QWENPAW_LOG_MAX_SIZE`, `QWENPAW_LOG_MAX_BACKUPS`), upload limit
(`QWENPAW_UPLOAD_MAX_SIZE_MB`), image decoding cap (`QWENPAW_MAX_IMAGE_PIXELS`), telemetry
(`QWENPAW_TELEMETRY_DISABLED`), skill scanning (`QWENPAW_SKILL_SCAN_MODE`), tool guard
(`QWENPAW_TOOL_GUARD_*`) and the LLM retry / rate-limit knobs (`QWENPAW_LLM_*`).

In Hub mode there is no panel and no supported path to pass those values into a tenant runtime:

- A tenant who wants `QWENPAW_LOG_MAX_SIZE=50MB`, or wants telemetry disabled, cannot do it at all.
- An operator cannot express "these defaults apply to every runtime on this Hub" and has to touch
  each tenant individually — or has no lever over a tenant container at all.
- The only workaround is `docker exec` / rebuilding the container, which is unsupported and is lost
  on the next `start()`.

This is not just a missing UI: three independent layers currently reject the whole namespace, so a
panel alone would not be enough.

| Layer | Result | Code |
| --- | --- | --- |
| Hub credentials (`PUT /api/hub/credentials`, scope `tenant` or `runtime:<id>`) | `400 Credential name is reserved by the runtime: QWENPAW_LOG_MAX_SIZE` | `runtime_credential_name_allowed()` is `user_environment_key_allowed()`, whose `_CONTROL_PREFIXES` contains `QWENPAW_` (`src/qwenpaw/utils/runtime_environment.py:34-51`, `src/qwenpaw/hub/credentials.py:29-31`) |
| Runtime's own `PATCH /envs` (Console → Settings → Environment Variables) | `400 Environment variable is managed internally: QWENPAW_LOG_MAX_SIZE` | `is_managed_control_key()` (`src/qwenpaw/envs/registry.py:233-241`) |
| Provisioners | Their own `QWENPAW_*` boundary values are written *after* the credential mapping is merged, so a value that got through would still be replaced | `src/qwenpaw/hub/docker_provisioner.py:196-216`, `src/qwenpaw/hub/local_provisioner.py:332-380` |

Verified for the `PATCH /envs` layer by running `validate_env_key()` from this repo with and without
`QWENPAW_RUNTIME_ID`:

| Key | standalone (`QWENPAW_RUNTIME_ID` unset) | managed runtime (`QWENPAW_RUNTIME_ID` set) |
| --- | --- | --- |
| `QWENPAW_LOG_MAX_SIZE` | accepted | **rejected: managed internally** |
| `QWENPAW_LOG_MAX_BACKUPS` | accepted | **rejected: managed internally** |
| `QWENPAW_TELEMETRY_DISABLED` | accepted | **rejected: managed internally** |
| `QWENPAW_MAX_IMAGE_PIXELS` | accepted | **rejected: managed internally** |
| `QWENPAW_UPLOAD_MAX_SIZE_MB` | accepted | **rejected: managed internally** |
| `QWENPAW_SKILL_SCAN_MODE` | accepted | **rejected: managed internally** |
| `QWENPAW_TOOL_GUARD_ENABLED` | accepted | **rejected: managed internally** |
| `QWENPAW_LLM_MAX_RETRIES` | rejected: read-only | **rejected: managed internally** |
| `QWENPAW_LLM_STREAM_IDLE_TIMEOUT` | accepted | accepted (has a `hot_runtime` spec) |
| `MY_TEST_VAR` | accepted | accepted |

`ENV_VAR_SPECS` has 17 entries and only `QWENPAW_LLM_STREAM_FIRST_CONTENT_TIMEOUT` /
`QWENPAW_LLM_STREAM_IDLE_TIMEOUT` are `hot_runtime`; none of the log / telemetry / image / upload /
tool-guard tunables are in the catalog. Both console forms also accept the input and reject it only
server-side (the Hub credential form checks the uppercase pattern, the environment-variable editor
checks a key regex at `console/src/pages/Settings/Environments/index.tsx:120`).

## Proposed Solution

A supported way — ideally a panel in the Hub console — to define environment variables for a
managed tenant runtime, including allowlisted `QWENPAW_*` names.

1. **Panel / API to set env vars per managed runtime**, at the granularity Hub already models:
   Hub-wide defaults, tenant-scoped, and `runtime:<id>` scoped.
2. **An allowlist of `QWENPAW_*` tunables** (log, upload, image, telemetry, skill-scan, tool-guard,
   LLM retry / rate-limit) so tenant or operator can set them exactly as when QwenPaw runs
   standalone.
3. **Boundary keys stay reserved** (`QWENPAW_WORKING_DIR`, `QWENPAW_SECRET_DIR`,
   `QWENPAW_RUNTIME_ID`, `QWENPAW_RUNTIME_INTERNAL_TOKEN`, `QWENPAW_AUTH_ENABLED`, ...) and keep
   being overridden by the Hub.
4. **Clear apply semantics**: Docker environment is immutable after container creation, so the panel
   should state that a restart is required and offer "apply & restart" instead of silently doing
   nothing.

Implementation notes / reusable pieces:

- `TenantCredentialVault` already stores encrypted tenant- and runtime-scoped values, and
  `resolve_environment()` already feeds them into the container environment at `start()`
  (`src/qwenpaw/hub/credentials.py:202-217`). Non-`QWENPAW_` names already work end-to-end today, so
  the gap is the prefix policy plus UI/validation, not new plumbing.
- The runtime already exposes a typed catalog (`GET /envs/catalog`) with `default`,
  `effective_value`, `editable` and `mutability`, which the panel could render directly instead of
  introducing a second schema.

Rough acceptance criteria:

- Admin can define Hub-wide `QWENPAW_*` defaults for managed runtimes; a tenant (or one runtime) can
  override the allowlisted subset.
- Setting a value returns a "restart required" state, and "apply & restart" recreates the container
  so the new variable shows up in `docker inspect`.
- Reserved boundary names are rejected with a message naming the reason and the allowed alternatives,
  and the console validates before submit.
- The effective value is visible (catalog `effective_value` fits), so users can tell admin default vs
  tenant override vs boundary value.

## Alternatives Considered

- **Only extend `ENV_VAR_SPECS`**: mark the log / telemetry / image / tool-guard keys `hot_runtime` so
  the in-runtime Console can edit them. Smaller change, but it bypasses the Hub (no Hub-wide defaults,
  no per-runtime scoping, and it does not help a stopped runtime or a fresh container).
- **Admin-only config field**: add `runtime.docker.environment` (`DockerRuntimeConfig` currently uses
  `extra="forbid"`). Good for deployment-wide defaults, but gives tenants no per-runtime control and
  requires a Hub config reload for every change.
- **Relax the Hub credential filter only**: keeps the existing UI, but then the boundary-owned
  `QWENPAW_*` names would collide with the provisioner's own values, which are written after the
  merge and would silently win.
- **Current workarounds**: `docker exec` into the tenant container, or patching the process
  environment by hand. Unsupported, invisible to the Hub, and lost on the next `start()`.
- **Host-level `HUB_RUNTIME_ENV_*` style passthrough**: useful for operators, but still no per-tenant
  control and awkward to audit per runtime.

## Additional Context

- QwenPaw `v2.2.2` (also present on `main`), Hub mode, `runtime.provisioner: docker`,
  Docker Engine 29.x with Linux containers.
- The same gap applies to `runtime.provisioner: local`, since `LocalProcessRuntimeProvisioner`
  builds its environment the same way; Docker makes it more visible because the container
  environment cannot be patched after creation.
- Open questions before implementation:
  1. Is the blanket `QWENPAW_` block deliberate defense-in-depth or a shortcut? Would an explicit
     allowlist of user-tunable names be acceptable?
  2. Where should the panel live: Hub → Credentials (extend the existing store form with an
     allowlist), Hub → runtime detail ("Runtime environment" section), or admin config?
  3. Should there be two levels — admin defaults plus per-tenant / per-runtime overrides — mirroring
     the existing `tenant` vs `runtime:<id>` credential scopes?
  4. Is "restart required / apply & restart" an acceptable contract given Docker env immutability?
  5. Which names must stay Hub-owned? Assumption: `QWENPAW_WORKING_DIR`, `QWENPAW_SECRET_DIR`,
     `QWENPAW_BACKUP_DIR`, `QWENPAW_RUNTIME_ID`, `QWENPAW_TENANT_ID`,
     `QWENPAW_RUNTIME_INTERNAL_TOKEN`, `QWENPAW_RUNTIME_API_URL`, `QWENPAW_AUTH_ENABLED`,
     `QWENPAW_RUNNING_IN_CONTAINER`, `QWENPAW_HUB_MODEL_URL`, `QWENPAW_HUB_MODEL_TOKEN`.

## Willing to Contribute

- [x] I am willing to open a PR for this feature (after discussion).
