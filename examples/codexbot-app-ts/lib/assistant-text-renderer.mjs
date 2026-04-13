function containsMarkdownSyntax(text) {
  if (typeof text !== "string") {
    return false;
  }
  return /(^|\n)(#{1,6}\s|[-*]\s|\d+\.\s|>\s)|```|\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)/m.test(text);
}

function looksLikeLabelValueLine(line) {
  return /^[A-Za-z][A-Za-z0-9 /_-]{1,32}:\s+.+$/.test(line);
}

function looksLikeBulletLine(line) {
  return /^[-*+•]\s+.+$/.test(line);
}

function looksLikeNumberedLine(line) {
  return /^\d+[\.\)]\s+.+$/.test(line);
}

function normalizeListLine(line) {
  if (looksLikeBulletLine(line)) {
    return line.replace(/^[-*+•]\s+/, "- ");
  }
  if (looksLikeNumberedLine(line)) {
    return line.replace(/^(\d+)\)\s+/, "$1. ");
  }
  return line;
}

function looksLikeCodeLine(line) {
  return /[{};<>]/.test(line)
    || /=>/.test(line)
    || /^\s*(const|let|var|if|else|for|while|return|function|class|interface|type|import|export|SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|WITH)\b/i.test(line)
    || /^\s*<\/?[A-Za-z][^>]*>$/.test(line)
    || /^\s*[A-Za-z0-9_.]+\([^)]*\)\s*$/.test(line)
    || /^\s*[\[{].*[\]}]\s*$/.test(line);
}

function looksLikeCodeBlock(lines) {
  if (!Array.isArray(lines) || lines.length < 2) {
    return false;
  }
  let score = 0;
  for (const line of lines) {
    if (looksLikeCodeLine(line)) {
      score += 1;
    }
  }
  return score >= Math.max(2, Math.ceil(lines.length / 2));
}

function joinWrappedParagraph(lines) {
  return lines
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function splitMarkdownBlocks(text) {
  const lines = typeof text === "string" ? text.replace(/\r\n/g, "\n").split("\n") : [];
  const blocks = [];
  let current = [];
  let inFence = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("```")) {
      if (!inFence && current.length) {
        blocks.push({ type: "text", lines: current.slice() });
        current = [];
      }
      current.push(line);
      inFence = !inFence;
      if (!inFence) {
        blocks.push({ type: "fence", lines: current.slice() });
        current = [];
      }
      continue;
    }
    if (inFence) {
      current.push(line);
      continue;
    }
    if (trimmed === "") {
      if (current.length) {
        blocks.push({ type: "text", lines: current.slice() });
        current = [];
      }
      continue;
    }
    current.push(line);
  }
  if (current.length) {
    blocks.push({ type: inFence ? "fence" : "text", lines: current.slice() });
  }
  return blocks;
}

function looksLikeHeadingLine(line) {
  return /^#{1,6}\s+.+$/.test(line.trim());
}

function looksLikeQuoteLine(line) {
  return /^>\s+.+$/.test(line.trim());
}

function looksLikeTableRow(line) {
  const trimmed = line.trim();
  return trimmed.includes("|") && /^\|?.+\|.+\|?$/.test(trimmed);
}

function looksLikeTableDivider(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line.trim());
}

function parseTableCells(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function renderMarkdownTableBlock(lines) {
  if (lines.length < 2 || !looksLikeTableRow(lines[0]) || !looksLikeTableDivider(lines[1])) {
    return "";
  }
  const headers = parseTableCells(lines[0]);
  const rows = lines.slice(2).filter((line) => looksLikeTableRow(line));
  if (!headers.length || !rows.length) {
    return "";
  }
  return rows.map((line, index) => {
    const cells = parseTableCells(line);
    const parts = [];
    for (let i = 0; i < headers.length; i += 1) {
      const header = headers[i] || `col_${i + 1}`;
      const value = cells[i] || "";
      if (value) {
        parts.push(`**${header}**: ${value}`);
      }
    }
    return `${index + 1}. ${parts.join(" | ")}`.trim();
  }).join("\n");
}

function normalizeMarkdownTextBlock(lines) {
  const trimmedLines = lines.map((line) => line.replace(/\s+$/g, ""));
  const compact = trimmedLines.map((line) => line.trim()).filter(Boolean);
  if (!compact.length) {
    return "";
  }
  if (compact.length >= 2 && compact.every(looksLikeLabelValueLine)) {
    return compact.map((line) => {
      const index = line.indexOf(":");
      const label = line.slice(0, index).trim();
      const value = line.slice(index + 1).trim();
      return `- **${label}**: ${value}`;
    }).join("\n");
  }
  if (compact.every((line) => looksLikeBulletLine(line) || looksLikeNumberedLine(line))) {
    return compact.map((line) => normalizeListLine(line)).join("\n");
  }
  const tableBlock = renderMarkdownTableBlock(trimmedLines);
  if (tableBlock) {
    return tableBlock;
  }
  if (compact.some((line) => looksLikeHeadingLine(line) || looksLikeQuoteLine(line))) {
    return trimmedLines.map((line) => normalizeListLine(line)).join("\n").trim();
  }
  return joinWrappedParagraph(trimmedLines);
}

function normalizeMarkdownForFeishu(text) {
  const raw = typeof text === "string" ? text.replace(/\r\n/g, "\n").trim() : "";
  if (raw === "") {
    return "";
  }
  const blocks = splitMarkdownBlocks(raw)
    .map((block) => {
      if (block.type === "fence") {
        return block.lines.join("\n").trim();
      }
      return normalizeMarkdownTextBlock(block.lines);
    })
    .filter((block) => typeof block === "string" && block.trim() !== "");
  return blocks.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
}

function renderPlainAssistantBlock(block) {
  const rawLines = block.split("\n").map((line) => line.replace(/\s+$/g, ""));
  const lines = rawLines.map((line) => line.trim()).filter(Boolean);
  if (!lines.length) {
    return "";
  }
  if (lines.length >= 2 && lines.every(looksLikeLabelValueLine)) {
    return lines.map((line) => {
      const index = line.indexOf(":");
      const label = line.slice(0, index).trim();
      const value = line.slice(index + 1).trim();
      return `- **${label}**: ${value}`;
    }).join("\n");
  }
  if (lines.every((line) => looksLikeBulletLine(line) || looksLikeNumberedLine(line))) {
    return lines.map((line) => normalizeListLine(line)).join("\n");
  }
  if (looksLikeCodeBlock(rawLines.filter((line) => line.trim() !== ""))) {
    return ["```", ...rawLines.filter((line) => line.trim() !== ""), "```"].join("\n");
  }
  return joinWrappedParagraph(rawLines);
}

export function renderCodexAssistantText(text) {
  const raw = typeof text === "string" ? text.replace(/\r\n/g, "\n").trim() : "";
  if (raw === "") {
    return "";
  }
  if (containsMarkdownSyntax(raw)) {
    return normalizeMarkdownForFeishu(raw);
  }
  const blocks = raw
    .split(/\n{2,}/)
    .map((block) => renderPlainAssistantBlock(block))
    .filter(Boolean);
  const body = blocks.join("\n\n").trim();
  return body === "" ? "" : normalizeMarkdownForFeishu(body);
}
