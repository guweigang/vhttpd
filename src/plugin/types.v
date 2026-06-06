module plugin

import config
import executor

// PluginState holds plugin configurations and vjsx executor instances.
pub struct PluginState {
pub mut:
	configs  map[string]config.PluginConfig
	vjsx     map[string]executor.InProcVjsxExecutor
}
