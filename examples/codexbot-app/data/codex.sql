PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS projects (
  project_key TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  repo_path TEXT NOT NULL,
  default_branch TEXT DEFAULT 'main',
  current_model TEXT,
  current_thread_id TEXT,
  current_cwd TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS project_channels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_key TEXT NOT NULL,
  platform TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_key TEXT,
  is_primary INTEGER NOT NULL DEFAULT 1,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_key) REFERENCES projects(project_key)
);

CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  project_key TEXT NOT NULL,
  thread_id TEXT,
  platform TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_key TEXT,
  user_id TEXT,
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
  platform TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_key TEXT,
  response_message_id TEXT,
  status TEXT NOT NULL,
  last_render_hash TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(task_id)
);

CREATE TABLE IF NOT EXISTS command_contexts (
  platform TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  selection_scope TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (platform, channel_id)
);

CREATE TABLE IF NOT EXISTS settings (
  name TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_project_channels_project_key
  ON project_channels(project_key);

CREATE INDEX IF NOT EXISTS idx_project_channels_lookup
  ON project_channels(platform, channel_id);

CREATE INDEX IF NOT EXISTS idx_tasks_project_key
  ON tasks(project_key);

CREATE INDEX IF NOT EXISTS idx_tasks_thread_id
  ON tasks(thread_id);

CREATE INDEX IF NOT EXISTS idx_tasks_thread_id_created_at
  ON tasks(thread_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tasks_stream_id
  ON tasks(stream_id);

CREATE INDEX IF NOT EXISTS idx_tasks_status
  ON tasks(status);

CREATE INDEX IF NOT EXISTS idx_tasks_status_created_at
  ON tasks(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tasks_codex_turn_id
  ON tasks(codex_turn_id);

CREATE INDEX IF NOT EXISTS idx_tasks_platform_channel
  ON tasks(platform, channel_id);

CREATE INDEX IF NOT EXISTS idx_streams_status
  ON streams(status);

CREATE INDEX IF NOT EXISTS idx_streams_platform_channel
  ON streams(platform, channel_id);

CREATE INDEX IF NOT EXISTS idx_command_contexts_updated_at
  ON command_contexts(updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_settings_updated_at
  ON settings(updated_at DESC);
