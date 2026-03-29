function env(name, fallbackValue) {
  const value = process.env[name];
  if (typeof value === "string" && value.trim() !== "") {
    return value;
  }
  return fallbackValue;
}

function envList(name, fallbackValue) {
  const raw = env(name, fallbackValue);
  return raw
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

export function botDefaults() {
  const defaults = {};

  defaults.projectKey = env("CODEXBOT_TS_DEFAULT_PROJECT", "vhttpd");
  defaults.model = env("CODEXBOT_TS_DEFAULT_MODEL", "gpt-5.4");
  defaults.supportedModels = envList(
    "CODEXBOT_TS_SUPPORTED_MODELS",
    "gpt-5.4,gpt-5.3-codex",
  );
  defaults.effort = env("CODEXBOT_TS_DEFAULT_EFFORT", "medium");
  defaults.cwd = env("CODEXBOT_TS_DEFAULT_CWD", process.cwd());
  defaults.projectRootDir = env("CODEXBOT_TS_PROJECT_ROOT", process.cwd());
  defaults.dbPath = env(
    "CODEXBOT_TS_DB_PATH",
    `${process.cwd()}/tmp/codexbot-app-ts.sqlite`,
  );
  defaults.defaultCodexInstance = env(
    "CODEXBOT_TS_DEFAULT_CODEX_INSTANCE",
    "main",
  );
  defaults.defaultFeishuInstance = env(
    "CODEXBOT_TS_DEFAULT_FEISHU_INSTANCE",
    "main",
  );
  defaults.codexUrl = env("CODEX_URL", "ws://127.0.0.1:4500");
  defaults.codexReconnectDelay = Number(
    env("CODEXBOT_TS_CODEX_RECONNECT_DELAY_MS", "3000"),
  );
  defaults.codexFlushInterval = Number(
    env("CODEXBOT_TS_CODEX_FLUSH_INTERVAL_MS", "400"),
  );
  defaults.feishuAppId = env("FEISHU_APP_ID", "");
  defaults.feishuAppSecret = env("FEISHU_APP_SECRET", "");
  defaults.feishuVerificationToken = env("FEISHU_VERIFICATION_TOKEN", "");
  defaults.feishuEncryptKey = env("FEISHU_ENCRYPT_KEY", "");
  defaults.enableProviderInstancePreflight =
    env("CODEXBOT_TS_ENABLE_PROVIDER_INSTANCE_PREFLIGHT", "0") === "1";
  defaults.approvalPolicy = env("CODEXBOT_TS_APPROVAL_POLICY", "never");
  defaults.sandbox = env("CODEXBOT_TS_SANDBOX", "workspace-write");

  return defaults;
}
