module main

import server_lifecycle
import ws
import executor

fn test_websocket_counters_include_secondary_listener_and_deduplicate_aliases() {
	mut primary := &App{ websocket: WebSocketRuntime.new(false) }
	mut secondary := &App{ websocket: WebSocketRuntime.new(true) }
	secondary.websocket.state.conns['fixture'] = ws.HubConn{ id: 'fixture', lifecycle: &ws.DispatchConnState{} }
	secondary.websocket.state.room_members['fixture-room'] = {
		'fixture': true
	}
	mut registry := ActiveRuntimeRegistry{}
	base := server_lifecycle.ServerRuntimeConfig{ executor_plan: executor.LogicExecutorRuntimePlan{ executor: executor.DisabledLogicExecutor{}, lifecycle: executor.disabled_executor_lifecycle() } }
	registry.register(primary, server_lifecycle.ServerRuntimeConfig{ ...base, plan_listener_id: 'web' })
	registry.register(secondary, server_lifecycle.ServerRuntimeConfig{ ...base, plan_listener_id: 'paseo' })
	registry.register(secondary, server_lifecycle.ServerRuntimeConfig{ ...base, plan_listener_id: 'paseo-alias' })
	before := registry.websocket_counters()
	assert before.scope == 'process' && before.active_connections == 1 && before.active_rooms == 1
	assert before.listeners.len == 2 && before.listeners[0].active_connections == 0
	assert before.listeners[1].listener_ids == ['paseo', 'paseo-alias']
	secondary.websocket.state.conns.delete('fixture')
	secondary.websocket.state.room_members.clear()
	after := registry.websocket_counters()
	assert after.active_connections == 0 && after.active_rooms == 0
	assert before.active_connections == 1
}
