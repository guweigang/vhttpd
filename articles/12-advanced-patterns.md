# 高级模式：多监听器、数据库连接池与高级集成

在前面的文章中，我们了解了 vhttpd 的可观测性。现在，让我们探索一些高级使用模式，包括多监听器配置、数据库连接池托管，以及与其他系统的集成。

---

## 多监听器模式

vhttpd 支持在同一个进程中监听多个端口，每个端口可以配置不同的应用。这在以下场景特别有用：

- 开发/测试/生产环境共用一个进程
- 不同协议使用不同端口
- 微服务架构中的服务聚合

### 配置示例

```toml
# 主配置：server
[server]
host = "0.0.0.0"
port = 8080

[worker]
autostart = true
pool_size = 4

[worker.env]
VHTTPD_APP = "/path/to/main-app.php"

# 辅助监听器配置
[[listeners]]
name = "admin"
host = "127.0.0.1"
port = 8081
mode = "admin"
token = "admin-secret-token"

[[listeners]]
name = "metrics"
host = "0.0.0.0"
port = 9090
mode = "metrics"

[[listeners]]
name = "ai-stream"
host = "0.0.0.0"
port = 8082
worker_pool_size = 8
worker_timeout_ms = 60000
VHTTPD_APP = "/path/to/ai-app.php"
```

### 不同应用的端口分配

```toml
# 主应用：公共 API
[server]
port = 8080

# AI 流式应用：需要更多 Worker 和更长超时
[[listeners]]
name = "ai-stream"
port = 8082
pool_size = 8
read_timeout_ms = 120000

# MCP 应用
[[listeners]]
name = "mcp"
port = 8083
pool_size = 4

# Admin Plane
[[listeners]]
name = "admin"
port = 8081
mode = "internal"
```

### 路由到不同的监听器

```php
<?php
// main-app.php
return [
    'http' => function ($req) {
        $path = $req['path'] ?? '/';

        if (str_starts_with($path, '/api/')) {
            return handleApi($req);
        }

        if (str_starts_with($path, '/webhook/')) {
            return handleWebhook($req);
        }

        return [
            'status' => 404,
            'content_type' => 'text/plain',
            'body' => 'Not Found',
        ];
    },
];
```

---

## 数据库连接池托管

### 为什么需要连接池托管？

传统的 PHP-FPM 模式下，每个请求都会创建新的数据库连接，导致：
- 连接建立开销大
- 数据库连接数快速增长
- 连接复用率低

vhttpd 的 Worker 是长期运行的，适合托管数据库连接池。

### 实现连接池托管

```php
<?php

class DatabasePoolManager
{
    private static ?PDO $pool = null;
    private static array $config = [];

    public static function configure(array $config): void
    {
        self::$config = $config;
    }

    public static function getConnection(): PDO
    {
        if (self::$pool === null) {
            $dsn = sprintf(
                'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
                self::$config['host'],
                self::$config['port'],
                self::$config['database']
            );

            self::$pool = new PDO($dsn, self::$config['user'], self::$config['password'], [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
        }

        return self::$pool;
    }

    public static function query(string $sql, array $params = []): array
    {
        $pdo = self::getConnection();
        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        return $stmt->fetchAll();
    }

    public static function execute(string $sql, array $params = []): int
    {
        $pdo = self::getConnection();
        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        return $stmt->rowCount();
    }
}

// Worker 启动时初始化
return [
    'init' => function () {
        DatabasePoolManager::configure([
            'host' => getenv('DB_HOST') ?: 'localhost',
            'port' => (int)(getenv('DB_PORT') ?: 3306),
            'database' => getenv('DB_NAME') ?: 'app',
            'user' => getenv('DB_USER') ?: 'root',
            'password' => getenv('DB_PASSWORD') ?: '',
        ]);
    },

    'http' => function ($req) {
        $path = $req['path'] ?? '/';

        if ($path === '/users') {
            $users = DatabasePoolManager::query(
                'SELECT * FROM users ORDER BY created_at DESC LIMIT 100'
            );
            return [
                'status' => 200,
                'content_type' => 'application/json',
                'body' => json_encode(['users' => $users]),
            ];
        }

        return ['status' => 404, 'body' => 'Not Found'];
    },
];
```

### 配置数据库连接池

```toml
[worker]
autostart = true
pool_size = 4

[worker.env]
DB_HOST = "localhost"
DB_PORT = "3306"
DB_NAME = "vhttpd_app"
DB_USER = "app_user"
DB_PASSWORD = "secure-password"

[database_pool]
enabled = true
max_connections = 20
min_connections = 2
idle_timeout_seconds = 300
max_lifetime_seconds = 3600
```

### PostgreSQL 连接池

```php
<?php

class PgConnectionPool
{
    private static ?PgPool $pool = null;
    private static array $config = [];

    public static function configure(array $config): void
    {
        self::$config = $config;
    }

    public static function getConnection(): PgPool
    {
        if (self::$pool === null) {
            self::$pool = pg_connect(self::$config['connection_string']);
        }
        return self::$pool;
    }

    public static function query(string $sql, array $params = []): array
    {
        $result = pg_query_params(self::getConnection(), $sql, $params);
        return pg_fetch_all($result) ?: [];
    }
}
```

---

## Paseo Relay 模式

### 什么是 Paseo？

Paseo 是一个轻量级的消息中继协议，用于在不同 vhttpd 实例之间转发消息，特别适合：
- 分布式部署
- 跨区域服务通信
- 微服务间事件传递

### 配置 Paseo Relay

```toml
[paseo]
enabled = true
mode = "relay"  # relay | client | standalone
bind = "0.0.0.0:9090"
upstream = "http://relay-server:9090"
token = "paseo-secret-token"
heartbeat_interval_seconds = 30
reconnect_delay_ms = 1000

[paseo.routes]
"chat:*" = "broadcast"
"user:*" = "unicast"
"event:*" = "fanout"
```

### 使用 Paseo 发送消息

```php
<?php

class PaseoRelay
{
    private string $relayUrl;
    private string $token;

    public function __construct(string $relayUrl, string $token)
    {
        $this->relayUrl = $relayUrl;
        $this->token = $token;
    }

    public function send(string $channel, array $message): bool
    {
        $ch = curl_init($this->relayUrl . '/publish');
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => json_encode([
                'channel' => $channel,
                'message' => $message,
            ]),
            CURLOPT_HTTPHEADER => [
                'Content-Type: application/json',
                'Authorization: Bearer ' . $this->token,
            ],
            CURLOPT_RETURNTRANSFER => true,
        ]);

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        return $httpCode === 200;
    }

    public function subscribe(string $channel, callable $callback): void
    {
        // SSE 订阅通道
        $ch = curl_init($this->relayUrl . '/subscribe?' . http_build_query([
            'channel' => $channel,
        ]));
        curl_setopt_array($ch, [
            CURLOPT_HTTPHEADER => [
                'Authorization: Bearer ' . $this->token,
            ],
            CURLOPT_WRITEFUNCTION => function ($ch, $chunk) use ($callback) {
                $data = json_decode($chunk, true);
                if ($data) {
                    $callback($data);
                }
                return strlen($chunk);
            },
        ]);

        curl_exec($ch);
    }
}

// 在 Worker 中使用
$paseo = new PaseoRelay(
    getenv('PASEO_RELAY_URL'),
    getenv('PASEO_TOKEN')
);

// 发送消息
$paseo->send('chat:general', [
    'type' => 'message',
    'from' => 'user123',
    'content' => 'Hello from vhttpd!',
]);
```

### Paseo 事件处理

```php
<?php

return [
    'http' => function ($req) {
        return ['status' => 200, 'body' => 'OK'];
    },

    'paseo' => function ($event) {
        $channel = $event['channel'] ?? '';
        $message = $event['message'] ?? [];

        switch ($channel) {
            case 'chat:general':
                return handleChatMessage($message);

            case 'user:login':
                return handleUserLogin($message);

            case 'event:notification':
                return handleNotification($message);

            default:
                return ['handled' => false];
        }
    },
];

function handleChatMessage(array $message): array
{
    $content = $message['content'] ?? '';
    $from = $message['from'] ?? 'anonymous';

    // 记录消息
    logChatMessage($from, $content);

    // 广播到相关频道
    return [
        'handled' => true,
        'actions' => [
            ['type' => 'broadcast', 'channel' => 'chat:logs', 'message' => $message],
        ],
    ];
}
```

---

## 服务网格集成

### 与 Envoy 集成

```yaml
# envoy.yaml
static_resources:
  listeners:
    - name: vhttpd_listener
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 8080
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                codec_type: AUTO
                route_config:
                  virtual_hosts:
                    - name: vhttpd_service
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route:
                            cluster: vhttpd_cluster
                http_filters:
                  - name: envoy.filters.http.router

    - name: metrics_listener
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 9901
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                codec_type: AUTO
                route_config:
                  virtual_hosts:
                    - name: admin_service
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/admin" }
                          route:
                            cluster: vhttpd_admin_cluster

  clusters:
    - name: vhttpd_cluster
      type: STRICT_DNS
      lb_policy: ROUND_ROBIN
      hosts:
        - socket_address:
            address: vhttpd
            port_value: 8080
      health_checks:
        - timeout: 5s
          interval: 10s
          unhealthy_threshold: 3
          healthy_threshold: 2
          http_health_check:
            path: "/health"

    - name: vhttpd_admin_cluster
      type: STRICT_DNS
      hosts:
        - socket_address:
            address: vhttpd
            port_value: 8081
```

### 与 Kubernetes 集成

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vhttpd
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vhttpd
  template:
    metadata:
      labels:
        app: vhttpd
    spec:
      containers:
        - name: vhttpd
          image: vhttpd:v1.0.0
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 8081
              name: admin
          env:
            - name: VHTTPD_APP
              value: "/app/main.php"
            - name: WORKER_POOL_SIZE
              value: "4"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
```

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: vhttpd
spec:
  selector:
    app: vhttpd
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: admin
      port: 8081
      targetPort: 8081
  type: LoadBalancer
```

---

## WebSocket 集群

### Sticky Sessions

```toml
[websocket]
enabled = true
port = 8080

[websocket.sticky]
enabled = true
cookie_name = "vhttpd_ws_id"
cookie_ttl_seconds = 3600

[websocket.upstream]
enabled = true
strategy = "consistent_hash"
nodes = [
    "ws://vhttpd-1:8080",
    "ws://vhttpd-2:8080",
    "ws://vhttpd-3:8080"
]
```

### WebSocket 消息广播

```php
<?php

class WebSocketBroadcaster
{
    private array $connections = [];

    public function register(string $roomId, string $connectionId): void
    {
        if (!isset($this->connections[$roomId])) {
            $this->connections[$roomId] = [];
        }
        $this->connections[$roomId][$connectionId] = true;
    }

    public function unregister(string $roomId, string $connectionId): void
    {
        unset($this->connections[$roomId][$connectionId]);
    }

    public function broadcast(string $roomId, array $message, ?string $exceptId = null): int
    {
        $count = 0;
        foreach ($this->connections[$roomId] ?? [] as $connectionId => $_) {
            if ($connectionId !== $exceptId) {
                $this->send($connectionId, $message);
                $count++;
            }
        }
        return $count;
    }

    public function broadcastAll(array $message): int
    {
        $count = 0;
        foreach ($this->connections as $roomId => $connections) {
            foreach ($connections as $connectionId => $_) {
                $this->send($connectionId, $message);
                $count++;
            }
        }
        return $count;
    }

    private function send(string $connectionId, array $message): void
    {
        // 通过 WebSocket 连接发送消息
    }
}

$broadcaster = new WebSocketBroadcaster();

return [
    'websocket' => function ($frame) use ($broadcaster) {
        switch ($frame['event']) {
            case 'join':
                $roomId = $frame['room'] ?? 'default';
                $connectionId = $frame['id'];
                $broadcaster->register($roomId, $connectionId);
                return ['accepted' => true];

            case 'leave':
                $roomId = $frame['room'] ?? 'default';
                $connectionId = $frame['id'];
                $broadcaster->unregister($roomId, $connectionId);
                return ['accepted' => true];

            case 'message':
                $roomId = $frame['room'] ?? 'default';
                $message = $frame['data'];
                $connectionId = $frame['id'];
                $broadcaster->broadcast($roomId, [
                    'event' => 'message',
                    'from' => $connectionId,
                    'data' => $message,
                ], $connectionId);
                return ['accepted' => true];

            default:
                return ['accepted' => false];
        }
    },
];
```

---

## 缓存层集成

### Redis 缓存

```php
<?php

class RedisCache
{
    private ?Redis $redis = null;
    private array $config;

    public function __construct(array $config)
    {
        $this->config = $config;
    }

    private function getConnection(): Redis
    {
        if ($this->redis === null) {
            $this->redis = new Redis();
            $this->redis->connect(
                $this->config['host'],
                $this->config['port']
            );

            if (!empty($this->config['password'])) {
                $this->redis->auth($this->config['password']);
            }

            if (!empty($this->config['database'])) {
                $this->redis->select($this->config['database']);
            }
        }

        return $this->redis;
    }

    public function get(string $key, $default = null)
    {
        $value = $this->getConnection()->get($key);
        return $value !== false ? unserialize($value) : $default;
    }

    public function set(string $key, $value, int $ttl = 0): bool
    {
        $value = serialize($value);
        if ($ttl > 0) {
            return $this->getConnection()->setex($key, $ttl, $value);
        }
        return $this->getConnection()->set($key, $value);
    }

    public function delete(string $key): bool
    {
        return $this->getConnection()->del($key) > 0;
    }

    public function exists(string $key): bool
    {
        return $this->getConnection()->exists($key) > 0;
    }

    public function remember(string $key, int $ttl, callable $callback)
    {
        if ($this->exists($key)) {
            return $this->get($key);
        }

        $value = $callback();
        $this->set($key, $value, $ttl);
        return $value;
    }
}

// 使用缓存
$cache = new RedisCache([
    'host' => getenv('REDIS_HOST') ?: 'localhost',
    'port' => (int)(getenv('REDIS_PORT') ?: 6379),
    'password' => getenv('REDIS_PASSWORD') ?: null,
    'database' => 0,
]);

return [
    'http' => function ($req) use ($cache) {
        $path = $req['path'] ?? '/';

        if ($path === '/api/users') {
            $users = $cache->remember('users:all', 300, function () {
                return DatabasePoolManager::query('SELECT * FROM users');
            });

            return [
                'status' => 200,
                'content_type' => 'application/json',
                'body' => json_encode(['users' => $users]),
            ];
        }

        return ['status' => 404, 'body' => 'Not Found'];
    },
];
```

### Memcached 缓存

```php
<?php

class MemcachedCache
{
    private ?Memcached $memcached = null;
    private array $config;

    public function __construct(array $config)
    {
        $this->config = $config;
    }

    private function getConnection(): Memcached
    {
        if ($this->memcached === null) {
            $this->memcached = new Memcached();
            $this->memcached->addServer(
                $this->config['host'],
                $this->config['port']
            );
        }

        return $this->memcached;
    }

    public function get(string $key, $default = null)
    {
        $value = $this->getConnection()->get($key);
        return $value !== false ? $value : $default;
    }

    public function set(string $key, $value, int $ttl = 0): bool
    {
        return $this->getConnection()->set($key, $value, $ttl);
    }

    public function delete(string $key): bool
    {
        return $this->getConnection()->delete($key);
    }
}
```

---

## 速率限制

### 实现速率限制中间件

```php
<?php

class RateLimiter
{
    private Redis $redis;
    private int $maxRequests;
    private int $windowSeconds;

    public function __construct(Redis $redis, int $maxRequests, int $windowSeconds)
    {
        $this->redis = $redis;
        $this->maxRequests = $maxRequests;
        $this->windowSeconds = $windowSeconds;
    }

    public function check(string $identifier): array
    {
        $key = "rate_limit:{$identifier}";
        $now = time();
        $windowStart = $now - $this->windowSeconds;

        // 移除过期记录
        $this->redis->zremrangebyscore($key, 0, $windowStart);

        // 获取当前请求数
        $count = $this->redis->zcard($key);

        if ($count >= $this->maxRequests) {
            $oldest = $this->redis->zrange($key, 0, 0, ['WITHSCORES' => true]);
            $retryAfter = $oldest ? (int)($oldest[0] + $this->windowSeconds - $now) : $this->windowSeconds;

            return [
                'allowed' => false,
                'remaining' => 0,
                'retry_after' => $retryAfter,
            ];
        }

        // 添加当前请求
        $this->redis->zadd($key, $now, "{$now}:{$this->generateId()}");
        $this->redis->expire($key, $this->windowSeconds);

        return [
            'allowed' => true,
            'remaining' => $this->maxRequests - $count - 1,
            'retry_after' => 0,
        ];
    }

    private function generateId(): string
    {
        return bin2hex(random_bytes(8));
    }
}

// 使用速率限制
$rateLimiter = new RateLimiter($redis, 100, 60); // 100 请求/分钟

return [
    'http' => function ($req) use ($rateLimiter) {
        $identifier = $req['headers']['x-forwarded-for'] ?? $req['ip'] ?? 'unknown';

        $result = $rateLimiter->check($identifier);

        $response = [
            'status' => $result['allowed'] ? 200 : 429,
            'headers' => [
                'X-RateLimit-Limit' => 100,
                'X-RateLimit-Remaining' => $result['remaining'],
                'X-RateLimit-Reset' => time() + 60,
            ],
        ];

        if (!$result['allowed']) {
            $response['body'] = json_encode([
                'error' => 'Too Many Requests',
                'retry_after' => $result['retry_after'],
            ]);
            return $response;
        }

        // 处理正常请求
        return array_merge($response, [
            'content_type' => 'application/json',
            'body' => json_encode(['message' => 'Hello!']),
        ]);
    },
];
```

### 配置速率限制

```toml
[rate_limit]
enabled = true
default_limit = 100
default_window_seconds = 60

[[rate_limit.rules]]
path_prefix = "/api/"
limit = 1000
window_seconds = 60

[[rate_limit.rules]]
path_prefix = "/api/stream/"
limit = 10
window_seconds = 60

[[rate_limit.rules]]
path = "/health"
limit = 10000
window_seconds = 60
```

---

## 下一步

恭喜你！已经完成了 vhttpd 系列文章的学习。在最后一篇文章中，我们将探讨 **真实案例和未来展望**。

如果你想继续探索，可以：
- 查看项目中完整的配置示例
- 部署自己的 vhttpd 集群
- 尝试不同的集成模式

---

## 相关资源

- [多监听器配置示例](file:///workspace/examples/config/)
- [数据库连接配置](file:///workspace/config/vhttpd.example.toml)
- [Paseo Relay 配置](file:///workspace/examples/config/feishu-paseo.toml)
- [服务网格集成指南](https://www.envoyproxy.io/docs/envoy/latest)
