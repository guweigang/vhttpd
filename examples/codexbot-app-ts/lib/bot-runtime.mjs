import { mkdir, stat } from "fs";
import * as path from "path";
import { feishuText, feishuUpdateText, codexRpcCall, codexTurnStart, codexTurnInterrupt, codexSessionClear, feishuSessionClear } from "./commands.mts";
import { parseFeishuInboundFrame } from "./feishu.mts";
import { parseCodexRpcResponse, parseCodexNotification } from "./codex.mts";
import { botDefaults } from "./config.mts";
import {
  appendStreamDraft,
  bindProjectToChat,
  clearSelectionScope,
  bindThreadToStream,
  createStreamState,
  ensureChatState,
  ensureProjectRecord,
  finalizeStreamState,
  getProjectRecord,
  getSettingValue,
  getSelectionScope,
  getLatestProjectThread,
  getStreamState,
  listBoundChatProjects,
  listChatProjects,
  listRecentProjectThreads,
  listSettings,
  rememberSelectionScope,
  resetChatThread,
  runtimeSnapshot,
  unbindProjectFromChat,
  upsertSetting,
  updateProjectRecordPath,
  updateStreamState,
  updateChatState,
} from "./state.mjs";

const CODEXBOT_TS_BUILD = "codexbot-ts-2026-03-28-idle-thread-read-v2";

function mdInline(value) {
  const text = typeof value === "string" ? value.trim() : String(value ?? "").trim();
  if (text === "") {
    return "`-`";
  }
  return `\`${text.replace(/`/g, "'")}\``;
}

function mdText(value) {
  return typeof value === "string" ? value.trim() : String(value ?? "").trim();
}

function mdSection(title, lines = []) {
  const body = lines.filter((line) => typeof line === "string" && line.trim() !== "");
  if (!body.length) {
    return `**${title}**`;
  }
  return [`**${title}**`, ...body].join("\n");
}

function mdBullet(label, value, { code = false } = {}) {
  const text = mdText(value);
  if (text === "") {
    return "";
  }
  return `- ${label}: ${code ? mdInline(text) : text}`;
}

function containsMarkdownSyntax(text) {
  if (typeof text !== "string") {
    return false;
  }
  return /(^|\n)(#{1,6}\s|[-*]\s|\d+\.\s|>\s)|```|\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)/m.test(text);
}

function looksLikeLabelValueLine(line) {
  return /^[A-Za-z][A-Za-z0-9 /_-]{1,32}:\s+.+$/.test(line);
}

function looksLikeBulletLine(line) {
  return /^[-*+•]\s+.+$/.test(line);
}

function looksLikeNumberedLine(line) {
  return /^\d+[\.\)]\s+.+$/.test(line);
}

function normalizeListLine(line) {
  if (looksLikeBulletLine(line)) {
    return line.replace(/^[-*+•]\s+/, "- ");
  }
  if (looksLikeNumberedLine(line)) {
    return line.replace(/^(\d+)\)\s+/, "$1. ");
  }
  return line;
}

function looksLikeCodeLine(line) {
  return /[{};<>]/.test(line)
    || /=>/.test(line)
    || /^\s*(const|let|var|if|else|for|while|return|function|class|interface|type|import|export|SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|WITH)\b/i.test(line)
    || /^\s*<\/?[A-Za-z][^>]*>$/.test(line)
    || /^\s*[A-Za-z0-9_.]+\([^)]*\)\s*$/.test(line)
    || /^\s*[\[{].*[\]}]\s*$/.test(line);
}

function looksLikeCodeBlock(lines) {
  if (!Array.isArray(lines) || lines.length < 2) {
    return false;
  }
  let score = 0;
  for (const line of lines) {
    if (looksLikeCodeLine(line)) {
      score += 1;
    }
  }
  return score >= Math.max(2, Math.ceil(lines.length / 2));
}

function joinWrappedParagraph(lines) {
  return lines
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function splitMarkdownBlocks(text) {
  const lines = typeof text === "string" ? text.replace(/\r\n/g, "\n").split("\n") : [];
  const blocks = [];
  let current = [];
  let inFence = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("```")) {
      if (!inFence && current.length) {
        blocks.push({ type: "text", lines: current.slice() });
        current = [];
      }
      current.push(line);
      inFence = !inFence;
      if (!inFence) {
        blocks.push({ type: "fence", lines: current.slice() });
        current = [];
      }
      continue;
    }
    if (inFence) {
      current.push(line);
      continue;
    }
    if (trimmed === "") {
      if (current.length) {
        blocks.push({ type: "text", lines: current.slice() });
        current = [];
      }
      continue;
    }
    current.push(line);
  }
  if (current.length) {
    blocks.push({ type: inFence ? "fence" : "text", lines: current.slice() });
  }
  return blocks;
}

function looksLikeHeadingLine(line) {
  return /^#{1,6}\s+.+$/.test(line.trim());
}

function looksLikeQuoteLine(line) {
  return /^>\s+.+$/.test(line.trim());
}

function looksLikeTableRow(line) {
  const trimmed = line.trim();
  return trimmed.includes("|") && /^\|?.+\|.+\|?$/.test(trimmed);
}

function looksLikeTableDivider(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line.trim());
}

function parseTableCells(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function renderMarkdownTableBlock(lines) {
  if (lines.length < 2 || !looksLikeTableRow(lines[0]) || !looksLikeTableDivider(lines[1])) {
    return "";
  }
  const headers = parseTableCells(lines[0]);
  const rows = lines.slice(2).filter((line) => looksLikeTableRow(line));
  if (!headers.length || !rows.length) {
    return "";
  }
  return rows.map((line, index) => {
    const cells = parseTableCells(line);
    const parts = [];
    for (let i = 0; i < headers.length; i += 1) {
      const header = headers[i] || `col_${i + 1}`;
      const value = cells[i] || "";
      if (value) {
        parts.push(`**${header}**: ${value}`);
      }
    }
    return `${index + 1}. ${parts.join(" | ")}`.trim();
  }).join("\n");
}

function normalizeMarkdownTextBlock(lines) {
  const trimmedLines = lines.map((line) => line.replace(/\s+$/g, ""));
  const compact = trimmedLines.map((line) => line.trim()).filter(Boolean);
  if (!compact.length) {
    return "";
  }
  if (compact.length >= 2 && compact.every(looksLikeLabelValueLine)) {
    return compact.map((line) => {
      const index = line.indexOf(":");
      const label = line.slice(0, index).trim();
      const value = line.slice(index + 1).trim();
      return `- **${label}**: ${value}`;
    }).join("\n");
  }
  if (compact.every((line) => looksLikeBulletLine(line) || looksLikeNumberedLine(line))) {
    return compact.map((line) => normalizeListLine(line)).join("\n");
  }
  const tableBlock = renderMarkdownTableBlock(trimmedLines);
  if (tableBlock) {
    return tableBlock;
  }
  if (compact.some((line) => looksLikeHeadingLine(line) || looksLikeQuoteLine(line))) {
    return trimmedLines.map((line) => normalizeListLine(line)).join("\n").trim();
  }
  return joinWrappedParagraph(trimmedLines);
}

function normalizeMarkdownForFeishu(text) {
  const raw = typeof text === "string" ? text.replace(/\r\n/g, "\n").trim() : "";
  if (raw === "") {
    return "";
  }
  const blocks = splitMarkdownBlocks(raw)
    .map((block) => {
      if (block.type === "fence") {
        return block.lines.join("\n").trim();
      }
      return normalizeMarkdownTextBlock(block.lines);
    })
    .filter((block) => typeof block === "string" && block.trim() !== "");
  return blocks.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
}

function renderPlainAssistantBlock(block) {
  const rawLines = block.split("\n").map((line) => line.replace(/\s+$/g, ""));
  const lines = rawLines.map((line) => line.trim()).filter(Boolean);
  if (!lines.length) {
    return "";
  }
  if (lines.length >= 2 && lines.every(looksLikeLabelValueLine)) {
    return lines.map((line) => {
      const index = line.indexOf(":");
      const label = line.slice(0, index).trim();
      const value = line.slice(index + 1).trim();
      return `- **${label}**: ${value}`;
    }).join("\n");
  }
  if (lines.every((line) => looksLikeBulletLine(line) || looksLikeNumberedLine(line))) {
    return lines.map((line) => normalizeListLine(line)).join("\n");
  }
  if (looksLikeCodeBlock(rawLines.filter((line) => line.trim() !== ""))) {
    return ["```", ...rawLines.filter((line) => line.trim() !== ""), "```"].join("\n");
  }
  return joinWrappedParagraph(rawLines);
}

function renderCodexAssistantText(text) {
  const raw = typeof text === "string" ? text.replace(/\r\n/g, "\n").trim() : "";
  if (raw === "") {
    return "";
  }
  if (containsMarkdownSyntax(raw)) {
    return normalizeMarkdownForFeishu(raw);
  }
  const blocks = raw
    .split(/\n{2,}/)
    .map((block) => renderPlainAssistantBlock(block))
    .filter(Boolean);
  const body = blocks.join("\n\n").trim();
  return body === "" ? "" : normalizeMarkdownForFeishu(body);
}

function helpText() {
  return [
    mdSection("Project", [
      "- `help` / `/help`",
      "- `/create [project_key]`",
      "- `/bind [project_key] [path]`",
      "- `/unbind [project_key]`",
      "- `/projects`",
      "- `/project` / `/project [project_key]`",
    ]),
    mdSection("Model", [
      "- `/models` / `/model [model_id]`",
    ]),
    mdSection("Thread", [
      "- `/threads`",
      "- `/thread` / `/thread [thread_id]`",
      "- `/use [project_key|model_id|thread_id]`",
      "- `/use latest`",
      "- `/new [model_id]`",
      "- `/cancel`",
    ]),
    mdSection("Runtime", [
      "- `/settings` / `/setting [name] [value]`",
      "- `/codex models|threads|thread|config|skills|apps`",
    ]),
    mdSection("Notes", [
      "- `/create` only works for a brand-new project key and a brand-new directory.",
      "- `/bind` registers or completes a project path and binds it to this chat without switching the current session.",
      "- `/unbind` only works for non-current projects.",
      "- `/project [project_key]` only switches to a project already bound to this chat.",
      "- `/use` keeps the last selection scope until the next non-`/use` command.",
      "- In thread scope, `/use` also reads the latest assistant reply from the selected thread.",
      "- `/import` has been merged into `/bind`.",
      "- Plain text messages start a Codex task in the current project context.",
      "- In Feishu threads, session state is scoped to the current thread.",
    ]),
  ].join("\n\n");
}

function isThreadScopedSession(sessionKey) {
  return typeof sessionKey === "string" && sessionKey.includes("::thread:");
}

function sessionScopeText(sessionKey) {
  return isThreadScopedSession(sessionKey) ? "current Feishu thread" : "whole chat";
}

function taskQueuedText(stream) {
  return mdSection("Queued", [
    mdBullet("Project", stream.projectKey, { code: true }),
    mdBullet("Model", stream.model, { code: true }),
    mdBullet("Mode", stream.threadId ? "reuse" : "new", { code: true }),
    mdBullet("Thread", stream.threadId || "new thread", { code: true }),
    mdBullet("Stream", stream.streamId, { code: true }),
  ]);
}

function threadBoundText(threadId) {
  return mdSection("Thread Ready", [
    mdInline(threadId),
  ]);
}

function taskRunningText(stream) {
  return mdSection("Running", [
    mdBullet("Project", stream.projectKey, { code: true }),
    mdBullet("Model", stream.model, { code: true }),
    mdBullet("Mode", stream.threadId ? "reuse" : "new", { code: true }),
    mdBullet("Thread", stream.threadId || "starting", { code: true }),
  ]);
}

function currentProjectText(state) {
  return mdSection("Current Project", [
    mdBullet("Project", state.projectKey, { code: true }),
    mdBullet("CWD", state.cwd, { code: true }),
  ]);
}

function projectSelectedText(state) {
  return mdSection("Project Updated", [
    mdBullet("Project", state.projectKey, { code: true }),
    mdBullet("CWD", state.cwd, { code: true }),
  ]);
}

function projectCreatedText(project, state) {
  return mdSection("Project Created", [
    mdBullet("Project", project.projectKey, { code: true }),
    mdBullet("Path", project.repoPath, { code: true }),
    mdBullet("Current Project", state.projectKey, { code: true }),
    mdBullet("Model", state.model, { code: true }),
  ]);
}

function settingsEmptyText() {
  return mdSection("Settings", [
    "- No settings configured yet.",
    "- Use `/setting project_root_dir [path]` first.",
  ]);
}

function settingsListText(settings) {
  const lines = [];
  for (const setting of settings) {
    lines.push(`- ${mdInline(setting.name)} = ${mdInline(setting.value)}`);
  }
  return mdSection("Current Settings", lines);
}

function settingUpdatedText(name, value) {
  return mdSection("Setting Updated", [
    `- ${mdInline(name)} = ${mdInline(value)}`,
  ]);
}

function projectRootMissingText() {
  return mdSection("Project Root Missing", [
    "- Use `/setting project_root_dir [path]` first.",
  ]);
}

function usageText(command, syntax) {
  return mdSection("Usage", [
    `- ${mdInline(command)} ${syntax}`.trim(),
  ]);
}

function useCommandSyntax(scope) {
  switch (scope) {
    case "project":
      return "[project_key]";
    case "model":
      return "[model_id]";
    case "thread":
      return "latest | [thread_id]";
    default:
      return "[project_key|model_id|thread_id] | latest";
  }
}

function importPathInvalidText(repoPath) {
  return mdSection("Import Path Invalid", [
    mdBullet("Path", repoPath, { code: true }),
    "- The path must point to an existing directory.",
  ]);
}

function codexCommandHelpText(state) {
  return [
    mdSection("Codex RPC Query", [
      "- `/codex models`",
      "- `/codex threads`",
      "- `/codex thread`",
      "- `/codex config`",
      "- `/codex skills`",
      "- `/codex apps`",
      "- `/codex thread/read {\"threadId\":\"...\",\"includeTurns\":true}`",
    ]),
    mdSection("Current Context", [
      mdBullet("CWD", state.cwd, { code: true }),
      mdBullet("Thread", state.threadId || "not bound", { code: true }),
    ]),
  ].join("\n\n");
}

function codexRpcQueuedText(method) {
  return mdSection("Codex RPC Query", [
    mdBullet("Method", method, { code: true }),
    "- Query sent to Codex.",
  ]);
}

function threadReadQueuedText() {
  return "Reading the latest assistant reply from this thread.";
}

function codexRpcErrorText(method, message) {
  return mdSection("Codex RPC Error", [
    mdBullet("Method", method, { code: true }),
    message || "",
  ]);
}

function unsupportedCodexMethodText(method) {
  return mdSection("Unsupported Codex Method", [
    mdBullet("Method", method, { code: true }),
    "- Only query-style RPC methods are allowed.",
  ]);
}

function codexThreadRequiredText() {
  return mdSection("Thread Required", [
    "- Use `/thread` first, or send `/codex thread/read {\"threadId\":\"...\",\"includeTurns\":true}`.",
  ]);
}

function threadReadEmptyText(threadId) {
  return mdSection("Thread Read", [
    mdBullet("Thread", threadId || "unknown", { code: true }),
    "- No assistant reply was found in this thread yet.",
  ]);
}

function codexErrorText(method) {
  return mdSection("Codex Error", [
    mdBullet("Method", method, { code: true }),
  ]);
}

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

function summarizeThreadRow(thread, index) {
  const id = thread?.id || thread?.threadId || `thread_${index + 1}`;
  const title = thread?.name || thread?.title || thread?.preview || "";
  const status = thread?.status?.type || thread?.status || "";
  const lines = [`**${index + 1}. ${mdInline(id)}**`];
  if (title) {
    lines.push(mdBullet("Title", title));
  }
  if (status) {
    lines.push(mdBullet("Status", status, { code: true }));
  }
  return lines.join("\n");
}

function summarizeModelRow(model, index) {
  const id = model?.id || model?.name || `model_${index + 1}`;
  const provider = model?.provider || model?.modelProvider || "";
  const lines = [`**${index + 1}. ${mdInline(id)}**`];
  if (provider) {
    lines.push(mdBullet("Provider", provider, { code: true }));
  }
  return lines.join("\n");
}

function formatCodexRpcResult(method, result, rawResult = result) {
  if (method === "thread/list") {
    const threads = extractThreadRows(result);
    if (threads.length) {
      return [mdSection("Codex RPC", [mdBullet("Method", method, { code: true })]), "", ...threads.slice(0, 10).flatMap((thread, index) => {
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
      return [mdSection("Codex RPC", [mdBullet("Method", method, { code: true })]), "", ...models.slice(0, 20).map((model, index) => summarizeModelRow(model, index))].join("\n");
    }
  }
  return `${mdSection("Codex RPC", [mdBullet("Method", method, { code: true })])}\n\n\`\`\`json\n${truncateText(prettyJson(rawResult))}\n\`\`\``;
}

function extractAnswerFromThreadItem(item) {
  if (!item || typeof item !== "object") {
    return "";
  }
  if (item.type === "agentMessage" && typeof item.text === "string" && item.text.trim() !== "") {
    return item.text.trim();
  }
  if (item.type === "message" && item.role === "assistant" && Array.isArray(item.content)) {
    const text = item.content
      .filter((part) => part && typeof part === "object" && typeof part.text === "string" && part.text.trim() !== "")
      .map((part) => part.text.trim())
      .join("\n")
      .trim();
    if (text) {
      return text;
    }
  }
  return "";
}

function extractAnswerFromThreadReadResult(result) {
  const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : Array.isArray(result?.turns) ? result.turns : [];
  let fallback = "";
  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const items = Array.isArray(turns[turnIndex]?.items) ? turns[turnIndex].items : [];
    for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const item = items[itemIndex];
      const text = extractAnswerFromThreadItem(item);
      if (!text) {
        continue;
      }
      if (item?.phase === "final_answer") {
        return text;
      }
      if (!fallback) {
        fallback = text;
      }
    }
  }
  return fallback;
}

function codexFinalizingText() {
  return mdSection("Finishing", [
    "- Waiting for final answer from Codex.",
  ]);
}

function projectRegisteredText(project, state) {
  return mdSection("Project Registered", [
    mdBullet("Project", project.projectKey, { code: true }),
    mdBullet("Path", project.repoPath, { code: true }),
    mdBullet("Current Project", state.projectKey, { code: true }),
    mdBullet("Model", state.model, { code: true }),
  ]);
}

function projectBoundText(projectKey, repoPath = "") {
  const lines = [
    mdBullet("Project", projectKey, { code: true }),
    "- Current session project is unchanged.",
  ];
  if (repoPath) {
    lines.splice(1, 0, mdBullet("Path", repoPath, { code: true }));
  }
  return mdSection("Project Bound", lines);
}

function projectPathFilledText(project, state) {
  return mdSection("Project Path Updated", [
    mdBullet("Project", project.projectKey, { code: true }),
    mdBullet("Path", project.repoPath, { code: true }),
    mdBullet("Current Project", state.projectKey, { code: true }),
    mdBullet("Model", state.model, { code: true }),
  ]);
}

function projectExistsText(projectKey, repoPath) {
  return mdSection("Project Exists", [
    mdBullet("Project", projectKey, { code: true }),
    mdBullet("Path", repoPath, { code: true }),
  ]);
}

function projectDirectoryExistsText(projectKey, repoPath) {
  return mdSection("Project Directory Exists", [
    mdBullet("Project", projectKey, { code: true }),
    mdBullet("Path", repoPath, { code: true }),
    "- `/create` only works when the target directory does not exist yet.",
  ]);
}

function projectMissingText(projectKey) {
  return mdSection("Unknown Project", [
    mdInline(projectKey),
  ]);
}

function projectPathAlreadyBoundText(projectKey, repoPath) {
  return mdSection("Project Path Already Bound", [
    mdBullet("Project", projectKey, { code: true }),
    mdBullet("Existing Path", repoPath, { code: true }),
    "- Use `/project [project_key]` to switch, or choose a new project key.",
  ]);
}

function bindMergedText() {
  return mdSection("Command Updated", [
    "- `/import` has been merged into `/bind`.",
    "- Use `/bind [project_key] [path]`.",
  ]);
}

function projectUnboundText(projectKey) {
  return mdSection("Project Unbound", [
    mdBullet("Project", projectKey, { code: true }),
    "- Chat binding removed.",
  ]);
}

function projectNotBoundText(projectKey) {
  return mdSection("Project Not Bound", [
    mdBullet("Project", projectKey, { code: true }),
    "- No explicit chat binding exists for this project.",
    "- Use `/bind [project_key] [path]` first.",
  ]);
}

function projectUnbindCurrentBlockedText(projectKey) {
  return mdSection("Cannot Unbind Current Project", [
    mdBullet("Project", projectKey, { code: true }),
    "- Switch to another project first, then run `/unbind` again.",
  ]);
}

function currentModelText(state) {
  return mdSection("Current Model", [
    mdInline(state.model),
  ]);
}

function modelSelectedText(state) {
  return mdSection("Model Updated", [
    mdInline(state.model),
  ]);
}

function currentThreadText(state) {
  return state.threadId ? `Current thread: ${mdInline(state.threadId)}` : "No thread is currently bound.";
}

function currentThreadSummaryText(state, stream) {
  const lines = [
    mdBullet("Session Scope", sessionScopeText(state.sessionKey)),
    currentThreadText(state),
    mdBullet("Next Prompt", state.threadId ? "reuse current thread" : "start new thread"),
  ];
  if (stream) {
    lines.push(mdBullet("Last Stream", stream.streamId, { code: true }));
    lines.push(mdBullet("Last Status", stream.status || "queued", { code: true }));
    if (stream.prompt) {
      lines.push(mdBullet("Last Prompt", stream.prompt));
    }
  }
  return mdSection("Current Thread", lines);
}

function formatThreadEntry(stream, index, currentThreadId = "") {
  const lines = [
    `**${index}. ${mdInline(stream.threadId)}${stream.threadId === currentThreadId ? " current" : ""}**`,
    mdBullet("Status", stream.status || "queued", { code: true }),
  ];
  if (stream.prompt) {
    lines.push(mdBullet("Prompt", stream.prompt));
  }
  return lines.join("\n");
}

function formatProjectEntry(project, currentProjectKey, index) {
  const badge = project.projectKey === currentProjectKey ? " current" : "";
  const lines = [
    `**${index}. ${mdInline(project.projectKey)}${badge}**`,
    mdBullet("Model", project.model, { code: true }),
    mdBullet("Path", project.cwd, { code: true }),
  ];
  lines.push(mdBullet("Thread", project.threadId || "not bound", { code: true }));
  return lines.join("\n");
}

function projectsListText(state, projects) {
  const lines = [mdBullet("Chat", state.chatId, { code: true })];
  if (!projects.length) {
    lines.push("- No bound projects yet.");
    lines.push("- Use `/bind [project_key] [path]` first.");
    return mdSection("Projects", lines);
  }
  lines.push("");
  for (let i = 0; i < projects.length; i += 1) {
    lines.push(formatProjectEntry(projects[i], state.projectKey, i + 1));
    if (i < projects.length - 1) {
      lines.push("");
    }
  }
  lines.push("");
  lines.push("- Use `/project [project_key]` or `/use [project_key]` to switch.");
  return mdSection("Projects", lines);
}

function modelsListText(state, models) {
  const lines = [mdBullet("Current", state.model, { code: true })];
  if (!models.length) {
    lines.push("- No models configured.");
    return mdSection("Configured Models", lines);
  }
  lines.push("");
  for (let i = 0; i < models.length; i += 1) {
    const model = models[i];
    lines.push(`**${i + 1}. ${mdInline(model)}${model === state.model ? " current" : ""}**`);
  }
  lines.push("");
  lines.push("- Use `/model [model_id]` or `/use [model_id]` to switch.");
  return mdSection("Configured Models", lines);
}

function threadsListText(state, streams) {
  const lines = [
    mdBullet("Project", state.projectKey, { code: true }),
    mdBullet("Current", state.threadId || "not bound", { code: true }),
    mdBullet("Next Prompt", state.threadId ? "reuse current thread" : "start new thread"),
  ];
  if (!streams.length) {
    lines.push("- No known threads yet.");
    lines.push("- Send a prompt first, or use `/new` to start a fresh thread next.");
    return mdSection("Recent Threads", lines);
  }
  lines.push("");
  for (let i = 0; i < streams.length; i += 1) {
    lines.push(formatThreadEntry(streams[i], i + 1, state.threadId || ""));
    if (i < streams.length - 1) {
      lines.push("");
    }
  }
  return mdSection("Recent Threads", lines);
}

function threadSelectedText(state, threadId, sourceStream) {
  const lines = [mdBullet("Thread", threadId, { code: true }), mdBullet("Session Scope", sessionScopeText(state.sessionKey))];
  if (sourceStream?.prompt) {
    lines.push(mdBullet("Latest Prompt", sourceStream.prompt));
  }
  if (sourceStream?.status) {
    lines.push(mdBullet("Latest Status", sourceStream.status, { code: true }));
  }
  lines.push(mdBullet("Next Prompt", "reuse current thread"));
  lines.push("- Next prompt will continue on this thread.");
  return mdSection("Thread Selected", lines);
}

function latestThreadMissingText(state) {
  return mdSection("Recent Threads", [
    `- No recent threads found for project ${mdInline(state.projectKey)}.`,
  ]);
}

function newConversationText(state, previousThreadId, previousModel) {
  const lines = ["- Thread binding cleared.", mdBullet("Session Scope", sessionScopeText(state.sessionKey))];
  if (previousThreadId) {
    lines.push(mdBullet("Previous Thread", previousThreadId, { code: true }));
  }
  if (previousModel && previousModel !== state.model) {
    lines.push(`- Model switched: ${mdInline(previousModel)} -> ${mdInline(state.model)}`);
  }
  lines.push(mdBullet("Next Prompt", "start new thread"));
  lines.push("- Next prompt will start a new thread.");
  return mdSection("New Conversation", lines);
}

function isActiveStream(stream) {
  if (!stream || typeof stream !== "object") {
    return false;
  }
  const status = typeof stream.status === "string" ? stream.status.trim().toLowerCase() : "";
  return ["queued", "thread_ready", "running", "streaming"].includes(status);
}

function busyText(stream) {
  const lines = [
    isThreadScopedSession(stream.sessionKey)
      ? "Still working on the previous request in this thread."
      : "Still working on the previous request.",
    mdBullet("Last Stream", stream.streamId, { code: true }),
    mdBullet("Status", stream.status || "queued", { code: true }),
  ];
  if (stream.prompt) {
    lines.push(mdBullet("Prompt", stream.prompt));
  }
  lines.push("- Use `/cancel` to detach this run, or wait for Codex to finish.");
  return mdSection("Busy", lines);
}

function cancelIdleText(sessionKey) {
  return isThreadScopedSession(sessionKey)
    ? mdSection("Cancel", ["- No active Codex run to cancel in this thread."])
    : mdSection("Cancel", ["- No active Codex run to cancel."]);
}

function cancelDetachedText(stream) {
  const lines = [
    isThreadScopedSession(stream.sessionKey)
      ? "Detached the current run from this thread session."
      : "Detached the current run from this chat.",
    mdBullet("Stream", stream.streamId, { code: true }),
  ];
  if (stream.threadId) {
    lines.push(mdBullet("Thread", stream.threadId, { code: true }));
  }
  if (stream.prompt) {
    lines.push(mdBullet("Prompt", stream.prompt));
  }
  lines.push("- The next prompt will start a new thread.");
  return mdSection("Run Detached", lines);
}

function cancelInterruptingText(stream) {
  const lines = [
    isThreadScopedSession(stream.sessionKey)
      ? "Interrupt requested for the current run in this thread."
      : "Interrupt requested for the current run.",
    mdBullet("Stream", stream.streamId, { code: true }),
  ];
  if (stream.threadId) {
    lines.push(mdBullet("Thread", stream.threadId, { code: true }));
  }
  if (stream.turnId) {
    lines.push(mdBullet("Turn", stream.turnId, { code: true }));
  }
  if (stream.prompt) {
    lines.push(mdBullet("Prompt", stream.prompt));
  }
  lines.push("- The next prompt will start a new thread.");
  return mdSection("Interrupt Requested", lines);
}

function codexStatusText(status, detail) {
  const label = typeof status === "string" && status.trim() !== "" ? status.trim() : "running";
  return detail && detail.trim() !== ""
    ? mdSection("Codex Status", [mdBullet("Status", label, { code: true }), detail])
    : mdSection("Codex Status", [mdBullet("Status", label, { code: true })]);
}

function isTerminalIdleStatus(status) {
  return typeof status === "string" && status.trim().toLowerCase() === "idle";
}

function sandboxPolicyType(sandbox) {
  switch (sandbox) {
    case "workspace-write":
      return "workspaceWrite";
    case "danger-full-access":
      return "dangerFullAccess";
    case "read-only":
      return "readOnly";
    default:
      return "workspaceWrite";
  }
}

function buildThreadStartParams(state, defaults) {
  return {
    cwd: state.cwd,
    model: state.model,
    approvalPolicy: defaults.approvalPolicy,
    sandbox: defaults.sandbox,
  };
}

function isUseCommandText(text) {
  return typeof text === "string" && /^\/use(?:\s|$)/.test(text.trim());
}

function resolveProjectCwd(state, projectKey) {
  const currentProjectKey = typeof state.projectKey === "string" ? state.projectKey.trim() : "";
  const normalizedCwd = typeof state.cwd === "string" ? state.cwd.replace(/\/+$/, "") : "";
  const defaults = botDefaults();
  const defaultCwd = typeof defaults.cwd === "string" ? defaults.cwd.replace(/\/+$/, "") : "";
  if (currentProjectKey && normalizedCwd.endsWith(`/${currentProjectKey}`)) {
    return `${normalizedCwd.slice(0, -currentProjectKey.length)}${projectKey}`;
  }
  if (defaultCwd) {
    if (defaultCwd.endsWith(`/${projectKey}`)) {
      return defaultCwd;
    }
    return `${defaultCwd}/${projectKey}`;
  }
  return normalizedCwd ? `${normalizedCwd}/${projectKey}` : projectKey;
}

function normalizeImportPath(rawPath) {
  return path.resolve(rawPath);
}

async function pathExistsAsDirectory(targetPath) {
  try {
    const info = await stat(targetPath);
    return !!info && typeof info.isDirectory === "function" && info.isDirectory();
  } catch (_) {
    return false;
  }
}

const CODEX_QUERY_METHODS = new Set([
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

function buildTurnStartParams(stream, state, defaults) {
  return {
    threadId: state.threadId || stream.threadId || "",
    input: [
      {
        type: "text",
        text: stream.prompt,
      },
    ],
    effort: defaults.effort,
    model: state.model,
    approvalPolicy: defaults.approvalPolicy,
    sandboxPolicy: {
      type: sandboxPolicyType(defaults.sandbox),
      writableRoots: state.cwd ? [state.cwd] : [],
      networkAccess: true,
    },
    cwd: state.cwd,
  };
}

function readFinalAnswerFromSessionPath(runtime, sessionPath) {
  if (typeof sessionPath !== "string" || sessionPath.trim() === "") {
    return "";
  }
  if (!runtime || typeof runtime.readTextFile !== "function") {
    return "";
  }
  try {
    const raw = runtime.readTextFile(sessionPath, "");
    if (typeof raw !== "string" || raw.trim() === "") {
      return "";
    }
    const lines = raw.split(/\r?\n/).filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      let row;
      try {
        row = JSON.parse(lines[i]);
      } catch (_) {
        continue;
      }
      const payload = row && typeof row === "object" ? row.payload : undefined;
      if (!payload || typeof payload !== "object") {
        continue;
      }
      if (row.type === "event_msg" && payload.type === "agent_message" && typeof payload.message === "string" && payload.message.trim() !== "") {
        return payload.message.trim();
      }
      if (row.type === "response_item" && payload.type === "message" && payload.role === "assistant" && Array.isArray(payload.content)) {
        for (const part of payload.content) {
          if (part && typeof part.text === "string" && part.text.trim() !== "") {
            return part.text.trim();
          }
        }
      }
    }
  } catch (_) {
    return "";
  }
  return "";
}

function resolveSessionPath(runtime, stream, latest) {
  const explicitPath = latest?.threadPath || stream.threadPath || "";
  if (explicitPath) {
    return explicitPath;
  }
  const threadId = latest?.threadId || stream.threadId || "";
  if (!threadId || !runtime || typeof runtime.findCodexSessionPath !== "function") {
    return "";
  }
  try {
    return runtime.findCodexSessionPath(threadId, "");
  } catch (_) {
    return "";
  }
}

async function persistNotificationContext(streamId, notification, stream) {
  const patch = {};
  if (notification.turnId && notification.turnId !== stream.turnId) {
    patch.turnId = notification.turnId;
  }
  if (notification.threadId && notification.threadId !== stream.threadId) {
    patch.threadId = notification.threadId;
  }
  if (notification.threadPath && notification.threadPath !== stream.threadPath) {
    patch.threadPath = notification.threadPath;
  }
  if (notification.method) {
    patch.lastEvent = notification.method;
  }
  return Object.keys(patch).length > 0 ? updateStreamState(streamId, patch) : stream;
}

function feishuReplyText(session, text, streamId = "") {
  return feishuText(session.replyTarget || session.chatId, text, streamId, session.replyTargetType || "chat_id");
}

function handleHelp(session) {
  return {
    handled: true,
    commands: [feishuReplyText(session, helpText())],
  };
}

async function handleSettingsCommand(session, text) {
  if (text === "/settings") {
    const settings = await listSettings();
    return {
      handled: true,
      commands: [feishuReplyText(session, settings.length ? settingsListText(settings) : settingsEmptyText())],
    };
  }
  const match = text.match(/^\/setting\s+(\S+)\s+(.+)$/);
  if (!match) {
    return {
      handled: false,
      commands: [],
    };
  }
  const name = match[1].trim();
  const value = match[2].trim();
  await upsertSetting(name, value);
  return {
    handled: true,
    commands: [feishuReplyText(session, settingUpdatedText(name, value))],
  };
}

async function handleProjectCommand(session, text) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length === 1) {
    return {
      handled: true,
      commands: [feishuReplyText(session, currentProjectText(state))],
    };
  }
  const projectKey = parts.slice(1).join(" ").trim();
  const boundProjects = await listBoundChatProjects(session.chatId, 64);
  const bound = boundProjects.find((item) => item.projectKey === projectKey);
  if (!bound) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectNotBoundText(projectKey))],
    };
  }
  const next = await updateChatState(session.sessionKey, session.chatId, {
    projectKey,
    cwd: bound.repoPath || resolveProjectCwd(state, projectKey),
    threadId: "",
    threadPath: "",
  });
  return {
    handled: true,
    commands: [feishuReplyText(session, projectSelectedText(next))],
  };
}

async function handleCreateCommand(session, text) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length !== 2) {
    return {
      handled: true,
      commands: [feishuReplyText(session, usageText("/create", "[project_key]"))],
    };
  }
  const projectKey = parts[1].trim();
  const projectRoot = (await getSettingValue("project_root_dir")).trim();
  if (projectRoot === "") {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectRootMissingText())],
    };
  }
  const existingProject = await getProjectRecord(projectKey);
  if (existingProject) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectExistsText(projectKey, existingProject.repoPath || ""))],
    };
  }
  const repoPath = path.join(path.resolve(projectRoot), projectKey);
  if (await pathExistsAsDirectory(repoPath)) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectDirectoryExistsText(projectKey, repoPath))],
    };
  }
  await mkdir(repoPath, { recursive: true });
  const next = await updateChatState(session.sessionKey, session.chatId, {
    projectKey,
    cwd: repoPath,
    threadId: "",
    threadPath: "",
  });
  return {
    handled: true,
    commands: [feishuReplyText(session, projectCreatedText({ projectKey, repoPath }, next))],
  };
}

async function resolveBindProjectPath(projectKey, rawPath) {
  const explicitPath = typeof rawPath === "string" ? rawPath.trim() : "";
  if (explicitPath) {
    return normalizeImportPath(explicitPath);
  }
  const projectRoot = (await getSettingValue("project_root_dir")).trim();
  if (projectRoot === "") {
    return "";
  }
  return path.join(path.resolve(projectRoot), projectKey);
}

async function handleImportCommand(session) {
  return {
    handled: true,
    commands: [feishuReplyText(session, bindMergedText())],
  };
}

async function handleBindCommand(session, text) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const match = text.match(/^\/bind\s+(\S+)(?:\s+(.+))?$/);
  if (!match) {
    return {
      handled: true,
      commands: [feishuReplyText(session, usageText("/bind", "[project_key] [path]"))],
    };
  }
  const projectKey = match[1].trim();
  const repoPath = await resolveBindProjectPath(projectKey, match[2] || "");
  if (!repoPath) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectRootMissingText())],
    };
  }
  if (!(await pathExistsAsDirectory(repoPath))) {
    return {
      handled: true,
      commands: [feishuReplyText(session, importPathInvalidText(repoPath))],
    };
  }
  const project = await getProjectRecord(projectKey);
  if (!project) {
    await ensureProjectRecord(projectKey, repoPath, { defaultModel: state.model });
    await bindProjectToChat(session.chatId, projectKey, false);
    return {
      handled: true,
      commands: [feishuReplyText(session, projectRegisteredText({ projectKey, repoPath }, state))],
    };
  }
  const existingPath = typeof project.repoPath === "string" ? project.repoPath.trim() : "";
  if (existingPath) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectPathAlreadyBoundText(projectKey, existingPath))],
    };
  }
  await updateProjectRecordPath(projectKey, repoPath);
  await bindProjectToChat(session.chatId, projectKey, false);
  return {
    handled: true,
    commands: [feishuReplyText(session, projectPathFilledText({ projectKey, repoPath }, state))],
  };
}

async function handleUnbindCommand(session, text) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length !== 2) {
    return {
      handled: true,
      commands: [feishuReplyText(session, usageText("/unbind", "[project_key]"))],
    };
  }
  const projectKey = parts[1].trim();
  const boundProjects = await listBoundChatProjects(session.chatId, 128);
  const bound = boundProjects.find((item) => item.projectKey === projectKey);
  if (!bound) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectNotBoundText(projectKey))],
    };
  }
  if (state.projectKey === projectKey) {
    return {
      handled: true,
      commands: [feishuReplyText(session, projectUnbindCurrentBlockedText(projectKey))],
    };
  }
  await unbindProjectFromChat(session.chatId, projectKey);
  return {
    handled: true,
    commands: [feishuReplyText(session, projectUnboundText(projectKey))],
  };
}

async function handleCodexCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parsed = parseCodexCommand(session.text || "");
  if (!parsed.method) {
    return {
      handled: true,
      commands: [feishuReplyText(session, codexCommandHelpText(state))],
    };
  }
  if (parsed.error) {
    return {
      handled: true,
      commands: [feishuReplyText(session, `${parsed.error}\n\n${codexCommandHelpText(state)}`)],
    };
  }
  const normalized = normalizeCodexAlias(parsed.method, parsed.params, state);
  if (!CODEX_QUERY_METHODS.has(normalized.method)) {
    return {
      handled: true,
      commands: [feishuReplyText(session, unsupportedCodexMethodText(parsed.method))],
    };
  }
  const baseParams = defaultCodexParams(normalized.method, state);
  const params = normalized.params ? { ...(baseParams || {}), ...normalized.params } : (baseParams || {});
  if (normalized.method === "thread/read" && !params.threadId) {
    return {
      handled: true,
      commands: [feishuReplyText(session, codexThreadRequiredText())],
    };
  }
  const stream = await createStreamState(session.sessionKey, session.chatId, session.text || `/codex ${parsed.method}`);
  await updateStreamState(stream.streamId, {
    status: "rpc_query",
    lastEvent: `codex.rpc.query.${normalized.method}`,
  });
  return {
    handled: true,
    commands: [
      feishuReplyText(session, codexRpcQueuedText(normalized.method), stream.streamId),
      codexRpcCall(normalized.method, params, stream.streamId),
    ],
  };
}

async function handleModelCommand(session, text) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length === 1) {
    return {
      handled: true,
      commands: [feishuReplyText(session, currentModelText(state))],
    };
  }
  const model = parts.slice(1).join(" ").trim();
  const next = await updateChatState(session.sessionKey, session.chatId, {
    model,
    threadId: "",
    threadPath: "",
  });
  return {
    handled: true,
    commands: [feishuReplyText(session, modelSelectedText(next))],
  };
}

async function handleProjectsCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  await rememberSelectionScope(session.sessionKey, session.chatId, "project");
  const projects = (await listBoundChatProjects(session.chatId, 8)).map((project) => ({
    projectKey: project.projectKey,
    model: project.defaultModel || (project.projectKey === state.projectKey ? state.model : ""),
    cwd: project.repoPath || "",
    threadId: project.projectKey === state.projectKey ? (state.threadId || "") : "",
  }));
  return {
    handled: true,
    commands: [feishuReplyText(session, projectsListText(state, projects))],
  };
}

async function handleModelsCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  await rememberSelectionScope(session.sessionKey, session.chatId, "model");
  return {
    handled: true,
    commands: [feishuReplyText(session, modelsListText(state, botDefaults().supportedModels || []))],
  };
}

async function handleThreadCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parts = (session.text || "").split(/\s+/).filter(Boolean);
  if (parts.length > 1) {
    const threadId = parts.slice(1).join(" ").trim();
    const recentThreads = await listRecentProjectThreads(state.projectKey, 32);
    const selected = recentThreads.find((stream) => stream.threadId === threadId);
    const next = await updateChatState(session.sessionKey, session.chatId, {
      threadId,
      threadPath: selected?.threadPath || "",
    });
    return {
      handled: true,
      commands: [feishuReplyText(session, threadSelectedText(next, threadId, selected))],
    };
  }
  const lastStream = state.lastStreamId ? await getStreamState(state.lastStreamId) : undefined;
  return {
    handled: true,
    commands: [feishuReplyText(session, currentThreadSummaryText(state, lastStream))],
  };
}

async function handleThreadsCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  await rememberSelectionScope(session.sessionKey, session.chatId, "thread");
  const threads = await listRecentProjectThreads(state.projectKey, 8);
  return {
    handled: true,
    commands: [feishuReplyText(session, threadsListText(state, threads))],
  };
}

async function handleUseCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const scope = await getSelectionScope(session.sessionKey);
  const parts = (session.text || "").split(/\s+/).filter(Boolean);
  if (parts.length === 1) {
    return {
      handled: true,
      commands: [feishuReplyText(session, usageText("/use", useCommandSyntax(scope)))],
    };
  }
  const value = parts.slice(1).join(" ").trim();
  if (scope === "project") {
    const project = (await listBoundChatProjects(session.chatId, 64)).find((item) => item.projectKey === value);
    if (!project) {
      return {
        handled: true,
        commands: [feishuReplyText(session, projectNotBoundText(value))],
      };
    }
    const next = await updateChatState(session.sessionKey, session.chatId, {
      projectKey: value,
      cwd: project.repoPath || resolveProjectCwd(state, value),
      threadId: "",
      threadPath: "",
    });
    return {
      handled: true,
      commands: [feishuReplyText(session, projectSelectedText(next))],
    };
  }
  if (scope === "model") {
    const next = await updateChatState(session.sessionKey, session.chatId, {
      model: value,
      threadId: "",
      threadPath: "",
    });
    return {
      handled: true,
      commands: [feishuReplyText(session, modelSelectedText(next))],
    };
  }
  if (value === "latest") {
    const latest = await getLatestProjectThread(state.projectKey);
    if (!latest?.threadId) {
      return {
        handled: true,
        commands: [feishuReplyText(session, latestThreadMissingText(state))],
      };
    }
    const next = await updateChatState(session.sessionKey, session.chatId, {
      threadId: latest.threadId,
      threadPath: latest.threadPath || "",
    });
    const stream = await createStreamState(session.sessionKey, session.chatId, session.text || "/use latest");
    await updateStreamState(stream.streamId, {
      threadId: latest.threadId,
      threadPath: latest.threadPath || "",
      status: "rpc_query",
      lastEvent: "thread/read.requested",
    });
    return {
      handled: true,
      commands: [
        feishuReplyText(session, `${threadSelectedText(next, latest.threadId, latest)}\n- ${threadReadQueuedText()}`, stream.streamId),
        codexRpcCall("thread/read", { threadId: latest.threadId, includeTurns: true }, stream.streamId),
      ],
    };
  }
  const recentThreads = await listRecentProjectThreads(state.projectKey, 32);
  const selected = recentThreads.find((stream) => stream.threadId === value);
  const next = await updateChatState(session.sessionKey, session.chatId, {
    threadId: value,
    threadPath: selected?.threadPath || "",
  });
  const stream = await createStreamState(session.sessionKey, session.chatId, session.text || `/use ${value}`);
  await updateStreamState(stream.streamId, {
    threadId: value,
    threadPath: selected?.threadPath || "",
    status: "rpc_query",
    lastEvent: "thread/read.requested",
  });
  return {
    handled: true,
    commands: [
      feishuReplyText(session, `${threadSelectedText(next, value, selected)}\n- ${threadReadQueuedText()}`, stream.streamId),
      codexRpcCall("thread/read", { threadId: value, includeTurns: true }, stream.streamId),
    ],
  };
}

async function handleNewCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const parts = (session.text || "").split(/\s+/).filter(Boolean);
  const nextModel = parts.length > 1 ? parts.slice(1).join(" ").trim() : "";
  const next = await updateChatState(session.sessionKey, session.chatId, {
    model: nextModel || state.model,
    threadId: "",
    threadPath: "",
  });
  return {
    handled: true,
    commands: [feishuReplyText(session, newConversationText(next, state.threadId || "", state.model || ""))],
  };
}

async function handleCancelCommand(session) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const lastStream = state.lastStreamId ? await getStreamState(state.lastStreamId) : undefined;
  if (!lastStream || !isActiveStream(lastStream)) {
    return {
      handled: true,
      commands: [feishuReplyText(session, cancelIdleText(session.sessionKey))],
    };
  }
  if (lastStream.threadId && lastStream.turnId) {
    const interruptingText = cancelInterruptingText(lastStream);
    await finalizeStreamState(lastStream.streamId, {
      status: "cancelled",
      resultText: interruptingText,
      completedAt: Date.now(),
      lastEvent: "user.cancel.interrupt",
    });
    await resetChatThread(session.sessionKey, session.chatId);
    return {
      handled: true,
      commands: [
        feishuUpdateText(lastStream.streamId, interruptingText),
        codexTurnInterrupt(lastStream.threadId, lastStream.turnId, lastStream.streamId),
        feishuSessionClear(lastStream.streamId),
        codexSessionClear(lastStream.streamId, lastStream.threadId),
      ],
    };
  }
  const detachedText = cancelDetachedText(lastStream);
  await finalizeStreamState(lastStream.streamId, {
    status: "cancelled",
    resultText: detachedText,
    completedAt: Date.now(),
    lastEvent: "user.cancel",
  });
  await resetChatThread(session.sessionKey, session.chatId);
  return {
    handled: true,
    commands: [
      feishuUpdateText(lastStream.streamId, detachedText),
      feishuSessionClear(lastStream.streamId),
      codexSessionClear(lastStream.streamId, state.threadId || lastStream.threadId || ""),
    ],
  };
}

async function handleRegularTask(session, prompt) {
  const state = await ensureChatState(session.sessionKey, session.chatId);
  const lastStream = state.lastStreamId ? await getStreamState(state.lastStreamId) : undefined;
  if (lastStream && isActiveStream(lastStream)) {
    return {
      handled: true,
      commands: [feishuReplyText(session, busyText(lastStream))],
    };
  }
  const stream = await createStreamState(session.sessionKey, session.chatId, prompt);
  const defaults = botDefaults();
  const commands = [feishuReplyText(session, taskQueuedText(stream), stream.streamId)];
  if (state.threadId) {
    commands.push(codexTurnStart(buildTurnStartParams(stream, state, defaults), stream.streamId));
  } else {
    commands.push(codexRpcCall("thread/start", buildThreadStartParams(state, defaults), stream.streamId));
  }
  return {
    handled: true,
    commands,
  };
}

async function routeFeishuCommand(frame) {
  const inbound = parseFeishuInboundFrame(frame);
  if (inbound.chatId === "" || inbound.text === "") {
    return {
      handled: false,
      commands: [],
    };
  }
  const text = inbound.text;
  const session = {
    chatId: inbound.chatId,
    sessionKey: inbound.sessionKey || inbound.chatId,
    replyTarget: inbound.replyTarget || inbound.chatId,
    replyTargetType: inbound.replyTargetType || "chat_id",
    text,
  };
  if (!isUseCommandText(text)) {
    await clearSelectionScope(session.sessionKey);
  }
  if (text === "/help" || text === "help" || text === "帮助") {
    return handleHelp(session);
  }
  if (text === "/codex" || text.startsWith("/codex ")) {
    return handleCodexCommand(session);
  }
  if (text === "/settings" || text === "/setting" || text.startsWith("/setting ")) {
    return handleSettingsCommand(session, text);
  }
  if (text === "/create" || text.startsWith("/create ")) {
    return handleCreateCommand(session, text);
  }
  if (text === "/import" || text.startsWith("/import ")) {
    return handleImportCommand(session);
  }
  if (text === "/bind" || text.startsWith("/bind ")) {
    return handleBindCommand(session, text);
  }
  if (text === "/unbind" || text.startsWith("/unbind ")) {
    return handleUnbindCommand(session, text);
  }
  if (text === "/projects") {
    return handleProjectsCommand(session);
  }
  if (text === "/models") {
    return handleModelsCommand(session);
  }
  if (text === "/threads") {
    return handleThreadsCommand(session);
  }
  if (text === "/use latest" || text.startsWith("/use ")) {
    return handleUseCommand(session);
  }
  if (text === "/thread" || text.startsWith("/thread ")) {
    return handleThreadCommand(session);
  }
  if (text === "/new" || text.startsWith("/new ")) {
    return handleNewCommand(session);
  }
  if (text === "/cancel") {
    return handleCancelCommand(session);
  }
  if (text === "/project" || text.startsWith("/project ")) {
    return handleProjectCommand(session, text);
  }
  if (text === "/model" || text.startsWith("/model ")) {
    return handleModelCommand(session, text);
  }
  return handleRegularTask(session, text);
}

async function handleCodexRpcResponse(frame) {
  const response = parseCodexRpcResponse(frame);
  const stream = await getStreamState(response.streamId);
  if (!stream) {
    return {
      handled: false,
      commands: [],
    };
  }
  if (response.method === "thread/start" && !response.hasError && response.threadId) {
    await bindThreadToStream(response.streamId, response.threadId, response.threadPath || "");
    await finalizeStreamState(response.streamId, {
      status: "thread_ready",
      threadPath: response.threadPath || "",
      lastEvent: "thread/start",
    });
    const chat = await ensureChatState(stream.sessionKey, stream.chatId);
    const defaults = botDefaults();
    return {
      handled: true,
      commands: [
        feishuUpdateText(response.streamId, threadBoundText(response.threadId)),
        codexTurnStart(
          buildTurnStartParams(
            {
              ...stream,
              threadId: response.threadId,
            },
            {
              ...chat,
              threadId: response.threadId,
            },
            defaults,
          ),
          response.streamId,
        ),
      ],
    };
  }
  if (response.method === "thread/read" && !stream.prompt.startsWith("/codex")) {
    if (response.hasError) {
      const errorText = codexRpcErrorText(response.method, response.errorMessage || truncateText(prettyJson(response.raw)));
      await finalizeStreamState(response.streamId, {
        status: "error",
        resultText: errorText,
        completedAt: Date.now(),
        lastEvent: response.method || "thread/read",
      });
      return {
        handled: true,
        commands: [feishuUpdateText(response.streamId, errorText)],
      };
    }
    const readAnswer = extractAnswerFromThreadReadResult(response.result);
    const resultText = readAnswer || threadReadEmptyText(response.threadId || stream.threadId || "");
    await finalizeStreamState(response.streamId, {
      threadPath: response.threadPath || stream.threadPath || "",
      status: "completed",
      resultText,
      completedAt: Date.now(),
      lastEvent: "thread/read",
    });
    const renderedReadAnswer = readAnswer ? renderCodexAssistantText(readAnswer) : resultText;
    return {
      handled: true,
      commands: renderedReadAnswer ? [feishuUpdateText(response.streamId, renderedReadAnswer)] : [],
    };
  }
  if (stream.prompt && stream.prompt.startsWith("/codex")) {
    if (response.hasError) {
      const errorText = codexRpcErrorText(response.method, response.errorMessage || truncateText(prettyJson(response.raw)));
      await finalizeStreamState(response.streamId, {
        status: "error",
        resultText: errorText,
        completedAt: Date.now(),
        lastEvent: response.method || "codex.rpc.response",
      });
      return {
        handled: true,
        commands: [feishuUpdateText(response.streamId, errorText)],
      };
    }
    const resultText = formatCodexRpcResult(response.method, response.result, response.raw.result ?? response.raw);
    await finalizeStreamState(response.streamId, {
      status: "completed",
      resultText,
      completedAt: Date.now(),
      lastEvent: response.method || "codex.rpc.response",
    });
    return {
      handled: true,
      commands: [feishuUpdateText(response.streamId, resultText)],
    };
  }
  if (response.method === "turn/start" && !response.hasError) {
    await finalizeStreamState(response.streamId, {
      turnId: response.turnId || stream.turnId || "",
      status: "running",
      lastEvent: "turn/start",
    });
    return {
      handled: true,
      commands: [feishuUpdateText(response.streamId, taskRunningText(stream))],
    };
  }
  if (response.hasError) {
    await finalizeStreamState(response.streamId, {
      status: "error",
      resultText: codexErrorText(response.method),
      lastEvent: response.method || "codex.rpc.response",
      completedAt: Date.now(),
    });
    return {
      handled: true,
      commands: [feishuUpdateText(response.streamId, codexErrorText(response.method))],
    };
  }
  return {
    handled: true,
    commands: [],
  };
}

async function handleCodexNotification(frame) {
  const notification = parseCodexNotification(frame);
  frame.runtime.log("codexbot-app-ts notification", CODEXBOT_TS_BUILD, notification.method, notification.status || "", notification.threadId || "", notification.streamId || "");
  let stream = await getStreamState(notification.streamId);
  if (!stream) {
    frame.runtime.warn("codexbot-app-ts notification missing stream", CODEXBOT_TS_BUILD, notification.streamId || "");
    return {
      handled: false,
      commands: [],
    };
  }
  if (notification.threadId) {
    const nextThreadPath = notification.threadPath || stream.threadPath || "";
    if (notification.threadId !== stream.threadId || nextThreadPath !== (stream.threadPath || "")) {
      await bindThreadToStream(notification.streamId, notification.threadId, nextThreadPath);
      stream = (await getStreamState(notification.streamId)) || stream;
    }
  }
  stream = (await persistNotificationContext(notification.streamId, notification, stream)) || stream;
  if (notification.method === "thread/status/changed" && isTerminalIdleStatus(notification.status || "")) {
    const latest = await getStreamState(notification.streamId);
    const resolvedSessionPath = resolveSessionPath(frame.runtime, stream, latest);
    const sessionAnswer = readFinalAnswerFromSessionPath(frame.runtime, resolvedSessionPath);
    const settledText = latest?.resultText || latest?.draft || stream.resultText || stream.draft || "";
    const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
    frame.runtime.log(
      "codexbot-app-ts idle check",
      CODEXBOT_TS_BUILD,
      "stream=" + (notification.streamId || ""),
      "latestStatus=" + (latest?.status || ""),
      "latestDraftLen=" + String((latest?.draft || "").length),
      "latestResultLen=" + String((latest?.resultText || "").length),
      "sessionAnswerLen=" + String(sessionAnswer.length),
      "lookupThreadId=" + lookupThreadId,
      "resolvedSessionPath=" + resolvedSessionPath,
    );
    if (!settledText && lookupThreadId) {
      frame.runtime.log("codexbot-app-ts idle -> thread/read", CODEXBOT_TS_BUILD, lookupThreadId, notification.streamId || "");
      await updateStreamState(notification.streamId, {
        turnId: notification.turnId || latest?.turnId || stream.turnId || "",
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "reading_final",
        lastEvent: notification.method,
      });
      return {
        handled: true,
        commands: [
          feishuUpdateText(notification.streamId, codexFinalizingText()),
          codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId),
        ],
      };
    }
    frame.runtime.log("codexbot-app-ts idle -> no-op", CODEXBOT_TS_BUILD, "settledTextLen=" + String(settledText.length), "lookupThreadId=" + lookupThreadId);
  }
  if (notification.method === "thread/started" && notification.threadId) {
    await finalizeStreamState(notification.streamId, {
      status: "thread_ready",
      threadPath: notification.threadPath || stream.threadPath || "",
      lastEvent: "thread/started",
    });
    return {
      handled: true,
      commands: [feishuUpdateText(notification.streamId, threadBoundText(notification.threadId))],
    };
  }
  if (notification.method === "turn/started") {
    await finalizeStreamState(notification.streamId, {
      turnId: notification.turnId || stream.turnId || "",
      status: "running",
      lastEvent: "turn/started",
    });
    return {
      handled: true,
      commands: [],
    };
  }
  if (notification.delta) {
    const next = await appendStreamDraft(notification.streamId, notification.delta, {
      turnId: notification.turnId || stream.turnId || "",
      lastEvent: notification.method || "item/agentMessage/delta",
    });
    const renderedDraft = renderCodexAssistantText(next ? next.draft : notification.delta);
    return {
      handled: true,
      commands: renderedDraft ? [feishuUpdateText(notification.streamId, renderedDraft)] : [],
    };
  }
  if (notification.finalText) {
    await finalizeStreamState(notification.streamId, {
      turnId: notification.turnId || stream.turnId || "",
      threadPath: notification.threadPath || stream.threadPath || "",
      status: "completed",
      resultText: notification.finalText,
      completedAt: Date.now(),
      lastEvent: notification.method || "codex.notification",
    });
    const renderedFinal = renderCodexAssistantText(notification.finalText);
    return {
      handled: true,
      commands: renderedFinal ? [feishuUpdateText(notification.streamId, renderedFinal)] : [],
    };
  }
  if (notification.errorMessage && (notification.status === "error" || notification.method === "error")) {
    const errorText = `Codex error: ${notification.errorMessage}`;
    await finalizeStreamState(notification.streamId, {
      turnId: notification.turnId || stream.turnId || "",
      status: "error",
      resultText: errorText,
      completedAt: Date.now(),
      lastEvent: notification.method || "codex.notification",
    });
    return {
      handled: true,
      commands: [feishuUpdateText(notification.streamId, errorText)],
    };
  }
  if (notification.message) {
    const latest = await getStreamState(notification.streamId);
    if ((latest?.status === "completed" || latest?.resultText) && notification.phase === "commentary") {
      return {
        handled: true,
        commands: [],
      };
    }
    await updateStreamState(notification.streamId, {
      turnId: notification.turnId || latest?.turnId || stream.turnId || "",
      status: "streaming",
      lastEvent: notification.method || "codex.notification",
    });
    const renderedMessage = renderCodexAssistantText(notification.message);
    return {
      handled: true,
      commands: renderedMessage ? [feishuUpdateText(notification.streamId, renderedMessage)] : [],
    };
  }
  if (notification.method === "turn/completed") {
    const latest = await getStreamState(notification.streamId);
    const resolvedSessionPath = resolveSessionPath(frame.runtime, stream, latest);
    const completedText = latest?.resultText || latest?.draft || notification.message || "";
    const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
    if (!completedText && lookupThreadId) {
      await updateStreamState(notification.streamId, {
        turnId: notification.turnId || latest?.turnId || stream.turnId || "",
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "reading_final",
        lastEvent: "turn/completed",
      });
      return {
        handled: true,
        commands: [
          feishuUpdateText(notification.streamId, codexFinalizingText()),
          codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId),
        ],
      };
    }
    const finalCompletedText = completedText || "Completed.";
    await finalizeStreamState(notification.streamId, {
      turnId: notification.turnId || latest?.turnId || stream.turnId || "",
      threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
      status: "completed",
      resultText: finalCompletedText,
      completedAt: Date.now(),
      lastEvent: "turn/completed",
    });
    const renderedCompleted = renderCodexAssistantText(finalCompletedText);
    return {
      handled: true,
      commands: latest?.resultText === finalCompletedText || !renderedCompleted ? [] : [feishuUpdateText(notification.streamId, renderedCompleted)],
    };
  }
  if (notification.status) {
    const latest = await getStreamState(notification.streamId);
    const resolvedSessionPath = resolveSessionPath(frame.runtime, stream, latest);
    if (resolvedSessionPath && !latest?.threadPath && (latest?.threadId || stream.threadId)) {
      await bindThreadToStream(notification.streamId, latest?.threadId || stream.threadId, resolvedSessionPath);
    }
    const settledText = latest?.resultText || latest?.draft || stream.resultText || stream.draft || notification.message || "";
    if (isTerminalIdleStatus(notification.status) && settledText) {
      await finalizeStreamState(notification.streamId, {
        turnId: notification.turnId || latest?.turnId || stream.turnId || "",
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "completed",
        resultText: settledText,
        completedAt: Date.now(),
        lastEvent: notification.method || "codex.notification",
      });
      const renderedSettled = renderCodexAssistantText(settledText);
      return {
        handled: true,
        commands: latest?.resultText === settledText || !renderedSettled ? [] : [feishuUpdateText(notification.streamId, renderedSettled)],
      };
    }
    if (isTerminalIdleStatus(notification.status) && !settledText) {
      const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
      if (lookupThreadId) {
        await updateStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: "reading_final",
          lastEvent: notification.method || "codex.notification",
        });
        return {
          handled: true,
          commands: [
            feishuUpdateText(notification.streamId, codexFinalizingText()),
            codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId),
          ],
        };
      }
    }
    await finalizeStreamState(notification.streamId, {
      turnId: notification.turnId || latest?.turnId || stream.turnId || "",
      threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
      status: notification.status,
      resultText: latest?.resultText || stream.resultText || "",
      lastEvent: notification.method || "codex.notification",
      completedAt: notification.status === "completed" ? Date.now() : 0,
    });
    return {
      handled: true,
      commands: settledText && !notification.message
        ? []
        : [feishuUpdateText(notification.streamId, codexStatusText(notification.status, notification.message || ""))],
    };
  }
  return {
    handled: true,
    commands: [],
  };
}

export function createBotApp() {
  return {
    async http(ctx) {
      if (ctx.path === "/health") {
        return ctx.text("OK", 200);
      }
      if (ctx.path === "/admin/state") {
        return ctx.json(
          {
            ok: true,
            app: "codexbot-app-ts",
            dispatchKind: ctx.runtime.dispatchKind,
            snapshot: await runtimeSnapshot(),
          },
          200,
        );
      }
      return ctx.json(
        {
          ok: true,
          app: "codexbot-app-ts",
          dispatchKind: ctx.runtime.dispatchKind,
          path: ctx.path,
        },
        200,
      );
    },

    async websocket_upstream(frame) {
      frame.runtime.log("codexbot-app-ts upstream", CODEXBOT_TS_BUILD, frame.provider, frame.eventType, frame.target);
      if (frame.provider === "feishu" && frame.eventType === "im.message.receive_v1") {
        return routeFeishuCommand(frame);
      }
      if (frame.provider === "codex" && frame.eventType === "codex.rpc.response") {
        return handleCodexRpcResponse(frame);
      }
      if (frame.provider === "codex" && frame.eventType === "codex.notification") {
        return handleCodexNotification(frame);
      }
      return {
        handled: false,
        commands: [],
      };
    },
  };
}
