import fs from "fs";
import * as path from "path";
import { loadBotConfig } from "./loader.mjs";

// vhttpd supplies the original entry, even when modules run from a build mirror.
const entry = process.argv[0];
const config = loadBotConfig(entry);

export function botDefaults() {
  return config.defaults;
}

export function botProviderConfig() {
  return config.providerConfig;
}

export function resolveApplicationPath(value) {
  return path.isAbsolute(value) ? value : path.resolve(config.configDir, value);
}

export function ensureDataDirectory() {
  fs.mkdirSync(path.dirname(config.defaults.dbPath), { recursive: true });
}

export function botAdminToken() {
  return config.adminToken;
}
