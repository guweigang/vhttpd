import fs from "fs";
import * as path from "path";

function object(value, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`codexbot config: ${field} must be an object`);
  }
  return value;
}

function text(value, fallback, field) {
  if (value === undefined) return fallback;
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`codexbot config: ${field} must be a nonempty string`);
  }
  return value.trim();
}

function positive(value, fallback, field) {
  if (value === undefined) return fallback;
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`codexbot config: ${field} must be a positive integer`);
  }
  return value;
}

function boolean(value, fallback, field) {
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") throw new Error(`codexbot config: ${field} must be a boolean`);
  return value;
}

function choice(value, fallback, values, field) {
  const result = text(value, fallback, field);
  if (!values.includes(result)) throw new Error(`codexbot config: invalid ${field}`);
  return result;
}

export function loadBotConfig(appEntry) {
  if (typeof appEntry !== "string" || !path.isAbsolute(appEntry)) {
    throw new Error("codexbot config: an absolute application entry is required");
  }
  const configDir = path.join(path.dirname(appEntry), "config");
  const localPath = path.join(configDir, "bot.local.json");
  const configPath = fs.existsSync(localPath) ? localPath : path.join(configDir, "bot.example.json");
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (_) {
    // Never include configuration contents or secret values in errors.
    throw new Error(`codexbot config: cannot read valid JSON from ${configPath}`);
  }
  object(raw, "root");
  if (raw.version !== 1) throw new Error("codexbot config: version must be 1");
  const bot = object(raw.bot || {}, "bot");
  const codex = object(raw.codex, "codex");
  const feishu = object(raw.feishu, "feishu");
  const resolve = (value, fallback, field) => path.resolve(configDir, text(value, fallback, field));
  const defaults = {
    projectKey: text(bot.default_project, "vhttpd", "bot.default_project"),
    model: text(codex.model, "gpt-5.4", "codex.model"),
    effort: choice(codex.effort, "medium", ["none", "minimal", "low", "medium", "high", "xhigh"], "codex.effort"),
    cwd: resolve(codex.cwd, "../.var/projects/vhttpd", "codex.cwd"),
    projectRootDir: resolve(bot.project_root, "../.var/projects", "bot.project_root"),
    dbPath: resolve(bot.db_path, "../.var/codexbot.sqlite", "bot.db_path"),
    defaultCodexInstance: text(codex.default_instance, "main", "codex.default_instance"),
    defaultFeishuInstance: text(feishu.default_instance, "main", "feishu.default_instance"),
    codexUrl: text(codex.url, "ws://127.0.0.1:4500", "codex.url"),
    codexReconnectDelay: positive(codex.reconnect_delay_ms, 3000, "codex.reconnect_delay_ms"),
    codexFlushInterval: positive(codex.flush_interval_ms, 400, "codex.flush_interval_ms"),
    activeStreamStaleMs: positive(bot.active_stream_stale_ms, 180000, "bot.active_stream_stale_ms"),
    enableProviderInstancePreflight: boolean(bot.enable_provider_instance_preflight, false, "bot.enable_provider_instance_preflight"),
    approvalPolicy: choice(codex.approval_policy, "untrusted", ["never", "untrusted", "on-request", "on-failure"], "codex.approval_policy"),
    sandbox: choice(codex.sandbox, "workspace-write", ["read-only", "workspace-write", "danger-full-access"], "codex.sandbox"),
    feishuEnabled: boolean(feishu.enabled, true, "feishu.enabled"),
  };
  defaults.supportedModels = codex.supported_models === undefined ? [defaults.model] : codex.supported_models;
  if (!Array.isArray(defaults.supportedModels) || !defaults.supportedModels.length ||
      defaults.supportedModels.some((v) => typeof v !== "string" || !v.trim())) {
    throw new Error("codexbot config: codex.supported_models must be a nonempty string array");
  }
  const instances = {};
  for (const [provider, section] of [["codex", codex], ["feishu", feishu]]) {
    const configured = object(section.instances, `${provider}.instances`);
    const result = {};
    for (const [name, value] of Object.entries(configured)) {
      if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(name) || name === "default") {
        throw new Error(`codexbot config: invalid ${provider} instance name`);
      }
      const spec = { ...object(value, `${provider}.instances.${name}`) };
      spec.startup = boolean(spec.startup, true, `${provider}.instances.${name}.startup`);
      if (provider === "codex") {
        if (spec.cwd !== undefined) spec.cwd = resolve(spec.cwd, "", `${provider}.instances.${name}.cwd`);
        for (const field of ["reconnect_delay_ms", "flush_interval_ms"]) {
          if (spec[field] !== undefined) spec[field] = positive(spec[field], 0, `${provider}.${field}`);
        }
        if (spec.model !== undefined) spec.model = text(spec.model, "", `codex.${name}.model`);
        if (spec.effort !== undefined) spec.effort = choice(spec.effort, defaults.effort, ["none", "minimal", "low", "medium", "high", "xhigh"], `codex.${name}.effort`);
        spec.url = text(spec.url, defaults.codexUrl, `${provider}.${name}.url`);
        if (!/^wss?:\/\/[^\s]+$/.test(spec.url)) throw new Error("codexbot config: Codex URL must use ws:// or wss://");
        spec.approval_policy = choice(spec.approval_policy, defaults.approvalPolicy, ["never", "untrusted", "on-request", "on-failure"], "codex.approval_policy");
        spec.sandbox = choice(spec.sandbox, defaults.sandbox, ["read-only", "workspace-write", "danger-full-access"], "codex.sandbox");
      } else {
        for (const field of ["app_id", "app_secret", "verification_token", "encrypt_key"]) {
          if (spec[field] !== undefined && typeof spec[field] !== "string") throw new Error(`codexbot config: feishu.${field} must be a string`);
        }
        if (!!spec.app_id !== !!spec.app_secret) throw new Error("codexbot config: Feishu app_id and app_secret must be configured together");
      }
      result[name] = spec;
    }
    const defaultName = provider === "codex" ? defaults.defaultCodexInstance : defaults.defaultFeishuInstance;
    if (!Object.hasOwn(result, defaultName)) throw new Error(`codexbot config: unknown default ${provider} instance`);
    instances[provider] = { instances: result };
  }
  const admin = object(raw.admin || {}, "admin");
  if (admin.token !== undefined && typeof admin.token !== "string") throw new Error("codexbot config: admin.token must be a string");
  return { configDir, configPath, defaults, providerConfig: { providers: instances }, adminToken: admin.token || "" };
}
