module main

import api.mcp.protocol as mcp_protocol
import api.openai
import cachex
import dbx
import plugin
import worker

struct TransportRuntimeHub {
mut:
	db    dbx.Runtime
	cache cachex.Runtime
}

struct ProtocolRuntimeHub {
mut:
	runtime_config_json string
	runtime_plan_json   string
	mcp                 mcp_protocol.McpState
	openai              openai.OpenaiState
	plugins             plugin.PluginState
}

struct EngineRuntime {
mut:
	primary    worker.WorkerState
	additional map[string]&worker.WorkerState
}
