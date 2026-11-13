# vhttpd 自托管微信云函数兼容层

本例由 vhttpd + vjsx 提供函数调用、微信登录鉴权、MySQL 8.0 / PostgreSQL 文档数据库和本地磁盘云存储。现有云函数可以保留 `const cloud = require('wx-server-sdk')`、`cloud.init()` 和 `exports.main` 的常用写法。

`wx-server-sdk` 在本例函数加载器中映射到自托管兼容实现，**不加载腾讯官方 npm 包、不连接 CloudBase，也不是完整 SDK 替代品**。小程序仍通过 `wx.request` 直连自己的 HTTPS 服务，使用 `vhttpd.callFunction()`。

## 入口与目录

- `app.mts`：生产兼容入口，支持 MySQL 8.0 和 PostgreSQL；加载 `cloudfunctions/<name>/index.js`。
- `cloudfunctions/getUser/index.js`：通过 SDK 查询当前用户文档；无文档时返回默认资料，不产生写入。
- `cloudfunctions/updateProfile/index.js`：保存当前用户资料，再通过 `cloud.callFunction()` 调用 getUser。
- `lib/cloud/`：CommonJS 加载器、调用生命周期、SDK 和双数据库查询编译器。
- `legacy-app.mts`、`functions/get-user.js`：保留原来的 SQL 示例，支持 MySQL/PostgreSQL、自定义 context.db 和整次函数事务。
- `tests/local-entry.mjs`：只用于回环地址的假身份演示，不能部署到公网。

从仓库根目录启动。迁入函数时只需创建目录：

```js
// cloudfunctions/myFunction/index.js
const cloud = require('wx-server-sdk');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
const db = cloud.database();

exports.main = async event => {
  const {OPENID} = cloud.getWXContext();
  return await db.collection('todos').where({_openid: OPENID}).get();
};
```

启动时扫描直接子目录，函数名由目录名决定；新建函数、修改入口或依赖后重启应用。HTTP 客户端不能指定文件路径。仅加载可信业务代码，这不是代码沙箱。

## 启动与建表

需要支持异步 `runtime.db` 的 DB-enabled vhttpd 二进制；旧二进制即使能接受 DB 配置，也可能缺少 JS 宿主接口。

```sh
make build WITH_DB=1
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f examples/wechat-cloud-functions/schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f examples/wechat-cloud-functions/schema-cloud-pgsql.sql
```

第一份 SQL 创建登录用户和会话关系表，第二份创建 JSONB 文档表及 GIN 索引。应用不会自动迁移、创建或删除业务表；不要把测试脚本指向业务数据库。

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

默认监听 127.0.0.1:19886，两个 JS lane、四个数据库连接。对外部署需使用 HTTPS 反向代理并配置小程序 request 合法域名。

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| WECHAT_FUNCTION_ROOT | ./examples/wechat-cloud-functions/cloudfunctions | 相对工作目录或绝对函数根目录 |
| WECHAT_CLOUD_ENV | local | 当前文档环境，服务端固定配置 |
| WECHAT_SESSION_SECONDS | 3600 | 会话有效期，1–86400 秒 |
| WECHAT_FUNCTION_TIMEOUT_MS | 3000 | 函数协作式期限，10–60000ms |
| WECHAT_DATABASE_TIMEOUT_MS | 30000 | 每次数据库操作期限，1000–120000ms |
| WECHAT_LOGIN_TIMEOUT_MS | 5000 | 微信登录校验期限，100–30000ms |

首版每个应用只配置一个云环境。其他 env 明确返回 ENV_NOT_FOUND；文档表按 AppID、环境、collection 和文档 ID 分区。多个环境可以运行多个配置实例，共享同一数据库。

使用 MySQL 8.0 时，应用 `schema-auth-mysql.sql` 和 `schema-cloud-mysql.sql`，设置 `WECHAT_DB_DRIVER=mysql`，启动配置改为 `vhttpd.mysql.toml`（默认数据库端口 3306）。MySQL 使用 InnoDB、utf8mb4 和区分大小写的文档键；需要 MySQL 8.0.16+ 的约束支持。PostgreSQL 继续使用上面的两份建表脚本和原配置。切换配置不会自动复制既有数据。

MySQL 事务要求连接使用 REPEATABLE READ（MySQL 默认值）或 SERIALIZABLE；配置为 READ COMMITTED 等其他级别时，兼容层明确拒绝事务。需要包含本次长度安全 MySQL 结果读取修复的新版 DB-enabled vhttpd。

## SDK 支持范围

| 能力 | 首版行为 |
| --- | --- |
| init、DYNAMIC_CURRENT_ENV | 当前环境初始化 |
| getWXContext | APPID、OPENID、UNIONID、ENV，来自已验证身份 |
| callFunction | 同一应用内调用、继承身份、独立事件与结果、共享外层截止时间 |
| collection/doc | 隐式 collection，字符串文档 ID |
| get | collection 返回 data 数组；doc 返回 data 对象 |
| add | 单个 JSON 文档，自动 UUID 或显式 _id |
| set | doc 全量替换或创建，不能传入 _id |
| update/remove/count | 支持条件批量操作及 stats/total |
| where | 字段精确 JSON 相等、点路径、eq/neq/gt/gte/lt/lte/in/nin/exists/and/or |
| 更新指令 | inc、mul、set、remove；支持点路径 |
| orderBy/skip/limit | 查询排序及分页，默认 100、最大 1000 条 |
| runTransaction | 显式事务，collection.doc 上的读写；不自动重试 |

`get`、`add`、`set`、`update`、`remove`、`count` 返回 SDK 风格的 `errMsg`；更新和删除分别返回 `stats.updated` 与 `stats.removed`。set 返回 `_id` 和 `stats.created/updated`。callFunction 返回 `result`、`requestID`、`requestId` 和 `errMsg`。

默认 doc.get 在文档不存在时抛 DOCUMENT_NOT_FOUND；通过 `cloud.init({throwOnNotFound: false})` 或 `cloud.database({throwOnNotFound: false})` 返回 data:null。

```js
const _ = db.command;

await db.collection('todos').add({
  data: {_openid: cloud.getWXContext().OPENID, title: '迁移云函数', done: false, visits: 0},
});

const result = await db.collection('todos')
  .where({done: false, visits: _.gte(0).and(_.lt(10))})
  .orderBy('visits', 'desc')
  .limit(20)
  .get();

await db.collection('todos').doc(result.data[0]._id)
  .update({data: {visits: _.inc(1)}});

await db.runTransaction(async transaction => {
  const target = transaction.collection('todos').doc(result.data[0]._id);
  const before = (await target.get()).data;
  await target.update({data: {visits: before.visits + 1}});
});
```

服务端函数具有应用级数据权限，**不会自动追加 _openid 条件或自动写入 _openid**；函数必须根据可信身份做授权。本例 getUser/updateProfile 的文档 ID 来自 getWXContext，而不是客户端参数。

### 明确限制

- 数据仅支持 JSON：对象、数组、字符串、布尔、有限数字、null；不支持 Date、Geo、RegExp、二进制、BigInt、undefined、serverDate。文档/结果最大 1 MiB，嵌套最多 32 层。
- collection、环境和 ID 使用 1–128 位字母/数字/下划线/连字符；字段点路径只支持标识符段，不支持数组下标。
- 精确 JSON 匹配不会模拟 MongoDB 的数组元素匹配。比较只允许同类型字符串或数字；字符串排序采用所选数据库的 JSON 行为，不承诺两种数据库或腾讯数据库的全部排序语义完全一致。
- 同一次 update 中不能出现重叠路径，例如 a 与 a.b；嵌套字段父节点应为对象。分页/排序后的写操作明确拒绝。
- 不支持字段投影、聚合、实时监听、批量 add、跨环境调用、手动 startTransaction、事务冲突重试。
- 云存储支持本地磁盘后端，详见下节；微信 OpenAPI 尚未实现，调用会抛 NOT_SUPPORTED。S3 尚未实现，仅预留后端接口。其他未列出的 SDK 属性不构成兼容承诺。
- HTTP 错误只暴露稳定错误码；SDK 错误码为本实现的字符串，不承诺腾讯数字错误码一致。

## 本地磁盘云存储

配置以下服务端环境变量后启用；未配置存储时文件 API 仍明确返回 NOT_SUPPORTED：

```sh
export WECHAT_STORAGE_ROOT='/absolute/private/path/wechat-files'
export WECHAT_STORAGE_BASE_URL='https://your-api.example.com'
export WECHAT_STORAGE_MAX_FILE_BYTES=10485760
export WECHAT_STORAGE_URL_TTL_SECONDS=600
```

重新应用所选数据库的 schema-cloud-pgsql.sql 或 schema-cloud-mysql.sql，其中已包含 wcf_files 文件元数据表。文件字节位于私有目录 objects/，不写入数据库、不通过静态目录公开。该目录由服务用户独占（0700）；文件与自动生成的 .signing-key 为 0600。备份时同时保存数据库、objects/ 和 .signing-key；保留签名密钥可让未过期链接跨应用重启继续工作。

云函数保留原 SDK 写法：

```js
const cloud = require('wx-server-sdk');
const fs = require('fs');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});

exports.main = async () => {
  const {fileID} = await cloud.uploadFile({
    cloudPath: 'reports/report.bin',
    fileContent: fs.createReadStream('./report.bin'),
  });
  const {fileContent} = await cloud.downloadFile({fileID}); // Buffer
  return cloud.getTempFileURL({fileList: [{fileID, maxAge: 600}]});
  // cloud.deleteFile({fileList: [fileID]}) 返回逐文件 status/errMsg
};
```

uploadFile 接受 Buffer、Uint8Array 和可读字节流；vjsx 的 fs.createReadStream 兼容常用上传写法。文件内容应在云函数内处理，不能直接把 Buffer 当成函数 JSON 返回值。当前按大小上限整体缓冲，尚未提供大文件分片、进度任务或无限大小流式传输。

默认按 AppID、环境和可信 OPENID 隔离，当前用户只能管理自己的文件。与微信服务端管理员权限并非完全一致，暂不提供跨用户管理员文件操作或公共桶规则。相同用户重复上传同一 cloudPath 会保持 fileID、替换物理版本；其他用户同名路径互不影响。fileID 为自托管 cloud://vhttpd/... 标识，不包含磁盘路径；腾讯原有 cloud:// 标识需要另行迁移，不能直接读取。

getTempFileURL 默认 600 秒，允许 1–3600 秒。持有链接者可在有效期内下载；链接属于临时访问凭证，日志和分享也应按此管理。签名绑定文件版本，覆盖或删除后旧链接立即失效。下载使用 nosniff 和 attachment，图片类型有限白名单，其他文件按 application/octet-stream 返回。

文件写入、删除各自提交，不和业务数据库事务组成跨资源事务；数据库 runTransaction 内调用文件 API 会明确拒绝。元数据发布先于旧版本清理，删除先撤销元数据访问。进程崩溃、提交结果未知或物理清理失败可能留下不可访问的孤立文件，清理失败输出 STORAGE_CLEANUP_PENDING；不要在未核对数据库有效引用前手动批量删除 objects/。

小程序仍用同一 createClient()，四个文件方法支持 Promise 与 success/fail/complete：

```js
const {fileID} = await vhttpd.uploadFile({cloudPath: 'avatars/photo.jpg', filePath: localTempFilePath});
const {tempFilePath} = await vhttpd.downloadFile({fileID});
```

上传通过微信文件系统有界读取及鉴权 JSON 通道；下载通过签名 URL 与 wx.downloadFile 返回本机临时路径。默认单文件 10 MiB，服务端可配置到 64 MiB；如提高服务端上限，客户端 createClient({maxUploadBytes}) 也需同步。对外部署配置 HTTPS 及微信 request/upload/download 合法域名。上传、删除不会自动重试。

后端边界为 initialize()、put(key, bytes, guard)、get(key, maxBytes, guard)、remove(key, guard)；对象键为服务端生成的不可变版本，不接收用户路径。后端 get 返回 Buffer/Uint8Array，guard 提供截止状态检查及 AbortSignal。createStorageService({backend, signingKey, publicBaseURL}) 可注入未来 S3 实现；默认文件系统后端持久化签名密钥，自定义后端需提供至少 32 字节的稳定 signingKey。仅设置 kind=s3 会明确拒绝，不会假装已接通 S3。迁换后端还需搬迁真实对象，不能只修改配置。

## CommonJS 与身份隔离

每次调用创建独立 SDK 对象和 CommonJS 模块缓存，同一调用中的入口、相对依赖和 npm 依赖获得相同 SDK。嵌套调用拥有新缓存和 SDK，但继承已验证的身份。

这使模块顶层的 `const db = cloud.database()` 能安全绑定本次调用；跨 await、多个 lane 和超时后的迟到回调不会读到下一位用户。**不修改 process.env，不设置全局 currentUser。**

代价是模块变量和初始化会在每次调用重建，不保留 Node 云函数常见的热实例全局缓存。已编译的模块函数会在 lane 内复用；源文件更新需要重启。

支持相对 .js/.cjs/.json、package.json 的 main、index.js、循环依赖、函数目录向上查找的 node_modules，以及 fs/path/crypto（含 node: 别名）。其他 Node 内置模块、ESM、package exports、原生扩展暂不支持。第三方库是否可迁入取决于其所需运行时能力，不能据此声明兼容所有 npm 包。SDK 映射优先于磁盘上的官方 wx-server-sdk。

## 生命周期与事务

新兼容入口的普通 CRUD 各自提交，函数后来失败不会撤销已完成的普通写入。需要原子操作时，显式使用 runTransaction。旧 legacy-app.mts 保留原有“整个函数一个事务”行为。

- 显式事务的普通异常和函数超时走等待回滚的路径；事务对象在完成后关闭。
- 不支持嵌套事务或事务期间函数互调。事务中应始终使用传入的 transaction；不要使用外部 db 开独立操作。
- PostgreSQL 显式事务使用 SERIALIZABLE；MySQL 使用 REPEATABLE READ / SERIALIZABLE，并对事务文档读取加 FOR UPDATE 行锁。语句串行执行；冲突会导致事务失败，不自动重试回调。PostgreSQL inc/mul 使用原子 SQL；MySQL 更新在同一原生事务内锁定、验证并写回文档，计数包含匹配但未变化的文档。事务期间使用外部 db 的操作会被拒绝。
- 嵌套函数最多 8 层，继承外层截止时间；事件和结果通过 JSON 复制，避免调用之间共享可变对象。
- 函数结束后拒绝新 SDK 操作；已提交的操作会被等待。已发生的 SQL 错误即使在业务中捕获，也可能使当前调用失败，事务内会回滚；应 await 所有操作。
- 不支持可靠的 detached 后台任务。迟到回调中的 SDK 被关闭，但任意 JS 代码仍可能继续运行。
- 期限为协作式，不能中断 CPU 死循环；执行中的 SQL、提交和回滚可能延长 HTTP 响应时间。连接断开或提交结果未知时，不能保证恢复或自动重试。

## 小程序调用

客户端实例仍命名为 vhttpd，不覆盖微信原生 wx.cloud：

```js
const {createClient} = require('./vhttpd');
const vhttpd = createClient({baseURL: 'https://your-api.example.com'});
await vhttpd.login();

const {result} = await vhttpd.callFunction({name: 'getUser', data: {}});
const updated = await vhttpd.callFunction({
  name: 'updateProfile',
  data: {displayName: 'Alice'},
});
```

原有 `wx.cloud.callFunction({name, data})` 可改成 `vhttpd.callFunction({name, data})`；保留 Promise、success/fail/complete 和 result 的用法。文件 API 使用同一客户端提供的 uploadFile、downloadFile、deleteFile、getTempFileURL；客户端数据库 API 尚未提供。不要全局替换 wx 前缀，wx.login、wx.request、导航和支付仍使用微信接口。

客户端失败不自动重试业务写入；401 清除会话，调用方重新登录。clearSession 只删除本地缓存，不撤销服务端令牌。回调先执行 success 或 fail，再执行一次 complete；回调模式也返回 Promise，忽略它不会产生未处理拒绝。

`miniprogram/` 带现有登录和 getUser 页面，可复制 config.js、utils/vhttpd.js、pages/vhttpd-demo 到已有小程序并追加页面路径，不覆盖原有 App。

## vhttpd Desktop 本机项目

`desktop-local/` 是可导入 Desktop 的独立本机项目，使用同一套云函数和兼容 SDK：

1. 执行 `bash examples/wechat-cloud-functions/desktop-local/database.sh start`，创建或启动专属 PostgreSQL。
2. 在 Desktop 切到“本机 Mac”，导入 `desktop-local/vhttpd.toml`，工作目录选择 `desktop-local/`。
3. 点击“启动项目”，等待“运行中”和“配置已生效”。后续启停、重启、日志和 Admin UI 均由 Desktop 操作。

业务地址为 `http://127.0.0.1:19886`，管理地址为 `http://127.0.0.1:19986/admin/ui/`，数据库仅监听 `127.0.0.1:19896`。本地管理 token 由 Desktop 在每次启动时替换为临时凭据。

数据库数据保存在 `desktop-local/.runtime/postgres/`（被 Git 忽略），独立于现有 Postgres 数据库，重启应用后保留。Desktop 只管理 vhttpd 实例；数据库由 `database.sh start|stop|status` 管理，不随 Desktop 停止而删除。不要与临时演示脚本同时占用 19886 端口。

Desktop 项目当前配置使用 `real.mts`，从 `.runtime/wechat-credentials.json` 读取 `WECHAT_APP_ID` 和 `WECHAT_APP_SECRET`，经固定微信 jscode2session 接口校验真实 code。该文件应保持 0600 权限并被 Git 忽略；AppID 与 AppSecret 必须属于同一个小程序。更新凭据后在 Desktop 点击“重启”，入口不会回退到模拟身份。

需要模拟模式时，将 desktop-local/vhttpd.toml 的 entry 改为 `app.mts`；该文件固定使用 desktop-demo-user，不校验微信 code，不能公开部署。正式远端部署仍使用 examples/wechat-cloud-functions/app.mts，通过服务端环境变量提供凭据。

独立小程序示例位于 miniprogram/；project.config.json 只包含公开 AppID，不包含 AppSecret。本机 127.0.0.1 联调使用 Git 忽略的 project.private.config.json 中 setting.urlCheck=false；切换公网 HTTPS 部署时恢复域名校验并配置合法域名。

## 无真实微信凭证的本地演示

```sh
VHTTPD_BIN="$PWD/vhttpd" make -C examples/wechat-cloud-functions dev-local
```

shell 只负责原生进程生命周期和信号清理，JavaScript 探测由 vjsx CLI 执行，无需 Node/npm。脚本创建全新临时 PostgreSQL，应用两份 schema，启动本机 vhttpd/vjsx；登录及文档读取成功后输出 LOCAL DEMO READY。Ctrl-C 停止两项服务并删除临时数据。可通过 WCF_LOCAL_PORT 换端口，通过 WCF_INITDB/WCF_PG_CTL/WCF_PSQL 指定 PostgreSQL 工具；设置 WCF_SMOKE_ONLY=1 可在就绪后自动清理退出。

默认使用相邻 vjsx 仓库已编译的 bin/vjsx，或 PATH 中的 vjsx；也可通过 VJSX_BIN 指定 CLI 的绝对路径。vhttpd.toml 中 runtime_profile="node" 和源码中的 node:fs/node:crypto 是 vjsx 提供的兼容 API 名称，执行器始终是 vjsx。应用继续使用 vhttpd.toml 和源码入口，不编译成独立应用二进制。

脚本冷启动预算默认为 VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS=120000，可设 1–300000ms；不改变函数/SQL 期限。开发者工具里使用 http://127.0.0.1:19886，并只在本机调试时关闭合法域名校验。真机上的 127.0.0.1 指向手机自身。

**local-entry 不校验微信 code，固定使用 local-demo-user，不能验证真实微信登录或双用户隔离。** 它要求固定假配置和回环 Host，但这不是公网安全边界，不能通过公网反代或隧道暴露。生产 app.mts 不导入测试入口，也没有环境变量开关可开启假鉴权。

真实部署配置 AppID/AppSecret，使用 HTTPS 及合法域名，恢复域名校验后重新登录。AppSecret 只放服务端。

## 身份与会话

登录通过固定微信 jscode2session HTTPS 地址校验 code；不接受请求提供的 openid、APPID 或 x-wx-* 身份头。会话令牌用安全随机 UUID 生成，数据库只保存 SHA256(appId + ':' + token)，不保存 session_key。会话在数据库中共享，可跨 lane、实例和重启。

函数 event 中的已知身份字段被覆盖，context/wxContext/session_key/userId 被移除；授权应始终使用 cloud.getWXContext()。生产环境仍需入口限流、请求体限制、会话清理和密钥管理。

## 验证

```sh
make -C examples/wechat-cloud-functions test
make -C examples/wechat-cloud-functions test-e2e VHTTPD_BIN="$PWD/vhttpd"
make -C examples/wechat-cloud-functions test-e2e-mysql VHTTPD_BIN="$PWD/vhttpd"
```

37 项单元、存储、数据库编译和小程序页面测试全部在 vjsx 中运行，使用轻量断言入口 tests/run.mjs，不依赖 node:test 或 node:vm。

E2E 由 shell 创建全新 PostgreSQL 并启动真实 vhttpd，HTTP 断言全部由 vjsx CLI 执行。测试入口使用固定的 alice/bob 假登录身份，不连接现有业务数据库，不使用真实 AppSecret，也不声称验证微信 code 的一次性语义。覆盖并发身份、函数互调、JSONB CRUD、原子增量、显式事务异常/超时回滚、普通写入独立提交、迟到写入拒绝，以及生产入口重启后的文档与会话持久化。生产入口不加载测试函数。

本示例 `test-e2e` 创建临时 PostgreSQL，`test-e2e-mysql` 使用 Docker 创建官方 MySQL 8.0 隔离容器并在退出时删除容器及测试卷，JavaScript 全部由 vjsx 执行。体测项目的双数据库验收使用 `server/tests/run.sh`，设置 `BODYTEST_DB_DRIVER=mysql` 或 `pgsql`。覆盖原云函数、并发增量、JSON 查询、事务回滚、大体积备份及签名发货幂等。PostgreSQL 工具路径通过 WCF_INITDB/WCF_PG_CTL/WCF_PSQL 配置。

设置 WCF_KEEP_TEST_FILES=1 可保留该次临时测试文件；默认退出时清理。真实微信平台联调还需有效小程序及 wx.login 产生的 code，本地替身通过不代表已完成真实平台联调。
