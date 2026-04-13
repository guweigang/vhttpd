export function normalizeMainInstanceAlias(value, fallbackValue = "") {
  const text = typeof value === "string" ? value.trim() : "";
  if (text === "default") {
    return "main";
  }
  if (text !== "") {
    return text;
  }
  return fallbackValue;
}
