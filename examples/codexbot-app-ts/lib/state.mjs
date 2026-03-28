import { open } from "sqlite";
import { botDefaults } from "./config.mts";

let dbPromise;

function now() {
  return Date.now();
}

function dbPath() {
  return botDefaults().dbPath;
}

async function tableExists(database, tableName) {
  const rows = await database.query("select name from sqlite_master where type = 'table' and name = ? limit 1", [tableName]);
  return rows.length > 0;
}

async function tableColumns(database, tableName) {
  return database.query(`pragma table_info(${tableName})`);
}

async function ensureChatStateTable(database) {
  if (!(await tableExists(database, "chat_state"))) {
    await database.exec("create table chat_state (session_key text primary key, chat_id text not null, project_key text not null, model text not null, cwd text not null, thread_id text not null default '', thread_path text not null default '', last_stream_id text not null default '', updated_at integer not null)");
    return;
  }
  const columns = await tableColumns(database, "chat_state");
  const names = new Set(columns.map((column) => column.name));
  if (!names.has("session_key")) {
    const legacyThreadPathExpr = names.has("thread_path") ? "coalesce(thread_path, '')" : "''";
    await database.exec("begin immediate");
    try {
      await database.exec("alter table chat_state rename to chat_state_legacy");
      await database.exec("create table chat_state (session_key text primary key, chat_id text not null, project_key text not null, model text not null, cwd text not null, thread_id text not null default '', thread_path text not null default '', last_stream_id text not null default '', updated_at integer not null)");
      await database.exec(`insert into chat_state (session_key, chat_id, project_key, model, cwd, thread_id, thread_path, last_stream_id, updated_at) select chat_id, chat_id, project_key, model, cwd, thread_id, ${legacyThreadPathExpr}, last_stream_id, updated_at from chat_state_legacy`);
      await database.exec("drop table chat_state_legacy");
      await database.exec("commit");
    } catch (error) {
      await database.exec("rollback");
      throw error;
    }
    return;
  }
  if (!names.has("chat_id")) {
    await database.exec("alter table chat_state add column chat_id text not null default ''");
    await database.exec("update chat_state set chat_id = session_key where coalesce(chat_id, '') = ''");
  }
  if (!names.has("thread_path")) {
    await database.exec("alter table chat_state add column thread_path text not null default ''");
  }
}

async function ensureStreamStateTable(database) {
  if (!(await tableExists(database, "stream_state"))) {
    await database.exec("create table stream_state (stream_id text primary key, session_key text not null, chat_id text not null, prompt text not null, project_key text not null, model text not null, cwd text not null, thread_id text not null default '', thread_path text not null default '', turn_id text not null default '', draft text not null default '', status text not null default 'queued', result_text text not null default '', completed_at integer not null default 0, last_event text not null default '', created_at integer not null, updated_at integer not null)");
    return;
  }
  const columns = await tableColumns(database, "stream_state");
  const names = new Set(columns.map((column) => column.name));
  if (!names.has("session_key")) {
    await database.exec("alter table stream_state add column session_key text not null default ''");
    await database.exec("update stream_state set session_key = chat_id where coalesce(session_key, '') = ''");
  }
  if (!names.has("thread_path")) {
    await database.exec("alter table stream_state add column thread_path text not null default ''");
  }
  if (!names.has("turn_id")) {
    await database.exec("alter table stream_state add column turn_id text not null default ''");
  }
  if (!names.has("status")) {
    await database.exec("alter table stream_state add column status text not null default 'queued'");
  }
  if (!names.has("result_text")) {
    await database.exec("alter table stream_state add column result_text text not null default ''");
  }
  if (!names.has("completed_at")) {
    await database.exec("alter table stream_state add column completed_at integer not null default 0");
  }
  if (!names.has("last_event")) {
    await database.exec("alter table stream_state add column last_event text not null default ''");
  }
}

async function ensureCommandContextStateTable(database) {
  if (!(await tableExists(database, "command_context_state"))) {
    await database.exec("create table command_context_state (session_key text primary key, chat_id text not null, scope text not null default '', updated_at integer not null)");
    return;
  }
  const columns = await tableColumns(database, "command_context_state");
  const names = new Set(columns.map((column) => column.name));
  if (!names.has("chat_id")) {
    await database.exec("alter table command_context_state add column chat_id text not null default ''");
    await database.exec("update command_context_state set chat_id = session_key where coalesce(chat_id, '') = ''");
  }
}

async function ensureProjectRegistryTable(database) {
  if (!(await tableExists(database, "project_registry"))) {
    await database.exec("create table project_registry (project_key text primary key, repo_path text not null, default_branch text not null default 'main', default_model text not null default '', created_at integer not null, updated_at integer not null)");
    return;
  }
  const columns = await tableColumns(database, "project_registry");
  const names = new Set(columns.map((column) => column.name));
  if (!names.has("default_branch")) {
    await database.exec("alter table project_registry add column default_branch text not null default 'main'");
  }
  if (!names.has("default_model")) {
    await database.exec("alter table project_registry add column default_model text not null default ''");
  }
}

async function ensureProjectBindingStateTable(database) {
  if (!(await tableExists(database, "project_binding_state"))) {
    await database.exec("create table project_binding_state (chat_id text not null, project_key text not null, is_primary integer not null default 0, created_at integer not null, updated_at integer not null, primary key (chat_id, project_key))");
    return;
  }
  const columns = await tableColumns(database, "project_binding_state");
  const names = new Set(columns.map((column) => column.name));
  if (!names.has("is_primary")) {
    await database.exec("alter table project_binding_state add column is_primary integer not null default 0");
  }
}

async function ensureSettingsTable(database) {
  if (!(await tableExists(database, "settings"))) {
    await database.exec("create table settings (name text primary key, value text not null, created_at integer not null, updated_at integer not null)");
  }
}

async function db() {
  if (dbPromise) {
    return dbPromise;
  }
  const filePath = dbPath();
  dbPromise = open({ path: filePath, busyTimeout: 5000 }).then(async (database) => {
    await database.exec("pragma journal_mode = wal");
    await ensureChatStateTable(database);
    await ensureStreamStateTable(database);
    await ensureCommandContextStateTable(database);
    await ensureProjectRegistryTable(database);
    await ensureProjectBindingStateTable(database);
    await ensureSettingsTable(database);
    await database.exec("create index if not exists idx_chat_state_chat_id on chat_state(chat_id)");
    await database.exec("create index if not exists idx_chat_state_updated_at on chat_state(updated_at desc)");
    await database.exec("create index if not exists idx_stream_state_session_key on stream_state(session_key)");
    await database.exec("create index if not exists idx_stream_state_chat_id on stream_state(chat_id)");
    await database.exec("create index if not exists idx_stream_state_updated_at on stream_state(updated_at desc)");
    await database.exec("create index if not exists idx_command_context_state_chat_id on command_context_state(chat_id)");
    await database.exec("create index if not exists idx_command_context_state_updated_at on command_context_state(updated_at desc)");
    await database.exec("create index if not exists idx_project_registry_updated_at on project_registry(updated_at desc)");
    await database.exec("create index if not exists idx_project_binding_state_chat_id on project_binding_state(chat_id)");
    await database.exec("create index if not exists idx_project_binding_state_updated_at on project_binding_state(updated_at desc)");
    return database;
  });
  return dbPromise;
}

function asChatState(row) {
  if (!row) {
    return undefined;
  }
  return {
    sessionKey: row.session_key,
    chatId: row.chat_id,
    projectKey: row.project_key,
    model: row.model,
    cwd: row.cwd,
    threadId: row.thread_id,
    threadPath: row.thread_path || "",
    lastStreamId: row.last_stream_id,
    updatedAt: row.updated_at,
  };
}

function asSettingRecord(row) {
  if (!row) {
    return undefined;
  }
  return {
    name: row.name,
    value: row.value,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function asStreamState(row) {
  if (!row) {
    return undefined;
  }
  return {
    streamId: row.stream_id,
    sessionKey: row.session_key,
    chatId: row.chat_id,
    prompt: row.prompt,
    projectKey: row.project_key,
    model: row.model,
    cwd: row.cwd,
    threadId: row.thread_id,
    threadPath: row.thread_path || "",
    turnId: row.turn_id || "",
    draft: row.draft,
    status: row.status || "queued",
    resultText: row.result_text || "",
    completedAt: row.completed_at || 0,
    lastEvent: row.last_event || "",
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function asProjectRecord(row) {
  if (!row) {
    return undefined;
  }
  return {
    projectKey: row.project_key,
    repoPath: row.repo_path,
    defaultBranch: row.default_branch || "main",
    defaultModel: row.default_model || "",
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

async function selectChatState(sessionKey) {
  const database = await db();
  const rows = await database.query("select session_key, chat_id, project_key, model, cwd, thread_id, thread_path, last_stream_id, updated_at from chat_state where session_key = ? limit 1", [sessionKey]);
  return asChatState(rows[0]);
}

async function selectStreamState(streamId) {
  const database = await db();
  const rows = await database.query("select stream_id, session_key, chat_id, prompt, project_key, model, cwd, thread_id, thread_path, turn_id, draft, status, result_text, completed_at, last_event, created_at, updated_at from stream_state where stream_id = ? limit 1", [streamId]);
  return asStreamState(rows[0]);
}

function nextStreamId() {
  return `codex:ts_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

export async function ensureChatState(sessionKey, chatId) {
  const existing = await selectChatState(sessionKey);
  if (existing) {
    return existing;
  }
  const defaults = botDefaults();
  const state = {
    sessionKey,
    chatId,
    projectKey: defaults.projectKey,
    model: defaults.model,
    cwd: defaults.cwd,
    threadId: "",
    threadPath: "",
    lastStreamId: "",
    updatedAt: now(),
  };
  const database = await db();
  await database.exec("insert or ignore into chat_state (session_key, chat_id, project_key, model, cwd, thread_id, thread_path, last_stream_id, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?)", [
    state.sessionKey,
    state.chatId,
    state.projectKey,
    state.model,
    state.cwd,
    state.threadId,
    state.threadPath,
    state.lastStreamId,
    state.updatedAt,
  ]);
  await ensureProjectRecord(state.projectKey, state.cwd, { defaultModel: state.model });
  await bindProjectToChat(chatId, state.projectKey, true);
  return (await selectChatState(sessionKey)) || state;
}

export async function updateChatState(sessionKey, chatId, patch) {
  const state = await ensureChatState(sessionKey, chatId);
  const next = {
    ...state,
    ...patch,
    chatId: patch?.chatId || chatId || state.chatId,
    updatedAt: now(),
  };
  const database = await db();
  await database.exec("insert into chat_state (session_key, chat_id, project_key, model, cwd, thread_id, thread_path, last_stream_id, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?) on conflict(session_key) do update set chat_id = excluded.chat_id, project_key = excluded.project_key, model = excluded.model, cwd = excluded.cwd, thread_id = excluded.thread_id, thread_path = excluded.thread_path, last_stream_id = excluded.last_stream_id, updated_at = excluded.updated_at", [
    next.sessionKey,
    next.chatId,
    next.projectKey,
    next.model,
    next.cwd,
    next.threadId || "",
    next.threadPath || "",
    next.lastStreamId || "",
    next.updatedAt,
  ]);
  await ensureProjectRecord(next.projectKey, next.cwd, { defaultModel: next.model });
  await bindProjectToChat(next.chatId, next.projectKey, true);
  return (await selectChatState(sessionKey)) || next;
}

export async function createStreamState(sessionKey, chatId, prompt) {
  const state = await ensureChatState(sessionKey, chatId);
  const stream = {
    streamId: nextStreamId(),
    sessionKey,
    chatId,
    prompt,
    projectKey: state.projectKey,
    model: state.model,
    cwd: state.cwd,
    threadId: state.threadId || "",
    threadPath: state.threadPath || "",
    turnId: "",
    draft: "",
    status: "queued",
    resultText: "",
    completedAt: 0,
    lastEvent: "feishu.message.receive_v1",
    createdAt: now(),
    updatedAt: now(),
  };
  const database = await db();
  await database.exec("begin immediate");
  try {
    await database.exec("insert into stream_state (stream_id, session_key, chat_id, prompt, project_key, model, cwd, thread_id, thread_path, turn_id, draft, status, result_text, completed_at, last_event, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
      stream.streamId,
      stream.sessionKey,
      stream.chatId,
      stream.prompt,
      stream.projectKey,
      stream.model,
      stream.cwd,
      stream.threadId,
      stream.threadPath,
      stream.turnId,
      stream.draft,
      stream.status,
      stream.resultText,
      stream.completedAt,
      stream.lastEvent,
      stream.createdAt,
      stream.updatedAt,
    ]);
    await database.exec("update chat_state set chat_id = ?, last_stream_id = ?, updated_at = ? where session_key = ?", [
      stream.chatId,
      stream.streamId,
      stream.updatedAt,
      stream.sessionKey,
    ]);
    await database.exec("commit");
  } catch (error) {
    await database.exec("rollback");
    throw error;
  }
  return (await selectStreamState(stream.streamId)) || stream;
}

export async function getStreamState(streamId) {
  if (!streamId) {
    return undefined;
  }
  return selectStreamState(streamId);
}

export async function listRecentProjectThreads(projectKey, limit = 8) {
  if (!projectKey) {
    return [];
  }
  const database = await db();
  const rows = await database.query("select stream_id, session_key, chat_id, prompt, project_key, model, cwd, thread_id, thread_path, turn_id, draft, status, result_text, completed_at, last_event, created_at, updated_at from stream_state where project_key = ? and coalesce(thread_id, '') <> '' order by updated_at desc, stream_id asc", [projectKey]);
  const threads = [];
  const seen = new Set();
  for (const row of rows) {
    const stream = asStreamState(row);
    if (!stream || !stream.threadId || seen.has(stream.threadId)) {
      continue;
    }
    seen.add(stream.threadId);
    threads.push(stream);
    if (threads.length >= limit) {
      break;
    }
  }
  return threads;
}

export async function getLatestProjectThread(projectKey) {
  const threads = await listRecentProjectThreads(projectKey, 1);
  return threads[0];
}

export async function listChatProjects(chatId, limit = 8) {
  if (!chatId) {
    return [];
  }
  const database = await db();
  const rows = await database.query("select '' as session_key, pbs.chat_id as chat_id, pr.project_key as project_key, coalesce(pr.default_model, '') as model, pr.repo_path as cwd, '' as thread_id, '' as thread_path, '' as last_stream_id, pbs.updated_at as updated_at, pbs.is_primary as is_primary from project_binding_state pbs join project_registry pr on pr.project_key = pbs.project_key where pbs.chat_id = ? union all select session_key, chat_id, project_key, model, cwd, thread_id, thread_path, last_stream_id, updated_at, 0 as is_primary from chat_state where chat_id = ? union all select session_key, chat_id, project_key, model, cwd, thread_id, thread_path, '' as last_stream_id, updated_at, 0 as is_primary from stream_state where chat_id = ? order by is_primary desc, updated_at desc, session_key asc", [chatId, chatId, chatId]);
  const projects = [];
  const seen = new Set();
  for (const row of rows) {
    const state = asChatState(row);
    if (!state || !state.projectKey || seen.has(state.projectKey)) {
      continue;
    }
    seen.add(state.projectKey);
    projects.push(state);
    if (projects.length >= limit) {
      break;
    }
  }
  return projects;
}

export async function ensureProjectRecord(projectKey, repoPath, options = {}) {
  if (!projectKey || !repoPath) {
    return undefined;
  }
  const timestamp = now();
  const database = await db();
  await database.exec("insert into project_registry (project_key, repo_path, default_branch, default_model, created_at, updated_at) values (?, ?, ?, ?, ?, ?) on conflict(project_key) do update set repo_path = excluded.repo_path, default_branch = excluded.default_branch, default_model = excluded.default_model, updated_at = excluded.updated_at", [
    projectKey,
    repoPath,
    options.defaultBranch || "main",
    options.defaultModel || "",
    timestamp,
    timestamp,
  ]);
  return getProjectRecord(projectKey);
}

export async function updateProjectRecordPath(projectKey, repoPath) {
  if (!projectKey || !repoPath) {
    return undefined;
  }
  const timestamp = now();
  const database = await db();
  await database.exec("update project_registry set repo_path = ?, updated_at = ? where project_key = ? and coalesce(repo_path, '') = ''", [
    repoPath,
    timestamp,
    projectKey,
  ]);
  return getProjectRecord(projectKey);
}

export async function getProjectRecord(projectKey) {
  if (!projectKey) {
    return undefined;
  }
  const database = await db();
  const rows = await database.query("select project_key, repo_path, default_branch, default_model, created_at, updated_at from project_registry where project_key = ? limit 1", [projectKey]);
  return asProjectRecord(rows[0]);
}

export async function bindProjectToChat(chatId, projectKey, isPrimary = false) {
  if (!chatId || !projectKey) {
    return;
  }
  const timestamp = now();
  const database = await db();
  await database.exec("begin immediate");
  try {
    if (isPrimary) {
      await database.exec("update project_binding_state set is_primary = 0, updated_at = ? where chat_id = ?", [timestamp, chatId]);
    }
    await database.exec("insert into project_binding_state (chat_id, project_key, is_primary, created_at, updated_at) values (?, ?, ?, ?, ?) on conflict(chat_id, project_key) do update set is_primary = excluded.is_primary, updated_at = excluded.updated_at", [
      chatId,
      projectKey,
      isPrimary ? 1 : 0,
      timestamp,
      timestamp,
    ]);
    await database.exec("commit");
  } catch (error) {
    await database.exec("rollback");
    throw error;
  }
}

export async function unbindProjectFromChat(chatId, projectKey) {
  if (!chatId || !projectKey) {
    return;
  }
  const database = await db();
  await database.exec("delete from project_binding_state where chat_id = ? and project_key = ?", [
    chatId,
    projectKey,
  ]);
}

export async function listBoundChatProjects(chatId, limit = 8) {
  if (!chatId) {
    return [];
  }
  const database = await db();
  const rows = await database.query("select pr.project_key, pr.repo_path, pr.default_branch, pr.default_model, pbs.created_at, pbs.updated_at, pbs.is_primary from project_binding_state pbs join project_registry pr on pr.project_key = pbs.project_key where pbs.chat_id = ? order by pbs.is_primary desc, pbs.updated_at desc, pr.project_key asc limit ?", [chatId, limit]);
  return rows.map((row) => ({
    ...asProjectRecord(row),
    isPrimary: row.is_primary === 1,
  }));
}

export async function listSettings() {
  const database = await db();
  const rows = await database.query("select name, value, created_at, updated_at from settings order by name asc");
  return rows.map(asSettingRecord);
}

export async function getSettingValue(name) {
  if (!name) {
    return "";
  }
  const database = await db();
  const rows = await database.query("select value from settings where name = ? limit 1", [name]);
  const value = rows[0]?.value;
  return typeof value === "string" ? value : "";
}

export async function upsertSetting(name, value) {
  if (!name) {
    return undefined;
  }
  const database = await db();
  const timestamp = now();
  await database.exec("insert into settings (name, value, created_at, updated_at) values (?, ?, ?, ?) on conflict(name) do update set value = excluded.value, updated_at = excluded.updated_at", [
    name,
    value,
    timestamp,
    timestamp,
  ]);
  const rows = await database.query("select name, value, created_at, updated_at from settings where name = ? limit 1", [name]);
  return asSettingRecord(rows[0]);
}

export async function rememberSelectionScope(sessionKey, chatId, scope) {
  const database = await db();
  await database.exec("insert into command_context_state (session_key, chat_id, scope, updated_at) values (?, ?, ?, ?) on conflict(session_key) do update set chat_id = excluded.chat_id, scope = excluded.scope, updated_at = excluded.updated_at", [
    sessionKey,
    chatId,
    scope || "",
    now(),
  ]);
}

export async function getSelectionScope(sessionKey) {
  if (!sessionKey) {
    return "";
  }
  const database = await db();
  const rows = await database.query("select scope from command_context_state where session_key = ? limit 1", [sessionKey]);
  const scope = rows[0]?.scope;
  return typeof scope === "string" ? scope : "";
}

export async function clearSelectionScope(sessionKey) {
  if (!sessionKey) {
    return;
  }
  const database = await db();
  await database.exec("delete from command_context_state where session_key = ?", [sessionKey]);
}

export async function updateStreamState(streamId, patch) {
  const state = await getStreamState(streamId);
  if (!state) {
    return undefined;
  }
  const next = {
    ...state,
    ...patch,
    updatedAt: now(),
  };
  const database = await db();
  await database.exec("update stream_state set session_key = ?, chat_id = ?, prompt = ?, project_key = ?, model = ?, cwd = ?, thread_id = ?, thread_path = ?, turn_id = ?, draft = ?, status = ?, result_text = ?, completed_at = ?, last_event = ?, updated_at = ? where stream_id = ?", [
    next.sessionKey,
    next.chatId,
    next.prompt,
    next.projectKey,
    next.model,
    next.cwd,
    next.threadId || "",
    next.threadPath || "",
    next.turnId || "",
    next.draft || "",
    next.status || "queued",
    next.resultText || "",
    next.completedAt || 0,
    next.lastEvent || "",
    next.updatedAt,
    streamId,
  ]);
  return (await selectStreamState(streamId)) || next;
}

export async function bindThreadToStream(streamId, threadId, threadPath = "") {
  const stream = await getStreamState(streamId);
  if (!stream) {
    return undefined;
  }
  const updatedAt = now();
  const database = await db();
  await database.exec("begin immediate");
  try {
    await database.exec("update stream_state set thread_id = ?, thread_path = ?, updated_at = ? where stream_id = ?", [threadId, threadPath || "", updatedAt, streamId]);
    await database.exec("update chat_state set thread_id = ?, thread_path = ?, updated_at = ? where session_key = ?", [threadId, threadPath || "", updatedAt, stream.sessionKey]);
    await database.exec("commit");
  } catch (error) {
    await database.exec("rollback");
    throw error;
  }
  return {
    stream: await getStreamState(streamId),
    chat: await ensureChatState(stream.sessionKey, stream.chatId),
  };
}

export async function appendStreamDraft(streamId, chunk, patch = {}) {
  if (!chunk) {
    return getStreamState(streamId);
  }
  const turnId = typeof patch.turnId === "string" ? patch.turnId : "";
  const lastEvent = typeof patch.lastEvent === "string" && patch.lastEvent.trim() !== "" ? patch.lastEvent : "item/agentMessage/delta";
  const database = await db();
  await database.exec("update stream_state set draft = coalesce(draft, '') || ?, turn_id = case when ? <> '' then ? else turn_id end, status = 'streaming', last_event = ?, updated_at = ? where stream_id = ?", [chunk, turnId, turnId, lastEvent, now(), streamId]);
  return getStreamState(streamId);
}

export async function finalizeStreamState(streamId, patch) {
  return updateStreamState(streamId, patch);
}

export function resetChatThread(sessionKey, chatId) {
  return updateChatState(sessionKey, chatId, { threadId: "", threadPath: "" });
}

export async function runtimeSnapshot() {
  const database = await db();
  const chats = await database.query("select session_key, chat_id, project_key, model, cwd, thread_id, thread_path, last_stream_id, updated_at from chat_state order by updated_at desc, session_key asc");
  const streams = await database.query("select stream_id, session_key, chat_id, prompt, project_key, model, cwd, thread_id, thread_path, turn_id, draft, status, result_text, completed_at, last_event, created_at, updated_at from stream_state order by updated_at desc, stream_id asc");
  const commandContexts = await database.query("select session_key, chat_id, scope, updated_at from command_context_state order by updated_at desc, session_key asc");
  const projects = await database.query("select project_key, repo_path, default_branch, default_model, created_at, updated_at from project_registry order by updated_at desc, project_key asc");
  const bindings = await database.query("select chat_id, project_key, is_primary, created_at, updated_at from project_binding_state order by updated_at desc, chat_id asc, project_key asc");
  const settings = await database.query("select name, value, created_at, updated_at from settings order by name asc");
  return {
    dbPath: dbPath(),
    chats: chats.map(asChatState),
    streams: streams.map(asStreamState),
    commandContexts: commandContexts.map((row) => ({
      sessionKey: row.session_key,
      chatId: row.chat_id,
      scope: row.scope || "",
      updatedAt: row.updated_at,
    })),
    projects: projects.map(asProjectRecord),
    bindings: bindings.map((row) => ({
      chatId: row.chat_id,
      projectKey: row.project_key,
      isPrimary: row.is_primary === 1,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
    settings: settings.map(asSettingRecord),
  };
}
