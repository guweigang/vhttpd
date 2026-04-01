export function isUseCommandText(text) {
  return typeof text === "string" && /^\/use(?:\s|$)/.test(text.trim());
}
