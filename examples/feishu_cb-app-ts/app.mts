function json(value) {
  return JSON.stringify(value);
}

function pickFirstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return "";
}

function payloadJson(raw, fallbackValue = {}) {
  if (typeof raw !== "string" || raw.trim() === "") {
    return fallbackValue;
  }
  try {
    return JSON.parse(raw);
  } catch (_) {
    return fallbackValue;
  }
}

function env(name, fallbackValue = "") {
  const value = typeof process !== "undefined" && process?.env ? process.env[name] : "";
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallbackValue;
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

async function sha256Hex(text) {
  const encoder = new TextEncoder();
  const digest = await globalThis.crypto.subtle.digest("SHA-256", encoder.encode(text));
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("")
    .toLowerCase();
}

async function verifySignature(ctx, rawPayload, encryptKey) {
  const headers = ctx.headers || {};
  const signature = pickFirstString(headers["x-lark-signature"], headers["x-lark-request-signature"]).toLowerCase();
  if (!signature) {
    return !encryptKey;
  }
  const timestamp = pickFirstString(headers["x-lark-request-timestamp"]);
  const nonce = pickFirstString(headers["x-lark-request-nonce"]);
  if (!timestamp || !nonce || !encryptKey) {
    return false;
  }
  return (await sha256Hex(`${timestamp}${nonce}${encryptKey}${rawPayload}`)) === signature;
}

async function decryptPayloadIfNeeded(rawPayload, encryptKey) {
  if (!encryptKey) {
    return rawPayload;
  }
  const parsed = payloadJson(rawPayload, null);
  const encrypted = parsed && typeof parsed.encrypt === "string" ? parsed.encrypt.trim() : "";
  if (!encrypted) {
    return rawPayload;
  }
  const encoder = new TextEncoder();
  const keyHash = await globalThis.crypto.subtle.digest("SHA-256", encoder.encode(encryptKey));
  const keyBytes = new Uint8Array(keyHash);
  const iv = keyBytes.slice(0, 16);
  const aesKey = await globalThis.crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "AES-CBC" },
    false,
    ["decrypt"],
  );
  const cipherBytes = Uint8Array.from((globalThis.Buffer || Buffer).from(encrypted, "base64"));
  const decrypted = await globalThis.crypto.subtle.decrypt(
    { name: "AES-CBC", iv },
    aesKey,
    cipherBytes,
  );
  const plaintext = new Uint8Array(decrypted);
  const padding = plaintext[plaintext.length - 1];
  if (!padding || padding > 16 || padding > plaintext.length) {
    throw new Error("invalid_pkcs7_padding");
  }
  return new TextDecoder().decode(plaintext.subarray(0, plaintext.length - padding));
}

function parseActionPayload(rawPayload) {
  const payload = payloadJson(rawPayload, {});
  const header = payload.header || {};
  const event = payload.event || {};
  const context = payload.context || {};
  const rootAction = payload.action || {};
  const eventAction = event.action || {};
  const action = Object.keys(eventAction).length ? eventAction : rootAction;
  const operator = payload.operator || {};
  return {
    eventType: pickFirstString(header.event_type),
    eventId: pickFirstString(header.event_id),
    token: pickFirstString(payload.token, event.token),
    messageId: pickFirstString(event?.message?.message_id),
    openMessageId: pickFirstString(event.open_message_id, context.open_message_id, action.open_message_id),
    actionTag: typeof action.tag === "string" ? action.tag : "",
    actionValue: action && typeof action.value === "object" ? action.value : payloadJson(action?.value, {}),
    operatorId: pickFirstString(operator.open_id, operator.user_id, operator.union_id),
    raw: payload,
  };
}

function buildResponseCard(action, bridgeResult) {
  const lines = [
    "## Card Action Forwarded",
    "",
    `- eventType: \`${action.eventType || "unknown"}\``,
    `- eventId: \`${action.eventId || "unknown"}\``,
    `- openMessageId: \`${action.openMessageId || "unknown"}\``,
  ];
  if (action.actionValue && Object.keys(action.actionValue).length) {
    lines.push(`- actionValue: \`${JSON.stringify(action.actionValue)}\``);
  }
  if (bridgeResult?.status) {
    lines.push(`- bridgeStatus: \`${bridgeResult.status}\``);
  }
  return json({
    elements: [
      {
        tag: "markdown",
        content: lines.join("\n"),
      },
    ],
  });
}

async function forwardToBridge(ctx, action, rawPayload) {
  const appName = env("FEISHU_CB_APP", "main");
  const traceId = `${ctx.traceId || ctx.requestId || "feishu-cb"}::${action.eventId || "unknown"}`;
  ctx.runtime.log("feishu-cb bridge dispatch start", traceId, action.eventType || "", action.openMessageId || "");
  const result = ctx.runtime.bridgeDispatch({
    app: appName,
    trace_id: traceId,
    event_type: action.eventType || "card.action.trigger",
    message_id: action.messageId || "",
    target: action.openMessageId || "",
    target_type: action.openMessageId ? "open_message_id" : "",
    payload: rawPayload,
  }, null);
  ctx.runtime.log("feishu-cb bridge dispatch done", traceId, json(result || {}));
  if (!result || result.error) {
    return okJson({
      ok: false,
      error: result?.error || "bridge_dispatch_failed",
    }, 502);
  }
  return {
    status: typeof result.status === "number" && result.status > 0 ? result.status : 200,
    headers: typeof result.headers === "object" && result.headers ? result.headers : {
      "content-type": "application/json; charset=utf-8",
    },
    body: typeof result.body === "string" && result.body ? result.body : buildResponseCard(action, result),
  };
}

export async function http(ctx) {
  ctx.runtime.log("feishu-cb http", ctx.method || "", ctx.path || "", ctx.traceId || ctx.requestId || "");
  if (ctx.path === "/healthz") {
    return okJson({
      ok: true,
      app: "feishu_cb",
      dispatchKind: ctx.runtime.dispatchKind,
    });
  }

  if (ctx.path !== "/callbacks/feishu-card") {
    return ctx.notFound({
      ok: false,
      error: "not_found",
      path: ctx.path,
    });
  }

  const rawPayload = ctx.bodyText("");
  ctx.runtime.log("feishu-cb payload received", `bytes=${rawPayload.length}`);
  if (!rawPayload.trim()) {
    return okJson({
      ok: false,
      error: "empty_payload",
    }, 400);
  }
  const encryptKey = env("FEISHU_CB_ENCRYPT_KEY");
  const verificationToken = env("FEISHU_CB_VERIFICATION_TOKEN");

  if (!(await verifySignature(ctx, rawPayload, encryptKey))) {
    return okJson({
      ok: false,
      error: "invalid_signature",
    }, 403);
  }

  let payload;
  try {
    payload = await decryptPayloadIfNeeded(rawPayload, encryptKey);
  } catch (error) {
    return okJson({
      ok: false,
      error: "decrypt_failed",
      detail: String(error?.message || error),
    }, 400);
  }

  const challengePayload = payloadJson(payload, {});
  if (typeof challengePayload.challenge === "string" && challengePayload.challenge.trim() !== "") {
    return okJson({
      challenge: challengePayload.challenge.trim(),
    });
  }

  const action = parseActionPayload(payload);
  if ((action.eventType || "") !== "card.action.trigger") {
    return okJson({
      ok: false,
      error: "unsupported_event_type",
      eventType: action.eventType || "",
    }, 400);
  }
  if (verificationToken && action.token !== verificationToken) {
    return okJson({
      ok: false,
      error: "invalid_token",
    }, 403);
  }

  ctx.runtime.log("feishu-cb callback", action.eventType || "", json(action.actionValue || {}));
  return forwardToBridge(ctx, action, payload);
}

export async function websocket_upstream(frame) {
  if (frame.provider !== "feishu" || frame.eventType !== "card.action.trigger") {
    return {
      handled: false,
      commands: [],
    };
  }
  const action = parseActionPayload(frame.payloadText("{}"));
  frame.runtime.log("feishu-cb action", action.eventType || "", json(action.actionValue || {}));
  return {
    handled: true,
    commands: [],
    response: {
      status: 200,
      headers: {
        "content-type": "application/json; charset=utf-8",
      },
      body: buildResponseCard(action, null),
    },
  };
}

const app = {
  http,
  websocket_upstream,
};

export default app;
