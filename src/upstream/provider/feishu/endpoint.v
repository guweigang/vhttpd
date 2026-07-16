module feishu

import json

// ── Endpoint URL Helpers ──

pub fn RuntimeWsEndpointData.normalize_open_base(raw string) string {
	mut base := raw.trim_space()
	if base == '' {
		base = 'https://open.feishu.cn/open-apis'
	}
	for base.len > 1 && base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return base
}

pub fn RuntimeWsEndpointData.root_base(base string) string {
	mut trimmed := RuntimeWsEndpointData.normalize_open_base(base)
	if trimmed.ends_with('/open-apis') {
		trimmed = trimmed[..trimmed.len - '/open-apis'.len]
	}
	return trimmed
}

pub fn RuntimeWsEndpointData.endpoint_urls(base string) []string {
	primary := '${RuntimeWsEndpointData.normalize_open_base(base)}/callback/ws/endpoint'
	fallback := '${RuntimeWsEndpointData.root_base(base)}/callback/ws/endpoint'
	if fallback == primary {
		return [primary]
	}
	return [primary, fallback]
}

pub fn RuntimeWsEndpointData.request_body(app_id string, app_secret string) string {
	return json.encode({
		'AppID':     app_id
		'AppSecret': app_secret
	})
}
