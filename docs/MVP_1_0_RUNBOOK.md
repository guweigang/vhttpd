# vhttpd MVP 1.0 Runbook (TOML-first)

## 1. Build

```bash
cd /Users/guweigang/Source/vhttpd
make vhttpd
```

## 2. Start (TOML only)

推荐：直接用 examples 里的 TOML。

```bash
cd /Users/guweigang/Source/vhttpd
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/config/laravel.toml
```

或位置参数简写：

```bash
./vhttpd /Users/guweigang/Source/vhttpd/examples/config/laravel.toml
```

## 3. Data plane smoke

```bash
http http://127.0.0.1:19886/laravel/meta
```

## 4. Admin plane checks

```bash
# worker 状态
curl --noproxy '*' -s http://127.0.0.1:19986/admin/workers | jq .

# 运行统计
curl --noproxy '*' -s http://127.0.0.1:19986/admin/stats | jq .
```

## 5. Admin operations

```bash
# 单 worker 重启
curl --noproxy '*' -s -X POST \
  'http://127.0.0.1:19986/admin/workers/restart?id=1' | jq .

# 全量重启
curl --noproxy '*' -s -X POST \
  'http://127.0.0.1:19986/admin/workers/restart/all' | jq .
```

如果设置了 token（`[admin].token`）：

```bash
curl --noproxy '*' -s -H 'x-vhttpd-admin-token: <token>' \
  'http://127.0.0.1:19986/admin/workers' | jq .
```

## 6. Bench (short + stream)

```bash
bash /Users/guweigang/Source/vhttpd/bench/run_host_regression.sh
```

只测生命周期（不跑 k6）：

```bash
VHTTPD_BENCH_RUN_K6=0 bash /Users/guweigang/Source/vhttpd/bench/run_host_regression.sh
```

## 7. TOML layout (recommended)

```toml
[server]
host = "127.0.0.1"
port = 19886

[files]
pid_file = "/tmp/vhttpd_laravel.pid"
event_log = "/tmp/vhttpd_laravel.events.ndjson"

[worker]
autostart = true
pool_size = 4
socket = "/tmp/vslim_laravel_worker.sock"
read_timeout_ms = 3000
cmd = "php -d extension=/Users/guweigang/Source/vphpx/vslim/vslim.so /Users/guweigang/Source/vhttpd/php/package/bin/php-worker"

[worker.env]
VHTTPD_APP = "/Users/guweigang/Source/vhttpd/examples/laravel/app.php"

[admin]
host = "127.0.0.1"
port = 19986
token = ""
```

说明：

- 推荐始终使用 `worker.socket`
- 当 `pool_size = 1` 时，它就是单 worker socket 路径
- 当 `pool_size > 1` 时，`vhttpd` 会自动把它当作 socket 前缀，展开成 `*_0.sock`、`*_1.sock` 这类 worker socket
- `VHTTPD_APP` 是固定的 worker bootstrap 环境变量名，MVP/1.0 不再变更
- `worker.env` 会注入 php-worker，PHP 里可直接 `getenv()`
- CLI 参数优先级高于 TOML（仅建议临时覆盖）

## 8. Release checklist (MVP)

```bash
# 1) build
make -C /Users/guweigang/Source/vhttpd vhttpd

# 2) admin split + token
#    启动后验证 data plane /admin/* 为 404，admin plane 可访问

# 3) worker stats increments
#    压几次请求后检查 .workers[].served_requests > 0

# 4) restart APIs
#    验证 single/all 重启返回 ok

# 5) graceful stop
#    Ctrl+C 后无残留 php-worker
```
