# Executor Modes

`vhttpd` currently supports two logic execution modes:

- `php`: dispatch through PHP workers over Unix sockets
- `vjsx`: dispatch in-process through embedded `vjsx`

Shared config such as `[server]`, `[files]`, `[runtime]`, `[admin]`, and `[assets]` works the same in both modes.

If you use `[paths]`, values that start with `/` are treated as absolute paths and kept as-is. Other aliases resolve against `[paths].root`, and `[paths].root` itself resolves against the config file directory.

## PHP Mode

Use `php` when you want the existing PHP worker model.

Minimal shape:

```toml
[paths]
root = "."
php_app = "examples/hello-app.php"
php_worker = "php/package/bin/php-worker"
vslim_ext = "../vphpx/vslim/vslim.so"

[executor]
kind = "php"

[php]
bin = "php"
worker_entry = "${paths.php_worker}"
app_entry = "${paths.php_app}"
extensions = ["${paths.vslim_ext}"]
args = []

[worker]
autostart = true
pool_size = 4
socket_prefix = "/tmp/vslim_worker"
read_timeout_ms = 3000
max_requests = 5000
restart_backoff_ms = 500
restart_backoff_max_ms = 8000
```

Important fields:

- `[executor].kind = "php"`
- `[php].worker_entry`: PHP worker bootstrap script
- `[php].app_entry`: PHP app/bootstrap entry, injected as `VHTTPD_APP`
- `[php].extensions[]`: ordered extension list, emitted as repeated `-d extension=...`
- `[php].args[]`: extra PHP CLI args
- `[worker].cmd`: optional explicit override for the generated worker command
- `[worker].socket` or `[worker].socket_prefix`: Unix socket path/prefix
- `[worker].pool_size`: worker count

Behavior:

- worker sockets are active
- worker autostart is available
- existing stream/websocket/MCP worker-based paths remain available when configured
- if `[worker].cmd` is empty, `vhttpd` generates it from `[php]`
- when generating from `[php]`, startup validates `worker_entry`, optional `app_entry`, and each configured extension path up front
- CLI overrides are available via `--php-bin`, `--php-worker-entry`, `--php-app-entry`, repeatable `--php-extension`, and repeatable `--php-arg`

Ready-to-run example:

- [config/vhttpd.example.toml](/Users/guweigang/Source/vhttpd/config/vhttpd.example.toml)

## vjsx Mode

Use `vjsx` when you want embedded in-proc logic execution.

Minimal shape:

```toml
[paths]
root = "."
vjsx_app = "examples/vjsx/hello-handler.mts"
vjsx_root = "examples/vjsx"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "${paths.vjsx_app}"
module_root = "${paths.vjsx_root}"
runtime_profile = "node"
thread_count = 2
```

Important fields:

- `[executor].kind = "vjsx"`
- `[vjsx].app_entry`: JS/TS entry file
- `[vjsx].module_root`: module resolution root
- `[vjsx].runtime_profile`: `script` or `node`
- `[vjsx].thread_count`: embedded execution lane count

Behavior:

- worker sockets are disabled automatically
- worker autostart is ignored
- current scope is HTTP dispatch plus `websocket_upstream` dispatch
- stream/websocket session worker modes and MCP are intentionally off in this mode

Ready-to-run example:

- [config/vhttpd.vjsx.example.toml](/Users/guweigang/Source/vhttpd/config/vhttpd.vjsx.example.toml)

## Quick Switch Rule

If you switch executors:

- keep common sections as-is
- change `[executor].kind`
- keep `[worker]` for `php`
- keep `[vjsx]` for `vjsx`

You do not need both execution paths active at the same time.
