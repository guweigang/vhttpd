module ws

import net.websocket
import connection_runtime

pub struct RelaySessionContext {
pub:
	ingress_run      ?&IngressRun
	register_conn_fn fn (string, string, string, string, string, string, map[string]string, map[string]string, string, &websocket.Client, &DispatchConnState, ?&IngressRun) @[required]
	mark_closing_fn  fn (string, &DispatchConnState) bool @[required]
	flush_pending_fn fn (string)                     @[required]
	cleanup_conn_fn  fn (string, &DispatchConnState) @[required]
	bind_outbound_fn fn (string, &DispatchConnState, &connection_runtime.Session) bool @[required]
	send_to_fn       fn (string, string, string) bool @[required]
}

pub fn (rt RelaySessionContext) register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState) {
	rt.register_conn_fn(conn_id, worker_socket, method, req_id, trace_id, path, query, headers,
		remote_addr, client, lifecycle, rt.ingress_run)
}

pub fn (rt RelaySessionContext) mark_closing(conn_id string, lifecycle &DispatchConnState) bool {
	return rt.mark_closing_fn(conn_id, lifecycle)
}

pub fn (rt RelaySessionContext) flush_pending(conn_id string) {
	rt.flush_pending_fn(conn_id)
}

pub fn (rt RelaySessionContext) cleanup_conn(conn_id string, lifecycle &DispatchConnState) {
	rt.cleanup_conn_fn(conn_id, lifecycle)
}

pub fn (rt RelaySessionContext) send_to(conn_id string, data string, opcode string) bool {
	return rt.send_to_fn(conn_id, data, opcode)
}

pub fn (rt RelaySessionContext) bind_outbound(conn_id string, lifecycle &DispatchConnState, session &connection_runtime.Session) bool {
	return rt.bind_outbound_fn(conn_id, lifecycle, session)
}

pub fn (rt RelaySessionContext) with_ingress(run ?&IngressRun) RelaySessionContext {
	return RelaySessionContext{ ...rt, ingress_run: run }
}
