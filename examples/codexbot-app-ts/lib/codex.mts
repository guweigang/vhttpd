import type { ContentItem } from "../codex/ts/ContentItem";
import type { ResponseItem } from "../codex/ts/ResponseItem";
import type { MessagePhase } from "../codex/ts/MessagePhase";
import type { Thread } from "../codex/ts/v2/Thread";
import type { ThreadItem } from "../codex/ts/v2/ThreadItem";
import type { ThreadReadResponse } from "../codex/ts/v2/ThreadReadResponse";
import type { Turn } from "../codex/ts/v2/Turn";
import {
  normalizeCodexMessagePhase,
  normalizeCodexThreadStatus,
  normalizeCodexTurnStatus,
} from "../codex/protocol.mts";

function decodeThreadId(result) {
  if (!result || typeof result !== "object") {
    return "";
  }
  if (typeof result.threadId === "string") {
    return result.threadId;
  }
  if (typeof result.thread_id === "string") {
    return result.thread_id;
  }
  if (result.thread && typeof result.thread.id === "string") {
    return result.thread.id;
  }
  return "";
}

function decodeTurnId(result) {
  if (!result || typeof result !== "object") {
    return "";
  }
  if (typeof result.turnId === "string") {
    return result.turnId;
  }
  if (typeof result.turn_id === "string") {
    return result.turn_id;
  }
  if (result.turn && typeof result.turn.id === "string") {
    return result.turn.id;
  }
  return "";
}

function decodeThreadPath(result) {
  if (!result || typeof result !== "object") {
    return "";
  }
  if (typeof result.threadPath === "string") {
    return result.threadPath;
  }
  if (typeof result.thread_path === "string") {
    return result.thread_path;
  }
  if (result.thread && typeof result.thread.path === "string") {
    return result.thread.path;
  }
  return "";
}

function pickFirstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value;
    }
  }
  return "";
}

function safeJsonParse(text) {
  if (typeof text !== "string" || text.trim() === "") {
    return undefined;
  }
  try {
    return JSON.parse(text);
  } catch (_) {
    return undefined;
  }
}

function extractTextCandidate(value) {
  if (typeof value === "string" && value.trim() !== "") {
    return value.trim();
  }
  if (!value || typeof value !== "object") {
    return "";
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const text = extractTextCandidate(item);
      if (text) {
        return text;
      }
    }
    return "";
  }
  return pickFirstString(
    typeof value.text === "string" ? value.text : "",
    typeof value.message === "string" ? value.message : "",
    extractTextCandidate(value.content),
    extractTextCandidate(value.item),
    extractTextCandidate(value.parts),
  );
}

function extractOutputTextContent(content: Array<ContentItem> | undefined | null) {
  if (!Array.isArray(content)) {
    return "";
  }
  const parts = [];
  for (const part of content) {
    if (!part || typeof part !== "object") {
      continue;
    }
    if (typeof part.text === "string" && part.text.trim() !== "" && (
      part.type === "output_text"
      || part.type === "text"
    )) {
      parts.push(part.text.trim());
    }
  }
  return parts.join("\n").trim();
}

function extractOutputTextOnlyContent(content: Array<ContentItem> | undefined | null) {
  if (!Array.isArray(content)) {
    return "";
  }
  const parts = [];
  for (const part of content) {
    if (!part || typeof part !== "object") {
      continue;
    }
    if (part.type === "output_text" && typeof part.text === "string" && part.text.trim() !== "") {
      parts.push(part.text.trim());
    }
  }
  return parts.join("\n").trim();
}

function isThreadTurn(value): value is Turn {
  return !!value && typeof value === "object" && typeof value.id === "string" && Array.isArray(value.items);
}

function isThreadItemAgentMessage(item: ThreadItem | ResponseItem | undefined | null): item is Extract<ThreadItem, { type: "agentMessage" }> {
  return !!item && typeof item === "object" && item.type === "agentMessage" && typeof item.text === "string";
}

function isResponseAssistantMessage(item: ThreadItem | ResponseItem | undefined | null): item is Extract<ResponseItem, { type: "message" }> {
  return !!item && typeof item === "object" && item.type === "message" && item.role === "assistant" && Array.isArray(item.content);
}

function assistantPhase(item: { phase?: MessagePhase | null } | undefined | null) {
  return normalizeCodexMessagePhase(item?.phase);
}

function isExplicitUserInputItem(item: ThreadItem | ResponseItem | Record<string, unknown> | undefined | null) {
  if (!item || typeof item !== "object") {
    return false;
  }
  const type = typeof item.type === "string" ? item.type.trim().toLowerCase() : "";
  const role = typeof item.role === "string" ? item.role.trim().toLowerCase() : "";
  return type === "usermessage" || role === "user";
}

function extractAssistantNotificationText(item: ThreadItem | ResponseItem | Record<string, unknown> | undefined | null) {
  if (!item || typeof item !== "object" || isExplicitUserInputItem(item)) {
    return "";
  }
  const contentText = extractOutputTextContent(item.content);
  const outputTextOnly = extractOutputTextOnlyContent(item.content);
  const phase = assistantPhase(item);
  if (isThreadItemAgentMessage(item)) {
    return item.text.trim();
  }
  if (isResponseAssistantMessage(item) && contentText) {
    return contentText;
  }
  if (phase === "commentary" || phase === "final_answer") {
    return pickFirstString(
      typeof item.text === "string" ? item.text : "",
      contentText,
      extractTextCandidate(item.content),
    );
  }
  return outputTextOnly;
}

export function extractAssistantTextFromThreadItem(item: ThreadItem | ResponseItem | undefined | null) {
  const assistantText = extractAssistantNotificationText(item);
  if (assistantText && assistantPhase(item) === "final_answer") {
    return assistantText;
  }
  if (assistantText && isThreadItemAgentMessage(item)) {
    return assistantText;
  }
  if (assistantText && isResponseAssistantMessage(item)) {
    return assistantText;
  }
  return "";
}

function joinAssistantTurnBlocks(blocks) {
  const seen = new Set();
  const ordered = [];
  for (const raw of Array.isArray(blocks) ? blocks : []) {
    const text = typeof raw === "string" ? raw.trim() : "";
    if (!text || seen.has(text)) {
      continue;
    }
    seen.add(text);
    ordered.push(text);
  }
  return ordered.join("\n\n").trim();
}

export function extractAssistantTextFromTurn(turn: Turn | undefined | null) {
  const items = isThreadTurn(turn) ? turn.items : [];
  const finalBlocks = [];
  const fallbackBlocks = [];
  for (const item of items) {
    const text = extractAssistantTextFromThreadItem(item);
    if (!text) {
      continue;
    }
    if (assistantPhase(item) === "final_answer") {
      finalBlocks.push(text);
    } else {
      fallbackBlocks.push(text);
    }
  }
  return joinAssistantTurnBlocks(finalBlocks.length ? finalBlocks : fallbackBlocks);
}

export function extractAssistantItemsFromTurn(turn: Turn | undefined | null) {
  const items = isThreadTurn(turn) ? turn.items : [];
  const extracted = [];
  for (const item of items) {
    const text = extractAssistantTextFromThreadItem(item);
    if (!text) {
      continue;
    }
    extracted.push({
      itemId: typeof item?.id === "string" ? item.id : "",
      phase: assistantPhase(item),
      text,
    });
  }
  return extracted;
}

export function threadTurnsFromReadResult(result: ThreadReadResponse | Thread | Record<string, unknown> | undefined | null): Turn[] {
  if (!result || typeof result !== "object") {
    return [];
  }
  if (Array.isArray((result as Thread).turns)) {
    return (result as Thread).turns.filter(isThreadTurn);
  }
  if (result.thread && typeof result.thread === "object" && Array.isArray((result.thread as Thread).turns)) {
    return (result.thread as Thread).turns.filter(isThreadTurn);
  }
  return [];
}

export function extractAssistantTextFromThreadReadResult(result: ThreadReadResponse | Thread | Record<string, unknown> | undefined | null, preferredTurnId = "") {
  const turns = threadTurnsFromReadResult(result);
  if (!turns.length) {
    return "";
  }
  const normalizedTurnId = typeof preferredTurnId === "string" ? preferredTurnId.trim() : "";
  if (normalizedTurnId) {
    const matchedTurn = turns.find((turn) => turn.id === normalizedTurnId);
    if (matchedTurn) {
      const matchedAnswer = extractAssistantTextFromTurn(matchedTurn);
      if (matchedAnswer) {
        return matchedAnswer;
      }
    }
  }
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const answer = extractAssistantTextFromTurn(turns[index]);
    if (answer) {
      return answer;
    }
  }
  return "";
}

export function extractAssistantItemsFromThreadReadResult(result: ThreadReadResponse | Thread | Record<string, unknown> | undefined | null, preferredTurnId = "") {
  const turns = threadTurnsFromReadResult(result);
  if (!turns.length) {
    return [];
  }
  const normalizedTurnId = typeof preferredTurnId === "string" ? preferredTurnId.trim() : "";
  if (normalizedTurnId) {
    const matchedTurn = turns.find((turn) => turn.id === normalizedTurnId);
    if (matchedTurn) {
      const matchedItems = extractAssistantItemsFromTurn(matchedTurn);
      if (matchedItems.length) {
        return matchedItems;
      }
    }
  }
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const items = extractAssistantItemsFromTurn(turns[index]);
    if (items.length) {
      return items;
    }
  }
  return [];
}

export function extractAssistantTextFromExactThreadTurn(result: ThreadReadResponse | Thread | Record<string, unknown> | undefined | null, preferredTurnId = "") {
  const turns = threadTurnsFromReadResult(result);
  if (!turns.length) {
    return "";
  }
  const normalizedTurnId = typeof preferredTurnId === "string" ? preferredTurnId.trim() : "";
  if (!normalizedTurnId) {
    return "";
  }
  const matchedTurn = turns.find((turn) => turn.id === normalizedTurnId);
  if (!matchedTurn) {
    return "";
  }
  return extractAssistantTextFromTurn(matchedTurn);
}

function decodeNotificationThreadId(payload, params) {
  return pickFirstString(
    params?.threadId,
    params?.thread_id,
    params?.thread?.id,
    payload?.threadId,
    payload?.thread_id,
    payload?.thread?.id,
  );
}

function decodeNotificationTurnId(payload, params) {
  return pickFirstString(
    params?.turnId,
    params?.turn_id,
    params?.turn?.id,
    payload?.turnId,
    payload?.turn_id,
    payload?.turn?.id,
  );
}

function decodeNotificationItemId(payload, params) {
  return pickFirstString(
    params?.itemId,
    params?.item_id,
    params?.item?.id,
    payload?.itemId,
    payload?.item_id,
    payload?.item?.id,
  );
}

function decodeNotificationThreadPath(payload, params) {
  return pickFirstString(
    params?.threadPath,
    params?.thread_path,
    params?.thread?.path,
    payload?.threadPath,
    payload?.thread_path,
    payload?.thread?.path,
  );
}

function decodeItemType(payload, params) {
  return pickFirstString(
    params?.item?.type,
    payload?.item?.type,
  );
}

function decodeItemRole(payload, params) {
  return pickFirstString(
    params?.item?.role,
    payload?.item?.role,
  );
}

function decodeNotificationPhase(payload, params) {
  return normalizeCodexMessagePhase(
    pickFirstString(
      params?.phase,
      params?.item?.phase,
      payload?.phase,
      payload?.item?.phase,
    ),
  );
}

function decodeThreadStatusType(payload, params) {
  const status = params?.status ?? payload?.status;
  if (typeof status === "string" && status.trim() !== "") {
    return normalizeCodexThreadStatus(status);
  }
  if (status && typeof status.type === "string" && status.type.trim() !== "") {
    return normalizeCodexThreadStatus(status.type);
  }
  return "";
}

function decodeThreadActiveFlags(payload, params) {
  const status = params?.status ?? payload?.status;
  const rawFlags = Array.isArray(status?.activeFlags)
    ? status.activeFlags
    : Array.isArray(status?.active_flags)
      ? status.active_flags
      : [];
  return rawFlags
    .filter((flag) => typeof flag === "string" && flag.trim() !== "")
    .map((flag) => flag.trim());
}

function decodeTurnStatus(payload, params) {
  return normalizeCodexTurnStatus(pickFirstString(
    params?.turn?.status,
    payload?.turn?.status,
  ));
}

function extractCodexErrorInfo(value) {
  if (!value) {
    return {
      code: "",
      httpStatusCode: undefined,
    };
  }
  if (typeof value === "string" && value.trim() !== "") {
    return {
      code: value.trim(),
      httpStatusCode: undefined,
    };
  }
  if (typeof value !== "object") {
    return {
      code: "",
      httpStatusCode: undefined,
    };
  }
  const entries = Object.entries(value);
  if (!entries.length) {
    return {
      code: "",
      httpStatusCode: undefined,
    };
  }
  const [code, detail] = entries[0];
  const httpStatusCode = Number(detail?.httpStatusCode);
  return {
    code,
    httpStatusCode: Number.isFinite(httpStatusCode) ? httpStatusCode : undefined,
  };
}

function decodeTurnError(payload, params) {
  const error = params?.error ?? params?.turn?.error ?? payload?.error ?? payload?.turn?.error;
  if (!error || typeof error !== "object") {
    return undefined;
  }
  const message = typeof error.message === "string" ? error.message.trim() : "";
  const additionalDetails = typeof error.additionalDetails === "string" ? error.additionalDetails.trim() : "";
  const codexErrorInfo = extractCodexErrorInfo(error.codexErrorInfo);
  if (!message && !additionalDetails && !codexErrorInfo.code) {
    return undefined;
  }
  return {
    message,
    additionalDetails,
    codexErrorCode: codexErrorInfo.code,
    codexErrorHttpStatus: codexErrorInfo.httpStatusCode,
  };
}

function decodeFinalText(payload, params) {
  const turnText = extractAssistantTextFromTurn(params?.turn || payload?.turn);
  if (turnText) {
    return turnText;
  }
  const item = params?.item && typeof params.item === "object" ? params.item : payload?.item;
  if (!item || typeof item !== "object") {
    return "";
  }
  const assistantText = extractAssistantNotificationText(item);
  const phase = normalizeCodexMessagePhase(item.phase);
  if (phase === "final_answer" && assistantText) {
    return assistantText;
  }
  if (payload?.method === "rawResponseItem/completed" && assistantText) {
    return assistantText;
  }
  if (payload?.method === "item/completed" && assistantText && typeof item.type !== "string" && typeof item.role !== "string") {
    return assistantText;
  }
  return "";
}

function decodeNotificationMessage(payload, params) {
  const finalText = decodeFinalText(payload, params);
  if (finalText) {
    return finalText;
  }
  const item = params?.item && typeof params.item === "object" ? params.item : payload?.item;
  const assistantItemText = extractAssistantNotificationText(item);
  if (assistantItemText) {
    return assistantItemText;
  }
  return pickFirstString(
    params?.message,
    payload?.message,
    params?.error?.message,
    params?.status?.error?.message,
    payload?.error?.message,
  );
}

function decodeNotificationStatus(params) {
  if (typeof params?.status === "string" && params.status.trim() !== "") {
    return params.status;
  }
  if (params?.status && typeof params.status.type === "string" && params.status.type.trim() !== "") {
    return params.status.type;
  }
  return "";
}

function decodeBurstEntryMessage(entry) {
  if (typeof entry === "string") {
    const parsed = safeJsonParse(entry);
    if (parsed && typeof parsed === "object") {
      return pickFirstString(
        parsed?.params?.error?.message,
        parsed?.error?.message,
        parsed?.params?.status?.error?.message,
        typeof parsed?.params?.status?.type === "string" ? parsed.params.status.type : "",
        typeof parsed?.method === "string" ? parsed.method : "",
      ) || entry.trim();
    }
    return entry.trim();
  }
  if (!entry || typeof entry !== "object") {
    return "";
  }
  return pickFirstString(
    entry?.params?.error?.message,
    entry?.error?.message,
    entry?.params?.status?.error?.message,
    typeof entry?.params?.status?.type === "string" ? entry.params.status.type : "",
    typeof entry?.method === "string" ? entry.method : "",
  );
}

function decodeRpcErrorMessage(payload) {
  const direct = pickFirstString(
    payload?.error?.message,
    payload?.error?.data?.message,
  );
  if (direct) {
    return direct;
  }
  if (Array.isArray(payload?.result)) {
    const parts = payload.result
      .map((entry) => decodeBurstEntryMessage(entry))
      .filter((entry) => typeof entry === "string" && entry.trim() !== "");
    if (parts.length) {
      return parts.join("\n");
    }
  }
  return "";
}

export function parseCodexRpcResponse(frame) {
  const payload = frame.payloadJson({});
  const errorMessage = decodeRpcErrorMessage(payload);
  return {
    streamId: frame.traceId || "",
    method: typeof payload.method === "string" ? payload.method : "",
    result: payload.result && typeof payload.result === "object" ? payload.result : {},
    hasError: !!payload.has_error,
    raw: payload,
    threadId: decodeThreadId(payload.result),
    turnId: decodeTurnId(payload.result),
    threadPath: decodeThreadPath(payload.result),
    errorMessage,
  };
}

export function parseCodexNotification(frame) {
  const payload = frame.payloadJson({});
  const params = payload.params && typeof payload.params === "object" ? payload.params : {};
  const turnError = decodeTurnError(payload, params);
  const finalText = decodeFinalText(payload, params);
  const message = decodeNotificationMessage(payload, params);
  return {
    streamId: frame.traceId || "",
    method: typeof payload.method === "string" ? payload.method : "",
    params,
    raw: payload,
    delta: typeof params.delta === "string" ? params.delta : "",
    message,
    finalText,
    status: decodeNotificationStatus(params),
    threadStatusType: decodeThreadStatusType(payload, params),
    activeFlags: decodeThreadActiveFlags(payload, params),
    turnStatus: decodeTurnStatus(payload, params),
    threadId: decodeNotificationThreadId(payload, params),
    turnId: decodeNotificationTurnId(payload, params),
    itemId: decodeNotificationItemId(payload, params),
    itemType: decodeItemType(payload, params),
    itemRole: decodeItemRole(payload, params),
    phase: decodeNotificationPhase(payload, params),
    threadPath: decodeNotificationThreadPath(payload, params),
    turnError,
    errorMessage: pickFirstString(
      turnError?.message,
      params?.error?.message,
      params?.status?.error?.message,
      payload?.error?.message,
      message,
    ),
  };
}
