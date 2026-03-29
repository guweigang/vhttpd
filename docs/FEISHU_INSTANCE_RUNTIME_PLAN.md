**Feishu Instance Runtime Plan**

This phase aligns Feishu with the same instance ownership model already being introduced for Codex.

**Boundary**

- TS/vjsx owns:
  - deciding logical Feishu instances such as `main`, `support`, `ops`
  - persisting each instance config
  - app-level bootstrap intent via `app_startup(runtime)`
  - emitting `provider.instance.upsert` and `provider.instance.ensure`
- `vhttpd` owns:
  - applying Feishu instance specs into runtime app config
  - resolving instance name to active Feishu app runtime
  - websocket connect/reconnect and HTTP send/update behavior
  - serializing `app_startup(runtime)` so only one lane performs process-global startup side effects
  - running `startup(runtime)` once per lane for lane-local initialization only

**Key Rule**

`feishu.main` should no longer be treated as a privileged hardcoded app defined only by static server config. It should be allowed to come from TS-side dynamic instance config the same way as `codex.default`.

**Compatibility**

- Existing static TOML Feishu apps remain valid.
- `provider.instance.ensure(provider=feishu, instance=main)` can synthesize a compatible instance spec from existing static Feishu config when present.
- Dynamic Feishu instance specs are applied into `feishu_apps`, so the rest of the Feishu runtime can continue using current app resolution helpers.
- During the transition, TS-side `app_startup(runtime)` may emit only `provider.instance.ensure(feishu, main)` when no dynamic credentials are present, allowing static `feishu.main` to remain the compatibility source.

**Transition Policy**

- Short term:
  - keep static `feishu.apps` as a compatibility source
  - allow TS-driven `provider.instance.upsert/ensure` to create or override logical Feishu instances such as `feishu.main`
  - treat static config and TS config as two ingress paths into the same runtime app registry
- Long term:
  - `provider_instance_specs` becomes the only logical instance registry
  - static `feishu.apps` is downgraded to migration-only or development-only bootstrap input
  - `vhttpd` should not own business instance naming such as `main`, `support`, or `ops`

**Source-of-Truth Direction**

- Instance existence should ultimately be decided by TS/vjsx.
- Process-level static config should remain only for global runtime defaults such as:
  - `open_base_url`
  - reconnect policy
  - token refresh skew
- Per-instance credentials and naming should move out of static TOML over time.

**What This Enables**

- TS can own the source of truth for Feishu instance definitions.
- `vhttpd` no longer requires `feishu.main` to be present only in static config to bootstrap runtime behavior.
- Feishu and Codex now share the same high-level control flow:
  - optional `startup(runtime)` for lane-local setup
  - serialized `app_startup(runtime)` for one-time bootstrap intent
  - upsert instance spec
  - ensure runtime materialization
  - send business commands with explicit `instance`
- Admin/runtime views can expose whether a Feishu instance is:
  - `static`
  - `dynamic`
  - `mixed`
- Provider-instance storage and compatibility rows can be inspected via:
  - `GET /admin/runtime/provider-instances`
  - the view also reports `runtime_configured`, `runtime_connected`, and `runtime_url`

**Follow-up**

- Move more Feishu bootstrap assumptions away from static process config and into the provider-instance registry.
- Add admin/runtime views that distinguish static-derived and TS-derived Feishu instances if that becomes operationally useful.
- Once TS-side config management is stable, begin deprecating direct dependence on static `feishu.apps`.
