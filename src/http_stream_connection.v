module main

import net
import upstream.transport
import veb
import worker

interface HttpStreamSocket {
mut:
	write(buf []u8) !int
	close() !
}

struct HttpStreamConnection {
mut:
	socket HttpStreamSocket
	tcp    ?&net.TcpConn
}

fn (mut conn HttpStreamConnection) write(buf []u8) !int {
	return conn.socket.write(buf)
}

fn (mut conn HttpStreamConnection) close() ! {
	conn.socket.close()!
}

fn (mut conn HttpStreamConnection) write_sse(frame transport.WorkerStreamFrame) ! {
	if mut tcp := conn.tcp {
		worker.WorkerHttpStreamWriter.write_sse_message(mut tcp, frame)!
	} else {
		worker.WorkerHttpStreamWriter.write_sse_message_to_writer(mut conn.socket, frame)!
	}
}

// Keep plain HTTP stream support on toolchains predating TLS takeover.
fn takeover_https_stream[T](mut ctx T) !HttpStreamConnection {
	$for method in T.methods {
		$if method.name == 'takeover_tls_conn' {
			mut conn := ctx.$method()!
			return HttpStreamConnection{socket: conn}
		}
	}
	return error('HTTPS stream takeover is unavailable in this V toolchain')
}

fn takeover_http_stream(mut ctx Context) !HttpStreamConnection {
	if ctx.client_fd < 0 && isnil(ctx.conn) {
		return takeover_https_stream[veb.Context](mut ctx.Context)
	}
	ctx.takeover_conn()
	if isnil(ctx.conn) {
		return error('HTTP stream connection is unavailable')
	}
	return HttpStreamConnection{socket: ctx.conn, tcp: ctx.conn}
}
