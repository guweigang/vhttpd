// Current app-server (-32600) reports a missing rollout explicitly. A generic
// "thread not found" can mean unloaded; never infer history loss from that text.
export function isMissingThreadHistory(response, threadId) {
  if (!response?.hasError || response.method !== "thread/resume" || !threadId) return false;
  const error = response.raw?.raw_response?.error || response.raw?.error || response.result;
  return error?.code === -32600
    && typeof error.message === "string"
    && error.message.trim() === `no rollout found for thread id ${threadId}`;
}
