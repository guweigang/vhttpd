module main

struct HttpRequestIdentity {}

fn HttpRequestIdentity.request_id(ctx Context, path string) string {
	return resolve_request_id(ctx, path)
}

fn HttpRequestIdentity.trace_id(ctx Context, path string) string {
	return resolve_trace_id(ctx, path)
}
