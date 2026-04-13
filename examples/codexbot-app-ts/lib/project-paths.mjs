import { stat } from "fs";
import * as path from "path";

export function createProjectPathHelpers(deps) {
  function resolveProjectCwd(state, projectKey) {
    const currentProjectKey = typeof state.projectKey === "string" ? state.projectKey.trim() : "";
    const normalizedCwd = typeof state.cwd === "string" ? state.cwd.replace(/\/+$/, "") : "";
    const defaults = deps.botDefaults();
    const defaultCwd = typeof defaults.cwd === "string" ? defaults.cwd.replace(/\/+$/, "") : "";
    if (currentProjectKey && normalizedCwd.endsWith(`/${currentProjectKey}`)) {
      return `${normalizedCwd.slice(0, -currentProjectKey.length)}${projectKey}`;
    }
    if (defaultCwd) {
      if (defaultCwd.endsWith(`/${projectKey}`)) {
        return defaultCwd;
      }
      return `${defaultCwd}/${projectKey}`;
    }
    return normalizedCwd ? `${normalizedCwd}/${projectKey}` : projectKey;
  }

  function normalizeImportPath(rawPath) {
    return path.resolve(rawPath);
  }

  async function pathExistsAsDirectory(targetPath) {
    try {
      const info = await stat(targetPath);
      return !!info && typeof info.isDirectory === "function" && info.isDirectory();
    } catch (_) {
      return false;
    }
  }

  return {
    normalizeImportPath,
    pathExistsAsDirectory,
    resolveProjectCwd,
  };
}
