import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { snapshotSchemas, compareContracts } from "./codex-contract.mjs";
const args = process.argv.slice(2);
const value = (flag) => args[args.indexOf(flag) + 1];
const binary = args.includes("--codex") ? value("--codex") : "codex";
const baselinePath = fileURLToPath(new URL("./codex-baseline.json", import.meta.url));
let temporary;
try {
  const directory = args.includes("--schema-dir") ? value("--schema-dir") : (temporary = fs.mkdtempSync(path.join(os.tmpdir(), "vhttpd-schema-")));
  if (temporary) execFileSync(binary, ["app-server", "generate-json-schema", "--out", directory], {stdio:"pipe",timeout:60000});
  const snapshot = snapshotSchemas((file) => JSON.parse(fs.readFileSync(path.join(directory, file), "utf8")));
  const missing = snapshot.flatMap((s) => s.paths.filter((p) => s.fields[p].missing).map((p) => `${s.file}:${p}`));
  if (missing.length) throw Error(`Consumed fields missing: ${missing.join(", ")}`);
  if (args.includes("--update-baseline")) {
    fs.writeFileSync(baselinePath, JSON.stringify({generator:execFileSync(binary,["--version"],{encoding:"utf8"}).trim(),surfaces:snapshot},null,2)+"\n");
    console.log("Explicitly updated Codex contract baseline; review the diff before accepting.");
  } else {
    const baseline = JSON.parse(fs.readFileSync(baselinePath,"utf8"));
    const issues = compareContracts(baseline.surfaces,snapshot);
    if (issues.length) throw Error(issues.join("\n"));
    console.log(`Codex transport and application contracts passed (baseline ${baseline.generator}).`);
  }
} finally { if (temporary) fs.rmSync(temporary,{recursive:true,force:true}); }
