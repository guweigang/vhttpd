# 小程序直连远端 vhttpd + vjsx

这是一个普通的 **vhttpd + vjsx 应用**，只使用现有 HTTP、fetch 和异步数据库接口。
不修改 vhttpd/vjsx 核心，不部署 CloudBase，也不声称完整兼容 `wx-server-sdk`。
小程序通过 `wx.request` 直接请求自己的远端 HTTPS 服务，**不通过腾讯云函数转发**。
保留 `exports.main(event, context)` 只是为了方便复用函数代码，不代表部署到微信云开发。

提供的最小闭环：

1. 小程序 `wx.login()` 获取 code。
2. `POST /auth/login`：服务端固定访问微信 `jscode2session` 校验 code。
3. 服务端生成随机会话令牌，只将令牌哈希及已验证身份写入数据库。
4. `POST /functions/getUser`：使用 Bearer 令牌查会话，调用 `exports.main(event, context)`。
5. 函数在调用专属事务中，根据 `context.userId` 查询当前用户。

## 启动

从 vhttpd 仓库根目录执行。需要支持现有 `runtime.db` 的 DB-enabled 二进制：

```sh
make build WITH_DB=1
```

显式在应用自己的数据库执行 `schema.sql`，例如 PostgreSQL：

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f examples/wechat-cloud-functions/schema.sql
```

不要把测试脚本指向业务数据库。应用不会自动创建、删除或迁移业务表。
`wcf_users` 与 `wcf_sessions` 只供本应用使用。

通过服务端环境变量配置，AppSecret 不应进入小程序代码或 Git：

```sh
export WECHAT_APP_ID='your-app-id'
export WECHAT_APP_SECRET='your-server-side-secret'
export WECHAT_DB_DRIVER='pgsql'
export WECHAT_DB_HOST='127.0.0.1'
export WECHAT_DB_USER='your-db-user'
export WECHAT_DB_PASSWORD='your-db-password'
export WECHAT_DB_NAME='your-db-name'
./vhttpd --config examples/wechat-cloud-functions/vhttpd.toml
```

示例配置为 PostgreSQL 5432、两个 JS lane、四个数据库连接，监听 `127.0.0.1:19886`。
使用 MySQL 时复制配置，修改资源的 `kind`、`port` 等数据库设置，并将
`WECHAT_DB_DRIVER` 设置为 `mysql`；不要只改其中一处。
对外部署需经 HTTPS 反向代理，配置小程序的 request 合法域名。

可选环境变量：

| 名称 | 默认值 | 含义 |
| --- | --- | --- |
| `WECHAT_SESSION_SECONDS` | `3600` | 会话有效期，1–86400 秒 |
| `WECHAT_FUNCTION_TIMEOUT_MS` | `3000` | 函数协作式期限，含事务 admission 等待 |
| `WECHAT_DATABASE_TIMEOUT_MS` | `30000` | 数据库操作逻辑超时 |
| `WECHAT_LOGIN_TIMEOUT_MS` | `5000` | 微信登录接口等待期限 |

登录和鉴权有自己的 I/O 期限，不包含在函数期限内。生产环境应额外配置入口限流、
请求体限制、数据库原生超时及可观测性；本例不是完整的生产认证产品。

## 小程序端

### 可直接运行的最小页面

`miniprogram/` 包含 app.js/app.json、config.js、客户端副本和独立页面
`pages/vhttpd-demo/index`，无 npm 依赖。复用已有小程序时，将 config.js、utils/vhttpd.js
和 pages/vhttpd-demo 复制到小程序源码目录，并在原有 app.json.pages **追加**页面路径，
不要覆盖原有 App 或首页。客户端副本与 client/vhttpd.js 保持一致，有测试检查。

页面提供四个按钮：登录、Promise 查询、回调查询、清除本地会话；显示当前用户、requestId
和回调顺序，但不显示或打印 code、token、AppSecret。不自动发请求、不自动重试业务调用。
清除会话后查询按钮禁用；401 时清空身份展示并提示重新登录。

### 无远端地址 / AppSecret 时的本地调试

从 vhttpd 仓库根目录启动（需要 PostgreSQL 工具和 DB-enabled 二进制）：

```sh
VHTTPD_BIN="$PWD/vhttpd" node examples/wechat-cloud-functions/tests/dev-local.mjs
```

等待 `LOCAL DEMO READY`。脚本仅监听 `127.0.0.1:19886`，创建全新的临时 PostgreSQL
和本例表，真实使用 vhttpd + vjsx + 异步 SQL，不连接已有数据库。按 Ctrl-C 停止两项
服务并删除该次临时数据；每次重启后，页面需要重新登录。可用 `WCF_LOCAL_PORT` 换端口，
并同步修改页面地址。PostgreSQL 工具可用 WCF_INITDB / WCF_PG_CTL / WCF_PSQL 指定。

开发者工具关闭本机“校验合法域名”（个人 project.private.config.json 的
setting.urlCheck=false），编译打开 `pages/vhttpd-demo/index`。页面默认请求
`http://127.0.0.1:19886`；依次点登录、Promise 查询、回调查询。真机上的 127.0.0.1
指向手机自己，因此这套回环地址模式只用于本机模拟器。

**本地入口 tests/local-entry.mjs 完全不校验微信 code**，固定映射到 `local-demo-user`；
页面仍会调用 wx.login，但身份是模拟的，所有客户端共享该假用户。这只验证客户端、HTTP、
函数调用和数据库链路，不验证微信真实登录、双用户隔离或生产安全。该入口要求固定假配置，
且只接受回环 Host，但这些不是公网安全边界；绝不能将它暴露到公网、加隧道或用生产反代代理。
生产 app.mts 不导入该入口，也不支持通过环境变量启用模拟身份。

切换真实远端：部署生产 app.mts，服务端配置当前小程序的 AppID/AppSecret 与数据库；
把 config.js.baseURL（或页面地址输入框）改成自有 HTTPS 域名，配置小程序 request 合法域名，
恢复 urlCheck=true，再重新登录。不要把 AppSecret 放进小程序。

### 客户端代码

将 `client/vhttpd.js` 复制进小程序，统一将客户端实例命名为 `vhttpd`。
先登录，再直连远端服务调用业务函数：

```js
const {createClient} = require('./vhttpd');
const vhttpd = createClient({baseURL: 'https://your-api.example.com'});

await vhttpd.login();
const {result} = await vhttpd.callFunction({name: 'getUser', data: {}});
console.log(result.user);
```

`vhttpd.login()` 内部用 `wx.login()` 取得 code，再通过 `wx.request` 直发远端
`/auth/login`；`vhttpd.callFunction()` 同样通过 `wx.request` 直发 `/functions/<name>`。
AppSecret 和 code 校验只在服务端处理，不需要 `wx.cloud.init()` 或云开发环境。
这是应用自己的客户端封装，不会改写原生 `wx.cloud.callFunction()`，也不安装到 `wx` 对象。
业务请求不会自动重试，避免写操作重放。401 会清除客户端会话；调用方应显式重新登录，
而不是自动重发上一笔业务操作。`clearSession()` 只清除本地缓存，不撤销服务端令牌。

### 从现有小程序迁移

支持 Promise 和 `success/fail/complete` 回调，保留 `{name, data}` 参数和返回值中的 `result`：

```js
// 原来
const {result} = await wx.cloud.callFunction({name: 'getUser', data: {}});
// 迁移后（先配置并登录上面的 vhttpd 实例）
const {result} = await vhttpd.callFunction({name: 'getUser', data: {}});
```

因此这类业务调用可以将 **`wx.cloud.callFunction` 替换为 `vhttpd.callFunction`**，
不需要修改 `name`、`data` 和 `result` 的使用方式。不要全局替换 `wx.`：
`wx.login`、`wx.request`、页面导航、支付等客户端 API 仍由微信提供。

回调式调用也可以只替换函数前缀：

```js
vhttpd.callFunction({
  name: 'getUser', data: {},
  success(res) { console.log(res.result); },
  fail(err) { console.error(err.errMsg); },
  complete(res) { console.log('请求结束', res.errMsg); },
});
```

每次调用先执行 `success` 或 `fail`，再执行一次 `complete`，两者收到同一个对象。
成功对象包含 `{result, requestId, errMsg: 'callFunction:ok'}`；失败为 Error，包含
`errMsg: 'callFunction:fail ...'`，HTTP 失败另保留 `status`。本地校验失败和网络失败
也走 `fail/complete`。回调异步执行，即使传了回调仍返回 Promise，可混用 await；
回调返回值不改变业务结果，也不等待 async 回调。回调抛异常仍执行 complete，随后
返回的 Promise 拒绝（不会把 success 回调的异常当作业务失败再触发 fail）。
仅使用回调、不消费 Promise 时不会产生未处理拒绝；混用时 await 仍会收到拒绝。

这不是完整 SDK 的直接替换：`config.env`、腾讯云数字错误码和其他选项尚未适配；`wx.cloud.database`、
云存储及服务端 `wx-server-sdk` 调用也需另行迁移。远端函数还需显式注册、部署，
使用本例的可信身份与 SQL API；只改客户端前缀不能自动迁移服务端依赖。

## 函数约定

`functions/get-user.js` 保留原始 CommonJS 形式：

```js
exports.main = async (event, context) => {
  const marker = context.dbDriver === 'mysql' ? '?' : '$1';
  const result = await context.db.query(
    'SELECT display_name FROM wcf_users WHERE user_id = ' + marker,
    [context.userId],
  );
  return result.rows[0];
};
```

在 `app.mts` 中显式导入并注册新函数；客户端不能选择文件路径或动态导入模块。
函数返回 JSON 数据，HTTP 成功结果为 `{result, requestId}`。
错误仅返回稳定错误码，不返回 SQL、调用栈、微信错误原文、登录 code 或密钥。
非 JSON 返回值在提交前失败并触发回滚。

`context` 及其身份对象被冻结，并且每次调用分别创建：

- `APPID`、`OPENID`、`UNIONID`、内部 `userId`。
- `wxContext`、`getWXContext()`：本次调用的身份，不读取 lane 全局变量。
- `requestId`、`laneId`：诊断元数据，不应作为身份凭证。
- `dbDriver`、`db.query(sql, stringParams)`、`db.execute(sql, stringParams)`。
- `signal`：调用结束/期限到达的协作式通知。

`context` 是本应用的适配契约，不是完整的腾讯云 context。原始函数若依赖
`require('wx-server-sdk')`、云数据库或云存储，需要显式迁移相应调用。

## 身份与会话边界

- AppID、AppSecret 来自服务端配置，生产登录地址固定为微信 HTTPS 接口。
- 不信任客户端 body、查询参数或 `x-wx-openid` 等头部提供的身份。
- `event` 中已知的 `openid/OPENID` 等兼容字段由可信身份覆盖；移除伪造的
  `context`、`wxContext` 等保留字段。**授权判断始终使用 context，而非任意业务输入。**
- 原始令牌由两个安全随机 UUID 生成，只返回给登录客户端；数据库只保存
  `SHA256(appId + ':' + token)`。不存储或下发微信 `session_key`。
- 会话写入数据库而不是模块 Map，因此两个 lane 或多个实例能共享同一会话。
- 会话按过期时间鉴权。撤销会话可由服务端删除对应令牌哈希记录；生产环境应定期
  清理过期记录，并增加会话管理、登录限流和密钥管理。
- 微信 code 的一次性语义依赖微信校验接口；本地测试替身也模拟 code 消费。

## 事务与超时边界

每次函数调用自动包裹在**一个**现有 `runtime.db.transaction()` 中：

- 正常返回且提交过的查询全部成功，才提交；即使忘记 await 已提交的写操作也会等待。
- 已捕获的 SQL 错误仍使整个调用失败；异常、不可序列化结果和超时走回滚路径。
- 回滚后才返回普通异常/函数超时响应。迟到的业务回调不能再通过其 context 发 SQL。
- 函数内不再开独立/嵌套事务，不发送原始 `BEGIN/COMMIT/ROLLBACK`。
  `context.db` 刻意只暴露 query/execute，避免绕过调用事务。
- 一次调用内查询按提交顺序串行；跨 lane 的调用可并发。
- 这是协作式 JS 期限，不能打断 CPU 死循环，也不是数据库端 `KILL QUERY/PQcancel`。
  SQL 已在执行时，会等待驱动返回后回滚，所以 504 可能晚于配置的函数期限返回。
- 在提交前再次检查期限；进入 COMMIT 后由数据库操作决定结果，不再用函数计时器
  覆盖已知提交成功的结果。提交和清理阶段也可能延长 HTTP 响应时间。
- 数据库连接失效、原生调用永久阻塞、COMMIT 结果未知、事务外副作用等，无法仅靠应用层
  保证恢复或撤销。现有数据库逻辑超时、事务总期限和回滚失败也不能当作回滚确认；
  此时需运维处理。不要自动重试未知结果的写入。
- 为控制兼容 await 的定时器/Promise 进展，适配层在调用期间用现有宿主
  `database('__drain')` 每 5ms 驱动 owner 队列；结束后清除。不新增核心接口。

仅运行自己信任的业务代码。本例不是多租户 JS 沙箱；函数仍能使用运行时安装的全局能力。
不要缓存调用者身份到模块全局变量，不支持可靠的 detached 后台任务。需要可靠异步工作时，
应显式交给独立任务队列，而不是让函数返回后继续写库。

数据库结果仍遵循现有 dbx 语义：值主要为字符串，NULL 映射为空字符串；
PostgreSQL affected_rows 暂无精确计数。这不是 ORM 或云数据库兼容层。

## 验证

无第三方 npm 依赖：

```sh
node --test --test-concurrency=1 examples/wechat-cloud-functions/tests/unit.test.mjs examples/wechat-cloud-functions/tests/miniprogram.test.mjs
VHTTPD_BIN="$PWD/vhttpd" node examples/wechat-cloud-functions/tests/e2e.mjs
```

E2E 要求本机有 MySQL 服务端/客户端、PostgreSQL 的 initdb/pg_ctl/psql，以及 DB-enabled
vhttpd。默认从 PATH 查找，兼容 Homebrew 与 macOS Postgres.app。可通过 `WCF_MYSQLD`、
`WCF_MYSQL`、`WCF_MYSQLADMIN`、`WCF_INITDB`、`WCF_PG_CTL`、`WCF_PSQL` 指定程序路径。
使用非 root 用户执行。`--mysql-only`、`--pgsql-only` 可只测一种驱动。

脚本只创建全新的临时数据目录，自动分配本机端口，不连接已有业务数据库；退出时停止
自己启动的进程并删除临时文件。设置 `WCF_KEEP_TEST_FILES=1` 可保留数据目录排障。

测试使用本地微信 HTTP 替身，不访问真实微信账号，不读取真实 AppSecret。替身只从
`tests/entry.mts` 注入，生产 `app.mts` 不注册测试函数、也不读取测试 endpoint 环境变量。

覆盖真实 HTTP → 两 lane → CommonJS main → 异步 SQL：

- 双用户重复并发，检查不同 lane 和实际重叠执行时间，身份跨 await 不串。
- 伪造 body/header openid、伪造/缺失/过期令牌、非法 code、code 重放被拒绝或忽略。
- 失败写入和 SQL 等待超时：HTTP 返回后立即从独立数据库连接检查写入已回滚。
- 超时后的迟到写入被拒绝，正常调用提交，连接池继续可用。
- 重启进程、切换到真实 `app.mts` 后会话仍可用，测试函数不暴露。

真实微信联调仍需你提供有效 AppID/AppSecret，并在小程序通过 `wx.login()` 产生 code；
本地替身的通过不等同于已完成真实微信平台联调。
