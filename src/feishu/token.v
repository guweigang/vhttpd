module feishu

import config

// An identity belongs to one app's current credentials, independent of runtime
// snapshots and of credential values that may rotate back to an earlier value.
@[heap]
struct TenantTokenOwner {}

pub struct TenantTokenRequest {
	name  string
	owner &TenantTokenOwner @[required]
pub:
	app_id       string
	app_secret   string
	cached_token string
}

// App.mu owns the surrounding provider configuration/registry transaction.
// This domain lock pairs credential publication with cache invalidation.
pub fn (mut s FeishuState) configure_app(name string, cfg config.FeishuAppConfig) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	previous := s.apps[name] or { config.FeishuAppConfig{} }
	s.apps[name] = cfg
	mut runtime := s.ensure_unlocked(name)
	if previous.app_id != cfg.app_id || previous.app_secret != cfg.app_secret {
		s.tenant_token_owners[name] = &TenantTokenOwner{}
		runtime.cache_tenant_access_token('', 0)
	}
	s.runtime[name] = runtime
}

// Capture credentials and cache eligibility in the same critical section.
// No network work or waiting is performed under this mutex.
pub fn (mut s FeishuState) begin_tenant_token_request(name string, now i64) !TenantTokenRequest {
	s.mu.@lock()
	defer { s.mu.unlock() }
	resolved := s.resolve_app_name(name)!
	cfg := s.apps[resolved] or { return error('missing feishu app config "${resolved}"') }
	owner := s.tenant_token_owners[resolved] or { &TenantTokenOwner{} }
	s.tenant_token_owners[resolved] = owner
	runtime := s.ensure_unlocked(resolved)
	cached := if runtime.tenant_access_token != ''
		&& now + i64(s.token_refresh_skew_seconds) < runtime.tenant_access_token_expire_unix {
		runtime.tenant_access_token
	} else {
		''
	}
	return TenantTokenRequest{
		name:         resolved
		owner:        owner
		app_id:       cfg.app_id
		app_secret:   cfg.app_secret
		cached_token: cached
	}
}

// Retired credentials cannot publish a refresh result or authorize its return.
pub fn (mut s FeishuState) commit_tenant_token_request(request TenantTokenRequest, token string, expire_unix i64) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	owner := s.tenant_token_owners[request.name] or { return false }
	if voidptr(owner) != voidptr(request.owner) { return false }
	mut runtime := s.ensure_unlocked(request.name)
	runtime.cache_tenant_access_token(token, expire_unix)
	s.runtime[request.name] = runtime
	return true
}
