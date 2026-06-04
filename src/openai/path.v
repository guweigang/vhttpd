module openai

// PathContext bridges HTTP path utilities from main to the openai sub-module.
pub struct PathContext {
pub:
	normalize_path           fn (string) string
	normalize_request_target fn (string) (string, string)
	parse_query_map          fn (string) map[string]string
}

// normalize_base_path canonicalizes an OpenAI API base path.
pub fn normalize_base_path(ctx PathContext, raw string) string {
	mut base := ctx.normalize_path(raw.trim_space())
	for base.len > 1 && base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return base
}

// relative_path computes the upstream-relative path from a full request target.
pub fn relative_path(ctx PathContext, target string, base_path string) ?string {
	request_path, _ := ctx.normalize_request_target(target)
	path := ctx.normalize_path(request_path)
	base := normalize_base_path(ctx, base_path)
	if path == base {
		return ''
	}
	prefix := '${base}/'
	if !path.starts_with(prefix) {
		return none
	}
	return '/' + path[prefix.len..]
}

// relative_target computes the upstream-relative target including query string.
pub fn relative_target(ctx PathContext, target string, base_path string) ?string {
	request_path, query := ctx.normalize_request_target(target)
	path := ctx.normalize_path(request_path)
	base := normalize_base_path(ctx, base_path)
	mut relative := ''
	if path == base {
		relative = ''
	} else {
		prefix := '${base}/'
		if !path.starts_with(prefix) {
			return none
		}
		relative = '/' + path[prefix.len..]
	}
	if query == '' {
		return relative
	}
	return '${relative}?${query}'
}

// is_stream_target checks whether a request target contains stream=true/1/yes.
pub fn is_stream_target(ctx PathContext, target string) bool {
	_, query := ctx.normalize_request_target(target)
	if query == '' {
		return false
	}
	params := ctx.parse_query_map(query)
	stream := params['stream'] or { return false }
	return stream.to_lower() in ['1', 'true', 'yes']
}
