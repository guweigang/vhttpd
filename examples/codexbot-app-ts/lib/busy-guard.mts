export const BUSY_STREAM_STATUSES = Object.freeze([
  "queued",
  "thread_ready",
  "thread_ready_notified",
  "starting_turn",
  "running",
  "streaming",
  "reading_final",
]);

export function positiveIntegerEnv(name, fallbackValue) {
  const raw = typeof process?.env?.[name] === "string" ? process.env[name].trim() : "";
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallbackValue;
  }
  return Math.floor(parsed);
}

export function isBusyStreamStatus(status) {
  const text = typeof status === "string" ? status.trim().toLowerCase() : "";
  return BUSY_STREAM_STATUSES.includes(text);
}

export function isBusyStream(stream) {
  if (!stream || typeof stream !== "object") {
    return false;
  }
  return isBusyStreamStatus(stream.status);
}

export function isStaleBusyStream(stream, staleMs, nowMs = Date.now()) {
  if (!isBusyStream(stream)) {
    return false;
  }
  const updatedAt = Number(stream?.updatedAt || 0);
  if (!updatedAt) {
    return false;
  }
  return (nowMs - updatedAt) >= staleMs;
}
