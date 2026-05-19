# 可观测性实战：监控、调试和运维

在前面的文章中，我们深入了解了 vhttpd 的架构。现在，让我们探讨如何在生产环境中有效地监控、调试和运维 vhttpd 应用。可观测性是保障服务稳定运行的关键。

---

## Admin Plane 概览

vhttpd 提供了一个完整的 Admin Plane（管理平面），让运维人员可以：
- 实时查看运行时状态
- 监控关键指标
- 执行管理操作
- 调试问题

### 启用 Admin Plane

```toml
[admin]
host = "127.0.0.1"
port = 19981
token = "change-me-in-production"
```

### 访问控制

大多数端点需要认证：

```bash
curl -H 'x-vhttpd-admin-token: your-token' \
  http://127.0.0.1:19981/admin/runtime
```

---

## 核心监控端点

### 1. 运行时摘要

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime | jq .
```

返回：

```json
{
  "worker_pool_size": 4,
  "worker_available": 3,
  "worker_queue_length": 0,
  "worker_queue_capacity": 100,
  "http_requests_total": 1523,
  "http_requests_ok": 1500,
  "http_requests_error": 23,
  "stream_requests_total": 45,
  "websocket_connections": 2,
  "active_upstreams": 1,
  "mcp_sessions": 5,
  "stream_dispatch": true,
  "websocket_dispatch": true,
  "mcp_dispatch": true,
  "uptime_seconds": 86400,
  "memory_mb": 128
}
```

**关键指标解读**：

| 指标 | 说明 | 告警阈值建议 |
|------|------|---------------|
| `worker_available` | 可用 Worker 数量 | < 1 持续超过 1 分钟 |
| `worker_queue_length` | 等待中的请求 | > 10 |
| `http_requests_error` | 错误请求数 | 任何非零值 |
| `websocket_connections` | 活跃 WebSocket | 接近上限 |
| `mcp_sessions` | MCP 会话数 | 接近 `max_sessions` |

### 2. Worker 状态

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/workers | jq .
```

返回：

```json
{
  "workers": [
    {
      "id": 0,
      "pid": 12345,
      "status": "idle",
      "request_count": 523,
      "uptime_seconds": 3600,
      "memory_mb": 64
    },
    {
      "id": 1,
      "pid": 12346,
      "status": "busy",
      "request_count": 487,
      "uptime_seconds": 3600,
      "memory_mb": 72
    }
  ],
  "pool_size": 4,
  "total_requests": 2010
}
```

### 3. 运行时统计

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/stats | jq .
```

返回：

```json
{
  "requests": {
    "total": 1523,
    "ok": 1500,
    "error": 23,
    "rate_1m": 25.5,
    "rate_5m": 22.3
  },
  "latency_ms": {
    "p50": 15,
    "p95": 45,
    "p99": 120
  },
  "errors": {
    "worker_timeout": 5,
    "worker_queue_full": 3,
    "upstream_error": 15
  }
}
```

---

## 上游连接监控

### WebSocket 上游状态

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime/upstreams/websocket | jq .
```

返回：

```json
{
  "connections": [
    {
      "provider": "feishu",
      "instance": "main",
      "status": "connected",
      "connected_at": "2024-01-15T10:00:00Z",
      "reconnect_count": 0,
      "messages_received": 1250,
      "messages_sent": 890
    }
  ],
  "total": 1
}
```

### 查看上游事件

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime/upstreams/websocket/events | jq .
```

返回最近的 WebSocket 事件：

```json
{
  "events": [
    {
      "ts": "2024-01-15T10:30:00Z",
      "kind": "upstream.connect",
      "provider": "feishu",
      "instance": "main"
    },
    {
      "ts": "2024-01-15T10:30:01Z",
      "kind": "upstream.message.receive",
      "provider": "feishu",
      "message_type": "text"
    },
    {
      "ts": "2024-01-15T10:30:05Z",
      "kind": "upstream.message.send",
      "provider": "feishu",
      "success": true
    }
  ]
}
```

### 发送测试消息

```bash
curl -X POST \
  -H 'x-vhttpd-admin-token: xxx' \
  -H 'Content-Type: application/json' \
  -d '{
    "provider": "feishu",
    "instance": "main",
    "chat_id": "test_chat_id",
    "message_type": "text",
    "text": "Test message from admin"
  }' \
  http://127.0.0.1:19981/admin/runtime/upstreams/websocket/send | jq .
```

---

## MCP 监控

### MCP 会话状态

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime/mcp | jq .
```

返回：

```json
{
  "sessions": [
    {
      "id": "sess_abc123",
      "created_at": "2024-01-15T09:00:00Z",
      "last_activity": "2024-01-15T10:30:00Z",
      "request_count": 25,
      "tools_called": [
        {"name": "read_file", "count": 10},
        {"name": "write_file", "count": 5}
      ]
    }
  ],
  "total": 5,
  "max_sessions": 1000
}
```

### MCP 事件日志

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime/mcp/events | jq .
```

---

## 飞书运行时监控

### 飞书连接状态

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime/feishu | jq .
```

返回：

```json
{
  "instances": [
    {
      "name": "main",
      "status": "connected",
      "connected_at": "2024-01-15T10:00:00Z",
      "tenant_count": 1,
      "messages_total": 2340,
      "error_count": 0
    }
  ]
}
```

### 飞书群聊列表

```bash
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/runtime/feishu/chats | jq .
```

### 发送飞书消息

```bash
curl -X POST \
  -H 'x-vhttpd-admin-token: xxx' \
  -H 'Content-Type: application/json' \
  -d '{
    "instance": "main",
    "chat_id": "oc_xxx",
    "message_type": "text",
    "content": {"text": "系统消息"}
  }' \
  http://127.0.0.1:19981/admin/runtime/feishu/messages | jq .
```

---

## 事件日志系统

### 配置

```toml
[files]
event_log = "/var/log/vhttpd/events.ndjson"
```

### 日志格式

每个事件都是 NDJSON 格式：

```json
{"ts":"2024-01-15T10:30:00Z","kind":"http.request","method":"GET","path":"/api/users","status":200,"duration_ms":15}
{"ts":"2024-01-15T10:30:01Z","kind":"worker.request","worker_id":0,"request_id":"req_abc123","duration_ms":45}
{"ts":"2024-01-15T10:30:05Z","kind":"upstream.connect","provider":"feishu","instance":"main","url":"wss://..."}
{"ts":"2024-01-15T10:30:10Z","kind":"error","code":"worker_timeout","request_id":"req_def456","message":"..."}
```

### 日志类型

| Kind | 说明 |
|-------|------|
| `http.request` | HTTP 请求 |
| `worker.request` | Worker 请求 |
| `worker.start` | Worker 启动 |
| `worker.stop` | Worker 停止 |
| `worker.error` | Worker 错误 |
| `upstream.connect` | 上游连接 |
| `upstream.close` | 上游断开 |
| `upstream.message` | 上游消息 |
| `error` | 错误 |
| `mcp.session.create` | MCP 会话创建 |
| `mcp.session.close` | MCP 会话关闭 |

### 日志分析命令

```bash
# 实时查看日志
tail -f /var/log/vhttpd/events.ndjson | jq .

# 统计错误
cat /var/log/vhttpd/events.ndjson | jq 'select(.kind == "error")' | wc -l

# 分析请求路径
cat /var/log/vhttpd/events.ndjson | jq 'select(.kind == "http.request")' | jq -r '.path' | sort | uniq -c | sort -rn

# 分析响应时间
cat /var/log/vhttpd/events.ndjson | jq 'select(.kind == "http.request" and .duration_ms > 100)' | jq .

# 分析上游连接
cat /var/log/vhttpd/events.ndjson | jq 'select(.kind | startswith("upstream"))' | jq -r '"[\(.ts)] \(.kind) - \(.provider // "")"'

# 导出特定时间范围的日志
cat /var/log/vhttpd/events.ndjson | \
  jq 'select(.ts >= "2024-01-15T10:00:00Z" and .ts <= "2024-01-15T11:00:00Z")' \
  > /tmp/hourly_logs.ndjson
```

---

## Worker 操作

### 重启单个 Worker

```bash
curl -X POST \
  -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/workers/restart \
  -d '{"worker_id": 0}' | jq .
```

### 重启所有 Worker

```bash
curl -X POST \
  -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19981/admin/workers/restart/all | jq .
```

**响应**：

```json
{
  "ok": true,
  "message": "All workers restarted",
  "workers": [12347, 12348, 12349, 12350]
}
```

---

## Prometheus 集成

### 配置 Prometheus 端点

创建 `prometheus.yml`：

```yaml
scrape_configs:
  - job_name: 'vhttpd'
    static_configs:
      - targets: ['localhost:19981']
    metrics_path: '/admin/metrics'
    headers:
      x-vhttpd-admin-token: 'your-token'
```

### 自定义 Metrics

你可以在应用中添加自定义 metrics：

```php
<?php
// 在 PHP Worker 中
VPhp\VHttpd\Metrics::increment('app_requests_total', ['endpoint' => '/api/users']);
VPhp\VHttpd\Metrics::gauge('app_active_users', $userCount);
VPhp\VHttpd\Metrics::histogram('app_request_duration_ms', $duration, ['endpoint' => '/api/users']);
```

---

## 日志轮转

### 配置 logrotate

创建 `/etc/logrotate.d/vhttpd`：

```
/var/log/vhttpd/*.ndjson {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        # 通知 vhttpd 重新打开日志文件
        kill -USR1 $(cat /var/run/vhttpd.pid)
    endscript
}
```

### 日志归档策略

| 类型 | 保留时间 | 说明 |
|------|----------|------|
| 实时日志 | 7 天 | 详细事件 |
| 压缩日志 | 30 天 | 用于问题排查 |
| 统计摘要 | 90 天 | 用于趋势分析 |

---

## 告警配置

### 推荐告警规则

```yaml
groups:
  - name: vhttpd
    rules:
      # Worker 池耗尽
      - alert: VhttpdNoIdleWorkers
        expr: vhttpd_worker_available == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "No idle workers available"
          description: "All {{ $value }} workers are busy"

      # Worker 队列积压
      - alert: VhttpdWorkerQueueBacklog
        expr: vhttpd_worker_queue_length > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Worker queue backlog"
          description: "Queue has {{ $value }} pending requests"

      # 高错误率
      - alert: VhttpdHighErrorRate
        expr: rate(vhttpd_http_requests_error[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate"
          description: "Error rate is {{ $value }} per second"

      # 上游连接断开
      - alert: VhttpdUpstreamDisconnected
        expr: vhttpd_upstream_connected == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Upstream disconnected"
          description: "{{ $labels.provider }} connection is down"

      # MCP 会话数高
      - alert: VhttpdMcpSessionNearLimit
        expr: vhttpd_mcp_sessions > 900
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MCP sessions near limit"
          description: "{{ $value }} sessions (limit: 1000)"
```

---

## 故障排查指南

### 1. Worker 无响应

**症状**：请求堆积，响应缓慢

**排查步骤**：

```bash
# 1. 查看 Worker 状态
curl http://127.0.0.1:19981/admin/workers | jq .

# 2. 查看 Worker 日志
tail -f /var/log/vhttpd/worker.log

# 3. 查看事件日志中的错误
cat /var/log/vhttpd/events.ndjson | jq 'select(.kind == "worker.error")'

# 4. 重启问题 Worker
curl -X POST -H 'x-vhttpd-admin-token: xxx' \
  -d '{"worker_id": 0}' \
  http://127.0.0.1:19981/admin/workers/restart
```

**常见原因**：
- PHP 代码死循环
- 数据库连接超时
- 内存泄漏

### 2. 上游连接频繁断开

**症状**：飞书/Ollama 连接不断重连

**排查步骤**：

```bash
# 1. 查看上游连接状态
curl http://127.0.0.1:19981/admin/runtime/upstreams/websocket | jq .

# 2. 查看上游事件日志
curl http://127.0.0.1:19981/admin/runtime/upstreams/websocket/events | jq .

# 3. 测试上游服务连通性
curl -v http://localhost:11434/api/tags
```

**常见原因**：
- 上游服务不可用
- 网络不稳定
- Token 过期

### 3. MCP 会话无法创建

**症状**：MCP 客户端连接失败

**排查步骤**：

```bash
# 1. 查看 MCP 状态
curl http://127.0.0.1:19981/admin/runtime/mcp | jq .

# 2. 检查 Worker 是否正常
curl http://127.0.0.1:19981/admin/workers | jq '.workers[] | select(.status == "busy")'

# 3. 查看 MCP 错误日志
cat /var/log/vhttpd/events.ndjson | jq 'select(.kind | contains("mcp"))'
```

### 4. 内存持续增长

**症状**：vhttpd 进程内存不断增长

**排查步骤**：

```bash
# 1. 监控内存使用
watch -n 5 'curl -s http://127.0.0.1:19981/admin/runtime | jq .memory_mb'

# 2. 检查 Worker 内存
curl http://127.0.0.1:19981/admin/workers | jq '.workers[].memory_mb'

# 3. 限制 Worker 最大请求数
# 在配置中设置 max_requests
```

**解决方案**：
- 设置 `max_requests` 定期重启 Worker
- 优化 PHP 代码，减少内存占用
- 增加 Worker 池大小分担压力

---

## 性能调优

### 1. Worker 池配置

```toml
[worker]
pool_size = 4              # 推荐：CPU 核心数 * 2
max_requests = 5000         # 定期重启避免内存泄漏
restart_backoff_ms = 500   # 重连退避时间
restart_backoff_max_ms = 8000
```

### 2. 超时配置

```toml
[worker]
read_timeout_ms = 3000     # 普通请求超时
```

对于 AI 流式请求：

```toml
[worker]
read_timeout_ms = 60000    # 1 分钟
```

### 3. 队列配置

```toml
[worker]
queue_capacity = 100       # 队列容量
queue_timeout_ms = 5000    # 队列等待超时
```

### 4. MCP 配置

```toml
[mcp]
max_sessions = 1000        # 最大并发会话
session_ttl_seconds = 900  # 会话超时
max_pending_messages = 128
```

---

## 健康检查

### 创建健康检查端点

在你的 PHP 应用中：

```php
<?php

return [
    'http' => static function ($req) {
        $checks = [
            'status' => 'ok',
            'timestamp' => time(),
            'version' => '1.0.0',
        ];

        // 数据库检查
        try {
            $pdo = new PDO('mysql:host=localhost;dbname=app', 'user', 'pass');
            $checks['database'] = 'ok';
        } catch (Exception $e) {
            $checks['database'] = 'error';
            $checks['status'] = 'degraded';
        }

        $status = $checks['status'] === 'ok' ? 200 : 503;
        return [
            'status' => $status,
            'content_type' => 'application/json',
            'body' => json_encode($checks),
        ];
    },
];
```

### 配置负载均衡器健康检查

```yaml
# Nginx upstream 健康检查
upstream vhttpd {
    server 127.0.0.1:19881;
    server 127.0.0.1:19882;
    server 127.0.0.1:19883;
}

# Kubernetes readiness probe
readinessProbe:
  httpGet:
    path: /health
    port: 19881
  initialDelaySeconds: 5
  periodSeconds: 10
```

---

## 备份和恢复

### 配置文件备份

```bash
#!/bin/bash
# backup.sh

BACKUP_DIR="/var/backups/vhttpd"
DATE=$(date +%Y%m%d_%H%M%S)

# 备份配置
mkdir -p $BACKUP_DIR
cp /etc/vhttpd/*.toml $BACKUP_DIR/config_$DATE/

# 备份数据库（如果使用）
if [ -f /var/lib/vhttpd/codexbot.db ]; then
    cp /var/lib/vhttpd/codexbot.db $BACKUP_DIR/db_$DATE
fi

# 保留最近 30 天
find $BACKUP_DIR -mtime +30 -delete
```

---

## 下一步

在下一篇文章中，我们将探讨 **高级模式**，包括：
- 多监听器配置
- 数据库连接池托管
- Paseo Relay 实战

如果你想继续探索，可以：
- 查看 Admin API 的完整实现
- 配置 Prometheus + Grafana 可视化
- 集成到你的监控平台

---

## 相关资源

- [Admin Plane 端点](file:///workspace/docs/OVERVIEW.md#admin-plane-paths)
- [运行时配置](file:///workspace/config/vhttpd.example.toml)
- [Prometheus 告警规则示例](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
