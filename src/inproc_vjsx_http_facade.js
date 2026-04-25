globalThis.__vhttpd_create_runtime = function(meta) {
  meta = meta && typeof meta === "object" ? meta : {};
  const freezeValue = (value) => {
    try {
      return Object.freeze(value);
    } catch (_) {
      return value;
    }
  };
  try {
    const dispatchKind = typeof meta.dispatchKind === "string" && meta.dispatchKind ? meta.dispatchKind : "http";
    const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "http";
    const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
    const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : requestPath;
    const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
    const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
    const hostApi = globalThis.vhttpdHost && typeof globalThis.vhttpdHost === "object" ? globalThis.vhttpdHost : undefined;
    const hostEmit = hostApi && typeof hostApi.emit === "function"
      ? (...args) => hostApi.emit(...args)
      : undefined;
    const hostSnapshot = hostApi && typeof hostApi.snapshot === "function"
      ? (...args) => hostApi.snapshot(...args)
      : undefined;
    const hostSessionStore = hostApi && typeof hostApi.sessionStore === "function"
      ? (...args) => hostApi.sessionStore(...args)
      : undefined;
    const hostConfig = hostApi && typeof hostApi.config === "function"
      ? (...args) => hostApi.config(...args)
      : undefined;
    const hostReadFile = hostApi && typeof hostApi.readTextFile === "function"
      ? (...args) => hostApi.readTextFile(...args)
      : undefined;
    const hostFindCodexSession = hostApi && typeof hostApi.findCodexSessionPath === "function"
      ? (...args) => hostApi.findCodexSessionPath(...args)
      : undefined;
    const hostHttpFetch = hostApi && typeof hostApi.httpFetch === "function"
      ? (...args) => hostApi.httpFetch(...args)
      : undefined;
    const hostBridgeDispatch = hostApi && typeof hostApi.bridgeDispatch === "function"
      ? (...args) => hostApi.bridgeDispatch(...args)
      : undefined;
    const hostWebSocketDispatch = hostApi && typeof hostApi.websocketDispatch === "function"
      ? (...args) => hostApi.websocketDispatch(...args)
      : undefined;
    const capabilities = freezeValue({
      http: dispatchKind === "http",
      stream: false,
      websocket: dispatchKind === "websocket",
      websocketUpstream: dispatchKind === "websocket_upstream",
      fs: !!meta.enableFs,
      process: !!meta.enableProcess,
      network: !!meta.enableNetwork
    });
    const request = freezeValue({
      id: meta.requestId,
      traceId: meta.traceId,
      method: meta.method,
      path: requestPath,
      url: requestPath,
      target: requestTarget,
      href: requestHref,
      origin: requestOrigin,
      scheme: requestScheme,
      host: requestHost,
      port: requestPort,
      protocolVersion: meta.requestProtocolVersion,
      remoteAddr: meta.requestRemoteAddr,
      ip: meta.requestRemoteAddr,
      server: freezeValue(meta.requestServer || {})
    });
    const upstream = dispatchKind === "websocket_upstream"
      ? freezeValue({
          provider: typeof meta.upstreamProvider === "string" ? meta.upstreamProvider : "",
          instance: typeof meta.upstreamInstance === "string" ? meta.upstreamInstance : "",
          event: typeof meta.upstreamEvent === "string" ? meta.upstreamEvent : "message",
          eventType: typeof meta.upstreamEventType === "string" ? meta.upstreamEventType : "",
          messageId: typeof meta.upstreamMessageId === "string" ? meta.upstreamMessageId : "",
          target: typeof meta.upstreamTarget === "string" ? meta.upstreamTarget : "",
          targetType: typeof meta.upstreamTargetType === "string" ? meta.upstreamTargetType : "",
          receivedAt: typeof meta.upstreamReceivedAt === "number" ? meta.upstreamReceivedAt : 0,
          metadata: freezeValue(meta.upstreamMetadata || {})
        })
      : undefined;
    const runtime = {
      provider: meta.provider,
      executor: meta.executor,
      dispatchKind,
      laneId: meta.laneId,
      requestId: meta.requestId,
      traceId: meta.traceId,
      appEntry: meta.appEntry,
      moduleRoot: meta.moduleRoot,
      runtimeProfile: meta.runtimeProfile,
      threadCount: meta.threadCount,
      capabilities,
      request,
      upstream,
      method: meta.method,
      path: requestPath,
      now() {
        return Date.now();
      },
      log(...args) {
        if (typeof console !== "undefined" && console && typeof console.log === "function") {
          console.log("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        }
      },
      warn(...args) {
        if (typeof console !== "undefined" && console && typeof console.warn === "function") {
          console.warn("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      error(...args) {
        if (typeof console !== "undefined" && console && typeof console.error === "function") {
          console.error("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      emit(kind, fields) {
        if (typeof hostEmit !== "function") {
          return false;
        }
        const normalizedFields = {};
        if (fields && typeof fields === "object") {
          for (const [key, value] of Object.entries(fields)) {
            normalizedFields[String(key)] = value == null ? "" : String(value);
          }
        }
        return !!hostEmit(String(kind), normalizedFields);
      },
      snapshot(input = undefined, fallbackValue = undefined) {
        if (typeof hostSnapshot !== "function") {
          return fallbackValue;
        }
        const request = input && typeof input === "object" ? input : {};
        const raw = hostSnapshot(JSON.stringify({
          scope: typeof request.scope === "string" ? request.scope : "",
          kind: typeof request.kind === "string" ? request.kind : ""
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const snapshot = JSON.parse(String(raw));
          if (snapshot && typeof snapshot === "object") {
            return freezeValue(snapshot);
          }
          return snapshot;
        } catch (_) {
          return fallbackValue;
        }
      },
      sessionStore(namespace) {
        const ns = namespace == null ? "" : String(namespace).trim();
        const callStore = (payload, fallbackValue) => {
          if (typeof hostSessionStore !== "function" || !ns) {
            return fallbackValue;
          }
          const raw = hostSessionStore(JSON.stringify({
            namespace: ns,
            ...payload
          }));
          if (raw === undefined || raw === null || raw === "") {
            return fallbackValue;
          }
          try {
            return JSON.parse(String(raw));
          } catch (_) {
            return fallbackValue;
          }
        };
        return freezeValue({
          namespace: ns,
          get(key, fallbackValue = undefined) {
            const resp = callStore({
              op: "get",
              key: key == null ? "" : String(key)
            }, undefined);
            if (!resp || !resp.ok || !resp.found) {
              return fallbackValue;
            }
            try {
              return JSON.parse(String(resp.value));
            } catch (_) {
              return fallbackValue;
            }
          },
          set(key, value, options = undefined) {
            const ttlMs = options && typeof options === "object" && typeof options.ttlMs === "number"
              ? Math.max(0, Math.trunc(options.ttlMs))
              : 0;
            const resp = callStore({
              op: "set",
              key: key == null ? "" : String(key),
              value: JSON.stringify(value),
              ttl_ms: ttlMs
            }, undefined);
            return !!(resp && resp.ok);
          },
          patch(key, updater, fallbackValue = undefined, options = undefined) {
            if (typeof updater !== "function") {
              return fallbackValue;
            }
            const normalizedKey = key == null ? "" : String(key);
            const ttlMs = options && typeof options === "object" && typeof options.ttlMs === "number"
              ? Math.max(0, Math.trunc(options.ttlMs))
              : 0;
            const maxRetries = 8;
            for (let attempt = 0; attempt < maxRetries; attempt += 1) {
              const currentResp = callStore({
                op: "get",
                key: normalizedKey
              }, undefined);
              const found = !!(currentResp && currentResp.ok && currentResp.found);
              const currentRaw = found && typeof currentResp.value === "string" ? currentResp.value : "";
              let currentValue = fallbackValue;
              if (found) {
                try {
                  currentValue = JSON.parse(String(currentRaw));
                } catch (_) {
                  currentValue = fallbackValue;
                }
              }
              let draft = currentValue;
              let nextValue;
              try {
                nextValue = updater(draft);
              } catch (_) {
                return fallbackValue;
              }
              if (nextValue === undefined) {
                nextValue = draft;
              }
              const patchResp = callStore({
                op: "patch",
                key: normalizedKey,
                value: nextValue == null ? "" : JSON.stringify(nextValue),
                expected_found: found,
                expected_value: currentRaw,
                delete_value: nextValue == null,
                ttl_ms: ttlMs
              }, undefined);
              if (patchResp && patchResp.ok) {
                return nextValue;
              }
              if (!patchResp || !patchResp.conflict) {
                return fallbackValue;
              }
            }
            return fallbackValue;
          },
          delete(key) {
            const resp = callStore({
              op: "delete",
              key: key == null ? "" : String(key)
            }, undefined);
            return !!(resp && resp.ok);
          },
          exists(key) {
            const resp = callStore({
              op: "exists",
              key: key == null ? "" : String(key)
            }, undefined);
            return !!(resp && resp.ok && resp.found);
          },
          keys(fallbackValue = []) {
            const resp = callStore({
              op: "keys",
              key: ""
            }, undefined);
            if (!resp || !resp.ok || typeof resp.value !== "string" || !resp.value) {
              return fallbackValue;
            }
            try {
              const parsed = JSON.parse(String(resp.value));
              return Array.isArray(parsed) ? parsed : fallbackValue;
            } catch (_) {
              return fallbackValue;
            }
          }
        });
      },
      config(fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const raw = hostConfig("");
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      getConfig(path, fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const key = path == null ? "" : String(path);
        const raw = hostConfig(key);
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      readTextFile(path, fallbackValue = "") {
        if (!this.capabilities || !this.capabilities.fs || typeof hostReadFile !== "function") {
          return fallbackValue;
        }
        const raw = hostReadFile(path == null ? "" : String(path));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        return String(raw);
      },
      findCodexSessionPath(threadId, fallbackValue = "") {
        if (!this.capabilities || !this.capabilities.fs || typeof hostFindCodexSession !== "function") {
          return fallbackValue;
        }
        const raw = hostFindCodexSession(threadId == null ? "" : String(threadId));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        return String(raw);
      },
      httpFetch(input, fallbackValue = undefined) {
        if (!this.capabilities || !this.capabilities.network || typeof hostHttpFetch !== "function") {
          return fallbackValue;
        }
        const request = input && typeof input === "object" ? input : {};
        const raw = hostHttpFetch(JSON.stringify({
          url: typeof request.url === "string" ? request.url : "",
          method: typeof request.method === "string" ? request.method : "GET",
          body: request.body == null ? "" : String(request.body),
          headers: request.headers && typeof request.headers === "object" ? request.headers : {},
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      },
      bridgeDispatch(input, fallbackValue = undefined) {
        if (typeof hostBridgeDispatch !== "function") {
          return fallbackValue;
        }
        const request = input && typeof input === "object" ? input : {};
        const raw = hostBridgeDispatch(JSON.stringify({
          app: typeof request.app === "string" ? request.app : "",
          trace_id: typeof request.trace_id === "string" ? request.trace_id : "",
          event_type: typeof request.event_type === "string" ? request.event_type : "",
          message_id: typeof request.message_id === "string" ? request.message_id : "",
          target: typeof request.target === "string" ? request.target : "",
          target_type: typeof request.target_type === "string" ? request.target_type : "",
          payload: typeof request.payload === "string" ? request.payload : "",
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      },
      websocketDispatch(input, fallbackValue = undefined) {
        if (typeof hostWebSocketDispatch !== "function") {
          return fallbackValue;
        }
        let commands = [];
        if (Array.isArray(input)) {
          commands = input;
        } else if (input && typeof input === "object") {
          if (Array.isArray(input.commands)) {
            commands = input.commands;
          } else {
            commands = [input];
          }
        }
        const raw = hostWebSocketDispatch(JSON.stringify({
          commands: commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, {}))
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      },
      toJSON() {
        return {
          provider: this.provider,
          executor: this.executor,
          laneId: this.laneId,
          requestId: this.requestId,
          traceId: this.traceId,
          appEntry: this.appEntry,
          moduleRoot: this.moduleRoot,
          runtimeProfile: this.runtimeProfile,
          threadCount: this.threadCount,
          dispatchKind: this.dispatchKind,
          method: this.method,
          path: this.path
        };
      }
    };
    return freezeValue(runtime);
  } catch (err) {
    const errorMessage = err && typeof err === "object" && "stack" in err && err.stack
      ? String(err.stack)
      : String(err);
    if (typeof console !== "undefined" && console && typeof console.error === "function") {
      console.error("[vhttpd]", meta.laneId || "", meta.requestId || "", meta.traceId || "", "runtime facade create failed", errorMessage, JSON.stringify(meta));
    }
    const dispatchKind = typeof meta.dispatchKind === "string" && meta.dispatchKind ? meta.dispatchKind : "http";
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    return freezeValue({
      provider: typeof meta.provider === "string" ? meta.provider : "",
      executor: typeof meta.executor === "string" ? meta.executor : "",
      dispatchKind,
      laneId: typeof meta.laneId === "string" ? meta.laneId : "",
      requestId: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
      moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
      runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
      threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
      capabilities: freezeValue({
        http: dispatchKind === "http",
        stream: false,
        websocket: false,
        websocketUpstream: dispatchKind === "websocket_upstream",
        websocketDispatch: false,
        fs: !!meta.enableFs,
        process: !!meta.enableProcess,
        network: !!meta.enableNetwork
      }),
      request: freezeValue({
        id: typeof meta.requestId === "string" ? meta.requestId : "",
        traceId: typeof meta.traceId === "string" ? meta.traceId : "",
        method: typeof meta.method === "string" ? meta.method : "",
        path: requestPath,
        url: requestPath,
        target: typeof meta.requestTarget === "string" ? meta.requestTarget : requestPath,
        href: typeof meta.requestTarget === "string" ? meta.requestTarget : requestPath,
        origin: "",
        scheme: typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "http",
        host: typeof meta.requestHost === "string" ? meta.requestHost : "",
        port: typeof meta.requestPort === "string" ? meta.requestPort : "",
        protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
        remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        server: freezeValue(meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {})
      }),
      upstream: dispatchKind === "websocket_upstream"
        ? freezeValue({
            provider: typeof meta.upstreamProvider === "string" ? meta.upstreamProvider : "",
            instance: typeof meta.upstreamInstance === "string" ? meta.upstreamInstance : "",
            event: typeof meta.upstreamEvent === "string" ? meta.upstreamEvent : "message",
            eventType: typeof meta.upstreamEventType === "string" ? meta.upstreamEventType : "",
            messageId: typeof meta.upstreamMessageId === "string" ? meta.upstreamMessageId : "",
            target: typeof meta.upstreamTarget === "string" ? meta.upstreamTarget : "",
            targetType: typeof meta.upstreamTargetType === "string" ? meta.upstreamTargetType : "",
            receivedAt: typeof meta.upstreamReceivedAt === "number" ? meta.upstreamReceivedAt : 0,
            metadata: freezeValue(meta.upstreamMetadata && typeof meta.upstreamMetadata === "object" ? meta.upstreamMetadata : {})
          })
        : undefined,
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      runtimeInitError: errorMessage,
      now() {
        return Date.now();
      },
      log(...args) {
        if (typeof console !== "undefined" && console && typeof console.log === "function") {
          console.log("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        }
      },
      warn(...args) {
        if (typeof console !== "undefined" && console && typeof console.warn === "function") {
          console.warn("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      error(...args) {
        if (typeof console !== "undefined" && console && typeof console.error === "function") {
          console.error("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      emit() {
        return false;
      },
      snapshot(_input = undefined, fallbackValue = undefined) {
        return fallbackValue;
      },
      config(fallbackValue = undefined) {
        return fallbackValue;
      },
      getConfig(_path, fallbackValue = undefined) {
        return fallbackValue;
      },
      readTextFile(_path, fallbackValue = "") {
        return fallbackValue;
      },
      findCodexSessionPath(_threadId, fallbackValue = "") {
        return fallbackValue;
      },
      httpFetch(_input, fallbackValue = undefined) {
        return fallbackValue;
      },
      bridgeDispatch(_input, fallbackValue = undefined) {
        return fallbackValue;
      },
      websocketDispatch(_input, fallbackValue = undefined) {
        return fallbackValue;
      },
      toJSON() {
        return {
          provider: this.provider,
          executor: this.executor,
          laneId: this.laneId,
          requestId: this.requestId,
          traceId: this.traceId,
          dispatchKind: this.dispatchKind,
          method: this.method,
          path: this.path,
          runtimeInitError: this.runtimeInitError
        };
      }
    });
  }
};
globalThis.__vhttpd_create_ctx = function(req, runtime) {
  const response = { status: 200, headers: {}, body: "" };
  const target = typeof req.server?.url === "string" && req.server.url ? req.server.url : req.path;
  const scheme = typeof req.scheme === "string" && req.scheme ? req.scheme : "http";
  const host = typeof req.host === "string" ? req.host : "";
  const port = typeof req.port === "string" ? req.port : "";
  const origin = host ? scheme + "://" + host + (port ? ":" + port : "") : "";
  const href = origin ? origin + target : target;
  const normalizeMime = (raw) => {
    if (raw === undefined || raw === null) {
      return "";
    }
    return String(raw).split(";")[0].trim().toLowerCase();
  };
  const mimeMatches = (accepted, candidate) => {
    if (!accepted || !candidate) {
      return false;
    }
    if (accepted === "*/*" || candidate === "*/*") {
      return true;
    }
    if (accepted === candidate) {
      return true;
    }
    if (accepted.endsWith("/*")) {
      return candidate.startsWith(accepted.slice(0, accepted.length - 1));
    }
    if (candidate.endsWith("/*")) {
      return accepted.startsWith(candidate.slice(0, candidate.length - 1));
    }
    return false;
  };
  const parseAccepts = (raw) => {
    if (raw === undefined || raw === null || String(raw).trim() === "") {
      return [];
    }
    return String(raw)
      .split(",")
      .map((part) => normalizeMime(part))
      .filter(Boolean);
  };
  return {
    req: req,
    res: response,
    request: req,
    response,
    runtime,
    requestId: runtime.requestId,
    traceId: runtime.traceId,
    method: req.method,
    path: req.path,
    url: req.path,
    target,
    href,
    origin,
    scheme,
    host,
    port,
    protocolVersion: req.protocol_version,
    remoteAddr: req.remote_addr,
    ip: req.remote_addr,
    server: req.server,
    body: req.body,
    headers: req.headers,
    query: req.query,
    cookies: req.cookies,
    status(code) {
      if (typeof code === "number") response.status = code;
      return this;
    },
    code(code) {
      return this.status(code);
    },
    setHeader(name, value) {
      response.headers[String(name).toLowerCase()] = String(value);
      return this;
    },
    getHeader(name) {
      const key = String(name).toLowerCase();
      return response.headers[key] ?? req.headers[key];
    },
    hasHeader(name) {
      const key = String(name).toLowerCase();
      return Object.prototype.hasOwnProperty.call(response.headers, key) || Object.prototype.hasOwnProperty.call(req.headers, key);
    },
    removeHeader(name) {
      const key = String(name).toLowerCase();
      delete response.headers[key];
      return this;
    },
    header(name, value) {
      if (arguments.length >= 2) {
        return this.setHeader(name, value);
      }
      return this.getHeader(name);
    },
    type(contentType) {
      return this.setHeader("content-type", contentType);
    },
    queryParam(name, fallbackValue) {
      const key = String(name);
      return this.query[key] ?? fallbackValue;
    },
    queryInt(name, fallbackValue) {
      const raw = this.queryParam(name, undefined);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const parsed = Number.parseInt(String(raw), 10);
      return Number.isNaN(parsed) ? fallbackValue : parsed;
    },
    queryBool(name, fallbackValue) {
      const raw = this.queryParam(name, undefined);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const normalized = String(raw).trim().toLowerCase();
      if (["1", "true", "yes", "on"].includes(normalized)) {
        return true;
      }
      if (["0", "false", "no", "off"].includes(normalized)) {
        return false;
      }
      return fallbackValue;
    },
    cookie(name, fallbackValue) {
      const key = String(name);
      return this.cookies[key] ?? fallbackValue;
    },
    is(method) {
      return String(this.method).toUpperCase() === String(method).toUpperCase();
    },
    headerInt(name, fallbackValue) {
      const raw = this.getHeader(name);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const parsed = Number.parseInt(String(raw), 10);
      return Number.isNaN(parsed) ? fallbackValue : parsed;
    },
    headerBool(name, fallbackValue) {
      const raw = this.getHeader(name);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const normalized = String(raw).trim().toLowerCase();
      if (["1", "true", "yes", "on"].includes(normalized)) {
        return true;
      }
      if (["0", "false", "no", "off"].includes(normalized)) {
        return false;
      }
      return fallbackValue;
    },
    contentType() {
      return normalizeMime(req.headers["content-type"]);
    },
    accepts(...types) {
      const requestedTypes = types.length === 1 && Array.isArray(types[0]) ? types[0] : types;
      if (requestedTypes.length === 0) {
        return parseAccepts(this.getHeader("accept"));
      }
      const accepted = parseAccepts(this.getHeader("accept"));
      if (accepted.length === 0 || accepted.includes("*/*")) {
        return requestedTypes[0] ?? false;
      }
      for (const candidate of requestedTypes.map((value) => normalizeMime(value)).filter(Boolean)) {
        if (accepted.some((value) => mimeMatches(value, candidate))) {
          return candidate;
        }
      }
      return false;
    },
    isJson() {
      const mime = this.contentType();
      return mime === "application/json" || mime.endsWith("+json");
    },
    isHtml() {
      return this.contentType() === "text/html";
    },
    wantsJson() {
      return !!this.accepts("application/json", "application/*", "*/*");
    },
    wantsHtml() {
      return !!this.accepts("text/html", "application/xhtml+xml", "*/*");
    },
    bodyText(fallbackValue) {
      if (req.body == null) {
        return fallbackValue;
      }
      const text = String(req.body);
      return text === "" ? fallbackValue : text;
    },
    jsonBody(fallbackValue) {
      if (req.body == null || String(req.body).trim() === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(req.body));
      } catch (_) {
        return fallbackValue;
      }
    },
    text(body, status) {
      if (typeof status === "number") response.status = status;
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "text/plain; charset=utf-8";
      }
      response.body = body == null ? "" : String(body);
      return response;
    },
    json(value, status) {
      if (typeof status === "number") response.status = status;
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "application/json; charset=utf-8";
      }
      response.body = JSON.stringify(value);
      return response;
    },
    html(body, status) {
      if (typeof status === "number") response.status = status;
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "text/html; charset=utf-8";
      }
      response.body = body == null ? "" : String(body);
      return response;
    },
    send(body, status) {
      return this.text(body, status);
    },
    ok(value) {
      if (typeof value === "string") {
        return this.text(value, 200);
      }
      return this.json(value, 200);
    },
    created(value) {
      if (value === undefined) {
        response.status = 201;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 201);
      }
      return this.json(value, 201);
    },
    accepted(value) {
      if (value === undefined) {
        response.status = 202;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 202);
      }
      return this.json(value, 202);
    },
    noContent() {
      response.status = 204;
      delete response.headers["content-type"];
      response.body = "";
      return response;
    },
    badRequest(value) {
      if (value === undefined) {
        response.status = 400;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 400);
      }
      return this.json(value, 400);
    },
    unprocessableEntity(value) {
      if (value === undefined) {
        response.status = 422;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 422);
      }
      return this.json(value, 422);
    },
    notFound(value) {
      if (value === undefined) {
        response.status = 404;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 404);
      }
      return this.json(value, 404);
    },
    problem(status, title, detail, extra) {
      const problemStatus = typeof status === "number" ? status : 500;
      const problemTitle = title == null || String(title).trim() === "" ? "Error" : String(title);
      const payload = {
        status: problemStatus,
        title: problemTitle
      };
      if (detail !== undefined && detail !== null && String(detail) !== "") {
        payload.detail = String(detail);
      }
      if (extra && typeof extra === "object" && !Array.isArray(extra)) {
        for (const [key, value] of Object.entries(extra)) {
          if (key === "status" || key === "title" || key === "detail") {
            continue;
          }
          payload[String(key)] = value;
        }
      }
      response.status = problemStatus;
      response.headers["content-type"] = "application/problem+json; charset=utf-8";
      response.body = JSON.stringify(payload);
      return response;
    },
    redirect(location, status) {
      response.status = typeof status === "number" ? status : 302;
      response.headers["location"] = String(location);
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "text/plain; charset=utf-8";
      }
      response.body = "";
      return response;
    },
    reply(body, status) {
      return this.text(body, status);
    }
  };
};
globalThis.__vhttpd_create_websocket_runtime = function(meta) {
  meta = meta && typeof meta === "object" ? meta : {};
  const freezeValue = (value) => {
    try {
      return Object.freeze(value);
    } catch (_) {
      return value;
    }
  };
  try {
    const dispatchKind = "websocket";
    const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "ws";
    const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
    const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : requestPath;
    const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
    const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
    const hostApi = globalThis.vhttpdHost && typeof globalThis.vhttpdHost === "object" ? globalThis.vhttpdHost : undefined;
    const hostConfig = hostApi && typeof hostApi.config === "function"
      ? (...args) => hostApi.config(...args)
      : undefined;
    const hostWebSocketDispatch = hostApi && typeof hostApi.websocketDispatch === "function"
      ? (...args) => hostApi.websocketDispatch(...args)
      : undefined;
    const capabilities = freezeValue({
      http: false,
      stream: false,
      websocket: true,
      websocketUpstream: false,
      websocketDispatch: typeof hostWebSocketDispatch === "function",
      fs: !!meta.enableFs,
      process: !!meta.enableProcess,
      network: !!meta.enableNetwork
    });
    const request = freezeValue({
      id: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      url: requestPath,
      target: requestTarget,
      href: requestHref,
      origin: requestOrigin,
      scheme: requestScheme,
      host: requestHost,
      port: requestPort,
      protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
      remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      server: freezeValue(meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {})
    });
    const runtime = {
      provider: typeof meta.provider === "string" ? meta.provider : "",
      executor: typeof meta.executor === "string" ? meta.executor : "",
      dispatchKind,
      laneId: typeof meta.laneId === "string" ? meta.laneId : "",
      requestId: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
      moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
      runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
      threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
      capabilities,
      request,
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      now() {
        return Date.now();
      },
      log(...args) {
        if (typeof console !== "undefined" && console && typeof console.log === "function") {
          console.log("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        }
      },
      warn(...args) {
        if (typeof console !== "undefined" && console && typeof console.warn === "function") {
          console.warn("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      error(...args) {
        if (typeof console !== "undefined" && console && typeof console.error === "function") {
          console.error("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      config(fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const raw = hostConfig("");
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      getConfig(path, fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const key = path == null ? "" : String(path);
        const raw = hostConfig(key);
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      websocketDispatch(input, fallbackValue = undefined) {
        if (typeof hostWebSocketDispatch !== "function") {
          return fallbackValue;
        }
        let commands = [];
        if (Array.isArray(input)) {
          commands = input;
        } else if (input && typeof input === "object") {
          if (Array.isArray(input.commands)) {
            commands = input.commands;
          } else {
            commands = [input];
          }
        }
        const raw = hostWebSocketDispatch(JSON.stringify({
          commands: commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, {}))
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      },
      toJSON() {
        return {
          provider: this.provider,
          executor: this.executor,
          laneId: this.laneId,
          requestId: this.requestId,
          traceId: this.traceId,
          appEntry: this.appEntry,
          moduleRoot: this.moduleRoot,
          runtimeProfile: this.runtimeProfile,
          threadCount: this.threadCount,
          dispatchKind: this.dispatchKind,
          method: this.method,
          path: this.path
        };
      }
    };
    return freezeValue(runtime);
  } catch (err) {
    const errorMessage = err && typeof err === "object" && "stack" in err && err.stack
      ? String(err.stack)
      : String(err);
    if (typeof console !== "undefined" && console && typeof console.error === "function") {
      console.error("[vhttpd]", meta.laneId || "", meta.requestId || "", meta.traceId || "", "websocket runtime facade create failed", errorMessage, JSON.stringify(meta));
    }
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    return freezeValue({
      provider: typeof meta.provider === "string" ? meta.provider : "",
      executor: typeof meta.executor === "string" ? meta.executor : "",
      dispatchKind: "websocket",
      laneId: typeof meta.laneId === "string" ? meta.laneId : "",
      requestId: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
      moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
      runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
      threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
      capabilities: freezeValue({
        http: false,
        stream: false,
        websocket: true,
        websocketUpstream: false,
        websocketDispatch: false,
        fs: false,
        process: false,
        network: false
      }),
      request: freezeValue({
        id: typeof meta.requestId === "string" ? meta.requestId : "",
        traceId: typeof meta.traceId === "string" ? meta.traceId : "",
        method: typeof meta.method === "string" ? meta.method : "",
        path: requestPath,
        url: requestPath,
        target: typeof meta.requestTarget === "string" ? meta.requestTarget : requestPath,
        href: typeof meta.requestTarget === "string" ? meta.requestTarget : requestPath,
        origin: "",
        scheme: typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "ws",
        host: typeof meta.requestHost === "string" ? meta.requestHost : "",
        port: typeof meta.requestPort === "string" ? meta.requestPort : "",
        protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
        remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        server: freezeValue(meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {})
      }),
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      runtimeInitError: errorMessage,
      now() {
        return Date.now();
      },
      log(...args) {
        if (typeof console !== "undefined" && console && typeof console.log === "function") {
          console.log("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        }
      },
      warn(...args) {
        if (typeof console !== "undefined" && console && typeof console.warn === "function") {
          console.warn("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      error(...args) {
        if (typeof console !== "undefined" && console && typeof console.error === "function") {
          console.error("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
        } else {
          this.log(...args);
        }
      },
      config(_fallbackValue = undefined) {
        return _fallbackValue;
      },
      getConfig(_path, fallbackValue = undefined) {
        return fallbackValue;
      },
      websocketDispatch(_input, fallbackValue = undefined) {
        return fallbackValue;
      }
    });
  }
};
globalThis.__vhttpd_create_websocket_upstream_frame = function(raw, runtime) {
  raw = raw && typeof raw === "object" ? raw : {};
  runtime = runtime && typeof runtime === "object" ? runtime : {};
  const frame = {
    mode: typeof raw.mode === "string" && raw.mode ? raw.mode : "websocket_upstream",
    event: typeof raw.event === "string" && raw.event ? raw.event : "message",
    id: typeof raw.id === "string" ? raw.id : runtime.requestId,
    provider: typeof raw.provider === "string" ? raw.provider : (runtime.upstream?.provider || ""),
    instance: typeof raw.instance === "string" ? raw.instance : (runtime.upstream?.instance || ""),
    traceId: typeof raw.trace_id === "string" ? raw.trace_id : runtime.traceId,
    eventType: typeof raw.event_type === "string" ? raw.event_type : (runtime.upstream?.eventType || ""),
    messageId: typeof raw.message_id === "string" ? raw.message_id : (runtime.upstream?.messageId || ""),
    target: typeof raw.target === "string" ? raw.target : (runtime.upstream?.target || ""),
    targetType: typeof raw.target_type === "string" ? raw.target_type : (runtime.upstream?.targetType || ""),
    payload: raw.payload == null ? "" : String(raw.payload),
    receivedAt: typeof raw.received_at === "number" ? raw.received_at : (runtime.upstream?.receivedAt || 0),
    metadata: raw.metadata && typeof raw.metadata === "object" ? Object.freeze(raw.metadata) : Object.freeze({}),
    runtime,
    payloadText(fallbackValue) {
      if (this.payload === "") {
        return fallbackValue;
      }
      return this.payload;
    },
    payloadJson(fallbackValue) {
      if (this.payload == null || String(this.payload).trim() === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(this.payload));
      } catch (_) {
        return fallbackValue;
      }
    }
  };
  return Object.freeze(frame);
};
globalThis.__vhttpd_create_websocket_frame = function(bundle) {
  bundle = bundle && typeof bundle === "object" ? bundle : {};
  const raw = bundle.raw && typeof bundle.raw === "object" ? bundle.raw : {};
  const meta = bundle.runtime && typeof bundle.runtime === "object" ? bundle.runtime : {};
  const hostApi = globalThis.vhttpdHost && typeof globalThis.vhttpdHost === "object" ? globalThis.vhttpdHost : undefined;
  const hostConfig = hostApi && typeof hostApi.config === "function"
    ? (...args) => hostApi.config(...args)
    : undefined;
  const hostSessionStore = hostApi && typeof hostApi.sessionStore === "function"
    ? (...args) => hostApi.sessionStore(...args)
    : undefined;
  const hostWebSocketDispatch = hostApi && typeof hostApi.websocketDispatch === "function"
    ? (...args) => hostApi.websocketDispatch(...args)
    : undefined;
  const requestPath = typeof meta.path === "string" ? meta.path : "";
  const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : requestPath;
  const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "ws";
  const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
  const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
  const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
  const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
  const runtime = {
    provider: typeof meta.provider === "string" ? meta.provider : "",
    executor: typeof meta.executor === "string" ? meta.executor : "",
    dispatchKind: "websocket",
    laneId: typeof meta.laneId === "string" ? meta.laneId : "",
    requestId: typeof meta.requestId === "string" ? meta.requestId : "",
    traceId: typeof meta.traceId === "string" ? meta.traceId : "",
    appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
    moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
    runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
    threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
    capabilities: {
      http: false,
      stream: false,
      websocket: true,
      websocketUpstream: false,
      websocketDispatch: typeof hostWebSocketDispatch === "function",
      fs: !!meta.enableFs,
      process: !!meta.enableProcess,
      network: !!meta.enableNetwork
    },
    request: {
      id: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      url: requestPath,
      target: requestTarget,
      href: requestHref,
      origin: requestOrigin,
      scheme: requestScheme,
      host: requestHost,
      port: requestPort,
      protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
      remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      server: meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {}
    },
    method: typeof meta.method === "string" ? meta.method : "",
    path: requestPath,
    now() {
      return Date.now();
    },
    log(...args) {
      if (typeof console !== "undefined" && console && typeof console.log === "function") {
        console.log("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
      }
    },
    warn(...args) {
      if (typeof console !== "undefined" && console && typeof console.warn === "function") {
        console.warn("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
      } else {
        this.log(...args);
      }
    },
    error(...args) {
      if (typeof console !== "undefined" && console && typeof console.error === "function") {
        console.error("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
      } else {
        this.log(...args);
      }
    },
    config(fallbackValue = undefined) {
      if (typeof hostConfig !== "function") {
        return fallbackValue;
      }
      const rawConfig = hostConfig("");
      if (rawConfig === undefined || rawConfig === null || rawConfig === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(rawConfig));
      } catch (_) {
        return fallbackValue;
      }
    },
    getConfig(path, fallbackValue = undefined) {
      if (typeof hostConfig !== "function") {
        return fallbackValue;
      }
      const key = path == null ? "" : String(path);
      const rawConfig = hostConfig(key);
      if (rawConfig === undefined || rawConfig === null || rawConfig === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(rawConfig));
      } catch (_) {
        return fallbackValue;
      }
    },
    sessionStore(namespace) {
      const ns = namespace == null ? "" : String(namespace).trim();
      const callStore = (payload, fallbackValue) => {
        if (typeof hostSessionStore !== "function" || !ns) {
          return fallbackValue;
        }
        const raw = hostSessionStore(JSON.stringify({
          namespace: ns,
          ...payload
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      };
      return {
        namespace: ns,
        get(key, fallbackValue = undefined) {
          const resp = callStore({
            op: "get",
            key: key == null ? "" : String(key)
          }, undefined);
          if (!resp || !resp.ok || !resp.found) {
            return fallbackValue;
          }
          try {
            return JSON.parse(String(resp.value));
          } catch (_) {
            return fallbackValue;
          }
        },
        set(key, value, options = undefined) {
          const ttlMs = options && typeof options === "object" && typeof options.ttlMs === "number"
            ? Math.max(0, Math.trunc(options.ttlMs))
            : 0;
          const resp = callStore({
            op: "set",
            key: key == null ? "" : String(key),
            value: JSON.stringify(value),
            ttl_ms: ttlMs
          }, undefined);
          return !!(resp && resp.ok);
        },
        delete(key) {
          const resp = callStore({
            op: "delete",
            key: key == null ? "" : String(key)
          }, undefined);
          return !!(resp && resp.ok);
        }
      };
    },
    websocketDispatch(input, fallbackValue = undefined) {
      if (typeof hostWebSocketDispatch !== "function") {
        return fallbackValue;
      }
      let commands = [];
      if (Array.isArray(input)) {
        commands = input;
      } else if (input && typeof input === "object") {
        if (Array.isArray(input.commands)) {
          commands = input.commands;
        } else {
          commands = [input];
        }
      }
      const rawResult = hostWebSocketDispatch(JSON.stringify({
        commands: commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, {}))
      }));
      if (rawResult === undefined || rawResult === null || rawResult === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(rawResult));
      } catch (_) {
        return fallbackValue;
      }
    }
  };
  const frame = {
    mode: typeof raw.mode === "string" && raw.mode ? raw.mode : "websocket_dispatch",
    event: typeof raw.event === "string" && raw.event ? raw.event : "message",
    id: typeof raw.id === "string" ? raw.id : runtime.requestId,
    path: typeof raw.path === "string" ? raw.path : runtime.path,
    query: raw.query && typeof raw.query === "object" ? raw.query : {},
    headers: raw.headers && typeof raw.headers === "object" ? raw.headers : {},
    remoteAddr: typeof raw.remote_addr === "string" ? raw.remote_addr : (runtime.request?.remoteAddr || ""),
    requestId: typeof raw.request_id === "string" ? raw.request_id : runtime.requestId,
    traceId: typeof raw.trace_id === "string" ? raw.trace_id : runtime.traceId,
    targetId: typeof raw.target_id === "string" ? raw.target_id : "",
    room: typeof raw.room === "string" ? raw.room : "",
    key: typeof raw.key === "string" ? raw.key : "",
    value: typeof raw.value === "string" ? raw.value : "",
    exceptId: typeof raw.except_id === "string" ? raw.except_id : "",
    rooms: Array.isArray(raw.rooms) ? raw.rooms.slice() : [],
    metadata: raw.metadata && typeof raw.metadata === "object" ? raw.metadata : {},
    roomMembers: raw.room_members && typeof raw.room_members === "object" ? raw.room_members : {},
    memberMetadata: raw.member_metadata && typeof raw.member_metadata === "object" ? raw.member_metadata : {},
    roomCounts: raw.room_counts && typeof raw.room_counts === "object" ? raw.room_counts : {},
    presenceUsers: raw.presence_users && typeof raw.presence_users === "object" ? raw.presence_users : {},
    status: typeof raw.status === "number" ? raw.status : 0,
    code: typeof raw.code === "number" ? raw.code : 0,
    reason: typeof raw.reason === "string" ? raw.reason : "",
    opcode: typeof raw.opcode === "string" ? raw.opcode : "",
    data: raw.data == null ? "" : String(raw.data),
    error: typeof raw.error === "string" ? raw.error : "",
    errorClass: typeof raw.error_class === "string" ? raw.error_class : "",
    runtime,
    dataText(fallbackValue) {
      if (this.opcode === "binary") {
        return fallbackValue;
      }
      if (this.data === "") {
        return fallbackValue;
      }
      return this.data;
    },
    dataBase64(fallbackValue) {
      if (this.opcode !== "binary") {
        return fallbackValue;
      }
      if (this.data === "") {
        return fallbackValue;
      }
      return this.data;
    },
    dataJson(fallbackValue) {
      if (this.opcode === "binary") {
        return fallbackValue;
      }
      if (this.data == null || String(this.data).trim() === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(this.data));
      } catch (_) {
        return fallbackValue;
      }
    }
  };
  return frame;
};
globalThis.__vhttpd_normalize_result = function(ctx, result) {
  if (result === undefined || result === null) {
    return ctx.response;
  }
  return result;
};
globalThis.__vhttpd_normalize_startup_result = function(result) {
  if (result === undefined || result === null || result === false || result === true) {
    return { commands: [] };
  }
  if (Array.isArray(result)) {
    return { commands: result };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid startup result type");
  }
  return {
    commands: Array.isArray(result.commands) ? result.commands : []
  };
};
globalThis.__vhttpd_bind_method = function(target, key) {
  if (!target || (typeof target !== "object" && typeof target !== "function")) {
    return undefined;
  }
  const value = target[key];
  if (typeof value !== "function") {
    return undefined;
  }
  return typeof value.bind === "function" ? value.bind(target) : value;
};
globalThis.__vhttpd_resolve_handler_for_kind = function(exportsValue, kind) {
  const httpAliases = ["http", "handle", "handleHttp", "handle_http"];
  const websocketAliases = ["websocket", "handleWebSocket", "handle_websocket"];
  const upstreamAliases = ["websocket_upstream", "websocketUpstream", "handleWebSocketUpstream", "handle_websocket_upstream"];
  const aliases = kind === "websocket"
    ? websocketAliases
    : kind === "websocket_upstream"
      ? upstreamAliases
      : httpAliases;
  if (exportsValue && typeof exportsValue === "object") {
    if (kind === "http" || kind === "websocket") {
      if (typeof exportsValue.default === "function") {
        return exportsValue.default;
      }
      if (kind === "http" && typeof exportsValue.handle === "function") {
        return exportsValue.handle;
      }
      if (kind === "websocket" && typeof exportsValue.websocket === "function") {
        return exportsValue.websocket;
      }
    } else {
      for (const key of upstreamAliases) {
        if (typeof exportsValue[key] === "function") {
          return exportsValue[key];
        }
      }
    }
    for (const key of aliases) {
      const boundExport = globalThis.__vhttpd_bind_method(exportsValue, key);
      if (typeof boundExport === "function") {
        return boundExport;
      }
    }
    const defaultExport = exportsValue.default;
    if (defaultExport && (typeof defaultExport === "object" || typeof defaultExport === "function")) {
      for (const key of aliases) {
        const boundDefault = globalThis.__vhttpd_bind_method(defaultExport, key);
        if (typeof boundDefault === "function") {
          return boundDefault;
        }
      }
    }
  }
  if (kind === "http" && typeof globalThis.__vhttpd_handle === "function") {
    return globalThis.__vhttpd_handle;
  }
  if (kind === "websocket" && typeof globalThis.__vhttpd_websocket_handle === "function") {
    return globalThis.__vhttpd_websocket_handle;
  }
  if (kind === "websocket_upstream" && typeof globalThis.__vhttpd_websocket_upstream_handle === "function") {
    return globalThis.__vhttpd_websocket_upstream_handle;
  }
  return undefined;
};
globalThis.__vhttpd_resolve_handler = function(exportsValue) {
  return globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "http");
};
globalThis.__vhttpd_resolve_hook_for_kind = function(exportsValue, kind) {
  const startupAliases = ["startup", "lane_startup", "laneStartup"];
  const appStartupAliases = ["app_startup", "appStartup"];
  const snapshotAliases = ["snapshot", "lane_snapshot", "laneSnapshot"];
  const websocketAffinityAliases = ["websocket_affinity", "websocketAffinity", "getWebSocketAffinity", "get_websocket_affinity"];
  const websocketActorAliases = ["websocket_actor", "websocketActor", "getWebSocketActor", "get_websocket_actor"];
  const aliases = kind === "app_startup"
    ? appStartupAliases
    : kind === "snapshot"
      ? snapshotAliases
      : kind === "websocket_affinity"
        ? websocketAffinityAliases
      : kind === "websocket_actor"
        ? websocketActorAliases
      : startupAliases;
  if (exportsValue && typeof exportsValue === "object") {
    for (const key of aliases) {
      if (typeof exportsValue[key] === "function") {
        return exportsValue[key];
      }
    }
    for (const key of aliases) {
      const boundExport = globalThis.__vhttpd_bind_method(exportsValue, key);
      if (typeof boundExport === "function") {
        return boundExport;
      }
    }
    const defaultExport = exportsValue.default;
    if (defaultExport && (typeof defaultExport === "object" || typeof defaultExport === "function")) {
      for (const key of aliases) {
        const boundDefault = globalThis.__vhttpd_bind_method(defaultExport, key);
        if (typeof boundDefault === "function") {
          return boundDefault;
        }
      }
    }
  }
  if (kind === "startup" && typeof globalThis.__vhttpd_startup_handle === "function") {
    return globalThis.__vhttpd_startup_handle;
  }
  if (kind === "app_startup" && typeof globalThis.__vhttpd_app_startup_handle === "function") {
    return globalThis.__vhttpd_app_startup_handle;
  }
  if (kind === "snapshot" && typeof globalThis.__vhttpd_snapshot_handle === "function") {
    return globalThis.__vhttpd_snapshot_handle;
  }
  if (kind === "websocket_affinity" && typeof globalThis.__vhttpd_websocket_affinity_handle === "function") {
    return globalThis.__vhttpd_websocket_affinity_handle;
  }
  if (kind === "websocket_actor" && typeof globalThis.__vhttpd_websocket_actor_handle === "function") {
    return globalThis.__vhttpd_websocket_actor_handle;
  }
  return undefined;
};
globalThis.__vhttpd_bind_handler = function(exportsValue) {
  const handler = globalThis.__vhttpd_resolve_handler(exportsValue);
  if (typeof handler === "function") {
    globalThis.__vhttpd_handle = handler;
  }
  return handler;
};
globalThis.__vhttpd_wrap_handler = function(kind, handler) {
  if (typeof handler !== "function") {
    return handler;
  }
  if (kind !== "websocket" && kind !== "websocket_upstream") {
    return handler;
  }
  return function(...args) {
    try {
      return handler(...args);
    } catch (error) {
      const rendered = error && typeof error === "object" && typeof error.stack === "string" && error.stack
        ? error.stack
        : error && typeof error === "object" && typeof error.message === "string" && error.message
          ? error.message
          : String(error);
      if (typeof console !== "undefined" && console && typeof console.error === "function") {
        console.error("[vhttpd] " + kind + " handler error", rendered);
      }
      throw error;
    }
  };
};
globalThis.__vhttpd_invoke_wrapped_handler = function(kind, handler, arg) {
  if (typeof handler !== "function") {
    throw new TypeError("handler is not a function");
  }
  try {
    const result = handler(arg);
    if (result && typeof result.then === "function") {
      return Promise.resolve(result).catch((error) => {
        const rendered = error && typeof error === "object" && typeof error.stack === "string" && error.stack
          ? error.stack
          : error && typeof error === "object" && typeof error.message === "string" && error.message
            ? error.message
            : String(error);
        let detailed = rendered;
        try {
          if (error && typeof error === "object") {
            detailed += "\nJSON: " + JSON.stringify(error);
          }
        } catch (e) {}
        if (typeof console !== "undefined" && console && typeof console.error === "function") {
          console.error("[vhttpd] " + kind + " handler error", detailed);
        }
        if (error && typeof error === "object" && !error.message && !error.stack) {
            error.message = rendered || "Unknown error";
        }
        throw error;
      });
    }
    return result;
  } catch (error) {
    const rendered = error && typeof error === "object" && typeof error.stack === "string" && error.stack
      ? error.stack
      : error && typeof error === "object" && typeof error.message === "string" && error.message
        ? error.message
        : String(error);
    let detailed = rendered;
    try {
      if (error && typeof error === "object") {
        detailed += "\nJSON: " + JSON.stringify(error);
      }
    } catch (e) {}
    if (typeof console !== "undefined" && console && typeof console.error === "function") {
      console.error("[vhttpd] " + kind + " handler error", detailed);
    }
    if (error && typeof error === "object" && !error.message && !error.stack) {
        error.message = rendered || "Unknown error";
    }
    throw error;
  }
};
globalThis.__vhttpd_invoke_websocket_handle = function(frame) {
  const handler = globalThis.__vhttpd_websocket_handle;
  return globalThis.__vhttpd_invoke_wrapped_handler("websocket", handler, frame);
};
globalThis.__vhttpd_bind_handlers = function(exportsValue) {
  const httpHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "http");
  const websocketHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "websocket");
  const websocketUpstreamHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "websocket_upstream");
  const startupHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "startup");
  const appStartupHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "app_startup");
  const snapshotHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "snapshot");
  const websocketAffinityHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "websocket_affinity");
  const websocketActorHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "websocket_actor");
  if (typeof httpHandler === "function") {
    globalThis.__vhttpd_handle = httpHandler;
  }
  if (typeof websocketHandler === "function") {
    globalThis.__vhttpd_websocket_handle = globalThis.__vhttpd_wrap_handler("websocket", websocketHandler);
  }
  if (typeof websocketUpstreamHandler === "function") {
    globalThis.__vhttpd_websocket_upstream_handle = globalThis.__vhttpd_wrap_handler("websocket_upstream", websocketUpstreamHandler);
  }
  if (typeof startupHandler === "function") {
    globalThis.__vhttpd_startup_handle = startupHandler;
  }
  if (typeof appStartupHandler === "function") {
    globalThis.__vhttpd_app_startup_handle = appStartupHandler;
  }
  if (typeof snapshotHandler === "function") {
    globalThis.__vhttpd_snapshot_handle = snapshotHandler;
  }
  if (typeof websocketAffinityHandler === "function") {
    globalThis.__vhttpd_websocket_affinity_handle = websocketAffinityHandler;
  }
  if (typeof websocketActorHandler === "function") {
    globalThis.__vhttpd_websocket_actor_handle = websocketActorHandler;
  }
  return {
    http: httpHandler,
    websocket: websocketHandler,
    websocket_upstream: websocketUpstreamHandler,
    startup: startupHandler,
    app_startup: appStartupHandler,
    snapshot: snapshotHandler,
    websocket_affinity: websocketAffinityHandler,
    websocket_actor: websocketActorHandler
  };
};
globalThis.__vhttpd_register_exports = function(exportsValue) {
  if (!exportsValue || typeof exportsValue !== "object") {
    return globalThis.__vhttpd_bind_handlers(undefined);
  }
  return globalThis.__vhttpd_bind_handlers(exportsValue);
};
globalThis.__vhttpd_normalize_websocket_command = function(command, frame) {
  const raw = command && typeof command === "object" ? command : {};
  const source = frame && typeof frame === "object" ? frame : {};
  return {
    mode: typeof raw.mode === "string" && raw.mode ? raw.mode : "websocket_dispatch",
    event: typeof raw.event === "string" ? raw.event : "",
    id: typeof raw.id === "string" && raw.id ? raw.id : (typeof source.id === "string" ? source.id : ""),
    path: typeof raw.path === "string" ? raw.path : (typeof source.path === "string" ? source.path : ""),
    query: raw.query && typeof raw.query === "object" && !Array.isArray(raw.query) ? raw.query : {},
    headers: raw.headers && typeof raw.headers === "object" && !Array.isArray(raw.headers) ? raw.headers : {},
    remote_addr: typeof raw.remote_addr === "string" ? raw.remote_addr : "",
    request_id: typeof raw.request_id === "string" ? raw.request_id : (typeof source.requestId === "string" ? source.requestId : ""),
    trace_id: typeof raw.trace_id === "string" ? raw.trace_id : (typeof source.traceId === "string" ? source.traceId : ""),
    target_id: typeof raw.target_id === "string"
      ? raw.target_id
      : typeof raw.targetId === "string"
        ? raw.targetId
        : "",
    room: typeof raw.room === "string" ? raw.room : "",
    key: typeof raw.key === "string" ? raw.key : "",
    value: typeof raw.value === "string" ? raw.value : "",
    except_id: typeof raw.except_id === "string"
      ? raw.except_id
      : typeof raw.exceptId === "string"
        ? raw.exceptId
        : "",
    rooms: Array.isArray(raw.rooms) ? raw.rooms : [],
    metadata: raw.metadata && typeof raw.metadata === "object" && !Array.isArray(raw.metadata) ? raw.metadata : {},
    room_members: raw.room_members && typeof raw.room_members === "object" && !Array.isArray(raw.room_members) ? raw.room_members : {},
    member_metadata: raw.member_metadata && typeof raw.member_metadata === "object" && !Array.isArray(raw.member_metadata) ? raw.member_metadata : {},
    room_counts: raw.room_counts && typeof raw.room_counts === "object" && !Array.isArray(raw.room_counts) ? raw.room_counts : {},
    presence_users: raw.presence_users && typeof raw.presence_users === "object" && !Array.isArray(raw.presence_users) ? raw.presence_users : {},
    status: typeof raw.status === "number" ? raw.status : 0,
    code: typeof raw.code === "number" ? raw.code : 0,
    reason: typeof raw.reason === "string" ? raw.reason : "",
    opcode: typeof raw.opcode === "string" ? raw.opcode : "text",
    data: raw.data == null ? "" : String(raw.data),
    error: typeof raw.error === "string" ? raw.error : "",
    error_class: typeof raw.error_class === "string"
      ? raw.error_class
      : typeof raw.errorClass === "string"
        ? raw.errorClass
        : ""
  };
};
globalThis.__vhttpd_normalize_websocket_result = function(frame, result) {
  if (result === undefined || result === null || result === false) {
    return {
      accepted: false,
      closed: false,
      commands: [],
      affinity_key: "",
      error: "",
      error_class: ""
    };
  }
  if (result === true) {
    return {
      accepted: true,
      closed: false,
      commands: [],
      affinity_key: "",
      error: "",
      error_class: ""
    };
  }
  if (Array.isArray(result)) {
    return {
      accepted: true,
      closed: false,
      commands: result.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, frame)),
      affinity_key: "",
      error: "",
      error_class: ""
    };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid websocket result type");
  }
  const commands = Array.isArray(result.commands)
    ? result.commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, frame))
    : [];
  return {
    accepted: Object.prototype.hasOwnProperty.call(result, "accepted") ? !!result.accepted : true,
    closed: !!result.closed,
    commands,
    affinity_key: typeof result.affinity_key === "string"
      ? result.affinity_key
      : typeof result.affinityKey === "string"
        ? result.affinityKey
        : "",
    error: typeof result.error === "string" ? result.error : "",
    error_class: typeof result.error_class === "string"
      ? result.error_class
      : typeof result.errorClass === "string"
        ? result.errorClass
        : ""
  };
};
globalThis.__vhttpd_normalize_websocket_upstream_result = function(frame, result) {
  if (result === undefined || result === null || result === false) {
    return {
      handled: false,
      commands: [],
      response: { status: 200, headers: {}, body: "" }
    };
  }
  if (result === true) {
    return {
      handled: true,
      commands: [],
      response: { status: 200, headers: {}, body: "" }
    };
  }
  if (Array.isArray(result)) {
    return {
      handled: true,
      commands: result,
      response: { status: 200, headers: {}, body: "" }
    };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid websocket_upstream result type");
  }
  const response = result.response && typeof result.response === "object" ? result.response : {};
  return {
    handled: Object.prototype.hasOwnProperty.call(result, "handled") ? !!result.handled : true,
    commands: Array.isArray(result.commands) ? result.commands : [],
    response: {
      status: typeof response.status === "number" ? response.status : 200,
      headers: response.headers && typeof response.headers === "object" && !Array.isArray(response.headers) ? response.headers : {},
      body: response.body == null ? "" : String(response.body)
    }
  };
};
