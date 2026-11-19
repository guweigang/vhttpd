module veb

import net
import net.http

#include "@VEXEROOT/thirdparty/libgc/include/gc.h"

fn C.GC_get_total_bytes() u64

fn legacy_response_writer_copy(mut ctx Context, user_context Context) {
	unsafe { *ctx = user_context }
	ctx.res.body = user_context.res.body.clone()
	ctx.res.header = clone_response_writer_header(user_context.res.header)
	ctx.res.status_msg = user_context.res.status_msg.clone()
	ctx.res.http_version = user_context.res.http_version.clone()
	ctx.req.header = clone_response_writer_header(user_context.req.header)
	ctx.return_file = user_context.return_file.clone()
}

fn test_response_writer_allocation_comparison() {
	$if response_transfer_bench ? {
		for size in [1024, 8192, 65536] {
			payload := 'x'.repeat(size)
			mut totals := [u64(0), u64(0)]
			for arm in 0 .. 2 {
				for _ in 0 .. 256 {
					mut source := Context{}
					source.text(payload)
					mut writer := Context{}
					before := C.GC_get_total_bytes()
					if arm == 0 { legacy_response_writer_copy(mut writer, source) }
					else { writer.preserve_for_response_writer(mut source) }
					totals[arm] += C.GC_get_total_bytes() - before
					assert writer.res.body == payload
					writer.release_response_body()
					if arm == 1 { source.shared_response_body = true }
					if arm == 1 { source.release_response_body() }
					else if source.res.body.len > 0 {
						unsafe { source.res.body.free() }
						source.res.body = ''
					}
				}
			}
			assert totals[0] > totals[1]
			println('BENCH size=${size} before=${totals[0]} after=${totals[1]} iterations=256')
		}
	}
}

struct BaselineResponseContextLayout {
mut:
	// veb will try to infer the content type base on file extension,
	// and if `content_type` is not empty the `Content-Type` header will always be
	// set to this value
	content_type string
	// done is set to true when a response can be sent over `conn`
	done bool
	// If the `Connection: close` header is present the connection should always be closed
	client_wants_to_close bool
	// Configuration for static file compression (set by serve_if_static)
	enable_static_gzip            bool
	enable_static_zstd            bool
	enable_static_compression     bool
	static_compression_max_size   int
	static_compression_mime_types []string
	// controls whether veb should automatically send the response or whether the handler
	// takes over response writing.
	takeover_mode         ContextTakeoverMode
	return_file           string
	custom_mime_types_ref &map[string]string = unsafe { nil }
	// raw client file descriptor, used by the fasthttp backend to create a TcpConn
	// on demand when takeover_conn() is called
	client_fd int = -1
	// already_compressed indicates that the response body is already compressed (zstd/gzip)
	// and the compression middlewares should skip it
	already_compressed bool
	// throttle_leases are the handler slots throttle middleware took for this
	// request. `handle_route` frees them however the request ends: 404s and
	// requests a middleware refuses skip the after-middleware, so an
	// after-middleware could not free them reliably.
	throttle_leases []ThrottleLease
	// trusted_proxies are the socket peer addresses whose forwarding headers
	// `ip()` may believe. The framework copies this from a `trusted_proxies`
	// field on the app struct into every request context; an app that does not
	// declare one gets the empty list, so `ip()` answers the socket peer.
	trusted_proxies []string
	// access_log_start_ns is the monotonic clock reading (`time.sys_mono_now()`)
	// the access-log middleware stamped when the request arrived, so its finish
	// half can log the latency. Zero means unstamped.
	access_log_start_ns i64
pub:
	// TODO: move this to `handle_request`
	// time.ticks() from start of veb connection handle.
	// You can use it to determine how much time is spent on your request.
	page_gen_start i64
pub mut:
	// how the http response should be handled by veb's backend
	return_type       ContextReturnType = .normal
	req               http.Request @[skip]
	custom_mime_types map[string]string
	// TCP connection to client. Only for advanced usage!
	conn &net.TcpConn = unsafe { nil }
	// Map containing query params for the route.
	// http://localhost:3000/index?q=vpm&order_by=desc => { 'q': 'vpm', 'order_by': 'desc' }
	query map[string]string
	// Multipart-form fields.
	form map[string]string
	// Files from multipart-form.
	files map[string][]http.FileData
	res   http.Response
	// use form_error to pass errors from the context to your frontend
	form_error string
	// livereload_poll_interval_ms is not used: veb serves the livereload script
	// before any user code runs, so it could never be set. With
	// `-d veb_livereload_polling`, use `-d veb_livereload_poll_ms=<ms>` instead.
	livereload_poll_interval_ms int = 250 @[deprecated: 'use `-d veb_livereload_poll_ms=<ms>`']
}

fn test_response_context_layout_growth_is_one_pointer() {
	assert sizeof(Context) <= sizeof(BaselineResponseContextLayout) + sizeof(voidptr)
	println('LAYOUT before=${sizeof(BaselineResponseContextLayout)} after=${sizeof(Context)}')
}
