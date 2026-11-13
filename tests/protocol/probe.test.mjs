import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const script = fileURLToPath(new URL("./probe.mjs", import.meta.url));
test("invalid private probe configuration cannot appear in error output", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "protocol-probe-test-"));
  try {
    const config = path.join(directory,"bot.local.json");
    fs.writeFileSync(config,'{"app_secret":"SYNTHETIC_PRIVATE_VALUE", invalid-json');
    const result = spawnSync(process.execPath,[script,"--config",config,"--provider","feishu"],{encoding:"utf8"});
    assert.notEqual(result.status,0);
    assert.ok(!`${result.stdout}${result.stderr}`.includes("SYNTHETIC_PRIVATE_VALUE"));
    assert.match(result.stderr,/invalid_application_configuration/);
  } finally { fs.rmSync(directory,{recursive:true,force:true}); }
});
