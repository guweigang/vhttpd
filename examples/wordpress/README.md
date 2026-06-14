# WordPress 示例

这个示例用于演示在 `vhttpd -> vphp-worker` 架构下以长驻 worker 模式运行已安装的 WordPress 站点。

## 前置条件

1. 本地有一个已安装的 WordPress 站点目录（必须包含 `wp-load.php` 和 `wp-config.php`）。
2. 在该目录下运行 `composer install` 以安装必要的运行时依赖（`vphp/runtime`）。

## 1) 运行方式

这个示例把 WordPress 作为根站点运行，也就是访问路径是 `/`，不是 `/wordpress`。

WordPress 根站点不要把 `VPHP_WP_ROOT` 直接挂载到 `[assets] prefix="/"`，否则 `wp-admin/*.php` 可能被静态层暴露。示例默认关闭 vhttpd assets，静态资源由 `app.php` 安全处理。

这个示例不会在 worker 内部启动 `php-cgi`，也不承接 WordPress 首次安装流程。若还没有 `wp-config.php`，请先用传统 PHP 环境完成安装，或后续使用独立的 CGI/compat executor。

您可以直接设置 `VPHP_WP_ROOT` 环境变量并执行：

```bash
cd /Users/guweigang/Source/vhttpd
cd examples/wordpress && composer install && cd ../..

# 设置 WordPress 目录路径并启动
VPHP_WP_ROOT=/Users/guweigang/wwwroot/wordpress \
./vhttpd --config examples/wordpress/vhttpd.toml
```

或者使用一键 demo 脚本：

```bash
VPHP_WP_ROOT=/Users/guweigang/wwwroot/wordpress \
make -C /Users/guweigang/Source/vhttpd demo-wordpress
```

## 2) 验证

可以通过如下接口测试：

```bash
curl --noproxy '*' -i "http://127.0.0.1:19881/meta?trace_id=demo"
curl --noproxy '*' -i "http://127.0.0.1:19881/post/1"
```

如果缺少 `wp-config.php`，`/meta` 会返回 `installed:false`，其他动态请求会返回 `wp_config_missing`。
