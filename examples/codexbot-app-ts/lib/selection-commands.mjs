export function createSelectionCommandHandlers(deps) {
  async function handleInstancesCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    await deps.rememberSelectionScope(session.sessionKey, session.chatId, "instance");
    const project = await deps.getProjectRecord(state.projectKey);
    const configuredInstances = deps.providerConfig.providers?.codex?.instances || {};
    const persisted = await deps.listInstanceSpecs("codex");
    const persistedMap = new Map(persisted.map((entry) => [entry.instance, entry]));
    const names = new Set([...Object.keys(configuredInstances), ...persisted.map((entry) => entry.instance)]);
    const defaults = deps.botDefaults();
    const entries = Array.from(names)
      .sort()
      .map((name) => {
        const configured = configuredInstances[name] || {};
        const stored = persistedMap.get(name);
        return {
          name,
          url: configured.url || stored?.config?.url || (name === "main" ? defaults.codexUrl : ""),
          cwd: configured.cwd || stored?.config?.cwd || (name === "main" ? defaults.cwd : ""),
          startup: configuredInstances[name] ? (configured.startup === false ? "false" : "true") : "dynamic",
          desiredState: stored?.desiredState || "",
          source: configuredInstances[name] ? "config" : "registry",
        };
      });
    return {
      handled: true,
      commands: [deps.replyText(session, deps.codexInstancesListText(state, project, entries))],
    };
  }

  async function handleInstanceCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const project = await deps.getProjectRecord(state.projectKey);
    const parts = text.split(/\s+/).filter(Boolean);
    if (parts.length === 1) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.currentInstanceText(state, project))],
      };
    }
    const instance = deps.fallbackCodexInstance(parts.slice(1).join(" ").trim(), deps.botDefaults());
    if (!deps.configuredCodexInstance(instance)) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.codexInstanceUnknownText(instance, deps.configuredCodexInstanceNames()))],
      };
    }
    const next = await deps.updateChatState(session.sessionKey, session.chatId, {
      codexInstance: instance,
      threadId: "",
      threadPath: "",
    }, {
      syncProjectDefaults: false,
    });
    return {
      handled: true,
      commands: [deps.replyText(session, deps.instanceSelectedText(next, state.codexInstance || "", project))],
    };
  }

  async function handleProjectInstanceCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const match = text.match(/^\/project-instance\s+(\S+)\s+(\S+)\s*$/);
    if (!match) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.usageText("/project-instance", "[project_key] [instance]"))],
      };
    }
    const projectKey = match[1].trim();
    const instance = deps.fallbackCodexInstance(match[2].trim(), deps.botDefaults());
    if (!deps.configuredCodexInstance(instance)) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.codexInstanceUnknownText(instance, deps.configuredCodexInstanceNames()))],
      };
    }
    const boundProjects = await deps.listBoundChatProjects(session.chatId, 128);
    const bound = boundProjects.find((item) => item.projectKey === projectKey);
    if (!bound) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectNotBoundText(projectKey))],
      };
    }
    const updatedProject = await deps.updateProjectDefaultCodexInstance(projectKey, instance);
    if (!updatedProject) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectMissingText(projectKey))],
      };
    }
    if (state.projectKey === projectKey) {
      const next = await deps.updateChatState(session.sessionKey, session.chatId, {
        codexInstance: instance,
        threadId: "",
        threadPath: "",
      }, {
        syncProjectDefaults: false,
      });
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectInstanceUpdatedText(updatedProject, state.projectKey, next.codexInstance))],
      };
    }
    return {
      handled: true,
      commands: [deps.replyText(session, deps.projectInstanceUpdatedText(updatedProject, state.projectKey, state.codexInstance))],
    };
  }

  async function handleProjectCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parts = text.split(/\s+/).filter(Boolean);
    if (parts.length === 1) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.currentProjectText(state))],
      };
    }
    const projectKey = parts.slice(1).join(" ").trim();
    const boundProjects = await deps.listBoundChatProjects(session.chatId, 64);
    const bound = boundProjects.find((item) => item.projectKey === projectKey);
    if (!bound) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectNotBoundText(projectKey))],
      };
    }
    const nextInstance = deps.fallbackCodexInstance(
      bound.defaultCodexInstance || deps.botDefaults().defaultCodexInstance,
      deps.botDefaults(),
    );
    const next = await deps.updateChatState(session.sessionKey, session.chatId, {
      projectKey,
      cwd: bound.repoPath || deps.resolveProjectCwd(state, projectKey),
      codexInstance: nextInstance,
      threadId: "",
      threadPath: "",
    }, {
      syncProjectDefaults: false,
    });
    return {
      handled: true,
      commands: [deps.replyText(session, deps.projectSelectedText(next))],
    };
  }

  async function handleModelCommand(session, text) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parts = text.split(/\s+/).filter(Boolean);
    if (parts.length === 1) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.currentModelText(state))],
      };
    }
    const model = parts.slice(1).join(" ").trim();
    const next = await deps.updateChatState(session.sessionKey, session.chatId, {
      model,
      threadId: "",
      threadPath: "",
    });
    return {
      handled: true,
      commands: [deps.replyText(session, deps.modelSelectedText(next))],
    };
  }

  async function handleProjectsCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    await deps.rememberSelectionScope(session.sessionKey, session.chatId, "project");
    const projects = (await deps.listBoundChatProjects(session.chatId, 8)).map((project) => ({
      projectKey: project.projectKey,
      model: project.defaultModel || (project.projectKey === state.projectKey ? state.model : ""),
      cwd: project.repoPath || "",
      threadId: project.projectKey === state.projectKey ? (state.threadId || "") : "",
    }));
    return {
      handled: true,
      commands: [deps.replyText(session, deps.projectsListText(state, projects))],
    };
  }

  async function handleModelsCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    await deps.rememberSelectionScope(session.sessionKey, session.chatId, "model");
    return {
      handled: true,
      commands: [deps.replyText(session, deps.modelsListText(state, deps.botDefaults().supportedModels || []))],
    };
  }

  return {
    handleInstanceCommand,
    handleInstancesCommand,
    handleModelCommand,
    handleModelsCommand,
    handleProjectCommand,
    handleProjectInstanceCommand,
    handleProjectsCommand,
  };
}
