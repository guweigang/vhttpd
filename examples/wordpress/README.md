# WordPress 示例

这个示例用于演示在 `vhttpd -> php-worker` 架构下直接启动和运行 WordPress 站点，并实现首次安装与生产运行。

## 前置条件

1. 本地有一个 WordPress 站点目录（必须包含 `wp-load.php` 等）。
2. 在该目录下运行 `composer install` 以安装必要的运行时依赖（`vphp/runtime`）。

## 1) 静态资源挂载 (强烈推荐)

因为 WordPress 的静态资源（CSS、JS、图片等）不需要消耗 PHP Worker 进程的算力，推荐通过 `vhttpd` 自身的静态资源服务来高效拦截和返回。
建议在您的 `vhttpd.toml` 中加入如下挂载配置：

```toml
[assets]
enabled = true
prefix = "/wordpress"                # 您的访问路由前缀
root = "/path/to/wordpress"          # 您的 WordPress 物理目录
cache_control = "public, max-age=3600"
```

通过如上配置后：
- 所有物理存在的静态文件（例如 `/wordpress/wp-content/...`）都将由 `vhttpd` 自身直接读取返回。
- 所有的动态路由请求都将透明地被转发给 PHP Worker 闭包处理。

## 2) 启动服务

您可以直接设置 `VPHP_WP_ROOT` 环境变量并执行：

```bash
cd /Users/guweigang/Source/vhttpd/examples/wordpress
composer install

# 设置 WordPress 目录路径并启动
VPHP_WP_ROOT=/path/to/wordpress \
VHTTPD_APP=/Users/guweigang/Source/vhttpd/examples/wordpress/app.php \
# 启动 vhttpd 并加载您的配置
vhttpd --config examples/wordpress/vhttpd.toml
```

或者使用一键 demo 脚本：

```bash
VPHP_WP_ROOT=/path/to/wordpress \
make -C /Users/guweigang/Source/vhttpd demo-wordpress
```

## 3) 验证

若为首次安装，请直接在浏览器中访问：
`http://127.0.0.1:19881/wordpress/`
页面会自动进入 WordPress 的安装数据库配置引导界面，填写配置即可无缝完成安装并直接运行！

如果已安装完成，可以通过如下接口测试：

```bash
curl --noproxy '*' -i "http://127.0.0.1:19881/wordpress/meta?trace_id=demo"
curl --noproxy '*' -i "http://127.0.0.1:19881/wordpress/post/1"
```
