module plugin

import config
import executor
import sync

// PluginState holds plugin configurations and vjsx executor instances.
pub struct PluginState {
mut:
	mu                  &sync.Mutex = &sync.Mutex{}
	closed              bool
	next_retirement     int
	shutdown_retirement int
	retiring            map[int][]executor.InProcVjsxExecutor
pub mut:
	configs map[string]config.PluginConfig
	vjsx    map[string]executor.InProcVjsxExecutor
}
