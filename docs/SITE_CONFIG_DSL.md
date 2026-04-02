# Site Config DSL

这页只讲一件事：

- multi-site / multi-listener 模式下，`[sites.<id>]` 现在可以写到多短

目标不是替代完整配置说明，而是给日常写配置时一个更顺手的心智模型。

## 当前推荐形态

推荐把 site 分成 4 层理解：

1. site 基础信息

- `host`
- `port`
- `root`
- `executor`

2. worker 通用运行参数

- `worker.entry`
- `worker.autostart`
- `worker.pool_size`
- `worker.socket_prefix`

3. executor 入口捷径

- `app`

4. executor 专属细节

- `php.*`
- `vjsx.*`
- `feishu.*`
- `codex.*`

## 最简 PHP Site

```toml
[sites.php_demo]
host = "127.0.0.1"
port = 19881
root = "examples"
executor = "php"
worker.entry = "php/package/bin/php-worker"
app = "examples/hello-app.php"
worker.autostart = true
worker.pool_size = 2
php.extensions = ["../vphpx/vslim/vslim.so"]
```

等价于更长的写法：

```toml
[listeners.php_demo]
host = "127.0.0.1"
port = 19881
site = "php_demo"

[sites.php_demo]
project_root = "examples"

[sites.php_demo.executor]
kind = "php"

[sites.php_demo.php]
worker_entry = "php/package/bin/php-worker"
app_entry = "examples/hello-app.php"
extensions = ["../vphpx/vslim/vslim.so"]

[sites.php_demo.worker]
autostart = true
pool_size = 2
```

## 最简 vjsx Site

```toml
[sites.codexbot]
host = "127.0.0.1"
port = 19883
root = "examples/codexbot-app-ts"
executor = "vjsx"
app = "examples/codexbot-app-ts/app.mts"
vjsx.build_root = "tmp/codexbot-vjsx-build"
vjsx.runtime_profile = "node"
vjsx.thread_count = 2
```

## 省略规则

### 1. `[listeners]` 可以省略

如果没写 `[listeners]`，`vhttpd` 会按每个 `[sites.<id>]` 的：

- `host`
- `port`

自动合成一个 listener。

### 2. `root` 是 `project_root` 的别名

这两个等价：

```toml
root = "examples/codexbot-app-ts"
```

```toml
project_root = "examples/codexbot-app-ts"
```

推荐优先用 `root`。

### 3. `app` 是 executor entry 的统一别名

- `php` site 下，`app` 映射到 `php.app_entry`
- `vjsx` site 下，`app` 映射到 `vjsx.app_entry`

如果没显式写 `executor`：

- `app = "*.php"` 会推断成 `php`
- 其他情况默认推断成 `vjsx`

### 4. `worker.entry` 是 PHP worker 入口别名

在 `php` site 下：

- `worker.entry` 映射到 `php.worker_entry`

推荐优先用 `worker.entry`，因为它和 `worker.autostart` / `worker.pool_size` 更像一组。

### 5. `vjsx.module_root` 默认跟随 site `root`

如果 site executor 是 `vjsx`，并且没有写：

```toml
vjsx.module_root = "..."
```

那么它默认等于：

```toml
root = "..."
```

所以大多数 TS site 不需要再重复写 `module_root`。

## 哪些字段不建议继续拍平

下面这些建议继续留在命名空间里：

- `php.extensions`
- `php.args`
- `vjsx.build_root`
- `vjsx.runtime_profile`
- `vjsx.thread_count`
- `feishu.*`
- `codex.*`

原因很简单：

- 这些已经是 executor/provider 专属配置
- 后面大概率还会继续长参数
- 保留命名空间更稳，也更容易扩展

## 兼容性

旧写法都还兼容：

- `[listeners.<id>]`
- `[sites.<id>.executor] kind = "..."`
- `[sites.<id>.php]`
- `[sites.<id>.vjsx]`
- `project_root`
- `php.worker_entry`
- `php.app_entry`
- `vjsx.app_entry`

这套 DSL 是在旧配置之上加的 shorthand，不是另起一套不兼容配置格式。
