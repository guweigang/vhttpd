// This adapter stays aligned with the vendored Codex TS schema under ./ts/.
// The copied files are type-only definitions generated from Codex itself.

export const CODEX_THREAD_STATUS = Object.freeze({
  NOT_LOADED: "notLoaded",
  IDLE: "idle",
  SYSTEM_ERROR: "systemError",
  ACTIVE: "active",
});

export const CODEX_THREAD_ACTIVE_FLAG = Object.freeze({
  WAITING_ON_APPROVAL: "waitingOnApproval",
  WAITING_ON_USER_INPUT: "waitingOnUserInput",
});

export const CODEX_TURN_STATUS = Object.freeze({
  COMPLETED: "completed",
  INTERRUPTED: "interrupted",
  FAILED: "failed",
  IN_PROGRESS: "inProgress",
});

export const CODEX_MESSAGE_PHASE = Object.freeze({
  COMMENTARY: "commentary",
  FINAL_ANSWER: "final_answer",
});

export function normalizeCodexMessagePhase(value) {
  if (typeof value !== "string") {
    return "";
  }
  const phase = value.trim();
  return phase === CODEX_MESSAGE_PHASE.COMMENTARY || phase === CODEX_MESSAGE_PHASE.FINAL_ANSWER
    ? phase
    : "";
}

export function normalizeCodexThreadStatus(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  const lowered = trimmed.toLowerCase();
  if (lowered === CODEX_THREAD_STATUS.NOT_LOADED.toLowerCase()) {
    return CODEX_THREAD_STATUS.NOT_LOADED;
  }
  if (lowered === CODEX_THREAD_STATUS.IDLE.toLowerCase()) {
    return CODEX_THREAD_STATUS.IDLE;
  }
  if (lowered === CODEX_THREAD_STATUS.SYSTEM_ERROR.toLowerCase()) {
    return CODEX_THREAD_STATUS.SYSTEM_ERROR;
  }
  if (lowered === CODEX_THREAD_STATUS.ACTIVE.toLowerCase()) {
    return CODEX_THREAD_STATUS.ACTIVE;
  }
  return trimmed;
}

export function normalizeCodexTurnStatus(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  const lowered = trimmed.toLowerCase();
  if (lowered === CODEX_TURN_STATUS.COMPLETED.toLowerCase()) {
    return CODEX_TURN_STATUS.COMPLETED;
  }
  if (lowered === CODEX_TURN_STATUS.INTERRUPTED.toLowerCase()) {
    return CODEX_TURN_STATUS.INTERRUPTED;
  }
  if (lowered === CODEX_TURN_STATUS.FAILED.toLowerCase()) {
    return CODEX_TURN_STATUS.FAILED;
  }
  if (lowered === "inprogress" || lowered === "in_progress") {
    return CODEX_TURN_STATUS.IN_PROGRESS;
  }
  return trimmed;
}

export function isCodexThreadIdleStatus(value) {
  return normalizeCodexThreadStatus(value) === CODEX_THREAD_STATUS.IDLE;
}

export function isCodexThreadActiveStatus(value) {
  return normalizeCodexThreadStatus(value) === CODEX_THREAD_STATUS.ACTIVE;
}

export function isCodexThreadSystemErrorStatus(value) {
  return normalizeCodexThreadStatus(value) === CODEX_THREAD_STATUS.SYSTEM_ERROR;
}

export function isCodexTurnInProgress(value) {
  return normalizeCodexTurnStatus(value) === CODEX_TURN_STATUS.IN_PROGRESS;
}

export function isCodexTurnFailed(value) {
  return normalizeCodexTurnStatus(value) === CODEX_TURN_STATUS.FAILED;
}

export function normalizeCodexRuntimeStatus(value) {
  if (isCodexThreadActiveStatus(value)) {
    return "active";
  }
  if (isCodexThreadSystemErrorStatus(value)) {
    return "systemerror";
  }
  if (isCodexThreadIdleStatus(value)) {
    return "idle";
  }
  if (isCodexTurnInProgress(value)) {
    return "running";
  }
  const text = typeof value === "string" ? value.trim().toLowerCase() : "";
  return text || value || "";
}

export function formatCodexErrorCodeLabel(code) {
  const text = typeof code === "string" ? code.trim() : "";
  if (!text) {
    return "";
  }
  return text.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (char) => char.toUpperCase());
}
