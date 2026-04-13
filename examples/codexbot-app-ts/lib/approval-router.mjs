import { parseCodexServerRequest } from "./codex.mts";

function json(value) {
  return JSON.stringify(value);
}

function trimText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function humanMethodLabel(method) {
  switch (method) {
    case "item/commandExecution/requestApproval":
      return "命令执行审批";
    case "item/fileChange/requestApproval":
      return "文件变更审批";
    case "item/permissions/requestApproval":
      return "权限申请审批";
    default:
      return "审批请求";
  }
}

function approvalTitle(request) {
  return `## ${humanMethodLabel(request.method)}`;
}

function approvalReason(request) {
  return trimText(request?.params?.reason) || "Codex 请求用户确认后继续执行。";
}

function approvalCommandText(request) {
  const command = trimText(request?.params?.command);
  if (command) {
    return command;
  }
  const actions = Array.isArray(request?.params?.commandActions) ? request.params.commandActions : [];
  const labels = actions
    .map((entry) => trimText(entry?.label || entry?.action || entry?.kind))
    .filter(Boolean);
  return labels.join(", ");
}

function approvalDetailsLines(request, parentStream) {
  const lines = [
    approvalTitle(request),
    "",
    approvalReason(request),
  ];
  if (request.method === "item/commandExecution/requestApproval") {
    const command = approvalCommandText(request);
    if (command) {
      lines.push("", `- 命令: \`${command}\``);
    }
    const cwd = trimText(request?.params?.cwd) || trimText(parentStream?.cwd);
    if (cwd) {
      lines.push(`- 目录: \`${cwd}\``);
    }
  }
  if (request.method === "item/fileChange/requestApproval") {
    const grantRoot = trimText(request?.params?.grantRoot);
    if (grantRoot) {
      lines.push("", `- 授权根目录: \`${grantRoot}\``);
    }
  }
  if (request.method === "item/permissions/requestApproval") {
    const permissions = request?.params?.permissions || {};
    lines.push("", `- 权限: \`${json(permissions)}\``);
  }
  if (request.threadId) {
    lines.push("", `- Thread: \`${request.threadId}\``);
  }
  if (request.turnId) {
    lines.push(`- Turn: \`${request.turnId}\``);
  }
  return lines.join("\n");
}

function decisionKind(decision) {
  if (typeof decision === "string") {
    return decision;
  }
  if (isPlainObject(decision)) {
    if (isPlainObject(decision.acceptWithExecpolicyAmendment)) {
      return "acceptWithExecpolicyAmendment";
    }
    if (isPlainObject(decision.applyNetworkPolicyAmendment)) {
      return "applyNetworkPolicyAmendment";
    }
  }
  return "";
}

function decisionStorageValue(decision) {
  return decisionKind(decision);
}

function decisionLabel(decision) {
  const kind = decisionKind(decision);
  switch (kind) {
    case "accept":
      return "允许一次";
    case "acceptForSession":
      return "本次会话允许";
    case "acceptWithExecpolicyAmendment":
      return "允许并更新策略";
    case "applyNetworkPolicyAmendment":
      return "允许并更新网络策略";
    case "decline":
      return "拒绝";
    case "cancel":
      return "取消";
    default:
      return kind || "unknown";
  }
}

function resolvedTitle(status, decision) {
  if (status === "resolved") {
    return "## 审批已收尾";
  }
  if (decision === "decline") {
    return "## 已拒绝";
  }
  if (decision === "cancel") {
    return "## 已取消";
  }
  if (decision) {
    return "## 已批准";
  }
  return "## 审批处理中";
}

function supportedDecisions(request) {
  if (request.method === "item/commandExecution/requestApproval") {
    const available = Array.isArray(request?.params?.availableDecisions)
      ? request.params.availableDecisions.filter((entry) => decisionKind(entry))
      : [];
    if (available.length) {
      return available;
    }
    return ["accept", "acceptForSession", "decline", "cancel"];
  }
  if (request.method === "item/fileChange/requestApproval" || request.method === "item/permissions/requestApproval") {
    return ["accept", "acceptForSession", "decline"];
  }
  return [];
}

function approvalStateKey(request) {
  return [
    trimText(request?.threadId),
    trimText(request?.turnId),
    trimText(request?.itemId),
    trimText(request?.method),
    trimText(request?.id),
  ].join("::");
}

function actionButton(decision, requestId) {
  const label = decisionLabel(decision);
  const kind = decisionKind(decision);
  const button = {
    tag: "button",
    text: {
      tag: "plain_text",
      content: label,
    },
    value: {
      kind: "codex_approval",
      requestId,
      decision,
    },
  };
  if (kind === "accept" || kind === "acceptWithExecpolicyAmendment" || kind === "applyNetworkPolicyAmendment") {
    button.type = "primary";
  } else if (kind === "decline") {
    button.type = "danger";
    button.confirm = {
      title: {
        tag: "plain_text",
        content: "确认拒绝？",
      },
      text: {
        tag: "plain_text",
        content: "拒绝后 Codex 会终止当前危险操作。",
      },
    };
  }
  return button;
}

function buildApprovalCardContent(request, parentStream) {
  const actions = supportedDecisions(request).map((decision) => actionButton(decision, request.id));
  return json({
    elements: [
      {
        tag: "markdown",
        content: approvalDetailsLines(request, parentStream),
      },
      ...(actions.length
        ? [{
            tag: "action",
            actions,
          }]
        : []),
    ],
  });
}

function buildApprovalStatusCard(state, parentStream, options = {}) {
  const decision = options.decision ?? state?.decision ?? "";
  const status = trimText(options.status || state?.status);
  const request = state?.payload || {};
  const lines = [
    resolvedTitle(status, decision),
    "",
    approvalReason(request),
  ];
  if (decision) {
    lines.push("", `- 决策: ${decisionLabel(decision)}`);
  }
  if (parentStream?.projectKey) {
    lines.push(`- 项目: \`${parentStream.projectKey}\``);
  }
  if (state?.requestId) {
    lines.push(`- Request: \`${state.requestId}\``);
  }
  if (status === "resolved") {
    lines.push("", "Codex 已确认该审批请求已结束。");
  } else {
    lines.push("", "已回传给 Codex，等待执行或收尾。");
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

function replyPayloadForDecision(request, decision) {
  if (request.method === "item/commandExecution/requestApproval" || request.method === "item/fileChange/requestApproval") {
    return { decision };
  }
  if (request.method === "item/permissions/requestApproval") {
    if (decision === "acceptForSession") {
      return {
        permissions: request?.params?.permissions || {},
        scope: "session",
      };
    }
    if (decision === "accept") {
      return {
        permissions: request?.params?.permissions || {},
        scope: "turn",
      };
    }
    return {
      permissions: {},
      scope: "turn",
    };
  }
  return { decision };
}

function isApprovalAction(inbound) {
  return inbound?.actionValue && inbound.actionValue.kind === "codex_approval";
}

export function createCodexApprovalRouter(deps) {
  async function handleCodexServerRequest(frame) {
    const request = parseCodexServerRequest(frame);
    const requestStateId = approvalStateKey(request);
    frame.runtime.log("codexbot-app-ts server_request", deps.buildTag, request.method || "", request.id || "", request.streamId || "");
    if (!requestStateId || !request.id || !request.method) {
      return {
        handled: false,
        commands: [],
      };
    }
    const parentStream = await deps.getStreamState(request.streamId);
    if (!parentStream) {
      frame.runtime.warn("codexbot-app-ts server_request missing parent stream", deps.buildTag, request.id || "", request.streamId || "");
      return {
        handled: false,
        commands: [],
      };
    }
    const existing = await deps.getApprovalRequestState(requestStateId);
    const approvalStream = existing?.approvalStreamId
      ? await deps.getStreamState(existing.approvalStreamId)
      : await deps.createDerivedStreamState(parentStream.streamId, {
          prompt: `[approval] ${request.method}`,
          threadId: request.threadId || parentStream.threadId || "",
          threadPath: request.threadPath || parentStream.threadPath || "",
          turnId: request.turnId || parentStream.turnId || "",
          status: "awaiting_approval",
          lastEvent: "codex.server_request",
        });
    if (!approvalStream) {
      return {
        handled: false,
        commands: [],
      };
    }
    await deps.upsertApprovalRequestState(requestStateId, {
      rpcRequestId: request.id,
      parentStreamId: parentStream.streamId,
      approvalStreamId: approvalStream.streamId,
      sessionKey: parentStream.sessionKey,
      chatId: parentStream.chatId,
      codexInstance: parentStream.codexInstance || frame.instance || "",
      method: request.method,
      threadId: request.threadId || "",
      turnId: request.turnId || "",
      itemId: request.itemId || "",
      status: "pending",
      decision: "",
      payload: request,
    });
    await deps.updateStreamState(approvalStream.streamId, {
      status: "awaiting_approval",
      lastEvent: "codex.server_request",
    });
    return {
      handled: true,
      commands: [
        deps.feishuCard(parentStream.chatId, buildApprovalCardContent({ ...request, id: requestStateId }, parentStream), approvalStream.streamId, "chat_id"),
      ],
    };
  }

  async function handleApprovalAction(inbound, frame) {
    if (!isApprovalAction(inbound)) {
      frame.runtime.log("codexbot-app-ts approval action ignored", deps.buildTag, inbound?.eventType || "", json(inbound?.actionValue || {}));
      return {
        handled: false,
        commands: [],
      };
    }
    const requestId = trimText(inbound?.actionValue?.requestId);
    const decision = inbound?.actionValue?.decision;
    const decisionKey = decisionStorageValue(decision);
    const state = await deps.getApprovalRequestState(requestId);
    if (!state) {
      frame.runtime.warn("codexbot-app-ts approval action missing state", deps.buildTag, requestId, decisionKey);
      return {
        handled: false,
        commands: [],
      };
    }
    const parentStream = state.parentStreamId ? await deps.getStreamState(state.parentStreamId) : undefined;
    if (state.status === "resolved" || state.status === "decided") {
      const responseCard = state.approvalStreamId
        ? buildApprovalStatusCard(state, parentStream, { status: state.status })
        : buildApprovalStatusCard(state, parentStream, { status: state.status });
      return {
        handled: true,
        commands: [],
        response: {
          status: 200,
          headers: {
            "content-type": "application/json",
          },
          body: responseCard,
        },
      };
    }
    const payload = replyPayloadForDecision(state.payload || {}, decision);
    frame.runtime.log("codexbot-app-ts approval reply", deps.buildTag, requestId, json(payload));
    await deps.upsertApprovalRequestState(requestId, {
      status: "decided",
      decision: decisionKey,
    });
    if (state.approvalStreamId) {
      await deps.updateStreamState(state.approvalStreamId, {
        status: "approval_decided",
        resultText: decisionLabel(decision),
        lastEvent: "feishu.card.action.trigger",
      });
    }
    return {
      handled: true,
      commands: [
        deps.codexRpcReply(state.rpcRequestId || requestId, payload, state.parentStreamId || state.approvalStreamId || "", state.codexInstance || frame.instance || ""),
      ],
      response: {
        status: 200,
        headers: {
          "content-type": "application/json",
        },
        body: buildApprovalStatusCard({
          ...state,
          decision: decisionKey,
          status: "decided",
        }, parentStream, {
          decision,
          status: "decided",
        }),
      },
    };
  }

  async function handleServerRequestResolved(notification, frame) {
    const requestId = trimText(notification?.requestId);
    const threadId = trimText(notification?.threadId);
    if (!requestId || !threadId) {
      return {
        handled: false,
        commands: [],
      };
    }
    const state = await deps.findApprovalRequestStateByRpcRequestId(threadId, requestId);
    if (!state || !state.approvalStreamId) {
      return {
        handled: false,
        commands: [],
      };
    }
    const parentStream = state.parentStreamId ? await deps.getStreamState(state.parentStreamId) : undefined;
    await deps.upsertApprovalRequestState(state.requestId, {
      status: "resolved",
    });
    await deps.finalizeStreamState(state.approvalStreamId, {
      status: "completed",
      resultText: decisionLabel(state.decision || ""),
      completedAt: Date.now(),
      lastEvent: notification.method || "serverRequest/resolved",
    });
    frame.runtime.log("codexbot-app-ts approval resolved", deps.buildTag, requestId, state.decision || "");
    return {
      handled: true,
      commands: [
        deps.feishuUpdateCard(state.approvalStreamId, buildApprovalStatusCard({
          ...state,
          status: "resolved",
        }, parentStream, {
          status: "resolved",
        })),
      ],
    };
  }

  return {
    handleApprovalAction,
    handleCodexServerRequest,
    handleServerRequestResolved,
  };
}
