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
  return {
    projectKey: env("CODEXBOT_TS_DEFAULT_PROJECT", "demo"),
    model: env("CODEXBOT_TS_DEFAULT_MODEL", "gpt-5.4"),
    supportedModels: envList("CODEXBOT_TS_SUPPORTED_MODELS", "gpt-5.4,gpt-5.3-codex"),
    effort: env("CODEXBOT_TS_DEFAULT_EFFORT", "medium"),
    cwd: env("CODEXBOT_TS_DEFAULT_CWD", process.cwd()),
    projectRootDir: env("CODEXBOT_TS_PROJECT_ROOT", process.cwd()),
    dbPath: env("CODEXBOT_TS_DB_PATH", `${process.cwd()}/tmp/codexbot-app-ts.sqlite`),
    approvalPolicy: env("CODEXBOT_TS_APPROVAL_POLICY", "never"),
    sandbox: env("CODEXBOT_TS_SANDBOX", "workspace-write"),
  };
}
