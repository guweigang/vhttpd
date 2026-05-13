# 从零开始：5分钟运行你的第一个 vhttpd 应用

在第一篇文章中，我们了解了 vhttpd 是什么，以及它能解决什么问题。现在，让我们动手实践，从编译安装开始，一步步运行你的第一个 vhttpd 应用。

---

## 前置准备

在开始之前，请确保你的开发环境满足以下要求：

- Unix-like 系统（Linux 或 macOS）
- V 语言编译器
- PHP 7.4+
- Git

---

## 第一步：获取代码

首先，让我们获取 vhttpd 的源代码：

```bash
git clone https://github.com/your-org/vhttpd.git
cd vhttpd
```

---

## 第二步：安装依赖和编译

vhttpd 使用 Makefile 来管理构建过程。让我们先安装核心依赖：

```bash
make deps-core
make doctor
```

`make doctor` 会检查你的系统环境是否满足要求。如果一切正常，我们就可以开始编译了：

```bash
make vhttpd
```

这个命令会：
1. 准备构建源代码
2. 使用 V 语言编译器编译 vhttpd
3. 生成一个独立的二进制文件 `vhttpd`

如果你想构建生产版本，可以使用：

```bash
make prod
```

---

## 第三步：运行 Hello World

项目已经为我们准备好了一个简单的示例应用，让我们直接运行它：

```bash
./vhttpd --config examples/config/hello.toml
```

这条命令会：
1. 加载配置文件 [`hello.toml`](file:///workspace/examples/config/hello.toml)
2. 启动 vhttpd 服务
3. 启动 PHP worker 进程
4. 开始监听端口

你应该会看到类似这样的输出：

```
vhttpd starting...
listening on 127.0.0.1:19881
admin plane listening on 127.0.0.1:19981
worker pool started (4 workers)
```

---

## 第四步：测试应用

现在让我们测试一下我们的应用是否正常工作。打开另一个终端窗口，运行：

```bash
curl --noproxy '*' -i http://127.0.0.1:19881/hello/codex
```

你应该会看到：

```
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
x-runtime: vslim
Date: ...
Content-Length: 12

Hello, codex
```

太棒了！我们的第一个 vhttpd 应用已经成功运行了！

让我们再测试另一个端点：

```bash
curl --noproxy '*' -i http://127.0.0.1:19881/api/meta
```

这会返回一个 JSON 响应，包含一些请求元信息。

---

## 第五步：探索 Admin Plane

vhttpd 的一个强大特性是它的 Admin Plane（管理平面）。让我们访问它：

```bash
curl --noproxy '*' http://127.0.0.1:19981/admin/runtime | jq .
```

你会看到类似这样的输出：

```json
{
  "worker_pool": {
    "size": 4,
    "active": 4,
    "available": 3
  },
  "stats": {
    "requests_total": 5,
    "requests_ok": 5
  },
  "mcp_sessions": 0,
  "websocket_connections": 0
}
```

你也可以查看 worker 的详细状态：

```bash
curl --noproxy '*' http://127.0.0.1:19981/admin/workers | jq .
```

---

## 理解配置文件

让我们看一下我们刚才使用的配置文件 [`hello.toml`](file:///workspace/examples/config/hello.toml)：

```toml
[paths]
root = ".."
php_app = "examples/hello-app.php"
php_worker = "php/package/bin/php-worker"
web_root = "examples/public"

[server]
host = "127.0.0.1"
port = 19881

[files]
pid_file = "tmp/vhttpd_${server.port}.pid"
event_log = "tmp/vhttpd_${server.port}.events.ndjson"

[runtime]
timezone = "Asia/Shanghai"

[worker]
autostart = true
pool_size = 4
socket_prefix = "${env.VHTTPD_SOCKET_PREFIX:-tmp/vslim_worker}"
read_timeout_ms = 3000

[executor]
kind = "php"

[php]
bin = "php"
worker_entry = "${paths.php_worker}"
app_entry = "${paths.php_app}"
extensions = ["${paths.vslim_ext}"]

[admin]
host = "127.0.0.1"
port = 19981
token = "change-me"
```

这个配置文件告诉 vhttpd：
1. 在哪里找到我们的 PHP 应用
2. 监听哪个端口
3. 启动多少个 worker
4. Admin Plane 在哪里监听
5. 时区设置

---

## 理解应用代码

让我们看一下我们的示例应用 [`hello-app.php`](file:///workspace/examples/hello-app.php)：

```php
<?php
declare(strict_types=1);

$app = new VSlim\App();

$app->before(function (VSlim\Request $req) {
    if ($req->path === '/blocked') {
        return new VSlim\Response(403, 'blocked', 'text/plain; charset=utf-8');
    }
    return null;
});

$app->get_named('hello.show', '/hello/:name', function (VSlim\Request $req) {
    return new VSlim\Response(
        200,
        'Hello, ' . $req->param('name'),
        'text/plain; charset=utf-8'
    );
});

$app->get('/go/:name', function (VSlim\Request $req) use ($app) {
    return $app->redirect_to('hello.show', ['name' => $req->param('name')]);
});

$api = $app->group('/api');
$api->get('/meta', function (VSlim\Request $req) use ($app) {
    return [
        'status' => 200,
        'content_type' => 'application/json; charset=utf-8',
        'body' => json_encode([
            'path' => $req->path,
            'secure' => $req->is_secure(),
            'host' => $req->host,
            'hello_url' => $app->url_for('hello.show', ['name' => 'codex']),
        ]),
    ];
});

$app->after(function (VSlim\Request $req, VSlim\Response $res) {
    $res->set_header('x-runtime', 'vslim');
    return $res;
});

return $app;
```

这个简单的应用展示了几个核心概念：
1. 路由定义
2. 命名路由
3. 路由分组
4. 中间件（before/after）
5. 请求和响应对象

---

## 下一步

恭喜你！你已经成功运行了你的第一个 vhttpd 应用。在下一篇文章中，我们将探索如何将现有的 Laravel、Symfony 或 WordPress 应用迁移到 vhttpd 上，享受现代运行时的好处。

如果你想继续探索，可以尝试：
- 修改 `hello-app.php`，添加你自己的路由
- 查看 `config` 目录下的其他配置示例
- 阅读 `docs` 目录下的详细文档
- 尝试 AI 流式应用示例

---

## 常见问题

**Q: 编译失败怎么办？**
A: 确保你已经运行了 `make deps-core` 和 `make doctor`，并且 V 语言编译器已正确安装。

**Q: 如何停止 vhttpd？**
A: 在运行 vhttpd 的终端按 `Ctrl+C`，或者使用 `kill` 命令。

**Q: 可以在后台运行吗？**
A: 可以使用类似 `nohup` 或配置 systemd/launchd 服务管理。

---

## 相关资源

- [配置文件参考](file:///workspace/config/vhttpd.example.toml)
- [示例应用](file:///workspace/examples/)
- [架构概述](file:///workspace/docs/OVERVIEW.md)
