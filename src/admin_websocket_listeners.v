module main

import json2 as json
import veb

struct ListenerWebSocketCounters {
pub:
	listener_ids       []string
	active_connections int
	active_rooms       int
}

struct ProcessWebSocketCounters {
pub:
	scope              string = 'process'
	active_connections int
	active_rooms       int
	listeners          []ListenerWebSocketCounters
}

// Registry aliases can point at the same App. Count its owner once and expose
// every listener alias, without holding the registry lock while reading a hub.
fn (r &ActiveRuntimeRegistry) websocket_counters() ProcessWebSocketCounters {
	r.mu.@lock()
	apps := r.apps.clone()
	cfgs := r.cfgs.clone()
	r.mu.unlock()
	mut owners := []&App{}
	mut aliases := [][]string{}
	for i, app in apps {
		cfg := cfgs[i] or { continue }
		id := if cfg.plan_listener_id != '' { cfg.plan_listener_id } else { 'default' }
		mut found := -1
		for j, owner in owners {
			if voidptr(owner) == voidptr(app) {
				found = j
				break
			}
		}
		if found >= 0 {
			if id !in aliases[found] { aliases[found] << id }
		} else {
			owners << app
			aliases << [id]
		}
	}
	mut listeners := []ListenerWebSocketCounters{}
	mut connections := 0
	mut rooms := 0
	for i in 0 .. owners.len {
		mut owner := owners[i]
		owner.websocket.state.mu.@lock()
		active_connections := owner.websocket.state.conns.len
		active_rooms := owner.websocket.state.room_members.len
		owner.websocket.state.mu.unlock()
		connections += active_connections
		rooms += active_rooms
		listeners << ListenerWebSocketCounters{ listener_ids: aliases[i], active_connections: active_connections, active_rooms: active_rooms }
	}
	return ProcessWebSocketCounters{ active_connections: connections, active_rooms: rooms, listeners: listeners }
}

@['/admin/runtime/websocket-listeners'; get]
pub fn (mut app AdminApp) admin_runtime_websocket_listeners(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/websocket-listeners')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	snapshot := unsafe { g_active_runtime_registry.websocket_counters() }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(snapshot), {
		'admin_endpoint': 'runtime_websocket_listeners'
	})
}
