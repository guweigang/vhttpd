export function createCodexStatusHelpers(deps) {
  function codexFinalizingText() {
    return deps.mdSection("Finishing", [
      "- Waiting for final answer from Codex.",
    ]);
  }

  function isTerminalIdleStatus(status) {
    return typeof status === "string" && status.trim().toLowerCase() === "idle";
  }

  function isTerminalStreamStatus(status) {
    const text = typeof status === "string" ? status.trim().toLowerCase() : "";
    return text === "completed" || text === "error" || text === "cancelled";
  }

  return {
    codexFinalizingText,
    isTerminalIdleStatus,
    isTerminalStreamStatus,
  };
}
