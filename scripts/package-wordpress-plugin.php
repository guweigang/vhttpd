<?php
/**
 * v-Profiler WordPress Plugin Packager
 * 自动化打包脚本：将当前开发环境的 v-Profiler 插件与自包含的 VHttpd 依赖打包成一个独立的 WordPress 插件 ZIP。
 */

declare(strict_types=1);

$projectRoot = dirname(__DIR__);
$distDir = $projectRoot . '/dist';
$stageDir = $distDir . '/v-profiler';
$zipFile = $distDir . '/v-profiler.zip';

echo "=== 开始打包 v-Profiler WordPress 插件 ===\n";

// 1. 清理并创建 dist/v-profiler 目录
if (is_dir($stageDir)) {
    echo "清理旧的构建目录...\n";
    exec("rm -rf " . escapeshellarg($stageDir));
}
if (is_file($zipFile)) {
    echo "清理旧的 ZIP 压缩包...\n";
    unlink($zipFile);
}
@mkdir($distDir, 0755, true);
@mkdir($stageDir, 0755, true);

// 2. 拷贝基本文件
echo "拷贝插件基础文件...\n";
$wordpressSrc = $projectRoot . '/php/package/wordpress';

// 拷贝插件入口
copy($wordpressSrc . '/v-profiler.php', $stageDir . '/v-profiler.php');
// 拷贝 proxy 文件
copy($wordpressSrc . '/vhttpd-db.php', $stageDir . '/vhttpd-db.php');

// 拷贝内部组件
$innerFiles = [
    'db.php',
    'object-cache.php',
    'v-profiler-admin.php',
    'v-profiler-ui.js',
    'vhttpd-db.php'
];
@mkdir($stageDir . '/v-profiler', 0755, true);
foreach ($innerFiles as $file) {
    copy($wordpressSrc . '/v-profiler/' . $file, $stageDir . '/v-profiler/' . $file);
}

// 3. 拷贝 VHttpd 命名空间下的所有 PHP 代码以实现自包含
echo "拷贝 VHttpd 依赖类库(实现独立自包含)...\n";
$vhttpdSrc = $projectRoot . '/php/package/src/VHttpd';
$vhttpdDest = $stageDir . '/src/VHttpd';
@mkdir($vhttpdDest, 0755, true);

// 复制
exec("rsync -a " . escapeshellarg($vhttpdSrc . '/') . " " . escapeshellarg($vhttpdDest));

// 4. 重写/修改代码，移除绝对路径及替换 Autoloader

// 4.1 修改 v-profiler.php
echo "优化 v-profiler.php 的 Autoloader...\n";
$mainPluginFile = $stageDir . '/v-profiler.php';
$mainContent = file_get_contents($mainPluginFile);

$autoloaderTarget = <<<'CODE'
// 确保 autoloader 正常加载
if (!class_exists(\VHttpd\WordPress\Profiler::class)) {
    $autoload = getenv('VHTTPD_PHP_PACKAGE_AUTOLOAD');
    if ((!is_string($autoload) || $autoload === '') && defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
        $autoload = (string) VHTTPD_PHP_PACKAGE_AUTOLOAD;
    }
    if (is_string($autoload) && $autoload !== '' && is_file($autoload)) {
        require_once $autoload;
    } else {
        $vhttpdVendor = getenv('VHTTPD_VENDOR');
        if (is_string($vhttpdVendor) && $vhttpdVendor !== '' && is_file($vhttpdVendor . '/vendor/autoload.php')) {
            require_once $vhttpdVendor . '/vendor/autoload.php';
        } elseif (is_file('/Users/guweigang/Source/vhttpd/php/package/vendor/autoload.php')) {
            require_once '/Users/guweigang/Source/vhttpd/php/package/vendor/autoload.php';
        } elseif (is_file(dirname(__DIR__) . '/vendor/autoload.php')) {
            require_once dirname(__DIR__) . '/vendor/autoload.php';
        }
    }
}
CODE;

$autoloaderReplacement = <<<'CODE'
// 注册自包含的 VHttpd 命名空间 Autoloader
if (!class_exists(\VHttpd\WordPress\Profiler::class)) {
    spl_autoload_register(static function (string $class): void {
        $prefix = 'VHttpd\\';
        if (str_starts_with($class, $prefix)) {
            $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
            $file = __DIR__ . '/src/VHttpd/' . $relative . '.php';
            if (is_file($file)) {
                require_once $file;
            }
        }
    });
}
CODE;

$mainContent = str_replace($autoloaderTarget, $autoloaderReplacement, $mainContent);
file_put_contents($mainPluginFile, $mainContent);

// 4.2 修改 v-profiler/db.php
echo "优化 v-profiler/db.php 的 Autoloader...\n";
$dbFile = $stageDir . '/v-profiler/db.php';
$dbContent = file_get_contents($dbFile);

$dbTarget = <<<'CODE'
if (!class_exists(Wpdb::class)) {
    $autoload = getenv('VHTTPD_PHP_PACKAGE_AUTOLOAD');
    if ((!is_string($autoload) || $autoload === '') && defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
        $autoload = (string) VHTTPD_PHP_PACKAGE_AUTOLOAD;
    }
    if (is_string($autoload) && $autoload !== '' && is_file($autoload)) {
        require_once $autoload;
    } elseif (is_file(__DIR__ . '/../vendor/autoload.php')) {
        require_once __DIR__ . '/../vendor/autoload.php';
    }
}
CODE;

$dbReplacement = <<<'CODE'
if (!class_exists(Wpdb::class)) {
    // 自动寻找插件目录以加载自包含的类库
    $vProfilerDir = null;
    if (defined('WPMU_PLUGIN_DIR') && is_dir(WPMU_PLUGIN_DIR . '/v-profiler')) {
        $vProfilerDir = WPMU_PLUGIN_DIR . '/v-profiler';
    } elseif (defined('WP_PLUGIN_DIR') && is_dir(WP_PLUGIN_DIR . '/v-profiler')) {
        $vProfilerDir = WP_PLUGIN_DIR . '/v-profiler';
    } elseif (defined('ABSPATH')) {
        if (is_dir(ABSPATH . 'wp-content/mu-plugins/v-profiler')) {
            $vProfilerDir = ABSPATH . 'wp-content/mu-plugins/v-profiler';
        } elseif (is_dir(ABSPATH . 'wp-content/plugins/v-profiler')) {
            $vProfilerDir = ABSPATH . 'wp-content/plugins/v-profiler';
        }
    }
    
    if ($vProfilerDir !== null) {
        spl_autoload_register(static function (string $class) use ($vProfilerDir): void {
            $prefix = 'VHttpd\\';
            if (str_starts_with($class, $prefix)) {
                $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
                $file = $vProfilerDir . '/src/VHttpd/' . $relative . '.php';
                if (is_file($file)) {
                    require_once $file;
                }
            }
        });
    }
}
CODE;

$dbContent = str_replace($dbTarget, $dbReplacement, $dbContent);
file_put_contents($dbFile, $dbContent);

// 4.3 修改 v-profiler/object-cache.php
echo "优化 v-profiler/object-cache.php 的 Autoloader...\n";
$ocFile = $stageDir . '/v-profiler/object-cache.php';
$ocContent = file_get_contents($ocFile);

$ocTarget = <<<'CODE'
$vhttpdPackageRoot = dirname(__DIR__);

if (!class_exists(ObjectCache::class)) {
    $autoload = getenv('VHTTPD_PHP_PACKAGE_AUTOLOAD');
    if ((!is_string($autoload) || $autoload === '') && defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
        $autoload = (string) VHTTPD_PHP_PACKAGE_AUTOLOAD;
    }
    if (is_string($autoload) && $autoload !== '' && is_file($autoload)) {
        require_once $autoload;
    } elseif (is_file($vhttpdPackageRoot . '/vendor/autoload.php')) {
        require_once $vhttpdPackageRoot . '/vendor/autoload.php';
    }
}

if (!class_exists(ObjectCache::class)) {
    spl_autoload_register(static function (string $class) use ($vhttpdPackageRoot): void {
        $prefix = 'VHttpd\\';
        if (!str_starts_with($class, $prefix)) {
            return;
        }

        $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
        $file = $vhttpdPackageRoot . '/src/VHttpd/' . $relative . '.php';
        if (is_file($file)) {
            require_once $file;
        }
    });
}
CODE;

$ocReplacement = <<<'CODE'
if (!class_exists(ObjectCache::class)) {
    // 自动寻找插件目录以加载自包含的类库
    $vProfilerDir = null;
    if (defined('WPMU_PLUGIN_DIR') && is_dir(WPMU_PLUGIN_DIR . '/v-profiler')) {
        $vProfilerDir = WPMU_PLUGIN_DIR . '/v-profiler';
    } elseif (defined('WP_PLUGIN_DIR') && is_dir(WP_PLUGIN_DIR . '/v-profiler')) {
        $vProfilerDir = WP_PLUGIN_DIR . '/v-profiler';
    } elseif (defined('ABSPATH')) {
        if (is_dir(ABSPATH . 'wp-content/mu-plugins/v-profiler')) {
            $vProfilerDir = ABSPATH . 'wp-content/mu-plugins/v-profiler';
        } elseif (is_dir(ABSPATH . 'wp-content/plugins/v-profiler')) {
            $vProfilerDir = ABSPATH . 'wp-content/plugins/v-profiler';
        }
    }
    
    if ($vProfilerDir !== null) {
        spl_autoload_register(static function (string $class) use ($vProfilerDir): void {
            $prefix = 'VHttpd\\';
            if (str_starts_with($class, $prefix)) {
                $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
                $file = $vProfilerDir . '/src/VHttpd/' . $relative . '.php';
                if (is_file($file)) {
                    require_once $file;
                }
            }
        });
    }
}
CODE;

$ocContent = str_replace($ocTarget, $ocReplacement, $ocContent);
file_put_contents($ocFile, $ocContent);

// 5. 压缩为 ZIP 包
echo "将插件打包为 ZIP 压缩包...\n";
$stageParentDir = escapeshellarg($distDir);
exec("cd $stageParentDir && zip -r v-profiler.zip v-profiler > /dev/null");

if (is_file($zipFile)) {
    echo "🎉 打包完成！生成文件位于: $zipFile (" . number_format(filesize($zipFile) / 1024, 2) . " KB)\n";
} else {
    echo "❌ 打包失败！未生成 ZIP 文件。\n";
}
