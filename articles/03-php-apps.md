# 让 PHP 应用重获新生：Laravel/Symfony/WordPress 迁移指南

在第二篇文章中，我们学会了如何运行一个简单的 vhttpd 应用。现在，让我们探索如何将现有的、成熟的 PHP 框架应用迁移到 vhttpd 上，享受现代运行时的好处，同时保留你熟悉的开发体验。

---

## 为什么要在 vhttpd 上运行 PHP 应用？

传统的 `nginx + PHP-FPM` 架构在处理以下场景时会遇到挑战：

1. **长连接和流式响应** - SSE、WebSocket 需要特殊的配置和处理
2. **Worker 生命周期管理** - PHP-FPM 的进程管理相对有限
3. **可观测性** - 需要额外的工具来监控 worker 状态、队列等
4. **AI 流式应用** - Token 流式输出需要复杂的配置避免缓冲

vhttpd 提供了一个统一的解决方案，同时保持 PHP 生态的完整性。

---

## 核心设计理念：互补而非替代

vhttpd 不是要替代 Laravel、Symfony 或 WordPress，而是要**补充**它们。

```
传统架构:
nginx -> PHP-FPM -> PHP 应用

vhttpd 架构:
vhttpd (协议层/运行时) -> php-worker -> PHP 应用
```

关键区别：
- **vhttpd** 负责：HTTP/SSE/WebSocket 连接管理、Worker 池调度、流生命周期、可观测性
- **PHP 应用** 负责：业务逻辑、框架功能、保持原样

---

## Laravel 集成实战

让我们从最流行的 PHP 框架 Laravel 开始。

### 1. 准备 Laravel 应用

首先，让我们查看项目中已有的 Laravel 示例：

```bash
cd examples/laravel
composer install
```

### 2. 理解集成代码

查看 [`laravel/app.php`](file:///workspace/examples/laravel/app.php)：

```php
<?php
declare(strict_types=1);

require_once __DIR__ . '/vendor/autoload.php';

use Illuminate\Container\Container;
use Illuminate\Events\Dispatcher;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Routing\Router;
use Nyholm\Psr7\Factory\Psr17Factory;
use Psr\Http\Message\ServerRequestInterface;
use Symfony\Bridge\PsrHttpMessage\Factory\HttpFoundationFactory;
use Symfony\Bridge\PsrHttpMessage\Factory\PsrHttpFactory;

return static function (ServerRequestInterface $request, array $envelope = []): object {
    static $router = null;
    static $httpFoundationFactory = null;
    static $psrHttpFactory = null;

    if ($router === null) {
        $container = new Container();
        Container::setInstance($container);
        $container->bind(
            \Illuminate\Routing\Contracts\CallableDispatcher::class,
            \Illuminate\Routing\CallableDispatcher::class
        );
        $events = new Dispatcher($container);
        $router = new Router($events, $container);

        $router->get('/laravel/hello/{name}', static function (string $name): Response {
            return new Response('laravel:' . $name, 200, ['x-framework' => 'laravel']);
        });
        $router->get('/laravel/meta', static function (Request $request): JsonResponse {
            parse_str((string) $request->server('QUERY_STRING', ''), $query);
            return new JsonResponse([
                'framework' => 'laravel',
                'trace' => (string) ($query['trace_id'] ?? ''),
                'path' => $request->path(),
            ], 200, ['x-framework' => 'laravel']);
        });

        $psr17 = new Psr17Factory();
        $httpFoundationFactory = new HttpFoundationFactory();
        $psrHttpFactory = new PsrHttpFactory($psr17, $psr17, $psr17, $psr17);
    }

    $symfonyRequest = $httpFoundationFactory->createRequest($request);
    $illuminateRequest = Request::createFromBase($symfonyRequest);
    $illuminateResponse = $router->dispatch($illuminateRequest);

    return $psrHttpFactory->createResponse($illuminateResponse);
};
```

这个集成模式展示了几个关键点：
1. **使用 PSR-7 接口** - vhttpd 使用 PSR-7 标准请求/响应
2. **状态保持在 Worker 中** - `static` 变量在 worker 生命周期内保持
3. **请求转换** - PSR-7 ↔ Symfony HttpFoundation ↔ Illuminate Request
4. **响应转换** - Illuminate Response → Symfony HttpFoundation → PSR-7

### 3. 配置 vhttpd

查看 [`laravel.toml`](file:///workspace/examples/config/laravel.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19886

[files]
pid_file = "/tmp/vhttpd_laravel.pid"
event_log = "/tmp/vhttpd_laravel.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 3000
pool_size = 4
socket = "/tmp/vslim_laravel_worker.sock"
cmd = "php -d extension=/path/to/vslim/vslim.so /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/laravel/app.php"

[admin]
host = "127.0.0.1"
port = 19986
token = ""
```

### 4. 启动和测试

```bash
./vhttpd --config examples/config/laravel.toml
```

然后在另一个终端测试：

```bash
curl --noproxy '*' -i "http://127.0.0.1:19886/laravel/hello/nova"
curl --noproxy '*' -i "http://127.0.0.1:19886/laravel/meta?trace_id=demo"
```

---

## Symfony 集成实战

接下来看 Symfony 框架的集成。

### 1. 准备 Symfony 应用

```bash
cd examples/symfony
composer install
```

### 2. 理解集成代码

查看 [`symfony/app.php`](file:///workspace/examples/symfony/app.php)：

```php
<?php
declare(strict_types=1);

require_once __DIR__ . '/vendor/autoload.php';

use Nyholm\Psr7\Factory\Psr17Factory;
use Psr\Http\Message\ServerRequestInterface;
use Symfony\Bridge\PsrHttpMessage\Factory\HttpFoundationFactory;
use Symfony\Bridge\PsrHttpMessage\Factory\PsrHttpFactory;
use Symfony\Component\EventDispatcher\EventDispatcher;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Controller\ArgumentResolver;
use Symfony\Component\HttpKernel\Controller\ControllerResolver;
use Symfony\Component\HttpKernel\HttpKernel;
use Symfony\Component\Routing\Exception\ResourceNotFoundException;
use Symfony\Component\Routing\Matcher\UrlMatcher;
use Symfony\Component\Routing\RequestContext;
use Symfony\Component\Routing\Route;
use Symfony\Component\Routing\RouteCollection;

return static function (ServerRequestInterface $request, array $envelope = []): object {
    static $kernel = null;
    static $matcher = null;
    static $httpFoundationFactory = null;
    static $psrHttpFactory = null;

    if ($kernel === null) {
        $routes = new RouteCollection();
        $routes->add('hello', new Route('/symfony/hello/{name}', [
            '_controller' => static function (Request $request, string $name): Response {
                return new Response('symfony:' . $name, 200, ['x-framework' => 'symfony']);
            },
        ]));
        $routes->add('meta', new Route('/symfony/meta', [
            '_controller' => static function (Request $request): Response {
                return new JsonResponse([
                    'framework' => 'symfony',
                    'trace' => (string) $request->query->get('trace_id', ''),
                    'path' => $request->getPathInfo(),
                ], 200, ['x-framework' => 'symfony']);
            },
        ]));

        $matcher = new UrlMatcher($routes, new RequestContext());
        $kernel = new HttpKernel(new EventDispatcher(), new ControllerResolver(), null, new ArgumentResolver());

        $psr17 = new Psr17Factory();
        $httpFoundationFactory = new HttpFoundationFactory();
        $psrHttpFactory = new PsrHttpFactory($psr17, $psr17, $psr17, $psr17);
    }

    $symfonyRequest = $httpFoundationFactory->createRequest($request);
    $matcher->getContext()->fromRequest($symfonyRequest);

    try {
        $attributes = $matcher->match($symfonyRequest->getPathInfo());
        $symfonyRequest->attributes->add($attributes);
        $symfonyResponse = $kernel->handle($symfonyRequest);
    } catch (ResourceNotFoundException) {
        $symfonyResponse = new Response('Not Found', 404, ['x-framework' => 'symfony']);
    }

    return $psrHttpFactory->createResponse($symfonyResponse);
};
```

Symfony 集成的关键点：
1. **直接使用 Symfony HttpKernel** - 保持完整的 Symfony 体验
2. **路由可以复用现有配置** - 或者像示例一样定义在 app.php 中
3. **同样的 PSR-7 桥接模式** - 与 Laravel 类似

### 3. 启动和测试

```bash
./vhttpd --config examples/config/symfony.toml
```

测试：

```bash
curl --noproxy '*' -i "http://127.0.0.1:19885/symfony/hello/nova"
curl --noproxy '*' -i "http://127.0.0.1:19885/symfony/meta?trace_id=demo"
```

---

## WordPress 集成实战

对于像 WordPress 这样的传统 PHP 应用，集成方式略有不同。

### 1. 准备 WordPress

首先，你需要一个标准的 WordPress 安装。

### 2. WordPress 集成配置

查看 [`wordpress.toml`](file:///workspace/examples/config/wordpress.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19887

[files]
pid_file = "/tmp/vhttpd_wordpress.pid"
event_log = "/tmp/vhttpd_wordpress.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 3000
socket = "/tmp/vslim_wordpress.sock"
cmd = "php -d extension=/path/to/vslim/vslim.so /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/wordpress/app.php"
VSLIM_WP_ROOT = "/ABS/PATH/TO/WORDPRESS"

[admin]
host = "127.0.0.1"
port = 19987
token = ""
```

关键配置：
- `VSLIM_WP_ROOT` - 指向你的 WordPress 根目录

### 3. WordPress 集成代码

查看 [`wordpress/app.php`](file:///workspace/examples/wordpress/app.php)（你需要创建这个文件）：

```php
<?php
declare(strict_types=1);

use Nyholm\Psr7\Factory\Psr17Factory;
use Psr\Http\Message\ServerRequestInterface;
use Symfony\Bridge\PsrHttpMessage\Factory\HttpFoundationFactory;
use Symfony\Bridge\PsrHttpMessage\Factory\PsrHttpFactory;

return static function (ServerRequestInterface $request, array $envelope = []): object {
    static $httpFoundationFactory = null;
    static $psrHttpFactory = null;
    static $wpRoot = null;

    if ($wpRoot === null) {
        $wpRoot = getenv('VSLIM_WP_ROOT');
        if ($wpRoot === false) {
            throw new RuntimeException('VSLIM_WP_ROOT not set');
        }

        $psr17 = new Psr17Factory();
        $httpFoundationFactory = new HttpFoundationFactory();
        $psrHttpFactory = new PsrHttpFactory($psr17, $psr17, $psr17, $psr17);
    }

    // 将 PSR-7 请求转换为 PHP 全局变量
    $symfonyRequest = $httpFoundationFactory->createRequest($request);

    // 设置 $_GET、$_POST、$_SERVER 等
    $_GET = $symfonyRequest->query->all();
    $_POST = $symfonyRequest->request->all();
    $_SERVER['REQUEST_METHOD'] = $symfonyRequest->getMethod();
    $_SERVER['REQUEST_URI'] = $symfonyRequest->getPathInfo();
    $_SERVER['QUERY_STRING'] = $symfonyRequest->getQueryString();

    // 模拟 WordPress 环境
    ob_start();
    require $wpRoot . '/index.php';
    $content = ob_get_clean();

    // 创建响应
    $response = $psr17->createResponse();
    $response->getBody()->write($content);

    return $response;
};
```

### 4. 启动和测试

```bash
./vhttpd --config examples/config/wordpress.toml
```

然后访问 `http://127.0.0.1:19887` 来使用 WordPress。

---

## 迁移完整应用的通用模式

以上是简化的示例。对于完整应用，你可以使用以下通用模式：

### 完整 Laravel 应用集成

```php
<?php
require_once __DIR__ . '/vendor/autoload.php';

$app = require_once __DIR__ . '/bootstrap/app.php';

return static function (ServerRequestInterface $request, array $envelope = []) use ($app) {
    static $httpFoundationFactory = null;
    static $psrHttpFactory = null;

    if ($httpFoundationFactory === null) {
        $psr17 = new Psr17Factory();
        $httpFoundationFactory = new HttpFoundationFactory();
        $psrHttpFactory = new PsrHttpFactory($psr17, $psr17, $psr17, $psr17);
    }

    $symfonyRequest = $httpFoundationFactory->createRequest($request);
    $illuminateRequest = \Illuminate\Http\Request::createFromBase($symfonyRequest);
    
    $kernel = $app->make(\Illuminate\Contracts\Http\Kernel::class);
    $illuminateResponse = $kernel->handle($illuminateRequest);

    return $psrHttpFactory->createResponse($illuminateResponse);
};
```

### 完整 Symfony 应用集成

```php
<?php
require_once __DIR__ . '/vendor/autoload.php';

$kernel = new \App\Kernel($_SERVER['APP_ENV'], (bool)$_SERVER['APP_DEBUG']);

return static function (ServerRequestInterface $request, array $envelope = []) use ($kernel) {
    static $httpFoundationFactory = null;
    static $psrHttpFactory = null;

    if ($httpFoundationFactory === null) {
        $psr17 = new Psr17Factory();
        $httpFoundationFactory = new HttpFoundationFactory();
        $psrHttpFactory = new PsrHttpFactory($psr17, $psr17, $psr17, $psr17);
    }

    $symfonyRequest = $httpFoundationFactory->createRequest($request);
    $symfonyResponse = $kernel->handle($symfonyRequest);

    return $psrHttpFactory->createResponse($symfonyResponse);
};
```

---

## 与传统 nginx + PHP-FPM 的对比

| 特性 | nginx + PHP-FPM | vhttpd + php-worker |
|------|----------------|---------------------|
| 普通 HTTP 请求 | ✅ 成熟稳定 | ✅ 同样支持 |
| SSE/流式响应 | ⚠️ 需要额外配置 | ✅ 原生支持 |
| WebSocket | ❌ 不支持 | ✅ 支持 |
| Worker 池管理 | ⚠️ 有限 | ✅ 强大的可观测性 |
| 请求队列 | ❌ 无 | ✅ 内置队列支持 |
| Admin/监控界面 | ❌ 需要额外工具 | ✅ 内置 Admin Plane |
| 上游 AI 流集成 | ❌ 需要额外实现 | ✅ 支持 phase 3 upstream plan |
| 部署复杂度 | ⚠️ 需要配置 nginx + PHP-FPM | ✅ 单一二进制 + TOML |

---

## 最佳实践

### 1. 保持应用代码不变

你的业务逻辑、控制器、模型等应该保持原样。只需在入口处做 PSR-7 桥接。

### 2. 充分利用 Worker 持久化

由于 php-worker 是持久的，你可以：
- 保持数据库连接池
- 缓存配置和元数据
- 预热应用状态

```php
return static function (ServerRequestInterface $request, array $envelope = []): object {
    static $dbPool = null;
    
    if ($dbPool === null) {
        $dbPool = new DatabasePool(); // 只在 worker 启动时初始化一次
    }
    
    // 使用 $dbPool
};
```

### 3. 使用 Admin Plane 监控

定期查看运行时状态：

```bash
curl http://127.0.0.1:19986/admin/workers | jq .
curl http://127.0.0.1:19986/admin/runtime | jq .
```

### 4. 配置适当的 Worker 池大小

```toml
[worker]
pool_size = 4  # 根据 CPU 核心数调整
max_requests = 5000  # 定期重启避免内存泄漏
```

---

## 下一步

在第四篇文章中，我们将探索 AI 流式应用，看看如何利用 vhttpd 的流式能力来构建实时 AI 对话接口。

如果你想继续探索，可以：
- 尝试把你自己的 Laravel/Symfony 应用迁移到 vhttpd
- 探索流式响应功能
- 配置多个站点在同一个 vhttpd 进程中运行

---

## 相关资源

- [Laravel 示例](file:///workspace/examples/laravel/)
- [Symfony 示例](file:///workspace/examples/symfony/)
- [WordPress 示例](file:///workspace/examples/wordpress/)
- [配置文件参考](file:///workspace/config/vhttpd.example.toml)
