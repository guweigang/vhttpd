export function sandboxPolicyType(sandbox) {
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

export function buildThreadStartParams(state, defaults) {
  return {
    cwd: state.cwd,
    model: state.model,
    approvalPolicy: defaults.approvalPolicy,
    sandbox: defaults.sandbox,
    experimentalRawEvents: true,
    persistExtendedHistory: true,
  };
}

// Resume metadata only; turn history remains on the server and is not replayed.
export function buildThreadResumeParams(state, defaults) {
  return {
    threadId: state.threadId,
    model: state.model,
    cwd: state.cwd,
    approvalPolicy: defaults.approvalPolicy,
    sandbox: defaults.sandbox,
    excludeTurns: true,
  };
}

export function buildTurnStartParams(stream, state, defaults) {
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
