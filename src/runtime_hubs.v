module main

import api.mcp.protocol as mcp_protocol
import api.openai
import dbx
import plugin
import worker
import ws

struct TransportRuntimeHub {
mut:
	websocket ws.HubState
	db        dbx.Runtime
}

struct ProtocolRuntimeHub {
mut:
	runtime_config_json string
	mcp                 mcp_protocol.McpState
	openai              openai.OpenaiState
	plugins             plugin.PluginState
}

struct ExecutorRuntimeHub {
mut:
	worker worker.WorkerState
}
