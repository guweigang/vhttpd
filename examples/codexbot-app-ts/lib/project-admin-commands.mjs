import * as path from "path";
import { mkdir } from "fs";

export function createProjectAdminCommandHandlers(deps) {
  async function resolveBindProjectPath(projectKey, rawPath) {
    const explicitPath = typeof rawPath === "string" ? rawPath.trim() : "";
    if (explicitPath) {
      return deps.normalizeImportPath(explicitPath);
    }
    const projectRoot = (await deps.getSettingValue("project_root_dir")).trim();
    if (projectRoot === "") {
      return "";
    }
    return path.join(path.resolve(projectRoot), projectKey);
  }

  async function handleCreateCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parts = text.split(/\s+/).filter(Boolean);
    if (parts.length !== 2) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.usageText("/create", "[project_key]"))],
      };
    }
    const projectKey = parts[1].trim();
    const projectRoot = (await deps.getSettingValue("project_root_dir")).trim();
    if (projectRoot === "") {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectRootMissingText())],
      };
    }
    const existingProject = await deps.getProjectRecord(projectKey);
    if (existingProject) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectExistsText(projectKey, existingProject.repoPath || ""))],
      };
    }
    const repoPath = path.join(path.resolve(projectRoot), projectKey);
    if (await deps.pathExistsAsDirectory(repoPath)) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectDirectoryExistsText(projectKey, repoPath))],
      };
    }
    await mkdir(repoPath, { recursive: true });
    const nextInstance = deps.fallbackCodexInstance(state.codexInstance, deps.botDefaults());
    const next = await deps.updateChatState(session.sessionKey, session.chatId, {
      projectKey,
      cwd: repoPath,
      codexInstance: nextInstance,
      threadId: "",
      threadPath: "",
    });
    return {
      handled: true,
      commands: [deps.replyText(session, deps.projectCreatedText({ projectKey, repoPath }, next))],
    };
  }

  async function handleImportCommand(session) {
    return {
      handled: true,
      commands: [deps.replyText(session, deps.bindMergedText())],
    };
  }

  async function handleBindCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const match = text.match(/^\/bind\s+(\S+)(?:\s+(.+))?$/);
    if (!match) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.usageText("/bind", "[project_key] [path]"))],
      };
    }
    const projectKey = match[1].trim();
    const repoPath = await resolveBindProjectPath(projectKey, match[2] || "");
    if (!repoPath) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectRootMissingText())],
      };
    }
    if (!(await deps.pathExistsAsDirectory(repoPath))) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.importPathInvalidText(repoPath))],
      };
    }
    const project = await deps.getProjectRecord(projectKey);
    if (!project) {
      const defaultCodexInstance = deps.fallbackCodexInstance(state.codexInstance, deps.botDefaults());
      await deps.ensureProjectRecord(projectKey, repoPath, {
        defaultModel: state.model,
        defaultCodexInstance,
      });
      await deps.bindProjectToChat(session.chatId, projectKey, false);
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectRegisteredText({ projectKey, repoPath }, state))],
      };
    }
    const existingPath = typeof project.repoPath === "string" ? project.repoPath.trim() : "";
    if (existingPath) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectPathAlreadyBoundText(projectKey, existingPath))],
      };
    }
    await deps.updateProjectRecordPath(projectKey, repoPath);
    await deps.bindProjectToChat(session.chatId, projectKey, false);
    return {
      handled: true,
      commands: [deps.replyText(session, deps.projectPathFilledText({ projectKey, repoPath }, state))],
    };
  }

  async function handleUnbindCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parts = text.split(/\s+/).filter(Boolean);
    if (parts.length !== 2) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.usageText("/unbind", "[project_key]"))],
      };
    }
    const projectKey = parts[1].trim();
    const boundProjects = await deps.listBoundChatProjects(session.chatId, 128);
    const bound = boundProjects.find((item) => item.projectKey === projectKey);
    if (!bound) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectNotBoundText(projectKey))],
      };
    }
    if (state.projectKey === projectKey) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectUnbindCurrentBlockedText(projectKey))],
      };
    }
    await deps.unbindProjectFromChat(session.chatId, projectKey);
    return {
      handled: true,
      commands: [deps.replyText(session, deps.projectUnboundText(projectKey))],
    };
  }

  return {
    handleBindCommand,
    handleCreateCommand,
    handleImportCommand,
    handleUnbindCommand,
  };
}
