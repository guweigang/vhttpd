module main

import time
import veb
import ws

fn https_websocket_socket[T](ctx &T) ?int {
	$for method in T.methods {
		$if method.name == 'tls_socket_handle' {
			return ctx.$method()
		}
	}
	return none
}

fn takeover_https_websocket[T](mut ctx T) !&ws.IngressConnection {
	// Toolchains with TLS stream takeover alone lack timed duplex reads.
	$for method in T.methods {
		$if method.name == 'takeover_tls_conn' {
			mut tls := ctx.$method()!
			return websocket_tls_ingress(tls)
		}
	}
	return error('WebSocket TLS takeover is unavailable in this V toolchain')
}

fn websocket_tls_ingress[T](tls T) !&ws.IngressConnection {
	$if T is ws.TlsIngressSocket {
		return ws.IngressConnection.tls(tls)
	} $else {
		return error('WebSocket TLS duplex reads are unavailable in this V toolchain')
	}
}

fn takeover_inbound_websocket(mut ctx Context) !&ws.IngressConnection {
	if ctx.client_fd < 0 && isnil(ctx.conn) {
		return takeover_https_websocket[veb.Context](mut ctx.Context)
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	return ws.IngressConnection.tcp(ctx.conn)
}
