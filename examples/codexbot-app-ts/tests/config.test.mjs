import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { loadBotConfig } from "../config/loader.mjs";

const template = JSON.parse(fs.readFileSync(new URL("../config/bot.example.json", import.meta.url), "utf8"));
function fixture(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codexbot-config-"));
  fs.mkdirSync(path.join(root, "config"));
  const write = (value, name = "bot.local.json") => fs.writeFileSync(path.join(root, "config", name), JSON.stringify(value));
  try { run(root, structuredClone(template), write); }
  finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test("configuration and relative paths belong to the application, regardless of cwd or environment", () => {
  fixture((root, value, write) => {
    value.feishu.instances.main.app_id = "local-id";
    value.feishu.instances.main.app_secret = "local-secret";
    write(value);
    const previous = { ...process.env };
    const cwd = process.cwd();
    try {
      process.env.FEISHU_APP_ID = "env-id";
      process.env.FEISHU_APP_SECRET = "env-secret";
      process.env.CODEX_URL = "ws://env-server:1234";
      process.env.CODEXBOT_TS_DB_PATH = "/env/database.sqlite";
      process.env.CODEXBOT_TS_APPROVAL_POLICY = "never";
      process.chdir(os.tmpdir());
      const result = loadBotConfig(path.join(root, "app.mts"));
      assert.equal(result.defaults.dbPath, path.join(root, ".var/codexbot.sqlite"));
      assert.equal(result.defaults.cwd, path.join(root, ".var/projects/vhttpd"));
      assert.equal(result.defaults.approvalPolicy, "untrusted");
      assert.equal(result.providerConfig.providers.codex.instances.main.url, "ws://127.0.0.1:4500");
      assert.equal(result.providerConfig.providers.feishu.instances.main.app_secret, "local-secret");
    } finally {
      process.chdir(cwd);
      process.env = previous;
    }
  });
});

test("template fallback allows an unconfigured install, local config is authoritative", () => {
  fixture((root, value, write) => {
    write(value, "bot.example.json");
    assert.equal(loadBotConfig(path.join(root, "app.mts")).adminToken, "");
    fs.writeFileSync(path.join(root, "config/bot.local.json"), "{invalid");
    assert.throws(() => loadBotConfig(path.join(root, "app.mts")), /cannot read valid JSON/);
  });
});

test("separate installs resolve data and per-instance workspaces independently", () => {
  fixture((root, value, write) => {
    value.codex.instances.secondary = { startup: false, url: "ws://localhost:4501", cwd: "../projects/second" };
    write(value);
    const first = loadBotConfig(path.join(root, "app.mts"));
    assert.equal(first.providerConfig.providers.codex.instances.secondary.cwd, path.join(root, "projects/second"));
    fixture((other, otherValue, otherWrite) => {
      otherWrite(otherValue);
      const second = loadBotConfig(path.join(other, "app.mts"));
      assert.notEqual(first.defaults.dbPath, second.defaults.dbPath);
      assert.notEqual(first.defaults.cwd, second.defaults.cwd);
    });
  });
});

test("invalid configuration fails before startup without echoing secrets", () => {
  fixture((root, value, write) => {
    const secret = "do-not-echo-this-secret";
    const invalid = [
      v => { v.bot.active_stream_stale_ms = 0; },
      v => { v.codex.default_instance = "missing"; },
      v => { v.codex.instances.main.url = "https://example.com"; },
      v => { v.codex.instances.main.startup = "false"; },
      v => { v.codex.approval_policy = "typo"; },
      v => { v.feishu.instances.main.app_secret = secret; },
    ];
    for (const mutate of invalid) {
      const next = structuredClone(value);
      mutate(next);
      write(next);
      assert.throws(() => loadBotConfig(path.join(root, "app.mts")), error => !error.message.includes(secret));
    }
  });
});

test("project creation uses the application's project root when no chat override exists", async () => {
  const { createProjectAdminCommandHandlers } = await import("../lib/project-admin-commands.mjs");
  let checkedPath;
  const handlers = createProjectAdminCommandHandlers({
    ensureChatState: async () => ({}),
    getSettingValue: async () => "",
    botDefaults: () => ({ projectRootDir: "/app/projects" }),
    getProjectRecord: async () => undefined,
    normalizeImportPath: value => path.resolve("/app/projects", value),
    pathExistsAsDirectory: async value => { checkedPath = value; return true; },
    projectDirectoryExistsText: (_key, value) => value,
    replyText: (_session, value) => value,
  });
  await handlers.handleCreateCommand({ sessionKey: "chat", chatId: "chat" }, "/create demo");
  assert.equal(checkedPath, "/app/projects/demo");
});

test("the distributable template contains no provider credentials or admin token", () => {
  assert.ok(!template.admin.token, "admin.token belongs in bot.local.json");
  for (const value of Object.values(template.feishu.instances)) {
    for (const field of ["app_id", "app_secret", "verification_token", "encrypt_key"]) {
      assert.ok(!value[field], `${field} belongs in bot.local.json`);
    }
  }
});
