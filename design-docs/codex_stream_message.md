那我给你一版**最小可用**的，先以“一个项目一个飞书群、一个项目当前只绑定一个主 thread”为前提设计。这样最容易落地。

## 先定边界

这版里：

* **PHP**

  * 维护 `chat_id -> project -> repo_path -> thread_id`
  * 维护 `task -> stream`
  * 维护 `stream -> feishu message_id`
* **vhttpd**

  * 持有 streaming buffer
  * 负责 timer / flush / patch
* **SQLite**

  * 持久化业务关系

---

# 一、最小 3 张表

## 1) `projects`

作用：保存“飞书群对应哪个项目，以及这个项目当前绑定哪个 Codex thread”。

```sql
CREATE TABLE projects (
  project_key TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  feishu_chat_id TEXT NOT NULL UNIQUE,
  repo_path TEXT NOT NULL,
  default_branch TEXT DEFAULT 'main',
  current_thread_id TEXT,
  current_cwd TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

### 字段说明

* `project_key`

  * 你的业务主键，比如 `vhttpd`
* `name`

  * 展示名，比如 `vhttpd`
* `feishu_chat_id`

  * 飞书群 ID
* `repo_path`

  * 仓库根目录，比如 `/repos/vhttpd`
* `default_branch`

  * 默认分支
* `current_thread_id`

  * 当前主 Codex thread
* `current_cwd`

  * 当前工作目录，通常等于 `repo_path`，以后也可以是 worktree
* `is_active`

  * 项目是否启用

---

## 2) `tasks`

作用：保存“一次用户请求”对应的任务。

```sql
CREATE TABLE tasks (
  task_id TEXT PRIMARY KEY,
  project_key TEXT NOT NULL,
  thread_id TEXT,
  feishu_chat_id TEXT NOT NULL,
  feishu_user_id TEXT,
  request_message_id TEXT,
  stream_id TEXT,
  task_type TEXT NOT NULL,
  prompt TEXT NOT NULL,
  status TEXT NOT NULL,
  codex_turn_id TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_key) REFERENCES projects(project_key)
);
```

### 字段说明

* `task_id`

  * 业务任务 ID，比如 `task_20260315_ab12`
* `project_key`

  * 属于哪个项目
* `thread_id`

  * 这次任务使用的 Codex thread
* `feishu_chat_id`

  * 来源群
* `feishu_user_id`

  * 谁触发的
* `request_message_id`

  * 用户原始消息 ID
* `stream_id`

  * 这次任务关联的流式输出 ID
* `task_type`

  * `ask / plan / edit / fix / diff / run / apply`
* `prompt`

  * 归一化后的 prompt
* `status`

  * `queued / running / streaming / completed / failed / cancelled`
* `codex_turn_id`

  * 如果你后面拿得到 turn id，可以存
* `error_message`

  * 失败原因

---

## 3) `streams`

作用：保存“流式输出”对应的飞书回包消息。

```sql
CREATE TABLE streams (
  stream_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL UNIQUE,
  feishu_chat_id TEXT NOT NULL,
  response_message_id TEXT,
  status TEXT NOT NULL,
  last_render_hash TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(task_id)
);
```

### 字段说明

* `stream_id`

  * 例如 `codex:task_20260315_ab12`
* `task_id`

  * 对应哪个任务
* `feishu_chat_id`

  * 发到哪个群
* `response_message_id`

  * 机器人发出的那条“持续更新消息”的 `message_id`
* `status`

  * `opened / streaming / completed / failed / closed`
* `last_render_hash`

  * 用来避免重复 patch 同样内容

---

# 二、推荐索引

```sql
CREATE INDEX idx_projects_chat_id ON projects(feishu_chat_id);
CREATE INDEX idx_tasks_project_key ON tasks(project_key);
CREATE INDEX idx_tasks_thread_id ON tasks(thread_id);
CREATE INDEX idx_tasks_stream_id ON tasks(stream_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_streams_chat_id ON streams(feishu_chat_id);
CREATE INDEX idx_streams_status ON streams(status);
```

---

# 三、初始化 SQL

你可以直接用这一份：

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS projects (
  project_key TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  feishu_chat_id TEXT NOT NULL UNIQUE,
  repo_path TEXT NOT NULL,
  default_branch TEXT DEFAULT 'main',
  current_thread_id TEXT,
  current_cwd TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  project_key TEXT NOT NULL,
  thread_id TEXT,
  feishu_chat_id TEXT NOT NULL,
  feishu_user_id TEXT,
  request_message_id TEXT,
  stream_id TEXT,
  task_type TEXT NOT NULL,
  prompt TEXT NOT NULL,
  status TEXT NOT NULL,
  codex_turn_id TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_key) REFERENCES projects(project_key)
);

CREATE TABLE IF NOT EXISTS streams (
  stream_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL UNIQUE,
  feishu_chat_id TEXT NOT NULL,
  response_message_id TEXT,
  status TEXT NOT NULL,
  last_render_hash TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(task_id)
);

CREATE INDEX IF NOT EXISTS idx_projects_chat_id ON projects(feishu_chat_id);
CREATE INDEX IF NOT EXISTS idx_tasks_project_key ON tasks(project_key);
CREATE INDEX IF NOT EXISTS idx_tasks_thread_id ON tasks(thread_id);
CREATE INDEX IF NOT EXISTS idx_tasks_stream_id ON tasks(stream_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_streams_chat_id ON streams(feishu_chat_id);
CREATE INDEX IF NOT EXISTS idx_streams_status ON streams(status);
```

---

# 四、建议的 ID 规则

尽量别只用自增整数，排查日志会很难。

## project_key

```text
vhttpd
payment
infra
```

## task_id

```text
task_20260315_ab12cd
```

## stream_id

```text
codex:task_20260315_ab12cd
```

这样你在：

* PHP 日志
* vhttpd 日志
* Feishu message metadata

里都容易追。

---

# 五、PHP Repository 接口

下面这几个接口就够第一版用了。

## `ProjectRepository`

```php
interface ProjectRepository
{
    public function findByChatId(string $chatId): ?array;

    public function findByProjectKey(string $projectKey): ?array;

    public function create(array $data): void;

    public function updateCurrentThread(
        string $projectKey,
        string $threadId,
        string $cwd
    ): void;
}
```

### 典型返回

```php
[
    'project_key' => 'vhttpd',
    'name' => 'vhttpd',
    'feishu_chat_id' => 'oc_xxx',
    'repo_path' => '/repos/vhttpd',
    'default_branch' => 'main',
    'current_thread_id' => 'th_123',
    'current_cwd' => '/repos/vhttpd',
]
```

---

## `TaskRepository`

```php
interface TaskRepository
{
    public function create(array $data): void;

    public function findByTaskId(string $taskId): ?array;

    public function updateStatus(
        string $taskId,
        string $status,
        ?string $errorMessage = null
    ): void;

    public function bindThread(string $taskId, string $threadId): void;

    public function bindStream(string $taskId, string $streamId): void;

    public function bindCodexTurn(string $taskId, string $turnId): void;
}
```

---

## `StreamRepository`

```php
interface StreamRepository
{
    public function create(array $data): void;

    public function findByStreamId(string $streamId): ?array;

    public function bindResponseMessageId(
        string $streamId,
        string $messageId
    ): void;

    public function updateStatus(
        string $streamId,
        string $status
    ): void;

    public function updateLastRenderHash(
        string $streamId,
        string $hash
    ): void;

    public function findMessageIdByStreamId(string $streamId): ?string;
}
```

---

# 六、建议的服务层

不要让 handler 里直接拼 SQL。
再包一层 service，结构会舒服很多。

## `ProjectResolver`

作用：根据飞书群找到项目。

```php
interface ProjectResolver
{
    public function resolveByChatId(string $chatId): ?array;
}
```

## `CodexSessionService`

作用：保证项目有 thread。

```php
interface CodexSessionService
{
    public function ensureThreadForProject(string $projectKey): array;
}
```

返回例如：

```php
[
    'thread_id' => 'th_123',
    'cwd' => '/repos/vhttpd',
]
```

## `StreamService`

作用：为任务创建流。

```php
interface StreamService
{
    public function openForTask(string $taskId, string $chatId): array;
}
```

返回例如：

```php
[
    'stream_id' => 'codex:task_20260315_ab12cd',
]
```

---

# 七、典型流程怎么落表

## 场景 1：群里来了 `/codex plan xxx`

### 第一步

PHP 通过 `chat_id` 查项目：

```text
feishu_chat_id -> projects
```

得到：

* `project_key = vhttpd`
* `repo_path = /repos/vhttpd`
* `current_thread_id = th_123`

### 第二步

创建 `task`

```php
tasks.insert([
  'task_id' => 'task_20260315_ab12cd',
  'project_key' => 'vhttpd',
  'thread_id' => 'th_123',
  'feishu_chat_id' => 'oc_xxx',
  'feishu_user_id' => 'ou_xxx',
  'request_message_id' => 'om_user_xxx',
  'task_type' => 'plan',
  'prompt' => '给 vhttpd 增加 codex upstream',
  'status' => 'queued',
]);
```

### 第三步

创建 `stream`

```php
streams.insert([
  'stream_id' => 'codex:task_20260315_ab12cd',
  'task_id' => 'task_20260315_ab12cd',
  'feishu_chat_id' => 'oc_xxx',
  'status' => 'opened',
]);
```

### 第四步

PHP 返回 command 给 vhttpd：

* `feishu.message.send`
* `codex.turn.start`

---

## 场景 2：vhttpd 发飞书成功，拿到 `message_id`

vhttpd 回写：

```php
streams.bindResponseMessageId(
  'codex:task_20260315_ab12cd',
  'om_bot_999'
);
```

这一步很关键。
以后 patch 都靠它。

---

## 场景 3：Codex streaming 完成

vhttpd 最后触发 PHP render 完成态后：

```php
tasks.updateStatus('task_20260315_ab12cd', 'completed');
streams.updateStatus('codex:task_20260315_ab12cd', 'completed');
```

---

# 八、SQLite 文件放哪

建议固定一个路径，比如：

```text
/var/lib/vhttpd-agent/state.db
```

或者开发环境：

```text
./var/state.db
```

同时把 SQLite WAL 打开：

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
```

这样并发读写会稳很多。

---

# 九、为什么这版不建议用文件 JSON

因为你马上就会遇到这几个查询：

* 这个 `chat_id` 属于哪个项目
* 这个 `stream_id` 对应哪个 `message_id`
* 这个 `task_id` 现在什么状态
* 这个项目当前有没有 thread

SQLite 对这些天然合适；JSON 文件做这些会越来越难受。

---

# 十、第一版先别做太多

先只做这三个约束：

### 1.

**一个群一个项目**

### 2.

**一个项目一个主 thread**

### 3.

**一个 task 一条 streaming message**

你先把这三个跑通，系统就已经很能用了。

---

# 十一、后面怎么扩展

以后你想支持：

* 一个项目多个 thread
* git worktree
* 审批流
* 历史 thread 切换

再补两张表就行：

* `thread_bindings`
* `project_worktrees`

但现在先不用。

---

# 十二、我建议你直接这样落代码目录

```text
src/
  Repository/
    ProjectRepository.php
    TaskRepository.php
    StreamRepository.php

  Service/
    ProjectResolver.php
    CodexSessionService.php
    StreamService.php

  Handler/
    HandleBotEvent.php
    RenderStreamUpdate.php

  Infra/
    SqliteConnection.php
```

---

