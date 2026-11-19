// Only interfaces consumed by each layer are gated. Additive optional fields pass.
export const surfaces = [
  {layer:"application", file:"CommandExecutionRequestApprovalParams.json", direction:"response", paths:["threadId", "turnId", "itemId", "command"]},
  {layer:"application", file:"CommandExecutionRequestApprovalResponse.json", direction:"request", paths:["decision"]},
  {layer:"application", file:"FileChangeRequestApprovalParams.json", direction:"response", paths:["threadId", "turnId", "itemId"]},
  {layer:"application", file:"FileChangeRequestApprovalResponse.json", direction:"request", paths:["decision"]},
  {layer:"application", file:"PermissionsRequestApprovalParams.json", direction:"response", paths:["threadId", "turnId", "itemId", "permissions"]},
  {layer:"application", file:"PermissionsRequestApprovalResponse.json", direction:"request", paths:["permissions", "scope"]},
  {layer:"transport", file:"v1/InitializeParams.json", direction:"request", paths:["clientInfo.name", "clientInfo.version"]},
  {layer:"transport", file:"v1/InitializeResponse.json", direction:"response", paths:["userAgent"]},
  {layer:"application", file:"v2/ThreadStartParams.json", direction:"request", paths:["model", "cwd", "sandbox", "approvalPolicy"]},
  {layer:"application", file:"v2/ThreadResumeParams.json", direction:"request", paths:["threadId", "excludeTurns", "model", "cwd", "approvalPolicy", "sandbox"]},
  {layer:"application", file:"v2/ThreadReadParams.json", direction:"request", paths:["threadId", "includeTurns"]},
  {layer:"application", file:"v2/TurnStartParams.json", direction:"request", paths:["threadId", "input"]},
  {layer:"application", file:"v2/TurnInterruptParams.json", direction:"request", paths:["threadId", "turnId"]},
  {layer:"application", file:"v2/ThreadResumeResponse.json", direction:"response", paths:["thread.id"]},
  {layer:"application", file:"v2/ThreadStartResponse.json", direction:"response", paths:["thread.id"]},
  {layer:"application", file:"v2/TurnStartResponse.json", direction:"response", paths:["turn.id", "turn.status"]},
  {layer:"application", file:"v2/ThreadReadResponse.json", direction:"response", paths:["thread.id", "thread.turns"]},
  {layer:"application", file:"v2/AgentMessageDeltaNotification.json", direction:"response", paths:["threadId", "turnId", "itemId", "delta"]},
  {layer:"application", file:"v2/TurnCompletedNotification.json", direction:"response", paths:["threadId", "turn.id", "turn.status"]},
  {layer:"application", file:"v2/ServerRequestResolvedNotification.json", direction:"response", paths:["threadId", "requestId"]},
];
function deref(schema, root) {
  if (!schema?.$ref) return schema;
  if (!schema.$ref.startsWith("#/")) throw Error(`external reference: ${schema.$ref}`);
  return deref(schema.$ref.slice(2).split("/").reduce((s,k) => s?.[k], root), root);
}
function shape(schema, root) {
  schema = deref(schema, root);
  if (!schema) return {missing:true};
  if (schema.anyOf || schema.oneOf) return {alternatives:(schema.anyOf || schema.oneOf).map((s) => shape(s, root))};
  const result = {};
  for (const key of ["type", "enum", "const", "format", "minimum", "maximum", "minItems", "maxItems"]) if (key in schema) result[key] = schema[key];
  if (schema.items) result.items = shape(schema.items, root);
  // Object fields are selected explicitly; expanding all fields would couple unrelated APIs.
  if (schema.properties) result.type = "object";
  return result;
}
function field(root, path) {
  let schema = root;
  let required = true;
  for (const key of path.split(".")) {
    schema = deref(schema, root);
    if (schema?.anyOf) schema = schema.anyOf.map((s) => deref(s, root)).find((s) => s.properties?.[key]);
    required &&= (schema?.required || []).includes(key);
    schema = schema?.properties?.[key];
  }
  return { required, ...shape(schema, root) };
}
export function snapshotSchemas(read) {
  return surfaces.map((surface) => {
    const root = read(surface.file);
    return {...surface, required: root.required || [], fields: Object.fromEntries(surface.paths.map((p) => [p, field(root, p)]))};
  });
}
export function compareContracts(baseline, candidate) {
  const issues = [];
  for (const old of baseline) {
    const next = candidate.find((entry) => entry.file === old.file);
    if (!next) { issues.push(`${old.layer}: missing ${old.file}`); continue; }
    if (old.direction === "request") {
      for (const key of next.required) if (!old.required.includes(key)) issues.push(`${old.layer}: ${old.file} adds required input ${key}`);
    }
    for (const path of old.paths) {
      if (JSON.stringify(old.fields[path]) !== JSON.stringify(next.fields[path])) issues.push(`${old.layer}: ${old.file} changes consumed field ${path}`);
    }
  }
  return issues;
}
