const LEGACY_RELAY_VERSION = "1";
const CURRENT_RELAY_VERSION = "2";
const MAX_PENDING_FRAMES = 200;
const DEFAULT_CONTROL_CLOSE_CODE = 1011;
const DEFAULT_SERVER_DATA_CLOSE_CODE = 1012;
const DEFAULT_CONTROL_NUDGE_DELAY_MS = 10_000;
const DEFAULT_CONTROL_RESET_DELAY_MS = 5_000;
const DEFAULT_PENDING_FLUSH_SETTLE_DELAY_MS = 250;
const DEFAULT_PENDING_FLUSH_DISPATCH_DELAY_MS = 1;
const DEFAULT_DEBUG_MESSAGE_LIMIT = 6;

function nowMs() {
  return Date.now();
}

function json(value) {
  return JSON.stringify(value);
}

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeRole(value) {
  const role = trimString(value);
  return role === "server" || role === "client" ? role : "";
}

function resolveRelayVersion(rawValue) {
  const value = trimString(rawValue);
  if (!value) {
    return LEGACY_RELAY_VERSION;
  }
  if (value === LEGACY_RELAY_VERSION || value === CURRENT_RELAY_VERSION) {
    return value;
  }
  return "";
}

function nextConnectionId() {
  const cryptoApi =
    typeof globalThis.crypto === "object" && globalThis.crypto ? globalThis.crypto : null;
  if (cryptoApi && typeof cryptoApi.randomUUID === "function") {
    return `conn_${cryptoApi.randomUUID().replace(/-/g, "").slice(0, 16)}`;
  }
  const random = Math.random().toString(16).slice(2, 10);
  return `conn_${nowMs().toString(16)}${random}`;
}

function okJson(body, status = 200) {
  return {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
    body: json(body),
  };
}

function numberConfig(runtime, path, fallbackValue) {
  if (!runtime || typeof runtime.getConfig !== "function") {
    return fallbackValue;
  }
  const raw = runtime.getConfig(path, fallbackValue);
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallbackValue;
}

function relayDebugEnabled(runtime) {
  if (!runtime || typeof runtime.getConfig !== "function") {
    return true;
  }
  const raw = runtime.getConfig("relay.debug", "true");
  if (typeof raw === "boolean") {
    return raw;
  }
  const value = trimString(raw).toLowerCase();
  return !(value === "0" || value === "false" || value === "off" || value === "no");
}

function relayLog(runtime, ...args) {
  if (!relayDebugEnabled(runtime)) {
    return;
  }
  if (runtime && typeof runtime.log === "function") {
    runtime.log("[paseo-relay]", ...args);
  }
}

function previewPayload(data, opcode) {
  const kind = trimString(opcode) || "text";
  const text = String(data ?? "");
  if (kind !== "text") {
    return `opcode=${kind} bytes=${text.length}`;
  }
  return `opcode=text bytes=${text.length} payload=${text.replace(/\s+/g, " ").slice(0, 180)}`;
}

function sessionDebugState(session, connectionId = "") {
  if (!session) {
    return "session=missing";
  }
  if (!connectionId) {
    return `session=${session.key} controls=${session.controlIds.size}`;
  }
  return [
    `session=${session.key}`,
    `connectionId=${connectionId}`,
    `clients=${(session.clientIdsByConnection.get(connectionId) || new Set()).size}`,
    `serverData=${session.serverDataByConnection.get(connectionId) || ""}`,
    `pending=${(session.pendingFramesByConnection.get(connectionId) || []).length}`,
    `draining=${(session.pendingDrainByConnection.get(connectionId)?.frames || []).length}`,
  ].join(" ");
}

function ensureDebugCounters(session) {
  if (!session.debugMessageCountByConnection) {
    session.debugMessageCountByConnection = new Map();
  }
  return session.debugMessageCountByConnection;
}

function shouldLogFrameSample(session, connectionId, runtime) {
  if (!connectionId) {
    return true;
  }
  const limit = numberConfig(runtime, "relay.debugMessageLimit", DEFAULT_DEBUG_MESSAGE_LIMIT);
  const counters = ensureDebugCounters(session);
  const next = (counters.get(connectionId) || 0) + 1;
  counters.set(connectionId, next);
  return next <= limit;
}

function relaySendCommand(event, data, opcode = "text", extra = {}) {
  return {
    event,
    data: data == null ? "" : String(data),
    opcode: trimString(opcode) || "text",
    ...extra,
  };
}

function textCommand(event, data, extra = {}) {
  return relaySendCommand(event, data, "text", extra);
}

function closeCommand(reason, extra = {}) {
  return {
    event: "close",
    reason: trimString(reason),
    ...extra,
  };
}

function safeJsonParse(text, fallbackValue = null) {
  if (typeof text !== "string" || text.trim() === "") {
    return fallbackValue;
  }
  try {
    return JSON.parse(text);
  } catch (_) {
    return fallbackValue;
  }
}

function roomSession(serverId) {
  return `relay:session:${serverId}`;
}

function roomConnection(serverId, connectionId) {
  return `relay:conn:${serverId}:${connectionId}`;
}

function relayState() {
  if (!globalThis.__paseoRelayState) {
    globalThis.__paseoRelayState = {
      createdAt: nowMs(),
    };
  }
  return globalThis.__paseoRelayState;
}

function sessionKey(serverId, version) {
  return `relay-v${version || CURRENT_RELAY_VERSION}:${serverId}`;
}

function relayStore(runtime) {
  if (!runtime || typeof runtime.sessionStore !== "function") {
    return null;
  }
  return runtime.sessionStore("relay");
}

function relaySessionStoreKey(serverId, version) {
  return `session:${serverId}:${version || CURRENT_RELAY_VERSION}`;
}

function createEmptySession(serverId, version) {
  const resolvedVersion = version || CURRENT_RELAY_VERSION;
  return {
    key: sessionKey(serverId, resolvedVersion),
    serverId,
    version: resolvedVersion,
    createdAt: nowMs(),
    updatedAt: nowMs(),
    v1ServerId: "",
    v1ClientIds: new Set(),
    controlIds: new Set(),
    serverDataByConnection: new Map(),
    clientIdsByConnection: new Map(),
    announcedConnections: new Set(),
    pendingFramesByConnection: new Map(),
    pendingDrainByConnection: new Map(),
    controlNudgeTokensByConnection: new Map(),
    debugMessageCountByConnection: new Map(),
  };
}

function serializeSession(session) {
  return {
    key: session.key,
    serverId: session.serverId,
    version: session.version,
    createdAt: Number(session.createdAt || 0),
    updatedAt: Number(session.updatedAt || 0),
    v1ServerId: trimString(session.v1ServerId),
    v1ClientIds: Array.from(session.v1ClientIds || []).sort(),
    controlIds: Array.from(session.controlIds || []).sort(),
    serverDataByConnection: Array.from(session.serverDataByConnection?.entries?.() || []).sort((a, b) =>
      String(a[0]).localeCompare(String(b[0])),
    ),
    clientIdsByConnection: Array.from(session.clientIdsByConnection?.entries?.() || [])
      .map(([connectionId, ids]) => [connectionId, Array.from(ids || []).sort()])
      .sort((a, b) => String(a[0]).localeCompare(String(b[0]))),
    announcedConnections: Array.from(session.announcedConnections || []).sort(),
    pendingFramesByConnection: Array.from(session.pendingFramesByConnection?.entries?.() || []).sort((a, b) =>
      String(a[0]).localeCompare(String(b[0])),
    ),
    pendingDrainByConnection: Array.from(session.pendingDrainByConnection?.entries?.() || []).sort((a, b) =>
      String(a[0]).localeCompare(String(b[0])),
    ),
    controlNudgeTokensByConnection: Array.from(
      session.controlNudgeTokensByConnection?.entries?.() || [],
    ).sort((a, b) => String(a[0]).localeCompare(String(b[0]))),
    debugMessageCountByConnection: Array.from(
      session.debugMessageCountByConnection?.entries?.() || [],
    ).sort((a, b) => String(a[0]).localeCompare(String(b[0]))),
  };
}

function hydrateSession(raw, serverId, version) {
  const session = createEmptySession(serverId, version);
  if (!raw || typeof raw !== "object") {
    return session;
  }
  session.key = trimString(raw.key) || session.key;
  session.serverId = trimString(raw.serverId) || serverId;
  session.version = resolveRelayVersion(raw.version) || version || CURRENT_RELAY_VERSION;
  session.createdAt = Number(raw.createdAt || session.createdAt);
  session.updatedAt = Number(raw.updatedAt || session.updatedAt);
  session.v1ServerId = trimString(raw.v1ServerId);
  session.v1ClientIds = new Set(Array.isArray(raw.v1ClientIds) ? raw.v1ClientIds.map(trimString).filter(Boolean) : []);
  session.controlIds = new Set(Array.isArray(raw.controlIds) ? raw.controlIds.map(trimString).filter(Boolean) : []);
  session.serverDataByConnection = new Map(
    Array.isArray(raw.serverDataByConnection)
      ? raw.serverDataByConnection.map(([connectionId, socketId]) => [trimString(connectionId), trimString(socketId)])
      : [],
  );
  session.clientIdsByConnection = new Map(
    Array.isArray(raw.clientIdsByConnection)
      ? raw.clientIdsByConnection.map(([connectionId, ids]) => [
          trimString(connectionId),
          new Set(Array.isArray(ids) ? ids.map(trimString).filter(Boolean) : []),
        ])
      : [],
  );
  session.announcedConnections = new Set(
    Array.isArray(raw.announcedConnections) ? raw.announcedConnections.map(trimString).filter(Boolean) : [],
  );
  session.pendingFramesByConnection = new Map(
    Array.isArray(raw.pendingFramesByConnection)
      ? raw.pendingFramesByConnection.map(([connectionId, frames]) => [
          trimString(connectionId),
          Array.isArray(frames) ? frames.map((frame) => ({
            data: String(frame?.data ?? ""),
            opcode: trimString(frame?.opcode) || "text",
          })) : [],
        ])
      : [],
  );
  session.pendingDrainByConnection = new Map(
    Array.isArray(raw.pendingDrainByConnection)
      ? raw.pendingDrainByConnection.map(([connectionId, drain]) => [
          trimString(connectionId),
          drain && typeof drain === "object"
            ? {
                targetId: trimString(drain.targetId),
                token: trimString(drain.token),
                createdAt: Number(drain.createdAt || 0),
                frames: Array.isArray(drain.frames) ? drain.frames.map((frame) => ({
                  data: String(frame?.data ?? ""),
                  opcode: trimString(frame?.opcode) || "text",
                })) : [],
              }
            : null,
        ]).filter(([connectionId, drain]) => connectionId && drain)
      : [],
  );
  session.controlNudgeTokensByConnection = new Map(
    Array.isArray(raw.controlNudgeTokensByConnection)
      ? raw.controlNudgeTokensByConnection.map(([connectionId, token]) => [trimString(connectionId), trimString(token)])
      : [],
  );
  session.debugMessageCountByConnection = new Map(
    Array.isArray(raw.debugMessageCountByConnection)
      ? raw.debugMessageCountByConnection.map(([connectionId, count]) => [trimString(connectionId), Number(count || 0)])
      : [],
  );
  return session;
}

function saveSession(runtime, session) {
  const store = relayStore(runtime);
  if (!store || !session) {
    return false;
  }
  return !!store.set(relaySessionStoreKey(session.serverId, session.version), serializeSession(session), {
    ttlMs: 24 * 60 * 60 * 1000,
  });
}

function loadSession(runtime, serverId, version) {
  const store = relayStore(runtime);
  if (!store) {
    return createEmptySession(serverId, version);
  }
  const raw = store.get(relaySessionStoreKey(serverId, version), null);
  return hydrateSession(raw, serverId, version);
}

function deleteSession(runtime, serverId, version) {
  const store = relayStore(runtime);
  if (!store) {
    return false;
  }
  return !!store.delete(relaySessionStoreKey(serverId, version));
}

function ensureSession(runtime, serverId, version) {
  const session = loadSession(runtime, serverId, version);
  session.version = version || CURRENT_RELAY_VERSION;
  session.updatedAt = nowMs();
  return session;
}

function patchSession(runtime, serverId, version, updater) {
  const store = relayStore(runtime);
  if (!store || typeof store.patch !== "function") {
    const session = ensureSession(runtime, serverId, version);
    const next = updater(session);
    if (next == null) {
      deleteSession(runtime, serverId, version);
      return null;
    }
    const resolved = next && typeof next === "object" ? next : session;
    saveSession(runtime, resolved);
    return resolved;
  }
  const fallback = serializeSession(createEmptySession(serverId, version));
  const raw = store.patch(
    relaySessionStoreKey(serverId, version),
    (stored) => {
      const session = hydrateSession(stored, serverId, version);
      session.version = version || CURRENT_RELAY_VERSION;
      session.updatedAt = nowMs();
      const next = updater(session);
      if (next == null) {
        return null;
      }
      const resolved = next && typeof next === "object" ? next : session;
      return serializeSession(resolved);
    },
    fallback,
    { ttlMs: 24 * 60 * 60 * 1000 },
  );
  if (raw == null) {
    return null;
  }
  return hydrateSession(raw, serverId, version);
}

function touchSession(session) {
  if (!session) {
    return;
  }
  session.updatedAt = nowMs();
}

function maybeDeleteSession(runtime, session) {
  if (!session) {
    return false;
  }
  const hasV1 = !!session.v1ServerId || session.v1ClientIds.size > 0;
  const hasV2 =
    session.controlIds.size > 0 ||
    session.serverDataByConnection.size > 0 ||
    session.clientIdsByConnection.size > 0;
  if (!hasV1 && !hasV2) {
    return deleteSession(runtime, session.serverId, session.version);
  }
  return saveSession(runtime, session);
}

function persistMaybeDeleteSession(runtime, session) {
  if (!session) {
    return null;
  }
  const hasV1 = !!session.v1ServerId || session.v1ClientIds.size > 0;
  const hasV2 =
    session.controlIds.size > 0 ||
    session.serverDataByConnection.size > 0 ||
    session.clientIdsByConnection.size > 0;
  if (!hasV1 && !hasV2) {
    return null;
  }
  return session;
}

function persistMaybeDeleteSessionValue(session) {
  if (!session) {
    return null;
  }
  const hasV1 = !!session.v1ServerId || session.v1ClientIds.size > 0;
  const hasV2 =
    session.controlIds.size > 0 ||
    session.serverDataByConnection.size > 0 ||
    session.clientIdsByConnection.size > 0;
  if (!hasV1 && !hasV2) {
    return null;
  }
  return session;
}

function setForConnection(session, connectionId) {
  let clients = session.clientIdsByConnection.get(connectionId);
  if (!clients) {
    clients = new Set();
    session.clientIdsByConnection.set(connectionId, clients);
  }
  return clients;
}

function clearControlNudge(session, connectionId) {
  if (!session || !connectionId) {
    return;
  }
  session.controlNudgeTokensByConnection.delete(connectionId);
}

function listConnectedConnectionIds(session) {
  return Array.from(session.clientIdsByConnection.keys()).sort();
}

function markConnectionAnnounced(session, connectionId) {
  if (!session || !connectionId) {
    return false;
  }
  if (session.announcedConnections.has(connectionId)) {
    return false;
  }
  session.announcedConnections.add(connectionId);
  return true;
}

function clearConnectionAnnounced(session, connectionId) {
  if (!session || !connectionId) {
    return;
  }
  session.announcedConnections.delete(connectionId);
}

function notifyControls(session, payload) {
  const text = json(payload);
  return Array.from(session.controlIds).map((controlId) =>
    textCommand("send", text, { targetId: controlId }),
  );
}

function failedTargetIdsFromDispatchResult(result) {
  if (!result || typeof result !== "object" || !Array.isArray(result.failures)) {
    return [];
  }
  const failed = [];
  for (const item of result.failures) {
    const targetId = trimString(item?.targetId ?? item?.target_id ?? "");
    if (targetId) {
      failed.push(targetId);
    }
  }
  return failed;
}

function scheduleControlNudge(session, connectionId, runtime) {
  if (
    !session ||
    !connectionId ||
    !runtime ||
    typeof runtime.websocketDispatch !== "function" ||
    typeof setTimeout !== "function"
  ) {
    return;
  }
  const token = nextConnectionId();
  const relaySessionKey = session.key;
  const initialDelayMs = numberConfig(
    runtime,
    "relay.controlNudgeDelayMs",
    DEFAULT_CONTROL_NUDGE_DELAY_MS,
  );
  const secondDelayMs = numberConfig(
    runtime,
    "relay.controlResetDelayMs",
    DEFAULT_CONTROL_RESET_DELAY_MS,
  );
  session.controlNudgeTokensByConnection.set(connectionId, token);
  setTimeout(() => {
    let shouldSync = false;
    const current = patchSession(runtime, session.serverId, session.version, (draft) => {
      if (!draft || draft.key !== relaySessionKey) {
        return draft;
      }
      if (draft.controlNudgeTokensByConnection.get(connectionId) !== token) {
        return draft;
      }
      const clients = draft.clientIdsByConnection.get(connectionId);
      if (!clients || clients.size === 0) {
        draft.controlNudgeTokensByConnection.delete(connectionId);
        return persistMaybeDeleteSessionValue(draft);
      }
      if (draft.serverDataByConnection.get(connectionId)) {
        draft.controlNudgeTokensByConnection.delete(connectionId);
        return persistMaybeDeleteSessionValue(draft);
      }
      shouldSync = true;
      return draft;
    });
    if (!current || !shouldSync) {
      return;
    }
    relayLog(runtime, "control_nudge_sync", sessionDebugState(current, connectionId));
    const syncResult = runtime.websocketDispatch(
      notifyControls(current, {
        type: "sync",
        connectionIds: listConnectedConnectionIds(current),
      }),
      { ok: false, failures: [] },
    );
    const failedControlIds = failedTargetIdsFromDispatchResult(syncResult);
    if (failedControlIds.length > 0) {
      relayLog(runtime, "control_sync_send_failed", `targets=${failedControlIds.join(",")}`);
      runtime.websocketDispatch(
        failedControlIds.map((controlId) =>
          closeCommand("Control send failed", {
            targetId: controlId,
            code: DEFAULT_CONTROL_CLOSE_CODE,
          }),
        ),
      );
    }
    setTimeout(() => {
      let shouldReset = false;
      const latest = patchSession(runtime, session.serverId, session.version, (draft) => {
        if (!draft || draft.key !== relaySessionKey) {
          return draft;
        }
        if (draft.controlNudgeTokensByConnection.get(connectionId) !== token) {
          return draft;
        }
        const latestClients = draft.clientIdsByConnection.get(connectionId);
        if (!latestClients || latestClients.size === 0) {
          draft.controlNudgeTokensByConnection.delete(connectionId);
          return persistMaybeDeleteSessionValue(draft);
        }
        if (draft.serverDataByConnection.get(connectionId)) {
          draft.controlNudgeTokensByConnection.delete(connectionId);
          return persistMaybeDeleteSessionValue(draft);
        }
        draft.controlNudgeTokensByConnection.delete(connectionId);
        shouldReset = true;
        return draft;
      });
      if (!latest || !shouldReset) {
        return;
      }
      relayLog(runtime, "control_nudge_reset", sessionDebugState(latest, connectionId));
      runtime.websocketDispatch(
        Array.from(latest.controlIds).map((controlId) =>
          closeCommand("Control unresponsive", {
            targetId: controlId,
            code: DEFAULT_CONTROL_CLOSE_CODE,
          }),
        ),
      );
    }, secondDelayMs);
  }, initialDelayMs);
}

function bufferFrame(session, connectionId, message) {
  const existing = session.pendingFramesByConnection.get(connectionId) || [];
  existing.push({
    data: message && typeof message === "object" ? String(message.data ?? "") : String(message ?? ""),
    opcode:
      message && typeof message === "object" ? trimString(message.opcode) || "text" : "text",
  });
  if (existing.length > MAX_PENDING_FRAMES) {
    existing.splice(0, existing.length - MAX_PENDING_FRAMES);
  }
  session.pendingFramesByConnection.set(connectionId, existing);
  touchSession(session);
}

function appendPendingFrames(session, connectionId, frames) {
  if (!session || !connectionId || !Array.isArray(frames) || frames.length === 0) {
    return;
  }
  const existing = session.pendingFramesByConnection.get(connectionId) || [];
  for (const frame of frames) {
    existing.push({
      data: String(frame?.data ?? ""),
      opcode: trimString(frame?.opcode) || "text",
    });
  }
  if (existing.length > MAX_PENDING_FRAMES) {
    existing.splice(0, existing.length - MAX_PENDING_FRAMES);
  }
  session.pendingFramesByConnection.set(connectionId, existing);
  touchSession(session);
}

function restorePendingDrain(session, connectionId, targetId = "") {
  if (!session || !connectionId) {
    return [];
  }
  const drain = session.pendingDrainByConnection.get(connectionId);
  if (!drain) {
    return [];
  }
  if (targetId && trimString(drain.targetId) && trimString(drain.targetId) !== trimString(targetId)) {
    return [];
  }
  session.pendingDrainByConnection.delete(connectionId);
  const frames = Array.isArray(drain.frames) ? drain.frames : [];
  appendPendingFrames(session, connectionId, frames);
  return frames;
}

function schedulePendingDrainFinalize(session, connectionId, token, targetId, runtime) {
  if (
    !session ||
    !connectionId ||
    !token ||
    !runtime ||
    typeof setTimeout !== "function"
  ) {
    return;
  }
  const relaySessionKey = session.key;
  const settleDelayMs = numberConfig(
    runtime,
    "relay.pendingFlushSettleDelayMs",
    DEFAULT_PENDING_FLUSH_SETTLE_DELAY_MS,
  );
  setTimeout(() => {
    patchSession(runtime, session.serverId, session.version, (current) => {
      if (!current || current.key !== relaySessionKey) {
        return current;
      }
      const drain = current.pendingDrainByConnection.get(connectionId);
      if (!drain) {
        return current;
      }
      if (drain.token !== token) {
        return current;
      }
      if (trimString(drain.targetId) !== trimString(targetId)) {
        return current;
      }
      current.pendingDrainByConnection.delete(connectionId);
      touchSession(current);
      return persistMaybeDeleteSessionValue(current);
    });
  }, settleDelayMs);
}

function flushPendingFrames(session, connectionId, targetId, runtime) {
  restorePendingDrain(session, connectionId);
  const frames = session.pendingFramesByConnection.get(connectionId) || [];
  if (frames.length === 0) {
    return [];
  }
  const clonedFrames = frames.map((frame) => ({
    data: String(frame?.data ?? ""),
    opcode: trimString(frame?.opcode) || "text",
  }));
  const token = nextConnectionId();
  session.pendingDrainByConnection.set(connectionId, {
    targetId,
    token,
    frames: clonedFrames,
    createdAt: nowMs(),
  });
  session.pendingFramesByConnection.delete(connectionId);
  touchSession(session);
  relayLog(
    runtime,
    "pending_flush_start",
    sessionDebugState(session, connectionId),
    `targetId=${targetId}`,
    `frames=${clonedFrames.length}`,
  );
  schedulePendingDrainFinalize(session, connectionId, token, targetId, runtime);
  return clonedFrames.map((frame) =>
    relaySendCommand("send", frame?.data ?? "", frame?.opcode ?? "text", { targetId }),
  );
}

function schedulePendingFlush(session, connectionId, targetId, runtime) {
  if (
    !session ||
    !connectionId ||
    !targetId ||
    !runtime ||
    typeof runtime.websocketDispatch !== "function" ||
    typeof setTimeout !== "function"
  ) {
    return;
  }
  const relaySessionKey = session.key;
  const delayMs = numberConfig(
    runtime,
    "relay.pendingFlushDispatchDelayMs",
    DEFAULT_PENDING_FLUSH_DISPATCH_DELAY_MS,
  );
  setTimeout(() => {
    const token = nextConnectionId();
    let commands = [];
    const current = patchSession(runtime, session.serverId, session.version, (draft) => {
      if (!draft || draft.key !== relaySessionKey) {
        return draft;
      }
      if ((draft.serverDataByConnection.get(connectionId) || "") !== targetId) {
        return draft;
      }
      restorePendingDrain(draft, connectionId);
      const frames = draft.pendingFramesByConnection.get(connectionId) || [];
      if (frames.length === 0) {
        commands = [];
        return draft;
      }
      const clonedFrames = frames.map((frame) => ({
        data: String(frame?.data ?? ""),
        opcode: trimString(frame?.opcode) || "text",
      }));
      draft.pendingDrainByConnection.set(connectionId, {
        targetId,
        token,
        frames: clonedFrames,
        createdAt: nowMs(),
      });
      draft.pendingFramesByConnection.delete(connectionId);
      touchSession(draft);
      commands = clonedFrames.map((frame) =>
        relaySendCommand("send", frame?.data ?? "", frame?.opcode ?? "text", { targetId }),
      );
      return draft;
    });
    if (!current) {
      return;
    }
    if (commands.length === 0) {
      return;
    }
    relayLog(
      runtime,
      "pending_flush_start",
      sessionDebugState(current, connectionId),
      `targetId=${targetId}`,
      `frames=${commands.length}`,
    );
    schedulePendingDrainFinalize(current, connectionId, token, targetId, runtime);
    runtime.websocketDispatch(commands, { ok: false, failures: [] });
  }, delayMs);
}

function sessionSnapshot(runtime) {
  const store = relayStore(runtime);
  const keys = store && typeof store.keys === "function" ? store.keys([]) : [];
  const sessions = [];
  for (const key of keys) {
    if (!String(key).startsWith("session:")) {
      continue;
    }
    const raw = store.get(key, null);
    const [_, serverId = "", version = CURRENT_RELAY_VERSION] = String(key).split(":");
    const session = hydrateSession(raw, serverId, version);
    const connectionRows = [];
    for (const [connectionId, clientIds] of session.clientIdsByConnection.entries()) {
      connectionRows.push({
        connectionId,
        clientCount: clientIds.size,
        serverDataId: session.serverDataByConnection.get(connectionId) || "",
        pendingCount: (session.pendingFramesByConnection.get(connectionId) || []).length,
        drainingCount: (session.pendingDrainByConnection.get(connectionId)?.frames || []).length,
      });
    }
    connectionRows.sort((a, b) => a.connectionId.localeCompare(b.connectionId));
    sessions.push({
      sessionKey: session.key,
      serverId: session.serverId,
      version: session.version,
      controlCount: session.controlIds.size,
      v1ServerId: session.v1ServerId,
      v1ClientCount: session.v1ClientIds.size,
      connections: connectionRows,
      updatedAt: session.updatedAt,
    });
  }
  sessions.sort((a, b) => a.serverId.localeCompare(b.serverId));
  return {
    ok: true,
    app: "paseo-relay",
    sessionCount: sessions.length,
    sessions,
  };
}

function mergeRelaySnapshotPayloads(payloads) {
  const mergedBySessionKey = new Map();
  for (const payload of payloads) {
    if (!payload || typeof payload !== "object" || !Array.isArray(payload.sessions)) {
      continue;
    }
    for (const session of payload.sessions) {
      if (!session || typeof session !== "object") {
        continue;
      }
      const sessionKey = trimString(session.sessionKey);
      if (!sessionKey) {
        continue;
      }
      const current = mergedBySessionKey.get(sessionKey) || {
        sessionKey,
        serverId: trimString(session.serverId),
        version: trimString(session.version),
        controlCount: 0,
        v1ServerId: trimString(session.v1ServerId),
        v1ClientCount: 0,
        connections: new Map(),
        updatedAt: 0,
      };
      current.serverId = current.serverId || trimString(session.serverId);
      current.version = current.version || trimString(session.version);
      current.v1ServerId = current.v1ServerId || trimString(session.v1ServerId);
      current.controlCount += Number(session.controlCount || 0);
      current.v1ClientCount += Number(session.v1ClientCount || 0);
      current.updatedAt = Math.max(current.updatedAt, Number(session.updatedAt || 0));
      for (const connection of Array.isArray(session.connections) ? session.connections : []) {
        const connectionId = trimString(connection?.connectionId);
        if (!connectionId) {
          continue;
        }
        const existing = current.connections.get(connectionId) || {
          connectionId,
          clientCount: 0,
          serverDataId: "",
          pendingCount: 0,
          drainingCount: 0,
        };
        existing.clientCount += Number(connection?.clientCount || 0);
        existing.serverDataId = existing.serverDataId || trimString(connection?.serverDataId);
        existing.pendingCount += Number(connection?.pendingCount || 0);
        existing.drainingCount += Number(connection?.drainingCount || 0);
        current.connections.set(connectionId, existing);
      }
      mergedBySessionKey.set(sessionKey, current);
    }
  }
  const sessions = Array.from(mergedBySessionKey.values())
    .map((session) => ({
      sessionKey: session.sessionKey,
      serverId: session.serverId,
      version: session.version,
      controlCount: session.controlCount,
      v1ServerId: session.v1ServerId,
      v1ClientCount: session.v1ClientCount,
      connections: Array.from(session.connections.values()).sort((a, b) =>
        a.connectionId.localeCompare(b.connectionId),
      ),
      updatedAt: session.updatedAt,
    }))
    .sort((a, b) => a.serverId.localeCompare(b.serverId));
  return {
    ok: true,
    app: "paseo-relay",
    sessionCount: sessions.length,
    sessions,
  };
}

function aggregateLaneSnapshots(runtime, fallbackValue) {
  if (!runtime || typeof runtime.snapshot !== "function") {
    return {
      merged: fallbackValue,
      local: fallbackValue,
      aggregated: null,
    };
  }
  const payloads = [fallbackValue];
  const aggregated = runtime.snapshot(
    {
      scope: "other_lanes",
      kind: "app",
    },
    null,
  );
  if (!aggregated || typeof aggregated !== "object" || !Array.isArray(aggregated.lanes)) {
    return {
      merged: mergeRelaySnapshotPayloads(payloads),
      local: fallbackValue,
      aggregated,
    };
  }
  for (const lane of aggregated.lanes) {
    if (!lane || typeof lane !== "object" || !lane.available || !lane.snapshot) {
      continue;
    }
    payloads.push(lane.snapshot);
  }
  if (payloads.length === 0) {
    return {
      merged: fallbackValue,
      local: fallbackValue,
      aggregated,
    };
  }
  return {
    merged: mergeRelaySnapshotPayloads(payloads),
    local: fallbackValue,
    aggregated,
  };
}

function rejectOpen(reason, status = 400, code = 1008) {
  return {
    accepted: false,
    commands: [
      closeCommand(reason, {
        status,
        code,
      }),
    ],
  };
}

function registerCommonOpenMetadata(frame, serverId, version, role, connectionId) {
  const commands = [
    { event: "set_meta", key: "relay_server_id", value: serverId },
    { event: "set_meta", key: "relay_version", value: version },
    { event: "set_meta", key: "relay_role", value: role },
    { event: "join", room: roomSession(serverId) },
  ];
  if (connectionId) {
    commands.push(
      { event: "set_meta", key: "relay_connection_id", value: connectionId },
      { event: "join", room: roomConnection(serverId, connectionId) },
    );
  }
  return commands.map((command) => ({ ...command, id: frame.id }));
}

function handleOpenV1(frame, session, role) {
  touchSession(session);
  relayLog(frame.runtime, "open_v1", `role=${role}`, sessionDebugState(session));
  const commands = [];
  if (role === "server") {
    if (session.v1ServerId && session.v1ServerId !== frame.id) {
      commands.push(closeCommand("Replaced by new connection", { targetId: session.v1ServerId, code: 1008 }));
    }
    session.v1ServerId = frame.id;
  } else {
    for (const clientId of session.v1ClientIds) {
      if (clientId !== frame.id) {
        commands.push(closeCommand("Replaced by new connection", { targetId: clientId, code: 1008 }));
      }
    }
    session.v1ClientIds = new Set([frame.id]);
  }
  commands.push(...registerCommonOpenMetadata(frame, session.serverId, LEGACY_RELAY_VERSION, role, ""));
  return {
    accepted: true,
    commands,
  };
}

function handleOpenV2(frame, session, role, rawConnectionId) {
  touchSession(session);
  const commands = [];
  if (role === "client") {
    const resolvedConnectionId = trimString(rawConnectionId) || nextConnectionId();
    const clients = setForConnection(session, resolvedConnectionId);
    clients.add(frame.id);
    relayLog(frame.runtime, "open_client", sessionDebugState(session, resolvedConnectionId), `socket=${frame.id}`);
    commands.push(
      ...registerCommonOpenMetadata(frame, session.serverId, CURRENT_RELAY_VERSION, "client", resolvedConnectionId),
    );
    if (markConnectionAnnounced(session, resolvedConnectionId)) {
      commands.push(...notifyControls(session, { type: "connected", connectionId: resolvedConnectionId }));
    }
    scheduleControlNudge(session, resolvedConnectionId, frame.runtime);
    return {
      accepted: true,
      commands,
    };
  }

  if (!trimString(rawConnectionId)) {
    for (const controlId of session.controlIds) {
      if (controlId !== frame.id) {
        commands.push(closeCommand("Replaced by new connection", { targetId: controlId, code: 1008 }));
      }
    }
    session.controlIds = new Set([frame.id]);
    relayLog(frame.runtime, "open_control", sessionDebugState(session), `socket=${frame.id}`);
    commands.push(
      ...registerCommonOpenMetadata(frame, session.serverId, CURRENT_RELAY_VERSION, "server-control", ""),
      textCommand(
        "send",
        json({ type: "sync", connectionIds: listConnectedConnectionIds(session) }),
        { targetId: frame.id },
      ),
    );
    return {
      accepted: true,
      commands,
    };
  }

  const connectionId = trimString(rawConnectionId);
  const previousId = session.serverDataByConnection.get(connectionId) || "";
  if (previousId && previousId !== frame.id) {
    commands.push(closeCommand("Replaced by new connection", { targetId: previousId, code: 1008 }));
  }
  clearControlNudge(session, connectionId);
  session.serverDataByConnection.set(connectionId, frame.id);
  relayLog(frame.runtime, "open_server_data", sessionDebugState(session, connectionId), `socket=${frame.id}`);
  commands.push(...flushPendingFrames(session, connectionId, frame.id, frame.runtime));
  commands.push(
    ...registerCommonOpenMetadata(frame, session.serverId, CURRENT_RELAY_VERSION, "server-data", connectionId),
  );
  return {
    accepted: true,
    commands,
  };
}

function handleOpen(frame) {
  if (frame.path !== "/ws") {
    return rejectOpen(`Unsupported websocket path: ${frame.path}`, 404);
  }
  const query = frame.query || {};
  const role = normalizeRole(query.role);
  const serverId = trimString(query.serverId);
  const version = resolveRelayVersion(query.v);
  if (!role) {
    return rejectOpen("Missing or invalid role parameter", 400);
  }
  if (!serverId) {
    return rejectOpen("Missing serverId parameter", 400);
  }
  if (!version) {
    return rejectOpen("Invalid v parameter (expected 1 or 2)", 400);
  }
  let response = null;
  patchSession(frame.runtime, serverId, version, (session) => {
    response = version === LEGACY_RELAY_VERSION
      ? handleOpenV1(frame, session, role)
      : handleOpenV2(frame, session, role, query.connectionId);
    return session;
  });
  return response || { accepted: true, commands: [] };
}

function handleMessageV1(frame, session, role) {
  touchSession(session);
  relayLog(frame.runtime, "message_v1", `role=${role}`, previewPayload(frame.data, frame.opcode || "text"));
  if (role === "server") {
    return {
      accepted: true,
      commands: Array.from(session.v1ClientIds).map((clientId) =>
        relaySendCommand("send", frame.data, frame.opcode || "text", { targetId: clientId }),
      ),
    };
  }
  if (!session.v1ServerId) {
    return { accepted: true, commands: [] };
  }
  return {
    accepted: true,
    commands: [relaySendCommand("send", frame.data, frame.opcode || "text", { targetId: session.v1ServerId })],
  };
}

function handleMessageV2(frame, session, role, connectionId) {
  touchSession(session);
  if (shouldLogFrameSample(session, connectionId, frame.runtime)) {
    relayLog(
      frame.runtime,
      "message_v2",
      `role=${role}`,
      connectionId ? sessionDebugState(session, connectionId) : sessionDebugState(session),
      previewPayload(frame.data, frame.opcode || "text"),
    );
  }
  if (role === "server-control") {
    const payload = frame.opcode === "text" ? safeJsonParse(frame.data, null) : null;
    if (payload && payload.type === "ping") {
      return {
        accepted: true,
        commands: [
          textCommand("send", json({ type: "pong", ts: nowMs() }), { targetId: frame.id }),
          textCommand(
            "send",
            json({ type: "sync", connectionIds: listConnectedConnectionIds(session) }),
            { targetId: frame.id },
          ),
        ],
      };
    }
    return { accepted: true, commands: [] };
  }

  if (!connectionId) {
    return { accepted: true, commands: [] };
  }

  if (role === "client") {
    const targetId = session.serverDataByConnection.get(connectionId) || "";
    if (!targetId) {
      bufferFrame(session, connectionId, { data: frame.data, opcode: frame.opcode || "text" });
      relayLog(
        frame.runtime,
        "buffer_client_frame",
        sessionDebugState(session, connectionId),
        previewPayload(frame.data, frame.opcode || "text"),
      );
      const commands = [];
      if (markConnectionAnnounced(session, connectionId)) {
        commands.push(...notifyControls(session, { type: "connected", connectionId }));
      }
      scheduleControlNudge(session, connectionId, frame.runtime);
      return { accepted: true, commands };
    }
    return {
      accepted: true,
      commands: [relaySendCommand("send", frame.data, frame.opcode || "text", { targetId })],
    };
  }

  const clientIds = Array.from(session.clientIdsByConnection.get(connectionId) || []);
  return {
    accepted: true,
    commands: clientIds.map((clientId) =>
      relaySendCommand("send", frame.data, frame.opcode || "text", { targetId: clientId }),
    ),
  };
}

function handleMessage(frame) {
  const metadata = frame.metadata || {};
  const serverId = trimString(metadata.relay_server_id);
  const version = resolveRelayVersion(metadata.relay_version) || CURRENT_RELAY_VERSION;
  const role = trimString(metadata.relay_role);
  const connectionId = trimString(metadata.relay_connection_id);
  if (!serverId || !role) {
    return {
      accepted: true,
      commands: [closeCommand("Relay metadata missing", { code: 1011 })],
      errorClass: "relay_state",
    };
  }
  let response = null;
  patchSession(frame.runtime, serverId, version, (session) => {
    response = version === LEGACY_RELAY_VERSION
      ? handleMessageV1(frame, session, role)
      : handleMessageV2(frame, session, role, connectionId);
    return session;
  });
  return response || { accepted: true, commands: [] };
}

function handleClose(frame) {
  const metadata = frame.metadata || {};
  const serverId = trimString(metadata.relay_server_id);
  const version = resolveRelayVersion(metadata.relay_version) || CURRENT_RELAY_VERSION;
  const role = trimString(metadata.relay_role);
  const connectionId = trimString(metadata.relay_connection_id);
  if (!serverId || !role) {
    return { accepted: true, closed: true, commands: [] };
  }
  let response = { accepted: true, closed: true, commands: [] };
  patchSession(frame.runtime, serverId, version, (session) => {
    touchSession(session);
    relayLog(
      frame.runtime,
      "close_event",
      `role=${role}`,
      connectionId ? sessionDebugState(session, connectionId) : sessionDebugState(session),
      `code=${frame.code || ""}`,
      `reason=${trimString(frame.reason)}`,
    );
    const commands = [];

    if (version === LEGACY_RELAY_VERSION) {
      if (role === "server" && session.v1ServerId === frame.id) {
        session.v1ServerId = "";
      }
      if (role === "client") {
        session.v1ClientIds.delete(frame.id);
      }
      response = { accepted: true, closed: true, commands };
      return persistMaybeDeleteSession(frame.runtime, session);
    }

    if (role === "server-control") {
      session.controlIds.delete(frame.id);
      response = { accepted: true, closed: true, commands };
      return persistMaybeDeleteSession(frame.runtime, session);
    }

    if (role === "client" && connectionId) {
      const clientIds = session.clientIdsByConnection.get(connectionId) || new Set();
      clientIds.delete(frame.id);
      if (clientIds.size === 0) {
        session.clientIdsByConnection.delete(connectionId);
        clearConnectionAnnounced(session, connectionId);
        session.pendingFramesByConnection.delete(connectionId);
        session.pendingDrainByConnection.delete(connectionId);
        ensureDebugCounters(session).delete(connectionId);
        clearControlNudge(session, connectionId);
        const serverDataId = session.serverDataByConnection.get(connectionId) || "";
        if (serverDataId) {
          commands.push(closeCommand("Client disconnected", {
            targetId: serverDataId,
            code: 1001,
          }));
          session.serverDataByConnection.delete(connectionId);
        }
        commands.push(...notifyControls(session, { type: "disconnected", connectionId }));
      } else {
        session.clientIdsByConnection.set(connectionId, clientIds);
      }
      response = { accepted: true, closed: true, commands };
      return persistMaybeDeleteSession(frame.runtime, session);
    }

    if (role === "server-data" && connectionId) {
      clearControlNudge(session, connectionId);
      const currentId = session.serverDataByConnection.get(connectionId) || "";
      if (currentId === frame.id) {
        session.serverDataByConnection.delete(connectionId);
      }
      restorePendingDrain(session, connectionId, frame.id);
      const clientIds = Array.from(session.clientIdsByConnection.get(connectionId) || []);
      for (const clientId of clientIds) {
        commands.push(closeCommand("Server disconnected", {
          targetId: clientId,
          code: DEFAULT_SERVER_DATA_CLOSE_CODE,
        }));
      }
      response = { accepted: true, closed: true, commands };
      return persistMaybeDeleteSession(frame.runtime, session);
    }

    response = { accepted: true, closed: true, commands };
    return persistMaybeDeleteSession(frame.runtime, session);
  });
  return response;
}

const app = {
  http(ctx) {
    if (ctx.path === "/" || ctx.path === "/meta") {
      return okJson({
        ok: true,
        app: "paseo-relay",
        dispatchKind: ctx.runtime.dispatchKind,
        endpoints: {
          health: "/health",
          healthz: "/healthz",
          state: "/state",
          websocket: "/ws?serverId=<id>&role=<server|client>&v=<1|2>&connectionId=<optional>",
        },
      });
    }
    if (ctx.path === "/health" || ctx.path === "/healthz") {
      return okJson({
        ok: true,
        app: "paseo-relay",
        dispatchKind: ctx.runtime.dispatchKind,
        uptimeMs: nowMs() - relayState().createdAt,
      });
    }
    if (ctx.path === "/state") {
      return okJson(sessionSnapshot(ctx.runtime));
    }
    return ctx.notFound({
      ok: false,
      error: "not_found",
      path: ctx.path,
    });
  },

  websocket(frame) {
    if (frame.event === "open") {
      return handleOpen(frame);
    }
    if (frame.event === "message" || frame.event === "info") {
      return handleMessage(frame);
    }
    if (frame.event === "close") {
      return handleClose(frame);
    }
    return { accepted: true, commands: [] };
  },

  snapshot(runtime) {
    return sessionSnapshot(runtime);
  },
};

export default app;
