export async function resolveCodexInstance(state, stream = undefined, project = undefined, deps) {
  const defaults = deps.botDefaults();
  if (stream?.codexInstance) {
    return deps.fallbackCodexInstance(stream.codexInstance, defaults);
  }
  if (state?.codexInstance) {
    return deps.fallbackCodexInstance(state.codexInstance, defaults);
  }
  const resolvedProject = project || (state?.projectKey ? await deps.getProjectRecord(state.projectKey) : undefined);
  if (resolvedProject?.defaultCodexInstance) {
    return deps.fallbackCodexInstance(resolvedProject.defaultCodexInstance, defaults);
  }
  return deps.fallbackCodexInstance("", defaults);
}

export async function ensureStreamCodexInstance(stream, state, project = undefined, deps) {
  const resolved = await resolveCodexInstance(state, stream, project, deps);
  if (stream?.codexInstance === resolved) {
    return stream;
  }
  return deps.updateStreamState(stream.streamId, { codexInstance: resolved });
}

export async function buildCodexPreflightCommands(state, stream, project = undefined, deps) {
  const defaults = deps.botDefaults();
  const instance = await resolveCodexInstance(state, stream, project, deps);
  const normalizedInstance = deps.fallbackCodexInstance(instance, defaults);
  const defaultInstance = deps.fallbackCodexInstance("", defaults);
  const explicitNonDefaultInstance = normalizedInstance !== defaultInstance && deps.configuredCodexInstance(normalizedInstance);
  if (!defaults.enableProviderInstancePreflight && !explicitNonDefaultInstance) {
    return [];
  }
  const spec = deps.buildCodexInstanceSpec(state, stream, defaults, normalizedInstance);
  return deps.buildProviderInstanceCommands("codex", instance, spec, "connected");
}
