import test from "node:test";
import assert from "node:assert/strict";
import { snapshotSchemas, compareContracts } from "./codex-contract.mjs";
const schema = {type:"object",properties:{threadId:{type:"string"},delta:{type:"string"},turn:{type:"object",properties:{id:{type:"string"}}}},required:["threadId"]};
test("consumed field type drift is detected while added optional fields pass", () => {
  const old = snapshotSchemas(() => structuredClone(schema));
  const addition = snapshotSchemas(() => ({...schema,properties:{...schema.properties,future:{type:"string"}}}));
  assert.deepEqual(compareContracts(old,addition),[]);
  const changed = snapshotSchemas(() => ({...schema,properties:{...schema.properties,threadId:{type:"integer"}}}));
  assert.ok(compareContracts(old,changed).some((issue) => issue.includes("threadId")));
});
test("new required request fields fail, response additions pass", () => {
  const old = snapshotSchemas(() => structuredClone(schema));
  const changed = snapshotSchemas(() => ({...schema,required:["threadId","future"]}));
  const issues = compareContracts(old,changed);
  assert.ok(issues.some((issue) => issue.includes("adds required input future")));
  for (const surface of old.filter((entry) => entry.direction === "response")) {
    assert.ok(!issues.some((issue) => issue.includes(`${surface.file} adds required`)));
  }
});
