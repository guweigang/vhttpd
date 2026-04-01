export function mdInline(value) {
  const text = typeof value === "string" ? value.trim() : String(value ?? "").trim();
  if (text === "") {
    return "`-`";
  }
  return `\`${text.replace(/`/g, "'")}\``;
}

export function mdText(value) {
  return typeof value === "string" ? value.trim() : String(value ?? "").trim();
}

export function mdSection(title, lines = []) {
  const body = lines.filter((line) => typeof line === "string" && line.trim() !== "");
  if (!body.length) {
    return `**${title}**`;
  }
  return [`**${title}**`, ...body].join("\n");
}

export function mdBullet(label, value, { code = false } = {}) {
  const text = mdText(value);
  if (text === "") {
    return "";
  }
  return `- ${label}: ${code ? mdInline(text) : text}`;
}
