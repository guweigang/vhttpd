import { extractAssistantItemsFromThreadReadResult, extractAssistantTextFromExactThreadTurn, extractAssistantTextFromThreadReadResult } from "./codex.mts";

export function createCodexRpcHelpers(deps) {
  const codeQueryMethods = new Set([
    "model/list",
    "thread/list",
    "thread/read",
    "thread/loaded/list",
    "config/read",
    "skills/list",
    "plugin/list",
    "plugin/read",
    "app/list",
    "account/read",
    "account/rateLimits/read",
    "getAuthStatus",
    "mcpServerStatus/list",
    "configRequirements/read",
    "experimentalFeature/list",
  ]);

  function truncateText(text, maxLength = 3500) {
    if (typeof text !== "string") {
      return "";
    }
    if (text.length <= maxLength) {
      return text;
    }
    return `${text.slice(0, maxLength)}\n...`;
  }

  function prettyJson(value) {
    try {
      return JSON.stringify(value, null, 2);
    } catch (_) {
      return String(value);
    }
  }

  function extractThreadRows(result) {
    if (Array.isArray(result?.threads)) {
      return result.threads;
    }
    if (Array.isArray(result?.items)) {
      return result.items;
    }
    if (Array.isArray(result)) {
      return result;
    }
    return [];
  }

  function codexRpcDebugText(response) {
    const parts = [];
    if (typeof response?.errorMessage === "string" && response.errorMessage.trim() !== "") {
      parts.push(response.errorMessage.trim());
    }
    if (Array.isArray(response?.result)) {
      for (const entry of response.result) {
        if (typeof entry === "string" && entry.trim() !== "") {
          parts.push(entry.trim());
        } else if (entry && typeof entry === "object") {
          parts.push(prettyJson(entry));
        }
      }
    } else if (response?.result && typeof response.result === "object") {
      parts.push(prettyJson(response.result));
    }
    if (response?.raw && typeof response.raw === "object") {
      if (typeof response.raw.raw_response === "string" && response.raw.raw_response.trim() !== "") {
        parts.push(response.raw.raw_response.trim());
      }
      if (response.raw.error && typeof response.raw.error === "object") {
        parts.push(prettyJson(response.raw.error));
      }
    }
    return parts.join("\n").trim();
  }

  function codexRpcIndicatesMissingThread(response) {
    return codexRpcDebugText(response).toLowerCase().includes("thread not found");
  }

  function extractThreadNameFromResult(result) {
    if (!result || typeof result !== "object") {
      return "";
    }
    const thread = result.thread && typeof result.thread === "object" ? result.thread : {};
    if (typeof thread.name === "string" && thread.name.trim() !== "") {
      return thread.name.trim();
    }
    if (typeof thread.title === "string" && thread.title.trim() !== "") {
      return thread.title.trim();
    }
    return "";
  }

  function summarizeThreadRow(thread, index) {
    const id = thread?.id || thread?.threadId || `thread_${index + 1}`;
    const title = thread?.name || thread?.title || thread?.preview || "";
    const status = thread?.status?.type || thread?.status || "";
    const lines = [`**${index + 1}. ${deps.mdInline(id)}**`];
    if (title) {
      lines.push(deps.mdBullet("Title", title));
    }
    if (status) {
      lines.push(deps.mdBullet("Status", status, { code: true }));
    }
    return lines.join("\n");
  }

  function summarizeModelRow(model, index) {
    const id = model?.id || model?.name || `model_${index + 1}`;
    const provider = model?.provider || model?.modelProvider || "";
    const lines = [`**${index + 1}. ${deps.mdInline(id)}**`];
    if (provider) {
      lines.push(deps.mdBullet("Provider", provider, { code: true }));
    }
    return lines.join("\n");
  }

  function formatCodexRpcResult(method, result, rawResult = result) {
    if (method === "thread/list") {
      const threads = extractThreadRows(result);
      if (threads.length) {
        return [deps.mdSection("Codex RPC", [deps.mdBullet("Method", method, { code: true })]), "", ...threads.slice(0, 10).flatMap((thread, index) => {
          const lines = [summarizeThreadRow(thread, index)];
          if (index < Math.min(threads.length, 10) - 1) {
            lines.push("");
          }
          return lines;
        })].join("\n").trim();
      }
    }
    if (method === "model/list") {
      const models = Array.isArray(result?.models) ? result.models : Array.isArray(result?.items) ? result.items : Array.isArray(result) ? result : [];
      if (models.length) {
        return [deps.mdSection("Codex RPC", [deps.mdBullet("Method", method, { code: true })]), "", ...models.slice(0, 20).map((model, index) => summarizeModelRow(model, index))].join("\n");
      }
    }
    return `${deps.mdSection("Codex RPC", [deps.mdBullet("Method", method, { code: true })])}\n\n\`\`\`json\n${truncateText(prettyJson(rawResult))}\n\`\`\``;
  }

  function extractAnswerFromThreadReadResult(result, preferredTurnId = "") {
    return extractAssistantTextFromThreadReadResult(result, preferredTurnId);
  }

  function extractExactAnswerFromThreadReadResult(result, preferredTurnId = "") {
    return extractAssistantTextFromExactThreadTurn(result, preferredTurnId);
  }

  function extractAssistantItemsFromReadResult(result, preferredTurnId = "") {
    return extractAssistantItemsFromThreadReadResult(result, preferredTurnId);
  }

  function defaultCodexParams(method, state) {
    switch (method) {
      case "model/list":
        return { limit: 20 };
      case "thread/list":
        return { limit: 10, cwd: state.cwd };
      case "thread/read":
        return state.threadId ? { threadId: state.threadId, includeTurns: true } : { includeTurns: true };
      case "thread/loaded/list":
        return {};
      case "config/read":
        return { includeLayers: true, cwd: state.cwd };
      case "skills/list":
        return { cwds: [state.cwd], forceReload: false };
      case "plugin/list":
        return {};
      case "plugin/read":
        return {};
      case "app/list":
        return { limit: 20, threadId: state.threadId || null };
      case "account/read":
        return { refreshToken: false };
      case "account/rateLimits/read":
        return {};
      case "getAuthStatus":
        return {};
      case "mcpServerStatus/list":
        return { limit: 20 };
      case "configRequirements/read":
        return {};
      case "experimentalFeature/list":
        return {};
      default:
        return undefined;
    }
  }

  function parseCodexCommand(text) {
    const trimmed = typeof text === "string" ? text.trim() : "";
    if (trimmed === "/codex") {
      return { method: "", params: undefined, error: "" };
    }
    const rest = trimmed.replace(/^\/codex\s+/, "").trim();
    if (!rest) {
      return { method: "", params: undefined, error: "" };
    }
    const firstSpace = rest.indexOf(" ");
    const method = firstSpace === -1 ? rest : rest.slice(0, firstSpace).trim();
    const rawParams = firstSpace === -1 ? "" : rest.slice(firstSpace + 1).trim();
    if (!method) {
      return { method: "", params: undefined, error: "" };
    }
    if (!rawParams) {
      return { method, params: undefined, error: "" };
    }
    try {
      const parsed = JSON.parse(rawParams);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        return { method, params: undefined, error: "JSON params must be an object." };
      }
      return { method, params: parsed, error: "" };
    } catch (_) {
      return { method, params: undefined, error: "Invalid JSON params." };
    }
  }

  function normalizeCodexAlias(method, params, state) {
    switch (method) {
      case "models":
        return { method: "model/list", params };
      case "threads":
        return { method: "thread/list", params };
      case "thread":
        return {
          method: "thread/read",
          params: params || (state.threadId ? { threadId: state.threadId, includeTurns: true } : undefined),
        };
      case "config":
        return { method: "config/read", params };
      case "skills":
        return { method: "skills/list", params };
      case "apps":
        return { method: "app/list", params };
      default:
        return { method, params };
    }
  }

  function readFinalAnswerFromSessionPath(runtime, sessionPath, preferredTurnId = "") {
    if (typeof sessionPath !== "string" || sessionPath.trim() === "") {
      return "";
    }
    if (!runtime || typeof runtime.readTextFile !== "function") {
      return "";
    }
    const normalizedTurnId = typeof preferredTurnId === "string" ? preferredTurnId.trim() : "";
    try {
      const raw = runtime.readTextFile(sessionPath, "");
      if (typeof raw !== "string" || raw.trim() === "") {
        return "";
      }
      const lines = raw.split(/\r?\n/).filter(Boolean);
      let matchedTurnSeen = false;
      for (let i = lines.length - 1; i >= 0; i -= 1) {
        let row;
        try {
          row = JSON.parse(lines[i]);
        } catch (_) {
          continue;
        }
        const rowTurnId = typeof row?.turnId === "string"
          ? row.turnId.trim()
          : (typeof row?.payload?.turnId === "string" ? row.payload.turnId.trim() : "");
        const payload = row && typeof row === "object" ? row.payload : undefined;
        if (!payload || typeof payload !== "object") {
          continue;
        }
        if (normalizedTurnId && rowTurnId === normalizedTurnId) {
          matchedTurnSeen = true;
        }
        if (row.type === "event_msg" && payload.type === "agent_message" && typeof payload.message === "string" && payload.message.trim() !== "") {
          const message = payload.message.trim();
          if (normalizedTurnId) {
            if (rowTurnId !== normalizedTurnId) {
              continue;
            }
            if (payload.phase === "final_answer") {
              return message;
            }
            continue;
          }
          if (payload.phase === "final_answer") {
            return message;
          }
          continue;
        }
        if (row.type === "response_item" && payload.type === "message" && payload.role === "assistant" && Array.isArray(payload.content)) {
          let message = "";
          for (const part of payload.content) {
            if (part && typeof part.text === "string" && part.text.trim() !== "") {
              message = part.text.trim();
              break;
            }
          }
          if (!message) {
            continue;
          }
          if (normalizedTurnId) {
            if (rowTurnId !== normalizedTurnId) {
              continue;
            }
            if (payload.phase === "final_answer") {
              return message;
            }
            continue;
          }
          if (payload.phase === "final_answer") {
            return message;
          }
        }
      }
      if (normalizedTurnId) {
        return matchedTurnSeen ? "" : "";
      }
      return "";
    } catch (_) {
      return "";
    }
    return "";
  }

  return {
    codeQueryMethods,
    codexRpcDebugText,
    codexRpcIndicatesMissingThread,
    defaultCodexParams,
    extractAnswerFromThreadReadResult,
    extractExactAnswerFromThreadReadResult,
    extractAssistantItemsFromReadResult,
    extractThreadNameFromResult,
    formatCodexRpcResult,
    normalizeCodexAlias,
    parseCodexCommand,
    prettyJson,
    readFinalAnswerFromSessionPath,
    truncateText,
  };
}
